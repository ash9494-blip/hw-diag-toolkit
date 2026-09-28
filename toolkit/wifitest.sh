#!/bin/bash
# Wireless stability test.
#
# A wifi card either works or it does not is the wrong question on a repair
# bench. The faults that actually come in are intermittent: an antenna cable
# left unplugged after a screen replacement, a U.FL connector that has worked
# loose, a card that associates and then drops after four minutes, a machine
# that is fine next to the AP and useless one room away. None of those show up
# in a connect-once check, so this watches a live link over time and reports
# what changed.
#
# Four parts, each usable on its own:
#   1. Scan      - every AP the radio can hear, with signal and channel. This
#                  alone proves the radio and both antennas are alive, and needs
#                  no password.
#   2. Connect   - associate with a chosen network.
#   3. Stability - sample signal, link rate, channel and BSSID every 2 s while
#                  pinging the gateway continuously. Drops, roams and signal
#                  collapse are timestamped.
#   4. Internet  - DNS, HTTPS latency to several endpoints, and throughput.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

WPA_CONF=$RUN_DIR/wpa.conf
WPA_LOG=$RUN_DIR/wpa.log
SAMPLES=$RUN_DIR/wifi_samples      # t  rssi  rate  chan  bssid  ping_ms
EVENTS=$RUN_DIR/wifi_events
SCAN_CACHE=$RUN_DIR/wifi_scan

DURATION=${DIAG_WIFI_SECS:-$(setting_get wifi_secs 600)}   # the picker overrides it
SAMPLE_EVERY=2                     # seconds between samples
OWNED_IFACE=0                      # 1 when we brought the link up ourselves

ev() { printf '%s\t%s\t%s\n' "$(date '+%H:%M:%S')" "$1" "$2" >> "$EVENTS"; }

# ---------------------------------------------------------------- the radio
wifi_ifaces() {
  local d n
  for d in /sys/class/net/*; do
    [ -d "$d/wireless" ] || [ -L "$d/phy80211" ] || continue
    n=${d##*/}
    printf '%s\n' "$n"
  done
}

iface_driver() { basename "$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null)" 2>/dev/null; }

iface_chip() {
  local i=$1 p v d
  p=$(readlink -f "/sys/class/net/$i/device" 2>/dev/null) || return
  v=$(cat "$p/vendor" 2>/dev/null); d=$(cat "$p/device" 2>/dev/null)
  local name
  name=$(lspci -d "${v#0x}:${d#0x}" 2>/dev/null | head -1 | sed 's/^[0-9a-f:.]* //')
  [ -z "$name" ] && name=$(lsusb 2>/dev/null | grep -i wireless | head -1 | sed 's/.*: //')
  printf '%s' "${name:-unknown}"
}

# A card that is soft- or hard-blocked looks identical to a dead one until you
# ask rfkill, and a hardware block is a switch or a BIOS setting, not a fault.
rfkill_state() {
  command -v rfkill >/dev/null || { printf 'unknown'; return; }
  local out; out=$(rfkill list 2>/dev/null | grep -A2 -i 'wlan\|wireless' | head -3)
  case "$out" in
    *"Hard blocked: yes"*) printf 'hard blocked' ;;
    *"Soft blocked: yes"*) printf 'soft blocked' ;;
    *) printf 'not blocked' ;;
  esac
}

signal_dbm() {   # current RSSI, or empty
  iw dev "$1" link 2>/dev/null | awk '/signal:/{print $2; exit}'
}
link_rate() { iw dev "$1" link 2>/dev/null | awk '/tx bitrate:/{print $3; exit}'; }
link_bssid() { iw dev "$1" link 2>/dev/null | awk '/^Connected to/{print $3; exit}'; }
link_ssid() { iw dev "$1" link 2>/dev/null | awk '/SSID:/{$1="";sub(/^ /,"");print;exit}'; }
link_freq() { iw dev "$1" link 2>/dev/null | awk '/freq:/{print $2; exit}'; }

freq_band() {    # 2412 -> "2.4 GHz ch 1"
  local f=$1 ch=""
  case "$f" in
    24[0-9][0-9]|2[45][0-9][0-9]) ch=$(( (f - 2407) / 5 )); printf '2.4 GHz ch %s' "$ch" ;;
    5[0-9][0-9][0-9]) ch=$(( (f - 5000) / 5 )); printf '5 GHz ch %s' "$ch" ;;
    6[0-9][0-9][0-9]|7[0-9][0-9][0-9]) ch=$(( (f - 5950) / 5 )); printf '6 GHz ch %s' "$ch" ;;
    *) printf '%s MHz' "$f" ;;
  esac
}

