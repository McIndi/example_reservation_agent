# era-k8s

A single-node Kubernetes cluster that runs the rossoctl platform and this repository's reservation agent
without OpenShift: Fedora 44, kubeadm, CRI-O, Calico, local-path storage, SELinux enforcing, firewalld.
It comes as a Lima template for macOS (Intel and Apple silicon) and as Vagrant boxes for VirtualBox and
VMware, all built from the same provisioning scripts; the cluster initializes itself at its first boot.
Inside the VM, the `era` command installs the platform, the agent and its tool, OpenBao with the Vault
Secrets Operator, and SIEMatic, the audit plane.

**To run it, start with [docs/running-the-box.md](docs/running-the-box.md).**

| File | Purpose |
|---|---|
| `k8s.yaml` | Lima template for the cluster VM. Generated: edit `k8s.yaml.in` or `provision/*.sh`, then run `bin/render-template` |
| `provision/` | The provisioning steps, shared by the Lima template and the Packer builds (`ERA_*` variables, defaults inside) |
| `ansible/` | Playbooks run inside the VM by `era`: `verify`, `platform` (rossoctl + TLS + Phoenix + Ollama), `agent` (reservation tool and agent, gateway credential, IBAC), `vault` (OpenBao + Vault Secrets Operator over the platform Secrets, audit to stdout), `siematic` (from Cliff's manifests in `files/siematic/upstream`, rendered for this cluster); `files/` holds the scripts they install |
| `bin/era` | The VM's own command: `era verify`, `era platform`, `era agent`, `era vault`, `era siematic`, `era all`, `era update`, `era config` |
| `packer/` | Packer template, kickstart and scripts for the Vagrant boxes (`era-k8s-vmware.box`, `era-k8s-virtualbox.box`) |
| `Vagrantfile` | Runs a box: sizes, bridge and host ports from `ERA_*` environment variables |
| `export/` | Sanitize and convert a Lima instance into a raw disk image for other hypervisors; `RECIPIENT.md` ships with it |
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

## Vagrant boxes

```bash
cd packer && packer init era-k8s.pkr.hcl
packer build -only='*.vmware' era-k8s.pkr.hcl        # output/era-k8s-vmware.box
packer build -only='*.virtualbox' era-k8s.pkr.hcl    # output/era-k8s-virtualbox.box
```

The builds boot the Fedora 44 Server netinst ISO (`isos/`, a symlink to your download; the checksum is in
the template) and take 8 to 12 minutes each. A box is a pre-init image: installed, tuned, images
pre-pulled, the playbooks and `era` baked in; `k8s-init.service` initializes the cluster at the first
`vagrant up`.

## Developing

- After editing `provision/*.sh` or `k8s.yaml.in`: `bin/render-template` (and `bin/render-template --check`
  tells whether `k8s.yaml` is current).
- After editing `ansible/`: in a running VM, `sudo era update` pulls this repository's `era-k8s` branch
  (`ERA_REPO`, `ERA_BRANCH`, `ERA_REPO_SUBDIR` in `/etc/era-k8s/config.env`), or copy the files in by hand.
- Images: the agent and tool come from this repository's `era-k8s` branch (`ghcr.io/mcindi/reservation-agent`
  and `reservation-tool`, tag `era-k8s`, linux/amd64 and linux/arm64); SIEMatic from its own `era-k8s`
  branch, pinned by digest in `ansible/playbooks/siematic.yml`.

The design notes and the demo material are kept outside this repository.
