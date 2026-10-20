#!/usr/bin/env python3
"""Clone, back up, restore, verify - the imaging work itself.

imaging.sh asks the questions (which drive, ERASE, the BitLocker key) and runs
this in the background; this does the work and keeps a status file the screen
redraws from once a second:

  phase=copy  step=3  steps=6  what=Copying C:  pct=41  partpct=63
  rate=4.2 GB/min  eta=0:07:12  msg=...  result=      (ok / failed / stopped)

Every subcommand that writes is told exactly what to write by a plan from
imgplan.py; nothing here decides on its own to touch a drive. The source
drive is set read-only in the kernel (blockdev --setro) for the whole job, so
even a mistake here cannot write to the customer's drive - except when the
operator chose to shrink C: on the old drive itself (--source-shrink).

    imgengine.py scan DISK
    imgengine.py plan SCAN.json TARGET [--keep-size]
    imgengine.py plan-restore IMGDIR TARGET [--keep-size]
    imgengine.py rows PLAN.json
    imgengine.py shrink-need PLAN.json [IMGDIR]
    imgengine.py clone PLAN.json --status F [--scratch DIR | --source-shrink]
    imgengine.py backup SCAN.json IMGDIR --status F [--split-mb N] [--machine TEXT]
    imgengine.py restore IMGDIR PLAN.json --status F [--scratch DIR]
    imgengine.py verify IMGDIR --status F
    imgengine.py bl-unlock NODE < key        imgengine.py bl-close [NODE]
    imgengine.py unhibernate NODE            imgengine.py clear-dirty NODE
"""
import argparse
import glob
import json
import os
import re
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import imgfmt   # noqa: E402
import imgplan  # noqa: E402
import imgscan  # noqa: E402

RUN_DIR = os.environ.get("RUN_DIR", "/run/diag")
LOG = os.path.join(RUN_DIR, "imaging.log")
MiB = 1024 * 1024
SCRATCH_MARGIN = 64 * MiB


class Stop(Exception):
    """The operator pressed Q."""


class Fail(Exception):
    """Something went wrong; the message is for the operator."""


def log(text):
    try:
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), text))
    except OSError:
        pass


def sh(cmd, check=True, input_=None, timeout=None):
    """A short command, logged. Returns (rc, combined output)."""
    log("$ " + (cmd if isinstance(cmd, str) else " ".join(cmd)))
    r = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True,
                       input=input_, timeout=timeout, errors="replace",
                       executable="/bin/bash" if isinstance(cmd, str) else None)
    out = (r.stdout + r.stderr).strip()
    if out:
        log("  " + out[-2000:].replace("\n", "\n  "))
    if check and r.returncode != 0:
        raise Fail(out.splitlines()[-1] if out else "%s failed" % cmd)
    return r.returncode, out


# ---------------------------------------------------------------- the job
class Job:
    """Status file, child processes, and everything to undo at the end."""

    def __init__(self, status_path):
        self.path = status_path
        self.st = {"phase": "start", "step": 0, "steps": 0, "pct": 0, "partpct": 0,
                   "what": "", "rate": "", "eta": "", "msg": "", "result": ""}
        self.undo = []
        self.child = None
        self.done_w = 0
        self.total_w = 1
        self._w = 0
        # a partition move (imgparted) must not be cut in half: Q while it
        # runs is remembered and acted on when the move is over
        self.hold = False
        self.stop_pending = False
        signal.signal(signal.SIGTERM, self._stop)
        signal.signal(signal.SIGINT, self._stop)

    def _stop(self, *_):
        if self.hold:
            self.stop_pending = True
            return
        if self.child is not None:
            try:
                os.killpg(self.child.pid, signal.SIGKILL)
            except OSError:
                pass
        raise Stop()

    def set(self, **kw):
        self.st.update(kw)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            for k, v in self.st.items():
                f.write("%s=%s\n" % (k, str(v).replace("\n", " ")))
        os.replace(tmp, self.path)

    def step(self, what, weight):
        self.set(step=self.st["step"] + 1, what=what, partpct=0, rate="", eta="", msg="")
        self._w = weight

    def finish_step(self):
        self.done_w += self._w
        self.set(pct=min(100, self.done_w * 100 // self.total_w), partpct=100)

    def track(self, pipeline, label):
        """A long command whose stderr carries partclone's progress lines."""
        prog = os.path.join(RUN_DIR, "imaging.progress")
        log("$ " + pipeline)
        with open(prog, "w") as err:
            self.child = subprocess.Popen(["bash", "-c", "set -o pipefail; " + pipeline],
                                          stdout=subprocess.DEVNULL, stderr=err,
                                          start_new_session=True)
        while self.child.poll() is None:
            time.sleep(0.7)
            self._progress(prog)
        rc, self.child = self.child.returncode, None
        tail = _tail(prog)
        log("  rc=%d %s" % (rc, tail[-600:].replace("\n", " | ")))
        if rc != 0:
            raise Fail("%s failed: %s" % (label, _last_error(tail)))

    def _progress(self, prog):
        text = _tail(prog, 4096)
        m = list(re.finditer(r"Completed:\s*([\d.]+)%", text))
        if not m:
            return
        part = float(m[-1].group(1))
        r = re.findall(r"([\d.]+\s*[KMGT]?B/min)", text)
        e = re.findall(r"Remaining:\s*([\d:]+)", text)
        pct = (self.done_w + self._w * part / 100) * 100 / self.total_w
        self.set(partpct=int(part), pct=min(99, int(pct)),
                 rate=r[-1].replace(" ", "") if r else "", eta=e[-1] if e else "")

    def cleanup(self):
        while self.undo:
            fn = self.undo.pop()
            try:
                fn()
            except Exception as exc:          # cleanup must run to the end
                log("cleanup: %s" % exc)


def _tail(path, n=20000):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - n))
            return f.read().decode("utf-8", "replace").replace("\r", "\n")
    except OSError:
        return ""