# Signal quality in words. These thresholds are the ones that matter in
# practice: above -60 everything works, below -80 nothing does reliably, and an
# internal antenna that has come unplugged typically reads -85 or worse while
# sitting next to the access point - which is how you tell it apart from simply
# being far away.
rssi_verdict() {
  local r=$1
  [ -z "$r" ] && { printf 'unknown'; return; }
  if   [ "$r" -ge -55 ]; then printf 'excellent'
  elif [ "$r" -ge -67 ]; then printf 'good'
  elif [ "$r" -ge -75 ]; then printf 'usable'
  elif [ "$r" -ge -82 ]; then printf 'weak'
  else printf 'very weak'
  fi
}

# ---------------------------------------------------------------- 1. scan
do_scan() {   # iface -> writes SCAN_CACHE: rssi TAB freq TAB enc TAB ssid
  wifi_scan_tsv "$1" "$SCAN_CACHE"
}

wifi_scan_progress() {   # attempt last-error
  tui_frame "Wireless - scanning" "please wait"
  tui_line 8 "Listening for access points on every channel...  (attempt $1 of 3)" muted
  [ -n "$2" ] && tui_line 10 "Last try: $(wifi_scan_explain)" warn
  tui_flush
}

scan_screen() {
  local i=$1
  tui_frame "Wireless - scanning" "please wait"
  tui_line 8 "Listening for access points on every channel..." muted
  tui_flush
  if ! do_scan "$i"; then
    tui_msg "No networks found" \
      "$(wifi_scan_explain)" "" \
      "Reported: ${WIFI_SCAN_ERR:-nothing}" "" \
      "If a phone in the same spot sees networks, suspect the antenna leads."
    return 1
  fi
  local n; n=$(wc -l < "$SCAN_CACHE")
  local best; best=$(head -1 "$SCAN_CACHE" | cut -f1)

  tui_frame "Wireless - networks in range" "Enter to go on"
  tui_kv 6 "Access points heard" "$n"
  tui_kv 7 "Strongest signal"    "$best dBm  ($(rssi_verdict "$best"))" \
         "$( [ "${best:-0}" -ge -67 ] && echo ok || echo warn )"
  local row=9 rssi freq enc ssid
  tui_line $row "$(printf '%-26s %8s  %-14s %s' SSID SIGNAL BAND SECURITY)" muted
  row=$((row+1))
  while IFS=$'\t' read -r rssi freq enc ssid; do
    [ $row -gt 21 ] && break
    tui_line $row "$(printf '%-26.26s %5s dBm  %-14s %s' "$ssid" "$rssi" "$(freq_band "$freq")" "$enc")" \
      "$( [ "$rssi" -ge -75 ] && echo "" || echo muted )"
    row=$((row+1))
  done < "$SCAN_CACHE"
  [ "${best:-0}" -lt -75 ] && tui_line $((row+1)) \
    "Everything is faint - suspect an unplugged antenna if the AP is nearby." warn
  tui_flush
  tui_anykey
  return 0
}

# ---------------------------------------------------------------- 2. the link
# Connecting moved to the Wi-Fi page on the home screen. Doing it here as well
# meant typing the password twice on a machine that was already online, and two
# copies of the same wpa_supplicant handling that could disagree about which
# link was in use.
require_link() {   # -> 0 when there is a live wireless link to watch
  local i
  for i in $(wifi_ifaces); do
    [ -n "$(link_ssid "$i")" ] || continue
    IFACE=$i
    SSID=$(link_ssid "$i")
    IPADDR=$(ip -4 addr show "$i" 2>/dev/null | awk '/inet /{print $2; exit}')
    GATEWAY=$(ip route 2>/dev/null | awk -v d="$i" '$1=="default" && $0 ~ d {print $3; exit}')
    [ -z "$GATEWAY" ] && GATEWAY=$(ip route 2>/dev/null | awk '$1=="default"{print $3; exit}')
    return 0
  done
  return 1
}

no_link_screen() {
  tui_frame "Wireless test" "Enter to go back"
  tui_badge 6 UNKNOWN "not connected to a network"
  tui_line 9  "This test watches a live wireless link - signal, roaming and" ""
  tui_line 10 "packet loss over several minutes - so it needs one to watch." ""
  tui_line 12 "Connect first: go back to the main menu and choose Wi-Fi," warn
  tui_line 13 "then come back here." warn
  tui_line 15 "The scan below still works without connecting, and on its own" muted
  tui_line 16 "proves the radio and both antennas are alive." muted
  tui_flush
  tui_anykey
}

