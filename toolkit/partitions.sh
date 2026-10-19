#!/bin/bash
# Partitions - split C:, resize, move, make new partitions in free space,
# delete, format (Disk imaging -> Partitions). Ash: "able to drag and drop
# partition, create partition on unallocated space".
#
# The drive is drawn twice, now and as it will be (ui.py PartEditor - his
# pick of three samples); the After bar is dragged. Nothing is written until
# Apply, which lists every step in the order it runs, defaults to NO, and
# then wants a word typed: ERASE when anything is deleted or formatted
# (invariant 5), APPLY otherwise. The work is imgparted.py, in the
# background like a clone, with the same status screen.
. /opt/diag/lib.sh
. /opt/diag/tui.sh
. /opt/diag/imglib.sh

PE="python3 /opt/diag/imgparted.py"
STATE=$W/parted.json

load_drive() {   # disk
  tui_frame "Reading /dev/$1" ""
  tui_line 6 "Reading the partitions and how far each one can shrink..." muted
  tui_flush
  if ! $PE load "$1" "$STATE" 2>>"$W/engine.out"; then
    tui_msg "Could not read /dev/$1" "$(tail -1 "$W/engine.out" | cut -c1-90)"
    return 1
  fi
  local e; e=$($PE problems "$STATE" | sed -n 's/^E|//p' | head -1)
  if [ -n "$e" ] && grep -q extended <<<"$e"; then
    say_wrapped "Not on this drive" "$e"
    return 1
  fi
}

info() {   # index -> INFO_NAME INFO_FS INFO_SIZE INFO_MIN INFO_RESIZE INFO_MOVE INFO_WHY INFO_MAX
  IFS='|' read -r INFO_NAME INFO_FS INFO_SIZE INFO_MIN INFO_RESIZE INFO_MOVE INFO_WHY INFO_MAX \
    < <($PE info "$STATE" "$1")
}

pick_fs() {   # title hint -> FS
  tui_menu "$1" "$2" \
    "NTFS|a Windows drive (D:) - the usual choice" \
    "exFAT|for files shared with Mac or kept on a stick" \
    "FAT32|small and simple - anything reads it, 4 GB per file at most" \
    "ext4|Linux" || return 1
  FS=$(sed -n "${TUI_CHOICE}p" <<<$'ntfs\nexfat\nvfat\next4')
}

ask_label() {   # what -> LABEL
  tui_input "Name for $1" "A name Windows shows for it (letters and numbers), blank for none:"
  LABEL=$TUI_TEXT
}

new_partition() {   # gap index
  local g=$1 size gsz mb
  gsz=$($PE gaps "$STATE" | awk -F'|' -v g="$g" '$1 == g {print $3}')
  [ -n "$gsz" ] || return
  gsz=$(( gsz * $(jq -r .disk.sector "$STATE") ))
  pick_fs "New partition - which kind?" "in the free space ($(gbytes "$gsz"))" || return
  ask_label "the new partition"
  tui_menu "New partition - how big?" "the free space is $(gbytes "$gsz")" \
    "All of it|$(gbytes "$gsz")" "Choose a size|in GB" || return
  mb=""
  if [ "$TUI_CHOICE" = 2 ]; then
    tui_input "Size" "Size in GB (up to $(gbytes "$gsz" | sed 's/ GB//')):"
    size=$(printf '%s' "$TUI_TEXT" | tr -cd '0-9.')
    [ -n "$size" ] || return
    mb=$(awk -v g="$size" 'BEGIN{printf "%d", g * 1024}')
  fi
  $PE new "$STATE" "$g" "$FS" "$LABEL" $mb 2>>"$W/engine.out" \
    || tui_msg "Could not add it" "$(tail -1 "$W/engine.out" | cut -c1-90)"
}

format_partition() {   # index
  info "$1"
  pick_fs "Format $INFO_NAME - as which kind?" "everything on it is erased when you Apply" || return
  ask_label "$INFO_NAME"
  tui_confirm "Format $INFO_NAME?" no "$INFO_NAME ($INFO_FS, $(gbytes "$INFO_SIZE"))" "" \
    "Everything on it is erased when you Apply." "Nothing happens until then." "" "Format it?" || return
  $PE format "$STATE" "$1" "$FS" "$LABEL"
}

exact_size() {   # index
  local gb bytes
  info "$1"
  if [ "$INFO_RESIZE" != 1 ]; then
    say_wrapped "$INFO_NAME keeps its size" "$INFO_WHY"
    return
  fi
  tui_input "Size of $INFO_NAME" "Size in GB, from $(gbytes "$INFO_MIN") to $(gbytes "$INFO_MAX") (now $(gbytes "$INFO_SIZE")):"
  gb=$(printf '%s' "$TUI_TEXT" | tr -cd '0-9.')
  [ -n "$gb" ] || return
  bytes=$(awk -v g="$gb" 'BEGIN{printf "%d", g * 1073741824}')
  $PE size "$STATE" "$1" "$bytes"
}

part_menu() {   # index
  info "$1"
  tui_menu "$INFO_NAME" "$INFO_FS, $(gbytes "$INFO_SIZE")" \
    "Exact size|type the size in GB" "Delete|its files are erased when you Apply" \
    "Format|erase it and start it fresh" "Back|to the drive" || return
  case "$TUI_CHOICE" in
    1) exact_size "$1" ;;
    2) $PE delete "$STATE" "$1" ;;
    3) format_partition "$1" ;;
  esac
}

