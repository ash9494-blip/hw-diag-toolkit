#!/bin/bash
# System settings.
#
# Everything here changes how the toolkit behaves on this bench, not what it
# measures. Each setting takes effect immediately and is written to the run
# directory so it survives the renderer restarting; "Save to the USB stick"
# copies them onto the boot medium so the next machine starts the same way.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

SETTINGS=$RUN_DIR/settings.conf

get() {   # key default
  local v
  v=$(awk -F= -v k="$1" '$1==k{print $2; exit}' "$SETTINGS" 2>/dev/null)
  printf '%s' "${v:-$2}"
}

put() {   # key value - rewrite the one line, keep the rest
  local k=$1 v=$2 tmp=$RUN_DIR/.settings.new
  touch "$SETTINGS" 2>/dev/null
  grep -v "^$k=" "$SETTINGS" 2>/dev/null > "$tmp"
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv "$tmp" "$SETTINGS"
}

theme_label() {
  case "$1" in
    light)    printf 'Light  - white cards, best in a bright workshop' ;;
    dark)     printf 'Dark   - easier at night or in a dim room' ;;
    contrast) printf 'High contrast - black and white, for a failing panel' ;;
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
    "High contrast|black and white, for a dim or failing screen" || return
  local t
  case "$TUI_CHOICE" in 1) t=light ;; 2) t=dark ;; 3) t=contrast ;; esac
  put theme "$t"
  tui_setting theme "$t"
  # Redraw something so the change is visible straight away rather than at the
  # next screen the operator happens to open.
  tui_msg "Theme changed" "Now using: $(theme_label "$t")" "" \
    "Every screen from here on uses it."
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
  put textscale "$v"
  tui_setting textscale "$v"
  tui_msg "Text size changed" "Now using: $(scale_label "$v")" "" \
    "Larger text means fewer lines fit on a screen, so long" \
    "reports scroll more."
}

set_layout_default() {
  local cur; cur=$(cat "$RUN_DIR/layout" 2>/dev/null || echo compact)
  tui_menu "Which menu to open on" "currently: $cur" \
    "Short list|the common tests, peripherals behind one tile" \
    "Every test|all tiles at once" || return
  case "$TUI_CHOICE" in
    1) printf 'compact\n' > "$RUN_DIR/layout"; put layout compact ;;
    2) printf 'all\n'     > "$RUN_DIR/layout"; put layout all ;;
  esac
  tui_msg "Saved" "The main menu will open on that layout."
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
    "You can still pick a different length each time you run it."
}

set_disk_default() {
  local cur; cur=$(get disk_size 1G)
  tui_menu "Default disk benchmark size" "currently: $cur" \
    "1 GB|quick, fits inside most SSD cache" \
    "4 GB|" "16 GB|past the cache on most consumer SSDs" "64 GB|sustained behaviour" || return
  local v
  case "$TUI_CHOICE" in 1) v=1G ;; 2) v=4G ;; 3) v=16G ;; 4) v=64G ;; esac
  put disk_size "$v"
  tui_msg "Saved" "The disk benchmark will start on $v."
}

save_to_stick() {
  STORAGE_PROMPT="Which drive should the settings be kept on?"
  pick_storage || return
  if ! mount_storage; then
    tui_msg "Could not write" "$(head -1 "$RUN_DIR/mnterr" 2>/dev/null)"
    return
  fi
  if cp "$SETTINGS" "$STORAGE_MNT/diag-settings.conf" 2>/dev/null; then
    sync
    local owned=$STORAGE_OWNED
    umount_storage
    tui_msg "Settings saved" "Written to diag-settings.conf on the drive." "" \
      "They are picked up automatically the next time the toolkit" \
      "boots from it." \
      "$([ "$owned" = 1 ] && echo "The drive has been unmounted - safe to remove." || echo "")"
  else
    umount_storage
    tui_msg "Could not write" "The settings file could not be copied there."
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
  tui_setting textscale 1.0
  tui_msg "Reset" "Everything is back to its default."
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
    "Text size|$(scale_label "$(get textscale 1.0)")" \
    "Opening menu|$(cat "$RUN_DIR/layout" 2>/dev/null || echo compact)" \
    "Wireless test length|$(secs_ms "$(get wifi_secs 600)")" \
    "Disk benchmark size|$(get disk_size 1G)" \
    "Save settings to the USB stick|so the next machine starts the same way" \
    "About this toolkit|version, kernel, uptime" \
    "Reset everything|back to defaults" || break
  case "$TUI_CHOICE" in
    1) set_theme ;;
    2) set_text_size ;;
    3) set_layout_default ;;
    4) set_wifi_default ;;
    5) set_disk_default ;;
    6) save_to_stick ;;
    7) show_about ;;
    8) reset_all ;;
  esac
done
