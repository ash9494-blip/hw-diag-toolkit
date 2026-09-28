#!/bin/bash
# Build the chroot from nothing. Reconstructed after the original was lost with
# the container; the package list comes from the project's stack notes.
set -e
B=${B:-$(cd "$(dirname "$0")" && pwd)}
C=$B/chroot
rm -rf "$C"; mkdir -p "$C"

debootstrap --variant=minbase --arch=amd64 noble "$C" http://archive.ubuntu.com/ubuntu/

cat > "$C/etc/apt/sources.list" <<'X'
deb http://archive.ubuntu.com/ubuntu/ noble main universe
deb http://archive.ubuntu.com/ubuntu/ noble-updates main universe
X

mount --bind /proc "$C/proc"; mount --bind /sys "$C/sys"; mount --bind /dev "$C/dev"
trap 'umount -l "$C/dev" "$C/sys" "$C/proc" 2>/dev/null || true' EXIT

export DEBIAN_FRONTEND=noninteractive
chroot "$C" apt-get update
chroot "$C" apt-get install -y --no-install-recommends \
    linux-image-generic live-boot systemd-sysv \
    fio stress-ng stressapptest memtester \
    smartmontools nvme-cli lm-sensors dmidecode e2fsprogs \
    pciutils kmod util-linux bash coreutils procps \
    python3 python3-pil console-setup kbd \
    ca-certificates

echo "bootstrap done: $(du -sh --exclude=proc --exclude=sys --exclude=dev "$C" | cut -f1)"
