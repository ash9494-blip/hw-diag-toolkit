#!/bin/bash
# Install the toolkit into the chroot and configure live boot behaviour
set -e
B=${B:-$(cd "$(dirname "$0")" && pwd)}
C=$B/chroot; [ -L "$C" ] && C=$(readlink -f "$C")   # a symlinked chroot must be followed, or mksquashfs packs the link

mount --bind /proc $C/proc; mount --bind /sys $C/sys; mount --bind /dev $C/dev; mount --bind /dev/pts $C/dev/pts
trap 'umount -l $C/dev/pts $C/dev $C/sys $C/proc 2>/dev/null || true' EXIT

export DEBIAN_FRONTEND=noninteractive
# trim.sh empties /var/lib/apt/lists to save space, so there is no package index
# here until this runs. Without it every install below fails with "Unable to
# locate package" and the build carries on regardless, producing an image with
# no wifi tools in it.
chroot $C apt-get update >/dev/null 2>&1

chroot $C apt-get install -y --no-install-recommends jq zstd \
    iproute2 iputils-ping ethtool isc-dhcp-client \
    alsa-utils alsa-ucm-conf v4l-utils usbutils pciutils fonts-crosextra-carlito \
    fonts-dejavu-core \
    iw wpasupplicant rfkill wireless-regdb curl 2>&1 | tail -2
# Fail loudly rather than shipping an image missing the tools a test needs.
for t in iw wpa_supplicant rfkill curl dhclient lspci alsaucm; do
  chroot $C sh -c "command -v $t" >/dev/null 2>&1 \
    || { echo "BUILD ABORTED - $t did not install into the image" >&2; exit 1; }
done
echo "tooling present: iw wpa_supplicant rfkill curl dhclient lspci alsaucm"
# ALSA's use-case profiles. On 11th-gen and newer laptops the sound DSP (SOF)
# comes up with its speaker and headphone paths switched off; these profiles
# are what switch them on. The A40-J image had none.
[ -d $C/usr/share/alsa/ucm2 ] \
  || { echo "BUILD ABORTED - alsa-ucm-conf profiles missing from the image" >&2; exit 1; }
echo "sound profiles present: $(ls $C/usr/share/alsa/ucm2 | wc -l) entries"
# A second DHCP client, tried when dhclient gets no address. Installed on its
# own line because it lives in universe: if it is ever unavailable, that must
# not take the whole package list above down with it.
chroot $C apt-get install -y --no-install-recommends udhcpc >/dev/null 2>&1 \
  && echo "backup DHCP client present: udhcpc" \
  || echo "WARN: udhcpc not installed - wifi falls back to dhclient only" >&2

# The touchpad driver chain. All of it ships in linux-modules(-extra); this is
# here so a future trim can never quietly take a link out - a missing one
# looks, on the bench, like a dead touchpad.
K=$(basename "$(ls -1 $C/boot/vmlinuz-* | sort | tail -1)" | sed 's/vmlinuz-//')
for m in drivers/hid/i2c-hid/i2c-hid-acpi drivers/hid/hid-multitouch \
         drivers/mfd/intel-lpss-pci drivers/pinctrl/intel/pinctrl-tigerlake \
         drivers/input/mouse/psmouse drivers/input/mouse/elan_i2c; do
  ls $C/usr/lib/modules/$K/kernel/$m.ko* >/dev/null 2>&1 \
    || { echo "BUILD ABORTED - touchpad driver missing from the image: $m" >&2; exit 1; }
done
echo "touchpad driver chain present"

# Every font the renderer asks for must actually exist.
#
# PIL's ImageFont.truetype() raises when a file is missing and the loader falls
# back to load_default() - a fixed ~11px bitmap that ignores the requested size
# entirely. No error, no crash, just permanently tiny text wherever that font
# was used. The image shipped for months with no monospace font at all, so
# every value column and the whole report viewer rendered in that bitmap while
# the labels beside them scaled correctly. Nothing catches that except looking,
# so it is asserted here instead.
for f in /usr/share/fonts/truetype/crosextra/Carlito-Regular.ttf \
         /usr/share/fonts/truetype/crosextra/Carlito-Bold.ttf \
         /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf \
         /usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf; do
  [ -f "$C$f" ] || { echo "BUILD ABORTED - font missing from the image: $f" >&2; exit 1; }
done
echo "fonts present: Carlito + DejaVu Sans Mono"

