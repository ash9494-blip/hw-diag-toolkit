#!/bin/bash
# System identification + battery health
. /opt/diag/lib.sh
. /opt/diag/tui.sh

battery_health() {   # echoes "pct|design|full|cycles|name" for the first battery
  local b fd fc cyc mfr mdl pct
  for b in /sys/class/power_supply/BAT*; do
    [ -d "$b" ] || continue
    fd=$(cat "$b/energy_full_design" 2>/dev/null || cat "$b/charge_full_design" 2>/dev/null)
    fc=$(cat "$b/energy_full"        2>/dev/null || cat "$b/charge_full"        2>/dev/null)
    cyc=$(cat "$b/cycle_count" 2>/dev/null)
    mfr=$(cat "$b/manufacturer" 2>/dev/null); mdl=$(cat "$b/model_name" 2>/dev/null)
    pct=""
    [ -n "$fd" ] && [ -n "$fc" ] && [ "$fd" -gt 0 ] 2>/dev/null && \
      pct=$(awk -v a="$fc" -v d="$fd" 'BEGIN{printf "%.1f", a*100/d}')
    printf '%s|%s|%s|%s|%s' "$pct" "$(( ${fd:-0} / 1000 ))" "$(( ${fc:-0} / 1000 ))" "${cyc:-}" "${mfr:-} ${mdl:-}"
    return
  done
  printf '||||'
}

# ---------------------------------------------------------------- more info
# The motherboard, the network cards (address, speed, Wi-Fi standard) and the
# PCIe links: what a bench sheet asks for and the first page has no room for
# (1.21, Ash). more_facts prints "label|value|tone" lines, "||" for a gap, for
# the More info page and the report alike.

pci_short() {   # bdf -> the card's name from lspci, boilerplate dropped
  lspci -s "$1" 2>/dev/null | head -1 | sed -e 's/^[0-9a-f:.]* //' -e 's/^[^:]*: //' \
    -e 's/ Corporation//' -e 's/, Inc\.//' -e 's/ Co\., Ltd\.*//' -e 's/ Semiconductor//' \
    -e 's/ (rev [0-9a-f]*)$//'
}

net_card() {   # iface -> its card's name, PCI or USB
  local d n; d=$(readlink -f "/sys/class/net/$1/device" 2>/dev/null)
  case "$d" in
    */usb*) n="$(cat "$d/../manufacturer" 2>/dev/null) $(cat "$d/../product" 2>/dev/null) (USB)" ;;
    *)      n=$(pci_short "${d##*/}") ;;
  esac
  printf '%s (%s)' "${n:-not named}" "$1"
}

mac_of() {   # iface -> the card's own address, not one randomised for a scan
  local m; m=$(ethtool -P "$1" 2>/dev/null | awk '{print $NF}')
  case "$m" in ''|00:00:00:00:00:00) m=$(cat "/sys/class/net/$1/address" 2>/dev/null) ;; esac
  printf '%s' "$m"
}

net_list() {   # wired|wifi -> interfaces that are real cards
  local i n w
  for i in /sys/class/net/*; do
    n=${i##*/}
    [ -e "$i/device" ] || continue
    w=wired; { [ -d "$i/wireless" ] || [ -e "$i/phy80211" ]; } && w=wifi
    [ "$w" = "$1" ] && printf '%s\n' "$n"
  done
}

undriven() {   # PCI class (0x0200 ethernet, 0x0280 wifi) -> bdf of cards with no interface
  local d
  for d in /sys/bus/pci/devices/*; do
    case "$(cat "$d/class" 2>/dev/null)" in "$1"*) ;; *) continue ;; esac
    [ -d "$d/net" ] && continue
    printf '%s\n' "${d##*/}"
  done
}

eth_max() {   # iface -> "1 Gbps": the fastest of the port's supported link modes
  ethtool "$1" 2>/dev/null | awk '
    /Supported link modes:/ { on = 1 }
    on && /:/ && !/Supported link modes:/ { on = 0 }
    on { for (i = 1; i <= NF; i++) if (match($i, /^[0-9]+base/)) { v = substr($i, 1, RLENGTH - 4) + 0; if (v > m) m = v } }
    END { if (m >= 1000) printf "%g Gbps", m / 1000; else if (m) printf "%d Mbps", m }'
}

