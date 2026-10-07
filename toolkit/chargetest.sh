#!/bin/bash
# Charging test - does the machine see its charger, charge from it, and keep
# the connection when the plug is moved?
#
# The battery test measures what the pack holds; this is the other half of a
# "won't charge" repair: the DC jack, the charger, the charge circuit and the
# USB-C ports. A loose jack - the commonest charging fault - only shows while
# the plug is being moved, so there is a step for exactly that, counting
# every drop.
#
# Everything is read. A charge limit (Dynabook/Toshiba "eco" mode and the
# like) is reported, never changed - firmware settings are off limits.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

PS=${DIAG_PS_ROOT:-/sys/class/power_supply}
TC=${DIAG_TYPEC_ROOT:-/sys/class/typec}
STEP_FILE=$RUN_DIR/charge.step       # the current step - the VM harness reads it
EVENTS=$RUN_DIR/charge-events.log    # kernel power events while the plug is moved
RATE_S=60; WIGGLE_S=30
FINDINGS=(); PORTS_DONE=(); PORTS=()
note() { FINDINGS+=("$1|$2"); }      # FAIL|text, WARN|text
rd() { cat "$1" 2>/dev/null; }
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
step_mark() { printf '%s\n' "$1" > "$STEP_FILE"; }
key_wait() { _ask waitkey "$1"; KEY=$(printf '%s' "$UI_ANS" | tr '[:upper:]' '[:lower:]'); }

# ---------------------------------------------------------------- reading
find_supplies() {
  BAT=""; ADAPTERS=(); MAINS=()
  local p
  for p in "$PS"/*; do
    [ -d "$p" ] || continue
    case "$(rd "$p/type")" in
      Battery) [ "$(rd "$p/scope")" = Device ] && continue    # a mouse or pen battery
               [ -z "$BAT" ] && BAT=$p ;;
      Mains) ADAPTERS+=("$p"); MAINS+=("$p") ;;
      USB|USB_C|USB_PD|USB_PD_DRP|USB_DCP|USB_CDP|USB_ACA) ADAPTERS+=("$p") ;;
    esac
  done
}

flag_name() {   # ADP1 -> ADP1, ucsi-source-psy-USBC000:001 -> USB-C 1
  local n=${1##*/} c
  case "$n" in
    ucsi-source-psy-*)
      c=${n##*:}; c=${c:2}          # ACPI instance (2 hex digits), then the connector
      case "$c" in ''|*[!0-9]*) printf '%s' "$n" ;; *) printf 'USB-C %d' "$((10#$c))" ;; esac ;;
    *) printf '%s' "$n" ;;
  esac
}

flag_list() {   # every charger flag as read now: "ADP1 off, USB-C 1 on"
  local a out=""
  for a in "${ADAPTERS[@]}"; do
    out+="$(flag_name "$a") $([ "$(rd "$a/online")" = 1 ] && echo on || echo off), "
  done
  printf '%s' "${out%, }"
}

charger_names() {   # the chargers the machine reports, by kind
  local a out=""
  for a in "${ADAPTERS[@]}"; do
    case "${a##*/}" in
      ucsi-source-psy*) out+=", USB-C" ;;
      *) [ "$(rd "$a/type")" = Mains ] && out+=", adapter ${a##*/}" || out+=", ${a##*/}" ;;
    esac
  done
  printf '%s' "${out#, }"
}

# The machine thinks a charger is connected. The firmware's own AC flag (a
# Mains supply) decides when there is one: the kernel asks the firmware afresh
# on every read. A USB-C supply's "online" is only the UCSI driver's memory of
# the last event the port sent - on the TECRA A40-J (1.18.0) the test still
# said "connected" a minute after the unplug, battery discharging, and the
# USB-C step then waited for an unplug forever. So the USB-C flags count only
# on machines with no AC flag, and with no flags at all the battery's own
# status is the judge. JUDGE=battery once a flag has been caught lying (the
# battery saw the plug go, or charged from "nothing") - see step_unplug/plug.
plugged() {
  local a
  [ "$JUDGE" = battery ] && { on_charger; return; }
  for a in "${MAINS[@]}"; do [ "$(rd "$a/online")" = 1 ] && return 0; done
  [ ${#MAINS[@]} -gt 0 ] && return 1
  for a in "${ADAPTERS[@]}"; do [ "$(rd "$a/online")" = 1 ] && return 0; done
  [ ${#ADAPTERS[@]} -gt 0 ] && return 1
  on_charger
}

on_charger() { case "$(rd "$BAT/status")" in Charging|Full|"Not charging") return 0 ;; esac; return 1; }

charging_ok() {   # charging, full, or held at the charge limit as set
  case "$(bat_status)" in
    Charging|Full) return 0 ;;
    "Not charging") [ -n "$LIMIT" ] && [ "$(bat_pct)" -ge $(( LIMIT - 3 )) ] ;;
    *) return 1 ;;
  esac
}

