#!/bin/bash
# Driver check: every device on the machine, whether its driver is working,
# and - for one that is not - a fix: known faults first, then the driver
# restarted, then whatever it is missing fetched from the internet, then (for
# Intel sound) the older driver. Everything fetched can be removed again.
#   drivercheck.sh          interactive
#   drivercheck.sh --quiet  scan and report only (Full run)
. /opt/diag/lib.sh
. /opt/diag/tui.sh
. /opt/diag/drivers.sh

scan_screen() {
  tui_frame "Driver check" "please wait"
  tui_line 6 "Looking at every device and what its driver made of it..." muted
  tui_line 8 "Devices with no driver are given one if the stick has it." muted
  tui_flush
  dc_scan
}

if [ "$1" = --quiet ]; then
  scan_screen
  dc_report
  exit 0
fi

tone_for() {
  case "$1" in
    OK|LOADED) echo ok ;;  FIRMWARE|NOOUT|UNBOUND) echo err ;;  OFF|NODRIVER) echo warn ;;  *) echo muted ;;
  esac
}

advice() {   # state
  case "$1" in
    OFF)      echo "Only the BIOS setup (or the Fn touchpad key) can turn it back on." ;;
    NODRIVER) echo "No download can add a driver to a running Linux. A newer Linux may know this part." ;;
    LOADED)   echo "It was not running at boot. Run its test now." ;;
    BLOCKED)  echo "On purpose: a graphics driver froze a C40-K once. The screen test still works." ;;
    *)        echo "" ;;
  esac
}

details() {   # one drivers.tsv line - a device that needs no fixing
  local st bus id type name drv ids made detail fix p row=9 e
  IFS='|' read -r st bus id type name drv ids made detail fix p <<< "$1"
  tui_frame "$name" "Enter to go back"
  case "$st" in
    OK|LOADED) tui_badge 6 PASS "$(dc_state_word "$st")" ;;
    *) tui_badge 6 UNKNOWN "$(dc_state_word "$st")" ;;
  esac
  tui_kv $row "Type" "$type"; row=$((row+1))
  tui_kv $row "Where" "$bus $id   (IDs $ids)"; row=$((row+1))
  tui_kv $row "Driver" "${drv:-none}" "$([ -n "$drv" ] && echo ok || echo warn)"; row=$((row+1))
  tui_kv $row "It made" "${made:--}"; row=$((row+1))
  [ -n "$detail" ] && [ "$st" != OK ] && tui_line $((row+1)) "$detail" "$(tone_for "$st")"
  e=$(advice "$st"); [ -n "$e" ] && tui_line 18 "$e" ""
  [ "$st" = NODRIVER ] && tui_line 19 "The IDs above are in the report, so the part can be looked up." muted
  tui_flush; tui_anykey
}

# ---------------------------------------------------------------- online
get_online() {   # -> 0 with a route to the internet
  have_route && return 0
  tui_frame "Driver check" "please wait"
  tui_line 6 "Looking for a network cable and asking for an address..." muted; tui_flush
  wired_online && return 0
  tui_confirm "No internet" yes \
    "Looking online needs the internet, and this machine is not connected." "" \
    "Open the Wi-Fi page now?  (Or plug in a network cable, choose No," \
    "then try again.)" || return 1
  DIAG_IN_WIFI=1 /opt/diag/wificonnect.sh
  [ -n "$TUI_SUB" ] && _send_sub "$TUI_SUB"
  have_route
}

