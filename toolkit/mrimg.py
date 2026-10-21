#!/usr/bin/env python3
"""Macrium Reflect 7/8 disk images (.mrimg), read for restore and browse -
Ash, 1.22: "my macrium back up image is not readable, means that all of my
previous image is failed to load".

Macrium never published this format (only Reflect X's .mrimgx). The layout
was reverse-engineered by the mrimg7z project and checked here against
Ash's own Reflect 8.0.7783 image of a PORTEGE X40-K: every block decoded
matched the MD5 the image keeps for it. Every block read here is checked
against that MD5 - a misread block is an error, never wrong data written
to a customer's drive.

  [raw FAT system areas + QuickLZ blocks, partition by partition]
  [metadata] [tail: 54 bytes]
  tail: u64 at +6 = where the metadata starts; magic "__79241006_2651_11D4_"
  metadata: 8-byte image id, u16 (0 = a full image), u16 file number,
    u8 length + the path the image was saved to, ... the backup definition
    XML (its length in the u16 before "<?xml"), then the disk's MBR, and on
    a GPT disk the GPT header and entries straight after it
  one section per imaged partition, each opening with that path again; after
    the path: u32 3, u32 1, u16 0, u64 raw-head offset, u32 raw-head length,
    16-byte MD5 of the raw head (a FAT's reserved sectors and FATs, stored as
    they are); 30-byte block records from path end + 36: u64 file offset at
    +6, MD5 of the unpacked block at +14 (all zero: not stored - free
    space); record 0's u32 at +2 is the number of blocks
  blocks: QuickLZ 1.31 (level 2), each one block of the partition after its
    raw head (64 KB; 132 KB on that C:)

Full, unencrypted disk images only: incremental, differential, password
and file-and-folder backups are refused with the reason.

    mrimg.py info IMAGE                  the disk and its partitions (JSON)
    mrimg.py verify IMAGE --status F     every block read back, MD5 checked
    mrimg.py extract IMAGE NUM FILE      one partition to a file (tests)
"""
import argparse
import collections
import ctypes
import hashlib
import json
import os
import re
import struct
import sys
import time
import uuid
import zlib

MAGIC = b"__79241006_2651_11D4_"
TAIL = 54
REC = 30
REC_START = 36          # first record, counted from the end of the section's path
SEC = 512
MiB = 1 << 20
BLOCKS_KEPT = 48        # unpacked blocks kept (132 KB each at most)
RECS_READ = 4096        # block records read at once (120 KB)
LIB_PATHS = (os.environ.get("DIAG_QLZ", ""), "/opt/diag/lib/libqlz.so",
             os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "libqlz.so"))


class NotMacrium(Exception):
    """Not a Macrium Reflect 7/8 image."""


class Unsupported(Exception):
    """A Macrium image this reader does not open; the message says why."""


def _u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def _u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def _u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


# ---------------------------------------------------------------- QuickLZ
class QuickLZ:
    """QuickLZ 1.31 through libqlz.so (toolkit/vendor/quicklz131.c, built by
    finalize_chroot.sh with memory_safe). Python would take hours per image."""

    def __init__(self):
        lib = next((ctypes.CDLL(p) for p in LIB_PATHS if p and os.path.exists(p)), None)
        if lib is None:
            raise Unsupported("the QuickLZ library (libqlz.so) is missing from this toolkit")
        lib.qlz_decompress.restype = ctypes.c_size_t
        lib.qlz_decompress.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]
        self.lib = lib
        self.scratch = ctypes.create_string_buffer(1 << 17)

    @staticmethod
    def header(head):
        """(header length, stored size, unpacked size) of a QuickLZ block."""
        n = 4 if head[0] & 2 else 1
        return 1 + 2 * n, int.from_bytes(head[1:1 + n], "little"), \
            int.from_bytes(head[1 + n:1 + 2 * n], "little")

    def unpack(self, blob):
        _, stored, size = self.header(blob)
        if stored != len(blob) or not 0 < size <= 64 * MiB:
            raise OSError("a block header of the image is damaged")
        out = ctypes.create_string_buffer(size)
        self.lib.qlz_decompress(blob, out, self.scratch)
        return out.raw


