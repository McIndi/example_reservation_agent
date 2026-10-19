#!/bin/bash
# Enable IBAC on an agent, the way the example_reservation_agent demo cluster and cortex's IBAC demo do it:
# merge a2a-parser (inbound, first) and mcp-parser + ibac (outbound, after token-exchange) into the
# namespace's AuthBridge template ConfigMap (authbridge-runtime-config), which the operator's webhook
# renders into each workload's authbridge-config-<name> at pod admission (patching the per-agent copy
# directly is overwritten at the next pod creation, found 2026-10-17), then restart the agent.
#   NS=team1 AGENT=reservation-agent JUDGE_ENDPOINT=http://ollama.ollama.svc.cluster.local:11434 \
#   JUDGE_MODEL=llama3.2:3b-instruct-q4_K_M enable-ibac.sh
# Idempotent. UNCLASSIFIED_POLICY defaults to "judge" (plain HTTP calls are judged too, as on the demo cluster).
set -euo pipefail
: "${NS:?}" "${AGENT:?}" "${JUDGE_ENDPOINT:?}" "${JUDGE_MODEL:?}"
UNCLASSIFIED_POLICY="${UNCLASSIFIED_POLICY:-judge}"; TIMEOUT_MS="${TIMEOUT_MS:-60000}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
CM="${TARGET_CM:-authbridge-runtime-config}"
LLM_HOST=$(echo "$JUDGE_ENDPOINT" | sed -E 's|^[a-z]+://||; s|[:/].*$||')
kubectl -n "$NS" get configmap "$CM" -o jsonpath='{.data.config\.yaml}' > /tmp/ab-config.yaml
python3 - "$JUDGE_ENDPOINT" "$JUDGE_MODEL" "$UNCLASSIFIED_POLICY" "$TIMEOUT_MS" "$LLM_HOST" <<'PY'
import sys, yaml
endpoint, model, policy, timeout, llm_host = sys.argv[1:6]
c = yaml.safe_load(open('/tmp/ab-config.yaml'))
p = c.setdefault('pipeline', {})
inbound = p.setdefault('inbound', {}).setdefault('plugins', [])
outbound = p.setdefault('outbound', {}).setdefault('plugins', [])
names_in = [x['name'] for x in inbound]; names_out = [x['name'] for x in outbound]
if 'a2a-parser' not in names_in:
    inbound.insert(0, {'name': 'a2a-parser'})
if 'mcp-parser' not in names_out:
    outbound.append({'name': 'mcp-parser'})
ibac = {'name': 'ibac', 'config': {
    'judge_endpoint': endpoint, 'judge_model': model, 'timeout_ms': int(timeout),
    'judge_inference': False, 'agent_llm_host': llm_host, 'unclassified_policy': policy}}
if 'ibac' in names_out:
    outbound[names_out.index('ibac')] = ibac
else:
    outbound.append(ibac)
yaml.safe_dump(c, open('/tmp/ab-config.yaml', 'w'), sort_keys=False)
PY
kubectl -n "$NS" create configmap "$CM" --from-file=config.yaml=/tmp/ab-config.yaml --dry-run=client -o yaml \
  | kubectl -n "$NS" patch configmap "$CM" --type=merge --patch-file /dev/stdin >/dev/null
rm -f /tmp/ab-config.yaml
kubectl -n "$NS" rollout restart "deployment/$AGENT" >/dev/null
kubectl -n "$NS" rollout status "deployment/$AGENT" --timeout=300s >/dev/null
echo "IBAC enabled via $NS/$CM for $AGENT: judge $JUDGE_MODEL at $JUDGE_ENDPOINT, unclassified_policy=$UNCLASSIFIED_POLICY"
kubectl -n "$NS" get configmap "authbridge-config-${AGENT}" -o jsonpath='{.data.config\.yaml}' | grep -E '^\s+- name:|name: ' | sed 's/^/   /'