# One network session for however many downloads follow: the route, the copy
# kept on the stick, and the package index.
ONLINE=0; CACHE=""
online_begin() {
  [ "$ONLINE" = 1 ] && return 0
  get_online || return 1
  CACHE=""
  STORAGE_PROMPT="Keep a copy of the downloads on which stick?  (Q to skip)"
  if lsblk -rno FSTYPE 2>/dev/null | grep -qxE 'vfat|exfat|ntfs|ext2|ext3|ext4' \
     && pick_storage && mount_storage; then
    CACHE="$STORAGE_MNT/DiagFirmware"; mkdir -p "$CACHE" 2>/dev/null || CACHE=""
  fi
  tui_frame "Driver check" "reading the package index"
  tui_line 6 "Asking the Ubuntu archive what belongs with this kernel..." muted; tui_flush
  if ! apt_ready; then
    online_end
    tui_msg "Could not reach the archive" "$(tail -2 "$RUN_DIR/apt.log" 2>/dev/null | head -1)" "" \
      "Check that this network allows archive.ubuntu.com."
    return 1
  fi
  ONLINE=1
}

online_end() {
  [ -n "$CACHE" ] && { sync; umount_storage; }
  CACHE=""; ONLINE=0
}

fetch_pkg() {   # package -> 0 once unpacked into the firmware tree
  local pkg=$1 deb=""
  [ -n "$CACHE" ] && deb=$(ls -1 "$CACHE"/${pkg}_*.deb 2>/dev/null | sort -V | tail -1)
  if [ -z "$deb" ] || [ ! -s "$deb" ]; then
    deb=$(download_pkg "$pkg") || deb=""
    [ -n "$deb" ] || { dc_log "download failed: $pkg"; return 1; }
    [ -n "$CACHE" ] && cp "$deb" "$CACHE/" 2>/dev/null
  fi
  install_deb "$deb" || { dc_log "unpack failed: $pkg"; return 1; }
  rm -f "$RUN_DIR"/${pkg}_*.deb
  rsilent "Driver check: installed $pkg into RAM (nothing written to this machine's drive)"
  return 0
}

# ---------------------------------------------------------------- fixing
fix_plan() {   # state type detail fix -> what Fix will try, in a line
  case "$1" in
    FIRMWARE) echo "Fix downloads $4 from the Ubuntu archive and restarts the driver." ;;
    *)
      if dc_gpu_wait "$3"; then
        echo "Fix tells the sound driver not to wait for graphics, then checks it again."
      elif [ "$2" = Sound ]; then
        echo "Fix restarts the driver, looks online for what it is missing, then tries the older sound driver."
      else
        echo "Fix restarts the driver, then looks online for anything it is missing."
      fi ;;
  esac
}

ask_fix() {   # line -> 0 when the operator wants it fixed
  local st bus id type name drv ids made detail fix p e
  IFS='|' read -r st bus id type name drv ids made detail fix p <<< "$1"
  e=$(dc_errors "$id" | tail -1)
  tui_confirm "$name" yes \
    "$(dc_state_word "$st")  -  $type  -  driver: ${drv:-none}" \
    "$detail" \
    "${e:+Kernel: ${e:0:100}}" \
    "" \
    "$(fix_plan "$st" "$type" "$detail $e" "$fix")" \
    "" "Try to fix it now?"
}

FIX_STEPS=(); FIX_NAME=""
fstep() {   # text [tone] - adds a line to the fixing screen and redraws it
  FIX_STEPS+=("$1|${2:-}")
  local row=8 s
  tui_frame "Fixing: $FIX_NAME" "please wait"
  tui_line 6 "Trying the fixes one at a time, checking the device after each." muted
  for s in "${FIX_STEPS[@]}"; do
    [ $row -gt 19 ] && break
    tui_line $row "${s%|*}" "${s##*|}"; row=$((row+1))
  done
  tui_flush
}

