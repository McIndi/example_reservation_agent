#!/bin/bash
# era-sleep-watch: the VM gets no "resumed" event when the Mac sleeps with the lid closed; it only sees
# its wall clock jump when Lima re-syncs time. Found 2026-10-18 (15 min lid-close test): everything looked
# healthy afterwards, but the MCP Gateway's one-hour Keycloak token for the tool had expired and the
# refresher CronJob had missed its slot, so every tool call got 401 until the next half-hour. This runs
# every minute from era-sleep-watch.timer, remembers the wall clock, and when it jumped by more than
# JUMP seconds since the last tick it runs every token-refresher CronJob once (idempotent, ~10 s) and
# re-runs the mesh recovery's Keycloak-dependent phase through era-mesh-recover if the gateway answers 401.
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
STATE=/run/era-sleep-watch.last
JUMP="${JUMP:-180}"
now=$(date +%s)
last=$(cat "$STATE" 2>/dev/null || echo "$now")
echo "$now" > "$STATE"
gap=$(( now - last - 60 ))
[ "$gap" -gt "$JUMP" ] || exit 0
log() { printf '%s era-sleep-watch: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
log "wall clock jumped by ${gap}s beyond the minute: the VM was suspended; refreshing gateway credentials"
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done
kubectl get cronjob -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' | grep -E 'token-refresher' | while read -r ns cj; do
  job="${cj}-wake-$(date +%s)"
  kubectl -n "$ns" create job --from="cronjob/$cj" "$job" >/dev/null && kubectl -n "$ns" wait --for=condition=complete "job/$job" --timeout=180s >/dev/null 2>&1 \
    && log "ran $ns/$cj once ($job)" || log "warning: $job did not complete"
done
# The gateway keeps using the credential it loaded (2026-10-18: pings still 401 after a refresh); restart it.
if kubectl -n mcp-system get deployment mcp-gateway >/dev/null 2>&1; then
  kubectl -n mcp-system rollout restart deployment/mcp-gateway >/dev/null && kubectl -n mcp-system rollout status deployment/mcp-gateway --timeout=180s >/dev/null 2>&1 && log "restarted mcp-system/mcp-gateway"
fi
log "done"
