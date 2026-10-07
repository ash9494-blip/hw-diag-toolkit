#!/bin/bash
# Ethernet test: link, negotiated speed, DHCP, then traffic - all of it sent
# out of the cable port itself (see netcheck.sh), so a Wi-Fi link joined
# from the home screen can no longer carry the test for a dead port.
#
# What a wired fault looks like on the bench, and where this test sees it:
#   no link at all            the cable, the socket, or the chip
#   100 Mbit/s on gigabit     a broken pair: gigabit needs all 8 wires, 100
#                             Mbit/s only 4 - a bent pin or a cut cable
#   errors while downloading  CRC / frame errors on the wire: cable, socket,
#                             the magnetics behind it, or the chip
#   lost pings to the router  the same, or a bad switch port
# Faults on the network side (no DHCP server, a dead DNS server, a login
# page) are named as the network's, not the laptop's.
. /opt/diag/lib.sh
. /opt/diag/tui.sh
. /opt/diag/netcheck.sh

load_net_modules() {
  local d
  for d in /sys/bus/pci/devices/*; do
    [ -r "$d/class" ] || continue
    case "$(cat "$d/class")" in 0x0200*) ;; *) continue ;; esac
    [ -e "$d/driver" ] && continue
    modprobe "$(cat "$d/modalias" 2>/dev/null)" 2>/dev/null
  done
  modprobe r8169 2>/dev/null; modprobe e1000e 2>/dev/null
  modprobe igb 2>/dev/null;   modprobe atlantic 2>/dev/null
  sleep 1
}

wired_ifaces() {
  local i n
  for i in /sys/class/net/*; do
    n=${i##*/}
    case "$n" in lo|dummy*|bond*|veth*|docker*) continue ;; esac
    [ -d "$i/wireless" ] && continue
    [ -e "$i/phy80211" ] && continue
    [ -e "$i/device" ] || continue
    printf '%s\n' "$n"
  done
}

wifi_ifaces() {
  local i n
  for i in /sys/class/net/*; do
    n=${i##*/}
    { [ -d "$i/wireless" ] || [ -e "$i/phy80211" ]; } && printf '%s\n' "$n"
  done
}

wifi_hardware() {
  lspci 2>/dev/null | grep -iE 'network controller|wireless' | sed 's/^[0-9a-f:.]* //'
}

# "Ethernet controller: Intel Corporation 82574L Gigabit Network Connection"
# is mostly boilerplate; the part that identifies the chip is what fits on screen.
nic_name() {
  lspci 2>/dev/null | grep -i 'ethernet controller' | head -1 \
    | sed -e 's/^[0-9a-f:.]* //' -e 's/^Ethernet controller: //' \
          -e 's/ Corporation//' -e 's/ Semiconductor Co., Ltd\.//'
}

# Can this port, and the switch at the other end, do gigabit? ethtool lists
# both: ours under "Supported link modes", theirs under "Link partner
# advertised link modes" (not every driver reports the partner).
modes_1000() {   # iface ours|partner -> 0 when 1000baseT is listed
  local sect="Supported link modes"; [ "$2" = partner ] && sect="Link partner advertised link modes"
  ethtool "$1" 2>/dev/null | awk -v s="$sect" '
    index($0, s ":") { on = 1 }
    on && /:/ && !index($0, s ":") { on = 0 }
    on && /1000baseT/ { f = 1 }
    END { exit !f }'
}
partner_known() { ethtool "$1" 2>/dev/null | grep -q 'Link partner advertised link modes'; }

