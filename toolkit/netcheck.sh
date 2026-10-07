#!/bin/bash
# Network checks shared by the Ethernet and Wi-Fi tests (sourced, after lib.sh).
#
# Every check here is sent out of the adapter under test (ping -I, curl
# --interface, a DNS socket bound to the device). Before 1.20 none were: with
# Wi-Fi joined from the home screen, the Ethernet test's internet and DNS
# checks went out over Wi-Fi, and a dead port could pass.
#
# What is checked, in the order a fault shows itself:
#   gateway   20 pings to the router: loss, average, worst, jitter
#   internet  ping to 1.1.1.1 / 8.8.8.8, and a plain web connection to
#             1.1.1.1 - many networks block ping, and that is not a fault
#   DNS       the network's own DNS server, and 1.1.1.1 directly: only the
#             first failing means the network is at fault, not the laptop
#   portal    a hotel / shop Wi-Fi login page in the way
#   HTTPS     a secure connection - fails when the clock is wrong
#   clock     the laptop's hardware clock against the internet's: a flat
#             CMOS battery shows up here (see nc_clock)
# Results land in NC_* variables; nc_cause turns them into one cause and
# what to do about it.

NC_ICMP_HOSTS="1.1.1.1 8.8.8.8"
NC_WEB_IP=1.1.1.1                    # a web server reached by address: no DNS needed
NC_DNS_NAME=www.google.com
NC_DIRECT_DNS=1.1.1.1
NC_PORTAL_URL=http://connectivitycheck.gstatic.com/generate_204
NC_HTTPS_URL=https://1.1.1.1/cdn-cgi/trace
NC_DOWN_URL="https://speed.cloudflare.com/__down?bytes="

nc_reset() {
  NC_GW=""; NC_GW_SENT=0; NC_GW_RECV=0; NC_GW_LOSS=""; NC_GW_AVG=""; NC_GW_MAX=""; NC_GW_MDEV=""; NC_GW_STATE=""
  NC_ICMP=""; NC_ICMP_RTT=""; NC_TCP=""; NC_TCP_MS=""; NC_NET_EPOCH=""
  NC_DNS_SERVER=""; NC_DNS_NET=""; NC_DNS_NET_MS=""; NC_DNS_DIRECT=""; NC_DNS_DIRECT_MS=""
  NC_PORTAL=""; NC_HTTPS=""; NC_HTTPS_ERR=""; NC_DOWN_MBPS=""
  NC_CLOCK_STATE=""; NC_CLOCK_SKEW=""; NC_CLOCK_TEXT=""
  NC_CAUSE=""; NC_ACTION=""; NC_STATE=""
}
nc_reset

nc_log() { printf '%s %s\n' "$(date +%T)" "$*" >> "$RUN_DIR/netcheck.log"; }

# A value from a dhclient lease file: the last "option routers 10.0.0.1;"
nc_lease() {   # lease-file option -> first value, commas dropped
  [ -r "$1" ] || return 1
  awk -v o="$2" '$1=="option" && $2==o {v=$3} END{if(v!=""){sub(/;$/,"",v); print v}}' "$1" \
    | cut -d, -f1
}

# dhclient adds a default route only when there is none: with Wi-Fi already
# online, the cable got an address and no way out ("File exists"). Bound
# traffic needs a route through its own device, so one is added - at a high
# metric, so it never takes over the other link.
nc_route() {   # iface gateway
  [ -n "$2" ] || return 1
  ip route show default dev "$1" 2>/dev/null | grep -q . && return 0
  ip route add default via "$2" dev "$1" metric 1000 >> "$RUN_DIR/netcheck.log" 2>&1
  nc_log "added default route via $2 dev $1"
}

