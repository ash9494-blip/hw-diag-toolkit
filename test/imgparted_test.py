#!/usr/bin/env python3
"""Unit tests for toolkit/imgparted.py - the partition editor's model: what
may be dragged where, and the order the changes run in.

Pure logic, no disks touched:   python3 test/imgparted_test.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "toolkit"))
import imgparted  # noqa: E402

GiB, MiB, S = 1024 ** 3, 1024 ** 2, 512
EFI = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
MSR = "E3C9E316-0B5C-4DB8-817D-F92DF00215AE"
BASIC = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
WINRE = "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC"


def part(num, start_mib, size_mib, ptype, fs, used=None, mn=None, state="ok", label=""):
    return {"node": "/dev/sda%d" % num, "num": num, "start": start_mib * MiB // S,
            "size": size_mib * MiB // S, "type": ptype, "uuid": "0000000%d-AAAA-BBBB-CCCC-DDDDEEEEFFFF" % num,
            "name": "", "attrs": "", "bootable": False, "fs": fs, "label": label,
            "used": used, "min": mn, "state": state}


def scan(c_state="ok", c_fs="ntfs", label="gpt", gib=476):
    c = gib * 1024 - 1 - 260 - 16 - 1024 - 1
    return {"name": "sda", "path": "/dev/sda", "bytes": gib * GiB, "sector": S, "label": label,
            "id": "8F3A0C1E-1111-2222-3333-444455556666", "firstlba": 2048, "model": "TEST",
            "parts": [part(1, 1, 260, EFI, "vfat", 40 * MiB, label="SYSTEM"),
                      part(2, 261, 16, MSR, ""),
                      part(3, 277, c, BASIC, c_fs, 212 * GiB, 214 * GiB, c_state, "Windows"),
                      part(4, 277 + c, 1024, WINRE, "ntfs", 600 * MiB, 700 * MiB, label="WinRE")]}


def mib(n):
    return n * MiB // S


class LimitTests(unittest.TestCase):
    def test_c_can_shrink_to_its_minimum_plus_room(self):
        st = imgparted.new_state(scan())
        lim = imgparted.limits(st, 2)
        self.assertTrue(lim["can_resize"])
        self.assertGreaterEqual(lim["min_size"] * S, 214 * GiB + GiB)
        self.assertLess(lim["min_size"] * S, 220 * GiB)
        self.assertEqual(lim["hi"], st["after"][3]["start"])      # up to WinRE

    def test_fat_and_raw_partitions_keep_their_size_but_can_move(self):
        st = imgparted.new_state(scan())
        for i in (0, 1):
            lim = imgparted.limits(st, i)
            self.assertFalse(lim["can_resize"])
            self.assertTrue(lim["can_move"])

    def test_hibernated_c_neither_moves_nor_resizes(self):
        st = imgparted.new_state(scan(c_state="hibernated"))
        lim = imgparted.limits(st, 2)
        self.assertFalse(lim["can_resize"]); self.assertFalse(lim["can_move"])
        self.assertIn("shut down", lim["why"].lower())

    def test_locked_bitlocker_moves_but_does_not_resize(self):
        st = imgparted.new_state(scan(c_state="locked", c_fs="bitlocker"))
        lim = imgparted.limits(st, 2)
        self.assertFalse(lim["can_resize"]); self.assertTrue(lim["can_move"])
        self.assertIn("BitLocker", lim["why"])


class EditTests(unittest.TestCase):
    def test_drag_below_minimum_is_held_at_the_minimum(self):
        st = imgparted.new_state(scan())
        c = st["after"][2]
        st2 = imgparted.set_geometry(st, 2, c["start"], mib(1024))
        self.assertEqual(st2["after"][2]["size"], imgparted.limits(st, 2)["min_size"])

    def test_sizes_and_starts_stay_aligned(self):
        st = imgparted.new_state(scan())
        c = st["after"][2]
        st2 = imgparted.set_geometry(st, 2, c["start"], c["size"] - 12345)
        self.assertEqual((st2["after"][2]["start"] + st2["after"][2]["size"]) % 2048, 0)

    def test_no_overlap_with_the_next_partition(self):
        st = imgparted.new_state(scan())
        c = st["after"][2]
        st2 = imgparted.set_geometry(st, 2, c["start"], c["size"] + mib(5000))
        self.assertEqual(st2["after"][2]["size"], c["size"])          # WinRE is in the way

    def test_edits_do_not_change_the_old_state(self):
        st = imgparted.new_state(scan())
        before = st["after"][2]["size"]
        imgparted.set_geometry(st, 2, st["after"][2]["start"], mib(300 * 1024))
        self.assertEqual(st["after"][2]["size"], before)

    def test_undo(self):
        st = imgparted.new_state(scan())
        st2 = imgparted.set_geometry(st, 2, st["after"][2]["start"], mib(300 * 1024))
        st3 = imgparted.undo(st2)
        self.assertEqual(st3["after"], st["after"])


class SplitTests(unittest.TestCase):
    def split(self):
        st = imgparted.new_state(scan())
        st = imgparted.set_geometry(st, 2, st["after"][2]["start"], mib(300 * 1024))
        gaps = imgparted.gaps(st)
        self.assertEqual(len(gaps), 1)
        g0, gs = gaps[0]
        return imgparted.add_new(st, g0, gs, "ntfs", "Data")

    def test_split_c_into_c_and_d(self):
        st = self.split()
        ops = imgparted.ops(st)
        self.assertEqual([o["kind"] for o in ops], ["shrink", "create"])
        new = [e for e in st["after"] if e.get("new")][0]
        self.assertEqual(new["num"], 5)
        self.assertEqual(new["type"].upper(), BASIC)
        self.assertIn("Data", ops[1]["text"])
        self.assertIn("300 GB", ops[0]["text"])

    def test_new_partition_fills_the_gap_and_is_aligned(self):
        st = self.split()
        new = [e for e in st["after"] if e.get("new")][0]
        self.assertEqual(new["start"] % 2048, 0)
        self.assertLessEqual(new["start"] + new["size"], st["after"][-1]["start"])

    def test_deleting_the_new_one_leaves_only_the_shrink(self):
        st = self.split()
        i = [k for k, e in enumerate(st["after"]) if e.get("new")][0]
        st = imgparted.delete(st, i)
        self.assertEqual([o["kind"] for o in imgparted.ops(st)], ["shrink"])


class OrderTests(unittest.TestCase):
    def test_recovery_moves_right_before_c_grows(self):
        st = imgparted.new_state(scan(gib=600))
        st["end"] = st["end"] + mib(100 * 1024)           # a bigger drive after a raw clone
        re_ = st["after"][3]
        st = imgparted.set_geometry(st, 3, st["end"] - re_["size"], re_["size"])
        c = st["after"][2]
        st = imgparted.set_geometry(st, 2, c["start"], st["after"][3]["start"] - c["start"])
        self.assertEqual([o["kind"] for o in imgparted.ops(st)], ["move", "grow"])

    def test_delete_runs_first(self):
        st = imgparted.new_state(scan())
        st = imgparted.delete(st, 3)
        c = st["after"][2]
        st = imgparted.set_geometry(st, 2, c["start"], c["size"] + mib(1024))
        self.assertEqual([o["kind"] for o in imgparted.ops(st)], ["delete", "grow"])

    def test_format_in_place(self):
        st = imgparted.new_state(scan())
        st = imgparted.set_format(st, 3, "exfat", "SPARE")
        ops = imgparted.ops(st)
        self.assertEqual([o["kind"] for o in ops], ["format"])
        self.assertIn("erased", ops[0]["text"])


class ProblemTests(unittest.TestCase):
    def test_mbr_has_room_for_four(self):
        st = imgparted.new_state(scan(label="dos"))
        st = imgparted.set_geometry(st, 2, st["after"][2]["start"], mib(300 * 1024))
        g0, gs = imgparted.gaps(st)[0]
        st = imgparted.add_new(st, g0, gs, "ntfs", "Data")
        errors, _ = imgparted.problems(st)
        self.assertTrue(any("4 partitions" in e for e in errors))

    def test_moving_windows_on_mbr_is_warned(self):
        s = scan(label="dos")
        s["parts"] = s["parts"][2:]                       # C: and recovery only
        st = imgparted.new_state(s)
        st = imgparted.set_geometry(st, 0, st["after"][0]["start"] + mib(1024), st["after"][0]["size"] - mib(1024))
        _, warnings = imgparted.problems(st)
        self.assertTrue(any("MBR" in w for w in warnings))

    def test_nothing_to_do(self):
        st = imgparted.new_state(scan())
        self.assertEqual(imgparted.ops(st), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
