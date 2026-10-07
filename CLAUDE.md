# Hardware Diagnostic Toolkit — project brief for Claude Code

Bootable USB/ISO for bench-testing laptops at Data Dynamics (Johor). Owner: Ash
(Senior IT Engineer; laptop repair bench, mostly Dynabook/Toshiba). Boots a
minimal Ubuntu live system straight into a full-screen tile menu of hardware
tests, and writes a per-machine report to the USB stick.

**Current version: 1.20.0** (`toolkit/lib.sh` → `DIAG_VERSION`).
Last delivered ISO: 1.20.0, SHA256 `2b386ec50d6082c43250fc09f69cb6001122e5e876752ef5e3440fab584c8f5f`.
Version history and the reasoning behind past changes: `docs/HISTORY.md`.

## Layout

```
bootstrap.sh        debootstrap noble minbase -> ./chroot, installs base packages
trim.sh             slims the chroot (GPU drivers, zfs, firmware, docs removed)
finalize_chroot.sh  installs extra packages + firmware subset, COPIES toolkit/ INTO
                    the chroot, live-boot config, autologin, renderer smoke test
build_iso.sh        squashfs + isolinux (BIOS) + GRUB standalone (UEFI) -> hybrid ISO
build-all.sh        runs the above in order and verifies the version in the squashfs
setup-host.sh       apt packages the build host needs
toolkit/            everything that ends up in /opt/diag on the image
  menu.sh           entry point (autologin on tty1/ttyS0), tile menus, dispatcher
  lib.sh            shared helpers, report writing, disk/mem helpers, Wi-Fi scan
  tui.sh            tui_* API -> FIFO -> ui.py; falls back to tui-text.sh (ANSI)
  drivers.sh        Driver check library: device scan (PCI/USB/I2C/ACPI), state
                    per device, firmware download + removal (sourced)
  drivercheck.sh    Driver check screen + per-device Fix; --quiet = scan + report
  ctrltest.sh       SSD controller check (HDD/SSD menu), read only
  ssdanim.py        "How these tests work" animations for the HDD/SSD tests
                    (imported by ui.py on demand; --check / --text / --frames),
                    and the shared engine: Canvas, frame(), play(), Live
  hwanim.py         the same for RAM, CPU, battery, charging, USB, Wi-Fi,
                    Ethernet; live, the drawing follows the test's own kv
                    figures (label text matters) and shows its first plain
                    line as the operator's instruction
  chargetest.sh     Charging test (Peripherals); writes $RUN_DIR/charge.step
  netcheck.sh       network checks shared by nettest.sh / wifitest.sh (sourced):
                    every check bound to the adapter under test, nc_cause
  errlog.sh         Hardware error log: kernel-log fault rules (--quiet in Full run)
  sdtest.sh         SD card reader; lidtest.sh lid + tablet-mode switch
  swstate.py        input switch states (lid, tablet, jacks) via EVIOCGSW
  ui.py             Pillow framebuffer renderer (/dev/fb0), all screens + the
                    interactive tests (keyboard, pointer, touchscreen, camera)
  skins.py          the anime themes (mecha, kawaii): ui.py hands header,
                    card, grid, menus, badges, bars to it when SKIN is set;
                    --check / --shots DIR (the build runs --check)
  *test.sh etc      one script per test
  icons/            Ash's 24x24 PNG icon set (alpha used as a stencil)
test/               QEMU harness: boot-vm.sh, screenshot, keystrokes, QMP touch
docs/               HISTORY.md, dmi-board-swap.md
```

## Build

Needs Linux as root with internet: Ubuntu 24.04 native, VM, or **WSL2**.
On WSL2, clone/build inside the Linux filesystem (`~/...`), **never under
`/mnt/c`** — NTFS breaks chroot permissions and squashfs is painfully slow.
`build-all.sh` refuses to run from `/mnt/<drive>`.

```bash
sudo ./setup-host.sh
sudo ./build-all.sh          # from nothing, ~20-40 min
sudo ./build-all.sh quick    # after editing toolkit/: re-finalize + ISO only
```

Output: `hw-diagnostic-toolkit.iso` (~450 MB, hybrid — `dd`/Rufus/Ventoy).
Secure Boot must be off (unsigned).

## Test

```bash
test/boot-vm.sh          # or: usb (boot from virtual stick), touch (multitouch)
# wait 2-3 min, then:
test/shot.sh home && open /tmp/diagvm/home.png
test/k.sh 7 ret          # keys: digits, arrows, ret, q, esc ...
```

