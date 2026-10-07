#!/bin/bash
# SSD controller check - the chip that runs the drive, not its flash.
#
# On a modern SSD the controller is what fails: it resets under load, drops
# off the PCIe bus, overheats and throttles, or wakes too slowly from power
# saving (the PM991 in the SATELLITE PRO C40-K). A speed benchmark measures
# the flash and misses all of it. This names the controller chip, gives it the
# load that works it hardest - thousands of small random reads at once - while
# watching its temperature, PCIe link, error counters and the kernel log, then
# times how fast it wakes from power saving.
#
# Read only (fio --readonly): nothing is written, safe on a customer's drive.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

LOAD_S=${DIAG_CTRL_LOAD:-60}
FIO_JSON=$RUN_DIR/ctrl-fio.json
# Resets and time-outs only. PCIe link retries are counted separately from
# the AER counters: they are a warning, and matching "error" here made every
# corrected retry read as a controller reset.
KERR_RE='nvme.*(timeout|time out|controller is down|reset|abort|not ready|removing|disabl)|ata[0-9.]+:.*(exception|hard resetting|failed command)'
FINDINGS=()
note() { FINDINGS+=("$1|$2"); }      # FAIL|text or WARN|text

jq_get() { printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null; }
kv() { printf '%s\n' "$2" | awk -F= -v k="$1" '$1==k{print $2; exit}'; }
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
ns_ms() { awk -v n="${1:-0}" 'BEGIN{printf "%.1f", n/1000000}'; }

