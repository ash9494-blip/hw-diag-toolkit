#!/bin/bash
# Driver check library - sourced by drivercheck.sh after lib.sh and tui.sh.
#
# For every device the buses and the firmware report: is a driver attached,
# and did that driver produce what it should - a sound card, a network
# interface, an input device, a camera. The second question is the one that
# matters: on the TECRA A40-J the sound controller and the touchpad both had a
# driver attached and still gave no sound card and no touchpad, and a plain
# "driver attached" list calls that fine.
#
# Every kernel driver Ubuntu ships for this kernel is already on the image
# (linux-modules + linux-modules-extra, 6,465 of them); only the graphics
# drivers are left out, on purpose (invariant 1). So what the internet can
# supply is firmware, not drivers. A device this kernel has no driver for at
# all needs a newer kernel, and the check says so instead of pretending a
# download could help.
#
# Everything lands in the live system's RAM. Nothing is written to the
# machine being tested; a restart removes all of it.

K=$(uname -r)
FW_DIR=/usr/lib/firmware
DC_TSV=$RUN_DIR/drivers.tsv            # one device per line, fields below
DC_ADDED=$RUN_DIR/drivers-added.list   # files downloaded this session
DC_LOG=$RUN_DIR/drivers.log
DC_DMESG=$RUN_DIR/drivers-dmesg.log
DC_FWMISS=$RUN_DIR/drivers-fwmiss.list # "device|firmware-file"
MIRROR=${DIAG_FW_MIRROR:-http://archive.ubuntu.com/ubuntu}

# drivers.tsv fields, '|' separated:
#   state bus id type name driver ids made detail fix path
# state: OK LOADED FIRMWARE NOOUT UNBOUND OFF NODRIVER NONE BLOCKED

dc_log() { printf '%s %s\n' "$(date +%T)" "$*" >> "$DC_LOG"; }

dc_row() {
  local out="" f
  for f in "$@"; do
    f=${f//|//}; f=${f//$'\n'/ }; f=${f//$'\t'/ }
    out+="$f|"
  done
  printf '%s\n' "${out%|}" >> "$DC_TSV"
}

dc_driver() { [ -L "$1/driver" ] && basename "$(readlink "$1/driver")"; }

# ---------------------------------------------------------------- firmware
# Which Ubuntu package carries a firmware path.
fw_package() {
  case "$1" in
    intel/ibt-*|intel/ice/*|intel/irci*|intel/ipu*) echo linux-firmware-intel-misc ;;
    iwlwifi*|intel/iwlwifi*)                        echo linux-firmware-intel-wireless ;;
    intel/sof*|intel/avs*)                          echo firmware-sof-signed ;;
    rtl_nic/*|rtlwifi/*|rtw88/*|rtw89/*|rtl_bt/*)   echo linux-firmware-realtek ;;
    ath10k/*|ath11k/*|ath12k/*|ath9k*|qca/*)        echo linux-firmware-qualcomm-wireless ;;
    brcm/*|cypress/*)                               echo linux-firmware-broadcom-wireless ;;
    mediatek/*|mt76*|mt79*)                         echo linux-firmware-mediatek ;;
    mrvl/*|libertas/*|mwl8k/*|mwlwifi/*)            echo linux-firmware-marvell-wireless ;;
    amdgpu/*|radeon/*|i915/*|xe/*|nvidia/*)         echo "" ;;   # graphics: never loaded here
    amd/*|amd_sev*|amdtee/*)                        echo linux-firmware-amd-misc ;;
    *)                                              echo linux-firmware-misc ;;
  esac
}

# The package to try when a driver runs, made nothing, and its messages talk
# about firmware without naming a file (ath11k and iwlwifi do this).
dc_driver_package() {
  case "$1" in
    iwlwifi|iwlmvm|iwldvm)          echo linux-firmware-intel-wireless ;;
    ath9k*|ath10k*|ath11k*|ath12k*) echo linux-firmware-qualcomm-wireless ;;
    mt7*|mt76*)                     echo linux-firmware-mediatek ;;
    rtw88*|rtw89*|r8169|rtl8*|btrtl) echo linux-firmware-realtek ;;
    brcmfmac|brcmsmac|bcma*)        echo linux-firmware-broadcom-wireless ;;
    sof-audio*|snd_sof*|snd-sof*)   echo firmware-sof-signed ;;
    btusb|btintel)                  echo linux-firmware-intel-misc ;;
    mwifiex*)                       echo linux-firmware-marvell-wireless ;;
    *)                              echo "" ;;
  esac
}

fw_present() { [ -e "$FW_DIR/$1" ] || [ -e "$FW_DIR/$1.zst" ] || [ -e "$FW_DIR/$1.xz" ]; }

# The kernel log this check reads: the copy taken at boot (the ring buffer
# rolls over during long tests) plus whatever has arrived since.
dc_read_log() {
  { cat "$RUN_DIR/boot-dmesg.log" 2>/dev/null; dmesg 2>/dev/null; } | awk '!seen[$0]++' > "$DC_DMESG"
}

# Every firmware file a driver asked for and still does not have, with the
# device that asked. Drivers print "<driver> <device>: Direct firmware load for
# <file> failed"; iwlwifi asks quietly and only says it found nothing.
dc_find_missing_fw() {
  sed -nE \
    -e 's/^\[[^]]*\] *[^ ]+ ([^ ]+): (Direct firmware load for|firmware: failed to load) ([^ ]+).*/\1|\3/p' \
    -e 's/^\[[^]]*\] *iwlwifi ([^ ]+): no suitable firmware found.*/\1|iwlwifi (no suitable file)/p' \
    "$DC_DMESG" | sort -u | while IFS='|' read -r dev f; do
      [ -n "$f" ] || continue
      case "$f" in iwl-debug-yoyo.bin|regulatory.db*) continue ;; esac   # optional, asked for on every boot
      fw_present "$f" && continue
      printf '%s|%s\n' "$dev" "$f"
    done > "$DC_FWMISS"
}

