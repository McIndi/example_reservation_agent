#!/bin/bash
# build-preinit.sh [INSTANCE] -- build a throwaway pre-init instance of the Lima template (kubeadmInit=false, no
# bridged network, 4 CPUs / 8 GiB for the build), bake the playbooks and `era` in like the Packer boxes, add the
# vagrant login (add-login.sh), sanitize it (sanitize-guest.sh) and stop it. The result is ~/.lima/INSTANCE/disk:
# a raw disk for the native architecture of this Mac, ready for convert.sh (qcow2, vmdk, vdi) or for
# `VBoxManage convertfromraw`. The cluster initializes at the recipient's first boot (k8s-init.service).
set -euo pipefail
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/.."
inst="${1:-k8s-export}"
if limactl list -q 2>/dev/null | grep -qx "$inst"; then
  [ "$(limactl list "$inst" --format '{{.Status}}')" = Running ] || { echo "instance $inst exists and is not running; limactl delete -f $inst first" >&2; exit 1; }
  echo "=== $inst is already running: continuing with the playbooks, the login and the sanitizer $(date)"
else
  echo "=== create+start $inst $(date)"
  # copyToHost is dropped: the kubeconfigs it copies do not exist before the first-boot init, and Lima reports
  # the failed copy as a degraded start (exit 1) although provisioning succeeded.
  limactl start --name "$inst" --tty=false --timeout 25m \
    --set 'del(.networks) | del(.copyToHost) | .param.kubeadmInit="false" | .cpus=4 | .memory="8GiB"' k8s.yaml
fi
echo "=== pre-pulled images: $(limactl shell "$inst" -- sudo crictl images -q 2>/dev/null | wc -l | tr -d ' ') (13 = control plane 7, tigera operator, calico 3, local-path 2)"
echo "=== playbooks and era into /opt/era-k8s $(date)"
limactl shell "$inst" -- sudo rm -rf /tmp/era-k8s-stage
limactl shell "$inst" -- mkdir -p /tmp/era-k8s-stage
limactl cp -r ansible "$inst:/tmp/era-k8s-stage/ansible"
limactl cp -r provision "$inst:/tmp/era-k8s-stage/provision"
limactl cp bin/era "$inst:/tmp/era-k8s-stage/era"
limactl cp export/add-login.sh "$inst:/tmp/era-k8s-stage/add-login.sh"
limactl cp export/sanitize-guest.sh "$inst:/tmp/era-k8s-stage/sanitize-guest.sh"
limactl shell "$inst" -- sudo bash -c 'set -e; install -d -m 0755 /opt/era-k8s; rm -rf /opt/era-k8s/ansible /opt/era-k8s/provision;
  cp -r /tmp/era-k8s-stage/ansible /opt/era-k8s/ansible; cp -r /tmp/era-k8s-stage/provision /opt/era-k8s/provision;
  install -m 0755 /tmp/era-k8s-stage/era /usr/local/bin/era; install -m 0755 /opt/era-k8s/ansible/files/era-chat.sh /usr/local/bin/era-chat;
  chown -R root:root /opt/era-k8s; test ! -e /etc/kubernetes/admin.conf'
echo "=== login, sanitize $(date)"
limactl shell "$inst" -- sudo bash /tmp/era-k8s-stage/add-login.sh
# The sanitizer removes the Lima user's key, so it is the last thing done over ssh (the stage dir goes with it).
limactl shell "$inst" -- sudo bash -c 'KEEP_USER=vagrant bash /tmp/era-k8s-stage/sanitize-guest.sh; rc=$?; rm -rf /tmp/era-k8s-stage; exit $rc'
limactl stop "$inst"
echo "=== done $(date): raw disk $HOME/.lima/$inst/disk ($(du -sh "$HOME/.lima/$inst/disk" | cut -f1) allocated)"