# ---------------------------------------------------------------- the drive
pick_ssd() {
  local -a names=() labels=() trans=()
  local n s r t m
  while read -r n s r t m; do
    [ -n "$n" ] || continue
    [ "$t" = usb ] && continue            # a USB case hides the controller
    [ "$r" = 1 ] && continue              # hard disks have no flash controller
    names+=("$n"); trans+=("$t"); labels+=("/dev/$n|$s  ${t^^}|$m")
  done < <(list_disks)
  if [ ${#names[@]} -eq 0 ]; then
    tui_msg "No SSD found" "No internal SSD was found." "" \
      "A drive in a USB case cannot be checked: the USB bridge hides its controller."
    return 1
  fi
  if [ ${#names[@]} -gt 1 ]; then
    tui_menu "Which SSD?" "arrows + Enter, Q to go back" "${labels[@]}" || return 1
    DISK=${names[$((TUI_CHOICE-1))]}; TRAN=${trans[$((TUI_CHOICE-1))]}
  else
    DISK=${names[0]}; TRAN=${trans[0]}
  fi
  case "$DISK" in nvme*) TRAN=nvme ;; esac
}

identify() {
  CHIP=""; MODEL=""; FW=""; MEMORY=""; BDF=""; CTRL=""; APSTA=0; MAXWAKE_US=0; WCT=""; CCT=""; ANIM_DRAM=""
  if [ "$TRAN" = nvme ]; then
    CTRL=${DISK%%n[0-9]*}
    BDF=$(basename "$(readlink -f "/sys/class/nvme/$CTRL/device" 2>/dev/null)")
    local id; id=$(nvme id-ctrl "/dev/$CTRL" -o json 2>/dev/null)
    MODEL=$(jq_get "$id" .mn | sed 's/ *$//'); FW=$(jq_get "$id" .fr | sed 's/ *$//')
    CHIP=$(lspci -s "$BDF" 2>/dev/null | head -1 | sed 's/^[^ ]* //; s/^Non-Volatile memory controller: //')
    CHIP="${CHIP:-unknown} [$(sed 's/^0x//' "/sys/bus/pci/devices/$BDF/vendor" 2>/dev/null):$(sed 's/^0x//' "/sys/bus/pci/devices/$BDF/device" 2>/dev/null)]"
    APSTA=$(num "$(jq_get "$id" .apsta)")
    MAXWAKE_US=$(printf '%s' "$id" | jq '[.psds[]? | select(."non-operational_state"==1) | (.entry_lat + .exit_lat)] | max // 0' 2>/dev/null)
    MAXWAKE_US=$(num "$MAXWAKE_US")
    local w c; w=$(num "$(jq_get "$id" .wctemp)"); c=$(num "$(jq_get "$id" .cctemp)")
    [ "$w" -gt 273 ] && WCT=$(( w - 273 )); [ "$c" -gt 273 ] && CCT=$(( c - 273 ))
    # A DRAM-less controller keeps its mapping tables in borrowed laptop RAM
    # (the host memory buffer). Without it, it runs blind: slow, and the type
    # most likely to stall - the C40-K's PM991 was one.
    local hmpre hmb; hmpre=$(num "$(jq_get "$id" .hmpre)")
    if [ "$hmpre" -gt 0 ]; then
      hmb=$({ cat "$RUN_DIR/boot-dmesg.log" 2>/dev/null; dmesg 2>/dev/null; } \
            | grep -i "$CTRL: allocated .* host memory buffer" | tail -1 \
            | sed 's/.*allocated //; s/ host memory buffer.*//')
      MEMORY="no DRAM - borrows laptop RAM (asks $(( hmpre * 4 / 1024 )) MB, got ${hmb:-none})"
      ANIM_DRAM=none
      [ -n "$hmb" ] || note WARN "no DRAM of its own and no host memory given to it - it will be slow and is more likely to stall"
    else
      MEMORY="own DRAM (borrows no laptop RAM)"
      ANIM_DRAM=own
    fi
  else
    local out; out=$(smartctl -i "/dev/$DISK" 2>/dev/null)
    MODEL=$(printf '%s' "$out" | awk -F: '/Device Model|Model Number/{gsub(/^ +/,"",$2);print $2;exit}')
    FW=$(printf '%s' "$out" | awk -F: '/Firmware Version/{gsub(/^ +/,"",$2);print $2;exit}')
    CHIP="not reported by SATA drives"
    MEMORY=$(printf '%s' "$out" | awk -F': ' '/SATA Version is/{print $2;exit}')
  fi
}

aer_total() {   # bdf correctable|nonfatal|fatal
  awk '/^TOTAL/{print $2; exit}' "/sys/bus/pci/devices/$1/aer_dev_$2" 2>/dev/null
}

# The drive's own counters, KEY=VALUE per line, taken before and after.
snapshot() {
  if [ "$TRAN" = nvme ]; then
    nvme smart-log "/dev/$CTRL" -o json 2>/dev/null | jq -r '
      "CW=\(.critical_warning // 0)", "TEMPK=\(.temperature // 0)",
      "MEDIA=\(.media_errors // 0)", "ERRLOG=\(.num_err_log_entries // 0)",
      "T1C=\(.thm_temp1_trans_count // 0)", "T2C=\(.thm_temp2_trans_count // 0)",
      "WARNT=\(.warning_temp_time // 0)", "CRITT=\(.critical_comp_time // 0)",
      "SPARE=\(.avail_spare // 0)", "USED=\(.percent_used // 0)",
      "UNSAFE=\(.unsafe_shutdowns // 0)", "POH=\(.power_on_hours // 0)"' 2>/dev/null
    echo "AERC=$(num "$(aer_total "$BDF" correctable)")"
    echo "AERU=$(( $(num "$(aer_total "$BDF" nonfatal)") + $(num "$(aer_total "$BDF" fatal)") ))"
  else
    smartctl -A "/dev/$DISK" 2>/dev/null | awk '
      $1==5   {print "REALLOC=" $10}  $1==187 {print "UNCORR=" $10}
      $1==188 {print "CMDTO=" $10}    $1==197 {print "PENDING=" $10}
      $1==199 {print "CRC=" $10}'
  fi
}

delta() { echo $(( $(num "$(kv "$1" "$POST")") - $(num "$(kv "$1" "$PRE")") )); }

# ---------------------------------------------------------------- the load
draw_load() {   # elapsed temp link
  tui_frame "Controller check - /dev/$DISK" "Q = stop"
  tui_kv 6  "Controller chip" "$CHIP"
  tui_kv 7  "Drive"           "$MODEL   firmware $FW"
  tui_kv 8  "Memory"          "$MEMORY"
  tui_line 10 "Working the controller: 4 KB random reads, 128 at once - read only, data is safe." muted
  tui_kv 12 "Time"            "$1 of $LOAD_S s"
  tui_kv 13 "Temperature"     "$( [ "$2" -ge 0 ] 2>/dev/null && echo "$2 C now, $PEAK C peak${WCT:+ (warning at $WCT C)}" || echo "not reported")"
  [ -n "$3" ] && tui_kv 14 "PCIe link" "$3" "$( [ "$LINK_DROP" = 1 ] && echo warn || echo ok )"
  tui_kv 15 "Kernel errors"   "$KERR" "$( [ "$KERR" -gt 0 ] && echo err || echo ok )"
  tui_bar 22 $(( $1 * 100 / LOAD_S ))
  tui_flush
}

run_load() {
  local t0 el temp link mark
  mark=$(dmesg_mark); rm -f "$FIO_JSON"
  tui_anim_live ctrl 2 3 "$ANIM_DRAM"      # the load, playing while it runs
  fio --name=ctrl --filename="/dev/$DISK" --readonly --rw=randread --bs=4k \
      --iodepth=32 --numjobs=4 --direct=1 --ioengine=libaio --time_based \
      --runtime="$LOAD_S" --group_reporting --randrepeat=0 --norandommap \
      --percentile_list=50:99:99.9 --output-format=json --output="$FIO_JSON" \
      >/dev/null 2>"$RUN_DIR/ctrl-fio.err" &
  local fio_pid=$!
  t0=$(date +%s); PEAK=-1; LINK_FIRST=""; LINK_DROP=0; KERR=0; VANISHED=0
  while kill -0 "$fio_pid" 2>/dev/null; do
    el=$(( $(date +%s) - t0 ))
    temp=$(disk_temp_c "$DISK")
    [ "$temp" -gt "$PEAK" ] 2>/dev/null && PEAK=$temp
    link=""
    if [ -n "$BDF" ]; then
      link="PCIe $(pcie_gen "$(cat "/sys/bus/pci/devices/$BDF/current_link_speed" 2>/dev/null)") x$(cat "/sys/bus/pci/devices/$BDF/current_link_width" 2>/dev/null)"
      if [ -z "$LINK_FIRST" ]; then
        LINK_FIRST=$link
        pcie_link "$BDF"                  # against what both ends can do
      elif [ "$link" != "$LINK_FIRST" ]; then
        LINK_DROP=1; LINK_LOW=$link
      fi
    fi
    KERR=$(dmesg_since "$mark" | grep -ciE "$KERR_RE")
    disk_alive "$DISK" || VANISHED=1
    draw_load "$el" "$temp" "$link"
    tui_wait_abort 2 && { kill "$fio_pid" 2>/dev/null; ABORTED=1; break; }
  done
  wait "$fio_pid" 2>/dev/null
  KLOG=$(dmesg_since "$mark" | grep -iE "$KERR_RE" | tail -4 | sed -E 's/^\[[^]]*\] *//')
  IOPS=$(jq -r '.jobs[0].read.iops // 0 | floor' "$FIO_JSON" 2>/dev/null)
  FERR=$(jq -r '.jobs[0].error // 0' "$FIO_JSON" 2>/dev/null)
  P99=$(jq -r '.jobs[0].read.clat_ns.percentile["99.000000"] // 0' "$FIO_JSON" 2>/dev/null)
  P999=$(jq -r '.jobs[0].read.clat_ns.percentile["99.900000"] // 0' "$FIO_JSON" 2>/dev/null)
  MAXNS=$(jq -r '.jobs[0].read.clat_ns.max // 0' "$FIO_JSON" 2>/dev/null)
  IOPS=$(num "$IOPS"); FERR=$(num "$FERR")
}

# ---------------------------------------------------------------- heavy
# Ten minutes of full load in 10 s slices, then two minutes' rest and one
# more slice. It separates the two things a throttling drive can be: a
# controller protecting itself from poor cooling (it slows, keeps working,
# and is back to full speed once cool) and a failing one (errors, resets, or
# a speed that does not come back). Reads only, like the standard check.
HEAVY_S=${DIAG_CTRL_HEAVY:-600}; COOL_S=120
CURVE=$RUN_DIR/ctrl-curve                 # elapsed-s MB/s IOPS temp-C, per slice

heavy_slice() {   # -> "bytes/s iops errors max-latency-ns" for one 10 s slice
  fio --output-format=json --output="$FIO_JSON" --filename="/dev/$DISK" --readonly \
      --direct=1 --ioengine=libaio --time_based --runtime=10 --randrepeat=0 --norandommap \
      --name=rand --rw=randread --bs=4k --iodepth=32 --numjobs=4 \
      --name=seq --rw=read --bs=128k --iodepth=16 --numjobs=2 \
      --offset=$(( RANDOM % 80 ))% --offset_increment=10% \
      >/dev/null 2>>"$RUN_DIR/ctrl-fio.err" || { echo "0 0 1 0"; return; }
  jq -r '"\([.jobs[].read.bw_bytes] | add | floor) \([.jobs[].read.iops] | add | floor) \([.jobs[].error] | add) \([.jobs[].read.clat_ns.max] | max | floor)"' \
    "$FIO_JSON" 2>/dev/null || echo "0 0 1 0"
}

draw_heavy() {   # elapsed MB/s percent-of-start temp link
  tui_frame "Controller check, heavy - /dev/$DISK" "Q = stop"
  tui_kv 6  "Controller chip" "$CHIP"
  tui_line 8 "Full load for $(( HEAVY_S / 60 )) minutes: random and sequential reads together - read only, data is safe." muted
  tui_kv 10 "Time"        "$(( $1 / 60 )) min $(( $1 % 60 )) s of $(( HEAVY_S / 60 )) min"
  tui_kv 11 "Speed now"   "$2 MB/s  ($3% of its starting speed)" "$( [ "$3" -lt 60 ] && echo warn || echo ok )"
  tui_kv 12 "Temperature" "$( [ "$4" -ge 0 ] 2>/dev/null && echo "$4 C now, $PEAK C peak${WCT:+ (warning at $WCT C)}" || echo "not reported")"
  [ -n "$5" ] && tui_kv 13 "PCIe link" "$5" "$( [ "$LINK_DROP" = 1 ] && echo warn || echo ok )"
  tui_kv 14 "Kernel errors" "$KERR" "$( [ "$KERR" -gt 0 ] && echo err || echo ok )"
  tui_bar 22 $(( $1 * 100 / HEAVY_S ))
  tui_flush
}

run_heavy() {
  local t0 el bw iops err mx temp mark n=0 mbps pct link
  mark=$(dmesg_mark); : > "$CURVE"
  tui_anim_live ctrl 2 3 "$ANIM_DRAM"
  t0=$(date +%s); PEAK=-1; BASE=0; MINPCT=100; SLOW_S=0; KERR=0; VANISHED=0
  FERR=0; MAXNS=0; IOPS=0; LINK_FIRST=""; LINK_DROP=0
  while [ $(( $(date +%s) - t0 )) -lt "$HEAVY_S" ]; do
    read -r bw iops err mx <<< "$(heavy_slice)"
    n=$((n+1)); el=$(( $(date +%s) - t0 )); mbps=$(( $(num "$bw") / 1000000 ))
    [ "$(num "$err")" -gt 0 ] && FERR=$(( FERR + err ))
    [ "$(num "$mx")" -gt "$MAXNS" ] && MAXNS=$mx
    [ "$(num "$iops")" -gt "$IOPS" ] && IOPS=$iops
    temp=$(disk_temp_c "$DISK"); [ "$temp" -gt "$PEAK" ] 2>/dev/null && PEAK=$temp
    [ $n -eq 1 ] && START_T=$temp
    [ $n -le 3 ] && BASE=$(( (BASE * (n - 1) + mbps) / n ))     # the cool, fresh start
    pct=100; [ "$BASE" -gt 0 ] && pct=$(( mbps * 100 / BASE ))
    if [ $n -gt 3 ]; then
      [ "$pct" -lt "$MINPCT" ] && MINPCT=$pct
      [ "$pct" -lt 20 ] && SLOW_S=$(( SLOW_S + 10 ))
    fi
    link=""
    if [ -n "$BDF" ]; then
      link="PCIe $(pcie_gen "$(cat "/sys/bus/pci/devices/$BDF/current_link_speed" 2>/dev/null)") x$(cat "/sys/bus/pci/devices/$BDF/current_link_width" 2>/dev/null)"
      if [ -z "$LINK_FIRST" ]; then LINK_FIRST=$link; pcie_link "$BDF"
      elif [ "$link" != "$LINK_FIRST" ]; then LINK_DROP=1; LINK_LOW=$link; fi
    fi
    printf '%d %d %d %d\n' "$el" "$mbps" "$(num "$iops")" "$temp" >> "$CURVE"
    KERR=$(dmesg_since "$mark" | grep -ciE "$KERR_RE")
    disk_alive "$DISK" || { VANISHED=1; break; }
    draw_heavy "$el" "$mbps" "$pct" "$temp" "$link"
    tui_wait_abort 0 && { ABORTED=1; break; }
  done
  KLOG=$(dmesg_since "$mark" | grep -iE "$KERR_RE" | tail -4 | sed -E 's/^\[[^]]*\] *//')
}

run_cool() {
  local t=0 bw iops err mx
  RECOVER_PCT=-1
  tui_anim_live ctrl 4 4 "$ANIM_DRAM"        # idle: the robots rest
  while [ $t -lt $COOL_S ]; do
    tui_frame "Controller check, heavy - resting" "Q = stop"
    tui_line 6 "Two minutes' rest, then one more burst: does full speed come back once it is cool?" muted
    tui_kv 9  "Rest" "$t of $COOL_S s"
    tui_kv 10 "Temperature" "$(disk_temp_c "$DISK") C   (peak was $PEAK C)"
    tui_bar 22 $(( t * 100 / COOL_S )); tui_flush
    tui_wait_abort 5 && { ABORTED=1; return; }
    t=$((t + 5))
  done
  COOL_TEMP=$(disk_temp_c "$DISK")
  tui_frame "Controller check, heavy - one more burst" "Q = stop"
  tui_kv 9 "After resting" "$COOL_TEMP C - ten seconds of full load again"; tui_flush
  tui_anim_live ctrl 2 2 "$ANIM_DRAM"
  read -r bw iops err mx <<< "$(heavy_slice)"
  [ "$(num "$err")" -gt 0 ] && FERR=$(( FERR + err ))
  [ "$BASE" -gt 0 ] && RECOVER_PCT=$(( $(num "$bw") / 1000000 * 100 / BASE ))
}

# ---------------------------------------------------------------- waking
# Linux lets an NVMe drive drop into deeper sleep states on its own after a
# moment of idle (APST). A controller that wakes slowly - or not at all - is
# the drive that "disappears" or freezes the machine; a test that keeps it
# busy never sees it. So: leave it idle for longer and longer, then time the
# very next read.
run_wake() {
  WAKES=(); WAKE_MAX=-1; WAKE_NOTE=""
  [ "$TRAN" = nvme ] || { WAKE_NOTE="not checked on SATA drives"; return; }
  [ "$APSTA" = 1 ] || { WAKE_NOTE="this drive has no automatic power saving (APST)"; return; }
  grep -q 'nvme_core.default_ps_max_latency_us=0' /proc/cmdline \
    && { WAKE_NOTE="power saving was turned off by the boot menu entry"; return; }
  local v; v=$(nvme get-feature "/dev/$CTRL" -f 0x0c 2>/dev/null | sed -n 's/.*Current value: *\(0x[0-9a-fA-F]*\).*/\1/p')
  [ -n "$v" ] && [ $(( v & 1 )) = 0 ] && { WAKE_NOTE="power saving (APST) is switched off for this drive"; return; }
  local mark gap t0 t1 ms blocks off
  mark=$(dmesg_mark)
  tui_anim_live ctrl 4 4 "$ANIM_DRAM"
  blocks=$(( $(disk_bytes "$DISK") / 4096 )); [ "$blocks" -gt 0 ] || return
  for gap in 1 2 4 8; do
    tui_frame "Controller check - waking from power saving" "Q = stop"
    tui_line 6 "Leaving the drive idle so it can sleep, then timing the next read." muted
    local row=8 w
    for w in "${WAKES[@]}"; do tui_line $row "$w"; row=$((row+1)); done
    tui_line $row "Idle for $gap s..." muted
    tui_flush
    tui_wait_abort "$gap" && { ABORTED=1; break; }
    off=$(( (RANDOM * 32768 + RANDOM) % blocks ))
    t0=$(date +%s%N)
    if ! dd if="/dev/$DISK" of=/dev/null bs=4096 count=1 skip="$off" iflag=direct status=none 2>/dev/null; then
      note FAIL "a read after $gap s of idle failed - the drive did not wake up properly"; break
    fi
    t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 ))
    WAKES+=("after $gap s idle: answered in $ms ms")
    [ "$ms" -gt "$WAKE_MAX" ] && WAKE_MAX=$ms
  done
  local kerr limit
  kerr=$(dmesg_since "$mark" | grep -ciE "$KERR_RE")
  [ "$kerr" -gt 0 ] && note FAIL "the drive had to be reset after waking from power saving"
  limit=$(( MAXWAKE_US * 3 / 1000 )); [ "$limit" -lt 100 ] && limit=100
  [ "$WAKE_MAX" -gt "$limit" ] && note WARN "slow to wake from power saving: $WAKE_MAX ms (it promises about $(( MAXWAKE_US / 1000 )) ms) - the kind of drive that vanishes or freezes"
}

# ---------------------------------------------------------------- verdict
judge() {
  local d floor maxms
  [ "$VANISHED" = 1 ] && note FAIL "the drive dropped off the bus during the test"
  [ "$FERR" -ne 0 ] && note FAIL "reads failed with an I/O error ($FERR)"
  [ "$KERR" -gt 0 ] && note FAIL "the controller stopped answering and was reset ($KERR kernel messages)"
  if [ "$TRAN" = nvme ]; then
    local cw; cw=$(num "$(kv CW "$POST")")
    [ $(( cw & 1 )) != 0 ]  && note FAIL "spare blocks below the safe limit - the flash is wearing out"
    [ $(( cw & 4 )) != 0 ]  && note FAIL "the drive reports its own reliability as degraded"
    [ $(( cw & 8 )) != 0 ]  && note FAIL "the drive has switched itself to read-only"
    [ $(( cw & 16 )) != 0 ] && note FAIL "the drive's power-loss backup has failed"
    [ $(( cw & 2 )) != 0 ]  && note WARN "the drive flags its temperature as out of range"
    d=$(delta MEDIA);  [ "$d" -gt 0 ] && note FAIL "$d new media / data-integrity error(s) during the test"
    d=$(delta AERU);   [ "$d" -gt 0 ] && note FAIL "$d PCIe error(s) the link could not correct"
    d=$(delta AERC);   [ "$d" -gt 0 ] && note WARN "the PCIe link had to retry $d time(s) - reseat the drive, clean the M.2 contacts"
    d=$(delta ERRLOG); [ "$d" -gt 0 ] && note WARN "the controller logged $d new error(s) while under load"
    d=$(( $(delta T1C) + $(delta T2C) ))
    THROTTLED=$d
    [ "$d" -gt 0 ] && [ "$MODE" != heavy ] && note WARN "it throttled from heat within a minute of reading - run the Heavy check to tell a cooling problem from a faulty controller"
    [ -n "$CCT" ] && [ "$PEAK" -ge "$CCT" ] && note FAIL "it reached its critical temperature ($PEAK C)"
    [ -n "$WCT" ] && [ "$PEAK" -ge "$WCT" ] && [ "$PEAK" -lt "${CCT:-999}" ] && note WARN "it reached its warning temperature ($PEAK C)"
    [ "$LINK_DROP" = 1 ] && note WARN "the PCIe link fell from $LINK_FIRST to $LINK_LOW under load"
    [ "$PCIE_TONE" = warn ] && note WARN "$PCIE_NOTE"
    [ "$(num "$(kv USED "$POST")")" -ge 90 ] && note WARN "$(kv USED "$POST")% of its rated life is used"
    floor=20000
  else
    d=$(delta CMDTO);   [ "$d" -gt 0 ] && note FAIL "$d command time-out(s) during the test"
    d=$(delta UNCORR);  [ "$d" -gt 0 ] && note FAIL "$d unreadable block(s) during the test"
    d=$(delta PENDING); [ "$d" -gt 0 ] && note FAIL "$d new sector(s) waiting to be replaced"
    d=$(delta CRC);     [ "$d" -gt 0 ] && note WARN "$d SATA link error(s) - check the cable and connector"
    floor=5000
  fi
  if [ "$MODE" = heavy ]; then
    [ "$SLOW_S" -ge 60 ] && note FAIL "under sustained load it fell below 20% of its starting speed for $SLOW_S s"
    [ "$RECOVER_PCT" -ge 0 ] && [ "$RECOVER_PCT" -lt 70 ] \
      && note FAIL "still slow after two minutes' rest ($RECOVER_PCT% of its starting speed) - suspect the controller"
    # Heat is blamed only when there is heat: the drive's own throttle
    # counters moved, it came within 5 C of its warning limit, or it rose
    # 20 C over the run. (In the VM the speed swung to 13% at a flat 49 C and
    # the first version still said "the problem is cooling".)
    local hot=0
    [ "${THROTTLED:-0}" -gt 0 ] && hot=1
    [ -n "$WCT" ] && [ "$PEAK" -ge $(( WCT - 5 )) ] && hot=1
    [ "${START_T:--1}" -ge 0 ] && [ $(( PEAK - START_T )) -ge 20 ] && hot=1
    if ! printf '%s\n' "${FINDINGS[@]}" | grep -q '^FAIL|'; then
      if [ "$hot" = 1 ] && { [ "${THROTTLED:-0}" -gt 0 ] || [ "$MINPCT" -lt 60 ]; } && [ "$RECOVER_PCT" -ge 70 ]; then
        note WARN "slows itself when hot (down to $MINPCT% of its starting speed, peak $PEAK C) but keeps working and is back to full speed after resting - the controller is protecting itself, not failing: check its thermal pad, heatsink and airflow"
      elif [ "$hot" = 0 ] && [ "$MINPCT" -lt 60 ]; then
        note WARN "its speed fell to $MINPCT% of the start without getting hot (peak $PEAK C) - not a cooling problem; if it happens again, suspect the controller or its firmware"
      fi
    fi
  fi
  maxms=$(( $(num "${MAXNS%.*}") / 1000000 ))
  [ "$maxms" -ge 500 ] && note WARN "it froze for $maxms ms at least once under load"
  [ "$IOPS" -gt 0 ] && [ "$IOPS" -lt "$floor" ] && note WARN "very slow for this kind of drive: $IOPS reads a second"
  return 0
}

report() {   # state
  local f
  rsection "SSD CONTROLLER CHECK -- /dev/$DISK"
  rsilent "Controller chip : $CHIP"
  rsilent "Drive           : $MODEL   firmware $FW"
  rsilent "Memory          : $MEMORY"
  [ -n "$PCIE_NOW" ] && rsilent "PCIe link       : $PCIE_NOW${PCIE_DRIVE:+   drive $PCIE_DRIVE}${PCIE_SLOT:+, slot $PCIE_SLOT}"
  if [ "$MODE" = heavy ]; then
    rsilent "Load            : heavy - 4 KB random (32 x 4) + 128 KB sequential (16 x 2) reads, $(( HEAVY_S / 60 )) min, read only"
    rsilent "Speed           : started at $BASE MB/s, lowest $MINPCT% of that, $SLOW_S s below 20%"
    rsilent "After 2 min rest: $( [ "$RECOVER_PCT" -ge 0 ] && echo "$RECOVER_PCT% of the starting speed, at ${COOL_TEMP} C" || echo "not measured")"
    rsilent "Worst stall     : $(ns_ms "$MAXNS") ms"
    rsilent "Each minute (MB/s, temperature):"
    awk -v last=$(( HEAVY_S / 60 - 1 )) '{m=int($1/60); if(m>last)m=last; s[m]+=$2; n[m]++; if($4>t[m])t[m]=$4} END{for(i=0;i in n;i++) printf "  minute %2d: %5d MB/s  %3d C\n", i+1, s[i]/n[i], t[i]}' \
      "$CURVE" >> "$REPORT_TXT"
  else
    rsilent "Load            : 4 KB random reads, queue 32 x 4 jobs, $LOAD_S s, read only"
    rsilent "Reads a second  : $IOPS"
    rsilent "Latency         : 99% under $(ns_ms "$P99") ms, 99.9% under $(ns_ms "$P999") ms, worst $(ns_ms "$MAXNS") ms"
  fi
  rsilent "Temperature     : $(kv TEMPK "$PRE" | awk '{if($1>273)print $1-273" C at start"}')  peak ${PEAK} C${WCT:+  (warning $WCT C, critical $CCT C)}"
  if [ ${#WAKES[@]} -gt 0 ]; then
    for f in "${WAKES[@]}"; do rsilent "Wake-up         : $f"; done
  else
    rsilent "Wake-up         : ${WAKE_NOTE:-not checked}"
  fi
  [ "$TRAN" = nvme ] && rsilent "Lifetime        : $(kv POH "$POST") hours, $(kv USED "$POST")% life used, $(kv UNSAFE "$POST") unsafe shutdowns, $(kv ERRLOG "$POST") logged errors"
  [ -n "$CONCL" ] && rsilent "Conclusion      : $CONCL"
  for f in "${FINDINGS[@]}"; do rsilent "  ${f%%|*}: ${f#*|}"; done
  [ -n "$KLOG" ] && printf '%s\n' "$KLOG" | sed 's/^/  log: /' >> "$REPORT_TXT"
  case "$1" in
    PASS) rsilent "RESULT: PASS -- the controller handled the load cleanly"; set_kv DISK_CTRL "PASSED" ;;
    WARN) rsilent "RESULT: WARN -- works, with ${#FINDINGS[@]} point(s) to look at"; set_kv DISK_CTRL "WARN (${#FINDINGS[@]})" ;;
    FAIL) rsilent "RESULT: FAIL -- the controller misbehaved"; set_kv DISK_CTRL "FAILED" ;;
    *)    rsilent "RESULT: NOT TESTED -- stopped by the operator"; set_kv DISK_CTRL "NOT TESTED (stopped)" ;;
  esac
}

