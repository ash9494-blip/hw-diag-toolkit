#!/usr/bin/env python3
"""The clone / restore plan's sizes, changed by hand on the plan screen (Ash,
1.24: "when the system shows me the before and after clone size, I want to be
able to adjust the partitions from there").

The plan imgplan.py made is the starting picture. The operator drags it in
the partition editor (ui.py PlanEditor, on this module's state), and "Use
these sizes" turns it back into a plan for the same engine - checked again
here, because a plan with ok: true is what may write a drive (invariant 9).
Nothing here touches a disk: test/imgplanedit_test.py covers it anywhere.

What may change, and why:
  * partitions before C: (EFI, MSR, System Reserved) keep their place and
    size - the plan's own rule, Macrium's: on an MBR drive Windows' boot
    entries find C: by where it starts, so C: keeps its start too;
  * C: takes any size from its data plus the plan's margin up to the next
    partition - when it can be resized at all (imgplan.resizable: not
    locked, hibernated or flagged for a check);
  * the partitions after C: (WinRE) move anywhere after it and grow when
    their filesystem can; none shrinks below its size on the old drive;
  * free space may be left anywhere, and new partitions made in it - made
    and formatted empty after the copy (imgengine.py, how "new").
The state has the partition editor's shape (imgparted.py), so the same
screen and the same free-space, new-partition and undo code drive it.

    imgplanedit.py open PLAN STATE OLD-CAPTION NEW-CAPTION TITLE
    imgplanedit.py done STATE PLAN       the plan with these sizes (ok / errors)
    imgplanedit.py ops | problems | gaps | items STATE
    imgplanedit.py new STATE GAP FS LABEL [MB] / size STATE I BYTES / info STATE I
    imgplanedit.py geom STATE I START SIZE / delete STATE I / undo STATE
"""
import copy
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import imgplan    # noqa: E402
import imgparted  # noqa: E402

MiB, GiB = 1024 ** 2, 1024 ** 3
FS_NAMES = imgparted.FS_NAMES

# the partition editor's own, on this module's state
gaps = imgparted.gaps
add_new = imgparted.add_new
undo = imgparted.undo
load = imgparted.load
save = imgparted.save


