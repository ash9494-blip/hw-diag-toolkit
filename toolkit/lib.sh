#!/bin/bash
# Common library for the Hardware Diagnostic Toolkit
# shellcheck disable=SC2034

# fd 8 holds menu.sh's "toolkit is running" lock. Every script sources this
# file, so closing it here stops daemons the tests start (wpa_supplicant,
# dhclient) from inheriting the lock and keeping it after the menu restarts -
# which left the menu unable to come back after the Command prompt.
# menu.sh sources this before it takes the lock, so it is unaffected.
#
# Only fd 8. This line once read `exec 8>&- 2>/dev/null`, and a bare exec
# makes every redirection permanent: stderr went to /dev/null in every script,
# including the bash behind Command prompt - which then decided it was not
# interactive, showed no prompt, echoed arrow keys as ^[[A and swallowed every
# error message. Closing an fd that is not open is not an error, so nothing
# needs silencing here.
exec 8>&-

DIAG_VERSION="1.15.0"
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
set_kv() {
  printf '%s=%s\n' "$1" "$2" >> "$SUMMARY_KV"
  # When it was written, for the parts list on the home screen ("PASS 14:02").
  printf '%s %s\n' "$1" "$(date +%H:%M)" >> "$RUN_DIR/results.at"
}

# A test's latest verdict as the home screen shows it: "PASS 14:02",
# "FAIL 14:31", or nothing when it has not run since boot. The first key that
# has a value wins, so a tile can fall back to a lesser result (the drive's
# SMART health when no benchmark has run).
test_result() {   # KEY...
  local k v t
  for k in "$@"; do
    v=$(grep "^$k=" "$SUMMARY_KV" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "$v" ] || continue
    t=$(awk -v k="$k" '$1==k{t=$2} END{print t}' "$RUN_DIR/results.at" 2>/dev/null)
    v=${v%%[ (]*}
    case "$v" in
      PASSED) v=PASS ;;  FAILED) v=FAIL ;;  NOT) v="NOT TESTED" ;;  INCOMPLETE) v=PART ;;
    esac
    printf '%s %s' "$v" "$t"
    return 0
  done
  return 0
}

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

pcie_gen() {
  case "${1%% *}" in
    2.5) echo "1.0" ;; 5.0|5) echo "2.0" ;; 8.0|8) echo "3.0" ;;
    16.0|16) echo "4.0" ;; 32.0|32) echo "5.0" ;; 64.0|64) echo "6.0" ;;
    *) echo "" ;;
  esac
}

