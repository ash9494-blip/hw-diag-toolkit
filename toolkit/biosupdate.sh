#!/bin/bash
# BIOS update (tile 20, 1.28 - Ash: "can you add one features is to update
# BIOS in tools?"). The toolkit never writes firmware itself (CLAUDE.md,
# invariant 4): it starts the maker's own flasher with the maker's own image,
# for this laptop's model, newer only, after the technician types UPDATE.
#
# Dynabook ships a USB update as two files - the flasher, a UEFI Shell
# program (ShellFlash64.efi, Phoenix SCT Flash, on the X30L-M; ChgFirmA.efi,
# Dynabook's capsule tool, on the X30L-K - 1.28.1), and the image
# (BIOS0126.bin, a UEFI capsule); both flashers take the image as argument -
# which Ash runs today from the root of a FAT32 stick with the "`" key at
# power-on. Here they live on the stick's DIAGDATA, a folder per package as
# Dynabook names it (BIOS\X30L-M_B210_USB), and the laptop restarts by itself
# into a UEFI Shell (EDK2's, carried by the toolkit) that runs the flasher:
#
#   1. biospkg.py says which folders may be offered (model, newer only).
#   2. Checks: AC adapter, battery >= 30 %, BitLocker on the laptop's drive
#      (Windows asks for the recovery key after a BIOS update), unsaved
#      results (the restart ends this session), then UPDATE typed.
#   3. On DIAGDATA, in BIOS\.diag: the Shell, its startup.nsh and a note of
#      what was started (serial, version before, package). Two boot entries,
#      made without touching the laptop's boot order: the Shell, set as the
#      next boot only (BootNext), and the stick's own loader, which the
#      script sets as the boot after that - back to the toolkit.
#   4. The script runs the flasher; Dynabook's flasher reboots to write the
#      capsule. If it stops instead (its own checks), its message stays on
#      the screen until a key is pressed, then the laptop restarts.
#   5. Back in the toolkit (menu.sh, after the Language menu): --result reads
#      the note, compares the BIOS version now, says updated or not, writes
#      it into the report, and removes the entries and the files.
#
#   biosupdate.sh            the screen (tile 20)
#   biosupdate.sh --result   at boot: the result of an update started here
. /opt/diag/lib.sh
. /opt/diag/tui.sh

BP="python3 /opt/diag/biospkg.py"
SHELL_EFI=/usr/share/efi-shell-x64/shellx64.efi
DIAG_SUB=BIOS/.diag                  # on DIAGDATA: shellx64.efi, startup.nsh, pending.txt
LABEL_SHELL="Diag BIOS update"
LABEL_BACK="Diag back to the toolkit"
EFI_GLOBAL=8BE4DF61-93CA-11D2-AA0D-00E098032B8C
MIN_BATTERY=30
LOG=$RUN_DIR/biosupdate.log

blog() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

serial() { cat /sys/class/dmi/id/product_serial 2>/dev/null | tr -d '\n'; }

# ---------------------------------------------------------------- the stick
# DIAGDATA, FAT32 - the firmware reads FAT only. Any USB stick's, the boot
# stick's first. -> DD_DEV (mountable: Ventoy may hold it, stick_part_dev),
# DD_PART (/dev/sdb3), DD_DISK (/dev/sdb), DD_NUM (3), DD_FS; 1 = none at all.
find_diagdata() {
  local p fs boot best="" other=""
  DD_DEV=""; DD_PART=""; DD_DISK=""; DD_NUM=""; DD_FS=""
  boot=$(boot_stick_disk 2>/dev/null)
  for p in $(blkid -t LABEL=DIAGDATA -o device 2>/dev/null); do
    case "$p" in /dev/dm-*|/dev/mapper/*|/dev/loop*) continue ;; esac   # a mapping of one of these
    fs=$(blkid -o value -s TYPE "$p" 2>/dev/null)
    if [ "$fs" = vfat ]; then
      if [ "$(lsblk -no PKNAME "$p" 2>/dev/null | head -1 | tr -d ' ')" = "$boot" ]; then best=$p; break; fi
      [ -z "$best" ] && best=$p
    else
      other="$p $fs"
    fi
  done
  if [ -z "$best" ]; then
    [ -n "$other" ] && DD_FS=${other#* }
    return 1
  fi
  DD_PART=$best; DD_FS=vfat
  DD_DISK=/dev/$(lsblk -no PKNAME "$best" 2>/dev/null | head -1 | tr -d ' ')
  DD_NUM=$(cat "/sys/class/block/${best##*/}/partition" 2>/dev/null)
  DD_DEV=$(stick_part_dev "$best")
  [ -n "$DD_NUM" ] && [ "$DD_DISK" != /dev/ ]
}

