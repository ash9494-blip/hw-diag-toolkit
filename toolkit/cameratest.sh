#!/bin/bash
# Camera test - live preview.
#
# The preview itself is the test: focus, colour, a dead or half-dead sensor and
# a stuck privacy shutter are all things you judge by looking. What this script
# adds is the things you cannot see - whether the device enumerated at all, how
# many frames per second it actually delivers, and whether every frame came back
# black, which is a dead sensor rather than a covered lens.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

load_camera_modules() {
  modprobe videodev 2>/dev/null
  modprobe uvcvideo 2>/dev/null
  local i
  for i in 1 2 3 4 5 6; do
    ls /dev/video* >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

usb_cameras() {
  # UVC cameras sit on USB; naming them helps when /dev/video* is missing.
  local d
  for d in /sys/bus/usb/devices/*; do
    [ -r "$d/product" ] || continue
    case "$(cat "$d/bInterfaceClass" 2>/dev/null)" in
      0e) ;; *) grep -qis 'camera\|webcam' "$d/product" || continue ;;
    esac
    printf '%s\n' "$(cat "$d/product" 2>/dev/null)"
  done | sort -u
}

tui_frame "Camera test" "please wait"
tui_line 6 "Looking for a camera..." muted
tui_flush

if [ "$TUI_GUI" != 1 ]; then
  tui_msg "Camera test" \
    "Showing a live picture needs the graphical interface." \
    "Boot the default entry on the machine's own screen and try again."
  exit 0
fi

load_camera_modules
NODES=$(ls /dev/video* 2>/dev/null | tr '\n' ' ')

tui_frame "Camera test" "Enter to start"
tui_line 6  "A live picture from the camera comes up next." ""
tui_line 8  "Check that it is sharp, that the colour is not washed out or green," muted
tui_line 9  "and cover the lens with a finger to confirm the picture goes dark." muted
tui_line 11 "If this machine has a privacy shutter, slide it both ways." muted
tui_line 13 "Enter or Esc ends the preview." muted
tui_flush
tui_anykey

tui_camtest
IFS='|' read -r card frames fps mean dark <<< "$CAM_SUMMARY"
frames=${frames:-0}; fps=${fps:-0}; mean=${mean:-0}; dark=${dark:-0}

# ---------------------------------------------------------------- verdict
if [ "${card:-none}" = none ] || [ -z "$card" ]; then
  STATE=UNKNOWN
  VERDICT="NOT TESTED (no camera found)"
elif [ "$frames" -eq 0 ]; then
  STATE=FAIL
  VERDICT="FAIL (the camera enumerated but delivered no frames)"
elif [ "$frames" -lt 20 ]; then
  STATE=PART
  VERDICT="INCOMPLETE (only $frames frame(s) captured)"
else
  # every sampled frame black is a dead sensor; a few is just a covered lens
  SAMPLES=$(( frames / 5 + 1 ))
  if [ "$dark" -ge "$SAMPLES" ]; then
    STATE=FAIL
    VERDICT="FAIL (every frame was black - dead sensor or a shutter that never opens)"
  elif [ "$fps" -lt 10 ]; then
    STATE=WARN
    VERDICT="MARGINAL (only ${fps} fps)"
  else
    STATE=PASS
    VERDICT="PASS (${frames} frames at ${fps} fps)"
  fi
fi

rsection "CAMERA TEST"
rsilent "Camera            : ${card:-none found}"
rsilent "Video nodes       : ${NODES:-none}"
USBCAM=$(usb_cameras)
[ -n "$USBCAM" ] && rsilent "USB video devices : $(printf '%s' "$USBCAM" | tr '\n' ',' | sed 's/,$//')"
rsilent "Frames captured   : $frames"
rsilent "Frame rate        : ${fps} fps"
rsilent "Last brightness   : ${mean} of 255"
rsilent "Black frames      : $dark (sampled every 5th frame)"
rsilent ""
rsilent "Note: focus, colour and the privacy shutter are judged on screen by the"
rsilent "operator - this records what the camera delivered, not how it looked."
rsilent "RESULT: $VERDICT"
set_kv CAMERA_RESULT "$VERDICT"

tui_frame "Camera test finished" "Enter to go back"
case "$STATE" in
  PASS)    tui_badge 6 PASS "the camera delivers a steady picture" ;;
  WARN)    tui_badge 6 MARGINAL "it works, but the frame rate is low" ;;
  FAIL)    tui_badge 6 FAIL "the camera did not produce a usable picture" ;;
  UNKNOWN) tui_badge 6 UNKNOWN "no camera on this machine" ;;
  *)       tui_badge 6 PARTIAL "the preview ended too soon to judge" ;;
esac
tui_kv 9  "Camera"     "${card:-none found}"
tui_kv 10 "Frames"     "$frames"
tui_kv 11 "Frame rate" "${fps} fps"
row=13
case "$STATE" in
  FAIL)
    if [ "$frames" -eq 0 ]; then
      tui_line $row "The device appeared but never handed over a frame." err; row=$((row+1))
      tui_line $row "Usually a failed sensor or a broken camera ribbon." muted
    else
      tui_line $row "Every frame came back black with the lens uncovered." err; row=$((row+1))
      tui_line $row "Check the privacy shutter first, then the ribbon." muted
    fi ;;
  UNKNOWN)
    tui_line $row "No video device appeared." warn; row=$((row+1))
    tui_line $row "A camera switched off in the BIOS looks exactly like this," muted; row=$((row+1))
    tui_line $row "so check there before opening the machine." muted ;;
esac
tui_flush
tui_anykey
