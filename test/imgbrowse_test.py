#!/usr/bin/env python3
"""Unit tests for toolkit/imgbrowse.py: the reader - any byte of a
partition, read out of a partclone image compressed in independent zstd
frames - and what is listed and copied out of the mounted partition.

The images are made here, byte by byte, the way partclone 0.3 lays them out
(header, bitmap + CRC, used blocks with a checksum after every N), then cut
into frames and pieces the way imgengine.save_part writes them - with frames
of a few KB instead of 32 MB. Needs the zstd command, no disks:

    python3 test/imgbrowse_test.py
"""
import os
import random
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "toolkit"))
import imgbrowse  # noqa: E402


def partclone_v2(device, block, used, per=0, csize=0, fs=b"NTFS"):
    """A version 0002 image of `device` holding the blocks in `used`."""
    total = len(device) // block
    head = b"partclone-image\0" + b"0.3.27".ljust(14, b"\0") + b"0002" + struct.pack("<H", 0xC0DE)
    head += fs.ljust(16, b"\0")
    head += struct.pack("<QQQQ", len(device), total, len(used), len(used))
    head += struct.pack("<IIHHHHIBB", block, 0, 2, 64, 32 if csize else 0, csize, per, 1, 1)
    head += b"CRC!"
    assert len(head) == 110
    bitmap = bytearray((total + 7) // 8)
    for b in used:
        bitmap[b >> 3] |= 1 << (b & 7)
    out = bytearray(head + bitmap + b"BMCK")
    for k, b in enumerate(sorted(used)):
        out += device[b * block:(b + 1) * block]
        if per and (k + 1) % per == 0:
            out += b"\xee" * csize
    if per and len(used) % per:
        out += b"\xee" * csize
    return bytes(out)


def frames(stream, chunk, tmp, pieces=1):
    """zstd frames of `chunk` bytes each, written as `pieces` files cut at
    arbitrary places; returns (files, compressed frame sizes)."""
    blobs = []
    for i in range(0, len(stream), chunk):
        r = subprocess.run(["zstd", "-q", "-c"], input=stream[i:i + chunk], capture_output=True, check=True)
        blobs.append(r.stdout)
    data = b"".join(blobs)
    cuts = sorted(random.Random(7).sample(range(1, len(data)), pieces - 1)) if pieces > 1 else []
    files = []
    for n, (a, b) in enumerate(zip([0] + cuts, cuts + [len(data)])):
        p = os.path.join(tmp, "sda3.ntfs-ptcl-img.zst.a%s" % chr(97 + n))
        with open(p, "wb") as f:
            f.write(data[a:b])
        files.append(p)
    return files, [len(b) for b in blobs]


class Reader(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.rnd = random.Random(1)
        self.streams = []

    def tearDown(self):
        for s in self.streams:
            s.close()

    def device(self, blocks, block):
        return self.rnd.randbytes(blocks * block)

    def stream(self, *args):
        s = imgbrowse.Stream(*args)
        self.streams.append(s)
        return s

    def check(self, part, device, used, block, tries=300):
        expect = bytearray(len(device))
        for b in used:
            expect[b * block:(b + 1) * block] = device[b * block:(b + 1) * block]
        self.assertEqual(part.read(0, len(device)), bytes(expect))
        for _ in range(tries):
            off = self.rnd.randrange(0, len(device))
            n = self.rnd.randrange(1, 5 * block)
            self.assertEqual(part.read(off, n), bytes(expect[off:off + n]), "read %d+%d" % (off, n))

    def build(self, blocks=300, block=512, density=0.6, per=0, csize=0, chunk=3000, pieces=1):
        device = self.device(blocks, block)
        used = sorted(b for b in range(blocks) if self.rnd.random() < density)
        files, sizes = frames(partclone_v2(device, block, used, per, csize), chunk, self.tmp, pieces)
        part = imgbrowse.Partition(self.stream(files, "zst", sizes, chunk))
        return part, device, used

    def test_plain_blocks(self):
        part, device, used = self.build()
        self.assertEqual(part.size, len(device))
        self.check(part, device, used, 512)

    def test_checksum_after_every_n_blocks(self):
        part, device, used = self.build(per=7, csize=4)
        self.check(part, device, used, 512)

    def test_4k_blocks_frames_cut_mid_block_and_pieces(self):
        part, device, used = self.build(blocks=90, block=4096, chunk=5000, per=64, csize=4, pieces=3)
        self.check(part, device, used, 4096, tries=150)

    def test_rank_counts_used_blocks_before(self):
        part, _, used = self.build(blocks=70000, block=512, density=0.3, chunk=1 << 20)
        s = set(used)
        n = 0
        for b in range(70000):
            if b % 997 == 0 or b in (32767, 32768, 65536):
                self.assertEqual(part.rank(b), n, "block %d" % b)
            n += b in s

    def test_empty_and_full(self):
        for density in (0.0, 1.0):
            part, device, used = self.build(blocks=40, density=density)
            self.check(part, device, used, 512, tries=40)

    def test_reads_past_the_end_are_cut(self):
        part, device, _ = self.build(blocks=20)
        self.assertEqual(len(part.read(len(device) - 100, 4096)), 100)
        self.assertEqual(part.read(len(device), 512), b"")

    def test_raw_image_is_the_partition(self):
        device = self.device(50, 512)
        files, sizes = frames(device, 2000, self.tmp)
        part = imgbrowse.Partition(self.stream(files, "zst", sizes, 2000), part_bytes=len(device))
        self.assertTrue(part.raw)
        self.assertEqual(part.read(1000, 3000), device[1000:4000])

    def test_partition_reaches_the_tables_size(self):
        # NTFS's backup boot sector lies past the last cluster: the device
        # must be as big as the partition, the tail reading as zeros
        device = self.device(40, 512)
        used = list(range(0, 40, 3))
        files, sizes = frames(partclone_v2(device, 512, used), 3000, self.tmp)
        part = imgbrowse.Partition(self.stream(files, "zst", sizes, 3000), part_bytes=len(device) + 4096)
        self.assertEqual(part.size, len(device) + 4096)
        self.assertEqual(part.read(len(device), 4096), bytes(4096))

    def test_no_index_is_refused(self):
        files, _ = frames(b"x" * 5000, 2000, self.tmp)
        with self.assertRaises(imgbrowse.NotBrowsable):
            imgbrowse.Stream(files, "zst", None, 2000)

    def test_wrong_index_is_refused(self):
        files, sizes = frames(b"x" * 5000, 2000, self.tmp)
        with self.assertRaises(imgbrowse.NotBrowsable):
            imgbrowse.Stream(files, "zst", sizes[:-1], 2000)

    def test_gzip_is_refused(self):
        with self.assertRaises(imgbrowse.NotBrowsable):
            imgbrowse.Stream([], "gz", [1], 2000)

    def test_damaged_frame_is_an_io_error(self):
        part, device, used = self.build(blocks=200, chunk=3000)
        with open(part.stream.pieces[0][0].name, "r+b") as f:
            f.seek(part.stream.starts[2] + 20)
            f.write(b"\0" * 40)
        part.stream.cache.clear()
        with self.assertRaises(OSError):
            for off in range(0, len(device), 4096):
                part.read(off, 4096)


class FakeJob:
    def __init__(self):
        self.st, self.total_w = {}, 1

    def set(self, **kw):
        self.st.update(kw)

    def step(self, what, weight):
        self.st["what"] = what

    def finish_step(self):
        pass


class Copying(unittest.TestCase):
    """What is listed and copied out of a mounted image - here a folder made
    to look like one: ordinary files, a link, a FIFO."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.src = os.path.join(self.tmp, "Documents")
        os.makedirs(os.path.join(self.src, "Invoices 2025"))
        for rel, data in (("report.docx", b"r" * 3000), ("Invoices 2025/inv-001.pdf", b"i" * 70000)):
            with open(os.path.join(self.src, rel), "wb") as f:
                f.write(data)
        os.mkfifo(os.path.join(self.src, "pipe"))             # would block a copy forever
        os.symlink("/", os.path.join(self.src, "loop"))       # a junction-like loop
        self.dest = os.path.join(self.tmp, "stick")
        os.makedirs(self.dest)

    def test_walk_takes_ordinary_files_only(self):
        files, unreadable = imgbrowse.walk(self.src)
        names = sorted(os.path.relpath(p, self.src) for p, _ in files)
        self.assertEqual(names, ["Invoices 2025/inv-001.pdf", "report.docx"])
        self.assertEqual(unreadable, [])

    def test_copy_a_folder_twice(self):
        job = FakeJob()
        imgbrowse.copy(job, self.src, self.dest)
        with open(os.path.join(self.dest, "Documents", "Invoices 2025", "inv-001.pdf"), "rb") as f:
            self.assertEqual(f.read(), b"i" * 70000)
        self.assertFalse(os.path.exists(os.path.join(self.dest, "Documents", "pipe")))
        imgbrowse.copy(job, self.src, self.dest)
        self.assertEqual(job.st["dest"], os.path.join(self.dest, "Documents (2)"))

    def test_a_second_file_keeps_its_extension(self):
        job = FakeJob()
        for _ in range(2):
            imgbrowse.copy(job, os.path.join(self.src, "report.docx"), self.dest)
        self.assertEqual(sorted(os.listdir(self.dest)), ["report (2).docx", "report.docx"])

    def test_a_fifo_alone_is_refused(self):
        with self.assertRaises(imgbrowse.imgengine.Fail):
            imgbrowse.copy(FakeJob(), os.path.join(self.src, "pipe"), self.dest)

    def test_a_read_error_is_the_images(self):
        # a folder opened as a file stands in for a file the image cannot give
        with self.assertRaises(imgbrowse._ReadError):
            imgbrowse._copy_one(self.src, os.path.join(self.dest, "x"), "x", lambda n, r: None)
        self.assertFalse(os.path.exists(os.path.join(self.dest, "x")))

    def test_a_write_error_is_the_drives(self):
        with self.assertRaises(imgbrowse.imgengine.Fail) as cm:
            imgbrowse._copy_one(os.path.join(self.src, "report.docx"),
                                os.path.join(self.dest, "gone", "report.docx"), "report.docx",
                                lambda n, r: None)
        self.assertIn("could not write to that drive", str(cm.exception))

    def test_listing_shows_folders_first_and_skips_odd_entries(self):
        out = subprocess.run([sys.executable, imgbrowse.__file__, "ls", self.src],
                             capture_output=True, text=True, env=dict(os.environ, RUN_DIR=self.tmp)).stdout
        rows = [l.split("|") for l in out.splitlines()]
        self.assertEqual([(r[0], r[3]) for r in rows], [("d", "Invoices 2025"), ("f", "report.docx")])


if __name__ == "__main__":
    unittest.main(verbosity=1)
