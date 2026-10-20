# Hardware Diagnostic Toolkit — project brief for Claude Code

Bootable USB/ISO for bench-testing laptops at Data Dynamics (Johor). Owner: Ash
(Senior IT Engineer; laptop repair bench, mostly Dynabook/Toshiba). Boots a
minimal Ubuntu live system straight into a full-screen tile menu of hardware
tests, and writes a per-machine report to the USB stick.

**Current version: 1.26.0** (`toolkit/lib.sh` → `DIAG_VERSION`).
Last delivered ISO: 1.26.0, SHA256 `79f1babdaaf4efe20de5abe72c0216a1a74c5daa3c4e514dba6c64d196d06e91`
(asks "USB or OneDrive" first; with no app IDs built in, choosing OneDrive
asks for them on screen and keeps them in the stick's diag-onedrive.conf).
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
  onedrive.py       Ash's work OneDrive as an image store: device code sign-in
                    (code typed on his phone), Microsoft Graph over http.client
                    (kept-alive connections), find images (search + walk),
                    mount/sync/umount; onedrive.conf = the app's two IDs
                    (or diag-onedrive.conf on the stick)
  odfs.py           OneDrive as a folder (FUSE via python3-fusepy, fsname
                    "onedrive"): 8 MB ranged reads + read-ahead; a file being
                    written is held in /dev/shm until closed (uploads need the
                    size up front) - small ones until .diag-sync (tests:
                    test/onedrive_test.py against test/fakegraph.py)
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
# wait 2-3 min - the first screen is the Language menu (every boot): Enter
test/k.sh ret
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
  Flow bar has no drive to watch and never shows a stall. The store's side
  is `$(store_io)`: its disk, or the network ports for OneDrive.
- OneDrive is one more store: `pick_place` asks "USB or OneDrive" first (back
  up, restore, check, browse - Ash: "it always ask me to plug in USB"; never
  scratch space, which stays `pick_store`, USB only). USB goes to the drive
  list, which waits for a plug-in (Q: back to the question); OneDrive with
  no app IDs asks for them (`od_setup`, kept on the stick; asked again when
  Microsoft refuses them, onedrive.py exit 4), then `STORAGE_DEV=onedrive`,
  mounted at `/mnt/onedrive` by `od_mount` and left open until Disk imaging
  exits (`od_close`). A backup there is not done until `od_sync` (the small
  files go up last, the image's markers after them). Browse never copies
  into OneDrive. The sign-in is kept on the stick (`diag-onedrive.json`) -
  Ash's explicit choice; Disk imaging -> OneDrive signs out and deletes it
  (shred first: FAT keeps deleted clusters). Only the boot stick's own
  partitions hold or give it (`od_places`) - a stranger's DIAGDATA stick
  must not bring its account; the build's app IDs win over the stick's; the
  backup confirm shows the account from a live `/me` (`whoami --live`).
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
  reading (battery drain fps=1, CPU idle baseline fps=2). Scenes play at 45
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
- Settings live in RAM (`/run/diag/settings.conf`); `keep_settings`
  (lib.sh) writes them to the boot stick after every change and
  `restore_settings` reads them back in menu.sh *before* `start-ui.sh` -
  ui.py reads settings once, at start-up. Ash boots from **Ventoy**: the
  live medium is the read-only ISO image (`/dev/mapper/ventoy`; this
  image's live-boot mounts the medium at `/usr/lib/live/mount/medium`, not
  `/run/live/medium` - use `live_medium_dev`), and the
  partition holding the ISOs is locked (`mount /dev/sdb1` fails). Ventoy
  1.1.01+ maps that partition as a dm device named after it (`dm_named
  sdb1`) - write through that, never the plain device.
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

- partclone: `-o FILE` refuses an existing file (even /dev/null) - use
  `-O`; dev-to-dev (`-b`) compares the *partition* sizes, so a filesystem
  already shrunk inside a big partition needs `-C`. `-I` copies an NTFS
  marked for chkdsk (exact copy; never resize one). partclone.dd output has
  no header (chkimg says "not partclone image") - check it through zstd.
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
- ntfsresize leaves the volume flagged for chkdsk (by design - Windows checks
  once). Volumes the toolkit resized are listed by serial in
  `$RUN_DIR/ntfs-resized.list` and scan as "ok"; any other flagged NTFS is
  "dirty" and is never resized.
- Never edit a bash script while it runs (`test/imaging-loop.sh` takes ~20
  min): bash reads it as it goes, and the run dies with exit 2 mid-way.
- Pointer press / drag / release exist only while `kb.drag_mode` is on (the
  partition editor). Everywhere else a press is still "click" - a release
  arriving on the next screen would otherwise answer it.
- Browse an image uses NBD's old ioctl interface on a socketpair (no
  nbd-client): NBD_SET_SOCK and the other setup ioctls from one task,
  NBD_DO_IT blocks in a thread for the whole connection. The bitmap's CRC32
  (4 bytes) sits between the bitmap and the first block, and a checksum
  follows every `blocks_per_checksum` blocks - offsets off by either read
  plausible-looking garbage, which test/imgbrowse_test.py catches.
  `fcntl.ioctl` passes a C int: NBD_SET_SIZE of anything over 2 GB
  overflowed - imgbrowse's `ioctl()` goes through ctypes (unsigned long).
- An image can only be read in the middle through diag/<part>.idx; the
  reader refuses one whose frame sizes do not add up to the files (a lost
  line would shift every offset after it).
- Macrium .mrimg (mrimg.py): no published spec for Reflect 7/8 - the layout
  came from the mrimg7z project and was checked against Ash's own image
  and images Macrium made of known test disks (C:\Users\Ash\mrimg-test,
  make-mrimg.ps1 - Macrium's command line wants the GPT disk GUID in upper
  case). The u16 at metadata+8 is the split piece, +10 the incremental
  number; "No compression" blocks carry no QuickLZ header; FAT partitions
  keep their reserved sectors + FATs raw before the blocks. QuickLZ itself
  never reports bad input - the per-block MD5 is the only check, keep it.
- NBD devices now allow partitions (`modprobe nbd`, no max_part=0): Restore
  from a Macrium image serves the whole drive and clones from nbdNp1...;
  the kernel's table scan needs `blockdev --rereadpt` + `udevadm settle`.
- OneDrive (Graph): an upload must give its total size up front - no
  streaming of unknown length - hence odfs.py's spool and the 256 MB backup
  pieces (`split -a 3` below 1000 MB: two letters stop at 676 pieces). An
  upload-session URL must NOT get the Authorization header (401); fragments
  are multiples of 320 KiB; a fragment whose answer was lost is resent and
  gets 416 - ask the session where to go on. Download links (`@microsoft.
  graph.downloadUrl`) carry their own key and run out after about an hour;
  never log a URL's query. Work-OneDrive search results often have no
  `parentReference.path` (fetch the item) and search lags uploads by
  minutes. Names ignore case. Debian's fusepy module is `fusepy`, not
  `fuse`. A spool file must be unbuffered: `>>` appends at the size
  getattr reported.

## Open items

- **1.26.0 OneDrive on the real tenant** (tested only against
  test/fakegraph.py: unit tests, a real FUSE mount in WSL, imaging-loop.sh
  case onedrive - backup in 256 MB pieces, find, check, restore, a Macrium
  image browsed off it). Still to see with Ash's app registration (he sends
  the Application (client) ID and Directory (tenant) ID - into
  onedrive.conf, or diag-onedrive.conf on the stick): the device code
  sign-in on his phone (Conditional Access may block device code flow -
  then his admin must allow it for this app), whether Microsoft's search
  finds his .mrimg files by "mrimg", real upload/download speed on the
  bench network and the CPU odfs.py costs, a restore of one of his real
  Macrium images straight off OneDrive, the sign-in found again after a
  reboot (Ventoy stick), and Sign out. Ask Ash before writing test data to
  his OneDrive.

