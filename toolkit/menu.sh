#!/bin/bash
# Hardware Diagnostic Toolkit -- main menu
. /opt/diag/lib.sh

# --- startup -----------------------------------------------------------------
# The renderer has to be up before tui.sh is sourced, because that is where the
# graphical/text decision is made. Everything the toolkit launches afterwards
# inherits the same choice.
# Laptop panels are high resolution, so the default console font is unreadable
# at arm's length. Only needed when the graphical renderer is not running.
set_console_font() {
  case "$(tty)" in /dev/tty[0-9]*) ;; *) return ;; esac
  local h font
  h=$(cut -d, -f2 /sys/class/graphics/fb0/virtual_size 2>/dev/null)
  case "$h" in ''|*[!0-9]*) return ;; esac
  if   [ "$h" -ge 1300 ]; then font=Lat15-TerminusBold32x16
  elif [ "$h" -ge 900 ];  then font=Lat15-TerminusBold28x14
  elif [ "$h" -ge 700 ];  then font=Lat15-TerminusBold24x12
  else return
  fi
  [ -f "/usr/share/consolefonts/$font.psf.gz" ] && setfont "$font" 2>/dev/null
}

daemon_alive() {
  [ -r "$RUN_DIR/ui.pid" ] && kill -0 "$(cat "$RUN_DIR/ui.pid" 2>/dev/null)" 2>/dev/null
}

# --- one copy only ------------------------------------------------------------
# Machines with a serial port - and every virtual machine - log in automatically
# on ttyS0 as well as tty1, so the toolkit was being started twice. Both copies
# talked to the same interface and stole each other's keystrokes, which is why a
# menu choice would sometimes land on the wrong test. The screen gets first
# refusal; whoever else arrives gets a plain shell instead.
# The console the operator is actually looking at gets to claim it first. That
# is the last console= on the kernel command line, which is the same rule the
# kernel uses for /dev/console, and tty1 when nothing was asked for.
preferred_tty() {
  local last=""
  for w in $(cat /proc/cmdline 2>/dev/null); do
    case "$w" in console=*) last=${w#console=}; last=${last%%,*} ;; esac
  done
  printf '/dev/%s\n' "${last:-tty1}"
}
[ "$(tty)" = "$(preferred_tty)" ] || sleep 3
exec 8>"$RUN_DIR/toolkit.lock"
if ! flock -n 8; then
  clear
  printf '\n  The Hardware Diagnostic Toolkit is running on the main screen.\n'
  printf '  This console is left free for manual commands.\n\n'
  exec bash --norc
fi

if [ ! -f "$RUN_DIR/.seeded" ]; then
  console_quiet
  clear
  printf '\n  Detecting hardware, please wait...\n'
  modprobe coretemp 2>/dev/null; modprobe k10temp 2>/dev/null
  NEW_BOOT=1
fi

daemon_alive || /opt/diag/start-ui.sh || set_console_font

. /opt/diag/tui.sh

if [ ! -f "$RUN_DIR/.seeded" ]; then
  # Settings left on the boot medium by a previous session, if any. Copied in
  # before the first screen so the theme and text size are right immediately.
  for m in /run/live/medium /lib/live/mount/medium /usr/lib/live/mount/medium; do
    [ -f "$m/diag-settings.conf" ] && { cp "$m/diag-settings.conf" "$RUN_DIR/settings.conf"; break; }
  done
  /opt/diag/sysinfo.sh --quiet
  # Firmware-load failures are printed once, while the drivers bind at boot.
  # The ring buffer rolls over on a chatty machine and a long test can push
  # them out, so the record is kept here the moment the toolkit starts. Get
  # firmware reads this as well as the live log.
  dmesg 2>/dev/null | grep -iE 'firmware|microcode' > "$RUN_DIR/boot-firmware.log" 2>/dev/null
  touch "$RUN_DIR/.seeded"
fi

