# Running era-k8s on your own machine

era-k8s is a single-node Kubernetes VM (Fedora 44, kubeadm, CRI-O, Calico, local-path storage, SELinux
enforcing, firewalld) with the rossoctl platform tooling baked in. The images are on the release page
[era-k8s-images-2026-10-18](https://github.com/McIndi/example_reservation_agent/releases/tag/era-k8s-images-2026-10-18) with a `SHA256SUMS` file; download the one for your hypervisor:

| form | for | file | section |
|---|---|---|---|
| Vagrant box, `virtualbox` provider | VirtualBox on Windows, Linux or Intel macOS | `era-k8s-virtualbox.box` | 1 |
| Vagrant box, `vmware_desktop` provider | VMware Workstation (Windows, Linux) or VMware Fusion (Intel macOS) | `era-k8s-vmware.box` | 1 |
| Lima template | macOS, Intel or Apple silicon | `k8s.yaml` in this repo | 2 |
| OVA | VirtualBox without Vagrant (Windows, Linux, Intel macOS) | `era-k8s-virtualbox.ova` | 3 |
| OVA | VMware Workstation or Fusion (Intel) without Vagrant | `era-k8s-vmware.ova` | 3 |
| qcow2 | KVM / libvirt on Linux (x86_64) | `era-k8s-amd64.qcow2` | 4 |
| arm64 disk images | Apple silicon without Lima: VirtualBox, UTM, VMware Fusion, Parallels | `era-k8s-arm64.vdi.zip` / `.qcow2` / `.vmdk` | 5 |

All of them are the same thing: a pre-init image. Everything is installed and the container images are
pre-pulled; the cluster initializes itself on the first boot (`k8s-init.service`, one to two minutes with
the pre-pulled images). The platform itself (rossoctl, Keycloak, the MCP gateway, Phoenix, Ollama, the
reservation agent, OpenBao, SIEMatic) is installed afterwards from inside the VM with the `era` command,
which needs internet access and takes 10 to 20 minutes. Every image logs in as user `vagrant`, password
`vagrant` (sudo without password); change it once you are in. The console shows the VM's address.
If the first-boot init fails (`systemctl status k8s-init`), `sudo era init` resumes it: every phase is
idempotent, so a transient hiccup on a slow machine costs one rerun, not a reset.

Sizing: 8 CPUs and 24 GB of memory are the defaults and what the demo was rehearsed with; 4 CPUs and
16 GB work for the cluster and the platform, but the in-cluster LLM gets slow. The disk is 100 GB thin.

## 1. Vagrant (VirtualBox or VMware)

Install [Vagrant](https://developer.hashicorp.com/vagrant/install) and your hypervisor. For VMware you also
need the [Vagrant VMware utility](https://developer.hashicorp.com/vagrant/docs/providers/vmware/vagrant-vmware-utility)
and `vagrant plugin install vagrant-vmware-desktop`. VirtualBox needs nothing else (no guest additions are
used; the VM shares no folder with the host).

```bash
git clone https://github.com/McIndi/example_reservation_agent -b era-k8s   # this Vagrantfile
cd example_reservation_agent
vagrant box add era-k8s era-k8s-virtualbox.box        # or era-k8s-vmware.box
vagrant up                                           # add --provider vmware_desktop for VMware
vagrant ssh -c 'sudo journalctl -fu k8s-init'        # until "k8s-init: done" (Ctrl-C to leave)
vagrant ssh -c 'sudo era verify'                     # the cluster is healthy
vagrant ssh -c 'sudo era all'                        # platform, agent, vault, siematic (10 to 20 min)
```

Environment variables read by the Vagrantfile: `ERA_CPUS` (8), `ERA_MEMORY` in MiB (24576), `ERA_BRIDGE`
(a host interface name for a LAN address; default NAT only), `ERA_HTTPS_PORT` / `ERA_HTTP_PORT` /
`ERA_API_PORT` (host ports for 8443, 8080 and 6443; Vagrant picks a free one and says so if yours is taken).
`vagrant halt` and `vagrant up` are the way to stop and start the VM; a sleeping laptop is healed by the VM
itself within about a minute of waking (token refresh and gateway restart), but stop/start is safer.

Windows notes: run the commands in PowerShell or Git Bash; Hyper-V and WSL2 can coexist with VirtualBox 7
and Workstation 17, but check that your hypervisor shows a VM with hardware virtualization available.

## 2. Lima (macOS)

```bash
mise use -g lima@latest            # or brew install lima
limactl start --name k8s k8s.yaml --tty=false      # ~3 min on Apple silicon, ~10 on Intel; the cluster is initialized at the end
limactl shell k8s -- sudo era verify
limactl shell k8s -- sudo era all
```

The template bridges the VM to your LAN through socket_vmnet; without it, create the instance with
`limactl start --name k8s --set 'del(.networks)' k8s.yaml` and use the port forwards on 127.0.0.1 instead.
To get bridged networking: install the socket_vmnet release tarball into /opt/socket_vmnet and run
`limactl sudoers | sudo tee /etc/sudoers.d/lima` (the only step that needs sudo).

## 3. OVA: VirtualBox, VMware Workstation or Fusion, without Vagrant

**VirtualBox** (Windows, Linux, Intel macOS): File > Import Appliance > `era-k8s-virtualbox.ova`, or
`VBoxManage import era-k8s-virtualbox.ova --vsys 0 --cpus 8 --memory 24576`. The appliance carries its
NAT port forwards (host 127.0.0.1: 8443, 8080 and 6443 to the VM, 2222 to SSH), so the platform URLs below
work unchanged, exactly as with the Vagrant box. Start it, then `ssh -p 2222 vagrant@127.0.0.1`.

**VMware Workstation or Fusion** (Intel): File > Open (or Import) > `era-k8s-vmware.ova`, adjust CPUs and
memory, start. VMware's NAT gives the VM an address your machine can reach (the console login screen shows
it): `ssh vagrant@<address>`. There is no port forward, so point the platform's hostnames at that address
before installing the platform:

```bash
sudo era config ERA_DOMAIN=192-168-105-7.sslip.io     # the VM's address with dashes; sslip.io resolves it
sudo journalctl -fu k8s-init                          # until "k8s-init: done"
sudo era verify && sudo era all
```

The URLs are then https://rossoctl-ui.192-168-105-7.sslip.io:8443 and so on (port 8443 reaches the VM
directly; firewalld inside forwards it to the gateway). Bridged networking works the same way with the LAN
address. The same `ERA_DOMAIN` route works for VirtualBox too if you prefer a bridged adapter to the port
forwards.

## 4. KVM / libvirt (Linux, x86_64)

`era-k8s-amd64.qcow2` boots on virtio disk and network (the initramfs is generic), BIOS firmware, 100 GB
thin:

```bash
sudo cp era-k8s-amd64.qcow2 /var/lib/libvirt/images/era-k8s.qcow2
sudo virt-install --name era-k8s --memory 24576 --vcpus 8 --import \
  --disk /var/lib/libvirt/images/era-k8s.qcow2,bus=virtio --os-variant fedora-unknown \
  --network network=default --graphics none --noautoconsole
sudo virsh domifaddr era-k8s                           # the address on the default NAT network
ssh vagrant@192.168.122.X                              # password vagrant
sudo era config ERA_DOMAIN=192-168-122-X.sslip.io      # before the platform install, as in section 3
sudo journalctl -fu k8s-init; sudo era verify; sudo era all
```

cloud-init is installed and idle without a datasource; a NoCloud seed (`--cloud-init user-data=...`) can
add your own user and SSH key, or change `/etc/era-k8s/config.env`, at the first boot. The image also
works on Proxmox (import the qcow2 as a disk of a BIOS VM) and, converted with `qemu-img`, elsewhere.

## 5. Apple silicon without Lima

The arm64 images come from the Lima template (Fedora 44 Cloud, UEFI), sanitized and given the same
`vagrant` login. Pick the file your hypervisor reads; all three carry the same disk:

- **VirtualBox 7.1+ for macOS/Arm**: unzip `era-k8s-arm64.vdi.zip`. Create an ARM VM (Fedora, 64-bit Arm) with an
  NVMe or SATA controller (not VirtIO SCSI, which VirtualBox refuses for ARM VMs), use the existing disk, NAT adapter; add port forwards 8443, 8080, 6443 and 2222 to 22 in the adapter's settings
  (or `VBoxManage modifyvm era-k8s --natpf1 "https,tcp,127.0.0.1,8443,,8443"` and so on). Then the
  platform URLs work unchanged, as with the boxes.
- **UTM**: `era-k8s-arm64.qcow2`. New VM > Virtualize > Linux, skip the ISO, 8 cores, 16 to 24 GB, then
  replace the default drive with the qcow2 (import). UTM's shared network gives the VM a reachable address:
  use the `ERA_DOMAIN` route of section 3.
- **VMware Fusion 13+ (Apple silicon)** or **Parallels**: `era-k8s-arm64.vmdk`. Create a custom Linux arm64
  VM with an existing virtual disk, NAT; then the `ERA_DOMAIN` route of section 3.

The in-cluster LLM runs on the CPU; Apple silicon handles it well (the IBAC judgement takes 20 to 30 s).

## 6. Using the platform

- Settings for the platform install live in `/etc/era-k8s/config.env` inside the VM (`sudo era config`):
  the hostnames' domain (default `localtest.me`, which resolves to 127.0.0.1 everywhere), the LLM
  endpoint and model (default: in-cluster Ollama), TLS (default on). Edit before `era platform`.
- URLs after `era platform`: https://rossoctl-ui.localtest.me:8443 (sign in as the test user: the
  username and password are in the Secret `rossoctl-test-user` in namespace `keycloak`),
  https://keycloak.localtest.me:8443, https://phoenix.localtest.me:8443, and after `era siematic`
  https://siematic.localtest.me:8443. Add `siematic.localtest.me` to your hosts file if your resolver
  does not do the wildcard. If you moved the host ports, use those instead of 8443.
