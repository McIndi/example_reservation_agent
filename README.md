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
    reservation-tool.yaml                # SA + Deployment + Service + AgentRuntime
    reservation-agent.yaml               # same four objects for the agent
    reservation-tool-mcp-gateway.yaml    # HTTPRoute + MCPServerRegistration
    reservation-tool-token-refresher.yaml  # CronJob that keeps the gateway credential fresh
```

## How a tool call is secured

Every hop below is what runs on the demo cluster, checked against the
live pods and sidecar logs on 2026-09-03.

1. The Rossoctl UI sends the customer's message to the agent with the
   customer's Keycloak token. The agent pod's AuthBridge sidecar
   validates it (`inbound authorized`) and hands the request to the
   agent container.
2. The agent container has `HTTP_PROXY` and `HTTPS_PROXY` set to the
   sidecar's forward proxy, `127.0.0.1:8081`, and `NO_PROXY` covering
   loopback only. `mcp_client.py` builds its HTTP client with the
   default `trust_env=True`, so every call to MCP Gateway, and every
   call to Ollama, leaves through the sidecar.
3. The sidecar's outbound chain runs `token-exchange` (passthrough here:
   it forwards the customer's token), `mcp-parser` (tags `tools/call` as
   an action), then `ibac`. IBAC asks the judge model whether the action
   matches the intent the inbound `a2a-parser` recorded from the chat.
   A mismatch is a `403` with `code=ibac.blocked`; the agent's log shows
   it and the customer gets the "nothing has been booked or changed"
   reply. `unclassified_policy` is `judge` on this cluster, so a plain
   HTTP call from the agent would be judged too.
4. MCP Gateway routes the call to `reservation-tool-mcp:8000`, which is
   the tool pod's AuthBridge reverse proxy, not the tool. That sidecar
   validates the forwarded token again and passes the call to the tool
   on `8001`.

What this does not do: the agent's own SPIFFE identity is never put on
the call, and the tool accepts any valid Keycloak token for `rossoctl`.
Authorization at the tool is coarse. The intent check is the control
that decides.

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

Two paths work. The manifest path is the one that was run on the demo
cluster: that install has no Tekton or Shipwright, and the UI's Import
dialog rewrote the image tag on the weather-tool example, so the tool
went in with `oc apply`. The UI path is the platform's documented one.

### Manifest path (tested)

`manifests/reservation-tool.yaml` carries the ServiceAccount, Deployment,
Service, and the `AgentRuntime` CR that tells the Rossoctl operator to
inject the AuthBridge sidecar and SPIRE identity. It is the same object
set the UI's Import flow creates.

```bash
sed 's/NAMESPACE/team1/' manifests/reservation-tool.yaml | oc apply -f -
oc rollout status deployment/reservation-tool -n team1 --timeout=300s
```

### UI path

**Tools -> Import -> Deploy From Image**, image
`ghcr.io/mcindi/reservation-tool:latest`, namespace `team1`. Turn on
AuthBridge sidecar injection and SPIRE identity. The install must run
with `injectTools=true` for a tool to get its sidecar at all (see the
IBAC deploy guide's Step 7). If the Deployment comes up with a different
image tag than you typed, `oc set image` it back.

### Check the ports

Either way, the operator's webhook moves the tool's listener from `8000`
to `8001` and puts AuthBridge's reverse proxy on `8000`. The Service
keeps targeting `8000`, so every request to the tool passes through
AuthBridge first. Confirm it:

```bash
oc get pod -n team1 -l app.kubernetes.io/name=reservation-tool -o json | \
  jq '.items[0].spec.containers[] | {name, ports, PORT: [.env[]? | select(.name=="PORT") | .value]}'
```

The `mcp` container must show `containerPort: 8001` and `PORT=8001`. The
`authbridge-proxy` container must show `reverse-proxy` on `8000`. If the
import put the tool on `9090` instead, the moved listener lands on
`9091`, where the sidecar's health server already is, and the tool
crash-loops. Redeploy with port `8000`.

### Register with MCP Gateway

```bash
sed 's/NAMESPACE/team1/' manifests/reservation-tool-mcp-gateway.yaml | oc apply -f -
```

The registration is not ready yet. The tool's inbound AuthBridge rejects
MCP Gateway's discovery request with `401` because the gateway has no
credential for this tool. Do not turn off JWT validation. Create a
dedicated Keycloak client and credential Secret with the platform's
weather-tool script, pointed at this tool through its environment
variables. This is the exact invocation that was run on the demo
cluster; `/vagrant` is where the `ocp-runner` VM mounts this repo's
parent folder:

```bash
NS=team1 \
DEPLOYMENT=reservation-tool \
REGISTRATION=reservation-tool-servers \
DISCOVERY_CLIENT_ID=mcp-gateway-reservation-discovery \
DISCOVERY_SECRET=reservation-tool-gateway-credential \
CLIENT_SECRET_NAME=reservation-tool-discovery-client \
SETTINGS_CONFIGMAP=reservation-tool-token-refresher-settings \
MAPPER_NAME=reservation-tool-audience \
/vagrant/scripts/configure-weather-tool-gateway-credential.sh
```

The script reads the tool's SPIFFE id from its sidecar
(`spiffe://<trust-domain>/ns/team1/sa/reservation-tool`), creates the
Keycloak client with that audience, stores the client id and secret in
`reservation-tool-discovery-client`, mints the first token into
`reservation-tool-gateway-credential`, and patches `credentialRef` onto
the registration. It must print `Audience verified`. Then:

```bash
oc get mcpserverregistration reservation-tool-servers -n team1 \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,TOOLS:.status.discoveredTools'
```