bat_status() { local s; s=$(rd "$BAT/status"); printf '%s' "${s:-Unknown}"; }
bat_pct() { num "$(rd "$BAT/capacity")"; }

bat_watts() {   # power into or out of the battery, or nothing when not reported
  local p c v
  p=$(rd "$BAT/power_now")
  if [ -z "$p" ]; then
    c=$(rd "$BAT/current_now"); v=$(rd "$BAT/voltage_now")
    [ -n "$c" ] && [ -n "$v" ] && p=$(awk -v c="$c" -v v="$v" 'BEGIN{if(c<0)c=-c; printf "%.0f", c*v/1e6}')
  fi
  [ -n "$p" ] || return 1
  awk -v p="$p" 'BEGIN{if(p<0)p=-p; printf "%.1f", p/1e6}'
}

bat_energy_wh() {   # charge in the pack now, in Wh
  local e c v
  e=$(rd "$BAT/energy_now")
  [ -n "$e" ] && { awk -v e="$e" 'BEGIN{printf "%.3f", e/1e6}'; return; }
  c=$(rd "$BAT/charge_now"); v=$(rd "$BAT/voltage_min_design"); [ -n "$v" ] || v=$(rd "$BAT/voltage_now")
  [ -n "$c" ] && [ -n "$v" ] && awk -v c="$c" -v v="$v" 'BEGIN{printf "%.3f", c*v/1e12}'
}

bat_full_wh() {
  local e c v
  e=$(rd "$BAT/energy_full")
  [ -n "$e" ] && { awk -v e="$e" 'BEGIN{printf "%.1f", e/1e6}'; return; }
  c=$(rd "$BAT/charge_full"); v=$(rd "$BAT/voltage_min_design"); [ -n "$v" ] || v=$(rd "$BAT/voltage_now")
  [ -n "$c" ] && [ -n "$v" ] && awk -v c="$c" -v v="$v" 'BEGIN{printf "%.1f", c*v/1e12}'
}

# What a USB-C charger offers: "20.0 V up to 3.25 A (65 W)".
psy_contract() {
  local uv ua
  uv=$(rd "$1/voltage_now"); ua=$(rd "$1/current_max")
  [ -n "$uv" ] && [ -n "$ua" ] || return 1
  awk -v v="$uv" -v a="$ua" 'BEGIN{printf "%.1f V up to %.2f A (%.0f W)", v/1e6, a/1e6, v*a/1e12}'
}

usbc_contract() {   # typec port -> the contract of the charger in it
  local ps want="USB-C $(( ${1##*port} + 1 ))"
  for ps in "$PS"/ucsi-source-psy-*; do
    [ "$(flag_name "$ps")" = "$want" ] && [ "$(rd "$ps/online")" = 1 ] && { psy_contract "$ps"; return; }
  done
  return 1
}

