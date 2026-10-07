#!/bin/bash
# Battery drain test.
#
# Charge to full, unplug, and measure what the pack actually delivers. The log
# is written to the USB stick every 30 s, so when the machine finally dies the
# test can be finished on the next boot instead of starting over.
#
# Pass/fail is based on delivered energy rather than on "it felt fast":
#   * 80 % of design capacity is the industry end-of-life marker for lithium
#     cells (Battery University BU-801b), typically reached after 300-500 full
#     cycles.
#   * What the firmware gauge *claims* as full-charge capacity is an estimate
#     and a failing pack often overstates it, so the test compares the energy
#     measured coming out against both the design capacity and the claim.
#   * A pack that cuts out while still indicating a healthy charge level has
#     high internal resistance or an imbalanced cell, and fails regardless of
#     how much energy it delivered.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

SAMPLE_EVERY=30

# ---------------------------------------------------------------- sysfs
PS_ROOT=${DIAG_PS_ROOT:-/sys/class/power_supply}
bat_path() {
  local b
  for b in "$PS_ROOT"/BAT*; do
    [ -d "$b" ] && { echo "$b"; return 0; }
  done
  return 1
}

rd() { cat "$1" 2>/dev/null; }
num() { case "$1" in ''|*[!0-9-]*) echo 0 ;; *) echo "$1" ;; esac; }

# Populates BAT_* from sysfs, normalising charge-reporting packs (uAh) to
# energy (uWh) so both kinds are handled the same way downstream.
bat_read() {
  local b=$BAT v
  BAT_STATUS=$(rd "$b/status"); [ -z "$BAT_STATUS" ] && BAT_STATUS=Unknown
  BAT_PCT=$(num "$(rd "$b/capacity")")
  BAT_VOLT_UV=$(num "$(rd "$b/voltage_now")")
  BAT_CYCLES=$(rd "$b/cycle_count")

  if [ -r "$b/energy_now" ]; then
    BAT_ENERGY_UWH=$(num "$(rd "$b/energy_now")")
    BAT_FULL_UWH=$(num "$(rd "$b/energy_full")")
    BAT_DESIGN_UWH=$(num "$(rd "$b/energy_full_design")")
    BAT_POWER_UW=$(num "$(rd "$b/power_now")")
  else
    local vref
    vref=$(num "$(rd "$b/voltage_min_design")")
    [ "$vref" -le 0 ] && vref=$BAT_VOLT_UV
    [ "$vref" -le 0 ] && vref=11100000
    BAT_ENERGY_UWH=$(( $(num "$(rd "$b/charge_now")")         / 1000000 * vref / 1000000 * 1000000 ))
    BAT_FULL_UWH=$((   $(num "$(rd "$b/charge_full")")        / 1000000 * vref / 1000000 * 1000000 ))
    BAT_DESIGN_UWH=$(( $(num "$(rd "$b/charge_full_design")") / 1000000 * vref / 1000000 * 1000000 ))
    v=$(num "$(rd "$b/current_now")")
    BAT_POWER_UW=$(( v / 1000000 * BAT_VOLT_UV / 1000000 * 1000000 ))
  fi
  [ "$BAT_POWER_UW" -lt 0 ] && BAT_POWER_UW=$(( -BAT_POWER_UW ))
}

wh() { awk -v u="$1" 'BEGIN{printf "%.1f", u/1000000}'; }
w()  { awk -v u="$1" 'BEGIN{printf "%.1f", u/1000000}'; }

# ---------------------------------------------------------------- state
STATE=""; SAMPLES=""
state_set() { printf '%s=%s\n' "$1" "$2" >> "$STATE"; sync; }
state_get() { grep "^$1=" "$STATE" 2>/dev/null | tail -1 | cut -d= -f2-; }

