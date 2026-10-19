#!/bin/bash
# SIEMatic's Keycloak side, as Cliff's microshift-runner siematic role does it, through the admin API
# on the in-cluster Keycloak Service: the confidential browser client "siematic" (standard flow,
# redirect to the SIEMatic callback, secret = OIDC_RP_CLIENT_SECRET from Vault), the service-account
# client "siematic-events" (secret = KEYCLOAK_CLIENT_SECRET from Vault) with realm-management
# view-events so it can read /admin/realms/<realm>/events, the realm roles "siematic" and
# "rossoctl-admin" (OIDC_GROUP_MAP maps both to Django's Registered User), and the "siematic" role on
# the demo login user. Idempotent; an existing client is updated so Keycloak and Vault agree.
#   KC_NS=keycloak KC_SVC=keycloak-service KC_REALM=rossoctl SIEMATIC_PUBLIC=https://siematic.localtest.me:8443 \
#   OIDC_SECRET=... EVENTS_SECRET=... DEMO_USER=admin keycloak-clients.sh
set -euo pipefail
: "${KC_REALM:?}" "${SIEMATIC_PUBLIC:?}" "${OIDC_SECRET:?}" "${EVENTS_SECRET:?}" "${DEMO_USER:?}"
KC_NS="${KC_NS:-keycloak}"; KC_SVC="${KC_SVC:-keycloak-service}"; KC_ADMIN_SECRET="${KC_ADMIN_SECRET:-keycloak-initial-admin}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
log() { printf '>>> %s\n' "$*"; }

KC_IP=$(kubectl -n "$KC_NS" get svc "$KC_SVC" -o jsonpath='{.spec.clusterIP}')
KC="http://${KC_IP}:8080"
ADMIN_USER=$(kubectl -n "$KC_NS" get secret "$KC_ADMIN_SECRET" -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(kubectl -n "$KC_NS" get secret "$KC_ADMIN_SECRET" -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -sSf -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d "username=$ADMIN_USER" --data-urlencode "password=$ADMIN_PASS" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
auth=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")
api="$KC/admin/realms/$KC_REALM"
jget() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

# 1. the browser client
client_uuid() { curl -sSf "${auth[@]}" "$api/clients?clientId=$1" | jget 'd[0]["id"] if d else ""'; }
BROWSER=$(python3 - "$OIDC_SECRET" "$SIEMATIC_PUBLIC" <<'PY'
import json, sys
secret, public = sys.argv[1:3]
print(json.dumps({"clientId": "siematic", "enabled": True, "protocol": "openid-connect", "publicClient": False,
  "secret": secret, "standardFlowEnabled": True, "directAccessGrantsEnabled": False, "serviceAccountsEnabled": False,
  "redirectUris": [public + "/oidc/callback/"], "webOrigins": ["+"],
  "attributes": {"post.logout.redirect.uris": public + "/*"}}))
PY
)
ID=$(client_uuid siematic)
if [ -z "$ID" ]; then
  curl -sSf -o /dev/null "${auth[@]}" -X POST "$api/clients" -d "$BROWSER"; ID=$(client_uuid siematic); log "client siematic created"
else
  curl -sSf -o /dev/null "${auth[@]}" -X PUT "$api/clients/$ID" -d "$(printf '%s' "$BROWSER" | python3 -c "import sys,json; d=json.load(sys.stdin); d['id']='$ID'; print(json.dumps(d))")"; log "client siematic updated"
fi

# 2. the events client (service account) and its view-events role
EVENTS=$(python3 - "$EVENTS_SECRET" <<'PY'
import json, sys
print(json.dumps({"clientId": "siematic-events", "enabled": True, "protocol": "openid-connect", "publicClient": False,
  "secret": sys.argv[1], "standardFlowEnabled": False, "directAccessGrantsEnabled": False, "serviceAccountsEnabled": True}))
PY
)
EID=$(client_uuid siematic-events)
if [ -z "$EID" ]; then
  curl -sSf -o /dev/null "${auth[@]}" -X POST "$api/clients" -d "$EVENTS"; EID=$(client_uuid siematic-events); log "client siematic-events created"
else
  curl -sSf -o /dev/null "${auth[@]}" -X PUT "$api/clients/$EID" -d "$(printf '%s' "$EVENTS" | python3 -c "import sys,json; d=json.load(sys.stdin); d['id']='$EID'; print(json.dumps(d))")"; log "client siematic-events updated"
fi
SA_USER=$(curl -sSf "${auth[@]}" "$api/clients/$EID/service-account-user" | jget 'd["id"]')
RM=$(client_uuid realm-management)
# view-realm as well: the shipper first reads /admin/realms/<realm> to check eventsEnabled, and with
# view-events alone Keycloak returns a partial representation without that field (found 2026-10-18).
for r in view-events view-realm; do
  ROLE=$(curl -sSf "${auth[@]}" "$api/clients/$RM/roles/$r")
  curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" -X POST "$api/users/$SA_USER/role-mappings/clients/$RM" -d "[$ROLE]" | grep -qE '^(204|409)$'
done
log "siematic-events service account has realm-management view-events and view-realm"

# 3. realm roles, and the demo user gets "siematic"
for role in siematic rossoctl-admin; do
  curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" -X POST "$api/roles" -d "{\"name\":\"$role\"}" | grep -qE '^(201|409)$'
done
UID_=$(curl -sSf "${auth[@]}" "$api/users?username=$DEMO_USER&exact=true" | jget 'd[0]["id"] if d else ""')
[ -n "$UID_" ] || { echo "user $DEMO_USER not found in realm $KC_REALM" >&2; exit 1; }
SROLE=$(curl -sSf "${auth[@]}" "$api/roles/siematic")
curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" -X POST "$api/users/$UID_/role-mappings/realm" -d "[$SROLE]" | grep -qE '^(204|409)$'
log "realm roles siematic and rossoctl-admin exist; user $DEMO_USER has siematic"

# 4. realm event storage (off by default; the primary's deploy guide turns it on in Step 7). Without it
#    /admin/realms/<realm>/events is empty and SIEMatic's keycloak index stays dark.
CFG=$(curl -sSf "${auth[@]}" "$api/events/config")
if printf '%s' "$CFG" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("eventsEnabled") and d.get("adminEventsEnabled") and d.get("adminEventsDetailsEnabled") else 1)'; then
  log "realm event storage already on"
else
  printf '%s' "$CFG" | python3 -c 'import sys,json; d=json.load(sys.stdin); d.update(eventsEnabled=True, adminEventsEnabled=True, adminEventsDetailsEnabled=True); print(json.dumps(d))' \
    | curl -sSf -o /dev/null "${auth[@]}" -X PUT "$api/events/config" --data-binary @-
  log "realm event storage turned on (login, token and admin events are now stored)"
fi
echo "SIEMatic login: $SIEMATIC_PUBLIC as $DEMO_USER (Keycloak realm $KC_REALM)"
