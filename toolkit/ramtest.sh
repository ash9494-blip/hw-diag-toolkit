#!/bin/bash
# RAM stress / error test (in-OS). Full-coverage testing is the MemTest86+ boot entry.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

dimm_info() {
  dmidecode -t 17 2>/dev/null | awk '
    /Memory Device/ {slot="";size="";type="";speed="";mfr="";part="";ser=""}
    /Locator:/ && !/Bank/ {sub(/^[ \t]*Locator: /,"");slot=$0}
    /^\t*Size:/ {sub(/^[ \t]*Size: /,"");size=$0}
    /^\t*Type:/ && !/Detail/ {sub(/^[ \t]*Type: /,"");type=$0}
    /Configured Memory Speed:/ {sub(/^[ \t]*Configured Memory Speed: /,"");speed=$0}
    /Manufacturer:/ {sub(/^[ \t]*Manufacturer: /,"");mfr=$0}
    /Part Number:/ {sub(/^[ \t]*Part Number: /,"");part=$0}
    /Serial Number:/ {sub(/^[ \t]*Serial Number: /,"");ser=$0
      if (size != "" && size !~ /No Module/) printf "  %-22s %-9s %-6s %-11s %-12s %-18s %s\n", slot, size, type, speed, mfr, part, ser}
  '
}

# How much memory can safely be handed to a test process. Taking everything
# MemAvailable offers makes the kernel thrash and the OOM killer step in, which
# looks exactly like a hang - hence the 512 MB margin and the 75 %.
#
# Shmem (the live system's tmpfs, and the whole OS image when booted "run from
# RAM") is NOT subtracted again: tmpfs pages cannot be reclaimed, so the kernel
# already leaves them out of MemAvailable. Subtracting them a second time cost
# nothing on a normal boot but threw away ~450 MB of test coverage in RAM mode.
test_region_mb() {
  local avail
  avail=$(mem_avail_mb)
  local usable=$(( avail - 512 ))
  [ "$usable" -lt 0 ] && usable=0
  echo $(( usable * 75 / 100 ))
}

report_modules() {
  rsilent ""
  rsilent "Installed memory modules:"
  rsilent "$(printf '  %-22s %-9s %-6s %-11s %-12s %-18s %s' Slot Size Type Speed Vendor Part Serial)"
  dimm_info >> "$REPORT_TXT"
  rsilent ""
  rsilent "Total usable memory: $(mem_total_mb) MB"
  set_kv RAM_TOTAL_MB "$(mem_total_mb)"
}

show_modules_screen() {
  tui_frame "Installed memory modules" "Enter to go back"
  local row=6 l
  tui_line $row "$(printf '%-22s %-9s %-6s %-11s %-12s %-18s %s' Slot Size Type Speed Vendor Part Serial)" muted
  row=$((row+1))
  while IFS= read -r l; do
    tui_line $row "$l"
    row=$((row+1)); [ $row -gt 18 ] && break
  done < <(dimm_info)
  row=$((row+1))
  tui_kv $row "Total usable" "$(mem_total_mb) MB"
  tui_kv $((row+1)) "Free right now" "$(mem_avail_mb) MB"
  tui_kv $((row+2)) "Testable from here" "$(test_region_mb) MB"
  tui_anykey
}

# ---------------------------------------------------------------- live runner
# monitor <title> <total-seconds> <logfile> <pid> <engine>
# Draws a live screen and returns 1 if the user aborted with Q.
monitor_run() {
  local title=$1 total=$2 log=$3 pid=$4 engine=$5
  local start now el pct errs last aborted=0
  start=$(date +%s)
  tui_frame "$title" "Q = stop the test    (results so far are kept)"
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s); el=$(( now - start ))
    pct=0; [ "$total" -gt 0 ] && pct=$(( el * 100 / total ))
    [ "$pct" -gt 100 ] && pct=100
    errs=$(grep -ciE 'hardware error|miscompare|FAILURE' "$log" 2>/dev/null)
    tui_kv 6  "Engine"        "$engine"
    tui_kv 7  "Region tested" "${REGION_MB} MB of $(mem_total_mb) MB installed"
    tui_kv 8  "Elapsed"       "$(secs_ms "$el")   of $(secs_ms "$total")"
    if [ "${errs:-0}" -gt 0 ]; then
      tui_kv 9 "Errors found" "$errs" "$ERR$B"
    else
      tui_kv 9 "Errors found" "none so far" "$OKC"
    fi
    tui_kv 10 "Free memory"   "$(mem_avail_mb) MB"
    tui_bar 12 "$pct"
    last=$(tail -1 "$log" 2>/dev/null | cut -c1-$((TUI_W-6)))
    tui_line 14 "${last:-starting up...}" "$MUTE"
    if tui_wait_abort 2; then
      kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null
      aborted=1; break
    fi
  done
  wait "$pid" 2>/dev/null
  RUN_RC=$?
  RUN_ELAPSED=$(( $(date +%s) - start ))
  return $aborted
}

