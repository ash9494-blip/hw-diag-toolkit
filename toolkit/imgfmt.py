#!/usr/bin/env python3
"""The image folder - Clonezilla's layout, so Clonezilla can restore what the
toolkit saves and the toolkit can restore what Clonezilla saved.

  disk, parts                 which drive, which partitions
  sda-pt.sf, sda-pt.parted    the partition table (sfdisk -d, parted print)
  sda-gpt-1st/-2nd/.gdisk     the GPT itself; sda-mbr, the boot sector
  sda3.ntfs-ptcl-img.zst      one partition: partclone image, zstd
  sda3.ntfs-ptcl-img.zst.aa   ... split into pieces on a FAT32 drive
  clonezilla-img, Info-*.txt  Clonezilla's own markers and machine notes

The toolkit's extras live in diag/, where Clonezilla never looks: its file
globs ("sda3.ntfs-ptcl-img.zst.*") would take an index file sitting next to
the pieces for one more piece of the image.

The zstd stream is written as independent 32 MB frames. Any zstd reads that
as one ordinary stream (Clonezilla does), and diag/<part>.idx - the size of
each frame - lets "browse an image" start reading in the middle.
"""
import glob
import os
import re
import struct
import subprocess

CHUNK = 32 * 1024 * 1024
SIDE = "diag"
DECOMP = {"zst": "zstd -dc", "gz": "gzip -dc", "xz": "xz -dc", "bz2": "bzip2 -dc",
          "lz4": "lz4 -dc", "lzo": "lzop -dc", "uncomp": "cat"}
_IMG_RE = re.compile(r"^(?P<part>.+?)\.(?P<fs>[a-z0-9+]+)-ptcl-img\.(?P<comp>[a-z0-9]+)(?:\.(?P<piece>[a-z]{2,}))?$")


def to_filename(node):
    """Clonezilla's name for a device in file names: /dev/nvme0n1p3 -> nvme0n1p3."""
    return node.replace("/dev/", "", 1).replace("/", "-")