- **1.25.0 imaging on the bench** (WSL loop drives, offscreen renders, the
  renderer driven over its FIFO, and the VM: two USB drives hot-plugged into
  open Clone lists, C: shrunk + a new DATA made with E on the plan screen,
  the clone read back PASS and checked from outside, the bar amber while the
  target was throttled with `block_set_io_throttle` and moving again after).
  Still to see on real hardware: a real USB drive
  plugged in while a drive list is open, and a slow card reader (does the
  list settle, or flicker as the size arrives); the plan screen's E editor
  dragged on a real touchpad; a clone with sizes set by hand - C: shrunk,
  WinRE grown, a new D: - booting Windows; the Flow bar's CPU on the
  slowest bench machine during a compressed backup, and whether it freezes
  amber on a drive that really stalls.

- **1.24.0 fan and GPU on the bench** (VM only: QEMU's VGA, fake sensors
  via `DIAG_HWMON_ROOT`). GPU: a laptop with a discrete GPU (Optimus /
  hybrid) - does waking it through power/control bring it out of D3cold, do
  its link lanes and AER counters read, and does a known-bad board show it.
  Fan: which bench models report a speed at all (hwmon fan*_input, ACPI
  `fan_speed_rpm`, Toshiba's `TOS*/fan` switch) - `sensors` on each.

- **1.22.0 on the bench** (VM only): the pointer on a real touchpad and
  mouse (does it feel smooth now - HOVER_SETTLE 60 ms, one-write cursor);
  45 fps animations on the slowest bench machine (frames are dropped, not
  slowed - check the CPU it costs); a failed peripheral test fetching real
  firmware online (VM proved only a driver started from the stick: the
  e1000 unbound, then the Ethernet test fixed it and passed on re-run); the
  battery log on Ash's Ventoy stick (written through Ventoy's mapping,
  found again after the laptop dies) - VM tested only the "No USB stick"
  warning with a fake BAT0 (`DIAG_PS_ROOT`).

