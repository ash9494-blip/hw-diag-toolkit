#!/bin/bash
# Browse an image (Disk imaging item 6) - open a partition inside an image and
# copy files out of it: a customer's Documents back from a backup without
# restoring the whole drive. Ash's list: "Browse files in image".
#
# imgbrowse.py serves the partition straight out of the image as a read-only
# block device and mounts it read-only - nothing here writes the image or the
# drive it is on, except the folder the copied files go into (next to the
# image, or on another USB drive). Toolkit images only: Clonezilla's have no
# frame index and cannot be read in the middle (the partition list says so).
. /opt/diag/lib.sh
. /opt/diag/tui.sh
. /opt/diag/imglib.sh

IB="python3 /opt/diag/imgbrowse.py"
MNT=/mnt/diagbrowse
DEST_MNT=/mnt/diagcopy
NBD=""
DEST_OWNED=0

pick_part() {   # -> PART, PART_TITLE
  local name fs bytes title ok why i
  local -a names=() titles=() labels=() oks=() whys=()
  tui_frame "Reading ${IMAGE##*/}" ""; tui_line 6 "Looking at the partitions in the image..." muted; tui_flush
  while IFS='|' read -r name fs bytes title ok why; do
    names+=("$name"); titles+=("$title"); oks+=("$ok"); whys+=("$why")
    if [ "$ok" = 1 ]; then labels+=("$title|$fs|$(gbytes "$bytes")")
    else labels+=("$title|$fs|$(gbytes "$bytes")|cannot be opened"); fi
  done < <($IB parts "$IMAGE" 2>"$W/parts.err")
  if [ ${#names[@]} -eq 0 ]; then
    # the reason, when there is one (a partition-only Clonezilla image...)
    say_wrapped "Nothing to open" "$(tail -1 "$W/parts.err" | grep . || echo "This image holds no partition with files on it.")"
    return 1
  fi
  while :; do
    tui_menu "Which partition?" "in ${IMAGE##*/}" "${labels[@]}" || return 1
    i=$((TUI_CHOICE-1))
    if [ "${oks[$i]}" = 1 ]; then PART=${names[$i]}; PART_TITLE=${titles[$i]}; return 0; fi
    say_wrapped "${titles[$i]} cannot be opened" "${whys[$i]}"
  done
}

close_part() {
  [ -n "$NBD" ] && $IB close "$MNT" "$NBD" >>"$W/engine.out" 2>&1
  NBD=""
  return 0
}

# The partition, read-only at $MNT. A BitLocker partition saved locked (no
# key at backup time) is unlocked here with the recovery key - read-only.
open_part() {
  local rc id
  tui_frame "Opening $PART_TITLE" ""; tui_line 6 "Reading the image..." muted; tui_flush
  if ! NBD=$($IB attach "$IMAGE" "$PART" 2>>"$W/engine.out"); then
    NBD=""
    say_wrapped "Could not open $PART_TITLE" "$(tail -1 "$W/engine.out")"
    return 1
  fi
  $IB mount "$NBD" "$MNT" > "$W/mount.out" 2>&1; rc=$?
  if [ $rc = 4 ]; then
    id=$(bl_key_id "$NBD")
    tui_confirm "$PART_TITLE is locked with BitLocker" yes \
      "It was saved locked, so its files need the recovery key." \
      "The key: the customer's Microsoft account, aka.ms/myrecoverykey${id:+ - Key ID $id}" "" \
      "Type the key now?" && bl_key_entry "$NBD" "$PART_TITLE" \
      && { $IB mount "$NBD" "$MNT" > "$W/mount.out" 2>&1; rc=$?; }
  fi
  [ $rc = 0 ] && return 0
  [ $rc = 4 ] || say_wrapped "Could not open $PART_TITLE" "$(tail -1 "$W/mount.out")"
  close_part
  return 1
}

# ---------------------------------------------------------------- copying out
dest_done() {
  [ "$DEST_OWNED" = 1 ] && { sync; umount "$DEST_MNT" 2>/dev/null; }
  DEST_OWNED=0
  return 0
}

# Where copied files go: a folder named after the image, next to it on the
# same drive, or on another USB drive. Sets DEST (the folder), DEST_DESC.
pick_dest() {
  local i d
  store_list
  # every row two cells, the second short: a long folder name ran off the
  # card, and rows with more cells than the first lost them (VM, 1.21)
  local -a devs=("") labels=("Next to the image|on ${STORE_DESC%%  *}, in a folder named after the image")
  # not into OneDrive: odfs.py holds a file in memory until it is closed,
  # and a folder of small files would go up one slow request at a time
  if [ "$STORAGE_DEV" = onedrive ]; then
    devs=(); labels=()
    if [ ${#STORE_DEVS[@]} -eq 0 ]; then
      tui_msg "Copy to where?" "Files from an image on OneDrive are copied to a USB drive." "" \
        "Plug one in (exFAT, NTFS or FAT32), then choose Copy again."
      return 1
    fi
  fi
  for i in "${!STORE_DEVS[@]}"; do
    d=${STORE_DEVS[$i]}
    [ "$d" = "$STORAGE_DEV" ] && continue
    devs+=("$d"); labels+=("${STORE_LABELS[$i]%%|*}|$(cut -d'|' -f2- <<<"${STORE_LABELS[$i]}" | sed 's/|/  /g')")
  done
  tui_menu "Copy to where?" "the image's drive, or another USB drive plugged in now" "${labels[@]}" || return 1
  d=${devs[$((TUI_CHOICE-1))]}
  if [ -z "$d" ]; then
    if ! remount_storage_rw; then
      tui_msg "Cannot write there" "$STORE_DESC is read-only here. Plug in another USB drive and choose it."
      return 1
    fi
    DEST="$STORAGE_MNT/${IMAGE##*/}-files"; DEST_DESC="${IMAGE##*/}-files on $STORE_DESC"
  else
    mkdir -p "$DEST_MNT"
    mountpoint -q "$DEST_MNT" && umount -l "$DEST_MNT" 2>/dev/null
    # FAT names as UTF-8: the kernel's default (iso8859-1) cannot write a
    # Chinese file name at all
    local -a opts=()
    [ "$(lsblk -dno FSTYPE "$d" | tr -d ' ')" = vfat ] && opts=(-o utf8)
    if ! mount "${opts[@]}" "$d" "$DEST_MNT" 2>"$W/mount.out"; then
      say_wrapped "Cannot use $d" "$(tail -1 "$W/mount.out")"
      return 1
    fi
    DEST_OWNED=1
    DEST="$DEST_MNT/${IMAGE##*/}-files"; DEST_DESC="${IMAGE##*/}-files on ${labels[$((TUI_CHOICE-1))]//|/  }"
  fi
  mkdir -p "$DEST" 2>/dev/null && return 0
  tui_msg "Cannot write there" "The folder could not be made on that drive."
  dest_done
  return 1
}

win_path() {   # /mnt/diagbrowse/Users/Ash -> \Users\Ash
  local p=${1#"$MNT"}
  p=${p:-/}
  printf '%s' "${p//\//\\}"
}

copy_out() {   # path
  local src=$1 what name="" got
  pick_dest || return
  what=$(win_path "$src")
  [ "$src" = "$MNT" ] && name=$PART          # the whole partition: not "diagbrowse"
  rsection "IMAGE BROWSE -- ${IMAGE##*/}, $PART_TITLE"
  rsilent "Copy  : $what"
  rsilent "To    : $DEST_DESC"
  JOB_FROM="$PART_TITLE  $what"; JOB_TO=$DEST_DESC
  JOB_PROG=$IB run_job "Copying ${src##*/}" "The files copied so far stay; the one being copied is left half-done." \
    copy "$src" "$DEST" $name
  got=$(st dest); got=${got##*/}             # "Documents (2)" when one was there
  case "$JOB_RESULT" in
    ok)
      rsilent "Copied in $(secs_hms "$JOB_TIME") as ${got:-${src##*/}}"
      say_wrapped "Copied" "$what is now in the folder $DEST_DESC, as ${got:-${src##*/}}." "" \
        "Took $(secs_hms "$JOB_TIME")." ;;
    stopped)
      rsilent "Stopped by the operator"
      tui_msg "Stopped" "The files copied so far are in $DEST_DESC." ;;
    *)
      rsilent "Copy incomplete: $JOB_MSG"
      say_wrapped "Not everything was copied" "$JOB_MSG" "" \
        "What was copied is in $DEST_DESC${got:+, as $got}." ;;
  esac
  dest_done
}

file_menu() {   # path size date
  tui_menu "${1##*/}" "$2, $3" \
    "Copy it|to a USB drive, or next to the image" "Back|to the folder" || return
  [ "$TUI_CHOICE" = 1 ] && copy_out "$1"
}

# ---------------------------------------------------------------- the folders
# Q in a folder goes up one; Q at the top leaves the partition.
browse() {
  local dir=$MNT kind size date name hint i shown total
  local -a kinds=() names=() sizes=() dates=() labels=()
  while :; do
    kinds=(); names=(); sizes=(); dates=(); labels=(); shown=""; total=""
    while IFS='|' read -r kind size date name; do
      case "$kind" in
        d|f) kinds+=("$kind"); names+=("$name"); sizes+=("$size"); dates+=("$date")
             if [ "$kind" = d ]; then labels+=("${name//|//}|folder|$date")
             else labels+=("${name//|//}|$size|$date"); fi ;;
        more) shown=$size; total=$date ;;
        err) say_wrapped "Cannot read this folder" "$name"
             [ "$dir" = "$MNT" ] && return
             dir=${dir%/*}; continue 2 ;;
      esac
    done < <($IB ls "$dir")
    hint="Enter opens a folder - Q goes up"
    [ -n "$total" ] && hint="the first $shown of $total - Copy this folder takes them all"
    tui_menu "$PART_TITLE  $(win_path "$dir")" "$hint" \
      "Copy this folder|everything in it, with the folders inside" "${labels[@]}" || {
      [ "$dir" = "$MNT" ] && return
      dir=${dir%/*}
      continue
    }
    if [ "$TUI_CHOICE" = 1 ]; then copy_out "$dir"; continue; fi
    i=$((TUI_CHOICE-2))
    if [ "${kinds[$i]}" = d ]; then dir="$dir/${names[$i]}"
    else file_menu "$dir/${names[$i]}" "${sizes[$i]}" "${dates[$i]}"; fi
  done
}

trap 'close_part; dest_done; umount_storage' EXIT
pick_place "Browse an image from where?" "Browse an image on which drive?" || exit 0
store_mount ro || exit 0
pick_image || exit 0
while pick_part; do
  open_part || continue
  browse
  close_part
done
exit 0
