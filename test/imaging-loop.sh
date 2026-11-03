#!/bin/bash
# End-to-end test of the imaging engine on loop devices - no real drive is
# touched. Needs root and: partclone ntfs-3g gdisk fdisk parted dosfstools
# zstd dmsetup jq (the build host's setup-host.sh installs them).
#
#   sudo test/imaging-loop.sh            # all cases
#   sudo test/imaging-loop.sh clone      # cases whose name contains "clone"
#   sudo test/imaging-loop.sh backup,browse   # browse needs backup's image
#
# A fake factory Windows drive (EFI, MSR, C:, Recovery) is built, filled with
# files and checksummed, then cloned, backed up and restored every way the
# toolkit offers. Each case checks every file on the copy and that the source
# image file did not change by one byte.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ENG="python3 $HERE/../toolkit/imgengine.py"
IB="python3 $HERE/../toolkit/imgbrowse.py"
W=${IMGTEST_DIR:-/root/imgtest}
export RUN_DIR=$W/run
ONLY=${1:-}
PASS=0; FAILS=0; LOOPS=""

say()  { printf '\n=== %s\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad()  { FAILS=$((FAILS+1)); printf '  FAIL %s\n' "$*"; }
want() {   # ONLY: names (or parts of names), comma-separated
  local o
  [ -z "$ONLY" ] && return 0
  for o in ${ONLY//,/ }; do [[ "$1" == *"$o"* ]] && return 0; done
  return 1
}

lo() {   # file -> /dev/loopN with partitions
  local d; d=$(losetup -f --show -P "$1") || exit 1
  LOOPS="$LOOPS $d"; echo "$d"
}
cleanup() {
  umount -q "$W/m" "$W/bm" 2>/dev/null
  for p in "$RUN_DIR"/browse-nbd*.pid; do      # a browse case that failed half-way
    [ -e "$p" ] && $IB detach "/dev/$(basename "$p" .pid | sed 's/^browse-//')"
  done
  for m in /dev/mapper/diag-*; do [ -e "$m" ] && dmsetup remove -f "${m##*/}"; done 2>/dev/null
  for l in $LOOPS; do losetup -d "$l" 2>/dev/null; done
  # loops made inside $(...) never reach LOOPS (make_source's): every loop
  # over a file of ours goes, so runs do not pile up attached drives
  losetup -a | awk -F: -v w="$W/" 'index($0, w) {print $1}' | xargs -r -n1 losetup -d 2>/dev/null
}
trap cleanup EXIT

# ---------------------------------------------------------------- the fake drive
make_source() {   # file size-MiB label(gpt|dos)
  local f=$1 mib=$2 label=$3 d
  rm -f "$f"; truncate -s "${mib}M" "$f"
  d=$(lo "$f")
  if [ "$label" = gpt ]; then
    sfdisk -q "$d" <<SF
label: gpt
unit: sectors
start=2048, size=204800, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI system partition"
start=206848, size=32768, type=E3C9E316-0B5C-4DB8-817D-F92DF00215AE, name="Microsoft reserved partition"
start=239616, size=$(( (mib - 120 - 260) * 2048 )), type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="Basic data partition"
type=DE94BBA4-06D1-4D40-A16A-BFD50179D6AC, size=$(( 200 * 2048 )), attrs="RequiredPartition GUID:63"
SF
    partprobe "$d"; udevadm settle
    mkfs.vfat -n SYSTEM "${d}p1" >/dev/null
    head -c 16M /dev/urandom > "${d}p2"                      # MSR: no filesystem
    mkntfs -Q -L Windows "${d}p3" >/dev/null 2>&1
    mkntfs -Q -L WinRE "${d}p4" >/dev/null 2>&1
    fill "${d}p3" ntfs-3g 110 8; fill_small "${d}p1" vfat; fill_small "${d}p4" ntfs-3g
  else
    sfdisk -q "$d" <<SF
label: dos
unit: sectors
start=2048, size=204800, type=7, bootable
start=206848, type=7
SF
    partprobe "$d"; udevadm settle
    mkntfs -Q -L "System Reserved" "${d}p1" >/dev/null 2>&1
    mkntfs -Q -L Windows "${d}p2" >/dev/null 2>&1
    printf 'BOOTCODE-TEST' | dd of="$d" bs=1 seek=100 conv=notrunc status=none
    fill "${d}p2" ntfs-3g 30 2; fill_small "${d}p1" ntfs-3g
  fi
  sync
  echo "$d"
}

fill() {   # node mounter files keep-every: fill the volume, then delete all
  # but every Nth file - what is left is spread to the far end of the volume,
  # so shrinking it has data to move (the scratch area is really used)
  mkdir -p "$W/m"
  if [ "$2" = ntfs-3g ]; then ntfs-3g "$1" "$W/m"; else mount "$1" "$W/m"; fi
  local i
  for i in $(seq 1 "$3"); do head -c 24M /dev/urandom > "$W/m/f$i.bin"; done
  for i in $(seq 1 "$3"); do [ $((i % $4)) = 0 ] || rm "$W/m/f$i.bin"; done
  mkdir -p "$W/m/Windows/System32"; echo "boot me" > "$W/m/Windows/System32/winload.efi"
  (cd "$W/m" && find . -type f -exec sha256sum {} +) | sort -k2 > "$W/sums-$(basename "$1" | sed 's/^loop[0-9]*//').txt"
  umount "$W/m"
}
fill_small() {
  mkdir -p "$W/m"
  if [ "$2" = ntfs-3g ]; then ntfs-3g "$1" "$W/m"; else mount "$1" "$W/m"; fi
  mkdir -p "$W/m/EFI/Boot"; head -c 2M /dev/urandom > "$W/m/EFI/Boot/bootx64.efi"
  (cd "$W/m" && find . -type f -exec sha256sum {} +) | sort -k2 > "$W/sums-$(basename "$1" | sed 's/^loop[0-9]*//').txt"
  umount "$W/m"
}

check_files() {   # node sums-file what
  mkdir -p "$W/m"
  if ! mount -o ro "$1" "$W/m" 2>/dev/null && ! ntfs-3g -o ro "$1" "$W/m" 2>/dev/null; then
    bad "$3: $1 does not mount"; return
  fi
  if (cd "$W/m" && sha256sum --quiet -c "$2" >/dev/null 2>&1); then
    ok "$3: every file on $1 matches ($(wc -l < "$2") files)"
  else
    bad "$3: files on $1 differ"
  fi
  umount "$W/m"
}

status_is() {   # status-file result what
  local r; r=$(sed -n 's/^result=//p' "$1")
  if [ "$r" = "$2" ]; then ok "$3: result=$r"; else bad "$3: result=$r ($(sed -n 's/^msg=//p' "$1"))"; fi
}

fresh_target() {   # file size-MiB
  rm -f "$1"; truncate -s "${2}M" "$1"; lo "$1"
}

part() { echo "${1}p$2"; }

# ---------------------------------------------------------------- cases
mkdir -p "$W" "$RUN_DIR"; rm -rf "$W/img"
say "building the fake Windows drive"
SRC=$(make_source "$W/src.img" 4000 gpt | tail -1)
SRCMD5=$(md5sum < "$W/src.img")
$ENG scan "${SRC#/dev/}" > "$W/scan.json"
jq -c '[.parts[] | {num, fs, label, state, used, min}]' "$W/scan.json"
src_same() {
  if [ "$(md5sum < "$W/src.img")" = "$SRCMD5" ]; then ok "$1: source drive unchanged"
  else bad "$1: SOURCE DRIVE CHANGED"; fi
}
check_all() {   # target what
  check_files "$(part "$1" 3)" "$W/sums-p3.txt" "$2 C:"
  check_files "$(part "$1" 1)" "$W/sums-p1.txt" "$2 EFI"
  check_files "$(part "$1" 4)" "$W/sums-p4.txt" "$2 WinRE"
}

if want clone-bigger; then
  say "clone-bigger: 4 GB -> 6 GB"
  T=$(fresh_target "$W/t1.img" 6000)
  $ENG plan "$W/scan.json" "${T#/dev/}" > "$W/plan1.json"
  $ENG rows "$W/plan1.json"
  $ENG clone "$W/plan1.json" --status "$W/s1"
  status_is "$W/s1" ok clone-bigger
  check_all "$T" clone-bigger
  [ "$(sfdisk --json "$T" | jq -r .partitiontable.id)" = "$(sfdisk --json "$SRC" | jq -r .partitiontable.id)" ] \
    && ok "clone-bigger: same disk GUID" || bad "clone-bigger: disk GUID differs"
  [ "$(sfdisk --json "$T" | jq '.partitiontable.partitions[2].size')" -gt "$(sfdisk --json "$SRC" | jq '.partitiontable.partitions[2].size')" ] \
    && ok "clone-bigger: C: grew" || bad "clone-bigger: C: did not grow"
  cmp -s <(dd if="$(part "$SRC" 2)" bs=1M status=none) <(dd if="$(part "$T" 2)" bs=1M status=none) \
    && ok "clone-bigger: MSR copied sector for sector" || bad "clone-bigger: MSR differs"
  src_same clone-bigger
fi

if want clone-edited; then
  # the plan screen's sizes editor (imgplanedit.py, 1.24): what a drag of
  # C:'s edge, a drag of WinRE and N on the gap do, through its command line
  say "clone-edited: 4 GB -> 6 GB, sizes set by hand - C: 2.5 GB, WinRE +300 MB, new DATA"
  PX="python3 $HERE/../toolkit/imgplanedit.py"
  T=$(fresh_target "$W/t1e.img" 6000)
  $ENG plan "$W/scan.json" "${T#/dev/}" > "$W/plan1e.json"
  $PX open "$W/plan1e.json" "$W/pe.json" "Old drive" "New drive" "Sizes on the new drive"
  $PX geom "$W/pe.json" 2 "$(jq '.after[2].start' "$W/pe.json")" $(( 2560 * 2048 ))
  rs=$(jq '.after[3].start' "$W/pe.json"); rz=$(jq '.after[3].size' "$W/pe.json")
  $PX geom "$W/pe.json" 3 $(( rs - 300 * 2048 )) $(( rz + 300 * 2048 ))
  $PX new "$W/pe.json" 0 ntfs DATA
  $PX ops "$W/pe.json" | sed 's/^/  /'
  if $PX done "$W/pe.json" "$W/plan1e.json"; then ok "clone-edited: the edited plan is accepted"
  else bad "clone-edited: the edited plan was refused"; fi
  $ENG rows "$W/plan1e.json"
  $ENG clone "$W/plan1e.json" --status "$W/s1e" --scratch /dev/shm
  status_is "$W/s1e" ok clone-edited
  check_all "$T" clone-edited
  [ "$(sfdisk --json "$T" | jq '.partitiontable.partitions[] | select(.node | endswith("p3")) | .size')" = $(( 2560 * 2048 )) ] \
    && ok "clone-edited: C: is 2.5 GB" || bad "clone-edited: C: is not the size set"
  [ "$(sfdisk --json "$T" | jq '.partitiontable.partitions[] | select(.node | endswith("p4")) | .size')" = $(( rz + 300 * 2048 )) ] \
    && ok "clone-edited: WinRE grew by 300 MB" || bad "clone-edited: WinRE is not the size set"
  [ "$(blkid -o value -s TYPE "$(part "$T" 5)")/$(blkid -o value -s LABEL "$(part "$T" 5)")" = ntfs/DATA ] \
    && ok "clone-edited: new partition 5 is an empty NTFS named DATA" || bad "clone-edited: new partition 5 is not NTFS DATA"
  src_same clone-edited
fi

if want clone-smaller; then
  say "clone-smaller: 4 GB -> 1.9 GB, shrink in scratch"
  T=$(fresh_target "$W/t2.img" 1900)
  $ENG plan "$W/scan.json" "${T#/dev/}" > "$W/plan2.json"
  jq -r '.errors[]?, .notes[]?' "$W/plan2.json"
  echo "  scratch needed: $($ENG shrink-need "$W/plan2.json") bytes"
  $ENG clone "$W/plan2.json" --status "$W/s2" --scratch /dev/shm
  status_is "$W/s2" ok clone-smaller
  check_all "$T" clone-smaller
  src_same clone-smaller
  ls /dev/mapper/ | grep -q diag- && bad "clone-smaller: dm devices left behind" || ok "clone-smaller: nothing left behind"
fi

if want clone-source-shrink; then
  say "clone-source-shrink: 4 GB -> 1.9 GB, shrinking C: on a COPY of the source"
  cp "$W/src.img" "$W/src2.img"; S2=$(lo "$W/src2.img")
  $ENG scan "${S2#/dev/}" > "$W/scan2.json"
  T=$(fresh_target "$W/t3.img" 1900)
  $ENG plan "$W/scan2.json" "${T#/dev/}" > "$W/plan3.json"
  $ENG clone "$W/plan3.json" --status "$W/s3" --source-shrink
  status_is "$W/s3" ok clone-source-shrink
  check_all "$T" clone-source-shrink
  check_files "$(part "$S2" 3)" "$W/sums-p3.txt" "clone-source-shrink old C: afterwards"
  sz=$(ntfsresize -i -f "$(part "$S2" 3)" | sed -n 's/Current volume size: \([0-9]*\).*/\1/p')
  dev=$(blockdev --getsize64 "$(part "$S2" 3)")
  [ $(( dev - sz )) -lt 1048576 ] && ok "clone-source-shrink: old C: back to full size" \
    || bad "clone-source-shrink: old C: left at $sz of $dev"
fi

if want backup; then
  say "backup: image to a folder, split in 100 MB pieces, then verify"
  $ENG backup "$W/scan.json" "$W/img/2026-10-08-test-img" --status "$W/s4" --split-mb 100 --machine "TEST A40-J"
  status_is "$W/s4" ok backup
  I="$W/img/2026-10-08-test-img"
  for f in disk parts clonezilla-img Info-img-id.txt dev-fs.list diag/image.json; do
    [ -e "$I/$f" ] || bad "backup: $f missing"
  done
  d=$(cat "$I/disk")
  for f in "$d-pt.sf" "$d-pt.parted" "$d-mbr" "$d-gpt-1st" "$d-gpt-2nd" "$d-gpt.gdisk"; do
    [ -s "$I/$f" ] || bad "backup: $f missing or empty"
  done
  ls "$I" | grep -q 'p3.ntfs-ptcl-img.zst.aa$' && ok "backup: C: saved as ntfs partclone image in pieces" || bad "backup: C: image not named as Clonezilla names it"
  ls "$I" | grep -q 'p2.dd-ptcl-img.zst' && ok "backup: MSR saved as dd image" || bad "backup: MSR image missing"
  ls "$I"/*.idx 2>/dev/null && bad "backup: an index sits among the pieces (Clonezilla would read it)"
  [ -s "$I/diag/${d}p3.idx" ] && ok "backup: frame index written" || bad "backup: no frame index"
  du -sh "$I" | sed 's/^/  image size: /'
  $ENG verify "$I" --status "$W/s5"
  status_is "$W/s5" ok verify
  # a broken piece must be caught
  cp -r "$I" "$W/img/broken-img"
  p=$(ls "$W/img/broken-img/"*p3.ntfs-ptcl-img.zst.aa)
  printf 'XXXXXXXX' | dd of="$p" bs=1 seek=5000000 conv=notrunc status=none
  $ENG verify "$W/img/broken-img" --status "$W/s5b"
  [ "$(sed -n 's/^result=//p' "$W/s5b")" = failed ] && ok "verify: a damaged image is caught" || bad "verify: damage NOT caught"
  rm -rf "$W/img/broken-img"
  src_same backup
fi

if want restore; then
  I="$W/img/2026-10-08-test-img"
  [ -d "$I" ] || { bad "restore: run the backup case first"; }
  say "restore-bigger: image -> 6 GB"
  T=$(fresh_target "$W/t4.img" 6000)
  $ENG plan-restore "$I" "${T#/dev/}" > "$W/plan4.json"
  $ENG rows "$W/plan4.json"
  $ENG restore "$I" "$W/plan4.json" --status "$W/s6"
  status_is "$W/s6" ok restore-bigger
  check_all "$T" restore-bigger
  say "restore-smaller: image -> 1.9 GB"
  T=$(fresh_target "$W/t5.img" 1900)
  $ENG plan-restore "$I" "${T#/dev/}" > "$W/plan5.json"
  echo "  scratch needed: $($ENG shrink-need "$W/plan5.json" "$I") bytes"
  $ENG restore "$I" "$W/plan5.json" --status "$W/s7" --scratch /dev/shm
  status_is "$W/s7" ok restore-smaller
  check_all "$T" restore-smaller
  say "restore of a Clonezilla-style image (no diag/ notes)"
  cp -r "$I" "$W/img/cz-img"; rm -rf "$W/img/cz-img/diag"
  T=$(fresh_target "$W/t6.img" 4500)
  $ENG plan-restore "$W/img/cz-img" "${T#/dev/}" > "$W/plan6.json"
  jq -r '.errors[]?' "$W/plan6.json"
  $ENG restore "$W/img/cz-img" "$W/plan6.json" --status "$W/s8"
  status_is "$W/s8" ok restore-clonezilla
  check_all "$T" restore-clonezilla
fi

if want mbr; then
  say "mbr: old BIOS-style drive, 1 GB -> 2 GB"
  # make_source writes sums-pN.txt over the GPT drive's: kept aside and put
  # back, or browse (after this case) checked the GPT EFI against the MBR
  # drive's sums and failed every full run (1.24)
  for f in "$W"/sums-p*.txt; do cp "$f" "$f.gpt"; done
  MS=$(make_source "$W/mbr.img" 1000 dos | tail -1)
  mv "$W/sums-p2.txt" "$W/sums-mbr-c.txt"; mv "$W/sums-p1.txt" "$W/sums-mbr-sr.txt"
  for f in "$W"/sums-p*.txt.gpt; do mv "$f" "${f%.gpt}"; done
  $ENG scan "${MS#/dev/}" > "$W/scanm.json"
  T=$(fresh_target "$W/t7.img" 2000)
  $ENG plan "$W/scanm.json" "${T#/dev/}" > "$W/planm.json"
  $ENG clone "$W/planm.json" --status "$W/s9"
  status_is "$W/s9" ok mbr
  check_files "$(part "$T" 2)" "$W/sums-mbr-c.txt" "mbr C:"
  check_files "$(part "$T" 1)" "$W/sums-mbr-sr.txt" "mbr System Reserved"
  [ "$(sfdisk --json "$T" | jq -r .partitiontable.id)" = "$(sfdisk --json "$MS" | jq -r .partitiontable.id)" ] \
    && ok "mbr: same disk signature" || bad "mbr: disk signature differs"
  sfdisk --json "$T" | jq -e '.partitiontable.partitions[0].bootable' >/dev/null \
    && ok "mbr: boot flag kept" || bad "mbr: boot flag lost"
  dd if="$T" bs=1 skip=100 count=13 status=none | grep -q BOOTCODE-TEST \
    && ok "mbr: boot code copied" || bad "mbr: boot code not copied"
fi

if want refused; then
  say "refused: a plan the planner turned down never touches the drive"
  T=$(fresh_target "$W/t9.img" 400)
  $ENG plan "$W/scan.json" "${T#/dev/}" > "$W/plan9.json"
  jq -e '.ok == false' "$W/plan9.json" >/dev/null && ok "refused: 400 MB is refused" || bad "refused: 400 MB was accepted"
  $ENG clone "$W/plan9.json" --status "$W/s11"
  status_is "$W/s11" failed refused
  [ -z "$(sfdisk -d "$T" 2>/dev/null)" ] && ok "refused: no partition table written" || bad "refused: the drive was written"
fi

# ---------------------------------------------------------------- partition editor
PE="python3 $HERE/../toolkit/imgparted.py"
jget() { jq -r "$2" "$1"; }

if want parted-split; then
  say "parted-split: shrink C: to 2 GB (data has to move) and make D: in the space"
  cp "$W/src.img" "$W/p1.img"; P=$(lo "$W/p1.img")
  $PE load "${P#/dev/}" "$W/ps.json"
  $PE size "$W/ps.json" 2 $((2048 * 1024 * 1024))
  $PE new "$W/ps.json" 0 ntfs Data
  $PE ops "$W/ps.json" | sed 's/^/  step: /'
  $PE apply "$W/ps.json" --status "$W/s12"
  status_is "$W/s12" ok parted-split
  check_files "$(part "$P" 3)" "$W/sums-p3.txt" "parted-split C:"
  check_files "$(part "$P" 4)" "$W/sums-p4.txt" "parted-split WinRE"
  [ "$(blkid -o value -s LABEL "$(part "$P" 5)")" = Data ] && ok "parted-split: D: made, labelled Data" \
    || bad "parted-split: no D:"
  if ntfs-3g "$(part "$P" 5)" "$W/m" && echo hello > "$W/m/t.txt" && umount "$W/m"; then
    ok "parted-split: D: takes files"; else bad "parted-split: D: not writable"; fi
  sz=$(ntfsresize -i -f "$(part "$P" 3)" | sed -n 's/Current volume size: \([0-9]*\).*/\1/p')
  [ $(( $(blockdev --getsize64 "$(part "$P" 3)") - sz )) -lt 1048576 ] && ok "parted-split: C: fills its smaller partition" \
    || bad "parted-split: C: volume and partition sizes differ"
fi

if want parted-move; then
  say "parted-move: Recovery moved left next to a shrunk C:, then right again, C: grown back"
  cp "$W/src.img" "$W/p2.img"; P=$(lo "$W/p2.img")
  $PE load "${P#/dev/}" "$W/pm.json"
  $PE size "$W/pm.json" 2 $((2048 * 1024 * 1024))
  cend=$(( $(jget "$W/pm.json" '.after[2].start') + $(jget "$W/pm.json" '.after[2].size') ))
  $PE geom "$W/pm.json" 3 "$cend" "$(jget "$W/pm.json" '.after[3].size')"
  $PE ops "$W/pm.json" | sed 's/^/  step: /'
  $PE apply "$W/pm.json" --status "$W/s13"
  status_is "$W/s13" ok "parted-move left"
  check_files "$(part "$P" 4)" "$W/sums-p4.txt" "parted-move left WinRE"
  $PE load "${P#/dev/}" "$W/pm2.json"
  rsz=$(jget "$W/pm2.json" '.after[3].size'); end=$(jget "$W/pm2.json" '.end')
  $PE geom "$W/pm2.json" 3 $(( (end - rsz) / 2048 * 2048 )) "$rsz"
  cs=$(jget "$W/pm2.json" '.after[2].start'); rs=$(jget "$W/pm2.json" '.after[3].start')
  $PE geom "$W/pm2.json" 2 "$cs" $(( rs - cs ))
  $PE ops "$W/pm2.json" | sed 's/^/  step: /'
  # the C: this session just shrank is flagged for chkdsk by ntfsresize -
  # that flag is ours and must not stop it growing again
  [ "$($PE ops "$W/pm2.json" | cut -d' ' -f1 | tr '\n' ' ')" = "Move Grow " ] \
    && ok "parted-move: steps are move, then grow" || bad "parted-move: steps are not move, grow"
  csize=$(blockdev --getsize64 "$(part "$P" 3)")
  $PE apply "$W/pm2.json" --status "$W/s14"
  status_is "$W/s14" ok "parted-move right"
  [ "$(blockdev --getsize64 "$(part "$P" 3)")" -gt "$csize" ] && ok "parted-move: C: grew" || bad "parted-move: C: did not grow"
  check_files "$(part "$P" 3)" "$W/sums-p3.txt" "parted-move C: grown"
  check_files "$(part "$P" 4)" "$W/sums-p4.txt" "parted-move right WinRE"
fi

if want parted-format; then
  say "parted-format: Recovery formatted exFAT, EFI deleted"
  cp "$W/src.img" "$W/p3.img"; P=$(lo "$W/p3.img")
  $PE load "${P#/dev/}" "$W/pf.json"
  $PE format "$W/pf.json" 3 exfat SPARE
  $PE delete "$W/pf.json" 0
  $PE ops "$W/pf.json" | sed 's/^/  step: /'
  $PE apply "$W/pf.json" --status "$W/s15"
  status_is "$W/s15" ok parted-format
  [ "$(blkid -o value -s TYPE "$(part "$P" 4)")" = exfat ] && [ "$(blkid -o value -s LABEL "$(part "$P" 4)")" = SPARE ] \
    && ok "parted-format: exFAT SPARE" || bad "parted-format: not exFAT SPARE"
  [ -e "$(part "$P" 1)" ] && bad "parted-format: EFI still there" || ok "parted-format: EFI deleted"
  check_files "$(part "$P" 3)" "$W/sums-p3.txt" "parted-format C: untouched"
fi

if want parted-stop; then
  say "parted-stop: Q during a move waits for the move to finish"
  cp "$W/src.img" "$W/p4.img"; P=$(lo "$W/p4.img")
  $PE load "${P#/dev/}" "$W/pq.json"
  $PE size "$W/pq.json" 2 $((2048 * 1024 * 1024))
  cend=$(( $(jget "$W/pq.json" '.after[2].start') + $(jget "$W/pq.json" '.after[2].size') ))
  $PE geom "$W/pq.json" 3 "$cend" "$(jget "$W/pq.json" '.after[3].size')"
  $PE apply "$W/pq.json" --status "$W/s16" & pid=$!
  for _ in $(seq 1 600); do grep -q '^phase=move' "$W/s16" 2>/dev/null && break; sleep 0.05; done
  kill -TERM $pid; wait $pid
  r=$(sed -n 's/^result=//p' "$W/s16")
  case "$r" in stopped|ok) ok "parted-stop: result=$r" ;; *) bad "parted-stop: result=$r" ;; esac
  check_files "$(part "$P" 4)" "$W/sums-p4.txt" "parted-stop WinRE after the move"
