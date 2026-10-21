#!/usr/bin/env python3
"""Unit tests for toolkit/onedrive.py (sign-in, Graph) and toolkit/odfs.py
(OneDrive as a folder), against test/fakegraph.py - no tenant needed, so
the build runs them. odfs is driven through its FUSE operations directly;
the kernel mount itself is tested last, only when run as root with
/dev/fuse (WSL, the VM), as imaging-loop.sh's onedrive case does in full.

    python3 test/onedrive_test.py
"""
import errno
import hashlib
import io
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.request
import warnings

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLKIT = os.path.join(HERE, "..", "toolkit")
sys.path.insert(0, TOOLKIT)
sys.path.insert(0, HERE)
import fakegraph  # noqa: E402
import onedrive as od  # noqa: E402

try:
    import odfs  # noqa: E402
    from odfs import FuseOSError  # noqa: E402
    NO_FUSE = ""
except (ImportError, OSError) as exc:          # no fusepy / libfuse here
    odfs, NO_FUSE = None, str(exc)

CONF = {"client": fakegraph.CLIENT, "tenant": "t1"}


def blob(n, seed):
    return random.Random(seed).randbytes(n)


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # a pool thread's kept-alive connection is closed when the thread ends
        warnings.filterwarnings("ignore", category=ResourceWarning)
        cls.tmp = tempfile.mkdtemp(prefix="odtest-")
        cls.root = os.path.join(cls.tmp, "drive")
        os.makedirs(cls.root)
        cls.srv = fakegraph.start(cls.root)
        od.LOGIN, od.GRAPH = cls.srv.url, cls.srv.url + "/v1.0"
        od.RUN_DIR = cls.tmp
        od.LOG = os.path.join(cls.tmp, "onedrive.log")
        od.STATE = os.path.join(cls.tmp, "onedrive")
        if odfs:
            odfs.LAST_ERROR = os.path.join(cls.tmp, "last-error")
            odfs.SPOOL = cls.tmp

    @classmethod
    def tearDownClass(cls):
        cls.srv.stop()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        self.fault(throttle_every=0, drop_fragment=0, page=5, search_path=False, decline=False,
                   pending_polls=1, expires_in=3600, ignore_range=False, full=False, interval=0)
        self.admin("_reset")

    def admin(self, what, body=None):
        req = urllib.request.Request(self.srv.url + "/" + what, data=json.dumps(body or {}).encode(), method="POST")
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())

    def fault(self, **kw):
        return self.admin("_fault", kw)

    def signed_in(self):
        auth = od.Auth(path=os.path.join(self.tmp, "token-%s.json" % self._testMethodName), conf=CONF)
        auth.wait(auth.start())
        return auth

    def put(self, rel, data):
        path = os.path.join(self.root, rel.strip("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        return path

    def on_drive(self, rel):
        with open(os.path.join(self.root, rel.strip("/")), "rb") as f:
            return f.read()


class SignIn(Base):
    def test_device_code_then_approved(self):
        auth = od.Auth(path=os.path.join(self.tmp, "t.json"), conf=CONF)
        dc = auth.start()
        self.assertEqual(dc["user_code"], "TESTCODE9")
        auth.wait(dc)
        self.assertTrue(auth.signed_in())
        self.assertEqual(os.stat(auth.path).st_mode & 0o777, 0o600)
        self.assertEqual(od.Drive(auth).me()["userPrincipalName"], "tester@example.com")
        again = od.Auth(path=auth.path, conf=CONF)          # read back from the file
        self.assertEqual(again.tok["refresh_token"], auth.tok["refresh_token"])

    def test_declined(self):
        self.fault(decline=True)
        auth = od.Auth(path=os.path.join(self.tmp, "d.json"), conf=CONF)
        with self.assertRaisesRegex(od.GraphError, "declined"):
            auth.wait(auth.start())
        self.assertFalse(auth.signed_in())

    def test_unknown_app_says_so(self):
        auth = od.Auth(path=os.path.join(self.tmp, "u.json"), conf={"client": "not-registered", "tenant": "t1"})
        with self.assertRaisesRegex(od.AppRejected, "AADSTS700016"):     # exit 4: the screen asks again
            auth.start()

    def test_no_app_id_in_the_build(self):
        auth = od.Auth(path=os.path.join(self.tmp, "n.json"), conf={"client": "", "tenant": ""})
        with self.assertRaisesRegex(od.GraphError, "not set up"):
            auth.start()

    def test_renewal_rotates_and_is_saved(self):
        auth = self.signed_in()
        old = auth.tok["refresh_token"]
        auth.tok["expires_at"] = 0
        auth.token()
        self.assertNotEqual(auth.tok["refresh_token"], old)
        with open(auth.path) as f:
            self.assertEqual(json.load(f)["refresh_token"], auth.tok["refresh_token"])

    def test_expired_access_token_renewed_once(self):
        drive = od.Drive(self.signed_in())
        self.admin("_expire")
        self.assertEqual(drive.me()["displayName"], "Bench Tester")

    def test_withdrawn_sign_in_is_forgotten(self):
        auth = self.signed_in()
        self.admin("_revoke")
        with self.assertRaisesRegex(od.GraphError, "sign in again"):
            od.Drive(auth).me()
        self.assertFalse(auth.signed_in())
        self.assertFalse(os.path.exists(auth.path))


class Graph(Base):
    def setUp(self):
        super().setUp()
        self.drive = od.Drive(self.signed_in())

    def test_throttling_is_waited_out(self):
        self.fault(throttle_every=2)
        for _ in range(6):
            self.assertEqual(self.drive.me()["id"], "u1")

    def test_children_follow_every_page(self):
        for i in range(12):
            self.put("/many/f%02d" % i, b"x")
        self.assertEqual(sorted(k["name"] for k in self.drive.children("/many")),
                         ["f%02d" % i for i in range(12)])

    def test_ranged_reads(self):
        data = blob(3 * 1024 * 1024 + 17, 1)
        self.put("/r/file.bin", data)
        item = self.drive.item("/r/file.bin")
        for off, n in ((0, 100), (1024 * 1024 - 3, 4096), (len(data) - 10, 10)):
            self.assertEqual(self.drive.read(item, off, n), data[off:off + n])
        self.admin("_rotate")                                 # the link ran out
        self.assertEqual(self.drive.read(item, 5, 50), data[5:55])
        self.fault(ignore_range=True)                          # never the wrong bytes
        self.assertEqual(self.drive.read(item, 1000, 64), data[1000:1064])

    def test_item_names_ignore_case(self):
        self.put("/Disk images/A/x", b"1")
        self.assertIsNotNone(self.drive.item("/disk IMAGES/a/X"))
        self.assertIsNone(self.drive.item("/Disk images/B"))

    def test_upload_small_and_in_fragments(self):
        self.drive.makedirs("/up")
        small, big = blob(1024 * 1024, 2), blob(25 * 1024 * 1024 + 5, 3)
        self.drive.upload("/up/small", io.BytesIO(small), len(small))
        self.drive.upload("/up/big", io.BytesIO(big), len(big))
        self.assertEqual(self.on_drive("/up/small"), small)
        self.assertEqual(self.on_drive("/up/big"), big)
        self.assertGreaterEqual(self.admin("_reset")["fragments"], 3)

    def test_fragment_whose_answer_was_lost(self):
        self.drive.makedirs("/up2")
        big = blob(25 * 1024 * 1024, 4)
        self.fault(drop_fragment=2)
        self.drive.upload("/up2/big", io.BytesIO(big), len(big))
        self.assertEqual(self.on_drive("/up2/big"), big)

    def test_full_drive_says_so(self):
        self.drive.makedirs("/up3")
        self.fault(full=True)
        with self.assertRaisesRegex(od.GraphError, "Insufficient Space"):
            self.drive.upload("/up3/x", io.BytesIO(b"abc"), 3)

    def test_makedirs_twice_and_in_other_case(self):
        self.drive.makedirs("/Disk images/M/diag")
        self.drive.makedirs("/Disk images/M/diag")
        self.drive.makedirs("/disk images/m/diag")
        self.assertEqual(os.listdir(os.path.join(self.root, "Disk images", "M")), ["diag"])

    def test_app_ids_must_look_like_ids(self):
        keep = dict(od.CONF)
        try:
            od.CONF.update(CLIENT_ID="not a guid", TENANT_ID="t1")
            self.assertEqual(od.config()["client"], "")
            od.CONF.update(CLIENT_ID=fakegraph.CLIENT, TENANT_ID="evil/../x")
            self.assertEqual(od.config(), {"client": fakegraph.CLIENT, "tenant": ""})
        finally:
            od.CONF.clear()
            od.CONF.update(keep)

    def test_the_sign_in_goes_only_to_graph(self):
        with self.assertRaisesRegex(od.GraphError, "somewhere else"):
            self.drive._get("https://example.invalid/v1.0/me")

    def test_an_upload_that_arrives_short_is_an_error(self):
        self.drive.makedirs("/short")
        with self.assertRaisesRegex(od.GraphError, "could be read"):
            self.drive.upload("/short/x", io.BytesIO(b"abc"), 10)

    def test_find_images(self):
        for rel in ("/Disk images/IMG1/disk", "/Disk images/IMG1/parts",
                    "/Disk images/IMG1/sda1.ntfs-ptcl-img.zst.aa", "/Disk images/IMG1/clonezilla-img",
                    "/Disk images/HALF/sda1.ntfs-ptcl-img.zst.aa",          # no disk/parts: not an image
                    "/partimag/disk", "/partimag/sda2.ext4-ptcl-img.gz.aa",
                    "/Backups/X40.mrimg", "/Deep/a/b/Win-00-00.mrimg", "/Deep/a/b/Win-00-01.mrimg",
                    "/Deep/c/d/CZ/clonezilla-img", "/Top-00-00.mrimg", "/notes.txt"):
            self.put(rel, b"x")
        self.assertEqual(od.find_images(self.drive),
                         ["/Backups/X40.mrimg", "/Deep/a/b/Win-00-00.mrimg", "/Deep/c/d/CZ",
                          "/Disk images/IMG1", "/Top-00-00.mrimg", "/partimag"])
        self.fault(search_path=True)                           # personal OneDrive: paths given
        self.assertIn("/Deep/a/b/Win-00-00.mrimg", od.find_images(self.drive))


@unittest.skipIf(odfs is None, "odfs needs fusepy + libfuse2: %s" % NO_FUSE)
class Folder(Base):
    """odfs.OneDriveFS's operations, as the kernel would call them."""

    def setUp(self):
        super().setUp()
        self.fs = odfs.OneDriveFS(od.Drive(self.signed_in()))

    def write_file(self, path, data, step=128 * 1024, flags=None):
        fh = self.fs.create(path, 0o644) if flags is None else self.fs.open(path, flags)
        off = 0 if flags is None or not flags & os.O_APPEND else self.fs.getattr(path)["st_size"]
        for i in range(0, len(data), step):
            self.fs.write(path, data[i:i + step], off + i, fh)
        self.fs.flush(path, fh)
        self.fs.release(path, fh)

    def read_file(self, path, step=128 * 1024):
        fh = self.fs.open(path, os.O_RDONLY)
        out, off = [], 0
        while True:
            chunk = self.fs.read(path, step, off, fh)
            if not chunk:
                break
            out.append(chunk)
            off += len(chunk)
        self.fs.release(path, fh)
        return b"".join(out)

    def sync(self):
        fh = self.fs.create("/" + od.SYNC_NAME, 0o644)
        try:
            self.fs.flush("/" + od.SYNC_NAME, fh)
        finally:
            self.fs.release("/" + od.SYNC_NAME, fh)

    def test_a_backup_as_the_engine_writes_one(self):
        img = "/Disk images/B1"
        self.fs.mkdir("/Disk images", 0o755)
        self.fs.mkdir(img, 0o755)
        self.fs.mkdir(img + "/diag", 0o755)
        self.write_file(img + "/disk", b"sda\n")
        idx = img + "/diag/sda1.idx"
        self.write_file(idx, b"")
        piece = blob(20 * 1024 * 1024, 5)
        self.write_file(img + "/sda1.ntfs-ptcl-img.zst.aa", piece)
        self.assertEqual(self.on_drive(img + "/sda1.ntfs-ptcl-img.zst.aa"), piece)   # up when closed
        for n in (b"123\n", b"456\n", b"789\n"):                 # stat ... >> "$IDX"
            self.write_file(idx, n, flags=os.O_WRONLY | os.O_APPEND)
        self.write_file(img + "/sda1.ntfs-ptcl-img.zst.ab", b"tail")
        self.write_file(img + "/clonezilla-img", b"marker")
        self.write_file(img + "/diag/image.json", b"{}")
        self.assertFalse(os.path.exists(os.path.join(self.root, "Disk images/B1/disk")))  # small: held
        self.assertEqual(self.fs.getattr(idx)["st_size"], 12)
        self.assertEqual(self.read_file(idx), b"123\n456\n789\n")
        self.assertIn("disk", self.fs.readdir(img, None))
        self.admin("_reset")
        self.sync()
        order = self.admin("_reset")["uploads"]
        self.assertEqual(set(order[-2:]), {img + "/clonezilla-img", img + "/diag/image.json"})
        self.assertEqual(self.on_drive(idx), b"123\n456\n789\n")
        self.assertEqual(self.on_drive(img + "/disk"), b"sda\n")
        self.assertEqual(self.fs.spools, {})                      # the RAM is given back
        self.assertEqual(self.fs.getattr(idx)["st_size"], 12)     # now from OneDrive's listing

    def test_reading_front_to_back_and_anywhere(self):
        data = blob(20 * 1024 * 1024 + 333, 6)
        self.put("/read/big.zst", data)
        self.assertEqual(hashlib.sha256(self.read_file("/read/big.zst")).hexdigest(),
                         hashlib.sha256(data).hexdigest())
        fh = self.fs.open("/read/big.zst", os.O_RDONLY)
        rnd = random.Random(7)
        for _ in range(40):
            off, n = rnd.randrange(len(data)), rnd.randrange(1, 300000)
            self.assertEqual(self.fs.read("/read/big.zst", n, off, fh), data[off:off + n])
        self.assertEqual(self.fs.read("/read/big.zst", 10, len(data) + 5, fh), b"")
        self.fs.release("/read/big.zst", fh)
        self.assertLessEqual(self.fs.held, odfs.CACHE_BYTES + odfs.BLOCK)

    def test_missing_names(self):
        with self.assertRaises(FuseOSError) as e:
            self.fs.getattr("/no/such/file")
        self.assertEqual(e.exception.errno, errno.ENOENT)
        self.put("/case/File.TXT", b"abc")
        self.assertEqual(self.fs.getattr("/case/file.txt")["st_size"], 3)

    def test_a_failed_upload_fails_the_close(self):
        self.fs.mkdir("/full", 0o755)
        self.fault(full=True)
        fh = self.fs.create("/full/piece", 0o644)
        self.fs.write("/full/piece", blob(odfs.UP_NOW, 8), 0, fh)
        with self.assertRaises(FuseOSError) as e:
            self.fs.flush("/full/piece", fh)
        self.assertEqual(e.exception.errno, errno.ENOSPC)
        self.fs.release("/full/piece", fh)
        with open(odfs.LAST_ERROR) as f:
            self.assertIn("Insufficient Space", f.read())
        with self.assertRaises(FuseOSError):                       # still held: sync says so too
            self.sync()
        self.fault(full=False)
        self.sync()
        self.assertEqual(len(self.on_drive("/full/piece")), odfs.UP_NOW)

    def test_free_space_counts_what_is_held(self):
        before = self.fs.statfs("/")["f_bavail"]
        self.fs.mkdir("/hold", 0o755)
        self.write_file("/hold/small", blob(4 * 1024 * 1024, 9))
        self.assertEqual(before - self.fs.statfs("/")["f_bavail"], 1024)
        self.sync()

    def test_a_file_written_again_reads_new(self):
        self.fs.mkdir("/again", 0o755)
        first, second = blob(odfs.UP_NOW + 5, 11), blob(odfs.UP_NOW + 5, 12)
        self.write_file("/again/piece", first)
        self.assertEqual(self.read_file("/again/piece"), first)
        self.write_file("/again/piece", second)               # same name, same size
        self.assertEqual(self.read_file("/again/piece"), second)

    def test_no_attribute_shadows_a_fuse_operation(self):
        # fusepy offers an operation to the kernel when getattr(fs, op) is not
        # None (Operations has lock = None: the kernel locks by itself). An
        # "fs.lock" RLock was offered, called - and every flock got EINVAL.
        for op in ("lock", "bmap", "flush", "fsync", "read", "write", "open", "create", "release", "statfs"):
            v = getattr(self.fs, op, None)
            self.assertTrue(v is None or callable(v), op)

    def test_a_folder_made_elsewhere_just_now_is_found(self):
        self.fs.readdir("/", None)                               # the top, listed
        self.put("/Late upload/X40/img-00-00.mrimg", b"x")       # then a phone uploads
        keep, odfs.MISS_AGAIN = odfs.MISS_AGAIN, 0
        try:
            self.assertEqual(self.fs.getattr("/Late upload")["st_mode"] & 0o170000, 0o040000)
            self.assertEqual(self.fs.getattr("/Late upload/X40/img-00-00.mrimg")["st_size"], 1)
        finally:
            odfs.MISS_AGAIN = keep

    def test_a_drive_that_does_not_say_its_room(self):
        self.fs.quota = (None, None, __import__("time").time())
        self.assertGreater(self.fs.statfs("/")["f_bavail"], 1 << 30)

    def test_remove(self):
        self.put("/rm/a", b"1")
        self.fs.unlink("/rm/a")
        self.assertFalse(os.path.exists(os.path.join(self.root, "rm/a")))
        self.fs.rmdir("/rm")
        self.assertFalse(os.path.exists(os.path.join(self.root, "rm")))


@unittest.skipUnless(odfs and os.geteuid() == 0 and os.path.exists("/dev/fuse")
                     and not os.environ.get("ODTEST_NO_MOUNT"), "kernel mount: root + /dev/fuse, not in the build")
class Mounted(Base):
    """The real thing: the kernel, a mount point, shell tools."""

    def test_mount_split_cat_sync(self):
        mnt, env = os.path.join(self.tmp, "mnt"), dict(os.environ)
        env.update(RUN_DIR=self.tmp, OD_LOGIN=self.srv.url, OD_GRAPH=self.srv.url + "/v1.0",
                   OD_CLIENT=fakegraph.CLIENT, OD_TENANT="t1", OD_SPOOL=self.tmp)
        auth = od.Auth(path=os.path.join(self.tmp, "onedrive", "token.json"), conf=CONF)
        auth.wait(auth.start())
        tool = [sys.executable, os.path.join(TOOLKIT, "onedrive.py")]
        r = subprocess.run(tool + ["mount", mnt], env=env, timeout=60, capture_output=True, text=True)
        log = os.path.join(self.tmp, "onedrive.log")
        self.assertEqual(r.returncode, 0, r.stderr + (open(log).read()[-2000:] if os.path.exists(log) else ""))
        try:
            src = os.path.join(self.tmp, "src.bin")
            with open(src, "wb") as f:
                f.write(blob(45 * 1000 * 1000, 10))

            def sh(c):
                return subprocess.run(["bash", "-c", c], env=env, check=True, timeout=300,
                                      capture_output=True, text=True).stdout
            sh("mkdir -p '%s/Disk images/K/diag' && split -a 2 -b 20MB '%s' '%s/Disk images/K/p.'" % (mnt, src, mnt))
            sh("echo 1 >> '%s/Disk images/K/diag/i.idx'; echo 2 >> '%s/Disk images/K/diag/i.idx'" % (mnt, mnt))
            self.assertEqual(sh("cat '%s/Disk images/K/'p.* | sha256sum" % mnt).split()[0],
                             sh("sha256sum '%s'" % src).split()[0])
            self.assertTrue(sh("df -B1 --output=avail '%s' | tail -1" % mnt).strip().isdigit())
            subprocess.run(tool + ["sync", mnt], env=env, check=True, timeout=120)
            self.assertEqual(self.on_drive("/Disk images/K/diag/i.idx"), b"1\n2\n")
            self.assertEqual(len(self.on_drive("/Disk images/K/p.ab")), 20 * 1000 * 1000)
        finally:
            subprocess.run(tool + ["umount", mnt], env=env, timeout=60)
        self.assertFalse(os.path.ismount(mnt))


if __name__ == "__main__":
    unittest.main(verbosity=2)