def quote(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


# ---------------------------------------------------------------- reading
def part_images(imgdir):
    """{part name: (fs, comp, [files in order])} for every partition image."""
    found = {}
    for path in sorted(glob.glob(os.path.join(imgdir, "*-ptcl-img.*"))):
        m = _IMG_RE.match(os.path.basename(path))
        if not m:
            continue
        key = m.group("part")
        fs, comp, files = found.get(key, (m.group("fs"), m.group("comp"), []))
        files.append(path)
        found[key] = (fs, comp, files)
    return found


def is_image(d):
    return (os.path.isfile(os.path.join(d, "disk")) or os.path.isfile(os.path.join(d, "parts"))) \
        and bool(part_images(d))


_MR_PIECE = re.compile(r"-\d\d-(\d\d)\.mrimg$", re.I)


def find_images(root, depth=2):
    """Image folders under a drive's root - at the top or one level down
    (Clonezilla users often keep them in partimag/) - and Macrium Reflect
    image files (.mrimg; the later pieces of a split one, -NN-01 on, are
    not images of their own)."""
    out = []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return out
    for n in names:
        d = os.path.join(root, n)
        if n.startswith("."):
            continue
        if os.path.isfile(d):
            m = _MR_PIECE.search(n)
            if n.lower().endswith(".mrimg") and not (m and m.group(1) != "00"):
                out.append(d)
            continue
        if not os.path.isdir(d):
            continue
        if is_image(d):
            out.append(d)
        elif depth > 1:
            out.extend(find_images(d, depth - 1))
    return out


def read_words(path):
    try:
        with open(path) as f:
            return f.read().split()
    except OSError:
        return []


def parse_sf(text):
    """An sfdisk -d dump into the disk description imgplan.py uses."""
    disk = {"label": "dos", "id": "", "firstlba": None, "sector": 512, "parts": []}
    for line in text.splitlines():
        line = line.strip()
        if " : " in line and line.startswith("/dev/"):
            node, _, rest = line.partition(" : ")
            p = {"node": node, "num": int(re.search(r"(\d+)$", node).group(1)),
                 "type": "", "uuid": "", "name": "", "attrs": "", "bootable": False}
            for k, v in re.findall(r'(\w[\w-]*)\s*=\s*("[^"]*"|[^,]+)', rest):
                v = v.strip().strip('"')
                if k in ("start", "size"):
                    p[k] = int(v)
                elif k in ("type", "uuid", "name", "attrs"):
                    p[k] = v
            p["bootable"] = bool(re.search(r"(^|,)\s*bootable\s*(,|$)", rest))
            disk["parts"].append(p)
            continue
        k, sep, v = line.partition(":")
        if not sep:
            continue
        k, v = k.strip(), v.strip()
        if k == "label":
            disk["label"] = v
        elif k == "label-id":
            disk["id"] = v
        elif k == "first-lba":
            disk["firstlba"] = int(v)
        elif k == "sector-size":
            disk["sector"] = int(v)
    return disk


# ---------------------------------------------------------------- partclone header
def stream_cmd(files, comp):
    return "cat %s | %s" % (" ".join(quote(f) for f in files), DECOMP.get(comp, "zstd -dc"))


def read_stream(files, comp, nbytes):
    """The first nbytes of the decompressed image."""
    p = subprocess.Popen(["bash", "-c", stream_cmd(files, comp)],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        data = b""
        while len(data) < nbytes:
            got = p.stdout.read(min(1 << 20, nbytes - len(data)))
            if not got:
                break
            data += got
        return data
    finally:
        p.kill()
        p.wait()


HEAD_V2 = 110        # bytes before the bitmap in a version 0002 image


def parse_head(data):
    """partclone's image_desc_v2 (src/partclone.h). Offsets confirmed against
    a partclone 0.3.27 image: version "0002" at 30, filesystem at 36, then
    device size, total / used blocks, block size, checksum layout, bitmap mode.
    Of the two used counts the superblock's is 0 for NTFS - the bitmap's is
    the real one."""
    if data[:15] != b"partclone-image" or data[30:34] != b"0002":
        return None
    fs = data[36:52].split(b"\0")[0].decode("ascii", "replace")
    dev_size, total, used_sb, used_bm = struct.unpack_from("<QQQQ", data, 52)
    block, _feat, _ver, _bits, _cmode, csize, per_ck = struct.unpack_from("<IIHHHHI", data, 84)
    bitmap_mode = data[105]
    return {"fs": fs, "device_size": dev_size, "total": total,
            "used_blocks": used_bm or used_sb, "block": block,
            "checksum_size": csize, "blocks_per_checksum": per_ck,
            "bitmap_mode": bitmap_mode, "bitmap_at": HEAD_V2,
            "bitmap_len": (total + 7) // 8}


def image_head(files, comp):
    return parse_head(read_stream(files, comp, HEAD_V2))


def used_beyond(files, comp, offset):
    """Bytes of data the image holds past `offset` into the partition - how
    much has to move when the partition is restored smaller than it was saved
    (the scratch area needs room for exactly that)."""
    h = image_head(files, comp)
    if h is None or h["bitmap_mode"] != 1:
        return None
    data = read_stream(files, comp, h["bitmap_at"] + h["bitmap_len"])
    bm = data[h["bitmap_at"]:]
    first = offset // h["block"]
    if first >= h["total"]:
        return 0
    lead = first // 8
    n = bin(bm[lead] >> (first % 8)).count("1") if lead < len(bm) else 0
    for i in range(lead + 1, len(bm), 1 << 20):
        n += int.from_bytes(bm[i:i + (1 << 20)], "little").bit_count()
    return n * h["block"]


def read_index(imgdir, part):
    """diag/<part>.idx: compressed size of each 32 MB frame, one per line."""
    try:
        with open(os.path.join(imgdir, SIDE, part + ".idx")) as f:
            return [int(x) for x in f.read().split()]
    except (OSError, ValueError):
        return None
