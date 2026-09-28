#!/bin/bash
# Install everything the build and the VM tests need on the build host.
# Ubuntu 24.04 (noble) - native, a VM, or WSL2. Run as root.
set -e
apt-get update
apt-get install -y --no-install-recommends \
  debootstrap squashfs-tools xorriso \
  isolinux syslinux-common grub-efi-amd64-bin grub-common \
  mtools dosfstools memtest86+ \
  qemu-system-x86 qemu-utils ovmf \
  python3 python3-pil zstd ca-certificates
# memtest86+ 7.x drops these into /boot; build_iso.sh copies them from there
ls /boot/memtest86+x64.bin /boot/memtest86+x64.efi
echo "host ready"
