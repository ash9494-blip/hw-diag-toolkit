# Version history

Newest first. Each entry says what changed and why; the "why" is usually a
real machine on Ash's bench.

## 1.19.0 — 2026-10-07
Released as 1.19.0 at Ash's request ("deploy v1.19 with all the fixes");
the charging fixes below were built and VM-tested as 1.18.1 first.

- **Charging test: "Charger: connected" after the charger was unplugged**
  (TECRA A40-J, Ash's photos). The test counted a charger as connected if
  *any* charger flag was on, and a USB-C port's flag is only the UCSI
  driver's memory of the last event the port sent - on the A40-J it stayed
  on. The unplug step timed out, and the USB-C step waited forever for an
  unplug. Now the firmware's AC flag decides (re-read from the firmware on
  every look); USB-C flags count only on machines without one. The battery
  is a second witness: discharging for 5 s after the unplug, or charging
  while no flag says so, means a flag is wrong - reported as a WARN, and the
  rest of the test goes by the battery.
- **USB-C step**: in and out are judged as above, never by the port. The port
  the charger went into is the one that reports something *new*; when none
  does, the try still counts as "USB-C try N (the machine did not say which
  port)". The step now shows the live charger, battery and power figures.
- **Every charger flag on screen** ("Charger flags: ADP1 off, USB-C 1 on"),
  and in the report at the unplug and at the end - the evidence for the next
  machine that disagrees.
- **The animation never shows its example figures live**: the A40-J's USB-C
  step showed "62 % not charging" - the example's number, as the step sent
  no battery figure. No figure is now drawn as "no reading". The charger's
  wattage is what a USB-C charger offers, or none (was always "65 W"), and a
  USB-C charger is drawn as a USB-C plug in steps 1-4 too.

