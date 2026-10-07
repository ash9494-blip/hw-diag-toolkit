#!/bin/bash
# USB port test.
#
# There is no way to test a USB port without putting something in it, so this
# lists every port the controller reports and watches them live. Plug one stick
# into each port in turn: the row lights up, and the negotiated speed tells you
# whether a blue USB 3 port actually came up at 5 Gbps or fell back to 480 Mbps,
# which is the usual sign of a damaged or dirty connector.
#
# Ports the firmware marks "hardwired" are internal - the camera, bluetooth,
# the fingerprint reader - so they are listed separately and not counted.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

PORTS_TMP=$RUN_DIR/usb_ports
SEEN_TMP=$RUN_DIR/usb_seen

# The negotiated speed, in the words printed on the box.
#
# Speed and protocol are not the same thing and both matter: a USB 3 stick in a
# USB 2 port negotiates 480 Mbps, and so does a faulty USB 3 port with a broken
# SuperSpeed pair. The device's own bcdUSB says which protocol it speaks, so
# showing both is what tells those two cases apart.
speed_text() {
  case "$1" in
    1.5|1)    echo "1.5 Mbit/s" ;;
    12)       echo "12 Mbit/s" ;;
    480)      echo "480 Mbit/s" ;;
    5000)     echo "5 Gbit/s" ;;
    10000)    echo "10 Gbit/s" ;;
    20000)    echo "20 Gbit/s" ;;
    ''|*)     echo "${1:-unknown}" ;;
  esac
}

# Which generation the link actually came up at, named the way the standard is
# marketed rather than by its bcdUSB number.
speed_gen() {
  case "$1" in
    1.5|1)  echo "USB 1.0 low speed" ;;
    12)     echo "USB 1.1 full speed" ;;
    480)    echo "USB 2.0 high speed" ;;
    5000)   echo "USB 3.0 (3.2 Gen 1)" ;;
    10000)  echo "USB 3.1 (3.2 Gen 2)" ;;
    20000)  echo "USB 3.2 Gen 2x2" ;;
    40000)  echo "USB4 / Thunderbolt" ;;
    *)      echo "unknown speed" ;;
  esac
}

# What the device says it is, from its bcdUSB descriptor.
usb_version_text() {
  case "$1" in
    " 1.00"|"1.00") echo "USB 1.0" ;;
    " 1.10"|"1.10") echo "USB 1.1" ;;
    " 2.00"|"2.00") echo "USB 2.0" ;;
    " 2.01"|"2.01") echo "USB 2.0" ;;
    " 3.00"|"3.00") echo "USB 3.0" ;;
    " 3.10"|"3.10") echo "USB 3.1" ;;
    " 3.20"|"3.20") echo "USB 3.2" ;;
    "")             echo "" ;;
    *)              echo "USB ${1# }" ;;
  esac
}

# What kind of thing it is, from the USB class code. The device-level class is
# usually 0 ("see the interfaces"), so the interfaces are what get read.
class_name() {
  case "$1" in
    01) echo "audio device" ;;
    02) echo "network / modem" ;;
    03) echo "keyboard, mouse or other input" ;;
    05) echo "physical interface" ;;
    06) echo "camera or scanner" ;;
    07) echo "printer" ;;
    08) echo "storage" ;;
    09) echo "hub" ;;
    0a) echo "serial / communications" ;;
    0b) echo "smart card reader" ;;
    0d) echo "content security" ;;
    0e) echo "webcam" ;;
    0f) echo "healthcare device" ;;
    10) echo "audio/video device" ;;
    11) echo "billboard (USB-C adapter)" ;;
    dc) echo "diagnostic device" ;;
    e0) echo "wireless (Bluetooth or wifi)" ;;
    ef) echo "composite device" ;;
    fe) echo "application specific" ;;
    ff) echo "vendor specific" ;;
    *)  echo "" ;;
  esac
}

