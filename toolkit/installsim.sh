#!/bin/bash
# Windows-install simulation: sustained write past the SLC cache, with
# root-cause instrumentation.
#
# WHY THIS EXISTS
# ---------------
# The CrystalDiskMark-style benchmark writes for five seconds at a time. On a
# 512 GB drive that is about 8 GB per pass, which lands entirely inside the
# drive's SLC write cache - the fast scratch area every consumer SSD keeps in
# front of its real flash. Inside that cache a failing drive looks perfect.
#
# Windows setup expanding install.wim writes 25-30 GB in one unbroken stream.
# Somewhere around the 20-40 GB mark the SLC cache is full, and the drive has to
# start folding SLC into TLC *while still accepting new writes*. On a DRAM-less
# drive like the Samsung PM991 the mapping tables for that live in borrowed host
# RAM (HMB), so the controller is doing its hardest work with its least margin.
# That is the state a drive is in when it disappears mid-install, and it is the
# state the five-second benchmark never reaches.
#
# So this writes continuously until it is well past the cache, samples the speed
# every chunk to show exactly where the cliff is, reads everything back to prove
# it landed correctly, and - the part that matters - records the drive's own
# error counters, PCIe link state and thermal-throttle timers before and after,
# so that when it does drop you get a cause and not just a failure.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

CHUNK_MB=256                                  # per write step; also the sample rate
DEFAULT_GB=${DIAG_SIM_GB:-48}                 # well past a 512 GB drive's SLC cache
BUF=$RUN_DIR/simbuf                           # the pattern we write
RB=$RUN_DIR/simread                           # read-back scratch
CURVE=$RUN_DIR/simcurve                       # chunk  MB/s  tempC  seconds
EVENTS=$RUN_DIR/simevents                     # the timeline - what happened, where

# ---------------------------------------------------------------- the timeline
# A verdict is only worth as much as the evidence under it, so every notable
# moment is stamped with how long into the test it was, how far into the drive
# the write head had got, and what the drive was doing. When something fails the
# operator can see the run up to it - the temperature climbing, a stall, the
# cache running out - instead of just the failure.
T_START=0
ev() {   # severity  text
  local now=$(( $(date +%s) - T_START ))
  printf '%d\t%s\t%d\t%s\t%s\n' \
    "$now" "$(secs_hms "$now")" "$WRITTEN_MB" "$1" "$2" >> "$EVENTS"
}
# Byte and sector address of a chunk, so a failure can be pointed at precisely.
chunk_addr() { printf 'byte %d (sector %d)' "$1" $(( $1 / 512 )); }

# Megabytes as something readable. Integer division alone turned a failure at
# 768 MB into "0 GB", which reads as though nothing had been written at all.
hsize() {   # megabytes -> "768 MB" / "23.5 GB"
  local mb=${1:-0}
  if [ "$mb" -lt 1024 ]; then printf '%d MB' "$mb"
  else awk -v m="$mb" 'BEGIN{printf "%.1f GB", m/1024}'
  fi
}

# ---------------------------------------------------------------- the drive's own story
# Everything here is read straight from the drive or the PCIe bridge above it.
# Taken once before the test and once after, the difference is the diagnosis.

nvme_ctrl() {   # nvme0n1 -> nvme0
  case "$1" in nvme*) printf '%s' "${1%%n[0-9]*}" ;; *) printf '' ;; esac
}

nvme_bdf() {    # PCI address of the controller, for link state and AER counters
  local c; c=$(nvme_ctrl "$1"); [ -z "$c" ] && return
  local p; p=$(readlink -f "/sys/class/nvme/$c/device" 2>/dev/null)
  [ -n "$p" ] && basename "$p"
}

pci_val() { cat "/sys/bus/pci/devices/$1/$2" 2>/dev/null; }

# Correctable AER errors are the PCIe link reporting that it had to retry.
# A handful over a lifetime is normal; a burst during a write test means the
# physical link is marginal - a solder joint, a dirty M.2 socket, a cracked
# board - and that is a different repair from a bad drive.
aer_total() {
  local bdf=$1 f t=0 v
  [ -n "$bdf" ] || { echo 0; return; }
  for f in aer_dev_correctable aer_dev_nonfatal aer_dev_fatal; do
    v=$(awk '{s+=$2} END{print s+0}' "/sys/bus/pci/devices/$bdf/$f" 2>/dev/null)
    t=$(( t + ${v:-0} ))
  done
  echo "$t"
}

