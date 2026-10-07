#!/bin/bash
# SD card reader test.
#
# Most of the bench's laptops have a microSD or SD slot and nothing tested
# it. Like the USB test (invariant 6), the slot only counts when a card goes
# in during the test - a card already sitting in it, or a soldered eMMC
# drive that looks like one, is listed but not counted. Then:
#   - the card's bus mode (UHS-I SDR104 ~ 90 MB/s, High Speed ~ 23 MB/s ...),
#     read from the kernel's view of the slot
#   - a short read of the card - read only: nothing is ever written to it
#   - taking it out again: a reader that never notices the card leaving has
#     a stuck card-detect switch, the other common slot fault
# Readers on the PCIe bus (Realtek rtsx, sdhci) appear as mmcblkN; USB ones
# (most external and some internal readers) as an sdX that reads 0 bytes
# while empty.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

WAIT_IN=60; WAIT_OUT=30
READ_MB=256; READ_SECS=20

load_modules() {
  local m
  for m in sdhci_pci rtsx_pci_sdmmc rtsx_usb_sdmmc mmc_block; do modprobe "$m" 2>/dev/null; done
  sleep 1
}

key() { _ask waitkey "$1"; KEY=$(printf '%s' "$UI_ANS" | tr '[:upper:]' '[:lower:]'); }

usb_reader() {   # sdX -> 0 when it is a USB card reader's slot
  local b=/sys/block/$1
  [ "$(cat "$b/removable" 2>/dev/null)" = 1 ] || return 1
  readlink -f "$b" | grep -q '/usb' || return 1
  [ "$(cat "$b/size" 2>/dev/null)" = 0 ] && return 0          # an empty slot
  cat "$b/device/vendor" "$b/device/model" 2>/dev/null | tr '\n' ' ' \
    | grep -qiE 'sd/|mmc|card|reader|multi|xd/|ms pro'
}

# The readers the kernel can see, for the first screen.
readers() {
  local h drv dev name s
  for h in /sys/class/mmc_host/mmc*; do
    [ -e "$h" ] || continue
    # eMMC soldered to the board is a drive, not a slot
    grep -qx MMC "$h"/mmc*/type 2>/dev/null && continue
    dev=$(readlink -f "$h/device")
    drv=$(basename "$(readlink -f "$dev/driver" 2>/dev/null)")
    name=""
    case "$dev" in
      */pci*) name=$(lspci -s "$(basename "$dev")" 2>/dev/null | sed 's/^[^ ]* //; s/^[^:]*: //') ;;
    esac
    printf '%s|%s\n' "${h##*/}" "${name:-$drv}"
  done
  for s in /sys/block/sd*; do
    [ -e "$s" ] || continue
    usb_reader "${s##*/}" || continue
    printf '%s|USB card reader: %s\n' "${s##*/}" \
      "$(cat "$s/device/vendor" "$s/device/model" 2>/dev/null | tr -s ' \n' ' ' | sed 's/ $//')"
  done
}

cards() {   # every card in a slot now: "dev|bytes"
  local b n
  for b in /sys/block/mmcblk[0-9]*; do
    [ -e "$b" ] || continue
    n=${b##*/}
    case "$n" in *boot*|*rpmb*) continue ;; esac
    [ "$(cat "$b/device/type" 2>/dev/null)" = MMC ] && continue    # eMMC
    printf '%s|%s\n' "$n" $(( $(cat "$b/size" 2>/dev/null || echo 0) * 512 ))
  done
  for b in /sys/block/sd*; do
    [ -e "$b" ] || continue
    usb_reader "${b##*/}" || continue
    [ "$(cat "$b/size" 2>/dev/null)" -gt 0 ] 2>/dev/null || continue
    printf '%s|%s\n' "${b##*/}" $(( $(cat "$b/size") * 512 ))
  done
}

