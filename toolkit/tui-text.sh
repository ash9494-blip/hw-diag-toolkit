#!/bin/bash
# Minimal full-screen text UI for the diagnostic toolkit.
# Everything is drawn with ANSI sequences and background colours only - no
# box-drawing or block glyphs - so it renders identically on any console font.
# shellcheck disable=SC2034

# ---------- palette ----------------------------------------------------------
# 16-colour console, repainted to a dark modern scheme by tui_init.
E=$'\e'
R="${E}[0m"      ; B="${E}[1m"       ; DIM="${E}[2m"
FG="${E}[37m"    ; MUTE="${E}[90m"   ; ACC="${E}[96m"
OKC="${E}[92m"   ; WRN="${E}[93m"    ; ERR="${E}[91m"  ; VIO="${E}[95m"
BG="${E}[40m"    ; BAR="${E}[46m"    ; TRACK="${E}[45m"
INV="${E}[7m"
HIDE="${E}[?25l"; SHOW="${E}[?25h"

TUI_COLS=80; TUI_ROWS=24

tui_size() {
  local s
  s=$(stty size 2>/dev/null) || s=""
  TUI_ROWS=${s%% *}; TUI_COLS=${s##* }
  case "$TUI_ROWS" in ''|*[!0-9]*) TUI_ROWS=24 ;; esac
  case "$TUI_COLS" in ''|*[!0-9]*) TUI_COLS=80 ;; esac
  [ "$TUI_COLS" -lt 60 ] && TUI_COLS=60
  [ "$TUI_ROWS" -lt 16 ] && TUI_ROWS=16
  if [ "$TUI_COLS" -gt 124 ]; then TUI_W=120; else TUI_W=$(( TUI_COLS - 4 )); fi
  TUI_PAD=$(( (TUI_COLS - TUI_W) / 2 ))
}

# Repaint the console palette. Silently ignored on terminals that do not
# support it, and skipped entirely when not on a Linux virtual console.
tui_palette() {
  case "$(tty 2>/dev/null)" in /dev/tty[0-9]*) ;; *) return ;; esac
  command -v setvtrgb >/dev/null 2>&1 || return
  printf '%s\n%s\n%s\n' \
    "11,255,61,255,76,45,86,219,60,255,93,255,110,220,130,255" \
    "15,95,220,204,194,55,212,228,72,120,240,235,180,235,200,255" \
    "20,109,151,102,255,68,221,239,86,130,160,150,255,255,230,255" \
    > /run/diag/vtrgb 2>/dev/null && setvtrgb /run/diag/vtrgb 2>/dev/null
}

tui_init() {
  tui_size
  tui_palette
  printf '%s%s%s' "$HIDE" "${E}[40m" "${E}[2J${E}[H"
  stty -echo 2>/dev/null
  trap 'tui_done' EXIT
}
tui_done() { stty echo 2>/dev/null; printf '%s%s' "$SHOW" "$R"; }

tui_cls() { printf '%s' "${E}[2J${E}[H"; }
tui_at()  { printf '%s' "${E}[${1};${2}H"; }
# pad "text" width -> text padded/truncated to width (ignores escape codes)
tui_pad() { local t=$1 w=$2; printf '%-*.*s' "$w" "$w" "$t"; }
tui_rule() { local i s=""; for ((i=0;i<TUI_W;i++)); do s="$s─"; done; printf '%s' "$s"; }

# ---------- chrome -----------------------------------------------------------
TUI_TITLE="HARDWARE DIAGNOSTIC TOOLKIT"
TUI_SUB=""

