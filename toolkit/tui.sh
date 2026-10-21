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
# One command per line, fields split by TAB - so a TAB or newline inside a
# value (kernel files pad with TABs) cut the line and blanked the field: the
# SD test's "Bus mode" (1.20). Both become spaces here, whatever the caller.
_s() {
  local a f=()
  for a in "$@"; do a=${a//$'\t'/ }; f+=("${a//$'\n'/ }"); done
  printf '%s\n' "$(printf '%s\t' "${f[@]}" | sed 's/\t$//')" >&9
}
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
# The imaging job's bar (1.24): row, pct, then the drives the job reads and
# writes (sda nvme0n1 ...). It moves while they are busy and goes amber and
# still when none of them has done anything for 10 seconds (ui.py BarLive).
tui_bar_live() { _s bar "$1" "$2" live "${@:3}"; }
tui_badge() { _s badge "$1" "$2" "${3:-}"; }
tui_thead() { local r=$1; shift; _s thead "$r" "$@"; }
tui_trow()  { local r=$1; shift; _s trow  "$r" "$@"; }
tui_flush() { _s flush; }
# A drive as a bar of partitions: row, caption, then imgengine.py's mapspec
# ("bytes|kind|label|used;..."). It takes the caption row and the next two.
tui_diskmap() { _s diskmap "$1" "$2" "$3"; }
# The partition editor (ui.py PartEditor) on a state file from imgparted.py.
# PE_ANSWER: back, apply, new|gap, format|i, size|i, menu|i.
tui_partedit() { _ask partedit "$1"; PE_ANSWER=$UI_ANS; }
# The same editor on a clone / restore plan's sizes (imgplanedit.py state).
# PE_ANSWER: back, apply (= use these sizes), new|gap, size|i, menu|i.
tui_planedit() { _ask partedit "$1" plan; PE_ANSWER=$UI_ANS; }

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

# tui_menu that opens with item $1 (1-based) chosen, not the first - the boot
# language prompt opens on the language already in use.
tui_menu_at() {
  local at=$1 title=$2 hint=$3; shift 3
  while :; do
    _ask menuat "$at" "$title" "$hint" "$@"
    [ "$UI_ANS" = wifi ] || break
    _wifi_shortcut
  done
  case "$UI_ANS" in ''|0|*[!0-9]*) return 1 ;; esac
  TUI_CHOICE=$UI_ANS
  return 0
}

# A list of drives that follows a drive plugged in or pulled out while it is
# open (Ash, 1.24: no going back and choosing again to see a new USB drive).
# As tui_menu_at, plus return 2 when the drives changed: TUI_HOTSEL is the
# row that was highlighted (1-based) - list the drives again and ask again.
tui_menu_watch() {
  local at=$1 title=$2 hint=$3; shift 3
  while :; do
    _ask menuw "$at" "$title" "$hint" "$@"
    [ "$UI_ANS" = wifi ] || break
    _wifi_shortcut
  done
  case "$UI_ANS" in hotplug*) TUI_HOTSEL=$(( ${UI_ANS#hotplug } + 1 )); return 2 ;; esac
  case "$UI_ANS" in ''|0|*[!0-9]*) return 1 ;; esac
  TUI_CHOICE=$UI_ANS
  return 0
}

# Under a "plug the drive in" page the caller drew: 0 once a drive comes or
# goes, 1 when the operator gives up (Q / Esc).
tui_wait_device() { _ask waitdev; [ "$UI_ANS" = hotplug ]; }

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

# A test's animation, playing while the test itself runs: scene, first and
# last step to loop, then options - "own"/"none" for whether a drive has DRAM,
# "fps=N" for fewer frames. The test keeps drawing its usual frame / kv / line
# / bar - they fill the animation's side panel and progress strip, and the
# drawing follows its figures (hwanim.py). Call it once per phase, not in the
# test's redraw loop: each call starts the loop of steps again. Any question
# or result screen (anykey, menu, confirm...) stops it; tui_anim_stop ends it
# early.
tui_anim_live() { _s animlive "$@"; }
tui_anim_stop() { _s animstop; }

# A line too long for the screen, wrapped at word boundaries over the rows
# from $1 (a single tui_line is cut off at the edge). Echoes the next free row.
# The renderer wraps it, after translating: cut here into 95-character pieces,
# no English piece matched a catalogue entry (1.21). The width is the text
# interface's (tui-text.sh); in pixels the card's own width is the limit.
tui_para() {   # row text [tone] [width]
  _ask para "$1" "$2" "${3:-}"
  case "$UI_ANS" in ''|*[!0-9]*) echo $(($1 + 1)) ;; *) echo "$UI_ANS" ;; esac
}

tui_confirm() {
  local t=$1 d=$2; shift 2
  _ask confirm "$t" "$d" "$@"
  [ "$UI_ANS" = 1 ]
}

tui_input() { _ask input "$1" "$2"; TUI_TEXT=$UI_ANS; }

tui_anykey() { _ask anykey; }
# tui_anykey that also takes the given letters ("m") and says in $TUI_KEY which
# key ended it (enter, esc, q, m...) - for a screen with a second page.
tui_keys() { _ask anykey "$1"; TUI_KEY=${UI_ANS:-enter}; }

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

# The animated "how it works" for one test - a drive test (ssdanim.py: smart
# ctrl bench install surface selftest) or another (hwanim.py: ram cpu battery
# charge usb wifi ether). It moves on through its set; Esc comes back.
tui_anim() { _ask anim "$1"; }
