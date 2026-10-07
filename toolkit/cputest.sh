#!/bin/bash
# CPU stress test with temperature monitoring (min / max / average)
. /opt/diag/lib.sh
. /opt/diag/tui.sh

SAMPLE_LOG=$RUN_DIR/cpu_samples.csv
STRESS_OUT=$RUN_DIR/stress_ng.out
CRIT_TEMP=${DIAG_CRIT_TEMP:-100}

modprobe coretemp 2>/dev/null
modprobe k10temp  2>/dev/null
modprobe zenpower 2>/dev/null

pick_duration() {
  tui_menu "CPU stress test - how long?" "arrows + ENTER, Q to go back" \
    "1 minute|quick sanity check" \
    "5 minutes|normal check" \
    "10 minutes|recommended when chasing a heat problem" \
    "20 minutes|thorough" \
    "30 minutes|soak test" \
    "60 minutes|full burn-in" \
    "How this test works|animated: the load, the heat, the cooler" || return 1
  case "$TUI_CHOICE" in 1) MINUTES=1 ;; 2) MINUTES=5 ;; 3) MINUTES=10 ;; 4) MINUTES=20 ;; 5) MINUTES=30 ;; 6) MINUTES=60 ;;
    7) tui_anim cpu; pick_duration; return ;;
  esac
  return 0
}

temp_colour() {
  if   [ "$1" -ge 95 ]; then printf '%s' "$ERR$B"
  elif [ "$1" -ge 85 ]; then printf '%s' "$WRN"
  else printf '%s' "$OKC"
  fi
}

