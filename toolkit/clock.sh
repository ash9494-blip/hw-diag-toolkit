#!/bin/bash
# The laptop's clock: set from the internet's time when a connection is up, or
# by hand. A wrong clock fails secure websites (OneDrive's sign-in among them),
# so this runs on its own whenever the laptop is online, and from Settings.
#
#   clock.sh watch          the background watcher menu.sh starts at boot
#   clock.sh sync           set it from the internet if it is out (exit 0 / 1);
#                           nothing when it was found right in the last 5 min
#   clock.sh screen         the Settings screen (also called from OneDrive)
#
# The internet's time comes from the Date header of a plain web address, not
# from an HTTPS one: HTTPS checks the clock, so it cannot be used to fix it. A
# Date header is to the second, and a stranger on the path could forge it -
# the same trust a clock set by hand has. The clock is only stepped when it is
# more than a minute out, so ordinary drift never moves it.
#
# The hardware clock holds local time (/etc/adjtime says LOCAL, as Windows
# keeps it), so every write to it goes through hwclock --systohc.

CLOCK_LOG=${RUN_DIR:-/run/diag}/clock.log
CLOCK_STEP=60                 # seconds out before the clock is moved
CLOCK_EVERY=300               # seconds between automatic checks while online
CLOCK_PID=${RUN_DIR:-/run/diag}/clock-watch.pid
CLOCK_OK=${RUN_DIR:-/run/diag}/clock.ok   # seconds since boot of the last internet time
CLOCK_URLS="http://www.msftconnecttest.com/connecttest.txt http://connectivitycheck.gstatic.com/generate_204"

clock_log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$CLOCK_LOG" 2>/dev/null; }

clock_online() { ip route show default 2>/dev/null | grep -q .; }

# The internet's time, in seconds since 1970 - nothing when there is none.
clock_net_epoch() {
  local u d e
  for u in $CLOCK_URLS; do
    d=$(curl -s -I --connect-timeout 5 --max-time 8 "$u" 2>/dev/null \
        | sed -n 's/^[Dd]ate: *//p' | tr -d '\r' | head -1)
    if [ -n "$d" ]; then
      e=$(date -u -d "$d" +%s 2>/dev/null) && [ -n "$e" ] && { printf '%s\n' "$e"; return 0; }
    fi
  done
  return 1
}

# Move the clock to epoch $1 and write it to the hardware clock.
clock_set_epoch() {
  date -u -s "@$1" >/dev/null 2>&1 || return 1
  hwclock --systohc >/dev/null 2>&1
  return 0
}

# Set from the internet if it is more than CLOCK_STEP out (or always, with
# force=1). 0 when the clock is now right, 1 when there is no internet time.
clock_sync() {
  local force=${1:-0} e now skew abs
  e=$(clock_net_epoch) || { clock_log "sync: no internet time"; return 1; }
  cut -d. -f1 /proc/uptime > "$CLOCK_OK" 2>/dev/null
  now=$(date -u +%s); skew=$(( e - now )); abs=${skew#-}
  if [ "$force" = 1 ] || [ "$abs" -gt "$CLOCK_STEP" ]; then
    clock_set_epoch "$e" || return 1
    clock_log "set from the internet: was $abs s $( [ "$skew" -lt 0 ] && echo behind || echo ahead )"
  fi
  return 0
}

# OneDrive's look before it signs in or opens. Not when the internet's time
# was had in the last CLOCK_EVERY s (the watcher's, or the last open's): a
# network that blocks plain web addresses made every open wait up to 16 s
# for two answers that never come (review, 1.26). Only a time actually had
# counts - a "no internet" from before the Wi-Fi was joined must not skip it.
clock_sync_recent() {
  local last now
  last=$(cat "$CLOCK_OK" 2>/dev/null); now=$(cut -d. -f1 /proc/uptime)
  [ -n "$last" ] && [ $(( now - last )) -lt "$CLOCK_EVERY" ] && return 0
  clock_sync 0
}

# Set by hand, from "YYYY-MM-DD" and "HH:MM" as the clock reads on this bench.
clock_set_by_hand() {   # date time -> 0 set, 1 not a date and time
  local d=$1 t=$2
  [[ $d =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && $t =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || return 1
  date -d "$d $t" >/dev/null 2>&1 || return 1
  date -s "$d $t" >/dev/null 2>&1 || return 1
  hwclock --systohc >/dev/null 2>&1
  clock_log "set by hand to $d $t"
  return 0
}

# Watch for a connection and keep the clock right while there is one. Timed
# by the seconds since boot, not by the clock it sets: with the wall clock, a
# clock set back by years would wait years for its next check.
clock_watch() {
  local last=-"$CLOCK_EVERY" now
  echo $$ > "$CLOCK_PID"
  while :; do
    now=$(cut -d. -f1 /proc/uptime)
    if clock_online && [ $(( now - last )) -ge "$CLOCK_EVERY" ]; then
      clock_sync 0 >/dev/null 2>&1
      last=$now
    fi
    sleep 20
  done
}

# ---------------------------------------------------------------- the screen
clock_screen() {
  local now d t
  while :; do
    now=$(date '+%d %b %Y, %H:%M:%S')
    tui_menu "Date and time" "now: $now - Q to go back" \
      "Set from the internet|needs a connection - the clock is set to the internet's time" \
      "Set by hand|type the date and the time as they are here" || return 0
    case "$TUI_CHOICE" in
      1) tui_frame "Date and time" ""; tui_line 6 "Asking the internet for the time..." muted; tui_flush
         if clock_sync 1; then
           tui_msg "Clock set" "The clock now reads $(date '+%d %b %Y, %H:%M:%S')." ""
         else
           tui_msg "No internet time" "The laptop is not online, so there is no time to set it from." "" \
             "Connect a cable or Wi-Fi, or set the date and time by hand."
         fi ;;
      2) tui_input "Date (year-month-day)" "for example 2026-10-21 - blank to cancel"
         [ -z "$TUI_TEXT" ] && continue
         d=$TUI_TEXT
         tui_input "Time (24 hour)" "for example 14:35 - blank to cancel"
         [ -z "$TUI_TEXT" ] && continue
         t=$TUI_TEXT
         if clock_set_by_hand "$d" "$t"; then
           tui_msg "Clock set" "The clock now reads $(date '+%d %b %Y, %H:%M:%S')." ""
         else
           tui_msg "Not a date and time" "Type the date as 2026-10-21 and the time as 14:35." ""
         fi ;;
    esac
  done
}

case "${1:-}" in
  watch)  clock_watch ;;
  sync)   clock_sync_recent ;;
  screen) . /opt/diag/lib.sh; . /opt/diag/tui.sh; clock_screen ;;
  *)      sed -n '2,11p' "$0" ;;
esac