open_storage() {
  STORAGE_PROMPT="Where should the battery log be written? (it must survive the shutdown)"
  pick_storage || return 1
  if ! mount_storage; then
    tui_msg "Cannot write there" "$STORAGE_DEV could not be mounted for writing." \
      "$(head -1 "$RUN_DIR/mnterr" 2>/dev/null)"
    return 1
  fi
  local dir="$STORAGE_MNT/DiagReports/battery"
  mkdir -p "$dir"
  STATE="$dir/$(machine_tag).state"
  SAMPLES="$dir/$(machine_tag).csv"
  return 0
}

# ---------------------------------------------------------------- phases
# Keys come from the renderer: it owns the keyboard, so reading stdin here
# saw nothing - S and Q did nothing on a pack stuck at 98%.
key_wait() { _ask waitkey "$1"; KEY=$(printf '%s' "$UI_ANS" | tr '[:upper:]' '[:lower:]'); }

# A worn pack often stops short of 100% (98% here on Ash's bench) and would
# hold this step for ever. When the charge has not risen for 10 minutes at
# 90% or more, say so; S starts the test from there and the report notes it.
STALL_SECS=600
wait_for_full() {
  local best=-1 since stalled=0
  since=$(date +%s)
  tui_frame "Battery test - step 1 of 3" "Q to cancel    S to start from the charge it has now"
  tui_anim_live battery 0 0
  while :; do
    bat_read
    if [ "$BAT_PCT" -gt "$best" ]; then best=$BAT_PCT; since=$(date +%s); fi
    [ "$BAT_PCT" -ge 90 ] && [ $(( $(date +%s) - since )) -ge "$STALL_SECS" ] && stalled=1
    tui_frame "Battery test - step 1 of 3" "Q to cancel    S to start from the charge it has now"
    tui_kv 6  "Battery"        "$(rd "$BAT/manufacturer") $(rd "$BAT/model_name")"
    tui_kv 7  "Design capacity" "$(wh "$BAT_DESIGN_UWH") Wh"
    tui_kv 8  "Reported full"   "$(wh "$BAT_FULL_UWH") Wh"
    tui_kv 10 "Charge level"    "${BAT_PCT} %" "$ACC$B"
    tui_kv 11 "Status"          "$BAT_STATUS"
    tui_bar 13 "$BAT_PCT"
    tui_line 15 "Plug in the charger and leave it until the battery reaches 100%."
    if [ "$stalled" = 1 ]; then
      tui_line 16 "Charging has stopped at ${BAT_PCT}% - press S to start the test from here." "$WRN"
    else
      tui_line 16 "This screen continues on its own once the pack is full." "$MUTE"
    fi
    case "$BAT_STATUS" in
      Full) return 0 ;;
      Charging|"Not charging") [ "$BAT_PCT" -ge 100 ] && return 0 ;;
      Discharging) tui_line 16 "Charger is not connected." "$WRN" ;;
    esac
    key_wait 5
    case "$KEY" in
      q) return 1 ;;
      s) [ "$BAT_PCT" -lt 100 ] && state_set CHARGE_STALL "$BAT_PCT"; return 0 ;;
    esac
  done
}

wait_for_unplug() {
  tui_frame "Battery test - step 2 of 3" "Q to cancel"
  tui_anim_live battery 1 1
  while :; do
    bat_read
    tui_frame "Battery test - step 2 of 3" "Q to cancel"
    tui_line 6 "Now unplug the charger."
    tui_line 8 "The test starts by itself the moment the battery takes over." "$MUTE"
    tui_kv 10 "Charge level" "${BAT_PCT} %" "$ACC$B"
    tui_kv 11 "Status"       "$BAT_STATUS" \
      "$([ "$BAT_STATUS" = Discharging ] && echo "$OKC" || echo "$WRN")"
    [ "$BAT_STATUS" = Discharging ] && return 0
    key_wait 2
    [ "$KEY" = q ] && return 1
  done
}

