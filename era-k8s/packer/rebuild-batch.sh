#!/bin/bash
# rebuild-batch.sh [--check|--publish] -- the whole image set rebuilt, tested and republished in one unattended run:
#   1. preconditions (Fusion idle, gh logged in, the M1 Max reachable, podman VM for qemu-img, clean tree)
#   2. x86_64 here: ./build.sh all (two Packer builds, then the OVAs and the qcow2); in parallel on the M1 Max:
#      the arm64 pre-init disk (export/build-preinit.sh), its VirtualBox test there, the VDI copied back here
#   3. tests here: both Vagrant boxes, both OVAs; the qcow2 under QEMU (TCG, own port) runs alongside
#   4. arm64 qcow2 + vmdk from the VDI (export/convert.sh), the VDI zipped, SHA256SUMS
#   5. only when every test passed: the assets of the GitHub release replaced (--clobber), title and notes updated
#      (release-notes.md), the remote SHA256SUMS compared with the local one
# Logs: rebuild-batch.log (everything), rebuild-batch/<step>.log, one line per step in rebuild-batch.status.
# The previous output/ set is kept as output-prev/. Written for one unattended run on RELEASE_DAY; refuses to run on
# another day unless FORCE=1. --check runs the preconditions only. ERA_ARM64_HOST names the Apple-silicon Mac that
# builds and tests the arm64 disk (ssh with BatchMode, mise shims, Lima and VirtualBox installed there).
set -uo pipefail
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Applications/VMware Fusion.app/Contents/Public"   # vmrun
cd "$(dirname "$0")"; PK="$PWD"; REPO="$(dirname "$PK")"
M1=${ERA_ARM64_HOST:-arm64-mac}; TAG=era-k8s-images-2026-10-18; GHREPO=McIndi/example_reservation_agent; RELEASE_DAY=2026-10-20
L="$PK/rebuild-batch"; STATUS="$PK/rebuild-batch.status"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 $M1"
RPATH='export PATH=$HOME/.local/share/mise/shims:$HOME/.local/bin:/usr/local/bin:$PATH'
ASSETS=(era-k8s-vmware.box era-k8s-virtualbox.box era-k8s-vmware.ova era-k8s-virtualbox.ova era-k8s-amd64.qcow2
        era-k8s-arm64.vdi.zip era-k8s-arm64.qcow2 era-k8s-arm64.vmdk SHA256SUMS)
t0=$(date +%s); el() { echo "$(( ($(date +%s)-t0)/60 )) min"; }
log() { echo "$(date '+%F %T') $*"; }
status() { echo "$(date '+%F %T') $*" >> "$STATUS"; log "$*"; }
fail() { status "FAILED: $* (after $(el))"; exit 1; }

pre() {
  log "== preconditions"
  local n; n=$(vmrun -T fusion list 2>/dev/null | head -1); [ "$n" = "Total running VMs: 0" ] || fail "Fusion: $n"
  [ -z "$(VBoxManage list runningvms)" ] || fail "VirtualBox VMs running: $(VBoxManage list runningvms | tr '\n' ' ')"
  (cd "$REPO" && vagrant status 2>/dev/null | grep -qE "running|poweroff|saved") && fail "a Vagrant machine exists in $REPO (vagrant destroy -f)"
  limactl list -q | grep -qx qemutest && fail "Lima instance qemutest exists (a previous test left it)"
  [ "$(limactl list podman --format '{{.Status}}')" = Running ] || limactl start podman --tty=false || fail "podman VM not running"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in"
  gh release view "$TAG" --repo "$GHREPO" --json tagName >/dev/null 2>&1 || fail "release $TAG not found"
  [ -f "$PK/release-notes.md" ] || fail "no $PK/release-notes.md"
  $SSH 'uname -m' 2>/dev/null | grep -q arm64 || fail "$M1 unreachable"
  $SSH "$RPATH; limactl list -q 2>/dev/null | grep -qx k8s-export" && fail "instance k8s-export exists on $M1"
  $SSH "$RPATH; [ -z \"\$(VBoxManage list runningvms)\" ]" || fail "VirtualBox VMs running on $M1"
  (cd "$REPO" && git status --porcelain | grep -v '^??' | grep -q .) && fail "uncommitted changes in $REPO"
  (cd "$REPO" && bin/render-template --check >/dev/null 2>&1) || fail "k8s.yaml is not current (bin/render-template)"
  local avail; avail=$(df -g "$PK" | awk 'NR==2{print $4}'); [ "$avail" -gt 60 ] || fail "only ${avail} GB free"
  log "preconditions OK (Fusion idle, VirtualBox idle, podman VM up, gh ok, $M1 reachable, tree clean, ${avail} GB free)"
}