smart_num() {   # field name -> integer, from the NVMe SMART page
  # smartctl appends a restatement in brackets on some fields ("31,964,933
  # [16.3 TB]"). Those digits are not part of the value, so cut the bracket off
  # before stripping separators.
  local dev=$1 key=$2 v
  v=$(smartctl -A "/dev/$dev" 2>/dev/null \
      | awk -F: -v k="$key" 'index($0,k)==1 {
            v = substr($0, index($0, ":") + 1)
            sub(/\[.*/, "", v); gsub(/[^0-9]/, "", v)
            print v; exit }')
  echo "${v:-0}"
}

# nvme_state <dev> -> a snapshot, one KEY=VALUE per line
nvme_state() {
  local dev=$1 bdf; bdf=$(nvme_bdf "$dev")
  echo "AER=$(aer_total "$bdf")"
  echo "LINKSPEED=$(pci_val "$bdf" current_link_speed)"
  echo "LINKWIDTH=$(pci_val "$bdf" current_link_width)"
  echo "TEMP=$(disk_temp_c "$dev")"
  echo "MEDIA_ERR=$(smart_num "$dev" 'Media and Data Integrity Errors')"
  echo "ERRLOG=$(smart_num "$dev" 'Error Information Log Entries')"
  echo "CRIT_WARN=$(smartctl -A "/dev/$dev" 2>/dev/null | awk -F: '/Critical Warning/{gsub(/ /,"",$2);print $2;exit}')"
  # These two are the drive's own thermal stopwatch: minutes spent above its
  # warning and critical thresholds. If they do not move, heat did not do it.
  echo "WARN_TIME=$(smart_num "$dev" 'Warning  Comp. Temperature Time')"
  echo "CRIT_TIME=$(smart_num "$dev" 'Critical Comp. Temperature Time')"
  echo "UNSAFE=$(smart_num "$dev" 'Unsafe Shutdowns')"
}

sget() { printf '%s' "$2" | awk -F= -v k="$1" '$1==k{print $2; exit}'; }

# Host Memory Buffer: how much host RAM the drive borrowed for its mapping
# tables. A DRAM-less drive with no HMB is running blind and will crawl, and a
# drive whose HMB was refused is a prime suspect for dropping under load.
hmb_state() {
  local c=$1 pre
  pre=$(dmesg 2>/dev/null | grep -i "$c.*host memory buffer" | tail -1)
  if [ -n "$pre" ]; then
    printf '%s' "$(echo "$pre" | sed 's/.*: //')"
  else
    printf 'not in use'
  fi
}

# ---------------------------------------------------------------- setup
prepare_buffer() {
  # Random data, so the drive's compression engine cannot cheat the write.
  dd if=/dev/urandom of="$BUF" bs=1M count="$CHUNK_MB" iflag=fullblock \
     status=none 2>/dev/null || return 1
  [ -s "$BUF" ]
}

# Each chunk gets its serial number written into its first 4 KiB. On read-back a
# chunk that carries the wrong number means the drive handed us a different part
# of itself than we asked for - a mapping-table fault, which is exactly what a
# DRAM-less controller loses when its HMB goes wrong. Without this every chunk
# would be identical and that failure would read as a pass.
stamp_chunk() {   # dev offset_bytes index
  printf 'DIAGSIM chunk %08d                                           \n' "$3" \
    | dd of="/dev/$1" bs=4096 count=1 seek=$(( $2 / 4096 )) \
         conv=notrunc,fsync oflag=direct status=none 2>/dev/null
}

read_stamp() {    # dev offset_bytes -> index, or empty
  dd if="/dev/$1" bs=4096 count=1 skip=$(( $2 / 4096 )) iflag=direct \
     status=none 2>/dev/null | head -c 64 | awk '/^DIAGSIM chunk/{print $3+0}'
}

# ---------------------------------------------------------------- the write
# One chunk at a time, timed individually. The per-chunk rate is the whole
# point: plotted against position it shows the SLC cliff, the recovery, and any
# stall long enough to be a controller hiccup.
CHUNKS=0; WRITTEN_MB=0; CLIFF_AT=-1; PEAK_TEMP=-1; STALLS=0
FAST_AVG=0; SLOW_AVG=0; MIN_MBPS=999999; DROPPED=0; WRITE_ERR=""

FAIL_PHASE=""; FAIL_OFFSET=-1; FAIL_CHUNK=-1
TEMP_MARK=0

run_write() {   # dev total_chunks
  local dev=$1 total=$2 i off t0 t1 el mbps temp fast_sum=0 fast_n=0 slow_sum=0 slow_n=0
  : > "$CURVE"
  local start; start=$(date +%s)
  ev INFO "write phase started - ${total} steps of ${CHUNK_MB} MB"

  for (( i = 0; i < total; i++ )); do
    off=$(( i * CHUNK_MB * 1024 * 1024 ))

    t0=$(date +%s.%N)
    if ! dd if="$BUF" of="/dev/$dev" bs=1M count="$CHUNK_MB" \
            seek=$(( i * CHUNK_MB )) oflag=direct conv=notrunc \
            status=none 2>"$RUN_DIR/sim.err"; then
      WRITE_ERR=$(head -2 "$RUN_DIR/sim.err" | tr '\n' ' ')
      DROPPED=1
      FAIL_PHASE="write"; FAIL_OFFSET=$off; FAIL_CHUNK=$i
      ev FAIL "WRITE FAILED at $(chunk_addr "$off") - ${WRITE_ERR:-no error text}"
      break
    fi
    t1=$(date +%s.%N)

    stamp_chunk "$dev" "$off" "$i"

    # A drive that has fallen off the bus keeps its /dev node but reports zero
    # size, so this is what catches the disappearance the instant it happens.
    if ! disk_alive "$dev"; then
      DROPPED=1
      FAIL_PHASE="write"; FAIL_OFFSET=$off; FAIL_CHUNK=$i
      WRITE_ERR="the drive stopped responding after $(hsize $(( (i + 1) * CHUNK_MB )))"
      ev FAIL "DRIVE VANISHED after writing $(chunk_addr "$off") - it accepted the write, then stopped answering"
      break
    fi

    el=$(awk -v a="$t0" -v b="$t1" 'BEGIN{d=b-a; print (d<=0?0.001:d)}')
    mbps=$(awk -v m="$CHUNK_MB" -v s="$el" 'BEGIN{printf "%.0f", m/s}')
    temp=$(disk_temp_c "$dev")
    [ "$temp" -gt "$PEAK_TEMP" ] 2>/dev/null && PEAK_TEMP=$temp
    [ "$mbps" -lt "$MIN_MBPS" ] 2>/dev/null && MIN_MBPS=$mbps

    # Temperature milestones, logged once each, so the timeline shows the climb
    # rather than only the peak.
    if [ "${temp:-0}" -ge 70 ] && [ "$TEMP_MARK" -lt 70 ]; then
      TEMP_MARK=70; ev INFO "drive reached 70 C"
    fi
    if [ "${temp:-0}" -ge 80 ] && [ "$TEMP_MARK" -lt 80 ]; then
      TEMP_MARK=80; ev WARN "drive reached 80 C - into throttling territory"
    fi
    if [ "${temp:-0}" -ge 85 ] && [ "$TEMP_MARK" -lt 85 ]; then
      TEMP_MARK=85; ev WARN "drive reached 85 C - at or near its critical limit"
    fi

    # Any single 256 MB chunk taking over 5 s is a stall, not slow flash.
    if awk -v s="$el" 'BEGIN{exit !(s>5)}'; then
      STALLS=$(( STALLS + 1 ))
      ev WARN "STALL - one 256 MB step took $(awk -v s="$el" 'BEGIN{printf "%.1f", s}') s at $(chunk_addr "$off")"
    fi

    printf '%d %d %d %d\n' "$i" "$mbps" "$temp" "$(( $(date +%s) - start ))" >> "$CURVE"

    # First 8 chunks (2 GB) are cache-speed by definition; use them as the
    # baseline and watch for the sustained rate falling away from it.
    if [ "$i" -lt 8 ]; then
      fast_sum=$(( fast_sum + mbps )); fast_n=$(( fast_n + 1 ))
      # Kept up to date inside the loop, not just at the end: the progress
      # screen shows this figure from the first chunk onwards, and computing
      # it only after the run left it reading "0 MB/s" for the whole test.
      FAST_AVG=$(( fast_sum / fast_n ))
    else
      slow_sum=$(( slow_sum + mbps )); slow_n=$(( slow_n + 1 ))
      if [ "$CLIFF_AT" -lt 0 ] && [ "$fast_n" -gt 0 ] \
         && [ "$mbps" -lt $(( fast_sum / fast_n * 2 / 5 )) ]; then
        CLIFF_AT=$(( i * CHUNK_MB ))          # MB written when speed fell below 40%
        ev INFO "SLC cache exhausted - speed fell from $(( fast_sum / fast_n )) to $mbps MB/s; the drive is now writing to raw flash"
      fi
    fi

    CHUNKS=$(( i + 1 )); WRITTEN_MB=$(( CHUNKS * CHUNK_MB ))
    draw_progress "$dev" "$total" "$mbps" "$temp"
    tui_wait_abort 0 && { ABORTED=1; ev INFO "stopped by the operator"; break; }
  done
  [ "$DROPPED" = 0 ] && [ "$ABORTED" = 0 ] \
    && ev INFO "write phase completed - $(hsize "$WRITTEN_MB"), no dropout"

  [ "$fast_n" -gt 0 ] && FAST_AVG=$(( fast_sum / fast_n ))
  [ "$slow_n" -gt 0 ] && SLOW_AVG=$(( slow_sum / slow_n ))
  [ "$MIN_MBPS" = 999999 ] && MIN_MBPS=0
  return 0
}

draw_progress() {
  local dev=$1 total=$2 mbps=$3 temp=$4
  local gb=$(( WRITTEN_MB / 1024 )) tgb=$(( total * CHUNK_MB / 1024 ))
  tui_frame "Install simulation - writing" "Q = stop"
  tui_line 6 "Writing one continuous stream, the way Windows setup expands install.wim." muted
  tui_kv  8  "Written"        "$gb GB of $tgb GB"
  tui_kv  9  "Now"            "$mbps MB/s"
  tui_kv  10 "Cache speed"    "${FAST_AVG:-?} MB/s  (first 2 GB)"
  if [ "$CLIFF_AT" -ge 0 ]; then
    tui_kv 11 "SLC cache ran out" "at $(hsize "$CLIFF_AT") - now on raw flash" warn
  else
    tui_kv 11 "SLC cache"      "still absorbing writes" muted
  fi
  tui_kv  12 "Drive temp"     "$temp C  (peak $PEAK_TEMP C)" \
             "$( [ "${temp:-0}" -ge 75 ] && echo warn || echo ok )"
  [ "$STALLS" -gt 0 ] && tui_kv 13 "Stalls" "$STALLS chunk(s) took over 5 s" warn
  tui_bar 22 $(( WRITTEN_MB * 100 / (total * CHUNK_MB) ))
  tui_flush
}

# ---------------------------------------------------------------- read back
# Writing is only half of it. Windows expands the image and then reads it to
# install from, so a drive that accepts writes and returns something else is
# still a failed install - and the benchmark would have called it a pass.
VERIFY_BAD=0; VERIFY_MISPLACED=0; VERIFY_DONE=0; VERIFY_ERR=""

run_verify() {   # dev chunks
  local dev=$1 total=$2 i off got
  ev INFO "read-back phase started - checking $(hsize $(( total * CHUNK_MB )))"
  for (( i = 0; i < total; i++ )); do
    off=$(( i * CHUNK_MB * 1024 * 1024 ))

    got=$(read_stamp "$dev" "$off")
    if [ -z "$got" ]; then
      VERIFY_BAD=$(( VERIFY_BAD + 1 ))
      [ "$FAIL_OFFSET" -lt 0 ] && { FAIL_PHASE="verify"; FAIL_OFFSET=$off; FAIL_CHUNK=$i; }
      ev FAIL "MARKER GONE at $(chunk_addr "$off") - the drive returned nothing recognisable"
    elif [ "$got" -ne "$i" ]; then
      # The drive returned a different chunk than the one asked for.
      VERIFY_MISPLACED=$(( VERIFY_MISPLACED + 1 ))
      [ "$FAIL_OFFSET" -lt 0 ] && { FAIL_PHASE="verify"; FAIL_OFFSET=$off; FAIL_CHUNK=$i; }
      ev FAIL "WRONG DATA at $(chunk_addr "$off") - asked for block $i, the drive returned block $got"
    fi

    if ! dd if="/dev/$dev" of="$RB" bs=1M count="$CHUNK_MB" \
            skip=$(( i * CHUNK_MB )) iflag=direct status=none 2>"$RUN_DIR/sim.err"; then
      VERIFY_ERR=$(head -1 "$RUN_DIR/sim.err")
      DROPPED=1
      [ "$FAIL_OFFSET" -lt 0 ] && { FAIL_PHASE="verify"; FAIL_OFFSET=$off; FAIL_CHUNK=$i; }
      ev FAIL "READ FAILED at $(chunk_addr "$off") - ${VERIFY_ERR:-no error text}"
      break
    fi
    if ! disk_alive "$dev"; then
      DROPPED=1; VERIFY_ERR="drive vanished during read-back"
      FAIL_PHASE="verify"; FAIL_OFFSET=$off; FAIL_CHUNK=$i
      ev FAIL "DRIVE VANISHED while reading $(chunk_addr "$off")"
      break
    fi

    # Skip the first 4 KiB of both - that is the serial number, checked above.
    if ! cmp -s -i 4096:4096 "$RB" "$BUF"; then
      VERIFY_BAD=$(( VERIFY_BAD + 1 ))
      [ "$FAIL_OFFSET" -lt 0 ] && { FAIL_PHASE="verify"; FAIL_OFFSET=$off; FAIL_CHUNK=$i; }
      ev FAIL "DATA CHANGED at $(chunk_addr "$off") - written and read-back copies differ"
    fi

    VERIFY_DONE=$(( i + 1 ))
    tui_frame "Install simulation - reading back" "Q = stop"
    tui_line 6 "Checking every byte came back exactly as written." muted
    tui_kv  8 "Verified"   "$(hsize $(( VERIFY_DONE * CHUNK_MB ))) of $(hsize $(( total * CHUNK_MB )))"
    tui_kv  9 "Mismatches" "$VERIFY_BAD" "$( [ "$VERIFY_BAD" -gt 0 ] && echo err || echo ok )"
    [ "$VERIFY_MISPLACED" -gt 0 ] && tui_kv 10 "Wrong data returned" "$VERIFY_MISPLACED chunk(s)" err
    tui_bar 22 $(( VERIFY_DONE * 100 / total ))
    tui_flush
    tui_wait_abort 0 && { ABORTED=1; ev INFO "read-back stopped by the operator"; break; }
  done
  [ "$VERIFY_BAD" = 0 ] && [ "$VERIFY_MISPLACED" = 0 ] && [ "$DROPPED" = 0 ] \
    && ev INFO "read-back completed - every byte matched"
}

# ---------------------------------------------------------------- the verdict
# This is the part the operator is actually here for. Every branch below points
# at a different repair, so the ordering matters: the most specific evidence
# wins, and "I do not know" is an honest answer when nothing fired.
CAUSE=""; CAUSE_DETAIL=""; ACTION=""; STATE=PASS

decide() {
  local dev=$1 pre=$2 post=$3
  local aer_d=$(( $(sget AER "$post") - $(sget AER "$pre") ))
  local err_d=$(( $(sget ERRLOG "$post") - $(sget ERRLOG "$pre") ))
  local med_d=$(( $(sget MEDIA_ERR "$post") - $(sget MEDIA_ERR "$pre") ))
  local crit_d=$(( $(sget CRIT_TIME "$post") - $(sget CRIT_TIME "$pre") ))
  local warn_d=$(( $(sget WARN_TIME "$post") - $(sget WARN_TIME "$pre") ))
  local uns_d=$(( $(sget UNSAFE "$post") - $(sget UNSAFE "$pre") ))
  local w_post; w_post=$(sget LINKWIDTH "$post")
  local w_pre;  w_pre=$(sget LINKWIDTH "$pre")
  local resets; resets=$(dmesg_since "$DMESG_MARK" | grep -ci "$(nvme_ctrl "$dev").*\(controller is down\|resetting\|reset controller\|I/O.*timeout\)")

  AER_D=$aer_d; ERR_D=$err_d; MED_D=$med_d; CRIT_D=$crit_d; WARN_D=$warn_d
  UNS_D=$uns_d; RESETS=$resets

  if [ "$DROPPED" = 1 ]; then
    STATE=FAIL
    if [ "$aer_d" -gt 0 ] || { [ -n "$w_post" ] && [ -n "$w_pre" ] && [ "$w_post" != "$w_pre" ]; }; then
      CAUSE="PCIe link failure - the connection to the drive, not the flash"
      CAUSE_DETAIL="$aer_d new PCIe error(s) were logged and the link width went from ${w_pre:-?} to ${w_post:-?}. The drive was not the thing that gave up; the electrical path to it was."
      ACTION="Reseat the drive and clean the M.2 socket. If it repeats, try this drive in another machine - if it behaves there, the fault is the mainboard socket or its solder."
    elif [ "$crit_d" -gt 0 ]; then
      CAUSE="Overheating - the drive shut itself down to protect the flash"
      CAUSE_DETAIL="The drive's own critical-temperature timer advanced by $crit_d minute(s) during this test, peaking at $PEAK_TEMP C. It stopped because it was too hot."
      ACTION="Replace or refit the thermal pad between the drive and the chassis. Retest before condemning the drive."
    elif [ "$CLIFF_AT" -ge 0 ] && [ "$WRITTEN_MB" -gt "$CLIFF_AT" ]; then
      CAUSE="Controller firmware fault under sustained write"
      CAUSE_DETAIL="The drive dropped after its SLC cache ran out at $(hsize "$CLIFF_AT"), while folding cache into main flash - and with no temperature or PCIe errors to explain it. This is the drive's own firmware losing its footing under exactly the load Windows setup applies."
      ACTION="Check for a firmware update for this drive. If none, replace the drive - it will keep failing installs."
    elif [ "$med_d" -gt 0 ]; then
      CAUSE="Failing flash"
      CAUSE_DETAIL="$med_d new media / data-integrity error(s) were recorded. The flash itself is returning bad data."
      ACTION="Replace the drive."
    else
      CAUSE="Drive stopped responding, cause not narrowed"
      CAUSE_DETAIL="The drive disappeared at $(hsize "$WRITTEN_MB"), but no PCIe error, thermal event or media error was recorded to explain it. $resets controller reset(s)/timeout(s) are in the kernel log."
      ACTION="Read the kernel log section below - it is the best evidence. Then retry with a known-good drive to separate the drive from the mainboard."
    fi
    return
  fi

  if [ "$VERIFY_MISPLACED" -gt 0 ]; then
    STATE=FAIL
    CAUSE="Drive returned the wrong data - mapping table fault"
    CAUSE_DETAIL="$VERIFY_MISPLACED chunk(s) came back carrying a different serial number than the one written there. The drive accepted the writes but has lost track of where it put them. On a DRAM-less drive this points at the host-memory-buffer path."
    ACTION="Replace the drive. Do not install an operating system on it - the install will appear to succeed and then fail to boot."
    return
  fi

  if [ "$VERIFY_BAD" -gt 0 ]; then
    STATE=FAIL
    CAUSE="Data came back different from what was written"
    CAUSE_DETAIL="$VERIFY_BAD chunk(s) of 256 MB did not match. The drive reported every write as successful. This is silent corruption, and it is the reason an install can finish and then fail to boot."
    ACTION="Replace the drive."
    return
  fi

  if [ "$crit_d" -gt 0 ] || [ "$PEAK_TEMP" -ge 85 ]; then
    STATE=WARN
    CAUSE="Survived, but ran too hot"
    CAUSE_DETAIL="Peak $PEAK_TEMP C, and the drive's critical-temperature timer advanced by $crit_d minute(s). It completed the test, but a longer install may not be so lucky."
    ACTION="Refit the thermal pad and retest."
    return
  fi

  if [ "$STALLS" -gt 0 ]; then
    STATE=WARN
    CAUSE="Survived, but stalled under load"
    CAUSE_DETAIL="$STALLS write step(s) of 256 MB took over five seconds. The drive recovered each time, but those pauses are the drive struggling, and a longer write may turn one into a dropout."
    ACTION="Run this test again - twice more. A drive that stalls intermittently is a drive that will fail an install intermittently."
    return
  fi

  if [ "$aer_d" -gt 0 ]; then
    STATE=WARN
    CAUSE="Survived, but the PCIe link logged errors"
    CAUSE_DETAIL="$aer_d correctable PCIe error(s) during the test. The link retried and succeeded, so nothing was lost, but a clean link logs none."
    ACTION="Reseat the drive and clean the socket."
    return
  fi

  STATE=PASS
  CAUSE="No fault found under install-equivalent load"
  if [ "$CLIFF_AT" -ge 0 ]; then
    CAUSE_DETAIL="$(hsize "$WRITTEN_MB") written in one stream and read back byte-for-byte. The drive ran out of SLC cache at $(hsize "$CLIFF_AT") and kept going on raw flash without a dropout, a stall, a PCIe error or a thermal event - which is the hard part, and it passed it."
    ACTION="This drive handled more sustained writing than a Windows install does, including the part past its cache. If installs still fail, the drive is unlikely to be the cause - look at the install media, the USB port it boots from, or the firmware settings."
  else
    # Never reaching the cliff means the test was not as hard as it looks.
    CAUSE_DETAIL="$(hsize "$WRITTEN_MB") written in one stream and read back byte-for-byte, with no dropout, stall, PCIe error or thermal event. Note that the drive's SLC cache never ran out, so the hardest case - writing while folding cache into flash - was not reached."
    ACTION="Run it again at a larger size so the cache is exhausted; that is the state a Windows install puts the drive in. If it passes that too, the drive is unlikely to be the cause of a failed install."
  fi
}

# ---------------------------------------------------------------- report
write_report() {
  local dev=$1 pre=$2 post=$3
  rsection "INSTALL SIMULATION (SUSTAINED WRITE, DESTRUCTIVE) -- /dev/$dev"
  rsilent "Drive         : $(lsblk -dno SIZE,MODEL "/dev/$dev" 2>/dev/null | sed 's/  */ /g')"
  rsilent "Written       : $(hsize "$WRITTEN_MB") in one continuous stream, direct I/O"
  rsilent "Verified      : $(hsize $(( VERIFY_DONE * CHUNK_MB ))) read back and compared"
  rsilent ""
  rsilent "This mimics Windows setup expanding install.wim: one unbroken write far"
  rsilent "larger than the drive's SLC cache, then a full read-back."
  rsilent ""
  rsilent "--- speed ---"
  rsilent "$(printf '%-34s %s' "Cache speed (first 2 GB)"  "$FAST_AVG MB/s")"
  rsilent "$(printf '%-34s %s' "Sustained speed after that" "$SLOW_AVG MB/s")"
  rsilent "$(printf '%-34s %s' "Slowest single ${CHUNK_MB} MB step" "$MIN_MBPS MB/s")"
  if [ "$CLIFF_AT" -ge 0 ]; then
    rsilent "$(printf '%-34s %s' "SLC cache exhausted at" "$(hsize "$CLIFF_AT")")"
    rsilent "  Past this point the drive writes to raw flash. A Windows install"
    rsilent "  crosses this line every time; a 5-second benchmark never does."
  else
    rsilent "$(printf '%-34s %s' "SLC cache" "never exhausted in this run")"
  fi
  rsilent "$(printf '%-34s %s' "Write steps over 5 s (stalls)" "$STALLS")"
  rsilent ""
  rsilent "--- speed curve (GB written : MB/s : drive temp) ---"
  # Thinned to roughly forty rows whatever the test size, so the shape of the
  # curve - which is the point - stays visible without pages of numbers.
  local rows; rows=$(wc -l < "$CURVE" 2>/dev/null || echo 0)
  local every=$(( rows / 40 )); [ "$every" -lt 1 ] && every=1
  awk -v c="$CHUNK_MB" -v n="$every" 'NR % n == 1 || n == 1 {
        printf "  %5.1f GB   %6d MB/s   %3s\n", ($1*c)/1024, $2, ($3 < 0 ? "n/a" : $3 " C") }' \
      "$CURVE" 2>/dev/null >> "$REPORT_TXT"
  rsilent ""
  rsilent "--- what the drive recorded about itself ---"
  rsilent "$(printf '%-34s %s' "Peak temperature"            "$PEAK_TEMP C")"
  rsilent "$(printf '%-34s %s' "Minutes above warning temp"  "+$WARN_D during this test")"
  rsilent "$(printf '%-34s %s' "Minutes above critical temp" "+$CRIT_D during this test")"
  rsilent "$(printf '%-34s %s' "New PCIe link errors"        "$AER_D")"
  rsilent "$(printf '%-34s %s' "New drive error-log entries" "$ERR_D")"
  rsilent "$(printf '%-34s %s' "New media integrity errors"  "$MED_D")"
  rsilent "$(printf '%-34s %s' "New unsafe shutdowns"        "$UNS_D")"
  rsilent "$(printf '%-34s %s' "Controller resets/timeouts"  "$RESETS in the kernel log")"
  if [ -n "$(sget LINKWIDTH "$pre")" ]; then
    rsilent "$(printf '%-34s %s' "PCIe link before" "$(sget LINKSPEED "$pre") x$(sget LINKWIDTH "$pre")")"
    rsilent "$(printf '%-34s %s' "PCIe link after"  "$(sget LINKSPEED "$post") x$(sget LINKWIDTH "$post")")"
  else
    rsilent "$(printf '%-34s %s' "PCIe link" "not reported (not an NVMe drive)")"
  fi
  rsilent "$(printf '%-34s %s' "Host memory buffer"          "$HMB")"
  rsilent "$(printf '%-34s %s' "NVMe power saving (APST)"    "$APST")"
  rsilent ""
  rsilent "--- read-back ---"
  rsilent "$(printf '%-34s %s' "Chunks that did not match"   "$VERIFY_BAD")"
  rsilent "$(printf '%-34s %s' "Chunks returned from wrong place" "$VERIFY_MISPLACED")"
  [ -n "$VERIFY_ERR" ] && rsilent "Read error    : $VERIFY_ERR"
  [ -n "$WRITE_ERR" ]  && rsilent "Write error   : $WRITE_ERR"
  rsilent ""
  rsilent "--- where it failed ---"
  if [ -n "$FAIL_PHASE" ]; then
    rsilent "$(printf '%-34s %s' "Phase"     "$FAIL_PHASE ($( [ "$FAIL_PHASE" = write ] && echo "writing to the drive" || echo "reading it back" ))")"
    rsilent "$(printf '%-34s %s' "Position"  "$(hsize $(( FAIL_OFFSET / 1048576 ))) into the drive")"
    rsilent "$(printf '%-34s %s' "Address"   "$(chunk_addr "$FAIL_OFFSET")")"
    rsilent "$(printf '%-34s %s' "Step"      "$FAIL_CHUNK of $(( GB * 1024 / CHUNK_MB ))")"
    if [ "$CLIFF_AT" -ge 0 ] && [ $(( FAIL_OFFSET / 1048576 )) -gt "$CLIFF_AT" ]; then
      rsilent "$(printf '%-34s %s' "Relative to the SLC cache" "AFTER it ran out - the drive was folding cache into flash")"
    elif [ "$CLIFF_AT" -ge 0 ]; then
      rsilent "$(printf '%-34s %s' "Relative to the SLC cache" "before it ran out - still in fast cache")"
    fi
  else
    rsilent "Nothing failed - the test ran to the end."
  fi
  rsilent ""
  rsilent "--- timeline ---"
  rsilent "  elapsed    written   what happened"
  if [ -s "$EVENTS" ]; then
    awk -F'\t' '{printf "  %-9s %5.1f GB  %-5s %s\n", $2, $3/1024, ($4=="INFO"?"":$4), $5}' \
        "$EVENTS" >> "$REPORT_TXT"
  else
    rsilent "  (nothing was recorded)"
  fi
  rsilent ""
  rsilent "--- CAUSE ---"
  rsilent "$CAUSE"
  rsilent ""
  printf '%s\n' "$CAUSE_DETAIL" | fold -s -w 76 | sed 's/^/  /' >> "$REPORT_TXT"
  rsilent ""
  rsilent "  What to do:"
  printf '%s\n' "$ACTION" | fold -s -w 74 | sed 's/^/    /' >> "$REPORT_TXT"
  rsilent ""
  case "$STATE" in
    PASS) rsilent "RESULT: PASS -- no fault under install-equivalent sustained write" ;;
    WARN) rsilent "RESULT: MARGINAL -- $CAUSE" ;;
    *)    rsilent "RESULT: FAIL -- $CAUSE" ;;
  esac
  set_kv SIM_RESULT "$STATE ($CAUSE)"
  # The kernel log is the primary evidence for a dropout, so it goes in whole.
  [ "$DROPPED" = 1 ] && capture_dmesg 80
  return 0
}