# The one USB-C charger in, when it is clear which: with a port that never
# reported its unplug, two would be "online" and either figure could be stale.
usbc_offer() {
  local ps on=()
  for ps in "$PS"/ucsi-source-psy-*; do [ "$(rd "$ps/online")" = 1 ] && on+=("$ps"); done
  [ ${#on[@]} = 1 ] && psy_contract "${on[0]}"
}

# The animation draws the charger's plug as USB-C when that is what is in.
plug_kind() { usbc_offer >/dev/null && PLUG_OPT=usbc; return 0; }

# ---------------------------------------------------------------- screens
# Rows 13-17: the live state every step shows. The flags row is there for the
# photo: which flag said what is the evidence when a machine disagrees.
status_rows() {
  local w on=0 c
  plugged && on=1
  w=$(bat_watts)
  if [ "$on" = 1 ]; then tui_kv 13 "Charger" "connected" ok; else tui_kv 13 "Charger" "not connected" warn; fi
  tui_kv 14 "Battery" "$(bat_pct)%   $(bat_status)"
  [ -n "$w" ] && tui_kv 15 "Power" "$w W $( [ "$(bat_status)" = Charging ] && echo into || echo out of ) the battery"
  [ "$on" = 1 ] && c=$(usbc_offer) && tui_kv 16 "Charger offers" "$c"
  [ ${#ADAPTERS[@]} -gt 0 ] && \
    tui_kv 17 "Charger flags" "$(flag_list)$([ "$JUDGE" = battery ] && echo " (going by the battery)")" muted
  return 0
}

frame() {   # step-name line1 [line2]
  tui_frame "Charging test - $1" "S = skip this step     Q = stop"
  tui_line 6 "$2" ""
  [ -n "$3" ] && tui_line 7 "$3" muted
}

# ---------------------------------------------------------------- steps
# Each step returns 0 done, 1 skipped or not seen, 2 stopped by Q.
step_unplug() {
  local t was dis=0
  plugged || return 0
  step_mark unplug
  was=$(bat_status)
  frame "unplug" "Unplug the charger from the laptop."; tui_anim_live charge 0 0 $PLUG_OPT
  for (( t = 0; t < 60; t++ )); do
    frame "unplug" "Unplug the charger from the laptop." "The test goes on by itself the moment the machine notices."
    tui_kv 10 "Waiting" "$t s"
    status_rows; tui_flush
    plugged || { UNPLUG_SEEN=1; UNPLUG_FLAGS=$(flag_list); return 0; }
    # The battery is the second witness: discharging for 5 s straight when it
    # was not at the start, the charger is out - whatever a flag still says.
    if [ "$was" != Discharging ] && [ "$(bat_status)" = Discharging ]; then dis=$((dis+1)); else dis=0; fi
    if [ "$dis" -ge 5 ]; then
      UNPLUG_SEEN=1; UNPLUG_FLAGS=$(flag_list); JUDGE=battery
      note WARN "the firmware still reported a charger after it was unplugged ($UNPLUG_FLAGS) - only the battery noticed, so the rest of the test went by the battery. A BIOS update may cure it"
      return 0
    fi
    key_wait 1; case "$KEY" in q) return 2 ;; s) return 1 ;; esac
  done
  note WARN "the machine did not notice the charger being unplugged (or it was left in)"
  return 1
}

step_plug() {
  local t t_on=-1 st
  step_mark plug
  frame "plug in" "Plug the charger in."; tui_anim_live charge 1 1 $PLUG_OPT
  for (( t = 0; t < 90; t++ )); do
    frame "plug in" "Plug the charger in." "Use the charger that came with the machine, or one of the same wattage."
    tui_kv 10 "Waiting" "$t s"
    status_rows; tui_flush
    if plugged; then t_on=$t; break; fi
    # The other way round: a battery charging from "nothing" means a flag is
    # wrong, not that the charger is missing.
    if [ "$(bat_status)" = Charging ]; then
      JUDGE=battery; t_on=$t
      note WARN "the battery charges but the firmware does not report a charger ($(flag_list)) - the rest of the test went by the battery. A BIOS update may cure it"
      break
    fi
    key_wait 1; case "$KEY" in q) return 2 ;; s) NO_CHARGER=1; return 1 ;; esac
  done
  if [ "$t_on" -lt 0 ]; then
    note FAIL "the charger was not detected - check the charger, the DC jack and the charge board"
    return 1
  fi
  PLUG_SEEN=1
  plug_kind
  for (( t = 0; t < 20; t++ )); do
    st=$(bat_status)
    case "$st" in
      Charging) CHARGE_START=$t; return 0 ;;
      Full) return 0 ;;
    esac
    frame "plug in" "Charger seen - waiting for the battery to start charging..."
    tui_kv 10 "Waiting" "$t s"; status_rows; tui_flush
    sleep 1
  done
  st=$(bat_status)
  charging_ok && return 0                     # held at the charge limit, as set
  if [ "$st" = "Not charging" ]; then
    note FAIL "the charger is seen but the machine refuses to charge (status: not charging) - suspect the battery, a charger of the wrong wattage, or the charge circuit"
  else
    note FAIL "the charger is seen but the battery is not charging (status: $st)"
  fi
  return 1
}