`test/boot-vm.sh` documents hot-plugging USB, touch input and typing. Also:
- Wi-Fi without hardware: in the Command prompt tile,
  `modprobe mac80211_hwsim radios=2`, then run `wpa_supplicant` on wlan1 with
  `mode=2` (AP) — wlan0 can then scan and see it.
- Camera: `modprobe vivid`.
- After a change, always boot it and look. The build has a renderer smoke test,
  but most UI regressions only show on screen.

**QEMU cannot catch graphics-driver faults** (see invariant 1) and has no real
radio, touchpad or battery. Say so when something is only VM-verified.

## Invariants — do not break

1. **No KMS GPU drivers in the image** (i915, xe, amdgpu, nouveau, radeon).
   The kernel uses simpledrm/efifb on the firmware framebuffer. In 1.4.0 a
   module restore put i915 back; on a real SATELLITE PRO C40-K it seized the
   display and froze at "Detecting hardware". `build_iso.sh` aborts if any are
   present. Invisible in QEMU.
2. **Never add `nomodeset` to the default boot entries** — it also blocks the
   harmless simpledrm/bochs and gives a striped screen. Only the "safe
   graphics" entry has it.
3. **`finalize_chroot.sh` before `build_iso.sh`**, and verify the built
   squashfs, not the source (build-all.sh does this).
4. **Nothing is ever written to firmware/DMI/EEPROM.** Machine details edits
   override the report only. DMI capture writes a `dmichg.txt` for Toshiba's
   Windows tool SetDmiAll. Do not build a Linux DMI writer or reverse-engineer
   SetDmiAll/TVALZ.sys — deliberate decision, see `docs/dmi-board-swap.md`.
   Never redistribute Toshiba's SetDmiAll binaries.
5. **Destructive disk tests require typing `ERASE`**, default to NO, and are
   never part of Full run.
6. **A USB socket only counts as tested if something was plugged in during the
   test.** Devices present at the start (including the boot stick) are shown
   but not counted — otherwise the boot socket passes every run for free.
7. On normal boot entries the OS reads from the stick live — **the boot stick
   must not be pulled.** Only the "run from RAM" (`toram`) entry allows it.
8. RAM test region = (MemAvailable − 512 MB) × 75 %. Do not subtract Shmem
   again (MemAvailable already excludes tmpfs). Full coverage is MemTest86+.

## Conventions

- Bash scripts source `lib.sh` then `tui.sh`. Screens: `tui_frame`, `tui_line
  row text [tone]`, `tui_kv row label value [tone]`, `tui_badge`, `tui_flush`,
  `tui_menu` / `tui_grid` (return choice in `$TUI_CHOICE`), `tui_msg`,
  `tui_confirm`, `tui_anykey`. Tones: `""`, `muted`, `ok`, `warn`, `err`, `accent`.
  Rows 6..~20 at normal text size.
- Protocol to ui.py is one TAB-separated line per command over a FIFO — no
  TABs or newlines inside arguments. Menu entries are `label|description`.
- Input: `Keyboard.poll` also yields pointer events `click` (at `click_xy`),
  `back`, `hover`, `wheelup`/`wheeldown`. Any new widget loop must handle or
  ignore them, redraw only on change, and full-screen tests must run through
  `fullscreen()` in main (pointer off, no header refresh). `menu`/`gridmenu`
  can answer `wifi`; tui.sh handles it — don't treat it as a choice.
- Report: `rsection`, `rsilent` → `/run/diag/report.txt`; one `RESULT:` line per
  test; `set_kv KEY value` → `summary.kv`.
- Comments explain *why* (usually the bug that forced it). Keep that style.
- New tests: add to `run_test` in menu.sh and to both menu layouts (compact
  grid / peripherals submenu, and the expanded "Every test" list).
- A drive test's behaviour is also described in `ssdanim.py` (captions and
  the robots' moves), the other tests' in `hwanim.py`. Change one, change
  the other; run `python3 toolkit/ssdanim.py --check` and `hwanim.py
  --check` (need Pillow) before building. hwanim reads a test's figures by
  their kv labels ("Temperature now", "Charger", "Cable"...): renaming a
  label in a script silently stops the picture following it.
