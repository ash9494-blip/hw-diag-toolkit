#!/usr/bin/env python3
"""Unit tests for toolkit/imgplanedit.py - the clone / restore plan's sizes,
changed by hand on the plan screen: what may be dragged where, and that only
a plan the engine can trust comes back.

Pure logic, no disks touched:   python3 test/imgplanedit_test.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "toolkit"))
import imgengine    # noqa: E402
import imgplan      # noqa: E402
import imgplanedit as E  # noqa: E402

GiB, MiB, S = 1024 ** 3, 1024 ** 2, 512
EFI = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
MSR = "E3C9E316-0B5C-4DB8-817D-F92DF00215AE"
BASIC = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
WINRE = "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC"


def part(num, start_mib, size_mib, ptype, fs, used=None, min_=None, state="ok", label=""):
    return {"node": "/dev/sda%d" % num, "num": num, "start": start_mib * MiB // S,
            "size": size_mib * MiB // S, "type": ptype,
            "uuid": "0000000%d-AAAA-BBBB-CCCC-DDDDEEEEFFFF" % num, "name": "", "attrs": "",
            "bootable": False, "fs": fs, "label": label, "used": used, "min": min_, "state": state}


def dynabook(c_state="ok", gib=256, label="gpt"):
    """A factory Windows 11 layout: EFI, MSR, C: (60 GB of data), WinRE at the end."""
    c = gib * 1024 - 1 - 260 - 16 - 1024 - 1
    return {"name": "sda", "bytes": gib * GiB, "sector": S, "label": label,
            "id": "8F3A0C1E-1111-2222-3333-444455556666", "firstlba": 34,
            "parts": [part(1, 1, 260, EFI, "vfat", 40 * MiB),
                      part(2, 261, 16, MSR, ""),
                      part(3, 277, c, BASIC, "ntfs", 60 * GiB, 62 * GiB, c_state, "Windows"),
                      part(4, 277 + c, 1024, WINRE, "ntfs", 600 * MiB, 700 * MiB, label="WinRE")]}


def state(src=None, gib=512, keep_size=False):
    plan = imgplan.plan(src or dynabook(), {"name": "sdb", "bytes": gib * GiB, "sector": S}, keep_size)
    return E.from_plan(plan, "Old drive", "New drive", "Sizes on the new drive")


def idx(st, num):
    return next(i for i, e in enumerate(st["after"]) if e["num"] == num and not e.get("new"))


def gib(sectors):
    return sectors * S / float(GiB)


def c_at(st, size_gib):
    i = idx(st, 3)
    return E.set_geometry(st, i, st["after"][i]["start"], size_gib * GiB // S)


class LimitTests(unittest.TestCase):
    def test_partitions_before_c_keep_place_and_size(self):
        st = state()
        for num in (1, 2):
            lim = E.limits(st, idx(st, num))
            self.assertFalse(lim["can_move"])
            self.assertFalse(lim["can_resize"])
            self.assertIn("before C:", lim["why"])

    def test_c_resizes_but_keeps_its_start(self):
        st = state()
        lim = E.limits(st, idx(st, 3))
        self.assertTrue(lim["can_resize"])
        self.assertFalse(lim["can_move"])
        # 62 GB of data plus the plan's margin (min // 20 = 3.1 GB)
        self.assertAlmostEqual(gib(lim["min_size"]), 62 + 3.1, delta=0.01)

    def test_recovery_moves_and_only_grows(self):
        st = state()
        lim = E.limits(st, idx(st, 4))
        self.assertTrue(lim["can_move"])
        self.assertTrue(lim["can_resize"])
        self.assertEqual(lim["min_size"], dynabook()["parts"][3]["size"])

    def test_locked_c_keeps_its_size_with_the_reason(self):
        st = state(dynabook(c_state="locked"))
        lim = E.limits(st, idx(st, 3))
        self.assertFalse(lim["can_resize"])
        self.assertIn("BitLocker", lim["why"])

    def test_extended_layout_is_blocked(self):
        src = dynabook(label="dos")
        src["parts"] = [part(1, 1, 500, "7", "ntfs", 100 * MiB), part(2, 501, 100000, "5", ""),
                        part(5, 502, 99000, "7", "ntfs", GiB)]
        st = state(src)
        self.assertTrue(E.problems(st)[0])


class EditTests(unittest.TestCase):
    def test_shrinking_c_leaves_free_space_and_a_valid_plan(self):
        st = c_at(state(), 200)
        self.assertAlmostEqual(gib(st["after"][idx(st, 3)]["size"]), 200, delta=0.01)
        plan = E.to_plan(st)
        self.assertTrue(plan["ok"], plan["errors"])
        q = next(q for q in plan["parts"] if q["num"] == 3)
        self.assertTrue(q["shrink"])             # 200 GB, from 254 on the old drive
        self.assertTrue(any("left unallocated" in n for n in plan["notes"]))
        self.assertIn("disk ID", plan["notes"][-1])    # still closes the list
        self.assertTrue(plan["edited"])

    def test_c_never_goes_below_its_data(self):
        st = c_at(state(), 10)
        i = idx(st, 3)
        self.assertGreaterEqual(st["after"][i]["size"], E.limits(st, i)["min_size"])
        plan = E.to_plan(st)
        self.assertTrue(plan["ok"], plan["errors"])
        self.assertTrue(any(n.startswith("C: is shrunk from") for n in plan["notes"]))

    def test_recovery_cannot_shrink_below_the_old_size(self):
        st = state()
        i = idx(st, 4)
        e = st["after"][i]
        st = E.set_geometry(st, i, e["start"], e["size"] // 2)
        self.assertEqual(st["after"][i]["size"], e["size"])

    def test_recovery_moves_left_and_grows(self):
        st = c_at(state(), 200)
        i = idx(st, 4)
        e = st["after"][i]
        st = E.set_geometry(st, i, e["start"] - 50 * GiB // S, e["size"] + 2 * GiB // S)
        plan = E.to_plan(st)
        self.assertTrue(plan["ok"], plan["errors"])
        q = next(q for q in plan["parts"] if q["num"] == 4)
        self.assertTrue(q["grow"])
        self.assertLess(q["nstart"], e["start"])

    def test_a_new_partition_in_the_free_space(self):
        st = c_at(state(), 200)
        g = E.gaps(st)
        self.assertEqual(len(g), 1)
        st = E.add_new(st, g[0][0], g[0][1], "ntfs", "DATA")
        plan = E.to_plan(st)
        self.assertTrue(plan["ok"], plan["errors"])
        new = [q for q in plan["parts"] if q["how"] == "new"]
        self.assertEqual(len(new), 1)
        self.assertEqual(new[0]["type"], BASIC)
        self.assertEqual(new[0]["label"], "DATA")
        self.assertTrue(any(o["text"].startswith("New partition 5 (DATA), NTFS") for o in E.ops(st)))
        # sfdisk gets it, the old drive's bar does not, and it is never "C:"
        self.assertIn("sdb5 :", imgplan.sfdisk_script(plan))
        self.assertNotIn("|new|", imgengine.mapspec(plan))
        self.assertIn("|new|new DATA", imgengine.mapspec(plan, new=True))
        self.assertEqual(imgengine.system_part(plan)["num"], 3)
        row = [r for r in imgengine.rows(plan) if r.startswith("5|")][0].split("|")
        self.assertEqual((row[3], row[5], row[6]), ("-", "made empty", "new"))

    def test_a_big_new_partition_is_not_taken_for_c(self):
        st = c_at(state(gib=2000), 100)
        g = E.gaps(st)
        st = E.add_new(st, g[0][0], g[0][1], "ntfs", "")
        plan = E.to_plan(st)
        self.assertTrue(plan["ok"], plan["errors"])
        self.assertEqual(imgengine.system_part(plan)["num"], 3)
        self.assertEqual(E.from_plan(plan)["system"], 3)

    def test_only_a_new_partition_can_be_removed(self):
        st = state()
        self.assertIs(E.delete(st, idx(st, 4)), st)
        st = c_at(st, 200)
        g = E.gaps(st)
        st = E.add_new(st, g[0][0], g[0][1], "exfat", "")
        n = next(k for k, e in enumerate(st["after"]) if e.get("new"))
        st = E.delete(st, n)
        self.assertFalse(any(e.get("new") for e in st["after"]))

    def test_reopening_an_edited_plan_keeps_the_new_partition(self):
        st = c_at(state(), 200)
        g = E.gaps(st)
        st = E.add_new(st, g[0][0], g[0][1], "ntfs", "DATA")
        plan = E.to_plan(st)
        again = E.to_plan(E.from_plan(plan))
        self.assertTrue(again["ok"], again["errors"])
        self.assertEqual([q["num"] for q in again["parts"]], [q["num"] for q in plan["parts"]])
        self.assertEqual(sum(1 for q in again["parts"] if q["how"] == "new"), 1)
        self.assertEqual(again["notes"], plan["notes"])

    def test_mbr_holds_four(self):
        src = dynabook(label="dos")
        for p in src["parts"]:
            p["type"] = {"vfat": "ef", "ntfs": "7", "": "c"}[p["fs"]]
        st = c_at(state(src), 200)
        g = E.gaps(st)
        st = E.add_new(st, g[0][0], g[0][1], "ntfs", "")
        self.assertTrue(E.problems(st)[0])
        self.assertFalse(E.to_plan(st)["ok"])

    def test_a_tampered_state_is_refused(self):
        st = state()
        st["after"][idx(st, 4)]["start"] = st["after"][idx(st, 3)]["start"] + 10   # on top of C:
        plan = E.to_plan(st)
        self.assertFalse(plan["ok"])
        self.assertTrue(any("overlaps" in x for x in plan["errors"]))

    def test_locked_c_still_takes_a_new_partition_at_the_end(self):
        st = state(dynabook(c_state="locked"))
        g = E.gaps(st)
        self.assertTrue(g)
        st = E.add_new(st, g[-1][0], g[-1][1], "ntfs", "DATA")
        plan = E.to_plan(st)
        self.assertTrue(plan["ok"], plan["errors"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
