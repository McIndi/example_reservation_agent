# era-k8s

A single-node Kubernetes cluster that runs the rossoctl platform and this repository's reservation agent
without OpenShift: Fedora 44, kubeadm, CRI-O, Calico, local-path storage, SELinux enforcing, firewalld.
It comes as a Lima template for macOS (Intel and Apple silicon), as Vagrant boxes and OVAs for VirtualBox and
VMware, all built from the same provisioning scripts; the cluster initializes itself at its first boot.
Inside the VM, the `era` command installs the platform, the agent and its tool, OpenBao with the Vault
Secrets Operator, and SIEMatic, the audit plane.

**To run it, start with [docs/running-the-box.md](docs/running-the-box.md); the images are on the
[release page](https://github.com/McIndi/example_reservation_agent/releases/tag/era-k8s-images-2026-10-18).**

| File | Purpose |
|---|---|
| `k8s.yaml` | Lima template for the cluster VM. Generated: edit `k8s.yaml.in` or `provision/*.sh`, then run `bin/render-template` |
| `provision/` | The provisioning steps, shared by the Lima template and the Packer builds (`ERA_*` variables, defaults inside) |
| `ansible/` | Playbooks run inside the VM by `era`: `verify`, `platform` (rossoctl + TLS + Phoenix + Ollama), `agent` (reservation tool and agent, gateway credential, IBAC), `vault` (OpenBao + Vault Secrets Operator over the platform Secrets, audit to stdout), `siematic` (from Cliff's manifests in `files/siematic/upstream`, rendered for this cluster); `files/` holds the scripts they install |
| `bin/era` | The VM's own command: `era verify`, `era platform`, `era agent`, `era vault`, `era siematic`, `era all`, `era update`, `era config` |
| `packer/` | Packer template, kickstart and scripts for the x86_64 images: Vagrant boxes, OVAs and a qcow2 (`build.sh`) |
| `Vagrantfile` | Runs a box: sizes, bridge and host ports from `ERA_*` environment variables |
| `export/` | The arm64 (or any Lima-built) images: `build-preinit.sh` makes a sanitized pre-init instance, `convert.sh` turns its disk into qcow2, vmdk or vdi |
| `lima-snap` | Disk snapshots for Lima's vz driver (`create`, `apply`, `list`, `delete`) |

## Lima

```bash
limactl start --name k8s k8s.yaml --tty=false                 # the cluster (3 to 10 minutes)
export KUBECONFIG=~/.lima/k8s/copied-from-guest/kubeconfig.yaml && kubectl get nodes
limactl shell k8s -- sudo era verify                          # the cluster is healthy
limactl shell k8s -- sudo era all                             # platform, agent, vault, siematic
limactl stop k8s && ./lima-snap create k8s clean && limactl start k8s    # a rollback point
```

The template bridges the VM to the LAN through socket_vmnet; without it, add `--set 'del(.networks)'` to
the first command and use the port forwards on 127.0.0.1. Settings a recipient can change before the
platform install live in `/etc/era-k8s/config.env` inside the VM (`sudo era config`); their defaults come
from the `param:` block of `k8s.yaml.in`.

## x86_64 images: Vagrant boxes, OVAs, qcow2

```bash
cd packer && packer init era-k8s.pkr.hcl
./build.sh                 # output/: era-k8s-{vmware,virtualbox}.box, era-k8s-{vmware,virtualbox}.ova, era-k8s-amd64.qcow2
```

The builds boot the Fedora 44 Server netinst ISO (`isos/`, a symlink to your download; the checksum is in
the template) and take 10 to 15 minutes each (VMware Fusion, then VirtualBox). Each is a pre-init image:
installed, tuned, images pre-pulled, the playbooks and `era` baked in; `k8s-init.service` initializes
the cluster at the first boot. The OVAs are the hypervisors' own exports of the same VMs; the qcow2 is the
VMware disk converted by qemu-img (in the `podman` Lima VM, as Intel macOS has no qemu-img).

Tests: `packer/test/vagrant-box.sh virtualbox|vmware_desktop` registers the box, runs `vagrant up`, waits for the
first-boot init, reboots, checks the node and the pods, runs `era verify` and destroys the machine;
`test/virtualbox-ova.sh`, `test/vmware-ova.sh` and `test/qcow2-qemu.sh` do the same for the other forms.
`packer/rebuild-batch.sh` is the unattended run: the x86_64 builds here, the arm64 disk on the Apple silicon Mac
named by `ERA_ARM64_HOST`, every test, and the GitHub release's assets replaced only when all of them passed
(`release-notes.md` is the release text).

## arm64 images (from the Lima template, on an Apple silicon Mac)

```bash
export/build-preinit.sh k8s-export       # a pre-init instance, playbooks baked in, vagrant login, sanitized, stopped
export/convert.sh k8s-export qcow2       # also vmdk, vdi; or: VBoxManage convertfromraw ~/.lima/k8s-export/disk era-k8s-arm64.vdi
```

## Developing

- After editing `provision/*.sh` or `k8s.yaml.in`: `bin/render-template` (and `bin/render-template --check`
  tells whether `k8s.yaml` is current).
- After editing `ansible/`: in a running VM, `sudo era update` pulls this repository's `era-k8s` branch
  (`ERA_REPO`, `ERA_BRANCH`, `ERA_REPO_SUBDIR` in `/etc/era-k8s/config.env`), or copy the files in by hand.
- Images: the agent and tool come from this repository's `era-k8s` branch (`ghcr.io/mcindi/reservation-agent`
  and `reservation-tool`, tag `era-k8s`, linux/amd64 and linux/arm64); SIEMatic from its own `era-k8s`
  branch, pinned by digest in `ansible/playbooks/siematic.yml`.

The design notes and the demo material are kept outside this repository.
