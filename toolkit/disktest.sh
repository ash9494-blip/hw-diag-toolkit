#!/bin/bash
# HDD/SSD read-write test -- CrystalDiskMark-style profiles via fio
. /opt/diag/lib.sh
. /opt/diag/tui.sh

RUNTIME=${DIAG_DISK_RUNTIME:-5}      # seconds of measurement per pass (CDM uses 5)
TMPJSON=$RUN_DIR/fio.json
TEST_SIZE=${DIAG_DISK_SIZE:-$(setting_get disk_size 1G)}
RUNS=1

PROF_NAME=("SEQ1M Q8T1" "SEQ1M Q1T1" "RND4K Q32T1" "RND4K Q1T1")
PROF_SEQ=(1 1 0 0)
PROF_BS=(1M 1M 4k 4k)
PROF_QD=(8 1 32 1)

# ---------------------------------------------------------------- fio
mbps() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1000000}'; }

fio_pass() {  # rw bs qd target size -> "bytes_per_sec iops" or ERR
  local rw=$1 bs=$2 qd=$3 target=$4 size=$5
  fio --output-format=json --output="$TMPJSON" \
      --name=diag --rw="$rw" --bs="$bs" --iodepth="$qd" --numjobs=1 \
      --direct=1 --ioengine=libaio --filename="$target" --size="$size" \
      --runtime="$RUNTIME" --time_based --ramp_time=1 --group_reporting \
      --randrepeat=0 --norandommap --refill_buffers >/dev/null 2>"$RUN_DIR/fio.err" || { echo ERR; return 1; }
  local key=read
  case "$rw" in write|randwrite) key=write ;; esac
  jq -r ".jobs[0].${key} | \"\(.bw_bytes) \(.iops)\"" "$TMPJSON" 2>/dev/null
}

# ---------------------------------------------------------------- options
pick_size() {
  tui_menu "Test size" "the region of the drive the test works over - bigger is harder on an SSD" \
    "1 GB|quick, fits inside most SSD cache" \
    "2 GB|" "4 GB|" "8 GB|" \
    "16 GB|past the SLC cache on most consumer SSDs" \
    "32 GB|" \
    "64 GB|sustained-write behaviour, slow drives take a while" || return 1
  case "$TUI_CHOICE" in
    1) TEST_SIZE=1G ;; 2) TEST_SIZE=2G ;; 3) TEST_SIZE=4G ;; 4) TEST_SIZE=8G ;;
    5) TEST_SIZE=16G ;; 6) TEST_SIZE=32G ;; 7) TEST_SIZE=64G ;;
  esac
  SIZE_GB=${TEST_SIZE%G}
  return 0
}

pick_runs() {
  tui_menu "How many runs per profile?" "the best result of the runs is reported, the same way CrystalDiskMark does" \
    "1 run|fastest" "2 runs|" "3 runs|" "4 runs|" "5 runs|CrystalDiskMark default" \
    "6 runs|" "7 runs|" "8 runs|" "9 runs|most repeatable" || return 1
  RUNS=$TUI_CHOICE
  return 0
}

# $1 = 1 when the write passes will run too
show_plan() {
  local dowrite=$1 target=$2 mode=$3
  local passes=$(( 4 * (dowrite == 1 ? 2 : 1) * RUNS ))
  local est=$(( passes * (RUNTIME + 3) ))
  tui_confirm "Ready to start" yes \
    "Target        $target" \
    "Mode          $mode" \
    "Test size     $TEST_SIZE per profile" \
    "Runs          $RUNS  (best result reported)" \
    "Measurement   ${RUNTIME}s per pass, direct I/O" \
    "" \
    "$passes passes, roughly $(secs_ms $est) in total." \
    ""
}

# ---------------------------------------------------------------- benchmark
draw_table_head() {
  tui_thead 6 "Profile" "Read MB/s" "Read IOPS" "Write MB/s" "Wr. IOPS"
}

draw_row() {  # idx rmb riops wmb wiops
  tui_trow $(( 7 + $1 )) "${PROF_NAME[$1]}" "$2" "$3" "$4" "$5"
}

