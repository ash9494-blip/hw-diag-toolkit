#!/bin/bash
# Network test - wired ethernet, and whether a wifi card is present.
#
# Wifi is deliberately detection-only. Associating with an access point needs
# the wireless firmware blobs, which are 651 MB and would quadruple the size of
# this image for a test that mostly proves the access point works. What matters
# on a repair bench is whether the card is there and the machine can see it;
# whether it connects is a Windows problem, not a hardware one.
#
# The ethernet side is the real test: link, negotiated speed and duplex, DHCP,
# and whether traffic actually gets anywhere.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

PING_HOST=${DIAG_PING_HOST:-1.1.1.1}
PING_NAME=${DIAG_PING_NAME:-one.one.one.one}

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
  local i
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

if [ -n "$IFACE" ]; then
  MAC=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null)
  SPEED=$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null)
  DUPLEX=$(cat "/sys/class/net/$IFACE/duplex" 2>/dev/null)
  case "$SPEED" in ''|-1) SPEED=$(ethtool "$IFACE" 2>/dev/null | awk '/Speed:/{print $2}' | tr -dc '0-9') ;; esac
fi

# ---------------------------------------------------------------- live screen
show() {
  tui_frame "Ethernet network test" "$1"
  local row=6
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
  tui_flush
}

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
    MAC=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null)
    sleep 2
    SPEED=$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null)
    DUPLEX=$(cat "/sys/class/net/$IFACE/duplex" 2>/dev/null)
  fi
fi

IP=""; GW=""; DNS_OK=no; PING_OK=no; DHCP=no; LOSS=""
if [ "$LINK" = yes ]; then
  show "asking for an address" "Link is up. Requesting an address by DHCP..."
  tui_anim_live ether 2 2
  ip addr flush dev "$IFACE" 2>/dev/null
  timeout 25 dhclient -1 -v "$IFACE" >"$RUN_DIR/dhcp.log" 2>&1
  IP=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | head -1)
  GW=$(ip route show default dev "$IFACE" 2>/dev/null | awk '{print $3}' | head -1)
  [ -n "$IP" ] && DHCP=yes

  if [ -n "$IP" ]; then
    show "testing the connection" "Address $IP" "Testing the gateway and the internet..."
    tui_anim_live ether 3 3
    if [ -n "$GW" ]; then ping -c 2 -W 2 "$GW" >/dev/null 2>&1 && GW_OK=yes || GW_OK=no; else GW_OK=n/a; fi
    out=$(ping -c 4 -W 3 "$PING_HOST" 2>/dev/null)
    if printf '%s' "$out" | grep -q ' 0% packet loss'; then PING_OK=yes; fi
    LOSS=$(printf '%s' "$out" | awk -F, '/packet loss/{gsub(/^ +/,"",$3); print $3}')
    RTT=$(printf '%s' "$out" | awk -F'/' '/rtt|round-trip/{print $5}')
    ping -c 1 -W 3 "$PING_NAME" >/dev/null 2>&1 && DNS_OK=yes
  fi
fi

# ---------------------------------------------------------------- report
rsection "ETHERNET NETWORK TEST"
rsilent "Ethernet adapter  : ${NIC:-none found}"
rsilent "Wired interfaces  : ${WIRED[*]:-none}"
rsilent "Interface tested  : ${IFACE:-none}"
[ -n "$MAC" ]   && rsilent "MAC address       : $MAC"
rsilent "Cable link        : $LINK"
[ -n "$SPEED" ] && rsilent "Negotiated speed  : ${SPEED} Mbps ${DUPLEX}"
rsilent "DHCP address      : ${IP:-none}"
rsilent "Default gateway   : ${GW:-none}"
[ -n "$LOSS" ]  && rsilent "Packet loss       : $LOSS"
[ -n "$RTT" ]   && rsilent "Round trip        : ${RTT} ms average"
rsilent "Internet reachable: $PING_OK"
rsilent "DNS working       : $DNS_OK"
rsilent ""
rsilent "Wifi card         : ${WIFI_HW:-none detected}"
rsilent "Wifi interfaces   : ${WIFI[*]:-none}"
rsilent "Note: the wifi card is detected only. This image carries no wireless"
rsilent "firmware, so it cannot join a network - that is by design, not a fault."
rsilent ""

if [ "${#WIRED[@]}" -eq 0 ]; then
  STATE=UNKNOWN; VERDICT="NOT TESTED (no wired adapter on this machine)"
elif [ "$LINK" != yes ]; then
  STATE=PART;    VERDICT="NOT TESTED (no cable was connected)"
elif [ "$DHCP" != yes ]; then
  STATE=FAIL;    VERDICT="FAIL (link is up but DHCP gave no address)"
elif [ "$PING_OK" != yes ]; then
  STATE=WARN;    VERDICT="MARGINAL (address $IP, but nothing answered on the internet)"
elif [ "$DNS_OK" != yes ]; then
  STATE=WARN;    VERDICT="MARGINAL (traffic works, name lookup does not)"
else
  STATE=PASS;    VERDICT="PASS (${SPEED:-?} Mbps, $IP, internet and DNS both work)"
fi
rsilent "RESULT: $VERDICT"
set_kv ETHERNET_RESULT "$VERDICT"

tui_frame "Ethernet network test finished" "Enter to go back"
case "$STATE" in
  PASS)    tui_badge 6 PASS "wired network fully working" ;;
  WARN)    tui_badge 6 MARGINAL "connects, but not everything works" ;;
  FAIL)    tui_badge 6 FAIL "link is up but the network does not work" ;;
  UNKNOWN) tui_badge 6 UNKNOWN "no wired adapter" ;;
  *)       tui_badge 6 PARTIAL "no cable was connected" ;;
esac
tui_kv 9  "Interface"  "${IFACE:-none}"
tui_kv 10 "Link"       "$LINK" "$([ "$LINK" = yes ] && echo ok || echo warn)"
[ -n "$SPEED" ] && tui_kv 11 "Speed" "${SPEED} Mbps ${DUPLEX}"
tui_kv 12 "Address"    "${IP:-none}"
tui_kv 13 "Internet"   "$PING_OK" "$([ "$PING_OK" = yes ] && echo ok || echo warn)"
tui_kv 14 "Wifi card"  "$([ -n "$WIFI_HW" ] && echo "present" || echo "not detected")" \
          "$([ -n "$WIFI_HW" ] && echo ok || echo warn)"
row=16
if [ -n "$WIFI_HW" ]; then
  tui_line $row "$WIFI_HW" muted; row=$((row+1))
  tui_line $row "Detected only - this image carries no wireless firmware." muted
elif [ "${#WIFI[@]}" -eq 0 ]; then
  tui_line $row "No wireless card is visible on the bus at all." warn; row=$((row+1))
  tui_line $row "Check that the card is seated and not disabled in the BIOS." muted
fi
tui_flush
tui_anykey
