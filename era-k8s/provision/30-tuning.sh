#!/bin/bash
# era-k8s provisioning, step 30: UTC, inotify, virtual-disk scheduler, transparent huge pages off
# Shared by the Lima template (k8s.yaml is rendered from k8s.yaml.in + provision/*.sh by bin/render-template,
# which exports the template's param: values as ERA_* variables) and by the Packer builds (which export the
# same variables, or none: every variable below has the template's default). Runs as root on Fedora 44.
set -eux -o pipefail
# The node keeps UTC: CRI-O/conmon stamp container logs in the local zone, and SIEMatic's kube-logs
# shipper compares those stamps as strings with a UTC checkpoint (found 2026-10-18); OpenShift nodes
# are UTC too. Lima copies the Mac's zone into the guest otherwise.
timedatectl set-timezone UTC 2>/dev/null || ln -sf /usr/share/zoneinfo/UTC /etc/localtime
# inotify: kubelet and many pods exhaust Fedora's defaults (128 instances) -> "too many open files"
cat <<EOF >/etc/sysctl.d/99-guest-tuning.conf
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
vm.swappiness = 10
EOF
sysctl --system
# virtual disks: not rotational, no guest-side scheduling (the host already schedules)
cat <<EOF >/etc/udev/rules.d/60-virtual-disk.rules
ACTION=="add|change", KERNEL=="vd[a-z]|sd[a-z]|nvme[0-9]n[0-9]", ATTR{queue/rotational}="0", ATTR{queue/scheduler}="none"
EOF
udevadm control --reload-rules
udevadm trigger --action=change --subsystem-match=block
# transparent huge pages off (etcd, Keycloak's Postgres)
cat <<EOF >/etc/systemd/system/disable-thp.service
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
[Install]
WantedBy=basic.target
EOF
systemctl daemon-reload
systemctl enable --now disable-thp.service