verdict_screen() {  # $1 state  $2 detail
  tui_frame "RAM test finished" "Enter to go back"
  case "$1" in
    PASS)   tui_badge 6 PASS "no memory errors detected" ;;
    FAIL)   tui_badge 6 FAIL "memory errors detected" ;;
    ABORT)  tui_badge 6 STOPPED "cancelled before the end" ;;
    *)      tui_badge 6 UNKNOWN "the test did not complete" ;;
  esac
  local i=8 l
  for l in "${@:2}"; do tui_line $i "$l"; i=$((i+1)); done
  tui_anykey
}

# ---------------------------------------------------------------- tests
test_stress() {
  local mins=$1
  if [ -z "$mins" ]; then
    tui_menu "Memory stress test - how long?" "arrows + ENTER, Q to go back" \
      "2 minutes|quick check" \
      "5 minutes|normal" \
      "15 minutes|thorough" \
      "30 minutes|soak test" \
      "60 minutes|full burn-in" || return
    case "$TUI_CHOICE" in 1) mins=2 ;; 2) mins=5 ;; 3) mins=15 ;; 4) mins=30 ;; 5) mins=60 ;; esac
  fi
  REGION_MB=$(test_region_mb)
  if [ "$REGION_MB" -lt 64 ]; then
    tui_msg "Not enough free memory" "Only ${REGION_MB} MB could be tested." \
      "Use the MemTest86+ boot entry instead."
    return
  fi
  rsection "RAM STRESS TEST (multi-threaded)"
  report_modules
  rsilent "Engine       : stressapptest"
  rsilent "Region tested: ${REGION_MB} MB of $(mem_total_mb) MB installed"
  rsilent "              (memory held by the toolkit itself cannot be tested from inside the"
  rsilent "               OS -- use the MemTest86+ boot entry for 100% coverage)"
  rsilent "Duration     : ${mins} minutes"

  local log=$RUN_DIR/sat.log
  : > "$log"
  stressapptest -M "$REGION_MB" -s $(( mins * 60 )) -m "$(nproc)" -W >"$log" 2>&1 &
  local pid=$!
  local aborted=0
  monitor_run "RAM stress test - stressapptest" $(( mins * 60 )) "$log" "$pid" "stressapptest" || aborted=1

  local hw; hw=$(grep -ciE 'hardware error|miscompare' "$log")
  rsilent "Elapsed      : $(secs_ms "$RUN_ELAPSED")"
  if [ "$aborted" = 1 ]; then
    rsilent "RESULT: CANCELLED by operator after $(secs_ms "$RUN_ELAPSED") (no errors up to that point)"
    set_kv RAM_RESULT "CANCELLED after $(secs_ms "$RUN_ELAPSED")"
    verdict_screen ABORT "Stopped after $(secs_ms "$RUN_ELAPSED")." \
      "No errors had been found up to that point." \
      "A short run proves little - rerun it for at least 5 minutes."
  elif grep -q 'Status: PASS' "$log" && [ "$hw" = 0 ]; then
    rsilent "RESULT: PASS -- no memory errors in ${mins} minutes"
    set_kv RAM_RESULT "PASS (${mins}min stressapptest)"
    verdict_screen PASS "${REGION_MB} MB tested for $(secs_ms "$RUN_ELAPSED")." \
      "Memory bandwidth: $(grep -m1 'Memory Copy:' "$log" | sed 's/.*at //')" \
      "" "For 100% coverage reboot and run MemTest86+."
  elif [ "$hw" -gt 0 ] || grep -q 'Status: FAIL' "$log"; then
    rsilent "RESULT: FAIL -- memory errors detected"
    grep -iE 'hardware error|miscompare' "$log" | head -10 | sed 's/^/       /' >> "$REPORT_TXT"
    set_kv RAM_RESULT "FAIL (errors detected)"
    verdict_screen FAIL "$hw error event(s) recorded." \
      "Reseat the modules and retest; if it still fails, test one module at a time." \
      "Confirm with MemTest86+ from the boot menu before replacing anything."
  else
    rsilent "RESULT: INCONCLUSIVE -- stressapptest did not finish (exit $RUN_RC)"
    set_kv RAM_RESULT "INCONCLUSIVE (did not finish)"
    verdict_screen UNKNOWN "The test process stopped early (exit code $RUN_RC)." \
      "Usually it could not get the memory it asked for." \
      "No conclusion about the RAM - use MemTest86+ instead."
  fi
}

