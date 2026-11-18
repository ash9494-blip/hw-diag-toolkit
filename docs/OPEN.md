# Open items - what still needs a real machine

Newest version first. Most of it was verified only in the VM, in WSL on loop
drives, or rendered offscreen. Remove an item once Ash confirms it on the
bench; items marked **(ask Ash)** are old enough that he may already have.

## 1.28 BIOS update (UEFI VM only)

OVMF dressed as an X30L-M on 2.00 via -smbios; Dynabook's flasher started
there and refused ("Unable to detect BIOS communication service channel").
1.28.1: the X30L-K's ChgFirmA.efi (Ash's B860 package, VM only - OVMF
answered its UpdateCapsule "Unsupported").

- First real flash: Ash, on a bench X30L-M that is not a customer's; a real
  X30L-K is the first chance to see ChgFirmA's own capsule restart.
- Ash's DIAGDATA: Ventoy holds it, so it is probably his Ventoy partition,
  exFAT, which the firmware cannot read (the toolkit then says so). Ways out:
  a FAT32 DIAGDATA in Ventoy's reserved space, or a second stick labelled
  DIAGDATA.
- The X30L-M's DMI product name (does "X30L-M" match as a word?) and BIOS
  version format.
- Does Dynabook's firmware keep the way-back entry and honour BootNext across
  its capsule restart? (Else Ash starts the stick with F12 - the result page
  still comes.) Does the flasher ask Y/N when started this way?
- Settings after the flash (Ash: Secure Boot stayed off with the "`" key
  method).
- **(ask Ash)** 1.28 shreds 1.26's OneDrive sign-in from the stick at start
  (settings.log says so); Ash to delete the app registration in Entra.

## 1.27 (offscreen + VM only)

- Does the pointer feel smooth on a real touchpad and mouse now that the
  framebuffer is written with write() (QEMU's display cannot show the 50 ms
  it used to wait)?
- The CPU a 60 fps animation costs on the slowest bench machine at 1080p
  (WSL: 13-32 ms to draw a frame + 11-27 ms to convert it - frames are
  dropped, not slowed).
- The Full run / Run them all pause on a real keyboard.

## 1.26.1 (VM only)

- Settings -> Date and time and the boot watcher on a laptop with a flat CMOS
  cell.
- DIAGDATA read through Ventoy's hold on Ash's own stick (the VM faked the
  hold with a dm device).

## Disk imaging (1.21 - 1.25)

WSL loop drives, offscreen renders, the renderer driven over its FIFO, and the
VM (two USB drives hot-plugged into open Clone lists, C: shrunk + a new DATA
made with E on the plan screen, the clone read back PASS and checked from
outside, the bar amber while the target was throttled and moving again
after). Still to see on real hardware:

- A cloned Windows actually booting (GPT and MBR); a clone with sizes set by
  hand - C: shrunk, WinRE grown, a new D: - booting Windows; a C: moved in the
  partition editor booting Windows.
- A real USB drive plugged in while a drive list is open, and a slow card
  reader (does the list settle, or flicker as the size arrives).
- The partition editor and the plan screen's E editor dragged on a real
  touchpad (click and hold) and touchscreen.
- The Flow bar's CPU on the slowest bench machine during a compressed backup,
  and whether it freezes amber on a drive that really stalls.
- BitLocker unlock with a real recovery key (cryptsetup BITLK - never run
  against a real volume), the Key ID shown.
- A Ventoy stick as the image store; a real Clonezilla restoring a toolkit
  image.
- Browse: a real customer image (large NTFS, a hibernated or dirty C: - ntfs3
  then ntfs-3g read-only), a BitLocker partition saved locked and unlocked at
  browse time, copying to a second USB drive.
- Macrium (1.23): restore one of Ash's real Reflect 8 images onto a real
  laptop and boot Windows from it; Browse a real customer image. What is not
  supported: `docs/imaging-notes.md`.

## 1.24 fan and GPU (VM only: QEMU's VGA, fake sensors via `DIAG_HWMON_ROOT`)

- GPU: a laptop with a discrete GPU (Optimus / hybrid) - does waking it
  through power/control bring it out of D3cold, do its link lanes and AER
  counters read, and does a known-bad board show it.