pick_network() {
  local -a ss=() labels=()
  local rssi freq enc ssid
  while IFS=$'\t' read -r rssi freq enc ssid; do
    [ "$ssid" = "(hidden)" ] && continue
    ss+=("$ssid|$enc")
    labels+=("$(printf '%-24.24s %5s dBm  %-13s %s' "$ssid" "$rssi" "$(freq_band "$freq")" "$enc")")
  done < "$SCAN_CACHE"
  [ ${#ss[@]} -eq 0 ] && { tui_msg "Nothing to join" "No named networks were found."; return 1; }
  tui_menu "Choose a network" "arrows + Enter, Q to skip the connected tests" "${labels[@]}" || return 1
  local pick=${ss[$((TUI_CHOICE-1))]}
  SSID=${pick%|*}; ENC=${pick##*|}
  return 0
}

connect_wifi() {   # iface
  local i=$1
  if [ "$ENC" = open ]; then
    cat > "$WPA_CONF" <<EOF
network={
	ssid="$SSID"
	key_mgmt=NONE
}
EOF
  else
    tui_input "Wi-Fi password" "Password for $SSID (leave blank to cancel):"
    [ -z "$TUI_TEXT" ] && return 1
    # wpa_passphrase keeps the plaintext out of the file where it can.
    if command -v wpa_passphrase >/dev/null; then
      wpa_passphrase "$SSID" "$TUI_TEXT" > "$WPA_CONF" 2>/dev/null
    else
      cat > "$WPA_CONF" <<EOF
network={
	ssid="$SSID"
	psk="$TUI_TEXT"
}
EOF
    fi
    TUI_TEXT=""
  fi
  chmod 600 "$WPA_CONF" 2>/dev/null

  tui_frame "Wireless - connecting" "please wait"
  tui_line 8 "Associating with $SSID..." ""
  tui_flush

  pkill -x wpa_supplicant 2>/dev/null
  sleep 1
  ip link set "$i" up 2>/dev/null
  wpa_supplicant -B -i "$i" -c "$WPA_CONF" -f "$WPA_LOG" 2>/dev/null
  OWNED_IFACE=1

  local n
  for n in $(seq 1 25); do
    sleep 1
    [ -n "$(link_bssid "$i")" ] && break
    tui_line 10 "waiting for association... ${n}s" muted
    tui_flush
  done
  if [ -z "$(link_bssid "$i")" ]; then
    local why="no reply from the access point"
    grep -qi 'WRONG_KEY\|4-Way Handshake failed' "$WPA_LOG" 2>/dev/null && why="the password was rejected"
    tui_msg "Could not connect" "Association with $SSID failed - $why." "" \
      "The radio and antennas are still proven by the scan above."
    return 1
  fi

  tui_line 10 "associated, asking for an address..." ""
  tui_flush
  dhclient -1 -timeout 20 "$i" 2>/dev/null &
  local dh=$!
  for n in $(seq 1 22); do
    sleep 1
    [ -n "$(ip -4 addr show "$i" 2>/dev/null | awk '/inet /{print $2}')" ] && break
  done
  wait $dh 2>/dev/null
  IPADDR=$(ip -4 addr show "$i" 2>/dev/null | awk '/inet /{print $2; exit}')
  GATEWAY=$(ip route 2>/dev/null | awk -v d="$i" '$1=="default" && $0 ~ d {print $3; exit}')
  [ -z "$GATEWAY" ] && GATEWAY=$(ip route 2>/dev/null | awk '$1=="default"{print $3; exit}')
  return 0
}

# How long to watch.
#
# Intermittent wireless faults are a function of time, not of effort: a card
# that drops once every forty minutes cannot be caught in three. The long
# options exist for exactly that, and for leaving a machine on soak overnight.
#
# The sampling interval opens up with the duration. Pinging every two seconds
# for a day would be 43,000 samples and a lot of needless traffic, while giving
# no better answer than one every half minute - the thing being measured is
# whether the link survives, not its microsecond behaviour.
pick_duration() {
  tui_menu "How long should the link be watched?" \
    "longer runs catch faults that only appear after a while" \
    "1 minute|a quick check that the link is alive" \
    "10 minutes|the usual bench test" \
    "30 minutes|catches most intermittent drops" \
    "1 hour|for a machine the customer says drops occasionally" \
    "5 hours|soak test - keep it on mains power" \
    "1 day|overnight soak - mains power, lid open" || return 1
  case "$TUI_CHOICE" in
    1) DURATION=60      ; SAMPLE_EVERY=2  ;;
    2) DURATION=600     ; SAMPLE_EVERY=2  ;;
    3) DURATION=1800    ; SAMPLE_EVERY=5  ;;
    4) DURATION=3600    ; SAMPLE_EVERY=5  ;;
    5) DURATION=18000   ; SAMPLE_EVERY=15 ;;
    6) DURATION=86400   ; SAMPLE_EVERY=30 ;;
  esac
  return 0
}