# run_cdm <target> <dowrite 0|1> <mode label>
# DEV, when set, is the kernel name of the drive under test (sda, nvme0n1) and
# enables liveness and temperature monitoring.
run_cdm() {
  local target=$1 dowrite=$2 what=$3
  local dropped=0 maxtemp=-1
  local total=$(( 4 * (dowrite == 1 ? 2 : 1) * RUNS )) done=0
  local i run res bmb biops wbmb wbiops rmb riops
  local -a RB RI WB WI
  local aborted=0

  tui_frame "Disk benchmark - $what" "Q = stop after the current pass"
  draw_table_head
  for i in 0 1 2 3; do
    RB[$i]=0; RI[$i]=0; WB[$i]=0; WI[$i]=0
    draw_row "$i" "-" "-" "-" "-"
  done

  for i in 0 1 2 3; do
    local rrw wrw
    if [ "${PROF_SEQ[$i]}" = 1 ]; then rrw=read; wrw=write; else rrw=randread; wrw=randwrite; fi
    for run in $(seq 1 "$RUNS"); do
      tui_line 13 "${PROF_NAME[$i]}  -  read pass, run $run of $RUNS" "$WRN"
      tui_bar 15 $(( done * 100 / total ))
      res=$(fio_pass "$rrw" "${PROF_BS[$i]}" "${PROF_QD[$i]}" "$target" "$TEST_SIZE")
      done=$((done+1))
      if [ "$res" != ERR ] && [ -n "$res" ]; then
        bmb=${res%% *}; biops=${res##* }
        awk -v a="$bmb" -v b="${RB[$i]}" 'BEGIN{exit !(a>b)}' && { RB[$i]=$bmb; RI[$i]=$biops; }
      fi
      draw_row "$i" "$(mbps "${RB[$i]}")" "$(printf '%.0f' "${RI[$i]}")" \
               "$([ "$dowrite" = 1 ] && [ "${WB[$i]}" != 0 ] && mbps "${WB[$i]}" || echo '-')" \
               "$([ "$dowrite" = 1 ] && [ "${WI[$i]}" != 0 ] && printf '%.0f' "${WI[$i]}" || echo '-')"
      if [ "$dowrite" = 1 ]; then
        tui_line 13 "${PROF_NAME[$i]}  -  write pass, run $run of $RUNS" "$WRN"
        tui_bar 15 $(( done * 100 / total ))
        res=$(fio_pass "$wrw" "${PROF_BS[$i]}" "${PROF_QD[$i]}" "$target" "$TEST_SIZE")
        done=$((done+1))
        if [ "$res" != ERR ] && [ -n "$res" ]; then
          wbmb=${res%% *}; wbiops=${res##* }
          awk -v a="$wbmb" -v b="${WB[$i]}" 'BEGIN{exit !(a>b)}' && { WB[$i]=$wbmb; WI[$i]=$wbiops; }
        fi
        draw_row "$i" "$(mbps "${RB[$i]}")" "$(printf '%.0f' "${RI[$i]}")" \
                 "$(mbps "${WB[$i]}")" "$(printf '%.0f' "${WI[$i]}")"
      fi
      if [ -n "$DEV" ]; then
        local dt; dt=$(disk_temp_c "$DEV")
        if [ "$dt" -gt 0 ]; then
          [ "$dt" -gt "$maxtemp" ] && maxtemp=$dt
          tui_kv 11 "Drive temperature" "$(printf '%d C   (peak %d C)' "$dt" "$maxtemp")" \
            "$([ "$dt" -ge 70 ] && echo "$ERR$B" || { [ "$dt" -ge 60 ] && echo "$WRN" || echo "$OKC"; })"
        fi
        if ! disk_alive "$DEV"; then dropped=1; break 2; fi
      fi
      if [ -t 0 ]; then
        IFS= read -rsn1 -t 0.01 k 2>/dev/null
        case "$k" in q|Q) aborted=1; break 2 ;; esac
      fi
    done
  done
  if [ "$dropped" = 1 ]; then
    tui_line 13 "DRIVE DISAPPEARED - /dev/$DEV stopped responding mid-test" "$ERR$B"
  else
    tui_bar 15 100
    tui_line 13 "$([ "$aborted" = 1 ] && echo 'Stopped by operator.' || echo 'Finished.')" "$OKC"
  fi

  # ---- report ----
  rsilent ""
  rsilent "Target      : $target ($what)"
  rsilent "Test size   : $TEST_SIZE per profile, $RUNS run(s), ${RUNTIME}s per pass, direct I/O"
  [ "$aborted" = 1 ] && rsilent "NOTE        : stopped early by the operator, table may be incomplete"
  rsilent ""
  rsilent "$(printf '  %-14s %11s %10s   %11s %10s' Profile 'Read MB/s' 'Read IOPS' 'Write MB/s' 'Wr. IOPS')"
  rsilent "$(printf '  %-14s %11s %10s   %11s %10s' -------------- ----------- ---------- ----------- ----------)"
  for i in 0 1 2 3; do
    local rm im wm iw
    rm=$(mbps "${RB[$i]}"); im=$(printf '%.0f' "${RI[$i]}")
    if [ "$dowrite" = 1 ]; then wm=$(mbps "${WB[$i]}"); iw=$(printf '%.0f' "${WI[$i]}"); else wm="-"; iw="-"; fi
    rsilent "$(printf '  %-14s %11s %10s   %11s %10s' "${PROF_NAME[$i]}" "$rm" "$im" "$wm" "$iw")"
  done
  set_kv DISK_SEQ1M_Q8T1_READ_MBPS "$(mbps "${RB[0]}")"
  set_kv DISK_RND4K_Q32T1_READ_IOPS "$(printf '%.0f' "${RI[2]}")"
  if [ "$dowrite" = 1 ]; then
    set_kv DISK_SEQ1M_Q8T1_WRITE_MBPS "$(mbps "${WB[0]}")"
    set_kv DISK_RND4K_Q32T1_WRITE_IOPS "$(printf '%.0f' "${WI[2]}")"
  fi
  [ "$maxtemp" -gt 0 ] && rsilent "Peak drive temp : ${maxtemp} C"
  if [ "$dropped" = 1 ]; then
    rsilent ""
    rsilent "RESULT: FAIL -- the drive stopped responding during the test."
    rsilent "The block device went to zero size, meaning the controller dropped off the bus."
    set_kv DISK_RESULT "FAIL (drive dropped off the bus)"
    capture_dmesg 80
    drive_lost_screen
    return
  fi
  # A benchmark with no verdict on it makes the reader do the judging, and the
  # numbers alone do not say whether the drive is healthy. This is deliberately
  # modest about what it proves: throughput inside the drive's cache, nothing
  # about sustained writing - that is what the install simulation is for.
  rsilent ""
  local seqr; seqr=$(mbps "${RB[0]}")
  if [ "$aborted" = 1 ]; then
    rsilent "RESULT: INCOMPLETE -- stopped early by the operator"
    set_kv DISK_RESULT "INCOMPLETE (stopped early)"
  elif awk -v v="$seqr" 'BEGIN{exit !(v+0 < 1)}'; then
    rsilent "RESULT: FAIL -- the drive returned no measurable throughput"
    set_kv DISK_RESULT "FAIL (no measurable throughput)"
  else
    rsilent "RESULT: PASS -- the drive completed every pass without dropping out"
    rsilent "Note: these are burst figures. Each pass writes for only ${RUNTIME}s, which"
    rsilent "lands inside the drive's SLC cache. For behaviour under a sustained write -"
    rsilent "what a Windows install does - run the install simulation."
    set_kv DISK_RESULT "PASS (burst benchmark, ${seqr} MB/s sequential read)"
  fi

  # A benchmark with no verdict on it makes the reader do the judging, and the
  # numbers alone do not say whether the drive is healthy. This is deliberately
  # modest about what it proves: throughput inside the drive's cache, nothing
  # about sustained writing - that is what the install simulation is for.
  rsilent ""
  local seqr; seqr=$(mbps "${RB[0]}")
  if [ "$aborted" = 1 ]; then
    rsilent "RESULT: INCOMPLETE -- stopped early by the operator"
    set_kv DISK_RESULT "INCOMPLETE (stopped early)"
  elif awk -v v="$seqr" 'BEGIN{exit !(v+0 < 1)}'; then
    rsilent "RESULT: FAIL -- the drive returned no measurable throughput"
    set_kv DISK_RESULT "FAIL (no measurable throughput)"
  else
    rsilent "RESULT: PASS -- the drive completed every pass without dropping out"
    rsilent "Note: these are burst figures. Each pass writes for only ${RUNTIME}s, which"
    rsilent "lands inside the drive's SLC cache. For behaviour under a sustained write -"
    rsilent "what a Windows install does - run the install simulation."
    set_kv DISK_RESULT "PASS (burst benchmark, ${seqr} MB/s sequential read)"
  fi

  if [ -s "$RUN_DIR/fio.err" ]; then
    tui_line 17 "fio: $(head -1 "$RUN_DIR/fio.err" | cut -c1-$((TUI_W-10)))" "$ERR"
  fi
  tui_anykey "ENTER to go back"
}

drive_lost_screen() {
  tui_frame "Drive stopped responding" "Enter to go back"
  tui_badge 6 FAIL "/dev/$DEV dropped off the bus mid-test"
  local row=8
  tui_line $row "The device node is still there but now reports zero size, so the"; row=$((row+1))
  tui_line $row "controller stopped answering. The test was stopped."; row=$((row+2))
  tui_line $row "Likely causes, most common first:" "$MUTE"; row=$((row+1))
  tui_line $row "  1. Controller hang or failed reset (often a failing drive)"; row=$((row+1))
  tui_line $row "  2. Thermal cutout - check the peak temperature above"; row=$((row+1))
  tui_line $row "  3. PCIe power-state bug (this image already works around it)"; row=$((row+2))
  tui_line $row "To recover: shut down fully, unplug the charger, hold the power" "$WRN"; row=$((row+1))
  tui_line $row "button 20-30 s, then boot. A warm reboot will not bring it back." "$WRN"; row=$((row+2))
  tui_line $row "The kernel log has been saved into the report." "$MUTE"
  tui_anykey "ENTER to go back"
}

# ---------------------------------------------------------------- pickers
pick_disk() {
  local -a names=() labels=()
  local n s r t m kind
  while read -r n s r t m; do
    [ -z "$n" ] && continue
    [ "$r" = 1 ] && kind="HDD" || kind="SSD"
    names+=("$n")
    labels+=("$(printf '/dev/%-8s %-8s %-6s %-5s %s' "$n" "$s" "$t" "$kind" "$m")")
  done < <(list_disks)
  [ ${#names[@]} -eq 0 ] && { tui_msg "No drives" "No storage devices were detected."; return 1; }
  tui_menu "Select the drive" "arrows + ENTER, Q to go back" "${labels[@]}" || return 1
  DISK=${names[$((TUI_CHOICE-1))]}
  return 0
}

pick_partition() {
  local -a names=() labels=()
  local n size fs mp
  while read -r n size fs mp; do
    case "$fs" in ntfs|vfat|exfat|ext2|ext3|ext4|btrfs|xfs) ;; *) continue ;; esac
    names+=("$n")
    labels+=("$(printf '/dev/%-9s %-9s %-7s %s' "$n" "$size" "$fs" "${mp:-not mounted}")")
  done < <(lsblk -rno NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | awk '$1 !~ /^(loop|sr|ram)/')
  [ ${#names[@]} -eq 0 ] && { tui_msg "No filesystems" "No usable filesystem was found." "Use one of the raw-device tests instead."; return 1; }
  tui_menu "Select the filesystem for the test file" "arrows + ENTER, Q to go back" "${labels[@]}" || return 1
  PART=${names[$((TUI_CHOICE-1))]}
  return 0
}

disk_busy() { lsblk -rno MOUNTPOINT "/dev/$1" 2>/dev/null | grep -q .; }

# ---------------------------------------------------------------- tests
test_read_only() {
  pick_disk || return
  pick_size || return
  pick_runs || return
  local szb; szb=$(disk_bytes "$DISK")
  if [ "$szb" -gt 0 ] && [ $(( SIZE_GB * 1000000000 )) -gt "$szb" ]; then
    tui_msg "Test size too large" "/dev/$DISK is only $(( szb / 1000000000 )) GB." "Pick a smaller test size."
    return
  fi
  show_plan 0 "/dev/$DISK  ($(lsblk -dno SIZE,MODEL "/dev/$DISK" | sed 's/  */ /g'))" "raw device, READ ONLY - data is safe" || return
  DEV=$DISK
  rsection "DISK BENCHMARK (READ ONLY) -- /dev/$DISK"
  rsilent "Drive       : /dev/$DISK  ($(lsblk -dno SIZE,MODEL "/dev/$DISK" | sed 's/  */ /g'))"
  rsilent "Mode        : raw device, READ ONLY -- nothing is written, data is safe"
  run_cdm "/dev/$DISK" 0 "raw read-only"
}

test_file_rw() {
  pick_partition || return
  pick_size || return
  pick_runs || return
  mkdir -p /mnt/disktest; umount /mnt/disktest 2>/dev/null
  if ! mount "/dev/$PART" /mnt/disktest 2>"$RUN_DIR/mnt.err"; then
    tui_msg "Cannot mount /dev/$PART" "$(head -2 "$RUN_DIR/mnt.err")" "" \
      "A Windows partition left in fast-startup or hibernation" \
      "cannot be mounted for writing."
    return
  fi
  if ! touch /mnt/disktest/.diagwrite 2>/dev/null; then
    umount /mnt/disktest
    tui_msg "Read-only filesystem" "/dev/$PART could not be mounted for writing."
    return
  fi
  rm -f /mnt/disktest/.diagwrite
  local freeg; freeg=$(df -BG --output=avail /mnt/disktest | awk 'NR==2{gsub(/G/,"");print $1}')
  if [ "$freeg" -lt $(( SIZE_GB + 1 )) ]; then
    umount /mnt/disktest
    tui_msg "Not enough free space" "/dev/$PART has ${freeg} GB free but the test needs $(( SIZE_GB + 1 )) GB." \
      "Choose a smaller test size or another partition."
    return
  fi
  show_plan 1 "/dev/$PART  (test file on the existing filesystem)" "read + write, existing data untouched" \
    || { umount /mnt/disktest; return; }
  DEV=$(lsblk -no PKNAME "/dev/$PART" 2>/dev/null | head -1)
  rsection "DISK BENCHMARK (READ + WRITE, FILE BASED) -- /dev/$PART"
  rsilent "Partition   : /dev/$PART  ($(lsblk -dno FSTYPE,SIZE "/dev/$PART" | sed 's/  */ /g'))"
  rsilent "Mode        : test file on the existing filesystem -- existing data is NOT touched"
  run_cdm "/mnt/disktest/diag_testfile.bin" 1 "file based"
  rm -f /mnt/disktest/diag_testfile.bin
  sync; umount /mnt/disktest 2>/dev/null
}

test_raw_rw() {
  pick_disk || return
  if disk_busy "$DISK"; then
    tui_msg "Drive in use" "/dev/$DISK has mounted partitions." "Unmount them before running a destructive test."
    return
  fi
  pick_size || return
  pick_runs || return
  local layout; layout=$(lsblk -no NAME,SIZE,FSTYPE,LABEL "/dev/$DISK" | head -8)
  tui_confirm "DESTRUCTIVE TEST" no \
    "This writes directly to /dev/$DISK." \
    "The partition table and every file on it will be destroyed." \
    "" \
    "$(echo "$layout" | sed -n 1p)" \
    "$(echo "$layout" | sed -n 2p)" \
    "$(echo "$layout" | sed -n 3p)" \
    "$(echo "$layout" | sed -n 4p)" \
    "" "Continue?" || return
  tui_input "Final confirmation" "Type ERASE to destroy all data on /dev/$DISK:"
  # Case-insensitive: the safeguard is typing the word deliberately, not getting
  # the Shift key right. Caps Lock now works, but a stuck one should not stop you.
  case "$(printf '%s' "$TUI_TEXT" | tr '[:lower:]' '[:upper:]')" in
    ERASE) ;;
    *) tui_msg "Cancelled" "Nothing was written."; return ;;
  esac
  show_plan 1 "/dev/$DISK" "raw device read + write - DATA DESTROYED" || return
  DEV=$DISK
  rsection "DISK BENCHMARK (RAW READ + WRITE, DESTRUCTIVE) -- /dev/$DISK"
  rsilent "Drive       : /dev/$DISK  ($(lsblk -dno SIZE,MODEL "/dev/$DISK" | sed 's/  */ /g'))"
  rsilent "Mode        : raw device read + write -- DATA DESTROYED"
  run_cdm "/dev/$DISK" 1 "raw destructive"
}

# Wear and write/erase cycles.
#
# NVMe does not report program/erase cycles directly - no standard SMART field
# carries them, and the vendor log pages that sometimes do are undocumented. So
# this works them out from what the drive does publish, and says which figures
# are measured and which are derived.
#
#   Data Units Written  x 512000 bytes  = host bytes written  (measured)
#   host bytes / capacity              = full drive writes    (derived)
#   Percentage Used                    = the drive's own wear estimate (measured)
#
# Full drive writes is the honest floor for P/E cycles: the flash always writes
# somewhat more than the host asked for (write amplification), so real cycles
# are higher - how much higher is not something any tool here can measure. Where
# the drive reports a non-zero Percentage Used, the two together give a far
# better answer: the projected total life, and therefore what is left.
wear_report() {
  local dev=$1 out=$2
  local units_w units_r pct cap_b
  # smartctl prints these as "31,964,933 [16.3 TB]". The bracket is a courtesy
  # restatement, not part of the number - stripping non-digits across the whole
  # field glued its digits on the end and made the drive look 1000x more worn
  # than it is. Cut at the bracket first, then take the digits.
  smart_int() {
    printf '%s' "$out" | awk -F: -v k="$1" '
      index($0, k) { v = substr($0, index($0, ":") + 1)
                     sub(/\[.*/, "", v); gsub(/[^0-9]/, "", v)
                     print v; exit }'
  }
  units_w=$(smart_int 'Data Units Written')
  units_r=$(smart_int 'Data Units Read')
  pct=$(smart_int 'Percentage Used')
  cap_b=$(disk_bytes "$dev")

  # SATA SSDs put the same idea in vendor attributes instead.
  if [ -z "$units_w" ]; then
    local lba_w
    lba_w=$(printf '%s' "$out" | awk '/Total_LBAs_Written|Host_Writes_32MiB|Total_Writes_GiB/{print $10; exit}')
    [ -n "$lba_w" ] && units_w=$(( lba_w / 1000 ))
  fi
  [ -z "$units_w" ] && [ -z "$pct" ] && return 0      # nothing to work with

  rsilent ""
  rsilent "--- wear and write cycles ---"

  local tb_w="" dw=""
  if [ -n "$units_w" ] && [ "$cap_b" -gt 0 ]; then
    tb_w=$(awk -v u="$units_w" 'BEGIN{printf "%.2f", u*512000/1e12}')
    dw=$(awk -v u="$units_w" -v c="$cap_b" 'BEGIN{printf "%.1f", (u*512000)/c}')
    rsilent "$(printf '%-36s %s' "Written over the drive's life"  "$tb_w TB   (measured)")"
    [ -n "$units_r" ] && rsilent "$(printf '%-36s %s' "Read over the drive's life" \
      "$(awk -v u="$units_r" 'BEGIN{printf "%.2f", u*512000/1e12}') TB   (measured)")"
    rsilent "$(printf '%-36s %s' "Equivalent full-drive writes"   "$dw   (derived)")"
    rsilent "  This is the floor for write/erase cycles per flash cell. The real"
    rsilent "  number is higher by the drive's write amplification, which is not"
    rsilent "  something any tool can read out of it."
  fi

  if [ -n "$pct" ]; then
    rsilent "$(printf '%-36s %s' "Drive's own wear estimate" "${pct}% used   (measured)")"
    if [ -n "$dw" ] && [ "$pct" -gt 0 ]; then
      # If N drive-writes consumed P% of life, the drive is rated for about
      # N*100/P drive-writes in total. This is the drive's own arithmetic
      # turned around, and it is the most useful number on the page.
      local total left
      total=$(awk -v d="$dw" -v p="$pct" 'BEGIN{printf "%.0f", d*100/p}')
      left=$(awk -v t="$total" -v d="$dw" 'BEGIN{printf "%.0f", t-d}')
      rsilent "$(printf '%-36s %s' "Projected total life"  "about $total full-drive writes   (derived)")"
      rsilent "$(printf '%-36s %s' "Remaining"             "about $left full-drive writes, ~$((100-pct))%   (derived)")"
    elif [ "$pct" = 0 ]; then
      rsilent "  0% used - the drive has not worn enough to register yet."
    fi
    set_kv DISK_WEAR_PCT "$pct"
  fi
  [ -n "$tb_w" ] && set_kv DISK_WRITTEN_TB "$tb_w"
  [ -n "$dw" ]   && set_kv DISK_DRIVE_WRITES "$dw"
  W_TB=$tb_w; W_DW=$dw; W_PCT=$pct

  local spare thresh
  spare=$(printf '%s' "$out" | awk -F: '/Available Spare:/{gsub(/[^0-9]/,"",$2);print $2;exit}')
  thresh=$(printf '%s' "$out" | awk -F: '/Available Spare Threshold/{gsub(/[^0-9]/,"",$2);print $2;exit}')
  if [ -n "$spare" ]; then
    rsilent "$(printf '%-36s %s' "Spare blocks left" "${spare}%, drive warns below ${thresh:-10}%")"
    if [ -n "$thresh" ] && [ "$spare" -le "$thresh" ]; then
      rsilent "  WARNING - the drive has used up its replacement blocks. Replace it."
    fi
  fi
  return 0
}

# Wear and write/erase cycles.
#
# NVMe does not report program/erase cycles directly - no standard SMART field
# carries them, and the vendor log pages that sometimes do are undocumented. So
# this works them out from what the drive does publish, and says which figures
# are measured and which are derived.
#
#   Data Units Written  x 512000 bytes  = host bytes written  (measured)
#   host bytes / capacity              = full drive writes    (derived)
#   Percentage Used                    = the drive's own wear estimate (measured)
#
# Full drive writes is the honest floor for P/E cycles: the flash always writes
# somewhat more than the host asked for (write amplification), so real cycles
# are higher - how much higher is not something any tool here can measure. Where
# the drive reports a non-zero Percentage Used, the two together give a far
# better answer: the projected total life, and therefore what is left.
wear_report() {
  local dev=$1 out=$2
  local units_w units_r pct cap_b
  # smartctl prints these as "31,964,933 [16.3 TB]". The bracket is a courtesy
  # restatement, not part of the number - stripping non-digits across the whole
  # field glued its digits on the end and made the drive look 1000x more worn
  # than it is. Cut at the bracket first, then take the digits.
  smart_int() {
    printf '%s' "$out" | awk -F: -v k="$1" '
      index($0, k) { v = substr($0, index($0, ":") + 1)
                     sub(/\[.*/, "", v); gsub(/[^0-9]/, "", v)
                     print v; exit }'
  }
  units_w=$(smart_int 'Data Units Written')
  units_r=$(smart_int 'Data Units Read')
  pct=$(smart_int 'Percentage Used')
  cap_b=$(disk_bytes "$dev")

  # SATA SSDs put the same idea in vendor attributes instead.
  if [ -z "$units_w" ]; then
    local lba_w
    lba_w=$(printf '%s' "$out" | awk '/Total_LBAs_Written|Host_Writes_32MiB|Total_Writes_GiB/{print $10; exit}')
    [ -n "$lba_w" ] && units_w=$(( lba_w / 1000 ))
  fi
  [ -z "$units_w" ] && [ -z "$pct" ] && return 0      # nothing to work with

  rsilent ""
  rsilent "--- wear and write cycles ---"

  local tb_w="" dw=""
  if [ -n "$units_w" ] && [ "$cap_b" -gt 0 ]; then
    tb_w=$(awk -v u="$units_w" 'BEGIN{printf "%.2f", u*512000/1e12}')
    dw=$(awk -v u="$units_w" -v c="$cap_b" 'BEGIN{printf "%.1f", (u*512000)/c}')
    rsilent "$(printf '%-36s %s' "Written over the drive's life"  "$tb_w TB   (measured)")"
    [ -n "$units_r" ] && rsilent "$(printf '%-36s %s' "Read over the drive's life" \
      "$(awk -v u="$units_r" 'BEGIN{printf "%.2f", u*512000/1e12}') TB   (measured)")"
    rsilent "$(printf '%-36s %s' "Equivalent full-drive writes"   "$dw   (derived)")"
    rsilent "  This is the floor for write/erase cycles per flash cell. The real"
    rsilent "  number is higher by the drive's write amplification, which is not"
    rsilent "  something any tool can read out of it."
  fi

  if [ -n "$pct" ]; then
    rsilent "$(printf '%-36s %s' "Drive's own wear estimate" "${pct}% used   (measured)")"
    if [ -n "$dw" ] && [ "$pct" -gt 0 ]; then
      # If N drive-writes consumed P% of life, the drive is rated for about
      # N*100/P drive-writes in total. This is the drive's own arithmetic
      # turned around, and it is the most useful number on the page.
      local total left
      total=$(awk -v d="$dw" -v p="$pct" 'BEGIN{printf "%.0f", d*100/p}')
      left=$(awk -v t="$total" -v d="$dw" 'BEGIN{printf "%.0f", t-d}')
      rsilent "$(printf '%-36s %s' "Projected total life"  "about $total full-drive writes   (derived)")"
      rsilent "$(printf '%-36s %s' "Remaining"             "about $left full-drive writes, ~$((100-pct))%   (derived)")"
      W_TOTAL=$total; W_LEFT=$left
    elif [ "$pct" = 0 ]; then
      rsilent "  0% used - the drive has not worn enough to register yet."
    fi
    set_kv DISK_WEAR_PCT "$pct"
  fi
  [ -n "$tb_w" ] && set_kv DISK_WRITTEN_TB "$tb_w"
  [ -n "$dw" ]   && set_kv DISK_DRIVE_WRITES "$dw"
  W_TB=$tb_w; W_DW=$dw; W_PCT=$pct

  local spare thresh
  spare=$(printf '%s' "$out" | awk -F: '/Available Spare:/{gsub(/[^0-9]/,"",$2);print $2;exit}')
  thresh=$(printf '%s' "$out" | awk -F: '/Available Spare Threshold/{gsub(/[^0-9]/,"",$2);print $2;exit}')
  if [ -n "$spare" ]; then
    rsilent "$(printf '%-36s %s' "Spare blocks left" "${spare}%, drive warns below ${thresh:-10}%")"
    if [ -n "$thresh" ] && [ "$spare" -le "$thresh" ]; then
      rsilent "  WARNING - the drive has used up its replacement blocks. Replace it."
    fi
  fi
  return 0
}

# PCIe generation from the link rate. The kernel reports the rate per lane
# ("16.0 GT/s PCIe"); the generation is what is printed on the box.
# The controller is what actually fails on a modern SSD, and it is not the same
# thing as the model on the label: a dozen drive names share a handful of
# controllers, and a fault is usually a property of the controller and its
# firmware revision rather than of the brand. Worth recording so that when the
# same symptom turns up on a different model you can see it is the same part.
controller_detail() {
  local dev=$1 out=$2
  local ctrl="" bdf="" pciname="" link="" nsid=""   # link stays empty unless real
  case "$dev" in
    nvme*)
      ctrl=${dev%%n[0-9]*}
      bdf=$(basename "$(readlink -f "/sys/class/nvme/$ctrl/device" 2>/dev/null)" 2>/dev/null)
      [ -n "$bdf" ] && {
        pciname=$(lspci -s "$bdf" 2>/dev/null | head -1 | sed 's/^[0-9a-f:.]* //; s/^Non-Volatile memory controller: //')
        # Some drives drop the link to a slower rate while idle to save
        # power, so read it while the drive is busy: an idle reading of
        # "PCIe 1.0" would be a false alarm.
        dd if="/dev/$dev" of=/dev/null bs=1M count=512 iflag=direct status=none 2>/dev/null &
        local ddp=$!
        sleep 0.4
        pcie_link "$bdf" && link=$PCIE_NOW
        kill "$ddp" 2>/dev/null; wait "$ddp" 2>/dev/null
      }
      nsid=$(cat "/sys/block/$dev/nsid" 2>/dev/null)
      ;;
  esac

  rsilent ""
  rsilent "--- controller and interface ---"
  [ -n "$pciname" ] && rsilent "$(printf '%-30s %s' "Controller"  "$pciname")"
  [ -n "$bdf" ]     && rsilent "$(printf '%-30s %s' "PCI address" "$bdf")"
  local nvv sata
  nvv=$(printf '%s' "$out" | awk -F: '/NVMe Version/{gsub(/^ +/,"",$2);print $2;exit}')
  sata=$(printf '%s' "$out" | awk -F': ' '/SATA Version is/{print $2;exit}')
  if [ -n "$link" ]; then
    rsilent "$(printf '%-30s %s' "Interface" "NVMe${nvv:+ $nvv} over PCIe")"
    rsilent "$(printf '%-30s %s' "PCIe link now" "$link")"
    [ -n "$PCIE_DRIVE" ] && rsilent "$(printf '%-30s %s' "Drive supports" "$PCIE_DRIVE")"
    [ -n "$PCIE_SLOT" ]  && rsilent "$(printf '%-30s %s' "Laptop slot supports" "$PCIE_SLOT")"
    [ -n "$PCIE_NOTE" ]  && rsilent "$(printf '%-30s %s' "" "$PCIE_NOTE")"
    link="NVMe - $link"
  elif [ -n "$sata" ]; then
    rsilent "$(printf '%-30s %s' "Interface" "$sata")"
    link="$sata"; PCIE_TONE=ok
    case "$sata" in *"current: 1.5"*|*"current: 3.0"*)
      case "$sata" in *"6.0 Gb/s (current"*) PCIE_TONE=warn
        PCIE_NOTE="6 Gb/s drive running slower - check the SATA cable or connector" ;; esac ;;
    esac
  fi
  local fw mn
  fw=$(printf '%s' "$out" | awk -F: '/Firmware Version/{gsub(/^ +/,"",$2);print $2;exit}')
  mn=$(printf '%s' "$out" | awk -F: '/Model Number|Device Model/{gsub(/^ +/,"",$2);print $2;exit}')
  [ -n "$mn" ] && rsilent "$(printf '%-30s %s' "Model number" "$mn")"
  [ -n "$fw" ] && rsilent "$(printf '%-30s %s' "Firmware revision" "$fw")"
  [ -n "$nsid" ] && rsilent "$(printf '%-30s %s' "Namespace" "$nsid")"

  local tform
  tform=$(printf '%s' "$out" | awk -F: '/Form Factor/{gsub(/^ +/,"",$2);print $2;exit}')
  [ -n "$tform" ] && rsilent "$(printf '%-30s %s' "Form factor" "$tform")"

  local rot
  rot=$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null)
  rsilent "$(printf '%-30s %s' "Media" "$( [ "$rot" = 0 ] && echo "solid state (flash)" || echo "rotating disk" )")"

  SMART_CTRL=$pciname; SMART_FW=$fw; SMART_LINK=$link
  return 0
}

