# Hardware Diagnostic Toolkit — project brief for Claude Code

Bootable USB/ISO for bench-testing laptops at Data Dynamics (Johor). Owner: Ash
(Senior IT Engineer; laptop repair bench, mostly Dynabook/Toshiba). Boots a
minimal Ubuntu live system straight into a full-screen tile menu of hardware
tests, and writes a per-machine report to the USB stick.

**Current version: 1.28.1** (`toolkit/lib.sh` → `DIAG_VERSION`).
1.28.0 took OneDrive out - its code is in git, d615508.
Version history, the reasoning behind past changes and every delivered ISO's
SHA256: `docs/HISTORY.md`.

Project skills (`.claude/skills/`): **release** (delivering a version),
**vm-test** (boot the ISO in QEMU and drive it), **bios-update** (tile 20 and
its UEFI traps). Disk imaging notes: `docs/imaging-notes.md`. What still needs
a real machine: `docs/OPEN.md`.

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
  gputest.sh        GPU check (tile 5): every graphics chip, the discrete one
                    woken; PCIe link lanes, AER counters, kernel log - no
                    GPU driver (invariant 1); --quiet in Full run
  fantest.sh        Fan test (Peripherals 14): CPU load, fan rpm where the
                    laptop reports one, else the technician is asked
  imaging.sh        Disk imaging screens (tile 8): clone, back up, restore,
                    check; runs imgengine.py in the background (status file)
  imgengine.py      the imaging work: clone / backup / restore / verify,
                    BitLocker unlock, hibernation discard; the shrink-in-
                    scratch device (dm snapshot); drive bars (mapspec)
  imgplan.py        where each partition goes on the new drive (pure; tests
                    in test/imgplan_test.py, run by the build)
  imgscan.py        a drive's table + per-partition fs, used, min, state
  imgfmt.py         Clonezilla's image folder; partclone v2 header/bitmap;
                    toolkit extras in diag/ (frame index for browsing)
  partitions.sh     Partitions (Disk imaging item 5): runs ui.py's PartEditor
                    (op partedit - Now / After bars, drag), then Apply
  imgparted.py      the editor's model + work: limits, after-picture edits,
                    now->after steps in a safe order (tests: test/imgparted_test.py)
  imgplanedit.py    the same editor on a clone / restore plan (plan screen,
                    E = adjust sizes; ui.py PlanEditor): the plan's rules for
                    what may move, new partitions, re-checks the plan
                    (tests: test/imgplanedit_test.py, run by the build)
  imglib.sh         shared by imaging.sh / partitions.sh / imgbrowse.sh: drive
                    and store pickers (follow hot-plug), BitLocker key entry,
                    run_job, both editors' questions (PE / STATE)
  imgbrowse.sh      Browse an image (Disk imaging item 6): partition, folders,
                    copy files out next to the image or to another USB drive
  imgbrowse.py      serves a partition out of an image as a read-only NBD
                    device (partclone bitmap + zstd frame index, no unpacking),
                    mounts it read-only; copy with progress (tests:
                    test/imgbrowse_test.py, run by the build)
  mrimg.py          Macrium Reflect 7/8 images (.mrimg): reverse-engineered
                    reader, every block MD5-checked; served as a drive (NBD)
                    for Restore (cloned with Clone's plan), a partition for
                    Browse; verify (tests: test/mrimg_test.py, run by the build)
  vendor/quicklz131.c  QuickLZ 1.31 (GPL) - Macrium 8's compression; the build
                    compiles it to /opt/diag/lib/libqlz.so on the host
  clock.sh          the clock: set from the internet (Date header of a plain
                    web address) or by hand, written to the RTC; `watch` runs
                    from boot and sets it whenever there is a connection
  biosupdate.sh     BIOS update (tile 20): the maker's own flasher, started in a
                    UEFI Shell after a restart (see invariant 4 and the
                    BIOS convention); --result after the boot Language menu
  biospkg.py        which packages in DIAGDATA\BIOS may be offered: model and
                    version from the folder name, whole-word model match on
                    DMI (name, version, board - not the series' family), newer
                    only, names the Shell can run as written (tests:
                    test/biospkg_test.py, run by the build)
  ui.py             Pillow framebuffer renderer (/dev/fb0), all screens + the
                    interactive tests (keyboard, pointer, touchscreen, camera)
  skins.py          the anime themes (mecha, kawaii): ui.py hands header,
                    card, grid, menus, badges, bars to it when SKIN is set;
                    --check / --shots DIR (the build runs --check)
  i18n.py           Settings -> Language: T() translates every string at the
                    font (Pillow's getmask2/getbbox/getlength are wrapped),
                    Noto Sans CJK for Chinese/Japanese/Korean; --check
  i18n/<lang>.json  the catalogues {"English": "translation"}, {0} = a value
  *test.sh etc      one script per test
  icons/            Ash's 24x24 PNG icon set (alpha used as a stencil)
test/               QEMU harness: boot-vm.sh, screenshot, keystrokes, QMP touch;
                    imaging-loop.sh (imaging end to end on loop drives, root);
                    i18n_extract.py (every on-screen string, for i18n/)
docs/               HISTORY.md, OPEN.md, imaging-notes.md, dmi-board-swap.md
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

Boot it and look after every change - the `vm-test` skill (`test/boot-vm.sh`
documents every mode). The build has a renderer smoke test, but most UI
regressions only show on screen.

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
4. **The toolkit never writes firmware/DMI/EEPROM itself.** Since 1.28 (Ash,
   agreed): a BIOS update may *start the maker's own flasher with the
   maker's own image* (Dynabook's ShellFlash64.efi or ChgFirmA.efi + .bin;
   ChgFirmA's /f is a force), only for the
   matching model, only newer, after UPDATE is typed - never in Full run.
   Never a force option, never a vendor binary in the ISO (they come from
   Ash's stick). DMI writing stays banned: machine details edits override
   the report only; DMI capture writes a `dmichg.txt` for Toshiba's Windows
   tool SetDmiAll. Do not build a Linux DMI writer or reverse-engineer
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
9. **Disk imaging never writes the drive it copies.** imgengine.py sets the
   source read-only in the kernel for the whole job; only plans with
   `ok: true` from imgplan.py may write a target, and ERASE is typed first.
   The two writes to a source (discard hibernation, shrink C: on a SMART-
   PASSED drive after typing SHRINK) are the operator's named choices.
   Disk and partition IDs are kept on a clone - Windows boots by them.
   Run `sudo test/imaging-loop.sh` after any change to img*.py.

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
  can answer `wifi`; tui.sh handles it — don't treat it as a choice. `hover`
  comes only once the pointer rests (`HOVER_SETTLE`, 60 ms): a full redraw
  per hover froze the arrow (1.22). The arrow itself moves on every event,
  and between screens the main loop moves it (`pump_pointer`).
- A peripheral test that can fail for want of a driver is listed in
  `driver_key` / `driver_followup` (menu.sh) with its drivers.tsv types: a
  FAIL (or "NOT TESTED (no ...)") runs `drivercheck.sh --for` on those.
- Disk imaging: a list of drives or sticks goes through `pick_drive` /
  `pick_store` (imglib.sh) - they follow hot-plug (`tui_menu_watch`); set
  `JOB_DEVS` (the disks a job reads and writes) before `run_job`, or its
  Flow bar has no drive to watch and never shows a stall. A step a person
  waits on must read keys while it runs (background + `tui_wait_key`): a
  page that reads none looks hung, and the keys pressed meanwhile answer the
  pages after it (1.26 shipped a search page that read no key).
- BIOS update (biosupdate.sh / biospkg.py, 1.28): read the `bios-update`
  skill first. The essentials: packages in `DIAGDATA\BIOS\<Dynabook's folder>`
  on FAT32; the UEFI Shell entry is BootNext only, never in BootOrder; the way
  back goes last in BootOrder; `--result` drops both entries at every start;
  file names only letters, digits, `. _ -` (startup.nsh runs them as written).
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
  reading (battery drain fps=1, CPU idle baseline fps=2). Scenes play at 60
  fps (`ssdanim.FPS`), except while a test measures: scenes in `MEASURING`
  stay at 15 - add a new measuring scene there.
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
- Languages: scripts keep writing English; the renderer translates at the
  font (i18n.py). A new or reworded on-screen string shows in English until
  it is in the catalogues: `python3 test/i18n_extract.py --merge
  toolkit/i18n/zh_CN.json` lists what is missing. Code that cuts or wraps
  text must work on `tr(text)` (ui.py) / `I.T()` first - a cut English
  string matches nothing - and wrap with `i18n.tokens`/`join` (Chinese and
  Japanese break between characters). Never cut screen text in bash: a long
  sentence goes through `tui_para`, which the renderer wraps after
  translating (op `para`; it answers the next free row). A plural made with
  `%s` ("change%s") cannot match - write the two strings out. Test logic
  never compares against drawn text. The report stays English.
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
- Write the framebuffer with write()/pwrite (`Framebuffer._write`), never
  through the mmap: simpledrm's fbdev (any DRM fbdev) puts mmap stores on
  screen only every 50 ms (deferred I/O, HZ/20) - the pointer and the
  animations were stuck at 20 updates a second until 1.27, invisible in a
  screenshot. A frame's period counts from its start, not its end.
- ui.py: `_draw_grid` gets `d` not the canvas; `KDSETMODE/KD_TEXT/KD_GRAPHICS`
  constants must stay (deleting them silently drops to the text UI).
- Daemons started by tests inherit fds: lib.sh closes fd 8 (menu's lock) so
  `wpa_supplicant` etc can't keep the lock and stop the menu restarting.
- `find -L /sys` hangs (circular symlinks) — use bounded globs.
- bash `read` with whitespace IFS collapses empty fields — use `|`.
- VM harness traps (pkill kills your shell, vmmouse, Esc -> 1 = Reboot): the
  `vm-test` skill.
- A bare `exec` with redirections is permanent: `exec 8>&- 2>/dev/null` in
  lib.sh silenced stderr in every script and broke the Command prompt shell
  (1.11-1.12.0). Close fds with `exec 8>&-` alone.
- Device-name matching must use word starts: "alps" matched QEMU's
  "VirtuALPS/2 VMware VMMouse" and made the mouse a "touchpad" (pointer dead,
  touchpad test found a pad in the VM). `\b(alps|elan|...)` in Pointer._devices.
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
- Settings live in RAM (`/run/diag/settings.conf`); `keep_settings`
  (lib.sh) writes them to the boot stick after every change and
  `restore_settings` reads them back in menu.sh *before* `start-ui.sh` -
  ui.py reads settings once, at start-up. Ash boots from **Ventoy**: the
  live medium is the read-only ISO image (`/dev/mapper/ventoy`; this
  image's live-boot mounts the medium at `/usr/lib/live/mount/medium`, not
  `/run/live/medium` - use `live_medium_dev`), and the
  partition holding the ISOs is locked (`mount /dev/sdb1` fails). Ventoy
  1.1.01+ maps that partition as a dm device named after it (`dm_named
  sdb1`) - write through that, never the plain device. An older Ventoy does
  not: `stick_part_dev` (lib.sh) then maps it itself as `diag-sdb1` (dm
  linear over the whole partition) - before it (1.26), Ash's settings on
  his DIAGDATA were neither read nor kept.
- hwclock is not in util-linux on noble but in util-linux-extra; a clock set
  without it was lost at the next boot. The image's zone must be the bench's
  (Asia/Kuala_Lumpur, finalize_chroot.sh) with /etc/adjtime LOCAL: on Etc/UTC
  the RTC's local time passed for UTC, and writing a true time back would put
  the customer's Windows 8 hours out. QEMU's RTC is UTC - test the clock with
  `-rtc base=localtime`, as a Windows laptop keeps it. Time a watcher by /proc/uptime, not
  by the clock it sets (a clock set back by years waited years).
- Linux 7.0 (HWE) since 1.21; noble's 6.8 iwlwifi loads Intel firmware only
  up to API 86 and Panther Lake's (Z40L-P) starts at 101 - "firmware
  missing" with the file on the stick. 7.0 brought a VFIO "xe" directory
  (drivers/vfio/pci/xe) that trips invariant 1's check - trim.sh removes
  it - and intel_agp half-matching QEMU's 440FX host bridge (Driver check
  treats an unbound Bridge as fine).
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

- Disk imaging traps (partclone flags, ntfsresize's chkdsk flag, NBD ioctls
  and offsets, Macrium's layout): `docs/imaging-notes.md` - read it before
  touching img*.py / mrimg.py.
- Never parse a command's stdout+stderr together for a value: `losetup
  --show` printed a warning on stderr and it became part of the device name
  in a dm table. A loop over a file whose size is not a multiple of 512 warns.
- FAT: the image kernel's default file-name charset is iso8859-1 (no
  FAT_DEFAULT_UTF8) - a Chinese file name copied to a FAT32 stick failed
  (EINVAL) or garbled. Mount vfat with `-o utf8` (`_mount_storage` does).
- The build tree and the chroot outlive every quick build: a script removed
  from toolkit/ (getfirmware.sh, 1.15) still shipped in 1.23. finalize clears
  `/opt/diag/*.sh *.py` before copying; a build-tree sync must mirror
  toolkit/, not copy over it.
- Never edit a bash script while it runs (`test/imaging-loop.sh` takes ~20
  min): bash reads it as it goes, and the run dies with exit 2 mid-way.
- Pointer press / drag / release exist only while `kb.drag_mode` is on (the
  partition editor). Everywhere else a press is still "click" - a release
  arriving on the next screen would otherwise answer it.
- UEFI traps (El Torito hides partitions, firmware deleting unlisted boot
  entries, EDK2 Shell syntax): the `bios-update` skill.
- Two sessions sharing this checkout: a build of one version from HEAD plus
  its own files leaves out the other's uncommitted helpers. 1.26's
  `od_stopkey` called `tui_wait_key` (1.27's tui.sh) - undefined in the 1.26
  build, so the search page spun without ever reading a key. Check new
  calls against the tui.sh that ships (`git show HEAD:toolkit/tui.sh`).

## Open items

`docs/OPEN.md` - what each version still needs a real machine for. Add to it
when something is only VM-verified; remove what Ash confirms.

## Delivering to Ash

The `release` skill: bump `DIAG_VERSION`, build, boot-test, HISTORY entry,
SHA256 to Ash (`hw-diagnostic-toolkit vX.Y.Z.iso`, for his Ventoy stick).
