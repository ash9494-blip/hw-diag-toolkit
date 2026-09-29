#!/bin/bash
# Interface layer.
#
# When the graphical renderer (ui.py) is running, every tui_* call is forwarded
# to it over a FIFO and drawn as pixels. When it is not - no framebuffer, an
# unsupported colour depth, a serial console - this falls back to the original
# ANSI text implementation in tui-text.sh, so the toolkit always works.
#
# The function signatures are identical in both modes, which is why the test
# scripts did not have to change.
# shellcheck disable=SC2034

UI_CMD=/run/diag/ui.cmd
UI_REPLY=/run/diag/ui.reply
UI_PID=/run/diag/ui.pid

ui_running() {
  [ -p "$UI_CMD" ] && [ -p "$UI_REPLY" ] && [ -r "$UI_PID" ] \
    && kill -0 "$(cat "$UI_PID" 2>/dev/null)" 2>/dev/null
}

if ! ui_running; then
  . /opt/diag/tui-text.sh
  return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------- graphical
TUI_GUI=1
E=$'\e'
# In graphical mode the "colour" variables carry tone names instead of escape
# codes, so existing calls like tui_kv 9 "Temp" "91 C" "$ERR$B" keep working.
R=""; B=""; DIM=""; INV=""; BG=""; BAR=""; TRACK=""; HIDE=""; SHOW=""
FG="";        MUTE="muted"; ACC="accent"
OKC="ok";     WRN="warn";   ERR="err";    VIO="accent"

# nominal geometry, for the few scripts that measure before drawing
TUI_COLS=120; TUI_ROWS=30; TUI_W=110; TUI_PAD=2
TUI_CHOICE=0; TUI_TEXT=""; TUI_TITLE=""; TUI_SUB=""

exec 9>"$UI_CMD"
_s() { printf '%s\n' "$(printf '%s\t' "$@" | sed 's/\t$//')" >&9; }
_ask() {
  _s "$@"
  UI_ANS=$(timeout 7200 head -n1 "$UI_REPLY" 2>/dev/null)
}

tui_size()  { :; }
tui_init()  { :; }
tui_done()  { :; }
tui_cls()   { :; }
tui_at()    { :; }
tui_pad()   { printf '%s' "$1"; }
tui_rule()  { :; }
tui_palette() { :; }

# The machine identity is two lines. A raw newline would be read by the
# renderer as the start of a second command, so send it as two fields.
_send_sub() {
  local a=$1 b=""
  case "$1" in *$'\n'*) a=${1%%$'\n'*}; b=${1#*$'\n'} ;; esac
  _s sub "$a" "$b"
}
tui_sub()   { TUI_SUB=$1; _send_sub "$1"; }
tui_frame() { _s frame "$1" "$2"; [ -n "$TUI_SUB" ] && _send_sub "$TUI_SUB"; return 0; }
tui_kv()    { _s kv "$1" "$2" "$3" "${4:-}"; }
tui_line()  { _s line "$1" "$2" "${3:-}"; }
tui_bar()   { _s bar "$1" "$2"; }
tui_badge() { _s badge "$1" "$2" "${3:-}"; }
tui_thead() { local r=$1; shift; _s thead "$r" "$@"; }
tui_trow()  { local r=$1; shift; _s trow  "$r" "$@"; }
tui_flush() { _s flush; }

# Change a renderer setting (theme, textscale) for the rest of the session.
tui_setting() { _s setting "$1" "$2"; }

# The Wi-Fi icon in the header (click it, or press W) answers a menu with
# "wifi". The Wi-Fi page opens right there and the same menu comes back
# afterwards, so no caller has to know about it. Not from inside the Wi-Fi page
# itself - wificonnect.sh sets DIAG_IN_WIFI - or it would open inside itself.
_wifi_shortcut() {
  [ -n "$DIAG_IN_WIFI" ] && return 0
  DIAG_IN_WIFI=1 /opt/diag/wificonnect.sh
  [ -n "$TUI_SUB" ] && _send_sub "$TUI_SUB"
  return 0
}

tui_menu() {
  local title=$1 hint=$2; shift 2
  while :; do
    _ask menu "$title" "$hint" "$@"
    [ "$UI_ANS" = wifi ] || break
    _wifi_shortcut
  done
  case "$UI_ANS" in ''|0|*[!0-9]*) return 1 ;; esac
  TUI_CHOICE=$UI_ANS
  return 0
}

# Same contract as tui_menu, but each entry is "Label|icon" and it is drawn as a
# grid of square tiles. The text interface falls back to the list.
tui_grid() {
  local title=$1 hint=$2; shift 2
  while :; do
    _ask gridmenu "$title" "$hint" "$@"
    [ "$UI_ANS" = wifi ] || break
    _wifi_shortcut
  done
  case "$UI_ANS" in ''|0|*[!0-9]*) return 1 ;; esac
  TUI_CHOICE=$UI_ANS
  return 0
}

tui_msg() { local t=$1; shift; _ask msg "$t" "$@"; }

tui_confirm() {
  local t=$1 d=$2; shift 2
  _ask confirm "$t" "$d" "$@"
  [ "$UI_ANS" = 1 ]
}

tui_input() { _ask input "$1" "$2"; TUI_TEXT=$UI_ANS; }

tui_anykey() { _ask anykey; }

tui_pager() { _ask pager "$1" "$2"; }

# Returns 0 when the operator pressed Q within the timeout.
tui_wait_abort() {
  _ask waitkey "$1"
  case "$UI_ANS" in q|Q) return 0 ;; esac
  return 1
}

# Runs the whole keyboard test inside the renderer and returns its summary as
# TAB-separated fields: total, seen, stuck, missing, repeated.
tui_kbtest() { _ask kbtest; KB_SUMMARY=$UI_ANS; }

# Runs the touchpad or mouse test inside the renderer. Returns pipe-separated:
# coverage%, dead cells, button counts, device names, taps, max fingers, wheel.
tui_ptrtest() { _ask ptrtest "$1"; PTR_SUMMARY=$UI_ANS; }

# Full-screen touchscreen test inside the renderer. Returns pipe-separated:
# coverage%, dead cells, device names, most fingers at once, ghost touches,
# total contacts, touch points supported, uncalibrated flag, dead cell list.
tui_tstest() { _ask tstest; TS_SUMMARY=$UI_ANS; }

# Number of pointing devices of a kind ("touchpad", "mouse") present right now.
tui_ptrprobe() { _ask ptrprobe "$1"; PTR_COUNT=${UI_ANS:-0}; }

# Full-screen colours for dead and stuck pixels. Returns "screens-seen|total".
tui_pixtest() { _ask pixtest; PIX_SUMMARY=$UI_ANS; }

# Live camera preview inside the renderer. Returns pipe-separated:
# card name, frames grabbed, fps, mean brightness, dark-frame count.
tui_camtest() { _ask camtest; CAM_SUMMARY=$UI_ANS; }
