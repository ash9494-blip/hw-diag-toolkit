#!/usr/bin/env python3
"""What is on a drive: its partition table, and for each partition the
filesystem, how much of it is in use, how small it could shrink, and whether
it is safe to resize - the disk description imgplan.py plans from.

Only ever reads. Every probe is a read-only tool (sfdisk --json, blkid -p,
ntfsresize --info, ntfscat, dumpe2fs, resize2fs -P) or a read-only mount.

    imgscan.py sda          -> JSON on stdout
"""
import json
import os
import re
import subprocess
import sys
import tempfile

BL_PREFIX = "diag-bl-"            # /dev/mapper name of an unlocked BitLocker partition


def run(cmd, timeout=180, input_=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           input=input_, errors="replace")
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, "", str(exc)


def dev_bytes(path):
    rc, out, _ = run(["blockdev", "--getsize64", path])
    return int(out.strip()) if rc == 0 and out.strip().isdigit() else 0


def dev_sector(path):
    rc, out, _ = run(["blockdev", "--getss", path])
    return int(out.strip()) if rc == 0 and out.strip().isdigit() else 512


def part_num(node):
    m = re.search(r"(\d+)$", node)
    return int(m.group(1)) if m else 0


def bl_mapper(node):
    """The unlocked view of a BitLocker partition, if this session opened one."""
    path = "/dev/mapper/" + BL_PREFIX + os.path.basename(node)
    return path if os.path.exists(path) else None


def read_table(path):
    """sfdisk --json, flattened. A drive with no partition table gives none."""
    rc, out, _ = run(["sfdisk", "--json", path])
    if rc != 0 or not out.strip():
        return {"label": "", "id": "", "firstlba": None, "parts": []}
    t = json.loads(out).get("partitiontable", {})
    parts = []
    for p in t.get("partitions", []):
        parts.append({"node": p["node"], "num": part_num(p["node"]),
                      "start": int(p["start"]), "size": int(p["size"]),
                      "type": str(p.get("type", "")), "uuid": p.get("uuid") or "",
                      "name": p.get("name") or "", "attrs": p.get("attrs") or "",
                      "bootable": bool(p.get("bootable"))})
    return {"label": t.get("label", ""), "id": t.get("id", ""),
            "firstlba": t.get("firstlba"), "parts": parts}


def blkid(node):
    rc, out, _ = run(["blkid", "-p", "-o", "export", node])
    info = {}
    for line in out.splitlines():
        k, _, v = line.partition("=")
        info[k] = v
    return info


def mountpoint_of(node):
    rc, out, _ = run(["findmnt", "-rno", "TARGET", "--source", node])
    return out.splitlines()[0] if rc == 0 and out.strip() else None


# ---------------------------------------------------------------- per filesystem
def _ntfs_numbers(text):
    used = mn = size = None
    m = re.search(r"Current volume size:\s*(\d+) bytes", text)
    if m:
        size = int(m.group(1))
    m = re.search(r"Space in use\s*:\s*(\d+) MB", text)
    if m:
        used = int(m.group(1)) * 1000 * 1000
    m = re.search(r"might resize at (\d+) bytes", text)
    if m:
        mn = int(m.group(1))
    return used, mn, size


