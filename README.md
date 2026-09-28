# Hardware Diagnostic Toolkit

Bootable USB/ISO for laptop bench testing: HDD/SSD (SMART, benchmark, install
simulation, surface scan), CPU stress with temperatures, RAM stress +
MemTest86+, battery drain, keyboard, touchpad, touchscreen, sound, USB ports,
camera, Ethernet, Wi-Fi, DMI capture, and a saved per-machine report.

```bash
sudo ./setup-host.sh      # Ubuntu 24.04 / WSL2, once
sudo ./build-all.sh       # -> hw-diagnostic-toolkit.iso
test/boot-vm.sh           # try it in QEMU (VNC :9)
```

Start with **CLAUDE.md** — layout, invariants, traps, open items.
History: `docs/HISTORY.md`.