- Fan: which bench models report a speed at all (hwmon fan*_input, ACPI
  `fan_speed_rpm`, Toshiba's `TOS*/fan` switch) - `sensors` on each.

## 1.22 (VM only)

The pointer and frame-rate checks are covered by 1.27 above.

- A failed peripheral test fetching real firmware online (VM proved only a
  driver started from the stick: the e1000 unbound, then the Ethernet test
  fixed it and passed on re-run).
- The battery log on Ash's Ventoy stick (written through Ventoy's mapping,
  found again after the laptop dies) - VM tested only the "No USB stick"
  warning with a fake BAT0 (`DIAG_PS_ROOT`).

## 1.21 Linux 7.0 and the rest (VM only)

- Every model needs a pass on the new kernel - screen (simpledrm, invariant
  1), sound with gpu_bind=0, touchpad, Wi-Fi. First the PORTEGE Z40L-P: does
  its Wi-Fi now come up (iwlmld + iwlwifi-sc-a0-wh-b0-c10x), its touchpad
  (THC), its sound (SOF for Panther Lake may need newer firmware than noble
  ships)?
- First boot in the VM once stopped in initramfs ("mounting /run on /root/run
  failed", also /sys, /proc) under heavy host I/O; a reset booted. Not seen in
  other boots. If it shows on a real stick, look at live-boot's medium wait
  (dmesg at that prompt).
- Languages: machine translations (Haiku, from the brief and glossary in the
  1.21 session) - ask a native speaker of each to look through the screens.
  Long translations may clip on tight screens at 150 %.
- More info page: PCIe ports/slots counts, Wi-Fi standard from `iw phy`,
  permanent MAC via `ethtool -P` (QEMU: no PCIe, no Wi-Fi).

## 1.20.1 settings on Ash's real Ventoy stick **(ask Ash)**

VM-tested only with a DIAGDATA stick (kept, restored after reboot, cleared by
Reset) and a dd-written stick (honest "read-only image" message). Writing
through Ventoy's dm copy of its partition (1.1.01+) has never run - ask Ash
which message the theme change shows, and for `/run/diag/settings.log`.

## 1.20 **(ask Ash)** (VM-tested with fakes only)

- Wi-Fi per-antenna signal and retries on the AX201: does iwlwifi put chains
  in `iw station dump`?
- The SD reader on a Realtek rtsx slot (bus mode from debugfs).
- The lid and tablet switches on a Dynabook.
- The headphone jack on SOF (the A40-J) - does the switch report, and does
  sound move to the headphones without PulseAudio?
- The PROCHOT MSR read.
- The error log's rules against a real faulty machine.
- The anime themes (mecha, kawaii) on a real panel: VM-checked at 1280x800,
  the rest rendered offscreen at 1024x768-1920x1080 and 150 % text.

## 1.15 **(ask Ash)**

A40-J sound with gpu_bind=0 (and the legacy-HDA fallback, never exercised);
controller-check wake timing (QEMU NVMe has no APST); Charging test on a real
charger, DC jack and USB-C/UCSI (VM-tested only with `test_power`).

## Older **(ask Ash)**

- Wi-Fi on the real AX201 (`wlo1`): 1.11 scanning works on the A40-J
  (attempt 1 timed out, attempt 2 found 26 APs). 1.12 fixes the "no address"
  failure (dhclient `-timeout` bug); joining is not yet re-verified on the
  real card. Ask Ash for the Toolkit log "wireless connections" section.
- Touchpad on the TECRA A40-J reported "not found". Drivers are all in the
  image; 1.12's driver search will say whether the firmware lists it,
  disables it, or it is silent on I2C. Get that screen / log from Ash.
- Never verified on real hardware: touchscreen test, USB-C/PD reporting
  (needs UCSI), PCIe gen readout, two-finger right-click, run-from-RAM on a
  real stick, install simulation, screen test. (Drive self-test: confirmed OK
  by Ash.)

## Small known issues

- Two-digit tile numbers wait only 0.7 s for the second digit
  (`_pick_number`).
- Stress test elapsed display lags the progress bar (cosmetic).

## Not built yet

- WinPE companion ISO for SetDmiAll **(ask Ash: is the Windows ADK + WinPE
  add-on installed, still wanted?)**: it must take the path to Ash's own
  extracted SetDmiAll folder; TVALZ.sys needs Secure Boot off.
- Ideas raised but not built: keyboard LED test, Bluetooth scan, Windows 11
  readiness (TPM), idle gaps inside the install simulation. (Fan RPM: built
  in 1.24.)