human_duration() {
  local s=$1 n unit
  if   [ "$s" -lt 60 ];    then n=$s;               unit=second
  elif [ "$s" -lt 3600 ];  then n=$(( s / 60 ));    unit=minute
  elif [ "$s" -lt 86400 ]; then n=$(( s / 3600 ));  unit=hour
  else                          n=$(( s / 86400 )); unit=day
  fi
  [ "$n" = 1 ] && printf '1 %s' "$unit" || printf '%d %ss' "$n" "$unit"
}

# ---------------------------------------------------------------- 3. stability
DROPS=0; ROAMS=0; PING_SENT=0; PING_LOST=0
RSSI_MIN=999; RSSI_MAX=-999; RSSI_SUM=0; RSSI_N=0
LAT_SUM=0; LAT_N=0; LAT_MAX=0; FIRST_BSSID=""

stability_run() {   # iface seconds
  local i=$1 secs=$2 t=0 rssi rate freq bssid p
  : > "$SAMPLES"
  local last_bssid; last_bssid=$(link_bssid "$i")
  FIRST_BSSID=$last_bssid
  ev INFO "watching $SSID on $i for $(human_duration "$secs"), sampling every ${SAMPLE_EVERY}s, gateway ${GATEWAY:-none}"

  while [ "$t" -lt "$secs" ]; do
    bssid=$(link_bssid "$i")
    if [ -z "$bssid" ]; then
      DROPS=$((DROPS+1))
      ev FAIL "link DOWN - the card lost the access point"
      # Wait for it to come back rather than abandoning the test: a link that
      # recovers on its own is a different fault from one that stays down.
      local w
      for w in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1; t=$((t+1))
        bssid=$(link_bssid "$i")
        [ -n "$bssid" ] && { ev INFO "link came back after ${w}s"; break; }
      done
      [ -z "$bssid" ] && { draw_stability "$i" "$t" "$secs" "" "" "" ; continue; }
    fi
    if [ -n "$last_bssid" ] && [ "$bssid" != "$last_bssid" ]; then
      ROAMS=$((ROAMS+1))
      ev WARN "roamed to a different access point ($last_bssid -> $bssid)"
    fi
    last_bssid=$bssid

    rssi=$(signal_dbm "$i"); rate=$(link_rate "$i"); freq=$(link_freq "$i")
    if [ -n "$rssi" ]; then
      RSSI_N=$((RSSI_N+1)); RSSI_SUM=$((RSSI_SUM + rssi))
      [ "$rssi" -lt "$RSSI_MIN" ] && RSSI_MIN=$rssi
      [ "$rssi" -gt "$RSSI_MAX" ] && RSSI_MAX=$rssi
    fi

    p=""
    if [ -n "$GATEWAY" ]; then
      PING_SENT=$((PING_SENT+1))
      p=$(ping -n -c1 -W2 "$GATEWAY" 2>/dev/null | awk -F'time=' '/time=/{print int($2); exit}')
      if [ -z "$p" ]; then
        PING_LOST=$((PING_LOST+1))
        ev WARN "no ping reply from the gateway"
      else
        LAT_N=$((LAT_N+1)); LAT_SUM=$((LAT_SUM + p))
        [ "$p" -gt "$LAT_MAX" ] && LAT_MAX=$p
      fi
    fi

    printf '%d\t%s\t%s\t%s\t%s\t%s\n' "$t" "${rssi:-}" "${rate:-}" "${freq:-}" "${bssid:-}" "${p:-}" >> "$SAMPLES"
    draw_stability "$i" "$t" "$secs" "$rssi" "$rate" "$p"
    sleep "$SAMPLE_EVERY"; t=$(( t + SAMPLE_EVERY ))
    tui_wait_abort 0 && { ev INFO "stopped by the operator"; ABORTED=1; break; }
  done
}