step_rate() {
  local t w sum=0 n=0 e0 e1 p0 prev=1 cur drops=0
  case "$(bat_status)" in Charging) ;; *) RATE_NOTE="not measured - the battery was not charging"; return 1 ;; esac
  p0=$(bat_pct)
  [ "$p0" -ge 95 ] && { RATE_NOTE="not measured - the battery is nearly full (charging slows near full)"; return 1; }
  step_mark rate
  frame "charge rate" "Measuring how fast the battery charges. Leave the charger in, do not touch it."
  tui_anim_live charge 2 2 $PLUG_OPT
  e0=$(bat_energy_wh)
  for (( t = 0; t < RATE_S; t += 2 )); do
    frame "charge rate" "Measuring how fast the battery charges. Leave the charger in, do not touch it."
    tui_kv 10 "Time" "$t of $RATE_S s"
    w=$(bat_watts) && { sum=$(awk -v s="$sum" -v w="$w" 'BEGIN{print s+w}'); n=$((n+1)); }
    if plugged; then cur=1; else cur=0; fi
    [ "$prev" = 1 ] && [ "$cur" = 0 ] && drops=$((drops+1)); prev=$cur
    status_rows; tui_bar 22 $(( t * 100 / RATE_S )); tui_flush
    key_wait 2; case "$KEY" in q) return 2 ;; s) RATE_NOTE="skipped"; return 1 ;; esac
  done
  [ "$drops" -gt 0 ] && note FAIL "the charger connection dropped $drops time(s) while nobody was touching it - charger, cable or jack"
  e1=$(bat_energy_wh)
  if [ "$n" -gt 0 ] && awk -v s="$sum" 'BEGIN{exit !(s>0)}'; then
    RATE_W=$(awk -v s="$sum" -v n="$n" 'BEGIN{printf "%.1f", s/n}')
  elif [ -n "$e0" ] && [ -n "$e1" ]; then
    # firmware that reports no power at all: the charge gained over the minute
    RATE_W=$(awk -v a="$e0" -v b="$e1" -v s="$RATE_S" 'BEGIN{d=b-a; if(d<=0){exit} printf "%.1f", d*3600/s}')
  fi
  RATE_PCT=$(( $(bat_pct) - p0 ))
  if [ -z "$RATE_W" ]; then
    RATE_NOTE="the firmware does not report how fast it charges"
    return 0
  fi
  local full want; full=$(bat_full_wh)
  # Above ~80% every pack slows down on purpose, and a tiny "full" figure
  # means the firmware's numbers are not real Wh - judge only when both hold.
  if [ "$p0" -lt 80 ] && awk -v f="${full:-0}" 'BEGIN{exit !(f>=10)}'; then
    want=$(awk -v f="$full" 'BEGIN{w=f*0.15; if(w<5)w=5; printf "%.0f", w}')
    awk -v r="$RATE_W" -v w="$want" 'BEGIN{exit !(r<w)}' \
      && note WARN "charging slowly: $RATE_W W (about $want W or more is normal for this $full Wh battery) - a weak or wrong-wattage charger, or a worn battery"
  fi
  return 0
}

