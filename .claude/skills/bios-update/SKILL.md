---
name: bios-update
description: How the toolkit's BIOS update (tile 20, biosupdate.sh / biospkg.py, since 1.28) works and the UEFI traps found building it - package layout, checks, startup.nsh, BootNext and the way back, --result. Use before changing biosupdate.sh, biospkg.py, the boot-entry handling, or testing it in the OVMF VM.
---

# BIOS update (tile 20)

Invariant 4 (CLAUDE.md) is the limit: the toolkit only *starts the maker's own
flasher with the maker's own image*, matching model only, newer only, after
UPDATE is typed, never in Full run. Never a force option (ChgFirmA's `/f`),
never a vendor binary in the ISO.

## Packages

- Live in `DIAGDATA\BIOS\<folder as Dynabook names it>`; DIAGDATA must be
  FAT32 - the firmware reads nothing else.
  - X30L-M_B210_USB: ShellFlash64.efi + one .bin
  - X30L-K_B860_..._USB: ChgFirmA.efi + one .BIN - also one folder down, as
    Windows' Extract All leaves it (a package folder holding only one folder
    is looked into).
- `biospkg.py` decides what may be offered: model and version from the folder
  name, whole-word model match on DMI (product name, version, board - not the
  series' family), newer only, names the Shell can run as written. Tests:
  `test/biospkg_test.py`, run by the build.
- Package and file names: letters, digits, `. _ -` only - startup.nsh runs
  them as written (a space splits, `%` expands).

## Checks before anything is written

Model (biospkg, DMI from /sys - never the report overrides), newer only, AC,
battery >= 30 %, BitLocker warning, unsaved results (the report in RAM is lost
across the restart - offer to save first), UPDATE typed.

## What it writes

- On DIAGDATA `BIOS\.diag\`: the EDK2 Shell + `startup.nsh` + the note.
  startup.nsh (CRLF) finds DIAGDATA by pending.txt, `setvar BootNext` to the
  way back, runs the flasher (changing into an inner folder if the package
  has one), waits for a key, `reset`.
- Two efibootmgr entries made with `-C`:
  - the Shell, as **BootNext only** - never in BootOrder: a forgotten one must
    not start the flasher again;
  - the way back to the stick's `\EFI\BOOT\BOOTX64.EFI`, **last** in
    BootOrder.
- Nothing restarts unless startup.nsh reads back whole (ends in `reset`).
  With no way back set, the countdown says "start the stick with F12".

## After the restart: `--result`

menu.sh runs `biosupdate.sh --result` after the Language menu, at every
start. It first drops both entries (and a BootNext pointing at one), note or
not - an entry left by a start from another stick could run the flasher with
nobody typing UPDATE - then matches the note by serial, writes the RESULT
line, and `undo_prepare` removes `.diag`. The note is the only state across
the restart.

## UEFI traps (all found in the OVMF VM, 1.28)

- A dd-written hybrid ISO starts with El Torito: the firmware then shows its
  CD image and none of the partitions after it ("Not Found" for a file on an
  added partition 3). Test on a stick laid out like Ventoy's (plain GPT: EFI
  partition + the ISO in a partition + DIAGDATA). The 1.28 session built one
  with a scratch script (mkuefistick.sh) that was not committed - rebuild it.
- Firmware may delete at start-up every Boot#### its BootOrder does not list,
  sparing only the BootNext target (OVMF does). With a QEMU `bootindex` OVMF
  also rewrites BootOrder from QEMU's order every boot - leave bootindex off to
  see a real laptop's behaviour. An entry that must outlast the next boot goes
  last in BootOrder.
- EDK2 Shell: it runs `startup.nsh` from its own folder; `echo` takes a bare
  ` - ` for an option (quote the words); `setvar BootNext -guid
  8BE4DF61-93CA-11D2-AA0D-00E098032B8C -bs -rt -nv =0300` sets Boot0003 (two
  bytes, little-endian); `pause` quits the script on q.
- In the VM: test_power (a charger) is gone after every restart; type UPDATE
  slowly (type.py drops letters on a busy VM).
- Dress OVMF as the model with `-smbios type=1,...`. Dynabook's flashers
  refuse to flash in the VM (ShellFlash64: "Unable to detect BIOS
  communication service channel"; ChgFirmA's UpdateCapsule: "Unsupported") -
  the VM proves everything up to the flasher starting and the way back.

What is still unseen on a real machine: `docs/OPEN.md`, 1.28.