pick_load() {
  tui_menu "How should the machine be loaded while it drains?" \
    "idle is the honest standby figure, load is faster and harder on a weak pack" \
    "Idle|real standby drain, takes the longest" \
    "Light load|one CPU thread, roughly halves the time" \
    "Full load|every thread, fastest and harshest on a weak pack" || return 1
  case "$TUI_CHOICE" in
    1) LOAD=idle ;; 2) LOAD=light ;; 3) LOAD=full ;;
  esac
  return 0
}

start_load() {
  case "$LOAD" in
    light) stress-ng --cpu 1 --cpu-method matrixprod -t 24h >/dev/null 2>&1 & LOADPID=$! ;;
    full)  stress-ng --cpu 0 --cpu-method matrixprod -t 24h >/dev/null 2>&1 & LOADPID=$! ;;
  esac
}
stop_load() { [ -n "$LOADPID" ] && kill "$LOADPID" 2>/dev/null; }

drain() {
  bat_read
  local t0 e0 p0
  t0=$(date +%s); e0=$BAT_ENERGY_UWH; p0=$BAT_PCT

  : > "$SAMPLES"
  echo "elapsed_s,pct,energy_uwh,voltage_uv,power_uw,status" >> "$SAMPLES"
  : > "$STATE"
  state_set phase DRAIN
  state_set machine "$(dmi system-product-name)"
  state_set serial "$(dmi system-serial-number)"
  state_set started "$(date '+%Y-%m-%d %H:%M:%S')"
  state_set load "$LOAD"
  state_set design_uwh "$BAT_DESIGN_UWH"
  state_set full_uwh "$BAT_FULL_UWH"
  state_set cycles "$BAT_CYCLES"
  state_set start_pct "$p0"
  state_set start_energy_uwh "$e0"

  start_load

  local el pct_used rate_wh_h eta used
  tui_frame "Battery test - step 3 of 3, draining" "Q = stop and analyse now    the log survives a shutdown"
  # One frame a second: a smooth picture would cost the pack being measured -
  # several watts on an old laptop, and the idle drain would read high.
  tui_anim_live battery 2 2 fps=1
  while :; do
    bat_read
    el=$(( $(date +%s) - t0 ))
    echo "$el,$BAT_PCT,$BAT_ENERGY_UWH,$BAT_VOLT_UV,$BAT_POWER_UW,$BAT_STATUS" >> "$SAMPLES"
    state_set last_elapsed "$el"
    state_set last_pct "$BAT_PCT"
    state_set last_energy_uwh "$BAT_ENERGY_UWH"

    if [ "$BAT_STATUS" != Discharging ] && [ "$BAT_STATUS" != Unknown ]; then
      tui_line 18 "Charger reconnected - unplug it again to continue." "$WRN"
    else
      tui_line 18 "" "$FG"
    fi

    used=$(( e0 - BAT_ENERGY_UWH )); [ "$used" -lt 0 ] && used=0
    tui_kv 6  "Load"            "$LOAD"
    tui_kv 7  "Elapsed"         "$(secs_hms "$el")"
    tui_kv 9  "Charge level"    "${BAT_PCT} %   (started at ${p0} %)" "$ACC$B"
    tui_kv 10 "Drawing now"     "$(w "$BAT_POWER_UW") W"
    tui_kv 11 "Energy used"     "$(wh "$used") Wh  of $(wh "$BAT_DESIGN_UWH") Wh design"
    tui_kv 12 "Pack voltage"    "$(awk -v v="$BAT_VOLT_UV" 'BEGIN{printf "%.2f", v/1000000}') V"
    if [ "$BAT_POWER_UW" -gt 0 ]; then
      tui_kv 13 "Time left at this rate" \
        "$(awk -v e="$BAT_ENERGY_UWH" -v p="$BAT_POWER_UW" 'BEGIN{h=e/p; printf "%d:%02d", int(h), int((h-int(h))*60)}')"
    fi
    tui_bar 15 "$BAT_PCT"

    if [ "$BAT_PCT" -le 1 ]; then break; fi
    if tui_wait_abort "$SAMPLE_EVERY"; then
      state_set stopped_by operator
      break
    fi
  done
  stop_load
  analyse
}

