#!/bin/bash
# vagrant-box.sh virtualbox|vmware_desktop -- register output/era-k8s-<provider>.box as the box `era-k8s` (replacing
# the registered one), `vagrant up` with the repo's Vagrantfile, wait for the first-boot init, reboot (vagrant reload),
# check the node and the pods, `era verify`, destroy. Small VM and moved host ports by default so it can run beside the
# backup Lima instance on this Mac (override with ERA_*). KEEP=1 leaves the machine up.
set -euo pipefail
prov="${1:?virtualbox|vmware_desktop}"
case "$prov" in
  virtualbox) file=era-k8s-virtualbox.box ;;
  vmware_desktop|vmware) prov=vmware_desktop; file=era-k8s-vmware.box ;;
  *) echo "unknown provider $prov" >&2; exit 1 ;;
esac
cd "$(dirname "$0")/../.."    # the Vagrantfile is at the repo root
export ERA_HTTPS_PORT="${ERA_HTTPS_PORT:-9443}" ERA_HTTP_PORT="${ERA_HTTP_PORT:-9080}" ERA_API_PORT="${ERA_API_PORT:-16443}"
export ERA_CPUS="${ERA_CPUS:-4}" ERA_MEMORY="${ERA_MEMORY:-8192}"
vs() { vagrant ssh -c "$1" 2>/dev/null | tr -d '\r'; }
echo "== destroy any previous machine, add the box $(date)"
vagrant destroy -f >/dev/null 2>&1 || true
vagrant box add --force era-k8s "packer/output/$file" 2>&1 | tail -1
echo "== vagrant up --provider $prov (${ERA_CPUS} cpus, ${ERA_MEMORY} MiB, ports $ERA_HTTPS_PORT/$ERA_HTTP_PORT/$ERA_API_PORT) $(date)"
vagrant up --provider "$prov" 2>&1 | grep -vE '^WARNING' | grep -E 'Fixed port|error|Error|Booting|Machine booted|Timed out' || true
vagrant status 2>/dev/null | grep -q "running" || { echo "machine not running after vagrant up" >&2; exit 1; }
echo "== wait for k8s-init $(date)"
for i in $(seq 1 60); do
  st=$(vs 'systemctl is-active k8s-init.service' || true)
  [ "$st" = active ] && break
  [ "$st" = failed ] && { echo "k8s-init FAILED"; vs 'sudo journalctl -u k8s-init --no-pager | tail -40'; exit 1; }
  [ "$i" = 60 ] && { echo "k8s-init not finished after 600 s" >&2; exit 1; }
  sleep 10
done
vs 'sudo journalctl -u k8s-init --no-pager -o short-iso | grep -E "Starting k8s-init|k8s-init: done" | cut -c1-70; echo hostname=$(hostname); cat /etc/sysconfig/kubelet; sudo kubectl get nodes --no-headers | cut -c1-60'
echo "== reload (reboot) $(date)"
vagrant reload 2>&1 | grep -vE '^WARNING' | grep -E 'error|Error|Machine booted|Timed out' || true
sleep 20
out=""
for i in $(seq 1 36); do out=$(vs 'sudo kubectl get nodes --no-headers' || true); case "$out" in *" Ready "*) break ;; esac; sleep 5; done
case "$out" in *" Ready "*) echo "after reboot: $out" ;; *) echo "node not Ready within 200 s of the reboot: $out" >&2; exit 1 ;; esac
vs 'sudo kubectl get pods -A --no-headers | grep -v -E " (Running|Completed) " || echo "all pods Running"'
echo "== era verify $(date)"
rec=$(vs 'sudo era verify 2>&1 | tail -3'); echo "$rec"
echo "$rec" | grep -q "failed=0" || { echo "era verify FAILED" >&2; exit 1; }
if [ "${KEEP:-}" != 1 ]; then vagrant destroy -f >/dev/null 2>&1; echo "destroyed"; fi
echo "VAGRANT_BOX_TEST_OK $prov $(date)"
