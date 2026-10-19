#!/bin/bash
# test-arm64-virtualbox.sh DISK -- on an Apple silicon Mac with VirtualBox 7.1+ (no Vagrant, no Lima needed):
# DISK is the raw disk of a sanitized pre-init instance (~/.lima/k8s-export/disk, converted here to a VDI) or an
# existing era-k8s-arm64.vdi. Creates an ARM VM on it (NAT with the same port forwards as the x86 OVA, moved
# by ERA_*_PORT if taken), boots it headless, waits for the first-boot init, runs `era verify`, deletes the VM.
# KEEP=1 leaves the VM running. The VDI stays: it is the artifact for VirtualBox users.
set -euo pipefail
VB=/Applications/VirtualBox.app/Contents/MacOS/VBoxManage; command -v VBoxManage >/dev/null && VB=VBoxManage
src="${1:?disk (raw) or .vdi}"; VM="${VM:-era-k8s-arm64test}"
HTTPS=${ERA_HTTPS_PORT:-8443}; HTTP=${ERA_HTTP_PORT:-8080}; API=${ERA_API_PORT:-6443}; SSHP=${ERA_SSH_PORT:-2222}
case "$src" in
  *.vdi) VDI="$src" ;;
  *) VDI="${2:-$HOME/era-k8s-arm64.vdi}"; echo "== convertfromraw $src -> $VDI $(date)"; rm -f "$VDI"; "$VB" convertfromraw "$src" "$VDI" --format VDI ;;
esac
ls -lh "$VDI"
"$VB" list vms | grep -q "\"$VM\"" && { "$VB" controlvm "$VM" poweroff 2>/dev/null || true; sleep 2; "$VB" unregistervm "$VM" --delete-all 2>/dev/null || "$VB" unregistervm "$VM" --delete; }
# unregistervm --delete removes attached media too; re-clone from a copy would be safer, so attach a linked copy:
WORK="$HOME/VirtualBox VMs/$VM"; mkdir -p "$WORK"; TEST="$WORK/disk.vdi"
# A stale registry entry for the test copy (a previous run) blocks the clone: close it, by UUID, then clone afresh.
"$VB" list hdds | awk -v f="$TEST" '$1=="UUID:"{u=$2} $1=="Location:" && $2==f {print u}' | while read -r u; do
  "$VB" closemedium disk "$u" --delete 2>/dev/null || "$VB" closemedium disk "$u" 2>/dev/null || true
done
rm -f "$TEST"
"$VB" clonemedium disk "$VDI" "$TEST" --format VDI >/dev/null; echo "test copy $TEST"
"$VB" closemedium disk "$VDI" 2>/dev/null || true
echo "== create $VM $(date)"
"$VB" createvm --name "$VM" --platform-architecture arm --ostype Fedora_arm64 --register --basefolder "$HOME/VirtualBox VMs" >/dev/null
"$VB" modifyvm "$VM" --cpus 8 --memory 16384 --firmware efi --graphicscontroller qemuramfb --vram 16 \
  --nic1 nat --nic-type1 virtio --nat-localhostreachable1 on \
  --natpf1 "era-https,tcp,127.0.0.1,$HTTPS,,8443" --natpf1 "era-http,tcp,127.0.0.1,$HTTP,,8080" \
  --natpf1 "era-api,tcp,127.0.0.1,$API,,6443" --natpf1 "era-ssh,tcp,127.0.0.1,$SSHP,,22"
# Storage controller: VirtualBox's ARM VMs refuse VirtIO SCSI on 7.2.10 ("Invalid controller type 11"); NVMe (pcie)
# is the one the GUI creates for them, AHCI the fallback. Fedora's generic initramfs carries nvme, ahci and virtio.
for ctl in "pcie NVMe" "sata IntelAhci" "scsi VirtIO"; do
  set -- $ctl
  if "$VB" storagectl "$VM" --name era --add "$1" --controller "$2" --bootable on 2>/dev/null; then echo "storage controller: $2"; break; fi
done
"$VB" storageattach "$VM" --storagectl era --port 0 --device 0 --type hdd --medium "$TEST"
"$VB" showvminfo "$VM" --machinereadable | grep -E "^(firmware|ostype|cpus|memory|Forwarding|storagecontrollername0)"
echo "== start $(date)"; "$VB" startvm "$VM" --type headless
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)
for k in ~/.ssh/vagrant.key.ed25519 ~/.ssh/vagrant.key.rsa ~/.vagrant.d/insecure_private_keys/vagrant.key.ed25519; do [ -f "$k" ] && SSHOPTS+=(-i "$k"); done
vssh() { ssh "${SSHOPTS[@]}" -p "$SSHP" vagrant@127.0.0.1 "$@"; }
for i in $(seq 1 90); do vssh true 2>/dev/null && break; sleep 5; [ "$i" = 90 ] && { echo "no ssh after 450 s" >&2; "$VB" showvminfo "$VM" | grep -E "^State"; exit 1; }; done
echo "ssh up $(date)"; vssh 'hostname; uname -m; cat /etc/issue.d/era-k8s.issue | head -1; ip -brief addr | grep -v lo; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | head -8'
for i in $(seq 1 60); do st=$(vssh 'systemctl is-active k8s-init.service' 2>/dev/null || true); [ "$st" = active ] && break; [ "$st" = failed ] && { vssh 'sudo journalctl -u k8s-init --no-pager | tail -40'; exit 1; }; sleep 10; done
echo "init done $(date)"; vssh 'sudo kubectl get nodes -o wide; sudo era verify 2>&1 | tail -6'
echo "== https through the forward: $(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$HTTPS/" || true)"
if [ "${KEEP:-}" != 1 ]; then "$VB" controlvm "$VM" poweroff; sleep 3; "$VB" unregistervm "$VM" --delete-all; echo "deleted $VM (the VDI $VDI stays)"; fi