eth_now() {   # iface [wait] -> "1000 Mbps, full duplex" or "no cable"
  local n=$1 i
  # cable ports boot switched off, and an off port has no carrier even with a
  # cable in - so the page switches it on and gives it a moment (not the report)
  if [ "$2" = wait ] && [ "$(cat "/sys/class/net/$n/carrier" 2>/dev/null)" != 1 ]; then
    ip link set "$n" up 2>/dev/null
    for i in 1 2 3 4 5 6; do [ "$(cat "/sys/class/net/$n/carrier" 2>/dev/null)" = 1 ] && break; sleep 0.5; done
  fi
  [ "$(cat "/sys/class/net/$n/carrier" 2>/dev/null)" = 1 ] || { printf 'no cable'; return; }
  local sd
  sd=$(ethtool "$n" 2>/dev/null | awk -F': ' '/Speed:/ {s = $2} /Duplex:/ {d = tolower($2)}
    END { if (s == "" || s ~ /Unknown/) exit; sub(/Mb\/s/, " Mbps", s); printf "%s|%s", s, d }')
  # whole strings per duplex, not "%s duplex" inside awk: the screen
  # translates them, and awk's text was never found for the catalogues (1.21)
  case "$sd" in
    '')       printf 'cable in, speed not reported' ;;
    *'|full') printf '%s, full duplex' "${sd%%|*}" ;;
    *'|half') printf '%s, half duplex' "${sd%%|*}" ;;
    *)        printf '%s' "${sd%%|*}" ;;
  esac
}

wifi_std() {   # iface -> "Wi-Fi 7 (802.11be) - 2.4 / 5 / 6 GHz", from what the card says it can do
  local phy; phy=$(iw dev "$1" info 2>/dev/null | awk '/wiphy/{print $2; exit}')
  [ -n "$phy" ] || return 1
  iw phy "phy$phy" info 2>/dev/null | awk '
    /^[ \t]*Band [0-9]+:/ { band[$2 + 0] = 1 }
    /EHT Iftypes/ { e = 1 } /HE Iftypes/ { h = 1 } /VHT Capabilities/ { v = 1 } /HT Capabilities/ { n = 1 }
    END {
      if (e) g = "Wi-Fi 7 (802.11be)"; else if (h && band[4]) g = "Wi-Fi 6E (802.11ax)"
      else if (h) g = "Wi-Fi 6 (802.11ax)"; else if (v) g = "Wi-Fi 5 (802.11ac)"
      else if (n) g = "Wi-Fi 4 (802.11n)"; else g = "802.11a/b/g"
      s = ""
      if (band[1]) s = "2.4"
      if (band[2]) s = s (s ? " / " : "") "5"
      if (band[4]) s = s (s ? " / " : "") "6"
      printf "%s%s", g, (s ? " - " s " GHz" : "")
    }'
}

pci_kind() {   # class -> what the device is, short
  case "$1" in
    0x0108*) echo "NVMe drive" ;; 0x0106*) echo "SATA controller" ;; 0x0280*) echo "Wi-Fi" ;;
    0x0200*) echo "Ethernet" ;; 0x03*) echo "Graphics" ;; 0x0805*|0xff00*) echo "Card reader" ;;
    0x0c03*) echo "USB controller" ;; 0x0c0a*|0x0880*) echo "Thunderbolt" ;; *) echo "Device" ;;
  esac
}

pcie_facts() {   # -> the ports in use, then a line per device with a link
  local d bdf cls ports=0 used=0 top="" t slots=0 sused=0 a
  for d in /sys/bus/pci/devices/*; do
    case "$(cat "$d/class" 2>/dev/null)" in 0x0604*) ;; *) continue ;; esac
    # a root port hangs straight off the root complex (pci0000:00)
    case "$(readlink -f "$d/..")" in */pci[0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;; *) continue ;; esac
    ports=$((ports + 1))
    ls -d "$d"/[0-9a-f][0-9a-f][0-9a-f][0-9a-f]:* >/dev/null 2>&1 && used=$((used + 1))
    t=$(pcie_gen "$(cat "$d/max_link_speed" 2>/dev/null)")
    [ -n "$t" ] && awk -v a="$t" -v b="${top:-0}" 'BEGIN{exit !(a > b)}' && top=$t
  done
  [ "$ports" -gt 0 ] || return 0
  printf 'PCIe ports|%s of %s in use%s|\n' "$used" "$ports" "${top:+ - fastest PCIe $top}"
  # physical slots, where the firmware lists any (laptops mostly do not)
  for d in /sys/bus/pci/slots/*/address; do
    [ -r "$d" ] || continue
    slots=$((slots + 1)); a=$(cat "$d")
    ls -d /sys/bus/pci/devices/"$a".* >/dev/null 2>&1 && sused=$((sused + 1))
  done
  [ "$slots" -gt 0 ] && printf 'PCIe slots|%s of %s in use|\n' "$sused" "$slots"
  for d in /sys/bus/pci/devices/*; do
    bdf=${d##*/}; cls=$(cat "$d/class" 2>/dev/null)
    case "$cls" in 0x0604*) continue ;; esac
    pcie_link "$bdf" || continue
    printf '%s|%s - %s|%s\n' "$(pci_kind "$cls")" "${PCIE_NOW%%  (*}${PCIE_DRIVE:+ (can do ${PCIE_DRIVE#PCIe })}" \
      "$(pci_short "$bdf")" "$( [ -n "$PCIE_NOTE" ] && [ "$PCIE_TONE" = warn ] && echo warn)"
  done
}