fi

if want browse; then
  I="$W/img/2026-10-08-test-img"
  [ -d "$I" ] || bad "browse: run the backup case first"
  d=$(cat "$I/disk")
  say "browse: the partitions in the image; C: served read-only (NBD) and mounted"
  $IB parts "$I" | tee "$W/parts.txt"
  grep -q "^${d}p3|ntfs|[0-9]*|C: Windows|1|" "$W/parts.txt" && ok "browse: C: listed, can be opened" || bad "browse: C: cannot be opened"
  grep -q "^${d}p2|raw|[0-9]*|MSR|0|" "$W/parts.txt" && ok "browse: MSR listed as no files" || bad "browse: MSR not refused"
  N=$($IB attach "$I" "${d}p3") && ok "browse: served as $N" || bad "browse: attach failed"
  if [ -n "$N" ]; then
    [ "$(blockdev --getro "$N")" = 1 ] && ok "browse: $N is read-only" || bad "browse: $N is writable"
    $IB mount "$N" "$W/bm" >/dev/null && ok "browse: C: mounted" || bad "browse: C: did not mount"
    (cd "$W/bm" && sha256sum --quiet -c "$W/sums-p3.txt" >/dev/null 2>&1) \
      && ok "browse: every file on C: reads back out of the image ($(wc -l < "$W/sums-p3.txt") files)" \
      || bad "browse: files read from the image differ"
    $IB ls "$W/bm" | head -1 | grep -q '^d|' && ok "browse: folders listed first" || bad "browse: folders not first"
    rm -rf "$W/out"; mkdir -p "$W/out"
    $IB copy "$W/bm/Windows" "$W/out" --status "$W/s20"
    status_is "$W/s20" ok browse-copy
    cmp -s "$W/bm/Windows/System32/winload.efi" "$W/out/Windows/System32/winload.efi" \
      && ok "browse: the copied folder matches" || bad "browse: the copy differs"
    $IB copy "$W/bm/Windows" "$W/out" --status "$W/s21"
    [ -d "$W/out/Windows (2)" ] && ok "browse: a second copy goes to 'Windows (2)'" || bad "browse: the second copy overwrote the first"
    touch "$W/bm/x" 2>/dev/null && bad "browse: the mounted image took a write" || ok "browse: the mount is read-only"
    $IB close "$W/bm" "$N"
    mountpoint -q "$W/bm" && bad "browse: still mounted" || ok "browse: unmounted"
    [ -e "/sys/block/${N#/dev/}/pid" ] && bad "browse: $N still connected" || ok "browse: $N released"
    pgrep -f "imgbrowse.py serve" >/dev/null && bad "browse: the reader still runs" || ok "browse: the reader stopped"
  fi
  N=$($IB attach "$I" "${d}p1")
  if [ -n "$N" ] && $IB mount "$N" "$W/bm" >/dev/null \
      && (cd "$W/bm" && sha256sum --quiet -c "$W/sums-p1.txt" >/dev/null 2>&1); then
    ok "browse: EFI (FAT32) reads back"
  else
    bad "browse: EFI did not read back"
  fi
  [ -n "$N" ] && $IB close "$W/bm" "$N"
  # an index that lost a line would read the wrong bytes: refused instead
  cp -r "$I" "$W/img/badidx-img"; sed -i '$d' "$W/img/badidx-img/diag/${d}p3.idx"
  $IB parts "$W/img/badidx-img" | grep -q "^${d}p3|.*|0|the index does not match" \
    && ok "browse: an index that does not match is refused" || bad "browse: a wrong index was accepted"
  rm -rf "$W/img/badidx-img"
  src_same browse
