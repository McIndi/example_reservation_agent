#!/bin/bash
# era-k8s provisioning, step 60: k8s-init.sh + k8s-init.service; initialize now (ERA_KUBEADM_INIT=true) or pre-pull and leave it to the first boot
# Shared by the Lima template (k8s.yaml is rendered from k8s.yaml.in + provision/*.sh by bin/render-template,
# which exports the template's param: values as ERA_* variables) and by the Packer builds (which export the
# same variables, or none: every variable below has the template's default). Runs as root on Fedora 44.
set -eux -o pipefail
: "${ERA_KUBEADM_INIT:=true}"
: "${ERA_K8S_VERSION:=stable}"
: "${ERA_CALICO_VERSION:=v3.33.0}"
: "${ERA_LOCAL_PATH_VERSION:=v0.0.37}"
cat <<'INIT' >/usr/local/sbin/k8s-init.sh
#!/bin/bash
# Single-node kubeadm + CRI-O + Calico + local-path storage. Resumable: each phase checks its own
# result and is skipped when already done, so a failed run is simply run again.
set -eux -o pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
# versions baked in at provisioning (provision/20-config.sh); the defaults match the template's
[ -f /etc/era-k8s/build.env ] && . /etc/era-k8s/build.env
VERSION="${ERA_K8S_VERSION:-stable}"
CALICO="${ERA_CALICO_VERSION:-v3.33.0}"
LPV="${ERA_LOCAL_PATH_VERSION:-v0.0.37}"
CRI=unix:///var/run/crio/crio.sock
[ -f /etc/era-k8s/config.env ] && . /etc/era-k8s/config.env && echo "era-k8s config: domain=${ERA_DOMAIN:-} llm=${ERA_LLM_PROVIDER:-} tls=${ERA_TLS:-}"

# Addresses. Under Lima the bridged interface is lima0 and may still be waiting for DHCP; elsewhere
# the default-route interface is the one that matters. Every global IPv4 goes into the certificate.
LAN_IF=lima0
ip link show lima0 >/dev/null 2>&1 || LAN_IF=$(ip -4 route show default | awk '{print $5; exit}')
LAN_IP=""
for i in $(seq 1 45); do
  LAN_IP=$(ip -4 -o addr show "$LAN_IF" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  [ -n "$LAN_IP" ] && break
  sleep 2
done
IPS=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
echo "interface ${LAN_IF}: ${LAN_IP:-none}; certificate SANs: ${IPS}"

# Phase 1: kubeadm init (skipped when the cluster exists)
if [ ! -e /etc/kubernetes/admin.conf ]; then
  swapoff -a || true
  # Pin the node name to the hostname of this moment: the kubelet re-derives its name from the hostname at
  # every start, and Vagrant or cloud-init may rename the host after this init (found on the first VMware
  # box, 2026-10-18: "node era-k8s not found" after a reboot of a node registered as "fedora").
  NODE=$(hostname)
  echo "KUBELET_EXTRA_ARGS=--hostname-override=${NODE}" >/etc/sysconfig/kubelet
  kubeadm config images list --kubernetes-version="${VERSION}"
  kubeadm config images pull --kubernetes-version="${VERSION}" --cri-socket="${CRI}"
  {
    cat <<EOF
kind: InitConfiguration
apiVersion: kubeadm.k8s.io/v1beta4
nodeRegistration:
  criSocket: ${CRI}
  name: ${NODE}
---
kind: ClusterConfiguration
apiVersion: kubeadm.k8s.io/v1beta4
kubernetesVersion: "${VERSION}"
apiServer:
  certSANs:
  - "127.0.0.1"
  - "$(hostname)"
EOF
    for ip in ${IPS}; do echo "  - \"${ip}\""; done
    cat <<EOF
networking:
  podSubnet: "10.244.0.0/16"
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd
EOF
  } >/etc/kubeadm-config.yaml
  kubeadm init --config /etc/kubeadm-config.yaml
fi
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 3; done

# Phase 2: Calico via the Tigera operator. The operator manifest creates the operator; the
# operator then installs its own CRDs, so poll for the CRD before waiting on it.
if ! kubectl get installation default >/dev/null 2>&1; then
  kubectl get deploy tigera-operator -n tigera-operator >/dev/null 2>&1 || \
    kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO}/manifests/tigera-operator.yaml"
  for i in $(seq 1 120); do kubectl get crd installations.operator.tigera.io >/dev/null 2>&1 && break; sleep 3; done
  # Between the CRD's creation and its first status update `kubectl wait` errors out instead of waiting
  # (".status.conditions accessor error: <nil>"); seen on a slow machine (QEMU without KVM, 2026-10-18). Retry.
  for i in $(seq 1 60); do
    kubectl wait --for=condition=established --timeout=180s crd/installations.operator.tigera.io 2>/dev/null && break
    sleep 3
  done
  kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=300s
  cat <<EOF >/etc/calico-installation.yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    nodeAddressAutodetectionV4:
      canReach: "1.1.1.1"
    ipPools:
    - name: default-ipv4-ippool
      blockSize: 26
      cidr: 10.244.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
  kubectl apply -f /etc/calico-installation.yaml