dc_fw_for() {   # device-token... -> first missing file named against any of them
  local t
  for t in "$@"; do
    [ -n "$t" ] || continue
    awk -F'|' -v d="$t" '$1==d{print $2; exit}' "$DC_FWMISS"
  done | head -1
}

# Why a driver is waiting instead of attaching ("deferred probe"): the
# kernel's own list when debugfs is mounted, else the line it logs when it
# gives up waiting.
dc_deferred_reason() {   # device-id
  local r=""
  [ -r /sys/kernel/debug/devices_deferred ] && \
    r=$(awk -v d="$1" '$1==d { $1=""; sub(/^[ \t]+/, ""); print; exit }' /sys/kernel/debug/devices_deferred 2>/dev/null)
  [ -n "$r" ] || r=$(grep -F " $1: deferred probe pending" "$DC_DMESG" 2>/dev/null | tail -1 | sed 's/.*deferred probe pending: *//')
  printf '%s' "$r"
}

# Intel sound (SOF and HD Audio, 6th gen on) waits for the i915 graphics
# driver to drive HDMI audio. This image has no i915 on purpose (invariant 1),
# so on the TECRA A40-J it waited forever: no sound card at all.
dc_gpu_wait() { printf '%s' "$1" | grep -qiE 'i915|audio component|gfx driver'; }

# The last kernel complaints naming a device.
dc_errors() {
  grep -F " $1: " "$DC_DMESG" 2>/dev/null \
    | grep -iE 'error|fail|timed? ?out|unable|not found|invalid|refused' \
    | grep -v 'iwl-debug-yoyo' | tail -4 | sed -E 's/^\[[^]]*\] *//'
}

# ---------------------------------------------------------------- output
# What a driver produced under its device, by the kind of device it is.
# Prints the names; returns 1 when it should have made something and did not,
# 2 when this kind of device has nothing to show.
dc_made() {   # sysfs-path kind
  local p=$1 x out=""
  case "$2" in
    audio)
      for x in /sys/class/sound/card*; do
        [ -e "$x" ] || continue
        case "$(readlink -f "$x")" in "$p"/*) out+=" ${x##*/}" ;; esac
      done ;;
    net)
      while IFS= read -r x; do out+=" ${x##*/}"; done \
        < <(find "$p" -maxdepth 4 -path '*/net/*' -prune -type d 2>/dev/null) ;;
    input)
      while IFS= read -r x; do out+=", $(cat "$x/name" 2>/dev/null)"; done \
        < <(find "$p" -maxdepth 5 -type d -name 'input[0-9]*' 2>/dev/null)
      out=${out#, } ;;
    video)
      while IFS= read -r x; do out+=" ${x##*/}"; done \
        < <(find "$p" -maxdepth 5 -type d -path '*/video4linux/video*' 2>/dev/null) ;;
    bt)
      while IFS= read -r x; do out+=" ${x##*/}"; done \
        < <(find "$p" -maxdepth 5 -type d -path '*/bluetooth/hci*' -prune 2>/dev/null) ;;
    *) return 2 ;;
  esac
  out=${out# }
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

dc_kind_word() {
  case "$1" in
    audio) echo "sound card" ;;  net) echo "network interface" ;;
    input) echo "input device" ;; video) echo "camera device" ;;
    bt) echo "Bluetooth adapter" ;; *) echo "device" ;;
  esac
}