# How the slot is talking to the card: "sd uhs SDR104, 208 MHz, 4 bits".
# Only the kernel's debug view says; it is mounted here if it is not.
bus_mode() {   # mmcblkN -> mode text, or nothing
  local host ios
  host=$(basename "$(readlink -f "/sys/block/$1/device/..")")
  mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug >> "$RUN_DIR/sdtest.log" 2>&1
  ios=/sys/kernel/debug/$host/ios
  printf 'bus mode: host %s, %s\n' "$host" "$( [ -r "$ios" ] && echo "ios readable" || echo "no $ios")" >> "$RUN_DIR/sdtest.log"
  [ -r "$ios" ] || return 1
  # "timing spec:\t6 (sd uhs SDR104)" - the kernel pads after the colon with
  # TABs, not spaces. Splitting on ": *" kept a TAB in the value, and a TAB
  # inside a tui_kv value cut the renderer's line: "Bus mode" came out blank
  # (1.20, VM). Split on either, and never pass a TAB on.
  awk -F':[ \t]*' '
    /^timing spec/ { t = $2; sub(/^[0-9]+ \(/, "", t); sub(/\)$/, "", t) }
    /^clock/       { c = $2 + 0 }
    /^bus width/   { w = $2; sub(/^[0-9]+ \(/, "", w); sub(/\)$/, "", w) }
    END { if (t != "") printf "%s, %.0f MHz, %s", t, c / 1000000, w }' "$ios" | tr '\t' ' '
}

card_info() {   # dev -> "SD card, SanDisk SC64G (made 08/2023)", or the USB reader's model
  local d=/sys/block/$1/device t name mid date
  if [ -r "$d/type" ]; then
    t=$(cat "$d/type"); name=$(cat "$d/name" 2>/dev/null); mid=$(cat "$d/manfid" 2>/dev/null)
    date=$(cat "$d/date" 2>/dev/null)
    case "$mid" in
      0x000003) mid=SanDisk ;; 0x000002) mid=Toshiba/Kioxia ;; 0x00001b) mid=Samsung ;;
      0x000074) mid=Transcend ;; 0x000027) mid=Phison ;; 0x000028) mid=Lexar ;;
      0x00009f|0x000041) mid=Kingston ;; *) mid="maker $mid" ;;
    esac
    printf '%s card, %s %s%s' "$t" "$mid" "$name" "${date:+ (made $date)}"
  else
    printf 'card in %s' "$(sed 's/ *$//' "$d/model" 2>/dev/null)"
  fi
}

human_gb() { awk -v b="$1" 'BEGIN{ if (b >= 1e9) printf "%.1f GB", b/1e9; else printf "%.0f MB", b/1e6 }'; }

# A read straight off the card, past the page cache: what the slot delivers.
# In 8 MB pieces, each allowed 10 s and all of them 20 s together: a slot
# dying mid-read hangs its piece instead of the test, a slow one is measured
# on what it managed. The speed is MB actually read over the time taken -
# 1.20's first VM run divided the size asked for by the time to a failure
# and reported "4.1 MB/s" for a read that had died half way.
read_test() {   # dev bytes -> READ_MBS READ_OK READ_SIZE (MB read) READ_CAPPED
  local total=$(( $2 / 1048576 )) piece=8 done=0 n rc=0 t0 t1 out
  [ "$total" -gt "$READ_MB" ] && total=$READ_MB
  [ "$total" -lt 1 ] && total=1
  READ_CAPPED=""
  t0=$(date +%s%N)
  while [ "$done" -lt "$total" ]; do
    n=$piece; [ $(( done + n )) -gt "$total" ] && n=$(( total - done ))
    out=$(timeout 10 dd if="/dev/$1" of=/dev/null bs=1M skip="$done" count="$n" iflag=direct 2>&1)
    rc=$?
    [ "$rc" = 0 ] || { printf 'read stopped at %s MB, rc %s: %s\n' "$done" "$rc" "$out" >> "$RUN_DIR/sdtest.log"; break; }
    done=$(( done + n ))
    if [ $(( ($(date +%s%N) - t0) / 1000000000 )) -ge "$READ_SECS" ] && [ "$done" -lt "$total" ]; then
      READ_CAPPED=yes; break
    fi
  done
  t1=$(date +%s%N)
  READ_SIZE=$done
  READ_MBS=$(awk -v m="$done" -v ns=$(( t1 - t0 )) 'BEGIN{ if (ns > 0 && m > 0) printf "%.1f", m * 1.048576 / (ns / 1e9) }')
  if [ "$rc" = 0 ] && [ "$done" -gt 0 ]; then READ_OK=0; else READ_OK=1; fi
  printf 'read %s MB in %s ms%s\n' "$done" $(( (t1 - t0) / 1000000 )) "${READ_CAPPED:+ (time cap)}" >> "$RUN_DIR/sdtest.log"
}