# ---------------------------------------------------------------- analysis
analyse() {
  local design full cycles start_pct start_e last_e last_pct el stoppedby machine load started
  design=$(num "$(state_get design_uwh)")
  full=$(num "$(state_get full_uwh)")
  cycles=$(state_get cycles)
  start_pct=$(num "$(state_get start_pct)")
  start_e=$(num "$(state_get start_energy_uwh)")
  last_e=$(num "$(state_get last_energy_uwh)")
  last_pct=$(num "$(state_get last_pct)")
  el=$(num "$(state_get last_elapsed)")
  stoppedby=$(state_get stopped_by)
  load=$(state_get load); started=$(state_get started)

  local delivered=$(( start_e - last_e )); [ "$delivered" -lt 0 ] && delivered=0
  local vs_design=0 vs_full=0 avg_w=0 health=0
  [ "$design" -gt 0 ] && vs_design=$(awk -v a="$delivered" -v b="$design" 'BEGIN{printf "%.0f", a*100/b}')
  [ "$full" -gt 0 ]   && vs_full=$(awk -v a="$delivered" -v b="$full" 'BEGIN{printf "%.0f", a*100/b}')
  [ "$design" -gt 0 ] && health=$(awk -v a="$full" -v b="$design" 'BEGIN{printf "%.0f", a*100/b}')
  [ "$el" -gt 0 ] && avg_w=$(awk -v e="$delivered" -v s="$el" 'BEGIN{printf "%.1f", (e/1000000)/(s/3600)}')

  # A pack that cut out while still showing charge is the classic "drains too
  # fast" complaint: the cells cannot hold voltage under load any more.
  local premature=0
  [ "$stoppedby" != operator ] && [ "$last_pct" -gt 15 ] && premature=1

  local state verdict
  if [ "$premature" = 1 ]; then
    state=FAIL; verdict="FAIL (cut out at ${last_pct}% indicated - cell cannot hold voltage)"
  elif [ "$stoppedby" = operator ]; then
    state=PART; verdict="PARTIAL (stopped by operator at ${last_pct}%, ${vs_design}% of design delivered so far)"
  elif [ "$vs_design" -lt 60 ]; then
    state=FAIL; verdict="FAIL (delivered ${vs_design}% of design capacity)"
  elif [ "$vs_full" -lt 70 ] && [ "$full" -gt 0 ]; then
    state=FAIL; verdict="FAIL (delivered ${vs_full}% of what the gauge claimed - gauge is overstating)"
  elif [ "$vs_design" -lt 80 ]; then
    state=WORN; verdict="WORN (delivered ${vs_design}% of design capacity)"
  else
    state=PASS; verdict="PASS (delivered ${vs_design}% of design capacity)"
  fi

  rsection "BATTERY DRAIN TEST"
  rsilent "Started        : $started"
  rsilent "Load           : $load"
  rsilent "Ran for        : $(secs_hms "$el")"
  rsilent "Charge range   : ${start_pct}% down to ${last_pct}%"
  rsilent ""
  rsilent "Design capacity          : $(wh "$design") Wh"
  rsilent "Gauge reports full at    : $(wh "$full") Wh   (${health}% of design)"
  [ -n "$cycles" ] && rsilent "Cycle count              : $cycles"
  rsilent "Energy actually delivered: $(wh "$delivered") Wh"
  rsilent "  as % of design         : ${vs_design}%"
  rsilent "  as % of gauge claim    : ${vs_full}%"
  rsilent "Average draw             : ${avg_w} W"
  [ "$premature" = 1 ] && rsilent "NOTE: the machine lost power while still indicating ${last_pct}% charge."
  local stall; stall=$(state_get CHARGE_STALL)
  [ -n "$stall" ] && rsilent "NOTE: charging stopped at ${stall}% and never reached 100% - the test started from there (a worn pack, or a charge limit)."
  rsilent ""
  rsilent "Reference: 80% of design capacity is the standard end-of-life point for"
  rsilent "lithium cells, usually reached after 300-500 full cycles."
  rsilent ""
  rsilent "RESULT: $verdict"
  set_kv BATTERY_DELIVERED_WH "$(wh "$delivered")"
  set_kv BATTERY_VS_DESIGN_PCT "$vs_design"
  set_kv BATTERY_AVG_DRAW_W "$avg_w"
  set_kv BATTERY_RESULT "$verdict"

  # keep the raw curve with the report
  rsilent ""
  rsilent "Discharge curve (every 10 minutes):"
  awk -F, 'NR>1 && $1%600==0 {printf "  %6s  %3s%%  %6.2f Wh  %5.1f W\n", $1"s", $2, $3/1000000, $5/1000000}' "$SAMPLES" >> "$REPORT_TXT"

  state_set phase DONE
  umount_storage

  tui_frame "Battery drain test finished" "Enter to go back"
  local row=6
  case "$state" in
    PASS) tui_badge $row PASS "the pack delivers what it should" ;;
    WORN) tui_badge $row WARN "degraded but serviceable - plan a replacement" ;;
    FAIL) tui_badge $row FAIL "replace this battery" ;;
    *)    tui_badge $row PARTIAL "stopped early - result is indicative only" ;;
  esac
  row=$((row+2))
  tui_kv $row "Ran for"              "$(secs_hms "$el")"; row=$((row+1))
  tui_kv $row "Charge range"         "${start_pct}% down to ${last_pct}%"; row=$((row+1))
  tui_kv $row "Design capacity"      "$(wh "$design") Wh"; row=$((row+1))
  tui_kv $row "Gauge claims full at" "$(wh "$full") Wh  (${health}% of design)"; row=$((row+1))
  tui_kv $row "Actually delivered"   "$(wh "$delivered") Wh  (${vs_design}% of design)" \
    "$([ "$vs_design" -ge 80 ] && echo "$OKC$B" || { [ "$vs_design" -ge 60 ] && echo "$WRN$B" || echo "$ERR$B"; })"; row=$((row+1))
  tui_kv $row "Average draw"         "${avg_w} W"; row=$((row+2))
  if [ "$premature" = 1 ]; then
    tui_line $row "The machine lost power while still showing ${last_pct}% charge." "$ERR"; row=$((row+1))
    tui_line $row "That is a failing cell, not a calibration problem." "$ERR"; row=$((row+1))
  fi
  tui_line $((row+1)) "80% of design is the standard end-of-life point for lithium cells." "$MUTE"
  tui_anykey "ENTER to go back"
}