# The wire's error counters: a cable, socket or chip fault shows up as CRC
# and frame errors once traffic flows.
wire_errors() {   # iface -> total of the receive/transmit error counters
  local s=/sys/class/net/$1/statistics f t=0 v
  for f in rx_errors rx_crc_errors rx_frame_errors rx_length_errors tx_errors tx_carrier_errors; do
    v=$(cat "$s/$f" 2>/dev/null); case "$v" in ''|*[!0-9]*) v=0 ;; esac
    t=$((t + v))
  done
  echo "$t"
}
wire_detail() {   # iface -> "crc_errors: 3, frame_errors: 1" (non-zero counters only)
  local s=/sys/class/net/$1/statistics f v out=""
  for f in rx_crc_errors rx_frame_errors rx_length_errors rx_missed_errors tx_carrier_errors collisions; do
    v=$(cat "$s/$f" 2>/dev/null)
    [ -n "$v" ] && [ "$v" != 0 ] && out+="${f#rx_}: $v, "
  done
  printf '%s' "${out%, }"
}

# ---------------------------------------------------------------- collect
tui_frame "Ethernet network test" "please wait"
tui_line 6 "Looking for network hardware..." muted
tui_flush
load_net_modules

mapfile -t WIRED < <(wired_ifaces)
mapfile -t WIFI  < <(wifi_ifaces)
WIFI_HW=$(wifi_hardware)
NIC=$(nic_name)

IFACE=""; LINK=no; SPEED=""; DUPLEX=""; MAC=""
for w in "${WIRED[@]}"; do
  ip link set "$w" up 2>/dev/null
done
[ "${#WIRED[@]}" -gt 0 ] && sleep 2

for w in "${WIRED[@]}"; do
  c=$(cat "/sys/class/net/$w/carrier" 2>/dev/null)
  if [ "$c" = 1 ]; then IFACE=$w; LINK=yes; break; fi
done
[ -z "$IFACE" ] && [ "${#WIRED[@]}" -gt 0 ] && IFACE=${WIRED[0]}

read_link() {
  MAC=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null)
  SPEED=$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null)
  DUPLEX=$(cat "/sys/class/net/$IFACE/duplex" 2>/dev/null)
  case "$SPEED" in ''|-1) SPEED=$(ethtool "$IFACE" 2>/dev/null | awk '/Speed:/{print $2}' | tr -dc '0-9') ;; esac
}
[ -n "$IFACE" ] && read_link

# ---------------------------------------------------------------- live screen
ROWS=()    # "label|value|tone" for each check done so far
show() {   # subtitle [line...]
  tui_frame "Ethernet network test" "$1"
  local row=6 r lab val tone
  tui_kv $row "Ethernet adapter" "${NIC:-${IFACE:-none found}}"; row=$((row+1))
  tui_kv $row "Interface" "${IFACE:-none}"; row=$((row+1))
  [ -n "$MAC" ] && { tui_kv $row "MAC address" "$MAC"; row=$((row+1)); }
  if [ "$LINK" = yes ]; then
    tui_kv $row "Cable" "connected" ok
  else
    tui_kv $row "Cable" "no link" warn
  fi
  row=$((row+1))
  if [ -n "$SPEED" ] && [ "$SPEED" != 0 ]; then
    tui_kv $row "Negotiated" "${SPEED} Mbps ${DUPLEX:-}" \
      "$([ "$SPEED" -ge 1000 ] 2>/dev/null && echo ok || echo warn)"
    row=$((row+1))
  fi
  row=$((row+1))
  local i=0 l
  for l in "$@"; do
    i=$((i+1)); [ $i -eq 1 ] && continue
    tui_line $row "$l" ""; row=$((row+1))
  done
  for r in "${ROWS[@]}"; do
    IFS='|' read -r lab val tone <<< "$r"
    tui_kv $row "$lab" "$val" "$tone"; row=$((row+1))
  done
  tui_flush
}
add_row() { ROWS+=("$1|$2|$3"); }

if [ "${#WIRED[@]}" -eq 0 ]; then
  show "no ethernet hardware" "This machine has no wired network adapter the kernel can see."
  sleep 1