draw_stability() {
  local i=$1 t=$2 secs=$3 rssi=$4 rate=$5 p=$6
  tui_frame "Wireless - stability" "Q = stop"
  tui_line 6 "Watching the link and pinging the gateway. Walk away from the AP" muted
  tui_line 7 "and back to see how the signal follows." muted
  tui_kv 9  "Network"    "${SSID:-?}  $( [ -n "$(link_freq "$i")" ] && freq_band "$(link_freq "$i")" )"
  if [ -n "$rssi" ]; then
    tui_kv 10 "Signal now" "$rssi dBm  ($(rssi_verdict "$rssi"))" \
      "$( [ "$rssi" -ge -75 ] && echo ok || echo warn )"
  else
    tui_kv 10 "Signal now" "link is down" err
  fi
  tui_kv 11 "Link rate"  "${rate:-—} Mbit/s"
  [ "$RSSI_N" -gt 0 ] && tui_kv 12 "Signal range" "$RSSI_MAX to $RSSI_MIN dBm"
  if [ -n "$GATEWAY" ]; then
    tui_kv 13 "Gateway ping" "${p:-lost}  (avg $( [ "$LAT_N" -gt 0 ] && echo $((LAT_SUM/LAT_N)) || echo '—' ) ms, max ${LAT_MAX} ms)" \
      "$( [ -n "$p" ] && echo ok || echo err )"
    tui_kv 14 "Packets lost" "$PING_LOST of $PING_SENT"
  else
    tui_kv 13 "Gateway ping" "no gateway - ping test skipped" muted
  fi
  [ "$DROPS" -gt 0 ] && tui_kv 15 "Link drops" "$DROPS" err
  [ "$ROAMS" -gt 0 ] && tui_kv 16 "Roams" "$ROAMS" warn
  tui_bar 22 $(( t * 100 / (secs>0?secs:1) ))
  tui_flush
}

# ---------------------------------------------------------------- 4. internet
DNS_MS=""; HTTP_OK=0; HTTP_N=0; HTTP_AVG=""; DOWN_MBPS=""

internet_run() {
  tui_frame "Wireless - internet" "please wait"
  tui_line 8 "Checking DNS, reachability and throughput..." ""
  tui_flush

  # DNS: time a handful of lookups the way the netprobe page does.
  local t0 t1 n ok=0 sum=0
  for n in www.google.com cloudflare.com github.com; do
    t0=$(date +%s%N)
    if getent hosts "$n" >/dev/null 2>&1; then
      t1=$(date +%s%N); sum=$(( sum + (t1-t0)/1000000 )); ok=$((ok+1))
    fi
  done
  [ "$ok" -gt 0 ] && DNS_MS=$(( sum / ok ))
  ev INFO "DNS: $ok/3 lookups OK${DNS_MS:+, median ${DNS_MS} ms}"

  # HTTPS latency to a few endpoints.
  local url sum2=0
  for url in https://www.google.com/generate_204 https://1.1.1.1/cdn-cgi/trace https://github.com/; do
    HTTP_N=$((HTTP_N+1))
    t0=$(date +%s%N)
    if curl -s -o /dev/null --max-time 6 "$url" 2>/dev/null; then
      t1=$(date +%s%N); sum2=$(( sum2 + (t1-t0)/1000000 )); HTTP_OK=$((HTTP_OK+1))
    fi
  done
  [ "$HTTP_OK" -gt 0 ] && HTTP_AVG=$(( sum2 / HTTP_OK ))
  ev INFO "HTTPS: $HTTP_OK/$HTTP_N endpoints answered${HTTP_AVG:+, avg ${HTTP_AVG} ms}"

  # Throughput: one stream, indicative rather than a benchmark.
  if [ "$HTTP_OK" -gt 0 ]; then
    tui_line 10 "Measuring download speed..." muted; tui_flush
    local bytes=20000000 start end
    start=$(date +%s%N)
    local got
    got=$(curl -s -o /dev/null -w '%{size_download}' --max-time 15 \
          "https://speed.cloudflare.com/__down?bytes=$bytes" 2>/dev/null)
    end=$(date +%s%N)
    local ms=$(( (end-start)/1000000 ))
    if [ "${got:-0}" -gt 1000000 ] && [ "$ms" -gt 0 ]; then
      DOWN_MBPS=$(awk -v b="$got" -v m="$ms" 'BEGIN{printf "%.1f", b*8/(m/1000)/1000000}')
      ev INFO "download ${DOWN_MBPS} Mbit/s"
    fi
  fi
}

# ---------------------------------------------------------------- verdict
STATE=PASS; CAUSE=""; ACTION=""