# ---------------------------------------------------------------- loading
# A device with no driver: load what the image has for it and ask the bus to
# match again. 0 = attached now, 1 = a driver exists but would not attach,
# 2 = nothing in the image matches it.
dc_try_load() {   # bus id modalias
  local bus=$1 id=$2 mods m
  mods=$(modprobe -R "$3" 2>/dev/null | sort -u)
  [ -n "$mods" ] || return 2
  for m in $mods; do
    modprobe -b -q "$m" 2>>"$DC_LOG" || dc_log "modprobe $m failed for $id"
  done
  echo "$id" > "/sys/bus/$bus/drivers_probe" 2>/dev/null
  sleep 0.3
  [ -L "/sys/bus/$bus/devices/$id/driver" ] && { dc_log "$id attached to $(dc_driver "/sys/bus/$bus/devices/$id")"; return 0; }
  dc_log "$id: $mods loaded but did not attach"
  DC_MODS=$mods
  return 1
}

# ---------------------------------------------------------------- judging
# One device, any bus: attach what can be attached, then decide its state.
dc_judge() {   # bus id path type kind name ids modalias none-needed(0|1) [extra fw tokens]
  local bus=$1 id=$2 p=$3 type=$4 kind=$5 name=$6 ids=$7 alias=$8 none=$9
  shift 9
  local drv made st="" detail="" fix="" fw rc
  drv=$(dc_driver "$p")
  if [ -z "$drv" ]; then
    fw=$(dc_fw_for "$id" "$@")
    if [ "$type" = Graphics ]; then
      st=BLOCKED; detail="the screen runs on the firmware display; graphics drivers are left out on purpose"
    else
      rc=2; DC_MODS=""
      [ -n "$alias" ] && { dc_try_load "$bus" "$id" "$alias"; rc=$?; }
      case $rc in
        0) drv=$(dc_driver "$p"); st=LOADED; detail="was not running; started by the driver check" ;;
        1) st=UNBOUND
           local why; why=$(dc_deferred_reason "$id")
           if [ "$type" = Sound ] && dc_gpu_wait "$why $(dc_errors "$id")"; then
             detail="the sound driver is waiting for the Intel graphics driver, which this stick leaves out on purpose"
           elif [ -n "$why" ]; then
             detail="the driver is waiting: $why"
           else
             detail="driver $(echo $DC_MODS) is on the stick but would not take the device"
           fi ;;
        2) if [ "$none" = 1 ]; then st=NONE; detail="nothing here needs a driver"
           else st=NODRIVER; detail="Linux $K has no driver for $ids"; fi ;;
      esac
      if [ -z "$drv" ] && [ -n "$fw" ]; then
        st=FIRMWARE; detail="needs firmware $fw, which is not on the stick"; fix=$(fw_package "$fw")
      fi
    fi
  fi
  if [ -n "$drv" ]; then
    made=$(dc_made "$p" "$kind"); rc=$?
    fw=$(dc_fw_for "$id" "$@" $made)
    if [ $rc = 1 ]; then
      if [ -n "$fw" ]; then
        st=FIRMWARE; detail="$drv asked for $fw and did not get it"; fix=$(fw_package "$fw")
      else
        st=NOOUT; detail="$drv is attached but made no $(dc_kind_word "$kind")"
        dc_errors "$id" | grep -qi 'firmware\|board' && fix=$(dc_driver_package "$drv")
      fi
    elif [ $rc = 2 ] && [ -n "$fw" ]; then
      st=FIRMWARE; detail="$drv asked for $fw and did not get it"; fix=$(fw_package "$fw")
    fi
    st=${st:-OK}
  fi
  dc_row "$st" "$bus" "$id" "$type" "$name" "$drv" "$ids" "$made" "$detail" "$fix" "$p"
}

