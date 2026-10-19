#!/usr/bin/env python3
"""The partition editor's model and its work: resize, move, split, create,
delete, format - GParted's jobs, the way Ash asked for them ("drag and drop
partition, create partition on unallocated space").

The screen (ui.py's partedit, run from partitions.sh) only ever changes the
"after" picture of the drive. Nothing is written until Apply; then the
difference between now and after becomes a list of steps in an order that
cannot collide: deletes, shrinks, moves (leftward ones left to right,
rightward ones right to left), grows, then new partitions and formats.

    imgparted.py load DISK STATE.json        a fresh state from the drive
    imgparted.py ops STATE                   the steps Apply will run, one a line
    imgparted.py problems STATE              E|reason (blocks Apply), W|warning
    imgparted.py gaps STATE                  index|start|size|"12.3 GB"
    imgparted.py new STATE GAP FS LABEL [MB] a new partition in a gap
    imgparted.py format STATE I FS LABEL     wipe and format partition I
    imgparted.py size STATE I BYTES          an exact size, typed
    imgparted.py geom STATE I START SIZE     what a drag does (sectors)
    imgparted.py delete STATE I / undo STATE
    imgparted.py info STATE I                name|fs|size|smallest|resizable|movable|why|largest
    imgparted.py apply STATE --status F      do it (imgengine.Job status file)
"""
import copy
import json
import os
import re
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import imgplan  # noqa: E402

MiB, GiB = 1024 ** 2, 1024 ** 3
NEW_MIN = 16 * MiB
HISTORY = 50
BASIC = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
LINUX = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
TYPES = {"gpt": {"ntfs": BASIC, "exfat": BASIC, "vfat": BASIC, "ext4": LINUX},
         "dos": {"ntfs": "7", "exfat": "7", "vfat": "c", "ext4": "83"}}
FS_NAMES = {"ntfs": "NTFS", "exfat": "exFAT", "vfat": "FAT32", "ext4": "ext4"}