# ------------------------------------------------------------- gateway
nc_gateway() {   # iface gateway [count]
  local out n=${3:-20}
  NC_GW=$2
  [ -n "$2" ] || { NC_GW_STATE=none; return 1; }
  out=$(ping -I "$1" -n -c "$n" -i 0.2 -W 1 "$2" 2>&1)
  nc_log "gateway ping $2 via $1: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  NC_GW_SENT=$(printf '%s' "$out" | sed -n 's/^\([0-9]*\) packets transmitted.*/\1/p')
  NC_GW_RECV=$(printf '%s' "$out" | sed -n 's/.* \([0-9]*\) received.*/\1/p')
  NC_GW_SENT=${NC_GW_SENT:-$n}; NC_GW_RECV=${NC_GW_RECV:-0}
  NC_GW_LOSS=$(( (NC_GW_SENT - NC_GW_RECV) * 100 / (NC_GW_SENT > 0 ? NC_GW_SENT : 1) ))
  # rtt min/avg/max/mdev = 0.291/0.411/0.733/0.102 ms
  read -r NC_GW_AVG NC_GW_MAX NC_GW_MDEV <<< "$(printf '%s' "$out" \
    | awk -F'[=/ ]+' '/rtt|round-trip/{printf "%.1f %.1f %.1f", $7, $8, $9}')"
  # A healthy wired LAN answers in under 5 ms with nothing lost; past 20 ms
  # or any loss is worth a look (the netprobe agent's thresholds).
  if [ "$NC_GW_RECV" = 0 ]; then NC_GW_STATE=lost
  elif [ "$NC_GW_LOSS" -gt 0 ] || awk -v a="${NC_GW_AVG:-0}" 'BEGIN{exit !(a>20)}'; then NC_GW_STATE=warn
  else NC_GW_STATE=ok; fi
  return 0
}

nc_gateway_text() {
  case "$NC_GW_STATE" in
    none) printf 'no gateway was given' ;;
    lost) printf 'no answer (%s of %s lost)' "$((NC_GW_SENT - NC_GW_RECV))" "$NC_GW_SENT" ;;
    *)    printf '%s ms avg, %s ms worst, %s%% lost' "$NC_GW_AVG" "$NC_GW_MAX" "$NC_GW_LOSS" ;;
  esac
}

# ------------------------------------------------------------- internet
nc_internet() {   # iface
  local h out code ms hdr=$RUN_DIR/nc_headers
  NC_ICMP=no
  for h in $NC_ICMP_HOSTS; do
    out=$(ping -I "$1" -n -c 4 -W 2 "$h" 2>&1)
    if printf '%s' "$out" | grep -q ' [1-9][0-9]* received'; then
      NC_ICMP=yes
      NC_ICMP_RTT=$(printf '%s' "$out" | awk -F'[=/ ]+' '/rtt|round-trip/{printf "%.0f", $7}')
      break
    fi
  done
  nc_log "ping internet via $1: $NC_ICMP${NC_ICMP_RTT:+ ${NC_ICMP_RTT} ms}"
  # A web connection by address. Its Date header is also the clock check.
  : > "$hdr"
  read -r code ms <<< "$(curl --interface "$1" -s -o /dev/null -D "$hdr" \
       -w '%{http_code} %{time_connect}' --connect-timeout 5 --max-time 8 "http://$NC_WEB_IP/" 2>>"$RUN_DIR/netcheck.log")"
  if [ -n "$code" ] && [ "$code" != 000 ]; then
    NC_TCP=yes; NC_TCP_MS=$(awk -v t="${ms:-0}" 'BEGIN{printf "%.0f", t*1000}')
    local dline; dline=$(sed -n 's/^[Dd]ate: *//p' "$hdr" | tr -d '\r' | head -1)
    [ -n "$dline" ] && NC_NET_EPOCH=$(date -u -d "$dline" +%s 2>/dev/null)
  else
    NC_TCP=no
  fi
  nc_log "web by address via $1: $NC_TCP (http ${code:-none})${NC_NET_EPOCH:+, date $NC_NET_EPOCH}"
}