# ---------------------------------------------------------------- buses
dc_pci_type() {
  case "${1#0x}" in
    01*) echo Storage ;;         0200*) echo Ethernet ;;     0280*) echo Wi-Fi ;;
    02*) echo Network ;;         03*) echo Graphics ;;       0401*|0403*) echo Sound ;;
    04*) echo Multimedia ;;      05*) echo Memory ;;         06*) echo Bridge ;;
    07*) echo Communication ;;   08*) echo System ;;         0b*) echo Processor ;;
    0c03*) echo "USB controller" ;; 0c05*) echo SMBus ;;     0c80*) echo "Serial bus" ;;
    0c*) echo "Serial bus" ;;    0d11*) echo Bluetooth ;;    11*) echo "Signal processing" ;;
    *) echo Other ;;
  esac
}

dc_pci_name() {   # id vendor:device
  local n=""
  command -v lspci >/dev/null 2>&1 && \
    n=$(lspci -mm -s "$1" 2>/dev/null | awk -F'"' 'NR==1{v=$4; sub(/ Corporation$/,"",v); sub(/ Inc\.?$/,"",v); print v" "$6}')
  printf '%s' "${n:-PCI device $2}"
}

dc_scan_pci() {   # [one device id]
  local d id cls type kind none ids
  for d in /sys/bus/pci/devices/${1:-*}; do
    [ -e "$d" ] || continue
    id=${d##*/}
    cls=$(cat "$d/class" 2>/dev/null)
    type=$(dc_pci_type "$cls")
    case "$type" in
      Sound) kind=audio ;;  Ethernet|Wi-Fi|Network) kind=net ;;  Bluetooth) kind=bt ;;  *) kind="" ;;
    esac
    case "$type" in Memory|Bridge|System|Processor|"Signal processing"|SMBus|Other) none=1 ;; *) none=0 ;; esac
    ids="$(sed 's/^0x//' "$d/vendor" 2>/dev/null):$(sed 's/^0x//' "$d/device" 2>/dev/null)"
    dc_judge pci "$id" "$(readlink -f "$d")" "$type" "$kind" "$(dc_pci_name "$id" "$ids")" \
      "$ids" "$(cat "$d/modalias" 2>/dev/null)" "$none"
  done
}

# Touchpads and touchscreens the firmware lists as HID-over-I2C but whose I2C
# bus never started, so no device exists for a driver to take. Run before the
# I2C scan so anything this brings up is listed there.
dc_scan_acpi_hid() {
  local a x st hid started=0
  for a in /sys/bus/acpi/devices/*; do
    grep -qE ':(PNP0C50|ACPI0C50):' "$a/modalias" 2>/dev/null || continue
    [ -e "$a/physical_node" ] && continue
    hid=$(cat "$a/hid" 2>/dev/null)
    st=$(cat "$a/status" 2>/dev/null || echo 15)
    if [ "$st" = 0 ]; then
      dc_row OFF acpi "${a##*/}" "Touch (I2C)" "Touch device $hid" "" "$hid" "" \
        "turned off by the firmware - check the BIOS setting, or the Fn touchpad key" "" "$a"
      continue
    fi
    if [ $started = 0 ]; then
      # everything the firmware lists (I2C controllers, pin control included),
      # the way udev does it at boot - a failed step there leaves the bus dead
      for x in /sys/bus/acpi/devices/*; do
        [ "$(cat "$x/status" 2>/dev/null || echo 15)" = 0 ] && continue
        cat "$x/modalias" 2>/dev/null; echo
      done | grep . | sort -u | xargs -r modprobe -a -b -q 2>>"$DC_LOG"
      modprobe -a -b -q intel_lpss_pci i2c_designware_platform i2c_hid_acpi 2>>"$DC_LOG"
      sleep 1; started=1
    fi
    [ -e "$a/physical_node" ] && continue
    dc_row UNBOUND acpi "${a##*/}" "Touch (I2C)" "Touch device $hid" "" "$hid" "" \
      "listed by the firmware, but its I2C bus did not start" "" "$a"
  done
}