- The platform's TLS certificates come from a local CA created in the VM: `/etc/era-k8s/era-ca.crt`.
  Trust it in your browser or OS keychain, or accept the warning per hostname.
- `kubectl` from the host: `vagrant ssh -c 'sudo cat /root/.kube/config.localhost'` (server
  127.0.0.1:6443, or your `ERA_API_PORT`) saved as a kubeconfig; without port forwards,
  `/root/.kube/config.lan` points at the VM's own address.
- Talk to the agent without the UI, with timing: `sudo era-chat "I would like to book a reservation"`,
  then `sudo era-chat --continue "..."` to stay in the same conversation.

## 7. What is on the box

Fedora 44 Server (kickstart `packer/http/ks.cfg`), the shared provisioning `provision/*.sh` run with
`ERA_KUBEADM_INIT=false`, `/opt/era-k8s` (the playbooks, `era`), `/usr/local/sbin/k8s-init.sh` with its
first-boot unit, the vagrant user with Vagrant's insecure key (replaced at the first `vagrant up`) and the
password `vagrant`, no swap, UTC, hostname `era-k8s` (the node name is pinned to it), a generic initramfs
(every storage driver, so the one disk boots on VirtualBox, VMware, KVM and Hyper-V). Built by
`packer/era-k8s.pkr.hcl` through `packer/build.sh`, which also derives the OVAs and the qcow2. The arm64
images are built by `export/build-preinit.sh` (a sanitized pre-init instance of the Lima template) and
converted by `export/convert.sh`.