# Everything that can be tried for one device, cheapest first; the first
# attempt that leaves it working ends it. FIX_OK=1 when it worked.
fix_device() {   # drivers.tsv line [batch]
  local st bus id type name drv ids made detail fix p pkg batch=${2:-} before
  IFS='|' read -r st bus id type name drv ids made detail fix p <<< "$1"
  FIX_NAME=$name; FIX_STEPS=(); FIX_OK=0; before=$st
  fstep "Problem: $(dc_state_word "$st") - $detail" warn
  while :; do
    if dc_fix_known "$bus" "$id" "$type"; then
      fstep "Recognised it: $DC_FIX_SAID"
      dc_settle "$bus" "$id" && { FIX_OK=1; break; }
      fstep "  that was not enough on its own" muted
    fi
    if [ "$st" != FIRMWARE ]; then
      fstep "Restarting the driver..."
      dc_restart_device "$bus" "$id" "$drv" "$p"
      dc_settle "$bus" "$id" && { FIX_OK=1; break; }
    fi
    IFS='|' read -r st bus id type name drv ids made detail fix p <<< "$(dc_line "$bus" "$id")"
    pkg=$fix
    [ -z "$pkg" ] && [ -n "$drv" ] && dc_errors "$id" | grep -qi 'firmware\|board' && pkg=$(dc_driver_package "$drv")
    if [ -n "$pkg" ]; then
      fstep "Looking online for $pkg..."
      if online_begin; then
        if fetch_pkg "$pkg"; then fstep "  downloaded and unpacked" ok; else fstep "  could not download it" warn; fi
        dc_restart_device "$bus" "$id" "$drv" "$p"
        dc_settle "$bus" "$id" && { FIX_OK=1; break; }
      else
        fstep "  no internet - connect a cable or Wi-Fi, then try again" warn
      fi
    else
      fstep "Nothing to download: the driver is on the stick and asked for no missing files" muted
    fi
    if [ "$type" = Sound ] && [ "$bus" = pci ] && [ "$(sed 's/^0x//' "/sys/bus/pci/devices/$id/vendor" 2>/dev/null)" = 8086 ]; then
      dc_fix_audio_legacy "$id" && {
        fstep "Last try: $DC_FIX_SAID"
        dc_settle "$bus" "$id" && { FIX_OK=1; break; }
      }
    fi
    break
  done

  local now; now=$(dc_line "$bus" "$id")
  IFS='|' read -r st bus id type name drv ids made detail fix p <<< "$now"
  if [ "$FIX_OK" = 1 ]; then fstep "Fixed: it now works${made:+ - it made $made}" ok
  else fstep "Still not working: $(dc_state_word "${st:-$before}")${detail:+ - $detail}" err; fi
  rsection "DRIVER FIX -- $FIX_NAME"
  local s; for s in "${FIX_STEPS[@]}"; do rsilent "  ${s%|*}"; done
  [ "$FIX_OK" = 1 ] || dc_errors "$id" | while IFS= read -r s; do rsilent "  log: $s"; done
  if [ -z "$batch" ]; then
    tui_frame "Fixing: $FIX_NAME" "Enter to go back"
    tui_badge 6 "$([ "$FIX_OK" = 1 ] && echo PASS || echo FAIL)" \
      "$([ "$FIX_OK" = 1 ] && echo "fixed" || echo "still not working")"
    local row=8
    for s in "${FIX_STEPS[@]}"; do
      [ $row -gt 17 ] && break
      tui_line $row "${s%|*}" "${s##*|}"; row=$((row+1))
    done
    if [ "$FIX_OK" != 1 ]; then
      s=$(dc_errors "$id" | tail -1)
      [ -n "$s" ] && tui_line 19 "Kernel: ${s:0:110}" muted
      tui_line 20 "This points at the part itself, its connector, or a BIOS setting." ""
    fi
    tui_flush; tui_anykey
  fi
  [ "$FIX_OK" = 1 ]
}

