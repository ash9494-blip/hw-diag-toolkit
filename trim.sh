#!/bin/bash
# Slim the chroot, and enforce the graphics invariant.
#
# Reconstructed after the original was lost. It differs from the original on
# purpose: the first version stripped most of the module tree and a companion
# script put the needed subtrees back, which is what broke v1.4.0 when the
# restore quietly returned the GPU drivers. Here the module tree is kept whole
# and only the genuinely unwanted parts are removed, so there is nothing to
# restore and nothing to get wrong.
set -e
B=${B:-$(cd "$(dirname "$0")" && pwd)}
C=$B/chroot; [ -L "$C" ] && C=$(readlink -f "$C")   # a symlinked chroot must be followed, or mksquashfs packs the link
K=$(basename "$(ls -1 $C/boot/vmlinuz-* | sort | tail -1)" | sed 's/vmlinuz-//')
MOD=$C/usr/lib/modules/$K/kernel

before=$(du -sh --exclude=proc --exclude=sys --exclude=dev "$C" | cut -f1)

# ---- firmware -------------------------------------------------------------
# 651 MB, almost all of it GPU microcode for cards we deliberately cannot use.
# finalize_chroot.sh puts back the wifi vendors, the SOF sound firmware and the
# Realtek NIC firmware - the only blobs any test needs.
rm -rf "$C/usr/lib/firmware"
mkdir -p "$C/usr/lib/firmware"

# ---- the graphics invariant ----------------------------------------------
# No KMS graphics drivers, ever. Without them the kernel falls back to
# simpledrm/efifb on the framebuffer the firmware already set up, so every
# machine renders identically and no driver can seize the display. v1.4.0
# shipped with these present and froze a live machine at "Detecting hardware".
for g in i915 xe amdgpu nouveau radeon; do
  rm -rf "$MOD/drivers/gpu/drm/$g"
done
rm -rf "$MOD/zfs" "$MOD/drivers/gpu/drm/amd"

# ---- dead weight ----------------------------------------------------------
rm -rf "$C"/usr/share/doc/* "$C"/usr/share/man/* "$C"/usr/share/info/* \
       "$C"/usr/share/locale/* "$C"/usr/share/help/* \
       "$C"/var/lib/apt/lists/* "$C"/var/cache/apt/archives/*.deb 2>/dev/null || true

depmod -b "$C" "$K" 2>/dev/null || true

echo "trim: $before -> $(du -sh --exclude=proc --exclude=sys --exclude=dev "$C" | cut -f1)"
echo -n "KMS drivers remaining: "
find "$MOD" -type d \( -name i915 -o -name xe -o -name amdgpu -o -name nouveau -o -name radeon \) 2>/dev/null | wc -l