# ------------------------------------------------------------- DNS
# One A-record query, from a socket bound to the adapter - getent would ask
# whichever server resolv.conf names, over whichever link the route picks.
nc_dnsq() {   # iface server name -> "ok IP MS" | "fail REASON MS"
  python3 - "$1" "$2" "$3" <<'PY'
import random, socket, struct, sys, time
iface, server, name = sys.argv[1:4]
qid = random.randint(0, 65535)
q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
for part in name.rstrip(".").split("."):
    q += bytes([len(part)]) + part.encode()
q += b"\x00" + struct.pack(">HH", 1, 1)

def skip(d, i):
    while i < len(d):
        n = d[i]
        if n == 0:
            return i + 1
        if n & 0xC0 == 0xC0:
            return i + 2
        i += n + 1
    return i

t0 = time.time()
ms = lambda: int((time.time() - t0) * 1000)
data = None
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if iface != "-":
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, iface.encode())
    s.settimeout(1.5)
    for _ in range(2):
        try:
            s.sendto(q, (server, 53))
            while True:
                d, _ = s.recvfrom(4096)
                if len(d) >= 12 and struct.unpack(">H", d[:2])[0] == qid:
                    data = d
                    break
            break
        except socket.timeout:
            continue
except OSError as e:
    print("fail error%d %d" % (e.errno or 0, ms()))
    sys.exit(0)
if data is None:
    print("fail timeout %d" % ms())
    sys.exit(0)
rcode = data[3] & 0x0F
an = struct.unpack(">H", data[6:8])[0]
if rcode:
    print("fail rcode%d %d" % (rcode, ms()))
    sys.exit(0)
i = skip(data, 12) + 4
for _ in range(an):
    i = skip(data, i)
    if i + 10 > len(data):
        break
    typ, _, _, ln = struct.unpack(">HHIH", data[i:i + 10])
    i += 10
    if typ == 1 and ln == 4:
        print("ok %s %d" % (socket.inet_ntoa(data[i:i + 4]), ms()))
        sys.exit(0)
    i += ln
print("fail empty %d" % ms())
PY
}

nc_dns_reason() {   # timeout | rcode2 | ... -> words
  case "$1" in
    timeout) printf 'no answer' ;;
    rcode2)  printf 'server failure' ;;
    rcode3)  printf 'name not found' ;;
    rcode5)  printf 'refused' ;;
    empty)   printf 'empty answer' ;;
    *)       printf '%s' "$1" ;;
  esac
}

nc_dns() {   # iface [lease-file]
  local r bind=$1
  NC_DNS_SERVER=$(nc_lease "$2" domain-name-servers)
  [ -z "$NC_DNS_SERVER" ] && NC_DNS_SERVER=$(awk '$1=="nameserver"{print $2; exit}' /etc/resolv.conf 2>/dev/null)
  # A resolver on this machine itself (127.x, or one of its own addresses -
  # WSL's 10.255.255.254) cannot be reached through the cable: ask it unbound.
  case "$NC_DNS_SERVER" in 127.*) bind=- ;; esac
  ip -4 -o addr show 2>/dev/null | grep -q " $NC_DNS_SERVER/" && bind=-
  if [ -n "$NC_DNS_SERVER" ]; then
    r=$(nc_dnsq "$bind" "$NC_DNS_SERVER" "$NC_DNS_NAME")
    set -- "$1" $r
    NC_DNS_NET=$2; NC_DNS_NET_MS=${4:-$3}
    [ "$2" = ok ] || NC_DNS_NET="fail $(nc_dns_reason "$3")"
  else
    NC_DNS_NET=none
  fi
  r=$(nc_dnsq "$1" "$NC_DIRECT_DNS" "$NC_DNS_NAME")
  set -- "$1" $r
  NC_DNS_DIRECT=$2; NC_DNS_DIRECT_MS=${4:-$3}
  [ "$2" = ok ] || NC_DNS_DIRECT="fail $(nc_dns_reason "$3")"
  nc_log "DNS via $1: network ${NC_DNS_SERVER:-none} $NC_DNS_NET, direct $NC_DIRECT_DNS $NC_DNS_DIRECT"
}