must report `READY=True` and `7` tools.

### Keep the credential fresh

That token lives 3,600 seconds. Install the refresher, which mints a new
one every 30 minutes and may patch only that one Secret, and run it once
now instead of waiting for the schedule:

```bash
sed 's/NAMESPACE/team1/' manifests/reservation-tool-token-refresher.yaml | oc apply -f -
JOB="reservation-tool-token-refresh-test-$(date +%s)"
oc create job --from=cronjob/reservation-tool-token-refresher "${JOB}" -n team1
oc wait --for=condition=complete "job/${JOB}" -n team1 --timeout=180s
oc logs "job/${JOB}" -n team1
```

The log must end with `Credential refreshed; expires_in=3600`.

## 3. Deploy the agent

`manifests/reservation-agent.yaml` carries the ServiceAccount,
Deployment, Service, and `AgentRuntime` CR, with the environment below
already set for the in-cluster Ollama. Agents get the AuthBridge sidecar
whether or not `injectTools` is set; that flag only affects tools.

```bash
sed 's/NAMESPACE/team1/' manifests/reservation-agent.yaml | oc apply -f -
oc rollout status deployment/reservation-agent -n team1 --timeout=300s
```

The UI path is **Agents -> Import -> Deploy From Image**, image
`ghcr.io/mcindi/reservation-agent:latest`, namespace `team1`, with these
environment variables:

```
LLM_API_BASE=http://ollama.ollama.svc.cluster.local:11434/v1
LLM_MODEL=llama3.2:3b-instruct-q4_K_M
LLM_API_KEY=ollama
MCP_URL=http://mcp-gateway-istio.gateway-system.svc.cluster.local:8080/mcp
MCP_TOOL_PREFIX=reservation_
```

For OpenAI or Anthropic instead, use their usual OpenAI-compatible base
URL, model name, and a real API key in place of the first three lines
above.

`LLM_MODEL` is the same quantized model the IBAC judge uses. Ollama on
the demo cluster serves one request at a time, so running two resident
models would force a reload on every alternation between an agent turn
and a judge call.

`MCP_URL` points at MCP Gateway, not at the tool directly - the gateway
is what applies the `reservation_` tool prefix from the registration and
enforces the AuthBridge/IBAC pipeline in front of the tool call.

`MCP_TOOL_PREFIX` has to match that registration's `toolPrefix`. The
gateway republishes `check_availability` as
`reservation_check_availability`, so calling the short name through the
gateway asks for a tool it does not serve. Leave it unset when `MCP_URL`
points straight at the tool Service, where the names are unprefixed.

### Pin the images

`imagePullPolicy: Always` with `:latest` means any restart can pick up
whatever CI published last. The demo cluster pins both Deployments to a
digest after each verified build:

```bash
oc set image deployment/reservation-agent -n team1 agent=ghcr.io/mcindi/reservation-agent@sha256:<digest>
oc set image deployment/reservation-tool -n team1 mcp=ghcr.io/mcindi/reservation-tool@sha256:<digest>
```

Digests are on each package's page under
[github.com/orgs/McIndi/packages](https://github.com/orgs/McIndi/packages),
or in the `build-and-push` run's log.

### Confirm the routing

Before the first chat, check that the agent's outbound traffic is wired
through its sidecar:

```bash
oc exec -n team1 deploy/reservation-agent -c agent -- sh -c \
  'env | sort | grep -E "^(HTTP_PROXY|HTTPS_PROXY|NO_PROXY|MCP_URL|MCP_TOOL_PREFIX)="'
```

Expected: `HTTP_PROXY` and `HTTPS_PROXY` equal `http://127.0.0.1:8081`,
`NO_PROXY` is `127.0.0.1,localhost`, and the two `MCP_` values match
Step 3. The pod also has a `proxy-init` init container from the operator
that sets up the sidecar's transparent proxy on `8082`, so traffic that
ignores those variables still passes through the sidecar.

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
  reservation-tool-servers -n team1` reports `READY=True` with seven
  discovered tools, per Step 2 above. If the registration went back to
  `401`, the gateway credential expired: check the last
  `reservation-tool-token-refresher` Job's log.
- **The customer gets "I couldn't reach the scheduling system", and the
  agent log says `code=ibac.blocked`.** That is IBAC enforcement, not an
  outage. The judge decided the tool call contradicted the intent the
  customer stated earlier in the same conversation; the reason is on the
  same log line, in both the agent container's log and the sidecar's:

  ```bash
  oc logs deploy/reservation-agent -n team1 -c authbridge-proxy | grep -E 'tools/call|ibac'
  ```

  Seen once on the demo cluster: a customer said they did not want to
  cancel, the model called `cancel_reservation` anyway, and the sidecar
  returned `403`. The agent rolled the turn back so the model could not
  build on the failed call. Intent is tracked per conversation, so start
  a new one if the block was a false positive. An allowed call writes no
  `allow` line; it shows as `mcp-parser: request method=tools/call
  isAction=true` followed by a response.
- **`tools/call` never appears in the sidecar log.** The agent is
  bypassing its sidecar. Re-run the environment check at the end of
  Step 3; `HTTP_PROXY` must point at `127.0.0.1:8081`. A client built
  with `trust_env=False` would also bypass it.
- **`ImagePullBackOff` after import.** The UI's Import flow can rewrite
  your image tag - the weather-tool example hits this too. Confirm the
  Deployment's image with `oc get deployment reservation-tool -n team1
  -o jsonpath='{.spec.template.spec.containers[*].image}'` and `oc set
  image` it back if needed.
