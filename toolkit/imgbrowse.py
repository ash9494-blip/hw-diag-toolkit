#!/usr/bin/env python3
"""Browse the files in an image (Disk imaging -> Browse an image) - Macrium's
"Browse image", for getting a customer's documents back out of a backup.

A partition image is partclone's stream - header, bitmap, then only the used
blocks - zstd-compressed in independent 32 MB frames whose sizes the toolkit
keeps in diag/<part>.idx (imgfmt.py). That makes any offset of the partition
readable without unpacking the image: block N is either unused (zeros) or the
k-th used block, at a known place in the stream, inside a known frame. This
serves the partition as a read-only block device through the kernel's NBD
driver - the old ioctl interface on a socketpair, so no nbd-client and no
network - and it is mounted read-only. Nothing here writes the image; files
the operator picks are copied out with `copy`.

Images Clonezilla saved are one zstd frame (or gzip): no index, so they
cannot be read in the middle - restore them instead.

    imgbrowse.py parts IMGDIR              name|fs|bytes|title|ok|why per partition
    imgbrowse.py attach IMGDIR PART        -> /dev/nbdN, served in the background
    imgbrowse.py mount DEV MNT             read-only; exit 4 = BitLocker, locked
    imgbrowse.py close MNT DEV             unmount, lock, detach
    imgbrowse.py ls DIR                    kind|size|date|name, folders first
    imgbrowse.py copy SRC DESTDIR --status F
"""
import argparse
import collections
import ctypes
import errno
import json
import os
import shutil
import socket
import stat
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import imgengine   # noqa: E402
import imgfmt      # noqa: E402
import imgscan     # noqa: E402
import mrimg       # noqa: E402

RUN_DIR = imgengine.RUN_DIR
GROUP = 4096                 # bitmap bytes per rank entry (32768 blocks)
FRAMES_KEPT = 4              # unpacked frames kept in memory, 32 MB each
LS_MAX = 300                 # entries a folder listing shows
MOUNTABLE = ("ntfs", "vfat", "fat16", "fat32", "exfat", "ext2", "ext3", "ext4", "bitlocker")


class NotBrowsable(Exception):
    """Why this partition image cannot be opened; for the operator."""


# ---------------------------------------------------------------- the image stream
class Stream:
    """The decompressed partclone stream, readable at any offset."""

    def __init__(self, files, comp, sizes, chunk=imgfmt.CHUNK):
        self.comp, self.chunk, self.sizes = comp, chunk, sizes
        self.cache = collections.OrderedDict()
        stored = [os.path.getsize(f) for f in files]
        if comp not in ("zst", "uncomp"):
            raise NotBrowsable("compressed with %s - only zstd images open here; restore it instead"
                               % comp)
        if comp == "zst" and not sizes:
            raise NotBrowsable("no index - saved by Clonezilla or an older toolkit; restore it instead")
        if comp == "zst" and sum(sizes) != sum(stored):
            raise NotBrowsable("the index does not match the image files - the image is incomplete")
        self.starts = [0]
        for s in (sizes or [])[:-1]:
            self.starts.append(self.starts[-1] + s)
        self.pieces = [(open(f, "rb"), s) for f, s in zip(files, stored)]

    def close(self):
        for fh, _ in self.pieces:
            fh.close()

    def _stored(self, off, n):
        """n bytes at `off` of the files as stored, across the .aa .ab pieces."""
        out = []
        for fh, size in self.pieces:
            if off >= size:
                off -= size
                continue
            fh.seek(off)
            got = fh.read(min(n, size - off))
            out.append(got)
            n -= len(got)
            off = 0
            if n <= 0:
                break
        return b"".join(out)

    def frame(self, i):
        if i in self.cache:
            self.cache.move_to_end(i)
            return self.cache[i]
        r = subprocess.run(["zstd", "-q", "-d", "-c"], input=self._stored(self.starts[i], self.sizes[i]),
                           capture_output=True)
        if r.returncode != 0:
            raise OSError("frame %d of the image does not unpack: %s"
                          % (i, r.stderr.decode("utf-8", "replace").strip()[:120]))
        self.cache[i] = r.stdout
        while len(self.cache) > FRAMES_KEPT:
            self.cache.popitem(last=False)
        return r.stdout

    def read(self, off, n):
        if self.comp == "uncomp":
            return self._stored(off, n)
        out = []
        while n > 0:
            i, at = divmod(off, self.chunk)
            if i >= len(self.sizes):
                break
            data = self.frame(i)[at:at + n]
            if not data:
                break
            out.append(data)
            off += len(data)
            n -= len(data)
        return b"".join(out)


