#!/bin/bash
# Connect this machine to a wireless network.
#
# Separate from the wireless *test* on purpose. Getting online is something you
# do once when the machine arrives on the bench - so that Get firmware can
# fetch drivers, and so the wireless test has a link to watch - and it should
# not have to be repeated inside every test that happens to need the network.
#
# The link this sets up stays up for the rest of the session. Everything else
# in the toolkit checks for it rather than building its own.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

# This page is what the header's Wi-Fi icon opens; clicking the icon while
# already here must not open a second copy inside it.
export DIAG_IN_WIFI=1

WPA_CONF=$RUN_DIR/wpa.conf
WPA_LOG=$RUN_DIR/wpa.log
SCAN_CACHE=$RUN_DIR/wifi_scan
STATE_FILE=$RUN_DIR/wifi.state      # iface<TAB>ssid, written once connected

# ---------------------------------------------------------------- shared
# These are used by wifitest.sh and getfirmware.sh too, which is the point:
# one definition of "are we online", not three that disagree.

wifi_ifaces() {
  local d
  for d in /sys/class/net/*; do
    [ -d "$d/wireless" ] || [ -L "$d/phy80211" ] || continue
    printf '%s\n' "${d##*/}"
  done
}

wifi_link_ssid() {   # iface -> SSID when associated, empty otherwise
  iw dev "$1" link 2>/dev/null | awk '/^\tSSID: /{print substr($0,8); exit}'
}

wifi_connected_iface() {
  local i
  for i in $(wifi_ifaces); do
    [ -n "$(wifi_link_ssid "$i")" ] || continue
    # Associated is not the same as usable: without an address nothing routes.
    ip -4 addr show "$i" 2>/dev/null | grep -q 'inet ' || continue
    printf '%s\n' "$i"; return 0
  done
  return 1
}

# Any working route, wired or wireless. Get firmware only cares about this.
net_is_up() {
  ip route 2>/dev/null | grep -q '^default' || return 1
  return 0
}

rfkill_state() {
  command -v rfkill >/dev/null || { printf 'unknown'; return; }
  local out; out=$(rfkill list 2>/dev/null | grep -A2 -i 'wlan\|wireless' | head -3)
  case "$out" in
    *"Hard blocked: yes"*) printf 'hard blocked' ;;
    *"Soft blocked: yes"*) printf 'soft blocked' ;;
    *) printf 'not blocked' ;;
  esac
}

freq_band() {
  local f=$1 ch=""
  case "$f" in
    24[0-9][0-9]|2[45][0-9][0-9]) ch=$(( (f - 2407) / 5 )); printf '2.4 GHz ch %s' "$ch" ;;
    5[0-9][0-9][0-9]) ch=$(( (f - 5000) / 5 )); printf '5 GHz ch %s' "$ch" ;;
    6[0-9][0-9][0-9]|7[0-9][0-9][0-9]) ch=$(( (f - 5950) / 5 )); printf '6 GHz ch %s' "$ch" ;;
    *) printf '%s MHz' "$f" ;;
  esac
}

wifi_scan_to_cache() {   # iface
  wifi_scan_tsv "$1" "$SCAN_CACHE"
}

wifi_scan_progress() {   # attempt last-error
  tui_frame "Wi-Fi" "scanning"
  tui_line 8 "Looking for networks...  (attempt $1 of 3)" muted
  [ -n "$2" ] && tui_line 10 "Last try: $(wifi_scan_explain)" warn
  tui_flush
}

# ---------------------------------------------------------------- connecting
JOIN_NAME=""
wifi_join_progress() {   # called by wifi_join in lib.sh
  tui_frame "Wi-Fi" "connecting"
  tui_line 8  "Connecting to $JOIN_NAME" ""
  tui_line 10 "$1" muted
  tui_flush
}

do_connect() {   # iface ssid(as scanned) enc
  local i=$1 ssid=$2 enc=$3 pass=""
  JOIN_NAME=$(wifi_ssid_show "$ssid")

  case "$enc" in
    open|OWE) ;;
    Enterprise)
      tui_msg "Company network" "$JOIN_NAME uses 802.1X sign-in (username and certificate)." "" \
        "The toolkit only joins password networks. Pick another one, or use a cable."
      return 1 ;;
    *)
      tui_input "Wi-Fi password" "Password for $JOIN_NAME (blank to cancel):"
      [ -z "$TUI_TEXT" ] && return 1
      pass=$TUI_TEXT; TUI_TEXT="" ;;
  esac

  wifi_join_progress "starting..."
  if ! wifi_join "$i" "$ssid" "$enc" "$pass"; then
    # A half-made link (joined, no address) would make this page and the
    # wireless test believe the machine is online.
    wifi_leave "$i"
    tui_msg "Could not connect" "Joining $JOIN_NAME failed:" "" "$WIFI_JOIN_ERR." "" \
      "Every step is in the Toolkit log on the power menu (Q on the home screen)."
    return 1
  fi
  printf '%s\t%s\n' "$i" "$JOIN_NAME" > "$STATE_FILE"
  return 0
}

# Signal in words as well as dBm - a technician reads "weak" faster than -78.
signal_words() {
  local r=$1
  if   [ "$r" -ge -55 ]; then printf 'excellent'
  elif [ "$r" -ge -67 ]; then printf 'good'
  elif [ "$r" -ge -75 ]; then printf 'fair'
  else printf 'weak'
  fi
}

