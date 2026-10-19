#!/usr/bin/env python3
"""Where each partition goes on the new drive - the clone / restore planner.

Pure arithmetic over a disk description (imgscan.py makes one from a real
drive, imgengine.py from an image's saved table); nothing here touches a disk,
so test/imgplan_test.py covers it on any machine.

The rules are Macrium's "clone this disk" defaults, which is what Ash expects:
  * everything before the system partition (EFI, MSR, System Reserved) keeps
    its exact place and size;
  * the system partition (the largest one - Windows C:) takes up the
    difference, bigger or smaller;
  * whatever follows it (the WinRE recovery partition) keeps its size and moves
    to the end of the new drive;
  * the disk and partition IDs stay the same, because Windows' boot entries
    find C: by them - a clone with new IDs does not start.

Sizes in user-facing text are 1024-based "GB", the way Windows Explorer and
Disk Management show them: Ash compares these numbers with what Windows says.
"""

MiB = 1024 ** 2
GiB = 1024 ** 3
ALIGN_BYTES = MiB
GPT_TAIL = 33                    # backup GPT: 32 sectors of entries + header

# filesystems partclone copies used-blocks-only; anything else is copied whole
FS_COPY = {"ntfs", "vfat", "exfat", "ext2", "ext3", "ext4", "btrfs", "xfs", "f2fs"}
# and the ones this toolkit can also resize (ntfsresize, resize2fs)
FS_RESIZE = {"ntfs", "ext2", "ext3", "ext4"}
DOS_EXTENDED = {"5", "f", "85"}


def gb(n):
    if n is None:
        return "?"
    if n < GiB:
        return "%d MB" % round(n / MiB)
    return "%.1f GB" % (n / GiB) if n < 100 * GiB else "%d GB" % round(n / GiB)