decide() {
  local avg_rssi=""
  [ "$RSSI_N" -gt 0 ] && avg_rssi=$(( RSSI_SUM / RSSI_N ))
  local loss=0
  [ "$PING_SENT" -gt 0 ] && loss=$(( PING_LOST * 100 / PING_SENT ))

  if [ "$DROPS" -gt 0 ]; then
    STATE=FAIL
    CAUSE="The link dropped $DROPS time(s) while sitting still"
    ACTION="A link that drops without the machine moving is a hardware or driver fault, not coverage. Check both antenna leads are clipped onto the card, then try a different card. Note the signal range above: if it was strong when it dropped, coverage is not the explanation."
  elif [ "$RSSI_N" -eq 0 ]; then
    STATE=FAIL
    CAUSE="Never associated with a network"
    ACTION="The radio found access points but could not join one. Check the password, then the card."
  elif [ -n "$avg_rssi" ] && [ "$avg_rssi" -lt -80 ]; then
    STATE=FAIL
    CAUSE="Signal is very weak (average $avg_rssi dBm)"
    ACTION="At this level, next to an access point, suspect a disconnected or damaged antenna lead - the commonest fault after a screen or hinge repair. Open the lid hinge covers and check both U.FL connectors are seated on the card."
  elif [ "$loss" -gt 5 ]; then
    STATE=FAIL
    CAUSE="${loss}% of pings to the gateway were lost"
    ACTION="The link stayed up but is not carrying traffic reliably. Check antenna seating and interference on this channel; retest on a 5 GHz network if the current one is 2.4 GHz."
  elif [ -n "$avg_rssi" ] && [ "$avg_rssi" -lt -75 ]; then
    STATE=WARN
    CAUSE="Signal is weak (average $avg_rssi dBm)"
    ACTION="Usable but marginal. If the machine is near the access point, check the antenna leads before returning it."
  elif [ "$loss" -gt 0 ]; then
    STATE=WARN
    CAUSE="${loss}% packet loss to the gateway"
    ACTION="Occasional loss on wifi is normal in a busy area. Retest away from other networks if the customer reports drops."
  elif [ "$ROAMS" -gt 2 ]; then
    STATE=WARN
    CAUSE="Roamed between access points $ROAMS times"
    ACTION="Normal in a building with several APs, but worth noting if the customer complains about brief interruptions."
  else
    STATE=PASS
    CAUSE="Wireless link held steady"
    ACTION="Signal, link rate and ping were stable for the whole test with no drops."
  fi
}

write_report() {
  local i=$1
  local avg_rssi="" loss=0
  [ "$RSSI_N" -gt 0 ] && avg_rssi=$(( RSSI_SUM / RSSI_N ))
  [ "$PING_SENT" -gt 0 ] && loss=$(( PING_LOST * 100 / PING_SENT ))

  rsection "WIRELESS STABILITY TEST"
  rsilent "Adapter       : $i"
  rsilent "Chipset       : $(iface_chip "$i")"
  rsilent "Driver        : $(iface_driver "$i")"
  rsilent "Radio block   : $(rfkill_state)"
  rsilent "MAC           : $(cat "/sys/class/net/$i/address" 2>/dev/null)"
  rsilent ""
  rsilent "--- networks in range ---"
  rsilent "$(printf '  %-28s %8s  %-14s %s' SSID SIGNAL BAND SECURITY)"
  local rssi freq enc ssid shown=0
  while IFS=$'\t' read -r rssi freq enc ssid; do
    [ "$shown" -ge 15 ] && break
    rsilent "$(printf '  %-28.28s %5s dBm  %-14s %s' "$ssid" "$rssi" "$(freq_band "$freq")" "$enc")"
    shown=$((shown+1))
  done < "$SCAN_CACHE"
  rsilent "  ($(wc -l < "$SCAN_CACHE") access points heard in total)"

  if [ "$RSSI_N" -gt 0 ]; then
    rsilent ""
    rsilent "--- connected link ---"
    rsilent "$(printf '%-30s %s' "Network"            "$SSID")"
    rsilent "$(printf '%-30s %s' "Access point"       "$FIRST_BSSID")"
    rsilent "$(printf '%-30s %s' "Band"               "$(freq_band "$(link_freq "$i")")")"
    rsilent "$(printf '%-30s %s' "IP address"         "${IPADDR:-none}")"
    rsilent "$(printf '%-30s %s' "Gateway"            "${GATEWAY:-none}")"
    rsilent ""
    rsilent "--- stability over $(human_duration $(( RSSI_N * SAMPLE_EVERY ))) ---"
    rsilent "$(printf '%-30s %s' "Signal average"     "$avg_rssi dBm  ($(rssi_verdict "$avg_rssi"))")"
    rsilent "$(printf '%-30s %s' "Signal best / worst" "$RSSI_MAX / $RSSI_MIN dBm")"
    rsilent "$(printf '%-30s %s' "Link drops"         "$DROPS")"
    rsilent "$(printf '%-30s %s' "Roams between APs"  "$ROAMS")"
    if [ "$PING_SENT" -gt 0 ]; then
      rsilent "$(printf '%-30s %s' "Gateway pings"    "$PING_SENT sent, $PING_LOST lost (${loss}%)")"
      [ "$LAT_N" -gt 0 ] && \
      rsilent "$(printf '%-30s %s' "Gateway latency"  "avg $((LAT_SUM/LAT_N)) ms, worst $LAT_MAX ms")"
    fi
    rsilent ""
    rsilent "--- signal trace (seconds : dBm : Mbit/s : ping ms) ---"
    local rows every
    rows=$(wc -l < "$SAMPLES" 2>/dev/null || echo 0)
    every=$(( rows / 40 )); [ "$every" -lt 1 ] && every=1
    awk -F'\t' -v n="$every" 'NR % n == 1 || n == 1 {
        printf "  %4ds   %5s dBm   %7s   %s\n", $1, ($2==""?"--":$2), ($3==""?"--":$3), ($6==""?"lost":$6" ms") }' \
        "$SAMPLES" >> "$REPORT_TXT"
  fi

  if [ "$HTTP_N" -gt 0 ]; then
    rsilent ""
    rsilent "--- internet ---"
    rsilent "$(printf '%-30s %s' "DNS lookups"     "${DNS_MS:+avg ${DNS_MS} ms}${DNS_MS:-all failed}")"
    rsilent "$(printf '%-30s %s' "HTTPS endpoints" "$HTTP_OK of $HTTP_N answered${HTTP_AVG:+, avg ${HTTP_AVG} ms}")"
    rsilent "$(printf '%-30s %s' "Download"        "${DOWN_MBPS:-not measured}${DOWN_MBPS:+ Mbit/s}")"
  fi

  rsilent ""
  rsilent "--- timeline ---"
  if [ -s "$EVENTS" ]; then
    awk -F'\t' '{printf "  %-10s %-5s %s\n", $1, ($2=="INFO"?"":$2), $3}' "$EVENTS" >> "$REPORT_TXT"
  else
    rsilent "  (nothing notable happened)"
  fi

  rsilent ""
  rsilent "--- CAUSE ---"
  rsilent "$CAUSE"
  rsilent ""
  printf '%s\n' "$ACTION" | fold -s -w 76 | sed 's/^/  /' >> "$REPORT_TXT"
  rsilent ""
  case "$STATE" in
    PASS) rsilent "RESULT: PASS -- $CAUSE" ;;
    WARN) rsilent "RESULT: MARGINAL -- $CAUSE" ;;
    *)    rsilent "RESULT: FAIL -- $CAUSE" ;;
  esac
  set_kv WIFI_RESULT "$STATE ($CAUSE)"
  return 0
}

