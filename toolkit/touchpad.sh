#!/bin/bash
# Touchpad and mouse test.
#
# Both are evdev pointing devices, so one script covers them: "touchpad" reads
# the built-in pad (absolute finger position, finger-count buttons), "mouse"
# reads an external mouse (relative movement and a wheel). The live surface is
# drawn by the renderer; this script owns the verdict and the report.
#
# The coverage map is the point of the touchpad test: a pad with a dead patch
# tracks perfectly everywhere else, so only sweeping the whole surface finds it.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

MODE=${1:-touchpad}
case "$MODE" in touchpad) LABEL="Touchpad" ;; mouse) LABEL="Mouse" ;; *) MODE=touchpad; LABEL="Touchpad" ;; esac

if [ "$TUI_GUI" != 1 ]; then
  tui_msg "$LABEL test" \
    "This test draws the pad surface, so it needs the graphical interface." \
    "Boot the default entry on the machine's own screen and try again."
  exit 0
fi

# ---------------------------------------------------------------- driver search
# "No touchpad found" on a machine that plainly has one. On a TECRA A40-J the
# first answer was "download the driver", but every driver a laptop touchpad
# uses - i2c-hid, hid-multitouch, the Intel serial-IO bridge and GPIO drivers,
# psmouse, elan_i2c, rmi4 - is already in the image; there is nothing extra to
# fetch the way Windows would. When the pad is missing, the driver is there
# and did not attach. So this finds the hardware the firmware describes,
# loads the chain, binds the device by hand if it is still loose, and says
# exactly what it saw - on screen, in the report and in the Toolkit log.
DRV_LOG=$RUN_DIR/drivers.log
dlog() { printf '%s %s\n' "$(date +%T)" "$*" >> "$DRV_LOG"; }

# HID-over-I2C input devices the firmware lists (touchpads and touchscreens
# both use PNP0C50): "acpi-name status driver i2c-node", one per line.
i2c_hid_devices() {
  local a st node drv
  for a in /sys/bus/acpi/devices/*; do
    grep -qE ':(PNP0C50|ACPI0C50):' "$a/modalias" 2>/dev/null || continue
    st=$(cat "$a/status" 2>/dev/null)
    node=$(readlink -f "$a/physical_node" 2>/dev/null)
    drv=""
    [ -n "$node" ] && drv=$(basename "$(readlink -f "$node/driver" 2>/dev/null)" 2>/dev/null)
    printf '%s %s %s %s\n' "${a##*/}" "${st:-?}" "${drv:-none}" "${node##*/}"
  done
}

# The PS/2 mouse port, which older and cheaper pads still use: its driver.
ps2_aux() {
  local p d
  for p in /sys/bus/serio/devices/serio*; do
    grep -q 'AUX' "$p/description" 2>/dev/null || continue
    d=$(basename "$(readlink -f "$p/driver" 2>/dev/null)" 2>/dev/null)
    printf '%s' "${d:-none}"
    return 0
  done
  return 1
}