# Kernel power events are recorded alongside the polling, so a drop too
# short to be caught by looking 4 times a second is still counted.
step_wiggle() {
  local t prev cur upid polled=0 flips=0 st prevst ev
  plugged || { WIGGLE_NOTE="not done - no charger connected"; return 1; }
  step_mark wiggle
  frame "wiggle" "Gently move the charger plug and cable - up, down, side to side."
  tui_anim_live charge 3 3 $PLUG_OPT
  : > "$EVENTS"
  udevadm monitor --kernel --property --subsystem-match=power_supply > "$EVENTS" 2>/dev/null &
  upid=$!
  prev=1; prevst=$(bat_status)
  for (( t = 0; t < WIGGLE_S * 4; t++ )); do
    if plugged; then cur=1; else cur=0; fi
    [ "$prev" = 1 ] && [ "$cur" = 0 ] && polled=$((polled+1))
    st=$(bat_status)
    [ "$prevst" = Charging ] && [ "$st" = Discharging ] && flips=$((flips+1))
    prev=$cur; prevst=$st
    if [ $(( t % 4 )) = 0 ]; then
      frame "wiggle" "Gently move the charger plug and cable - up, down, side to side." \
        "As you would to check for a loose jack. Every drop in the connection is counted."
      tui_kv 10 "Time" "$(( t / 4 )) of $WIGGLE_S s"
      tui_kv 11 "Connection drops" "$polled" "$([ "$polled" -gt 0 ] && echo err || echo ok)"
      status_rows; tui_bar 22 $(( t * 100 / (WIGGLE_S * 4) )); tui_flush
    fi
    key_wait 0.25; case "$KEY" in q) kill "$upid" 2>/dev/null; return 2 ;; s) break ;; esac
  done
  kill "$upid" 2>/dev/null; wait "$upid" 2>/dev/null
  ev=$(grep -c '^POWER_SUPPLY_ONLINE=0' "$EVENTS" 2>/dev/null)
  DROPS=$polled
  [ "${ev:-0}" -gt "$DROPS" ] && DROPS=$ev
  [ "$flips" -gt "$DROPS" ] && DROPS=$flips
  WIGGLE_DONE=1
  [ "$DROPS" -gt 0 ] && note FAIL "the charger connection broke $DROPS time(s) while the plug was moved - suspect the DC jack or its solder joints, the cable, or the charger plug"
  return 0
}

partners() {   # the USB-C ports UCSI says have something in, one per line
  local tp
  for tp in "${PORTS[@]}"; do [ -d "${tp}-partner" ] && printf '%s\n' "$tp"; done
}

new_partner() {   # ports-before -> a port with something in now that had nothing then
  local tp
  for tp in $(partners); do
    printf '%s\n' "$1" | grep -qx "$tp" || { printf '%s' "$tp"; return 0; }
  done
  return 1
}

usbc_frame() {   # instruction [second line]: the ports so far and the live state under it
  local row=9 d
  frame "USB-C" "$1" "$2"
  for d in "${PORTS_DONE[@]}"; do
    [ $row -gt 12 ] && break
    case "$d" in *": charges"*) tui_line $row "$d" ok ;; *) tui_line $row "$d" err ;; esac
    row=$((row+1))
  done
  status_rows; tui_flush
}

