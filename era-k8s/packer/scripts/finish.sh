#!/bin/bash
# Last step before Packer shuts the VM down: the same sanitizer the Lima export uses (identity, logs, host
# keys, cloud-init state; the vagrant user is kept) (no zero-fill: 100 GiB thin disk).
set -eux -o pipefail
KEEP_USER=vagrant bash /tmp/era-k8s/sanitize-guest.sh
rm -rf /tmp/era-k8s
# No zero-fill of the free space here: the disk is 100 GiB thin and a dd to /EMPTY would write it all out
# on the build host before compaction. fstrim (in the sanitizer) plus Packer's compaction keep the box
# close to its used size; the installer's and dnf's leftovers are cleaned above.
sync