show_verdict() {
  tui_frame "Install simulation finished" "Enter to go back"
  case "$STATE" in
    PASS) tui_badge 6 PASS "no fault under install-equivalent load" ;;
    WARN) tui_badge 6 MARGINAL "completed, but not cleanly" ;;
    *)    tui_badge 6 FAIL "the drive failed the way an install fails" ;;
  esac
  tui_line 8 "$CAUSE" "$( [ "$STATE" = PASS ] && echo ok || echo err )"
  local row=10 l
  if [ -n "$FAIL_PHASE" ]; then
    tui_kv $row "Failed while" \
      "$( [ "$FAIL_PHASE" = write ] && echo "writing" || echo "reading back" ), $(hsize $(( FAIL_OFFSET / 1048576 ))) in" err
    row=$((row+1))
    tui_kv $row "At address" "$(chunk_addr "$FAIL_OFFSET")" muted
    row=$((row+2))
  fi
  while IFS= read -r l; do
    [ $row -gt 16 ] && break
    tui_line $row "$l" muted; row=$((row+1))
  done < <(printf '%s\n' "$CAUSE_DETAIL" | fold -s -w 72)
  row=$((row+1))
  tui_line $row "What to do:" ""; row=$((row+1))
  while IFS= read -r l; do
    [ $row -gt 21 ] && break
    tui_line $row "$l" ""; row=$((row+1))
  done < <(printf '%s\n' "$ACTION" | fold -s -w 72)
  tui_flush
  tui_anykey
}