touchpad_driver_search() {   # 0 when a touchpad is present afterwards
  tui_frame "Touchpad test" "looking for the touchpad"
  tui_line 6 "No touchpad is reporting in. Looking for it and its driver..." ""
  tui_flush
  dlog "touchpad search"

  local hid aux
  hid=$(i2c_hid_devices)
  dlog "  I2C HID devices: ${hid:-none}"
  aux=$(ps2_aux)
  dlog "  PS/2 aux port driver: ${aux:-no PS/2 port}"

  # The chain an I2C pad needs, bottom up: the Serial IO controller, the GPIO
  # controller that carries its interrupt (named by the firmware, so loaded
  # by its own ID), the I2C-HID transport and the multitouch driver. Plus the
  # PS/2 and vendor-specific pad drivers. Anything already loaded is a no-op.
  local a m
  for a in /sys/bus/acpi/devices/INT34[BC]*/modalias /sys/bus/acpi/devices/INTC10*/modalias; do
    [ -r "$a" ] && modprobe -b -q "$(cat "$a")" 2>>"$DRV_LOG"
  done
  for m in intel_lpss_pci intel_lpss_acpi i2c_hid_acpi hid_multitouch hid_generic \
           psmouse elan_i2c rmi_i2c; do
    modprobe -b -q "$m" 2>>"$DRV_LOG" || dlog "  modprobe $m failed"
  done
  sleep 2

  # Loaded but still not attached: ask for the bind explicitly and keep the
  # kernel's answer, which is the most useful line in the whole search.
  local name st drv node
  while read -r name st drv node; do
    [ -n "$node" ] && [ "$drv" = none ] || continue
    dlog "  binding $node to i2c_hid_acpi"
    echo "$node" > /sys/bus/i2c/drivers/i2c_hid_acpi/bind 2>>"$DRV_LOG" \
      || dlog "  bind refused"
  done <<< "$(i2c_hid_devices)"
  sleep 2

  dmesg 2>/dev/null | grep -iE 'i2c_hid|i2c-hid|hid-multitouch|hid_multitouch|psmouse|elan_i2c|synaptics|rmi4|intel-lpss|i2c_designware|PNP0C50' \
    | tail -12 | sed 's/^/    /' >> "$DRV_LOG"

  # What the kernel actually made of it: every input device with its axes and
  # properties, and which HID driver took each HID device. The A40-J case
  # ("driver attached, no touchpad") cannot be told apart without these.
  dlog "  input devices:"
  grep -E '^N:|^H:|^B: (EV|ABS|REL|PROP)=' /proc/bus/input/devices 2>/dev/null \
    | sed 's/^/    /' >> "$DRV_LOG"
  dlog "  HID driver bindings:"
  local h
  for h in /sys/bus/hid/devices/*; do
    [ -e "$h" ] || continue
    printf '    %s -> %s\n' "${h##*/}" \
      "$(basename "$(readlink -f "$h/driver" 2>/dev/null)" 2>/dev/null)" >> "$DRV_LOG"
  done

  tui_ptrprobe touchpad
  dlog "  touchpads now: $PTR_COUNT"
  [ "${PTR_COUNT:-0}" -gt 0 ] && return 0

  # Still nothing: say what was seen, which is what decides the next step.
  hid=$(i2c_hid_devices)
  local row=8 disabled=0 loose=0 verdict
  while read -r name st drv node; do
    [ -n "$name" ] || continue
    [ "$st" = 0 ] && disabled=1
    [ "$drv" = none ] && loose=1
  done <<< "$hid"

  tui_frame "Touchpad test" "Enter to go back"
  tui_badge 6 UNKNOWN "no touchpad found"
  if [ -z "$hid" ] && [ "${aux:-none}" = none ]; then
    tui_line $row "The firmware lists no touchpad at all - not on I2C, not on PS/2." ""; row=$((row+2))
    tui_line $row "Most likely, in order:" muted; row=$((row+1))
    tui_line $row "  1. Turned off in the BIOS setup (look for Touch Pad / Pointing Device)" ""; row=$((row+1))
    tui_line $row "  2. Turned off with the touchpad function key (Fn + the pad icon)" ""; row=$((row+1))
    tui_line $row "  3. The flex cable is unplugged or the pad is dead" ""
    verdict="NOT TESTED (no touchpad listed by the firmware - BIOS, Fn key or cable)"
  elif [ "$disabled" = 1 ]; then
    tui_line $row "The firmware lists a touchpad but marks it disabled." warn; row=$((row+2))
    tui_line $row "Enable it in the BIOS setup or with the touchpad function key," ""; row=$((row+1))
    tui_line $row "then run this test again." ""
    verdict="NOT TESTED (touchpad present but disabled by the firmware)"
  elif [ "$loose" = 1 ]; then
    tui_line $row "A touchpad is listed but its driver would not attach:" warn; row=$((row+1))
    tui_line $row "  $(printf '%s' "$hid" | awk '$3=="none"{print $1; exit}')" ""; row=$((row+2))
    tui_line $row "It did not answer on its I2C bus - usually the flex cable, or the" ""; row=$((row+1))
    tui_line $row "pad itself. Reseat the cable and try again." ""
    verdict="FAIL (touchpad listed by the firmware but did not respond on I2C)"
  else
    # Touchscreens are PNP0C50 too, so an attached device here may be the
    # screen rather than the pad.
    tui_line $row "Every touch device the firmware lists has its driver, but none of" warn; row=$((row+1))
    tui_line $row "them is a touchpad (an attached one may be the touchscreen)." warn; row=$((row+2))
    tui_line $row "Check the pad's flex cable, and retry after a full power off." ""
    verdict="FAIL (touch drivers attached but no touchpad reports in)"
  fi
  tui_line 18 "The kernel's own messages are in the report and the Toolkit log." muted
  tui_flush

  rsection "TOUCHPAD TEST"
  rsilent "Driver search     : no touchpad appeared after loading the drivers"
  rsilent "I2C HID devices   : $(printf '%s' "${hid:-none}" | tr '\n' ';' | sed 's/;$//')"
  rsilent "PS/2 port driver  : ${aux:-no PS/2 port}"
  sed 's/^/  /' "$DRV_LOG" >> "$REPORT_TXT"
  rsilent "RESULT: $verdict"
  set_kv TOUCHPAD_RESULT "$verdict"
  tui_anykey
  return 1
}

if [ "$MODE" = touchpad ]; then
  tui_ptrprobe touchpad
  if [ "${PTR_COUNT:-0}" = 0 ]; then
    touchpad_driver_search || exit 0
    tui_msg "Touchpad found" "The touchpad driver was not running and has now been started." "" \
      "The test starts next."
  fi
fi