class Partition:
    """The partition as it was saved: its used blocks out of the stream,
    every other block zeros. A partclone.dd image (no header) is the
    partition itself, byte for byte."""

    def __init__(self, stream, part_bytes=None):
        """part_bytes: the partition's size in the saved table. A raw image
        is exactly that; for partclone's it is a floor - NTFS keeps its
        backup boot sector past the last cluster, and ntfs-3g reads the
        last sector of the device."""
        self.stream = stream
        head = imgfmt.parse_head(stream.read(0, imgfmt.HEAD_V2))
        self.raw = head is None
        if self.raw:
            if not part_bytes:
                raise NotBrowsable("not a partclone image this toolkit can read")
            self.size = part_bytes
            return
        if head["bitmap_mode"] != 1:
            raise NotBrowsable("an old partclone image layout - restore it instead")
        self.h, self.block, self.total = head, head["block"], head["total"]
        self.size = max(head["device_size"], self.total * self.block, part_bytes or 0) // 512 * 512
        self.bitmap = stream.read(head["bitmap_at"], head["bitmap_len"])
        if len(self.bitmap) != head["bitmap_len"]:
            raise NotBrowsable("the image is cut short")
        self.data_at = head["bitmap_at"] + head["bitmap_len"] + 4     # + the bitmap's CRC32
        per, csize = head["blocks_per_checksum"], head["checksum_size"]
        self.per, self.csize = (per, csize) if per and csize else (0, 0)
        self.groups = []
        n = 0
        for g in range(0, len(self.bitmap), GROUP):
            self.groups.append(n)
            n += int.from_bytes(self.bitmap[g:g + GROUP], "little").bit_count()

    def used(self, b):
        return b < self.total and (self.bitmap[b >> 3] >> (b & 7)) & 1

    def rank(self, b):
        """Used blocks before block b - its place among the saved ones."""
        g = b // (GROUP * 8)
        start = g * GROUP
        n = self.groups[g] if g < len(self.groups) else 0
        n += int.from_bytes(self.bitmap[start:b >> 3], "little").bit_count()
        if b & 7 and (b >> 3) < len(self.bitmap):
            n += (self.bitmap[b >> 3] & ((1 << (b & 7)) - 1)).bit_count()
        return n

    def where(self, k):
        """Stream offset of the k-th saved block: a checksum follows every
        `per` blocks."""
        return self.data_at + k * self.block + ((k // self.per) * self.csize if self.per else 0)

    def read(self, off, n):
        n = max(0, min(n, self.size - off))
        if self.raw:
            return self.stream.read(off, n).ljust(n, b"\0")
        out = bytearray()
        b, within = divmod(off, self.block)
        k = self.rank(b)
        while len(out) < n:
            take = min(self.block - within, n - len(out))
            if self.used(b):
                data = self.stream.read(self.where(k) + within, take)
                if len(data) < take:
                    raise OSError("the image ends before block %d" % b)
                out += data
                k += 1
            else:
                out += bytes(take)
            b, within = b + 1, 0
        return bytes(out)


def macrium(path):
    """The Macrium image at `path`, or why it does not open (NotBrowsable)."""
    try:
        return mrimg.MacriumImage(path)
    except (mrimg.NotMacrium, mrimg.Unsupported, OSError) as exc:
        raise NotBrowsable(str(exc))


def macrium_parts(path):
    """A Macrium image's partitions, shaped like image_parts() rows."""
    img = macrium(path)
    info = img.info()
    img.close()
    disk = {"label": info["label"], "parts": [dict(p, how="fs") for p in info["parts"]]}
    system = imgengine.system_part(disk)
    out = []
    for q in disk["parts"]:
        if not q["imaged"]:
            continue
        kind = imgengine.seg_kind(q, system)
        out.append(dict(q, part=str(q["num"]), bytes=q["size"] * info["sector"], label="",
                        title=imgengine.seg_name(q, kind), image={"fs": q.get("fs") or "dd"}))
    return out


def image_parts(imgdir):
    """Every partition in the image, as image_disk() describes it, with its
    name in the image's files and a title like the drive bars' (C: Windows)."""
    if os.path.isfile(imgdir):
        return macrium_parts(imgdir)
    disk = imgengine.image_disk(imgdir)
    system = imgengine.system_part(disk)
    out = []
    for q in disk["parts"]:
        img = q.get("image") or {}
        if not img.get("files"):
            continue
        kind = imgengine.seg_kind(q, system)
        q = dict(q, part=imgfmt.to_filename(q["node"]), bytes=q["size"] * disk.get("sector", 512),
                 title=imgengine.seg_name(q, kind))
        out.append(q)
    return out


def open_part(imgdir, part):
    """A partition of the image - or with part "disk", a Macrium image's whole
    drive (Restore serves it and clones from it)."""
    if os.path.isfile(imgdir):
        img = macrium(imgdir)
        if part == "disk":
            return img
        try:
            p = img.partition(int(part))
        except (ValueError, mrimg.Unsupported) as exc:
            raise NotBrowsable(str(exc))
        if img.fs_of(p) not in MOUNTABLE:
            raise NotBrowsable("no files on it - a raw copy of a partition Linux cannot read")
        return p
    for q in image_parts(imgdir):
        if q["part"] == part:
            break
    else:
        raise NotBrowsable("%s is not in this image" % part)
    img = q["image"]
    if img["fs"] == "dd" and q.get("fs") not in MOUNTABLE:
        raise NotBrowsable("no files on it - a raw copy of a partition Linux cannot read")
    chunk = imgfmt.CHUNK
    try:
        with open(os.path.join(imgdir, imgfmt.SIDE, "image.json")) as f:
            chunk = json.load(f).get("chunk") or chunk
    except (OSError, ValueError):
        pass
    stream = Stream(img["files"], img["comp"], imgfmt.read_index(imgdir, part), chunk)
    return Partition(stream, q["bytes"])


def cmd_parts(imgdir):
    try:
        parts = image_parts(imgdir)
    except (imgengine.Fail, OSError, ValueError, KeyError) as exc:
        # a partition-only Clonezilla image, a missing table: say so, not
        # "no partition with files" (the screen shows this line)
        raise NotBrowsable("cannot read this image: %s" % exc)
    for q in parts:
        why, fs = "", q["image"]["fs"]
        if fs == "dd":
            fs = q.get("fs") or "raw"
        try:
            open_part(imgdir, q["part"])
        except (NotBrowsable, OSError) as exc:
            why = " ".join(str(exc).split())      # zstd's stderr can hold newlines
        print("|".join(str(x).replace("|", "/") for x in
                       (q["part"], fs, q["bytes"], q["title"], 0 if why else 1, why)))


# ---------------------------------------------------------------- NBD
# linux/nbd.h, numbers from a C probe (CLAUDE.md: never by hand)
NBD_SET_SOCK, NBD_SET_BLKSIZE, NBD_SET_SIZE, NBD_DO_IT = 0xab00, 0xab01, 0xab02, 0xab03
NBD_CLEAR_SOCK, NBD_CLEAR_QUE, NBD_DISCONNECT = 0xab04, 0xab05, 0xab08
NBD_SET_TIMEOUT, NBD_SET_FLAGS = 0xab09, 0xab0a
REQ_MAGIC, REPLY_MAGIC = 0x25609513, 0x67446698
FLAG_HAS_FLAGS, FLAG_READ_ONLY = 1, 2
CMD_READ, CMD_WRITE, CMD_DISC = 0, 1, 2
EPERM, EIO = 1, 5


_libc = ctypes.CDLL(None, use_errno=True)


def ioctl(fd, req, arg=0):
    """ioctl with an unsigned long argument. fcntl.ioctl passes a C int:
    NBD_SET_SIZE of a 3.6 GB C: overflowed it (loop test, 1.21) - every
    partition over 2 GB. ctypes also lets go of the GIL while NBD_DO_IT
    blocks."""
    if _libc.ioctl(fd, ctypes.c_ulong(req), ctypes.c_ulong(arg)) < 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))


