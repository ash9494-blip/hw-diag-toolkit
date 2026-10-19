#!/bin/bash
# Fan test (Peripherals) - load the CPU so the fan has to work, watch the
# fan speed and the temperature, let it rest, judge.
#
# Many Dynabook / Toshiba models give Linux no fan speed at all (the
# embedded controller keeps it). Where a speed is readable - a hwmon fan
# input (Dell, ThinkPad, HP, ASUS...) or an ACPI 4.0 fan's fan_speed_rpm -
# it decides. Where none is, the technician is asked mid-load whether warm
# air comes out of the vent, and the temperature curve says the rest (Ash's
# choice, 1.24). A fan that turns while the CPU still runs at its limit
# points at the heatsink: dust in the fins or dried thermal paste.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

IDLE_SECS=10; LOAD_SECS=${DIAG_FAN_LOAD:-120}; COOL_SECS=30
CRIT_TEMP=${DIAG_CRIT_TEMP:-100}
HOT_MARGIN=5                     # within this of CRIT under load: cooling falls short
FAN_LOG=$RUN_DIR/fan.csv
modprobe coretemp 2>/dev/null; modprobe k10temp 2>/dev/null

fan_files() {   # every readable fan speed: hwmon fan inputs, ACPI 4.0 fans
  local f
  for f in "$HWMON_ROOT"/hwmon*/fan*_input /sys/bus/platform/devices/*/fan_speed_rpm; do
    [ -r "$f" ] && printf '%s\n' "$f"
  done
}
fan_rpm() {   # the fastest fan now, in rpm; nothing when no fan reports one
  local f v best=""
  while IFS= read -r f; do
    v=$(cat "$f" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$best" ] || [ "$v" -gt "$best" ]; then best=$v; fi
  done < <(fan_files)
  printf '%s' "$best"
}
fan_source() {   # where the speed comes from, for the report
  local f h
  f=$(fan_files | head -1)
  case "$f" in
    '') printf 'none - this laptop does not report its fan speed' ;;
    */fan_speed_rpm) printf 'ACPI fan (%s)' "$(basename "$(dirname "$f")")" ;;
    *) h=$(dirname "$f"); printf '%s %s' "$(cat "$h/name" 2>/dev/null)" "$(basename "$f")" ;;
  esac
}
fan_switch() {   # what the firmware says about the fan: on / off / nothing
  local f v
  # Toshiba's own ACPI device (toshiba_acpi), then any ACPI fan cooling device
  for f in /sys/bus/acpi/devices/TOS*/fan; do
    v=$(cat "$f" 2>/dev/null) || continue
    case "$v" in 0) echo off; return ;; [1-9]*) echo on; return ;; esac
  done
  for f in /sys/class/thermal/cooling_device*; do
    [ "$(cat "$f/type" 2>/dev/null)" = Fan ] || continue
    v=$(cat "$f/cur_state" 2>/dev/null)
    case "$v" in 0) echo off; return ;; [1-9]*) echo on; return ;; esac
  done
}

# ---------------------------------------------------------------- start
HAVE_RPM=0; [ -n "$(fan_rpm)" ] && HAVE_RPM=1
if [ "$HAVE_RPM" = 1 ]; then
  how="The fan speed is read as it goes."
else
  how="This laptop does not report its fan speed: halfway through you are asked whether warm air comes out of the vent."
fi
tui_confirm "Fan test" yes \
  "Runs every CPU core at full load for $((LOAD_SECS / 60)) minutes, so the fan has to speed up," \
  "then lets the laptop rest for $COOL_SECS seconds and watches it cool." \
  "" "$how" "" \
  "Keep it on a hard surface with the vents clear, the charger plugged in." \
  "" "Start now?" || exit 0

echo "seconds,phase,temp_c,rpm" > "$FAN_LOG"
t0=$(date +%s)
sample() {   # phase -> CUR_T, CUR_RPM, logged
  CUR_T=$(cpu_temp_c); CUR_RPM=$(fan_rpm)
  echo "$(( $(date +%s) - t0 )),$1,$CUR_T,$CUR_RPM" >> "$FAN_LOG"
}
draw() {   # title phase-line elapsed total
  tui_frame "$1" "Q = stop the test early"
  if [ "$CUR_T" -gt 0 ]; then
    tui_kv 6 "Temperature now" "$CUR_T C" "$( [ "$CUR_T" -ge $((CRIT_TEMP - HOT_MARGIN)) ] && echo err || echo ok )"
  else
    tui_kv 6 "Temperature now" "no sensor on this machine" muted
  fi
  if [ "$HAVE_RPM" = 1 ]; then
    tui_kv 7 "Fan speed" "${CUR_RPM:-0} rpm" "$( [ "${CUR_RPM:-0}" -gt 0 ] && echo ok || echo warn )"
  else
    tui_kv 7 "Fan speed" "not reported - listen and feel at the vent" muted
  fi
  [ -n "$SWITCH" ] && tui_kv 8 "Firmware says the fan is" "$SWITCH"
  tui_line 10 "$2" muted
  tui_bar 12 $(( $3 * 100 / $4 ))
  tui_flush
}