dc_scan_i2c() {   # [one device id]
  local d id alias type kind none name
  for d in /sys/bus/i2c/devices/${1:-*}; do
    [ -e "$d" ] || continue
    id=${d##*/}
    [[ $id =~ ^i2c-[0-9]+$ ]] && continue          # the buses themselves
    alias=$(cat "$d/modalias" 2>/dev/null)
    name=$(cat "$d/name" 2>/dev/null)
    if [[ $alias =~ (PNP0C50|ACPI0C50) ]]; then
      type="Touch (I2C)"; kind=input; none=0
    else
      type="I2C device"; kind=""; none=1              # sensors, EEPROMs: no test uses them
    fi
    dc_judge i2c "$id" "$(readlink -f "$d")" "$type" "$kind" "${name:-$id}" "${alias#acpi:}" "$alias" "$none"
  done
}

# Fingerprint readers never have a kernel driver on Linux (libfprint drives
# them from outside), so an empty one is not a fault.
dc_is_fingerprint() {   # vendor name
  case "$1" in 06cb|27c6|138a|1c7a|10a5|2808) return 0 ;; esac
  [[ ${2,,} == *fingerprint* ]]
}

# USB: one row per device, judged across its interfaces. Hubs are skipped.
dc_scan_usb() {   # [one device id]
  local d id p ic type kinds drv drvs i made st detail fix fw ids name v rc k out
  for d in /sys/bus/usb/devices/${1:-*}; do
    [ -e "$d" ] || continue
    id=${d##*/}
    case "$id" in *:*|usb*) continue ;; esac
    [ "$(cat "$d/bDeviceClass" 2>/dev/null)" = 09 ] && continue
    p=$(readlink -f "$d")
    v=$(cat "$d/idVendor" 2>/dev/null)
    ids="$v:$(cat "$d/idProduct" 2>/dev/null)"
    name=$(printf '%s %s' "$(cat "$d/manufacturer" 2>/dev/null)" "$(cat "$d/product" 2>/dev/null)" | sed 's/^ *//;s/ *$//')
    name=${name:-USB device $ids}
    kinds=""; type=""; drvs=""
    for i in "$d/$id":*; do
      [ -e "$i" ] || continue
      ic=$(cat "$i/bInterfaceClass" 2>/dev/null)
      case "$ic" in
        e0) kinds+=" bt";    type=${type:-Bluetooth} ;;
        0e) kinds+=" video"; type=Camera ;;
        01) kinds+=" audio"; type=${type:-Sound} ;;
        03) kinds+=" input"; type=${type:-"Keyboard / mouse"} ;;
        08) type=${type:-Storage} ;;
        02|0a) type=${type:-Network} ;;
      esac
      drv=$(dc_driver "$(readlink -f "$i")")
      if [ -z "$drv" ] && [ "$ic" != ff ]; then
        dc_try_load usb "${i##*/}" "$(cat "$i/modalias" 2>/dev/null)" >/dev/null
        drv=$(dc_driver "$(readlink -f "$i")")
      fi
      [ -n "$drv" ] && [[ " $drvs " != *" $drv "* ]] && drvs+=" $drv"
    done
    drvs=${drvs# }; type=${type:-"USB device"}
    st=""; detail=""; fix=""; made=""
    if [ -z "$drvs" ]; then
      # nothing took it - vendor-specific interfaces included, try them all
      for i in "$d/$id":*; do
        [ -e "$i" ] || continue
        dc_try_load usb "${i##*/}" "$(cat "$i/modalias" 2>/dev/null)" >/dev/null
        drv=$(dc_driver "$(readlink -f "$i")"); [ -n "$drv" ] && drvs+=" $drv"
      done
      drvs=${drvs# }
    fi
    if [ -z "$drvs" ]; then
      fw=$(dc_fw_for "$id")
      if dc_is_fingerprint "$v" "$name"; then
        st=NONE; type="Fingerprint reader"; detail="Linux drives fingerprint readers outside the kernel; not tested here"
      elif [ -n "$fw" ]; then
        st=FIRMWARE; detail="needs firmware $fw, which is not on the stick"; fix=$(fw_package "$fw")
      else
        st=NODRIVER; detail="Linux $K has no driver for $ids"
      fi
    else
      for k in $kinds; do
        out=$(dc_made "$p" "$k"); rc=$?
        [ -n "$out" ] && made+="${made:+, }$out"
        if [ $rc = 1 ] && [ -z "$st" ]; then
          st=NOOUT; detail="$drvs attached but made no $(dc_kind_word "$k")"
        fi
      done
      fw=$(dc_fw_for "$id" $made)
      if [ -n "$fw" ]; then
        st=FIRMWARE; detail="$drvs asked for $fw and did not get it"; fix=$(fw_package "$fw")
      fi
      st=${st:-OK}
    fi
    dc_row "$st" usb "$id" "$type" "$name" "$drvs" "$ids" "$made" "$detail" "$fix" "$p"
  done
}

# The whole machine. Writes drivers.tsv; takes a few seconds.
dc_scan() {
  : > "$DC_TSV"
  dc_log "scan start, kernel $K"
  dc_read_log
  dc_find_missing_fw
  dc_scan_pci
  dc_scan_acpi_hid
  dc_scan_i2c
  dc_scan_usb
  dc_log "scan done: $(wc -l < "$DC_TSV") devices"
}

dc_count() {   # state... -> how many devices are in any of them
  local s n=0
  for s in "$@"; do n=$((n + $(grep -c "^$s|" "$DC_TSV" 2>/dev/null))); done
  echo $n
}

# Problems first, then what works, then what needs nothing.
dc_sorted() {
  local s
  for s in FIRMWARE NOOUT UNBOUND OFF NODRIVER LOADED OK BLOCKED NONE; do
    grep "^$s|" "$DC_TSV" 2>/dev/null
  done
}

dc_state_word() {
  case "$1" in
    OK) echo "working" ;;                LOADED) echo "started now" ;;
    FIRMWARE) echo "firmware missing" ;; NOOUT) echo "not working" ;;
    UNBOUND) echo "no driver attached" ;; OFF) echo "turned off" ;;
    NODRIVER) echo "no Linux driver" ;;  BLOCKED) echo "not loaded (graphics)" ;;
    NONE) echo "not needed" ;;           *) echo "$1" ;;
  esac
}