tui_frame "$LABEL test" "Enter to start"
if [ "$MODE" = touchpad ]; then
  tui_line 6  "Slide one finger slowly over the whole pad, corner to corner."
  tui_line 7  "The surface fills in green as it registers you." muted
  tui_line 9  "Then click the left, middle and right buttons, and try a two-finger"
  tui_line 10 "scroll. A patch that never fills in is a dead zone." muted
else
  tui_line 6  "Move the mouse around, click all three buttons, and turn the wheel"
  tui_line 7  "both ways. Tilt it sideways too if it does that." muted
  tui_line 9  "The square is just a drawing surface - tracking that stutters or"
  tui_line 10 "jumps shows up as gaps in the trail." muted
fi
tui_line 12 "The test ends 25 s after you stop, or press Esc three times." muted
tui_flush
tui_anykey

tui_ptrtest "$MODE"
IFS='|' read -r coverage dead buttons devices taps fingers wheel rightemu <<< "$PTR_SUMMARY"
coverage=${coverage:-0}; dead=${dead:-0}; taps=${taps:-0}; fingers=${fingers:-0}
wheel=${wheel:-0}; rightemu=${rightemu:-0}

# button counts come back as "left=3 middle=0 right=1"
btn_count() { printf '%s' "$buttons" | tr ' ' '\n' | awk -F= -v k="$1" '$1==k{print $2}'; }
L=$(btn_count left);   L=${L:-0}
M=$(btn_count middle); M=${M:-0}
R=$(btn_count right);  R=${R:-0}

# A clickpad has no right button to press. The driver reports a right click as
# a two-finger click or a two-finger tap, so either of those counts. Requiring
# a hardware BTN_RIGHT failed every modern touchpad that was working perfectly.
R_TOTAL=$(( R + rightemu ))
if [ "$R" -gt 0 ]; then
  R_HOW="hardware button"
elif [ "$rightemu" -gt 0 ]; then
  R_HOW="two-finger click or tap (clickpad)"
else
  R_HOW="not seen"
fi

rsection "${LABEL^^} TEST"
rsilent "Device            : ${devices:-none}"
rsilent "Surface covered   : ${coverage} %"
rsilent "Unreached patches : $dead"
rsilent "Buttons           : left $L   middle $M   right $R_TOTAL"
rsilent "Right click via   : $R_HOW"
if [ "$MODE" = touchpad ]; then
  rsilent "Taps registered   : $taps"
  rsilent "Most fingers seen : $fingers"
else
  rsilent "Wheel events      : $wheel"
fi
rsilent ""

state=PASS; verdict=""
if [ "${devices:-none}" = none ] || [ "$devices" = "" ]; then
  state=UNKNOWN; verdict="NOT TESTED (no $MODE found)"
elif [ "$coverage" -lt 35 ]; then
  state=PART;  verdict="INCOMPLETE (only ${coverage} % of the surface was swept)"
elif [ "$dead" -gt 0 ]; then
  state=FAIL;  verdict="FAIL ($dead patch(es) of the surface never registered)"
elif [ "$L" -eq 0 ] || [ "$R_TOTAL" -eq 0 ]; then
  state=PART;  verdict="INCOMPLETE (left and right clicks were not both seen)"
elif [ "$MODE" = touchpad ] && [ "$fingers" -lt 2 ]; then
  state=PART;  verdict="INCOMPLETE (no two-finger gesture was seen)"
elif [ "$MODE" = mouse ] && [ "$wheel" -eq 0 ]; then
  state=PART;  verdict="INCOMPLETE (the wheel was not turned)"
else
  state=PASS;  verdict="PASS (${coverage} % covered, all buttons responded; right click via $R_HOW)"
fi
rsilent "RESULT: $verdict"
set_kv "${LABEL^^}_RESULT" "$verdict"

tui_frame "$LABEL test finished" "Enter to go back"
case "$state" in
  PASS)    tui_badge 6 PASS "tracking and buttons are good" ;;
  FAIL)    tui_badge 6 FAIL "part of the surface does not respond" ;;
  UNKNOWN) tui_badge 6 UNKNOWN "nothing to test" ;;
  *)       tui_badge 6 PARTIAL "not enough of the test was carried out" ;;
esac
tui_kv 9  "Device"          "${devices:-none}"
tui_kv 10 "Surface covered" "${coverage} %"
tui_kv 11 "Buttons"         "left $L   middle $M   right $R"
if [ "$MODE" = touchpad ]; then
  tui_kv 12 "Fingers seen"  "$fingers"
else
  tui_kv 12 "Wheel events"  "$wheel"
fi
row=14
if [ "$dead" -gt 0 ]; then
  tui_line $row "$dead patch(es) of the pad never registered a finger." err; row=$((row+1))
  tui_line $row "A dead zone is usually a cracked pad or a lifting flex cable." muted
elif [ "$coverage" -lt 35 ]; then
  tui_line $row "Too little of the surface was swept to call it either way." warn; row=$((row+1))
  tui_line $row "Run it again and cover the whole pad, including the corners." muted
fi
tui_flush
tui_anykey
