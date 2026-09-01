# Example reservation agent and tool

A worked example of a custom Rossoctl agent and its MCP tool, in the same
shape as the platform's own weather-service / weather-tool example. The
agent negotiates a reservation time with a customer over chat; the tool
is the source of truth for availability and bookings.

## What it does

- **Agent** (`agent/`): an A2A agent that talks with the customer, offers
  three concrete date/time options when asked to book, and keeps going
  back and forth until the customer agrees on one. It never invents
  availability or reservation ids itself - every check, booking,
  cancellation, and reschedule goes through the tool.
- **Tool** (`tool/`): an MCP server that is the only thing that actually
  knows what's booked. Business hours are Monday-Friday, 09:00-17:00,
  fixed 30-minute slots, the same for every customer. It exposes:
  `get_business_hours`, `check_availability`, `suggest_reservation_times`,
  `book_reservation`, `get_reservation`, `cancel_reservation`, and
  `reschedule_reservation`.

## Folder layout

```
example_reservation_agent/
  agent/
    Dockerfile
    requirements.txt
    src/
      agent.py            # conversation loop: LLM + tool-calling
      agent_executor.py   # A2A protocol wiring
      main.py             # entry point, agent card, uvicorn
      mcp_client.py        # calls the tool over MCP
  tool/
    Dockerfile
    requirements.txt
    src/
      store.py             # in-memory availability/reservation logic
      server.py             # MCP tool server (FastMCP)
  manifests/
    reservation-tool-mcp-gateway.yaml   # HTTPRoute + MCPServerRegistration
```

## Limitations (read before you demo this)

- **State is in memory only.** The tool pod restarting, rescheduling, or
  scaling to more than one replica loses or splits the reservation book.
  Fine for a demo; not something to point real customers at.
- **No timezone handling.** Dates and times are naive, business-hours
  checks use the tool pod's local clock (UTC in most clusters).
- **No double-booking protection across a race.** Two simultaneous
  bookings for the same slot are not locked against each other; the
  second one just fails the availability check if it loses the race, so
  this is fine for one interactive demo user.

## Prerequisites

