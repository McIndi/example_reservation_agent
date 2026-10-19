#!/bin/bash
# era-k8s provisioning, step 20: /etc/era-k8s/config.env (recipient settings) and build.env (versions for k8s-init.sh)
# Shared by the Lima template (k8s.yaml is rendered from k8s.yaml.in + provision/*.sh by bin/render-template,
# which exports the template's param: values as ERA_* variables) and by the Packer builds (which export the
# same variables, or none: every variable below has the template's default). Runs as root on Fedora 44.
set -eux -o pipefail
: "${ERA_DOMAIN:=localtest.me}"
: "${ERA_LLM_PROVIDER:=in-cluster}"
: "${ERA_LLM_API_BASE:=http://ollama.ollama.svc.cluster.local:11434/v1}"
: "${ERA_LLM_MODEL:=llama3.2:3b-instruct-q4_K_M}"
: "${ERA_TLS:=true}"
: "${ERA_K8S_VERSION:=stable}"
: "${ERA_CALICO_VERSION:=v3.33.0}"
: "${ERA_LOCAL_PATH_VERSION:=v0.0.37}"
mkdir -p /etc/era-k8s
# Versions baked into this image, read by /usr/local/sbin/k8s-init.sh at first boot.
cat <<EOF >/etc/era-k8s/build.env
ERA_K8S_VERSION=${ERA_K8S_VERSION}
ERA_CALICO_VERSION=${ERA_CALICO_VERSION}
ERA_LOCAL_PATH_VERSION=${ERA_LOCAL_PATH_VERSION}
EOF
[ -f /etc/era-k8s/config.env ] && exit 0
cat <<EOF >/etc/era-k8s/config.env
# era-k8s settings. Read by /usr/local/sbin/k8s-init.sh and by the platform playbooks (Ansible).
# Hostnames of the platform: <service>.ERA_DOMAIN. localtest.me resolves to 127.0.0.1 (works on the Mac
# through Lima's port forwards); for LAN access use e.g. 10-15-10-120.sslip.io or a real domain.
ERA_DOMAIN=${ERA_DOMAIN}
# LLM for agents and the IBAC judge. in-cluster = the Ollama Deployment in namespace ollama.
# external = an OpenAI-compatible endpoint; its key comes from the secrets file, never from here.
ERA_LLM_PROVIDER=${ERA_LLM_PROVIDER}
ERA_LLM_API_BASE=${ERA_LLM_API_BASE}
ERA_LLM_MODEL=${ERA_LLM_MODEL}
# TLS for the platform's gateway: true = cert-manager with the local CA (ClusterIssuer era-ca),
# HTTPS listener on 443 -> NodePort 30443. Development clients may skip verification.
ERA_TLS=${ERA_TLS}
# Where locally built images go: in-cluster (rossoctl-deps registry, NodePort 30500) or ghcr.
ERA_REGISTRY=in-cluster
# Where \`era update\` refreshes /opt/era-k8s from: the era-k8s branch of the agent repo, folder era-k8s.
ERA_REPO=https://github.com/McIndi/example_reservation_agent.git
ERA_BRANCH=era-k8s
ERA_REPO_SUBDIR=era-k8s
EOF
chmod 0644 /etc/era-k8s/config.env
