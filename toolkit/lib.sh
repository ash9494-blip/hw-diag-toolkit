#!/bin/bash
# Common library for the Hardware Diagnostic Toolkit
# shellcheck disable=SC2034

# fd 8 holds menu.sh's "toolkit is running" lock. Every script sources this
# file, so closing it here stops daemons the tests start (wpa_supplicant,
# dhclient) from inheriting the lock and keeping it after the menu restarts -
# which left the menu unable to come back after the Command prompt.
# menu.sh sources this before it takes the lock, so it is unaffected.
exec 8>&- 2>/dev/null

DIAG_VERSION="1.11.0"
RUN_DIR=/run/diag
REPORT_TXT="$RUN_DIR/report.txt"
SUMMARY_KV="$RUN_DIR/summary.kv"
mkdir -p "$RUN_DIR"

# ---------- terminal ----------
if [ -t 1 ]; then
  C_RST=$'\e[0m'; C_B=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_CYN=$'\e[36m'; C_MAG=$'\e[35m'
else
  C_RST=""; C_B=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_MAG=""
fi

hdr() {
  printf '%s\n' "${C_CYN}${C_B}================================================================================${C_RST}"
  printf '%s\n' "${C_CYN}${C_B}  $*${C_RST}"
  printf '%s\n' "${C_CYN}${C_B}================================================================================${C_RST}"
}

sub() { printf '\n%s\n' "${C_B}-- $* ------------------------------------------------------------${C_RST}"; }
ok()   { printf '%s\n' "${C_GRN}[ PASS ]${C_RST} $*"; }
warn() { printf '%s\n' "${C_YEL}[ WARN ]${C_RST} $*"; }
bad()  { printf '%s\n' "${C_RED}[ FAIL ]${C_RST} $*"; }
info() { printf '%s\n' "${C_DIM}       ${C_RST} $*"; }

pause() { printf '\n%s' "Press ENTER to return to the menu... "; read -r _; }

# ---------- report ----------
# rlog: print to screen AND append to the report
rlog() { printf '%s\n' "$*" | tee -a "$REPORT_TXT"; }
# rsilent: append to report only
rsilent() { printf '%s\n' "$*" >> "$REPORT_TXT"; }
rsection() {
  { echo; echo "================================================================================"
    echo "  $*"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================================"; } >> "$REPORT_TXT"
  hdr "$*"
}
set_kv() { printf '%s=%s\n' "$1" "$2" >> "$SUMMARY_KV"; }

# ---------- operator settings ----------
# Written by settings.sh, read by anything that has a default worth changing.
SETTINGS_FILE=$RUN_DIR/settings.conf
setting_get() {   # key default
  local v
  v=$(awk -F= -v k="$1" '$1==k{print $2; exit}' "$SETTINGS_FILE" 2>/dev/null)
  printf '%s' "${v:-$2}"
}

# ---------- hardware helpers ----------
BOARD_OVERRIDE=$RUN_DIR/board.override

# Firmware values, unless the operator has corrected them. Whitebox laptops
# often report a blank serial, and after a board swap the firmware still claims
# the old identity - both make the report wrong.
dmi() {
  local v
  if [ -r "$BOARD_OVERRIDE" ]; then
    v=$(grep -m1 "^$1=" "$BOARD_OVERRIDE" 2>/dev/null | cut -d= -f2-)
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  fi
  dmidecode -s "$1" 2>/dev/null | grep -v '^#' | head -1 | sed 's/^ *//;s/ *$//'
}

dmi_raw() { dmidecode -s "$1" 2>/dev/null | grep -v '^#' | head -1 | sed 's/^ *//;s/ *$//'; }
dmi_is_override() { [ -r "$BOARD_OVERRIDE" ] && grep -q "^$1=" "$BOARD_OVERRIDE"; }

machine_tag() {
  local m s
  m=$(dmi system-product-name); s=$(dmi system-serial-number)
  [ -z "$m" ] && m="Unknown-System"
  [ -z "$s" ] && s="NoSerial"
  printf '%s_%s' "$(echo "$m" | tr -cs 'A-Za-z0-9' '-' | sed 's/-*$//')" \
                 "$(echo "$s" | tr -cs 'A-Za-z0-9' '-' | sed 's/-*$//')"
}

cpu_model() { grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'; }
cpu_threads() { nproc; }

# Highest current CPU temperature in whole degrees C, or -1 if unreadable.
HWMON_ROOT=${DIAG_HWMON_ROOT:-/sys/class/hwmon}
cpu_temp_c() {
  local best=-1 v n f pass
  for pass in preferred fallback; do
    for h in "$HWMON_ROOT"/hwmon*; do
      [ -r "$h/name" ] || continue
      n=$(cat "$h/name" 2>/dev/null)
      if [ "$pass" = preferred ]; then
        case "$n" in coretemp|k10temp|zenpower|cpu_thermal) ;; *) continue ;; esac
      else
        case "$n" in acpitz|thinkpad|*thermal*) ;; *) continue ;; esac
      fi
      for f in "$h"/temp*_input; do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null) || continue
        case "$v" in ''|*[!0-9-]*) continue ;; esac
        v=$((v / 1000))
        [ "$v" -gt 0 ] && [ "$v" -lt 130 ] && [ "$v" -gt "$best" ] && best=$v
      done
    done
    [ "$best" -gt 0 ] && break
  done
  echo "$best"
}

