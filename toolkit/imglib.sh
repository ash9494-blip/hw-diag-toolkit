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

# "Plug it in": the page tui_wait_device sits under. 0 once a drive came (its
# partitions read), 1 for Q.
plug_page() {   # title why what-to-do
  tui_frame "$1" "Q = back"
  tui_line 6 "$2"
  tui_line 8 "$3"
  tui_line 9 "This page goes on by itself when it appears." muted
  tui_flush
  tui_wait_device || return 1
  udevadm settle -t 5 2>/dev/null
  return 0
}

# Every drive except the toolkit's own stick and any named. Sets DRIVE.
# The list follows the drives while it is open (Ash, 1.24: "detect hot-plug
# USB, instead of back and select again"): a USB drive plugged in joins it,
# marked as just plugged in; one pulled out leaves; the highlighted drive
# stays highlighted. With no drive to offer, the page waits for one.
pick_drive() {   # title hint skip...
  local title=$1 hint=$2 boot n s r t m sk where seen cur="" at; shift 2
  local -a names labels
  seen=" $(list_disks | awk '{printf "%s ", $1}')"
  while :; do
    names=(); labels=(); at=1
    boot=$(boot_stick_disk 2>/dev/null)
    while read -r n s r t m; do
      [ "$n" = "$boot" ] && continue
      for sk in "$@"; do [ "$n" = "$sk" ] && continue 2; done
      where="inside"; [ "$t" = usb ] && where="USB"
      case "$seen" in *" $n "*) ;; *) where="just plugged in" ;; esac
      names+=("$n"); labels+=("/dev/$n|$(gbytes "$(disk_bytes "$n")")|$m|$where")
      [ "$n" = "$cur" ] && at=${#names[@]}
    done < <(list_disks)
    if [ ${#names[@]} -eq 0 ]; then
      plug_page "$title" "No drive was found apart from the toolkit's own stick." \
        "Plug it in now in a USB adapter - a drive fitted inside needs the laptop restarted." || return 1
      continue
    fi
    tui_menu_watch "$at" "$title" "$hint" "${labels[@]}"
    case $? in
      0) DRIVE=${names[$((TUI_CHOICE-1))]}; return 0 ;;
      2) cur=${names[$((TUI_HOTSEL-1))]}; udevadm settle -t 5 2>/dev/null ;;
      *) return 1 ;;
    esac
  done
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
  [ "$1" = onedrive ] && return 0            # on no disk here
  n=$(basename "$(readlink -f "$1")")
  for _ in 1 2 3; do
    [ "$(lsblk -dno TYPE "/dev/$n" 2>/dev/null | tr -d ' ')" = disk ] && { echo "$n"; return; }
    p=$(lsblk -dno PKNAME "/dev/$n" 2>/dev/null | head -1 | tr -d ' ')
    [ -z "$p" ] && for p in /sys/block/"$n"/slaves/*; do p=${p##*/}; break; done
    case "$p" in ''|'*') return ;; esac
    n=$p
  done
}