# ---- wifi firmware ----
# linux-firmware whole is 651 MB, nearly all of it GPUs and devices a repair
# bench never sees. Ubuntu 24.04 splits it by vendor, and these cover
# essentially every wifi card in a laptop: Intel (the whole Toshiba/Dynabook
# fleet and most business machines), Realtek and Qualcomm/Atheros.
#
# Two traps here, both already paid for:
#   * "linux-firmware" in noble-updates is a 1.8 KB transitional stub. Pulling
#     it gets you nothing; the real blobs are only in the split packages.
#   * dpkg still lists those split packages as installed, because trim.sh
#     deleted their files without removing the packages. So apt-get install is
#     a no-op and the files never come back - the .debs have to be fetched and
#     unpacked by hand.
install_wifi_firmware() {
  local work; work=$(mktemp -d)
  # firmware-sof-signed matters as much as the wifi blobs: without it there is
  # no sound at all on 11th-gen and newer laptops. linux-firmware-realtek
  # carries rtl_nic for the wired adapter as well as the wifi parts.
  # MediaTek, Broadcom and the newer Qualcomm cards are here too: Wi-Fi is how
  # Driver check downloads everything else, so a card that needs a download
  # before it can get online would leave that machine stuck.
  local pkgs="linux-firmware-intel-wireless linux-firmware-realtek
              linux-firmware-qualcomm-wireless linux-firmware-intel-misc
              linux-firmware-mediatek linux-firmware-broadcom-wireless
              firmware-sof-signed"
  chroot $C apt-get update >/dev/null 2>&1 || true
  local p got=0
  for p in $pkgs; do
    if chroot $C sh -c "cd /tmp && apt-get download $p" >/dev/null 2>&1; then
      local deb; deb=$(ls $C/tmp/${p}_*.deb 2>/dev/null | head -1)
      if [ -n "$deb" ]; then
        dpkg-deb -x "$deb" "$work" && got=$((got+1))
        rm -f "$deb"
      fi
    else
      echo "WARN: could not fetch $p" >&2
    fi
  done
  if [ "$got" -eq 0 ]; then
    echo "WARN: no wifi firmware bundled - the wireless test cannot associate" >&2
    rm -rf "$work"; return 0
  fi
  mkdir -p $C/usr/lib/firmware
  cp -a "$work"/lib/firmware/. $C/usr/lib/firmware/ 2>/dev/null || true
  # Drop the generations no laptop on this bench will have: iwlwifi ucode is
  # versioned per card generation and the pre-7000 files are 2010 and earlier.
  local g
  for g in 1000 105 135 2000 2030 3945 4965 5000 5150 6000 6050 100; do
    rm -f $C/usr/lib/firmware/iwlwifi-${g}-*.ucode* 2>/dev/null
  done
  # MediaTek's package also carries firmware for its ARM tablet and router
  # chips (mt81xx/mt8xxx, the VPU blobs) - no laptop here has those.
  rm -rf $C/usr/lib/firmware/mediatek/mt8[0-9]* $C/usr/lib/firmware/mediatek/sof* \
         $C/usr/lib/firmware/vpu_*.bin 2>/dev/null
  rm -rf "$work"
  local d
  for d in iwlwifi-* rtw88 rtw89 ath10k ath11k mediatek brcm intel/sof; do
    ls -d $C/usr/lib/firmware/$d >/dev/null 2>&1 \
      || echo "WARN: no $d firmware in the image" >&2
  done
  echo "wifi firmware: $got package(s), tree now $(du -sh $C/usr/lib/firmware | cut -f1)"
}
install_wifi_firmware

# restore_modules.sh is deliberately NOT run any more. trim.sh now keeps the
# module tree whole and removes only the GPU drivers, so there is nothing to
# put back - and it was the restore step that quietly returned i915 and froze a
# live machine in v1.4.0. Leaving it unused removes that failure mode entirely.

