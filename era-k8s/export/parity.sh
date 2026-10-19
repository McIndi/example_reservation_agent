#!/bin/bash
# Read-only snapshot of the PRIMARY (OpenShift) demo cluster for parity with the era-k8s backup.
# Run inside the ocpclient-fedora44 VM, logged in with oc:  vagrant ssh -c "bash -s" < export/parity.sh
set -u
echo "== login"; oc whoami 2>&1 | head -1; oc whoami --show-server 2>&1 | head -1; oc version 2>/dev/null | /usr/bin/grep -E 'Client|Server|Kubernetes'
echo "== nodes"; oc get nodes --no-headers 2>/dev/null | wc -l
echo "== helm releases"; oc get secrets -A -l owner=helm -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATUS:.metadata.labels.status,VER:.metadata.labels.version 2>/dev/null | /usr/bin/grep -v superseded | head -30
echo "== platform images (deployments)"; oc get deploy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image 2>/dev/null | /usr/bin/grep -i -E 'rossoctl|kagenti|authbridge|cortex|operator|keycloak|spire|mcp|gateway|otel|ollama|istio|kuadrant|tekton|shipwright|cert-manager|registry' | head -40
echo "== team1"; oc get deploy,svc,agentruntime,mcpserverregistration,httproute,cronjob -n team1 2>&1 | head -30
echo "== team1 running image digests"; oc get pods -n team1 -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.containerStatuses[*]}{"   "}{.name}{"  "}{.imageID}{"\n"}{end}{end}' 2>/dev/null | head -20
echo "== agent env"; oc get deploy reservation-agent -n team1 -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null | /usr/bin/grep -E '^(LLM_|MCP_|KEYCLOAK|OTEL)' 
echo "== authbridge policy (unclassified_policy)"; oc get cm -A -o yaml 2>/dev/null | /usr/bin/grep -n -m4 -E 'unclassified_policy|judge_model|judge' 
echo "== ollama"; oc get deploy -n ollama -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image 2>&1 | head -3; oc exec -n ollama deploy/ollama -- ollama list 2>&1 | head -5
echo "== routes (hostnames/tls)"; oc get route -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOST:.spec.host,TLS:.spec.tls.termination 2>/dev/null | /usr/bin/grep -i -E 'rossoctl|keycloak|mcp|spire' | head -12
