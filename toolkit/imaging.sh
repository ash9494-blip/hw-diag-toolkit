#!/bin/bash
# Disk imaging - clone a drive, back one up to an image, restore an image,
# check an image. Macrium Reflect's jobs, on the bench stick.
#
# The screens are here. The work is imgengine.py, run in the background with a
# status file between the two; where each partition goes is imgplan.py. The
# images are Clonezilla's format (imgfmt.py), so Clonezilla restores them too.
#
# Safety - the destructive disk tests' rules (invariant 5), and more:
#   * the drive about to be replaced is named, what is on it listed, default
#     NO, then ERASE typed;
#   * the drive being copied is set read-only in the kernel for the whole job
#     (imgengine.py). The only writes to it are ones the operator picks by
#     name: discarding a hibernated session, or shrinking C: on it - that one
#     only on a drive SMART calls healthy, and only after SHRINK is typed;
#   * the toolkit's own stick is never offered as a source or a target, and
#     an image is never written to the drive it is an image of.
. /opt/diag/lib.sh
. /opt/diag/tui.sh
. /opt/diag/imglib.sh     # drive picker, messages, run_job (shared with partitions.sh)

# ---------------------------------------------------------------- drives
scan_drive() {   # disk -> $W/scan-DISK.json
  tui_frame "Reading /dev/$1" ""
  tui_line 6 "Reading the partitions and how full each one is..." muted
  tui_flush
  if ! $ENG scan "$1" > "$W/scan-$1.json" 2>>"$W/engine.out"; then
    tui_msg "Could not read /dev/$1" "$(tail -1 "$W/engine.out" | cut -c1-90)"
    return 1
  fi
  if [ "$(jq '.parts | length' "$W/scan-$1.json")" = 0 ]; then
    tui_msg "Nothing on /dev/$1" "This drive has no partitions - there is nothing to copy."
    return 1
  fi
}

# ---------------------------------------------------------------- BitLocker
bl_ask() {   # node purpose(clone|backup) -> 0 when unlocked
  local node=$1 id effect
  id=$(bl_key_id "$node")
  if [ "$2" = backup ]; then effect="the image then holds the files unencrypted"
  else effect="BitLocker is then OFF on the new drive"; fi
  tui_menu "$node is locked with BitLocker" \
    "recovery key: the customer's Microsoft account, aka.ms/myrecoverykey${id:+ - Key ID $id}" \
    "Unlock with the recovery key|only the data is copied and C: can be resized - $effect" \
    "Leave it locked|every sector is copied at full size - BitLocker stays on" || return 1
  [ "$TUI_CHOICE" = 1 ] || return 1
  bl_key_entry "$node" "$node"
}

bitlocker_choices() {   # disk purpose
  local node changed=0
  while read -r node; do
    [ -n "$node" ] && bl_ask "$node" "$2" && changed=1
  done < <(jq -r '.parts[] | select(.state=="locked") | .node' "$W/scan-$1.json")
  [ "$changed" = 0 ] || scan_drive "$1"
}

# ---------------------------------------------------------------- Windows state
# A hibernated or check-flagged C: copies fine but cannot be resized. Offered
# only when resizing is what stands in the way, and named for what it does.
offer_fix() {   # disk plan -> 0 when the drive was changed (scan and plan again)
  local node state
  node=$(jq -r '.parts | max_by(.size) | select(.state=="hibernated" or .state=="dirty") | .node' "$W/scan-$1.json")
  [ -n "$node" ] || return 1
  [ "$(jq -r '.ok' "$2")" = true ] && [ "$(jq '.free_after < 1073741824' "$2")" = true ] && return 1
  state=$(jq -r '.parts | max_by(.size) | .state' "$W/scan-$1.json")
  if [ "$state" = hibernated ]; then
    tui_menu "Windows did not shut down fully" "Fast Startup or hibernation left a saved session on $node, so C: cannot be resized" \
      "Discard the saved session|writes to the old drive; Windows starts fresh - anything left open in it is lost" \
      "Leave it|start Windows, hold Shift while clicking Shut down, then come back" || return 1
    [ "$TUI_CHOICE" = 1 ] || return 1
    $ENG unhibernate "$node" > "$W/fix.out" 2>&1
  else
    tui_menu "C: is marked for a disk check" "Windows flagged $node to be checked, so it cannot be resized" \
      "Clear the flag (ntfsfix)|writes to the old drive - better: start Windows once and let it check" \
      "Leave it|start Windows, let the check finish, then come back" || return 1
    [ "$TUI_CHOICE" = 1 ] || return 1
    $ENG clear-dirty "$node" > "$W/fix.out" 2>&1
  fi || { tui_msg "That did not work" "$(tail -1 "$W/fix.out" | cut -c1-90)"; return 1; }
  return 0
}