def _recv(sock, n):
    buf = bytearray()
    while len(buf) < n:
        got = sock.recv(n - len(buf))
        if not got:
            raise EOFError
        buf += got
    return bytes(buf)


def _do_it(fd, dev):
    """The kernel's side of the connection; returns when it ends."""
    try:
        ioctl(fd, NBD_DO_IT)
    except OSError as exc:
        imgengine.log("browse %s: connection ended: %s" % (dev, exc))


def pidfile(dev):
    return os.path.join(RUN_DIR, "browse-%s.pid" % os.path.basename(dev))


def serve(part, dev):
    """Answer the kernel's requests for `dev` until it disconnects. The
    kernel holds one end of a socketpair; NBD_DO_IT blocks for the whole
    connection, so it runs in a thread while this one answers."""
    kern, ours = socket.socketpair()
    fd = os.open(dev, os.O_RDWR)
    ioctl(fd, NBD_CLEAR_SOCK)
    ioctl(fd, NBD_SET_BLKSIZE, 512)
    ioctl(fd, NBD_SET_SIZE, part.size)
    ioctl(fd, NBD_SET_FLAGS, FLAG_HAS_FLAGS | FLAG_READ_ONLY)
    ioctl(fd, NBD_SET_TIMEOUT, 120)
    ioctl(fd, NBD_SET_SOCK, kern.fileno())
    t = threading.Thread(target=_do_it, args=(fd, dev), daemon=True)
    t.start()
    with open(pidfile(dev), "w") as f:
        f.write("%d\n" % os.getpid())
    try:
        while True:
            magic, kind, handle, off, length = struct.unpack(">II8sQI", _recv(ours, 28))
            cmd = kind & 0xffff
            if magic != REQ_MAGIC or cmd == CMD_DISC:
                break
            data, err = b"", 0
            if cmd == CMD_READ:
                try:
                    data = part.read(off, length)
                except OSError as exc:
                    imgengine.log("browse %s: read %d+%d: %s" % (dev, off, length, exc))
                    err = EIO
            elif cmd == CMD_WRITE:
                _recv(ours, length)
                err = EPERM
            ours.sendall(struct.pack(">II8s", REPLY_MAGIC, err, handle) + (b"" if err else data))
    except EOFError:
        pass
    finally:
        ours.close()
        t.join(10)
        for op in (NBD_CLEAR_QUE, NBD_CLEAR_SOCK):
            try:
                ioctl(fd, op)
            except OSError:
                pass
        os.close(fd)
        kern.close()
        try:
            os.remove(pidfile(dev))
        except OSError:
            pass