# ---------------------------------------------------------------- one partition
class Partition:
    """One imaged partition, readable at any offset: its raw head (FAT) as
    stored, then its blocks unpacked; free space (blocks not stored) reads
    as zeros."""

    def __init__(self, img, num, start, size, sec):
        self.img, self.num, self.start, self.size = img, num, start, size
        self.head_off, self.head_len, self.head_md5 = sec["head_off"], sec["head_len"], sec["head_md5"]
        self.recs, self.count = sec["recs"], sec["count"]
        self.head_ok = self.head_len == 0
        self.cache = collections.OrderedDict()
        self._recs_at, self._recs_buf = -1, b""
        # "No compression" stores blocks bare, without a QuickLZ header
        self.raw = img.compression == "0"
        self.block = self._block_size()

    def record(self, i):
        """Block i's (file offset, MD5). Read 4096 records at a time: one
        read per record took 26 minutes for a quarter of a 3.8-million-block
        image over WSL's /mnt/c (1.23)."""
        chunk, k = divmod(i, RECS_READ)
        if chunk != self._recs_at:
            n = min(RECS_READ, self.count - chunk * RECS_READ)
            self._recs_buf = self.img.pread(self.recs + REC * chunk * RECS_READ, REC * n)
            self._recs_at = chunk
        r = self._recs_buf[REC * k:REC * (k + 1)]
        return _u64(r, 6), r[14:30]

    def _block_size(self):
        """From the first stored block's header - 64 KB, or 132 KB on a big
        C:. Bare blocks have no header: the smallest step between two stored
        blocks is one block."""
        offs = []
        for i in range(min(self.count, 4096)):
            off, md5 = self.record(i)
            if md5 == bytes(16):
                continue
            if not self.raw:
                return QuickLZ.header(self.img.pread(off, 9))[2]
            offs.append(off)
        steps = [b - a for a, b in zip(offs, offs[1:]) if b > a]
        return min(steps) if steps else 64 * 1024

    def _check_head(self):
        h, done = hashlib.md5(), 0
        while done < self.head_len:
            chunk = self.img.pread(self.head_off + done, min(4 * MiB, self.head_len - done))
            if not chunk:
                break
            h.update(chunk)
            done += len(chunk)
        if h.digest() != self.head_md5:
            raise OSError("partition %d's file-system area in the image is damaged" % self.num)
        self.head_ok = True

    def block_data(self, i):
        """Block i unpacked and MD5-checked, or None when it was not stored."""
        if i >= self.count:
            return None
        if i in self.cache:
            self.cache.move_to_end(i)
            return self.cache[i]
        off, md5 = self.record(i)
        if md5 == bytes(16):
            return None
        if self.raw:
            data = self.img.pread(off, self.block)
        else:
            _, stored, _ = QuickLZ.header(self.img.pread(off, 9))
            data = self.img.qlz.unpack(self.img.pread(off, stored))
        if len(data) != self.block or hashlib.md5(data).digest() != md5:
            raise OSError("block %d of partition %d in the image is damaged (checksum)" % (i, self.num))
        self.cache[i] = data
        while len(self.cache) > BLOCKS_KEPT:
            self.cache.popitem(last=False)
        return data

    def read(self, off, n):
        n = max(0, min(n, self.size - off))
        out = bytearray()
        while len(out) < n:
            pos = off + len(out)
            if pos < self.head_len:
                if not self.head_ok:
                    self._check_head()
                take = min(self.head_len - pos, n - len(out))
                out += self.img.pread(self.head_off + pos, take)
                continue
            b, within = divmod(pos - self.head_len, self.block)
            take = min(self.block - within, n - len(out))
            data = self.block_data(b)
            out += data[within:within + take] if data else bytes(take)
        return bytes(out)