# ---- toolkit ----
mkdir -p $C/opt/diag
cp $B/toolkit/*.sh $B/toolkit/*.py $C/opt/diag/
# The icon artwork is data the renderer loads at draw time, so it has to travel
# with the scripts. Missing it does not crash anything - _icon_smooth falls back
# to drawing - which is exactly why its absence would go unnoticed until the
# tiles looked wrong on a real machine.
rm -rf $C/opt/diag/icons
cp -a $B/toolkit/icons $C/opt/diag/icons
chmod +x $C/opt/diag/*.sh $C/opt/diag/*.py
n=$(ls $C/opt/diag/icons/*.png 2>/dev/null | wc -l)
[ "$n" -ge 19 ] || { echo "BUILD ABORTED - only $n icon files reached the image" >&2; exit 1; }
echo "icons installed: $n"

# Actually start the renderer against a file-backed framebuffer.
#
# A syntax check is not enough: ui.py once shipped with a NameError on a
# constant that only fires at startup, and the toolkit silently fell back to
# the text interface on real hardware. Booting it here for a couple of seconds
# and insisting it paints a frame catches that class of fault at build time.
smoke_test_ui() {
  local d=$C/tmp/uismoke
  rm -rf "$d"; mkdir -p "$d"
  printf 'q' > "$d/keys"
  chroot $C env DIAG_RUN=/tmp/uismoke \
                DIAG_FB_FILE=/tmp/uismoke/fb.raw \
                DIAG_UI_KEYS=/tmp/uismoke/keys \
    timeout 12 python3 /opt/diag/ui.py > "$d/out" 2>&1 || true
  # timeout returns 124 when it does the killing, which is the normal outcome
  # here - the renderer is a daemon and never exits on its own. The evidence is
  # the frame it painted, not its exit code.
  if [ ! -s "$d/fb.raw" ]; then
    echo "BUILD ABORTED - the renderer did not paint a frame:" >&2
    tail -12 "$d/out" >&2
    rm -rf "$d"; exit 1
  fi
  echo "renderer smoke test: painted $(stat -c%s "$d/fb.raw") bytes"
  rm -rf "$d"
}
smoke_test_ui

# The drive-test animations (HDD / SSD -> How these tests work) are a separate
# module that ui.py only imports when they are opened, so the smoke test above
# never touches them. Render every step of every one, in every theme, here -
# a broken animation stops the build instead of a demonstration at the bench.
[ -f $C/opt/diag/ssdanim.py ] \
  || { echo "BUILD ABORTED - ssdanim.py did not reach the image" >&2; exit 1; }
if ! chroot $C env DIAG_RUN=/tmp/animcheck python3 /opt/diag/ssdanim.py --check > /tmp/animcheck.out 2>&1; then
  echo "BUILD ABORTED - the drive-test animations failed to render:" >&2
  tail -12 /tmp/animcheck.out >&2
  exit 1
fi
cat /tmp/animcheck.out

# ---- autologin on tty1 and serial ----
mkdir -p $C/etc/systemd/system/getty@tty1.service.d
cat > $C/etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF
mkdir -p $C/etc/systemd/system/serial-getty@ttyS0.service.d
cat > $C/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,38400,9600 %I $TERM
EOF
chroot $C systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1 || true

cat > $C/root/.bash_profile <<'EOF'
# Launch the diagnostic toolkit on the console
case "$(tty)" in
  /dev/tty1|/dev/ttyS0)
    [ -z "$DIAG_NO_MENU" ] && exec /opt/diag/menu.sh
    ;;
esac
EOF

# ---- sound without the graphics driver ----
# Intel sound (SOF and HD Audio, 6th gen onwards) waits for the i915 graphics
# driver so it can drive HDMI audio. This image has no i915 (invariant 1), so
# on the TECRA A40-J the sound driver waited forever and there was no sound
# card at all: "deferred probe pending: sof-audio-pci-intel-tgl: init of i915
# and HDMI codec failed". gpu_bind=0 tells it not to wait - speakers,
# headphones and microphones work; HDMI audio does not, and could not anyway.
mkdir -p $C/etc/modprobe.d
cat > $C/etc/modprobe.d/diag-audio.conf <<'EOF'
options snd_hda_core gpu_bind=0
EOF
grep -q 'gpu_bind=0' $C/etc/modprobe.d/diag-audio.conf \
  || { echo "BUILD ABORTED - the sound fix (gpu_bind=0) is missing" >&2; exit 1; }
echo "sound: snd_hda_core gpu_bind=0 (Intel sound does not wait for the absent i915)"

# ---- misc system config ----
# The hardware clock holds LOCAL time. Every machine on this bench comes from
# Windows, which keeps the RTC in local time. Without this Linux reads it as
# UTC: the header clock showed 8 hours ahead (the image's zone is UTC+8), and
# once Wi-Fi let timesyncd set the true time, the kernel would write UTC back
# into the RTC - leaving the customer's Windows clock 8 hours out.
printf '0.0 0 0.0\n0\nLOCAL\n' > $C/etc/adjtime
echo "diagtool" > $C/etc/hostname
cat > $C/etc/hosts <<'EOF'
127.0.0.1 localhost diagtool
::1 localhost ip6-localhost ip6-loopback
EOF
chroot $C passwd -d root >/dev/null 2>&1 || true

# keep boot quiet and quick
cat > $C/etc/issue <<'EOF'
Hardware Diagnostic Toolkit
EOF
chroot $C systemctl disable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
chroot $C systemctl mask systemd-networkd-wait-online.service    >/dev/null 2>&1 || true
chroot $C systemctl mask apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

# A drain test can run for hours, and a CPU soak longer still - closing the lid
# or idling must not suspend the machine.
mkdir -p $C/etc/systemd/logind.conf.d
cat > $C/etc/systemd/logind.conf.d/99-diag.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
IdleAction=ignore
EOF

# live-boot: do not try to persist
mkdir -p $C/etc/live
cat > $C/etc/live/boot.conf <<'EOF'
LIVE_NOPERSISTENCE=true
EOF

# ---- slim down ----
chroot $C apt-get clean
rm -rf $C/usr/share/doc/* $C/usr/share/man/* $C/usr/share/info/* \
       $C/usr/share/locale/* $C/var/lib/apt/lists/* $C/var/cache/apt/* \
       $C/usr/share/help/* 2>/dev/null || true
find $C/usr/lib/modules -name '*.ko' -newermt '1970-01-01' >/dev/null 2>&1 || true

# regenerate initramfs so live-boot hooks are present
chroot $C update-initramfs -u -k all 2>&1 | tail -2

echo "chroot finalized"
du -sh --exclude=proc --exclude=sys --exclude=dev $C
