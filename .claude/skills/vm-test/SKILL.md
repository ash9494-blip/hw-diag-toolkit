---
name: vm-test
description: Boot the built Hardware Diagnostic Toolkit ISO in QEMU and drive it - keys, screenshots, pointer, touch, USB hot-plug, fake Wi-Fi / camera / SD / switches. Use after every change to toolkit/ to see it on screen, and before delivering a version.
---

# Boot-testing the ISO in QEMU

`test/boot-vm.sh` documents every mode and helper in its header - read it
first. The short version:

```bash
test/boot-vm.sh          # or: usb (virtual stick), touch, sound, sd, full
# wait 2-3 min (TCG: 100-170 s) - the first screen is the Language menu
# (every boot): Enter
test/k.sh ret
test/shot.sh home        # -> /tmp/diagvm/home.png (look at it)
test/k.sh 7 ret          # keys: digits, arrows, ret, q, esc ...
python3 test/fk.py 1 4   # fast keys, for two-digit tile numbers (0.7 s window)
```

Sample screenshots over a window: many "it's broken" conclusions were a
screenshot taken too early. After a change, always boot it and look.

## Fakes for hardware QEMU lacks

- Wi-Fi: in the Command prompt tile, `modprobe mac80211_hwsim radios=2`, then
  run `wpa_supplicant` on wlan1 with `mode=2` (AP) - wlan0 can scan and see it.
- Camera: `modprobe vivid`.
- SD card: `python3 test/mc.py "change sdc /tmp/diagvm/sd.img raw"` / `"eject -f sdc"`.
- Charger: the `test_power` module (gone after every restart). Lid, tablet
  mode, headphone jack: a uinput daemon in the guest. Tests that need the
  operator write a step file (`charge.step`, `lid.step`, `sound.step` in
  `$RUN_DIR`) so the guest script fakes the hardware in step with the test.
- Fan / GPU sensors: `DIAG_HWMON_ROOT`; battery: `DIAG_PS_ROOT`.
- Clock: QEMU's RTC is UTC - test with `-rtc base=localtime`, as a Windows
  laptop keeps it.
- Slow target drive: HMP `block_set_io_throttle`.

## Traps in the harness

- `pkill -f qemu...` kills your own shell: kill by pid (boot-vm.sh does).
- The active mouse is the absolute vmmouse: HMP `mouse_move` does nothing
  visible; drive the pointer with QMP `input-send-event` type `abs`
  (`test/qmp.py`, `test/drag.py`). Touch: type `mtt`, never pass `device=`
  (crashes QEMU 8.2).
- **Esc / right-click on the home grid opens the power menu, where "1" =
  Reboot** - scripted key sequences have rebooted the VM into MemTest86+
  twice.
- `test/type.py` drops letters on a busy VM - type a confirmation (ERASE,
  UPDATE, SHRINK) slowly, one key at a time.
- UEFI tests (OVMF): see the `bios-update` skill - El Torito, bootindex and
  BootOrder behave differently there.

## What QEMU cannot show

Graphics-driver faults (invariant 1 - the C40-K froze on real hardware only),
real radio, touchpad, battery, charger, lid, the 50 ms framebuffer delay of a
real DRM fbdev. When something is only VM-verified, say so, and add it to
`docs/OPEN.md`.
