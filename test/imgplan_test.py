#!/usr/bin/env python3
"""Unit tests for toolkit/imgplan.py - the clone / restore layout planner.

Pure logic, no disks touched: runs anywhere with Python 3.
    python3 test/imgplan_test.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "toolkit"))
import imgplan  # noqa: E402

GiB = 1024 ** 3
MiB = 1024 ** 2
S = 512

EFI = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
MSR = "E3C9E316-0B5C-4DB8-817D-F92DF00215AE"
BASIC = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
WINRE = "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC"
DISK_ID = "8F3A0C1E-1111-2222-3333-444455556666"


def part(num, start_mib, size_mib, ptype, fs, used=None, min_=None, state="ok", **kw):
    p = {"node": "/dev/sda%d" % num, "num": num,
         "start": start_mib * MiB // S, "size": size_mib * MiB // S,
         "type": ptype, "uuid": "0000000%d-AAAA-BBBB-CCCC-DDDDEEEEFFFF" % num, "name": kw.get("name", ""),
         "attrs": kw.get("attrs", ""), "bootable": kw.get("bootable", False),
         "fs": fs, "label": kw.get("label", ""), "used": used, "min": min_,
         "state": state}
    return p


def dynabook(c_state="ok", c_fs="ntfs", disk_gib=256):
    """A factory Windows 11 GPT layout: EFI, MSR, C:, WinRE at the end."""
    c_size = disk_gib * 1024 - 1 - 260 - 16 - 1024 - 1   # MiB, fills the disk
    return {"name": "sda", "bytes": disk_gib * GiB, "sector": S, "label": "gpt",
            "id": DISK_ID, "firstlba": 34,
            "parts": [
                part(1, 1, 260, EFI, "vfat", used=40 * MiB, name="EFI system partition"),
                part(2, 261, 16, MSR, "", name="Microsoft reserved partition"),
                part(3, 277, c_size, BASIC, c_fs, used=60 * GiB, min_=62 * GiB,
                     state=c_state, name="Basic data partition", label="Windows"),
                part(4, 277 + c_size, 1024, WINRE, "ntfs", used=600 * MiB, min_=700 * MiB,
                     attrs="RequiredPartition GUID:63", label="WinRE"),
            ]}


def target(gib, sector=S, name="sdb"):
    return {"name": name, "bytes": gib * GiB, "sector": sector}


class GrowTests(unittest.TestCase):
    def test_bigger_ssd_grows_c_and_moves_recovery_to_the_end(self):
        p = imgplan.plan(dynabook(), target(512))
        self.assertTrue(p["ok"], p["errors"])
        efi, msr, c, re_ = p["parts"]
        src = dynabook()["parts"]
        # everything before C: stays exactly where it was
        self.assertEqual((efi["nstart"], efi["nsize"]), (src[0]["start"], src[0]["size"]))
        self.assertEqual((msr["nstart"], msr["nsize"]), (src[1]["start"], src[1]["size"]))
        self.assertEqual(c["nstart"], src[2]["start"])
        self.assertGreater(c["nsize"], src[2]["size"])
        self.assertTrue(c["grow"])
        self.assertEqual(p["resize"], 2)
        # recovery keeps its size, sits right after C:, ends near the disk end
        self.assertEqual(re_["nsize"], src[3]["size"])
        self.assertEqual(re_["nstart"], c["nstart"] + c["nsize"])
        last_usable = 512 * GiB // S - imgplan.GPT_TAIL
        self.assertLessEqual(re_["nstart"] + re_["nsize"], last_usable)
        self.assertLess(last_usable - (re_["nstart"] + re_["nsize"]), 2048)

    def test_starts_are_1mib_aligned(self):
        p = imgplan.plan(dynabook(), target(500))
        for q in p["parts"]:
            self.assertEqual(q["nstart"] % 2048, 0, q["node"])

    def test_identity_is_kept_for_windows_boot(self):
        p = imgplan.plan(dynabook(), target(512))
        self.assertEqual(p["id"], DISK_ID)
        self.assertEqual([q["uuid"] for q in p["parts"]], ["0000000%d-AAAA-BBBB-CCCC-DDDDEEEEFFFF" % n for n in (1, 2, 3, 4)])

    def test_copy_methods(self):
        p = imgplan.plan(dynabook(), target(512))
        self.assertEqual([q["how"] for q in p["parts"]], ["fs", "raw", "fs", "fs"])


class ShrinkTests(unittest.TestCase):
    def test_smaller_ssd_shrinks_c_when_data_fits(self):
        p = imgplan.plan(dynabook(disk_gib=1000), target(128))
        self.assertTrue(p["ok"], p["errors"])
        c = p["parts"][2]
        self.assertTrue(c["shrink"])
        self.assertGreaterEqual(c["nsize"] * S, 62 * GiB + imgplan.shrink_margin(62 * GiB))

    def test_too_small_is_refused_with_the_numbers(self):
        p = imgplan.plan(dynabook(disk_gib=1000), target(64))
        self.assertFalse(p["ok"])
        msg = " ".join(p["errors"])
        self.assertIn("62", msg)          # what C: needs, in GB
        self.assertIn("C:", msg)

    def test_locked_bitlocker_cannot_shrink(self):
        p = imgplan.plan(dynabook(c_state="locked", c_fs="bitlocker", disk_gib=1000), target(256))
        self.assertFalse(p["ok"])
        msg = " ".join(p["errors"]).lower()
        self.assertIn("recovery key", msg)
        self.assertIn("shrink", msg)

    def test_hibernated_windows_cannot_shrink(self):
        p = imgplan.plan(dynabook(c_state="hibernated", disk_gib=1000), target(256))
        self.assertFalse(p["ok"])
        self.assertIn("shut down", " ".join(p["errors"]).lower())

    def test_unlocked_bitlocker_is_resized_and_noted(self):
        p = imgplan.plan(dynabook(c_state="unlocked", disk_gib=1000), target(256))
        self.assertTrue(p["ok"], p["errors"])
        self.assertTrue(p["parts"][2]["shrink"])
        self.assertTrue(any("BitLocker" in n for n in p["notes"]))


class KeepSizeTests(unittest.TestCase):
    def test_locked_bitlocker_on_bigger_disk_is_copied_same_size(self):
        p = imgplan.plan(dynabook(c_state="locked", c_fs="bitlocker"), target(512))
        self.assertTrue(p["ok"], p["errors"])
        src = dynabook()["parts"]
        for q, s in zip(p["parts"], src):
            self.assertEqual((q["nstart"], q["nsize"]), (s["start"], s["size"]))
        self.assertEqual(p["parts"][2]["how"], "raw")
        self.assertIsNone(p["resize"])
        self.assertGreater(p["free_after"], 200 * GiB)
        self.assertTrue(any("Disk Management" in n for n in p["notes"]))

    def test_keep_size_option(self):
        p = imgplan.plan(dynabook(), target(512), keep_size=True)
        self.assertTrue(p["ok"])
        self.assertIsNone(p["resize"])
        self.assertFalse(any(q["grow"] or q["shrink"] for q in p["parts"]))


class RefusalTests(unittest.TestCase):
    def test_sector_size_mismatch_is_refused(self):
        p = imgplan.plan(dynabook(), target(512, sector=4096))
        self.assertFalse(p["ok"])
        self.assertIn("4096", " ".join(p["errors"]))

    def test_disk_without_partitions_is_refused(self):
        d = dynabook(); d["parts"] = []
        self.assertFalse(imgplan.plan(d, target(512))["ok"])

    def test_partitions_after_c_that_cannot_fit(self):
        d = dynabook(disk_gib=1000)
        d["parts"][3]["size"] = 300 * GiB // S          # a huge recovery partition
        p = imgplan.plan(d, target(256))
        self.assertFalse(p["ok"])


class MbrTests(unittest.TestCase):
    def mbr(self):
        return {"name": "sda", "bytes": 500 * GiB, "sector": S, "label": "dos",
                "id": "0x1a2b3c4d",
                "parts": [part(1, 1, 500, "7", "ntfs", used=300 * MiB, min_=320 * MiB,
                               bootable=True, label="System Reserved"),
                          part(2, 501, 400 * 1024, "7", "ntfs", used=80 * GiB, min_=85 * GiB)]}

    def test_mbr_grows_last_partition_and_keeps_signature(self):
        p = imgplan.plan(self.mbr(), target(1000))
        self.assertTrue(p["ok"], p["errors"])
        self.assertEqual(p["resize"], 1)
        self.assertEqual(p["id"], "0x1a2b3c4d")
        # no GPT backup at the end of an MBR disk
        self.assertEqual(p["parts"][1]["nstart"] + p["parts"][1]["nsize"],
                         1000 * GiB // S // 2048 * 2048)

    def test_extended_partitions_are_copied_as_is(self):
        d = self.mbr()
        d["parts"].append(part(3, 410 * 1024, 20 * 1024, "f", ""))
        d["parts"].append(part(5, 410 * 1024 + 1, 10 * 1024, "83", "ext4", used=GiB))
        p = imgplan.plan(d, target(1000))
        self.assertTrue(p["ok"], p["errors"])
        self.assertIsNone(p["resize"])
        self.assertTrue(any("extended" in n.lower() for n in p["notes"]))
        self.assertEqual(p["parts"][2]["how"], "skip")       # the container itself


class ScriptTests(unittest.TestCase):
    def test_gpt_script(self):
        p = imgplan.plan(dynabook(), target(512, name="nvme0n1"))
        s = imgplan.sfdisk_script(p)
        self.assertIn("label: gpt", s)
        self.assertIn("label-id: " + DISK_ID, s)
        self.assertIn("first-lba: 34", s)
        self.assertIn("/dev/nvme0n1p3 : start=", s)
        self.assertIn('uuid=00000003-AAAA-BBBB-CCCC-DDDDEEEEFFFF', s)
        self.assertIn('name="Basic data partition"', s)
        self.assertIn('attrs="RequiredPartition GUID:63"', s)
        self.assertNotIn("last-lba", s)       # sfdisk works it out for the new disk

    def test_mbr_script(self):
        p = imgplan.plan(MbrTests().mbr(), target(1000))
        s = imgplan.sfdisk_script(p)
        self.assertIn("label: dos", s)
        self.assertIn("label-id: 0x1a2b3c4d", s)
        self.assertIn("/dev/sdb1 : start=", s)
        self.assertIn("bootable", s)
        self.assertIn("type=7", s)

    def test_quotes_in_names_cannot_break_the_script(self):
        d = dynabook(); d["parts"][2]["name"] = 'evil", type=0'
        s = imgplan.sfdisk_script(imgplan.plan(d, target(512)))
        self.assertNotIn('evil",', s)

    def test_part_node(self):
        self.assertEqual(imgplan.part_node("sda", 2), "/dev/sda2")
        self.assertEqual(imgplan.part_node("nvme0n1", 2), "/dev/nvme0n1p2")
        self.assertEqual(imgplan.part_node("mmcblk0", 1), "/dev/mmcblk0p1")
        self.assertEqual(imgplan.part_node("loop3", 1), "/dev/loop3p1")


if __name__ == "__main__":
    unittest.main(verbosity=1)
