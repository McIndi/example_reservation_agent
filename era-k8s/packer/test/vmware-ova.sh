#!/bin/bash
# Deploy output/era-k8s-vmware.ova with ovftool into a throwaway folder, start it with vmrun (no GUI), reach it by
# the address VMware's NAT gives it (as a recipient without Vagrant would), wait for the init, verify, delete.
set -euo pipefail
cd "$(dirname "$0")/.."; . test/lib.sh
OVFTOOL="/Applications/VMware Fusion.app/Contents/Library/VMware OVF Tool/ovftool"
DIR="${OVATEST_DIR:-$PWD/output-ovatest}"; rm -rf "$DIR"; mkdir -p "$DIR"   # not under $TMPDIR: Fusion cancels the start of a VM deployed there
echo "== deploy $(date)"
"$OVFTOOL" --acceptAllEulas --name=era-k8s-ovatest output/era-k8s-vmware.ova "$DIR/"
VMX=$(find "$DIR" -name '*.vmx' | head -1); echo "$VMX"
/usr/bin/sed -i '' -e 's/^numvcpus.*/numvcpus = "8"/' -e "s/^memsize.*/memsize = \"${ERA_MEMORY:-16384}\"/" "$VMX"; grep -E '^(numvcpus|memsize|ethernet0.connectionType|ethernet0.virtualDev)' "$VMX"
# No --lax on the deploy: it writes virtualhw.version 99, which vmrun refuses to power on ("canceled"). The two lines
# below answer any first-start prompt without a GUI.
printf 'uuid.action = "create"\nmsg.autoAnswer = "TRUE"\n' >> "$VMX"
echo "== start $(date)"; vmrun -T fusion start "$VMX" nogui
IP=$(vmrun -T fusion getGuestIPAddress "$VMX" -wait); echo "guest address $IP (via open-vm-tools)"
wait_ssh "$IP" 22; echo "ssh up $(date)"
wait_init "$IP" 22; echo "init done $(date)"
verify "$IP" 22
echo "== https direct to the VM: $(curl -sk -o /dev/null -w '%{http_code}' "https://$IP:8443/" || true)"
vssh "vagrant@$IP" 'sudo era config ERA_DOMAIN=$(hostname -I | awk "{print \$1}" | tr . -).sslip.io'
echo "== reboot"; reboot_check "$IP" 22
if [ "${KEEP:-}" != 1 ]; then vmrun -T fusion stop "$VMX" hard; vmrun -T fusion deleteVM "$VMX"; rm -rf "$DIR"; echo "deleted"; fi