elif [ "$LINK" != yes ]; then
  show "plug a cable in" "Plug a live network cable into the ethernet port." \
       "Waiting up to 30 seconds..."
  tui_anim_live ether 0 0
  for i in $(seq 1 30); do
    for w in "${WIRED[@]}"; do
      if [ "$(cat "/sys/class/net/$w/carrier" 2>/dev/null)" = 1 ]; then
        IFACE=$w; LINK=yes; break 2
      fi
    done
    tui_line 14 "$(printf 'still waiting... %ds' $((30 - i)))" muted
    tui_flush
    tui_wait_abort 1 && break
  done
  if [ "$LINK" = yes ]; then
    sleep 2
    read_link
  fi
fi

IP=""; GW=""; DHCP=no; DHCP_WHY=""; HW_CAUSE=""; HW_ACTION=""; ERR0=0; ERR1=0; ERRS=0
LEASE=/var/lib/dhcp/dhclient.$IFACE.leases
if [ "$LINK" = yes ]; then
  show "asking for an address" "Link is up. Requesting an address by DHCP..."
  tui_anim_live ether 2 2
  ip addr flush dev "$IFACE" 2>/dev/null
  mkdir -p /var/lib/dhcp; rm -f "$LEASE"
  timeout 25 dhclient -1 -v -pf "/run/dhclient.$IFACE.pid" -lf "$LEASE" "$IFACE" >"$RUN_DIR/dhcp.log" 2>&1
  IP=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | head -1)
  GW=$(ip route show default dev "$IFACE" 2>/dev/null | awk '{print $3}' | head -1)
  [ -z "$GW" ] && GW=$(nc_lease "$LEASE" routers)
  if [ -n "$IP" ]; then
    DHCP=yes
    nc_route "$IFACE" "$GW"
  else
    DHCP_WHY=$(_wifi_dhcp_explain "$RUN_DIR/dhcp.log")
  fi

  if [ -n "$IP" ]; then
    set -- "testing the connection" "Address $IP" "Testing the gateway, the internet and DNS through the cable..."
    show "$@"
    tui_anim_live ether 3 3
    ERR0=$(wire_errors "$IFACE")
    nc_gateway "$IFACE" "$GW"
    add_row "Gateway" "${GW:-none}  $(nc_gateway_text)" \
      "$(case "$NC_GW_STATE" in ok) echo ok ;; lost|none) echo err ;; *) echo warn ;; esac)"
    show "$@"
    nc_internet "$IFACE"
    add_row "Internet" "ping $NC_ICMP, web $NC_TCP" "$( [ "$NC_TCP" = yes ] && echo ok || echo err )"
    show "$@"
    nc_dns "$IFACE" "$LEASE"
    add_row "DNS" "network's $(nc_dns_text net), 1.1.1.1 $(nc_dns_text direct)" \
      "$( [ "$NC_DNS_NET" = ok ] && echo ok || echo warn )"
    show "$@"
    nc_portal "$IFACE"; nc_https "$IFACE"
    add_row "Secure web" "$( [ "$NC_HTTPS" = yes ] && echo works || echo fails )$( [ "$NC_PORTAL" = yes ] && echo " - a login page is in the way" )" \
      "$( [ "$NC_HTTPS" = yes ] && [ "$NC_PORTAL" != yes ] && echo ok || echo warn )"
    show "$@" "Downloading for up to 15 s - traffic for the error counters..."
    [ "$NC_TCP" = yes ] && nc_download "$IFACE" 50000000
    ERR1=$(wire_errors "$IFACE"); ERRS=$((ERR1 - ERR0))
    add_row "Wire errors" "$ERRS during the test$( [ "$ERRS" -gt 0 ] && echo " ($(wire_detail "$IFACE"))" )" \
      "$( [ "$ERRS" = 0 ] && echo ok || echo err )"
    [ -n "$NC_DOWN_MBPS" ] && add_row "Download" "$NC_DOWN_MBPS Mbit/s" ""
    nc_clock
    nc_cause cable
  fi

  # What the cable itself says comes before anything the network says.
  if [ "$ERRS" -gt 0 ]; then
    HW_CAUSE="$ERRS error(s) on the wire while traffic flowed ($(wire_detail "$IFACE"))"
    HW_ACTION="Errors on the wire are the cable, the port's socket, or the network chip. Swap the cable first, then the switch port; if the errors follow the laptop, the fault is in it."
  elif [ "${SPEED:-0}" -gt 0 ] 2>/dev/null && [ "$SPEED" -lt 1000 ] && modes_1000 "$IFACE" ours; then
    if partner_known "$IFACE" && modes_1000 "$IFACE" partner; then
      HW_CAUSE="linked at $SPEED Mbit/s although both ends can do 1000"
      HW_ACTION="Gigabit needs all 8 wires, $SPEED Mbit/s only 4: a broken pair - a cut or kinked cable, or a bent pin in the laptop's socket. Try a known-good cable; if it still links at $SPEED, check the socket."
    else
      HW_CAUSE="linked at $SPEED Mbit/s (this port can do 1000)"
      HW_ACTION="The switch port may only do $SPEED Mbit/s - or the cable has a broken pair. Try a gigabit switch port and a known-good cable."
    fi
  elif [ "$DUPLEX" = half ]; then
    HW_CAUSE="linked at half duplex"
    HW_ACTION="Half duplex on a modern network is a cable or switch-port fault. Swap both."
  fi