fi

if want macrium; then
  # images Macrium Reflect 8 made of known test disks (1.23; on Ash's PC:
  # C:\Users\Ash\mrimg-test, made by make-mrimg.ps1 there) - their files'
  # checksums were taken when the disks were made
  MT=${MRIMG_TEST:-/mnt/c/Users/Ash/mrimg-test}
  if [ ! -f "$MT/out/gpt-c1-00-00.mrimg" ]; then
    say "macrium: no test images in $MT - skipped"
  else
    gcc -O2 -shared -fPIC -DCOMPRESSION_LEVEL=2 -Dmemory_safe -o "$W/libqlz.so" "$HERE/../toolkit/vendor/quicklz131.c"
    export DIAG_QLZ=$W/libqlz.so
    MR="python3 $HERE/../toolkit/mrimg.py"
    say "macrium: every compression level, GPT and MBR, read back file by file"
    for v in gpt-c0 gpt-c1 gpt-c2 mbr-c1; do
      I="$MT/out/$v-00-00.mrimg"; c=3; sums=gpt-c.md5
      case $v in mbr-*) c=2; sums=mbr-c.md5 ;; esac
      rm -f "$W/mrpart.img"
      $MR extract "$I" $c "$W/mrpart.img" && mkdir -p "$W/m" && ntfs-3g -o ro "$W/mrpart.img" "$W/m" \
        && (cd "$W/m" && md5sum --quiet -c "$MT/$sums" >/dev/null 2>&1) \
        && ok "macrium $v: C: reads back, every file matches" || bad "macrium $v: C: does not read back"
      umount -q "$W/m" 2>/dev/null
    done
    $MR info "$MT/out/gpt-split-00-00.mrimg" >/dev/null 2>"$W/mr.err"
    grep -q "split" "$W/mr.err" && ok "macrium: a split image is refused, with the reason" || bad "macrium: split image not refused"
    $MR verify "$MT/out/gpt-c1-00-00.mrimg" --status "$W/s30"
    status_is "$W/s30" ok "macrium verify"

    say "macrium: restore = the image served as a drive, then Clone's plan onto a smaller one"
    N=$($IB attach "$MT/out/gpt-c1-00-00.mrimg" disk) && ok "macrium: served as $N" || bad "macrium: not served"
    if [ -n "$N" ]; then
      [ "$(blockdev --getro "$N")" = 1 ] && ok "macrium: $N is read-only" || bad "macrium: $N is writable"
      $ENG scan "${N#/dev/}" > "$W/mrscan.json"
      T=$(fresh_target "$W/t30.img" 2600)
      $ENG plan "$W/mrscan.json" "${T#/dev/}" > "$W/plan30.json"
      jq -e '.ok' "$W/plan30.json" >/dev/null && ok "macrium: plan for a smaller drive" || bad "macrium: no plan"
      $ENG clone "$W/plan30.json" --status "$W/s31" --scratch /dev/shm
      status_is "$W/s31" ok "macrium restore"
      partx -u "$T" 2>/dev/null; sleep 1
      [ "$(sfdisk -d "$T" | sed -n 's/^label-id: //p')" = 6D9E2A1B-1111-4C22-8E33-ABCDEF012345 ] \
        && ok "macrium: the disk ID is the imaged one" || bad "macrium: disk ID differs"
      ntfs-3g -o ro "$(part "$T" 3)" "$W/m" && (cd "$W/m" && md5sum --quiet -c "$MT/gpt-c.md5" >/dev/null 2>&1) \
        && ok "macrium: every file on the restored C: matches" || bad "macrium: restored C: differs"
      umount -q "$W/m" 2>/dev/null
      $IB detach "$N"
      [ -e "/sys/block/${N#/dev/}/pid" ] && bad "macrium: $N still served" || ok "macrium: $N released"
    fi
    say "macrium: browse - C: opened out of the image, read-only"
    N=$($IB attach "$MT/out/gpt-c1-00-00.mrimg" 3)
    if [ -n "$N" ] && $IB mount "$N" "$W/bm" >/dev/null \
        && (cd "$W/bm" && md5sum --quiet -c "$MT/gpt-c.md5" >/dev/null 2>&1); then
      ok "macrium: browse - every file on C: reads back"
    else
      bad "macrium: browse failed"
    fi
    [ -n "$N" ] && $IB close "$W/bm" "$N"
    $IB parts "$MT/out/gpt-c1-00-00.mrimg" | grep -q "^2|raw|[0-9]*|MSR|0|" \
      && ok "macrium: MSR listed as no files" || bad "macrium: MSR not refused"
  fi
fi

if want stop; then
  say "stop: Q in the middle of a clone"
  T=$(fresh_target "$W/t8.img" 6000)
  $ENG plan "$W/scan.json" "${T#/dev/}" > "$W/plan8.json"
  $ENG clone "$W/plan8.json" --status "$W/s10" & pid=$!
  for _ in $(seq 1 60); do grep -q '^phase=copy' "$W/s10" 2>/dev/null && break; sleep 0.2; done
  sleep 0.5; kill -TERM $pid; wait $pid
  status_is "$W/s10" stopped stop
  [ "$(blockdev --getro "$SRC")" = 0 ] && ok "stop: source writable again afterwards" || bad "stop: source left read-only"
  pgrep -f 'partclone\.' >/dev/null && bad "stop: partclone still running" || ok "stop: no partclone left running"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAILS"
[ "$FAILS" = 0 ]