# ---------------------------------------------------------------- the plan
# Both drives as Macrium draws them, then the table. The go-ahead is
# confirm_erase, which defaults to NO; E opens the sizes in the editor.
show_plan() {   # plan title old-caption new-caption
  local plan=$1 row num name fs old new how change shown l
  while :; do
    row=13; shown=0
    tui_frame "$2" "Enter = next   E = adjust sizes"
    tui_diskmap 6 "$3" "$($ENG mapspec "$plan" old)"
    tui_diskmap 9 "$4" "$($ENG mapspec "$plan" new)"
    tui_thead 12 "Partition" "Now" "After" "Copied as" "Change"
    while IFS='|' read -r num name fs old new how change; do
      [ $shown -ge 6 ] && break
      [ "$fs" = - ] || name="$name ($fs)"
      tui_trow $row "$name" "$old" "$new" "$how" "$change"
      row=$((row+1)); shown=$((shown+1))
    done < <($ENG rows "$plan")
    row=$((row+1))
    while IFS= read -r l; do
      [ $row -gt 22 ] && break
      row=$(tui_para $row "$l" muted 100)
    done < <(jq -r '.notes[]' "$plan")
    tui_flush
    tui_keys e
    [ "$TUI_KEY" = e ] || return 0
    adjust_plan "$plan" "$3" "$4"
  done
}

# The sizes on the new drive, changed by hand (Ash, 1.24: "when the system
# shows me the before and after clone size, I want to adjust the partitions
# from there"): the plan in the partition editor he picked (ui.py
# PlanEditor, imgplanedit.py). The plan is replaced only by one that
# imgplanedit.py has checked again; Q leaves it as it was.
PX="python3 /opt/diag/imgplanedit.py"
adjust_plan() {   # plan old-caption new-caption
  local plan=$1 e
  local -a why
  PE=$PX; STATE=$W/planedit.json
  if ! $PX open "$plan" "$STATE" "$2" "$3" "Sizes on the new drive" 2>>"$W/engine.out"; then
    tui_msg "Cannot open the sizes" "$(tail -1 "$W/engine.out" | cut -c1-90)"
    return
  fi
  e=$($PX problems "$STATE" | sed -n 's/^E|//p' | head -1)
  if [ -n "$e" ]; then say_wrapped "The sizes cannot be changed" "$e"; return; fi
  while :; do
    tui_planedit "$STATE"
    [ "$PE_ANSWER" = text ] && text_editor "Sizes on the new drive" "Use these sizes" "back to the plan"
    case "$PE_ANSWER" in
      apply)
        if $PX done "$STATE" "$W/plan.edit.json" > "$W/planedit.err" 2>&1; then
          mv -f "$W/plan.edit.json" "$plan"
          return
        fi
        mapfile -t why < "$W/planedit.err"
        say_wrapped "These sizes cannot be used" "${why[@]}" ;;
      new\|*)  new_partition "${PE_ANSWER#new|}" ;;
      size\|*) exact_size "${PE_ANSWER#size|}" ;;
      menu\|*) plan_part_menu "${PE_ANSWER#menu|}" ;;
      *)
        [ "$(jq '.history | length' "$STATE")" = 0 ] && return
        tui_confirm "Leave without using these sizes?" no "The plan keeps the sizes it had." "" "Leave?" && return ;;
    esac
  done
}

plan_part_menu() {   # index - Enter on a partition in the sizes editor
  info "$1"
  if [ "$INFO_NEW" != 1 ]; then exact_size "$1"; return; fi
  tui_menu "$INFO_NAME" "$INFO_FS, $(gbytes "$INFO_SIZE") - made empty after the copy" \
    "Exact size|type the size in GB" "Remove|it is not made" "Back|to the drive" || return
  case "$TUI_CHOICE" in
    1) exact_size "$1" ;;
    2) $PE delete "$STATE" "$1" ;;
  esac
}