fi

# ---------------------------------------------------------------- verdict
CAUSE=""; ACTION=""
if [ "${#WIRED[@]}" -eq 0 ]; then
  STATE=UNKNOWN; VERDICT="NOT TESTED (no wired adapter on this machine)"
elif [ "$LINK" != yes ]; then
  STATE=PART;    VERDICT="NOT TESTED (no cable was connected)"
elif [ "$DHCP" != yes ]; then
  STATE=FAIL;    VERDICT="FAIL (link is up but DHCP gave no address: $DHCP_WHY)"
  CAUSE="no address - $DHCP_WHY"
  ACTION="The link is up, so the cable and port carry a signal. Try a socket that works for another laptop; if this one still gets no address there, suspect the port or the chip."
elif [ "$NC_STATE" = FAIL ]; then
  STATE=FAIL;    VERDICT="FAIL ($NC_CAUSE)"; CAUSE=$NC_CAUSE; ACTION=$NC_ACTION
elif [ -n "$HW_CAUSE" ]; then
  STATE=WARN;    VERDICT="MARGINAL ($HW_CAUSE)"; CAUSE=$HW_CAUSE; ACTION=$HW_ACTION
elif [ "$NC_STATE" = WARN ] && [ "$NC_SIDE" = laptop ]; then
  STATE=WARN;    VERDICT="MARGINAL ($NC_CAUSE)"; CAUSE=$NC_CAUSE; ACTION=$NC_ACTION
elif [ "$NC_STATE" = WARN ]; then
  # The port carried traffic to the router and back: the laptop's part is
  # proven, whatever the network does past that.
  STATE=PASS;    VERDICT="PASS (${SPEED:-?} Mbps, port works - network problem: $NC_CAUSE)"
  CAUSE="the port works; the network has a problem: $NC_CAUSE"; ACTION=$NC_ACTION
else
  STATE=PASS;    VERDICT="PASS (${SPEED:-?} Mbps, $IP, $NC_CAUSE)"
  CAUSE=$NC_CAUSE
fi

# ---------------------------------------------------------------- report
rsection "ETHERNET NETWORK TEST"
rsilent "Ethernet adapter    : ${NIC:-none found}"
rsilent "Wired interfaces    : ${WIRED[*]:-none}"
rsilent "Interface tested    : ${IFACE:-none}"
[ -n "$MAC" ] && rsilent "MAC address         : $MAC"
rsilent "Cable link          : $LINK"
if [ -n "$SPEED" ] && [ "$LINK" = yes ]; then
  rsilent "Negotiated speed    : ${SPEED} Mbps ${DUPLEX}$(modes_1000 "$IFACE" ours && echo "   (this port can do 1000)")"
  partner_known "$IFACE" && \
    rsilent "Switch end offers   : $(modes_1000 "$IFACE" partner && echo "1000 Mbps" || echo "100 Mbps or less")"
