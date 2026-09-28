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
  tui_frame "System information" "ENTER to go back"
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
  tui_anykey "ENTER to go back"
}

case "$1" in
  --quiet) collect >/dev/null 2>&1 ;;
  *)       collect >/dev/null 2>&1; show_screen ;;
esac