# ---------------------------------------------------------------- resume
# Called at startup by the menu: returns 0 when an unfinished log exists.
check_unfinished() {
  local d s
  for d in /dev/disk/by-label/DIAGDATA $(lsblk -rno NAME,FSTYPE 2>/dev/null \
        | awk '$2=="vfat"||$2=="exfat"||$2=="ntfs"||$2~/^ext/ {print "/dev/"$1}'); do
    [ -b "$d" ] || continue
    STORAGE_DEV=$d
    mount_storage_ro || continue
    s="$STORAGE_MNT/DiagReports/battery/$(machine_tag).state"
    if [ -f "$s" ] && [ "$(grep '^phase=' "$s" | tail -1 | cut -d= -f2)" = DRAIN ]; then
      STATE=$s; SAMPLES="$STORAGE_MNT/DiagReports/battery/$(machine_tag).csv"
      return 0
    fi
    umount_storage
  done
  return 1
}

# ---------------------------------------------------------------- entry
# test hook: score an existing log without running a drain
if [ "$1" = "--analyse" ]; then
  STATE=$2; SAMPLES=$3
  analyse
  exit 0
fi

# Startup check. Must stay silent on machines that have no battery at all,
# otherwise it blocks the menu behind a message box on every desktop.
if [ "$1" = "--check-resume" ]; then
  BAT=$(bat_path) || exit 1
  check_unfinished || exit 1
  tui_confirm "Unfinished battery test found" yes \
    "This machine has a battery drain test that never finished -" \
    "it was still running when the machine lost power." \
    "" \
    "  Started      $(state_get started)" \
    "  Last seen    $(state_get last_pct)% after $(secs_hms "$(num "$(state_get last_elapsed)")")" \
    "" \
    "Analyse it now and add the result to the report?" || { umount_storage; exit 0; }
  remount_storage_rw
  analyse
  exit 0