refused() {   # plan
  local -a e; mapfile -t e < <(jq -r '.errors[]' "$1")
  say_wrapped "This will not work" "${e[@]}"
}

confirm_erase() {   # disk
  local -a now
  if lsblk -rno MOUNTPOINT "/dev/$1" | grep -q .; then
    tui_msg "Drive in use" "Something on /dev/$1 is mounted. Restart the toolkit, or unmount it."
    return 1
  fi
  mapfile -t now < <(lsblk -no NAME,SIZE,FSTYPE,LABEL "/dev/$1" | sed 's/  */ /g' | head -7)
  tui_confirm "Replace everything on /dev/$1?" no "$(drive_desc "$1")" "" \
    "Everything on it now is destroyed:" "${now[@]}" "" "Continue?" || return 1
  tui_input "Final confirmation" "Type ERASE to replace everything on /dev/$1:"
  # case-insensitive: the safeguard is typing the word, not the Shift key
  [ "$(upper "$TUI_TEXT")" = ERASE ] && return 0
  tui_msg "Cancelled" "Nothing was written."
  return 1
}

# ---------------------------------------------------------------- scratch for a shrink
# Data past the new end of C: needs somewhere to wait while C: is shrunk
# (imgengine composite): this laptop's memory when it fits, else a USB drive,
# else - a clone only, and only if the operator says so - C: on the old drive
# itself. Sets SCRATCH_OPT.
SCRATCH_MNT=/mnt/diagscratch
pick_scratch() {   # plan imgdir-or-"" purpose(clone|restore) skip-disk...
  local plan=$1 imgdir=$2 purpose=$3 need ram shm; shift 3
  SCRATCH_OPT=()
  tui_frame "Working out the shrink" ""; tui_line 6 "Counting the data that has to move..." muted; tui_flush
  need=$($ENG shrink-need "$plan" ${imgdir:+"$imgdir"} 2>>"$W/engine.out")
  [ "${need:-0}" -gt 0 ] || return 0
  ram=$(( ($(mem_avail_mb) - 768) * 1048576 ))
  shm=$(df -B1 --output=avail /dev/shm | tail -1)
  if [ "$need" -le "$ram" ] && [ "$need" -le "$shm" ]; then SCRATCH_OPT=(--scratch /dev/shm); return 0; fi
  local -a opts=("Use a USB drive for it|needs $(gbytes "$need") free; nothing on it is changed")
  [ "$purpose" = clone ] && opts+=("Shrink C: on the old drive first|writes to the customer's drive - only if it is healthy")
  tui_menu "C: has $(gbytes "$need") of data to move" \
    "too much for this laptop's memory ($(gbytes "$ram") free)" "${opts[@]}" || return 1
  if [ "$TUI_CHOICE" = 2 ]; then
    source_shrink_ok "$(jq -r .source "$plan")" && SCRATCH_OPT=(--source-shrink) && return 0
    return 1
  fi
  scratch_on_usb "$need" "$@"
}

scratch_on_usb() {   # need skip-disk...
  local need=$1 dev free at keep=$STORAGE_DEV keepd=$STORE_DESC; shift
  pick_store "Scratch space - which USB drive?" "$@" || return 1
  dev=$STORAGE_DEV; STORAGE_DEV=$keep; STORE_DESC=$keepd
  mkdir -p "$SCRATCH_MNT"; umount -q "$SCRATCH_MNT" 2>/dev/null
  at=$(findmnt -rno TARGET --source "$dev" | head -1)
  if [ -z "$at" ]; then
    mount "$dev" "$SCRATCH_MNT" 2>"$W/mnt.err" || { tui_msg "Cannot use $dev" "$(head -1 "$W/mnt.err")"; return 1; }
    at=$SCRATCH_MNT
  fi
  free=$(df -B1 --output=avail "$at" | tail -1)
  if [ "$free" -lt "$need" ]; then
    tui_msg "Not enough room" "$dev has $(gbytes "$free") free; the shrink needs $(gbytes "$need")."
    scratch_done
    return 1
  fi
  SCRATCH_OPT=(--scratch "$at")
}

scratch_done() { mountpoint -q "$SCRATCH_MNT" && umount "$SCRATCH_MNT" 2>/dev/null; return 0; }