tui_frame() {  # $1 screen title, $2 hint line
  tui_size
  tui_cls
  local left right
  left="  ${TUI_TITLE}"
  right="$(printf '%.28s  ' "${TUI_SUB}")"
  [ $(( TUI_W - ${#right} )) -lt 10 ] && right="  "
  tui_at 1 $((TUI_PAD+1))
  printf '%s%s%s%s' "$INV$ACC" "$(tui_pad "$left" $((TUI_W - ${#right})))" "$right" "$R"
  if [ -n "$1" ]; then
    tui_at 3 $((TUI_PAD+1)); printf '%s%s%s' "$B$FG" "$1" "$R"
    tui_at 4 $((TUI_PAD+1)); printf '%s%s%s' "$MUTE" "$(tui_rule)" "$R"
  fi
  if [ -n "$2" ]; then
    tui_at "$TUI_ROWS" $((TUI_PAD+1))
    printf '%s%s%s' "$INV$MUTE" "$(tui_pad "  $2" "$TUI_W")" "$R"
  fi
}

# ---------- input ------------------------------------------------------------
tui_key() {
  local k rest
  IFS= read -rsn1 k 2>/dev/null || { echo ENTER; return; }
  if [ "$k" = "$E" ]; then
    read -rsn2 -t 0.05 rest 2>/dev/null
    case "$rest" in
      '[A') echo UP ;; '[B') echo DOWN ;; '[C') echo RIGHT ;; '[D') echo LEFT ;;
      '') echo ESC ;; *) echo OTHER ;;
    esac
  elif [ -z "$k" ]; then echo ENTER
  else echo "$k"
  fi
}

tui_anykey() {
  # never block when there is no keyboard (automated runs, piped stdin)
  [ -t 0 ] || return 0
  local k
  while :; do k=$(tui_key); case "$k" in ENTER|ESC|q|Q|' ') break ;; esac; done
}

# ---------- menu -------------------------------------------------------------
# tui_menu <title> <hint> <label>...   -> TUI_CHOICE (1-based), rc 1 on cancel
TUI_CHOICE=0
tui_menu() {
  local title=$1 hint=$2; shift 2
  local -a items=("$@")
  local n=${#items[@]} sel=1 i row k
  [ -t 0 ] || return 1
  while :; do
    tui_frame "$title" "$hint"
    for ((i=0;i<n;i++)); do
      row=$((6+i))
      tui_at "$row" $((TUI_PAD+1))
      local lbl=${items[$i]//|/  }
      if [ $((i+1)) -eq "$sel" ]; then
        printf '%s%s%s' "$INV$ACC" "$(tui_pad "  $((i+1))  $lbl" "$TUI_W")" "$R"
      else
        printf '%s  %s%d%s  %s%s' "$BG" "$MUTE" $((i+1)) "$R" "$FG" "$lbl$R"
      fi
    done
    k=$(tui_key)
    case "$k" in
      UP)    sel=$(( sel>1 ? sel-1 : n )) ;;
      DOWN)  sel=$(( sel<n ? sel+1 : 1 )) ;;
      ENTER) TUI_CHOICE=$sel; return 0 ;;
      ESC|q|Q) return 1 ;;
      [1-9]) [ "$k" -le "$n" ] && { TUI_CHOICE=$k; return 0; } ;;
      0)     [ "$n" -ge 10 ] && { TUI_CHOICE=10; return 0; } ;;
    esac
  done
}

# tui_grid takes "Label|icon" entries. There are no tiles on a text console, so
# the icon name is dropped and it becomes an ordinary list.
tui_grid() {
  local title=$1 hint=$2; shift 2
  local -a plain=()
  local e
  for e in "$@"; do plain+=("${e%%|*}"); done
  tui_menu "$title" "$hint" "${plain[@]}"
}

# ---------- messages ---------------------------------------------------------
# tui_msg <title> <line>...
tui_msg() {
  local title=$1; shift
  tui_frame "$title" "ENTER to continue"
  local i=0 l
  for l in "$@"; do tui_at $((6+i)) $((TUI_PAD+1)); printf '%s%s%s' "$FG" "$l" "$R"; i=$((i+1)); done
  tui_anykey
}