# ---------------------------------------------------------------- main
pick_disk() {
  local -a names=() labels=()
  local n s r t m kind
  while read -r n s r t m; do
    [ -z "$n" ] && continue
    [ "$r" = 1 ] && kind="HDD" || kind="SSD"
    names+=("$n"); labels+=("$(printf '/dev/%-8s %-8s %-6s %-5s %s' "$n" "$s" "$t" "$kind" "$m")")
  done < <(list_disks)
  [ ${#names[@]} -eq 0 ] && { tui_msg "No drives" "No storage devices were detected."; return 1; }
  tui_menu "Select the drive to test" "arrows + ENTER, Q to go back" "${labels[@]}" || return 1
  DISK=${names[$((TUI_CHOICE-1))]}
  return 0
}

pick_amount() {
  tui_menu "How much to write" "must be bigger than the drive's SLC cache to mean anything" \
    "32 GB|about what a Windows install writes" \
    "48 GB|recommended - comfortably past the cache on a 512 GB drive" \
    "64 GB|harder, for a drive that passed at 48 GB" \
    "96 GB|worst case, takes a while" || return 1
  case "$TUI_CHOICE" in 1) GB=32 ;; 2) GB=48 ;; 3) GB=64 ;; 4) GB=96 ;; esac
  return 0
}