show_result() {   # state
  local row=9 f sev
  tui_frame "Controller check - /dev/$DISK" "Enter to go back"
  case "$1" in
    PASS) tui_badge 6 PASS "${CONCL:-the controller handled the load cleanly}" ;;
    WARN) tui_badge 6 PARTIAL "${CONCL:-works - with points to look at}" ;;
    FAIL) tui_badge 6 FAIL "${CONCL:-the controller misbehaved}" ;;
    *)    tui_badge 6 UNKNOWN "stopped before the end" ;;
  esac
  tui_kv $row "Controller chip" "$CHIP"; row=$((row+1))
  tui_kv $row "Memory" "$MEMORY"; row=$((row+1))
  [ -n "$PCIE_NOW" ] && { tui_kv $row "PCIe link" "$PCIE_NOW" "$PCIE_TONE"; row=$((row+1)); }
  if [ "$MODE" = heavy ]; then
    tui_kv $row "Sustained" "started $BASE MB/s, lowest $MINPCT% of that" "$( [ "$MINPCT" -lt 60 ] && echo warn || echo ok )"; row=$((row+1))
    tui_kv $row "After resting" "$( [ "$RECOVER_PCT" -ge 0 ] && echo "$RECOVER_PCT% of its starting speed" || echo "not measured")" \
      "$( [ "$RECOVER_PCT" -ge 70 ] && echo ok || echo warn )"; row=$((row+1))
  else
    tui_kv $row "Under load" "$IOPS reads/s, worst $(ns_ms "$MAXNS") ms"; row=$((row+1))
  fi
  tui_kv $row "Temperature" "peak $PEAK C${WCT:+ (warning $WCT C)}"; row=$((row+1))
  if [ "$WAKE_MAX" -ge 0 ] 2>/dev/null; then tui_kv $row "Wake-up" "slowest $WAKE_MAX ms"
  else tui_kv $row "Wake-up" "${WAKE_NOTE:-not checked}" muted; fi
  row=$((row+2))
  for f in "${FINDINGS[@]}"; do
    [ $row -gt 19 ] && break
    sev=${f%%|*}
    row=$(tui_para $row "${f#*|}" "$([ "$sev" = FAIL ] && echo err || echo warn)")
  done
  tui_flush; tui_anykey
}