## 1.18.0 — 2026-10-02
- **Animations for the RAM, CPU, battery, charging, USB, Wi-Fi and
  Ethernet tests** (Ash: "design animation for RAM, CPU test, Battery Test,
  Charging Test, USB test, Wifi test, Ethernet test as well"). New module
  `hwanim.py`, the same frame and tools as the drive set. One diagram per
  test:
  - RAM: the memory controller, the bus and two SO-DIMMs, with the part
    Linux holds hatched.
  - CPU: the die, cold plate, heat pipe, fins and fan.
  - Battery: the charge path and the cells.
  - Charging: the DC jack and the firmware's "charger connected" flag.
  - USB: a USB 3 socket's two rows of contacts.
  - Wi-Fi: the antenna leads up the lid.
  - Ethernet: a cable's four twisted pairs.
- **They play while each test runs, drawn from the test's own figures:**
  - The CPU's real temperature colours the die and fills the thermometer.
  - The charge level fills the cells.
  - A dropped charger connection sparks at the jack and shows in a
    4-times-a-second strip.
  - The sockets drawn are the ones the USB test lists, and a held-back
    socket's SuperSpeed contacts go red.
  - The negotiated speed lights 4 or 2 of the cable's pairs.
  - The signal bars follow the real dBm.

  Nothing shows a fault the test has not found.
- **The operator's instruction stays on screen.** The test's first plain
  line ("Unplug the charger", "Plug a live network cable in") is shown in
  bold under the title, and the scene acts it out (the plug moving in or
  out).
- **Lower frame rate where the animation would skew a reading:** 1 frame/s
  in the battery drain (a smooth picture costs the pack being measured), 2
  in the CPU idle baseline.
- **"How this test works" entries** in the RAM, CPU and Battery menus; Left
  / Right moves through all seven. The text interface shows the captions.
- **Shared engine.** The drive animations' frame, primitives, player and
  live mode are now shared (`ssdanim.Canvas`, a kit argument). Their frames
  were checked pixel-identical before and after. ui.py routes a scene to
  its set and runs each animation at its own frame rate. The build renders
  every new step in all three themes, three more screen sizes, and live
  with ordinary and worst-case figures.

## 1.17.0 — 2026-10-01
- **The animations play while the tests run** (Ash: "i want the animation
  show when the test is running"). Controller check (load, rest, burst,
  wake-up), Benchmark (each profile, then the write passes), Install
  simulation (cache filling, past the cliff, read-back), Surface scan and
  Drive self-test each start the matching scene and steps, which loop for
  as long as that phase lasts. Nothing on screen is invented: the title,
  the side panel ("THIS DRIVE, NOW") and the progress strip carry the
  test's own lines - its kv rows, alerts, results table and progress bar -
  and a LIVE tag says the moving parts are a picture. The DRAM chip is
  drawn as the drive really has it. ui.py: `animlive scene first last dram`
  and `animstop`; any question or result screen ends it; a failing frame
  falls back to the usual screen. tui.sh: tui_anim_live / tui_anim_stop
  (no-ops in text mode). The build check renders every live step too.
- fix: `waitkey 0` never polled the keyboard, so Q could not stop the
  install simulation, benchmark passes or heavy controller slices.
- fix: Heavy mode blamed cooling for any slowdown; now only when the drive
  actually got hot (throttle counters, within 5 C of its warning limit, or
  +20 C over the run). A slowdown without heat gets its own warning.

## 1.16.1 — 2026-10-01
- **Battery test: S and Q did nothing** (Ash: pack stuck at 98%, could not
  start or leave the test). Steps 1 and 2 read keys from stdin, but the
  renderer owns the keyboard; they now use its waitkey like every other
  test (the read-only benchmark's Q had the same fault - fixed too). When
  the charge has not risen for 10 minutes at 90% or more, step 1 says
  charging has stopped and S starts from there; the report notes the
  stall ("a worn pack, or a charge limit").
- **Controller check - Heavy mode** (Ash: a drive throttled at 83 C - is
  the controller faulty?). Ten minutes of full load (4 KB random 32x4 +
  128 KB sequential 16x2 reads, still read only) in 10 s slices tracking
  speed and temperature, then two minutes' rest and one more burst. Slows
  when hot but recovers = controller protecting itself, the cooling is the
  fault; errors, resets, <20% of start for a minute, or <70% after resting
  = fails under load. The result says which in words; the report has a
  per-minute speed/temperature table. Standard mode now points to Heavy
  when it sees throttling.

## 1.16.0 — 2026-10-01
- **How these tests work** (HDD / SSD menu, item 8, after the tests so their
  numbers do not move). Ash asked to see what each drive test looks like from
  inside the SSD. Six animations, one per test in menu order - SMART health,
  Controller check, Benchmark, Install simulation, Surface read scan, Drive
  self-test - drawn by the renderer itself (`ssdanim.py`, imported only when
  opened). One robot per flash channel carries data blocks between the
  controller and its chip: all four fetch together for SEQ1M Q8, one at a time
  for Q1; they fill the SLC cache and then have to shuttle it into TLC while
  new data arrives (the install-simulation cliff); the surface scan sends them
  to scattered shelves and one comes back broken; in the self-test they check
  every shelf with the bus quiet; in the controller check they sprint under
  128 queued reads, then fall asleep in APST and the wake-up is timed.
  Captions follow the scripts (fio profiles, 256 MB stamped chunks,
  badblocks, NVMe self-test segments, ctrltest.sh's load / watch / wake /
  verdict). Every figure is labelled "illustration - not this drive".
  Left/Right switch animation, Space pauses, Enter skips a step, Esc returns.
  The text interface shows the captions instead (`ssdanim.py --text`).
- Rendered labels are cached as masks: FreeType was three quarters of every
  frame. About 11 ms a frame at 1280x800 and 17 ms at 1920x1080 on the build
  host, against a 15 fps target; the animation keeps time by the clock, so a
  slower machine drops frames rather than playing slow.
- The build copies every toolkit `*.py` and renders every step of every
  animation in all three themes (`ssdanim.py --check`); a failure aborts it.
- Only checked in the renderer with a file-backed framebuffer, not yet booted
  in QEMU or seen on real hardware.

## 1.15.0 — 2026-10-01
- **A40-J sound: the cause, and the fix.** Ash's Driver check photo showed
  the sound controller with no driver: "deferred probe pending:
  sof-audio-pci-intel-tgl: init of i915 and HDMI codec failed". Intel sound
  (SOF and HD Audio, 6th gen on) waits for the i915 graphics driver to drive
  HDMI audio; the image has no i915 on purpose, so it waited forever and no
  sound card existed. `options snd_hda_core gpu_bind=0` in
  /etc/modprobe.d/diag-audio.conf tells it not to wait (speakers, headphones,
  mics work; HDMI audio cannot without i915 anyway). The build asserts it.
- **Driver check fixes, not just reports.** Choosing a failed device shows
  what is wrong and offers Fix, which tries in order: faults recognised by
  their kernel message (the graphics wait above, fixed at runtime), restarting
  the driver, fetching what it is missing online (firmware from the Ubuntu
  archive), and for Intel sound the older HD Audio driver
  (`snd_intel_dspcfg dsp_driver=1`). The device is re-checked after each step;
  the first that works ends it; every step goes into the report. "Fix
  everything" does this for all failed devices with one download session.
  Devices waiting on another driver now say what they wait for
  (`devices_deferred` / the "deferred probe pending" log line).
- **SSD controller check** (HDD / SSD menu, read only): names the controller
  chip (PCI ID + pci.ids), DRAM or DRAM-less and whether it got its host
  memory buffer, then a minute of 4 KB random reads (QD32 x 4, fio
  --readonly) while watching temperature, thermal-throttle counters, PCIe link
  speed/width, AER retries, the NVMe error log, media errors and kernel
  resets/time-outs; then idle gaps of 1-8 s and the next read timed, to catch
  controllers slow to wake from APST (the C40-K PM991 class). SATA SSDs get the
  load plus their CRC / time-out / uncorrectable counters.
- **Charging test** (Peripherals, Every test): unplug and plug-in detection,
  one minute of charge rate (W, judged against the pack's capacity below
  80 %), a 30 s wiggle check counting every connection drop (4 Hz polling plus
  kernel power events), and each USB-C port that can charge (only counted if
  a charger was plugged into it). Charge limits are read, never changed.
- `pcie_gen`/`pcie_link` moved from disktest.sh to lib.sh (shared).

## 1.14.0 — 2026-09-30
- **Driver check** (home screen tile 10; replaces Get firmware in Peripherals
  and Every test; part of Full run). Trigger: the A40-J's touchpad and sound
  both failed with their drivers attached, and Ash needs this to work on many
  models. Every PCI, USB and I2C device, plus touch devices the firmware lists
  on I2C, is judged on two questions: is a driver attached, and did it make
  what it should (sound card, network interface, input device, camera,
  Bluetooth adapter). States: working / started now / firmware missing / not
  working / no driver attached / turned off / no Linux driver / not needed /
  graphics (off on purpose). Devices with no driver get the one on the stick
  loaded and bound. Per-device details show the driver's own kernel errors.
  **Download fixes** fetches the firmware packages from the Ubuntu archive
  (kept on the stick for the next machine), restarts the affected drivers and
  checks again; **Remove downloaded files** takes exactly those files away.
  All of it lives in RAM; nothing is written to the machine being tested.
- Checked before building it: the image already carries every kernel driver
  Ubuntu ships for this kernel (6,465; linux-modules + -extra), minus the
  graphics drivers. So the downloadable part is firmware. A device Linux 6.8
  has no driver for is reported as such (a newer kernel is the only cure).
- Bundled Wi-Fi firmware now covers MediaTek, Broadcom and Qualcomm ath11k/12k
  as well as Intel and Realtek - Wi-Fi is how everything else gets downloaded.
- Sound: `alsa-ucm-conf` added (the A40-J image had no ALSA use-case
  profiles; SOF cards start with speaker/headphone paths off without them),
  and the sound test applies the card's profile before playing.
- The whole boot kernel log is kept (`boot-dmesg.log`), not just firmware lines.
- `pciutils` added so devices show real names.

## 1.13.1 — 2026-09-30
- **Machine details tile removed** (home and Every test). It could only
  override the report, never the machine's own details (invariant 4), which
  is not what Ash needed from it. DMI capture remains for board swaps.
- Home order: Show all tests right after Peripherals; System second last,
  Settings last (same ending in Every test).
- **Every test tidied.** Trigger: photo from the A40-J - 23 tests in six rows
  of 4 small squares, names cut short ("Keybo...", "Comm..."), some names
  large and bold and others small, two-line names spilling out of the box.
  The sheet now picks the column count that gives the biggest parts where
  every name fits (6 across at 1920x1080), uses one font size for every
  part, and anchors the names to the bottom of the part with the icons in
  line above. The parts list steps its text down when the rows get tight.

## 1.13.0 — 2026-09-29
- **Mouse.** A pointer driven by a USB mouse, the touchpad or the
  touchscreen. Left click / tap selects tiles, menu rows and YES / NO;
  right click or a two-finger tap goes back (like Esc); wheel or two-finger
  drag scrolls. Hovering highlights. Devices are read un-grabbed, so the
  touchpad/mouse tests still grab theirs; the pointer is switched off during
  full-screen tests (on the black screen-test page it would pass for a stuck
  pixel). A scrolled list's window now only moves when the selection leaves
  it, so it no longer slides under the pointer. Password entry ignores it.
- **Header status:** clock (HH:MM over the date) and a Wi-Fi icon - signal
  bars when online, amber when joined without an address, grey when not
  connected, struck through when off or no adapter. Read from sysfs/procfs
  every 3 s, redrawn while menus wait. Click the icon (or press W) in any
  menu to open the Wi-Fi page; the same menu comes back afterwards.
- `/etc/adjtime` = LOCAL: the hardware clock on these (Windows) machines is
  local time. Without it the clock read 8 h ahead, and after an NTP sync the
  kernel would have written UTC into the customer's RTC.
- **Service-manual look for the home grid and menus** (Ash chose it from
  preview renders over "Bench Mat"; Settings -> Menu style switches back to
  the classic tiles). A drawing frame with zone markers; a title block with
  the machine (model over CPU and RAM - kept at Ash's request, the memory
  figure is never the part shortened), revision, date, time and Wi-Fi; each
  test a line-art part with a numbered balloon; a parts list showing every
  test's result this session ("PASS 14:02") from summary.kv via
  `test_result`; menus as tables. The theme accent is the only selection
  colour, so light, dark and high contrast all work. Test screens unchanged.
- Absolute mice (USB tablets, KVMs, VMware/QEMU vmmouse) move the pointer.
- Includes 1.12.1 (the Command prompt fix), which was never shipped alone.

## 1.12.1 — 2026-09-29
- **Command prompt had no prompt.** On the A40-J it showed no `diag:` prompt,
  echoed arrow keys as `^[[A` and printed no errors. Cause, since 1.11: lib.sh
  closed fd 8 with `exec 8>&- 2>/dev/null`; a bare exec makes the stderr
  redirect permanent, so every script ran with stderr in /dev/null and the
  shell decided it was not interactive. Now `exec 8>&-` only, and both shell
  entries start `bash -i` with stderr on the terminal. (It also means error
  messages from every script are visible again.)
- Touchpad driver search logs the input-device list and HID driver bindings,
  and the whole search goes into the report. A40-J result so far: "every
  touch device has its driver, none is a touchpad" - the pad is attached but
  not recognised; waiting on that log to fix the classification.
- NVMe self-test confirmed working on real hardware (Ash).

## 1.12.0 — 2026-09-29
- **Wi-Fi now gets an address.** Trigger: TECRA A40-J (AX201) joined but
  "DHCP gave no address" every time. Root cause: `dhclient -timeout` is a
  Fedora-only option; Ubuntu's dhclient answers "Unknown command" and exits,
  and `2>/dev/null` hid it. Joining moved to `wifi_join` in lib.sh: waits for
  wpa_supplicant's COMPLETED state (not `iw link`, which shows the SSID before
  the WPA handshake), recognises a wrong password, runs DHCP with a hard
  limit and a retry, then `udhcpc` as a backup client. Every step goes to the
  Toolkit log ("wireless connections"). Password length is checked up front;
  the SSID goes to wpa_supplicant as hex, so quotes/non-ASCII names work.
- Scan reads the real security from the AKM suites: WPA2, WPA3, WPA2/3,
  Enterprise (refused with a clear message), OWE, WEP, open. `\x00...` SSIDs
  count as hidden; escaped UTF-8 names display properly.
- **Menus with columns.** Entries may carry several `|` cells; the renderer
  aligns them. Row height comes from the font, so the highlight can no longer
  slice the selected row; long lists scroll with an "11-22 of 26" counter.
  Wi-Fi list: name | dBm + quality word | band | security. Wireless test scan
  uses a real table. Toolkit log shows `|` instead of raw TABs.
- **Screen test** (Peripherals, tile "Screen"): black, white, R, G, B, grey,
  dark grey, grey ramp, full screen with a fading hint; operator records dead
  / stuck pixels, lines, blotches, bleed, banding.
- **Drive self-test** (HDD / SSD menu): NVMe Device Self-test (and SATA) via
  smartctl, short or extended (drive's own EDSTT estimate), live progress,
  Q aborts, result decoded per the NVMe spec; checks OACS for support.
- **Touchpad not found** now searches instead of giving up. Checked the 1.11
  image: every touchpad driver (i2c-hid-acpi, hid-multitouch, intel-lpss,
  pinctrl-tigerlake, psmouse, elan_i2c, rmi4) is already there, so nothing
  can be "downloaded like Windows". The test loads the chain, binds loose
  PNP0C50 devices by hand, and explains what it found (not listed → BIOS /
  Fn key / cable; disabled by firmware; listed but silent on I2C). Build
  aborts if any link of that chain goes missing.
- Removed the unused second copy of the connect code from wifitest.sh.

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