# ---------------------------------------------------------------- idle
SWITCH=$(fan_switch)
IDLE_T=-1; IDLE_RPM=""
for i in $(seq 1 $((IDLE_SECS / 2))); do
  sample idle; SWITCH=$(fan_switch)
  [ "$CUR_T" -gt "$IDLE_T" ] && IDLE_T=$CUR_T
  [ -n "$CUR_RPM" ] && IDLE_RPM=$CUR_RPM
  draw "Fan test - step 1 of 3, at rest" "Reading the temperature and the fan before the load." $((i * 2)) $IDLE_SECS
  if tui_wait_abort 2; then exit 0; fi
done

# ---------------------------------------------------------------- load
stress-ng --cpu 0 --cpu-method all -t "${LOAD_SECS}s" > "$RUN_DIR/fan_stress.out" 2>&1 &
spid=$!
MAX_T=-1; MAX_RPM=0; hot=0; ANSWER=""; stopped=0; start=$(date +%s)
while kill -0 $spid 2>/dev/null; do
  el=$(( $(date +%s) - start )); [ "$el" -gt "$LOAD_SECS" ] && el=$LOAD_SECS
  sample load; SWITCH=$(fan_switch)
  [ "$CUR_T" -gt "$MAX_T" ] && MAX_T=$CUR_T
  [ "${CUR_RPM:-0}" -gt "$MAX_RPM" ] && MAX_RPM=${CUR_RPM:-0}
  # the safety cut the CPU test has: four readings at the limit end the load
  if [ "$CUR_T" -ge "$CRIT_TEMP" ]; then hot=$((hot + 1)); else hot=0; fi
  [ "$hot" -ge 4 ] && { kill $spid 2>/dev/null; break; }
  draw "Fan test - step 2 of 3, CPU at full load" \
    "All $(cpu_threads) threads busy - the fan should be getting louder." "$el" "$LOAD_SECS"
  # halfway, with no speed reading: the fan is as fast as it gets - ask
  if [ "$HAVE_RPM" = 0 ] && [ -z "$ANSWER" ] && [ "$el" -ge $((LOAD_SECS / 2)) ]; then
    tui_menu "Hold your hand by the vent - is warm air coming out?" \
      "the CPU is at full load now, so the fan should be at full speed" \
      "Yes - warm air is blowing|the fan works" \
      "Only a little|weak airflow" \
      "No - no air, no fan sound|the fan is not turning" || TUI_CHOICE=0
    case "$TUI_CHOICE" in 1) ANSWER=yes ;; 2) ANSWER=weak ;; 3) ANSWER=no ;; *) ANSWER=skipped ;; esac
  fi
  if tui_wait_abort 2; then
    kill -TERM $spid 2>/dev/null; sleep 1; kill -KILL $spid 2>/dev/null; stopped=1; break
  fi
done
wait $spid 2>/dev/null

# ---------------------------------------------------------------- cool down
END_T=-1; COOL_RPM=""
if [ "$stopped" = 0 ]; then
  for i in $(seq 1 $((COOL_SECS / 2))); do
    sample cool
    END_T=$CUR_T; [ -n "$CUR_RPM" ] && COOL_RPM=$CUR_RPM
    draw "Fan test - step 3 of 3, cooling down" "The load is off: the temperature should fall quickly." $((i * 2)) $COOL_SECS
    if tui_wait_abort 2; then break; fi
  done
fi

# ---------------------------------------------------------------- verdict
# Whole sentences, one value each where possible: the screen translates them,
# and two values glued together ("rpm{0}{2}") match no catalogue entry. The
# temperatures have their own row on the result screen.
NEAR=$((CRIT_TEMP - HOT_MARGIN)); ACTION=""
if [ "$stopped" = 1 ] && [ -z "$ANSWER" ] && [ "$MAX_RPM" -eq 0 ]; then
  STATE=NOTTESTED; CAUSE="stopped by the operator before the fan could be judged"
elif [ "$HAVE_RPM" = 1 ]; then
  if [ "$MAX_RPM" -eq 0 ] && [ "$MAX_T" -ge 60 ]; then
    STATE=FAIL; CAUSE="the fan never turned (0 rpm) while the CPU reached $MAX_T C"
    ACTION="Check the fan's cable on the board, then the fan itself - replace it if it does not spin."
  elif [ "$MAX_T" -ge "$NEAR" ]; then
    STATE=WARN; CAUSE="the fan turns ($MAX_RPM rpm) but the CPU still reached $MAX_T C"
    ACTION="The heat is not leaving: clean the heatsink fins and replace the thermal paste."
  elif [ "$MAX_RPM" -eq 0 ]; then
    STATE=PASS; CAUSE="the fan stayed off (0 rpm) - the CPU never got hot enough to need it"
  elif [ -n "$IDLE_RPM" ] && [ "$MAX_RPM" -gt "$IDLE_RPM" ]; then
    STATE=PASS; CAUSE="the fan sped up from $IDLE_RPM rpm at rest to $MAX_RPM rpm under load"
  else
    STATE=PASS; CAUSE="the fan ran at up to $MAX_RPM rpm under load"
  fi
