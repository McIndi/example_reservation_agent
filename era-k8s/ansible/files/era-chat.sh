#!/bin/bash
# era-chat: talk to an A2A agent on this cluster from the node, as the platform's test user, with
# timing. Used to rehearse and to measure latency without the UI.
#   era-chat "I'd like to book a reservation this week."      # new conversation
#   era-chat --continue "Thursday at 2pm please"               # same conversation (contextId kept)
# Env: NS (team1), AGENT (reservation-agent), KC_CLIENT (rossoctl).
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NS="${NS:-team1}"; AGENT="${AGENT:-reservation-agent}"; KC_CLIENT="${KC_CLIENT:-era-chat}"    # a test client with an audience mapper for the agent (created below)
CTX_FILE=/tmp/era-chat.ctx
CONTINUE=0; [ "${1:-}" = "--continue" ] && { CONTINUE=1; shift; }
MSG="${1:?message}"

KC_IP=$(kubectl -n keycloak get svc keycloak-service -o jsonpath='{.spec.clusterIP}')
USER=$(kubectl -n keycloak get secret rossoctl-test-user -o jsonpath='{.data.username}' | base64 -d)
PASS=$(kubectl -n keycloak get secret rossoctl-test-user -o jsonpath='{.data.password}' | base64 -d)
AU=$(kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d)
AP=$(kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)
AT=$(curl -sSf -X POST "http://$KC_IP:8080/realms/master/protocol/openid-connect/token" -d grant_type=password -d client_id=admin-cli -d "username=$AU" --data-urlencode "password=$AP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
# The agent's sidecar requires aud = the agent's SPIFFE id (as the UI's exchanged tokens carry). A
# public test client with direct-access grants and an audience mapper for that id gives us the same.
TRUST_DOMAIN=$(. /etc/era-k8s/config.env; echo "$ERA_DOMAIN")
SA=$(kubectl -n "$NS" get deploy "$AGENT" -o jsonpath='{.spec.template.spec.serviceAccountName}')
AUD="spiffe://${TRUST_DOMAIN}/ns/${NS}/sa/${SA:-default}"
CID=$(curl -sSf -H "Authorization: Bearer $AT" "http://$KC_IP:8080/admin/realms/rossoctl/clients?clientId=$KC_CLIENT" | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r[0]["id"] if r else "")')
if [ -z "$CID" ]; then
  curl -sSf -H "Authorization: Bearer $AT" -H "Content-Type: application/json" -X POST "http://$KC_IP:8080/admin/realms/rossoctl/clients" -d @- <<JSON
{"clientId": "$KC_CLIENT", "name": "era-chat test harness", "enabled": true, "protocol": "openid-connect",
 "publicClient": true, "directAccessGrantsEnabled": true, "standardFlowEnabled": false,
 "protocolMappers": [{"name": "agent-audience", "protocol": "openid-connect", "protocolMapper": "oidc-audience-mapper",
   "config": {"included.custom.audience": "$AUD", "access.token.claim": "true", "id.token.claim": "false"}}]}
JSON
  CID=$(curl -sSf -H "Authorization: Bearer $AT" "http://$KC_IP:8080/admin/realms/rossoctl/clients?clientId=$KC_CLIENT" | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"])')
fi
CSECRET=$(curl -sS -H "Authorization: Bearer $AT" "http://$KC_IP:8080/admin/realms/rossoctl/clients/$CID/client-secret" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("value",""))
except Exception: print("")')
SECRET_ARG=(); [ -n "$CSECRET" ] && SECRET_ARG=(--data-urlencode "client_secret=$CSECRET")   # public client: no secret
TOKEN=$(curl -sSf -X POST "http://$KC_IP:8080/realms/rossoctl/protocol/openid-connect/token" -d grant_type=password -d "client_id=$KC_CLIENT" "${SECRET_ARG[@]}" -d "username=$USER" --data-urlencode "password=$PASS" -d scope=openid | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

SVC_IP=$(kubectl -n "$NS" get svc "$AGENT" -o jsonpath='{.spec.clusterIP}')
PORT=$(kubectl -n "$NS" get svc "$AGENT" -o jsonpath='{.spec.ports[0].port}')
if [ "$CONTINUE" = 1 ] && [ -f "$CTX_FILE" ]; then CTX=$(cat "$CTX_FILE"); else CTX=$(python3 -c 'import uuid; print(uuid.uuid4())'); fi
MID=$(python3 -c 'import uuid; print(uuid.uuid4())')
BODY=$(python3 - "$MSG" "$MID" "$CTX" <<'PY'
import sys, json
msg, mid, ctx = sys.argv[1:4]
print(json.dumps({"jsonrpc": "2.0", "id": mid, "method": "message/send",
  "params": {"message": {"role": "user", "kind": "message", "messageId": mid, "contextId": ctx,
                         "parts": [{"kind": "text", "text": msg}]}}}))
PY
)
START=$(date +%s.%N)
RESP=$(curl -sS -m 600 -X POST "http://$SVC_IP:$PORT/" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$BODY")
END=$(date +%s.%N)
echo "$CTX" > "$CTX_FILE"
python3 - "$RESP" "$START" "$END" <<'PY'
import sys, json
resp, start, end = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
try: r = json.loads(resp)
except Exception: print(resp[:800]); sys.exit(0)
if "error" in r: print("ERROR:", json.dumps(r["error"])[:600])
res = r.get("result", {})
texts = []
for a in res.get("artifacts", []) or []:
    for p in a.get("parts", []): texts.append(p.get("text", ""))
st = (res.get("status") or {}).get("message") or {}
for p in st.get("parts", []) or []: texts.append(p.get("text", ""))
print(f"[{end-start:6.1f}s] state={(res.get('status') or {}).get('state')} context={res.get('contextId','')[:8]}")
print("\n".join(t for t in texts if t) or json.dumps(res)[:800])
PY