# ---------------------------------------------------------------- run
command -v fio >/dev/null || { tui_msg "fio missing" "The load generator (fio) is not on this stick."; exit 0; }
pick_ssd || exit 0
identify
tui_menu "Controller check - /dev/$DISK" "Enter to choose, Q to go back" \
  "Standard|about 3 minutes: one minute of load, then wake-up timing" \
  "Heavy|about 13 minutes: 10 minutes of full load, rest, then again - is it the controller or its cooling?" || exit 0
MODE=std; [ "$TUI_CHOICE" = 2 ] && MODE=heavy
if [ "$MODE" = heavy ]; then
  tui_confirm "Controller check, heavy - /dev/$DISK" yes \
    "$MODEL" "Controller: $CHIP" "" \
    "About 13 minutes. Reads only - nothing on the drive is changed." \
    "1. Ten minutes of full load: random and sequential reads together." \
    "2. Two minutes' rest, then one more burst - does full speed come back?" \
    "3. The drive is left idle and woken again, timing each wake-up." "" \
    "A drive that slows when hot but recovers has a cooling problem;" \
    "errors, resets, or speed that does not come back point at the controller." \
    "" "Start?" || exit 0
else
  tui_confirm "Controller check - /dev/$DISK" yes \
    "$MODEL" "Controller: $CHIP" "" \
    "About three minutes. Reads only - nothing on the drive is changed." \
    "1. One minute of heavy random reads, watching heat, errors and the PCIe link." \
    "2. The drive is left idle and woken again, timing each wake-up." \
    "" "Start?" || exit 0
