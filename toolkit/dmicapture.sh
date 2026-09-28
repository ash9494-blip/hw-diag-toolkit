#!/bin/bash
# Capture the machine's SMBIOS identity, ready for a board swap.
#
# This does NOT write anything to the firmware - it cannot, and neither can any
# Linux tool. Writing those fields goes through the vendor's own service utility
# (on Toshiba/Dynabook that is SetDmiAll, which needs Windows and its TVALZ
# driver). What this does is remove the part that actually goes wrong: retyping
# a serial by hand onto the replacement board.
#
# Run it on the machine BEFORE the board comes out. It writes:
#   dmichg.txt  - SetDmiAll's own input format, ready to point the tool at
#   *-dmi.txt   - the full dmidecode dump, for anything dmichg.txt cannot carry
#
# Fields map onto SMBIOS as follows, which is how SetDmiAll names them:
#   Manufacturer       type 1  Manufacturer
#   ProductName        type 1  Product Name
#   SerialNumber       type 1  Serial Number
#   PartNumber         type 1  SKU Number  (Toshiba part number, PT###U-######)
#   SerialNumberType3  type 3  Chassis serial
#   AssetTag           type 3  Chassis asset tag
#   AssetTagType2      type 2  Baseboard asset tag
#   OemType11          type 11 OEM strings
# GSWID is Toshiba-specific and is not exposed in SMBIOS, so it is left blank
# for you to fill from the vendor record.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

dmi_field() { dmidecode -s "$1" 2>/dev/null | grep -v '^#' | head -1 | sed 's/[[:space:]]*$//'; }

oem_strings() {
  # Placeholder slots are padding, not data - SetDmiAll wants only the real ones.
  dmidecode -t 11 2>/dev/null \
    | awk '/String [0-9]+:/ {sub(/^[[:space:]]*String [0-9]+:[[:space:]]*/, ""); print}' \
    | grep -vxE 'Not Specified|To Be Filled By O\.E\.M\.|Default string|' \
    | paste -sd, - | sed 's/[[:space:]]*$//'
}

blank_ok() {   # firmware writes these when a field was never programmed
  case "$1" in
    ""|"To Be Filled By O.E.M."|"To be filled by O.E.M."|"Default string"|\
    "Not Specified"|"None"|"System Serial Number"|"System Product Name"|\
    "System manufacturer"|"Chassis Serial Number"|"Base Board Asset Tag"|"O.E.M.")
      return 0 ;;
  esac
  return 1
}

MANU=$(dmi_field system-manufacturer)
PROD=$(dmi_field system-product-name)
SERIAL=$(dmi_field system-serial-number)
SKU=$(dmi_field system-sku-number)
CH_SERIAL=$(dmi_field chassis-serial-number)
CH_ASSET=$(dmi_field chassis-asset-tag)
BB_ASSET=$(dmi_field baseboard-asset-tag)
BB_SERIAL=$(dmi_field baseboard-serial-number)
OEM11=$(oem_strings)

# Anything the operator corrected on the Machine details screen is what they
# read off the chassis sticker, so it is better evidence than blank firmware.
OVR_SERIAL=""; OVR_PROD=""; OVR_MANU=""
if [ -s "$BOARD_OVERRIDE" ]; then
  OVR_MANU=$(awk -F= '/^system-manufacturer=/{print substr($0,index($0,"=")+1)}'  "$BOARD_OVERRIDE")
  OVR_PROD=$(awk -F= '/^system-product-name=/{print substr($0,index($0,"=")+1)}'  "$BOARD_OVERRIDE")
  OVR_SERIAL=$(awk -F= '/^system-serial-number=/{print substr($0,index($0,"=")+1)}' "$BOARD_OVERRIDE")
fi

MISMATCH=""
[ -n "$OVR_SERIAL" ] && [ -n "$SERIAL" ] && [ "$OVR_SERIAL" != "$SERIAL" ] \
  && MISMATCH="serial: firmware says '$SERIAL', you entered '$OVR_SERIAL'"

BLANKS=0
for v in "$MANU" "$PROD" "$SERIAL"; do blank_ok "$v" && BLANKS=$((BLANKS+1)); done

# Placeholder text is the firmware saying "never programmed". Writing it into
# dmichg.txt would program the literal words "Not Specified" onto the new board,
# which is worse than leaving the field empty for you to fill.
clean() { blank_ok "$1" && printf '' || printf '%s' "$1"; }