cpu_temp_source() {
  local n
  for h in "$HWMON_ROOT"/hwmon*; do
    [ -r "$h/name" ] || continue
    n=$(cat "$h/name" 2>/dev/null)
    case "$n" in coretemp|k10temp|zenpower|cpu_thermal) echo "$n"; return ;; esac
  done
  for h in "$HWMON_ROOT"/hwmon*; do
    [ -r "$h/name" ] || continue
    n=$(cat "$h/name" 2>/dev/null)
    case "$n" in acpitz|thinkpad|*thermal*) echo "$n (approximate)"; return ;; esac
  done
  echo "none"
}

# Average current CPU clock in MHz
cpu_mhz() {
  local sum=0 cnt=0 v
  for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
    [ -r "$f" ] || continue
    v=$(cat "$f" 2>/dev/null); case "$v" in ''|*[!0-9]*) continue ;; esac
    sum=$((sum + v / 1000)); cnt=$((cnt + 1))
  done
  if [ "$cnt" -gt 0 ]; then echo $((sum / cnt)); return; fi
  awk -F: '/^cpu MHz/{s+=$2;c++} END{if(c) printf "%d", s/c; else print 0}' /proc/cpuinfo
}

throttle_count() {
  local sum=0 v
  for f in /sys/devices/system/cpu/cpu[0-9]*/thermal_throttle/core_throttle_count \
           /sys/devices/system/cpu/cpu[0-9]*/thermal_throttle/package_throttle_count; do
    [ -r "$f" ] || continue
    v=$(cat "$f" 2>/dev/null); case "$v" in ''|*[!0-9]*) continue ;; esac
    sum=$((sum + v))
  done
  echo "$sum"
}

mem_total_mb() { awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo; }
mem_avail_mb() { awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo; }

# List real physical disks, one per line:  NAME SIZE ROTA TRAN MODEL...
# MODEL comes last because it contains spaces. Pseudo devices and anything
# under 100 MB are skipped, which drops the floppy and card-reader stubs some
# firmware still advertises.
list_disks() {
  lsblk -bdno NAME,SIZE,ROTA,TRAN,MODEL 2>/dev/null | awk '
    $1 ~ /^(loop|sr|ram|zram|fd|md|dm-|nbd)/ { next }
    ($2 + 0) < 104857600 { next }
    {
      b = $2 + 0
      if (b >= 1000000000) size = sprintf("%.0fGB", b / 1000000000)
      else                 size = sprintf("%.0fMB", b / 1000000)
      model = ""
      for (i = 5; i <= NF; i++) model = model (i > 5 ? " " : "") $i
      if (model == "") model = "unknown model"
      printf "%s %s %s %s %s\n", $1, size, $3, ($4 == "" ? "?" : $4), model
    }'
}

