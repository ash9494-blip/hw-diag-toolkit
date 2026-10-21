#!/usr/bin/env python3
"""Unit tests for toolkit/mrimg.py - Macrium Reflect 7/8 images.

Real images are checked by test/imaging-loop.sh (case macrium, images made
by Macrium itself). Here, small .mrimg files are written in the layout
mrimg.py documents - so the build can test every path without Macrium:
reads at any offset, a FAT partition's raw head, free space, the disk's
rebuilt backup GPT, damaged blocks, and the images that are refused.
Needs libqlz.so (DIAG_QLZ, or /opt/diag/lib):

    DIAG_QLZ=/path/libqlz.so python3 test/mrimg_test.py
"""
import ctypes
import hashlib
import os
import random
import struct
import sys
import tempfile
import unittest
import uuid
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "toolkit"))
import mrimg  # noqa: E402

SEC = 512
EFI = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
BASIC = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"


def qlz_compress(data):
    lib = next(ctypes.CDLL(p) for p in mrimg.LIB_PATHS if p and os.path.exists(p))
    lib.qlz_compress.restype = ctypes.c_size_t
    lib.qlz_compress.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
    out = ctypes.create_string_buffer(len(data) * 2 + 1024)
    scratch = ctypes.create_string_buffer(1 << 20)
    n = lib.qlz_compress(data, out, len(data), scratch)
    return out.raw[:n]


def gpt(disk_sectors, parts):
    """Primary GPT header (92 bytes) and 128 entries for `parts`
    [(first_lba, sectors, type, name)]."""
    entries = bytearray(128 * 128)
    for i, (first, size, ptype, name) in enumerate(parts):
        e = uuid.UUID(ptype).bytes_le + uuid.uuid4().bytes_le
        e += struct.pack("<QQQ", first, first + size - 1, 0) + name.encode("utf-16-le").ljust(72, b"\0")
        entries[i * 128:(i + 1) * 128] = e
    h = bytearray(92)
    h[:8] = b"EFI PART"
    struct.pack_into("<IIIIQQQQ", h, 8, 0x10000, 92, 0, 0, 1, disk_sectors - 1, 34, disk_sectors - 34)
    h[56:72] = uuid.UUID("6D9E2A1B-1111-4C22-8E33-ABCDEF012345").bytes_le
    struct.pack_into("<QIII", h, 72, 2, 128, 128, zlib.crc32(bytes(entries)))
    struct.pack_into("<I", h, 16, zlib.crc32(bytes(h)))
    return bytes(h), bytes(entries)