device_kind() {   # device dir -> a human description of what was plugged in
  local dev=$1 c kinds="" n i ifc proto
  c=$(cat "$dev/bDeviceClass" 2>/dev/null)
  if [ -n "$c" ] && [ "$c" != "00" ] && [ "$c" != "ef" ] && [ "$c" != "03" ]; then
    n=$(class_name "$c"); [ -n "$n" ] && { printf '%s' "$n"; return; }
  fi
  # Composite and class-per-interface devices: collect the interface classes.
  # Input devices are split by their boot protocol, which is how a keyboard
  # and a mouse tell the BIOS what they are: 1 = keyboard, 2 = mouse.
  for i in "$dev"/*:*/bInterfaceClass; do
    [ -r "$i" ] || continue
    ifc=$(cat "$i" 2>/dev/null)
    if [ "$ifc" = 03 ]; then
      proto=$(cat "${i%/*}/bInterfaceProtocol" 2>/dev/null)
      case "$proto" in
        01) n="keyboard" ;;
        02) n="mouse" ;;
        *)  n="input device" ;;
      esac
    else
      n=$(class_name "$ifc")
    fi
    [ -n "$n" ] || continue
    case ", $kinds, " in *", $n, "*) ;; *) kinds="${kinds:+$kinds, }$n" ;; esac
  done
  # a mouse that also exposes a keyboard interface (most wireless dongles) is
  # still described by what it mostly is
  case "$kinds" in
    "keyboard, mouse"|"mouse, keyboard") kinds="keyboard + mouse receiver" ;;
  esac
  printf '%s' "${kinds:-unknown type}"
}

# The one-line headline the bench wants: "USB 3.0 - 5 Gbit/s - storage".
# The generation is taken from the link speed, not the descriptor, because the
# link is what the port actually managed.
headline() {   # speed version kind
  local sp=$1 ver=$2 kind=$3 gen
  case "$sp" in
    1.5|1)  gen="USB 1.0" ;;
    12)     gen="USB 1.1" ;;
    480)    gen="USB 2.0" ;;
    5000)   gen="USB 3.0" ;;
    10000)  gen="USB 3.1" ;;
    20000)  gen="USB 3.2" ;;
    40000)  gen="USB4" ;;
    *)      gen="USB" ;;
  esac
  printf '%s - %s - %s' "$gen" "$(speed_text "$sp")" "$kind"
}

# A device that speaks USB 3 but came up at 480 Mbit/s or below is the one
# case worth shouting about: the SuperSpeed pairs in that socket are not
# making contact. A USB 2 device in a USB 3 port is perfectly normal.
link_downgraded() {   # speed version
  local maj=${2%%.*}
  [ -n "$maj" ] && [ "$maj" -ge 3 ] 2>/dev/null || return 1
  case "$1" in 1.5|1|12|480) return 0 ;; esac
  return 1
}

# Every port directory the kernel exposes, downstream hubs included.
#
# Not "find -L /sys": sysfs is full of circular symlinks, so following them
# wanders for minutes. The port nodes always sit one interface below their hub,
# and /sys/bus/usb/devices lists every hub, so a plain glob finds them all and
# cannot wander.
scan_ports() {
  local p
  for p in /sys/bus/usb/devices/*/*/*-port[0-9]*; do
    [ -d "$p" ] || continue
    printf '%s\n' "$p"
  done | sort -V
}

port_label() {   # /sys/.../usb1-port3 -> "USB-A  bus 1 port 3"
  local b=${1##*/}                    # usb1-port3  or  1-4-port2
  local hub=${b%%-port*} num=${b##*-port}
  local kind; kind=$(port_kind "$1")
  local where
  case "$hub" in
    usb*) where=$(printf 'bus %s port %s' "${hub#usb}" "$num") ;;
    *)    where=$(printf 'hub %s port %s' "$hub" "$num") ;;
  esac
  printf 'USB-%s  %s' "$kind" "$where"
}

device_on() {    # port dir -> "product|speed|version|kind" or empty
  local dev=$1/device
  [ -e "$dev" ] || return
  local prod speed manuf ver kind
  prod=$(cat "$dev/product" 2>/dev/null)
  manuf=$(cat "$dev/manufacturer" 2>/dev/null)
  speed=$(cat "$dev/speed" 2>/dev/null)
  ver=$(cat "$dev/version" 2>/dev/null)
  kind=$(device_kind "$dev")
  [ -z "$prod" ] && prod=$(cat "$dev/idVendor" 2>/dev/null):$(cat "$dev/idProduct" 2>/dev/null)
  [ -n "$manuf" ] && case "$prod" in "$manuf"*) ;; *) prod="$manuf $prod" ;; esac
  printf '%s|%s|%s|%s' "$prod" "$speed" "$(printf '%s' "$ver" | tr -d ' ')" "$kind"
}