- **1.23.0 Macrium images** (WSL loop drives + VM): restore one of Ash's real
  Reflect 8 images onto a real laptop and boot Windows from it; Browse a
  real customer image. Not supported yet, each refused with the reason:
  split images (several .mrimg files - the last piece holds the index, and
  the records do not say which piece a block is in), incremental /
  differential images, password-protected ones, MBR images with logical
  partitions, Reflect X (.mrimgx - Macrium publishes that format, MIT, at
  github.com/macrium/mrimgx_file_layout, if Ash moves to Reflect X).

- **1.21.0 Linux 7.0 on the bench** (VM only): every model needs a pass on
  the new kernel - screen (simpledrm, invariant 1), sound with gpu_bind=0,
  touchpad, Wi-Fi. First the PORTEGE Z40L-P: does its Wi-Fi now come up
  (iwlmld + iwlwifi-sc-a0-wh-b0-c10x), its touchpad (THC), its sound (SOF
  for Panther Lake may need newer firmware than noble ships)?
- **1.21.0 first boot in the VM once stopped in initramfs** ("mounting /run on
  /root/run failed", also /sys, /proc) under heavy host I/O; a reset booted.
  Not seen in other boots. If it shows on a real stick, look at live-boot's
  medium wait (dmesg at that prompt).
- **1.21.0 languages**: machine translations (Haiku, from the brief and
  glossary in the 1.21 session) - ask a native speaker of each to look
  through the screens. Long translations may clip on tight screens at 150 %.
- **1.21.0 More info page** on real hardware: PCIe ports/slots counts, Wi-Fi
  standard from `iw phy`, permanent MAC via `ethtool -P` (QEMU: no PCIe, no
  Wi-Fi).

- **1.21.0 disk imaging on real hardware** (loop drives in WSL + VM only):
  a cloned Windows actually booting (GPT and MBR), BitLocker unlock with a
  real recovery key (cryptsetup BITLK - never run against a real volume),
  the Key ID shown, a Ventoy stick as the image store, a real Clonezilla
  restoring a toolkit image. The partition editor's drag on a real touchpad
  (click and hold) and touchscreen; a moved C: booting Windows. Browse an
  image: a real customer image (large NTFS, a hibernated or dirty C: - ntfs3
  then ntfs-3g read-only), a BitLocker partition saved locked and unlocked
  at browse time, copying to a second USB drive; Clonezilla's own images are
  refused (no index) - restore them instead.

- **1.20.1 settings on Ash's real Ventoy stick**: VM-tested only with a
  DIAGDATA stick (kept, restored after reboot, cleared by Reset) and a
  dd-written stick (honest "read-only image" message). Writing through
  Ventoy's dm copy of its partition (1.1.01+) has never run - ask Ash which
  message the theme change shows, and for `/run/diag/settings.log`.

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