def write_mrimg(path, parts, disk_sectors=8192, compression="1", piece=0, increment=0,
                aes="0", tamper_block=None, dos=False):
    """parts: [{"first": lba, "data": bytes, "head": bytes, "block": n}] - data
    after the head, cut into blocks; all-zero blocks are left unstored."""
    own = ("C:\\Images\\test-%02d-%02d.mrimg" % (increment, piece)).encode()
    body, sections = bytearray(), []
    for p in parts:
        head_off = len(body)
        body += p["head"]
        recs = []
        for i in range(0, len(p["data"]), p["block"]):
            blk = p["data"][i:i + p["block"]].ljust(p["block"], b"\0")
            if blk.count(0) == len(blk):
                recs.append((0, bytes(16)))
                continue
            md5 = hashlib.md5(blk).digest()
            if tamper_block == (len(sections), len(recs)):
                blk = b"\xff" + blk[1:]
            recs.append((len(body), md5))
            body += blk if compression == "0" else qlz_compress(blk)
        sections.append((head_off, p["head"], recs))
    meta_at = len(body)
    xml = ("<?xml version=\"1.0\"?><backup_definition><properties><backup_type>0</backup_type>"
           "<compression>%s</compression><password Type=\"Clear\"/><aes>%s</aes></properties>"
           "<source>%s</source><netbios>TESTPC</netbios><backup_set_date>1785294046</backup_set_date>"
           "</backup_definition>" % (compression, aes, "".join(
               "<image_entry id=\"%d\"><partition BitLocker=\"0\">%d</partition></image_entry>" % (k + 1, k + 1)
               for k in range(len(parts))))).encode()
    meta = bytearray(b"IMAGEID1" + struct.pack("<HH", piece, increment) + bytes([len(own)]) + own)
    meta += bytes(40) + struct.pack("<H", len(xml)) + xml + bytes(64)
    mbr = bytearray(SEC)
    mbr[440:444] = b"\x00\xed\xa1\x5e"
    if dos:
        for i, p in enumerate(parts):
            struct.pack_into("<B3xB3xII", mbr, 446 + 16 * i, 0x80 if i == 0 else 0, 0x07,
                             p["first"], (len(p["head"]) + len(p["data"])) // SEC)
    else:
        struct.pack_into("<B3xB3xII", mbr, 446, 0, 0xEE, 1, disk_sectors - 1)
    mbr[510:512] = b"\x55\xaa"
    meta += mbr
    if not dos:
        h, entries = gpt(disk_sectors, [(p["first"], (len(p["head"]) + len(p["data"])) // SEC,
                                         EFI if p["head"] else BASIC, "part%d" % k) for k, p in enumerate(parts)])
        meta += h.ljust(SEC, b"\0") + entries
    for head_off, head, recs in sections:
        md5 = hashlib.md5(head).digest()
        meta += bytes(47) + bytes([len(own)]) + own
        meta += struct.pack("<IIHQI", 3, 1, 0, head_off, len(head)) + md5[:14]
        for k, (off, bmd5) in enumerate(recs):
            first = md5[14:16] + struct.pack("<I", len(recs)) if k == 0 else bytes(6)
            meta += first + struct.pack("<Q", off) + bmd5
        meta += bytes(200)
    tail = bytes(6) + struct.pack("<Q", meta_at) + mrimg.MAGIC + b"\0\x07\x00" + bytes(16)
    with open(path, "wb") as f:
        f.write(body + meta + tail)


class Reader(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        rnd = random.Random(3)
        self.fat_head = rnd.randbytes(3 * SEC)
        self.efi = rnd.randbytes(64 * 1024) + bytes(64 * 1024) + rnd.randbytes(64 * 1024 - 3 * SEC)
        self.c = bytes(128 * 1024) + rnd.randbytes(200 * 1024) + b"text " * 20000
        self.c = self.c[:len(self.c) // (64 * 1024) * (64 * 1024)]
        self.parts = [{"first": 2048, "head": self.fat_head, "data": self.efi, "block": 65536},
                      {"first": 4096, "head": b"", "data": self.c, "block": 65536}]
        self.path = os.path.join(self.tmp, "test-00-00.mrimg")

    def open(self, **kw):
        write_mrimg(self.path, self.parts, **kw)
        img = mrimg.MacriumImage(self.path)
        self.addCleanup(img.close)
        return img

    def test_partitions_read_back(self):
        img = self.open()
        efi, c = img.partition(1), img.partition(2)
        self.assertEqual(efi.read(0, efi.size), self.fat_head + self.efi)
        self.assertEqual(c.read(0, c.size), self.c)
        rnd = random.Random(9)
        for _ in range(200):
            off = rnd.randrange(0, c.size)
            n = rnd.randrange(1, 150000)
            self.assertEqual(c.read(off, n), self.c[off:off + n])

    def test_free_space_reads_as_zeros(self):
        img = self.open()
        self.assertEqual(img.partition(2).read(0, 128 * 1024), bytes(128 * 1024))

    def test_the_disk_has_both_gpts(self):
        img = self.open()
        self.assertEqual(img.read(510, 2), b"\x55\xaa")
        self.assertEqual(img.read(SEC, 8), b"EFI PART")
        self.assertEqual(img.read(4096 * SEC, len(self.c)), self.c)
        last = img.read(img.size - SEC, 92)
        self.assertEqual(last[:8], b"EFI PART")
        my_lba, alt = struct.unpack_from("<QQ", last, 24)
        self.assertEqual((my_lba, alt), (img.sectors - 1, 1))
        h = bytearray(last)
        crc = struct.unpack_from("<I", h, 16)[0]
        struct.pack_into("<I", h, 16, 0)
        self.assertEqual(zlib.crc32(bytes(h)), crc)
        ent_lba = struct.unpack_from("<Q", last, 72)[0]
        self.assertEqual(img.read(ent_lba * SEC, 128 * 128), img.gpt_entries)

    def test_info(self):
        info = self.open().info()
        self.assertEqual(info["label"], "gpt")
        self.assertEqual([p["num"] for p in info["parts"]], [1, 2])
        self.assertTrue(all(p["imaged"] for p in info["parts"]))
        self.assertEqual(info["machine"], "TESTPC")

    def test_mbr_disk(self):
        img = self.open(dos=True)
        self.assertEqual(img.label, "dos")
        self.assertEqual(img.partition(2).read(0, len(self.c)), self.c)

    def test_no_compression(self):
        img = self.open(compression="0")
        self.assertEqual(img.partition(2).read(0, len(self.c)), self.c)
        self.assertEqual(img.partition(1).block, 65536)

    def test_a_damaged_block_is_an_error(self):
        img = self.open(tamper_block=(1, 3))
        with self.assertRaises(OSError):
            img.partition(2).read(3 * 65536, 10)
        self.assertEqual(img.partition(2).read(4 * 65536, 10), self.c[4 * 65536:4 * 65536 + 10])

    def test_a_damaged_fat_head_is_an_error(self):
        write_mrimg(self.path, self.parts)
        with open(self.path, "r+b") as f:
            f.write(b"\x00\x01")
        img = mrimg.MacriumImage(self.path)
        self.addCleanup(img.close)
        with self.assertRaises(OSError):
            img.partition(1).read(0, 10)

    def test_refused_images(self):
        for kw, word in (({"increment": 1}, "incremental"), ({"piece": 1}, "split"),
                         ({"aes": "3"}, "password")):
            write_mrimg(self.path, self.parts, **kw)
            with self.assertRaises(mrimg.Unsupported) as cm:
                mrimg.MacriumImage(self.path)
            self.assertIn(word, str(cm.exception))

    def test_first_piece_of_a_split_set_is_refused(self):
        write_mrimg(self.path, self.parts)
        open(os.path.join(self.tmp, "test-00-01.mrimg"), "wb").close()
        with self.assertRaises(mrimg.Unsupported):
            mrimg.MacriumImage(self.path)

    def test_not_macrium(self):
        with open(self.path, "wb") as f:
            f.write(os.urandom(8192))
        self.assertFalse(mrimg.is_macrium(self.path))
        with self.assertRaises(mrimg.NotMacrium):
            mrimg.MacriumImage(self.path)


if __name__ == "__main__":
    unittest.main(verbosity=1)