source_shrink_ok() {   # source disk
  local h
  h=$(smartctl -H "/dev/$1" 2>&1 | grep -iE 'overall-health|SMART Health Status' | head -1)
  if ! printf '%s' "$h" | grep -qiE 'PASSED|OK'; then
    say_wrapped "Not on this drive" \
      "The old drive does not report itself healthy (${h:-no SMART answer}). Shrinking C: on it could lose the customer's data." "" \
      "Use a USB drive for the scratch space instead, or shrink C: in Windows Disk Management."
    return 1
  fi
  tui_confirm "Shrink C: on the old drive?" no \
    "The drive reports itself healthy (SMART: PASSED)." "" \
    "C:'s data is moved down and C: shrunk, as Windows Disk Management would." \
    "After the copy, C: on the old drive is grown back to its full size." \
    "Windows on the old drive then checks the disk once on its next start." "" "Go ahead?" || return 1
  tui_input "Final confirmation" "Type SHRINK to let the toolkit write to the old drive:"
  [ "$(upper "$TUI_TEXT")" = SHRINK ]
}

# ---------------------------------------------------------------- reporting
report_plan() {   # plan
  local num name fs old new how change
  while IFS='|' read -r num name fs old new how change; do
    rsilent "$(printf '  %-3s %-26s %-6s %10s -> %-10s %-14s %s' "$num" "$name" "$fs" "$old" "$new" "$how" "$change")"
  done < <($ENG rows "$1")
  [ "$(jq -r '.edited // false' "$1")" = true ] && rsilent "  Sizes set by hand on the plan screen."
  jq -r '.notes[]' "$1" | sed 's/^/  Note: /' >> "$REPORT_TXT"
}

job_result() {   # what detail next-step...
  local what=$1 detail=$2 took row=9 l; shift 2
  took=$(secs_hms "${JOB_TIME:-0}")
  case "$JOB_RESULT" in
    ok)
      # Clone and restore always read the copy back; a backup only when the
      # operator said yes to the check (VM, 1.21: "read back" after a No)
      if [ "${JOB_READBACK:-1}" = 1 ]; then
        rsilent "RESULT: PASS -- $what of $detail finished and read back in $took"
      else
        rsilent "RESULT: PASS -- $what of $detail finished in $took (not read back - Check an image does that)"
      fi
      set_kv IMAGING_RESULT "PASS ($what, $took)"
      tui_frame "$what finished" "Enter to go back"
      # the detail can be a long folder name: its own wrapped line, not the badge's
      if [ "${JOB_READBACK:-1}" = 1 ]; then tui_badge 6 PASS "copied and read back in $took"
      else tui_badge 6 PASS "saved in $took - not read back yet"; fi
      row=$(tui_para 8 "$detail" muted 100); row=$((row+1))
      for l in "$@"; do row=$(tui_para $row "$l" "" 100); done
      if [ -f "$W/plan.json" ]; then
        while IFS= read -r l; do row=$(tui_para $((row+1)) "$l" muted 100); done \
          < <(jq -r '.notes[]?' "$W/plan.json" | grep -E 'BitLocker|checks the disk')
      fi
      tui_flush; tui_anykey ;;
    stopped)
      rsilent "RESULT: STOPPED -- $what of $detail stopped by the operator after $took"
      set_kv IMAGING_RESULT "STOPPED ($what)"
      tui_msg "$what stopped" "Stopped after $took." "Whatever was being written is incomplete - do not use it." ;;
    *)
      rsilent "RESULT: FAIL -- $what of $detail: $JOB_MSG"
      set_kv IMAGING_RESULT "FAIL ($what)"
      tail -15 "$RUN_DIR/imaging.log" 2>/dev/null | sed 's/^/  /' >> "$REPORT_TXT"
      say_wrapped "$what failed" "$JOB_MSG" "" \
        "The last steps are in the report and in the Toolkit log (power menu)." ;;
  esac
}

# ---------------------------------------------------------------- clone
plan_clone() {   # src tgt -> $W/plan.json, ok
  $ENG plan "$W/scan-$1.json" "$2" > "$W/plan.json" 2>>"$W/engine.out" || return 1
  if offer_fix "$1" "$W/plan.json"; then
    scan_drive "$1" || return 1
    $ENG plan "$W/scan-$1.json" "$2" > "$W/plan.json" 2>>"$W/engine.out" || return 1
  fi
  [ "$(jq -r .ok "$W/plan.json")" = true ] && return 0
  refused "$W/plan.json"
  return 1
}

