#!/bin/bash
# GPU check - every graphics chip on the PCI bus: is it there, does it wake,
# does it talk over a healthy link, has it logged link errors.
#
# Invariant 1: this image carries no GPU driver (i915, xe, amdgpu, nouveau,
# radeon) - i915 froze a SATELLITE PRO C40-K at boot - so nothing here loads
# one or draws through one. Everything is read from PCI config space and
# sysfs (lspci, setpci, the AER counters, the kernel log); the screen runs on
# the firmware framebuffer and has its own test. What this cannot see: 3D
# speed, the video memory, a GPU that draws garbage. Ash chose this over a
# stress test that would need the drivers back (1.24).
#   gputest.sh          the screen
#   gputest.sh --quiet  check and report only (Full run)
. /opt/diag/lib.sh
QUIET=0; [ "$1" = --quiet ] && QUIET=1
[ "$QUIET" = 1 ] || . /opt/diag/tui.sh
PCI=${DIAG_PCI_ROOT:-/sys/bus/pci/devices}

name_of() {   # pci id -> "Intel UHD Graphics 620"-style name
  local n
  n=$(lspci -mm -s "$1" 2>/dev/null | awk -F'"' 'NR==1 {v=$4; sub(/ Corporation$/, "", v); sub(/ Inc\.?$/, "", v); print v " " $6}')
  printf '%s' "${n:-PCI device $(sed 's/^0x//' "$PCI/$1/vendor" 2>/dev/null):$(sed 's/^0x//' "$PCI/$1/device" 2>/dev/null)}"
}

aer_total() {   # aer_dev_* file -> its TOTAL_ count; 0 when the kernel keeps none
  [ -r "$1" ] || { echo 0; return; }
  awk '/^TOTAL_/ {print $2; f = 1} END {if (!f) print 0}' "$1"
}

vram_window() {   # pci id -> the largest prefetchable BAR ("256 MB"), or nothing
  local s e f best=0 size
  while read -r s e f; do
    case "$s" in 0x*) ;; *) continue ;; esac
    (( f & 0x2000 )) || continue             # IORESOURCE_PREFETCH: the memory window
    size=$(( e - s + 1 ))
    [ "$size" -gt "$best" ] && best=$size
  done < "$PCI/$1/resource" 2>/dev/null
  if [ "$best" -ge 1073741824 ]; then echo "$(( best / 1073741824 )) GB"
  elif [ "$best" -gt 0 ]; then echo "$(( best / 1048576 )) MB"; fi
  return 0
}

# One GPU: wake it, read it, put its power setting back. Sets G_*.
check_gpu() {
  local id=$1 d=$PCI/$1 up ctl_d ctl_u v
  G_NAME=$(name_of "$id")
  G_SCREEN=$( [ "$(cat "$d/boot_vga" 2>/dev/null)" = 1 ] && echo yes || echo no )
  case "$id" in *:00:*) G_KIND=built-in ;; *) G_KIND=discrete ;; esac
  G_POWER0=$(cat "$d/power_state" 2>/dev/null)
  # A discrete GPU the firmware switched off (D3cold) reads as nothing at
  # all: power it and the port above it on first, so "not answering" means
  # the chip, not the power saving. Both settings are put back after.
  up=$(readlink -f "$d/.."); up=${up##*/}
  ctl_d=$(cat "$d/power/control" 2>/dev/null)
  echo on > "$d/power/control" 2>/dev/null
  if [ -w "$PCI/$up/power/control" ]; then
    ctl_u=$(cat "$PCI/$up/power/control" 2>/dev/null)
    echo on > "$PCI/$up/power/control" 2>/dev/null
  fi
  sleep 1
  G_POWER=$(cat "$d/power_state" 2>/dev/null)
  # the cached vendor file never changes; setpci reads the chip now
  v=$(setpci -s "$id" VENDOR_ID 2>/dev/null)
  case "$v" in ''|ffff|FFFF) G_ANSWERS=no ;; *) G_ANSWERS=yes ;; esac
  G_SPEED=$(cat "$d/current_link_speed" 2>/dev/null); G_MAXSPEED=$(cat "$d/max_link_speed" 2>/dev/null)
  G_WIDTH=$(cat "$d/current_link_width" 2>/dev/null); G_MAXWIDTH=$(cat "$d/max_link_width" 2>/dev/null)
  G_FATAL=$(aer_total "$d/aer_dev_fatal")
  G_NONFATAL=$(aer_total "$d/aer_dev_nonfatal")
  G_CORR=$(aer_total "$d/aer_dev_correctable")
  G_LOG=$( { cat "$RUN_DIR/boot-dmesg.log" 2>/dev/null; dmesg 2>/dev/null; } \
    | grep -F "${id#0000:}" | grep -iE 'fallen off|AER|not ready|timed out|unable to change power|link (is )?down|error' \
    | sed 's/^\[[ 0-9.]*\] *//' | sort -u | tail -3)
  G_VRAM=$(vram_window "$id")
  [ -n "$ctl_d" ] && echo "$ctl_d" > "$d/power/control" 2>/dev/null
  [ -n "$ctl_u" ] && echo "$ctl_u" > "$PCI/$up/power/control" 2>/dev/null
  return 0
}