dc_report() {
  local st bus id type name drv ids made detail fix p bad soft
  rsection "DRIVER CHECK"
  rsilent "Kernel: Linux $K"
  while IFS='|' read -r st bus id type name drv ids made detail fix p; do
    rsilent "$(printf '  %-18s %-14s %s  [%s %s  %s]' "$(dc_state_word "$st")" "$type" "$name" "$bus" "$id" "$ids")"
    [ -n "$drv" ]    && rsilent "      driver: $drv${made:+  ->  $made}"
    [ -n "$detail" ] && [ "$st" != OK ] && [ "$st" != NONE ] && rsilent "      $detail"
    [ -n "$fix" ]    && rsilent "      fix: download $fix"
    case "$st" in FIRMWARE|NOOUT|UNBOUND)
      dc_errors "$id" | while IFS= read -r e; do rsilent "      log: $e"; done ;;
    esac
  done < <(dc_sorted)
  bad=$(dc_count FIRMWARE NOOUT UNBOUND); soft=$(dc_count OFF NODRIVER)
  if [ "$bad" -gt 0 ]; then
    rsilent "RESULT: FAIL -- $bad device(s) have a driver problem"
    set_kv DRIVER_RESULT "FAILED ($bad not working)"
  elif [ "$soft" -gt 0 ]; then
    rsilent "RESULT: PARTIAL -- $soft device(s) are off or have no Linux driver"
    set_kv DRIVER_RESULT "INCOMPLETE ($soft without a driver)"
  else
    rsilent "RESULT: PASS -- every device has a working driver"
    set_kv DRIVER_RESULT "PASSED"
  fi
  return 0
}

# ---------------------------------------------------------------- download
have_route() { ip route show default 2>/dev/null | grep -q .; }

net_up() {
  local i c
  for i in /sys/class/net/*; do
    case "${i##*/}" in lo) continue ;; esac
    c=$(cat "$i/carrier" 2>/dev/null)
    [ "$c" = 1 ] && { printf '%s\n' "${i##*/}"; return 0; }
  done
  return 1
}

# Cable ports come up switched off, and a port that is off reports no carrier
# even with a cable in - so "is there a cable?" answered no on the VM and would
# on a laptop too. Every wired port is switched on before looking.
wired_online() {   # -> 0 with a default route over a cable
  local i n="" t
  for i in /sys/class/net/*; do
    n=${i##*/}
    [ "$n" = lo ] && continue
    [ -d "$i/wireless" ] || [ -e "$i/phy80211" ] && continue
    ip link set "$n" up 2>/dev/null
  done
  n=""
  for t in 1 2 3 4 5 6 7 8; do n=$(net_up) && break; sleep 1; done
  [ -n "$n" ] || { dc_log "no cable with a link"; return 1; }
  dc_log "cable on $n, asking for an address"
  timeout 25 dhclient -1 -v "$n" >> "$DC_LOG" 2>&1
  have_route && return 0
  command -v udhcpc >/dev/null && timeout 20 udhcpc -i "$n" -n -q -t 5 >> "$DC_LOG" 2>&1
  have_route
}