# Which physical socket is this port?
#
# The firmware exposes USB-C connectors under /sys/class/typec. Each one links
# back to the USB port it drives, so where that link exists the answer is
# certain. Where it does not - and on plenty of laptops it does not - anything
# left that is an external socket is a Type-A, because those are the only two
# kinds of socket a laptop has on the outside.
declare -A TYPEC_PORTS=()
map_typec() {
  local tp real usbport
  for tp in /sys/class/typec/port[0-9]*; do
    [ -d "$tp" ] || continue
    for real in "$tp/device" "$tp/port" "$tp/connector"; do
      [ -e "$real" ] || continue
      usbport=$(readlink -f "$real" 2>/dev/null)
      case "$usbport" in
        */usb*-port*|*-port[0-9]*) TYPEC_PORTS[$usbport]=1 ;;
      esac
    done
  done
}

port_kind() {   # port dir -> "C" or "A"
  # Kernel 5.15+ links a USB port to its Type-C connector when the firmware
  # describes the socket; that link is the certain answer.
  [ -e "$1/connector" ] && { printf 'C'; return; }
  local p; p=$(readlink -f "$1" 2>/dev/null)
  [ -n "${TYPEC_PORTS[$p]:-}" ] && { printf 'C'; return; }
  # A port that negotiated 20 Gbps or better is a Type-C socket in practice -
  # Type-A never goes above 10.
  local sp; sp=$(cat "$1/device/speed" 2>/dev/null)
  case "$sp" in 20000|40000) printf 'C'; return ;; esac
  printf 'A'
}

# ---------------------------------------------------------------- USB-C power
# What each Type-C connector can do with power, from the UCSI interface the
# firmware exposes. power_role lists every role the port supports, with the
# current one in brackets: a port that can be a sink can charge the laptop.
typec_power() {   # typec port dir -> short description
  local tp=$1 roles pd opmode txt
  roles=$(cat "$tp/power_role" 2>/dev/null)
  pd=$(cat "$tp/usb_power_delivery_revision" 2>/dev/null)
  opmode=$(cat "$tp/power_operation_mode" 2>/dev/null)
  case "$roles" in
    *source*sink*|*sink*source*) txt="charge port (can power the laptop)" ;;
    *sink*)                      txt="charge-in only" ;;
    *source*)                    txt="supplies power only - does not charge" ;;
    *)                           txt="power role not reported" ;;
  esac
  case "$pd" in
    ""|0.0|0) txt="$txt, no USB PD" ;;
    *)        txt="$txt, USB PD $pd" ;;
  esac
  if [ -d "${tp}-partner" ]; then
    case "$opmode" in
      usb_power_delivery) txt="$txt - PD contract active now" ;;
      3.0A)               txt="$txt - 5 V 3 A now (no PD)" ;;
      1.5A)               txt="$txt - 5 V 1.5 A now (no PD)" ;;
      default)            txt="$txt - USB default power now" ;;
    esac
  fi
  printf '%s' "$txt"
}

port_typec() {   # usb port dir -> its typec port dir, or empty
  [ -e "$1/connector" ] || return
  readlink -f "$1/connector" 2>/dev/null
}

port_pd_tag() {   # usb port dir -> " - PD charge port" or ""
  local tp; tp=$(port_typec "$1")
  [ -n "$tp" ] || return
  case "$(cat "$tp/power_role" 2>/dev/null)" in
    *source*sink*|*sink*source*|*sink*) printf '  (PD charge port)' ;;
  esac
}