more_facts() {   # [wait] -> "label|value|tone" lines; wait = let cable ports come up
  local v ver ser n i=0 b now max speed
  v=$(printf '%s %s' "$(dmi baseboard-manufacturer)" "$(dmi baseboard-product-name)" | sed 's/^ *//;s/ *$//')
  ver=$(dmi baseboard-version); ser=$(dmi baseboard-serial-number)
  printf 'Motherboard|%s%s|\n' "${v:-not reported by the firmware}" "${ver:+  (version $ver)}"
  [ -n "$ser" ] && printf 'Board serial|%s|\n' "$ser"
  printf '||\n'
  for n in $(net_list wired); do
    i=$((i + 1)); now=$(eth_now "$n" "$1"); max=$(eth_max "$n")
    printf 'Ethernet card|%s|\n' "$(net_card "$n")"
    printf 'LAN MAC address|%s|\n' "$(mac_of "$n")"
    # two whole strings: "up to 1 Gbps - " glued on in front matched nothing
    if [ -n "$max" ]; then speed="up to $max - now: $now"; else speed="now: $now"; fi
    printf 'LAN port speed|%s|%s\n' "$speed" "$( [ "$now" = "no cable" ] && echo muted)"
  done
  for b in $(undriven 0x0200); do
    i=$((i + 1)); printf 'Ethernet card|%s - no driver running (see Driver check)|warn\n' "$(pci_short "$b")"
  done
  [ "$i" = 0 ] && printf 'Ethernet card|none on this laptop|muted\n'
  printf '||\n'
  i=0
  for n in $(net_list wifi); do
    i=$((i + 1))
    printf 'Wi-Fi card|%s|\n' "$(net_card "$n")"
    printf 'Wi-Fi MAC address|%s|\n' "$(mac_of "$n")"
    printf 'Wi-Fi standard|%s|\n' "$(wifi_std "$n" || echo "not reported")"
    v=$(iw dev "$n" link 2>/dev/null | awk -F': ' '/tx bitrate/{print $2; exit}')
    [ -n "$v" ] && printf 'Wi-Fi now|connected: %s|ok\n' "$(link_kind "$v")"
  done
  for b in $(undriven 0x0280); do
    i=$((i + 1)); printf 'Wi-Fi card|%s - no driver running (see Driver check)|warn\n' "$(pci_short "$b")"
  done
  [ "$i" = 0 ] && printf 'Wi-Fi card|none found|muted\n'
  printf '||\n'
  pcie_facts
}

show_more() {
  tui_frame "System information - more" "ENTER to go back"
  local row=6 k v t
  while IFS='|' read -r k v t; do
    [ $row -gt $((TUI_ROWS-6)) ] && break
    [ -z "$k" ] && { row=$((row+1)); continue; }
    tui_kv $row "$k" "$v" "$t"; row=$((row+1))
  done < <(more_facts wait)
  tui_anykey "ENTER to go back"
}

