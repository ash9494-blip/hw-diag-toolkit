#!/bin/bash
# Boot the built ISO in QEMU for scripted testing.
#
#   test/boot-vm.sh            # ISO as a CD, with a 24 GB virtual NVMe
#   test/boot-vm.sh usb        # ISO as a USB stick on xHCI (boot-drive tests)
#   test/boot-vm.sh touch      # CD + virtio multitouch screen
#   test/boot-vm.sh sound      # CD + Intel HDA sound card (Driver check, sound test)
#   test/boot-vm.sh sd         # CD + an SD card reader with its slot empty
#   test/boot-vm.sh full       # CD + sound + SD reader
#
# SD card:  python3 test/mc.py "change sdc /tmp/diagvm/sd.img raw"   (insert)
#           python3 test/mc.py "eject -f sdc"                         (take out)
# Switches (lid, tablet mode, headphone jack): QEMU has none - a uinput
#           daemon in the guest fakes them (see the 1.20 VM scripts).
#
# Screen: VNC on :9 (port 5909), or test/shot.sh NAME -> /tmp/diagvm/NAME.png
# Keys:   test/k.sh right ret q ...       (0.7 s apart, via the HMP monitor)
#         python3 test/fk.py 1 4          (fast, for two-digit tile numbers)
#         python3 test/type.py $'cmd\n'   (type into a shell)
# Touch:  test/qmp.py (input-send-event with type "mtt" - begin, data x/y, end;
#         do NOT pass device=, it crashes QEMU 8.2)
# Hotplug USB:  python3 test/mc.py "drive_add 0 if=none,id=s1,file=stick.img,format=raw"
#               python3 test/mc.py "device_add usb-storage,bus=xhci.0,port=2,drive=s1,id=u1"
#               python3 test/mc.py "device_del u1"
#
# TCG (no KVM) takes 100-170 s to reach the menu; boot from USB is slower and
# "run from RAM" adds another minute. Sample screenshots over a window - many
# "it's broken" conclusions were a screenshot taken too early.
set -e
B=$(cd "$(dirname "$0")/.." && pwd)
V=/tmp/diagvm; mkdir -p $V
ISO=$B/hw-diagnostic-toolkit.iso
[ -f $V/nvme.qcow2 ] || qemu-img create -f qcow2 $V/nvme.qcow2 24G >/dev/null
for p in $(ps -eo pid,args | awk '/[q]emu-system-x86_64/ && /diagvm/ {print $1}'); do kill -9 $p; done
rm -f $V/mon $V/qmp
KVM=""; [ -w /dev/kvm ] && KVM="-enable-kvm -cpu host"
case "${1:-cd}" in
  usb)   BOOT="-drive if=none,id=boot,file=$ISO,format=raw,snapshot=on -device usb-storage,bus=xhci.0,drive=boot,bootindex=0,id=bootstick" ;;
  *)     BOOT="-cdrom $ISO -boot d" ;;
esac
EXTRA=""
SOUND="-audiodev none,id=snd0 -device intel-hda,id=hda -device hda-duplex,audiodev=snd0"
SD="-device sdhci-pci -drive if=none,id=sdc -device sd-card,drive=sdc"
case "${1:-}" in
  touch) EXTRA="-device virtio-multitouch-pci,id=ts" ;;
  sound) EXTRA=$SOUND ;;
  sd)    EXTRA=$SD ;;
  full)  EXTRA="$SOUND $SD" ;;
esac
# setsid: survives the calling shell timing out; nohup alone does not
setsid --fork qemu-system-x86_64 $KVM -m 3072 -smp 2 -vga std -display none -vnc :9 \
  -monitor unix:$V/mon,server,nowait -qmp unix:$V/qmp,server,nowait \
  -device qemu-xhci,id=xhci $BOOT \
  -drive file=$V/nvme.qcow2,if=none,id=nvm -device nvme,serial=DEMO0001,drive=nvm \
  $EXTRA -device virtio-rng-pci > $V/qemu.log 2>&1 < /dev/null
echo "VM starting (VNC :9). Give it ~2-3 minutes."
