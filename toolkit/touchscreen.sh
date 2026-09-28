#!/bin/bash
# Touchscreen test.
#
# The renderer takes over the whole panel: first three seconds hands-off to
# catch ghost touches (a cracked or delaminating digitiser fires on its own),
# then a finger dragged over the whole glass fills a grid, then several fingers
# at once to prove multi-touch. This script owns the verdict and the report.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

if [ "$TUI_GUI" != 1 ]; then
  tui_msg "Touchscreen test" \
    "This test draws on the whole screen, so it needs the graphical interface." \
    "Boot the default entry on the machine's own screen and try again."
  exit 0
fi

# Same rule the renderer uses: absolute axes and INPUT_PROP_DIRECT (PROP bit 1).
touchscreens() {
  awk 'BEGIN{RS=""; FS="\n"}
       { name=""; prop=0; abs=0
         for (i=1;i<=NF;i++) {
           if ($i ~ /^N: Name=/) { name=substr($i, 9); gsub(/"/, "", name) }
           if ($i ~ /^B: PROP=/) { v=substr($i, 9); n=split(v, a, " ")
                                   c=tolower(substr(a[n], length(a[n]), 1))
                                   prop=(index("2367abef", c) > 0) }   # bit 1 = DIRECT
           if ($i ~ /^B: ABS=/)  abs=1
         }
         low=tolower(name)
         if (abs && (prop || low ~ /touch ?screen/)) print name }' \
    /proc/bus/input/devices 2>/dev/null
}

if [ -z "$(touchscreens)" ]; then
  rsection "TOUCHSCREEN TEST"
  rsilent "RESULT: NOT TESTED (no touchscreen on this machine)"
  set_kv TOUCHSCREEN_RESULT "NOT TESTED (no touchscreen found)"
  tui_frame "Touchscreen test" "Enter to go back"
  tui_badge 6 UNKNOWN "no touchscreen on this machine"
  tui_line 9  "Nothing reports itself as a touchscreen." ""
  tui_line 10 "If this model has one, check it is enabled in the BIOS. A touchscreen" muted
  tui_line 11 "is an I2C HID device, so a missing one can also mean the I2C controller" muted
  tui_line 12 "did not come up - the System page lists what the kernel found." muted
  tui_flush; tui_anykey
  exit 0
fi

tui_frame "Touchscreen test" "Enter to start"
tui_line 6  "1.  Keep your hands off the screen for 3 seconds."
tui_line 7  "    Anything that registers then is a ghost touch - the glass touching itself." muted
tui_line 9  "2.  Drag one finger over the WHOLE screen, edges and corners too."
tui_line 10 "    Each patch turns green as it registers. One that never does is a dead zone." muted
tui_line 12 "3.  Put two or more fingers down together to check multi-touch."
tui_line 14 "If the green appears somewhere other than under your finger, the panel is" muted
tui_line 15 "mirrored or rotated - usually the wrong digitiser fitted, or a firmware mismatch." muted
tui_line 17 "Ends 25 s after the last touch, when the whole screen is covered, or Esc x3." muted
tui_flush
tui_anykey

tui_tstest
IFS='|' read -r coverage dead devices maxsim ghost contacts supported uncal deadlist <<< "$TS_SUMMARY"
coverage=${coverage:-0}; dead=${dead:-0}; maxsim=${maxsim:-0}; ghost=${ghost:-0}
contacts=${contacts:-0}; supported=${supported:-1}; uncal=${uncal:-0}

rsection "TOUCHSCREEN TEST"
rsilent "Device                 : ${devices:-none}"
rsilent "Touch points supported : $supported"
rsilent "Most fingers at once   : $maxsim"
rsilent "Ghost touches (idle)   : $ghost"
rsilent "Screen covered         : ${coverage} %"
rsilent "Dead patches           : $dead"
[ -n "$deadlist" ] && rsilent "Dead cells (col,row)   : $deadlist"
[ "$uncal" = 1 ] && rsilent "Note: the panel gave no coordinate range, so dead patches were not judged."
rsilent ""

need_multi=2; [ "$supported" -lt 2 ] && need_multi=1
state=PASS
if [ "${devices:-none}" = none ] || [ -z "$devices" ]; then
  state=UNKNOWN; verdict="NOT TESTED (no touchscreen found)"
elif [ "$ghost" -gt 0 ]; then
  state=FAIL;    verdict="FAIL ($ghost ghost touch(es) with nobody touching the screen)"
elif [ "$dead" -gt 0 ]; then
  state=FAIL;    verdict="FAIL ($dead patch(es) of the screen never registered)"
elif [ "$coverage" -lt 80 ]; then
  state=PART;    verdict="INCOMPLETE (only ${coverage} % of the screen was swept - 80 % needed to judge)"
elif [ "$maxsim" -lt "$need_multi" ]; then
  state=PART;    verdict="INCOMPLETE (multi-touch not tried - most fingers at once: $maxsim)"
else
  verdict="PASS (${coverage} % covered, no ghost touches, $maxsim fingers at once)"
fi
rsilent "RESULT: $verdict"
set_kv TOUCHSCREEN_RESULT "$verdict"

tui_frame "Touchscreen test finished" "Enter to go back"
case "$state" in
  PASS)    tui_badge 6 PASS "the whole screen responds to touch" ;;
  FAIL)    tui_badge 6 FAIL "$( [ "$ghost" -gt 0 ] && echo "the screen touches itself" || echo "part of the screen does not respond")" ;;
  UNKNOWN) tui_badge 6 UNKNOWN "nothing to test" ;;
  *)       tui_badge 6 PARTIAL "not enough of the test was carried out" ;;
esac
tui_kv 9  "Device"                 "${devices:-none}"
tui_kv 10 "Screen covered"         "${coverage} %"
tui_kv 11 "Dead patches"           "$dead"
tui_kv 12 "Ghost touches"          "$ghost"
tui_kv 13 "Fingers at once"        "$maxsim of $supported"
row=15
if [ "$ghost" -gt 0 ]; then
  tui_line $row "The screen registered touches with nobody touching it." err; row=$((row+1))
  tui_line $row "Usually a cracked or delaminating digitiser, or moisture under the glass." muted
elif [ "$dead" -gt 0 ]; then
  tui_line $row "$dead patch(es) of the glass never registered a finger." err; row=$((row+1))
  tui_line $row "A dead strip along one edge is usually the digitiser flex cable;" muted; row=$((row+1))
  tui_line $row "an isolated patch is usually a crack in the glass." muted
elif [ "$state" = PART ] && [ "$coverage" -lt 80 ]; then
  tui_line $row "Too little of the screen was swept to call it either way." warn; row=$((row+1))
  tui_line $row "Run it again and keep going until the whole grid is green." muted
fi
tui_flush
tui_anykey