show_verdict() {
  local avg_rssi=""; [ "$RSSI_N" -gt 0 ] && avg_rssi=$(( RSSI_SUM / RSSI_N ))
  tui_frame "Wireless test finished" "Enter to go back"
  case "$STATE" in
    PASS) tui_badge 6 PASS "the link held steady" ;;
    WARN) tui_badge 6 MARGINAL "it worked, but not cleanly" ;;
    *)    tui_badge 6 FAIL "the wireless link is not reliable" ;;
  esac
  tui_line 8 "$CAUSE" "$( [ "$STATE" = PASS ] && echo ok || echo err )"
  local row=10
  [ -n "$avg_rssi" ] && { tui_kv $row "Signal average" "$avg_rssi dBm ($(rssi_verdict "$avg_rssi"))"; row=$((row+1)); }
  [ "$PING_SENT" -gt 0 ] && { tui_kv $row "Packets lost" "$PING_LOST of $PING_SENT"; row=$((row+1)); }
  tui_kv $row "Link drops" "$DROPS"; row=$((row+2))
  local l
  while IFS= read -r l; do
    [ $row -gt 21 ] && break
    tui_line $row "$l" ""; row=$((row+1))
  done < <(printf '%s\n' "$ACTION" | fold -s -w 72)
  tui_flush
  tui_anykey
}

cleanup() {
  # Only tear down what this test set up; a link the operator was already using
  # should still be there when the test ends.
  [ "$OWNED_IFACE" = 1 ] || return 0
  pkill -x wpa_supplicant 2>/dev/null
  rm -f "$WPA_CONF"
}

