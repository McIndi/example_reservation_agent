# era-k8s images, 2026-10-18, rebuilt 2026-10-20

A single-node Kubernetes VM (Fedora 44, kubeadm v1.37.1, CRI-O, Calico v3.33, local-path storage, SELinux enforcing,
firewalld) with the rossoctl platform tooling baked in. Every file is the same pre-init image: everything installed,
container images pre-pulled, the cluster initializes itself on the first boot (one to two minutes), then the platform
(rossoctl, Keycloak, MCP gateway, Phoenix, Ollama, the reservation agent, OpenBao, SIEMatic) is installed from inside
the VM with `sudo era all` (internet access, 10 to 20 minutes).

**Start with the guide: [era-k8s/docs/running-the-box.md](https://github.com/McIndi/example_reservation_agent/blob/era-k8s/era-k8s/docs/running-the-box.md).**
Login on every image: user `vagrant`, password `vagrant` (sudo without password); the console shows the VM's address.

| file | for |
|---|---|
| `era-k8s-virtualbox.box` | Vagrant, `virtualbox` provider (Windows, Linux, Intel macOS) |
| `era-k8s-vmware.box` | Vagrant, `vmware_desktop` provider (Workstation; Fusion on Intel) |
| `era-k8s-virtualbox.ova` | VirtualBox without Vagrant: Import Appliance; the NAT port forwards (8443, 8080, 6443, SSH on 2222) are included |
| `era-k8s-vmware.ova` | VMware Workstation or Fusion (Intel) without Vagrant: File > Open |
| `era-k8s-amd64.qcow2` | KVM / libvirt (`virt-install --import`), Proxmox; BIOS firmware, virtio |
| `era-k8s-arm64.vdi.zip` | Apple silicon: VirtualBox 7.1+ (ARM VM, EFI, NVMe or SATA controller); unzip first |
| `era-k8s-arm64.qcow2` | Apple silicon: UTM; also libvirt on arm64 Linux |
| `era-k8s-arm64.vmdk` | Apple silicon: VMware Fusion 13+, Parallels (custom VM with an existing disk) |
| `SHA256SUMS` | checksums of all of the above (and of the unzipped VDI) |

Sizing: 8 CPUs and 24 GB are the defaults the demo was rehearsed with; 4 CPUs and 16 GB work for the cluster and the
platform, with a slower in-cluster LLM. The disk is 100 GB thin.

The 2026-10-20 build replaces the 2026-10-18 files: the first-boot init now retries the Calico CRD wait, which could
fail on a very slow machine in the first build (`sudo era init` resumed it). Nothing else changed.

Tested on this build: both Vagrant boxes (VirtualBox and VMware Fusion on an Intel Mac: first boot, reboot, `era verify`),
the VirtualBox OVA and the VMware OVA (same checks), the arm64 VDI on VirtualBox 7.2 on an M1 Mac, the amd64 qcow2
under QEMU (first boot complete). UTM, Fusion on Apple silicon, Parallels and Hyper-V are untested.

Built from the `era-k8s` branch of this repository (`era-k8s/packer`, `era-k8s/export`), with the
`ghcr.io/mcindi/reservation-agent:era-k8s`, `reservation-tool:era-k8s` and `ghcr.io/mcindi/siematic:era-k8s`
images (linux/amd64 and linux/arm64).