# The boot stick's own loader, for the way back: a FAT partition on it with
# \EFI\BOOT\BOOTX64.EFI (Ventoy's VTOYEFI, a written ISO's EFI partition).
# -> BACK_DISK, BACK_NUM; 1 when there is none (started from a CD...).
find_back() {
  local disk p fs m
  BACK_DISK=""; BACK_NUM=""
  disk=$(boot_stick_disk 2>/dev/null) || return 1
  m=$RUN_DIR/bios-back
  mkdir -p "$m"
  for p in $(lsblk -lnpo NAME,TYPE "/dev/$disk" 2>/dev/null | awk '$2 == "part" {print $1}'); do
    fs=$(blkid -o value -s TYPE "$p" 2>/dev/null)
    [ "$fs" = vfat ] || continue
    mount -o ro "$p" "$m" 2>/dev/null || continue
    if [ -f "$m/EFI/BOOT/BOOTX64.EFI" ]; then
      umount "$m"
      BACK_DISK=/dev/$disk; BACK_NUM=$(cat "/sys/class/block/${p##*/}/partition" 2>/dev/null)
      return 0
    fi
    umount "$m"
  done
  return 1
}

# ---------------------------------------------------------------- boot entries
efi_entry() {   # label -> its Boot number (0005); 1 when there is none
  local n
  n=$(efibootmgr 2>/dev/null | awk -v l="$1" '
    /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {
      s = substr($0, 9); sub(/^[* ]+/, "", s); sub(/\t.*/, "", s)
      if (s == l) { print substr($0, 5, 4); exit } }')
  [ -n "$n" ] && printf '%s\n' "$n"
}

efi_drop() {   # every entry with this label
  local n i
  for i in 1 2 3 4 5 6 7 8; do
    n=$(efi_entry "$1") || return 0
    efibootmgr -q -b "$n" -B >> "$LOG" 2>&1 || return 0
    blog "boot entry $n ($1) removed"
  done
}

efi_make() {   # label disk partnum path -> its Boot number; not in BootOrder (-C)
  efi_drop "$1"
  efibootmgr -q -C -d "$2" -p "$3" -L "$1" -l "$4" >> "$LOG" 2>&1 || return 1
  efi_entry "$1"
}

# An entry last in the boot order. Firmware may delete at start-up every
# entry its boot order does not list, sparing only the one booting next
# (OVMF did): the way-back entry was gone before the Shell's BootNext to it
# was used, and the laptop started Windows instead (VM, 1.28). Last, so
# nothing the laptop starts by itself changes; efi_drop takes it out again.
efi_order_last() {   # Boot number
  local order
  order=$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder: *//p' | tr -d ' ')
  case ",$order," in *",$1,"*) return 0 ;; esac
  efibootmgr -q -o "${order:+$order,}$1" >> "$LOG" 2>&1
}

# ---------------------------------------------------------------- checks
ac_online() {   # the charger in: a Mains supply online, or the battery charging
  local s
  for s in /sys/class/power_supply/*; do
    [ "$(cat "$s/type" 2>/dev/null)" = Mains ] && [ "$(cat "$s/online" 2>/dev/null)" = 1 ] && return 0
  done
  for s in /sys/class/power_supply/BAT*/status; do
    case "$(cat "$s" 2>/dev/null)" in Charging|Full) return 0 ;; esac
  done
  return 1
}

