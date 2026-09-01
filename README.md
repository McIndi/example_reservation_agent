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

- An OpenShift cluster with Rossoctl **v0.7.0** installed. See the
  upstream `docs/ocp/openshift-install.md` in the
  [rossoctl/rossoctl](https://github.com/rossoctl/rossoctl) repo if you
  don't have one yet.
- `oc` logged in to that cluster, and a namespace to deploy into (the
  examples below use `team1`).
- An LLM you can point the agent at - OpenAI, Anthropic, or an in-cluster
  Ollama all work. The agent reads three environment variables:
  `LLM_API_BASE`, `LLM_MODEL`, and `LLM_API_KEY` (any non-empty value
  for Ollama, which needs no real key).

## 1. Build and push the images

This repo's `.github/workflows/build-and-push.yml` builds both images on
every push to `main` and publishes them to GHCR:

- `ghcr.io/mcindi/reservation-agent:latest`
- `ghcr.io/mcindi/reservation-tool:latest`

(also tagged by short commit SHA, and by `vX.Y.Z` for any pushed `v*`
tag). No local `docker build` needed - once a run completes on the
[Actions tab](https://github.com/McIndi/example_reservation_agent/actions),
the images are ready to deploy from.

**First-run note:** GHCR packages a repo creates for the first time
often come out **private**, regardless of the source repo's own
visibility. Check
[github.com/orgs/McIndi/packages](https://github.com/orgs/McIndi/packages)
(or the "Packages" link on the repo page) after the first run and set
`reservation-agent` / `reservation-tool` to public, or link them to this
repo so it inherits the repo's access - otherwise the cluster's `oc`
image pulls in Step 2/3 below will fail with `ImagePullBackOff` /
`unauthorized`.

Prefer to build locally instead? `docker build -t <tag> tool/` and
`docker build -t <tag> agent/` work the same way any other
Dockerfile-based image does - push wherever your cluster can pull from.

`rossoctl` also supports building straight from a git repo in-cluster
(Tekton + Shipwright, via `--with-builds`) instead of a pre-built image -
see the **Import** dialog's "Build From Source" option in the UI. That
path needs the builds layer installed on the cluster first; the GHCR
route above works without it.

## 2. Deploy the tool

In the Rossoctl UI: **Tools -> Import -> Deploy From Image**.

- Image: `ghcr.io/mcindi/reservation-tool:latest` (or a specific commit
  SHA / `vX.Y.Z` tag from the Actions run, for something more pinned
  than `latest`)
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

- Image: `ghcr.io/mcindi/reservation-agent:latest`
- Namespace: `team1` (same namespace as the tool)

Set these environment variables. For an in-cluster Ollama (adjust the
service name/model to whatever is actually running on your cluster):

```
LLM_API_BASE=http://ollama.ollama.svc.cluster.local:11434/v1
LLM_MODEL=llama3.2:3b-instruct-fp16
LLM_API_KEY=ollama
MCP_URL=http://mcp-gateway-istio.gateway-system.svc.cluster.local:8080/mcp
```

For OpenAI or Anthropic instead, use their usual OpenAI-compatible base
URL, model name, and a real API key in place of the first three lines
above.

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

- **Agent errors on startup mentioning `a2a`** (e.g.
  `ModuleNotFoundError: No module named 'a2a.server.apps'`). Already hit
  once: `a2a-sdk` v1.0 removed `A2AStarletteApplication` (and its
  FastAPI/REST equivalents) in favor of composing route factories
  (`create_agent_card_routes`, `create_jsonrpc_routes`) directly into a
  plain Starlette app, and moved task/message construction onto helper
  functions in `a2a.helpers` (`new_task_from_user_message`,
  `new_text_message`, `new_text_part`, `get_message_text`) instead of
  building `Part`/`TextPart` objects by hand. `agent/requirements.txt`
  pins `a2a-sdk>=1.0.0` and `agent/src/agent_executor.py` /
  `agent/src/main.py` use that v1.0 shape now, verified against
  `a2aproject/a2a-samples/samples/python/agents/helloworld/`. If a
  future `a2a-sdk` release moves the API again, compare those two files
  against that same sample directory - it's the platform's own reference
  shape too (see `docs/concepts/tech-details.md` in the
  [rossoctl/rossoctl](https://github.com/rossoctl/rossoctl) repo).
- **Chat returns `Error: Method Not Found` (JSON-RPC `-32601`).** Already
  hit once: `a2a-sdk`'s JSON-RPC dispatcher has two method-name regimes -
  native mode only recognizes gRPC-style names (`SendMessage`,
  `GetTask`, ...), and the classic names Rossoctl's UI/backend actually
  sends (`message/send`, etc.) only work with
  `create_jsonrpc_routes(..., enable_v0_3_compat=True)`. `main.py` sets
  that flag; if it's missing, every chat message fails auth (AuthBridge
  logs show `inbound authorized`) but dies in the agent's own dispatcher
  before it reaches `ReservationAgentExecutor`.
- **`mcp` import errors** (`ModuleNotFoundError: No module named
  'mcp.server.fastmcp'`, or similar for `mcp.client.streamable_http`).
  Already hit once: `mcp` 2.0 renamed `FastMCP` to `MCPServer` (now
  `mcp.server.mcpserver.MCPServer`) and replaced the client's
  `streamablehttp_client` + `ClientSession` pair with a single `Client`
  that raises `MCPError` instead of returning `isError=True`. Both
  `tool/requirements.txt` and `agent/requirements.txt` pin
  `mcp>=2.0.0` and the code uses that v2 API - if a future `mcp` release
  moves the API again, check
  [py.sdk.modelcontextprotocol.io/migration](https://py.sdk.modelcontextprotocol.io/migration/)
  against `tool/src/server.py` and `agent/src/mcp_client.py`.
- **Agent can't reach the tool / every booking fails.** Check
  `MCP_URL` is set and that `oc get mcpserverregistration
  reservation-tool-servers -n team1` reports `READY=True` with at least
  one discovered tool, per Step 2 above.
- **`ImagePullBackOff` after import.** The UI's Import flow can rewrite
  your image tag - the weather-tool example hits this too. Confirm the
  Deployment's image with `oc get deployment reservation-tool -n team1
  -o jsonpath='{.spec.template.spec.containers[*].image}'` and `oc set
  image` it back if needed.
