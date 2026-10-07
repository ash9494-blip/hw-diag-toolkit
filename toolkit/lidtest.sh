#!/bin/bash
# Lid sensor test - and the tablet-mode switch on 2-in-1s.
#
# The lid is sensed by a hall sensor on the board and a magnet in the lid or
# the screen bezel. A magnet left out of a replacement bezel, or a dead
# sensor, gives a laptop that never sleeps when closed; a sensor stuck on
# "closed" gives one that blanks the screen or sleeps at random. Neither
# shows anywhere else. Closing the lid is safe here: the live system ignores
# it (logind HandleLidSwitch=ignore, finalize_chroot.sh), so nothing sleeps.
#
# The state is read from the kernel's switch devices (swstate.py), with the
# ACPI lid file as a fallback for firmware that makes no input device.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

SW=/opt/diag/swstate.py
WAIT=30

key() { _ask waitkey "$1"; KEY=$(printf '%s' "$UI_ANS" | tr '[:upper:]' '[:lower:]'); }

lid_state() {   # -> closed | open | "" (no sensor)
  local v
  v=$(python3 "$SW" lid 2>/dev/null | head -1 | cut -f4)
  case "$v" in
    1) echo closed; return ;;
    0) echo open; return ;;
  esac
  awk '{print $2; exit}' /proc/acpi/button/lid/*/state 2>/dev/null
}
tablet_state() {   # -> tablet | laptop | ""
  case "$(python3 "$SW" tablet 2>/dev/null | head -1 | cut -f4)" in
    1) echo tablet ;; 0) echo laptop ;;
  esac
}
lid_device() { python3 "$SW" lid 2>/dev/null | head -1 | cut -f2; }

# Wait for a switch to reach a position, showing it live. 0 = reached,
# 1 = timed out, 2 = Q, 3 = S.
wait_for() {   # reader-function want title instruction [note]
  local t now
  printf '%s\n' "$2" > "$RUN_DIR/lid.step"       # what is wanted - the VM harness reads it
  for (( t = 0; t < WAIT * 4; t++ )); do
    now=$($1)
    [ "$now" = "$2" ] && return 0
    if [ $(( t % 2 )) = 0 ]; then
      tui_frame "$3" "S = skip    Q = stop"
      tui_line 6 "$4" ""
      [ -n "$5" ] && tui_line 7 "$5" muted
      tui_kv 9 "Sensor reads" "${now:-nothing}" accent
      tui_kv 10 "Waiting" "$(( WAIT - t / 4 )) s"
      tui_flush
    fi
    key 0.25
    case "$KEY" in q) return 2 ;; s) return 3 ;; esac
  done
  return 1
}

LID_DEV=$(lid_device)
LID0=$(lid_state)
TAB0=$(tablet_state)
STATE=""; CAUSE=""; ACTION=""; CLOSED=""; OPENED=""; TAB_IN=""; TAB_OUT=""; STOPPED=0

if [ -z "$LID0" ]; then
  STATE=NOTTESTED; CAUSE="this laptop reports no lid sensor to the system"
  ACTION="Some firmware hides the lid switch. Check in Windows that closing the lid sleeps the machine."
elif [ "$LID0" = closed ]; then
  # Looking at this screen means the lid is open: the sensor is wrong now.
  STATE=FAIL; CAUSE="the sensor says the lid is closed while it is open"
  ACTION="A magnet near the sensor (a loose screw, a magnetic sleeve or stand) or a faulty sensor. Move magnets away and run this again; if it still reads closed, the hall sensor is faulty - the laptop will blank or sleep at random."
else
  wait_for lid_state closed "Lid sensor - close the lid" \
    "Close the lid all the way, wait a second, then open it again." \
    "Nothing sleeps: the system ignores the lid while the toolkit runs."
  case $? in
    0) CLOSED=yes ;;
    1) CLOSED=no ;;
    2) STOPPED=1 ;;
    3) CLOSED=skipped ;;
  esac
  if [ "$CLOSED" = yes ]; then
    wait_for lid_state open "Lid sensor - open it again" "Open the lid again."
    case $? in 0) OPENED=yes ;; 2) STOPPED=1 ;; *) OPENED=no ;; esac
  fi

  # 2-in-1s: the hinge folded right back is a second switch
  if [ -n "$TAB0" ] && [ "$STOPPED" = 0 ]; then
    wait_for tablet_state tablet "Tablet mode - fold the screen back" \
      "Fold the screen all the way back into tablet mode." \
      "S skips this if the machine does not fold."
    case $? in 0) TAB_IN=yes ;; 1) TAB_IN=no ;; 2) STOPPED=1 ;; 3) TAB_IN=skipped ;; esac
    if [ "$TAB_IN" = yes ]; then
      wait_for tablet_state laptop "Tablet mode - back to a laptop" "Fold it back into a laptop."
      case $? in 0) TAB_OUT=yes ;; 2) STOPPED=1 ;; *) TAB_OUT=no ;; esac
    fi
  fi

  if [ "$STOPPED" = 1 ]; then
    STATE=NOTTESTED; CAUSE="stopped by the operator"
  elif [ "$CLOSED" = no ]; then
    STATE=FAIL; CAUSE="closing the lid was not noticed"
    ACTION="The lid magnet or the hall sensor. After a screen or bezel replacement, check the magnet was moved to the new bezel; otherwise the sensor on the board. Windows will never sleep on closing the lid."
  elif [ "$CLOSED" = yes ] && [ "$OPENED" = no ]; then
    STATE=FAIL; CAUSE="the lid closed, but opening it was not noticed"
    ACTION="The sensor stays on 'closed': a stray magnet near it, or a faulty sensor. The screen will stay dark or the laptop asleep after opening."
  elif [ "$TAB_IN" = no ]; then
    STATE=WARN; CAUSE="the lid sensor works, but folding into tablet mode was not noticed"
    ACTION="The hinge's tablet-mode sensor or its magnet. Windows will not switch to tablet mode or turn the keyboard off when folded."
  elif [ "$TAB_IN" = yes ] && [ "$TAB_OUT" = no ]; then
    STATE=WARN; CAUSE="tablet mode was noticed, but not folding back"
    ACTION="The tablet-mode sensor stays on: the keyboard and touchpad may stay off in laptop position."
  elif [ "$CLOSED" = skipped ]; then
    STATE=NOTTESTED; CAUSE="the lid step was skipped"
  else
    STATE=PASS
    CAUSE="closing and opening the lid were both noticed$( [ "$TAB_IN" = yes ] && echo ", and tablet mode both ways")"
  fi
fi

echo done > "$RUN_DIR/lid.step"
rsection "LID SENSOR"
rsilent "Lid switch     : ${LID_DEV:-$( [ -n "$LID0" ] && echo "ACPI lid" || echo "none reported")}"
rsilent "Read at start  : ${LID0:-nothing}"
[ -n "$CLOSED" ] && rsilent "Close noticed  : $CLOSED"
[ -n "$OPENED" ] && rsilent "Open noticed   : $OPENED"
[ -n "$TAB0" ]   && rsilent "Tablet switch  : at start $TAB0${TAB_IN:+, folded: $TAB_IN}${TAB_OUT:+, back: $TAB_OUT}"
if [ -n "$ACTION" ]; then
  rsilent "What to do     :"
  printf '%s\n' "$ACTION" | fold -s -w 72 | sed 's/^/    /' >> "$REPORT_TXT"
fi
case "$STATE" in
  PASS) VERDICT="PASS ($CAUSE)" ;;  WARN) VERDICT="WARN ($CAUSE)" ;;
  FAIL) VERDICT="FAIL ($CAUSE)" ;;  *)    VERDICT="NOT TESTED ($CAUSE)" ;;
esac
rsilent "RESULT: $VERDICT"
set_kv LID_RESULT "$VERDICT"

tui_frame "Lid sensor" "Enter to go back"
case "$STATE" in
  PASS) tui_badge 6 PASS "the lid sensor works" ;;
  WARN) tui_badge 6 WARN "the lid works, tablet mode does not" ;;
  FAIL) tui_badge 6 FAIL "the lid sensor is faulty" ;;
  *)    tui_badge 6 UNKNOWN "not tested" ;;
esac
row=9
[ -n "$CLOSED" ] && { tui_kv $row "Lid closed" "$CLOSED" "$( [ "$CLOSED" = yes ] && echo ok || echo err )"; row=$((row+1)); }
[ -n "$OPENED" ] && { tui_kv $row "Lid opened" "$OPENED" "$( [ "$OPENED" = yes ] && echo ok || echo err )"; row=$((row+1)); }
[ -n "$TAB_IN" ] && { tui_kv $row "Tablet mode" "folded: $TAB_IN${TAB_OUT:+, back: $TAB_OUT}" "$( [ "$TAB_OUT" = yes ] && echo ok || echo warn )"; row=$((row+1)); }
row=$((row+1))
row=$(tui_para $row "$CAUSE" "$(case "$STATE" in PASS) echo ok ;; FAIL) echo err ;; WARN) echo warn ;; *) echo muted ;; esac)")
[ -n "$ACTION" ] && row=$(tui_para $row "$ACTION" "")
tui_flush
tui_anykey
exit 0