main() {
  need_root
  command -v smartctl >/dev/null || tui_msg "Note" "smartctl is missing - the drive's own error counters will not be read."

  pick_disk || return
  if lsblk -rno MOUNTPOINT "/dev/$DISK" 2>/dev/null | grep -q .; then
    tui_msg "Drive in use" "/dev/$DISK has mounted partitions." \
      "Unmount them before running a destructive test."
    return
  fi

  GB=$DEFAULT_GB
  pick_amount || return

  local cap_gb; cap_gb=$(( $(disk_bytes "$DISK") / 1000000000 ))
  if [ "$cap_gb" -gt 0 ] && [ "$GB" -gt $(( cap_gb * 80 / 100 )) ]; then
    GB=$(( cap_gb * 80 / 100 ))
    [ "$GB" -lt 8 ] && { tui_msg "Drive too small" "This drive is only ${cap_gb} GB - too small for a meaningful sustained-write test."; return; }
  fi
  local total=$(( GB * 1024 / CHUNK_MB ))

  tui_confirm "DESTRUCTIVE - install simulation" no \
    "This writes ${GB} GB directly to /dev/$DISK, then reads it all back." \
    "The partition table and every file on it will be destroyed." \
    "" \
    "It reproduces what Windows setup does to a drive: one unbroken" \
    "write far larger than the drive's cache. That is the load that" \
    "makes a marginal drive disappear, and a short benchmark misses it." \
    "" \
    "Roughly $(( GB / 20 + 5 )) to $(( GB / 4 + 5 )) minutes. Q stops it at any point." \
    "" "Continue?" || return

  tui_input "Final confirmation" "Type ERASE to destroy all data on /dev/$DISK:"
  case "$(printf '%s' "$TUI_TEXT" | tr '[:lower:]' '[:upper:]')" in
    ERASE) ;;
    *) tui_msg "Cancelled" "Nothing was written."; return ;;
  esac

  tui_frame "Install simulation" "preparing"
  tui_line 8 "Building the test pattern..." muted
  tui_flush
  prepare_buffer || { tui_msg "Could not start" "The ${CHUNK_MB} MB test pattern could not be created in RAM."; return; }

  # APST state matters to the reading: with power saving disabled the sleep/wake
  # path is never exercised, and the operator needs to know which run this was.
  if grep -q 'nvme_core.default_ps_max_latency_us=0' /proc/cmdline 2>/dev/null; then
    APST="disabled by boot option - the drive was never allowed to sleep"
  else
    APST="enabled (normal) - the drive was free to enter low-power states"
  fi
  HMB=$(hmb_state "$(nvme_ctrl "$DISK")")

  # Mark where the log is now rather than clearing it: the boot-time firmware
  # messages that Driver check relies on must survive this test.
  DMESG_MARK=$(dmesg_mark)
  local pre post
  pre=$(nvme_state "$DISK")

  T_START=$(date +%s)
  : > "$EVENTS"
  ABORTED=0
  ev INFO "test started on /dev/$DISK - target $GB GB, APST ${APST%% *}"
  ev INFO "starting temperature $(sget TEMP "$pre") C, host memory buffer: $HMB"
  run_write "$DISK" "$total"

  if [ "$DROPPED" = 0 ] && [ "$CHUNKS" -gt 0 ]; then
    run_verify "$DISK" "$CHUNKS"
  fi

  post=$(nvme_state "$DISK")
  decide "$DISK" "$pre" "$post"
  [ "$ABORTED" = 1 ] && [ "$STATE" = PASS ] && {
    STATE=WARN
    CAUSE="Stopped early by the operator"
    CAUSE_DETAIL="Only $(hsize "$WRITTEN_MB") was written before you pressed Q, which may not be past the drive's cache."
    ACTION="Run it again and let it finish to get a usable answer."
  }
  write_report "$DISK" "$pre" "$post"
  rm -f "$BUF" "$RB"
  show_verdict
}

main "$@"