# What an NVMe drive's link is doing now, against what the drive and the
# laptop's slot can each do. Sets PCIE_NOW ("PCIe 4.0 x4"), PCIE_NOTE (one
# line of explanation, empty when all is as it should be) and PCIE_TONE.
pcie_link() {   # bdf
  local d=/sys/bus/pci/devices/$1 up cs cw ms mw ss sw g gm gs
  PCIE_NOW=""; PCIE_NOTE=""; PCIE_TONE=ok; PCIE_DRIVE=""; PCIE_SLOT=""
  cs=$(cat "$d/current_link_speed" 2>/dev/null); cw=$(cat "$d/current_link_width" 2>/dev/null)
  ms=$(cat "$d/max_link_speed" 2>/dev/null);     mw=$(cat "$d/max_link_width" 2>/dev/null)
  up=$(readlink -f "$d/.." 2>/dev/null)
  ss=$(cat "$up/max_link_speed" 2>/dev/null);    sw=$(cat "$up/max_link_width" 2>/dev/null)
  g=$(pcie_gen "$cs"); gm=$(pcie_gen "$ms"); gs=$(pcie_gen "$ss")
  [ -n "$g" ] || return 1
  PCIE_NOW="PCIe $g x${cw:-?}  (${cs%% PCIe})"
  [ -n "$gm" ] && PCIE_DRIVE="PCIe $gm x${mw:-?}"
  [ -n "$gs" ] && PCIE_SLOT="PCIe $gs x${sw:-?}"

  # The link trains to the lower of the two ends. Below that is a fault.
  local best=$gm bestw=${mw:-0}
  if [ -n "$gs" ] && awk -v a="$gs" -v b="$gm" 'BEGIN{exit !(b=="" || a<b)}'; then best=$gs; fi
  [ -n "$sw" ] && [ "${sw:-0}" -lt "$bestw" ] 2>/dev/null && bestw=$sw
  if [ -n "$best" ] && awk -v c="$g" -v b="$best" 'BEGIN{exit !(c<b)}'; then
    PCIE_TONE=warn
    PCIE_NOTE="running below the PCIe $best both ends support - reseat the drive, check the M.2 contacts"
  elif [ "$bestw" -gt 0 ] 2>/dev/null && [ "${cw:-0}" -lt "$bestw" ] 2>/dev/null; then
    PCIE_TONE=warn
    PCIE_NOTE="only x$cw of x$bestw lanes trained - reseat the drive, check the M.2 contacts"
  elif [ -n "$gm" ] && [ -n "$gs" ] && awk -v s="$gs" -v m="$gm" 'BEGIN{exit !(s<m)}'; then
    PCIE_NOTE="drive can do PCIe $gm; this laptop's slot tops out at PCIe $gs - normal"
  fi
  return 0
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

# Security is read from the authentication suites, not from the mere presence
# of an RSN element. Every network used to come out as "WPA2/3", which hid the
# two cases that cannot be joined the ordinary way: WPA3-only (needs SAE, and a
# WPA2 key is simply refused) and Enterprise (needs a username, not a password).
#
# The SSID stays exactly as iw printed it, with unprintable bytes as \xNN, so
# it can be turned back into the real bytes when joining. A network that
# broadcasts a run of zero bytes is hiding its name the other way, and was
# listed as "\x00\x00\x00..." - it counts as hidden now.
_wifi_parse_scan() {   # raw-file out-file
  awk '
    /^BSS /            { if (inbss) emit(); inbss=1; sig=""; fr=""; ssid=""
                         rsn=0; wpa=0; priv=0; akm="" }
    /signal:/          { sig=$2+0 }
    /freq:/            { if (fr == "") fr=$2+0 }
    /^\tSSID:/         { ssid=substr($0,8) }
    /^\tRSN:/          { rsn=1 }
    /^\tWPA:/          { wpa=1 }
    /Authentication suites:/ { akm = akm " " substr($0, index($0, ":") + 1) }
    /capability:.*Privacy/   { priv=1 }
    END                { if (inbss) emit() }
    function emit(  enc) {
      gsub(/\t/, " ", ssid)
      if (ssid ~ /^[ \t]*$/ || ssid ~ /^(\\x00)+$/) ssid="(hidden)"
      enc="open"
      if (akm ~ /802\.1X/ && akm !~ /PSK|SAE/)      enc="Enterprise"
      else if (akm ~ /OWE/ && akm !~ /PSK|SAE/)     enc="OWE"
      else if (rsn && akm ~ /SAE/ && akm ~ /PSK/)   enc="WPA2/3"
      else if (rsn && akm ~ /SAE/)                  enc="WPA3"
      else if (rsn)                                 enc="WPA2"
      else if (wpa)                                 enc="WPA"
      else if (priv)                                enc="WEP"
      printf "%d\t%d\t%s\t%s\n", sig, fr, enc, ssid
    }' "$1" | sort -t$'\t' -rn -k1,1 | awk -F'\t' '!seen[$4]++' > "$2"
}

# The SSID for people: \xNN turned back into bytes (so a name in Chinese or
# with an emoji reads properly) with control characters dropped, and "|"
# swapped out because it separates the columns of a menu entry.
wifi_ssid_show() { printf '%b' "$1" | tr -d '\000-\037\177' | tr '|' '/'; }
# The SSID for wpa_supplicant: the exact bytes, as hex, so quotes, spaces and
# non-ASCII in a network name cannot break the config file.
wifi_ssid_hex()  { printf '%b' "$1" | od -An -tx1 -v | tr -d ' \n'; }

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

# ---------------------------------------------------------------- wireless join
# One way of getting onto a network, for the Wi-Fi page.
#
# The first version on a real TECRA A40-J (AX201) associated and then reported
# "the network gave out no address" every time. Three things in it were wrong:
#   * dhclient was run with -timeout, which is a Fedora patch. Ubuntu's
#     dhclient rejects the unknown option and exits at once, so no request
#     was ever sent - and 2>/dev/null threw the complaint away.
#   * "associated" was taken from `iw link`, which shows the SSID as soon as
#     the radio has joined - before the WPA handshake. Until the handshake
#     finishes the access point drops every packet, a DHCP request included,
#     and a wrong password looked exactly like a silent DHCP server.
#   * nothing was logged, so the screen was all there was to go on.
# Now the handshake is waited for through wpa_supplicant's own state, a wrong
# password is recognised as one, DHCP runs with a hard limit and a retry, and
# every step lands in the Toolkit log on the power menu.
#
# If the caller defines wifi_join_progress(text), it is called as things move.
WIFI_JOIN_LOG=$RUN_DIR/wifi_join.log
WPA_CTRL=/run/wpa_supplicant

_wj_log()      { printf '%s %s\n' "$(date +%T)" "$*" >> "$WIFI_JOIN_LOG"; }
_wj_progress() { declare -F wifi_join_progress >/dev/null && wifi_join_progress "$1"; return 0; }
wifi_has_ipv4() { ip -4 addr show "$1" 2>/dev/null | grep -q 'inet '; }

wifi_wpa_state() {   # iface -> COMPLETED, 4WAY_HANDSHAKE, SCANNING, ... or empty
  wpa_cli -p "$WPA_CTRL" -i "$1" status 2>/dev/null | sed -n 's/^wpa_state=//p'
}

# Take down whatever an earlier attempt left running on this interface.
wifi_leave() {   # iface
  local i=$1 pf=/run/dhclient.$1.pid
  [ -r "$pf" ] && kill "$(cat "$pf")" 2>/dev/null
  rm -f "$pf"
  pkill -x wpa_supplicant 2>/dev/null
  pkill -x udhcpc 2>/dev/null
  sleep 1
  ip addr flush dev "$i" 2>/dev/null
}

# Writes the network block. Returns 1 with WIFI_JOIN_ERR set when the password
# cannot possibly work, so that is said before anything is attempted.
_wifi_write_conf() {   # conf ssid enc password
  local conf=$1 ssid=$2 enc=$3 pass=$4 hex psk
  hex=$(wifi_ssid_hex "$ssid")
  {
    printf 'ctrl_interface=%s\n' "$WPA_CTRL"
    printf 'network={\n\tssid=%s\n\tscan_ssid=1\n' "$hex"
    case "$enc" in
      open) printf '\tkey_mgmt=NONE\n' ;;
      OWE)  printf '\tkey_mgmt=OWE\n\tieee80211w=2\n' ;;
      WEP)
        case "${#pass}" in
          5|13)  printf '\tkey_mgmt=NONE\n\twep_key0="%s"\n\twep_tx_keyidx=0\n' "$pass" ;;
          10|26) printf '\tkey_mgmt=NONE\n\twep_key0=%s\n\twep_tx_keyidx=0\n' "$pass" ;;
          *) WIFI_JOIN_ERR="a WEP key is 5 or 13 characters, or 10 or 26 hex digits"; return 1 ;;
        esac ;;
      WPA3)
        # SAE cannot use a pre-hashed key: the passphrase itself goes in.
        printf '\tkey_mgmt=SAE\n\tieee80211w=2\n\tsae_password="%s"\n' "$pass" ;;
      *)
        # WPA, WPA2 and WPA2/3 transition networks: plain PSK is what every
        # card and every access point in transition mode accepts. The key is
        # hashed here so the plaintext never sits in the file.
        psk=$(wpa_passphrase "$(printf '%b' "$ssid")" "$pass" 2>/dev/null \
              | sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p')
        if [ -z "$psk" ]; then
          WIFI_JOIN_ERR="a Wi-Fi password is 8 to 63 characters - that one is ${#pass}"
          return 1
        fi
        printf '\tkey_mgmt=WPA-PSK WPA-PSK-SHA256\n\tieee80211w=1\n\tpsk=%s\n' "$psk" ;;
    esac
    printf '}\n'
  } > "$conf"
  chmod 600 "$conf" 2>/dev/null
  return 0
}