run_test() {
  local total=$(( MINUTES * 60 ))
  CPU_NAME=$(cpu_model); TEMP_SRC=$(cpu_temp_source)
  : > "$SAMPLE_LOG"; echo "elapsed_s,temp_c,mhz" >> "$SAMPLE_LOG"

  # ---- idle baseline ----
  tui_frame "CPU stress test" "please wait"
  tui_kv 6 "CPU" "$CPU_NAME"
  tui_kv 7 "Threads" "$(cpu_threads)"
  tui_kv 8 "Sensor" "$TEMP_SRC"
  # The animation at 2 frames a second here: drawing it at full speed would
  # warm the very processor whose resting temperature this is.
  tui_anim_live cpu 0 0 fps=2
  local idle_sum=0 idle_n=0 t i
  for i in 1 2 3 4 5; do
    t=$(cpu_temp_c); [ "$t" -gt 0 ] && { idle_sum=$((idle_sum+t)); idle_n=$((idle_n+1)); }
    tui_line 10 "Recording idle baseline...  $(( i * 2 )) / 10 s" "$MUTE"
    tui_bar 12 $(( i * 20 ))
    sleep 2
  done
  local idle_temp=-1
  [ "$idle_n" -gt 0 ] && idle_temp=$(( idle_sum / idle_n ))
  local idle_mhz thr0
  idle_mhz=$(cpu_mhz); thr0=$(throttle_count)

  # ---- load ----
  stress-ng --cpu 0 --cpu-method all --metrics-brief --times -t "${total}s" >"$STRESS_OUT" 2>&1 &
  local spid=$!

  local start now elapsed cur min=999 max=-1 sum=0 n=0 avg mhz thr hot=0 aborted=0 pct
  start=$(date +%s)
  tui_frame "CPU stress test - all $(cpu_threads) threads loaded" "Q = stop the test early"
  tui_anim_live cpu 1 3
  while kill -0 $spid 2>/dev/null; do
    now=$(date +%s); elapsed=$(( now - start ))
    [ "$elapsed" -gt "$total" ] && elapsed=$total
    cur=$(cpu_temp_c); mhz=$(cpu_mhz); thr=$(( $(throttle_count) - thr0 ))
    if [ "$cur" -gt 0 ]; then
      sum=$(( sum + cur )); n=$(( n + 1 ))
      [ "$cur" -lt "$min" ] && min=$cur
      [ "$cur" -gt "$max" ] && max=$cur
      echo "$elapsed,$cur,$mhz" >> "$SAMPLE_LOG"
      if [ "$cur" -ge "$CRIT_TEMP" ]; then hot=$(( hot + 1 )); else hot=0; fi
      if [ "$hot" -ge 4 ]; then kill $spid 2>/dev/null; aborted=2; break; fi
    else
      echo "$elapsed,,$mhz" >> "$SAMPLE_LOG"
    fi
    avg="n/a"; [ "$n" -gt 0 ] && avg=$(awk -v s=$sum -v c=$n 'BEGIN{printf "%.1f", s/c}')
    pct=$(( elapsed * 100 / total ))

    tui_kv 6 "CPU" "$CPU_NAME"
    tui_kv 7 "Sensor" "$TEMP_SRC   (idle was ${idle_temp} C)"
    if [ "$cur" -gt 0 ]; then
      tui_kv 9  "Temperature now" "$(printf '%d C' "$cur")" "$(temp_colour "$cur")$B"
      tui_kv 10 "Min / max / avg"  "$(printf '%d C   %d C   %s C' "$min" "$max" "$avg")" \
                "$(temp_colour "$max")"
    else
      tui_kv 9  "Temperature now" "no sensor on this machine" "$WRN"
      tui_kv 10 "Min / max / avg"  "-" "$MUTE"
    fi
    tui_kv 11 "Clock speed"      "$(printf '%d MHz' "$mhz")"
    tui_kv 12 "Throttle events"  "$thr" "$([ "$thr" -gt 0 ] && echo "$WRN" || echo "$OKC")"
    tui_kv 13 "Elapsed"          "$(secs_ms "$elapsed")  of  $(secs_ms "$total")"
    tui_bar 15 "$pct"
    if [ "$cur" -ge "$CRIT_TEMP" ] 2>/dev/null; then
      tui_line 17 "WARNING: ${cur} C - the test aborts if it stays this high" "$ERR$B"
    else
      tui_line 17 "" "$FG"
    fi
    if tui_wait_abort 2; then
      kill -TERM $spid 2>/dev/null; sleep 1; kill -KILL $spid 2>/dev/null
      aborted=1; break
    fi
  done
  wait $spid 2>/dev/null
  local end; end=$(date +%s)
  local dur=$(( end - start ))
  thr=$(( $(throttle_count) - thr0 ))

  tui_line 17 "Cooling down for 5 s..." "$MUTE"
  tui_anim_live cpu 4 4 fps=2               # the load is off: the robots rest
  sleep 5
  local cool; cool=$(cpu_temp_c)

  # ---- report ----
  rsection "CPU STRESS TEST"
  rsilent "CPU            : $CPU_NAME"
  rsilent "Threads loaded : $(cpu_threads)"
  rsilent "Duration       : $(secs_ms "$dur") (requested ${MINUTES} min)"
  rsilent "Sensor         : $TEMP_SRC"
  rsilent ""
  if [ "$n" -gt 0 ]; then
    avg=$(awk -v s=$sum -v c=$n 'BEGIN{printf "%.1f", s/c}')
    rsilent "Idle temperature before test : ${idle_temp} C"
    rsilent "Temperature under load       : min ${min} C   max ${max} C   average ${avg} C"
    rsilent "Temperature 5 s after test   : ${cool} C"
    rsilent "Samples                      : $n (every 2 s)"
    set_kv CPU_TEMP_IDLE "$idle_temp"; set_kv CPU_TEMP_MIN "$min"
    set_kv CPU_TEMP_MAX "$max"; set_kv CPU_TEMP_AVG "$avg"
  else
    rsilent "Temperature    : no usable sensor on this machine"
    set_kv CPU_TEMP_MAX "n/a"
  fi
  rsilent "Clock idle / end             : ${idle_mhz} MHz / ${mhz} MHz"
  rsilent "Thermal throttle events      : $thr"
  set_kv CPU_THROTTLE_EVENTS "$thr"
  rsilent ""
  rsilent "Temperature curve (every 30 s):"
  awk -F, 'NR>1 && $2!="" && $1%30<2 {printf "  %4ds  %3s C  ", $1, $2; b=int($2/2); for(i=0;i<b;i++) printf "#"; printf "\n"}' "$SAMPLE_LOG" >> "$REPORT_TXT"
  rsilent ""
  grep -E 'bogo|cpu ' "$STRESS_OUT" | sed 's/^/  /' >> "$REPORT_TXT"

  # ---- verdict ----
  local state verdict
  if [ "$aborted" = 2 ]; then
    state=FAIL; verdict="FAIL (overheat abort at ${max} C)"
  elif [ "$aborted" = 1 ]; then
    state=ABORT; verdict="CANCELLED after $(secs_ms "$dur") (peak ${max} C)"
  elif [ "$n" -eq 0 ]; then
    state=UNKNOWN; verdict="COMPLETED (no temperature sensor)"
  elif [ "$max" -ge 97 ]; then
    state=FAIL; verdict="FAIL (peak ${max} C)"
  elif [ "$max" -ge 90 ]; then
    state=WARN; verdict="MARGINAL (peak ${max} C)"
  else
    state=PASS; verdict="PASS (peak ${max} C)"
  fi
  rsilent "RESULT: $verdict"
  set_kv CPU_RESULT "$verdict"

  # Full run goes straight on to the next test: no result screen to end it
  if [ "$AUTO" = 1 ]; then tui_anim_stop; return; fi

  tui_frame "CPU stress test finished" "Enter to go back"
  local row=6
  case "$state" in
    PASS)    tui_badge $row PASS "cooling is within normal range" ;;
    WARN)    tui_badge $row MARGINAL "runs hot, throttling likely under sustained load" ;;
    FAIL)    tui_badge $row FAIL "overheating - clean the fan and heatsink, repaste" ;;
    ABORT)   tui_badge $row STOPPED "cancelled before the end" ;;
    *)       tui_badge $row UNKNOWN "no temperature sensor was readable" ;;
  esac
  row=$((row+2))
  tui_kv $row "Duration" "$(secs_ms "$dur")"; row=$((row+1))
  if [ "$n" -gt 0 ]; then
    tui_kv $row "Idle before"  "${idle_temp} C"; row=$((row+1))
    tui_kv $row "Minimum"      "${min} C"; row=$((row+1))
    tui_kv $row "Maximum"      "${max} C" "$(temp_colour "$max")$B"; row=$((row+1))
    tui_kv $row "Average"      "${avg} C"; row=$((row+1))
    tui_kv $row "5 s after"    "${cool} C"; row=$((row+1))
  fi
  tui_kv $row "Throttle events" "$thr" "$([ "$thr" -gt 0 ] && echo "$WRN" || echo "$OKC")"; row=$((row+2))
  if [ "$thr" -gt 0 ]; then
    tui_line $row "The CPU had to slow itself down $thr time(s) to stay within limits." "$WRN"
    row=$((row+1))
  fi
  [ "$state" = FAIL ] && tui_line $row "Check the fan, clear the heatsink fins, replace the thermal paste." "$FG"
  tui_anykey "ENTER to go back"
}

if [ "$1" = "auto" ]; then
  MINUTES=${2:-10}; AUTO=1
  run_test
  exit 0
fi

pick_duration && run_test
