#!/bin/bash
# era-mesh-recover: after a VM restart, pods whose network namespaces were created before Istio's CNI
# node agent was ready are not enrolled in the ambient mesh, and the gateway answers 503 "upstream
# connect error ... delayed connect error: Invalid argument" for them (seen 2026-10-17 after the first
# platform restart). Restarting those workloads once the mesh is up fixes it. This runs at boot from
# era-mesh-recover.service and by hand as `era mesh-recover`. Idempotent and safe to repeat.
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
log() { printf '%s era-mesh-recover: %s\n' "$(date +%H:%M:%S)" "$*"; }

until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done
kubectl wait node --all --for=condition=Ready --timeout=600s >/dev/null
if ! kubectl get ns istio-system >/dev/null 2>&1; then log "no mesh installed; nothing to do"; exit 0; fi
log "waiting for the ambient data plane (istio-cni-node, ztunnel, istiod)"
kubectl -n istio-system rollout status ds/istio-cni-node --timeout=600s >/dev/null
kubectl -n istio-system rollout status ds/ztunnel --timeout=600s >/dev/null
kubectl -n istio-system rollout status deploy/istiod --timeout=600s >/dev/null
# Which pods predate the mesh is hard to tell reliably (container start vs. agent readiness races;
# the third cold start on 2026-10-17 still left the UI and Phoenix unreachable), so after a boot
# every workload in an ambient namespace is restarted, except the gateway pods, which are outside the
# mesh (dataplane-mode none). Costs about a minute; the demo needs certainty more than that minute.
for ns in $(kubectl get ns -l istio.io/dataplane-mode=ambient -o jsonpath='{.items[*].metadata.name}'); do
  for kind in deployment statefulset; do
    for name in $(kubectl -n "$ns" get "$kind" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      if kubectl -n "$ns" get "$kind" "$name" -o jsonpath='{.spec.template.metadata.labels.istio\.io/dataplane-mode}' | grep -q '^none$'; then continue; fi
      # workloads with an AuthBridge sidecar are restarted in phase 2 (after Keycloak); skip them here
      if kubectl -n "$ns" get "$kind" "$name" -o jsonpath='{.spec.template.spec.containers[*].name}' | grep -qw authbridge-proxy; then continue; fi
      log "restarting $ns/$kind/$name (ambient namespace, after boot)"
      kubectl -n "$ns" rollout restart "$kind/$name" >/dev/null
    done
  done
done
for ns in $(kubectl get ns -l istio.io/dataplane-mode=ambient -o jsonpath='{.items[*].metadata.name}'); do
  kubectl -n "$ns" rollout status deployment --timeout=600s >/dev/null 2>&1 || true
done

# Phase 2: AuthBridge sidecars fetch Keycloak's signing keys at startup; if Keycloak is not up yet
# they cache the failure and answer 401 to everything (seen 2026-10-17: gateway registration
# NotReady "unauthorized (401)" after a restart). Wait for Keycloak, then restart every workload
# that carries the sidecar and whose containers started before Keycloak was ready.
if kubectl -n keycloak get statefulset keycloak >/dev/null 2>&1; then
  log "waiting for Keycloak"
  kubectl -n keycloak rollout status statefulset/keycloak --timeout=900s >/dev/null || true
  kubectl get pods -A -o json | python3 -c "
import sys, json
seen = set()
for p in json.load(sys.stdin)['items']:
    if not any(c['name'] == 'authbridge-proxy' for c in p['spec'].get('containers', [])): continue
    owner = (p['metadata'].get('ownerReferences') or [{}])[0]
    kind, name = owner.get('kind', ''), owner.get('name', '')
    if kind == 'ReplicaSet': kind, name = 'deployment', name.rsplit('-', 1)[0]
    elif kind == 'StatefulSet': kind = 'statefulset'
    else: continue
    key = (p['metadata']['namespace'], kind, name)
    if key in seen: continue
    seen.add(key); print(*key)
" | while read -r ns kind name; do
    log "restarting $ns/$kind/$name (AuthBridge sidecar, after Keycloak is ready)"
    kubectl -n "$ns" rollout restart "$kind/$name" >/dev/null
    kubectl -n "$ns" rollout status "$kind/$name" --timeout=600s >/dev/null 2>&1 || true
  done
  # The MCP Gateway credential for each tool is a Keycloak token that the refresher CronJob renews
  # every 30 minutes; after a stop/start it may be expired or the scheduled run may have failed while
  # Keycloak was down. Run every refresher once now.
  kubectl get cronjob -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' | grep -E 'token-refresher' | while read -r ns cj; do
    job="${cj}-boot-$(date +%s)"
    log "running $ns/$cj once ($job)"
    kubectl -n "$ns" create job --from="cronjob/$cj" "$job" >/dev/null && kubectl -n "$ns" wait --for=condition=complete "job/$job" --timeout=180s >/dev/null 2>&1 || log "warning: $job did not complete"
  done
  # The gateway keeps the credential it loaded at start; after the refreshers, restart it so the new
  # token is the one it presents (found 2026-10-18 after a lid-close sleep: pings 401 until restarted).
  if kubectl -n mcp-system get deployment mcp-gateway >/dev/null 2>&1; then
    log "restarting mcp-system/deployment/mcp-gateway (reloads the refreshed credentials)"
    kubectl -n mcp-system rollout restart deployment/mcp-gateway >/dev/null && kubectl -n mcp-system rollout status deployment/mcp-gateway --timeout=300s >/dev/null 2>&1 || true
  fi
fi
# SIEMatic's shippers (outside the mesh) stall for good if they start before the indexer answers their
# first checkpoint fetch (2026-10-18); after a boot, restart them once everything else is up. They
# resume from their checkpoints, so nothing is lost.
if kubectl get ns siematic >/dev/null 2>&1; then
  kubectl -n siematic rollout status deployment/siematic-indexer --timeout=600s >/dev/null 2>&1 || true
  for d in siematic-kube-logs siematic-keycloak-events; do
    log "restarting siematic/deployment/$d (shipper, after the indexer is up)"
    kubectl -n siematic rollout restart "deployment/$d" >/dev/null 2>&1 || true
  done
fi
log "done"