battery_pct() {   # the lowest battery's charge; nothing when there is no battery
  local s v low=""
  for s in /sys/class/power_supply/BAT*/capacity; do
    [ -r "$s" ] || continue
    v=$(tr -dc '0-9' < "$s")
    [ -n "$v" ] && { [ -z "$low" ] || [ "$v" -lt "$low" ]; } && low=$v
  done
  printf '%s' "$low"
}

bitlocker_drives() {   # BitLocker partitions on the laptop's own drives
  local p disk boot
  boot=$(boot_stick_disk 2>/dev/null)
  for p in $(blkid -t TYPE=BitLocker -o device 2>/dev/null); do
    disk=$(lsblk -no PKNAME "$p" 2>/dev/null | head -1 | tr -d ' ')
    [ -n "$disk" ] && [ "$disk" != "$boot" ] || continue
    [ "$(lsblk -dno TRAN "/dev/$disk" 2>/dev/null | tr -d ' ')" = usb ] && continue
    printf '%s ' "${p##*/}"
  done
}

# ---------------------------------------------------------------- the screen
pick_package() {   # -> PK_* of the chosen folder; 1 = back
  local f st mo ve cu re fl im di
  local -a rows=() labels=()
  while IFS='|' read -r f st mo ve cu re fl im di; do
    rows+=("$f|$st|$mo|$ve|$cu|$re|$fl|$im|$di")
    if [ "$st" = ok ]; then labels+=("$f|$re"); else labels+=("$f|not offered: $re"); fi
  done < <($BP list "$STORAGE_MNT/BIOS" 2>>"$LOG")
  if [ ${#rows[@]} -eq 0 ]; then
    say_wrapped "No BIOS packages" "There is no BIOS package in the folder BIOS on DIAGDATA ($(basename "$DD_PART"))." "" \
      "Copy the folder from Dynabook there as it comes - named like X30L-M_B210_USB, with the flasher (ShellFlash64.efi or ChgFirmA.efi) and the .bin file in it."
    return 1
  fi
  while :; do
    tui_menu "BIOS update - which package?" "this laptop: $($BP model), BIOS $($BP current)" "${labels[@]}" || return 1
    IFS='|' read -r PK_FOLDER PK_STATE PK_MODEL PK_VER PK_CUR PK_REASON PK_FLASHER PK_IMAGE PK_DIR \
      <<< "${rows[$((TUI_CHOICE-1))]}"
    [ "$PK_STATE" = ok ] && return 0
    tui_msg "Not offered" "$PK_FOLDER" "" "$PK_REASON"
  done
}

# The checks before UPDATE, on one page; 0 when nothing stops the update,
# 1 when something does, 2 for Q (back to the packages - it was taken for
# "not ready" and asked to check again, review 1.28).
check_page() {
  local ac bat bl row stop=0
  ac_online && ac=1 || ac=0
  bat=$(battery_pct)
  bl=$(bitlocker_drives)
  tui_frame "BIOS update - before it starts" "Enter = go on      Q = back"
  tui_kv 6 "Package" "$PK_FOLDER"
  tui_kv 7 "BIOS" "now $PK_CUR  ->  $PK_VER" ok
  if [ "$ac" = 1 ]; then tui_kv 8 "AC adapter" "plugged in" ok
  else tui_kv 8 "AC adapter" "NOT plugged in - plug in the charger" err; stop=1; fi
  if [ -z "$bat" ]; then tui_kv 9 "Battery" "none found" muted
  elif [ "$bat" -ge "$MIN_BATTERY" ]; then tui_kv 9 "Battery" "$bat %" ok
  else tui_kv 9 "Battery" "$bat % - below $MIN_BATTERY %, charge it first" err; stop=1; fi
  row=11
  if [ -n "$bl" ]; then
    tui_kv 10 "BitLocker" "on this laptop's drive ($bl)" warn
    row=$(tui_para 11 "After a BIOS update Windows asks for the BitLocker recovery key. Have the key ready, or suspend BitLocker in Windows first." warn)
  fi
  row=$(tui_para $((row + 1)) "The laptop restarts into Dynabook's flasher, then comes back to this stick. Pick the toolkit in Ventoy's menu as usual: the result is shown after the Language menu." muted)
  tui_flush
  tui_keys q
  case "$TUI_KEY" in q|esc) return 2 ;; esac
  return $stop
}

# The boot entries an update made on this laptop, and a next boot set to one
# of them, gone. At every toolkit start too, whatever the stick says: an
# entry left behind (the toolkit started from another stick, DIAGDATA not
# writable) could start the Shell and the flasher again with nobody having
# typed UPDATE (review, 1.28).
efi_forget() {
  local next ours
  [ -d /sys/firmware/efi/efivars ] || return 0
  next=$(efibootmgr 2>/dev/null | sed -n 's/^BootNext: *//p' | tr -d ' ')
  ours=" $(efi_entry "$LABEL_SHELL") $(efi_entry "$LABEL_BACK") "
  if [ -n "$next" ]; then
    case "$ours" in *" $next "*) efibootmgr -q -N >> "$LOG" 2>&1 && blog "next boot $next cleared" ;; esac
  fi
  efi_drop "$LABEL_SHELL"
  efi_drop "$LABEL_BACK"
}

