#!/bin/bash
# Save the accumulated report to a writable (USB) partition, as .txt and .html
. /opt/diag/lib.sh
. /opt/diag/tui.sh


# most recent value wins, so re-running a test updates the summary
kv() { grep "^$1=" "$SUMMARY_KV" 2>/dev/null | tail -1 | cut -d= -f2-; }

esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/\x1b\[[0-9;]*m//g'; }

row() { # label value
  [ -n "$2" ] && printf '<tr><th>%s</th><td>%s</td></tr>\n' "$1" "$2"
}

# rowk <label> <kv-key> [unit] -- emitted only when the key actually has a value
rowk() {
  local v; v=$(kv "$2" | esc)
  [ -z "$v" ] && return
  printf '<tr><th>%s</th><td>%s%s</td></tr>\n' "$1" "$v" "${3:+ $3}"
}

make_html() {
  local out=$1 tag=$2
  {
    cat <<'HEAD'
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hardware Diagnostic Report</title>
<style>
:root{--bg:#0b0f14;--panel:#121822;--line:#1f2a37;--tx:#dbe4ef;--dim:#7d8da3;--ac:#4cc2ff;--ok:#3ddc97;--warn:#ffcc66;--bad:#ff5f6d}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;padding:24px}
.wrap{max-width:1000px;margin:0 auto}
h1{font-size:20px;letter-spacing:.12em;text-transform:uppercase;color:var(--ac);margin:0 0 4px}
.sub{color:var(--dim);margin-bottom:24px}
table{border-collapse:collapse;width:100%;background:var(--panel);border:1px solid var(--line);margin-bottom:24px}
th,td{padding:8px 12px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{color:var(--dim);font-weight:500;width:230px}
tr:last-child th,tr:last-child td{border-bottom:0}
pre{background:var(--panel);border:1px solid var(--line);padding:18px;overflow-x:auto;white-space:pre;font-size:12.5px;color:var(--tx)}
.foot{color:var(--dim);margin-top:20px;font-size:12px}
</style></head><body><div class="wrap">
HEAD
    printf '<h1>Hardware Diagnostic Report</h1>\n'
    printf '<div class="sub">%s &middot; generated %s</div>\n' "$(printf '%s' "$tag" | esc)" "$(date '+%Y-%m-%d %H:%M:%S')"
    echo '<table>'
    rowk "Model"            SYS_MODEL
    rowk "Serial"           SYS_SERIAL
    rowk "CPU"              SYS_CPU
    rowk "Memory installed" RAM_TOTAL_MB "MB"
    rowk "Battery health"   BATTERY_HEALTH_PCT "%"
    echo '</table><table>'
    rowk "Disk SMART"          DISK_SMART
    rowk "Disk surface scan"   DISK_SURFACE
    rowk "Disk benchmark"      DISK_RESULT
    rowk "Install simulation"  SIM_RESULT
    rowk "SEQ1M Q8T1 read"     DISK_SEQ1M_Q8T1_READ_MBPS "MB/s"
    rowk "SEQ1M Q8T1 write"    DISK_SEQ1M_Q8T1_WRITE_MBPS "MB/s"
    rowk "RND4K Q32T1 read"    DISK_RND4K_Q32T1_READ_IOPS "IOPS"
    rowk "RND4K Q32T1 write"   DISK_RND4K_Q32T1_WRITE_IOPS "IOPS"
    rowk "CPU temp at idle"    CPU_TEMP_IDLE "&deg;C"
    if [ -n "$(kv CPU_TEMP_MAX)" ]; then
      row "CPU temp min / max / avg" \
          "$(kv CPU_TEMP_MIN) / <strong>$(kv CPU_TEMP_MAX)</strong> / $(kv CPU_TEMP_AVG) &deg;C"
    fi
    rowk "CPU thermal throttling" CPU_THROTTLE_EVENTS "events"
    rowk "CPU stress result"      CPU_RESULT
    rowk "RAM test result"        RAM_RESULT
    rowk "Ethernet network"       ETHERNET_RESULT
    rowk "Wireless stability"     WIFI_RESULT
    echo '</table>'
    echo '<pre>'
    esc < "$REPORT_TXT"
    echo '</pre>'
    printf '<div class="foot">Hardware Diagnostic Toolkit v%s</div></div></body></html>\n' "$DIAG_VERSION"
  } > "$out"
}

pick_target() {
  STORAGE_PROMPT="Where should the report be saved?"
  pick_storage || return 1
  TARGET=$STORAGE_DEV
  return 0
}

main() {
  if [ ! -s "$REPORT_TXT" ]; then
    tui_msg "Nothing to save" "No test results have been collected yet."
    return
  fi
  pick_target || return
  if ! mount_storage; then
    tui_msg "Could not write to $TARGET" \
      "$(head -1 "$RUN_DIR/mnterr" 2>/dev/null)" "" \
      "Pick a different partition, or plug in a USB stick" \
      "formatted FAT32, exFAT or NTFS."
    return
  fi
  local dir="$STORAGE_MNT/DiagReports" tag stamp base
  mkdir -p "$dir" 2>/dev/null || {
    umount_storage
    tui_msg "Could not write to $TARGET" "DiagReports could not be created there."
    return
  }
  tag=$(machine_tag); stamp=$(date '+%Y%m%d-%H%M%S')
  base="$dir/${tag}_${stamp}"
  cp "$REPORT_TXT" "$base.txt"
  make_html "$base.html" "$tag"
  sync
  local where=$STORAGE_MNT owned=$STORAGE_OWNED
  umount_storage
  tui_msg "Report saved" "Saved onto $TARGET" "" \
    "  DiagReports/${tag}_${stamp}.txt" \
    "  DiagReports/${tag}_${stamp}.html" "" \
    "$([ "$owned" = 1 ] && echo "The drive has been unmounted - safe to remove." \
                        || echo "Written to $where (the drive this toolkit booted from).")"
}

main
