#!/usr/bin/env python3
"""OneDrive as a folder (FUSE, fsname "onedrive"), started by
onedrive.py mount. Restore, Check, Browse and Back up then work on it the
way they work on a USB drive - no OneDrive code in the imaging engine.

Reading: 8 MB ranged downloads, kept in a small cache, with the next few
fetched ahead while a file is read front to back (a restore is one long
read; a single stream from OneDrive is far slower than the bench's LAN).

Writing: OneDrive takes a file whole - an upload has to say its size up
front - so a file being written is held in RAM (/dev/shm) until it is
closed. A backup to OneDrive is therefore split into 256 MB pieces
(imaging.sh); each piece goes up when split closes it, and a failed upload
fails that close, so the backup stops with the reason. Small files (the
table, notes, the frame index the engine appends to once per 32 MB) stay
here until onedrive.py sync - writing .diag-sync - sends them, the image's
own markers (clonezilla-img, diag/image.json) last: a backup cut off half
way never looks like a finished image on OneDrive.
"""
import errno
import os
import stat
import sys
import tempfile
import threading
import time
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import onedrive as od                                        # noqa: E402

try:                                    # Debian's python3-fusepy names it fusepy
    from fusepy import FUSE, FuseOSError, Operations
except ImportError:
    from fuse import FUSE, FuseOSError, Operations

BLOCK = 8 * 1024 * 1024      # a reader going front to back
SMALL = 512 * 1024           # a look somewhere else in a file
AHEAD = 3                    # blocks fetched ahead of a reader going front to back
CACHE_BYTES = 96 * 1024 * 1024
WORKERS = 4
DIR_TTL = 30                 # a folder listing is read again after this
MISS_AGAIN = 3               # ... or after this, when a name is not in it
UP_NOW = 16 * 1024 * 1024    # a closed file this big goes up at once; smaller ones wait for sync
SPOOL = os.environ.get("OD_SPOOL", "/dev/shm")
SPOOL_MAX = int(os.environ.get("OD_SPOOL_MAX", 1536 * 1024 * 1024))
LAST_ERROR = os.path.join(od.STATE, "last-error")
MARKERS = ("clonezilla-img", "image.json")   # uploaded last by sync


def _when(item):
    s = (item.get("fileSystemInfo") or {}).get("lastModifiedDateTime") or item.get("lastModifiedDateTime")
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return time.time()


def _norm(path):
    path = "/" + path.strip("/")
    return path, path.lower()                 # OneDrive's names ignore case


def _fail(exc):
    """A Graph failure as the errno the program on the other side sees;
    the words go to the log and last-error, for the screen to show."""
    od.log("odfs: %s" % exc)
    try:
        with open(LAST_ERROR, "w") as f:
            f.write("%s\n" % exc)
    except OSError:
        pass
    code = {404: errno.ENOENT, 403: errno.EACCES, 507: errno.ENOSPC, 413: errno.EFBIG}
    return FuseOSError(code.get(getattr(exc, "status", 0), errno.EIO))


class Spool:
    """A file being written, held until it goes up."""

    def __init__(self, path):
        self.path = path
        # unbuffered: its size (getattr) and pread must see every write at
        # once - an append (">>") is placed at the size the kernel was told
        self.f = tempfile.TemporaryFile(dir=SPOOL, prefix="odfs-", buffering=0)
        self.dirty, self.opens = True, 0
        self.lock = threading.RLock()

    def size(self):
        return os.fstat(self.f.fileno()).st_size

    def put(self, data, offset):
        """All of data at offset, or an error: a raw file may take part of
        it (/dev/shm full) - a piece cut short here would upload as good."""
        view, done = memoryview(data), 0
        while done < len(view):
            n = os.pwrite(self.f.fileno(), view[done:], offset + done)
            if n <= 0:
                raise OSError(errno.ENOSPC, "no room left in %s" % SPOOL)
            done += n

    def close(self):
        self.f.close()


