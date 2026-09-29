#!/bin/bash
# Drive self-test: the drive examines itself.
#
# SMART health is the drive's own opinion of its past; a self-test makes it
# check itself now - the controller reads its own flash (or platters) and
# reports the first thing that fails. On NVMe this is the Device Self-test
# command; SATA drives have had the same thing for decades. Both are started
# and read through smartctl, so one script covers every internal drive.
#
# Nothing is written to user data. The drive keeps working normally while it
# tests, just a little slower.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

need_root

# NVMe result codes from the spec (Self-test Result Data Structure, byte 0 bits
# 3:0). 5-7 mean the drive found something wrong with itself.
nvme_result_text() {
  case "$1" in
    0) echo "completed without error" ;;
    1) echo "aborted by a command" ;;
    2) echo "aborted by a controller reset" ;;
    3) echo "aborted - a namespace was removed" ;;
    4) echo "aborted by a format command" ;;
    5) echo "fatal error or unknown test error" ;;
    6) echo "completed - a segment failed (segment unknown)" ;;
    7) echo "completed - one or more segments failed" ;;
    8) echo "aborted for an unknown reason" ;;
    9) echo "aborted by a sanitize operation" ;;
    *) echo "result code $1" ;;
  esac
}

pick_drive() {
  local -a names=() labels=()
  local n s r t m kind
  while read -r n s r t m; do
    [ -z "$n" ] && continue
    case "$n" in nvme*) kind=NVMe ;; *) [ "$r" = 1 ] && kind=HDD || kind=SSD ;; esac
    [ "$t" = usb ] && continue      # USB bridges almost never pass self-tests through
    names+=("$n")
    labels+=("/dev/$n|$kind|$s|$m")
  done < <(list_disks)
  if [ ${#names[@]} -eq 0 ]; then
    tui_msg "No drives" "No internal drive was found to test."
    return 1
  fi
  tui_menu "Which drive?" "arrows + Enter, Q to go back" "${labels[@]}" || return 1
  DISK=${names[$((TUI_CHOICE-1))]}
  return 0
}

# The device smartctl should talk to. For NVMe that is the controller, so the
# test covers every namespace on it.
smart_dev() {
  case "$1" in
    nvme*) printf '/dev/%s' "${1%%n[0-9]*}" ;;
    *)     printf '/dev/%s' "$1" ;;
  esac
}

is_nvme() { case "$DISK" in nvme*) return 0 ;; esac; return 1; }

# 0 when the drive says it can self-test at all. Many cheap DRAM-less NVMe
# drives leave the optional command out.
supports_selftest() {
  if is_nvme; then
    local oacs
    oacs=$(nvme id-ctrl "$DEV" -o json 2>/dev/null | jq -r '.oacs // empty' 2>/dev/null)
    case "$oacs" in ''|*[!0-9]*) return 0 ;; esac     # cannot tell: let the drive answer
    [ $(( oacs & 16 )) -ne 0 ]
  else
    smartctl -j -c "$DEV" 2>/dev/null \
      | jq -e '.ata_smart_data.capabilities.self_tests_supported != false' >/dev/null 2>&1
  fi
}

# How long the extended test is allowed to take, in minutes, by the drive's
# own estimate.
extended_minutes() {
  local m=""
  if is_nvme; then
    m=$(nvme id-ctrl "$DEV" -o json 2>/dev/null | jq -r '.edstt // empty' 2>/dev/null)
  else
    m=$(smartctl -j -c "$DEV" 2>/dev/null | jq -r '.ata_smart_data.self_test.polling_minutes.extended // empty' 2>/dev/null)
  fi
  case "$m" in ''|*[!0-9]*|0) echo 0 ;; *) echo "$m" ;; esac
}

