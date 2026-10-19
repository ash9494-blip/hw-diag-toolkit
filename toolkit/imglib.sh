#!/bin/bash
# Shared by the Disk imaging screens (imaging.sh) and the partition editor
# (partitions.sh): picking a drive, long messages, and running the engine in
# the background with its progress on screen. Sourced after lib.sh and tui.sh.
# shellcheck disable=SC2034

ENG="python3 /opt/diag/imgengine.py"
W=$RUN_DIR/img
STATUS=$W/status
mkdir -p "$W"

gbytes() {   # bytes -> "238.5 GB", 1024-based like Windows
  awk -v b="${1:-0}" 'BEGIN{ if (b >= 1073741824) printf "%.1f GB", b/1073741824;
                             else printf "%d MB", b/1048576 }'
}
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# A message whose lines are too long for one screen row each. The renderer
# wraps them (tui_para) after translating: folded here, the English pieces
# matched no catalogue entry and Chinese has no spaces to fold at (1.21).
say_wrapped() {   # title text...
  local title=$1 l row=6; shift
  tui_frame "$title" "Enter to continue"
  for l in "$@"; do
    if [ -z "$l" ]; then row=$((row + 1)); continue; fi
    row=$(tui_para "$row" "$l")
  done
  tui_flush
  tui_anykey
}

# ---------------------------------------------------------------- drives
drive_desc() {   # disk -> "/dev/sda  238.5 GB  KIOXIA ..."
  printf '/dev/%s  %s  %s' "$1" "$(gbytes "$(disk_bytes "$1")")" \
    "$(lsblk -dno MODEL "/dev/$1" 2>/dev/null | sed 's/  */ /g;s/ *$//')"
}