- An OpenShift cluster with Rossoctl **v0.7.0** installed. If you don't
  have one yet, see
  [Deploy Rossoctl to OpenShift with IBAC](../docs/how-to-guides/deploy-rossoctl-to-openshift-with-ibac.md)
  in this repo, or the upstream `docs/ocp/openshift-install.md` in the
  [rossoctl/rossoctl](https://github.com/rossoctl/rossoctl) repo for a
  general install.
- `oc` logged in to that cluster, and a namespace to deploy into (the
  examples below use `team1`, matching this repo's other guides).
- A container registry both your workstation and the cluster can reach
  (Quay, GHCR, an internal registry, etc.), and `docker` or `podman` to
  build and push images.
- An LLM you can point the agent at - OpenAI, Anthropic, or an in-cluster
  Ollama all work. See
  [Point Rossoctl agents at a provider](../docs/how-to-guides/point-rossoctl-agents-at-a-provider.md)
  for the three environment variables every Rossoctl agent reads.

## 1. Build and push the images

```bash
export REGISTRY=quay.io/<your-username>   # or your own registry

docker build -t $REGISTRY/reservation-tool:v0.1.0 tool/
docker push $REGISTRY/reservation-tool:v0.1.0

docker build -t $REGISTRY/reservation-agent:v0.1.0 agent/
docker push $REGISTRY/reservation-agent:v0.1.0
```

`rossoctl` also supports building straight from a git repo (Tekton +
Shipwright, via `--with-builds`) instead of pushing pre-built images -
see the **Import** dialog's "Build From Source" option in the UI. It
needs `agent/` and `tool/` to each be a subfolder with its own
`Dockerfile`, which they already are.

## 2. Deploy the tool

In the Rossoctl UI: **Tools -> Import -> Deploy From Image**.

- Image: `$REGISTRY/reservation-tool:v0.1.0`
- Namespace: `team1` (or your own)
- Turn on AuthBridge sidecar injection and SPIRE identity if your
  install runs with `injectTools=true` (it must, for the gateway to
  reach the tool through AuthBridge - see the IBAC deploy guide's
  Step 7 for that flag)

Rossoctl's AuthBridge sidecar claims the tool's own container port for
its own health server, then moves your tool's listener up by one - this
tripped up the weather-tool example too. If the import gives your
container port `8000`, confirm it after the Deployment exists:

```bash
oc get pod -n team1 -l app.kubernetes.io/name=reservation-tool -o json | \
  jq '.items[0].spec.containers[] | {name, ports}'
```

If the tool container's actual listener ends up on a different port than
the Service targets (the weather-tool example needed `PORT=8000` on the
container with the Service's `targetPort` also patched to `8000`, while
AuthBridge's proxy took `8000` externally and pushed the tool itself to
`8001` internally), match that pattern:

```bash
oc set env deployment/reservation-tool -n team1 PORT=8000
oc patch service reservation-tool-mcp -n team1 --type=json -p='[
  {"op": "replace", "path": "/spec/ports/0/port", "value": 8000},
  {"op": "replace", "path": "/spec/ports/0/targetPort", "value": 8000}
]'
oc rollout status deployment/reservation-tool -n team1 --timeout=300s
```

Register the tool with MCP Gateway:

```bash
sed 's/NAMESPACE/team1/' manifests/reservation-tool-mcp-gateway.yaml | oc apply -f -
```

Check it came up:

```bash
oc get mcpserverregistration reservation-tool-servers -n team1 \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,TOOLS:.status.discoveredTools'
```

If `READY` is not `True`, the tool almost certainly needs a gateway
credential, the same way the weather-tool example does. Copy
`ocp-runner/scripts/configure-weather-tool-gateway-credential.sh`,
swap every `weather-tool` for `reservation-tool`, and run it - do not
turn off JWT validation to work around a `401` instead.

## 3. Deploy the agent

In the Rossoctl UI: **Agents -> Import -> Deploy From Image**.

- Image: `$REGISTRY/reservation-agent:v0.1.0`
- Namespace: `team1` (same namespace as the tool)

Set these environment variables (swap in whichever LLM section applies
to you from
[Point Rossoctl agents at a provider](../docs/how-to-guides/point-rossoctl-agents-at-a-provider.md)):

```
LLM_API_BASE=<your provider's OpenAI-compatible base URL>
LLM_MODEL=<model name>
LLM_API_KEY=<key, or "ollama" for a local model>
MCP_URL=http://mcp-gateway-istio.gateway-system.svc.cluster.local:8080/mcp
```

`MCP_URL` points at MCP Gateway, not at the tool directly - the gateway
is what applies the `reservation_` tool prefix from the registration and
enforces the AuthBridge/IBAC pipeline in front of the tool call.

Deploy, then wait for the pod:

```bash
oc rollout status deployment/reservation-agent -n team1 --timeout=300s
```

## 4. Try it

Open a chat with the agent in the Rossoctl UI and try something like:

> I'd like to book a reservation this week.

The agent should call `suggest_reservation_times` and come back with
three concrete options. Reply with one of them, or ask for other times;
once you agree on a slot it calls `book_reservation` and confirms the
date, time, and reservation id. From there:

> Can you move reservation `<id>` to Thursday at 2pm?

should call `check_availability` and then `reschedule_reservation`, and

> Cancel reservation `<id>`

should call `cancel_reservation`.

## Troubleshooting

- **Agent errors on startup mentioning `a2a`.** This example targets
  `a2a-sdk>=0.2.5`. If the installed version's `AgentExecutor` /
  `TaskUpdater` / `A2AStarletteApplication` API has moved since this was
  written, compare `agent/src/agent_executor.py` and `agent/src/main.py`
  against the upstream LangGraph `a2a-currency-agent` sample referenced
  in `docs/concepts/tech-details.md` of the
  [rossoctl/rossoctl](https://github.com/rossoctl/rossoctl) repo - it
  uses the same shape.
- **Agent can't reach the tool / every booking fails.** Check
  `MCP_URL` is set and that `oc get mcpserverregistration
  reservation-tool-servers -n team1` reports `READY=True` with at least
  one discovered tool, per Step 2 above.
- **`ImagePullBackOff` after import.** The UI's Import flow can rewrite
  your image tag - the weather-tool example hits this too. Confirm the
  Deployment's image with `oc get deployment reservation-tool -n team1
  -o jsonpath='{.spec.template.spec.containers[*].image}'` and `oc set
  image` it back if needed.