def shrink_margin(min_bytes):
    """Room left over on a shrunk partition: Windows needs space to update and
    a C: cut to the last byte would be full on its first start."""
    return max(GiB, (min_bytes or 0) // 20)


def part_node(disk, num):
    return "/dev/%s%s%d" % (disk, "p" if disk[-1:].isdigit() else "", num)


def _dos_type(p):
    return str(p.get("type", "")).lower().replace("0x", "")


def _is_extended(label, p):
    return label == "dos" and _dos_type(p) in DOS_EXTENDED


def copy_method(label, p):
    if _is_extended(label, p):
        return "skip"                 # the container: sfdisk recreates it
    if p.get("fs") == "swap":
        return "swap"
    if p.get("fs") in FS_COPY and p.get("state") != "locked":
        return "fs"
    return "raw"


def resizable(p):
    return p.get("fs") in FS_RESIZE and p.get("state") in ("ok", "unlocked")


def pname(p, system=None):
    if system is not None and p is system:
        return "C:"
    if p.get("label"):
        return "%s (partition %d)" % (p["label"], p["num"])
    return "partition %d" % p["num"]


def _why_fixed(p):
    """Why the system partition must keep its size - with what to do about it."""
    st = p.get("state")
    if st == "locked":
        return ("C: is locked with BitLocker, so it can only be copied sector by "
                "sector at its full size. Unlock it with the recovery key to copy "
                "just the data, or shrink C: in Windows Disk Management first.")
    if st == "hibernated":
        return ("Windows on C: is hibernated (Fast Startup), so C: cannot be "
                "resized. Start Windows, hold Shift while you click Shut down, "
                "then try again.")
    if st == "dirty":
        return ("C: is marked for a disk check, so it cannot be resized. Start "
                "Windows once and let the check finish, then try again.")
    return ("C: (%s) cannot be resized by this toolkit, so it keeps its size."
            % (p.get("fs") or "no filesystem"))


def _align_down(v, a):
    return v // a * a


def _same_layout(src, parts, end_limit, sec, system, errors, notes, why=None):
    for q in parts:
        q["nstart"], q["nsize"] = q["start"], q["size"]
    src_end = max(q["start"] + q["size"] for q in parts)
    if src_end > end_limit:
        need = src_end * sec
        msg = "The partitions take %s and the new drive has %s." % (gb(need), gb(end_limit * sec))
        errors.append(msg + (" " + why if why else ""))
        return None
    free = (end_limit - src_end) * sec
    if free >= GiB:
        if why and system is not None and system.get("state") == "locked":
            notes.append("%s left unallocated at the end - extend C: in Windows Disk "
                         "Management afterwards (works with BitLocker on)." % gb(free))
        elif why:
            notes.append("%s left unallocated at the end. %s" % (gb(free), why))
        else:
            notes.append("%s left unallocated at the end of the new drive." % gb(free))
    return free


def plan(src, target, keep_size=False):
    """src: disk description; target: {"name", "bytes", "sector"}.
    Returns the plan: the parts with nstart/nsize/how/grow/shrink, the index
    of the resized one, unallocated space left, notes, and errors (ok=False
    when any)."""
    errors, notes = [], []
    sec = int(src.get("sector") or 512)
    label = src.get("label", "gpt")
    out = {"ok": False, "errors": errors, "notes": notes, "label": label,
           "id": src.get("id", ""), "firstlba": src.get("firstlba"),
           "sector": sec, "source": src.get("name", ""), "target": target.get("name", ""),
           "target_bytes": int(target.get("bytes", 0)), "resize": None,
           "source_bytes": int(src.get("bytes") or 0),
           "free_after": 0, "parts": []}
    tsec = int(target.get("sector") or 512)
    if tsec != sec:
        errors.append("The new drive uses %d-byte sectors and the old one %d-byte sectors. "
                      "A copy made like this would not boot once the drive is fitted inside. "
                      "Connect the new drive another way (fit it inside and put the old one "
                      "in the USB adapter), or use a different adapter." % (tsec, sec))
        return out
    if not src.get("parts"):
        errors.append("The source drive has no partitions - there is nothing to copy.")
        return out

    parts = [dict(p) for p in sorted(src["parts"], key=lambda p: p["start"])]
    for q in parts:
        q["how"] = copy_method(label, q)
        q["grow"] = q["shrink"] = False
    out["parts"] = parts
    end_limit = out["target_bytes"] // sec - (GPT_TAIL if label == "gpt" else 0)
    align = max(1, ALIGN_BYTES // sec)

    real = [q for q in parts if q["how"] != "skip" and not _is_extended(label, q)]
    system = max(real, key=lambda q: q["size"]) if real else None
    if system is not None and system.get("state") == "unlocked":
        notes.append("C: is copied unlocked: BitLocker will be OFF on the new drive. "
                     "Turn it back on in Windows if the customer needs it.")

    if any(_is_extended(label, q) for q in parts):
        notes.append("This drive has extended partitions, so the layout is copied "
                     "exactly as it is.")
        free = _same_layout(src, parts, end_limit, sec, system, errors, notes)
    elif keep_size:
        free = _same_layout(src, parts, end_limit, sec, system, errors, notes)
    elif system is None or not resizable(system):
        free = _same_layout(src, parts, end_limit, sec, system, errors, notes,
                            why=_why_fixed(system) if system else None)
    else:
        free = _resize_system(parts, parts.index(system), end_limit, align, sec,
                              errors, notes)
        out["resize"] = parts.index(system) if (system["grow"] or system["shrink"]) else None

    if errors:
        return out
    out["free_after"] = free or 0
    notes.append("The new drive gets the same disk ID as the old one, so Windows starts "
                 "from it. Do not start Windows with both drives connected.")
    out["ok"] = True
    return out


def _resize_system(parts, i, end_limit, align, sec, errors, notes):
    system = parts[i]
    after = parts[i + 1:]
    end = _align_down(end_limit, align)
    for q in reversed(after):            # pack them against the end of the drive
        q["nstart"] = _align_down(end - q["size"], align)
        q["nsize"] = q["size"]
        end = q["nstart"]
    for q in parts[:i]:
        q["nstart"], q["nsize"] = q["start"], q["size"]
    system["nstart"] = system["start"]
    system["nsize"] = end - system["start"]
    have = system["nsize"] * sec
    smallest = system.get("min") or system.get("used") or system["size"] * sec
    need = smallest + shrink_margin(smallest)
    if system["nsize"] <= 0 or (system["nsize"] < system["size"] and have < need):
        held = system.get("used") or smallest
        if system["nsize"] <= 0:
            errors.append("The partitions after C: (%s) leave no room for C: on the new drive."
                          % gb(sum(q["size"] for q in after) * sec))
        else:
            errors.append("C: holds %s of data and needs at least %s; the new drive leaves "
                          "room for %s. Use a bigger drive, or delete files in Windows first."
                          % (gb(held), gb(need), gb(have)))
        return None
    if system["nsize"] > system["size"]:
        system["grow"] = True
    elif system["nsize"] < system["size"]:
        system["shrink"] = True
        notes.append("C: is shrunk from %s to %s. Windows checks the disk once on its "
                     "first start - let it finish." % (gb(system["size"] * sec), gb(have)))
    last = max(q["nstart"] + q["nsize"] for q in parts)
    return (end_limit - last) * sec


# ---------------------------------------------------------------- sfdisk
def _clean(text):
    """A GPT name or attribute list goes inside quotes in the sfdisk script:
    a quote or newline in it must not end the field and start another."""
    return "".join(c for c in str(text) if c >= " " and c not in '"\\')


def _hexish(text):
    t = str(text)
    return t if t and all(c in "0123456789abcdefABCDEFx-" for c in t) else ""


def sfdisk_script(p):
    lines = ["label: %s" % p["label"]]
    if _hexish(p.get("id")):
        lines.append("label-id: %s" % p["id"])
    lines.append("unit: sectors")
    if p["label"] == "gpt" and p.get("firstlba"):
        lines.append("first-lba: %d" % int(p["firstlba"]))
    lines.append("sector-size: %d" % p["sector"])
    lines.append("")
    for q in sorted(p["parts"], key=lambda q: q["num"]):
        f = ["start=%d" % q["nstart"], "size=%d" % q["nsize"]]
        t = _hexish(q.get("type"))
        if t:
            f.append("type=%s" % (t.lower().replace("0x", "") if p["label"] == "dos" else t))
        if p["label"] == "gpt":
            if _hexish(q.get("uuid")):
                f.append("uuid=%s" % q["uuid"])
            if q.get("name"):
                f.append('name="%s"' % _clean(q["name"]))
            if q.get("attrs"):
                f.append('attrs="%s"' % _clean(q["attrs"]))
        elif q.get("bootable"):
            f.append("bootable")
        lines.append("%s : %s" % (part_node(p["target"], q["num"]), ", ".join(f)))
    return "\n".join(lines) + "\n"