# ---------- drive helpers ----------
# A drive that has dropped off the bus keeps its /dev node but reports size 0.
disk_alive() {
  local b; b=$(blockdev --getsize64 "/dev/$1" 2>/dev/null || echo 0)
  [ "${b:-0}" -gt 0 ]
}

# Drive temperature in whole degrees C, or -1. NVMe exposes a hwmon node;
# SATA drives answer over SMART.
disk_temp_c() {
  local dev=$1 h n v
  case "$dev" in
    nvme*)
      for h in /sys/class/hwmon/hwmon*; do
        [ -r "$h/name" ] || continue
        n=$(cat "$h/name" 2>/dev/null)
        [ "$n" = nvme ] || continue
        case "$(readlink -f "$h/device" 2>/dev/null)" in
          *"${dev%%n[0-9]*}"*) ;;
          *) [ -e "/sys/block/$dev/device/device" ] || continue ;;
        esac
        v=$(cat "$h/temp1_input" 2>/dev/null)
        case "$v" in ''|*[!0-9-]*) continue ;; esac
        echo $(( v / 1000 )); return
      done
      ;;
  esac
  v=$(smartctl -A "/dev/$dev" 2>/dev/null \
      | awk '/Temperature_Celsius|Current Drive Temperature|^Temperature:/ {for(i=1;i<=NF;i++) if ($i+0>0 && $i+0<120) {print $i+0; exit}}' | head -1)
  case "$v" in ''|*[!0-9]*) echo -1 ;; *) echo "$v" ;; esac
}