# ---------------------------------------------------------------- main
main() {
  need_root
  : > "$EVENTS"
  # Nudge the stack awake. Which of these exist depends on the card; the ones
  # that do not simply fail, which is fine.
  local m
  for m in cfg80211 mac80211 iwlwifi iwlmvm rtw88_core rtw89_core ath10k_pci ath11k_pci; do
    modprobe "$m" 2>/dev/null
  done
  sleep 1

  mapfile -t IFACES < <(wifi_ifaces)
  if [ "${#IFACES[@]}" -eq 0 ]; then
    local chip; chip=$(lspci 2>/dev/null | grep -i 'network controller' | head -1 | sed 's/^[0-9a-f:.]* //')
    rsection "WIRELESS STABILITY TEST"
    if [ -n "$chip" ]; then
      rsilent "Card detected : $chip"
      rsilent "RESULT: NOT TESTED -- the card is present but no driver claimed it"
      set_kv WIFI_RESULT "NOT TESTED (no driver bound)"
      tui_frame "Wireless" "Enter to go back"
      tui_badge 6 UNKNOWN "card found, but no driver"
      tui_line 9  "$chip" ""
      tui_line 11 "The card is on the bus but the kernel has not bound a driver," muted
      tui_line 12 "which usually means its firmware is missing. Try Get firmware." muted
    else
      rsilent "RESULT: NOT TESTED -- no wireless card found on this machine"
      set_kv WIFI_RESULT "NOT TESTED (no card)"
      tui_frame "Wireless" "Enter to go back"
      tui_badge 6 UNKNOWN "no wireless card detected"
      tui_line 9 "Nothing on the PCI or USB bus identifies itself as a wifi card." muted
      tui_line 10 "On a laptop that should have one, check the card is seated." muted
    fi
    tui_flush; tui_anykey
    return
  fi

  local IFACE=${IFACES[0]}
  if [ "${#IFACES[@]}" -gt 1 ]; then
    local -a labels=()
    local n
    for n in "${IFACES[@]}"; do labels+=("$(printf '%-10s %s' "$n" "$(iface_chip "$n")")"); done
    tui_menu "Which wireless adapter?" "arrows + Enter" "${labels[@]}" || return
    IFACE=${IFACES[$((TUI_CHOICE-1))]}
  fi

  local block; block=$(rfkill_state)
  if [ "$block" = "hard blocked" ]; then
    tui_msg "Wireless is switched off" \
      "The radio is hard-blocked - a physical switch or key combination," \
      "or a setting in the BIOS." "" \
      "Turn it on and run this test again."
    rsection "WIRELESS STABILITY TEST"
    rsilent "RESULT: NOT TESTED -- the radio is hard-blocked (switch or BIOS)"
    set_kv WIFI_RESULT "NOT TESTED (radio hard-blocked)"
    return
  fi
  [ "$block" = "soft blocked" ] && { rfkill unblock wifi 2>/dev/null; ev INFO "radio was soft-blocked, unblocked it"; }

  tui_frame "Wireless adapter" "Enter to scan"
  tui_kv 6  "Adapter"  "$IFACE"
  tui_kv 7  "Chipset"  "$(iface_chip "$IFACE")"
  tui_kv 8  "Driver"   "$(iface_driver "$IFACE")"
  tui_kv 9  "MAC"      "$(cat "/sys/class/net/$IFACE/address" 2>/dev/null)"
  tui_kv 10 "Radio"    "$block" "$( [ "$block" = "not blocked" ] && echo ok || echo warn )"
  tui_line 12 "Next: scan for access points. That alone proves the radio and" muted
  tui_line 13 "both antennas work, and needs no password." muted
  tui_flush
  tui_anykey

  scan_screen "$IFACE" || { write_report "$IFACE"; return; }

  ABORTED=0
  if ! require_link; then
    no_link_screen
    decide
    STATE=PART
    CAUSE="Not connected - only the scan was done"
    ACTION="The radio and antennas are proven by the scan above. Connect with the Wi-Fi option on the main menu, then run this test again to watch the link over time."
    write_report "$IFACE"
    show_verdict
    return
  fi

  if pick_duration; then
    local warn_line=""
    [ "$DURATION" -ge 18000 ] && warn_line="Keep the machine on mains power - this outlasts any battery."
    tui_confirm "Stability watch" yes \
      "Using the existing connection to $SSID (${IPADDR:-no address})." \
      "" \
      "Watching the link for $(human_duration "$DURATION"): signal, link rate," \
      "roaming, and a ping to the gateway every ${SAMPLE_EVERY} seconds." \
      "" \
      "Walk the machine away from the access point and back if you want to" \
      "see how the signal follows. Q stops it early and still reports." \
      "$warn_line" \
      "" "Start?" && stability_run "$IFACE" "$DURATION"
    internet_run
  fi

  decide
  [ "$ABORTED" = 1 ] && [ "$STATE" = PASS ] && {
    STATE=WARN; CAUSE="Stopped early by the operator"
    ACTION="Only $(human_duration $(( RSSI_N * SAMPLE_EVERY ))) was watched. Intermittent drops need the full run to show up."
  }
  write_report "$IFACE"
  cleanup
  show_verdict
}

main "$@"
