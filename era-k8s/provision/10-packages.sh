#!/bin/bash
# era-k8s provisioning, step 10: kernel modules, swap off, repos, packages, helm, SELinux for SPIRE, CRI-O + kubelet on
# Shared by the Lima template (k8s.yaml is rendered from k8s.yaml.in + provision/*.sh by bin/render-template,
# which exports the template's param: values as ERA_* variables) and by the Packer builds (which export the
# same variables, or none: every variable below has the template's default). Runs as root on Fedora 44.
set -eux -o pipefail
: "${ERA_STABILITY:=stable}"
: "${ERA_RELEASE:=stable}"
: "${ERA_HELM_VERSION:=v3.22.1}"
command -v kubeadm >/dev/null 2>&1 && exit 0

cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat <<EOF >/etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# kubelet refuses swap. Fedora Cloud images use zram swap, and its unit may start AFTER this script
# runs (first build 2026-10-17: the check found no swap yet, zram came up later, kubelet died).
# So: unconditional, and the generator is disabled for every future boot.
swapoff -a || true
rpm -q zram-generator-defaults >/dev/null 2>&1 && dnf -y remove zram-generator-defaults
touch /etc/systemd/zram-generator.conf           # empty config = no zram devices
systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true
systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true

# Keep NetworkManager away from Calico's interfaces (Calico's documented setting).
mkdir -p /etc/NetworkManager/conf.d
cat <<EOF >/etc/NetworkManager/conf.d/calico.conf
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
EOF

STABILITY="${ERA_STABILITY}"
if [ "$ERA_RELEASE" = stable ]; then
  RELEASE=$(curl -L -s https://dl.k8s.io/release/stable.txt | cut -d'.' -f1-2)
else
  RELEASE="${ERA_RELEASE}"
fi

cat <<EOF >/etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/${STABILITY}:/${RELEASE}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/${STABILITY}:/${RELEASE}/rpm/repodata/repomd.xml.key
EOF
cat <<EOF >/etc/yum.repos.d/cri-o.repo
[cri-o]
name=CRI-O
baseurl=https://pkgs.k8s.io/addons:/cri-o:/${STABILITY}:/${RELEASE}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/addons:/cri-o:/${STABILITY}:/${RELEASE}/rpm/repodata/repomd.xml.key
EOF

# firewalld is installed here because Fedora Cloud does not ship it (AlmaLinux does).
# The second group is the controller toolset (what ocpclient-fedora44 carries, oc replaced by
# kubectl/helm): the VM drives its own platform install with Ansible, so one image serves
# Brian, Cliff and anyone else without a second VM.
# (dnf5 on Fedora 44 has no --disableexcludes; so install first, then add the exclude= guard below)
dnf -y install \
  cri-o kubelet kubeadm kubectl cri-tools \
  container-selinux conntrack-tools iproute-tc ethtool socat \
  firewalld podman buildah skopeo \
  git ansible-core ansible-collection-kubernetes-core python3-kubernetes python3-pip \
  jq openssl bash-completion tar gzip htop dos2unix policycoreutils-python-utils
# Helm 3 from upstream: rossoctl requires Helm >= 3.18 and < 4, and Fedora 44 packages Helm 4.
# The only architecture-specific download in this template: Lima's Fedora image template carries
# x86_64 and aarch64 entries, and pkgs.k8s.io, Calico and local-path-provisioner are multi-arch.
HELM="${ERA_HELM_VERSION}"
case "$(uname -m)" in x86_64) HELM_ARCH=amd64 ;; aarch64) HELM_ARCH=arm64 ;; *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;; esac
curl -fsSL "https://get.helm.sh/helm-${HELM}-linux-${HELM_ARCH}.tar.gz" | tar -xz -C /tmp "linux-${HELM_ARCH}/helm"
install -m 0755 "/tmp/linux-${HELM_ARCH}/helm" /usr/local/bin/helm && rm -rf "/tmp/linux-${HELM_ARCH}"
kubectl completion bash >/etc/bash_completion.d/kubectl
/usr/local/bin/helm completion bash >/etc/bash_completion.d/helm
mkdir -p /opt/era-k8s
# Upstream convention: a routine `dnf upgrade` must not move the cluster to a new minor.
# Deliberate upgrades: dnf5 `--disable-excludes=kubernetes`, dnf4 `--disableexcludes=kubernetes`.
echo 'exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni' >>/etc/yum.repos.d/kubernetes.repo
swapoff -a || true                                # again, in case zram came up during the installs
# SELinux enforcing, with the platform's host-path sockets: SPIRE's agent socket directory must be
# reachable by unprivileged pods (first platform install: the OIDC provider got "connect:
# permission denied"). Label it container_file_t and recreate it with that label at every boot.
semanage fcontext -a -t container_file_t '/run/spire(/.*)?' 2>/dev/null || true
cat <<EOF >/etc/tmpfiles.d/era-spire.conf
# era-k8s: SPIRE agent sockets must be reachable by unprivileged pods under SELinux
d /run/spire 0755 root root -
d /run/spire/agent-sockets 0777 root root -
Z /run/spire - - - - -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/era-spire.conf
systemctl enable --now crio
systemctl enable --now kubelet