fi

BAT=$(bat_path) || { tui_msg "No battery" "No battery was detected on this machine."; exit 0; }

while :; do
  tui_menu "Battery test" "arrows + ENTER, Q to go back" \
    "Drain test|charge to full, unplug, measure what it actually delivers" \
    "Finish an interrupted test|score a log left behind when the machine died" \
    "Battery details|capacity, cycle count and what the gauge claims" \
    "How this test works|animated: charge, unplug, drain, the account" || break
  case "$TUI_CHOICE" in
    1)
      bat_read
      if [ "$BAT_DESIGN_UWH" -le 0 ]; then
        tui_msg "Capacity not reported" "This machine does not report battery capacity," \
          "so a drain test cannot be scored. Firmware limitation."
        continue
      fi
      tui_confirm "Battery drain test" yes \
        "This runs until the battery is flat and the machine switches off." \
        "" \
        "A sample is written to the USB stick every 30 seconds, so when the" \
        "machine dies you can boot the toolkit again and it will pick the" \
        "test up and score it - nothing is lost." \
        "" \
        "Design capacity $(wh "$BAT_DESIGN_UWH") Wh. Expect several hours at idle." \
        "" "Continue?" || continue
      pick_load || continue
      open_storage || continue
      wait_for_full || { umount_storage; continue; }
      wait_for_unplug || { umount_storage; continue; }
      drain
      ;;
    2)
      if check_unfinished; then
        remount_storage_rw
        analyse
      else
        tui_msg "Nothing to finish" "No unfinished battery log was found for this machine." \
          "" "The log lives in DiagReports/battery on the USB stick."
      fi
      ;;
    3)
      bat_read
      tui_frame "Battery details" "ENTER to go back"
      tui_kv 6  "Vendor / model"  "$(rd "$BAT/manufacturer") $(rd "$BAT/model_name")"
      tui_kv 7  "Technology"      "$(rd "$BAT/technology")"
      tui_kv 8  "Status"          "$BAT_STATUS"
      tui_kv 9  "Charge level"    "${BAT_PCT} %"
      tui_kv 11 "Design capacity" "$(wh "$BAT_DESIGN_UWH") Wh"
      tui_kv 12 "Full capacity"   "$(wh "$BAT_FULL_UWH") Wh"
      if [ "$BAT_DESIGN_UWH" -gt 0 ]; then
        h=$(awk -v a="$BAT_FULL_UWH" -v b="$BAT_DESIGN_UWH" 'BEGIN{printf "%.1f", a*100/b}')
        tui_kv 13 "Gauge health"  "${h} %" \
          "$(awk -v p="$h" 'BEGIN{exit !(p>=80)}' && echo "$OKC$B" || echo "$WRN$B")"
      fi
      tui_kv 14 "Cycle count"     "${BAT_CYCLES:-not reported}"
      tui_kv 15 "Voltage"         "$(awk -v v="$BAT_VOLT_UV" 'BEGIN{printf "%.2f", v/1000000}') V"
      tui_kv 16 "Drawing now"     "$(w "$BAT_POWER_UW") W"
      tui_line 18 "Gauge health is the firmware's own estimate. A drain test measures" "$MUTE"
      tui_line 19 "what the pack really delivers, which is often less." "$MUTE"
      tui_anykey "ENTER to go back"
      ;;
    4) tui_anim battery ;;
  esac
done
