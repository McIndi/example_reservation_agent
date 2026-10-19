#!/bin/bash
# Run the shared provisioning (uploaded to /tmp/era-k8s by Packer's file provisioner) as a pre-init image:
# everything installed, tuned and pre-pulled; k8s-init.service initializes the cluster at the recipient's
# first boot. Then bake the playbooks and the `era` command in, so `era all` works on the box.
set -eux -o pipefail
export ERA_KUBEADM_INIT=false
cd /tmp/era-k8s
for f in provision/[0-9][0-9]-*.sh; do echo "=== $f ==="; bash "$f"; done
install -d -m 0755 /opt/era-k8s
rm -rf /opt/era-k8s/ansible /opt/era-k8s/provision
cp -r ansible /opt/era-k8s/ansible
cp -r provision /opt/era-k8s/provision
install -m 0755 era /usr/local/bin/era
install -m 0755 ansible/files/era-chat.sh /usr/local/bin/era-chat
chown -R root:root /opt/era-k8s