# Waits for the WPA handshake to finish. 0 once wpa_supplicant says COMPLETED.
_wifi_wait_auth() {   # iface wpa-log
  local i=$1 wlog=$2 n st last=""
  for n in $(seq 1 30); do
    sleep 1
    st=$(wifi_wpa_state "$i")
    [ "$st" != "$last" ] && { _wj_log "  wpa state: ${st:-unknown}"; last=$st; }
    [ "$st" = COMPLETED ] && return 0
    # No wpa_cli answer at all: fall back to the log line wpa_supplicant
    # writes when the handshake is done.
    [ -z "$st" ] && grep -q 'CTRL-EVENT-CONNECTED' "$wlog" 2>/dev/null && return 0
    if grep -q 'reason=WRONG_KEY\|4-Way Handshake failed\|pre-shared key may be incorrect' \
         "$wlog" 2>/dev/null; then
      WIFI_JOIN_ERR="the password was rejected"; return 1
    fi
    if [ "$(grep -c 'CTRL-EVENT-ASSOC-REJECT' "$wlog" 2>/dev/null)" -ge 3 ]; then
      WIFI_JOIN_ERR="the access point refused the connection ($(grep -o 'status_code=[0-9]*' "$wlog" | tail -1))"
      return 1
    fi
    if [ "$n" -ge 15 ] && grep -q 'CTRL-EVENT-NETWORK-NOT-FOUND' "$wlog" 2>/dev/null \
         && [ "$st" = SCANNING ]; then
      WIFI_JOIN_ERR="the network is no longer in range"; return 1
    fi
    case "$st" in
      ASSOCIATING|ASSOCIATED) _wj_progress "joining the access point... ${n}s" ;;
      4WAY_HANDSHAKE|GROUP_HANDSHAKE) _wj_progress "checking the password... ${n}s" ;;
      *) _wj_progress "looking for the access point... ${n}s" ;;
    esac
  done
  WIFI_JOIN_ERR="the access point did not finish the connection within 30 seconds"
  return 1
}