# A charger that is negotiating right now shows up as a UCSI power supply.
charger_now() {
  local ps on uv ua w
  for ps in /sys/class/power_supply/ucsi-source-psy-*; do
    [ -d "$ps" ] || continue
    on=$(cat "$ps/online" 2>/dev/null)
    [ "$on" = 1 ] || continue
    uv=$(cat "$ps/voltage_now" 2>/dev/null); ua=$(cat "$ps/current_max" 2>/dev/null)
    [ -n "$uv" ] && [ -n "$ua" ] || { printf 'charger connected
'; continue; }
    awk -v v="$uv" -v a="$ua" 'BEGIN{printf "charger: %.1f V at up to %.2f A (%.0f W)
", v/1e6, a/1e6, v*a/1e12}'
  done
}

controllers() {
  lspci 2>/dev/null | grep -i 'usb controller' | sed 's/^[0-9a-f:.]* //'
}

modprobe usb_storage 2>/dev/null
modprobe uas 2>/dev/null
modprobe ucsi_acpi 2>/dev/null      # USB-C connector and PD information
sleep 0.5

map_typec
mapfile -t ALLPORTS < <(scan_ports)
if [ "${#ALLPORTS[@]}" -eq 0 ]; then
  rsection "USB PORT TEST"
  rsilent "RESULT: NOT TESTED -- the kernel reports no USB ports on this machine"
  set_kv USB_RESULT "NOT TESTED (no ports reported)"
  tui_frame "USB ports" "Enter to go back"
  tui_badge 6 UNKNOWN "no USB ports reported"
  tui_line 9 "The kernel exposes no USB port information on this machine." ""
  tui_flush; tui_anykey
  exit 0
fi

# Split real sockets from internal ports.
#
# connect_type comes from the firmware's ACPI tables and is the reliable signal,
# but plenty of laptops leave it "unknown" - in which case the controller
# advertises every port it could theoretically have and the camera, bluetooth
# and fingerprint reader look just like sockets. A device sitting on a port at
# start that reports itself "fixed" rather than "removable" is soldered down, so
# that port is internal too.
EXT=(); INT=()
for p in "${ALLPORTS[@]}"; do
  ct=$(cat "$p/connect_type" 2>/dev/null)
  rem=$(cat "$p/device/removable" 2>/dev/null)
  case "$ct" in
    hardwired)  INT+=("$p"); continue ;;
    "not used") continue ;;
  esac
  if [ -e "$p/device" ] && [ "$rem" = fixed ]; then
    INT+=("$p"); continue
  fi
  EXT+=("$p")
done

NEXT=${#EXT[@]}
if [ "$NEXT" -eq 0 ]; then
  EXT=("${ALLPORTS[@]}"); NEXT=${#EXT[@]}; INT=()
fi

# One physical socket is two ports to the kernel: a USB 2 port and a USB 3
# port wired to the same connector, linked to each other as "peer". A stick
# lands on the USB 3 one and a mouse on the USB 2 one, so without pairing them
# the same socket would show up as two rows. Each pair is keyed on one member.
declare -A MEMBERS=()
SOCKS=()
for p in "${EXT[@]}"; do
  k=$p
  if [ -e "$p/peer" ]; then
    a=$(readlink -f "$p"); b=$(readlink -f "$p/peer")
    # key on whichever of the pair sorts first, as it appears in EXT
    for q in "${EXT[@]}"; do
      r=$(readlink -f "$q")
      if [ "$r" = "$a" ] || [ "$r" = "$b" ]; then k=$q; break; fi
    done
  fi
  if [ -z "${MEMBERS[$k]+x}" ]; then SOCKS+=("$k"); MEMBERS[$k]="$p"
  elif [ "$k" != "$p" ]; then MEMBERS[$k]="${MEMBERS[$k]} $p"; fi
done

sock_dev() {   # socket key -> device_on of whichever member has something in it
  local m out
  for m in ${MEMBERS[$1]}; do
    out=$(device_on "$m"); [ -n "$out" ] && { printf '%s' "$out"; return; }
  done
}

# What was already plugged in when we started - that is the baseline, and it is
# how the boot stick itself is kept from counting as a successful test. Once a
# baseline port is emptied, the baseline is forgotten, so putting anything back
# in it - even the same stick - counts.
declare -A BASE SEEN CUR LAST HIST SLOWP
declare -A START
for p in "${SOCKS[@]}"; do
  BASE[$p]=$(sock_dev "$p")
  START[$p]=${BASE[$p]}      # never cleared - remembers what was here at the start
  SEEN[$p]=0; CUR[$p]=""; LAST[$p]=""; HIST[$p]=""; SLOWP[$p]=0
done

tui_frame "USB port test" "start plugging"
tui_line 6 "Plug a device into each socket in turn - its row appears straight away," ""
tui_line 7 "with its name, USB version, speed and type." ""
tui_line 9 "Unplug it and the row changes to empty, so you can see each socket both" muted
tui_line 10 "take and release a device. Q when you have been round every socket." muted
tui_flush
# the sockets drawn are the ones listed below, as they fill and empty
tui_anim_live usb 0 2
sleep 2

# One pass over the sockets: work out what is in each one right now and update
# its history. Returns nothing; fills CUR, LAST, HIST, SEEN.
refresh() {
  local p cur prod speed ver kind
  for p in "${SOCKS[@]}"; do
    cur=$(sock_dev "$p")
    if [ -z "$cur" ]; then
      CUR[$p]=""
      BASE[$p]=""                     # emptied - forget the baseline
      continue
    fi
    if [ -n "${BASE[$p]}" ] && [ "$cur" = "${BASE[$p]}" ]; then
      CUR[$p]=""                      # still the stick we booted from
      continue
    fi
    if [ "$cur" != "${CUR[$p]}" ]; then
      IFS='|' read -r prod speed ver kind <<< "$cur"
      SEEN[$p]=1
      # While a device is arriving or being pulled out its interfaces are not
      # there yet (or already gone), so for a moment it reads "unknown type".
      # Never let that half-seen moment replace what was properly identified.
      if [ "$kind" != "unknown type" ] || [ "${LAST[$p]%%|*}" != "$prod" ]; then
        LAST[$p]=$cur
      fi
      case "|${HIST[$p]}|" in
        *"|$prod ($(speed_text "$speed"))|"*) ;;
        *) HIST[$p]="${HIST[$p]:+${HIST[$p]}|}$prod ($(speed_text "$speed"))" ;;
      esac
      link_downgraded "$speed" "$ver" && SLOWP[$p]=1
    fi
    CUR[$p]=$cur
  done
}