# Kernel-log lines newer than a mark, without clearing the ring buffer.
#
# Clearing it (dmesg -C) was how a test used to isolate its own messages, and it
# threw away the boot-time record every other test depends on - the firmware
# fetcher reads exactly those "direct firmware load failed" lines, and after a
# clear it found nothing to download. Take a mark instead and filter by it.
dmesg_mark() { dmesg 2>/dev/null | tail -1 | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p'; }
dmesg_since() {   # mark
  local mark=${1:-0}
  dmesg 2>/dev/null | awk -v m="${mark:-0}" '
    match($0, /^\[ *[0-9.]+\]/) {
      t = substr($0, RSTART+1, RLENGTH-2) + 0
      if (t > m) print
      next
    }
    { print }'
}

# Append the tail of the kernel log to the report - the only place that says
# why a drive vanished or a controller reset.
capture_dmesg() {
  rsilent ""
  rsilent "--- kernel log (last ${1:-60} lines) ---"
  dmesg 2>/dev/null | tail -"${1:-60}" | sed 's/^/  /' >> "$REPORT_TXT"
  rsilent "--- end kernel log ---"
}

disk_bytes() { blockdev --getsize64 "/dev/$1" 2>/dev/null || echo 0; }

# ---------- storage for things that must survive a power cut ----------
# Requires tui.sh to be sourced. Sets STORAGE_DEV, and STORAGE_MNT once mounted.
STORAGE_MNT=/mnt/diagdata

pick_storage() {
  local d
  d=$(blkid -L DIAGDATA 2>/dev/null) && [ -n "$d" ] && { STORAGE_DEV=$d; return 0; }
  local -a names=() labels=()
  local name size fs label rm
  while read -r name size fs label rm; do
    case "$fs" in vfat|exfat|ntfs|ext2|ext3|ext4) ;; *) continue ;; esac
    names+=("/dev/$name")
    labels+=("$(printf '/dev/%-9s %-9s %-7s %-14s %s' "$name" "$size" "$fs" "${label:-no-label}" \
      "$([ "$rm" = 1 ] && echo removable || echo internal)")")
  done < <(lsblk -rno NAME,SIZE,FSTYPE,LABEL,RM 2>/dev/null | awk '$1 !~ /^(loop|sr|ram)/')
  if [ ${#names[@]} -eq 0 ]; then
    tui_msg "Nowhere to write" "No writable partition was found." "" \
      "Plug in a USB stick formatted FAT32, exFAT or NTFS." \
      "Label a partition DIAGDATA and it is picked automatically."
    return 1
  fi
  tui_menu "${STORAGE_PROMPT:-Where should this be saved?}" \
    "label a partition DIAGDATA to skip this step next time" "${labels[@]}" || return 1
  STORAGE_DEV=${names[$((TUI_CHOICE-1))]}
  return 0
}

# Mounting the target has three cases worth handling: the partition may already
# be mounted somewhere (the boot medium always is), our own mount point may be
# stale from an earlier attempt, or it may genuinely need mounting. Trying to
# mount an already-mounted device is what produced "already mounted or mount
# point busy".
STORAGE_OWNED=0

storage_existing_mount() {
  findmnt -rno TARGET --source "$STORAGE_DEV" 2>/dev/null | head -1
}

storage_writable() {
  touch "$STORAGE_MNT/.diagw" 2>/dev/null || return 1
  rm -f "$STORAGE_MNT/.diagw"
  return 0
}

_mount_storage() {   # $1 = "ro" for a read-only mount
  local existing
  existing=$(storage_existing_mount)
  if [ -n "$existing" ]; then
    STORAGE_MNT=$existing
    STORAGE_OWNED=0
    [ "$1" = ro ] && return 0
    storage_writable && return 0
    mount -o remount,rw "$STORAGE_MNT" 2>"$RUN_DIR/mnterr"
    storage_writable && return 0
    echo "$STORAGE_DEV is mounted read-only at $STORAGE_MNT" > "$RUN_DIR/mnterr"
    return 1
  fi

  STORAGE_MNT=/mnt/diagdata
  mkdir -p "$STORAGE_MNT"
  mountpoint -q "$STORAGE_MNT" && umount -l "$STORAGE_MNT" 2>/dev/null
  if [ "$1" = ro ]; then
    mount -o ro "$STORAGE_DEV" "$STORAGE_MNT" 2>"$RUN_DIR/mnterr" || return 1
  else
    mount "$STORAGE_DEV" "$STORAGE_MNT" 2>"$RUN_DIR/mnterr" || return 1
  fi
  STORAGE_OWNED=1
  [ "$1" = ro ] && return 0
  storage_writable && return 0
  umount "$STORAGE_MNT" 2>/dev/null; STORAGE_OWNED=0
  echo "$STORAGE_DEV mounted, but nothing can be written to it" > "$RUN_DIR/mnterr"
  return 1
}

mount_storage()    { _mount_storage ""; }
mount_storage_ro() { _mount_storage ro; }
remount_storage_rw() { mount -o remount,rw "$STORAGE_MNT" 2>/dev/null; storage_writable; }

# Only ever unmount what we mounted ourselves; never yank the boot medium.
umount_storage() {
  sync
  [ "$STORAGE_OWNED" = 1 ] && umount "$STORAGE_MNT" 2>/dev/null
  STORAGE_OWNED=0
}

need_root() { [ "$(id -u)" = 0 ] || { bad "Must run as root"; exit 1; }; }

# Keep the kernel from scribbling over the interface. Firmware on some laptops
# emits a continuous stream of ACPI errors, and hung-task warnings appear
# whenever a test puts the machine under heavy memory pressure; both are noise
# here and both stay available in dmesg for the report.
console_quiet() {
  echo 1 4 1 3          > /proc/sys/kernel/printk              2>/dev/null
  echo 0                > /proc/sys/kernel/hung_task_timeout_secs 2>/dev/null
  setterm -blank 0 -powersave off 2>/dev/null   # long tests must not blank the screen
  setterm -term linux -blank 0 </dev/tty1 >/dev/tty1 2>/dev/null
}

secs_hms() { printf '%d:%02d:%02d' $(( $1/3600 )) $(( ($1%3600)/60 )) $(( $1%60 )); }
secs_ms()  { printf '%d min %02d s' $(( $1/60 )) $(( $1%60 )); }

# ---------------------------------------------------------------- wireless scan
# One scan routine for the Wi-Fi page and the wireless test.
#
# A single bare `iw scan` was not enough on real hardware: straight after the
# interface is brought up an Intel card can answer "Device or resource busy"
# or return nothing, and a scan that stalls had no time limit at all, so the
# screen sat on "scanning" for ever. This waits for the interface, puts a limit
# on every attempt, retries, falls back to the results the kernel already
# holds, and leaves the real reason in WIFI_SCAN_ERR when all of that fails.
#
# If the caller defines wifi_scan_progress(attempt, last_error), it is called
# before each attempt so the screen can say what is happening.
WIFI_SCAN_LOG=$RUN_DIR/wifi_scan.log

_wifi_parse_scan() {   # raw-file out-file
  awk '
    /^BSS /            { if (inbss) emit(); inbss=1; sig=""; fr=""; ssid=""; enc="open" }
    /signal:/          { sig=$2+0 }
    /freq:/            { if (fr == "") fr=$2+0 }
    /^\tSSID:/         { ssid=substr($0,8) }
    /RSN:/             { enc="WPA2/3" }
    /WPA:/             { if (enc=="open") enc="WPA" }
    /Privacy/          { if (enc=="open") enc="WEP" }
    END                { if (inbss) emit() }
    function emit() {
      gsub(/\t/, " ", ssid)
      if (ssid ~ /^[ \t]*$/) ssid="(hidden)"
      printf "%d\t%d\t%s\t%s\n", sig, fr, enc, ssid
    }' "$1" | sort -t$'\t' -rn -k1,1 | awk -F'\t' '!seen[$4]++' > "$2"
}

wifi_scan_tsv() {   # iface out-file -> 0 when at least one access point was heard
  local i=$1 out=$2 raw=$RUN_DIR/wifi_scan.raw err=$RUN_DIR/wifi_scan.err n rc
  WIFI_SCAN_ERR=""
  : > "$out"
  printf '%s scan on %s\n' "$(date +%T)" "$i" >> "$WIFI_SCAN_LOG"

  ip link set "$i" up 2>>"$WIFI_SCAN_LOG"
  # give the firmware a moment to finish coming up before the first scan
  for n in 1 2 3 4 5; do
    ip link show "$i" 2>/dev/null | grep -q '<[^>]*UP' && break
    sleep 1
  done
  sleep 1

  for n in 1 2 3; do
    declare -F wifi_scan_progress >/dev/null && wifi_scan_progress "$n" "$WIFI_SCAN_ERR"
    timeout 25 iw dev "$i" scan > "$raw" 2> "$err"; rc=$?
    _wifi_parse_scan "$raw" "$out"
    printf '  attempt %d: rc=%d, %d AP(s), %s\n' "$n" "$rc" "$(wc -l < "$out")" \
      "$(head -1 "$err" 2>/dev/null)" >> "$WIFI_SCAN_LOG"
    [ -s "$out" ] && return 0
    if [ "$rc" = 124 ]; then
      WIFI_SCAN_ERR="the scan did not finish within 25 seconds"
    elif [ -s "$err" ]; then
      WIFI_SCAN_ERR=$(head -1 "$err")
    else
      WIFI_SCAN_ERR="the radio heard no access points"
    fi
    sleep 3
  done

  # Last resort: whatever the kernel already learnt from earlier scans.
  timeout 10 iw dev "$i" scan dump > "$raw" 2>/dev/null
  _wifi_parse_scan "$raw" "$out"
  printf '  cached results: %d AP(s)\n' "$(wc -l < "$out")" >> "$WIFI_SCAN_LOG"
  [ -s "$out" ]
}

# Plain-language reading of a scan failure, for the screen.
wifi_scan_explain() {
  case "$WIFI_SCAN_ERR" in
    *busy*|*"-16"*)  echo "The card stayed busy - another scan or connection attempt was running." ;;
    *"-19"*|*"No such device"*) echo "The adapter disappeared while scanning - the card or its driver reset." ;;
    *"-100"*|*"Network is down"*) echo "The adapter would not come up - check the wireless switch or BIOS setting." ;;
    *"(-1)"*|*"not permitted"*) echo "The radio refused to scan - usually rfkill or a regulatory lock." ;;
    *"25 seconds"*)  echo "The scan never finished - the card or its firmware stopped answering." ;;
    *"heard no"*)    echo "The radio works but heard nothing - suspect the antenna leads." ;;
    *)               echo "$WIFI_SCAN_ERR" ;;
  esac
}