smart_report() {
  local out; out=$(smartctl -x "/dev/$DISK" 2>&1)
  SMART_CTRL=""; SMART_FW=""; SMART_LINK=""; PCIE_NOTE=""; PCIE_TONE=ok
  W_TB=""; W_DW=""; W_PCT=""; W_TOTAL=""; W_LEFT=""
  local health state
  health=$(printf '%s' "$out" | grep -iE 'SMART overall-health|SMART Health Status' | head -1)
  rsection "SMART HEALTH -- /dev/$DISK"
  rsilent "Device      : $(lsblk -dno MODEL,SIZE "/dev/$DISK" | sed 's/  */ /g')"
  rsilent "Serial      : $(printf '%s' "$out" | awk -F: '/Serial Number/{gsub(/^ +/,"",$2);print $2;exit}')"
  rsilent "Firmware    : $(printf '%s' "$out" | awk -F: '/Firmware Version/{gsub(/^ +/,"",$2);print $2;exit}')"
  if printf '%s' "$health" | grep -qi 'PASSED\|OK'; then
    state=PASSED; set_kv DISK_SMART PASSED
  elif [ -n "$health" ]; then
    state=FAILED; set_kv DISK_SMART FAILED
  else
    state=UNKNOWN; set_kv DISK_SMART UNKNOWN
  fi
  rsilent "SMART health: $state"
  rsilent ""
  printf '%s' "$out" | grep -iE 'Power_On_Hours|Power On Hours|Power_Cycle_Count|Power Cycles|Reallocated_Sector|Reallocated_Event|Current_Pending|Offline_Uncorrectable|CRC_Error|Wear_Leveling|Media_Wearout|Percentage Used|Available Spare|Data Units Written|Data Units Read|Temperature_Celsius|Temperature:' \
    | sed 's/^/  /' >> "$REPORT_TXT"
  controller_detail "$DISK" "$out"
  wear_report "$DISK" "$out"

  tui_frame "SMART health - /dev/$DISK" "Enter to go back"
  local row=6
  case "$state" in
    PASSED)  tui_badge $row PASS "drive reports itself healthy" ;;
    FAILED)  tui_badge $row FAIL "replace this drive" ;;
    *)       tui_badge $row UNKNOWN "no SMART data (USB bridge?)" ;;
  esac
  row=$((row+2))
  tui_kv $row "Model"    "$(lsblk -dno MODEL,SIZE "/dev/$DISK" | sed 's/  */ /g')"; row=$((row+1))
  tui_kv $row "Serial"   "$(printf '%s' "$out" | awk -F: '/Serial Number/{gsub(/^ +/,"",$2);print $2;exit}')"; row=$((row+1))
  [ -n "$SMART_CTRL" ] && { tui_kv $row "Controller" "$SMART_CTRL"; row=$((row+1)); }
  [ -n "$SMART_FW" ]   && { tui_kv $row "Firmware"   "$SMART_FW";   row=$((row+1)); }
  [ -n "$SMART_LINK" ] && { tui_kv $row "Interface"  "$SMART_LINK" "$PCIE_TONE"; row=$((row+1)); }
  [ -n "$PCIE_NOTE" ]  && { tui_line $row "  $PCIE_NOTE" "$( [ "$PCIE_TONE" = warn ] && echo warn || echo muted )"; row=$((row+1)); }
  [ -n "$W_TB" ]  && { tui_kv $row "Written in its life" "$W_TB TB"; row=$((row+1)); }
  [ -n "$W_DW" ]  && { tui_kv $row "Full-drive writes"   "$W_DW  (write/erase cycles, at least)"; row=$((row+1)); }
  [ -n "$W_PCT" ] && { tui_kv $row "Life used"           "${W_PCT}%" \
                        "$( [ "${W_PCT:-0}" -ge 80 ] && echo warn || echo ok )"; row=$((row+1)); }
  row=$((row+1))
  while IFS= read -r l; do
    [ $row -gt $((TUI_ROWS-3)) ] && break
    tui_line $row "$(echo "$l" | cut -c1-$((TUI_W-6)))"; row=$((row+1))
  done < <(printf '%s' "$out" | grep -iE 'Power_On_Hours|Power On Hours|Power_Cycle_Count|Power Cycles|Reallocated_Sector|Current_Pending|CRC_Error|Wear_Leveling|Media_Wearout|Percentage Used|Available Spare|Temperature_Celsius|Temperature:' | sed 's/  */ /g')
  tui_anykey "ENTER to go back"
}