nc_dns_text() {   # net|direct
  local v ms
  if [ "$1" = net ]; then v=$NC_DNS_NET; ms=$NC_DNS_NET_MS; else v=$NC_DNS_DIRECT; ms=$NC_DNS_DIRECT_MS; fi
  case "$v" in
    ok)   printf 'answers (%s ms)' "$ms" ;;
    none) printf 'none given by the network' ;;
    *)    printf '%s' "${v#fail }" ;;
  esac
}

# ------------------------------------------------------------- portal, HTTPS
# A login page answers the "is this the internet?" address with its own page
# instead of the empty 204 - shop and hotel Wi-Fi, some guest networks.
nc_portal() {   # iface
  local code
  code=$(curl --interface "$1" -s -o /dev/null -w '%{http_code}' --max-time 8 "$NC_PORTAL_URL" 2>>"$RUN_DIR/netcheck.log")
  case "$code" in
    204)     NC_PORTAL=no ;;
    ''|000)  NC_PORTAL=unknown ;;
    *)       NC_PORTAL=yes ;;
  esac
  nc_log "portal check via $1: http ${code:-none} -> $NC_PORTAL"
}

nc_https() {   # iface
  local rc
  curl --interface "$1" -s -o /dev/null --max-time 10 "$NC_HTTPS_URL" 2>>"$RUN_DIR/netcheck.log"
  rc=$?
  if [ "$rc" = 0 ]; then NC_HTTPS=yes; else NC_HTTPS=no; NC_HTTPS_ERR=$rc; fi
  nc_log "HTTPS via $1: $NC_HTTPS${NC_HTTPS_ERR:+ (curl $NC_HTTPS_ERR)}"
}

nc_download() {   # iface bytes -> NC_DOWN_MBPS
  local got ms start end
  start=$(date +%s%N)
  got=$(curl --interface "$1" -s -o /dev/null -w '%{size_download}' --max-time 15 \
        "$NC_DOWN_URL$2" 2>>"$RUN_DIR/netcheck.log")
  end=$(date +%s%N); ms=$(( (end - start) / 1000000 ))
  if [ "${got:-0}" -gt 1000000 ] && [ "$ms" -gt 0 ]; then
    NC_DOWN_MBPS=$(awk -v b="$got" -v m="$ms" 'BEGIN{printf "%.1f", b*8/(m/1000)/1000000}')
  fi
  nc_log "download via $1: ${got:-0} bytes in $ms ms${NC_DOWN_MBPS:+ = $NC_DOWN_MBPS Mbit/s}"
}

# ------------------------------------------------------------- the clock
# The hardware clock (RTC) runs from the coin cell while the laptop is off.
# A flat cell loses the time whenever the main battery is flat or out, and
# the BIOS starts again from its default date - and secure websites,
# Windows sign-in and updates then fail. Windows keeps this clock in local
# time, so a whole number of hours (or half / quarter hours) off is a time
# zone, not a fault.
NC_BUILD_EPOCH=$(cat /opt/diag/build-epoch 2>/dev/null)

nc_span() {   # seconds -> "3 days" / "5 hours" / "12 minutes"
  local s=$1
  if   [ "$s" -ge 172800 ]; then printf '%d days' $(( s / 86400 ))
  elif [ "$s" -ge 7200 ];   then printf '%d hours' $(( s / 3600 ))
  else                           printf '%d minutes' $(( s / 60 ))
  fi
}

nc_dist() { local d=$(( $1 - $2 )); printf '%d' "${d#-}"; }