# tui_confirm <title> <default:yes|no> <line>...  -> rc 0 = yes
tui_confirm() {
  local title=$1 def=$2; shift 2
  local sel=1; [ "$def" = no ] && sel=2
  local i l k
  [ -t 0 ] || { [ "$def" = no ] && return 1; return 0; }
  while :; do
    tui_frame "$title" "arrows or Y / N, ENTER to confirm"
    i=0
    for l in "$@"; do tui_at $((6+i)) $((TUI_PAD+1)); printf '%s%s%s' "$FG" "$l" "$R"; i=$((i+1)); done
    tui_at $((6+i+1)) $((TUI_PAD+3))
    if [ "$sel" = 1 ]; then
      printf '%s  YES  %s   %s  NO  %s' "$INV$OKC" "$R" "$MUTE" "$R"
    else
      printf '%s  YES  %s   %s  NO  %s' "$MUTE" "$R" "$INV$ERR" "$R"
    fi
    k=$(tui_key)
    case "$k" in
      LEFT|RIGHT|UP|DOWN) sel=$(( sel==1 ? 2 : 1 )) ;;
      y|Y) return 0 ;;
      n|N|ESC|q|Q) return 1 ;;
      ENTER) [ "$sel" = 1 ] && return 0 || return 1 ;;
    esac
  done
}

# tui_input <title> <prompt>  -> TUI_TEXT
tui_input() {
  [ -t 0 ] || { TUI_TEXT=""; return 1; }
  tui_frame "$1" "type, then ENTER"
  tui_at 6 $((TUI_PAD+1)); printf '%s%s %s' "$FG" "$2" "$R"
  stty echo 2>/dev/null; printf '%s' "$SHOW"
  read -r TUI_TEXT
  stty -echo 2>/dev/null; printf '%s' "$HIDE"
}

# ---------- progress ---------------------------------------------------------
# tui_bar <row> <percent> [width]
tui_bar() {
  local row=$1 pct=$2 w=${3:-$((TUI_W-14))}
  [ "$pct" -lt 0 ] && pct=0; [ "$pct" -gt 100 ] && pct=100
  local fill=$(( pct * w / 100 )) rest
  rest=$(( w - fill ))
  tui_at "$row" $((TUI_PAD+1))
  printf '  %s%*s%s%*s%s %s%3d%%%s' "$BAR" "$fill" "" "$TRACK" "$rest" "" "$R" "$ACC" "$pct" "$R"
}

# tui_kv <row> <label> <value> [colour]
tui_kv() {
  tui_at "$1" $((TUI_PAD+3))
  printf '%s%-22s%s%s%s%s' "$MUTE" "$2" "$R" "${4:-$FG}" "$3" "$R${E}[K"
}

tui_line() { tui_at "$1" $((TUI_PAD+3)); printf '%s%s%s%s' "${3:-$FG}" "$2" "$R" "${E}[K"; }

# ---------- pager ------------------------------------------------------------
tui_pager() {
  tui_done
  LESSSECURE=1 less -R -P"$1  --  arrows to scroll, Q to go back" "$2"
  printf '%s' "$HIDE"; stty -echo 2>/dev/null
}

# ---------- abort helper -----------------------------------------------------
# Returns 0 if the user pressed Q/ESC within <timeout> seconds.
tui_wait_abort() {
  local t=$1 k
  if [ -t 0 ]; then
    IFS= read -rsn1 -t "$t" k 2>/dev/null
    case "$k" in q|Q) return 0 ;; esac
  else
    sleep "$t"
  fi
  return 1
}

# ---------- table helpers (text mode) ----------------------------------------
tui_thead() {
  local row=$1; shift
  tui_at "$row" $((TUI_PAD+3))
  printf '%s%-14s %11s %10s   %11s %10s%s' "$MUTE" "$1" "$2" "$3" "$4" "$5" "$R"
}
tui_trow() {
  local row=$1; shift
  tui_at "$row" $((TUI_PAD+3))
  printf '%s%-14s %s%11s %s%10s   %s%11s %s%10s%s%s' \
    "$FG" "$1" "$ACC" "$2" "$MUTE" "$3" "$ACC" "$4" "$MUTE" "$5" "$R" "${E}[K"
}

tui_sub() { TUI_SUB=$1; }

# The text interface has no palette or font to change.
tui_setting() { :; }

# Live animations need the framebuffer; the text screens carry on without.
tui_anim_live() { :; }
tui_anim_stop() { :; }

# No framebuffer, no animation: the same explanation as the captions, as text.
tui_anim() {
  local f=${RUN_DIR:-/run/diag}/how-it-works.txt
  python3 /opt/diag/hwanim.py --text "$1" > "$f" 2>&1      # passes drive scenes to ssdanim
  tui_pager "How it works" "$f"
}