boot_disk() {
  local src p
  src=$(findmnt -no SOURCE /run/live/medium 2>/dev/null)
  [ -z "$src" ] && src=$(findmnt -no SOURCE / 2>/dev/null)
  case "$src" in /dev/*) ;; *) echo ""; return ;; esac
  p=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
  [ -n "$p" ] && echo "$p" || basename "$src"
}

auto_target_disk() {
  local boot; boot=$(boot_disk)
  local n rm
  while read -r n _; do
    [ "$n" = "$boot" ] && continue
    rm=$(lsblk -dno RM "/dev/$n" 2>/dev/null | head -1 | tr -d " ")   # lsblk right-aligns: " 0"
    [ "$rm" = 0 ] || continue
    printf '%s\n' "$n"; return
  done < <(list_disks)
}

full_run() {
  local disk; disk=$(auto_target_disk)
  local diskline="Disk benchmark on /dev/$disk  (read only)        about 2 min"
  [ -z "$disk" ] && diskline="Disk benchmark                                  skipped, no drive found"

  tui_confirm "Full diagnostic run" yes \
    "1.  System info, battery health, SMART          about 1 min" \
    "2.  $diskline" \
    "3.  CPU stress and temperature log              about 10 min" \
    "4.  RAM stress test                             about 5 min" \
    "5.  Save the report" \
    "" \
    "Nothing is written to the tested drive. Each stage stops with Q." \
    "" "Start now?" || return

  /opt/diag/sysinfo.sh --quiet

  if [ -n "$disk" ]; then
    /opt/diag/disktest.sh auto "$disk" 1G 1
  else
    # No drive is a finding, not a reason to abandon the whole run.
    tui_frame "Full run - storage" "continuing automatically"
    tui_badge 6 UNKNOWN "no drive detected"
    tui_line 9  "No internal drive was found, so the disk benchmark is skipped."
    tui_line 10 "Check that the drive is seated, or run the disk test manually." muted
    local i
    for i in 5 4 3 2 1; do
      tui_line 12 "Moving on to the CPU test in ${i}s" muted
      tui_flush; sleep 1
    done
    rsection "DISK BENCHMARK"
    rsilent "RESULT: SKIPPED -- no internal drive was detected"
    set_kv DISK_RESULT "SKIPPED (no drive detected)"
  fi

  AUTO=1 /opt/diag/cputest.sh auto 10
  AUTO=1 /opt/diag/ramtest.sh auto 5

  tui_frame "Full run complete" "Enter to save the report"
  local row=6 l
  while IFS= read -r l; do
    [ $row -gt 20 ] && break
    case "$l" in
      *FAIL*)    tui_line $row "$l" err ;;
      *PASS*)    tui_line $row "$l" ok ;;
      *SKIPPED*) tui_line $row "$l" muted ;;
      *)         tui_line $row "$l" warn ;;
    esac
    row=$((row+1))
  done < <(grep -E '^RESULT:|^SMART health:' "$REPORT_TXT")
  tui_flush
  tui_anykey
  /opt/diag/savereport.sh
}

view_report() {
  if [ ! -s "$REPORT_TXT" ]; then
    tui_msg "Nothing collected" "No test results have been collected yet."
    return
  fi
  tui_pager "Collected results" "$REPORT_TXT"
}

stop_ui() {
  if [ "$TUI_GUI" = 1 ]; then
    _s quit 2>/dev/null
    sleep 0.6
  fi
  tui_done 2>/dev/null
}

power_menu() {
  tui_menu "Finish" "arrows + Enter, Q to go back" \
    "Reboot|restart this machine" \
    "Power off|shut down" \
    "Shell|advanced, for manual commands" \
    "Toolkit log|what the interface itself has been doing" \
    "Back|return to the menu" || return
  case "$TUI_CHOICE" in
    1) stop_ui; clear; echo "Rebooting..."; sync; reboot -f ;;
    2) stop_ui; clear; echo "Powering off..."; sync; poweroff -f ;;
    3) stop_ui; clear
       echo "Type 'exit' to return to the toolkit."
       PS1='diag:\w# ' bash --norc -i 8>&- 2>/dev/tty
       exec /opt/diag/menu.sh ;;
    4) if [ -s "$RUN_DIR/ui.log" ] || [ -s "$RUN_DIR/wifi_scan.log" ]; then
         { if [ -s "$RUN_DIR/wifi_join.log" ]; then
             echo "=== wireless connections ==="; cat "$RUN_DIR/wifi_join.log"; echo
           fi
           if [ -s "$RUN_DIR/drivers.log" ]; then
             echo "=== driver search ==="; cat "$RUN_DIR/drivers.log"; echo
           fi
           if [ -s "$RUN_DIR/wifi_scan.log" ]; then
             echo "=== wireless scans ==="; cat "$RUN_DIR/wifi_scan.log"; echo
           fi
           echo "=== interface ==="; cat "$RUN_DIR/ui.log" 2>/dev/null
         } > "$RUN_DIR/toolkit-log.txt"
         tui_pager "Toolkit log" "$RUN_DIR/toolkit-log.txt"
       else
         tui_msg "Toolkit log" "Nothing logged - the text interface is in use."
       fi ;;
  esac
}

# A drain test that was still running when the battery died left its log on the
# USB stick; offer to finish it rather than make the user start over.
[ "$NEW_BOOT" = 1 ] && /opt/diag/battery.sh --check-resume

tui_sub "$(dmi system-manufacturer) $(dmi system-product-name)
$(cpu_model) - $(mem_total_mb) MB"

# --- the two layouts ----------------------------------------------------------
# Compact is the default: the six peripheral tests live behind one tile. The
# "Show all tests" tile switches to the full sixteen, and Q there comes back.
# The choice lasts until reboot, so it is not re-made after every test.
LAYOUT_FILE=$RUN_DIR/layout
layout() { cat "$LAYOUT_FILE" 2>/dev/null || echo compact; }
set_layout() { printf '%s\n' "$1" > "$LAYOUT_FILE"; }

drop_to_shell() {
  stop_ui; clear
  printf '\n  Hardware Diagnostic Toolkit - command prompt\n'
  printf '  Type "exit" to return to the menu.\n\n'
  # without the lock fd, so nothing started from the prompt can hold it.
  # -i and stderr on the terminal: a shell that inherits a redirected stderr
  # decides it is not interactive - no prompt, arrow keys printed as ^[[A.
  PS1='diag:\w# ' bash --norc -i 8>&- 2>/dev/tty
  exec /opt/diag/menu.sh
}

run_test() {   # one dispatcher, so both layouts stay in step
  case "$1" in
    fullrun)  full_run ;;
    disk)     /opt/diag/disktest.sh ;;
    installsim) /opt/diag/installsim.sh ;;
    cpu)      /opt/diag/cputest.sh ;;
    ram)      /opt/diag/ramtest.sh ;;
    battery)  /opt/diag/battery.sh ;;
    keyboard) /opt/diag/keyboard.sh ;;
    touchpad) /opt/diag/touchpad.sh ;;
    touchscreen) /opt/diag/touchscreen.sh ;;
    screen)   /opt/diag/screentest.sh ;;
    wireless) /opt/diag/wifitest.sh ;;
    wificonnect) /opt/diag/wificonnect.sh ;;
    shell)    drop_to_shell ;;
    settings) /opt/diag/settings.sh ;;
    sound)    /opt/diag/soundtest.sh ;;
    usb)      /opt/diag/usbtest.sh ;;
    camera)   /opt/diag/cameratest.sh ;;
    network)  /opt/diag/nettest.sh ;;
    system)   /opt/diag/sysinfo.sh ;;
    board)    /opt/diag/boardinfo.sh ;;
    dmi)      /opt/diag/dmicapture.sh ;;
    firmware) /opt/diag/getfirmware.sh ;;
    results)  view_report ;;
    save)     /opt/diag/savereport.sh ;;
  esac
}

peripherals_menu() {
  local acts=(all screen touchpad touchscreen sound usb camera network wireless firmware)
  while :; do
    tui_grid "Peripherals" "arrows to move, Enter to select      Q = back" \
      "Run them all|grid" \
      "Screen|screen|$(test_result SCREEN_RESULT)" \
      "Touchpad|touchpad|$(test_result TOUCHPAD_RESULT)" \
      "Touchscreen|touchscreen|$(test_result TOUCHSCREEN_RESULT)" \
      "Sound|sound|$(test_result SOUND_RESULT)" \
      "USB ports|usb|$(test_result USB_RESULT)" \
      "Camera|camera|$(test_result CAMERA_RESULT)" \
      "Ethernet Network|network|$(test_result ETHERNET_RESULT)" \
      "Wireless test|wifi|$(test_result WIFI_RESULT)" \
      "Get firmware|download" || return
    if [ "${acts[$((TUI_CHOICE-1))]}" = all ]; then
      local t
      for t in screen touchpad touchscreen sound usb camera network wireless; do run_test "$t"; done
    else
      run_test "${acts[$((TUI_CHOICE-1))]}"
    fi
  done
}

compact_menu() {
  local acts=(fullrun disk cpu ram battery keyboard peripherals wificonnect system board dmi results save shell settings showall)
  tui_grid "Choose a test" "arrows or its number (two digits for 10+), Enter to select      Q = power menu" \
    "Full run|play" \
    "HDD / SSD|disk|$(test_result DISK_RESULT DISK_SELFTEST DISK_SMART)" \
    "CPU|cpu|$(test_result CPU_RESULT)" \
    "RAM|ram|$(test_result RAM_RESULT)" \
    "Battery|battery|$(test_result BATTERY_RESULT)" \
    "Keyboard|keyboard|$(test_result KEYBOARD_RESULT)" \
    "Peripherals|grid" "Wi-Fi|wifi" "System|info" "Machine details|pencil" \
    "DMI capture|chip" "Results|list" "Save report|save" "Command prompt|terminal" \
    "Settings|gear" "Show all tests|expand" || return 1
  case "${acts[$((TUI_CHOICE-1))]}" in
    peripherals) peripherals_menu ;;
    showall)     set_layout all ;;
    *)           run_test "${acts[$((TUI_CHOICE-1))]}" ;;
  esac
  return 0
}

expanded_menu() {
  local acts=(fullrun disk cpu ram battery keyboard screen touchpad touchscreen sound usb camera network wificonnect wireless system board dmi firmware results save shell settings)
  tui_grid "Every test" "arrows or its number, Enter to select      Q = back to the short list" \
    "Full run|play" \
    "HDD / SSD|disk|$(test_result DISK_RESULT DISK_SELFTEST DISK_SMART)" \
    "CPU|cpu|$(test_result CPU_RESULT)" "RAM|ram|$(test_result RAM_RESULT)" \
    "Battery|battery|$(test_result BATTERY_RESULT)" \
    "Keyboard|keyboard|$(test_result KEYBOARD_RESULT)" \
    "Screen|screen|$(test_result SCREEN_RESULT)" \
    "Touchpad|touchpad|$(test_result TOUCHPAD_RESULT)" \
    "Touchscreen|touchscreen|$(test_result TOUCHSCREEN_RESULT)" \
    "Sound|sound|$(test_result SOUND_RESULT)" \
    "USB ports|usb|$(test_result USB_RESULT)" "Camera|camera|$(test_result CAMERA_RESULT)" \
    "Ethernet Network|network|$(test_result ETHERNET_RESULT)" "Wi-Fi|wifi" \
    "Wireless test|wifi|$(test_result WIFI_RESULT)" "System|info" \
    "Machine details|pencil" "DMI capture|chip" "Get firmware|download" \
    "Results|list" "Save report|save" "Command prompt|terminal" "Settings|gear" \
    || { set_layout compact; return 0; }
  run_test "${acts[$((TUI_CHOICE-1))]}"
  return 0
}

while :; do
  if [ "$(layout)" = all ]; then
    expanded_menu
  else
    compact_menu || power_menu
  fi
done