write_files() {   # $1 = directory
  local dir=$1 tag stamp
  tag=$(machine_tag); stamp=$(date '+%Y%m%d-%H%M%S')
  OUT_DIR="$dir/DmiCapture/${tag}_${stamp}"
  mkdir -p "$OUT_DIR" 2>/dev/null || return 1

  # SetDmiAll input file. Written with CRLF because it is read on Windows.
  {
    printf 'Manufacturer=%s\r\n' "$(clean "${OVR_MANU:-$MANU}")"
    printf 'PartNumber=%s\r\n' "$(clean "$SKU")"
    printf 'ProductName=%s\r\n' "$(clean "${OVR_PROD:-$PROD}")"
    printf 'SerialNumber=%s\r\n' "$(clean "${OVR_SERIAL:-$SERIAL}")"
    printf 'SerialNumberType3=%s\r\n' "$(clean "$CH_SERIAL")"
    printf 'AssetTag=%s\r\n' "$(clean "$CH_ASSET")"
    printf 'AssetTagType2=%s\r\n' "$(clean "$BB_ASSET")"
    printf 'OemType11=%s\r\n'         "$OEM11"
    printf 'GSWID=\r\n'
  } > "$OUT_DIR/dmichg.txt"

  {
    echo "DMI capture taken by the Hardware Diagnostic Toolkit $DIAG_VERSION"
    echo "$(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "Captured from this machine BEFORE any board change."
    echo "dmichg.txt next to this file is ready for SetDmiAll on Windows."
    echo "Fields the firmware never had are left EMPTY there on purpose - fill"
    echo "them from the chassis sticker rather than writing placeholder text."
    [ -n "$MISMATCH" ] && { echo; echo "WARNING - $MISMATCH"; }
    echo
    echo "--- fields SetDmiAll writes ---"
    printf '%-20s %s\n' "Manufacturer"      "${OVR_MANU:-$MANU}"
    printf '%-20s %s\n' "PartNumber"        "$SKU"
    printf '%-20s %s\n' "ProductName"       "${OVR_PROD:-$PROD}"
    printf '%-20s %s\n' "SerialNumber"      "${OVR_SERIAL:-$SERIAL}"
    printf '%-20s %s\n' "SerialNumberType3" "$CH_SERIAL"
    printf '%-20s %s\n' "AssetTag"          "$CH_ASSET"
    printf '%-20s %s\n' "AssetTagType2"     "$BB_ASSET"
    printf '%-20s %s\n' "OemType11"         "$OEM11"
    printf '%-20s %s\n' "GSWID"             "(not in SMBIOS - fill from the vendor record)"
    echo
    printf '%-20s %s\n' "Baseboard serial"  "$BB_SERIAL"
    echo
    echo "--- full SMBIOS dump ---"
    dmidecode 2>/dev/null
  } > "$OUT_DIR/dmi-full.txt"
  sync
  return 0
}

# ---------------------------------------------------------------- screen
tui_frame "DMI capture" "Enter to continue"
tui_line 6  "This records the identity the firmware is reporting now, so you can" ""
tui_line 7  "put it back on a replacement board without retyping anything." ""
tui_line 9  "Nothing is written to this machine's firmware. Writing is done by" muted
tui_line 10 "SetDmiAll on Windows, which this file feeds." muted
tui_kv 12 "Manufacturer" "${MANU:-blank}"
tui_kv 13 "Model"        "${PROD:-blank}"
tui_kv 14 "Serial"       "${SERIAL:-blank}" "$(blank_ok "$SERIAL" && echo warn || echo ok)"
tui_kv 15 "Part number"  "${SKU:-blank}"
tui_kv 16 "Chassis serial" "${CH_SERIAL:-blank}"
row=18
if [ "$BLANKS" -gt 0 ]; then
  tui_line $row "$BLANKS field(s) are blank or placeholder text." warn; row=$((row+1))
  tui_line $row "On a replaced board that is expected - use the chassis sticker." muted; row=$((row+1))
fi
[ -n "$MISMATCH" ] && tui_line $row "$MISMATCH" warn
tui_flush
tui_anykey

STORAGE_PROMPT="Where should the DMI capture be saved?"
pick_storage || exit 0
if ! mount_storage; then
  tui_msg "Could not write to $STORAGE_DEV" \
    "$(head -1 "$RUN_DIR/mnterr" 2>/dev/null)" "" \
    "Pick a different partition, or plug in a USB stick" \
    "formatted FAT32, exFAT or NTFS."
  exit 0
fi
if write_files "$STORAGE_MNT"; then
  REL=${OUT_DIR#"$STORAGE_MNT"/}
  OWNED=$STORAGE_OWNED
  umount_storage
  rsection "DMI CAPTURE"
  rsilent "Saved to        : $REL"
  rsilent "Manufacturer    : ${OVR_MANU:-$MANU}"
  rsilent "Product name    : ${OVR_PROD:-$PROD}"
  rsilent "Serial number   : ${OVR_SERIAL:-$SERIAL}"
  rsilent "Part number     : $SKU"
  rsilent "Chassis serial  : $CH_SERIAL"
  [ -n "$MISMATCH" ] && rsilent "WARNING         : $MISMATCH"
  rsilent "RESULT: CAPTURED (dmichg.txt written for SetDmiAll)"
  set_kv DMI_CAPTURE "saved to $REL"

  tui_frame "DMI captured" "Enter to go back"
  tui_badge 6 OK "identity saved to the stick"
  tui_line 9  "$REL/" ""
  tui_line 10 "    dmichg.txt    ready for SetDmiAll on Windows" muted
  tui_line 11 "    dmi-full.txt  the complete SMBIOS dump" muted
  tui_line 13 "On the new board: boot Windows, run SetDmiAll and point it at" ""
  tui_line 14 "dmichg.txt. Check the serial against the chassis sticker first." muted
  [ "$OWNED" = 1 ] && tui_line 16 "The drive has been unmounted - safe to remove." muted
  tui_flush
  tui_anykey
else
  umount_storage
  tui_msg "Could not write" "The capture folder could not be created on $STORAGE_DEV."
fi