# The drive the toolkit booted from, as a sysfs path, so its socket can be
# named on screen instead of silently left out. Found by the live medium's
# mount, or failing that by the ISO's volume label.
boot_usb_path() {
  local src disk
  src=$(findmnt -no SOURCE /run/live/medium 2>/dev/null)
  [ -z "$src" ] && src=$(blkid -L DIAGTOOL 2>/dev/null)
  [ -z "$src" ] && src=$(lsblk -rno PATH,LABEL 2>/dev/null | awk '$2=="DIAGTOOL"{print $1; exit}')
  case "$src" in /dev/*) ;; *) return ;; esac
  disk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
  [ -z "$disk" ] && disk=${src##*/}
  readlink -f "/sys/block/$disk" 2>/dev/null
}
BOOT_PATH=$(boot_usb_path)
RUNNING_FROM_RAM=0
grep -qw toram /proc/cmdline 2>/dev/null && RUNNING_FROM_RAM=1

is_boot_sock() {   # socket key -> 0 when the boot drive hangs off it
  [ -n "$BOOT_PATH" ] || return 1
  local m dev
  for m in ${MEMBERS[$1]}; do
    dev=$(readlink -f "$m/device" 2>/dev/null)
    [ -n "$dev" ] || continue
    case "$BOOT_PATH/" in "$dev"/*) return 0 ;; esac
  done
  return 1
}

# A socket that already held something when the test started is shown - you
# can see it is there and what it is - but not counted: nothing about it was
# exercised, so crediting it would pass a socket on every run for free.
start_note() {   # socket key
  if is_boot_sock "$1"; then
    if [ "$RUNNING_FROM_RAM" = 1 ]; then
      printf 'boot drive - running from RAM, safe to unplug and replug to test this socket'
    else
      printf 'boot drive - DO NOT unplug, the toolkit is running from it'
    fi
  else
    printf 'plugged in before the test - unplug and replug to count it'
  fi
}

draw() {
  refresh
  local p prod speed ver kind done=0 inuse=0 early=0 row
  for p in "${SOCKS[@]}"; do
    [ "${SEEN[$p]}" = 1 ] && done=$((done+1))
    [ -n "${CUR[$p]}" ] && inuse=$((inuse+1))
    [ "${SEEN[$p]}" != 1 ] && [ -n "${START[$p]}" ] && early=$((early+1))
  done
  DONE=$done

  tui_frame "USB port test" "plug into each socket, then unplug    Q = finish"
  if [ "$done" -eq 0 ] && [ "$early" -eq 0 ]; then
    tui_line 6 "Plug a device into a socket - it appears here as soon as the" muted
    tui_line 7 "controller sees it. A stick, a mouse or a phone all work." muted
    tui_line 9 "Nothing detected yet." ""
    tui_flush
    return
  fi

  local head="$done socket(s) tested    $inuse in use now"
  [ "$early" -gt 0 ] && head="$head    $early present at start (not counted)"
  tui_line 6 "$head" ""
  row=8
  for p in "${SOCKS[@]}"; do
    if [ "${SEEN[$p]}" != 1 ]; then
      # present at start and not yet re-plugged
      [ -n "${START[$p]}" ] || continue
      [ $row -gt 19 ] && { tui_line $row "... more sockets below - see the report" muted; break; }
      if [ -z "${BASE[$p]}" ]; then
        IFS='|' read -r prod speed ver kind <<< "${START[$p]}"
        tui_kv $row "$(port_label "$p")" "empty - unplugged" muted
        tui_line $((row+1)) "   was: $prod  -  plug it (or anything) back in to count this socket" muted
        row=$((row+2))
        continue
      fi
      IFS='|' read -r prod speed ver kind <<< "${BASE[$p]}"
      tui_kv $row "$(port_label "$p")" "$prod" accent
      tui_line $((row+1)) "   $(headline "$speed" "$ver" "$kind")  -  $(start_note "$p")" \
        "$(is_boot_sock "$p" && [ "$RUNNING_FROM_RAM" != 1 ] && echo warn || echo muted)"
      row=$((row+2))
      continue
    fi
    [ $row -gt 19 ] && { tui_line $row "... more sockets below - see the report" muted; break; }
    if [ -n "${CUR[$p]}" ]; then
      IFS='|' read -r prod speed ver kind <<< "${CUR[$p]}"
      if link_downgraded "$speed" "$ver"; then
        tui_kv $row "$(port_label "$p")" "$prod" warn
        tui_line $((row+1)) "   $(headline "$speed" "$ver" "$kind")  -  USB $ver device held back to $(speed_text "$speed")" warn
      else
        tui_kv $row "$(port_label "$p")" "$prod" ok
        tui_line $((row+1)) "   $(headline "$speed" "$ver" "$kind")$(port_pd_tag "$p")" ""
      fi
    else
      IFS='|' read -r prod speed ver kind <<< "${LAST[$p]}"
      tui_kv $row "$(port_label "$p")" "empty - unplugged" muted
      tui_line $((row+1)) "   tested OK - last: $prod, $(headline "$speed" "$ver" "$kind")$(port_pd_tag "$p")" muted
    fi
    row=$((row+2))
  done
  # Live charger line, when a USB-C charger is negotiating right now
  local ch; ch=$(charger_now | head -1)
  [ -n "$ch" ] && tui_line 20 "USB-C $ch" accent
  tui_flush
}

DONE=0
while :; do
  draw
  tui_wait_abort 1 && break
done
refresh

# ---------------------------------------------------------------- report
rsection "USB PORT TEST"
CTRL=$(controllers)
if [ -n "$CTRL" ]; then
  rsilent "Controllers:"
  printf '%s\n' "$CTRL" | while IFS= read -r l; do rsilent "  $l"; done
  rsilent ""
fi
rsilent "Sockets that accepted a device : $DONE"
rsilent ""
for p in "${SOCKS[@]}"; do
  [ "${SEEN[$p]}" = 1 ] || continue
  IFS='|' read -r prod speed ver kind <<< "${LAST[$p]}"
  rsilent "$(port_label "$p")$(port_pd_tag "$p")"
  rsilent "    last device : $prod"
  rsilent "    link        : $(headline "$speed" "$ver" "$kind")   (device is USB $ver)"
  [ "${SLOWP[$p]}" = 1 ] && rsilent "    WARNING     : a USB 3 device came up at USB 2 speed or below in this socket"
  if [ "$(printf '%s' "${HIST[$p]}" | tr '|' '\n' | wc -l)" -gt 1 ]; then
    rsilent "    all devices : $(printf '%s' "${HIST[$p]}" | sed 's/|/; /g')"
  fi
  rsilent "    at the end  : $([ -n "${CUR[$p]}" ] && echo "still plugged in" || echo "unplugged")"
done
[ "$DONE" -eq 0 ] && rsilent "  (nothing was plugged in during the test)"
for p in "${SOCKS[@]}"; do
  [ "${SEEN[$p]}" != 1 ] && [ -n "${START[$p]}" ] || continue
  IFS='|' read -r prod speed ver kind <<< "${START[$p]}"
  rsilent "$(port_label "$p")  - present at start, not counted"
  rsilent "    device      : $prod"
  rsilent "    link        : $(headline "$speed" "$ver" "$kind")"
  rsilent "    note        : $(start_note "$p")"
done
rsilent ""

# USB-C connectors and their power capability
TCN=0
for tp in /sys/class/typec/port[0-9]*; do
  [ -d "$tp" ] || continue
  case "${tp##*/}" in *-*) continue ;; esac   # skip partner/cable entries
  [ "$TCN" -eq 0 ] && rsilent "USB-C connectors (from the firmware):"
  TCN=$((TCN+1))
  rsilent "  ${tp##*/}: $(typec_power "$tp")"