# The plain reason DHCP failed, read from dhclient's own output.
_wifi_dhcp_explain() {   # dhcp-log
  local f=$1
  if grep -q 'Unknown command\|Usage:' "$f" 2>/dev/null; then
    echo "the address client refused its options (see the Toolkit log)"
  elif grep -q 'not found' "$f" 2>/dev/null; then
    echo "no DHCP client is installed in this image"
  elif grep -q 'DHCPOFFER of' "$f" 2>/dev/null; then   # not "No DHCPOFFERS received"
    echo "an address was offered but never confirmed - a busy or misconfigured DHCP server"
  elif grep -q 'DHCPDISCOVER' "$f" 2>/dev/null; then
    echo "nothing on that network answered the request for an address"
  else
    echo "the address request could not be sent"
  fi
}

wifi_dhcp() {   # iface -> 0 once an IPv4 address is held
  local i=$1 n pf=/run/dhclient.$1.pid lf=/var/lib/dhcp/dhclient.$1.leases
  local dlog=$RUN_DIR/dhcp.$1.log
  mkdir -p /var/lib/dhcp
  for n in 1 2; do
    _wj_progress "asking the network for an address (attempt $n of 2)..."
    # dhclient -1 goes to the background once it holds a lease, so timeout only
    # ever cuts off a request nobody answered.
    timeout 30 dhclient -1 -v -pf "$pf" -lf "$lf" "$i" > "$dlog" 2>&1
    _wj_log "  dhclient attempt $n, rc=$?"
    sed 's/^/    /' "$dlog" >> "$WIFI_JOIN_LOG"
    wifi_has_ipv4 "$i" && return 0
    if [ "$(wifi_wpa_state "$i")" != COMPLETED ] \
         && ! grep -q 'CTRL-EVENT-CONNECTED' "$RUN_DIR/wpa.log" 2>/dev/null; then
      WIFI_JOIN_ERR="the link dropped while waiting for an address - suspect the antenna leads"
      return 1
    fi
  done
  # A second, unrelated client, in case the fault is in dhclient's own
  # scripts rather than on the network.
  if command -v udhcpc >/dev/null; then
    _wj_progress "trying the backup address client..."
    timeout 25 udhcpc -i "$i" -n -q -t 6 >> "$WIFI_JOIN_LOG" 2>&1
    _wj_log "  udhcpc rc=$?"
    wifi_has_ipv4 "$i" && return 0
  fi
  WIFI_JOIN_ERR=$(_wifi_dhcp_explain "$dlog")
  return 1
}

wifi_join() {   # iface ssid(as scanned) enc password -> 0 when online
  local i=$1 ssid=$2 enc=$3 pass=$4
  local conf=$RUN_DIR/wpa.conf wlog=$RUN_DIR/wpa.log
  WIFI_JOIN_ERR=""
  _wj_log "join $(wifi_ssid_show "$ssid") on $i ($enc)"
  if [ "$enc" = Enterprise ]; then
    WIFI_JOIN_ERR="this is a company (802.1X) network - it needs a username, not just a password"
    _wj_log "  refused: $WIFI_JOIN_ERR"; return 1
  fi
  _wifi_write_conf "$conf" "$ssid" "$enc" "$pass" || { _wj_log "  refused: $WIFI_JOIN_ERR"; return 1; }

  wifi_leave "$i"
  : > "$wlog"
  ip link set "$i" up 2>>"$WIFI_JOIN_LOG"
  if ! wpa_supplicant -B -i "$i" -c "$conf" -f "$wlog" 2>>"$WIFI_JOIN_LOG"; then
    wpa_supplicant -B -i "$i" -c "$conf" 2>>"$WIFI_JOIN_LOG" || {
      WIFI_JOIN_ERR="wpa_supplicant would not start on $i"; _wj_log "  $WIFI_JOIN_ERR"; return 1; }
  fi

  if ! _wifi_wait_auth "$i" "$wlog"; then
    _wj_log "  failed: $WIFI_JOIN_ERR"
    grep -E 'CTRL-EVENT|WRONG_KEY|Handshake|reason=' "$wlog" 2>/dev/null | tail -8 \
      | sed 's/^/    /' >> "$WIFI_JOIN_LOG"
    return 1
  fi
  _wj_log "  handshake complete"
  if ! wifi_dhcp "$i"; then
    _wj_log "  failed: $WIFI_JOIN_ERR"; return 1
  fi
  _wj_log "  online: $(ip -4 addr show "$i" | awk '/inet /{print $2; exit}')"
  return 0
}
