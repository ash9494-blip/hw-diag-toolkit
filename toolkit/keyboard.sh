#!/bin/bash
# Keyboard test - draws the layout and lights up each key as it is pressed.
#
# Raw keycodes come from showkey(1), which puts the console keyboard into raw
# mode for the duration. That has two useful side effects: nothing leaks into
# the shell, and Alt+Fn cannot switch virtual terminals by accident.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

LOG=$RUN_DIR/keys.log

declare -A KPOS      # keycode -> "row col width"
declare -A KLABEL    # keycode -> label
declare -A KSTATE    # keycode -> new | down | done
declare -A KCOUNT    # keycode -> number of presses

KB_ROWS=0

# def <row> <keycode:label:width> ...
def_row() {
  local row=$1; shift
  local col=0 item code label width
  for item in "$@"; do
    if [ "$item" = "--" ]; then col=$((col+2)); continue; fi
    code=${item%%:*}; item=${item#*:}
    label=${item%%:*}; width=${item##*:}
    KPOS[$code]="$row $col $width"
    KLABEL[$code]="$label"
    KSTATE[$code]=new
    KCOUNT[$code]=0
    col=$(( col + width + 1 ))
  done
  [ "$col" -gt "$KB_WIDTH" ] && KB_WIDTH=$col
  [ "$row" -ge "$KB_ROWS" ] && KB_ROWS=$((row+1))
}

KB_WIDTH=0
build_layout() {
  def_row 0  1:Esc:4 -- 59:F1:4 60:F2:4 61:F3:4 62:F4:4 -- 63:F5:4 64:F6:4 65:F7:4 66:F8:4 \
             -- 67:F9:4 68:F10:4 87:F11:4 88:F12:4
  def_row 1  41:\`:3 2:1:3 3:2:3 4:3:3 5:4:3 6:5:3 7:6:3 8:7:3 9:8:3 10:9:3 11:0:3 12:-:3 13:=:3 14:Bksp:7
  def_row 2  15:Tab:5 16:Q:3 17:W:3 18:E:3 19:R:3 20:T:3 21:Y:3 22:U:3 23:I:3 24:O:3 25:P:3 \
             26:[:3 27:]:3 43:\\:4
  def_row 3  58:Caps:6 30:A:3 31:S:3 32:D:3 33:F:3 34:G:3 35:H:3 36:J:3 37:K:3 38:L:3 \
             39:\;:3 40:\':3 28:Enter:8
  def_row 4  42:Shift:8 44:Z:3 45:X:3 46:C:3 47:V:3 48:B:3 49:N:3 50:M:3 51:,:3 52:.:3 53:/:3 54:Shift:8
  def_row 5  29:Ctrl:5 125:Win:4 56:Alt:4 57:Space:22 100:AltGr:5 97:Ctrl:5
  def_row 7  110:Ins:4 102:Home:5 104:PgUp:5 -- 103:Up:4 -- 99:PrtSc:6 119:Paus:5
  def_row 8  111:Del:4 107:End:5 109:PgDn:5 -- 105:Lt:4 108:Dn:4 106:Rt:4
}

# ---------------------------------------------------------------- drawing
KB_TOP=7
key_colour() {
  case "${KSTATE[$1]}" in
    down) printf '%s' "${E}[46m${E}[30m" ;;   # pressed right now
    done) printf '%s' "${E}[42m${E}[30m" ;;   # already registered
    stuck) printf '%s' "${E}[41m${E}[30m" ;;  # held far too long
    *)    printf '%s' "${TRACK}${E}[37m" ;;   # never seen
  esac
}

draw_key() {
  local code=$1 row col width lbl pad len left right
  read -r row col width <<< "${KPOS[$code]}"
  lbl=${KLABEL[$code]}
  # centre the label inside the key
  len=${#lbl}
  [ "$len" -gt "$width" ] && { lbl=${lbl:0:$width}; len=$width; }
  left=$(( (width - len) / 2 )); right=$(( width - len - left ))
  tui_at $(( KB_TOP + row )) $(( TUI_PAD + KB_LEFT + col ))
  printf '%s%*s%s%*s%s' "$(key_colour "$code")" "$left" "" "$lbl" "$right" "" "$R"
}

draw_all() {
  local c
  for c in "${!KPOS[@]}"; do draw_key "$c"; done
}

stats_line() {
  local total=0 seen=0 c
  for c in "${!KPOS[@]}"; do
    total=$((total+1))
    [ "${KSTATE[$c]}" = done ] || [ "${KSTATE[$c]}" = down ] && seen=$((seen+1))
  done
  KB_TOTAL=$total; KB_SEEN=$seen
  tui_kv $(( KB_TOP + KB_ROWS + 1 )) "Keys registered" "$seen of $total"
  tui_bar $(( KB_TOP + KB_ROWS + 2 )) $(( seen * 100 / total ))
}

# ---------------------------------------------------------------- test
run_test() {
  build_layout
  KB_LEFT=$(( (TUI_W - KB_WIDTH) / 2 )); [ "$KB_LEFT" -lt 1 ] && KB_LEFT=1

  if [ "$TUI_W" -lt "$KB_WIDTH" ]; then
    tui_msg "Screen too narrow" "The keyboard layout needs ${KB_WIDTH} columns and this console has ${TUI_W}." \
      "Try the safe-graphics boot entry, which usually gives a wider console."
    return
  fi

  tui_frame "Keyboard test" "press every key    ESC three times to finish    stops 10 s after the last key"
  draw_all
  stats_line
  tui_line $(( KB_TOP + KB_ROWS + 4 )) "Green = registered   Cyan = held down   Grey = not seen yet" "$MUTE"
  tui_line $(( KB_TOP + KB_ROWS + 5 )) "The Fn key itself is handled inside the keyboard controller and never reaches the OS." "$MUTE"

  : > "$LOG"
  # showkey's stdout is a file here, so libc would block-buffer it and no key
  # would appear until the very end. stdbuf forces line buffering.
  stdbuf -oL showkey -k > "$LOG" 2>&1 &
  local skpid=$!
  sleep 0.5
  if ! kill -0 $skpid 2>/dev/null && grep -qi 'couldn.t\|not a console\|inappropriate' "$LOG"; then
    tui_msg "Cannot read the keyboard" "showkey could not take over the console." \
      "This test only works on the machine's own screen, not over a serial console."
    return
  fi

  local last=0 n line code act esc_hits=0 esc_last=0 now
  local -A DOWN_SINCE
  while kill -0 $skpid 2>/dev/null; do
    n=$(wc -l < "$LOG" 2>/dev/null); n=${n:-0}
    if [ "$n" -gt "$last" ]; then
      while IFS= read -r line; do
        case "$line" in
          *keycode*press*)   act=press ;;
          *keycode*release*) act=release ;;
          *) continue ;;
        esac
        code=$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if ($i=="keycode") {print $(i+1); exit}}')
        [ -z "${KPOS[$code]}" ] && continue
        now=$(date +%s)
        if [ "$act" = press ]; then
          KSTATE[$code]=down
          KCOUNT[$code]=$(( ${KCOUNT[$code]} + 1 ))
          DOWN_SINCE[$code]=$now
          if [ "$code" = 1 ]; then
            [ $(( now - esc_last )) -le 3 ] && esc_hits=$((esc_hits+1)) || esc_hits=1
            esc_last=$now
          fi
        else
          KSTATE[$code]=done
          unset "DOWN_SINCE[$code]"
        fi
        draw_key "$code"
      done < <(sed -n "$((last+1)),${n}p" "$LOG")
      last=$n
      stats_line
      [ "$esc_hits" -ge 3 ] && { kill $skpid 2>/dev/null; break; }
    fi
    # a key still down after 5 s is stuck
    now=$(date +%s)
    for code in "${!DOWN_SINCE[@]}"; do
      if [ $(( now - ${DOWN_SINCE[$code]} )) -ge 5 ]; then
        KSTATE[$code]=stuck; draw_key "$code"
      fi
    done
    sleep 0.15
  done
  wait $skpid 2>/dev/null
  # showkey restores the keyboard mode itself, but make sure
  kbd_mode -u 2>/dev/null
  stty sane 2>/dev/null; stty -echo 2>/dev/null

  report
}

report() {
  local c missing="" stuck="" repeat="" n=0 seen=0
  for c in $(printf '%s\n' "${!KPOS[@]}" | sort -n); do
    n=$((n+1))
    case "${KSTATE[$c]}" in
      new)   missing="$missing ${KLABEL[$c]}" ;;
      stuck) stuck="$stuck ${KLABEL[$c]}"; seen=$((seen+1)) ;;
      *)     seen=$((seen+1)) ;;
    esac
    [ "${KCOUNT[$c]}" -gt 12 ] && repeat="$repeat ${KLABEL[$c]}(${KCOUNT[$c]})"
  done

  rsection "KEYBOARD TEST"
  rsilent "Keys in layout    : $n"
  rsilent "Keys registered   : $seen"
  rsilent "Never registered  : ${missing:-none}"
  rsilent "Held down / stuck : ${stuck:-none}"
  rsilent "Unusually repeated: ${repeat:-none}"
  rsilent ""
  rsilent "Note: the Fn key is handled by the keyboard controller and never reaches"
  rsilent "the OS, so it cannot be tested this way."

  local state verdict
  if [ -n "$stuck" ]; then
    state=FAIL; verdict="FAIL (stuck key:$stuck)"
  elif [ -n "$missing" ] && [ "$seen" -lt $(( n * 90 / 100 )) ]; then
    state=PART; verdict="INCOMPLETE (${seen} of ${n} keys tested)"
  elif [ -n "$missing" ]; then
    state=PART; verdict="INCOMPLETE (not pressed:$missing)"
  else
    state=PASS; verdict="PASS (all ${n} keys registered)"
  fi
  rsilent "RESULT: $verdict"
  set_kv KEYBOARD_RESULT "$verdict"

  tui_frame "Keyboard test finished" "ENTER to go back"
  tui_at 6 $((TUI_PAD+3))
  case "$state" in
    PASS) printf '%s  PASS  %s  %severy key in the layout registered%s' "$INV$OKC" "$R" "$FG" "$R" ;;
    FAIL) printf '%s  FAIL  %s  %sa key is stuck down%s' "$INV$ERR" "$R" "$FG" "$R" ;;
    *)    printf '%s PARTIAL %s  %ssome keys were never pressed%s' "$INV$WRN" "$R" "$FG" "$R" ;;
  esac
  local row=8
  tui_kv $row "Registered" "$seen of $n"; row=$((row+2))
  if [ -n "$stuck" ]; then
    tui_line $row "Stuck:$stuck" "$ERR"; row=$((row+1))
  fi
  if [ -n "$repeat" ]; then
    tui_line $row "Repeating more than expected:$repeat" "$WRN"; row=$((row+1))
  fi
  if [ -n "$missing" ]; then
    tui_line $row "Not pressed:" "$MUTE"; row=$((row+1))
    local line=""
    for c in $missing; do
      if [ ${#line} -gt $((TUI_W-14)) ]; then
        tui_line $row "  $line" "$WRN"; row=$((row+1)); line=""
      fi
      line="$line $c"
    done
    [ -n "$line" ] && { tui_line $row "  $line" "$WRN"; row=$((row+1)); }
    row=$((row+1))
    tui_line $row "Keys you simply did not press also show here - only treat a key" "$MUTE"
    tui_line $((row+1)) "as faulty if you pressed it and it stayed grey." "$MUTE"
  fi
  tui_anykey "ENTER to go back"
}

# The graphical renderer runs the whole test itself: it owns the input devices,
# so it can honour a 20 s timeout and finish the moment every key has reported.
if [ "$TUI_GUI" = 1 ]; then
  tui_kbtest
  IFS='|' read -r n seen stuck missing repeat <<< "$KB_SUMMARY"
  n=${n:-0}; seen=${seen:-0}
  rsection "KEYBOARD TEST"
  rsilent "Keys in layout    : $n"
  rsilent "Keys registered   : $seen"
  rsilent "Never registered  : ${missing:-none}"
  rsilent "Held down / stuck : ${stuck:-none}"
  rsilent "Unusually repeated: ${repeat:-none}"
  rsilent ""
  rsilent "Note: the Fn key is handled by the keyboard controller and never reaches"
  rsilent "the OS, so it cannot be tested this way."
  if [ -n "$stuck" ]; then
    state=FAIL; verdict="FAIL (stuck key: $stuck)"
  elif [ "$n" -gt 0 ] && [ "$seen" -ge "$n" ]; then
    state=PASS; verdict="PASS (all ${n} keys registered)"
  else
    state=PARTIAL; verdict="INCOMPLETE (${seen} of ${n} keys registered)"
  fi
  rsilent "RESULT: $verdict"
  set_kv KEYBOARD_RESULT "$verdict"

  tui_frame "Keyboard test finished" "Enter to go back"
  case "$state" in
    PASS) tui_badge 6 PASS "every key in the layout registered" ;;
    FAIL) tui_badge 6 FAIL "a key is stuck down" ;;
    *)    tui_badge 6 PARTIAL "some keys were never pressed" ;;
  esac
  tui_kv 9 "Registered" "$seen of $n"

  # A full keyboard's worth of key names is far wider than the card, so wrap it
  # across rows instead of letting it run off the edge.
  wrap_from() {   # startrow tone maxrows label text -> echoes the next free row
    local r=$1 tone=$2 max=$3 label=$4 text=$5 first=1 l used=0
    while IFS= read -r l; do
      used=$((used+1))
      if [ "$used" -gt "$max" ]; then tui_line "$r" "  ..." "$tone"; r=$((r+1)); break; fi
      if [ "$first" = 1 ]; then tui_line "$r" "$label $l" "$tone"; first=0
      else tui_line "$r" "  $l" "$tone"; fi
      r=$((r+1))
    done < <(printf '%s\n' "$text" | fold -s -w 86)
    printf '%s\n' "$r"
  }

  row=11
  [ -n "$stuck" ]  && row=$(wrap_from $row err  2 "Stuck:" "$stuck")
  [ -n "$repeat" ] && row=$(wrap_from $row warn 2 "Repeating more than expected:" "$repeat")
  if [ -n "$missing" ]; then
    row=$(wrap_from $((row+1)) warn 5 "Not pressed:" "$missing")
    tui_line $((row+1)) "Keys you simply did not press also show here." muted
  fi
  tui_flush
  tui_anykey
  exit 0
fi

if [ "$1" = "--layout-check" ]; then
  build_layout
  echo "keys=${#KPOS[@]} width=$KB_WIDTH rows=$KB_ROWS"
  for c in $(printf '%s\n' "${!KPOS[@]}" | sort -n); do
    printf '%4s %-6s %s\n' "$c" "${KLABEL[$c]}" "${KPOS[$c]}"
  done
  exit 0
fi

run_test
