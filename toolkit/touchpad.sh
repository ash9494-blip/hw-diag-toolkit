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