def free_nbd():
    # partitions allowed (the module's default, 16): a Macrium image is
    # served as a whole drive and restored from nbdNp1, nbdNp2...
    subprocess.run(["modprobe", "nbd"], capture_output=True)
    for n in range(16):
        dev = "/dev/nbd%d" % n
        if os.path.exists(dev) and not os.path.exists("/sys/block/nbd%d/pid" % n) \
                and not os.path.exists(pidfile(dev)):
            return dev
    raise NotBrowsable("no free NBD device (is the nbd module there?)")


def attach(imgdir, part):
    open_part(imgdir, part)                          # says why before anything starts
    dev = free_nbd()
    log = open(os.path.join(RUN_DIR, "browse.log"), "a")
    p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "serve", imgdir, part, dev],
                         stdout=log, stderr=log, start_new_session=True)
    for _ in range(300):        # a multi-TB NTFS has a big bitmap to unpack first
        if os.path.exists("/sys/block/%s/pid" % os.path.basename(dev)):
            if part == "disk":   # its partitions, and udev's nodes for them
                imgengine.sh(["blockdev", "--rereadpt", dev], check=False)
                imgengine.sh(["udevadm", "settle", "-t", "10"], check=False)
            return dev
        if p.poll() is not None:
            raise NotBrowsable("the image reader stopped (browse.log)")
        time.sleep(0.1)
    p.kill()
    raise NotBrowsable("the image reader did not start")