collect() {
  rsection "SYSTEM INFORMATION"
  rsilent "Manufacturer  : $(dmi system-manufacturer)"
  rsilent "Model         : $(dmi system-product-name)"
  rsilent "Serial number : $(dmi system-serial-number)"
  rsilent "Baseboard     : $(dmi baseboard-manufacturer) $(dmi baseboard-product-name)"
  rsilent "BIOS          : $(dmi bios-vendor) $(dmi bios-version)  ($(dmi bios-release-date))"
  rsilent ""
  rsilent "CPU           : $(cpu_model)"
  rsilent "Threads       : $(cpu_threads)"
  rsilent "Memory        : $(mem_total_mb) MB usable"
  rsilent "Temp sensor   : $(cpu_temp_source)   (now: $(cpu_temp_c) C)"
  rsilent ""
  rsilent "Storage devices:"
  lsblk -dno NAME,SIZE,TRAN,ROTA,MODEL 2>/dev/null \
    | awk '$1 !~ /^(loop|sr|ram)/ {t=($4==1)?"HDD":"SSD"; printf "  /dev/%-8s %-9s %-6s %-5s %s\n", $1,$2,$3,t,substr($0, index($0,$5))}' >> "$REPORT_TXT"
  rsilent ""
  rsilent "Graphics:"
  lspci 2>/dev/null | grep -iE 'vga|3d|display' | sed 's/^/  /' >> "$REPORT_TXT"
  rsilent ""
  rsilent "More info:"
  local k v t
  while IFS='|' read -r k v t; do
    [ -n "$k" ] && rsilent "$(printf '  %-18s: %s' "$k" "$v")"
  done < <(more_facts)

  local bat pct design full cycles name
  bat=$(battery_health)
  IFS='|' read -r pct design full cycles name <<< "$bat"
  rsilent ""
  if [ -n "$pct" ]; then
    rsilent "Battery:"
    rsilent "  Vendor/model    : $name"
    rsilent "  Design capacity : ${design} mWh"
    rsilent "  Full capacity   : ${full} mWh"
    rsilent "  Health          : ${pct}%"
    [ -n "$cycles" ] && rsilent "  Cycle count     : $cycles"
    set_kv BATTERY_HEALTH_PCT "$pct"
  else
    rsilent "Battery: none detected or capacity not reported"
  fi

  set_kv SYS_MODEL "$(dmi system-product-name)"
  set_kv SYS_SERIAL "$(dmi system-serial-number)"
  set_kv SYS_CPU "$(cpu_model)"
}

show_screen() {
  tui_frame "System information" "ENTER to go back      M = more info: motherboard, network cards, PCIe"
  local row=6
  tui_kv $row "Manufacturer" "$(dmi system-manufacturer)"; row=$((row+1))
  tui_kv $row "Model"        "$(dmi system-product-name)"; row=$((row+1))
  tui_kv $row "Serial"       "$(dmi system-serial-number)"; row=$((row+1))
  tui_kv $row "BIOS"         "$(dmi bios-version)  ($(dmi bios-release-date))"; row=$((row+2))
  tui_kv $row "CPU"          "$(cpu_model)"; row=$((row+1))
  tui_kv $row "Threads"      "$(cpu_threads)"; row=$((row+1))
  tui_kv $row "Temp now"     "$(cpu_temp_c) C   via $(cpu_temp_source)"; row=$((row+1))
  tui_kv $row "Memory"       "$(mem_total_mb) MB"; row=$((row+2))

  local l
  while IFS= read -r l; do
    [ $row -gt $((TUI_ROWS-6)) ] && break
    tui_line $row "$l"; row=$((row+1))
  done < <(lsblk -dno NAME,SIZE,TRAN,ROTA,MODEL 2>/dev/null \
    | awk '$1 !~ /^(loop|sr|ram)/ {t=($4==1)?"HDD":"SSD"; printf "/dev/%-8s %-9s %-6s %-4s %s\n", $1,$2,$3,t,substr($0, index($0,$5))}')
  row=$((row+1))

  local bat pct design full cycles name
  bat=$(battery_health); IFS='|' read -r pct design full cycles name <<< "$bat"
  if [ -n "$pct" ]; then
    local col=$OKC
    awk -v p="$pct" 'BEGIN{exit !(p<80)}' && col=$WRN
    awk -v p="$pct" 'BEGIN{exit !(p<70)}' && col=$ERR
    tui_kv $row "Battery health" "${pct}%   (${full} of ${design} mWh${cycles:+, $cycles cycles})" "$col$B"
  else
    tui_kv $row "Battery" "none detected"
  fi
  tui_keys m
  [ "$TUI_KEY" = m ] && show_more
  return 0
}

case "$1" in
  --quiet) collect >/dev/null 2>&1 ;;
  *)       collect >/dev/null 2>&1; show_screen ;;
esac