# Each USB-C port that can take power: plug the charger in, see whether the
# machine charges from it. A port only counts if something was plugged into it.
#
# In and out are judged by plugged(), never by the port: the A40-J's ports did
# not report the unplug (1.18.0), so a port could look in use with nothing in
# it, and waiting for it to empty waited forever. Which port the charger went
# into comes from a port that reports something new after the plug - one
# already "in use" cannot say - and when none does, the try still counts, as
# "the machine did not say which port"; the operator knows which they used.
step_usbc() {
  local tp t found where label contract before msg again=""
  PORTS=()
  for tp in "$TC"/port[0-9]*; do
    [[ ${tp##*/} =~ ^port[0-9]+$ ]] || continue
    case "$(rd "$tp/power_role")" in *sink*) PORTS+=("$tp") ;; esac
  done
  [ ${#PORTS[@]} -gt 0 ] || { USBC_NOTE="no USB-C port that can charge the machine was reported"; return 1; }
  usbc_frame "Unplug the charger first." "Then each USB-C port is tried on its own."
  tui_anim_live charge 4 4
  while [ ${#PORTS_DONE[@]} -lt ${#PORTS[@]} ]; do
    step_mark "usbc-${#PORTS_DONE[@]}"
    # Another charger still connected would keep the battery charging and
    # make every port look good.
    msg="Unplug the charger first."
    [ -n "$where" ] && msg="Unplug the charger from $where."
    [ -n "$again" ] && msg="Unplug the charger: $where was tried already - use a port not tried yet."
    while plugged; do
      usbc_frame "$msg" "Then each USB-C port is tried on its own."
      key_wait 1; case "$KEY" in q) return 2 ;; s) return 1 ;; esac
    done
    again=""
    before=$(partners); found=""
    for (( t = 0; t < 60; t++ )); do
      usbc_frame "Plug the USB-C charger into a USB-C port not tried yet (${#PORTS_DONE[@]} of ${#PORTS[@]} done)."
      plugged && break
      found=$(new_partner "$before") && break
      key_wait 1; case "$KEY" in q) return 2 ;; s) return 1 ;; esac
    done
    if [ -z "$found" ] && ! plugged; then
      USBC_NOTE="no charger was plugged into a USB-C port within a minute"
      return 1
    fi
    for (( t = 0; t < 6; t++ )); do          # the port can report a moment after the flag
      [ -n "$found" ] && break
      sleep 0.5; found=$(new_partner "$before")
    done
    if [ -n "$found" ]; then
      where="USB-C port $(( ${found##*port} + 1 ))"; label=$where
      if printf '%s\n' "${PORTS_DONE[@]}" | grep -q "^$label:"; then
        again=1; continue
      fi
      contract=$(usbc_contract "$found")
    else
      where="that port"; contract=""
      label="USB-C try $(( ${#PORTS_DONE[@]} + 1 )) (the machine did not say which port)"
    fi
    for (( t = 0; t < 15; t++ )); do
      charging_ok && break
      usbc_frame "Charger in $where - waiting for the battery to charge..."
      key_wait 1; [ "$KEY" = q ] && return 2
    done
    if charging_ok; then
      PORTS_DONE+=("$label: charges${contract:+ - $contract}")
    else
      PORTS_DONE+=("$label: charger seen${contract:+ ($contract)}, but the battery did not charge")
      note FAIL "$label sees the charger but does not charge the battery"
    fi
  done
  return 0
}

# ---------------------------------------------------------------- report
finish() {   # stopped(0|1)
  local state f row=9
  if [ "$1" = 1 ]; then state=STOPPED
  elif printf '%s\n' "${FINDINGS[@]}" | grep -q '^FAIL|'; then state=FAIL
  elif printf '%s\n' "${FINDINGS[@]}" | grep -q '^WARN|'; then state=WARN
  elif [ "$NO_CHARGER" = 1 ]; then state=NOTTESTED
  else state=PASS; fi
  step_mark done

  rsection "CHARGING"
  rsilent "Chargers reported : ${CHARGERS:-none listed by the firmware}"
  rsilent "Battery           : $(rd "$BAT/manufacturer") $(rd "$BAT/model_name")  $(bat_pct)%  $(bat_status)"
  [ -n "$LIMIT" ] && rsilent "Charge limit      : $LIMIT% (set in the firmware - charging stops there on purpose)"
  rsilent "Unplug noticed    : $([ "$UNPLUG_SEEN" = 1 ] && echo yes || echo "not checked")"
  [ -n "$UNPLUG_FLAGS" ] && rsilent "Flags unplugged   : $UNPLUG_FLAGS"
  [ ${#ADAPTERS[@]} -gt 0 ] && rsilent "Flags at the end  : $(flag_list)"
  [ "$JUDGE" = battery ] && rsilent "Judged by         : the battery's own status (a firmware flag was wrong)"
  rsilent "Charger noticed   : $([ "$PLUG_SEEN" = 1 ] && echo "yes${CHARGE_START:+, charging after $CHARGE_START s}" || echo no)"
  rsilent "Charge rate       : ${RATE_W:+$RATE_W W}${RATE_PCT:+, +$RATE_PCT% in $RATE_S s}${RATE_NOTE:+ $RATE_NOTE}"
  rsilent "Wiggle check      : $([ "$WIGGLE_DONE" = 1 ] && echo "$DROPS drop(s) in $WIGGLE_S s" || echo "${WIGGLE_NOTE:-not done}")"
  for f in "${PORTS_DONE[@]}"; do rsilent "USB-C             : $f"; done
  [ -n "$USBC_NOTE" ] && rsilent "USB-C             : $USBC_NOTE"
  for f in "${FINDINGS[@]}"; do rsilent "  ${f%%|*}: ${f#*|}"; done
  case "$state" in
    PASS)      rsilent "RESULT: PASS -- charger seen, battery charges, connection held"; set_kv CHARGE_RESULT PASSED ;;
    WARN)      rsilent "RESULT: WARN -- charges, with points to look at"; set_kv CHARGE_RESULT "WARN (${#FINDINGS[@]})" ;;
    FAIL)      rsilent "RESULT: FAIL -- charging fault"; set_kv CHARGE_RESULT FAILED ;;
    NOTTESTED) rsilent "RESULT: NOT TESTED -- no charger was plugged in"; set_kv CHARGE_RESULT "NOT TESTED (no charger)" ;;
    *)         rsilent "RESULT: NOT TESTED -- stopped by the operator"; set_kv CHARGE_RESULT "NOT TESTED (stopped)" ;;
  esac

  tui_frame "Charging test" "Enter to go back"
  case "$state" in
    PASS) tui_badge 6 PASS "charger seen, battery charges, connection held" ;;
    WARN) tui_badge 6 PARTIAL "charges - with points to look at" ;;
    FAIL) tui_badge 6 FAIL "charging fault" ;;
    *)    tui_badge 6 UNKNOWN "not fully tested" ;;
  esac
  tui_kv $row "Charger noticed" "$([ "$PLUG_SEEN" = 1 ] && echo yes || echo no)" "$([ "$PLUG_SEEN" = 1 ] && echo ok || echo warn)"; row=$((row+1))
  tui_kv $row "Charge rate" "${RATE_W:+$RATE_W W}${RATE_NOTE:+ $RATE_NOTE}"; row=$((row+1))
  [ "$WIGGLE_DONE" = 1 ] && { tui_kv $row "Wiggle check" "$DROPS drop(s)" "$([ "$DROPS" -gt 0 ] && echo err || echo ok)"; row=$((row+1)); }
  [ -n "$LIMIT" ] && { tui_kv $row "Charge limit" "$LIMIT% - set in the firmware, on purpose"; row=$((row+1)); }
  for f in "${PORTS_DONE[@]}"; do [ $row -gt 15 ] && break; tui_line $row "$f" ""; row=$((row+1)); done
  row=$((row+1))
  for f in "${FINDINGS[@]}"; do
    [ $row -gt 19 ] && break
    row=$(tui_para $row "${f#*|}" "$([ "${f%%|*}" = FAIL ] && echo err || echo warn)")
  done
  tui_flush; tui_anykey
}