# What a job's Flow bar watches on the store's side (JOB_DEVS): its disk -
# or, for OneDrive, the network ports, where the image really moves
store_io() {
  local n
  [ "$STORAGE_DEV" = onedrive ] || { store_parent "$STORAGE_DEV"; return; }
  for n in /sys/class/net/*; do [ "${n##*/}" = lo ] || printf '%s ' "${n##*/}"; done
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

# USB or OneDrive, asked first - back up, restore, check, browse (Ash, 1.26:
# "it always ask me to plug in USB when imaging ... make the interface for
# me to be able to choose onedrive or usb"). USB goes on to the drive list,
# which waits for one to be plugged in; OneDrive to its sign-in (od_mount,
# from store_mount), its app IDs asked for first if this build has none.
# The last answer is the one highlighted next time.
pick_place() {   # title usb-title skip-disk... -> STORAGE_DEV, STORE_DESC
  local title=$1 usb_title=$2 who od_desc; shift 2
  while :; do
    od_desc="your work OneDrive - sign in with a code on your phone"
    who=$(od_who) && od_desc="signed in as $who"
    tui_menu_at "${OD_LAST_PLACE:-1}" "$title" "USB or OneDrive" \
      "USB drive|a USB drive or this stick - plug it in when asked" \
      "OneDrive|$od_desc" || return 1
    OD_LAST_PLACE=$TUI_CHOICE
    if [ "$TUI_CHOICE" = 2 ]; then
      od_ready || od_setup || continue
      STORAGE_DEV=onedrive; STORE_DESC="OneDrive"
      return 0
    fi
    # Q on the drive list or the "plug it in" page: back to this question
    pick_store "$usb_title" "$@" && return 0
  done
}

# Follows the drives like pick_drive: a stick plugged in while the list is
# open joins it, and with none there the page waits for one.
pick_store() {   # title skip-disk... -> STORAGE_DEV, STORE_DESC
  local title=$1 cur="" at i; shift
  while :; do
    store_list "$@"
    at=1
    for i in "${!STORE_DEVS[@]}"; do [ "${STORE_DEVS[$i]}" = "$cur" ] && at=$((i + 1)); done
    if [ ${#STORE_DEVS[@]} -eq 0 ]; then
      plug_page "$title" "No USB drive was found." \
        "Plug in a USB drive formatted exFAT, NTFS or FAT32 - or label a partition DIAGDATA." || return 1
      continue
    fi
    tui_menu_watch "$at" "$title" "USB drives and this stick - the laptop's own drives are not offered" \
      "${STORE_LABELS[@]}"
    case $? in
      0) STORAGE_DEV=${STORE_DEVS[$((TUI_CHOICE-1))]}
         STORE_DESC=${STORE_LABELS[$((TUI_CHOICE-1))]//|/  }
         return 0 ;;
      2) cur=${STORE_DEVS[$((TUI_HOTSEL-1))]}; udevadm settle -t 5 2>/dev/null ;;
      *) return 1 ;;
    esac
  done
}

store_mount() {   # [ro]
  [ "$STORAGE_DEV" = onedrive ] && { od_mount; return; }
  if [ "$1" = ro ]; then mount_storage_ro; else mount_storage; fi && return 0
  tui_msg "Cannot use $STORAGE_DEV" "$(head -2 "$RUN_DIR/mnterr" 2>/dev/null)"
  return 1
}

pick_image() {   # sets IMAGE (a folder on the mounted store)
  local p saved machine size drive rc
  local -a paths=() labels=() lister=($ENG list-images "$STORAGE_MNT")
  if [ "$STORAGE_DEV" = onedrive ]; then
    # Microsoft's search finds them anywhere on the drive, not just at the top
    lister=($OD images "$STORAGE_MNT")
    tui_frame "Looking on OneDrive" ""; tui_line 6 "Searching OneDrive for disk images..." muted; tui_flush
  fi
  "${lister[@]}" > "$W/images.txt" 2>"$W/images.err"; rc=$?
  cat "$W/images.err" >> "$W/engine.out"
  while IFS='|' read -r p saved machine size drive; do
    [ ${#machine} -gt 44 ] && machine="${machine:0:42}..."
    paths+=("$p"); labels+=("$saved|$machine|$size")
  done < "$W/images.txt"
  if [ ${#paths[@]} -eq 0 ] && [ "$rc" != 0 ]; then
    say_wrapped "Cannot look on $STORE_DESC" "$(tail -1 "$W/images.err")"
    return 1
  fi
  if [ ${#paths[@]} -eq 0 ] && [ "$STORAGE_DEV" = onedrive ]; then
    say_wrapped "No images on OneDrive" "No disk image was found on OneDrive ($(od_who))." "" \
      "Backups made here go into its folder Disk images. Macrium .mrimg files and Clonezilla folders are found anywhere on it - one uploaded in the last few minutes may not be found yet."
    return 1
  fi
  if [ ${#paths[@]} -eq 0 ]; then
    tui_msg "No images there" "No image folder was found on $STORE_DESC." "" \
      "The toolkit and Clonezilla both save one folder per image."
    return 1
  fi
  tui_menu "Which image?" "saved, machine, size" "${labels[@]}" || return 1
  IMAGE=${paths[$((TUI_CHOICE-1))]}
}

# ---------------------------------------------------------------- OneDrive
# Ash's work OneDrive as one more place for images (1.26: "not only rely on
# usb, but also to search image on onedrive, and back up from there").
# onedrive.py signs in - a code typed on Ash's phone, no password typed
# here - and odfs.py shows the drive as a folder at OD_MNT, so Restore,
# Check, Browse and Back up use it as they use a USB drive:
# STORAGE_DEV=onedrive. It stays open until Disk imaging is left (od_close).
# The sign-in is kept on the boot stick beside the settings (OD_KEPT) - Ash's
# choice, told that whoever holds the stick can then open his OneDrive until
# he signs out (Disk imaging -> OneDrive). The app's two IDs come with the
# build (onedrive.conf) or from OD_APP on the stick.
OD="python3 /opt/diag/onedrive.py"
OD_MNT=/mnt/onedrive
OD_STATE=$RUN_DIR/onedrive
OD_KEPT=diag-onedrive.json
OD_APP=onedrive.config

od_ready() { $OD ready; }
od_who() { $OD whoami 2>/dev/null; }

# Where the sign-in may be kept: partitions of the boot stick itself (its
# DIAGDATA too), never another stick's - a stranger's DIAGDATA stick holding
# its own sign-in would show its account here and take customer images to
# its OneDrive (security review, 1.26).
od_places() {
  local d boot
  boot=$(boot_stick_disk 2>/dev/null) || return 0
  for d in $(settings_places); do
    [ "$(store_parent "$d")" = "$boot" ] && printf '%s\n' "$d"
  done
  return 0
}

# The stick's sign-in and app IDs -> RAM, once a boot. Only while no store is
# mounted (the start of Disk imaging): a stick mounted here would take
# /mnt/diagdata from under the store in use.
od_restore() {
  [ -e "$OD_STATE/.looked" ] && return 0
  mkdir -p "$OD_STATE" && chmod 700 "$OD_STATE" && : > "$OD_STATE/.looked"
  local d
  local -a was=("$STORAGE_DEV" "$STORAGE_MNT" "$STORAGE_OWNED")
  for d in $(od_places); do
    STORAGE_DEV=$d
    mount_storage_ro || continue
    if [ ! -s "$OD_STATE/token.json" ] && [ -s "$STORAGE_MNT/$OD_KEPT" ]; then
      install -m 600 "$STORAGE_MNT/$OD_KEPT" "$OD_STATE/token.json" \
        && touch "$OD_STATE/kept" && echo "sign-in read from $d" >> "$OD_STATE/keep.log"
    fi
    if [ ! -s "$OD_STATE/onedrive.conf" ] && [ -s "$STORAGE_MNT/$OD_APP" ]; then
      # Notepad's line ends; and only the two IDs (onedrive.py takes no more)
      tr -d '\r' < "$STORAGE_MNT/$OD_APP" | grep -E '^(CLIENT_ID|TENANT_ID)=' > "$OD_STATE/onedrive.conf"
    fi
    umount_storage
  done
  STORAGE_DEV=${was[0]}; STORAGE_MNT=${was[1]}; STORAGE_OWNED=${was[2]}
  return 0
}

# A file onto the boot stick as keep_settings writes the settings - a new
# copy renamed over the old - or, with no source, every copy removed. The
# old copy is overwritten first (shred): FAT and exFAT leave a deleted
# file's clusters readable, and a refresh token found there still works.
# 0 written / none left; 1 not written / a copy may be left; 2 there is no
# boot stick place at all (started from a CD, a dd-written stick).
od_stick() {   # source-or-"" name
  local src=$1 name=$2 d f opts rc=2 log=$OD_STATE/keep.log
  local -a was=("$STORAGE_DEV" "$STORAGE_MNT" "$STORAGE_OWNED")
  for d in $(od_places); do
    if [ "$rc" = 2 ]; then [ -n "$src" ] && rc=1 || rc=0; fi
    STORAGE_DEV=$d
    opts=$(findmnt -no OPTIONS --source "$d" 2>/dev/null | head -1)
    if ! mount_storage; then
      echo "$name: $d: $(head -1 "$RUN_DIR/mnterr" 2>/dev/null)" >> "$log"
      [ -z "$src" ] && rc=1               # cannot say none is left there
      continue
    fi
    if [ -n "$src" ]; then
      cp "$src" "$STORAGE_MNT/$name.new" 2>>"$log" \
        && { [ ! -f "$STORAGE_MNT/$name" ] || shred -n1 -z "$STORAGE_MNT/$name" 2>>"$log"; } \
        && mv -f "$STORAGE_MNT/$name.new" "$STORAGE_MNT/$name" 2>>"$log" && rc=0
    else
      for f in "$STORAGE_MNT/$name" "$STORAGE_MNT/$name.new"; do
        [ -e "$f" ] || continue
        shred -n1 -z -u "$f" 2>>"$log" || rm -f "$f" 2>>"$log"
        [ -e "$f" ] && rc=1
      done
    fi
    sync
    case ",$opts," in *,ro,*) mount -o remount,ro "$STORAGE_MNT" 2>>"$log" ;; esac
    umount_storage
    [ -n "$src" ] && [ "$rc" = 0 ] && { echo "$name kept on $d" >> "$log"; break; }
  done
  STORAGE_DEV=${was[0]}; STORAGE_MNT=${was[1]}; STORAGE_OWNED=${was[2]}
  return $rc
}

od_keep() { od_stick "$OD_STATE/token.json" "$OD_KEPT" && touch "$OD_STATE/kept"; }

# OneDrive chosen, but this build has no app IDs (onedrive.conf empty, no
# onedrive.config on the stick): the two IDs typed in once - they are on
# the app registration's Overview page - and kept on the stick for next
# time. IDs, not secrets: the app is a public client, sign-in is the code.
od_setup() {   # [again] - skip the first question: Microsoft just refused the IDs typed before
  local client tenant guid='^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
  [ "$1" = again ] || tui_confirm "Set up OneDrive" yes "This toolkit does not have OneDrive's app IDs yet." \
    "They are on the app's Overview page: portal.azure.com - App registrations - the app." "" \
    "Type the two IDs in now? They are kept on this stick for next time." || return 1
  while :; do
    tui_input "Application (client) ID" "36 characters with dashes, from the app's Overview page - blank to cancel:"
    client=$(printf '%s' "$TUI_TEXT" | tr -d ' \t')
    [ -z "$client" ] && return 1
    [[ $client =~ $guid ]] && break
    tui_msg "That is not an ID" "An ID looks like 1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d5e6f." "" "Type it again."
  done
  while :; do
    tui_input "Directory (tenant) ID" "36 characters with dashes, from the same Overview page - blank to cancel:"
    tenant=$(printf '%s' "$TUI_TEXT" | tr -d ' \t')
    [ -z "$tenant" ] && return 1
    [[ $tenant =~ $guid ]] && break
    tui_msg "That is not an ID" "An ID looks like 1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d5e6f." "" "Type it again."
  done
  mkdir -p "$OD_STATE" && chmod 700 "$OD_STATE"
  printf 'CLIENT_ID=%s\nTENANT_ID=%s\n' "$client" "$tenant" > "$OD_STATE/onedrive.conf"
  od_stick "$OD_STATE/onedrive.conf" "$OD_APP" \
    || tui_msg "OneDrive set up" "The IDs could not be kept on the stick: after a restart they are asked for again."
  od_ready
}

# A way out to the internet at all (drivers.sh: have_route, wired_online).
od_routed() {
  declare -F wired_online >/dev/null || . /opt/diag/drivers.sh
  have_route
}

# Microsoft was not reached (onedrive.py exit 3), or there is no route yet.
# A cable first - the ports boot switched off, drivers.sh's wired_online
# switches them on - then the Wi-Fi page. 0 = online now, try again.
od_online() {
  if od_routed; then
    say_wrapped "Microsoft cannot be reached" "This laptop is on a network, but Microsoft's sign-in and OneDrive did not answer: $(tail -1 "$W/od.err")" "" \
      "The network may block them, or want a sign-in page first (guest Wi-Fi) - try another network."
    return 1
  fi
  tui_frame "OneDrive" "please wait"
  tui_line 6 "Looking for a network cable and asking for an address..." muted; tui_flush
  wired_online && return 0
  tui_confirm "No internet" yes "OneDrive needs the internet, and this laptop is not connected." "" \
    "Open the Wi-Fi page now?  (Or plug in a network cable, choose No," \
    "then try again.)" || return 1
  DIAG_IN_WIFI=1 /opt/diag/wificonnect.sh
  [ -n "$TUI_SUB" ] && _send_sub "$TUI_SUB"
  have_route
}

# The device code sign-in: Microsoft gives a short code, Ash types it at
# microsoft.com/devicelogin on his phone and approves there; this page only
# waits. 0 once signed in.
od_signin() {
  local pid code url mins rc row
  OD_UNKEPT=""
  od_routed || od_online || return 1
  while :; do
    tui_frame "Sign in to OneDrive" ""; tui_line 6 "Asking Microsoft for a sign-in code..." muted; tui_flush
    : > "$W/od.code"; : > "$W/od.err"
    $OD signin > "$W/od.code" 2> "$W/od.err" &
    pid=$!
    code=""
    for _ in $(seq 400); do                   # the code, or the reason there is none
      IFS='|' read -r code url mins < "$W/od.code"
      [ -n "$code" ] && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if [ -n "$code" ]; then
      tui_frame "Sign in to OneDrive" "Q = cancel"
      tui_line 6 "On your phone or any computer:"
      tui_kv 8 "Go to" "${url#https://}" accent
      tui_kv 9 "Type the code" "$code" accent
      row=$(tui_para 11 "Sign in with your Data Dynamics account and allow the Hardware Diagnostic Toolkit to open your files." muted)
      tui_line "$row" "The code works for $mins minutes - this page goes on by itself." muted
      tui_flush
      while kill -0 "$pid" 2>/dev/null; do
        tui_wait_abort 1 && { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 1; }
      done
    fi
    wait "$pid"; rc=$?
    if [ "$rc" = 0 ]; then
      od_keep && return 0
      OD_UNKEPT=1                             # said here; od_menu need not say "Signed in" again
      tui_msg "Signed in" "Signed in as $(od_who) - but the sign-in could not be kept on the stick:" \
        "after a restart you will be asked to sign in again." "" \
        "To keep it, start the toolkit from its USB stick (Ventoy, or a FAT32/exFAT partition on it labelled DIAGDATA)."
      return 0
    fi
    if [ "$rc" = 3 ]; then od_online && continue; return 1; fi
    if [ "$rc" = 4 ]; then                    # Microsoft knows no such app or tenant
      if grep -qsE '^CLIENT_ID=.' /opt/diag/onedrive.conf; then
        say_wrapped "OneDrive sign-in failed" "$(tail -1 "$W/od.err")" "" \
          "The app IDs built into this toolkit are not right: it has to be built again with the right ones."
        return 1
      fi
      tui_confirm "Microsoft does not know these IDs" yes "$(tail -1 "$W/od.err")" "" \
        "A typing mistake is the usual cause. Type the Application (client) ID and Directory (tenant) ID again?" \
        && od_setup again && continue
      return 1
    fi
    say_wrapped "OneDrive sign-in failed" "$(tail -1 "$W/od.err")"
    return 1
  done
}

# store_mount for OneDrive: STORAGE_MNT, signed in first when needed.
od_mount() {
  local rc
  STORAGE_OWNED=0                             # od_close unmounts it, not umount_storage
  if mountpoint -q "$OD_MNT"; then STORAGE_MNT=$OD_MNT; STORE_DESC="OneDrive ($(od_who))"; return 0; fi
  od_who >/dev/null || od_signin || return 1
  od_routed || od_online || return 1
  while :; do
    tui_frame "OneDrive" ""; tui_line 6 "Opening OneDrive..." muted; tui_flush
    $OD mount "$OD_MNT" 2> "$W/od.err"; rc=$?
    if [ "$rc" = 0 ]; then
      # the account as Microsoft names it now, not the label kept with the
      # sign-in: the confirm page says where the customer's image goes
      STORAGE_MNT=$OD_MNT
      STORE_DESC="OneDrive ($($OD whoami --live 2>>"$W/od.err" || od_who))"
      return 0
    fi
    if [ "$rc" = 3 ]; then od_online && continue; return 1; fi
    if ! od_who >/dev/null; then             # Microsoft ended the sign-in
      tui_confirm "Sign in again" yes "$(tail -1 "$W/od.err")" "" "Sign in to OneDrive again now?" \
        && od_signin && continue
      return 1
    fi
    say_wrapped "Cannot open OneDrive" "$(tail -1 "$W/od.err")"
    return 1
  done
}

# The files odfs.py still holds - an image's small files - up to OneDrive. A
# backup there is not finished until this is; OD_ERR says why not.
od_sync() {
  OD_ERR=""
  if ! mountpoint -q "$OD_MNT"; then          # odfs.py died: what it held is gone
    OD_ERR="the OneDrive folder closed before the image's last files went up"
    return 1
  fi
  tui_frame "OneDrive" ""; tui_line 6 "Sending the image's last files to OneDrive..." muted; tui_flush
  $OD sync "$OD_MNT" 2> "$W/od.err" && return 0
  OD_ERR=$(tail -1 "$OD_STATE/last-error" 2>/dev/null)
  [ -n "$OD_ERR" ] || OD_ERR=$(tail -1 "$W/od.err")
  return 1
}

# Leaving Disk imaging: OneDrive closed, and the sign-in - renewed while it
# was open - written back to the stick.
od_close() {
  mountpoint -q "$OD_MNT" && $OD umount "$OD_MNT" >> "$W/engine.out" 2>&1
  [ -s "$OD_STATE/token.json" ] && [ "$OD_STATE/token.json" -nt "$OD_STATE/kept" ] && od_keep
  return 0
}

od_signout() {   # od_stick's answer: 0 none left, 1 a copy may be left, 2 no stick
  mountpoint -q "$OD_MNT" && $OD umount "$OD_MNT" >> "$W/engine.out" 2>&1
  $OD signout
  rm -f "$OD_STATE/token.json" "$OD_STATE/kept"
  od_stick "" "$OD_KEPT"
}

# Disk imaging -> OneDrive: who is signed in, and signing out (the stick
# holds the sign-in, so Ash can end it before lending the stick).
od_menu() {
  local who kept="The sign-in is kept on this boot stick: anyone holding the stick can open this OneDrive."
  if who=$(od_who); then
    [ -e "$OD_STATE/kept" ] || kept="The sign-in is kept on this laptop only, until it restarts."
    tui_confirm "OneDrive" no "Signed in as $who." "$kept" "" \
      "Sign out - forget it on this laptop and on the stick?" || return 0
    od_signout
    case $? in
      0) tui_msg "Signed out" "The sign-in was removed from this laptop and from the stick." "" \
           "To end it on Microsoft's side too: myaccount.microsoft.com - Sign out everywhere." ;;
      2) tui_msg "Signed out" "The sign-in was removed from this laptop." "" \
           "To end it on Microsoft's side too: myaccount.microsoft.com - Sign out everywhere." ;;
      *) tui_msg "Signed out here" "The sign-in was removed from this laptop, but the stick could not be written." "" \
           "Delete $OD_KEPT from the stick on a PC, or: myaccount.microsoft.com - Sign out everywhere." ;;
    esac
    return 0
  fi
  od_ready || od_setup || return 0
  od_signin || return 0
  [ -n "$OD_UNKEPT" ] || tui_msg "Signed in" "Signed in as $(od_who)." "" \
    "OneDrive is now in the list when you back up, restore, check or browse an image."
  return 0
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
  # moving while the job's drives are busy, amber and still when they stop
  # (ui.py BarLive) - JOB_DEVS: the disks it reads and writes
  # shellcheck disable=SC2086
  tui_bar_live 16 "$(st pct)" $JOB_DEVS
  tui_flush
}

# The engine in the background - imgengine.py, or JOB_PROG (the partition
# editor's imgparted.py) - its status drawn once a second. Q asks before
# stopping. Sets JOB_RESULT (ok / failed / stopped), JOB_MSG, JOB_TIME.
# JOB_DEVS (set by the caller): the disks the job works on, for the bar.
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

# ---------------------------------------------------------------- the editors' questions
# Shared by the partition editor (partitions.sh on imgparted.py) and the
# plan screen's sizes (imaging.sh on imgplanedit.py, 1.24): PE is the
# model's command and STATE its state file - both answer the same calls.
info() {   # index -> INFO_NAME INFO_FS INFO_SIZE INFO_MIN INFO_RESIZE INFO_MOVE INFO_WHY INFO_MAX INFO_NEW
  IFS='|' read -r INFO_NAME INFO_FS INFO_SIZE INFO_MIN INFO_RESIZE INFO_MOVE INFO_WHY INFO_MAX INFO_NEW \
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
  # shellcheck disable=SC2086
  $PE new "$STATE" "$g" "$FS" "$LABEL" $mb 2>>"$W/engine.out" \
    || tui_msg "Could not add it" "$(tail -1 "$W/engine.out" | cut -c1-90)"
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

# The menu version of either editor, when there is no framebuffer to drag on.
text_editor() {   # title apply-label apply-description -> PE_ANSWER
  local kind i rest
  local -a keys=() labels=()
  while IFS='|' read -r kind i rest; do
    keys+=("$kind|$i"); labels+=("${rest//|/  }")
  done < <($PE items "$STATE")
  tui_menu "$1" "no dragging in the text screen - choose one" \
    "${labels[@]}" "$2|$3" || { PE_ANSWER=back; return; }
  if [ "$TUI_CHOICE" -gt ${#keys[@]} ]; then PE_ANSWER=apply; return; fi
  kind=${keys[$((TUI_CHOICE-1))]%%|*}; i=${keys[$((TUI_CHOICE-1))]#*|}
  if [ "$kind" = gap ]; then PE_ANSWER="new|$i"; else PE_ANSWER="menu|$i"; fi
}