def _last_error(text):
    lines = [l.strip() for l in text.splitlines()
             if l.strip() and not l.startswith("Elapsed") and "Completed" not in l]
    for l in reversed(lines):
        if re.search(r"error|fail|cannot|can't|No space|not enough|invalid", l, re.I):
            return l[:160]
    return lines[-1][:160] if lines else "no message"


# ---------------------------------------------------------------- drives
def node_of(disk, num):
    return imgplan.part_node(disk, num)


def wait_nodes(paths, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        if all(os.path.exists(p) for p in paths):
            return
        sh(["udevadm", "settle", "--timeout=2"], check=False)
        time.sleep(0.3)
    missing = [p for p in paths if not os.path.exists(p)]
    raise Fail("the new partitions did not appear: %s" % " ".join(missing))


def mounted(path):
    rc, out = sh("lsblk -rno MOUNTPOINT %s" % imgfmt.quote(path), check=False)
    return bool(out.strip())


def protect(job, disk):
    """Read-only in the kernel for the rest of the job: the disk and every
    partition on it. Put back as found afterwards."""
    # lsblk, not a glob: "loop1*" is also loop10, "sda*" also sdaa
    rc, out = sh(["lsblk", "-lnpo", "NAME", "/dev/" + disk], check=False)
    nodes = out.split() if rc == 0 else ["/dev/" + disk]
    for n in nodes:
        rc, was = sh(["blockdev", "--getro", n], check=False)
        if was.strip() == "0":
            sh(["blockdev", "--setro", n], check=False)
            job.undo.append(lambda n=n: sh(["blockdev", "--setrw", n], check=False))


def check_target(plan):
    # A refused plan must never reach the drive: the first test run wrote the
    # partition table of a plan the planner had turned down.
    if not plan.get("ok"):
        raise Fail("this plan was refused: %s" % " ".join(plan.get("errors") or ["no reason"]))
    tgt = "/dev/" + plan["target"]
    if plan["target"] == plan.get("source"):
        raise Fail("the source and the new drive are the same drive")
    if not os.path.exists(tgt):
        raise Fail("%s is not there any more" % tgt)
    if imgscan.dev_bytes(tgt) != plan["target_bytes"]:
        raise Fail("%s is not the drive this plan was made for" % tgt)
    if mounted(tgt):
        raise Fail("something on %s is in use (mounted)" % tgt)


def write_table(job, plan):
    tgt = "/dev/" + plan["target"]
    job.set(phase="table", msg="Writing the partition table")
    sh(["wipefs", "-a", "-f", tgt])
    sh(["sfdisk", "--no-reread", "--wipe", "always", "--wipe-partitions", "always", tgt],
       input_=imgplan.sfdisk_script(plan))
    sh(["blockdev", "--rereadpt", tgt], check=False)
    sh(["partprobe", tgt], check=False)
    nodes = [node_of(plan["target"], q["num"]) for q in plan["parts"]]
    wait_nodes(nodes)
    for n in nodes:                         # stale signatures from the drive's past
        sh(["wipefs", "-a", "-f", n], check=False)


def copy_boot_area(src_dev, tgt, plan, mbr_file=None, gap_file=None):
    """The boot code in front of the partition table (440 bytes - the disk
    signature and table after it are sfdisk's), and on an MBR disk whatever a
    boot loader keeps between it and the first partition."""
    # quoted: an image on OneDrive sits in "Disk images/..." - the space split
    # dd's if= and every restore from there failed here (1.26)
    q = imgfmt.quote
    src = mbr_file or src_dev
    if src:
        sh("dd if=%s of=%s bs=440 count=1 conv=notrunc,fsync status=none" % (q(src), q(tgt)))
    if plan["label"] != "dos" or not plan["parts"]:
        return
    first = min(p["nstart"] for p in plan["parts"])
    n = min(first, 2048) - 1
    if n <= 0:
        return
    if gap_file:
        sh("dd if=%s of=%s bs=512 seek=1 count=%d conv=notrunc,fsync status=none"
           % (q(gap_file), q(tgt), n))
    elif src_dev:
        sh("dd if=%s of=%s bs=512 skip=1 seek=1 count=%d conv=notrunc,fsync status=none"
           % (q(src_dev), q(tgt), n))


# ---------------------------------------------------------------- filesystems
def resize_fs(dev, fs, size=None):
    """Grow to fill the partition (size None), or shrink to `size` bytes."""
    if fs == "ntfs":
        cmd = ["ntfsresize", "--force", "--force", "--no-progress-bar"]
        if size:
            cmd += ["--size", str(size)]
        sh(cmd + [dev], input_="y\n")
        imgscan.mark_resized(dev)
    elif fs in ("ext2", "ext3", "ext4"):
        rc, _ = sh(["e2fsck", "-f", "-y", dev], check=False)
        if rc >= 4:
            raise Fail("the filesystem check before resizing found errors it could not fix")
        sh(["resize2fs", dev] + (["%dK" % (size // 1024)] if size else []))


def shrink_need(src, fs, size):
    """Bytes the scratch area must hold to shrink this filesystem to `size`:
    the data that sits past the new end. ntfsresize's dry run counts it
    exactly (read-only); for the rest, all of the data is the safe answer."""
    if fs == "ntfs":
        rc, out = sh(["ntfsresize", "--no-action", "--force", "--no-progress-bar",
                      "--size", str(size), src], check=False)
        m = re.search(r"Needed relocations\s*:\s*\d+\s*\((\d+) MB\)", out)
        if m:
            return int(m.group(1)) * 1000 * 1000
    p = imgscan.probe_fs(src, fs)
    return p.get("used") or 0


def composite(job, dst, new_bytes, full_bytes, scratch, need):
    """A device as big as the partition used to be: its first new_bytes are
    the real (smaller) partition, the rest is a scratch area that keeps only
    what is written to it. The full filesystem is copied onto this, then
    shrunk; the shrink moves the overflow into the real partition. The source
    is never written."""
    tag = "%d" % os.getpid()
    tail = full_bytes - new_bytes
    origin = "/dev/shm/diag-tail-%s.zero" % tag      # sparse: reads zeros, holds nothing
    cow = os.path.join(scratch, "diag-scratch-%s.cow" % tag)
    with open(origin, "wb") as f:
        f.truncate(tail)
    job.undo.append(lambda: os.path.exists(origin) and os.remove(origin))
    cow_bytes = -(-(need + need // 10 + SCRATCH_MARGIN) // MiB) * MiB   # whole MiB
    rc, _ = sh(["fallocate", "-l", str(cow_bytes), cow], check=False)
    if rc != 0:
        with open(cow, "wb") as f:
            f.truncate(cow_bytes)
    job.undo.append(lambda: os.path.exists(cow) and os.remove(cow))
    loops = []
    for f in (origin, cow):
        dev = losetup(f)
        loops.append(dev)
        job.undo.append(lambda d=dev: sh(["losetup", "-d", d], check=False))
    snap, comp = "diag-tail-" + tag, "diag-comp-" + tag
    sh(["dmsetup", "create", snap, "--table",
        "0 %d snapshot %s %s N 8" % (tail // 512, loops[0], loops[1])])
    job.undo.append(lambda: sh(["dmsetup", "remove", "--retry", snap], check=False))
    sh(["dmsetup", "create", comp, "--table",
        "0 %d linear %s 0\n%d %d linear /dev/mapper/%s 0"
        % (new_bytes // 512, dst, new_bytes // 512, tail // 512, snap)])
    job.undo.append(lambda: sh(["dmsetup", "remove", "--retry", comp], check=False))
    return "/dev/mapper/" + comp, snap


def losetup(path):
    """A loop device for a file. stdout only: a warning on stderr glued onto
    the device name broke the device-mapper table (first test run)."""
    log("$ losetup -f --show " + path)
    r = subprocess.run(["losetup", "-f", "--show", path], capture_output=True, text=True)
    dev = r.stdout.strip().splitlines()[0] if r.returncode == 0 and r.stdout.strip() else ""
    if not dev.startswith("/dev/loop"):
        raise Fail("no loop device for the scratch area: %s" % r.stderr.strip()[-120:])
    log("  " + dev)
    return dev


def scratch_overflowed(snap):
    rc, out = sh(["dmsetup", "status", snap], check=False)
    return "Invalid" in out or "Overflow" in out


def release_composite(job):
    """Take the composite device and its scratch snapshot down now - the real
    partition has to be free before it is fitted and checked."""
    for _ in range(2):
        job.undo.pop()()


def verify_fs(dev, fs, expect_used=None):
    """Read the copy back: mount it read-only and look, or let the
    filesystem's own checker say so. A copy that is not there fails here."""
    if fs in ("ntfs", "vfat", "exfat"):
        mp = os.path.join(RUN_DIR, "imgverify")
        os.makedirs(mp, exist_ok=True)
        rc, out = sh(["mount", "-o", "ro", "-t", "ntfs3" if fs == "ntfs" else fs, dev, mp],
                     check=False)
        if rc != 0 and fs == "ntfs":
            rc, out = sh(["ntfs-3g", "-o", "ro", dev, mp], check=False)
        if rc != 0:
            raise Fail("the copy of %s cannot be read back (%s)" % (dev, out[-80:]))
        try:
            st = os.statvfs(mp)
            used = (st.f_blocks - st.f_bfree) * st.f_frsize
            entries = len(os.listdir(mp))
        finally:
            sh(["umount", mp], check=False)
        if expect_used and used < expect_used * 0.9:
            raise Fail("the copy of %s holds %s, the original %s"
                       % (dev, imgplan.gb(used), imgplan.gb(expect_used)))
        return entries
    if fs in ("ext2", "ext3", "ext4"):
        rc, out = sh(["e2fsck", "-n", "-f", dev], check=False)
        if rc >= 4:
            raise Fail("the copy of %s has filesystem errors" % dev)
    return None


# ---------------------------------------------------------------- clone
def weight(q):
    if q["how"] == "fs":
        return max(1, q.get("used") or q["size"] * 512)
    if q["how"] == "raw":
        return q["size"] * 512
    return 1


def describe(q):
    name = q.get("label") or "partition %d" % q["num"]
    return "%s (%s)" % (name, q.get("fs") or "raw")


def make_new(job, q, dst):
    """A partition added on the plan screen (imgplanedit.py, 1.24): made
    empty, after the copies - the plan lists it last. The partition editor's
    own mkfs, so a D: made here is the same as one made in Partitions."""
    import imgparted
    job.step("Making %s" % describe(q), weight(q))
    job.set(phase="format", msg="Formatting %s" % describe(q))
    sh(["wipefs", "-a", "-f", dst], check=False)
    imgparted._mkfs(dst, q["fs"], q.get("label"), q["nstart"])
    job.finish_step()


def clone(job, plan, scratch=None, source_shrink=False):
    check_target(plan)
    sec = plan["sector"]
    if not source_shrink:
        protect(job, plan["source"])
    parts = [q for q in plan["parts"] if q["how"] != "skip"]
    job.total_w = sum(weight(q) for q in parts) or 1
    job.set(steps=len(parts) + 1, phase="table")
    write_table(job, plan)
    copy_boot_area("/dev/" + plan["source"], "/dev/" + plan["target"], plan)
    for q in parts:
        dst = node_of(plan["target"], q["num"])
        if q["how"] == "new":
            make_new(job, q, dst)
            continue
        src = q.get("mapper") or q["node"]
        job.step("Copying %s" % describe(q), weight(q))
        job.set(phase="copy")
        if q["how"] == "swap":
            sh(["mkswap"] + (["-U", q["fsuuid"]] if q.get("fsuuid") else [])
               + (["-L", q["label"]] if q.get("label") else []) + [dst])
        elif q["how"] == "raw":
            job.track("partclone.dd -s %s -O %s" % (src, dst), "copying %s" % describe(q))
        elif q["shrink"]:
            shrink_copy(job, q, src, dst, sec, scratch, source_shrink)
        else:
            job.track("partclone.%s -I -b -s %s -o %s" % (q["fs"], src, dst),
                      "copying %s" % describe(q))
            if q["grow"]:
                job.set(phase="resize", msg="Growing %s to fill the new drive" % describe(q))
                resize_fs(dst, q["fs"])
        job.finish_step()
    check_copies(job, plan)


def shrink_copy(job, q, src, dst, sec, scratch, source_shrink):
    new_b, full_b = q["nsize"] * sec, q["size"] * sec
    if source_shrink:
        job.set(phase="resize", msg="Shrinking %s on the old drive" % describe(q))
        resize_fs(src, q["fs"], new_b)
        # -C: partclone compares partition sizes, and the old partition is
        # still full size - the filesystem inside it now fits the new one
        job.track("partclone.%s -I -C -b -s %s -o %s" % (q["fs"], src, dst), "copying")
        job.set(phase="resize", msg="Putting %s on the old drive back to full size" % describe(q))
        resize_fs(src, q["fs"])
        resize_fs(dst, q["fs"])
        return
    need = shrink_need(src, q["fs"], new_b)
    comp, snap = composite(job, dst, new_b, full_b, scratch or "/dev/shm", need)
    job.track("partclone.%s -I -b -s %s -o %s" % (q["fs"], src, comp), "copying")
    shrink_composite(job, q, comp, snap, new_b)
    resize_fs(dst, q["fs"])


def shrink_composite(job, q, comp, snap, new_b):
    job.set(phase="resize", msg="Shrinking %s to fit the new drive" % describe(q))
    try:
        resize_fs(comp, q["fs"], new_b)
    except Fail:
        if scratch_overflowed(snap):
            raise Fail("the scratch area ran out of room while shrinking %s" % describe(q))
        raise
    release_composite(job)
    job.set(msg="Fitting %s to its partition" % describe(q))


def check_copies(job, plan):
    job.step("Checking the copy", 1)
    job.set(phase="verify")
    for q in plan["parts"]:
        if q["how"] == "fs" and not q.get("missing"):
            job.set(msg="Reading back %s" % describe(q))
            verify_fs(node_of(plan["target"], q["num"]), q["fs"], q.get("used"))
    job.finish_step()


# ---------------------------------------------------------------- backup
def backup(job, disk, imgdir, split_mb=None, machine=""):
    if os.path.exists(imgdir):
        raise Fail("%s already exists" % imgdir)
    os.makedirs(os.path.join(imgdir, imgfmt.SIDE))
    protect(job, disk["name"])
    parts = [dict(q, how=imgplan.copy_method(disk["label"], q)) for q in disk["parts"]]
    todo = [q for q in parts if q["how"] in ("fs", "raw")]
    job.total_w = sum(weight(q) for q in todo) or 1
    job.set(steps=len(todo), phase="table", msg="Saving the partition table")
    save_layout(disk, imgdir)
    saved = []
    for q in parts:
        name = imgfmt.to_filename(q["node"])
        if q["how"] == "swap":
            with open(os.path.join(imgdir, "swappt-%s.info" % name), "w") as f:
                f.write('UUID="%s"\nLABEL="%s"\n' % (q.get("fsuuid", ""), q.get("label", "")))
            continue
        if q["how"] not in ("fs", "raw"):
            continue
        job.step("Saving %s" % describe(q), weight(q))
        job.set(phase="copy")
        save_part(job, q, imgdir, name, split_mb)
        saved.append(name)
        job.finish_step()
    finish_image(disk, imgdir, saved, parts, machine)


def save_part(job, q, imgdir, name, split_mb):
    src = q.get("mapper") or q["node"]
    fs = q["fs"] if q["how"] == "fs" else "dd"
    reader = ("partclone.%s -I -c -s %s -o -" % (fs, src) if fs != "dd"
              else "partclone.dd -s %s -o -" % src)
    prefix = os.path.join(imgdir, "%s.%s-ptcl-img.zst" % (name, fs))
    idx = os.path.join(imgdir, imgfmt.SIDE, name + ".idx")
    tmpc = "/dev/shm/diag-chunk-%d.zst" % os.getpid()
    job.undo.append(lambda: os.path.exists(tmpc) and os.remove(tmpc))
    frames = ("split -b %d --filter='zstd -q -T0 -3 -c > \"$TMPC\" && "
              "stat -c %%s \"$TMPC\" >> \"$IDX\" && cat \"$TMPC\"'" % imgfmt.CHUNK)
    # two letters are 676 pieces: 2.7 TB at FAT32's 4000 MB, but only 173 GB
    # at OneDrive's 256 MB - three letters there (imgfmt reads either)
    out = ("split -a %d -b %dMB - %s." % (2 if split_mb >= 1000 else 3, split_mb, imgfmt.quote(prefix))
           if split_mb else "cat > %s" % imgfmt.quote(prefix))
    open(idx, "w").close()
    os.environ["TMPC"], os.environ["IDX"] = tmpc, idx
    job.track("%s | %s | %s" % (reader, frames, out), "saving %s" % describe(q))


def save_layout(disk, imgdir):
    d, dev = disk["name"], disk["path"]
    p = lambda suffix: imgfmt.quote(os.path.join(imgdir, imgfmt.to_filename(d) + suffix))
    q = lambda name: imgfmt.quote(os.path.join(imgdir, name))
    with open(os.path.join(imgdir, "disk"), "w") as f:
        f.write(d + "\n")
    sh("sfdisk -d %s > %s" % (dev, p("-pt.sf")))
    sh("LC_ALL=C parted -s %s unit s print > %s" % (dev, p("-pt.parted")), check=False)
    sh("LC_ALL=C parted -s %s unit compact print > %s" % (dev, p("-pt.parted.compact")), check=False)
    sh("dd if=%s of=%s bs=512 count=1 status=none" % (dev, p("-mbr")))
    if disk["label"] == "gpt":
        total = disk["bytes"] // 512
        sh("dd if=%s of=%s bs=512 count=34 status=none" % (dev, p("-gpt-1st")))
        sh("dd if=%s of=%s bs=512 skip=%d count=33 status=none" % (dev, p("-gpt-2nd"), total - 33))
        sh("sgdisk -b %s %s" % (p("-gpt.gdisk"), dev), check=False)
        sh("sgdisk -p %s > %s" % (dev, p("-gpt.sgdisk")), check=False)
    elif disk["parts"]:
        first = min(x["start"] for x in disk["parts"])
        n = min(first, 2048) - 1
        if n > 0:
            sh("dd if=%s of=%s bs=512 skip=1 count=%d status=none"
               % (dev, p("-hidden-data-after-mbr"), n))
    sh("blkid > %s" % q("blkid.list"), check=False)
    sh("lsblk -o KNAME,NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL > %s" % q("blkdev.list"), check=False)
    sh("dmidecode > %s" % q("Info-dmi.txt"), check=False)
    sh("lspci > %s" % q("Info-lspci.txt"), check=False)
    sh("smartctl -i %s > %s" % (dev, q("Info-smart.txt")), check=False)


def finish_image(disk, imgdir, saved, parts, machine):
    with open(os.path.join(imgdir, "parts"), "w") as f:
        f.write(" ".join(saved) + "\n")
    with open(os.path.join(imgdir, "dev-fs.list"), "w") as f:
        f.write("# <Device name>   <File system>   <Size>\n")
        for q in parts:
            if imgfmt.to_filename(q["node"]) in saved:
                f.write("%s %s %s\n" % (q["node"], q.get("fs") or "dd",
                                        imgplan.gb(q["size"] * 512).replace(" ", "")))
    total = sum(os.path.getsize(f) for f in glob.glob(os.path.join(imgdir, "*-ptcl-img.*")))
    with open(os.path.join(imgdir, "Info-img-size.txt"), "w") as f:
        f.write("Image size (Bytes):\n%d\n" % total)
    with open(os.path.join(imgdir, "clonezilla-img"), "w") as f:
        f.write("This image was saved by the Hardware Diagnostic Toolkit at %s.\n"
                "Machine: %s\nSaved in Clonezilla's format; restore with the toolkit or Clonezilla.\n"
                % (time.strftime("%F %T %Z"), machine))
    rc, out = sh("sha512sum %s" % imgfmt.quote(os.path.join(imgdir, "clonezilla-img")))
    with open(os.path.join(imgdir, "Info-img-id.txt"), "w") as f:
        f.write("IMG_ID=%s\n" % out.split()[0])
    side = {"saved": time.strftime("%F %T"), "machine": machine, "disk": disk,
            "chunk": imgfmt.CHUNK, "parts": saved, "bytes": total}
    with open(os.path.join(imgdir, imgfmt.SIDE, "image.json"), "w") as f:
        json.dump(side, f, indent=1)
    sh("sync", check=False)


# ---------------------------------------------------------------- restore
def image_disk(imgdir):
    """The saved drive, as imgplan.py wants it: from the toolkit's own notes
    when it made the image, otherwise from Clonezilla's table and headers."""
    side = os.path.join(imgdir, imgfmt.SIDE, "image.json")
    names = imgfmt.read_words(os.path.join(imgdir, "disk"))
    imgs = imgfmt.part_images(imgdir)
    if os.path.isfile(side):
        with open(side) as f:
            disk = json.load(f)["disk"]
    else:
        if not names:
            raise Fail("this image holds partitions only, not a whole drive")
        with open(os.path.join(imgdir, imgfmt.to_filename(names[0]) + "-pt.sf")) as f:
            disk = imgfmt.parse_sf(f.read())
        disk["name"] = names[0]
        for q in disk["parts"]:
            fs, comp, files = imgs.get(imgfmt.to_filename(q["node"]), (None, None, []))
            q.update(fs="" if fs in (None, "dd") else fs, label="", state="ok",
                     min=None, used=None)
            h = imgfmt.image_head(files, comp) if files and fs != "dd" else None
            if h:
                q["used"] = h["used_blocks"] * h["block"]
    for q in disk["parts"]:
        fs, comp, files = imgs.get(imgfmt.to_filename(q["node"]), (None, None, []))
        q["image"] = {"fs": fs, "comp": comp, "files": files}
        q.pop("mapper", None)
        if fs is None and q.get("fs") != "swap":
            q["missing"] = True
        if fs not in (None, "dd") and q.get("state") in ("locked", "unlocked"):
            q["state"] = "ok"           # saved unlocked: the image is plain NTFS
        if fs == "dd" and q.get("fs") != "bitlocker":
            q["fs"] = ""
    disk.setdefault("bytes", 0)
    return disk


def restore(job, imgdir, plan, scratch=None):
    check_target(plan)
    parts = [q for q in plan["parts"] if q["how"] != "skip" and not q.get("missing")]
    job.total_w = sum(weight(q) for q in parts) or 1
    job.set(steps=len(parts) + 1, phase="table")
    write_table(job, plan)
    base = os.path.join(imgdir, imgfmt.to_filename(plan["source"]))
    gap = base + "-hidden-data-after-mbr"
    copy_boot_area(None, "/dev/" + plan["target"], plan,
                   mbr_file=base + "-mbr" if os.path.exists(base + "-mbr") else None,
                   gap_file=gap if os.path.exists(gap) else None)
    for q in parts:
        if q["how"] == "new":
            make_new(job, q, node_of(plan["target"], q["num"]))
            continue
        job.step("Restoring %s" % describe(q), weight(q))
        job.set(phase="copy")
        restore_part(job, q, node_of(plan["target"], q["num"]), plan["sector"], scratch)
        job.finish_step()
    check_copies(job, plan)


def restore_part(job, q, dst, sec, scratch):
    img = q["image"]
    if q["how"] == "swap" or not img["files"]:
        if q["how"] == "swap":
            sh(["mkswap", dst], check=False)
        return
    stream = imgfmt.stream_cmd(img["files"], img["comp"])
    if img["fs"] == "dd":
        job.track("%s | partclone.dd -s - -O %s" % (stream, dst), "restoring")
    elif q["shrink"]:
        new_b = q["nsize"] * sec
        need = imgfmt.used_beyond(img["files"], img["comp"], new_b)
        need = need if need is not None else q.get("used") or 0
        comp, snap = composite(job, dst, new_b, q["size"] * sec, scratch or "/dev/shm", need)
        job.track("%s | partclone.%s -r -s - -o %s" % (stream, img["fs"], comp), "restoring")
        shrink_composite(job, q, comp, snap, new_b)
        resize_fs(dst, q["fs"])
    else:
        job.track("%s | partclone.%s -r -s - -o %s" % (stream, img["fs"], dst), "restoring")
        if q["grow"]:
            job.set(phase="resize", msg="Growing %s to fill the new drive" % describe(q))
            resize_fs(dst, q["fs"])


def verify_image(job, imgdir):
    imgs = imgfmt.part_images(imgdir)
    if not imgs:
        raise Fail("no partition images in this folder")
    sizes = {k: sum(os.path.getsize(f) for f in v[2]) for k, v in imgs.items()}
    job.total_w = sum(sizes.values()) or 1
    job.set(steps=len(imgs), phase="verify")
    for name, (fs, comp, files) in sorted(imgs.items()):
        job.step("Checking %s" % name, sizes[name])
        stream = imgfmt.stream_cmd(files, comp)
        if fs == "dd":
            # no partclone header to check - zstd's own checksums are the test
            job.track("%s > /dev/null" % stream, "checking %s" % name)
        else:
            job.track("%s | partclone.chkimg -s -" % stream, "checking %s" % name)
        job.finish_step()


# ---------------------------------------------------------------- BitLocker / Windows state
def bl_unlock(node, secret):
    """Open a BitLocker partition read-only with a password or the 48-digit
    recovery key. Read-only: unlocking is for copying, never for writing."""
    name = imgscan.BL_PREFIX + os.path.basename(node)
    if os.path.exists("/dev/mapper/" + name):
        return 0, "already unlocked"
    digits = re.sub(r"\D", "", secret)
    if len(digits) == 48:
        secret = "-".join(digits[i:i + 6] for i in range(0, 48, 6))
    r = subprocess.run(["cryptsetup", "open", "--type", "bitlk", "--readonly",
                        "--key-file=-", node, name], input=secret.encode(),
                       capture_output=True)
    msg = (r.stdout + r.stderr).decode("utf-8", "replace").strip()
    log("bl-unlock %s: rc=%d %s" % (node, r.returncode, msg[-200:]))   # never the key
    return r.returncode, msg


def bl_close(node=None):
    for m in glob.glob("/dev/mapper/" + imgscan.BL_PREFIX + "*"):
        if node is None or m.endswith("-" + os.path.basename(node)):
            sh(["cryptsetup", "close", os.path.basename(m)], check=False)


def unhibernate(node):
    """Throw away Windows' saved session (Fast Startup or hibernation) so C:
    can be resized. Windows then starts fresh; anything left open in a
    hibernated session is lost - the screen says so before this runs."""
    mp = os.path.join(RUN_DIR, "unhib")
    os.makedirs(mp, exist_ok=True)
    rc, out = sh(["ntfs-3g", "-o", "remove_hiberfile", node, mp], check=False)
    if rc == 0:
        sh(["umount", mp], check=False)
    return rc, out


# ---------------------------------------------------------------- drive bars
EFI_T = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
MSR_T = "e3c9e316-0b5c-4db8-817d-f92df00215ae"
WINRE_T = "de94bba4-06d1-4d40-a16a-bfd50179d6ac"
SEG_NAMES = {"efi": "EFI", "msr": "MSR", "rec": "Recovery", "locked": "BitLocker"}
NEW_FS = {"ntfs": "NTFS", "exfat": "exFAT", "vfat": "FAT32", "ext4": "ext4"}   # imgparted.FS_NAMES


def seg_kind(q, system):
    t = str(q.get("type", "")).lower()
    label = (q.get("label") or q.get("name") or "").lower()
    if q.get("how") == "new":
        return "new"
    if q.get("state") == "locked":
        return "locked"
    if t in (EFI_T, "ef"):
        return "efi"
    if t == MSR_T:
        return "msr"
    if t in (WINRE_T, "27") or "recovery" in label or "winre" in label:
        return "rec"
    if q is system:
        return "sys"
    return "data" if q.get("fs") else "raw"


def seg_name(q, kind):
    if kind == "sys":
        name = "C:" + (" " + q["label"] if q.get("label") else "")
    elif kind == "new":
        name = "new " + (q.get("label") or NEW_FS.get(q.get("fs"), q.get("fs") or ""))
    else:
        name = SEG_NAMES.get(kind) or q.get("label") or q.get("fs") or "partition %d" % q["num"]
    return name.replace("|", "/").replace(";", ",")


def seg_label(q, kind, nbytes):
    return "%s %s" % (seg_name(q, kind), imgplan.gb(nbytes))


def system_part(doc):
    # never a partition the plan screen added: a big new D: is not C:
    parts = [q for q in doc["parts"]
             if q.get("how") not in ("skip", "new") and not imgplan._is_extended(doc.get("label", ""), q)]
    return max(parts, key=lambda q: q["size"]) if parts else None


def mapspec(doc, new=False):
    """A drive for the renderer's disk bar (tui_diskmap): one segment per
    partition and per sizeable gap, "bytes|kind|label|used-fraction;...".
    `doc` is a scan, or a plan drawn as it is now (old) or will be (new)."""
    sec = doc.get("sector") or 512
    label = doc.get("label", "")
    # a partition the plan screen added is only on the new drive
    parts = [q for q in doc["parts"]
             if q.get("how") != "skip" and not imgplan._is_extended(label, q)
             and (new or q.get("how") != "new")]
    total = doc["target_bytes"] if new else (doc.get("source_bytes") or doc.get("bytes") or 0)
    k0, k1 = ("nstart", "nsize") if new else ("start", "size")
    parts.sort(key=lambda q: q[k0])
    system = system_part({"parts": parts, "label": label})
    floor = max(total // 100, 64 * MiB)
    segs, pos = [], 0
    for q in parts:
        start, size = q[k0], q[k1]
        if (start - pos) * sec >= floor:
            gap = (start - pos) * sec
            segs.append("%d|free|free %s|-1" % (gap, imgplan.gb(gap)))
        kind = seg_kind(q, system)
        used = q.get("used")
        frac = min(1.0, used / float(size * sec)) if used and size else -1
        segs.append("%d|%s|%s|%.3f" % (size * sec, kind, seg_label(q, kind, size * sec), frac))
        pos = start + size
    if total - pos * sec >= floor:
        gap = total - pos * sec
        segs.append("%d|free|free %s|-1" % (gap, imgplan.gb(gap)))
    return ";".join(segs)


# ---------------------------------------------------------------- CLI
def rows(plan):
    """One line per partition for imaging.sh: num|name|fs|old|new|how|change -
    named as the drive bars name them (EFI, MSR, C: Windows, Recovery)."""
    out = []
    sec = plan["sector"]
    system = system_part(plan)
    for q in plan["parts"]:
        change = "grows" if q.get("grow") else "shrinks" if q.get("shrink") else \
            "moves" if q.get("nstart", q["start"]) != q["start"] else ""
        how = {"fs": "used data", "raw": "every sector", "swap": "recreated",
               "skip": "-", "new": "made empty"}.get(q["how"], q["how"])
        if q.get("missing"):
            how = "not in the image"
        if q["how"] == "new":
            change = "new"
        out.append("|".join(str(x) for x in (
            q["num"], seg_name(q, seg_kind(q, system)),
            q.get("fs") or "-", "-" if q["how"] == "new" else imgplan.gb(q["size"] * sec),
            imgplan.gb(q.get("nsize", q["size"]) * sec), how, change)))
    return out


def _line(*cells):
    """One picker line. The notes come from the image - on OneDrive, from
    anyone's upload: a line break in them would be a picker line of its own."""
    return "|".join(re.sub(r"[\x00-\x1f]", " ", str(x)).replace("|", "/") for x in cells)


def macrium_line(path):
    """A Macrium image for the picker - the reason in place of the machine
    when it is one this toolkit cannot open (split, incremental, password)."""
    import mrimg
    size = os.path.getsize(path)
    saved = time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(path)))
    name = re.sub(r"-\d\d-\d\d\.mrimg$|\.mrimg$", "", os.path.basename(path), flags=re.I)
    try:
        img = mrimg.MacriumImage(path)
        saved = img.saved or saved
        drive = imgplan.gb(img.size)
        machine = "Macrium: %s" % name
        img.close()
    except (mrimg.NotMacrium, mrimg.Unsupported, OSError) as exc:
        machine, drive = "Macrium, cannot open: %s" % str(exc).split(" - ")[0], ""
    return _line(path, saved, machine, imgplan.gb(size), drive)


def image_line(d):
    """One image for imaging.sh's picker: path|saved|machine|size|drive."""
    if os.path.isfile(d):
        return macrium_line(d)
    side = os.path.join(d, imgfmt.SIDE, "image.json")
    try:
        with open(side) as f:
            j = json.load(f)
        saved, machine = j.get("saved", ""), j.get("machine", "")
        disk = j.get("disk") or {}
        drive = "%s %s" % (disk.get("model", ""), imgplan.gb(disk.get("bytes") or 0))
    except (OSError, ValueError):
        saved = time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(d)))
        machine, drive = "saved by Clonezilla", ""
    size = sum(os.path.getsize(f) for f in glob.glob(os.path.join(d, "*-ptcl-img.*")))
    return _line(d, saved, machine, imgplan.gb(size), drive.strip())


def load(path):
    with open(path) as f:
        return json.load(f)


def target_info(name):
    return {"name": name, "bytes": imgscan.dev_bytes("/dev/" + name),
            "sector": imgscan.dev_sector("/dev/" + name)}


def run_job(fn, status, *args):
    job = Job(status)
    try:
        fn(job, *args)
        job.set(phase="done", pct=100, result="ok", msg="")
        return 0
    except Stop:
        job.set(phase="done", result="stopped", msg="Stopped by the operator")
        return 3
    except (Fail, OSError, subprocess.SubprocessError) as exc:
        log("FAILED: %s" % exc)
        job.set(phase="done", result="failed", msg=str(exc))
        return 1
    finally:
        job.cleanup()


def cmd_plan_restore(imgdir, target, keep_size):
    try:
        disk = image_disk(imgdir)
    except (Fail, OSError) as exc:
        return {"ok": False, "errors": [str(exc)], "notes": [], "parts": []}
    p = imgplan.plan(disk, target_info(target), keep_size)
    p["source"] = disk.get("name", "")
    missing = [q for q in p["parts"] if q.get("missing")]
    if missing:
        p["notes"].append("%d partition(s) are not in this image and stay empty."
                          % len(missing))
    return p


def cmd_shrink_need(plan, imgdir):
    """Bytes of scratch space the planned shrink needs (0 when nothing shrinks)."""
    sec = plan["sector"]
    for q in plan["parts"]:
        if not q.get("shrink"):
            continue
        if imgdir:
            img = q["image"]
            need = imgfmt.used_beyond(img["files"], img["comp"], q["nsize"] * sec)
            need = need if need is not None else q.get("used") or 0
        else:
            need = shrink_need(q.get("mapper") or q["node"], q["fs"], q["nsize"] * sec)
        return need + need // 10 + SCRATCH_MARGIN
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="imgengine.py")
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--status", default=os.path.join(RUN_DIR, "imaging.status"))
    ap.add_argument("--scratch")
    ap.add_argument("--source-shrink", action="store_true")
    ap.add_argument("--keep-size", action="store_true")
    ap.add_argument("--split-mb", type=int)
    ap.add_argument("--machine", default="")
    a = ap.parse_args(argv[1:])
    c, x = a.cmd, a.args
    os.makedirs(RUN_DIR, exist_ok=True)
    if c == "scan":
        print(json.dumps(imgscan.scan(x[0]), indent=1))
    elif c == "plan":
        print(json.dumps(imgplan.plan(load(x[0]), target_info(x[1]), a.keep_size), indent=1))
    elif c == "plan-restore":
        print(json.dumps(cmd_plan_restore(x[0], x[1], a.keep_size), indent=1))
    elif c == "rows":
        print("\n".join(rows(load(x[0]))))
    elif c == "mapspec":
        print(mapspec(load(x[0]), new=len(x) > 1 and x[1] == "new"))
    elif c == "list-images":
        for d in imgfmt.find_images(x[0]):
            print(image_line(d))
    elif c == "shrink-need":
        print(cmd_shrink_need(load(x[0]), x[1] if len(x) > 1 else None))
    elif c == "clone":
        return run_job(clone, a.status, load(x[0]), a.scratch, a.source_shrink)
    elif c == "backup":
        return run_job(backup, a.status, load(x[0]), x[1], a.split_mb, a.machine)
    elif c == "restore":
        return run_job(restore, a.status, x[0], load(x[1]), a.scratch)
    elif c == "verify":
        return run_job(verify_image, a.status, x[0])
    elif c == "bl-unlock":
        rc, msg = bl_unlock(x[0], sys.stdin.read().strip())
        print(msg)
        return rc
    elif c == "bl-close":
        bl_close(x[0] if x else None)
    elif c == "unhibernate":
        rc, out = unhibernate(x[0])
        print(out)
        return rc
    elif c == "clear-dirty":
        return sh(["ntfsfix", "-d", x[0]], check=False)[0]
    else:
        ap.error("unknown command %s" % c)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