# ---------------------------------------------------------------- the image
class MacriumImage:
    """The whole disk as it was imaged: MBR and GPT from the image, the
    imaged partitions where the table puts them, a backup GPT at the end
    (rebuilt - the image keeps only the primary), zeros everywhere else."""

    def __init__(self, path):
        self.path = path
        self.fd = os.open(path, os.O_RDONLY)
        self.file_size = os.fstat(self.fd).st_size
        self.qlz = None
        try:
            self._parse()
        except Exception:
            os.close(self.fd)
            raise

    def pread(self, off, n):
        return os.pread(self.fd, n, off)

    def close(self):
        os.close(self.fd)

    # ---- parsing
    def _parse(self):
        if self.file_size < 4096:
            raise NotMacrium("too small to be a Macrium image")
        tail = self.pread(self.file_size - TAIL, TAIL)
        if tail[14:14 + len(MAGIC)] != MAGIC:
            raise NotMacrium("not a Macrium Reflect 7/8 image")
        self.meta_at = _u64(tail, 6)
        if not 0 < self.meta_at < self.file_size:
            raise NotMacrium("the image's index is damaged")
        meta = self.pread(self.meta_at, min(4 * MiB, self.file_size - self.meta_at))
        self.image_id = meta[:8].hex()
        # u16 at 8 is the piece of a split image (name-00-NN), u16 at 10 the
        # backup in its set (name-NN-00: 00 the full one) - Macrium's names
        if _u16(meta, 10) != 0:
            raise Unsupported("an incremental or differential image - only full images open here; "
                              "restore it with Macrium, or make a full image")
        if _u16(meta, 8) != 0 or self._next_piece():
            raise Unsupported("one image split into several files - not supported yet; "
                              "restore it with Macrium")
        self.own_path = meta[13:13 + meta[12]]
        self._parse_xml(meta)
        table_end = self._parse_table(meta)
        self.parts = self._parse_sections(meta, table_end)
        self.qlz = QuickLZ()
        self.partitions = {}
        for p, sec in self.parts:
            self.partitions[p["num"]] = Partition(self, p["num"], p["start"] * SEC, p["size"] * SEC, sec)

    def _next_piece(self):
        """A split image keeps its index only in its last piece; the first
        piece's own index is just the XML (test image gpt-split, 1.23)."""
        m = re.search(r"-(\d\d)-(\d\d)\.mrimg$", self.path, re.I)
        if not m:
            return False
        nxt = "%s-%s-%02d.mrimg" % (self.path[:m.start()], m.group(1), int(m.group(2)) + 1)
        return os.path.exists(nxt)

    def _parse_xml(self, meta):
        x = meta.find(b"<?xml")
        if x < 2:
            raise NotMacrium("no backup definition in the image")
        n = _u16(meta, x - 2)
        if n == 0xFFFF:
            n = _u32(meta, x - 6)
        self.xml_end = x + n
        xml = meta[x:x + n].split(b"\0")[0].decode("utf-8", "replace")
        tag = lambda t, d="": (re.search(r"<%s(?:\s[^>]*)?>([^<]*)</%s>" % (t, t), xml) or [None, d])[1]
        if tag("backup_type", "0").strip() != "0":
            raise Unsupported("a file and folder backup, not a disk image")
        if tag("aes", "0").strip() not in ("", "0") or tag("password").strip():
            raise Unsupported("protected with a password - restore it with Macrium")
        self.compression = tag("compression", "?").strip()
        self.machine = tag("netbios").strip()
        stamp = tag("backup_set_date").strip()
        self.saved = time.strftime("%Y-%m-%d %H:%M", time.localtime(int(stamp))) if stamp.isdigit() else ""
        self.xml_parts = [int(v) for v in re.findall(r"<partition[^>]*>\s*(\d+)\s*</partition>", xml)]

    def _parse_table(self, meta):
        mbr = meta.find(b"\x55\xaa", self.xml_end, self.xml_end + 1024)
        if mbr < 0:
            raise Unsupported("no partition table in the image")
        m0 = mbr - 510
        self.mbr = meta[m0:m0 + SEC]
        gpt = meta[m0 + SEC:m0 + 2 * SEC]
        self.table = []
        if gpt[:8] == b"EFI PART":
            self.label = "gpt"
            ent_lba, n_ent, ent_size = struct.unpack_from("<QII", gpt, 72)
            self.gpt_header = gpt[:_u32(gpt, 12)]
            self.gpt_entries = meta[m0 + SEC * ent_lba:m0 + SEC * ent_lba + n_ent * ent_size]
            self.gpt_layout = (ent_lba, n_ent, ent_size)
            self.sectors = _u64(gpt, 32) + 1                      # alternate LBA + 1
            self.disk_id = str(uuid.UUID(bytes_le=gpt[56:72])).upper()
            num = 0
            for i in range(n_ent):
                e = self.gpt_entries[i * ent_size:(i + 1) * ent_size]
                if e[:16] == bytes(16):
                    continue
                num += 1
                first, last = struct.unpack_from("<QQ", e, 32)
                self.table.append({"num": num, "slot": i + 1, "start": first, "size": last - first + 1,
                                   "type": str(uuid.UUID(bytes_le=e[:16])).upper(),
                                   "uuid": str(uuid.UUID(bytes_le=e[16:32])).upper(),
                                   "name": e[56:128].decode("utf-16-le", "replace").rstrip("\0")})
            return m0 + SEC * ent_lba + n_ent * ent_size
        self.label = "dos"
        self.disk_id = "0x%08x" % _u32(self.mbr, 440)
        for i in range(4):
            e = self.mbr[446 + 16 * i:462 + 16 * i]
            if e[4] in (0, 0x05, 0x0F, 0x85):
                if e[4]:
                    raise Unsupported("an MBR image with logical partitions - not yet supported here")
                continue
            self.table.append({"num": i + 1, "slot": i + 1, "start": _u32(e, 8), "size": _u32(e, 12),
                               "type": "%x" % e[4], "bootable": e[0] == 0x80, "uuid": "", "name": ""})
        end = max((p["start"] + p["size"] for p in self.table), default=2048)
        self.sectors = (end + 2047) // 2048 * 2048                # the real disk was bigger; unknown
        return m0 + SEC

    def _section(self, at):
        """The section header at metadata offset `at` (where its path starts)."""
        b = self.pread(self.meta_at + at + len(self.own_path), REC_START + 8)
        if _u32(b, 0) != 3:
            raise Unsupported("an index layout this toolkit does not know")
        return {"head_off": _u64(b, 10), "head_len": _u32(b, 18), "head_md5": b[22:38],
                "count": _u32(b, REC_START + 2),
                "recs": self.meta_at + at + len(self.own_path) + REC_START}

    def _parse_sections(self, meta, table_end):
        wanted = self.xml_parts or [p["num"] for p in self.table]
        by_num = {p["num"]: p for p in self.table}
        out, at = [], meta.find(self.own_path, table_end)
        for k, num in enumerate(wanted):
            if at < 0:
                raise Unsupported("the image lists %d partitions but holds %d" % (len(wanted), k))
            sec = self._section(at)
            p = by_num.get(num)
            if p is None:
                raise Unsupported("partition %d of the image is not in its partition table" % num)
            out.append((p, sec))
            nxt = sec["recs"] - self.meta_at + REC * sec["count"]
            look = self.pread(self.meta_at + nxt, 4096)
            i = look.find(self.own_path)
            at = nxt + i if i >= 0 else -1
        return out

    # ---- the disk
    @property
    def size(self):
        return self.sectors * SEC

    def _gpt_backup(self):
        ent_lba, n_ent, ent_size = self.gpt_layout
        ent_secs = (n_ent * ent_size + SEC - 1) // SEC
        last = self.sectors - 1
        h = bytearray(self.gpt_header)
        struct.pack_into("<QQ", h, 24, last, 1)
        struct.pack_into("<Q", h, 72, last - ent_secs)
        struct.pack_into("<I", h, 16, 0)
        struct.pack_into("<I", h, 16, zlib.crc32(bytes(h)) & 0xFFFFFFFF)
        return (last - ent_secs) * SEC, bytes(self.gpt_entries), last * SEC, bytes(h)

    def segments(self):
        if hasattr(self, "_segs"):
            return self._segs
        segs = [(0, self.mbr, None)]
        if self.label == "gpt":
            ent_lba = self.gpt_layout[0]
            segs.append((SEC, self.gpt_header, None))
            segs.append((ent_lba * SEC, bytes(self.gpt_entries), None))
            e_off, entries, h_off, hdr = self._gpt_backup()
            segs += [(e_off, entries, None), (h_off, hdr, None)]
        for part in self.partitions.values():
            segs.append((part.start, None, part))
        self._segs = sorted(segs, key=lambda s: s[0])
        return self._segs

    def read(self, off, n):
        n = max(0, min(n, self.size - off))
        out = bytearray(n)
        for start, data, part in self.segments():
            length = part.size if part else len(data)
            a, b = max(off, start), min(off + n, start + length)
            if a >= b:
                continue
            chunk = part.read(a - start, b - a) if part else data[a - start:b - start]
            out[a - off:a - off + len(chunk)] = chunk
        return bytes(out)

    def partition(self, num):
        if num not in self.partitions:
            raise Unsupported("partition %d is not in this image" % num)
        return self.partitions[num]

    # ---- for the screens
    def fs_of(self, part):
        b = part.read(0, 4096)
        if b[3:11] == b"NTFS    ":
            return "ntfs"
        if b[3:11] == b"EXFAT   ":
            return "exfat"
        if b[82:87] == b"FAT32" or b[54:57] == b"FAT":
            return "vfat"
        if len(b) >= 1082 and b[1080:1082] == b"\x53\xef":
            return "ext4"
        if b[3:11] == b"-FVE-FS-":
            return "bitlocker"
        return ""

    def info(self):
        parts = []
        for p in self.table:
            q = dict(p, imaged=p["num"] in self.partitions)
            if q["imaged"]:
                part = self.partitions[p["num"]]
                q.update(fs=self.fs_of(part), block=part.block)
            parts.append(q)
        return {"file": self.path, "label": self.label, "bytes": self.size, "sector": SEC,
                "id": self.disk_id, "compression": self.compression, "machine": self.machine,
                "saved": self.saved, "image_id": self.image_id, "parts": parts}

    def verify(self, job):
        """Every raw head and stored block read back and checked."""
        parts = list(self.partitions.values())
        job.total_w = sum(p.count for p in parts) or 1
        job.set(steps=len(parts), phase="verify")
        for part in parts:
            job.step("Checking partition %d" % part.num, part.count)
            if part.head_len:
                part._check_head()
            for i in range(part.count):
                part.block_data(i)
                part.cache.clear()
                if i % 512 == 0:
                    pct = (job.done_w + i) * 100 // job.total_w
                    job.set(partpct=i * 100 // max(1, part.count), pct=min(99, pct))
            job.finish_step()


def is_macrium(path):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            if f.tell() < 4096:
                return False
            f.seek(-TAIL, 2)
            return f.read(TAIL)[14:14 + len(MAGIC)] == MAGIC
    except OSError:
        return False


def main(argv):
    ap = argparse.ArgumentParser(prog="mrimg.py")
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--status", default="/run/diag/imaging.status")
    a = ap.parse_args(argv[1:])
    try:
        img = MacriumImage(a.args[0])
        if a.cmd == "info":
            print(json.dumps(img.info(), indent=1))
        elif a.cmd == "verify":
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import imgengine
            return imgengine.run_job(lambda job: img.verify(job), a.status)
        elif a.cmd == "extract":
            part = img.partition(int(a.args[1]))
            with open(a.args[2], "wb") as out:
                for off in range(0, part.size, 4 * MiB):
                    data = part.read(off, 4 * MiB)
                    if data.count(0) == len(data):
                        out.seek(len(data), 1)                 # sparse: free space
                    else:
                        out.write(data)
                out.truncate(part.size)
        else:
            print(__doc__)
            return 2
    except (NotMacrium, Unsupported, OSError) as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
