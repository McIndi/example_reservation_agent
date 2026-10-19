#!/bin/bash
# Make the image manageable by Vagrant: the well-known insecure public key (replaced by a per-VM key at the
# first `vagrant up`) and sudo without a TTY. The kickstart already created the user and its sudoers entry.
set -eux -o pipefail
install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.ssh
curl -fsSL https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant.pub -o /home/vagrant/.ssh/authorized_keys
chmod 0600 /home/vagrant/.ssh/authorized_keys && chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
echo "Defaults:vagrant !requiretty" >/etc/sudoers.d/99-vagrant-requiretty && chmod 0440 /etc/sudoers.d/99-vagrant-requiretty