done
if [ "$TCN" -eq 0 ]; then
  rsilent "USB-C connectors: the firmware does not describe them (no UCSI), so"
  rsilent "PD capability cannot be read. To find the charge port, plug a USB-C"
  rsilent "charger into each Type-C socket and watch the Battery page."
fi
charger_now | while IFS= read -r l; do rsilent "  $l"; done
rsilent ""
rsilent "Only sockets that saw a device are listed. A USB controller advertises"
rsilent "more ports than the case physically has, so the ones never plugged into"
rsilent "are not evidence of anything and are left out."
if [ "${#INT[@]}" -gt 0 ]; then
  rsilent ""
  rsilent "Internal ports (camera, bluetooth, card reader and the like):"
  for p in "${INT[@]}"; do
    d=$(device_on "$p"); d=${d%%|*}
    rsilent "$(printf '  %-20s %s' "$(port_label "$p")" "${d:-empty}")"
  done
fi
rsilent ""

SLOW=0
for p in "${SOCKS[@]}"; do
  [ "${SLOWP[$p]}" = 1 ] && SLOW=$((SLOW+1))
done

# The score is about the sockets you actually tested. Only a USB 3 device held
# back to USB 2 speed counts against a socket - a mouse at 12 Mbit/s is normal.
if [ "$DONE" -eq 0 ]; then
  STATE=PART; VERDICT="NOT TESTED (nothing was plugged into any socket)"
