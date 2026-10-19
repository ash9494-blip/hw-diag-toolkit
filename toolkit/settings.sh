#!/bin/bash
# System settings.
#
# Everything here changes how the toolkit behaves on this bench, not what it
# measures. Each setting takes effect immediately, is written to the run
# directory so it survives the renderer restarting, and is kept on the boot
# stick (keep_settings in lib.sh) so the next boot starts the same way.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

SETTINGS=$RUN_DIR/settings.conf

get() {   # key default
  local v
  v=$(awk -F= -v k="$1" '$1==k{print $2; exit}' "$SETTINGS" 2>/dev/null)
  printf '%s' "${v:-$2}"
}

put() {   # key value - rewrite the one line, keep the rest, then onto the stick
  local k=$1 v=$2 tmp=$RUN_DIR/.settings.new
  touch "$SETTINGS" 2>/dev/null
  grep -v "^$k=" "$SETTINGS" 2>/dev/null > "$tmp"
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv "$tmp" "$SETTINGS"
  keep
}

# After every change: onto the boot stick, and the lines that tell the
# operator whether the next boot will have it. Up to 1.20.0 a change silently
# lasted only until power-off unless it was saved by hand.
keep() {
  if keep_settings; then
    KEEP_LINES=("Kept on the USB stick ($KEPT_ON) - the next boot starts with it.")
  else
    KEEP_LINES=("Only until the laptop is switched off -" "$KEEP_WHY." "$KEEP_FIX")
  fi
}

theme_label() {
  case "$1" in
    light)    printf 'Light  - white cards, best in a bright workshop' ;;
    dark)     printf 'Dark   - easier at night or in a dim room' ;;
    contrast) printf 'High contrast - black and white, for a failing panel' ;;
    mecha)    printf 'Mecha command deck - anime, black deck and orange bays' ;;
    kawaii)   printf 'Kawaii pastel - anime, pink sticker sheet' ;;
    *)        printf '%s' "$1" ;;
  esac
}

scale_label() {
  case "$1" in
    1.0)  printf 'Normal' ;;
    1.25) printf 'Large  (125%%)' ;;
    1.5)  printf 'Extra large  (150%%)' ;;
    2.0)  printf 'Huge  (200%%)' ;;
    *)    printf '%s x' "$1" ;;
  esac
}

# ---------------------------------------------------------------- panes
set_theme() {
  local cur; cur=$(get theme light)
  tui_menu "Colour theme" "currently: $(theme_label "$cur")" \
    "Light|white cards on pale grey - the default" \
    "Dark|dark cards, much easier on the eyes at night" \
    "High contrast|black and white, for a dim or failing screen" \
    "Mecha command deck|anime: a black launch deck, every test a bay with a status lamp" \
    "Kawaii pastel|anime: a pink sticker sheet, results as reward stamps" || return
  local t
  case "$TUI_CHOICE" in 1) t=light ;; 2) t=dark ;; 3) t=contrast ;; 4) t=mecha ;; 5) t=kawaii ;; esac
  # the renderer first, then the stick: writing to the stick takes a moment
  tui_setting theme "$t"
  put theme "$t"
  # Redraw something so the change is visible straight away rather than at the
  # next screen the operator happens to open.
  tui_msg "Theme changed" "Now using: $(theme_label "$t")" "" \
    "Every screen from here on uses it." "" "${KEEP_LINES[@]}"
}

look_label() {
  case "$1" in
    classic) printf 'Classic tiles - the look of 1.0 to 1.12' ;;
    *)       printf 'Service manual - drawing sheet with a parts list' ;;
  esac
}

# Home screen and menus only; test screens look the same either way.
set_look() {
  local cur; cur=$(get look manual)
  tui_menu "Menu style" "currently: $(look_label "$cur")" \
    "Service manual|drawing frame, numbered callouts, results in a parts list" \
    "Classic tiles|white tiles on grey, as before 1.13" || return
  local v
  case "$TUI_CHOICE" in 1) v=manual ;; 2) v=classic ;; esac
  tui_setting look "$v"
  put look "$v"
  tui_msg "Menu style changed" "Now using: $(look_label "$v")" "" "${KEEP_LINES[@]}"
}

