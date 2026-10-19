#!/bin/bash
# Import output/era-k8s-virtualbox.ova into VirtualBox as a throwaway VM, boot it headless, wait for the first-boot
# init, run `era verify`, delete it. Host ports are moved (ERA_*_PORT, as in the Vagrantfile) because this Mac's
# backup Lima instance owns 8443/8080/6443.
set -euo pipefail
cd "$(dirname "$0")/.."; . test/lib.sh
VM=era-k8s-ovatest; OVA=${OVA:-output/era-k8s-virtualbox.ova}; MEM=${ERA_MEMORY:-16384}; HTTPS=${ERA_HTTPS_PORT:-9443}; HTTP=${ERA_HTTP_PORT:-9080}; API=${ERA_API_PORT:-16443}; SSHP=${ERA_SSH_PORT:-2232}
VBoxManage list vms | grep -q "\"$VM\"" && VBoxManage unregistervm "$VM" --delete
echo "== import $(date)"
VBoxManage import "$OVA" --vsys 0 --vmname "$VM" --cpus 8 --memory "$MEM"
VBoxManage showvminfo "$VM" --machinereadable | grep -E "^Forwarding|^nic1|natnet|localhostreachable" 
for r in era-https era-http era-api era-ssh; do VBoxManage modifyvm "$VM" --natpf1 delete "$r"; done
VBoxManage modifyvm "$VM" --natpf1 "era-https,tcp,127.0.0.1,$HTTPS,,8443" --natpf1 "era-http,tcp,127.0.0.1,$HTTP,,8080" \
  --natpf1 "era-api,tcp,127.0.0.1,$API,,6443" --natpf1 "era-ssh,tcp,127.0.0.1,$SSHP,,22"
echo "== start $(date)"; VBoxManage startvm "$VM" --type headless
wait_ssh 127.0.0.1 "$SSHP"; echo "ssh up $(date)"
wait_init 127.0.0.1 "$SSHP"; echo "init done $(date)"
verify 127.0.0.1 "$SSHP"
echo "== https through the forward: $(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$HTTPS/" || true) (any answer = the forward and firewalld work; the gateway is not installed yet)"
echo "== reboot"; reboot_check 127.0.0.1 "$SSHP"
if [ "${KEEP:-}" != 1 ]; then VBoxManage controlvm "$VM" poweroff; sleep 3; VBoxManage unregistervm "$VM" --delete; echo "deleted $VM"; fi
