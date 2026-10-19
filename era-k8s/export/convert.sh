#!/bin/zsh
# convert.sh INSTANCE|DISKFILE [qcow2|vmdk|vdi|vhdx] [OUT] -- convert a STOPPED Lima instance's raw disk, or any
# disk image under $HOME (raw, vdi, vmdk...), into a portable image, by default under ~/Documents/era-k8s/export/out/.
# qemu-img is not available for Intel macOS, so it runs inside the `podman` Lima VM, which sees the same paths
# through its home mount.
set -euo pipefail
inst="${1:-}"; fmt="${2:-qcow2}"
[[ -n "$inst" ]] || { print -u2 "usage: convert.sh INSTANCE|DISKFILE [qcow2|vmdk|vdi|vhdx] [OUT]"; exit 1; }
if [[ -f "$inst" ]]; then
  src="${inst:A}"; name="${${src:t}%.*}"
else
  src="$HOME/.lima/$inst/disk"; [[ -f "$src" ]] || { print -u2 "no disk at $src"; exit 1; }
  st=$(limactl list "$inst" --format '{{.Status}}'); [[ "$st" == "Stopped" ]] || { print -u2 "$inst is $st; stop it first"; exit 1; }
  name="${inst}-$(date +%Y%m%d)"
fi
[[ "$(limactl list podman --format '{{.Status}}')" == "Running" ]] || limactl start podman --tty=false
out="${3:-$HOME/Documents/era-k8s/export/out/${name}.${fmt}}"
mkdir -p "${out:h}"
limactl shell podman -- sudo dnf -y -q install qemu-img >/dev/null
case "$fmt" in
  qcow2) opts=(-c) ;;                       # compressed
  vmdk)  opts=(-o subformat=streamOptimized) ;;   # the form OVA/ovftool and Fusion import want
  vdi|vhdx) opts=() ;;
  *) print -u2 "unknown format $fmt"; exit 1 ;;
esac
print -- "converting $src -> $out"
limactl shell podman -- qemu-img convert -p -O "$fmt" "${opts[@]}" "$src" "$out"
shasum -a 256 "$out" > "$out.sha256"
ls -lh "$out"; cat "$out.sha256"