clone_flow() {
  local src tgt
  rm -f "$W/plan.json"
  pick_drive "Clone - copy FROM which drive?" "the drive with Windows and the customer's files - it is only read" || return
  src=$DRIVE
  scan_drive "$src" || return
  bitlocker_choices "$src" clone
  pick_drive "Clone - copy TO which drive?" "the new drive - everything on it will be replaced" "$src" || return
  tgt=$DRIVE
  plan_clone "$src" "$tgt" || return
  show_plan "$W/plan.json" "Clone /dev/$src to /dev/$tgt" "Old drive  $(drive_desc "$src")" \
    "New drive  $(drive_desc "$tgt")"
  confirm_erase "$tgt" || return
  pick_scratch "$W/plan.json" "" clone "$src" "$tgt" || return
  rsection "DISK CLONE -- /dev/$src to /dev/$tgt"
  rsilent "From : $(drive_desc "$src")"
  rsilent "To   : $(drive_desc "$tgt")"
  report_plan "$W/plan.json"
  JOB_FROM=$(drive_desc "$src"); JOB_TO=$(drive_desc "$tgt"); JOB_DEVS="$src $tgt"
  run_job "Cloning /dev/$src to /dev/$tgt" \
    "The new drive is left half-copied - clone it again before using it." \
    clone "$W/plan.json" "${SCRATCH_OPT[@]}"
  scratch_done
  $ENG bl-close >/dev/null 2>&1
  job_result "Clone" "/dev/$src to /dev/$tgt" \
    "Shut down, fit the new drive in place of the old one, and start the laptop." \
    "Keep the old drive out until Windows has started from the new one - they share a disk ID."
}

# ---------------------------------------------------------------- back up
backup_flow() {
  local src est free name dir fs where
  local -a split=()
  rm -f "$W/plan.json"
  pick_drive "Back up which drive?" "the drive is only read" || return
  src=$DRIVE
  scan_drive "$src" || return
  bitlocker_choices "$src" backup
  pick_place "Save the image where?" "Which USB drive?" "$src" || return
  store_mount || return
  est=$(jq '[.parts[] | if (.fs != "" and .fs != "bitlocker" and .used != null) then .used else .size * 512 end] | add' "$W/scan-$src.json")
  free=$(df -B1 --output=avail "$STORAGE_MNT" | tail -1)
  if [ "$free" -lt $(( est / 2 )) ]; then
    tui_msg "Not enough room" "$STORE_DESC has $(gbytes "$free") free." \
      "The drive holds $(gbytes "$est") of data - even compressed it will not fit."
    umount_storage; return
  fi
  fs=$(lsblk -dno FSTYPE "$STORAGE_DEV" 2>/dev/null | tr -d ' ')
  [ "$fs" = vfat ] && split=(--split-mb 4000)       # FAT32 stops at 4 GB a file
  # OneDrive takes a file whole once it is closed, and until then odfs.py
  # holds it in this laptop's memory: pieces of 256 MB
  [ "$STORAGE_DEV" = onedrive ] && split=(--split-mb 256)
  # model and serial, cut short: QEMU's model alone ran past the screen edge
  name="$(date +%Y-%m-%d-%H%M)-$(machine_tag | cut -c1-40)-img"
  where=$name
  [ "$STORAGE_DEV" = onedrive ] && where="Disk images/$name"   # where onedrive.py looks first
  dir="$STORAGE_MNT/$where"
  tui_confirm "Back up /dev/$src?" yes "$(drive_desc "$src")" "" "To      $STORE_DESC" \
    "Folder  $where" "Data    $(gbytes "$est") to read, $(gbytes "$free") free there" \
    "$( [ "$free" -lt "$est" ] && echo "It may not fit - that depends how well the data compresses.")" "" "Start?" \
    || { umount_storage; return; }
  rsection "DISK BACKUP -- /dev/$src"
  rsilent "Drive  : $(drive_desc "$src")"
  rsilent "Image  : $where on $STORE_DESC"
  JOB_FROM=$(drive_desc "$src"); JOB_TO="$name on $STORE_DESC"
  JOB_DEVS="$src $(store_io)"
  run_job "Backing up /dev/$src" "The image folder is left incomplete - delete it." \
    backup "$W/scan-$src.json" "$dir" --machine "$(dmi system-manufacturer) $(dmi system-product-name), S/N $(dmi system-serial-number)" "${split[@]}"
  $ENG bl-close >/dev/null 2>&1
  if [ "$JOB_RESULT" = ok ] && [ "$STORAGE_DEV" = onedrive ] && ! od_sync; then
    JOB_RESULT=failed; JOB_MSG="the image's last files did not reach OneDrive: $OD_ERR"
  fi
  JOB_READBACK=0
  if [ "$JOB_RESULT" = ok ] && tui_confirm "Backup saved" yes "Saved in $(secs_hms "$JOB_TIME"): $name" "" \
       "Read it back now and test every checksum?" "That takes about as long again, and proves the image restores."; then
    local took=$JOB_TIME
    run_job "Checking the new image" "Only the check stops - the image is kept." verify "$dir"
    [ "$JOB_RESULT" = ok ] || JOB_MSG="the image was saved, but reading it back failed: $JOB_MSG"
    JOB_TIME=$(( took + JOB_TIME ))
    JOB_READBACK=1
  fi
  sync; umount_storage
  job_result "Backup" "/dev/$src to $name" "The image is in the folder $where on $STORE_DESC." \
    "Restore it with this toolkit or with Clonezilla."
  JOB_READBACK=1
}