else
  case "$ANSWER" in
    no)
      STATE=FAIL; CAUSE="no air from the vent at full load - the fan is stuck, unplugged or dead"
      ACTION="Check the fan's cable on the board, then the fan itself - replace it if it does not spin." ;;
    weak)
      STATE=WARN; CAUSE="only a little air from the vent at full load - a dusty or failing fan"
      ACTION="Clean the fan and the heatsink fins; replace the fan if it stays weak or noisy." ;;
    yes)
      if [ "$MAX_T" -ge "$NEAR" ]; then
        STATE=WARN; CAUSE="air flows, but the CPU still reached $MAX_T C"
        ACTION="The heat is not leaving: clean the heatsink fins and replace the thermal paste."
      else
        STATE=PASS; CAUSE="warm air from the vent at full load"
      fi ;;
    *)
      STATE=NOTTESTED; CAUSE="the airflow question was not answered" ;;
  esac
fi
[ "$MAX_T" -le 0 ] && CAUSE="$CAUSE (no temperature sensor on this machine)"
drop=""; [ "$MAX_T" -gt 0 ] && [ "$END_T" -gt 0 ] && drop=$((MAX_T - END_T))
case "$STATE" in
  PASS) VERDICT="PASS ($CAUSE)" ;;  WARN) VERDICT="MARGINAL ($CAUSE)" ;;
  FAIL) VERDICT="FAIL ($CAUSE)" ;;  *)    VERDICT="NOT TESTED ($CAUSE)" ;;
esac

rsection "FAN"
rsilent "Fan speed from : $(fan_source)"
[ -n "$SWITCH" ] && rsilent "Firmware fan   : $SWITCH"
rsilent "At rest        : ${IDLE_T} C${IDLE_RPM:+, $IDLE_RPM rpm}"
rsilent "Full load      : peak ${MAX_T} C$( [ "$HAVE_RPM" = 1 ] && echo ", fan up to $MAX_RPM rpm")  ($(cpu_threads) threads, ${LOAD_SECS} s)"
[ -n "$ANSWER" ] && rsilent "Airflow (asked): $ANSWER"
[ -n "$drop" ] && rsilent "Cooling        : down $drop C in ${COOL_SECS} s${COOL_RPM:+, fan $COOL_RPM rpm}"
if [ -n "$ACTION" ]; then
  rsilent "What to do     :"
  printf '%s\n' "$ACTION" | fold -s -w 72 | sed 's/^/    /' >> "$REPORT_TXT"
fi
rsilent "RESULT: $VERDICT"
set_kv FAN_RESULT "$VERDICT"

tui_frame "Fan test finished" "Enter to go back"
case "$STATE" in
  PASS) tui_badge 6 PASS "the fan cools the laptop" ;;
  WARN) tui_badge 6 MARGINAL "cooling falls short" ;;
  FAIL) tui_badge 6 FAIL "the fan is not working" ;;
  *)    tui_badge 6 UNKNOWN "not tested" ;;
esac
row=8
if [ "$IDLE_T" -gt 0 ]; then
  tline="at rest $IDLE_T C,  peak $MAX_T C"
  [ "$END_T" -gt 0 ] && tline="$tline,  after cooling $END_T C"
  tui_kv $row "Temperature" "$tline"; row=$((row + 1))
fi
if [ "$HAVE_RPM" = 1 ]; then
  tui_kv $row "Fan speed" "at rest ${IDLE_RPM:-0} rpm,  at load $MAX_RPM rpm" "$( [ "$MAX_RPM" -gt 0 ] && echo ok || echo err )"
else
  case "$ANSWER" in
    yes)  tui_kv $row "Airflow at the vent" "warm air is blowing" ok ;;
    weak) tui_kv $row "Airflow at the vent" "only a little" warn ;;
    no)   tui_kv $row "Airflow at the vent" "no air, no fan sound" err ;;
    *)    tui_kv $row "Airflow at the vent" "not answered" muted ;;
  esac
fi
row=$((row + 1))
[ -n "$SWITCH" ] && { tui_kv $row "Firmware says the fan is" "$SWITCH"; row=$((row + 1)); }
row=$((row + 1))
row=$(tui_para $row "$CAUSE" "$(case "$STATE" in PASS) echo ok ;; FAIL) echo err ;; WARN) echo warn ;; *) echo muted ;; esac)")
[ -n "$ACTION" ] && row=$(tui_para $row "$ACTION" "")
tui_flush
tui_anykey
exit 0