# ---------------------------------------------------------------- run
tui_frame "SD card reader" "please wait"
tui_line 6 "Looking for card readers..." muted
tui_flush
load_modules

mapfile -t READERS < <(readers)
mapfile -t BEFORE < <(cards)

tui_frame "SD card reader" "S = skip    Q = stop"
row=6
if [ ${#READERS[@]} -gt 0 ]; then
  for r in "${READERS[@]}"; do
    [ $row -gt 9 ] && break
    tui_kv $row "Reader" "${r#*|}"; row=$((row+1))
  done
else
  tui_kv $row "Reader" "none seen yet - a USB reader shows up once a card is in" warn; row=$((row+1))
fi
for c in "${BEFORE[@]}"; do
  tui_line $row "Already in a slot (not counted): ${c%%|*} - $(card_info "${c%%|*}")" muted; row=$((row+1))
done
row=$((row+1))
tui_line $row "Insert an SD or microSD card into the laptop's slot." ""
tui_flush

mark=$(dmesg_mark)
DEV=""; BYTES=0; KEY=""
for (( t = 0; t < WAIT_IN; t++ )); do
  while IFS='|' read -r d b; do
    [ -z "$d" ] && continue
    printf '%s\n' "${BEFORE[@]}" | grep -q "^$d|" && continue
    DEV=$d; BYTES=$b; break
  done < <(cards)
  [ -n "$DEV" ] && break
  tui_line $((row+1)) "Waiting for a card... $(( WAIT_IN - t )) s" muted
  tui_flush
  key 1; case "$KEY" in q|s) break ;; esac
done

STATE=""; CAUSE=""; ACTION=""; MODE=""; INFO=""; READ_MBS=""; READ_OK=1; READ_SIZE=0; OUT_SEEN=""; KERR=0
if [ -z "$DEV" ]; then
  INSERTED=no
  if [ "$KEY" != q ] && [ "$KEY" != s ]; then
    tui_menu "No card was seen. Was one inserted?" "" \
      "No - I had no card to hand|the reader is not tested" \
      "Yes - a card is in the slot|the reader did not see it" && [ "$TUI_CHOICE" = 2 ] && INSERTED=yes
  fi
  if [ "$INSERTED" = yes ]; then
    STATE=FAIL; CAUSE="a card went in but the reader never saw it"
    ACTION="Try a second card you know works. If that is not seen either: the slot's contacts (bent or dirty), its card-detect switch, or the reader chip - Driver check shows whether the reader's driver came up."
  else
    STATE=NOTTESTED; CAUSE="no card was inserted"
  fi
else
  INFO=$(card_info "$DEV")
  case "$DEV" in mmcblk*) MODE=$(bus_mode "$DEV") ;; esac
  tui_frame "SD card reader" "reading the card"
  tui_kv 6 "Card" "$INFO" ok
  tui_kv 7 "Size" "$(human_gb "$BYTES")"
  [ -n "$MODE" ] && tui_kv 8 "Bus mode" "$MODE"
  tui_line 10 "Reading the card for up to $READ_SECS s - nothing is written to it..." muted
  tui_flush
  read_test "$DEV" "$BYTES"
  KERR=$(dmesg_since "$mark" | grep -ciE "($DEV|mmc[0-9]+):? .*(error|timeout)|I/O error, dev $DEV")

  # Out again: the card-detect switch must notice that too.
  tui_frame "SD card reader" "take the card out"
  tui_kv 6 "Card" "$INFO" ok
  tui_kv 7 "Read speed" "${READ_MBS:-?} MB/s over $READ_SIZE MB" "$( [ "$READ_OK" = 0 ] && echo ok || echo err )"
  tui_line 9 "Now take the card out of the slot." ""
  tui_flush
  OUT_SEEN=no; KEY=""
  for (( t = 0; t < WAIT_OUT; t++ )); do
    cards | grep -q "^$DEV|" || { OUT_SEEN=yes; break; }
    tui_line 10 "Waiting for the card to go... $(( WAIT_OUT - t )) s" muted; tui_flush
    key 1; case "$KEY" in q|s) break ;; esac
  done

  if [ "$READ_OK" != 0 ] || [ "${KERR:-0}" -gt 0 ]; then
    STATE=FAIL; CAUSE="the card was seen but could not be read cleanly"
    ACTION="Try a second card. If every card fails to read, the slot's contacts or the reader; if only this one, the card."
  elif [ "$OUT_SEEN" = no ] && [ "$KEY" != q ] && [ "$KEY" != s ]; then
    STATE=WARN; CAUSE="the reader did not notice the card being taken out"
    ACTION="The card-detect switch inside the slot is stuck. Windows will keep showing a card that is not there; clean or replace the slot."
  elif awk -v s="${READ_MBS:-0}" 'BEGIN{exit !(s < 2)}'; then
    STATE=WARN; CAUSE="reads at only ${READ_MBS} MB/s"
    ACTION="Even old cards manage 10 MB/s. Try a faster card; if it is just as slow, the reader runs in a fallback mode."
  else
    STATE=PASS; CAUSE="the card was seen, read at ${READ_MBS} MB/s, and its removal noticed"
  fi