# Every drive except the toolkit's own stick and any named. Sets DRIVE.
pick_drive() {   # title hint skip...
  local title=$1 hint=$2 boot n s r t m sk where; shift 2
  local -a names=() labels=()
  boot=$(boot_stick_disk 2>/dev/null)
  while read -r n s r t m; do
    [ "$n" = "$boot" ] && continue
    for sk in "$@"; do [ "$n" = "$sk" ] && continue 2; done
    where="inside"; [ "$t" = usb ] && where="USB"
    names+=("$n"); labels+=("/dev/$n|$(gbytes "$(disk_bytes "$n")")|$m|$where")
  done < <(list_disks)
  if [ ${#names[@]} -eq 0 ]; then
    tui_msg "No drive to use" "No drive was found apart from the toolkit's own stick." "" \
      "Connect it - fitted inside, or in a USB adapter - and try again."
    return 1
  fi
  tui_menu "$title" "$hint" "${labels[@]}" || return 1
  DRIVE=${names[$((TUI_CHOICE-1))]}
}

# ---------------------------------------------------------------- where images go
# USB drives, partitions labelled DIAGDATA, and the toolkit stick's own data
# partition (through Ventoy's mapping - lib.sh's settings_places). Never the
# laptop's own drives, never a drive in the skip list.
# A cloned Windows drive in a USB adapter is a USB drive too: its EFI, MSR
# and recovery partitions were offered as places for an image (VM, 1.21.0).
# Those, and anything under 1 GB, are left out.
store_candidates() {
  settings_places
  lsblk -Jbpo NAME,FSTYPE,TRAN,RM,TYPE,SIZE,PARTTYPE 2>/dev/null | jq -r '.blockdevices[]
    | select(.type == "disk") | . as $d | select($d.tran == "usb" or $d.rm == true)
    | ($d.children // [])[]
    | select(.fstype as $f | ["vfat","exfat","ntfs","ext4","ext3","ext2"] | index($f))
    | select((.size // 0) >= 1073741824)
    | select((.parttype // "" | ascii_downcase) as $t
        | ["c12a7328-f81f-11d2-ba4b-00a0c93ec93b", "e3c9e316-0b5c-4db8-817d-f92df00215ae",
           "de94bba4-06d1-4d40-a16a-bfd50179d6ac", "0xef", "0x27"] | index($t) | not)
    | .name'
}

store_parent() {   # dev -> the disk it is on (sdb), through Ventoy's dm mapping too
  local n p
  n=$(basename "$(readlink -f "$1")")
  for _ in 1 2 3; do
    [ "$(lsblk -dno TYPE "/dev/$n" 2>/dev/null | tr -d ' ')" = disk ] && { echo "$n"; return; }
    p=$(lsblk -dno PKNAME "/dev/$n" 2>/dev/null | head -1 | tr -d ' ')
    [ -z "$p" ] && for p in /sys/block/"$n"/slaves/*; do p=${p##*/}; break; done
    case "$p" in ''|'*') return ;; esac
    n=$p
  done
}

store_list() {   # skip-disk... -> STORE_DEVS, STORE_LABELS ("label|size|fs|dev")
  local d fs label size par sk boot
  STORE_DEVS=(); STORE_LABELS=()
  boot=$(boot_stick_disk 2>/dev/null)
  while read -r d; do
    [ -b "$d" ] || continue
    par=$(store_parent "$d")
    for sk in "$@"; do [ -n "$sk" ] && [ "$par" = "$sk" ] && continue 2; done
    fs=$(lsblk -dno FSTYPE "$d" | tr -d ' '); label=$(lsblk -dno LABEL "$d")
    size=$(gbytes "$(blockdev --getsize64 "$d" 2>/dev/null)")
    [ "$par" = "$boot" ] && label="${label:-no label} (this stick)"
    STORE_DEVS+=("$d"); STORE_LABELS+=("${label:-no label}|$size|$fs|$d")
  done < <(store_candidates | awk '!seen[$0]++')
}

pick_store() {   # title skip-disk... -> STORAGE_DEV, STORE_DESC
  local title=$1; shift
  store_list "$@"
  if [ ${#STORE_DEVS[@]} -eq 0 ]; then
    tui_msg "Nowhere to keep images" "No USB drive was found." "" \
      "Plug in a USB drive formatted exFAT, NTFS or FAT32 - or label a partition DIAGDATA."
    return 1
  fi
  tui_menu "$title" "USB drives and this stick - the laptop's own drives are not offered" "${STORE_LABELS[@]}" || return 1
  STORAGE_DEV=${STORE_DEVS[$((TUI_CHOICE-1))]}
  STORE_DESC=${STORE_LABELS[$((TUI_CHOICE-1))]//|/  }
}

store_mount() {   # [ro]
  if [ "$1" = ro ]; then mount_storage_ro; else mount_storage; fi && return 0
  tui_msg "Cannot use $STORAGE_DEV" "$(head -2 "$RUN_DIR/mnterr" 2>/dev/null)"
  return 1
}

pick_image() {   # sets IMAGE (a folder on the mounted store)
  local p saved machine size drive
  local -a paths=() labels=()
  while IFS='|' read -r p saved machine size drive; do
    [ ${#machine} -gt 44 ] && machine="${machine:0:42}..."
    paths+=("$p"); labels+=("$saved|$machine|$size")
  done < <($ENG list-images "$STORAGE_MNT" 2>>"$W/engine.out")
  if [ ${#paths[@]} -eq 0 ]; then
    tui_msg "No images there" "No image folder was found on $STORE_DESC." "" \
      "The toolkit and Clonezilla both save one folder per image."
    return 1
  fi
  tui_menu "Which image?" "saved, machine, size" "${labels[@]}" || return 1
  IMAGE=${paths[$((TUI_CHOICE-1))]}
}

# ---------------------------------------------------------------- BitLocker
# Windows' "Key ID": the start of the recovery protector's GUID. In bitlkDump
# the protector's GUID line comes before its "recovery passphrase" line.
# Shown so the right key can be picked out of the customer's Microsoft account.
bl_key_id() {
  cryptsetup bitlkDump "$1" 2>/dev/null \
    | awk '/GUID:/{g=$NF} tolower($0) ~ /recovery passphrase/ {print toupper(substr(g,1,8)); exit}'
}

bl_key_entry() {   # node name-to-show -> 0 when unlocked (read-only)
  local node=$1 name=$2 id tries=0
  id=$(bl_key_id "$node")
  while [ $tries -lt 3 ]; do
    tui_input "BitLocker recovery key" "The 48 digits for $name${id:+ (Key ID $id)} - dashes optional, blank to cancel:"
    [ -z "$TUI_TEXT" ] && return 1
    tui_frame "Unlocking $name" ""; tui_line 6 "Checking the key..." muted; tui_flush
    # the key goes down a pipe and is never written anywhere
    if printf '%s' "$TUI_TEXT" | $ENG bl-unlock "$node" > "$W/bl.out" 2>&1; then
      TUI_TEXT=""; return 0
    fi
    TUI_TEXT=""; tries=$((tries+1))
    say_wrapped "That key did not open it" "$(tail -1 "$W/bl.out")" "" \
      "Check the Key ID${id:+ ($id)} matches the key, and type it again."
  done
  return 1
}

# ---------------------------------------------------------------- running a job
st() { sed -n "s/^$1=//p" "$STATUS" 2>/dev/null | head -1; }

draw_status() {   # start
  local eta; eta=$(st eta)
  tui_kv 6 "Step" "$(st step) of $(st steps)   $(st what)"
  tui_kv 7 "This step" "$(st partpct)%${eta:+   - $eta to go}"
  tui_kv 8 "Speed" "$(st rate)"
  tui_kv 9 "Running for" "$(secs_hms $(( $(date +%s) - $1 )))"
  [ -n "$JOB_FROM" ] && tui_kv 11 "From" "$JOB_FROM"
  [ -n "$JOB_TO" ] && tui_kv 12 "To" "$JOB_TO" warn
  tui_line 14 "$(st msg)" muted
  tui_bar 16 "$(st pct)"
  tui_flush
}

# The engine in the background - imgengine.py, or JOB_PROG (the partition
# editor's imgparted.py) - its status drawn once a second. Q asks before
# stopping. Sets JOB_RESULT (ok / failed / stopped), JOB_MSG, JOB_TIME.
run_job() {   # title risk-if-stopped engine-args...
  local title=$1 risk=$2 pid start; shift 2
  rm -f "$STATUS"
  ${JOB_PROG:-$ENG} "$@" --status "$STATUS" >>"$W/engine.out" 2>&1 &
  pid=$!; start=$(date +%s)
  tui_frame "$title" "Q = stop"
  while kill -0 "$pid" 2>/dev/null; do
    draw_status "$start"
    if tui_wait_abort 1; then
      tui_confirm "Stop now?" no "$risk" "" "Stop?" && kill -TERM "$pid" 2>/dev/null
      tui_frame "$title" "Q = stop"
    fi
  done
  wait "$pid"
  JOB_RESULT=$(st result); JOB_MSG=$(st msg)
  [ -n "$JOB_RESULT" ] || { JOB_RESULT=failed; JOB_MSG="the imaging engine stopped: $(tail -1 "$W/engine.out")"; }
  JOB_TIME=$(( $(date +%s) - start ))
}
