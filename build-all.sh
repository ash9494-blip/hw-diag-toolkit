#!/bin/bash
# Full build from nothing: chroot -> trim -> toolkit -> ISO -> verify.
#
#   sudo ./build-all.sh            # everything (~20-40 min, needs internet)
#   sudo ./build-all.sh quick      # reuse the existing chroot: toolkit + ISO only
#
# Order matters: build_iso.sh does NOT copy the toolkit into the chroot,
# finalize_chroot.sh does. Running build_iso.sh alone ships the previous
# version's scripts.
set -e
B=$(cd "$(dirname "$0")" && pwd); export B
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
case "$B" in /mnt/[a-z]/*) echo "Build inside the Linux filesystem, not on a Windows drive ($B)."; exit 1 ;; esac

if [ "${1:-}" != quick ] || [ ! -d "$B/chroot/usr" ]; then
  "$B/bootstrap.sh"
  "$B/trim.sh"
fi
"$B/finalize_chroot.sh"
"$B/build_iso.sh"

# Verify the squashfs, not the source tree - a stale DIAG_VERSION shipped once.
want=$(sed -n 's/^DIAG_VERSION="\(.*\)"/\1/p' "$B/toolkit/lib.sh")
got=$(unsquashfs -cat "$B/image/live/filesystem.squashfs" opt/diag/lib.sh 2>/dev/null \
      | sed -n 's/^DIAG_VERSION="\(.*\)"/\1/p')
[ "$want" = "$got" ] || { echo "VERIFY FAILED: source $want, image $got"; exit 1; }
echo "built v$got: $B/hw-diagnostic-toolkit.iso"
sha256sum "$B/hw-diagnostic-toolkit.iso"