# Every file and entry an update leaves, gone (cancelled, or back after it).
undo_prepare() {
  efi_forget
  if [ -n "$STORAGE_MNT" ] && [ -d "$STORAGE_MNT/$DIAG_SUB" ]; then
    rm -rf "${STORAGE_MNT:?}/$DIAG_SUB"
    sync
  fi
}

le16() { printf '%s' "${1:2:2}${1:0:2}"; }   # 0005 -> 0500: BootNext's two bytes

# The Shell's script: find DIAGDATA among the Shell's file systems by the
# note, set the way back, run the flasher in the package's folder. CRLF, as
# UEFI scripts are written.
write_script() {   # back-entry-number-or-empty
  local f=$STORAGE_MNT/$DIAG_SUB/startup.nsh
  {
    printf '%s\n' "@echo -off"
    printf '%s\n' "# Written by the Hardware Diagnostic Toolkit (biosupdate.sh) for one BIOS"
    printf '%s\n' "# update the technician confirmed by typing UPDATE. The toolkit removes it."
    printf '%s\n' "for %a run (0 31)"
    printf '%s\n' '  if exist fs%a:\BIOS\.diag\pending.txt then'
    printf '%s\n' "    fs%a:"
    printf '%s\n' "    goto FOUND"
    printf '%s\n' "  endif"
    printf '%s\n' "endfor"
    # echo's words in quotes: a bare " - " was taken for an option (VM)
    printf '%s\n' 'echo "The toolkit'"'"'s DIAGDATA partition was not found: nothing was changed."'
    printf '%s\n' "goto DONE"
    printf '%s\n' ":FOUND"
    [ -n "$1" ] && printf '%s\n' "setvar BootNext -guid $EFI_GLOBAL -bs -rt -nv =$(le16 "$1")"
    # PK_DIR: the folder, or the folder inside it Windows' Extract All made
    printf '%s\n' 'cd "\BIOS\'"${PK_DIR//\//\\}"'"'
    printf '%s\n' "$PK_FLASHER $PK_IMAGE"
    printf '%s\n' 'echo " "'
    printf '%s\n' 'echo "Dynabook'"'"'s flasher has stopped: its message is above."'
    printf '%s\n' ":DONE"
    printf '%s\n' 'echo "Press any key to restart back to the toolkit."'
    printf '%s\n' "pause -q"
    printf '%s\n' "reset"
  } | sed 's/$/\r/' > "$f"
}