# "running pct" while a test is in progress, "idle" otherwise.
progress() {
  local j
  if is_nvme; then
    j=$(smartctl -j -l selftest "$DEV" 2>/dev/null)
    local op pct
    op=$(printf '%s' "$j" | jq -r '.nvme_self_test_log.current_self_test_operation.value // 0' 2>/dev/null)
    pct=$(printf '%s' "$j" | jq -r '.nvme_self_test_log.current_self_test_completion_percent // 0' 2>/dev/null)
    if [ "${op:-0}" != 0 ]; then echo "running ${pct:-0}"; else echo idle; fi
  else
    j=$(smartctl -j -c "$DEV" 2>/dev/null)
    local st rem
    st=$(printf '%s' "$j" | jq -r '.ata_smart_data.self_test.status.value // 0' 2>/dev/null)
    rem=$(printf '%s' "$j" | jq -r '.ata_smart_data.self_test.status.remaining_percent // 0' 2>/dev/null)
    # status 0xF_ = in progress
    if [ $(( ${st:-0} >> 4 )) -eq 15 ]; then echo "running $(( 100 - ${rem:-0} ))"; else echo idle; fi
  fi
}

# Newest log entry as "code|text|type".
last_result() {
  if is_nvme; then
    smartctl -j -l selftest "$DEV" 2>/dev/null | jq -r '
      .nvme_self_test_log.table[0] // empty
      | "\(.self_test_result.value)|\(.self_test_result.string // "")|\(.self_test_code.string // "")|\(.power_on_hours // "")"' 2>/dev/null
  else
    smartctl -j -l selftest "$DEV" 2>/dev/null | jq -r '
      .ata_smart_self_test_log.standard.table[0] // empty
      | "\(if .status.passed then 0 else 5 end)|\(.status.string // "")|\(.type.string // "")|\(.lifetime_hours // "")"' 2>/dev/null
  fi
}