test_pattern() {
  tui_menu "Memory pattern test - how many passes?" "arrows + ENTER, Q to go back" \
    "1 pass|roughly 3 min per GB" \
    "2 passes|" \
    "4 passes|" || return
  local passes; case "$TUI_CHOICE" in 1) passes=1 ;; 2) passes=2 ;; 3) passes=4 ;; esac
  REGION_MB=$(test_region_mb)
  if [ "$REGION_MB" -lt 64 ]; then
    tui_msg "Not enough free memory" "Only ${REGION_MB} MB could be tested."; return
  fi
  rsection "RAM PATTERN TEST (memtester)"
  report_modules
  rsilent "Engine       : memtester"
  rsilent "Region tested: ${REGION_MB} MB"
  rsilent "Passes       : ${passes}"

  local log=$RUN_DIR/mt.log
  : > "$log"
  memtester "${REGION_MB}M" "$passes" >"$log" 2>&1 &
  local pid=$!
  # ~180 s per GB per pass is a fair estimate for the progress bar
  local est=$(( REGION_MB * passes * 180 / 1024 ))
  local aborted=0
  monitor_run "RAM pattern test - memtester" "$est" "$log" "$pid" "memtester (estimated time)" || aborted=1

  rsilent "Elapsed      : $(secs_ms "$RUN_ELAPSED")"
  if [ "$aborted" = 1 ]; then
    rsilent "RESULT: CANCELLED by operator after $(secs_ms "$RUN_ELAPSED")"
    set_kv RAM_RESULT "CANCELLED after $(secs_ms "$RUN_ELAPSED")"
    verdict_screen ABORT "Stopped after $(secs_ms "$RUN_ELAPSED")."
  elif [ "$RUN_RC" = 0 ] && ! grep -qi 'FAILURE' "$log"; then
    rsilent "RESULT: PASS -- ${passes} pass(es), no errors"
    set_kv RAM_RESULT "PASS (${passes}x memtester)"
    verdict_screen PASS "${REGION_MB} MB, ${passes} pass(es), every pattern clean."
  elif grep -qi 'FAILURE' "$log"; then
    rsilent "RESULT: FAIL -- memtester reported failures"
    grep -i 'FAILURE' "$log" | head -10 | sed 's/^/       /' >> "$REPORT_TXT"
    set_kv RAM_RESULT "FAIL (memtester failures)"
    verdict_screen FAIL "$(grep -ci FAILURE "$log") pattern failure(s)."
  else
    rsilent "RESULT: INCONCLUSIVE -- memtester did not finish (exit $RUN_RC)"
    set_kv RAM_RESULT "INCONCLUSIVE (did not finish)"
    verdict_screen UNKNOWN "memtester stopped early (exit code $RUN_RC)." \
      "Most likely it could not lock that much memory."
  fi
}

# ---------------------------------------------------------------- entry
if [ "$1" = "auto" ]; then
  AUTO=1
  test_stress "${2:-5}"
  exit 0
fi

while :; do
  tui_menu "RAM tests" "a test inside the OS cannot check the memory the OS itself uses - MemTest86+ can" \
    "Memory stress test|multi-threaded, fast — random reboots and bluescreens" \
    "Memory pattern test|memtester, slow and thorough — suspect a specific bad module" \
    "Installed modules|slot, size, speed, part and serial of every DIMM" || break
  case "$TUI_CHOICE" in
    1) test_stress ;;
    2) test_pattern ;;
    3) show_modules_screen ;;
  esac
done