def _spool_max():
    """What may be held at once: OD_SPOOL_MAX, but never more than the
    spool's filesystem has free (/dev/shm is half the RAM - 1 GB on a 2 GB
    laptop), less room for the engine's own 32 MB chunks there."""
    try:
        st = os.statvfs(SPOOL)
        room = st.f_bavail * st.f_frsize - 128 * 1024 * 1024
    except OSError:
        room = SPOOL_MAX
    return max(64 * 1024 * 1024, min(SPOOL_MAX, room))


class Handle:
    def __init__(self, path, item=None, spool=None, sync=False):
        self.path, self.item, self.spool, self.sync = path, item, spool, sync
        self.pos = 0                            # where the last read ended


class OneDriveFS(Operations):
    def __init__(self, drive):
        self.drive = drive
        # not "self.lock": fusepy took it for the FUSE lock operation - every
        # flock on the folder got EINVAL ("RLock object is not callable")
        self.mu = threading.RLock()
        self.dirs = {}                          # lower path -> (when, {lower name: item})
        self.spools = {}                        # lower path -> Spool
        self.handles, self.next_fh = {}, 1
        self.blocks = OrderedDict()             # _key() -> bytes
        self.held = 0                           # bytes in blocks
        self.pending = {}                       # _key() -> Future
        self.pool = ThreadPoolExecutor(WORKERS)
        self.quota = (0, 0, 0.0)
        self.spool_max = _spool_max()

    # ------------------------------------------------------------ what is there
    def _list(self, d, newer_than=0.0):
        d, key = _norm(d)
        with self.mu:
            hit = self.dirs.get(key)
            if hit and time.time() - hit[0] < DIR_TTL and hit[0] >= newer_than:
                return hit[1]
        try:
            kids = self.drive.children(d)
        except od.GraphError as exc:
            raise _fail(exc)
        m = {k["name"].lower(): k for k in kids}
        with self.mu:
            self.dirs[key] = (time.time(), m)
        return m

    def _item(self, path):
        path, key = _norm(path)
        if key == "/":
            return {"name": "", "folder": {}, "size": 0}
        parent, name = os.path.split(path)
        try:
            it = self._list(parent).get(name.lower())
            if it is None:
                # not in a listing up to DIR_TTL old: something uploaded since
                # (search found it, the kernel walks the path a folder at a
                # time) - read the folder again, at most every MISS_AGAIN s
                it = self._list(parent, newer_than=time.time() - MISS_AGAIN).get(name.lower())
            return it
        except FuseOSError as exc:
            if exc.errno == errno.ENOENT:       # its folder is not there either
                return None
            raise

    def _noted(self, path, item):
        """Put a new or changed item into its folder's listing (no re-read)."""
        key = _norm(path)[1]
        parent = os.path.split(key)[0]
        with self.mu:
            hit = self.dirs.get(parent)
            if hit:
                if item is None:
                    hit[1].pop(os.path.basename(key), None)
                else:
                    hit[1][os.path.basename(key)] = item
            if item is not None and "folder" in item and key not in self.dirs:
                self.dirs[key] = (time.time(), {})

    def getattr(self, path, fh=None):
        now = time.time()
        if os.path.basename(path) == od.SYNC_NAME:
            # there while being written (the kernel looks it up after the
            # create), never otherwise: an open of an existing file would
            # truncate it rather than create it
            if not any(h.sync for h in list(self.handles.values())):
                raise FuseOSError(errno.ENOENT)
            return dict(st_mode=stat.S_IFREG | 0o644, st_nlink=1, st_size=0, st_mtime=now, st_atime=now, st_ctime=now)
        key = _norm(path)[1]
        with self.mu:
            sp = self.spools.get(key)
            try:
                size = sp.size() if sp else None
            except (OSError, ValueError):       # closed in between: it is on OneDrive now
                size = None
        if size is not None:
            return dict(st_mode=stat.S_IFREG | 0o644, st_nlink=1, st_size=size, st_blocks=(size + 511) // 512,
                        st_mtime=now, st_atime=now, st_ctime=now)
        item = self._item(path)
        if item is None:
            raise FuseOSError(errno.ENOENT)
        t = _when(item) if key != "/" else now
        if "folder" in item:
            return dict(st_mode=stat.S_IFDIR | 0o755, st_nlink=2, st_size=0, st_mtime=t, st_atime=t, st_ctime=t)
        size = int(item.get("size") or 0)
        return dict(st_mode=stat.S_IFREG | 0o644, st_nlink=1, st_size=size, st_blocks=(size + 511) // 512,
                    st_mtime=t, st_atime=t, st_ctime=t)

    def readdir(self, path, fh):
        listing = self._list(path)
        d = _norm(path)[1]
        with self.mu:                         # _noted changes listings from other threads
            names = {it["name"] for it in listing.values()}
            names |= {os.path.basename(s.path) for k, s in self.spools.items() if os.path.dirname(k) == d}
        return [".", ".."] + sorted(names)

    def statfs(self, path):
        total, free, when = self.quota
        if time.time() - when > 60:
            try:
                total, free = self.drive.quota()
            except od.GraphError as exc:
                raise _fail(exc)
            self.quota = (total, free, time.time())
        # a drive that does not say: unknown, not "full" - the backup's room
        # check would refuse every image
        total = total if total is not None else 1 << 50
        free = free if free is not None else total
        with self.mu:
            held = sum(s.size() for s in self.spools.values() if s.dirty)
        free = max(0, free - held)
        return dict(f_bsize=4096, f_frsize=4096, f_blocks=total // 4096, f_bfree=free // 4096,
                    f_bavail=free // 4096, f_files=0, f_ffree=0, f_namemax=255)

    # ------------------------------------------------------------ folders
    def mkdir(self, path, mode):
        path = _norm(path)[0]
        try:
            item = self.drive.mkdir(path)
        except od.GraphError as exc:
            raise _fail(exc)
        self._noted(path, item)

    def rmdir(self, path):
        item = self._item(path)
        if item is None:
            raise FuseOSError(errno.ENOENT)
        key = _norm(path)[1]
        with self.mu:
            held = any(k.startswith(key + "/") for k in self.spools)
        if self._list(path) or held:
            raise FuseOSError(errno.ENOTEMPTY)
        try:
            self.drive.delete(item)
        except od.GraphError as exc:
            raise _fail(exc)
        self._noted(path, None)
        with self.mu:
            self.dirs.pop(key, None)

    def unlink(self, path):
        key = _norm(path)[1]
        with self.mu:
            sp = self.spools.pop(key, None)
        if sp:
            sp.close()
        item = self._item(path)
        if item is not None:
            try:
                self.drive.delete(item)                 # to OneDrive's recycle bin
            except od.GraphError as exc:
                raise _fail(exc)
            self._noted(path, None)
        elif sp is None:
            raise FuseOSError(errno.ENOENT)

    def rename(self, old, new):
        raise FuseOSError(errno.ENOTSUP)               # nothing in the toolkit renames on a store

    def chmod(self, path, mode):
        return 0

    def chown(self, path, uid, gid):
        return 0

    def utimens(self, path, times=None):
        return 0

    # ------------------------------------------------------------ files
    def _fh(self, h):
        with self.mu:
            fh, self.next_fh = self.next_fh, self.next_fh + 1
            self.handles[fh] = h
        return fh

    def _spool(self, path, keep=None):
        """The file's spool, made when missing: empty, or holding the
        OneDrive copy when the file is opened to add to (the engine
        appends to its frame index)."""
        path, key = _norm(path)
        with self.mu:
            sp = self.spools.get(key)
            fresh = sp is None
            if fresh:
                sp = self.spools[key] = Spool(path)
            sp.opens += 1
        if fresh and keep is not None:
            size = int(keep.get("size") or 0)
            if size > UP_NOW:
                self._drop(key)
                raise FuseOSError(errno.EFBIG)
            if size:
                try:
                    sp.put(self.drive.read(keep, 0, size), 0)
                except od.GraphError as exc:
                    self._drop(key)
                    raise _fail(exc)
                except OSError as exc:
                    self._drop(key)
                    raise _fail(od.GraphError(str(exc), 507))
            sp.dirty = False
        return sp

    def _drop(self, key):
        with self.mu:
            sp = self.spools.pop(key, None)
        if sp:
            sp.close()

    def create(self, path, mode, fi=None):
        if os.path.basename(path) == od.SYNC_NAME:
            return self._fh(Handle(path, sync=True))
        sp = self._spool(path)
        with sp.lock:
            sp.f.truncate(0)
            sp.dirty = True
        return self._fh(Handle(_norm(path)[0], spool=sp))

    def open(self, path, flags):
        if os.path.basename(path) == od.SYNC_NAME:
            return self._fh(Handle(path, sync=True))
        key = _norm(path)[1]
        writing = flags & (os.O_WRONLY | os.O_RDWR)
        with self.mu:
            held = key in self.spools
        if held or writing:
            item = None if held else self._item(path)
            if not held and item is None:
                raise FuseOSError(errno.ENOENT)
            sp = self._spool(path, keep=None if (held or flags & os.O_TRUNC) else item)
            if flags & os.O_TRUNC:
                with sp.lock:
                    sp.f.truncate(0)
                    sp.dirty = True
            return self._fh(Handle(_norm(path)[0], spool=sp))
        item = self._item(path)
        if item is None:
            raise FuseOSError(errno.ENOENT)
        if "folder" in item:
            raise FuseOSError(errno.EISDIR)
        return self._fh(Handle(_norm(path)[0], item=item))

    def truncate(self, path, length, fh=None):
        if os.path.basename(path) == od.SYNC_NAME:
            return
        h = self.handles.get(fh) if fh else None
        sp = h.spool if h and h.spool else None
        if sp is None:
            item = self._item(path)
            if item is None and _norm(path)[1] not in self.spools:
                raise FuseOSError(errno.ENOENT)
            sp = self._spool(path, keep=None if length == 0 else item)
            with self.mu:
                sp.opens -= 1                   # no handle holds this one open
        with sp.lock:
            sp.f.truncate(length)
            sp.dirty = True

    def write(self, path, data, offset, fh):
        sp = self.handles[fh].spool
        if sp is None:
            raise FuseOSError(errno.EBADF)
        with self.mu:
            held = sum(s.size() for s in self.spools.values())
        if held + len(data) > self.spool_max:
            raise _fail(od.GraphError("a file this big cannot be held here for OneDrive (%d MB at most)"
                                      % (self.spool_max >> 20), 507))
        with sp.lock:
            try:
                sp.put(data, offset)
            except OSError as exc:
                raise _fail(od.GraphError(str(exc), 507))
            sp.dirty = True
        return len(data)

    def read(self, path, size, offset, fh):
        h = self.handles[fh]
        if h.spool is not None:
            with h.spool.lock:
                return os.pread(h.spool.f.fileno(), size, offset)
        total = int(h.item.get("size") or 0)
        end = min(offset + size, total)
        if offset >= end:
            return b""
        # near where this reader was (the kernel's read-ahead can come a
        # little out of order): a long read, in big blocks with more on the
        # way. Anywhere else - a Macrium image's tail and index - a small one.
        seq = abs(offset - h.pos) <= BLOCK
        unit = BLOCK if seq else SMALL
        first, last = offset // unit, (end - 1) // unit
        if seq:
            for n in range(last + 1, min(last + 1 + AHEAD, (total - 1) // unit + 1)):
                self._fetch(h.item, unit, n)
        h.pos = end
        out = b"".join(self._block(h.item, unit, n) for n in range(first, last + 1))
        start = offset - first * unit
        return out[start:start + (end - offset)]

    @staticmethod
    def _key(item, unit, n):
        # with the file's version: one written again keeps its item id, and
        # a check after a second backup must not read the first one's bytes
        return (item["id"], item.get("cTag") or item.get("eTag") or item.get("size"), unit, n)

    def _fetch(self, item, unit, n):
        """The block's download under way (a Future), or None when it is
        already in the cache."""
        key = self._key(item, unit, n)
        with self.mu:
            if key in self.blocks:
                self.blocks.move_to_end(key)
                return None
            fut = self.pending.get(key)
            if fut is None:
                fut = self.pending[key] = self.pool.submit(self._download, item, unit, n)
        return fut

    def _download(self, item, unit, n):
        key = self._key(item, unit, n)
        try:
            want = min(unit, int(item["size"]) - n * unit)
            data = self.drive.read(item, n * unit, want)
            if len(data) != want:
                raise od.GraphError("OneDrive sent %d bytes of %d" % (len(data), want))
            with self.mu:
                if key not in self.blocks:
                    self.blocks[key] = data
                    self.held += len(data)
                while self.held > CACHE_BYTES and len(self.blocks) > 1:
                    self.held -= len(self.blocks.popitem(last=False)[1])
            return data
        finally:
            with self.mu:
                self.pending.pop(key, None)

    def _block(self, item, unit, n):
        for _ in range(3):
            fut = self._fetch(item, unit, n)
            if fut is not None:
                try:
                    return fut.result()
                except od.GraphError as exc:
                    raise _fail(exc)
            with self.mu:
                data = self.blocks.get(self._key(item, unit, n))
            if data is not None:
                return data
            # pushed out of the cache between the two looks: fetch it again
        raise _fail(od.GraphError("the download cache is too small for this many readers"))

    # ------------------------------------------------------------ going up
    def _upload(self, sp):
        with sp.lock:
            if not sp.dirty:
                return
            size = sp.size()
            sp.f.seek(0)
            try:
                item = self.drive.upload(sp.path, sp.f, size)
            except od.GraphError as exc:
                raise _fail(exc)
            sp.dirty = False
        self._noted(sp.path, item)

    def sync_all(self):
        """Every held file goes up; the image's markers last."""
        with self.mu:
            todo = [s for s in self.spools.values() if s.dirty]
        todo.sort(key=lambda s: (os.path.basename(s.path) in MARKERS, s.path))
        for sp in todo:
            self._upload(sp)
            with self.mu:
                key = _norm(sp.path)[1]
                if sp.opens <= 0 and not sp.dirty and self.spools.get(key) is sp:
                    self.spools.pop(key)
                    sp.close()

    def flush(self, path, fh):
        h = self.handles.get(fh)
        if h is None:
            return 0
        if h.sync:
            self.sync_all()
        elif h.spool is not None and h.spool.dirty and h.spool.size() >= UP_NOW:
            self._upload(h.spool)
        return 0

    def fsync(self, path, datasync, fh):
        return self.flush(path, fh)

    def release(self, path, fh):
        with self.mu:
            h = self.handles.pop(fh, None)
        sp = h.spool if h else None
        if sp is None:
            return 0
        with self.mu:
            sp.opens -= 1
            key = _norm(sp.path)[1]
            if sp.opens <= 0 and not sp.dirty and self.spools.get(key) is sp:
                self.spools.pop(key)
                sp.close()                      # it is on OneDrive: the RAM goes back
        return 0

    def destroy(self, path):
        try:
            self.sync_all()
        except FuseOSError as exc:
            od.log("odfs: files not uploaded at unmount: %s" % exc)
        self.pool.shutdown(wait=False)


def main():
    if len(sys.argv) != 2:
        print("usage: odfs.py MOUNTPOINT", file=sys.stderr)
        return 2
    try:
        os.remove(LAST_ERROR)
    except OSError:
        pass
    drive = od.Drive(od.Auth())
    FUSE(OneDriveFS(drive), sys.argv[1], foreground=True, nothreads=False, fsname="onedrive",
         subtype="odfs", big_writes=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
