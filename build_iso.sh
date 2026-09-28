#!/bin/bash
# Assemble the hybrid BIOS + UEFI bootable ISO
set -e
B=${B:-$(cd "$(dirname "$0")" && pwd)}
C=$B/chroot; [ -L "$C" ] && C=$(readlink -f "$C")   # a symlinked chroot must be followed, or mksquashfs packs the link
I=$B/image
OUT=${1:-$B/hw-diagnostic-toolkit.iso}
VOLID="DIAGTOOL"

KVER=$(basename "$(ls -1 $C/boot/vmlinuz-* | sort | tail -1)" | sed 's/vmlinuz-//')
echo "kernel: $KVER"

rm -rf "$I"
mkdir -p "$I"/{live,isolinux,boot/grub,EFI/boot}

# ---------------- kernel + initrd ----------------
cp "$C/boot/vmlinuz-$KVER" "$I/live/vmlinuz"
cp "$C/boot/initrd.img-$KVER" "$I/live/initrd.img"

# ---------------- memtest86+ ----------------
cp /boot/memtest86+x64.bin "$I/boot/memtest86+x64.bin"
cp /boot/memtest86+x64.efi "$I/boot/memtest86+x64.efi"

# Do NOT add nomodeset to the default entries. It was tried in 1.4.1 as belt and
# braces and it backfires: it also blocks the harmless KMS drivers (simpledrm,
# bochs) that actually program the display mode, so the guest renders at one
# resolution while the hardware scans another and the screen turns to stripes.
# Excluding the vendor GPU drivers below is the real fix; the safe-graphics boot
# entry keeps nomodeset for the machines that genuinely need it.
# ---------------- invariant: no KMS graphics drivers ----------------
# The toolkit deliberately runs on the plain firmware framebuffer so every
# machine behaves the same. A KMS driver in the image seizes the display during
# startup and, with no graphics firmware shipped, can fail to give it back -
# which is exactly how v1.4.0 stranded a C40-K at "Detecting hardware".
# This is an invariant, so the build enforces it rather than trusting memory.
KMS_FOUND=$(find "$C/usr/lib/modules" -type d \
              \( -name i915 -o -name xe -o -name amdgpu -o -name nouveau -o -name radeon \) \
              2>/dev/null | head -5)
if [ -n "$KMS_FOUND" ]; then
  echo "BUILD ABORTED - KMS graphics drivers are in the image:" >&2
  printf '  %s\n' $KMS_FOUND >&2
  echo "Remove them (see restore_modules.sh skip_module) and build again." >&2
  exit 1
fi
echo "checked: no KMS graphics drivers in the image"

# ---------------- root filesystem ----------------
if [ "$SKIP_SQUASHFS" = 1 ] && [ -s "$I.keep/filesystem.squashfs" ]; then
  echo "reusing existing squashfs"
  cp "$I.keep/filesystem.squashfs" "$I/live/filesystem.squashfs"
else
echo "building squashfs (this takes a while)..."
mksquashfs "$C" "$I/live/filesystem.squashfs" \
  -comp xz -Xbcj x86 -b 1M -noappend -no-progress \
  -e boot proc sys dev/pts run tmp var/tmp var/cache/apt var/lib/apt/lists \
  | tail -3
mkdir -p "$I.keep"; cp "$I/live/filesystem.squashfs" "$I.keep/filesystem.squashfs"
fi
ls -lh "$I/live/filesystem.squashfs"

# ---------------- BIOS boot (isolinux) ----------------
cp /usr/lib/ISOLINUX/isolinux.bin "$I/isolinux/"
for m in ldlinux.c32 libcom32.c32 libutil.c32 menu.c32 vesamenu.c32; do
  cp "/usr/lib/syslinux/modules/bios/$m" "$I/isolinux/"
done

[ -f "$B/theme/splash.png" ] && cp "$B/theme/splash.png" "$I/isolinux/splash.png" || true

cat > "$I/isolinux/isolinux.cfg" <<'EOF'
UI vesamenu.c32
PROMPT 0
TIMEOUT 100
DEFAULT diag

MENU BACKGROUND splash.png
MENU TITLE Hardware Diagnostic Toolkit
MENU WIDTH 72
MENU MARGIN 8
MENU ROWS 8
MENU VSHIFT 8
MENU TABMSGROW 18
MENU TIMEOUTROW 20
MENU COLOR border       30;44   #00000000 #00000000 none
MENU COLOR title        1;36;44 #ff4cc2ff #00000000 none
MENU COLOR sel          7;37;40 #ff0b0f14 #ff4cc2ff none
MENU COLOR unsel        37;44   #ffdbe4ef #00000000 none
MENU COLOR hotkey       1;37;44 #ffffffff #00000000 none
MENU COLOR hotsel       1;7;37;40 #ff0b0f14 #ff4cc2ff none
MENU COLOR timeout_msg  37;40   #ff7d8da3 #00000000 none
MENU COLOR timeout      1;37;40 #ffffcc66 #00000000 none
MENU COLOR tabmsg       37;40   #ff556070 #00000000 none
MENU COLOR cmdline      37;40   #ffdbe4ef #00000000 none

LABEL diag
  MENU LABEL Hardware Diagnostic Toolkit  (disk / CPU / RAM)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live union=overlay quiet loglevel=3 consoleblank=0 nvme_core.default_ps_max_latency_us=0