fi
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

# Phase 3: default StorageClass (rossoctl's charts create PersistentVolumeClaims).
# SELinux enforcing: the provisioner's helper pod writes to this hostPath, so it must carry the
# container file label (first build: "mkdir: Permission denied" without it).
mkdir -p /opt/local-path-provisioner
semanage fcontext -a -t container_file_t '/opt/local-path-provisioner(/.*)?' 2>/dev/null || true
restorecon -R /opt/local-path-provisioner
if ! kubectl get storageclass local-path >/dev/null 2>&1; then
  kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LPV}/deploy/local-path-storage.yaml"
fi
kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite

# Phase 4: kubeconfigs: root; a 127.0.0.1 variant (Lima's port forward); a LAN variant; every human user.
mkdir -p /root/.kube && ln -sf "$KUBECONFIG" /root/.kube/config
sed -e "/server:/ s|https://.*:\([0-9]*\)$|https://127.0.0.1:\1|" "$KUBECONFIG" >/root/.kube/config.localhost
if [ -n "$LAN_IP" ]; then
  sed -e "/server:/ s|https://.*:\([0-9]*\)$|https://${LAN_IP}:\1|" "$KUBECONFIG" >/root/.kube/config.lan
fi
# every human account (home under /home; Lima's user is uid 501 with home /home/<user>.guest)
getent passwd | awk -F: '$6 ~ /^\/home\// {print $1, $6}' | while read -r u h; do
  mkdir -p "$h/.kube" && cp -f "$KUBECONFIG" "$h/.kube/config" && chown -R "$u" "$h/.kube"
done
echo "k8s-init: done"
INIT
chmod 0755 /usr/local/sbin/k8s-init.sh

cat <<'EOF' >/etc/systemd/system/k8s-init.service
[Unit]
Description=Initialize the single-node Kubernetes cluster on first boot (k8s-init.sh)
After=network-online.target cloud-final.service crio.service kubelet.service
Wants=network-online.target
ConditionPathExists=!/etc/kubernetes/admin.conf
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/k8s-init.sh
StandardOutput=journal+console
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable k8s-init.service

if [ "${ERA_KUBEADM_INIT}" = "true" ]; then
  /usr/local/sbin/k8s-init.sh
else
  # Pre-init image (exported boxes): pull what the first boot needs, so it works without internet or
  # at least without waiting for it. Calico's images are pulled by the operator at init, by name below.
  CRI=unix:///var/run/crio/crio.sock
  kubeadm config images pull --kubernetes-version="${ERA_K8S_VERSION}" --cri-socket="${CRI}"
  OP=$(curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${ERA_CALICO_VERSION}/manifests/tigera-operator.yaml" | awk '/image:/ {print $2; exit}')
  crictl -r "${CRI}" pull "${OP}"
  # Calico 3.33 ships three consolidated images on quay.io (what the operator pulls on the built clusters).
  for img in calico node third-party-cni-plugins; do
    crictl -r "${CRI}" pull "quay.io/calico/${img}:${ERA_CALICO_VERSION}" || echo "calico/${img}: not pre-pulled (optional)"
  done
  curl -fsSL "https://raw.githubusercontent.com/rancher/local-path-provisioner/${ERA_LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" | awk '/image:/ {print $2}' | sort -u | while read -r img; do crictl -r "${CRI}" pull "${img}"; done
  echo "ERA_KUBEADM_INIT=false: cluster not initialized; k8s-init.service will do it at the next boot"
fi
