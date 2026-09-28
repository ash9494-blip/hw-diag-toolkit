# Version history

Newest first. Each entry says what changed and why; the "why" is usually a
real machine on Ash's bench.

## 1.11.0 — 2026-09-25
- **Run from RAM** boot entry (`toram`, BIOS "run from RAM" / UEFI "load into
  RAM (USB stick can be removed)"). Copies the ~390 MB squashfs into RAM; the
  stick can then be pulled. VM-verified: stick pulled mid-session, RAM stress
  test still passed.
- **Wi-Fi scan** shared as `wifi_scan_tsv` in lib.sh (Wi-Fi page + wireless
  test): waits for link-up, 25 s limit per attempt, 3 attempts with progress on
  screen, `iw scan dump` fallback, plain-language error instead of hanging,
  log in Power menu → Toolkit log. Long menus scroll; network list capped at 20.
  Trigger: AX201 (`wlo1`) stuck on "Scanning" though a manual `iw scan` worked.
- **USB test** shows devices present at the start (boot stick included) as
  "present at start (not counted)"; boot stick labelled DO NOT unplug, or safe
  to unplug in RAM mode; rows stay visible as "empty - unplugged" after removal.
- Fixed: Command prompt `exit` didn't return to the menu when a daemon had
  inherited menu.sh's lock fd. Fixed: RAM test subtracted Shmem twice.

## 1.10.0 — 2026-09-24
- USB test: device name, "USB 3.0 - 5 Gbit/s - storage" style headline,
  keyboard/mouse by HID boot protocol, live slot status on unplug, USB2/USB3
  peer ports merged into one socket, USB 3 device held at USB 2 speed flagged,
  USB-C power role / PD revision / live charger watts via UCSI.
- New **touchscreen test** (Peripherals): 3 s hands-off ghost-touch check,
  full-screen coverage grid, multi-touch count; dead patches judged at ≥80 %.
  Touchscreens (INPUT_PROP_DIRECT) no longer grabbed by the touchpad test.
- SMART page: `NVMe - PCIe 4.0 x4 (16 GT/s)` with drive vs slot capability,
  warns on a link below both ends or missing lanes (read while the drive is
  busy to avoid idle downshift); SATA version for SATA drives.
- Fixed: Full run never benchmarked any drive (`lsblk` RM padding). Renderer
  no longer paints half-built frames (USB list flicker).

## 1.9.0 — 2026-09-21
- System settings: colour theme (light/dark/high contrast), text size
  (100–200 %), opening menu, default wireless length, default disk size,
  save settings to stick, about, reset.
- Root cause of the "values column still tiny": the image shipped no monospace
  font, so PIL used its 11 px bitmap. DejaVu Sans Mono added; build asserts fonts.

## 1.8.0
- Wireless test length picker (1 min … 1 day); "Network" renamed "Ethernet
  Network"; report viewer at 200 %; Command prompt tile.

## 1.7.0
- Wi-Fi connect page on the home screen, reused by Get firmware and the
  wireless test; Get firmware works like Windows Update (finds hardware lacking
  firmware and fetches it); Install sim removed from "Show all"; USB test counts
  only sockets that saw a device; Ash's icon set.
- Regression caught: icon rework deleted the KDSETMODE constants → text UI.
  Build now smoke-tests the renderer.

## 1.6.0 — 2026-09-17
- Mouse tile removed; Install sim moved into HDD/SSD; filesystem benchmark
  removed; SMART shows controller + firmware; clickpad right-click (two-finger
  click/tap); Get firmware fixed (installsim was running `dmesg -C`); USB-A/C
  labels; wireless stability test; smoother logo.
- The cloud build container was lost once; `bootstrap.sh`/`trim.sh` were
  reconstructed. `trim.sh` now keeps the module tree whole and removes only
  GPU drivers, zfs, firmware and docs; `restore_modules.sh` is retired.

## 1.5.0 — 2026-09-17
- **Install simulation** (`installsim.sh`): 32–96 GB continuous write in
  256 MB chunks, per-chunk timing shows the SLC cliff, serial-stamped chunks
  read back byte-for-byte, PCIe AER/link, NVMe error log and the drive's own
  thermal timers before/after, event timeline, ranked verdict (PCIe → thermal
  → controller firmware → flash → undetermined).
- "NVMe power saving left ON" boot entry (no APST workaround).
- SMART wear section (TB written, full-drive writes, projected life).

## Background: the C40-K NVMe case
SATELLITE PRO C40-K, Samsung PM991 MZVLQ512HBLU (DRAM-less, HMB). Every disk
test passed, but Windows 11 setup failed with 0x800701B1
(ERROR_NO_SUCH_DEVICE). 48 GB and 96 GB install simulations with APST on
cleared SLC exhaustion, sleep/wake, PCIe link (x4 @ 8 GT/s, zero AER) and
silent corruption (144 GB verified). Thermal unproven (82 °C peak, thermal
timers +0). Attention moved to the USB install media, since the error never
said *which* device vanished.

## 1.4.x
- 1.4.0 froze a real C40-K: a module restore put i915 back. Led to the
  no-GPU-driver invariant and the build-time abort. 1.4.1 tried `nomodeset` on
  all entries — striped screen; reverted.