fi
rsilent "DHCP address        : ${IP:-none}${DHCP_WHY:+  ($DHCP_WHY)}"
rsilent "Default gateway     : ${GW:-none}"
if [ "$DHCP" = yes ]; then
  rsilent "Wire errors         : $ERRS during the test$( [ "$ERRS" -gt 0 ] && echo "  ($(wire_detail "$IFACE"))")"
  nc_report
fi
rsilent ""
rsilent "Wifi card           : ${WIFI_HW:-none detected}"
rsilent "Wifi interfaces     : ${WIFI[*]:-none}  (the Wireless test checks the card)"
if [ -n "$ACTION" ]; then
  rsilent "What to do:"
  printf '%s\n' "$ACTION" | fold -s -w 74 | sed 's/^/    /' >> "$REPORT_TXT"
fi
rsilent "RESULT: $VERDICT"
set_kv ETHERNET_RESULT "$VERDICT"

# ---------------------------------------------------------------- result screen
tui_frame "Ethernet network test finished" "Enter to go back"
case "$STATE" in
  PASS)    tui_badge 6 PASS "$( [ "$NC_STATE" = WARN ] && echo "the port works - the network has a problem" || echo "wired network fully working" )" ;;
  WARN)    tui_badge 6 MARGINAL "connects, but not cleanly" ;;
  FAIL)    tui_badge 6 FAIL "the wired connection does not work" ;;
  UNKNOWN) tui_badge 6 UNKNOWN "no wired adapter" ;;
  *)       tui_badge 6 PARTIAL "no cable was connected" ;;
esac
# Rows 8-17 for the figures and 18-22 for the cause: the whole screen fits
# 1366x768 with a two-line action.
row=8
tui_kv $row "Link"    "${IFACE:-none}: $LINK${SPEED:+, $SPEED Mbps $DUPLEX}" "$([ "$LINK" = yes ] && echo ok || echo warn)"; row=$((row+1))
tui_kv $row "Address" "${IP:-none}" "$([ -n "$IP" ] && echo ok || echo warn)"; row=$((row+1))
for r in "${ROWS[@]}"; do
  IFS='|' read -r lab val tone <<< "$r"
  tui_kv $row "$lab" "$val" "$tone"; row=$((row+1))
done
if [ "$NC_CLOCK_STATE" = ok ] || [ "$NC_CLOCK_STATE" = wrong ]; then
  tui_kv $row "Clock" "$NC_CLOCK_TEXT" "$( [ "$NC_CLOCK_STATE" = ok ] && echo ok || echo warn )"; row=$((row+1))
fi
row=$((row+1))
if [ -n "$CAUSE" ] && { [ "$STATE" != PASS ] || [ "$NC_STATE" = WARN ]; }; then
  row=$(tui_para $row "Likely cause: $CAUSE" "$( [ "$STATE" = FAIL ] && echo err || echo warn )")
fi
[ -n "$ACTION" ] && row=$(tui_para $row "$ACTION" "")
# A wrong clock is a laptop fault of its own (the CMOS battery), named even
# when it is not what the network checks tripped over - in full when there
# is room, otherwise the Clock row above and the report carry it.
if [ "$NC_CLOCK_STATE" = wrong ] && [ -z "$ACTION" ]; then
  row=$(tui_para $row "The laptop's clock is $NC_CLOCK_TEXT. $(nc_clock_action)" warn)
fi
if [ -z "$WIFI_HW" ] && [ "${#WIFI[@]}" -eq 0 ] && [ "$row" -le 20 ]; then
  tui_line $row "No wireless card is visible on the bus - check it is seated and enabled in the BIOS." muted
fi
tui_flush
tui_anykey