fi
ABORTED=0; WAKES=(); WAKE_MAX=-1; PCIE_NOW=""; PCIE_TONE=ok; LINK_LOW=""
RECOVER_PCT=-1; MINPCT=100; SLOW_S=0; THROTTLED=0; BASE=0; P99=0; P999=0
PRE=$(snapshot)
if [ "$MODE" = heavy ]; then
  run_heavy
  [ "$ABORTED" = 0 ] && run_cool
else
  run_load
fi
[ "$ABORTED" = 0 ] && run_wake
POST=$(snapshot)
if [ "$ABORTED" = 1 ]; then STATE=STOPPED
else
  judge
  STATE=PASS
  printf '%s\n' "${FINDINGS[@]}" | grep -q '^WARN|' && STATE=WARN
  printf '%s\n' "${FINDINGS[@]}" | grep -q '^FAIL|' && STATE=FAIL
fi
# Heavy mode exists to answer one question; say the answer in words.
CONCL=""
if [ "$MODE" = heavy ]; then
  case "$STATE" in
    PASS) CONCL="controller OK - $(( HEAVY_S / 60 )) minutes of full load, no errors, no slowdown" ;;
    WARN) printf '%s\n' "${FINDINGS[@]}" | grep -q 'protecting itself' \
            && CONCL="controller OK - it slows when hot and recovers: the problem is cooling" ;;
    FAIL) CONCL="fails under sustained load - see why below" ;;
  esac
fi
report "$STATE"
show_result "$STATE"
exit 0