def ntfs_hibernated(node):
    """Windows' own test (ntfs-3g does the same): hiberfil.sys starting with
    "hibr" or "HIBR" is a session waiting to resume - Fast Startup writes one
    at every normal shut down. ntfsresize --info does not look, so a
    hibernated C: would have been offered for resizing."""
    try:
        r = subprocess.run(["ntfscat", "-f", node, "hiberfil.sys"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
        return r.stdout[:4] in (b"hibr", b"HIBR")
    except (OSError, subprocess.TimeoutExpired):
        return False


def probe_ntfs(node):
    rc, out, err = run(["ntfsresize", "--info", "--no-progress-bar", node])
    text = out + err
    state = "ok"
    if rc != 0 and re.search(r"scheduled for check|chkdsk", text, re.I):
        state = "dirty"
        rc, out, err = run(["ntfsresize", "--info", "--force", "--no-progress-bar", node])
        text = out + err
    if ntfs_hibernated(node):
        state = "hibernated"
    used, mn, size = _ntfs_numbers(text)
    if used is None:
        state = "error" if state == "ok" else state
    return {"used": used, "min": mn, "fsbytes": size, "state": state}


def probe_ext(node):
    rc, out, _ = run(["dumpe2fs", "-h", node])
    f = {}
    for line in out.splitlines():
        k, _, v = line.partition(":")
        f[k.strip()] = v.strip()
    try:
        bs = int(f["Block size"])
        count, free = int(f["Block count"]), int(f["Free blocks"])
    except (KeyError, ValueError):
        return {"used": None, "min": None, "fsbytes": None, "state": "error"}
    state = "ok" if f.get("Filesystem state", "").startswith("clean") else "dirty"
    mn = None
    rc, out, err = run(["resize2fs", "-P", node])
    m = re.search(r"minimum size of the filesystem:\s*(\d+)", out + err)
    if m:
        mn = int(m.group(1)) * bs
    return {"used": (count - free) * bs, "min": mn, "fsbytes": count * bs, "state": state}


def probe_mounted(node, fstype):
    """FAT, exFAT and the rest: how full they are, from a read-only mount (or
    the existing one - the same partition is never mounted twice)."""
    mp = mountpoint_of(node)
    tmp = None
    if mp is None:
        tmp = tempfile.mkdtemp(prefix="imgscan-", dir="/run" if os.path.isdir("/run") else None)
        rc, _, _ = run(["mount", "-o", "ro", "-t", fstype, node, tmp], timeout=60)
        if rc != 0:
            os.rmdir(tmp)
            return {"used": None, "min": None, "fsbytes": None, "state": "error"}
        mp = tmp
    try:
        st = os.statvfs(mp)
        size = st.f_blocks * st.f_frsize
        used = (st.f_blocks - st.f_bfree) * st.f_frsize
    finally:
        if tmp:
            run(["umount", tmp], timeout=60)
            os.rmdir(tmp)
    return {"used": used, "min": None, "fsbytes": size, "state": "ok"}


def probe_fs(node, fs):
    if fs == "ntfs":
        return probe_ntfs(node)
    if fs in ("ext2", "ext3", "ext4"):
        return probe_ext(node)
    if fs in ("vfat", "exfat", "btrfs", "xfs", "f2fs"):
        return probe_mounted(node, fs)
    if fs == "swap":
        return {"used": 0, "min": None, "fsbytes": None, "state": "ok"}
    return {"used": None, "min": None, "fsbytes": None, "state": "ok"}


# ntfsresize flags every volume it touches for a Windows check - on purpose.
# The editor then saw its own C: as "marked for a disk check" and refused to
# grow it back (test, 1.21.0). Volumes this session resized are listed here
# by serial; their flag is ours, not Windows reporting a problem.
RESIZED = os.path.join(os.environ.get("RUN_DIR", "/run/diag"), "ntfs-resized.list")


def mark_resized(dev):
    uid = blkid(dev).get("UUID", "")
    if uid:
        try:
            with open(RESIZED, "a") as f:
                f.write(uid + "\n")
        except OSError:
            pass


def resized_here(uid):
    try:
        with open(RESIZED) as f:
            return bool(uid) and uid in f.read().split()
    except OSError:
        return False


def probe_part(p):
    p.update(_probe_part(p))
    if p.get("state") == "dirty" and p.get("fs") == "ntfs" and resized_here(p.get("fsuuid")):
        p["state"] = "ok"
        p["resized"] = True
    return p


def _probe_part(p):
    info = blkid(p["node"])
    fs = info.get("TYPE", "").lower()
    p["label"] = info.get("LABEL", "")
    p["fsuuid"] = info.get("UUID", "")
    if fs == "bitlocker":
        mapper = bl_mapper(p["node"])
        if mapper is None:
            p.update(fs="bitlocker", used=None, min=None, fsbytes=None, state="locked")
            return p
        inner = blkid(mapper)
        fs = inner.get("TYPE", "").lower()
        p["label"] = inner.get("LABEL", "") or p["label"]
        p["mapper"] = mapper
        p["fs"] = fs
        p.update(probe_fs(mapper, fs))
        if p["state"] == "ok":
            p["state"] = "unlocked"
        p["bitlocker"] = True
        return p
    p["fs"] = fs
    p.update(probe_fs(p["node"], fs))
    return p


def disk_model(path):
    rc, out, _ = run(["lsblk", "-dno", "MODEL,SERIAL,TRAN,RM", "-J", path])
    try:
        d = json.loads(out)["blockdevices"][0]
        return {k: (d.get(k) or "").strip() if isinstance(d.get(k), str) else d.get(k)
                for k in ("model", "serial", "tran", "rm")}
    except (ValueError, KeyError, IndexError):
        return {"model": "", "serial": "", "tran": "", "rm": False}


def scan(name):
    path = "/dev/" + name
    t = read_table(path)
    disk = {"name": name, "path": path, "bytes": dev_bytes(path),
            "sector": dev_sector(path), "label": t["label"], "id": t["id"],
            "firstlba": t["firstlba"]}
    disk.update(disk_model(path))
    disk["parts"] = [probe_part(p) for p in t["parts"]]
    return disk


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: imgscan.py DISK   (e.g. sda, nvme0n1)\n")
        return 2
    json.dump(scan(argv[1]), sys.stdout, indent=1)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