fix_all() {
  local l todo res=() ok=0 row=8 r st bus id type name
  mapfile -t todo < <(grep -E '^(FIRMWARE|NOOUT|UNBOUND)\|' "$DC_TSV")
  for l in "${todo[@]}"; do
    IFS='|' read -r st bus id type name _ <<< "$l"
    # an earlier fix may have mended this one too (both sound devices share
    # the graphics wait), so look again before working on it
    dc_rescan_one "$bus" "$id"
    if dc_working "$bus" "$id"; then
      ok=$((ok+1)); res+=("$name|fixed along the way|ok"); continue
    fi
    if fix_device "$(dc_line "$bus" "$id")" batch; then
      ok=$((ok+1)); res+=("$name|fixed|ok")
    else
      res+=("$name|still not working|err")
    fi
  done
  online_end
  tui_frame "Fix everything" "Enter to go back"
  tui_badge 6 "$([ $ok = ${#todo[@]} ] && echo PASS || echo PARTIAL)" "fixed $ok of ${#todo[@]}"
  for r in "${res[@]}"; do
    [ $row -gt 19 ] && break
    IFS='|' read -r name st type <<< "$r"
    tui_kv $row "$name" "$st" "$type"; row=$((row+1))
  done
  tui_flush; tui_anykey
  DC_NOTE="Fixed $ok of ${#todo[@]}."
}

remove_downloads() {
  local n f
  n=$(grep -c . "$DC_ADDED" 2>/dev/null)
  tui_confirm "Remove downloaded files" yes \
    "Take away the $n file(s) this session downloaded?" "" \
    "A device already running keeps working until the machine restarts." \
    "Nothing was ever written to this machine's own drive." || return
  while IFS= read -r f; do
    case "$f" in "$FW_DIR"/*) rm -f "$f" ;; esac
  done < "$DC_ADDED"
  : > "$DC_ADDED"
  rsilent "Driver check: downloaded files removed ($n)."
  DC_NOTE="Removed $n downloaded file(s)."
}

# ---------------------------------------------------------------- the list
DC_NOTE=""
scan_screen
dc_report
while :; do
  bad=$(dc_count FIRMWARE NOOUT UNBOUND); soft=$(dc_count OFF NODRIVER)
  nadd=$(grep -c . "$DC_ADDED" 2>/dev/null); nadd=${nadd:-0}
  if [ "$bad" -gt 0 ]; then title="Driver check - $bad not working"
  elif [ "$soft" -gt 0 ]; then title="Driver check - $soft without a driver"
  else title="Driver check - all working"; fi
  entries=(); acts=()
  if [ "$bad" -gt 0 ]; then
    entries+=("Fix everything|$bad device(s)|known fixes, then downloads"); acts+=(fixall)
  fi
  if [ "$nadd" -gt 0 ]; then
    entries+=("Remove downloaded files|$nadd file(s)|this session only"); acts+=(remove)
  fi
  entries+=("Check again|look at every device once more|"); acts+=(rescan)
  mapfile -t lines < <(dc_sorted | grep -v '^NONE|')
  for l in "${lines[@]}"; do
    IFS='|' read -r st bus id type name drv ids made detail fix p <<< "$l"
    entries+=("$name|$(dc_state_word "$st")|$type${drv:+ - $drv}"); acts+=("dev:$l")
  done
  hint="Enter on a device to fix it or see why      Q to go back"
  [ -n "$DC_NOTE" ] && hint="$DC_NOTE      $hint"
  tui_menu "$title" "$hint" "${entries[@]}" || break
  act=${acts[$((TUI_CHOICE-1))]}
  case "$act" in
    fixall) fix_all; scan_screen; dc_report ;;
    remove) remove_downloads; scan_screen; dc_report ;;
    rescan) DC_NOTE=""; scan_screen; dc_report ;;
    dev:*)
      l=${act#dev:}
      case "${l%%|*}" in
        FIRMWARE|NOOUT|UNBOUND)
          if ask_fix "$l"; then
            fix_device "$l"; online_end
            DC_NOTE="$([ "$FIX_OK" = 1 ] && echo "Fixed: $FIX_NAME." || echo "$FIX_NAME: still not working.")"
            scan_screen; dc_report
          fi ;;
        *) details "$l" ;;
      esac ;;
  esac
done
exit 0
