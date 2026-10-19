# Running era-k8s on your own machine

era-k8s is a single-node Kubernetes VM (Fedora 44, kubeadm, CRI-O, Calico, local-path storage, SELinux
enforcing, firewalld) with the rossoctl platform tooling baked in. You get it in one of two forms:

| form | for | file |
|---|---|---|
| Vagrant box, `virtualbox` provider | VirtualBox on Windows, Linux or Intel macOS | `era-k8s-virtualbox.box` |
| Vagrant box, `vmware_desktop` provider | VMware Workstation (Windows, Linux) or VMware Fusion (Intel macOS) | `era-k8s-vmware.box` |
| Lima template | macOS, Intel or Apple silicon, no Vagrant needed | `k8s.yaml` in this repo |

The boxes are pre-init images: everything is installed and the images are pre-pulled, and the cluster
initializes itself on the first boot (about one to two minutes). The platform itself (rossoctl, Keycloak,
the MCP gateway, Phoenix, Ollama, the reservation agent, OpenBao, SIEMatic) is installed afterwards from
inside the VM with the `era` command, which needs internet access and takes 10 to 20 minutes.

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

## 3. Using the platform

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
  127.0.0.1:6443, or your `ERA_API_PORT`) saved as a kubeconfig.
- Talk to the agent without the UI, with timing: `sudo era-chat "I would like to book a reservation"`,
  then `sudo era-chat --continue "..."` to stay in the same conversation.

## 4. What is on the box

Fedora 44 Server (kickstart `packer/http/ks.cfg`), the shared provisioning `provision/*.sh` run with
`ERA_KUBEADM_INIT=false`, `/opt/era-k8s` (the playbooks, `era`), `/usr/local/sbin/k8s-init.sh` with its
first-boot unit, the vagrant user with Vagrant's insecure key (replaced at the first `vagrant up`), no
swap, UTC, hostname `era-k8s` (the node name is pinned to it). Built by `packer/era-k8s.pkr.hcl`.
