#!/bin/bash
# Boot output/era-k8s-amd64.qcow2 with QEMU inside a throwaway Lima instance (Fedora, home mounted): on a Linux host
# with /dev/kvm this is the real KVM test; on this Intel Mac it runs under TCG (software emulation; Apple's hypervisor
# gives neither Lima nor Fusion nested virtualization), slow but exercising exactly what KVM users hit: SeaBIOS, the
# generic initramfs, virtio-blk and virtio-net. Milestones: "ssh up" (the boot path works), "init done" (if TCG gets
# there within the timeout). KEEP=1 leaves the instance and the guest running.
set -euo pipefail
cd "$(dirname "$0")/.."; . test/lib.sh
INST=qemutest; IMG="$PWD/output/era-k8s-amd64.qcow2"; SSHP=${ERA_SSH_PORT:-2222}
limactl list -q | grep -qx "$INST" && limactl delete -f "$INST"
echo "== lima instance $(date)"
limactl start --name "$INST" --tty=false --timeout 10m --set '.cpus=6 | .memory="8GiB" | .disk="30GiB" | del(.networks)' template://fedora
limactl shell "$INST" -- sudo dnf -y -q install qemu-system-x86-core qemu-img >/dev/null
limactl shell "$INST" -- bash -c "qemu-img create -q -f qcow2 -F qcow2 -b '$IMG' /tmp/era-k8s-test.qcow2; ls -la /tmp/era-k8s-test.qcow2; ls -la /dev/kvm 2>/dev/null || echo 'no /dev/kvm: TCG'"
ACCEL=$(limactl shell "$INST" -- bash -c 'test -w /dev/kvm && echo kvm || echo tcg')
echo "== qemu ($ACCEL) $(date)"
limactl shell "$INST" -- bash -c "nohup qemu-system-x86_64 -accel $ACCEL -cpu max -m 6G -smp 4 -nographic -display none \
  -drive file=/tmp/era-k8s-test.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n0,hostfwd=tcp:0.0.0.0:$SSHP-:22 -device virtio-net-pci,netdev=n0 \
  -serial file:/tmp/era-k8s-serial.log -monitor none >/tmp/qemu.out 2>&1 &"
sleep 5; limactl shell "$INST" -- bash -c 'pgrep -a qemu-system | cut -c1-120; cat /tmp/qemu.out'
for i in $(seq 1 180); do vssh -p "$SSHP" vagrant@127.0.0.1 true 2>/dev/null && break; sleep 10; [ "$i" = 180 ] && { echo "no ssh after 30 min" >&2; limactl shell "$INST" -- tail -20 /tmp/era-k8s-serial.log; exit 1; }; done
echo "ssh up $(date) (accel $ACCEL)"
vssh -p "$SSHP" vagrant@127.0.0.1 'hostname; cat /proc/cmdline | tr " " "\n" | grep -E "^root=|BOOT_IMAGE"; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | head -6; ip -brief addr | grep -v lo; grep -m1 "model name" /proc/cpuinfo; systemd-detect-virt'
for i in $(seq 1 120); do st=$(vssh -p "$SSHP" vagrant@127.0.0.1 'systemctl is-active k8s-init.service' 2>/dev/null || true); [ "$st" = active ] && break; [ "$st" = failed ] && { vssh -p "$SSHP" vagrant@127.0.0.1 'sudo journalctl -u k8s-init --no-pager | tail -30'; exit 1; }; sleep 20; done
echo "init done $(date)"; verify 127.0.0.1 "$SSHP"
if [ "${KEEP:-}" != 1 ]; then limactl delete -f "$INST"; echo "deleted $INST"; fi