run_selftest() {   # short|long
  local kind=$1 cap_min label start el pct state t aborted=0 before after
  if [ "$kind" = short ]; then
    label="Short self-test"; cap_min=10
  else
    label="Extended self-test"; cap_min=$(( $(extended_minutes) * 3 / 2 + 10 ))
    [ "$cap_min" -lt 30 ] && cap_min=240          # the drive gave no estimate
  fi
  before=$(last_result)

  local out; out=$(smartctl -t "$kind" "$DEV" 2>&1)
  if ! printf '%s' "$out" | grep -qiE 'has begun|in progress'; then
    tui_msg "The drive would not start the test" \
      "$(printf '%s' "$out" | grep -iE 'error|fail|not supported|abort' | head -2)" "" \
      "Some drives only accept a self-test when idle - try again in a minute."
    rsection "DRIVE SELF-TEST -- /dev/$DISK"
    rsilent "RESULT: NOT RUN -- the drive refused to start a $kind self-test"
    set_kv DISK_SELFTEST "NOT RUN (drive refused)"
    return 0
  fi

  start=$(date +%s)
  sleep 2
  tui_frame "$label - /dev/$DISK" "Q = stop the test"
  while :; do
    el=$(( $(date +%s) - start ))
    state=$(progress)
    [ "$state" = idle ] && [ "$el" -ge 4 ] && break
    pct=${state#running }; case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
    tui_kv 6 "Drive"   "/dev/$DISK  $(lsblk -dno MODEL "/dev/$DISK" 2>/dev/null)"
    tui_kv 7 "Test"    "$label"
    tui_kv 8 "Elapsed" "$(secs_ms "$el")"
    t=$(disk_temp_c "$DISK")
    [ "$t" -gt 0 ] 2>/dev/null && tui_kv 9 "Temperature" "$t C"
    tui_bar 11 "$pct"
    tui_line 13 "The drive is checking itself. Nothing is written to your data." muted
    if [ "$el" -gt $(( cap_min * 60 )) ]; then
      smartctl -X "$DEV" >/dev/null 2>&1; aborted=2; break
    fi
    if tui_wait_abort 2; then
      smartctl -X "$DEV" >/dev/null 2>&1; aborted=1; break
    fi
  done
  sleep 1
  el=$(( $(date +%s) - start ))
  after=$(last_result)

  local code text what hours verdict badge
  IFS='|' read -r code text what hours <<< "$after"
  case "$code" in *[!0-9]*) code="" ;; esac          # jq prints "null" for a missing field
  # The same newest entry as before means the drive logged nothing new.
  [ "$after" = "$before" ] && [ "$aborted" = 0 ] && code=""
  is_nvme && [ -n "$code" ] && text=$(nvme_result_text "$code")

  if [ "$aborted" = 1 ]; then
    badge=PARTIAL; verdict="CANCELLED after $(secs_ms "$el")"
  elif [ "$aborted" = 2 ]; then
    badge=FAIL; verdict="FAIL (still running after $cap_min minutes - the drive may be hung)"
  elif [ -z "$code" ]; then
    badge=UNKNOWN; verdict="UNKNOWN (the drive logged no result)"
  elif [ "$code" = 0 ]; then
    badge=PASS; verdict="PASS ($label $text in $(secs_ms "$el"))"
  elif ! is_nvme || { [ "$code" -ge 5 ] && [ "$code" -le 7 ]; }; then
    badge=FAIL; verdict="FAIL ($text)"
  else
    badge=PARTIAL; verdict="INCOMPLETE ($text)"
  fi

  rsection "DRIVE SELF-TEST -- /dev/$DISK"
  rsilent "Drive       : /dev/$DISK  $(lsblk -dno MODEL,SIZE "/dev/$DISK" 2>/dev/null | sed 's/  */ /g')"
  rsilent "Test        : $label"
  rsilent "Elapsed     : $(secs_ms "$el")"
  rsilent "Drive says  : ${text:-nothing logged}"
  smartctl -l selftest "$DEV" 2>/dev/null | sed -n '/[Ss]elf-test [Ll]og/,$p' | head -12 \
    | sed 's/^/  /' >> "$REPORT_TXT"
  rsilent "RESULT: $verdict"
  set_kv DISK_SELFTEST "$verdict"

  tui_frame "$label - /dev/$DISK" "Enter to go back"
  case "$badge" in
    PASS)    tui_badge 6 PASS "the drive found nothing wrong with itself" ;;
    FAIL)    tui_badge 6 FAIL "the drive reports a fault" ;;
    PARTIAL) tui_badge 6 PARTIAL "the test did not finish" ;;
    *)       tui_badge 6 UNKNOWN "no result was logged" ;;
  esac
  tui_kv 9  "Drive says" "${text:-nothing}" "$( [ "$badge" = PASS ] && echo ok || echo warn )"
  tui_kv 10 "Elapsed"    "$(secs_ms "$el")"
  if [ "$badge" = FAIL ]; then
    tui_line 12 "A drive that fails its own self-test should be replaced, whatever" err
    tui_line 13 "the benchmark says. The self-test log is in the report." muted
  elif [ "$kind" = short ] && [ "$badge" = PASS ]; then
    tui_line 12 "The short test samples the drive. The extended test reads all of it." muted
  fi
  tui_flush
  tui_anykey
  return 0
}

# ---------------------------------------------------------------- main
pick_drive || exit 0
DEV=$(smart_dev "$DISK")

if ! supports_selftest; then
  tui_msg "No self-test on this drive" \
    "/dev/$DISK does not implement the optional self-test command." "" \
    "That is common on budget drives and is not a fault." \
    "Use SMART health and the surface read scan instead."
  rsection "DRIVE SELF-TEST -- /dev/$DISK"
  rsilent "RESULT: NOT SUPPORTED -- the drive does not implement self-test"
  set_kv DISK_SELFTEST "NOT SUPPORTED"
  exit 0
fi

if [ "$(progress)" != idle ]; then
  if tui_confirm "A self-test is already running" no \
       "/dev/$DISK is in the middle of a self-test started earlier." "" \
       "Stop it so a new one can start?"; then
    smartctl -X "$DEV" >/dev/null 2>&1; sleep 2
  else
    exit 0
  fi
fi

ext=$(extended_minutes)
ext_label="reads the whole drive"
[ "$ext" -gt 0 ] && ext_label="reads the whole drive - about $ext min by the drive's estimate"
tui_menu "Drive self-test - /dev/$DISK" "arrows + Enter, Q to go back" \
  "Short|about 2 minutes - checks the controller and samples the media" \
  "Extended|$ext_label" || exit 0
case "$TUI_CHOICE" in
  1) run_selftest short ;;
  2) run_selftest long ;;
esac
