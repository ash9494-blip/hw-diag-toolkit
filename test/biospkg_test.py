#!/usr/bin/env python3
"""Unit tests for toolkit/biospkg.py - which BIOS packages on the stick a
laptop may be updated with. A fake DMI folder stands in for the laptop's
firmware; the build runs these (finalize_chroot.sh).

    python3 test/biospkg_test.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOLKIT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "toolkit")
sys.path.insert(0, TOOLKIT)
import biospkg  # noqa: E402


def write(path, text=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class Parts(unittest.TestCase):
    def test_folder_names(self):
        self.assertEqual(biospkg.parse_name("X30L-M_B210_USB"), ("X30L-M", (2, 10)))
        self.assertEqual(biospkg.parse_name("A40-J_b180_USB"), ("A40-J", (1, 80)))
        self.assertEqual(biospkg.parse_name("Z40L-P_B105"), ("Z40L-P", (1, 5)))
        for bad in ("X30L-M_USB", "X30L-M B210", "readme", "X30L-M_B21_USB", "_B210_USB"):
            self.assertIsNone(biospkg.parse_name(bad), bad)

    def test_laptop_versions(self):
        self.assertEqual(biospkg.version_of("Version 2.10"), (2, 10))
        self.assertEqual(biospkg.version_of("2.00"), (2, 0))
        self.assertIsNone(biospkg.version_of(""))
        self.assertIsNone(biospkg.version_of("V2"))
        self.assertEqual(biospkg.vstr((2, 0)), "2.00")
        self.assertEqual(biospkg.vstr((1, 5)), "1.05")
        # 2.10 is newer than 2.09: the part after the point is a number
        self.assertGreater((2, 10), biospkg.version_of("2.09"))

    def test_model_is_a_word_of_its_own(self):
        names = ["dynabook PORTEGE X30L-M", "", "", ""]
        self.assertTrue(biospkg.model_matches("X30L-M", names))
        self.assertTrue(biospkg.model_matches("x30l-m", names))
        for other in (["PORTEGE X30L-MA"], ["PORTEGE X30L-M5"], ["PORTEGE X30L"], ["PORTEGEX30L-M"],
                      ["PORTEGE AX30L-M"], ["", ""]):
            self.assertFalse(biospkg.model_matches("X30L-M", other), other)
        self.assertTrue(biospkg.model_matches("X30L-M", ["", "X30L-M (PCR21L-0AL01X)"]))

    def test_package_files(self):
        d = tempfile.mkdtemp()
        try:
            write(os.path.join(d, "ShellFlash64.efi"))
            self.assertIsNone(biospkg.package_files(d))                 # no image yet
            write(os.path.join(d, "BIOS0126.bin"))
            self.assertEqual(biospkg.package_files(d), ("ShellFlash64.efi", "BIOS0126.bin"))
            write(os.path.join(d, "BIOS0125.bin"))
            self.assertIsNone(biospkg.package_files(d))                 # two images: never guess
        finally:
            shutil.rmtree(d)
        self.assertIsNone(biospkg.package_files("/no/such/folder"))


class Scan(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.dmi = os.path.join(self.tmp, "dmi")
        self.bios = os.path.join(self.tmp, "BIOS")
        self.laptop("dynabook PORTEGE X30L-M", "Version 2.00")
        os.makedirs(self.bios)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def laptop(self, name, bios):
        write(os.path.join(self.dmi, "product_name"), name + "\n")
        write(os.path.join(self.dmi, "bios_version"), bios + "\n")

    def package(self, folder, files=("ShellFlash64.efi", "BIOS0126.bin")):
        for f in files:
            write(os.path.join(self.bios, folder, f), "x")

    def states(self):
        return {p["folder"]: (p["state"], p["reason"]) for p in biospkg.scan(self.bios, self.dmi)}

    def test_what_is_offered_and_why_not(self):
        self.package("X30L-M_B210_USB")
        self.package("X30L-M_B200_USB")
        self.package("X30L-M_B190_USB")
        self.package("A40-J_B180_USB")
        self.package("X30L-M_USB")
        self.package("Old Toshiba", ("setup.exe", "readme.txt"))
        self.package(".diag", ("shellx64.efi", "startup.nsh"))           # the toolkit's own, hidden
        s = self.states()
        self.assertEqual(s["X30L-M_B210_USB"], ("ok", "2.00 -> 2.10"))
        self.assertEqual(s["X30L-M_B200_USB"][0], "same")
        self.assertEqual(s["X30L-M_B190_USB"], ("older", "older than this laptop's BIOS (2.00)"))
        self.assertEqual(s["A40-J_B180_USB"],
                         ("other-model", "for the A40-J - this laptop is a dynabook PORTEGE X30L-M"))
        self.assertEqual(s["X30L-M_USB"][0], "no-version")
        self.assertEqual(s["Old Toshiba"], ("not-package", biospkg.NOT_PACKAGE))
        self.assertNotIn(".diag", s)
        self.assertEqual(biospkg.scan(self.bios, self.dmi)[0]["folder"], "X30L-M_B210_USB")   # offered first

    def test_names_the_shell_cannot_take_are_not_offered(self):
        # startup.nsh runs them as written: a space splits the command, % # ^
        # mean something to the Shell
        self.package("X30L-M_B210_USB", ("ShellFlash64.efi", "BIOS0126 (1).bin"))
        self.package("X30L-M_B220_USB copy")
        self.package("X30L-M_B230_%USB%")
        s = self.states()
        for folder in ("X30L-M_B210_USB", "X30L-M_B220_USB copy", "X30L-M_B230_%USB%"):
            self.assertEqual(s[folder], ("bad-name", biospkg.BAD_NAME), folder)

    def test_the_series_name_does_not_make_a_match(self):
        # product_family is the series ("dynabook PORTEGE X30L"): a package
        # named for the series would match every model in it
        write(os.path.join(self.dmi, "product_family"), "dynabook PORTEGE X30L\n")
        self.laptop("dynabook PORTEGE X30L-K", "Version 2.00")
        self.package("X30L_B210_USB")
        self.assertEqual(self.states()["X30L_B210_USB"][0], "other-model")

    def test_a_laptop_whose_version_cannot_be_read_gets_nothing(self):
        self.laptop("dynabook PORTEGE X30L-M", "")
        self.package("X30L-M_B210_USB")
        self.assertEqual(self.states()["X30L-M_B210_USB"][0], "unknown")

    def test_no_bios_folder(self):
        self.assertEqual(biospkg.scan(os.path.join(self.tmp, "none"), self.dmi), [])

    def test_the_screen_gets_one_line_per_folder(self):
        self.package("X30L-M_B210_USB")
        self.package("A|B_B100_USB")                                     # a cell separator in a name
        out = subprocess.run([sys.executable, os.path.join(TOOLKIT, "biospkg.py"), "list", self.bios,
                              "--dmi", self.dmi], capture_output=True, text=True, check=True).stdout
        lines = out.splitlines()
        self.assertEqual(lines[0], "X30L-M_B210_USB|ok|X30L-M|2.10|2.00|2.00 -> 2.10|ShellFlash64.efi|BIOS0126.bin")
        self.assertTrue(all(len(l.split("|")) == 8 for l in lines), lines)
        cur = subprocess.run([sys.executable, os.path.join(TOOLKIT, "biospkg.py"), "current", "--dmi", self.dmi],
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(cur.strip(), "2.00")


if __name__ == "__main__":
    unittest.main(verbosity=2)
