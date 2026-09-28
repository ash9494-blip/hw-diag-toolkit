#!/bin/bash
# Correct the machine identity used in the report.
#
# This does NOT touch the motherboard - nothing is written to firmware. It only
# overrides what the toolkit prints and names the report file, which is what you
# need when the firmware reports a blank serial (common on whitebox laptops) or
# still carries the old board's identity after a swap. Every corrected field is
# marked in the report as operator-entered so the record stays honest.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

FIELDS="system-manufacturer system-product-name system-serial-number baseboard-product-name"
label_of() {
  case "$1" in
    system-manufacturer)  echo "Manufacturer" ;;
    system-product-name)  echo "Model" ;;
    system-serial-number) echo "Serial number" ;;
    baseboard-product-name) echo "Board model" ;;
  esac
}

set_field() {   # key value
  local tmp=$RUN_DIR/board.tmp
  touch "$BOARD_OVERRIDE"
  grep -v "^$1=" "$BOARD_OVERRIDE" > "$tmp" 2>/dev/null
  [ -n "$2" ] && printf '%s=%s\n' "$1" "$2" >> "$tmp"
  mv "$tmp" "$BOARD_OVERRIDE"
}

show() {
  tui_frame "Machine details" "arrows + Enter to correct a field, Q to go back"
  tui_line 6 "These values name the report and appear in its header." muted
  tui_line 7 "Nothing is written to the motherboard." muted
}

edit_one() {
  local key=$1 cur raw
  raw=$(dmi_raw "$key")
  tui_input "Correct: $(label_of "$key")" \
    "Firmware reports: ${raw:-(blank)}    Type the correct value:"
  [ -z "$TUI_TEXT" ] && return
  set_field "$key" "$TUI_TEXT"
}

while :; do
  items=()
  for f in $FIELDS; do
    cur=$(dmi "$f"); raw=$(dmi_raw "$f")
    mark=""
    dmi_is_override "$f" && mark="  (corrected)"
    items+=("$(label_of "$f")|${cur:-not reported}${mark}")
  done
  items+=("Clear all corrections|go back to what the firmware reports")

  tui_menu "Machine details" \
    "corrects the report only - nothing is written to the motherboard" \
    "${items[@]}" || break

  case "$TUI_CHOICE" in
    1) edit_one system-manufacturer ;;
    2) edit_one system-product-name ;;
    3) edit_one system-serial-number ;;
    4) edit_one baseboard-product-name ;;
    5) rm -f "$BOARD_OVERRIDE"
       tui_msg "Corrections cleared" "The report will use the firmware values again." ;;
  esac
done

# Record what was corrected, so the report says so rather than quietly lying.
if [ -s "$BOARD_OVERRIDE" ]; then
  rsection "MACHINE DETAILS CORRECTED BY OPERATOR"
  while IFS='=' read -r k v; do
    [ -z "$k" ] && continue
    rsilent "$(printf '%-22s %s' "$(label_of "$k")" "$v")"
    rsilent "$(printf '%-22s %s' "  firmware reported" "$(dmi_raw "$k" || echo '(blank)')")"
  done < "$BOARD_OVERRIDE"
  set_kv BOARD_CORRECTED "yes"
fi
