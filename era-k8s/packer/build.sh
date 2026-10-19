#!/bin/bash
# build.sh [all|vmware|virtualbox|artifacts] -- the x86_64 images in every shipped form, from one Packer build per
# hypervisor (era-k8s.pkr.hcl): the Vagrant boxes, an OVA for each hypervisor's own importer (no Vagrant), and a
# qcow2 for KVM/libvirt from the VMware disk (qemu-img runs in the `podman` Lima VM; it is not built for Intel
# macOS). Run with no Fusion VM of your own running; each build takes 10 to 15 minutes.
set -euo pipefail
cd "$(dirname "$0")"
OVFTOOL="/Applications/VMware Fusion.app/Contents/Library/VMware OVF Tool/ovftool"
what="${1:-all}"
build() { rm -rf "output-$1"; packer build -only="*.$1" era-k8s.pkr.hcl 2>&1 | tee "build-$1.log"; }
artifacts() {
  mkdir -p output
  echo "== VMware OVA (ovftool from the kept VM)"
  "$OVFTOOL" --overwrite --name=era-k8s output-vmware/era-k8s.vmx output/era-k8s-vmware.ova
  echo "== VirtualBox OVA (the builder's export, NAT port forwards included)"
  cp -f output-virtualbox/era-k8s.ova output/era-k8s-virtualbox.ova
  echo "== qcow2 for KVM/libvirt (compressed), from the VMware disk"
  [ "$(limactl list podman --format '{{.Status}}')" = Running ] || limactl start podman --tty=false
  limactl shell podman -- sudo dnf -y -q install qemu-img >/dev/null
  limactl shell podman -- qemu-img convert -p -O qcow2 -c "$PWD/output-vmware/disk.vmdk" "$PWD/output/era-k8s-amd64.qcow2"
  limactl shell podman -- qemu-img info "$PWD/output/era-k8s-amd64.qcow2"
  echo "== checksums"
  (cd output && shasum -a 256 era-k8s-* > SHA256SUMS && cat SHA256SUMS && ls -lh)
}
case "$what" in
  vmware|virtualbox) build "$what" ;;
  artifacts) artifacts ;;
  all) build vmware; build virtualbox; artifacts ;;
  *) echo "usage: build.sh [all|vmware|virtualbox|artifacts]" >&2; exit 1 ;;
esac
