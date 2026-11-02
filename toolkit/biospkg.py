#!/usr/bin/env python3
"""Which BIOS packages on the stick this laptop may be updated with (1.28,
Ash: "can you add one features is to update BIOS in tools?").

A package is a folder in DIAGDATA\\BIOS exactly as Dynabook ships it for a
USB update - "X30L-M_B210_USB": the model, then B and the version (210 =
2.10) - holding the maker's flasher, ShellFlash64.efi (Phoenix SCT Flash,
a UEFI Shell program), and one BIOS image (.bin, a UEFI capsule). The
toolkit never writes firmware itself: biosupdate.sh only starts that
flasher with that image (CLAUDE.md, invariant 4). This file decides what
may be offered:

- the folder holds ShellFlash64.efi and exactly one .bin, else it is "not a
  USB BIOS package the toolkit can run" (an old Toshiba package, a Windows
  .exe updater) - listed, never offered;
- the folder's and the files' names are letters, digits, . _ - only: the
  Shell's script runs them as written ("BIOS0126 (1).bin" from a second
  download would be two words);
- the model in the name is this laptop's, as its firmware names the model
  (DMI product name, version, board - not the family, which names the
  series) - a word of its own there: X30L-M is not X30L-MA. No override
  (Ash);
- the version is newer than the laptop's BIOS - same or older is refused,
  and so is a laptop whose version cannot be read (Ash: newer only).

    biospkg.py list BIOSDIR [--dmi DIR]   one line per folder:
        folder|state|model|version|current|reason|flasher|image
        state: ok, same, older, unknown, other-model, no-version, not-package,
               bad-name
    biospkg.py current [--dmi DIR]        this laptop's BIOS version (2.00)
    biospkg.py model [--dmi DIR]          this laptop's model, as DMI says it
"""
import os
import re
import sys

DMI = "/sys/class/dmi/id"
FLASHER = "shellflash64.efi"            # the name compared without case (FAT)
NAME = re.compile(r"^(?P<model>[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)_[Bb](?P<ver>\d{3})(?:_|$)")
VERSION = re.compile(r"(\d+)\.(\d+)")
NOT_PACKAGE = "not a USB BIOS package the toolkit can run"
SHELL_SAFE = re.compile(r"^[A-Za-z0-9._-]+$")
BAD_NAME = "a name with spaces or signs the UEFI Shell cannot run - rename it as Dynabook ships it"


def dmi(field, root=DMI):
    try:
        with open(os.path.join(root, field), errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def parse_name(folder):
    """("X30L-M", (2, 10)) from "X30L-M_B210_USB"; None when the name does
    not say both."""
    m = NAME.match(folder)
    if not m:
        return None
    v = m.group("ver")
    return m.group("model"), (int(v[0]), int(v[1:]))


def version_of(text):
    """(2, 10) from the laptop's "Version 2.10"; None when there is none."""
    m = VERSION.search(text or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def vstr(v):
    return "%d.%02d" % v if v else ""


def model_matches(model, texts):
    """The model as a word of its own in what the firmware says the laptop
    is: X30L-M in "dynabook PORTEGE X30L-M", not in "PORTEGE X30L-MA"."""
    word = re.compile(r"(?<![A-Za-z0-9-])%s(?![A-Za-z0-9-])" % re.escape(model), re.I)
    return any(word.search(t or "") for t in texts)


def laptop(root=DMI):
    """What the firmware says this laptop is, and its BIOS version. Not
    product_family: that is the series ("PORTEGE X30L"), and a package named
    for a series would match every model in it."""
    names = [dmi(f, root) for f in ("product_name", "product_version", "board_name")]
    return names, version_of(dmi("bios_version", root))


def package_files(path):
    """(flasher, image) file names in the folder, or None: the flasher and
    exactly one .bin, nothing to guess between."""
    try:
        names = [n for n in os.listdir(path) if os.path.isfile(os.path.join(path, n))]
    except OSError:
        return None
    flasher = [n for n in names if n.lower() == FLASHER]
    images = [n for n in names if n.lower().endswith(".bin")]
    if len(flasher) != 1 or len(images) != 1:
        return None
    return flasher[0], images[0]


def judge(folder, path, names, current):
    """One folder: (state, model, version, reason, flasher, image)."""
    files = package_files(path)
    if files is None:
        return "not-package", "", None, NOT_PACKAGE, "", ""
    if not all(SHELL_SAFE.match(n) for n in (folder, *files)):
        return "bad-name", "", None, BAD_NAME, *files
    parsed = parse_name(folder)
    if parsed is None:
        return "no-version", "", None, "the folder name does not say the model and version " \
                                       "(like X30L-M_B210_USB)", *files
    model, version = parsed
    if not model_matches(model, names):
        this = next((n for n in names if n), "") or "unknown"
        return "other-model", model, version, "for the %s - this laptop is a %s" % (model, this), *files
    if current is None:
        return "unknown", model, version, "this laptop's BIOS version cannot be read", *files
    if version == current:
        return "same", model, version, "the same version as this laptop's BIOS", *files
    if version < current:
        return "older", model, version, "older than this laptop's BIOS (%s)" % vstr(current), *files
    return "ok", model, version, "%s -> %s" % (vstr(current), vstr(version)), *files


def scan(bios_dir, root=DMI):
    """Every folder in bios_dir, offered ones first, then by name."""
    names, current = laptop(root)
    out = []
    try:
        folders = sorted(n for n in os.listdir(bios_dir)
                         if not n.startswith(".") and os.path.isdir(os.path.join(bios_dir, n)))
    except OSError:
        folders = []
    for folder in folders:
        state, model, version, reason, flasher, image = judge(folder, os.path.join(bios_dir, folder),
                                                              names, current)
        out.append(dict(folder=folder, state=state, model=model, version=vstr(version),
                        current=vstr(current), reason=reason, flasher=flasher, image=image))
    out.sort(key=lambda p: (p["state"] != "ok", p["folder"].lower()))
    return out


def _line(*cells):
    return "|".join(re.sub(r"[\x00-\x1f|]", " ", str(c)) for c in cells)


def main(argv):
    root = DMI
    if "--dmi" in argv:
        root = argv[argv.index("--dmi") + 1]
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "list" and len(argv) > 2:
        for p in scan(argv[2], root):
            print(_line(p["folder"], p["state"], p["model"], p["version"], p["current"], p["reason"],
                        p["flasher"], p["image"]))
    elif cmd == "current":
        print(vstr(laptop(root)[1]))
    elif cmd == "model":
        print(next((n for n in laptop(root)[0] if n), ""))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