def detach(dev):
    try:
        fd = os.open(dev, os.O_RDWR)
        try:
            ioctl(fd, NBD_DISCONNECT)
            ioctl(fd, NBD_CLEAR_SOCK)
        finally:
            os.close(fd)
    except OSError as exc:
        imgengine.log("browse detach %s: %s" % (dev, exc))
    for _ in range(50):
        if not os.path.exists(pidfile(dev)):
            return
        time.sleep(0.1)
    try:
        with open(pidfile(dev)) as f:
            os.kill(int(f.read()), 9)
        os.remove(pidfile(dev))
    except (OSError, ValueError):
        pass


# ---------------------------------------------------------------- mounting
def fstype(dev):
    r = subprocess.run(["blkid", "-p", "-o", "value", "-s", "TYPE", dev],
                       capture_output=True, text=True)
    return r.stdout.strip().lower()


def mount(dev, mnt):
    """Read-only, and for a journal never replayed (noload): the image stays
    exactly as saved. nodev/nosuid/noexec: an ext4 image can hold device
    nodes - one named like the laptop's disk would open the laptop's disk.
    FAT names as UTF-8 - the kernel's default is iso8859-1 and Chinese file
    names came out unreadable. Returns (rc, what): rc 4 = BitLocker, locked."""
    bl = "/dev/mapper/" + imgscan.BL_PREFIX + os.path.basename(dev)
    t = fstype(dev)
    if t == "bitlocker":
        if not os.path.exists(bl):
            return 4, "bitlocker"
        dev, t = bl, fstype(bl)
    os.makedirs(mnt, exist_ok=True)
    safe = "ro,nodev,nosuid,noexec"
    if t == "ntfs":
        tries = [["mount", "-t", "ntfs3", "-o", safe, dev, mnt], ["ntfs-3g", "-o", safe, dev, mnt]]
    elif t in ("ext2", "ext3", "ext4"):
        tries = [["mount", "-t", t, "-o", safe + ",noload", dev, mnt]]
    elif t == "vfat":
        tries = [["mount", "-t", "vfat", "-o", safe + ",utf8", dev, mnt]]
    elif t:
        tries = [["mount", "-o", safe, dev, mnt]]
    else:
        return 1, "no filesystem Linux can read on it"
    out = ""
    for cmd in tries:
        rc, out = imgengine.sh(cmd, check=False)
        if rc == 0:
            return 0, t
    return 1, (out.splitlines() or ["mount failed"])[-1]


def close(mnt, dev):
    # a mount left on a detached device would make the next one stack on it
    if os.path.ismount(mnt) and imgengine.sh(["umount", mnt], check=False)[0] != 0:
        imgengine.sh(["umount", "-l", mnt], check=False)
    imgengine.bl_close(dev)
    detach(dev)


# ---------------------------------------------------------------- folders, copying
def human(n):
    for unit, size in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if n >= size:
            return ("%.1f %s" if n < 10 * size else "%.0f %s") % (n / size, unit)
    return "%d B" % n


