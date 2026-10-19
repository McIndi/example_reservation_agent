#!/bin/bash
# Non-OpenShift reconstruction of the platform's weather-tool gateway-credential script, as the
# example_reservation_agent README invokes it (Step 2, "Register with MCP Gateway"):
#
#   NS=team1 DEPLOYMENT=reservation-tool REGISTRATION=reservation-tool-servers \
#   DISCOVERY_CLIENT_ID=mcp-gateway-reservation-discovery DISCOVERY_SECRET=reservation-tool-gateway-credential \
#   CLIENT_SECRET_NAME=reservation-tool-discovery-client SETTINGS_CONFIGMAP=reservation-tool-token-refresher-settings \
#   MAPPER_NAME=reservation-tool-audience  configure-gateway-credential.sh
#
# What it does: works out the tool's SPIFFE id, creates a confidential Keycloak client (client
# credentials) with an audience mapper for that id, stores client id/secret in CLIENT_SECRET_NAME,
# writes the refresher's settings ConfigMap, mints the first token into DISCOVERY_SECRET (key
# "token", value "Bearer ...", labelled mcp.kuadrant.io/credential=true) and patches credentialRef
# onto the MCPServerRegistration. Prints "Audience verified". Idempotent. Runs on the cluster node
# as root (kubectl via admin.conf; Keycloak reached by its ClusterIP from the node).
set -euo pipefail
: "${NS:?}" "${DEPLOYMENT:?}" "${REGISTRATION:?}" "${DISCOVERY_CLIENT_ID:?}" "${DISCOVERY_SECRET:?}"
: "${CLIENT_SECRET_NAME:?}" "${SETTINGS_CONFIGMAP:?}" "${MAPPER_NAME:?}"
KC_NS="${KC_NS:-keycloak}"; KC_SVC="${KC_SVC:-keycloak-service}"; KC_REALM="${KC_REALM:-rossoctl}"
KC_ADMIN_SECRET="${KC_ADMIN_SECRET:-keycloak-initial-admin}"
KC_INCLUSTER_URL="${KC_INCLUSTER_URL:-http://${KC_SVC}.${KC_NS}.svc.cluster.local:8080}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

log() { printf '>>> %s\n' "$*"; }

# 1. The tool's SPIFFE id: trust domain from SPIRE, service account from the Deployment.
TRUST_DOMAIN=$(kubectl -n zero-trust-workload-identity-manager get cm spire-server -o jsonpath='{.data.server\.conf}' 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["server"]["trust_domain"])' 2>/dev/null || true)
[ -n "$TRUST_DOMAIN" ] || TRUST_DOMAIN=$(. /etc/era-k8s/config.env; echo "$ERA_DOMAIN")
SA=$(kubectl -n "$NS" get deploy "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.serviceAccountName}')
SPIFFE_ID="spiffe://${TRUST_DOMAIN}/ns/${NS}/sa/${SA:-default}"
log "tool identity: $SPIFFE_ID"

# 2. Keycloak admin token (admin-cli, master realm), through the service's ClusterIP.
KC_IP=$(kubectl -n "$KC_NS" get svc "$KC_SVC" -o jsonpath='{.spec.clusterIP}')
KC="http://${KC_IP}:8080"
ADMIN_USER=$(kubectl -n "$KC_NS" get secret "$KC_ADMIN_SECRET" -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(kubectl -n "$KC_NS" get secret "$KC_ADMIN_SECRET" -o jsonpath='{.data.password}' | base64 -d)
ADMIN_TOKEN=$(curl -sSf -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d "username=$ADMIN_USER" --data-urlencode "password=$ADMIN_PASS" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
auth=(-H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json")

# 3. The discovery client with its audience mapper (create once, keep thereafter).
CID=$(curl -sSf "${auth[@]}" "$KC/admin/realms/$KC_REALM/clients?clientId=$DISCOVERY_CLIENT_ID" | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r[0]["id"] if r else "")')
if [ -z "$CID" ]; then
  log "creating Keycloak client $DISCOVERY_CLIENT_ID in realm $KC_REALM"
  curl -sSf "${auth[@]}" -X POST "$KC/admin/realms/$KC_REALM/clients" -d @- <<JSON
{"clientId": "$DISCOVERY_CLIENT_ID", "name": "MCP Gateway discovery for $DEPLOYMENT", "enabled": true,
 "protocol": "openid-connect", "publicClient": false, "serviceAccountsEnabled": true,
 "attributes": {"access.token.lifespan": "3600"},
 "standardFlowEnabled": false, "directAccessGrantsEnabled": false,
 "protocolMappers": [{"name": "$MAPPER_NAME", "protocol": "openid-connect", "protocolMapper": "oidc-audience-mapper",
   "config": {"included.custom.audience": "$SPIFFE_ID", "access.token.claim": "true", "id.token.claim": "false", "introspection.token.claim": "true"}}]}
JSON
  CID=$(curl -sSf "${auth[@]}" "$KC/admin/realms/$KC_REALM/clients?clientId=$DISCOVERY_CLIENT_ID" | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"])')
else
  log "Keycloak client $DISCOVERY_CLIENT_ID exists"
fi
CLIENT_SECRET=$(curl -sSf "${auth[@]}" "$KC/admin/realms/$KC_REALM/clients/$CID/client-secret" | python3 -c 'import sys,json; print(json.load(sys.stdin)["value"])')

# 4. Mint a token and verify the audience before storing anything.
TOKEN_URL_INCLUSTER="$KC_INCLUSTER_URL/realms/$KC_REALM/protocol/openid-connect/token"
TOKEN_JSON=$(curl -sSf -X POST "$KC/realms/$KC_REALM/protocol/openid-connect/token" \
  -d grant_type=client_credentials -d "client_id=$DISCOVERY_CLIENT_ID" --data-urlencode "client_secret=$CLIENT_SECRET")
ACCESS_TOKEN=$(echo "$TOKEN_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
EXPIRES=$(echo "$TOKEN_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("expires_in"))')
echo "$ACCESS_TOKEN" | python3 -c "
import sys, json, base64
seg = sys.stdin.read().strip().split('.')[1]; seg += '=' * (-len(seg) % 4)
aud = json.loads(base64.urlsafe_b64decode(seg)).get('aud', [])
aud = [aud] if isinstance(aud, str) else aud
assert '$SPIFFE_ID' in aud, f'audience {aud!r} lacks $SPIFFE_ID'
print('Audience verified')"

# 5. Kubernetes objects the README and the refresher expect.
kubectl -n "$NS" create secret generic "$CLIENT_SECRET_NAME" --from-literal=client-id="$DISCOVERY_CLIENT_ID" --from-literal=client-secret="$CLIENT_SECRET" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create configmap "$SETTINGS_CONFIGMAP" --from-literal=token-url="$TOKEN_URL_INCLUSTER" --from-literal=expected-audience="$SPIFFE_ID" --from-literal=target-secret="$DISCOVERY_SECRET" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic "$DISCOVERY_SECRET" --from-literal=token="Bearer $ACCESS_TOKEN" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" label secret "$DISCOVERY_SECRET" mcp.kuadrant.io/credential=true mcp.kuadrant.io/secret=true --overwrite >/dev/null   # 0.6.0 wants secret=true; older docs say credential=true
kubectl -n "$NS" patch mcpserverregistration "$REGISTRATION" --type=merge -p "{\"spec\":{\"credentialRef\":{\"name\":\"$DISCOVERY_SECRET\",\"key\":\"token\"}}}" >/dev/null
log "credential stored in $NS/$DISCOVERY_SECRET (expires_in=$EXPIRES); credentialRef set on $REGISTRATION"