on_battery() {   # 0 when a battery is there and no charger is
  local s ac=0 bat=0
  for s in /sys/class/power_supply/*; do
    case "$(cat "$s/type" 2>/dev/null)" in
      Mains) [ "$(cat "$s/online" 2>/dev/null)" = 1 ] && ac=1 ;;
      Battery) bat=1 ;;
    esac
  done
  [ "$bat" = 1 ] && [ "$ac" = 0 ]
}

apply_changes() {   # disk -> 0 when the drive was changed
  local disk=$1 word=APPLY l
  local -a steps=() warns=() errs=() lines=()
  mapfile -t steps < <($PE ops "$STATE")
  mapfile -t errs < <($PE problems "$STATE" | sed -n 's/^E|//p')
  mapfile -t warns < <($PE problems "$STATE" | sed -n 's/^W|//p')
  [ ${#steps[@]} -gt 0 ] || return 1
  if [ ${#errs[@]} -gt 0 ]; then say_wrapped "This cannot be applied" "${errs[@]}"; return 1; fi
  if printf '%s\n' "${steps[@]}" | grep -q '^Move' && on_battery; then
    warns=("The laptop is on battery. Plug the charger in before a move." "${warns[@]}")
  fi
  printf '%s\n' "${steps[@]}" | grep -qE '^(Delete|Format)' && word=ERASE
  for l in "${steps[@]}"; do lines+=("$(( ${#lines[@]} + 1 )).  $l"); done
  tui_confirm "Apply ${#steps[@]} change(s) to /dev/$disk?" no "$(drive_desc "$disk")" "" "${lines[@]}" "" \
    "${warns[@]}" "" "Go ahead?" || return 1
  tui_input "Final confirmation" "Type $word to change the partitions on /dev/$disk:"
  if [ "$(upper "$TUI_TEXT")" != "$word" ]; then tui_msg "Cancelled" "Nothing was written."; return 1; fi
  rsection "PARTITIONS -- /dev/$disk"
  rsilent "Drive : $(drive_desc "$disk")"
  for l in "${steps[@]}"; do rsilent "  $l"; done
  JOB_FROM=""; JOB_TO=$(drive_desc "$disk")
  JOB_PROG=$PE run_job "Changing the partitions on /dev/$disk" \
    "A move that has started finishes first; the steps after it are not done." apply "$STATE"
  case "$JOB_RESULT" in
    ok)
      rsilent "RESULT: PASS -- ${#steps[@]} partition change(s) on /dev/$disk done in $(secs_hms "$JOB_TIME")"
      set_kv PARTITION_RESULT "PASS (${#steps[@]} changes)"
      tui_msg "Partitions changed" "All ${#steps[@]} step(s) done in $(secs_hms "$JOB_TIME"), and the table checked." "" \
        "${warns[@]}" ;;
    stopped)
      rsilent "RESULT: STOPPED -- partition changes on /dev/$disk stopped by the operator"
      set_kv PARTITION_RESULT "STOPPED"
      tui_msg "Stopped" "The steps up to the one running when Q was pressed are done; the rest are not." ;;
    *)
      rsilent "RESULT: FAIL -- partition changes on /dev/$disk: $JOB_MSG"
      set_kv PARTITION_RESULT "FAIL"
      tail -15 "$RUN_DIR/imaging.log" 2>/dev/null | sed 's/^/  /' >> "$REPORT_TXT"
      say_wrapped "That did not finish" "$JOB_MSG" "" \
        "The drive now holds the steps that finished. The editor reads it again, so you can see it as it is." ;;
  esac
  return 0
}

text_editor() {   # the menu version, when there is no framebuffer to drag on
  local kind i rest
  local -a keys=() labels=()
  while IFS='|' read -r kind i rest; do
    keys+=("$kind|$i"); labels+=("${rest//|/  }")
  done < <($PE items "$STATE")
  tui_menu "Partitions - /dev/$DISK" "no dragging in the text screen - choose one" \
    "${labels[@]}" "Apply the changes|$($PE ops "$STATE" | wc -l) waiting" || { PE_ANSWER=back; return; }
  if [ "$TUI_CHOICE" -gt ${#keys[@]} ]; then PE_ANSWER=apply; return; fi
  kind=${keys[$((TUI_CHOICE-1))]%%|*}; i=${keys[$((TUI_CHOICE-1))]#*|}
  if [ "$kind" = gap ]; then PE_ANSWER="new|$i"; else PE_ANSWER="menu|$i"; fi
}

edit_drive() {
  local n
  while :; do
    tui_partedit "$STATE"
    [ "$PE_ANSWER" = text ] && text_editor
    case "$PE_ANSWER" in
      apply)    apply_changes "$DISK" && { load_drive "$DISK" || return; } ;;
      new\|*)   new_partition "${PE_ANSWER#new|}" ;;
      format\|*) format_partition "${PE_ANSWER#format|}" ;;
      size\|*)  exact_size "${PE_ANSWER#size|}" ;;
      menu\|*)  part_menu "${PE_ANSWER#menu|}" ;;
      *)
        n=$($PE ops "$STATE" | wc -l)
        [ "$n" = 0 ] && return
        tui_confirm "Leave without applying?" no "$n change(s) are waiting and would be dropped." "" "Leave?" && return ;;
    esac
  done
}

pick_drive "Partitions - which drive?" "nothing is written until you press Apply" || exit 0
DISK=$DRIVE
if lsblk -rno MOUNTPOINT "/dev/$DISK" | grep -q .; then
  tui_msg "Drive in use" "Something on /dev/$DISK is mounted. Restart the toolkit, or unmount it."
  exit 0
fi
load_drive "$DISK" && edit_drive
exit 0