LABEL diagram
  MENU LABEL Hardware Diagnostic Toolkit  (run from RAM)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live union=overlay toram quiet loglevel=3 consoleblank=0 nvme_core.default_ps_max_latency_us=0

LABEL diagapst
  MENU LABEL Hardware Diagnostic Toolkit  (NVMe power saving left ON)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live union=overlay quiet loglevel=3 consoleblank=0

LABEL diagsafe
  MENU LABEL Hardware Diagnostic Toolkit  (safe graphics)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live union=overlay nomodeset quiet loglevel=3 consoleblank=0 nvme_core.default_ps_max_latency_us=0

LABEL diagserial
  MENU LABEL Hardware Diagnostic Toolkit  (serial console ttyS0)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live union=overlay console=tty1 console=ttyS0,115200n8 loglevel=3

LABEL memtest
  MENU LABEL MemTest86+  (full RAM test, all memory)
  LINUX /boot/memtest86+x64.bin

LABEL local
  MENU LABEL Boot from the internal hard disk
  LOCALBOOT 0x80
EOF

# ---------------- UEFI boot (grub) ----------------
mkdir -p "$I/boot/grub/themes/diag"
if ls "$B"/theme/*.pf2 >/dev/null 2>&1; then
  cp "$B"/theme/*.png "$B"/theme/*.pf2 "$B/theme/theme.txt" "$I/boot/grub/themes/diag/" 2>/dev/null || true
else
  echo "note: no boot-menu theme present - GRUB falls back to plain colours"
fi

cat > "$I/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=15

insmod all_video
insmod gfxterm
insmod png
insmod gfxmenu

set gfxmode=auto
set gfxpayload=keep

# Load the fonts first. If any of this fails, fall through to the plain text
# menu rather than leaving a black screen.
if loadfont ($root)/boot/grub/themes/diag/mono14.pf2 ; then
  loadfont ($root)/boot/grub/themes/diag/mono18.pf2
  loadfont ($root)/boot/grub/themes/diag/mono18b.pf2
  loadfont ($root)/boot/grub/themes/diag/mono24b.pf2
  terminal_output gfxterm
  set theme=($root)/boot/grub/themes/diag/theme.txt
  export theme
else
  set menu_color_normal=white/black
  set menu_color_highlight=black/cyan
fi

menuentry "Start the toolkit" {
    linux  /live/vmlinuz boot=live union=overlay quiet loglevel=3 consoleblank=0 nvme_core.default_ps_max_latency_us=0
    initrd /live/initrd.img
}
menuentry "Start the toolkit  -  load into RAM (USB stick can be removed)" {
    linux  /live/vmlinuz boot=live union=overlay toram quiet loglevel=3 consoleblank=0 nvme_core.default_ps_max_latency_us=0
    initrd /live/initrd.img
}
menuentry "Start the toolkit  -  NVMe power saving left ON" {
    linux  /live/vmlinuz boot=live union=overlay quiet loglevel=3 consoleblank=0
    initrd /live/initrd.img
}
menuentry "Start the toolkit  -  safe graphics" {
    linux  /live/vmlinuz boot=live union=overlay nomodeset quiet loglevel=3 consoleblank=0 nvme_core.default_ps_max_latency_us=0
    initrd /live/initrd.img
}
menuentry "Start the toolkit  -  serial console" {
    linux  /live/vmlinuz boot=live union=overlay console=tty1 console=ttyS0,115200n8 loglevel=3
    initrd /live/initrd.img
}
menuentry "MemTest86+  -  full RAM test" {
    chainloader /boot/memtest86+x64.efi
}
menuentry "Reboot" { reboot }
menuentry "Shut down" { halt }
EOF

cat > "$B/grub-embed.cfg" <<'EOF'
search --set=root --file /live/vmlinuz
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

grub-mkstandalone -O x86_64-efi \
  --modules="part_gpt part_msdos fat iso9660 normal linux linux16 search search_fs_file configfile echo test all_video gfxterm gfxmenu png jpeg font bitmap bitmap_scale trig video video_fb chain reboot halt minicmd ls sleep" \
  --locales="" --fonts="" \
  -o "$I/EFI/boot/bootx64.efi" \
  "boot/grub/grub.cfg=$B/grub-embed.cfg"

# ESP image for El Torito
ESP=$B/efi.img
rm -f "$ESP"
mkfs.vfat -C -n ESP "$ESP" 4096 >/dev/null
mmd   -i "$ESP" ::/EFI ::/EFI/BOOT
mcopy -i "$ESP" "$I/EFI/boot/bootx64.efi" ::/EFI/BOOT/BOOTX64.EFI
mkdir -p "$I/boot"
cp "$ESP" "$I/boot/efi.img"

# ---------------- ISO ----------------
rm -f "$OUT"
xorriso -as mkisofs \
  -iso-level 3 -full-iso9660-filenames -volid "$VOLID" \
  -eltorito-boot isolinux/isolinux.bin \
  -eltorito-catalog isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  --eltorito-alt-boot \
  -e boot/efi.img -no-emul-boot -isohybrid-gpt-basdat \
  -o "$OUT" "$I" 2>&1 | tail -6

ls -lh "$OUT"