arm64_remote() {   # on the M1 Max: pre-init disk, VirtualBox test, VDI copied back; exit status = result
  set -e
  log "rsync repo -> $M1:Documents/era-k8s"
  rsync -a --delete --exclude .git --exclude .vagrant --exclude 'packer/output*' --exclude packer/isos --exclude '*.log' \
    --exclude 'packer/rebuild-batch*' --exclude export/out --exclude shared "$REPO/" "$M1:Documents/era-k8s/"
  $SSH "$RPATH; cd Documents/era-k8s && grep -q 'seq 1 60' provision/60-k8s-init.sh" || { echo "the CRD-wait fix is not in the synced copy"; return 1; }
  log "build-preinit.sh on $M1"
  $SSH "$RPATH; cd Documents/era-k8s && export/build-preinit.sh k8s-export"
  log "arm64 VirtualBox test on $M1"
  $SSH "$RPATH; cd Documents/era-k8s && rm -f ~/era-k8s-arm64.vdi && export/test-arm64-virtualbox.sh ~/.lima/k8s-export/disk ~/era-k8s-arm64.vdi"
  $SSH "$RPATH; limactl delete -f k8s-export"
  log "copy the VDI back"
  rsync -a --inplace "$M1:era-k8s-arm64.vdi" "$PK/output/era-k8s-arm64.vdi"
  local a b; a=$($SSH 'shasum -a 256 ~/era-k8s-arm64.vdi' | cut -c1-64); b=$(shasum -a 256 "$PK/output/era-k8s-arm64.vdi" | cut -c1-64)
  [ -n "$a" ] && [ "$a" = "$b" ] || { echo "VDI checksum mismatch after the copy ($a vs $b)"; return 1; }
  $SSH 'rm -f ~/era-k8s-arm64.vdi'
  log "ARM64_OK"
}

publish() {   # step 5 on the set in output/ (also `rebuild-batch.sh --publish`, after a re-test by hand)
  for f in "${ASSETS[@]}"; do [ -s "$PK/output/$f" ] || fail "missing output/$f"; done
  local chk; chk=$(cd "$PK/output" && shasum -a 256 -c SHA256SUMS 2>&1) || fail "output/ does not match its SHA256SUMS"
  status "step 5: upload to release $TAG (--clobber)"
  ok=0
  for attempt in 1 2 3; do
    if (cd "$PK/output" && gh release upload "$TAG" --repo "$GHREPO" --clobber "${ASSETS[@]}") >> "$L/upload.log" 2>&1; then ok=1; break; fi
    log "upload attempt $attempt failed; retrying in 60 s"; sleep 60
  done
  [ "$ok" = 1 ] || fail "upload (rebuild-batch/upload.log); the release may hold a mix of old and new assets"
  gh release edit "$TAG" --repo "$GHREPO" --title "era-k8s images 2026-10-18, rebuilt $RELEASE_DAY" --notes-file "$PK/release-notes.md" >> "$L/upload.log" 2>&1 || fail "release edit (assets are uploaded)"
  sleep 10
  curl -sL "https://github.com/$GHREPO/releases/download/$TAG/SHA256SUMS" -o "$L/SHA256SUMS.remote"
  cmp -s "$L/SHA256SUMS.remote" "$PK/output/SHA256SUMS" || fail "the remote SHA256SUMS differs from the local one (assets are uploaded; check rebuild-batch/)"
  gh release view "$TAG" --repo "$GHREPO" --json assets --jq '.assets[]|[.name,.size,.state]|@tsv' | tee -a "$L/upload.log"
  status "PUBLISHED: all ${#ASSETS[@]} assets of $TAG replaced, remote SHA256SUMS identical ($(el) total)"
}

run_test() { local name=$1; shift; log "-- test $name"; if "$@" > "$L/test-$name.log" 2>&1; then status "test $name OK ($(el))"; else status "test $name FAILED (rebuild-batch/test-$name.log)"; TESTFAIL=1; fi; }