set_text_size() {
  local cur; cur=$(get textscale 1.0)
  tui_menu "Text size" "currently: $(scale_label "$cur")" \
    "Normal|the original size" \
    "Large (125%)|a little bigger" \
    "Extra large (150%)|comfortable at arm's length" \
    "Huge (200%)|for reading across the bench" || return
  local v
  case "$TUI_CHOICE" in 1) v=1.0 ;; 2) v=1.25 ;; 3) v=1.5 ;; 4) v=2.0 ;; esac
  tui_setting textscale "$v"
  put textscale "$v"
  tui_msg "Text size changed" "Now using: $(scale_label "$v")" "" \
    "Larger text means fewer lines fit on a screen, so long" \
    "reports scroll more." "" "${KEEP_LINES[@]}"
}

lang_label() {
  case "$1" in
    en_GB) printf 'English (UK)' ;;
    zh_CN) printf '简体中文 - Chinese (Simplified)' ;;
    zh_TW) printf '繁體中文 - Chinese (Traditional)' ;;
    ja)    printf '日本語 - Japanese' ;;
    ko)    printf '한국어 - Korean' ;;
    *)     printf 'English' ;;
  esac
}

# Every screen, in the renderer (i18n.py); each language is listed in its own
# script so it can be found whatever language is on. The saved report stays
# English, and so does the text-only fallback (the console has no CJK font).
LANG_CODES=(en en_GB zh_CN zh_TW ja ko)
LANG_ITEMS=("English|" "English (UK)|British spelling: colour, centre"
  "简体中文|Chinese (Simplified)" "繁體中文|Chinese (Traditional)"
  "日本語|Japanese" "한국어|Korean")

set_language() {
  local cur; cur=$(get lang en)
  tui_menu "Language" "currently: $(lang_label "$cur")" "${LANG_ITEMS[@]}" || return
  local v=${LANG_CODES[$((TUI_CHOICE-1))]}
  tui_setting lang "$v"
  put lang "$v"
  tui_msg "Language changed" "Now using: $(lang_label "$v")" "" \
    "The saved report stays in English." "" "${KEEP_LINES[@]}"
}

# Every boot, after GRUB and before the home screen (menu.sh; Ash, 1.22).
# Opens on the language kept on the stick, so Enter (or Q) goes on with it;
# a new choice is kept for the next boot like any other setting. The title is
# in every language at once - whoever is at the bench can find theirs.
boot_language() {
  local cur at=1 i v
  cur=$(get lang en)
  for i in "${!LANG_CODES[@]}"; do
    [ "${LANG_CODES[$i]}" = "$cur" ] && at=$((i + 1))
  done
  tui_menu_at "$at" "Language  /  语言  /  語言  /  言語  /  언어" \
    "arrows + Enter to choose      Q = keep $(lang_label "$cur")" "${LANG_ITEMS[@]}" || return 0
  v=${LANG_CODES[$((TUI_CHOICE-1))]}
  [ "$v" = "$cur" ] && return 0
  tui_setting lang "$v"
  put lang "$v"
  return 0
}

if [ "$1" = --boot-language ]; then
  boot_language
  exit 0
fi

set_layout_default() {
  local cur; cur=$(cat "$RUN_DIR/layout" 2>/dev/null || echo compact)
  tui_menu "Which menu to open on" "currently: $cur" \
    "Short list|the common tests, peripherals behind one tile" \
    "Every test|all tiles at once" || return
  case "$TUI_CHOICE" in
    1) printf 'compact\n' > "$RUN_DIR/layout"; put layout compact ;;
    2) printf 'all\n'     > "$RUN_DIR/layout"; put layout all ;;
  esac
  tui_msg "Saved" "The main menu will open on that layout." "" "${KEEP_LINES[@]}"
}

set_wifi_default() {
  local cur; cur=$(get wifi_secs 600)
  tui_menu "Default wireless test length" "currently: $(secs_ms "$cur")" \
    "1 minute|" "10 minutes|" "30 minutes|" "1 hour|" "5 hours|" "1 day|" || return
  local v
  case "$TUI_CHOICE" in
    1) v=60 ;; 2) v=600 ;; 3) v=1800 ;; 4) v=3600 ;; 5) v=18000 ;; 6) v=86400 ;;
  esac
  put wifi_secs "$v"
  tui_msg "Saved" "The wireless test will offer this first." "" \
    "You can still pick a different length each time you run it." "" "${KEEP_LINES[@]}"
}

