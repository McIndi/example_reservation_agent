#!/bin/bash
# era-k8s provisioning, step 40: firewalld: API server, kubelet, NodePorts, 8080/8443 forwards, Calico, pod and service networks
# Shared by the Lima template (k8s.yaml is rendered from k8s.yaml.in + provision/*.sh by bin/render-template,
# which exports the template's param: values as ERA_* variables) and by the Packer builds (which export the
# same variables, or none: every variable below has the template's default). Runs as root on Fedora 44.
set -eux -o pipefail
systemctl enable --now firewalld
# API server, kubelet, NodePorts
firewall-cmd --permanent --add-port=6443/tcp --add-port=10250/tcp --add-port=30000-32767/tcp
# rossoctl URL ports -> the gateway NodePorts (for VMs reached by their own address)
firewall-cmd --permanent --add-port=8080/tcp --add-port=8443/tcp
firewall-cmd --permanent --add-forward-port=port=8080:proto=tcp:toport=30080
firewall-cmd --permanent --add-forward-port=port=8443:proto=tcp:toport=30443
# Calico: BGP, VXLAN, Typha (only matter if a second node ever joins; harmless on one)
firewall-cmd --permanent --add-port=179/tcp --add-port=4789/udp --add-port=5473/tcp
# pod and service networks are ours
firewall-cmd --permanent --zone=trusted --add-source=10.244.0.0/16
firewall-cmd --permanent --zone=trusted --add-source=10.96.0.0/12
firewall-cmd --reload