if [ "${1:-}" = --check ]; then STATUS=/dev/null; pre; exit 0; fi
if [ "${1:-}" = --publish ]; then
  mkdir -p "$L"; mkdir "$L/.lock" 2>/dev/null || { echo "another run holds $L/.lock" >&2; exit 1; }; trap 'rmdir "$L/.lock" 2>/dev/null' EXIT
  exec > >(tee -a "$PK/rebuild-batch.log") 2>&1
  status "PUBLISH only: the set in output/ (tests passed by hand)"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in"; [ -f "$PK/release-notes.md" ] || fail "no release-notes.md"
  publish; status "DONE"; exit 0
fi
[ "${FORCE:-}" = 1 ] || [ "$(date +%F)" = "$RELEASE_DAY" ] || { echo "today is $(date +%F), not $RELEASE_DAY (FORCE=1 to run anyway)" >&2; exit 1; }
mkdir -p "$L"; mkdir "$L/.lock" 2>/dev/null || { echo "another run holds $L/.lock" >&2; exit 1; }
trap 'rmdir "$L/.lock" 2>/dev/null' EXIT
exec > >(tee -a "$PK/rebuild-batch.log") 2>&1
status "START rebuild batch (pid $$)"
pre

status "step 2: x86 build here + arm64 on $M1 (parallel)"
rm -rf "$PK/output-prev"; [ -d "$PK/output" ] && mv "$PK/output" "$PK/output-prev"; mkdir -p "$PK/output"
( ./build.sh all > "$L/build-x86.log" 2>&1; echo $? > "$L/build-x86.rc" ) & BUILD_PID=$!
( (arm64_remote) > "$L/arm64.log" 2>&1; echo $? > "$L/arm64.rc" ) & ARM_PID=$!   # inner subshell: its set -e must not skip the rc
wait $ARM_PID;   [ "$(cat "$L/arm64.rc")" = 0 ] && status "arm64 disk built, tested on $M1, copied ($(el))" || status "arm64 FAILED (rebuild-batch/arm64.log)"
wait $BUILD_PID; [ "$(cat "$L/build-x86.rc")" = 0 ] && status "x86 build + OVAs + qcow2 done ($(el))" || status "x86 build FAILED (rebuild-batch/build-x86.log)"
[ "$(cat "$L/build-x86.rc")" = 0 ] && [ "$(cat "$L/arm64.rc")" = 0 ] || fail "build step; nothing uploaded, the release is unchanged, the previous set is in output-prev/"
for f in era-k8s-vmware.box era-k8s-virtualbox.box era-k8s-vmware.ova era-k8s-virtualbox.ova era-k8s-amd64.qcow2 era-k8s-arm64.vdi; do
  [ -s "$PK/output/$f" ] || fail "missing output/$f"
done

status "step 3: tests"
TESTFAIL=0
run_test vagrant-virtualbox test/vagrant-box.sh virtualbox
run_test vagrant-vmware    test/vagrant-box.sh vmware_desktop
run_test virtualbox-ova    test/virtualbox-ova.sh
run_test vmware-ova        test/vmware-ova.sh
# Last and alone: under TCG (software emulation) the guest's API server must answer kubeadm's 10 s requests; run
# beside the vagrant-virtualbox test on 2026-10-20 it did not ("context deadline exceeded" in wait-control-plane).
run_test qcow2-qemu        env ERA_SSH_PORT=2322 test/qcow2-qemu.sh

status "step 4: arm64 qcow2 + vmdk, zip, checksums"
"$REPO/export/convert.sh" "$PK/output/era-k8s-arm64.vdi" qcow2 "$PK/output/era-k8s-arm64.qcow2" > "$L/convert-qcow2.log" 2>&1 || fail "convert qcow2"
"$REPO/export/convert.sh" "$PK/output/era-k8s-arm64.vdi" vmdk  "$PK/output/era-k8s-arm64.vmdk"  > "$L/convert-vmdk.log"  2>&1 || fail "convert vmdk"
rm -f "$PK"/output/*.sha256                       # convert.sh writes one per file; SHA256SUMS is the list that ships
(cd "$PK/output" && rm -f era-k8s-arm64.vdi.zip && zip -q era-k8s-arm64.vdi.zip era-k8s-arm64.vdi) || fail "zip"
(cd "$PK/output" && shasum -a 256 era-k8s-* > SHA256SUMS && cat SHA256SUMS && ls -l) || fail "checksums"
for f in "${ASSETS[@]}"; do [ -s "$PK/output/$f" ] || fail "missing output/$f"; done
status "set complete: $(du -sh "$PK/output" | cut -f1) in output/ ($(el))"

[ "$TESTFAIL" = 0 ] || fail "a test failed; nothing uploaded, the release is unchanged"
publish
status "DONE"
