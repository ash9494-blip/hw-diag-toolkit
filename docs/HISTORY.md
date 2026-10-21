# Version history

Newest first. Each entry says what changed and why; the "why" is usually a
real machine on Ash's bench.

## 1.26.0 — 2026-10-19
- **OneDrive as a place for images** (Ash: "for image restore not only rely
  on usb, but also to search image on onedrive, and back up from there").
  Back up, Restore, Check and Browse an image first ask "USB drive or
  OneDrive" (Ash: "it always ask me to plug in USB when imaging ... if i
  choose one drive, then ask me credential, if i choose usb, wait for usb
  to plugged in"): USB goes to the drive list, which waits for a drive
  (Q goes back to the question); OneDrive goes to the sign-in. A toolkit
  without the app's IDs asks for them on screen once - Application (client)
  ID and Directory (tenant) ID, from the app's Overview page - and keeps
  them on the stick; if Microsoft does not know them it says so and asks
  again (his work account, Data Dynamics). Sign-in is Microsoft's device
  code: the screen shows a code, Ash types it at microsoft.com/devicelogin on
  his phone and approves there - no password is typed on a bench laptop.
  The sign-in is kept on the boot stick (`diag-onedrive.json`, beside the
  settings), Ash's choice after being told anyone holding the stick can
  then open his OneDrive; Disk imaging -> OneDrive shows who is signed in
  and signs out, deleting it from the laptop and the stick. No internet:
  a cable is tried, then the Wi-Fi page is offered.
  - `onedrive.py`: sign-in and Microsoft Graph over Python's own
    http.client (connections kept alive - a TLS handshake per 8 MB read cost
    more than the read), retries on throttling and dropped connections, the
    sign-in renewed and rewritten as Microsoft rotates it. Images are found
    by Microsoft's search (.mrimg files and Clonezilla folders anywhere) and
    by reading the top of the drive, its folders and "Disk images" directly
    (search lags an upload by minutes).
  - `odfs.py`: OneDrive as a folder (FUSE, python3-fusepy), so the imaging
    engine, mrimg.py and Browse work on it unchanged. Reads are 8 MB ranged
    downloads with three fetched ahead; a look elsewhere in a file (a
    Macrium image's index) fetches 512 KB. OneDrive takes a file only whole,
    with its size given first, so a file being written waits in memory
    until closed: backups to OneDrive go in 256 MB pieces into
    "Disk images/<name>", each sent when split closes it (a failed upload
    fails the backup with OneDrive's reason); the small files go up at the
    end, the image's own markers last, so a backup cut off never looks
    finished. Browse copies files out of an image on OneDrive to a USB
    drive only.
  - Pieces under 1000 MB are named with three letters (.aaa): two run out
    at 676 pieces, 173 GB at 256 MB.
  - The Flow bar also watches the network ports for OneDrive jobs: while a
    piece uploads the drive being read waits, and the bar would have turned
    amber.
  - The app's two IDs (Ash's registration in Data Dynamics' Entra ID; a
    public client - no secret) are in onedrive.conf, or in
    onedrive.config on the stick, so no rebuild is needed when they
    change.
  - Tests: test/fakegraph.py stands in for Microsoft (strict about upload
    fragments, the Authorization header, case; throttles, loses an answer,
    expires links on request); test/onedrive_test.py runs in the build;
    imaging-loop.sh case onedrive mounts it for real and backs up, finds,
    checks and restores through it.
  - Fixed on the way: a restore wrote the boot code with `dd if=<path>`
    unquoted - the space in "Disk images" made every restore from OneDrive
    fail (USB image folders never had one).
  - A security review before delivery: the sign-in is read from and kept
    on the boot stick only (a stranger's DIAGDATA stick could have brought
    its own account and taken customer images there); the build's app IDs
    win over a stick's, and IDs that are not IDs count as none; the backup
    confirm names the account as Microsoft does, not the kept label; Sign
    out overwrites the stick's copy before deleting it (FAT keeps deleted
    clusters) and no longer says "removed from the stick" when a stick
    place could not be written; a write the RAM spool only half took, a
    piece OneDrive holds short, or an OneDrive folder that died before the
    last files went up all fail the backup instead of passing it; a wrong
    clock says so instead of "no internet"; next-page links must be Graph's.
  - The new screens are in the Chinese, Japanese and Korean catalogues
    (machine translation, like the rest - for a native speaker to check).

## 1.25.0 — 2026-10-19
Three Disk imaging requests from Ash after 1.23.0.
- **Drive lists follow hot-plug** (Ash: "detecting hot-plug USB, instead of
  back and select again"). Every drive and USB-stick list in Disk imaging
  and Partitions updates where it is when a drive is plugged in or pulled
  out (about 2 s); the highlighted drive stays highlighted and a new one is
  marked "just plugged in". With nothing to offer, a "plug it in" page waits
  for one (Q gives up) instead of a message and a trip back. ui.py
  `BlockWatch` reads /proc/partitions (loop, NBD, dm and RAM devices are
  the toolkit's own and ignored); a change counts once it has held still
  1.5 s, so a stick's partitions arrive with it. Ops `menuw`
  (`tui_menu_watch`: returns 2 with `TUI_HOTSEL`) and `waitdev`
  (`tui_wait_device`). The text interface waits on the page but does not
  refresh an open list.
- **Adjust sizes on the plan screen** (Ash: "when the system shows me the
  before and after clone size, I want to be able to adjust partition also
  from there"). E on the Clone / Restore / Macrium-restore plan opens the
  partition editor (`PlanEditor`, Ash's Now / After pick) on the plan: C:
  from its data plus the plan's margin up to the next partition; the
  partitions after C: moved and grown (never shrunk below the old size);
  free space left anywhere; new partitions (NTFS, exFAT, FAT32, ext4) made
  empty right after the copy (imgengine `how: "new"`). Partitions before
  C: keep their place and size - Windows' boot entries find them there.
  `imgplanedit.py` checks the edited plan again (order, overlap, inside the
  drive, smallest sizes, MBR's four) before it replaces the plan: only an
  ok plan writes a drive. The report says "Sizes set by hand on the plan
  screen". The partition editor's questions (new partition, exact size, the
  text-screen list) moved to imglib.sh for both editors.
- **The imaging bar moves - "Flow"** (Ash's pick of four rendered samples:
  flow, sheen, pulse, block map). Packets run along the fill; mecha's lamps
  chase to the lit edge; kawaii's candy stripes roll. It follows the job's
  drives, not the percentage (/sys/block/X/stat): after 10 s with no sector
  read or written on any of them it stops and turns amber (grey on
  contrast, where amber is the accent) - a drive that has stopped answering
  shows as a frozen bar, while a slow shrink or read-back still moves. Only
  the bar's strip is redrawn, 10 times a second (`Framebuffer.update_region`);
  a frame that fails turns the motion off for the session. `tui_bar_live
  row pct DISKS`; run_job's callers set `JOB_DEVS`.
- The disk benchmark wrote its verdict twice: every run left two `RESULT:`
  lines and two `DISK_RESULT` entries (a block pasted twice in `run_cdm`).
  A stale first copy of `wear_report()` is gone too.
- test/imaging-loop.sh: a clone-edited case (C: shrunk by hand, WinRE grown,
  a new DATA partition, every file checked); the mbr case no longer
  overwrites the GPT drive's checksum files - "browse: EFI" failed every
  full run since 1.23. test/imgplanedit_test.py (16 tests) runs in the
  build; `skins.py --check` renders the job bar moving and stalled.

## 1.24.0 — 2026-10-19
- **GPU check** (`gputest.sh`, main page tile 5 after RAM; Ash). Every
  graphics chip on the PCI bus: the discrete one is woken first (power on,
  then a live config read with setpci - "does not answer" means a dead chip,
  not power saving), its PCIe link (lanes: x4 of x8 points at a seat or the
  solder under the chip; speed is shown, not judged - GPUs slow the link at
  idle), the PCIe error counters (AER) and the kernel log ("fallen off the
  bus"). No GPU driver is loaded (invariant 1, the C40-K freeze): Ash chose
  this over a 3D stress test, which would have needed i915/amdgpu/nouveau and
  Mesa back in the image. It cannot see 3D speed or the video memory - the
  screen says so. Also in Full run's first stage (`--quiet`).
- **Fan test** (`fantest.sh`, Peripherals item 14; Ash). All cores at full
  load for 2 minutes, then 30 s of rest, watching the fan and the
  temperature. Where the laptop reports a fan speed (a hwmon fan input, an
  ACPI 4.0 fan's `fan_speed_rpm`) it decides; most Dynabooks report none, so
  halfway through the technician is asked whether warm air comes out of the
  vent (Ash's choice over temperature alone). A fan that turns while the CPU
  still nears its limit is MARGINAL: dust in the fins or dried paste.
- Home tiles from 5 on moved up one (Disk imaging is now 8).

## 1.23.0 — 2026-10-12
- **Macrium Reflect images** (Ash: "my macrium back up image is not readable,
  means that all of my previous image is failed to load"). Disk imaging now
  restores, browses and checks the .mrimg files Macrium Reflect 7/8 made -
  they show in the image list beside the toolkit's and Clonezilla's.
  - Macrium never published the Reflect 7/8 format. The layout comes from the
    mrimg7z project (reverse-engineered) and was checked against Ash's own
    image (PORTEGE X40-K, Windows 11, 512 GB, five partitions) and against
    images Macrium 8 made of known test disks - no compression, Medium,
    High, GPT and MBR: every file read back identical. Every block read is
    checked against the MD5 the image keeps for it, so a misread or damaged
    block stops the job instead of reaching a customer's drive.
  - Restore: the image is served as the drive it was made from (read-only)
    and restored with Clone's own plan - C: resized to fit the new drive,
    disk and partition IDs kept, the copy read back.
  - Browse an image and Check an image take Macrium images too.
  - Not yet: split images (several files), incremental / differential and
    password-protected images - each is listed with the reason, and Macrium
    itself restores them.
  - QuickLZ 1.31 (Macrium's compression, GPL) is built into the image as
    libqlz.so; `setup-host.sh` now installs gcc for it.

## 1.22.0 — 2026-10-12
Seven bench requests from Ash after 1.21.0.
- **Language at every boot**: after GRUB, before the home screen, a Language
  menu (title in all five scripts) opens on the language kept on the stick -
  Enter or Q goes on with it, a new choice is kept for the next boot. Not on
  the text console (no CJK font). New `tui_menu_at` / ui.py op `menuat`: a
  menu that opens on a given row. The language list's own names ("English",
  "English (UK)") are no longer translated - in Chinese the list said 英语.
- **A failed peripheral test looks for its driver** (Touchpad, Touchscreen,
  Sound, Camera, SD card, Wi-Fi, Ethernet, USB ports): menu.sh runs
  `drivercheck.sh --for` on that kind of device only, and anything not working
  is fixed with no question - known fixes, a driver restart, the missing
  firmware fetched online - then the test is offered again. A test that found
  no device at all is checked quietly: it only speaks when something can be
  fixed (a laptop without a touchscreen is not news).
- **Results text**: the report page drew at twice the body size on top of the
  Text size setting (4x at Huge). It opens at body size now; - and + step it
  from 80 % to 200 %, kept until the renderer restarts. At Huge the first
  lines no longer run into the title.
- **Disk imaging is tile 7**, beside Keyboard (was 18) - in both layouts;
  every tile after it moved up one.
- **Battery test without a USB stick** warns before the drain starts: "No USB
  stick for the battery log" - Check again, or Run without saving (the log in
  memory: press Q before it runs flat). Only USB sticks are offered for the
  log now (DIAGDATA, the boot stick through Ventoy's mapping, other sticks -
  never the laptop's own drives), and an interrupted log on a Ventoy stick is
  found again after the laptop dies.
- **Smoother pointer**: it moved like 10 Hz. Every hover that moved the
  highlight redrew the whole screen (150 ms for the home sheet) and the arrow
  froze for each. A hover now arrives once the pointer rests (60 ms); the
  arrow moves on every event, in one write instead of erase-then-paint
  (it flickered); between screens the main loop moves it too (it stood still,
  then jumped). Redrawing is cheaper as well: text widths and drawn icons
  are cached (home sheet 152 -> 100 ms).
- **Animations at 45 frames a second** (were 15): a frame costs 15-22 ms on
  an i7-8665U. While a test measures (disk, controller, install, RAM, CPU,
  network) its scene stays at 15 - at 45 the drawing takes most of a core,
  which a 2-core bench machine would take out of the figures.
- Keys: keypad + / - and Shift+= / Shift+- now type "+" and "_" (a Wi-Fi
  password with "+" got "=").

## 1.21.0 — 2026-10-08
- **Disk imaging** (`imaging.sh`, tile 18 on the home grid; Ash: "clone/backup
  image, split partition, works like macrium"). Stage 1 of 3: clone, back up,
  restore and check whole drives. Macrium's own format and its WinPE disk
  were not used - closed, and nothing to build on; the work is partclone,
  ntfsresize and sfdisk, the tools Clonezilla and GParted are made of.
  - **Clone a drive**: everything before C: (EFI, MSR, System Reserved) keeps
    its place and size; C: takes up the difference; whatever follows it (the
    WinRE partition) keeps its size and moves to the end. Disk and partition
    IDs stay the same - Windows' boot entries find C: by them. Only the used
    blocks are copied (partclone).
  - **Smaller new drive**: C: is copied onto a device as big as it used to be
    - the new partition plus a scratch area (device-mapper snapshot) - and
    shrunk there, so the overflow lands inside the new partition. The old
    drive is never written. ntfsresize's dry run says first how much has to
    move: memory when it fits, else a USB drive, else (Ash's choice) C: is
    shrunk on the old drive itself - only if SMART says PASSED, only after
    SHRINK is typed, and grown back afterwards.
  - **The drive being copied is set read-only in the kernel** (`blockdev
    --setro`) for the whole job, and put back afterwards, even when stopped.
  - **BitLocker**: unlocked read-only with the 48-digit recovery key (the
    screen shows the Key ID to look it up by), then copied data-only and
    resizable - BitLocker is off on the copy, and the screen says so. Left
    locked, it is copied sector for sector at full size.
  - **Fast Startup / hibernation and chkdsk flags** are read from the drive
    (hiberfil.sys's "HIBR" - ntfsresize --info does not look). Such a C:
    copies as it is; when resizing is what it blocks, the screen offers to
    discard the saved session (or clear the flag) by name.
  - **Back up / restore / check an image**: to a USB drive or the toolkit
    stick's own Ventoy partition (through Ventoy's mapping, like the
    settings). The folder is Clonezilla's layout and file names, so
    Clonezilla restores it, and Clonezilla images restore here. Restore
    resizes to the target drive like a clone. Check reads every partition
    back through partclone's checksums.
  - Every write goes through a plan the planner approved: a refused plan
    once reached the drive in testing and wrote its table - the engine now
    checks. ERASE is typed before any drive is replaced.
  - Tested (`test/imaging-loop.sh`, 51 checks on loop drives in WSL): clone
    bigger, smaller through scratch, smaller by source shrink, back up,
    verify (a damaged image is caught), restore bigger and smaller, restore
    a Clonezilla-only image, an MBR drive (signature, boot flag, boot code),
    a refused plan, Q mid-copy. Every file checksummed; the source image
    file unchanged to the byte. `test/imgplan_test.py` (20 layout cases) runs
    in the build. Not yet on real hardware: a real Windows boot after a
    clone, BitLocker unlock (no BitLocker volume to test with), a Ventoy
    stick as the image store.
- **Partitions** (Disk imaging -> Partitions, `partitions.sh`; Ash: "drag and
  drop partition, create partition on unallocated space"). Stage 2 of 3.
  - The drive is drawn twice, now and after - Ash's pick of three rendered
    samples. The After bar is dragged with the mouse, touchpad (click and
    hold) or touchscreen: an edge resizes, the middle moves. Keys do the
    same ([ ] size, Shift+arrows move). New in free space (NTFS, exFAT,
    FAT32, ext4), delete, format, exact size, undo.
  - Each partition says how far it can go: C: down to what it holds plus
    room; FAT, MSR and BitLocker partitions move but keep their size; a
    hibernated or chkdsk-flagged C: neither moves nor resizes, with the
    reason and the fix on screen.
  - Nothing is written until Apply, which lists the steps in the order they
    run (deletes, shrinks, moves, grows, then new partitions and formats),
    defaults to NO and wants ERASE typed when anything is deleted or
    formatted, APPLY otherwise. A move asks for the charger on battery, and
    Q during a move waits for it to finish - half a move is a lost partition.
  - Moves are sfdisk's own (`--move-data`), its progress read from the
    kernel's write count; a moved NTFS gets its boot sectors' start fixed.
    The table on the drive is checked against the plan afterwards.
  - A C: the toolkit resized this session is no longer taken for "marked
    for a disk check" (ntfsresize flags it for Windows on purpose), so it can
    be resized again without a reboot.
  - Tested: `test/imgparted_test.py` (18 cases, in the build) and the loop
    drives - split C: (data moved) into C: + D:, move Recovery left and
    right with C: grown, format and delete, Q during a move.
- **Browse an image** (Disk imaging -> Browse an image, `imgbrowse.sh`; Ash:
  "Browse files in image"). Stage 3 of 3 - a customer's Documents back out
  of a backup without restoring the drive.
  - The partition is read straight out of the image: partclone's bitmap says
    where each block sits in the stream, the frame index saved with every
    image (diag/<part>.idx) says which 32 MB zstd frame holds it. Served to
    the kernel as a read-only block device (NBD, no network) and mounted
    read-only - the image is never written, and nothing is unpacked first.
  - Pick the partition (C:, EFI, Recovery, D:...), walk its folders, copy a
    file or a folder next to the image or to another USB drive, with
    progress; an existing copy is never overwritten ("Documents (2)",
    "report (2).docx"). A BitLocker partition saved locked opens with the
    recovery key, read-only. FAT32 drives are refused for a file over 4 GB,
    up front, and FAT is mounted with UTF-8 names (the kernel's default,
    iso8859-1, cannot write a Chinese file name).
  - A copy says exactly what is missing: a file or folder the image cannot
    give back is named, never quietly left out, and a drive that stops
    taking writes is blamed, not the image; no half-written file is left
    under its real name. Only folders and ordinary files are shown - an
    ext4 image's FIFOs and device nodes would hang a copy or read this
    laptop's own disk (mounted nodev).
  - Clonezilla's own images (one zstd frame, or gzip) cannot be read in the
    middle; the list says so - restore them instead.
  - Tested: `test/imgbrowse_test.py` (19 cases, in the build: block layouts,
    checksums, frames cut mid-block, image pieces, a damaged frame, the
    partition's full size; listing and copying with a FIFO, a link, read and
    write errors) and the loop drives - every file of C: and EFI read back
    out of a backup, copy, read-only device and mount, a wrong index
    refused.
- Text interface: `tui_para` was missing, so charging, CPU, controller check
  and error log lost their wrapped lines when there was no framebuffer.
- **Linux 7.0** (noble's HWE kernel) instead of 6.8, for every machine (Ash's
  choice). The PORTEGE Z40L-P (Core Ultra 5 325, Panther Lake) showed its
  Wi-Fi as "firmware missing" and Fix downloaded the package again:
  - its firmware was on the stick all along (versions 101 to 103)
  - Linux 6.8's driver loads Intel firmware only up to version 86

  Linux 7.0's driver (iwlmld) loads it. The build now asserts kernel 7.0+,
  Intel's Wi-Fi 7 driver, the THC touchpad controller (Lunar / Panther
  Lake) and the modules disk imaging needs. trim.sh also removes 7.0's new
  VFIO "xe" helper, which the graphics check (invariant 1) flagged.
- **Driver check**: when a driver's firmware is on the stick but only in
  versions it cannot load, it now says the toolkit is too old for the
  device, not that the device is faulty, and Fix offers no download. The
  closing line no longer blames "the part itself, its connector, or a BIOS
  setting" in that case. A host bridge that only an old chipset driver
  half-matches (intel_agp on QEMU's 440FX, new with 7.0) is not "not
  working".
- **System information -> More info** (M on the System page; Ash):
  - the motherboard
  - each Ethernet card with its MAC address and port speed (the port is
    switched on first; "up to 1 Gbps - now: 1000 Mbps, full duplex")
  - each Wi-Fi card with its MAC address, the Wi-Fi standard it can do (Wi-Fi
    4 to 7, with 6E when it has 6 GHz) and the bands, and the link it has
    now when connected
  - PCIe: the ports in use of those the BIOS enabled, the fastest
    generation, and each device's link against what it can do
  - a card with no driver running is listed as such, not left out
  - all of it in the report as well
- **Languages** (Settings -> Language, item 4; Ash): English, English (UK),
  简体中文, 繁體中文, 日本語, 한국어 - every screen, translated in the
  renderer (`i18n.py`) as each string is drawn, so no test script changed
  and the tests still read their own figures in English. Chinese, Japanese
  and Korean are drawn in Noto Sans CJK (fonts-noto-cjk, Sans only). The
  catalogues (`toolkit/i18n/`) are machine translations of the ~3,400
  strings `test/i18n_extract.py` finds; they want a native speaker's check.
  English (UK) is spelling rules (colour, centre, analyse). The saved report
  and the text-only fallback stay in English. Long explanations
  (`tui_para`: a test's likely cause and what to do) are now wrapped by the
  renderer after translating - bash cut them into 95-character English
  pieces, which no catalogue entry could match. Wrapped lines keep the
  spaces as written (a file name "报告 2025.docx" lost its space) and never
  start with closing punctuation (）。，). FAT sticks are mounted with UTF-8
  names, so Chinese file names copy out of an image intact.

## 1.20.1 — 2026-10-08
- **A changed theme came back as the old one after a reboot** (Ash). Three
  faults stacked:
  - Settings live in RAM; keeping them took "Save settings to the USB stick".
  - Even then, the next boot only looked inside the ISO's own filesystem. On
    a Ventoy stick that is the read-only ISO image, so the saved copy was
    never found.
  - When it was found, it was copied in after the renderer had already
    started and read its settings, so the first screens kept the default.

  Now every change (theme, menu style, text size, opening menu, test
  defaults) is written to the boot stick as it is made, and read back before
  the renderer starts. Where it goes:
  - a partition labelled DIAGDATA, if there is one
  - otherwise the boot stick's own partition: a FAT stick's medium, or
    Ventoy's partition through the device-mapper copy that Ventoy 1.1.01 and
    later make of it - the plain device is locked while an ISO on it is
    booted

  Never the laptop's own drives, and never a stick plugged in for a test.
  Every change message says whether the next boot will have it; when it
  will not, it says why (an older Ventoy, a dd-written stick, booted from a
  CD) and what to do. Settings item 7 now shows where they are kept, and
  Reset clears the stick's copy too.

## 1.20.0 — 2026-10-07
New tests from the 1.19 review (Ash: "go ahead"), and network checks taken
from the netprobe agent where they apply to a laptop on the bench.
- **Hardware error log** (`errlog.sh`, tile 17 on the home grid, last step of
  Full run): reads the kernel log since boot - and the boot copy menu.sh
  keeps - for faults no test watches. It looks for:
  - USB over-current and devices that will not start
  - SATA link errors and NVMe resets
  - drive I/O errors
  - processor machine checks and memory (EDAC) errors
  - PCIe errors, from the log and the AER counters
  - overheating
  - Wi-Fi and Bluetooth firmware failures
  - touchpad bus and SD reader errors

  Each finding says what to do. Matches nothing a healthy boot logs (checked
  against a synthetic log and WSL's real one).
- **CPU test: held back while cool** - a processor pinned at 400-800 MHz by
  the board (BD PROCHOT: a charger it does not accept, a failing battery, a
  sensor) stayed cool and PASSED. The clock under load (samples below 85 C)
  is now compared with the base clock; on Intel the PROCHOT status bit (MSR
  0x19c bit 2, read only) is shown as evidence.
- **SD card reader** (`sdtest.sh`, Peripherals tile 12):
  - The slot counts only when a card goes in during the test.
  - The bus mode is read from the kernel (SDR104, High Speed...).
  - The card is read briefly; nothing is written to it.
  - The card going out must be noticed too (a stuck card-detect switch).
- **Lid sensor** (`lidtest.sh`, Peripherals tile 13): close and open, read
  from the kernel's switch (`swstate.py`, EVIOCGSW - numbers from a C probe).
  2-in-1s also fold into tablet mode and back. A sensor reading "closed"
  while the screen is in use is a FAIL on the spot.
- **Headphone jack** in the Sound test: plug-in and removal through the
  jack's switch, a tone per ear, and the answer "it came from the speakers"
  - the jack's plug-detect switch.
- **Ethernet and Wi-Fi checks go out of the adapter under test** (`netcheck.sh`).
  Before, with Wi-Fi joined from the home screen, the Ethernet test's internet
  and DNS checks went out over Wi-Fi, and a dead port could pass. dhclient
  gave the second link no default route at all ("File exists"); one is added
  at a high metric. New checks, shared by both tests:
  - router quality from 20 pings
  - internet by ping *and* by web (ping blocked is not a fault)
  - DNS asked of the network's server and of 1.1.1.1 directly
  - a login page (captive portal) in the way
  - a secure connection
  - **the hardware clock against the internet's**: a flat CMOS battery, with
    Windows' local-time offset and ordinary drift allowed for

  A "likely cause" names the first layer that fails, and says when it is
  the network's fault and not the laptop's. Network-side faults no longer
  fail the laptop's port.
- **Ethernet**:
  - the wire's error counters are read before and after a 50 MB download
    (CRC and frame errors point at the cable, the socket or the chip)
  - 100 Mbit/s on a gigabit port, when the switch also offers 1000, is
    called a broken pair
  - DHCP failure says why (no answer, or offered but not confirmed)
  - the result screen fits 1366x768
- **Wi-Fi**:
  - the signal on each antenna from `iw station dump`: 20 dB apart = a lead
    off or broken (FAIL), 12 = WARN; the overall figure hid this
  - the share of retried frames
  - the link kind: Wi-Fi 4/5/6/7, channel width, streams
  - the gateway is this link's own (the old fallback took the cable's)
- **Build**: every script is syntax-checked and every .py compiled before the
  ISO is made; `/opt/diag/build-epoch` records the build date.
- **Two anime themes** (Settings -> Colour theme; Ash: "i want mecha common
  deck and kawaii paster both"). Each is a whole skin (`skins.py`): the
  header, home grid, menus, cards, badges, bars, YES/NO and the How-it-works
  title and LIVE chip. Row positions are unchanged, so no test script knows
  which skin is on.
  - **Mecha command deck**: a black launch deck; every test is a chamfered
    bay with a status lamp, and a failed bay is outlined red. Orange marks
    only the selection. Hazard stripes appear only on the deck's furniture.
    Display face: Bebas Neue.
  - **Kawaii pastel**: a pink sticker sheet; results are reward stamps
    (WARN in honey). Sparkles appear only in the margins, candy stripes only
    inside bar fills. Display face: Comfortaa.

  Ash ruled out a mascot, busy art behind text and Japanese lettering. Every
  word keeps 4.5:1 or better. The themes work from 1024x768 and at 150 %
  text. The fonts come from Ubuntu's fonts-bebas-neue / fonts-comfortaa
  (OFL); the build asserts them and runs `skins.py --check`. Light stays the
  default. Fixed on the way: the dark and high-contrast themes drew PASS/FAIL
  badges in the light theme's colours (the badge table was built once at
  start-up).

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