fi

# ---------------------------------------------------------------- report
rsection "SD CARD READER"
if [ ${#READERS[@]} -gt 0 ]; then
  for r in "${READERS[@]}"; do rsilent "Reader          : ${r#*|} (${r%%|*})"; done
else
  rsilent "Reader          : none seen by the kernel"
fi
for c in "${BEFORE[@]}"; do rsilent "Already present : ${c%%|*} - not counted"; done
if [ -n "$DEV" ]; then
  rsilent "Card inserted   : $DEV - $INFO, $(human_gb "$BYTES")"
  [ -n "$MODE" ] && rsilent "Bus mode        : $MODE"
  rsilent "Read            : ${READ_MBS:-?} MB/s over ${READ_SIZE} MB (read only)$( [ "$READ_OK" = 0 ] || echo " - FAILED")"
  [ "${KERR:-0}" -gt 0 ] && rsilent "Kernel errors   : $KERR while reading"
  rsilent "Removal noticed : ${OUT_SEEN:-not checked}"
fi
if [ -n "$ACTION" ]; then
  rsilent "What to do      :"
  printf '%s\n' "$ACTION" | fold -s -w 72 | sed 's/^/    /' >> "$REPORT_TXT"
fi
case "$STATE" in
  PASS) VERDICT="PASS ($CAUSE)" ;;
  WARN) VERDICT="WARN ($CAUSE)" ;;
  FAIL) VERDICT="FAIL ($CAUSE)" ;;
  *)    VERDICT="NOT TESTED ($CAUSE)" ;;
esac
rsilent "RESULT: $VERDICT"
set_kv SD_RESULT "$VERDICT"

tui_frame "SD card reader" "Enter to go back"
case "$STATE" in
  PASS) tui_badge 6 PASS "the slot reads cards" ;;
  WARN) tui_badge 6 WARN "reads cards, with a fault" ;;
  FAIL) tui_badge 6 FAIL "the slot does not work" ;;
  *)    tui_badge 6 UNKNOWN "not tested" ;;
esac
row=9
if [ -n "$DEV" ]; then
  tui_kv $row "Card" "$INFO, $(human_gb "$BYTES")"; row=$((row+1))
  [ -n "$MODE" ] && { tui_kv $row "Bus mode" "$MODE"; row=$((row+1)); }
  tui_kv $row "Read speed" "${READ_MBS:-?} MB/s" "$( [ "$READ_OK" = 0 ] && echo ok || echo err )"; row=$((row+1))
  tui_kv $row "Removal noticed" "${OUT_SEEN:-not checked}" "$( [ "$OUT_SEEN" = yes ] && echo ok || echo warn )"; row=$((row+1))
fi
row=$((row+1))
row=$(tui_para $row "$CAUSE" "$(case "$STATE" in PASS) echo ok ;; FAIL) echo err ;; WARN) echo warn ;; *) echo muted ;; esac)")
[ -n "$ACTION" ] && row=$(tui_para $row "$ACTION" "")
tui_flush
tui_anykey
exit 0