nc_clock() {
  local rtc skew abs h hh tz=""
  rtc=$(cat /sys/class/rtc/rtc0/since_epoch 2>/dev/null)
  [ -n "$rtc" ] || rtc=$(date -u +%s)
  if [ -n "$NC_NET_EPOCH" ]; then
    skew=$(( rtc - NC_NET_EPOCH )); abs=${skew#-}
    NC_CLOCK_SKEW=$skew
    # A few minutes is ordinary drift for a clock nobody has set in months;
    # a whole hour (or half hour) off, up to 14, is a time zone.
    h=$(( (abs + 1800) / 3600 )); hh=$(( (abs + 900) / 1800 ))
    if [ "$abs" -gt 900 ] && [ "$h" -ge 1 ] && [ "$h" -le 14 ] && [ "$(nc_dist "$abs" $(( h * 3600 )))" -le 900 ]; then
      tz=$h
    elif [ "$abs" -gt 900 ] && [ "$hh" -le 28 ] && [ "$(nc_dist "$abs" $(( hh * 1800 )))" -le 600 ]; then
      tz=$(awk -v n="$hh" 'BEGIN{printf "%g", n/2}')
    fi
    if [ "$abs" -le 120 ]; then
      NC_CLOCK_STATE=ok; NC_CLOCK_TEXT="right, within $abs s"
    elif [ "$abs" -le 900 ]; then
      NC_CLOCK_STATE=ok; NC_CLOCK_TEXT="right, $(( abs / 60 )) minutes off (ordinary drift)"
    elif [ -n "$tz" ]; then
      NC_CLOCK_STATE=ok
      NC_CLOCK_TEXT="right - kept in local time (UTC$( [ "$skew" -lt 0 ] && echo - || echo + )$tz), as Windows does"
    else
      NC_CLOCK_STATE=wrong
      NC_CLOCK_TEXT="wrong by $(nc_span "$abs") ($( [ "$skew" -lt 0 ] && echo behind || echo ahead))"
    fi
  elif [ -n "$NC_BUILD_EPOCH" ] && [ "$rtc" -lt $(( NC_BUILD_EPOCH - 86400 )) ]; then
    NC_CLOCK_STATE=wrong
    NC_CLOCK_TEXT="before the date this USB was made ($(date -u -d "@$rtc" '+%d %b %Y'))"
  else
    NC_CLOCK_STATE=unknown; NC_CLOCK_TEXT="not checked - no internet time to compare with"
  fi
  nc_log "clock: rtc $rtc, internet ${NC_NET_EPOCH:-none}: $NC_CLOCK_TEXT"
}

nc_clock_action() {
  printf '%s' "Set the date and time in the BIOS, then switch the laptop off, take the charger out (and the battery if it comes out) for a minute and check again. If the time is lost again, replace the CMOS coin cell on the board."
}

# ------------------------------------------------------------- the cause
# The first layer that fails is the cause; everything above it is only its
# consequence. NC_SIDE says whose fault it is: "network" faults (a dead DNS
# server, a login page, the router's own internet) say nothing against the
# laptop and must not fail it; "laptop" ones do. The clock is reported on
# its own (nc_clock) unless it is what breaks the secure connections.
nc_cause() {   # media(cable|wifi)
  local link="the cable or the port" where="cable and switch port"
  [ "$1" = wifi ] && { link="the antenna leads or the card"; where=network; }
  NC_STATE=PASS; NC_SIDE=""; NC_ACTION=""
  if [ "$NC_GW_STATE" = lost ] && [ "$NC_ICMP" != yes ] && [ "$NC_TCP" != yes ]; then
    NC_STATE=FAIL; NC_SIDE=unknown; NC_CAUSE="the router does not answer and nothing gets out"
    NC_ACTION="The laptop has an address but no traffic passes. Try another device on the same $where: if it works there, suspect $link."
  elif [ "$NC_ICMP" != yes ] && [ "$NC_TCP" != yes ]; then
    NC_STATE=WARN; NC_SIDE=network; NC_CAUSE="the router answers, but nothing beyond it does"
    NC_ACTION="The laptop reaches the router, so its side works. The router's own internet connection is down or blocked - check it with another device."
  elif [ "$NC_PORTAL" = yes ]; then
    NC_STATE=WARN; NC_SIDE=network; NC_CAUSE="a login page (captive portal) is in the way"
    NC_ACTION="This network wants a sign-in before it passes traffic - a network setting, not a laptop fault. Test on a network without a login page."
  elif [ "${NC_DNS_NET%% *}" = fail ] && [ "$NC_DNS_DIRECT" = ok ]; then
    NC_STATE=WARN; NC_SIDE=network; NC_CAUSE="the network's DNS server ($NC_DNS_SERVER) does not answer"
    NC_ACTION="Names cannot be looked up through this network's own DNS server, while 1.1.1.1 answers through the same adapter: the router or the ISP is at fault, not this laptop."
  elif [ "${NC_DNS_DIRECT%% *}" = fail ] && [ "$NC_DNS_NET" != ok ]; then
    NC_STATE=WARN; NC_SIDE=network; NC_CAUSE="no DNS server answers"
    NC_ACTION="Web traffic gets out but names cannot be looked up - DNS is blocked or broken on this network. Not a laptop fault."
  elif [ "$NC_HTTPS" = no ] && [ "$NC_CLOCK_STATE" = wrong ]; then
    NC_STATE=WARN; NC_SIDE=laptop; NC_CAUSE="secure websites fail - the laptop's clock is $NC_CLOCK_TEXT"
    NC_ACTION=$(nc_clock_action)
  elif [ "$NC_HTTPS" = no ]; then
    NC_STATE=WARN; NC_SIDE=network; NC_CAUSE="secure (HTTPS) connections fail"
    NC_ACTION="Plain web traffic works but secure connections do not - a filtering proxy or firewall on this network. Try another network."
  elif [ "$NC_GW_STATE" = warn ]; then
    NC_STATE=WARN; NC_SIDE=laptop; NC_CAUSE="the link to the router is poor - $(nc_gateway_text)"
    NC_ACTION="Lost or slow replies from the router point at $link. $( [ "$1" = wifi ] \
      && echo "Check both antenna leads are clipped onto the card, and test on another channel." \
      || echo "Swap the cable, then the switch port; if it follows the laptop, suspect its port." )"
  else
    NC_CAUSE="router, internet, DNS and secure web all work"
    [ "$NC_GW_STATE" = lost ] && NC_CAUSE="$NC_CAUSE (the router ignores ping - some do)"
    [ "$NC_ICMP" != yes ] && NC_CAUSE="$NC_CAUSE (ping is blocked on this network, web traffic is not)"
  fi
  return 0
}

# ------------------------------------------------------------- report
nc_report() {
  rsilent "Gateway (20 pings)  : ${NC_GW:-none}  $(nc_gateway_text)"
  rsilent "Internet by ping    : ${NC_ICMP:-not tried}${NC_ICMP_RTT:+  (${NC_ICMP_RTT} ms)}"
  rsilent "Internet by web     : ${NC_TCP:-not tried}${NC_TCP_MS:+  (connected in ${NC_TCP_MS} ms)}"
  rsilent "Network's DNS       : ${NC_DNS_SERVER:-none}  $(nc_dns_text net)"
  rsilent "DNS 1.1.1.1 direct  : $(nc_dns_text direct)"
  rsilent "Login page (portal) : ${NC_PORTAL:-not checked}"
  rsilent "Secure web (HTTPS)  : ${NC_HTTPS:-not tried}${NC_HTTPS_ERR:+  (curl error $NC_HTTPS_ERR)}"
  rsilent "Download            : ${NC_DOWN_MBPS:-not measured}${NC_DOWN_MBPS:+ Mbit/s}"
  rsilent "Clock (CMOS battery): ${NC_CLOCK_TEXT:-not checked}"
  rsilent "Likely cause        : $NC_CAUSE$( [ "$NC_SIDE" = network ] && echo "  [the network, not this laptop]")"
  [ -n "$NC_ACTION" ] && printf '%s\n' "$NC_ACTION" | fold -s -w 74 | sed 's/^/    /' >> "$REPORT_TXT"
  case "$NC_CLOCK_STATE" in
    ok)    set_kv CLOCK_RESULT "PASS ($NC_CLOCK_TEXT)" ;;
    wrong) set_kv CLOCK_RESULT "WARN (clock $NC_CLOCK_TEXT - CMOS battery?)" ;;
  esac
  return 0
}
