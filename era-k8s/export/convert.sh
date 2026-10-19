#!/bin/zsh
# convert.sh INSTANCE [qcow2|vmdk|vdi|vhdx] -- convert a STOPPED Lima instance's raw disk into a portable
# image under ~/Documents/era-k8s/export/out/. qemu-img is not available for Intel macOS, so it runs inside
# the `podman` Lima VM, which sees the same paths through its home mount.
set -euo pipefail
inst="${1:-}"; fmt="${2:-qcow2}"
[[ -n "$inst" ]] || { print -u2 "usage: convert.sh INSTANCE [qcow2|vmdk|vdi|vhdx]"; exit 1; }
src="$HOME/.lima/$inst/disk"; [[ -f "$src" ]] || { print -u2 "no disk at $src"; exit 1; }
st=$(limactl list "$inst" --format '{{.Status}}'); [[ "$st" == "Stopped" ]] || { print -u2 "$inst is $st; stop it first"; exit 1; }
[[ "$(limactl list podman --format '{{.Status}}')" == "Running" ]] || limactl start podman --tty=false
out="$HOME/Documents/era-k8s/export/out/${inst}-$(date +%Y%m%d).${fmt}"
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
