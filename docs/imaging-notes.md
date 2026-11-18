# Disk imaging - notes and traps

Read before changing `img*.py`, `mrimg.py`, `imaging.sh`, `partitions.sh` or
`imgbrowse.*`. Invariant 9 (CLAUDE.md) is the rule; this is what was learnt
keeping it. After any change: `sudo test/imaging-loop.sh`.

## partclone

- `-o FILE` refuses an existing file (even /dev/null) - use `-O`.
- dev-to-dev (`-b`) compares the *partition* sizes, so a filesystem already
  shrunk inside a big partition needs `-C`.
- `-I` copies an NTFS marked for chkdsk (exact copy; never resize one).
- partclone.dd output has no header (chkimg says "not partclone image") -
  check it through zstd.

## NTFS

- ntfsresize leaves the volume flagged for chkdsk (by design - Windows checks
  once). Volumes the toolkit resized are listed by serial in
  `$RUN_DIR/ntfs-resized.list` and scan as "ok"; any other flagged NTFS is
  "dirty" and is never resized.

## Browse an image (NBD)

- Uses NBD's old ioctl interface on a socketpair (no nbd-client):
  NBD_SET_SOCK and the other setup ioctls from one task, NBD_DO_IT blocks in a
  thread for the whole connection.
- The bitmap's CRC32 (4 bytes) sits between the bitmap and the first block,
  and a checksum follows every `blocks_per_checksum` blocks - offsets off by
  either read plausible-looking garbage, which `test/imgbrowse_test.py`
  catches.
- `fcntl.ioctl` passes a C int: NBD_SET_SIZE of anything over 2 GB overflowed
  - imgbrowse's `ioctl()` goes through ctypes (unsigned long).
- An image can only be read in the middle through `diag/<part>.idx`; the
  reader refuses one whose frame sizes do not add up to the files (a lost
  line would shift every offset after it).
- NBD devices allow partitions (`modprobe nbd`, no max_part=0): Restore from
  a Macrium image serves the whole drive and clones from nbdNp1...; the
  kernel's table scan needs `blockdev --rereadpt` + `udevadm settle`.

## Macrium .mrimg (mrimg.py)

- No published spec for Reflect 7/8 - the layout came from the mrimg7z
  project and was checked against Ash's own image and images Macrium made of
  known test disks (C:\Users\Ash\mrimg-test, make-mrimg.ps1 - Macrium's
  command line wants the GPT disk GUID in upper case).
- The u16 at metadata+8 is the split piece, +10 the incremental number.
- "No compression" blocks carry no QuickLZ header.
- FAT partitions keep their reserved sectors + FATs raw before the blocks.
- QuickLZ itself never reports bad input - the per-block MD5 is the only
  check, keep it.

### Not supported yet (each refused with the reason)

- split images (several .mrimg files - the last piece holds the index, and
  the records do not say which piece a block is in)
- incremental / differential images
- password-protected images
- MBR images with logical partitions
- Reflect X (.mrimgx) - Macrium publishes that format, MIT, at
  github.com/macrium/mrimgx_file_layout, if Ash moves to Reflect X
- Clonezilla's own images in Browse (no index) - restore them instead