prepare() {   # 0 ready to restart; 1 with PREP_WHY
  local shell_n back_n=""
  PREP_WHY=""
  remount_storage_rw || { PREP_WHY="DIAGDATA cannot be written"; return 1; }
  mkdir -p "$STORAGE_MNT/$DIAG_SUB" \
    && cp "$SHELL_EFI" "$STORAGE_MNT/$DIAG_SUB/shellx64.efi" \
    && printf 'serial=%s\nmodel=%s\nfrom=%s\nto=%s\npackage=%s\nwhen=%s\n' "$(serial)" "$PK_MODEL" \
         "$PK_CUR" "$PK_VER" "$PK_FOLDER" "$(date '+%F %H:%M')" > "$STORAGE_MNT/$DIAG_SUB/pending.txt" \
    || { PREP_WHY="the files could not be written to DIAGDATA"; undo_prepare; return 1; }
  if find_back; then
    back_n=$(efi_make "$LABEL_BACK" "$BACK_DISK" "$BACK_NUM" '\EFI\BOOT\BOOTX64.EFI') || back_n=""
    # the Shell's entry is spared as the next boot; this one must last a
    # boot longer. Never the Shell's: listed, a forgotten one could start
    # the flasher again by itself.
    [ -n "$back_n" ] && { efi_order_last "$back_n" || back_n=""; }
  fi
  BACK_SET=$back_n
  [ -n "$back_n" ] || blog "no way back to the stick set: the firmware's own boot order after the flash"
  # all of it on the stick, or nothing started: a short or missing script
  # leaves the laptop at the Shell's prompt with no way back (review, 1.28)
  write_script "$back_n"
  sync
  grep -q '^reset' "$STORAGE_MNT/$DIAG_SUB/startup.nsh" 2>/dev/null \
    || { PREP_WHY="the start script could not be written to DIAGDATA"; undo_prepare; return 1; }
  shell_n=$(efi_make "$LABEL_SHELL" "$DD_DISK" "$DD_NUM" '\BIOS\.diag\shellx64.efi') \
    || { PREP_WHY="the laptop's firmware did not take the boot entry (efibootmgr: $(tail -1 "$LOG"))"; undo_prepare; return 1; }
  efibootmgr -q -n "$shell_n" >> "$LOG" 2>&1 \
    || { PREP_WHY="the laptop's firmware did not take the next boot (efibootmgr: $(tail -1 "$LOG"))"; undo_prepare; return 1; }
  blog "prepared: $PK_FOLDER for $(serial), $PK_CUR -> $PK_VER; Shell Boot$shell_n next, back Boot${back_n:-none}"
  return 0
}

restart_countdown() {   # 0 = restart now, 1 = cancelled
  local i r
  for ((i = 10; i > 0; i--)); do
    tui_frame "BIOS update" "Q = cancel"
    tui_kv 7 "Package" "$PK_FOLDER"
    tui_kv 8 "BIOS" "$PK_CUR  ->  $PK_VER" accent
    tui_line 10 "Restarting into Dynabook's flasher in ${i}s." accent
    r=$(tui_para 12 "Do not unplug the charger or the USB stick until the laptop is back in the toolkit." warn)
    [ -n "$BACK_SET" ] || tui_para $((r + 1)) "The way back to this stick could not be set: after the update, start the stick with F12." warn >/dev/null
    tui_flush
    tui_wait_key 1
    case "$TUI_KEY" in q|esc) return 1 ;; esac
  done
  return 0
}