# apt picks the version that belongs with this release: the pool holds every
# version side by side and "newest file" can be firmware years off this kernel.
# A trimmed source list keeps the index to a couple of megabytes.
FW_SOURCES=$RUN_DIR/fw-sources.list
APT_OPTS=(-o "Dir::Etc::sourcelist=$FW_SOURCES"
          -o "Dir::Etc::sourceparts=/dev/null"
          -o "APT::Get::List-Cleanup=0"
          -o "Acquire::Languages=none")

apt_ready() {
  cat > "$FW_SOURCES" <<EOF
deb [arch=amd64] $MIRROR/ noble main restricted
deb [arch=amd64] $MIRROR/ noble-updates main restricted
EOF
  apt-get "${APT_OPTS[@]}" update >"$RUN_DIR/apt.log" 2>&1
}

download_pkg() {   # package -> path of the downloaded .deb
  local pkg=$1 out
  ( cd "$RUN_DIR" && apt-get "${APT_OPTS[@]}" download "$pkg" ) >>"$RUN_DIR/apt.log" 2>&1 || return 1
  out=$(ls -1t "$RUN_DIR"/${pkg}_*.deb 2>/dev/null | head -1)
  [ -n "$out" ] && printf '%s\n' "$out"
}

# Unpack a firmware .deb into the firmware tree, noting every file that was
# not there before so "Remove downloaded files" can take exactly those away.
install_deb() {
  local deb=$1 tmp=$RUN_DIR/fwx member srcdir
  rm -rf "$tmp"; mkdir -p "$tmp" || return 1
  # .deb is an ar archive; take data.tar.* out without needing binutils. The
  # member may be uncompressed (linux-firmware-realtek), .zst, .xz or .gz.
  python3 - "$deb" "$tmp" <<'PY' || return 1
import os, sys
d = open(sys.argv[1], "rb").read()
if not d.startswith(b"!<arch>\n"):
    sys.exit(1)
i = 8
while i < len(d):
    name = d[i:i+16].decode("ascii", "replace").strip().rstrip("/")
    size = int(d[i+48:i+58].decode("ascii").strip())
    body = d[i+60:i+60+size]
    if name.startswith("data.tar"):
        open(os.path.join(sys.argv[2], name), "wb").write(body)
        open(os.path.join(sys.argv[2], "member"), "w").write(name)
        sys.exit(0)
    i += 60 + size + (size % 2)
sys.exit(1)
PY
  member=$(cat "$tmp/member" 2>/dev/null)
  case "$member" in
    data.tar.zst) zstd -dc "$tmp/$member" | tar -x -C "$tmp" ;;
    data.tar.xz)  tar -xJf "$tmp/$member" -C "$tmp" ;;
    data.tar.gz)  tar -xzf "$tmp/$member" -C "$tmp" ;;
    data.tar)     tar -xf  "$tmp/$member" -C "$tmp" ;;
    *)            return 1 ;;
  esac
  srcdir=""
  [ -d "$tmp/usr/lib/firmware" ] && srcdir=$tmp/usr/lib/firmware
  [ -z "$srcdir" ] && [ -d "$tmp/lib/firmware" ] && srcdir=$tmp/lib/firmware
  [ -n "$srcdir" ] || { rm -rf "$tmp"; return 1; }
  ( cd "$srcdir" && find . \( -type f -o -type l \) ) | while IFS= read -r f; do
    f=${f#./}
    [ -e "$FW_DIR/$f" ] || [ -L "$FW_DIR/$f" ] || printf '%s\n' "$FW_DIR/$f"
  done >> "$DC_ADDED"
  mkdir -p "$FW_DIR"
  cp -a "$srcdir"/. "$FW_DIR"/ 2>/dev/null
  rm -rf "$tmp"
  return 0
}

