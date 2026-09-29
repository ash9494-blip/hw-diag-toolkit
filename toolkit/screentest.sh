#!/bin/bash
# Screen test: dead and stuck pixels, backlight bleed, banding.
#
# No sensor can see the panel, so the renderer shows full-screen flat colours
# and the operator is the instrument. What this script adds is the record: the
# answer goes into the report with what was seen, so "screen checked" means
# the same thing on every job sheet.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

if [ "$TUI_GUI" != 1 ]; then
  tui_msg "Screen test" \
    "This test fills the whole panel with colour, so it needs the graphical" \
    "interface. Boot the default entry on the machine's own screen."
  exit 0
fi

res=$(tr ',' 'x' < /sys/class/graphics/fb0/virtual_size 2>/dev/null)

tui_frame "Screen test" "Enter to start"
tui_line 6  "The screen fills with one colour at a time: black, white, red," ""
tui_line 7  "green, blue, grey, dark grey and a grey ramp." ""
tui_line 9  "On each one, look closely across the whole panel for:" ""
tui_line 10 "  dots that stay lit on black, or stay dark on white" muted
tui_line 11 "  lines, blotches, pressure marks, glowing edges, visible bands" muted
tui_line 13 "Space or the arrow keys move on. Esc when finished." ""
tui_line 14 "Clean the panel first - dust on white looks just like a dead pixel." muted
[ -n "$res" ] && tui_kv 16 "Resolution" "$res"
tui_flush
tui_anykey

tui_pixtest
IFS='|' read -r seen total <<< "$PIX_SUMMARY"
seen=${seen:-0}; total=${total:-8}

pick_fault() {
  tui_menu "Which fault?" "arrows + Enter, Q when done" \
    "Dead pixel(s)|stay dark on white" \
    "Stuck or hot pixel(s)|stay lit on black, or one colour always on" \
    "Line(s)|a row or column that is wrong on every colour" \
    "Blotches or pressure marks|patches on grey" \
    "Backlight bleed|light leaking from an edge on dark grey" \
    "Banding|visible steps in the smooth ramp"
}
FAULT_NAMES=("dead pixels" "stuck pixels" "lines" "blotches" "backlight bleed" "banding")

faults=""
if tui_confirm "What did you see?" no \
     "Did any colour show a fault - a dot that stayed lit or dark, a line," \
     "a blotch, bands in the ramp, or light leaking in from an edge?"; then
  while pick_fault; do
    f=${FAULT_NAMES[$((TUI_CHOICE-1))]}
    case ",$faults," in *",$f,"*) ;; *) faults=${faults:+$faults,}$f ;; esac
    tui_msg "Noted" "Recorded: ${faults//,/, }." "" "Pick another fault, or press Q on the list when done."
  done
  [ -z "$faults" ] && faults="unspecified fault"
fi

rsection "SCREEN TEST"
rsilent "Resolution        : ${res:-unknown}"
rsilent "Colours viewed    : $seen of $total"
rsilent "Operator reported : ${faults:-no faults}"
if [ -n "$faults" ]; then
  state=FAIL; verdict="FAIL (${faults//,/, })"
elif [ "$seen" -lt "$total" ]; then
  state=PART; verdict="INCOMPLETE (only $seen of $total colours were viewed)"
else
  state=PASS; verdict="PASS (no dead or stuck pixels, lines or bleed seen)"
fi
rsilent "RESULT: $verdict"
set_kv SCREEN_RESULT "$verdict"

tui_frame "Screen test finished" "Enter to go back"
case "$state" in
  PASS) tui_badge 6 PASS "no faults seen" ;;
  FAIL) tui_badge 6 FAIL "${faults//,/, }" ;;
  *)    tui_badge 6 PARTIAL "not every colour was viewed" ;;
esac
tui_kv 9  "Colours viewed" "$seen of $total"
tui_kv 10 "Resolution"     "${res:-unknown}"
if [ "$state" = FAIL ]; then
  tui_line 12 "Recorded in the report. Lines and blotches that follow the panel's" muted
  tui_line 13 "edge are often the flex cable - reseat it before quoting a panel." muted
fi
tui_flush
tui_anykey