elif [ "$SLOW" -gt 0 ]; then
  STATE=WARN; VERDICT="MARGINAL ($DONE socket(s) tested, $SLOW held a USB 3 device back to USB 2 speed)"
else
  STATE=PASS; VERDICT="PASS ($DONE socket(s) tested, every device came up at its own full speed)"
fi
rsilent "RESULT: $VERDICT"
set_kv USB_RESULT "$VERDICT"

tui_frame "USB port test finished" "Enter to go back"
case "$STATE" in
  PASS) tui_badge 6 PASS "every socket you tested worked at full speed" ;;
  WARN) tui_badge 6 MARGINAL "$SLOW socket(s) held a USB 3 device back" ;;
  *)    tui_badge 6 PARTIAL "nothing was plugged in" ;;
esac
tui_kv 9  "Sockets tested" "$DONE"
row=10
[ "${#INT[@]}" -gt 0 ] && { tui_kv $row "Internal ports (not counted)" "${#INT[@]}"; row=$((row+1)); }
tui_kv $row "USB-C connectors" "$([ "$TCN" -gt 0 ] && echo "$TCN described by firmware" || echo "not described (no UCSI)")"
row=$((row+1)); r0=$row
if [ "$TCN" -eq 0 ]; then
  tui_line $row "To find the charge port: plug a USB-C charger into each Type-C" muted; row=$((row+1))
  tui_line $row "socket in turn and watch the Battery page for charging." muted; row=$((row+1))
fi
for tp in /sys/class/typec/port[0-9]*; do
  [ -d "$tp" ] || continue
  case "${tp##*/}" in *-*) continue ;; esac
  [ $row -gt 16 ] && break
  tui_line $row "${tp##*/}: $(typec_power "$tp")" muted; row=$((row+1))
done
row=$((row+1))
if [ "$SLOW" -gt 0 ]; then
  tui_line $row "$SLOW socket(s) ran a USB 3 device at USB 2 speed or below." warn; row=$((row+1))
  tui_line $row "The SuperSpeed contacts in that socket are dirty, bent or broken." muted
elif [ "$DONE" -gt 0 ]; then
  tui_line $row "Only sockets that saw a device are counted, so the ports a" muted; row=$((row+1))
  tui_line $row "controller invents are not held against the machine." muted
fi
tui_flush
tui_anykey