- Live animations: `tui_anim_live scene first last [fps=N]` once per phase
  (each call restarts the loop), never inside the redraw loop. A phase that
  ends without a question or result screen (Full run's AUTO mode) must call
  `tui_anim_stop`. Keep the frame rate low where drawing would skew the
  reading (battery drain fps=1, CPU idle baseline fps=2).
- Network checks go out of the adapter under test (`ping -I`, `curl
  --interface`, DNS on a socket bound with SO_BINDTODEVICE) - use
  `netcheck.sh`, never a bare `ping`/`getent`: with Wi-Fi and a cable both
  up, an unbound check tests whichever link the route picks. A fault past
  the router is the network's (`NC_SIDE=network`) and must not fail the
  laptop's port.
- Tests the operator acts on write a step file for the VM harness
  (`charge.step`, `lid.step`, `sound.step` in `$RUN_DIR`): QEMU has no
  charger, lid or jack, so a guest script fakes them (test_power, uinput)
  in step with the test.
- Target machines run mawk, not gawk: no `strtonum`, `and()`, `gensub`.
- Ioctl numbers/struct offsets: compile a C probe against `/usr/include/linux`
  headers — hand calculations were wrong several times.

## Traps already hit

- `lsblk -dno COL` right-aligns (`" 0"`) — `tr -d ' '` before comparing.
- smartctl `31,964,933 [16.3 TB]`: cut at `[` before stripping non-digits
  (else 1000× wear).
- A bash function whose last statement is a false test returns 1 — end
  report writers with `return 0`.
- Never `dmesg -C` (Get firmware reads boot-time firmware lines); use
  `dmesg_mark`/`dmesg_since`.
- `trim.sh` empties apt lists; `finalize_chroot.sh` must `apt-get update` and
  asserts the tools installed. `linux-firmware` on noble is a stub — firmware
  comes from split packages extracted with `dpkg-deb -x`.
- PIL `load_default()` is a fixed 11 px bitmap: a missing font = tiny text, no
  error. The build asserts the fonts exist.
- Framebuffer is BGRX, not RGBX.
- ui.py: `_draw_grid` gets `d` not the canvas; `KDSETMODE/KD_TEXT/KD_GRAPHICS`
  constants must stay (deleting them silently drops to the text UI).
- Daemons started by tests inherit fds: lib.sh closes fd 8 (menu's lock) so
  `wpa_supplicant` etc can't keep the lock and stop the menu restarting.
- `find -L /sys` hangs (circular symlinks) — use bounded globs.
- `pkill -f qemu...` kills your own shell; kill by pid (see boot-vm.sh).
- bash `read` with whitespace IFS collapses empty fields — use `|`.
- A bare `exec` with redirections is permanent: `exec 8>&- 2>/dev/null` in
  lib.sh silenced stderr in every script and broke the Command prompt shell
  (1.11-1.12.0). Close fds with `exec 8>&-` alone.
- Device-name matching must use word starts: "alps" matched QEMU's
  "VirtuALPS/2 VMware VMMouse" and made the mouse a "touchpad" (pointer dead,
  touchpad test found a pad in the VM). `\b(alps|elan|...)` in Pointer._devices.
- In the VM, the active mouse is the absolute vmmouse: HMP `mouse_move` does
  nothing visible; drive the pointer with QMP `input-send-event` type `abs`.
  Esc/right-click on the home grid opens the power menu, where "1" = Reboot -
  scripted key sequences have rebooted the VM into MemTest86+ twice.
- Cable ports boot switched off, and an off port reports no carrier even
  with a cable in: `ip link set X up` before checking (`wired_online` in
  drivers.sh). Get firmware's "is a cable plugged in?" always said no.
- Everything the kernel ships is already on the image (linux-modules +
  -extra); "download a driver" means firmware. Driver check judges a device
  by what its driver *made* (card / netdev / input / video / hci), not by
  "driver attached" - the A40-J touchpad and sound were attached and dead.
- No i915 means Intel sound (SOF / HDA, 6th gen+) waits forever for it and
  makes no sound card ("init of i915 and HDMI codec failed", deferred probe).
  `snd_hda_core gpu_bind=0` (/etc/modprobe.d/diag-audio.conf) - never remove.
- Kernel debugfs/sysfs text pads with TABs (`timing spec:\t2 (sd
  high-speed)`): split on `:[ \t]*`, not `: *`. A TAB in a tui value used to
  blank the field (the protocol's separator); `_s` in tui.sh now turns TABs
  and newlines into spaces, but parse cleanly anyway.
- ui.py runs as `__main__` on the image: never look it up as
  `sys.modules["ui"]` (the checks import it as "ui", so only the VM shows
  the miss) - go through the screen object, `type(scr).__module__`.
- nvme-cli 2.8 JSON: plain numbers, temperatures in Kelvin, `psds[]` with
  `entry_lat`/`exit_lat`/`non-operational_state`. get-feature 0x0c errors on
  drives without APST - only ask when `apsta` is 1.
- Ubuntu's `dhclient` has no `-timeout` (Fedora patch) — wrap it in
  `timeout N` instead. Never `2>/dev/null` a network tool; log it.
- `iw link` shows the SSID before the WPA handshake completes; use
  `wifi_wpa_state` (wpa_cli) for "connected".
- A USB-C power supply's `online` and `typec/portN-partner` are the UCSI
  driver's memory of the port's last event; the A40-J never reported an
  unplug (1.18.0: "charger connected" with nothing plugged in). For "is a
  charger in", trust the Mains flag (`_PSR`, re-read every time), and the
  battery status as a cross-check - see `plugged()` in chargetest.sh.
- An animation must never draw its example figures live: a missing kv
  figure is "no reading" (the A40-J's USB-C step showed the example's 62 %).
- Never space-pad columns for the renderer (proportional font): pass menu
  cells as `name|col|col` or use `tui_thead`/`tui_trow`.
- Skins (mecha, kawaii) draw the same rows, card box and header height as
  the other themes - never move a position in a skin. A new item kind in
  `render()` falls through to `scr._draw_item` and gets the plain look; a new
  card-level element (badge-like, bar-like) needs a drawer in skins.py too.
  Look at both skins at 1024x768 and 150 % text (`skins.py --shots DIR`).

## Open items

- **1.20 needs real-hardware checks** (VM-tested with fakes only):
  - Wi-Fi per-antenna signal and retries on the AX201: does iwlwifi put
    chains in `iw station dump`?
  - the SD reader on a Realtek rtsx slot (bus mode from debugfs)
  - the lid and tablet switches on a Dynabook
  - the headphone jack on SOF (the A40-J) - does the switch report, and does
    sound move to the headphones without PulseAudio?
  - the PROCHOT MSR read
  - the error log's rules against a real faulty machine
  - the anime themes (mecha, kawaii) on a real panel: VM-checked at
    1280x800 (switch, home, menus, live CPU test), the rest rendered
    offscreen at 1024x768-1920x1080 and 150 % text

- **1.15 needs real-hardware checks**: A40-J sound with gpu_bind=0 (and the
  legacy-HDA fallback, never exercised); controller-check wake timing (QEMU
  NVMe has no APST); Charging test on a real charger, DC jack and USB-C/UCSI
  (VM-tested only with the `test_power` module).

- **Wi-Fi on the real AX201 (`wlo1`)**: 1.11 scanning works on the A40-J
  (attempt 1 timed out, attempt 2 found 26 APs). 1.12 fixes the "no address"
  failure (dhclient `-timeout` bug); joining is not yet re-verified on the
  real card. Ask Ash for the Toolkit log "wireless connections" section.
- **Touchpad on the TECRA A40-J** reported "not found". Drivers are all in
  the image; 1.12's driver search will say whether the firmware lists it,
  disables it, or it is silent on I2C. Get that screen / log from Ash.
- Never verified on real hardware: touchscreen test, USB-C/PD reporting (needs
  UCSI), PCIe gen readout, two-finger right-click, run-from-RAM on a real stick,
  install simulation, screen test. (Drive self-test: confirmed OK by Ash.)
- Two-digit tile numbers wait only 0.7 s for the second digit (`_pick_number`).
- Stress test elapsed display lags the progress bar (cosmetic).
- WinPE companion ISO for SetDmiAll (Ash is installing the Windows ADK + WinPE
  add-on): build script not yet written. It must take the path to Ash's own
  extracted SetDmiAll folder; TVALZ.sys needs Secure Boot off.
- Ideas raised but not built: fan RPM (check `sensors` on real models
  first), keyboard LED test, Bluetooth scan, Windows 11 readiness (TPM),
  idle gaps inside the install simulation.

## Delivering to Ash

He copies `hw-diagnostic-toolkit vX.Y.Z.iso` to a Ventoy stick. Bump
`DIAG_VERSION`, build, boot-test, then give him the SHA256. Keep a short
changelog entry in `docs/HISTORY.md` per version.