def edit_margin(min_bytes):
    """Room left when shrinking by hand: less than a clone leaves (imgplan),
    because here the operator is choosing the size on purpose."""
    return max(GiB, (min_bytes or 0) // 50)


def _ceil(v, a):
    return -(-v // a) * a


# ---------------------------------------------------------------- state
def _entry(p):
    keep = ("num", "start", "size", "fs", "label", "type", "uuid", "name", "state", "used", "min")
    e = {k: p.get(k) for k in keep}
    e.update(new=False, format="")
    return e


def new_state(scan):
    sec = scan["sector"]
    label = scan.get("label") or "gpt"
    total = scan["bytes"] // sec
    now = [dict(p) for p in sorted(scan["parts"], key=lambda p: p["start"])]
    a = max(1, MiB // sec)
    st = {"disk": {k: scan.get(k) for k in ("name", "path", "bytes", "sector", "label", "id", "model")},
          "first": min([a] + [p["start"] for p in now]),
          "end": total - (imgplan.GPT_TAIL if label == "gpt" else 0),
          "now": now, "after": [_entry(p) for p in now], "history": [], "blocked": ""}
    st["disk"]["label"] = label
    if any(imgplan._is_extended(label, p) for p in now):
        st["blocked"] = ("This drive has extended (logical) partitions - the editor does not "
                         "change those. Clone or back it up instead.")
    return st


def _align(st):
    return max(1, MiB // st["disk"]["sector"])


def _now(st, num):
    for p in st["now"]:
        if p["num"] == num:
            return p
    return None


def _system(st):
    return max(st["now"], key=lambda p: p["size"]) if st["now"] else None


def name_of(st, e):
    """As the drive bars name partitions: EFI, MSR, C: Windows, Recovery."""
    if e.get("new"):
        return "new partition %d%s" % (e["num"], (" (%s)" % e["label"]) if e.get("label") else "")
    import imgengine
    p = _now(st, e["num"]) or e
    return imgengine.seg_name(p, imgengine.seg_kind(p, _system(st)))


def limits(st, i):
    """Where after[i] may go: lo..hi (sectors, hi exclusive), its smallest
    size, and whether it may move / resize at all - with the reason when not."""
    after = st["after"]
    e = after[i]
    sec = st["disk"]["sector"]
    out = {"lo": after[i - 1]["start"] + after[i - 1]["size"] if i > 0 else st["first"],
           "hi": after[i + 1]["start"] if i + 1 < len(after) else st["end"],
           "can_move": True, "can_resize": True, "why": "", "min_size": -(-NEW_MIN // sec)}
    if e.get("new") or e.get("format"):
        return out
    p = _now(st, e["num"])
    state, fs = p.get("state"), p.get("fs")
    if state == "hibernated":
        out.update(can_move=False, can_resize=False,
                   why="Windows did not shut down fully (Fast Startup), so this partition cannot be "
                       "moved or resized. Start Windows, hold Shift while you click Shut down, then try again.")
    elif state == "dirty":
        out.update(can_move=False, can_resize=False,
                   why="Windows has marked this partition for a disk check, so it cannot be moved or "
                       "resized. Start Windows once and let the check finish.")
    elif state in ("locked", "unlocked"):
        out.update(can_resize=False,
                   why="Locked with BitLocker: it can be moved, not resized. Shrink or extend it in "
                       "Windows Disk Management instead.")
    elif fs not in imgplan.FS_RESIZE or state != "ok":
        out.update(can_resize=False,
                   why="%s partitions keep their size here - they can be moved."
                       % (FS_NAMES.get(fs) or "These"))
    if out["can_resize"]:
        smallest = p.get("min") or p.get("used") or 0
        need = _ceil(-(-(smallest + edit_margin(smallest)) // sec), _align(st))
        out["min_size"] = min(p["size"], need)
    else:
        out["min_size"] = e["size"]
    return out


def _clamp(st, i, start, size):
    e = st["after"][i]
    lim = limits(st, i)
    a = _align(st)
    if not lim["can_move"]:
        start = e["start"]
    elif start != e["start"]:
        start = int(round(start / a)) * a
    start = max(lim["lo"], min(start, lim["hi"] - lim["min_size"]))
    if lim["can_resize"]:
        end = start + size
        # whole MiB - or flush against the next partition / the end of the drive
        end = lim["hi"] if lim["hi"] - end < a // 2 else int(round(end / a)) * a
        size = min(max(lim["min_size"], min(end, lim["hi"]) - start), lim["hi"] - start)
    else:
        size = e["size"]
    return start, size


def _push(st):
    new = copy.deepcopy(st)
    new["history"] = (st.get("history") or [])[-(HISTORY - 1):] + [copy.deepcopy(st["after"])]
    return new


def set_geometry(st, i, start, size):
    start, size = _clamp(st, i, start, size)
    e = st["after"][i]
    if (start, size) == (e["start"], e["size"]):
        return st
    new = _push(st)
    new["after"][i].update(start=start, size=size)
    return new


def gaps(st):
    """Unallocated stretches big enough for a partition: (start, size)."""
    a = _align(st)
    out, pos = [], st["first"]
    edges = [(e["start"], e["start"] + e["size"]) for e in st["after"]] + [(st["end"], st["end"])]
    for s, end in edges:
        g0 = _ceil(pos, a)
        g1 = s if s == st["end"] else s // a * a
        if (g1 - g0) * st["disk"]["sector"] >= NEW_MIN:
            out.append((g0, g1 - g0))
        pos = max(pos, end)
    return out


def _clean_label(label, fs):
    label = re.sub(r"[^A-Za-z0-9 _-]", "", label or "").strip()
    return label.upper()[:11] if fs == "vfat" else label[:15 if fs == "exfat" else 32]


def add_new(st, start, size, fs, label):
    if fs not in FS_NAMES:
        raise ValueError("cannot make a %s partition" % fs)
    a = _align(st)
    g0 = _ceil(start, a)
    end = start + size if start + size == st["end"] else (start + size) // a * a
    used = {e["num"] for e in st["after"]}
    num = next(n for n in range(1, 129) if n not in used)
    new = _push(st)
    new["after"].append({"num": num, "start": g0, "size": end - g0, "fs": fs, "new": True, "format": "",
                         "label": _clean_label(label, fs), "type": TYPES[st["disk"]["label"]][fs],
                         "state": "ok", "used": None, "min": None, "uuid": "", "name": ""})
    new["after"].sort(key=lambda e: e["start"])
    return new


def delete(st, i):
    new = _push(st)
    del new["after"][i]
    return new


def set_format(st, i, fs, label):
    if fs not in FS_NAMES:
        raise ValueError("cannot make a %s partition" % fs)
    new = _push(st)
    e = new["after"][i]
    e.update(fs=fs, label=_clean_label(label, fs), type=TYPES[st["disk"]["label"]][fs])
    if not e.get("new"):
        e["format"] = fs
    return new


def undo(st):
    if not st.get("history"):
        return st
    new = copy.deepcopy(st)
    new["after"] = new["history"].pop()
    return new


# ---------------------------------------------------------------- the steps
def _op(kind, e, text, **kw):
    d = {"kind": kind, "num": e["num"], "text": text, "fs": e.get("fs")}
    d.update(kw)
    return d


def ops(st):
    sec = st["disk"]["sector"]
    gb = lambda sectors: imgplan.gb(sectors * sec)
    kept = {e["num"]: e for e in st["after"] if not e.get("new")}
    out = []
    for p in st["now"]:
        if p["num"] not in kept:
            out.append(_op("delete", p, "Delete %s %s - its files are erased"
                           % (name_of(st, _entry(p)), gb(p["size"]))))
    redo = [e for e in kept.values() if e.get("format")
            and (e["start"], e["size"]) != (_now(st, e["num"])["start"], _now(st, e["num"])["size"])]
    for e in redo:
        out.append(_op("delete", e, "Delete %s - it is made again below" % name_of(st, e)))
    keep = sorted((e for e in kept.values() if e not in redo), key=lambda e: e["start"])
    for e in keep:
        p = _now(st, e["num"])
        if e["size"] < p["size"]:
            out.append(_op("shrink", e, "Shrink %s  %s -> %s" % (name_of(st, e), gb(p["size"]), gb(e["size"])),
                           start=p["start"], size=e["size"]))
    lefts = [e for e in keep if e["start"] < _now(st, e["num"])["start"]]
    rights = [e for e in reversed(keep) if e["start"] > _now(st, e["num"])["start"]]
    for e in lefts + rights:
        p = _now(st, e["num"])
        size = min(p["size"], e["size"])
        out.append(_op("move", e, "Move %s %s - every byte is copied" % (name_of(st, e), gb(size)),
                       src=p["start"], start=e["start"], size=size))
    for e in keep:
        p = _now(st, e["num"])
        if e["size"] > p["size"]:
            out.append(_op("grow", e, "Grow %s  %s -> %s" % (name_of(st, e), gb(p["size"]), gb(e["size"])),
                           start=e["start"], size=e["size"]))
    for e in sorted([e for e in st["after"] if e.get("new")] + redo, key=lambda e: e["start"]):
        out.append(_op("create", e, "New partition %d%s, %s, %s" % (
            e["num"], (": " + e["label"]) if e.get("label") else "", FS_NAMES[e["fs"]], gb(e["size"])),
            start=e["start"], size=e["size"], label=e.get("label", ""), type=e["type"]))
    for e in keep:
        if e.get("format"):
            out.append(_op("format", e, "Format %s as %s%s - its files are erased" % (
                name_of(st, _entry(_now(st, e["num"]))), FS_NAMES[e["fs"]],
                (" '%s'" % e["label"]) if e.get("label") else ""),
                start=e["start"], label=e.get("label", ""), type=e["type"]))
    return out


def problems(st):
    errors, warnings = [], []
    if st.get("blocked"):
        errors.append(st["blocked"])
    if st["disk"]["label"] == "dos" and len(st["after"]) > 4:
        errors.append("An MBR drive holds 4 partitions; this layout has %d. Delete one first."
                      % len(st["after"]))
    steps = ops(st)
    kinds = {o["kind"] for o in steps}
    if kinds & {"shrink", "grow", "move"} and any(o["fs"] == "ntfs" for o in steps):
        warnings.append("Windows checks the disk once on its next start - let it finish.")
    if "move" in kinds:
        warnings.append("Moving copies every byte of the partition. Keep the charger in: a power cut "
                        "in the middle loses that partition.")
        if st["disk"]["label"] == "dos" and any(o["kind"] == "move" and o["fs"] == "ntfs" for o in steps):
            warnings.append("On an MBR drive Windows finds its partition by where it starts: after a move "
                            "Windows may not start until its boot files are repaired (bootrec /rebuildbcd "
                            "from a Windows USB).")
    return errors, warnings


# ---------------------------------------------------------------- doing it
def _sh(*a, **k):
    import imgengine
    return imgengine.sh(*a, **k)


def _sfdisk_part(dev, num, fields, move_log=None):
    cmd = ["sfdisk", "-N", str(num), "--no-reread"]
    if move_log:
        cmd.append("--move-data=%s" % move_log)
    return cmd + [dev], ", ".join("%s=%s" % kv for kv in fields)


def _reread(dev):
    _sh(["partx", "-u", dev], check=False)
    _sh(["partprobe", dev], check=False)
    _sh(["udevadm", "settle", "--timeout=10"], check=False)


def _sectors_written(disk):
    try:
        with open("/sys/block/%s/stat" % disk) as f:
            return int(f.read().split()[6])
    except (OSError, ValueError, IndexError):
        return 0


def _move(job, st, op):
    """sfdisk moves the data; progress is what the kernel says has been
    written to the drive (sfdisk shows none when not on a terminal). Q waits
    until the move is over - a half-moved partition is a lost one."""
    import imgengine
    dev, sec = st["disk"]["path"], st["disk"]["sector"]
    log = os.path.join(imgengine.RUN_DIR, "parted-move-%d.log" % op["num"])
    cmd, text = _sfdisk_part(dev, op["num"], (("start", op["start"]), ("size", op["size"])), log)
    imgengine.log("$ %s <<< %s" % (" ".join(cmd), text))
    base, total = _sectors_written(st["disk"]["name"]), op["size"] * sec
    job.hold = True
    try:
        job.child = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, start_new_session=True)
        job.child.stdin.write(text.encode())
        job.child.stdin.close()
        while job.child.poll() is None:
            time.sleep(1)
            done = (_sectors_written(st["disk"]["name"]) - base) * 512
            job.set(partpct=min(99, int(done * 100 / max(1, total))))
        out = job.child.stdout.read().decode("utf-8", "replace")
        rc, job.child = job.child.returncode, None
    finally:
        job.hold = False
    imgengine.log("  rc=%d %s" % (rc, out[-400:]))
    if rc != 0:
        raise imgengine.Fail("moving partition %d failed: %s"
                             % (op["num"], (out.strip().splitlines() or ["no message"])[-1]))
    if job.stop_pending:
        raise imgengine.Stop()


def fix_ntfs_start(node, old, new):
    """NTFS keeps its partition's start ("hidden sectors", offset 28) in both
    boot sectors, and BIOS booting reads it. Rewritten only when it held the
    old start - a 0 there (mkntfs on a loop device) is left alone."""
    with open(node, "r+b") as f:
        boot = f.read(512)
        if boot[3:11] != b"NTFS    " or struct.unpack_from("<I", boot, 28)[0] != old:
            return False
        bps = struct.unpack_from("<H", boot, 11)[0]
        nsec = struct.unpack_from("<Q", boot, 40)[0]
        for at in (0, nsec * bps):
            f.seek(at)
            if f.read(11)[3:11] == b"NTFS    ":
                f.seek(at + 28)
                f.write(struct.pack("<I", new & 0xffffffff))
    return True


def _mkfs(node, fs, label, start):
    cmd = {"ntfs": ["mkntfs", "-Q", "-F", "-p", str(start), "-H", "255", "-S", "63"]
                   + (["-L", label] if label else []),
           "exfat": ["mkfs.exfat"] + (["-L", label] if label else []),
           "vfat": ["mkfs.vfat", "-F", "32"] + (["-n", label] if label else []),
           "ext4": ["mkfs.ext4", "-F", "-q"] + (["-L", label] if label else [])}[fs]
    _sh(cmd + [node])


def _run_op(job, st, op):
    import imgengine
    dev, sec = st["disk"]["path"], st["disk"]["sector"]
    node = imgplan.part_node(st["disk"]["name"], op["num"])
    k = op["kind"]
    if k == "delete":
        _sh(["sfdisk", "--delete", "--no-reread", dev, str(op["num"])])
    elif k == "shrink":
        if op["fs"] in imgplan.FS_RESIZE:
            imgengine.resize_fs(node, op["fs"], op["size"] * sec)
        cmd, text = _sfdisk_part(dev, op["num"], (("size", op["size"]),))
        _sh(cmd, input_=text)
        _reread(dev)
        if op["fs"] in imgplan.FS_RESIZE:
            imgengine.resize_fs(node, op["fs"])        # flush with the partition's new end
    elif k == "move":
        _move(job, st, op)
        _reread(dev)
        if op["fs"] == "ntfs":
            fix_ntfs_start(node, op["src"], op["start"])
    elif k == "grow":
        cmd, text = _sfdisk_part(dev, op["num"], (("start", op["start"]), ("size", op["size"])))
        _sh(cmd, input_=text)
        _reread(dev)
        if op["fs"] in imgplan.FS_RESIZE:
            imgengine.resize_fs(node, op["fs"])
    elif k == "create":
        cmd, text = _sfdisk_part(dev, op["num"], (("start", op["start"]), ("size", op["size"]),
                                                  ("type", op["type"])))
        _sh(cmd, input_=text)
        _reread(dev)
        imgengine.wait_nodes([node])
        _sh(["wipefs", "-a", "-f", node], check=False)
        _mkfs(node, op["fs"], op.get("label"), op["start"])
    elif k == "format":
        _sh(["wipefs", "-a", "-f", node])
        _sh(["sfdisk", "--part-type", "--no-reread", dev, str(op["num"]), op["type"]])
        _reread(dev)
        _mkfs(node, op["fs"], op.get("label"), op["start"])
    _reread(dev)


def _check_result(st):
    """The table on the drive must be exactly the after picture."""
    import imgscan
    import imgengine
    t = imgscan.read_table(st["disk"]["path"])
    got = sorted((p["num"], p["start"], p["size"]) for p in t["parts"])
    want = sorted((e["num"], e["start"], e["size"]) for e in st["after"])
    if got != want:
        raise imgengine.Fail("the partition table does not match the plan afterwards: %s" % got)


def apply(job, st):
    import imgengine
    dev = st["disk"]["path"]
    errors, _ = problems(st)
    if errors:
        raise imgengine.Fail(errors[0])
    if imgengine.mounted(dev):
        raise imgengine.Fail("something on %s is in use (mounted)" % dev)
    steps = ops(st)
    w = lambda o: o["size"] * st["disk"]["sector"] if o["kind"] == "move" else GiB
    job.total_w = sum(w(o) for o in steps) or 1
    job.set(steps=len(steps), phase="parted")
    for o in steps:
        job.step(o["text"], w(o))
        job.set(phase=o["kind"])
        _run_op(job, st, o)
        job.finish_step()
    _check_result(st)


# ---------------------------------------------------------------- CLI
def load(path):
    with open(path) as f:
        return json.load(f)


def save(st, path):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, path)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd, path = argv[1], argv[2]
    if cmd == "load":
        import imgscan
        save(new_state(imgscan.scan(path)), argv[3])
        return 0
    if cmd == "apply":
        import imgengine
        status = argv[argv.index("--status") + 1] if "--status" in argv else \
            os.path.join(imgengine.RUN_DIR, "imaging.status")
        return imgengine.run_job(apply, status, load(path))
    st = load(path)
    sec = st["disk"]["sector"]
    if cmd == "ops":
        print("\n".join(o["text"] for o in ops(st)))
    elif cmd == "problems":
        e, w = problems(st)
        print("\n".join(["E|" + x for x in e] + ["W|" + x for x in w]))
    elif cmd == "gaps":
        for i, (s, z) in enumerate(gaps(st)):
            print("%d|%d|%d|%s" % (i, s, z, imgplan.gb(z * sec)))
    elif cmd == "new":
        s, z = gaps(st)[int(argv[3])]
        if len(argv) > 6 and argv[6].isdigit():
            z = min(z, int(argv[6]) * MiB // sec)
        save(add_new(st, s, z, argv[4], argv[5]), path)
    elif cmd == "format":
        save(set_format(st, int(argv[3]), argv[4], argv[5]), path)
    elif cmd == "size":
        i = int(argv[3])
        save(set_geometry(st, i, st["after"][i]["start"], int(argv[4]) // sec), path)
    elif cmd == "items":                      # the text interface's list (no dragging there)
        seq = [(e["start"], "part", i) for i, e in enumerate(st["after"])]
        seq += [(s0, "gap", g) for g, (s0, _z) in enumerate(gaps(st))]
        for _, kind, i in sorted(seq):
            if kind == "gap":
                print("gap|%d|unallocated|%s" % (i, imgplan.gb(gaps(st)[i][1] * sec)))
            else:
                e = st["after"][i]
                print("part|%d|%s|%s|%s" % (i, name_of(st, e), FS_NAMES.get(e.get("fs"), e.get("fs") or "-"),
                                             imgplan.gb(e["size"] * sec)))
    elif cmd == "geom":                       # what a drag does, for scripts and tests
        save(set_geometry(st, int(argv[3]), int(argv[4]), int(argv[5])), path)
    elif cmd == "delete":
        save(delete(st, int(argv[3])), path)
    elif cmd == "undo":
        save(undo(st), path)
    elif cmd == "info":
        i = int(argv[3])
        e, lim = st["after"][i], limits(st, i)
        print("|".join(str(x) for x in (
            name_of(st, e), FS_NAMES.get(e.get("fs"), e.get("fs") or "-"), e["size"] * sec,
            lim["min_size"] * sec, int(lim["can_resize"]), int(lim["can_move"]),
            lim["why"].replace("|", "/"), (lim["hi"] - e["start"]) * sec)))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