def cmd_ls(path):
    """Folders first, then files, as menu rows. Only folders and ordinary
    files: symlinks (NTFS junctions too) loop or leave the image, and the
    FIFOs and device nodes an ext4 image can hold hang a copy or read a
    device of this laptop. An entry that cannot be read is shown as such -
    left out, it looked like a file the backup never had."""
    rows = []
    try:
        entries = list(os.scandir(path))
    except OSError as exc:
        print("err|||%s" % exc)
        return
    for e in entries:
        if "\n" in e.name or "\t" in e.name:     # cannot be a menu row (ext4 only)
            continue
        try:
            st = e.stat(follow_symlinks=False)
        except OSError:
            rows.append((True, e.name.lower(), "f", "unreadable", "", e.name))
            continue
        folder = stat.S_ISDIR(st.st_mode)
        if not folder and not stat.S_ISREG(st.st_mode):
            continue
        rows.append((not folder, e.name.lower(), "d" if folder else "f",
                     "" if folder else human(st.st_size), time.strftime("%Y-%m-%d", time.localtime(st.st_mtime)),
                     e.name))
    rows.sort()
    for r in rows[:LS_MAX]:
        print("|".join(r[2:]))
    if len(rows) > LS_MAX:
        print("more|%d|%d|" % (LS_MAX, len(rows)))


def walk(src):
    """([(path, bytes)] of the ordinary files under src - src itself when it
    is one, [folders that could not be read]). Links, FIFOs and device
    nodes are left out, as in cmd_ls."""
    st = os.lstat(src)
    if stat.S_ISREG(st.st_mode):
        return [(src, st.st_size)], []
    out, unreadable = [], []
    if not stat.S_ISDIR(st.st_mode):
        return out, unreadable

    def failed(exc):
        unreadable.append(os.path.relpath(exc.filename or src, src))

    for root, dirs, files in os.walk(src, onerror=failed):
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
        for name in files:
            p = os.path.join(root, name)
            try:
                st = os.lstat(p)
            except OSError:
                out.append((p, 0))                # copying it reports the error
                continue
            if stat.S_ISREG(st.st_mode):
                out.append((p, st.st_size))
    return out, unreadable


def free_name(dest, keep_ext=True):
    """dest, or "report (2).docx", "Documents (2)" - never over a copy made
    before, and never over a name a FAT/NTFS stick folds to the same one
    (ext4's File and file)."""
    base, ext = os.path.splitext(dest) if keep_ext else (dest, "")
    n = 2
    while os.path.exists(dest):
        dest = "%s (%d)%s" % (base, n, ext)
        n += 1
    return dest


class _ReadError(Exception):
    """The image could not give a file back."""


def _write_fail(exc, rel):
    if exc.errno == errno.ENOSPC:
        return imgengine.Fail("the drive filled up at %s" % rel)
    return imgengine.Fail("could not write to that drive (%s) at %s - is it still plugged in?"
                          % (exc.strerror or exc, rel))


def _copy_one(path, out, rel, tick):
    """One file. A read error is the image's (_ReadError: the copy goes on),
    a write error the drive's (Fail: it stops). Neither leaves a half file
    under the real name, where it would pass for a good copy."""
    try:
        fi = open(path, "rb")
    except OSError as exc:
        raise _ReadError(exc)
    try:
        try:
            fo = open(out, "xb")
        except OSError as exc:
            raise _write_fail(exc, rel)
        try:
            while True:
                try:
                    buf = fi.read(4 << 20)
                except OSError as exc:
                    raise _ReadError(exc)
                if not buf:
                    break
                fo.write(buf)
                tick(len(buf), rel)
            fo.close()
        except BaseException as exc:              # Q (Stop) too
            try:
                fo.close()
            except OSError:
                pass
            try:
                os.remove(out)
            except OSError:
                pass
            if isinstance(exc, OSError):
                raise _write_fail(exc, rel)
            raise
    finally:
        fi.close()
    try:
        st = os.stat(path)
        os.utime(out, (st.st_atime, st.st_mtime))
    except OSError:
        pass                          # FAT rounds dates; not worth failing a copy