test_smart() { pick_disk || return; smart_report; }

test_surface() {
  pick_disk || return
  local szb szgb; szb=$(disk_bytes "$DISK"); szgb=$(( szb / 1000000000 ))
  tui_confirm "Full surface read scan" yes \
    "Reads every sector of /dev/$DISK (${szgb} GB) and reports" \
    "any that cannot be read. Nothing is written - data is safe." \
    "" \
    "Rough time: a ${szgb} GB HDD at 100 MB/s takes about $(( szgb / 6 )) minutes." \
    "An SSD is much faster." "" "Start?" || return
  rsection "SURFACE READ SCAN -- /dev/$DISK"
  rsilent "Drive       : /dev/$DISK (${szgb} GB), read-only verification of every sector"
  local log=$RUN_DIR/badblocks.log
  : > "$log"
  badblocks -sv -b 4096 "/dev/$DISK" >"$log" 2>&1 &
  local pid=$! start now el pct aborted=0
  start=$(date +%s)
  tui_frame "Surface read scan - /dev/$DISK" "Q = stop the scan"
  while kill -0 $pid 2>/dev/null; do
    now=$(date +%s); el=$(( now - start ))
    pct=$(tr '\r' '\n' < "$log" | grep -oE '[0-9]+\.[0-9]+% done' | tail -1 | cut -d. -f1)
    case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
    tui_kv 6 "Drive"      "/dev/$DISK  (${szgb} GB)"
    tui_kv 7 "Elapsed"    "$(secs_ms "$el")"
    tui_kv 8 "Bad blocks" "$(grep -cE '^[0-9]+$' "$log")" \
      "$([ "$(grep -cE '^[0-9]+$' "$log")" -gt 0 ] && echo "$ERR$B" || echo "$OKC")"
    tui_bar 10 "$pct"
    if tui_wait_abort 2; then
      kill -TERM $pid 2>/dev/null; sleep 1; kill -KILL $pid 2>/dev/null; aborted=1; break
    fi
  done
  wait $pid 2>/dev/null
  el=$(( $(date +%s) - start ))
  local cnt; cnt=$(grep -cE '^[0-9]+$' "$log")
  rsilent "Elapsed     : $(secs_ms "$el")"
  if [ "$aborted" = 1 ]; then
    rsilent "RESULT: CANCELLED after $(secs_ms "$el") ($cnt bad blocks up to that point)"
    set_kv DISK_SURFACE "CANCELLED ($cnt bad so far)"
    tui_msg "Scan stopped" "Cancelled after $(secs_ms "$el")." "$cnt unreadable block(s) found up to that point."
  elif [ "$cnt" -gt 0 ]; then
    rsilent "RESULT: FAIL -- $cnt unreadable blocks"
    set_kv DISK_SURFACE "FAIL ($cnt bad blocks)"
    tui_msg "Surface scan: FAIL" "$cnt unreadable block(s) found." "" "This drive should be replaced."
  else
    rsilent "RESULT: PASS -- no unreadable sectors"
    set_kv DISK_SURFACE PASS
    tui_msg "Surface scan: PASS" "Every sector read back cleanly in $(secs_ms "$el")."
  fi
}

