#!/bin/bash
# era-k8s provisioning, step 50: CRI-O: pause image, systemd cgroups, the in-cluster registry as insecure
# Shared by the Lima template (k8s.yaml is rendered from k8s.yaml.in + provision/*.sh by bin/render-template,
# which exports the template's param: values as ERA_* variables) and by the Packer builds (which export the
# same variables, or none: every variable below has the template's default). Runs as root on Fedora 44.
set -eux -o pipefail
[ -e /etc/crio/crio.conf.d/10-kubeadm.conf ] && exit 0
command -v kubeadm >/dev/null || { echo "kubeadm missing: package step failed" >&2; exit 1; }
mkdir -p /etc/crio/crio.conf.d
cat <<EOF >/etc/crio/crio.conf.d/10-kubeadm.conf
[crio.image]
pause_image = "$(kubeadm config images list | grep pause | sort -r | head -n1)"
[crio.runtime]
cgroup_manager = "systemd"
EOF
# The in-cluster registry (rossoctl-deps, namespace cr-system) speaks plain HTTP; CRI-O and podman
# share this registries.conf drop-in.
cat <<EOF >/etc/containers/registries.conf.d/era-k8s.conf
[[registry]]
location = "localhost:30500"
insecure = true
[[registry]]
location = "registry.cr-system.svc.cluster.local:5000"
insecure = true
EOF
systemctl restart crio