def copy(job, src, destdir, name=None):
    """src (a file or a folder) into destdir/<its name, or `name`>, never
    over something already there. The name it got is left in the status
    file (dest=) for the screen."""
    files, unreadable = walk(src)
    if not files and not unreadable and not os.path.isdir(src):
        raise imgengine.Fail("%s is not an ordinary file - there is nothing to copy"
                             % os.path.basename(src))
    total = sum(b for _, b in files) or 1
    free = shutil.disk_usage(destdir).free
    if total > free:
        raise imgengine.Fail("%s to copy and only %s free on that drive" % (human(total), human(free)))
    if fstype_of_dir(destdir) == "vfat" and any(b >= 4 << 30 for _, b in files):
        raise imgengine.Fail("a file is over 4 GB and that drive is FAT32 - use an exFAT or NTFS drive")
    folder = os.path.isdir(src)
    top = free_name(os.path.join(destdir, name or os.path.basename(src.rstrip("/")) or "files"),
                    keep_ext=not folder)
    job.total_w = total
    job.set(steps=1, phase="copy", dest=top)
    job.step("Copying %d file(s), %s" % (len(files), human(total)), total)
    progress = {"done": 0, "start": time.time(), "shown": 0.0}

    def tick(n, rel):
        progress["done"] += n
        if time.time() - progress["shown"] > 0.5:
            progress["shown"] = time.time()
            _progress(job, progress["done"], total, progress["start"], rel)

    bad = []
    for path, _ in files:
        rel = os.path.relpath(path, src) if folder else os.path.basename(path)
        out = os.path.join(top, rel) if folder else top
        try:
            os.makedirs(os.path.dirname(out), exist_ok=True)
        except OSError as exc:
            raise _write_fail(exc, rel)
        try:
            _copy_one(path, free_name(out), rel, tick)
        except _ReadError as exc:
            bad.append(rel)
            imgengine.log("browse copy %s: %s" % (path, exc))
    if folder and not files:
        try:
            os.makedirs(top, exist_ok=True)       # an empty folder is still copied
        except OSError as exc:
            raise _write_fail(exc, os.path.basename(top))
    job.finish_step()
    os.sync()
    missing = []
    if bad:
        missing.append("%d of %d file(s) could not be read from the image: %s"
                       % (len(bad), len(files), ", ".join(bad[:3])))
    if unreadable:
        missing.append("%d folder(s) could not be read from the image, so their files are missing: %s"
                       % (len(unreadable), ", ".join(unreadable[:3])))
    if missing:
        raise imgengine.Fail(" ".join(missing))


def _progress(job, done, total, start, rel):
    secs = max(0.1, time.time() - start)
    rate = done / secs
    left = int((total - done) / rate) if rate else 0
    job.set(partpct=done * 100 // total, pct=min(99, done * 100 // total),
            rate="%s/s" % human(rate).replace(" ", ""), eta="%d:%02d:%02d" % (left // 3600, left // 60 % 60, left % 60),
            msg=rel[-80:])


def fstype_of_dir(path):
    r = subprocess.run(["findmnt", "-no", "FSTYPE", "--target", path], capture_output=True, text=True)
    return r.stdout.strip()


def main(argv):
    ap = argparse.ArgumentParser(prog="imgbrowse.py")
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--status", default=os.path.join(RUN_DIR, "imaging.status"))
    a = ap.parse_args(argv[1:])
    cmd, x, status = a.cmd, a.args, a.status
    os.makedirs(RUN_DIR, exist_ok=True)
    try:
        if cmd == "parts":
            cmd_parts(x[0])
        elif cmd == "attach":
            print(attach(x[0], x[1]))
        elif cmd == "serve":
            serve(open_part(x[0], x[1]), x[2])
        elif cmd == "detach":
            detach(x[0])
        elif cmd == "mount":
            rc, what = mount(x[0], x[1])
            print(what)
            return rc
        elif cmd == "close":
            close(x[0], x[1])
        elif cmd == "ls":
            cmd_ls(x[0])
        elif cmd == "copy":
            return imgengine.run_job(copy, status, *x[:3])
        else:
            print(__doc__)
            return 2
    except (NotBrowsable, imgengine.Fail) as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
