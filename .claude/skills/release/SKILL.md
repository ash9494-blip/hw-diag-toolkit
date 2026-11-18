---
name: release
description: Deliver a new version of the Hardware Diagnostic Toolkit ISO to Ash - bump DIAG_VERSION, build, boot-test, write the HISTORY entry, give the SHA256. Use when a change is ready to ship or Ash asks for a new ISO.
---

# Delivering a version to Ash

Ash copies `hw-diagnostic-toolkit vX.Y.Z.iso` to a Ventoy stick and boots it
on the bench. Every version goes through the same steps:

1. **Bump `DIAG_VERSION`** in `toolkit/lib.sh` and the "Current version" line
   at the top of `CLAUDE.md`.
2. **Checks that need no build** (Pillow installed):
   `python3 toolkit/ssdanim.py --check`, `python3 toolkit/hwanim.py --check`,
   `python3 toolkit/skins.py --check`, `python3 toolkit/i18n.py --check`;
   `python3 test/i18n_extract.py --merge toolkit/i18n/zh_CN.json` lists
   on-screen strings missing from the catalogues - fill every language.
   After any change to `img*.py`: `sudo test/imaging-loop.sh` (~20 min; do not
   edit a bash script while it runs).
3. **Build**: `sudo ./build-all.sh quick` after toolkit/ edits, or
   `sudo ./build-all.sh` from nothing. build-all.sh verifies the version in the
   built squashfs (invariant 3) - never trust the source tree alone. Run it
   from the Linux filesystem, never `/mnt/<drive>` on WSL.
4. **Boot it and look** - see the `vm-test` skill. The renderer smoke test
   does not catch most UI regressions. Say plainly what was only VM-verified
   (QEMU has no GPU driver faults, radio, touchpad, battery, charger, lid).
5. **`docs/HISTORY.md`**: a short entry at the top, `## X.Y.Z — YYYY-MM-DD`,
   one bullet per change, quoting Ash's request where there was one, and the
   reason (usually the bug) behind each change.
6. **Open items**: add what still needs a real machine to `docs/OPEN.md`
   (newest version first); remove what Ash has confirmed.
7. **SHA256**: `sha256sum hw-diagnostic-toolkit.iso`. Put it in the HISTORY
   entry and the commit message, and give it to Ash with the file name
   `hw-diagnostic-toolkit vX.Y.Z.iso`. (CLAUDE.md does not carry the SHA -
   HISTORY.md is the one place.)
8. Commit on the session's branch and push. No model names in commits.