set_disk_default() {
  local cur; cur=$(get disk_size 1G)
  tui_menu "Default disk benchmark size" "currently: $cur" \
    "1 GB|quick, fits inside most SSD cache" \
    "4 GB|" "16 GB|past the cache on most consumer SSDs" "64 GB|sustained behaviour" || return
  local v
  case "$TUI_CHOICE" in 1) v=1G ;; 2) v=4G ;; 3) v=16G ;; 4) v=64G ;; esac
  put disk_size "$v"
  tui_msg "Saved" "The disk benchmark will start on $v." "" "${KEEP_LINES[@]}"
}

# Every change is kept as it is made; this shows where, and tries again - after
# a partition labelled DIAGDATA was plugged in, say. The old "pick a drive"
# save wrote wherever it was told, and the next boot only ever looked inside
# the ISO, so a saved theme never came back.
show_kept() {
  if [ ! -s "$SETTINGS" ]; then
    tui_msg "Nothing to keep" "Every setting is at its default." "" \
      "Change one and it is kept on the USB stick straight away."
    return
  fi
  keep
  if [ -n "$KEPT_ON" ]; then
    tui_msg "Settings kept" "On the USB stick: $KEPT_ON, in $SETTINGS_NAME." "" \
      "Every change is kept there as it is made, and the next boot" \
      "starts with them."
  else
    tui_msg "Settings not kept" "${KEEP_LINES[@]}"
  fi
}

reset_all() {
  tui_confirm "Reset settings" no \
    "This puts the theme, text size and every default back to how" \
    "the toolkit ships." \
    "" \
    "Test results already collected are not affected." \
    "" "Reset?" || return
  rm -f "$SETTINGS"
  printf 'compact\n' > "$RUN_DIR/layout"
  tui_setting theme light
  tui_setting look manual
  tui_setting textscale 1.0
  tui_setting lang en
  keep   # no settings file: the stick's copy goes too, or the next boot undoes this
  tui_msg "Reset" "Everything is back to its default." "" \
    "$([ -n "$KEPT_ON" ] && echo "The copy on the USB stick ($KEPT_ON) was cleared too.")"
}

show_about() {
  tui_frame "About" "Enter to go back"
  tui_kv 6  "Toolkit version" "$DIAG_VERSION"
  tui_kv 7  "Kernel"          "$(uname -r)"
  tui_kv 8  "Booted"          "$(who -b 2>/dev/null | awk '{print $3, $4}')"
  tui_kv 9  "Uptime"          "$(uptime -p 2>/dev/null | sed 's/^up //')"
  tui_kv 10 "Interface"       "$([ "$TUI_GUI" = 1 ] && echo "graphical" || echo "text fallback")"
  tui_kv 11 "Settings file"   "$SETTINGS"
  tui_line 13 "Nothing here is written to the machine being tested." muted
  tui_line 14 "The toolkit runs entirely in RAM." muted
  tui_flush
  tui_anykey
}

# ---------------------------------------------------------------- main
while :; do
  tui_menu "System settings" "arrows + Enter, Q to go back" \
    "Colour theme|$(theme_label "$(get theme light)")" \
    "Menu style|$(look_label "$(get look manual)")" \
    "Text size|$(scale_label "$(get textscale 1.0)")" \
    "Language|$(lang_label "$(get lang en)")" \
    "Opening menu|$(cat "$RUN_DIR/layout" 2>/dev/null || echo compact)" \
    "Wireless test length|$(secs_ms "$(get wifi_secs 600)")" \
    "Disk benchmark size|$(get disk_size 1G)" \
    "Keep settings on the USB stick|done after every change - this shows where" \
    "About this toolkit|version, kernel, uptime" \
    "Reset everything|back to defaults" || break
  case "$TUI_CHOICE" in
    1) set_theme ;;
    2) set_look ;;
    3) set_text_size ;;
    4) set_language ;;
    5) set_layout_default ;;
    6) set_wifi_default ;;
    7) set_disk_default ;;
    8) show_kept ;;
    9) show_about ;;
    10) reset_all ;;
  esac
done