bios_screen() {
  if [ ! -d /sys/firmware/efi/efivars ]; then
    tui_msg "BIOS update" "The toolkit was started in legacy (CSM) mode." "" \
      "A BIOS update starts a UEFI program: start the toolkit in UEFI mode (F12, the UEFI entry for the stick)."
    return 0
  fi
  if ! find_diagdata; then
    if [ -n "$DD_FS" ]; then
      tui_msg "BIOS update" "DIAGDATA is $DD_FS - the laptop's firmware reads only FAT32." "" \
        "Copy its files off, format it FAT32 with the label DIAGDATA, and copy them back." \
        "The BIOS packages go in its folder BIOS."
    else
      tui_msg "BIOS update" "No DIAGDATA partition (FAT32) was found on a USB stick." "" \
        "The BIOS packages go in the folder BIOS on DIAGDATA, one folder per package as Dynabook names it."
    fi
    return 0
  fi
  STORAGE_DEV=$DD_DEV
  if ! mount_storage_ro; then
    tui_msg "Cannot open DIAGDATA" "$(head -1 "$RUN_DIR/mnterr" 2>/dev/null)"
    return 0
  fi
  local rc
  while :; do
    pick_package || { umount_storage; return 0; }
    while :; do
      check_page; rc=$?
      [ "$rc" = 1 ] || break
      tui_confirm "Not ready" yes "The update cannot start yet - see the red lines." "" "Check again?" \
        || { umount_storage; return 0; }
    done
    [ "$rc" = 0 ] && break                     # 2: Q, back to the packages
  done
  if grep -q '^RESULT:' "$REPORT_TXT" 2>/dev/null; then
    tui_confirm "Save the report first?" yes "The restart ends this session: the results not saved are lost." "" \
      "Save the report now?" && /opt/diag/savereport.sh
  fi
  tui_input "Type UPDATE" "Type UPDATE to update this laptop's BIOS to $PK_VER with Dynabook's flasher - anything else cancels:"
  if [ "$(upper "$TUI_TEXT")" != UPDATE ]; then      # as ERASE and SHRINK (imaging.sh)
    tui_msg "BIOS update" "Cancelled - nothing was changed."
    umount_storage; return 0
  fi
  tui_frame "BIOS update" ""; tui_line 6 "Getting the stick ready..." muted; tui_flush
  if ! prepare; then
    say_wrapped "BIOS update" "It could not be started: $PREP_WHY." "" "Nothing was changed."
    umount_storage; return 0
  fi
  if ! restart_countdown; then
    undo_prepare
    tui_msg "BIOS update" "Cancelled - nothing was changed."
    umount_storage; return 0
  fi
  rsection "BIOS UPDATE"
  rsilent "Started: $PK_FOLDER - BIOS $PK_CUR to $PK_VER with Dynabook's flasher (the result is checked when the toolkit starts again)"
  sync; umount_storage
  blog "restarting into the flasher"
  systemctl reboot 2>>"$LOG" || reboot
  sleep 30
}

# ---------------------------------------------------------------- back again
bios_result() {
  local note serial_was from to pkg now
  efi_forget                    # whatever follows: no entry of ours outlives this start
  find_diagdata || return 0
  STORAGE_DEV=$DD_DEV
  mount_storage_ro || return 0
  note=$STORAGE_MNT/$DIAG_SUB/pending.txt
  if [ ! -f "$note" ]; then umount_storage; return 0; fi
  serial_was=$(sed -n 's/^serial=//p' "$note"); from=$(sed -n 's/^from=//p' "$note")
  to=$(sed -n 's/^to=//p' "$note"); pkg=$(sed -n 's/^package=//p' "$note")
  if [ "$serial_was" != "$(serial)" ]; then    # another laptop's update: its own start will say
    blog "a note for $serial_was, this is $(serial): left for that laptop"
    umount_storage; return 0
  fi
  now=$($BP current)
  rsection "BIOS UPDATE -- $pkg"
  rsilent "Before : $from"
  rsilent "Now    : ${now:-unknown}  (expected $to)"
  if [ "$now" = "$to" ]; then
    rsilent "RESULT: PASS -- BIOS updated from $from to $to"
    set_kv BIOS_RESULT "PASS ($from -> $to)"
    tui_frame "BIOS update" "Enter to go on"
    tui_badge 6 PASS "BIOS updated: $from -> $to"
    tui_kv 8 "Package" "$pkg"
  else
    rsilent "RESULT: FAIL -- BIOS still ${now:-unknown}, the update to $to did not apply"
    set_kv BIOS_RESULT "FAIL (still ${now:-unknown})"
    tui_frame "BIOS update" "Enter to go on"
    tui_badge 6 FAIL "still ${now:-unknown} - the update to $to did not apply"
    tui_kv 8 "Package" "$pkg"
    tui_para 10 "If Dynabook's flasher stopped, its message was on the screen before the restart. Plugged in, and on a full enough battery, it can be started again from tile 20." muted >/dev/null
  fi
  tui_flush
  tui_anykey
  remount_storage_rw && undo_prepare
  blog "result: $pkg $from -> ${now:-unknown} (expected $to)"
  umount_storage
  return 0
}

case "${1:-}" in
  --result) bios_result ;;
  *)        bios_screen ;;
esac
exit 0