# ---------------------------------------------------------------- screens
status_screen() {
  local i=$1 ssid ip4 gw sig
  ssid=$(wifi_ssid_show "$(wifi_link_ssid "$i")")
  ip4=$(ip -4 addr show "$i" 2>/dev/null | awk '/inet /{print $2; exit}')
  gw=$(ip route 2>/dev/null | awk '$1=="default"{print $3; exit}')
  sig=$(iw dev "$i" link 2>/dev/null | awk '/signal:/{print $2; exit}')

  tui_frame "Wi-Fi" "Enter to go back"
  tui_badge 6 OK "connected"
  tui_kv 9  "Network"   "$ssid"
  tui_kv 10 "Address"   "${ip4:-none}"
  tui_kv 11 "Gateway"   "${gw:-none}"
  [ -n "$sig" ] && tui_kv 12 "Signal" "$sig dBm"
  tui_kv 13 "Adapter"   "$i"
  tui_line 15 "Get firmware can now download drivers, and the wireless test" muted
  tui_line 16 "will watch this link instead of asking you to connect again." muted
  tui_flush
  tui_anykey
}

pick_and_connect() {   # iface
  local i=$1
  tui_frame "Wi-Fi" "scanning"
  tui_line 8 "Looking for networks..." muted
  tui_flush
  if ! wifi_scan_to_cache "$i"; then
    tui_msg "No networks found" \
      "$(wifi_scan_explain)" "" \
      "Adapter: $i" \
      "Reported: ${WIFI_SCAN_ERR:-nothing}" "" \
      "Full detail is in the Toolkit log on the power menu."
    return 1
  fi

  # One "|" field per column; the renderer lines each column up across rows.
  # Padding with spaces never did - the font is proportional, which is why the
  # dBm column wandered from row to row.
  local -a ssids=() encs=() labels=()
  local rssi freq enc ssid
  while IFS=$'\t' read -r rssi freq enc ssid; do
    [ "$ssid" = "(hidden)" ] && continue
    ssids+=("$ssid"); encs+=("$enc")
    labels+=("$(wifi_ssid_show "$ssid")|$rssi dBm  $(signal_words "$rssi")|$(freq_band "$freq")|$enc")
    [ ${#ssids[@]} -ge 30 ] && break     # strongest 30 - the list is sorted by signal
  done < "$SCAN_CACHE"
  [ ${#ssids[@]} -eq 0 ] && { tui_msg "Nothing to join" "Only hidden networks were found."; return 1; }

  tui_menu "Choose a network" "arrows + Enter to join, Q to go back" "${labels[@]}" || return 1
  do_connect "$i" "${ssids[$((TUI_CHOICE-1))]}" "${encs[$((TUI_CHOICE-1))]}"
}

disconnect_now() {   # iface
  wifi_leave "$1"
  ip link set "$1" down 2>/dev/null
  rm -f "$STATE_FILE" "$WPA_CONF"
  tui_msg "Disconnected" "The wireless link has been taken down."
}

# ---------------------------------------------------------------- main
main() {
  need_root
  local m
  for m in cfg80211 mac80211 iwlwifi iwlmvm rtw88_core rtw89_core ath10k_pci ath11k_pci; do
    modprobe "$m" 2>/dev/null
  done
  sleep 1

  mapfile -t IFACES < <(wifi_ifaces)
  if [ "${#IFACES[@]}" -eq 0 ]; then
    local chip; chip=$(lspci 2>/dev/null | grep -i 'network controller' | head -1 | sed 's/^[0-9a-f:.]* //')
    tui_frame "Wi-Fi" "Enter to go back"
    tui_badge 6 UNKNOWN "no wireless adapter"
    if [ -n "$chip" ]; then
      tui_line 9  "$chip" ""
      tui_line 11 "The card is on the bus but no driver claimed it - usually a" muted
      tui_line 12 "missing firmware blob. Plug in a network cable and run Get" muted
      tui_line 13 "firmware, which can fetch it." muted
    else
      tui_line 9  "Nothing identifies itself as a wifi card on this machine." muted
      tui_line 10 "Check the card is seated." muted
    fi
    tui_flush; tui_anykey
    return
  fi

  local IFACE=${IFACES[0]}
  if [ "${#IFACES[@]}" -gt 1 ]; then
    local -a labels=() n
    for n in "${IFACES[@]}"; do labels+=("$n"); done
    tui_menu "Which wireless adapter?" "arrows + Enter" "${labels[@]}" || return
    IFACE=${IFACES[$((TUI_CHOICE-1))]}
  fi

  local block; block=$(rfkill_state)
  if [ "$block" = "hard blocked" ]; then
    tui_msg "Wireless is switched off" \
      "The radio is hard-blocked by a switch, a key combination or the BIOS." \
      "" "Turn it on and try again."
    return
  fi
  [ "$block" = "soft blocked" ] && rfkill unblock wifi 2>/dev/null

  while :; do
    local cur; cur=$(wifi_ssid_show "$(wifi_link_ssid "$IFACE")")
    if [ -n "$cur" ]; then
      tui_menu "Wi-Fi - connected to $cur" "arrows + Enter, Q to go back" \
        "Connection details|address, gateway, signal" \
        "Join a different network|scan and reconnect" \
        "Disconnect|take the link down" || return
      case "$TUI_CHOICE" in
        1) status_screen "$IFACE" ;;
        2) pick_and_connect "$IFACE" && status_screen "$IFACE" ;;
        3) disconnect_now "$IFACE"; return ;;
      esac
    else
      pick_and_connect "$IFACE" || return
      status_screen "$IFACE"
    fi
  done
}

main "$@"