# The verdict on the GPU just read: G_STATE PASS / WARN / FAIL and G_WHY.
judge_gpu() {
  G_STATE=PASS; G_WHY="answers, powers up and talks over a healthy link"
  if [ "$G_ANSWERS" = no ]; then
    G_STATE=FAIL; G_WHY="does not answer on the PCI bus - a dead GPU, or it lost its power or its solder joints"
  elif [ "${G_FATAL:-0}" -gt 0 ] || [ "${G_NONFATAL:-0}" -gt 0 ] || printf '%s' "$G_LOG" | grep -qi 'fallen off'; then
    G_STATE=FAIL; G_WHY="logged uncorrected link errors - the link to the chip breaks down"
  elif [ -n "$G_WIDTH" ] && [ -n "$G_MAXWIDTH" ] && [ "$G_WIDTH" -gt 0 ] 2>/dev/null \
       && [ "$G_WIDTH" -lt "$G_MAXWIDTH" ] 2>/dev/null; then
    # lanes, not speed: a GPU slows its link when idle on purpose, but it
    # never gives up lanes unless a contact is open
    G_STATE=WARN; G_WHY="links on x$G_WIDTH of its x$G_MAXWIDTH lanes - reseat it (a card), or the solder under the chip is failing"
  elif [ "${G_CORR:-0}" -gt 0 ]; then
    G_STATE=WARN; G_WHY="$G_CORR corrected link errors - the link works but is noisy"
  fi
  return 0
}

# ---------------------------------------------------------------- check
if [ "$QUIET" = 0 ]; then
  tui_frame "GPU check" "please wait"
  tui_line 6 "Looking for every graphics chip and waking the discrete one..." muted
  tui_flush
fi
IDS=()
for d in "$PCI"/*; do
  case "$(cat "$d/class" 2>/dev/null)" in 0x03*) IDS+=("${d##*/}") ;; esac
done

STATE=PASS; ROWS=(); REP=(); n=0; why=""
for id in "${IDS[@]}"; do
  check_gpu "$id"; judge_gpu
  n=$((n + 1))
  case "$G_STATE" in
    FAIL) STATE=FAIL; why="$G_NAME $G_WHY" ;;
    WARN) [ "$STATE" = PASS ] && STATE=WARN; [ -z "$why" ] && why="$G_NAME $G_WHY" ;;
  esac
  link="-"; [ -n "$G_WIDTH" ] && [ "$G_WIDTH" != 0 ] && link="x$G_WIDTH of x$G_MAXWIDTH, ${G_SPEED%% PCIe*}"
  errs="none"
  [ "$((G_FATAL + G_NONFATAL + G_CORR))" -gt 0 ] && errs="fatal $G_FATAL, uncorrected $G_NONFATAL, corrected $G_CORR"
  power=${G_POWER:-D0}; [ -n "$G_POWER0" ] && [ "$G_POWER0" != "$G_POWER" ] && power="$G_POWER (woken from $G_POWER0)"
  where=$G_KIND; [ "$G_SCREEN" = yes ] && where="$G_KIND, drives the screen"
  ROWS+=("$G_NAME|$where|$G_STATE|$power|$link|$errs|$G_VRAM")
  REP+=("GPU $n         : $G_NAME  ($id, $where)"
        "  answers     : $G_ANSWERS   power: $power"
        "  PCIe link   : $link"
        "  link errors : $errs"
        "  memory window: ${G_VRAM:--}"
        "  verdict     : $G_STATE - $G_WHY")
  [ -n "$G_LOG" ] && while IFS= read -r l; do REP+=("  log: $l"); done <<< "$G_LOG"
done

if [ "$n" -eq 0 ]; then
  STATE=UNKNOWN; CAUSE="no graphics chip on the PCI bus - the screen runs on the firmware's own framebuffer"
elif [ "$STATE" = PASS ]; then
  CAUSE="$n GPU(s): each answers, powers up and talks over a healthy link"
else
  CAUSE=$why
fi
case "$STATE" in
  PASS) VERDICT="PASS ($CAUSE)" ;;  WARN) VERDICT="MARGINAL ($CAUSE)" ;;
  FAIL) VERDICT="FAIL ($CAUSE)" ;;  *)    VERDICT="NOT TESTED ($CAUSE)" ;;
esac
fb=$(tr ',' 'x' < /sys/class/graphics/fb0/virtual_size 2>/dev/null)

rsection "GPU"
for l in "${REP[@]}"; do rsilent "$l"; done
rsilent "Screen        : firmware framebuffer ${fb:-unknown} (no GPU driver - invariant 1)"
rsilent "RESULT: $VERDICT"
set_kv GPU_RESULT "$VERDICT"
[ "$QUIET" = 1 ] && exit 0

# ---------------------------------------------------------------- screen
tui_frame "GPU check" "Enter to go back"
case "$STATE" in
  PASS) tui_badge 6 PASS "$n GPU(s) answer on a healthy link" ;;
  WARN) tui_badge 6 MARGINAL "a GPU link is not right" ;;
  FAIL) tui_badge 6 FAIL "a GPU is faulty" ;;
  *)    tui_badge 6 UNKNOWN "no GPU found" ;;
esac
row=8
for r in "${ROWS[@]}"; do
  [ "$row" -gt 16 ] && break
  IFS='|' read -r nm where st power link errs vram <<< "$r"
  tone=ok; [ "$st" = WARN ] && tone=warn; [ "$st" = FAIL ] && tone=err
  tui_kv $row "$nm" "$where" "$tone"; row=$((row + 1))
  tui_kv $row "Power / PCIe link" "$power   $link"; row=$((row + 1))
  tui_kv $row "Link errors" "$errs" "$( [ "$errs" = none ] && echo ok || echo warn )"; row=$((row + 1))
  [ -n "$vram" ] && { tui_kv $row "Memory window" "$vram"; row=$((row + 1)); }
  row=$((row + 1))
done
[ "$STATE" != PASS ] && row=$(tui_para $row "$CAUSE" "$( [ "$STATE" = FAIL ] && echo err || echo warn )")
tui_para $row "Without its own driver this checks that a GPU is there, wakes and talks over a healthy link - not its 3D speed or its video memory. The Screen test covers the panel." muted >/dev/null
tui_flush
tui_anykey
exit 0
