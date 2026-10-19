#!/bin/bash
# Run INSIDE the throwaway export instance, as root, BEFORE sanitize-guest.sh (which then runs with KEEP_USER=vagrant):
# gives an image built from the Lima template the same login as the Packer boxes (user vagrant, password vagrant,
# sudo without password, SSH password login) and the hostname era-k8s, for recipients who import the disk into
# VirtualBox, UTM, Fusion or Parallels by hand and have no cloud-init seed. The Lima user stays, locked by the sanitizer.
set -eux -o pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
# -K: no subordinate uid/gid range (the cloud image's /etc/subuid leaves useradd none to hand out, and this user
# runs no rootless containers).
id vagrant >/dev/null 2>&1 || useradd -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 -m -G wheel -s /bin/bash vagrant
echo 'vagrant:vagrant' | chpasswd
# Vagrant's well-known insecure key too, as on the Packer boxes: scripted access without a password prompt.
install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.ssh
curl -fsSL https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant.pub -o /home/vagrant/.ssh/authorized_keys
chmod 0600 /home/vagrant/.ssh/authorized_keys && chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
echo "vagrant ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/99-vagrant && chmod 0440 /etc/sudoers.d/99-vagrant
echo "Defaults:vagrant !requiretty" >/etc/sudoers.d/99-vagrant-requiretty && chmod 0440 /etc/sudoers.d/99-vagrant-requiretty
# cloud-init wrote PasswordAuthentication no into 50-cloud-init.conf; sshd takes the first value it reads.
printf 'PasswordAuthentication yes\nPermitRootLogin no\n' >/etc/ssh/sshd_config.d/10-era-k8s.conf
sshd -t
# The node name is derived from the hostname at the first-boot init; pin it to the same name the boxes use, and
# keep cloud-init (a recipient's seed, or none) from renaming the host afterwards.
hostnamectl set-hostname era-k8s || echo era-k8s >/etc/hostname
echo 'preserve_hostname: true' >/etc/cloud/cloud.cfg.d/99-era-k8s.cfg
# Lima's cloud-init network profile matches the Lima NIC's MAC; drop it so NetworkManager's default DHCP profile
# takes whatever NIC the recipient's hypervisor presents (eth0 or enp0sN).
cloud-init clean --configs network || true
echo "login added; now: KEEP_USER=vagrant bash sanitize-guest.sh"