# ---------------------------------------------------------------- Macrium images
# A Macrium Reflect 7/8 image (Ash's old backups, 1.23: "all of my previous
# image is failed to load") is served as the drive it was imaged from -
# read-only, every block checked against the MD5 the image keeps (mrimg.py,
# through imgbrowse.py's NBD reader) - and restored by Clone's own plan,
# resize and read-back. Nothing is offered to fix in it: an image cannot be
# written, so a hibernated or flagged C: inside one is copied at full size.
IB="python3 /opt/diag/imgbrowse.py"
MR_NBD=""
mr_detach() { [ -n "$MR_NBD" ] && $IB detach "$MR_NBD" >>"$W/engine.out" 2>&1; MR_NBD=""; return 0; }

macrium_restore() {   # store-disk
  local sdisk=$1 src tgt
  tui_frame "Opening ${IMAGE##*/}" ""; tui_line 6 "Reading the Macrium image's index..." muted; tui_flush
  if ! MR_NBD=$($IB attach "$IMAGE" disk 2>"$W/mr.err"); then
    MR_NBD=""
    say_wrapped "Cannot open ${IMAGE##*/}" "$(tail -1 "$W/mr.err")"
    return
  fi
  src=${MR_NBD#/dev/}
  scan_drive "$src" || { mr_detach; return; }
  pick_drive "Restore TO which drive?" "everything on it will be replaced" "$sdisk" || { mr_detach; return; }
  tgt=$DRIVE
  $ENG plan "$W/scan-$src.json" "$tgt" > "$W/plan.json" 2>>"$W/engine.out"
  if [ ! -s "$W/plan.json" ]; then
    say_wrapped "Cannot plan the restore" "$(tail -1 "$W/engine.out")"; mr_detach; return
  fi
  if [ "$(jq -r .ok "$W/plan.json")" != true ]; then
    # the plan's own advice (start Windows, shut it down fully...) is for a
    # drive - an image cannot be changed
    local -a e; mapfile -t e < <(jq -r '.errors[]' "$W/plan.json")
    say_wrapped "This will not work" "${e[@]}" "" \
      "A Macrium image cannot be changed here: restore it to a drive at least as big as the one it was made from ($(gbytes "$(blockdev --getsize64 "$MR_NBD")")), or fix Windows on that laptop and make the image again."
    mr_detach; return
  fi
  show_plan "$W/plan.json" "Restore a Macrium image to /dev/$tgt" "In the image  ${IMAGE##*/}" \
    "On $(drive_desc "$tgt")"
  confirm_erase "$tgt" && pick_scratch "$W/plan.json" "" restore "$tgt" "$sdisk" || { mr_detach; return; }
  rsection "DISK RESTORE (Macrium image) -- ${IMAGE##*/} to /dev/$tgt"
  rsilent "Image : ${IMAGE##*/} on $STORE_DESC"
  rsilent "To    : $(drive_desc "$tgt")"
  report_plan "$W/plan.json"
  JOB_FROM="${IMAGE##*/} on $STORE_DESC"; JOB_TO=$(drive_desc "$tgt"); JOB_DEVS="$tgt $(store_io)"
  run_job "Restoring to /dev/$tgt" "The drive is left half-written - restore it again before using it." \
    clone "$W/plan.json" "${SCRATCH_OPT[@]}"
  scratch_done; mr_detach
  job_result "Restore" "${IMAGE##*/} to /dev/$tgt" \
    "Shut down, fit the drive, and start the laptop from it."
}

# ---------------------------------------------------------------- restore / check
restore_flow() {
  local tgt sdisk
  rm -f "$W/plan.json"
  pick_place "Restore from where?" "Restore from which drive?" || return
  store_mount ro || return
  sdisk=$(store_parent "$STORAGE_DEV")
  pick_image || { umount_storage; return; }
  if [ -f "$IMAGE" ]; then macrium_restore "$sdisk"; umount_storage; return; fi
  pick_drive "Restore TO which drive?" "everything on it will be replaced" "$sdisk" \
    || { umount_storage; return; }
  tgt=$DRIVE
  $ENG plan-restore "$IMAGE" "$tgt" > "$W/plan.json" 2>>"$W/engine.out"
  if [ "$(jq -r .ok "$W/plan.json")" != true ]; then refused "$W/plan.json"; umount_storage; return; fi
  show_plan "$W/plan.json" "Restore an image to /dev/$tgt" "In the image  ${IMAGE##*/}" \
    "On $(drive_desc "$tgt")"
  confirm_erase "$tgt" && pick_scratch "$W/plan.json" "$IMAGE" restore "$tgt" "$sdisk" \
    || { umount_storage; return; }
  rsection "DISK RESTORE -- ${IMAGE##*/} to /dev/$tgt"
  rsilent "Image : ${IMAGE##*/} on $STORE_DESC"
  rsilent "To    : $(drive_desc "$tgt")"
  report_plan "$W/plan.json"
  JOB_FROM="${IMAGE##*/} on $STORE_DESC"; JOB_TO=$(drive_desc "$tgt"); JOB_DEVS="$tgt $(store_io)"
  run_job "Restoring to /dev/$tgt" "The drive is left half-written - restore it again before using it." \
    restore "$IMAGE" "$W/plan.json" "${SCRATCH_OPT[@]}"
  scratch_done; umount_storage
  job_result "Restore" "${IMAGE##*/} to /dev/$tgt" \
    "Shut down, fit the drive, and start the laptop from it."
}

verify_flow() {
  rm -f "$W/plan.json"
  pick_place "Check an image from where?" "Check an image on which drive?" || return
  store_mount ro || return
  pick_image || { umount_storage; return; }
  rsection "IMAGE CHECK -- ${IMAGE##*/}"
  JOB_FROM="${IMAGE##*/} on $STORE_DESC"; JOB_TO=""; JOB_DEVS=$(store_io)
  local prog=""
  [ -f "$IMAGE" ] && prog="python3 /opt/diag/mrimg.py"     # a Macrium image: its own checksums
  JOB_PROG=$prog run_job "Checking ${IMAGE##*/}" "Only the check stops - the image is not changed." \
    verify "$IMAGE"
  umount_storage
  job_result "Check" "${IMAGE##*/}" "Every partition read back and every checksum matched."
}

# ---------------------------------------------------------------- menu
od_restore                  # OneDrive's sign-in and app IDs from the stick, before any store is mounted
while :; do
  od="OneDrive|sign in, to back up to it and restore from it"
  who=$(od_who) && od="OneDrive|signed in as $who - sign out"
  tui_menu "Disk imaging" "clone, back up and restore whole drives - arrows + Enter, Q to go back" \
    "Clone a drive|old drive to new, C: resized to fit - like Macrium's Clone this disk" \
    "Back up to an image|the whole drive into a folder on a USB drive, this stick or OneDrive" \
    "Restore an image|an image onto this drive or a new one, resized to fit" \
    "Check an image|read an image back and test every checksum" \
    "Partitions|split C:, resize, move, make new ones - drag and drop" \
    "Browse an image|open a partition in an image and copy files out of it" "$od" || break
  case "$TUI_CHOICE" in
    1) clone_flow ;;
    2) backup_flow ;;
    3) restore_flow ;;
    4) verify_flow ;;
    5) /opt/diag/partitions.sh ;;
    6) /opt/diag/imgbrowse.sh ;;
    7) od_menu ;;
  esac
done
$ENG bl-close >/dev/null 2>&1
od_close
exit 0