# ---------------------------------------------------------------- run
modprobe ucsi_acpi 2>/dev/null      # USB-C ports and PD chargers, when the firmware describes them
sleep 0.3
find_supplies
if [ -z "$BAT" ] && [ ${#ADAPTERS[@]} -eq 0 ]; then
  tui_msg "Nothing to test" "This machine reports no battery and no charger." \
    "(A desktop, or firmware that hides them.)"
  rsection "CHARGING"; rsilent "RESULT: NOT TESTED -- no battery or charger reported"
  set_kv CHARGE_RESULT "NOT TESTED (none reported)"
  exit 0
fi
LIMIT=$(rd "$BAT/charge_control_end_threshold")
case "$LIMIT" in ''|100|*[!0-9]*) LIMIT="" ;; esac
CHARGERS=$(charger_names)
UNPLUG_SEEN=0; PLUG_SEEN=0; NO_CHARGER=0; DROPS=0; WIGGLE_DONE=0
CHARGE_START=""; RATE_W=""; RATE_PCT=""; RATE_NOTE=""; WIGGLE_NOTE=""; USBC_NOTE=""
JUDGE=flags; PLUG_OPT=""; UNPLUG_FLAGS=""
plugged && plug_kind

tui_confirm "Charging test" yes \
  "Chargers reported: ${CHARGERS:-none listed by the firmware}" \
  "Battery: $(bat_pct)%, $(bat_status)${LIMIT:+ - charge limit $LIMIT% (left as it is)}" "" \
  "1. Unplug the charger, then plug it back in." \
  "2. One minute measuring how fast it charges." \
  "3. 30 seconds gently moving the plug - catches a loose jack." \
  "4. Each USB-C port that can charge, if there are any." \
  "" "About three minutes. Start?" || exit 0

stopped=0
for s in step_unplug step_plug step_rate step_wiggle step_usbc; do
  [ "$s" = step_rate ] && [ "$PLUG_SEEN" != 1 ] && continue
  [ "$s" = step_wiggle ] && [ "$PLUG_SEEN" != 1 ] && continue
  "$s"; [ $? = 2 ] && { stopped=1; break; }
done
finish "$stopped"
exit 0