def _ceil(v, a):
    return -(-v // a) * a


def _align(st):
    return max(1, MiB // st["disk"]["sector"])


def _entry(q):
    keep = ("num", "fs", "label", "type", "uuid", "name", "state", "used", "min")
    e = {k: q.get(k) for k in keep}
    e.update(start=q["nstart"], size=q["nsize"], new=q.get("how") == "new", format="")
    return e


def from_plan(plan, cap_old="", cap_new="", title=""):
    """The editor's state from a plan - a fresh one, or one already edited."""
    sec, label = plan["sector"], plan["label"]
    now = [dict(q) for q in plan["parts"] if q.get("how") != "new"]
    after = sorted((_entry(q) for q in plan["parts"]), key=lambda e: e["start"])
    real = [q for q in now if q.get("how") != "skip" and not imgplan._is_extended(label, q)]
    system = max(real, key=lambda q: q["size"]) if real else None
    blocked = ""
    if not plan.get("ok"):
        blocked = "This plan was refused, so there are no sizes to change."
    elif any(imgplan._is_extended(label, q) for q in now):
        blocked = ("This drive has extended partitions, so the layout is copied exactly as it is - "
                   "its sizes cannot be changed here.")
    a = max(1, MiB // sec)
    return {"kind": "plan", "title": title,
            "disk": {"name": plan["target"], "path": "/dev/" + plan["target"], "bytes": plan["target_bytes"],
                     "sector": sec, "label": label, "id": plan.get("id"), "caption": cap_new},
            "src": {"name": plan.get("source", ""), "bytes": plan.get("source_bytes") or 0, "caption": cap_old},
            "first": min([a] + [e["start"] for e in after]),
            "end": plan["target_bytes"] // sec - (imgplan.GPT_TAIL if label == "gpt" else 0),
            "now": now, "after": after, "system": system["num"] if system else None,
            "plan": plan, "history": [], "blocked": blocked}


def _now(st, num):
    for p in st["now"]:
        if p["num"] == num:
            return p
    return None


def _system(st):
    return _now(st, st.get("system"))


def name_of(st, e):
    """As the drive bars name partitions: EFI, MSR, C: Windows, Recovery."""
    if e.get("new"):
        return imgparted.name_of(st, e)
    import imgengine
    p = _now(st, e["num"]) or e
    return imgengine.seg_name(p, imgengine.seg_kind(p, _system(st)))


def _c_smallest(st, p):
    """C:'s smallest size in sectors: its data and the plan's own margin."""
    sec = st["disk"]["sector"]
    smallest = p.get("min") or p.get("used") or p["size"] * sec
    return min(p["size"], _ceil(-(-(smallest + imgplan.shrink_margin(smallest)) // sec), _align(st)))


def limits(st, i):
    """Where after[i] may go - the partition editor's limits, with the
    plan's rules (see the top of this file)."""
    after = st["after"]
    e = after[i]
    out = {"lo": after[i - 1]["start"] + after[i - 1]["size"] if i > 0 else st["first"],
           "hi": after[i + 1]["start"] if i + 1 < len(after) else st["end"],
           "can_move": True, "can_resize": True, "why": "",
           "min_size": -(-imgparted.NEW_MIN // st["disk"]["sector"])}
    if e.get("new"):
        return out
    p, system = _now(st, e["num"]), _system(st)
    fixed = dict(can_move=False, can_resize=False, min_size=e["size"])
    if p is system:
        out["can_move"] = False
        if p.get("how") == "fs" and imgplan.resizable(p):
            out["min_size"] = _c_smallest(st, p)
        else:
            out.update(fixed, why=imgplan._why_fixed(p))
    elif system is not None and p["start"] < system["start"]:
        out.update(fixed, why="Partitions before C: keep their place and size on the new drive - "
                              "Windows starts from them there.")
    elif p.get("how") == "fs" and imgplan.resizable(p):
        out["min_size"] = p["size"]               # grows, never shrinks
    else:
        out.update(can_resize=False, min_size=e["size"],
                   why="%s keeps its size - it can be moved." % name_of(st, e))
    return out


def set_geometry(st, i, start, size):
    return imgparted.set_geometry(st, i, start, size, lim=limits(st, i))


def delete(st, i):
    """Only a new partition: every partition of the old drive is copied."""
    if not st["after"][i].get("new"):
        return st
    return imgparted.delete(st, i)


def _new_text(e, gb):
    # two whole strings, not the label glued on: an empty value matches no
    # catalogue pattern, and two values side by side split wrongly (i18n)
    if e.get("label"):
        return "New partition %d (%s), %s, %s - made empty after the copy" % (
            e["num"], e["label"], FS_NAMES[e["fs"]], gb(e["size"]))
    return "New partition %d, %s, %s - made empty after the copy" % (
        e["num"], FS_NAMES[e["fs"]], gb(e["size"]))


def ops(st):
    """The new drive against the old one, a line each - for the editor's
    list. Not steps: nothing runs until the clone itself."""
    sec = st["disk"]["sector"]
    gb = lambda n: imgplan.gb(n * sec)
    out = []
    for e in st["after"]:
        if e.get("new"):
            out.append({"kind": "create", "num": e["num"], "text": _new_text(e, gb)})
            continue
        p = _now(st, e["num"])
        if e["size"] != p["size"]:
            out.append({"kind": "grow" if e["size"] > p["size"] else "shrink", "num": e["num"],
                        "text": "%s  %s -> %s" % (name_of(st, e), gb(p["size"]), gb(e["size"]))})
    free = sum(z for _s, z in gaps(st))
    if free * sec >= GiB:
        out.append({"kind": "free", "num": 0, "text": "Unallocated  %s" % gb(free)})
    return out


def problems(st):
    errors = [st["blocked"]] if st.get("blocked") else []
    if st["disk"]["label"] == "dos" and len(st["after"]) > 4:
        errors.append("An MBR drive holds 4 partitions; this layout has %d. Delete one first." % len(st["after"]))
    return errors, []


# ---------------------------------------------------------------- back to a plan
def check(plan, st):
    """Everything the engine relies on, whatever the state file says: in
    order, no overlap, inside the drive, nothing smaller than it may be."""
    errors = []
    sec = plan["sector"]
    parts = sorted(plan["parts"], key=lambda q: q["nstart"])
    pos = st["first"]
    for q in parts:
        if q["nstart"] < pos or q["nsize"] <= 0:
            errors.append("Partition %d overlaps the one before it." % q["num"])
        pos = q["nstart"] + q["nsize"]
    if pos > st["end"]:
        errors.append("The partitions take %s and the new drive has %s." % (
            imgplan.gb(pos * sec), imgplan.gb(st["end"] * sec)))
    system = _system(st)
    for q in parts:
        if q.get("how") == "new":
            continue
        p = _now(st, q["num"])
        if p is system and q.get("shrink") and q["nsize"] < _c_smallest(st, p):
            errors.append("C: holds %s of data and needs at least %s." % (
                imgplan.gb(p.get("used") or p.get("min") or 0), imgplan.gb(_c_smallest(st, p) * sec)))
        elif p is not system and q["nsize"] < q["size"]:
            errors.append("%s cannot be smaller than on the old drive." % name_of(st, _entry(q)))
        if not (q.get("how") == "fs" and imgplan.resizable(q)) and q["nsize"] != q["size"]:
            errors.append("%s cannot be resized." % name_of(st, _entry(q)))
        if system is not None and p["start"] < system["start"] and (q["nstart"], q["nsize"]) != (q["start"], q["size"]):
            errors.append("Partitions before C: keep their place and size on the new drive.")
    if plan["label"] == "dos" and len(parts) > 4:
        errors.append("An MBR drive holds 4 partitions; this layout has %d. Delete one first." % len(parts))
    return errors


def layout_notes(plan, st):
    sec = plan["sector"]
    gb = lambda n: imgplan.gb(n * sec)
    notes = []
    for q in plan["parts"]:
        if q.get("shrink"):
            notes.append("C: is shrunk from %s to %s. Windows checks the disk once on its "
                         "first start - let it finish." % (gb(q["size"]), gb(q["nsize"])))
    # no note for a new partition: the plan's table already says "made
    # empty", and one more note pushed the disk ID note off the card at
    # 1280x800 (offscreen render, 1.24)
    free = sum(z for _s, z in gaps(st))
    at_end = plan["free_after"] // sec
    if free * sec >= GiB:
        if free - at_end < _align(st) * 16:
            system = _system(st)
            if system is not None and system.get("state") == "locked":
                notes.append("%s left unallocated at the end - extend C: in Windows Disk "
                             "Management afterwards (works with BitLocker on)." % gb(free))
            else:
                notes.append("%s left unallocated at the end of the new drive." % gb(free))
        else:
            notes.append("%s left unallocated on the new drive." % gb(free))
    return notes


def _renote(base, lay):
    """The plan's notes with its size notes replaced by `lay`, in their place."""
    old = base.get("layout_notes") or []
    notes, put = [], False
    for n in base.get("notes") or []:
        if n in old:
            if not put:
                notes += lay
                put = True
            continue
        notes.append(n)
    if not put:
        # before the last note - the disk ID one, which closes the list
        notes[max(0, len(notes) - 1):max(0, len(notes) - 1)] = lay
    return notes


def to_plan(st):
    """The plan with the sizes in the editor - ok only if check() finds
    nothing; a refused plan never reaches a drive (check_target)."""
    base = st["plan"]
    plan = copy.deepcopy(base)
    by_num = {e["num"]: e for e in st["after"]}
    parts = []
    for q in plan["parts"]:
        if q.get("how") == "new":
            continue                              # made again from the state below
        e = by_num[q["num"]]
        q["nstart"], q["nsize"] = e["start"], e["size"]
        sized = q.get("how") == "fs" and imgplan.resizable(q)
        q["grow"] = sized and q["nsize"] > q["size"]
        q["shrink"] = sized and q["nsize"] < q["size"]
        parts.append(q)
    for e in st["after"]:
        if e.get("new"):
            parts.append({"num": e["num"], "start": e["start"], "size": e["size"],
                          "nstart": e["start"], "nsize": e["size"], "fs": e["fs"], "label": e.get("label") or "",
                          "type": e["type"], "uuid": "", "name": "", "attrs": "", "bootable": False,
                          "state": "ok", "used": None, "min": None, "how": "new",
                          "grow": False, "shrink": False})
    plan["parts"] = parts
    system = next((q for q in parts if q["num"] == st.get("system")), None)
    plan["resize"] = parts.index(system) if system is not None and (system["grow"] or system["shrink"]) else None
    last = max(q["nstart"] + q["nsize"] for q in parts) if parts else st["first"]
    plan["free_after"] = max(0, st["end"] - last) * plan["sector"]
    errors = problems(st)[0] + check(plan, st)
    lay = layout_notes(plan, st)
    plan["notes"] = _renote(base, lay)
    plan["layout_notes"] = lay
    plan["errors"] = errors
    plan["ok"] = not errors
    plan["edited"] = True
    return plan


# ---------------------------------------------------------------- CLI
def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd, path = argv[1], argv[2]
    if cmd == "open":
        with open(path) as f:
            plan = json.load(f)
        cap = lambda k: argv[k] if len(argv) > k else ""
        save(from_plan(plan, cap(4), cap(5), cap(6)), argv[3])
        return 0
    st = load(path)
    sec = st["disk"]["sector"]
    if cmd == "done":
        p = to_plan(st)
        tmp = argv[3] + ".tmp"
        with open(tmp, "w") as f:
            json.dump(p, f, indent=1)
        os.replace(tmp, argv[3])
        if not p["ok"]:
            print("\n".join(p["errors"]))
            return 1
    elif cmd == "ops":
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
    elif cmd == "size":
        i = int(argv[3])
        save(set_geometry(st, i, st["after"][i]["start"], int(argv[4]) // sec), path)
    elif cmd == "geom":
        save(set_geometry(st, int(argv[3]), int(argv[4]), int(argv[5])), path)
    elif cmd == "delete":
        save(delete(st, int(argv[3])), path)
    elif cmd == "undo":
        save(undo(st), path)
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
    elif cmd == "info":
        i = int(argv[3])
        e, lim = st["after"][i], limits(st, i)
        print("|".join(str(x) for x in (
            name_of(st, e), FS_NAMES.get(e.get("fs"), e.get("fs") or "-"), e["size"] * sec,
            lim["min_size"] * sec, int(lim["can_resize"]), int(lim["can_move"]),
            lim["why"].replace("|", "/"), (lim["hi"] - e["start"]) * sec, int(bool(e.get("new"))))))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