# ---------------------------------------------------------------- auto mode
if [ "$1" = "auto" ]; then
  DISK=$2
  [ -b "/dev/$DISK" ] || { echo "auto mode: /dev/$DISK not found"; exit 1; }
  TEST_SIZE=${3:-1G}; RUNS=${4:-1}; DEV=$DISK
  smart_report
  rsection "DISK BENCHMARK (READ ONLY) -- /dev/$DISK"
  rsilent "Drive       : /dev/$DISK  ($(lsblk -dno SIZE,MODEL "/dev/$DISK" | sed 's/  */ /g'))"
  rsilent "Mode        : raw device, READ ONLY -- nothing is written, data is safe"
  run_cdm "/dev/$DISK" 0 "raw read-only"
  exit 0
fi

# ---------------------------------------------------------------- menu
# The filesystem benchmark is gone: it measured the filesystem and its page
# cache as much as the drive, so its numbers were never comparable with the raw
# ones, and anyone wanting a safe test already has the read-only benchmark.
while :; do
  tui_menu "HDD / SSD tests" "arrows + ENTER, Q to go back" \
    "SMART health|the drive's own record - wear, hours, errors" \
    "Controller check|the SSD's controller chip: load, heat, errors, wake-up - data is safe" \
    "Benchmark, read only|raw device, burst speed - safe on customer data" \
    "Benchmark, raw read + write|burst speed both ways - DESTROYS ALL DATA" \
    "Install simulation|sustained write past the cache - DESTROYS ALL DATA" \
    "Surface read scan|reads every sector looking for unreadable ones" \
    "Drive self-test|NVMe or SATA - the drive checks itself, data is safe" || break
  case "$TUI_CHOICE" in
    1) test_smart ;;
    2) /opt/diag/ctrltest.sh ;;
    3) test_read_only ;;
    4) test_raw_rw ;;
    5) /opt/diag/installsim.sh ;;
    6) test_surface ;;
    7) /opt/diag/selftest.sh ;;
  esac
done