# Make a device's driver start over, so it asks for its firmware again.
dc_restart_device() {   # bus id driver path
  local bus=$1 id=$2 drv=$3 p=$4 i d
  if [ "$bus" = usb ]; then
    for i in "$p/$id":*; do
      [ -e "$i" ] || continue
      d=$(dc_driver "$i")
      if [ -n "$d" ]; then
        echo "${i##*/}" > "/sys/bus/usb/drivers/$d/unbind" 2>/dev/null
        echo "${i##*/}" > "/sys/bus/usb/drivers/$d/bind" 2>/dev/null
      else
        echo "${i##*/}" > /sys/bus/usb/drivers_probe 2>/dev/null
      fi
    done
  elif [ -n "$drv" ]; then
    echo "$id" > "/sys/bus/$bus/drivers/$drv/unbind" 2>/dev/null
    echo "$id" > "/sys/bus/$bus/drivers/$drv/bind" 2>/dev/null \
      || echo "$id" > "/sys/bus/$bus/drivers_probe" 2>/dev/null
  else
    echo "$id" > "/sys/bus/$bus/drivers_probe" 2>/dev/null
  fi
  dc_log "restarted $bus $id (${drv:-no driver})"
}

# ---------------------------------------------------------------- fixing
dc_line() { awk -F'|' -v b="$1" -v i="$2" '$2==b && $3==i' "$DC_TSV" | head -1; }
dc_state() { dc_line "$1" "$2" | cut -d'|' -f1; }
dc_working() { case "$(dc_state "$1" "$2")" in OK|LOADED|NONE) return 0 ;; esac; return 1; }

# Look at one device again. A touch device the firmware lists comes back on
# the I2C bus under a new name once its bus starts, so that takes a full look.
dc_rescan_one() {   # bus id
  local tmp=$DC_TSV.one
  if [ "$1" = acpi ]; then dc_scan; return; fi
  dc_read_log; dc_find_missing_fw
  awk -F'|' -v b="$1" -v i="$2" '!($2==b && $3==i)' "$DC_TSV" > "$tmp" && mv "$tmp" "$DC_TSV"
  case "$1" in
    pci) dc_scan_pci "$2" ;;  usb) dc_scan_usb "$2" ;;  i2c) dc_scan_i2c "$2" ;;
  esac
}

# Drivers like SOF load their firmware in the background after attaching, so
# "fixed" can take a few seconds to show.
dc_settle() {   # bus id -> 0 once the device works
  local n
  for n in 1 2 3 4 5 6; do
    dc_rescan_one "$1" "$2"
    dc_working "$1" "$2" && return 0
    sleep 1.5
  done
  return 1
}

# Faults recognised by their kernel message, each with its fix. Tried before
# anything is downloaded: they are instant and need no network. Sets
# DC_FIX_SAID to what was done.
dc_fix_known() {   # bus id type
  local bus=$1 id=$2 type=$3
  DC_FIX_SAID=""
  if [ "$type" = Sound ] && dc_gpu_wait "$(dc_deferred_reason "$id") $(dc_errors "$id")"; then
    [ -w /sys/module/snd_hda_core/parameters/gpu_bind ] || return 1
    echo 0 > /sys/module/snd_hda_core/parameters/gpu_bind
    echo "$id" > "/sys/bus/$bus/drivers_probe" 2>/dev/null
    DC_FIX_SAID="told the sound driver not to wait for the graphics driver"
    dc_log "known fix on $id: snd_hda_core gpu_bind=0"
    return 0
  fi
  return 1
}

# Last resort for Intel DSP sound (SOF): the older HD Audio driver. Speakers
# and headphones work with it; the built-in digital microphones may not. The
# choice is a load-time option, so the sound modules are reloaded.
dc_fix_audio_legacy() {   # pci id
  local id=$1 d m
  d=$(dc_driver "/sys/bus/pci/devices/$id")
  [ "$d" = snd_hda_intel ] && return 1
  [ -n "$d" ] && echo "$id" > "/sys/bus/pci/drivers/$d/unbind" 2>/dev/null
  for m in $(lsmod | awk '$1 ~ /^snd_sof_pci_intel/ {print $1}') snd_sof_pci snd_hda_intel snd_intel_dspcfg; do
    modprobe -r "$m" 2>>"$DC_LOG"
  done
  modprobe snd_intel_dspcfg dsp_driver=1 2>>"$DC_LOG"
  modprobe snd_hda_intel 2>>"$DC_LOG"
  echo "$id" > /sys/bus/pci/drivers_probe 2>/dev/null
  DC_FIX_SAID="switched to the older Intel HD Audio driver (speakers and headphones; built-in microphones may not work)"
  [ "$(cat /sys/module/snd_intel_dspcfg/parameters/dsp_driver 2>/dev/null)" = 1 ] \
    || DC_FIX_SAID="tried the older Intel HD Audio driver, but the sound modules could not be reloaded"
  dc_log "legacy HDA attempt on $id: $DC_FIX_SAID"
  return 0
}
