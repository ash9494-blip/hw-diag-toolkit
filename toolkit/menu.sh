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
  # The settings kept on the boot stick, before the renderer starts: it reads
  # them once, at start-up. Copied in after it (as up to 1.20.0), the theme
  # only came back if something restarted the renderer.
  if restore_settings; then
    v=$(setting_get layout "")
    [ -n "$v" ] && printf '%s\n' "$v" > "$RUN_DIR/layout"
  fi
  NEW_BOOT=1
fi

daemon_alive || /opt/diag/start-ui.sh || set_console_font

. /opt/diag/tui.sh

# The language, once per boot, before anything else (Ash, 1.22: "after grub
# selection but before the toolkit launch"). The renderer already has the kept
# settings, so it opens on the language used last time. Not on the text
# console: that has no CJK font and stays English.
[ -n "$NEW_BOOT" ] && [ -n "$TUI_GUI" ] && /opt/diag/settings.sh --boot-language

if [ ! -f "$RUN_DIR/.seeded" ]; then
  /opt/diag/sysinfo.sh --quiet
  # Firmware-load failures and driver errors are printed once, while the
  # drivers bind at boot. The ring buffer rolls over on a chatty machine and a
  # long test can push them out, so the whole boot log is kept here the moment
  # the toolkit starts. Driver check reads this as well as the live log.
  dmesg > "$RUN_DIR/boot-dmesg.log" 2>/dev/null
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
    "1.  System info, drivers, GPU, battery, SMART   about 1 min" \
    "2.  $diskline" \
    "3.  CPU stress and temperature log              about 10 min" \
    "4.  RAM stress test                             about 5 min" \
    "5.  Hardware error log - what the tests shook out" \
    "6.  Save the report" \
    "" \
    "Nothing is written to the tested drive. Each stage stops with Q." \
    "" "Start now?" || return

  /opt/diag/sysinfo.sh --quiet
  /opt/diag/drivercheck.sh --quiet
  /opt/diag/gputest.sh --quiet

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
  # Last: what the stress tests shook loose into the kernel log.
  /opt/diag/errlog.sh --quiet

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
# "Show all tests" tile switches to every test, and Q there comes back.
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

# A peripheral test that fails, or finds no device at all, gets Driver check
# for its kind of device straight away (Ash, 1.22: "auto search online for
# missing driver"): what is not working is fixed, a missing firmware file is
# fetched, and the test is offered again. Types are drivers.sh's.
driver_key() {   # test -> its result key; 1 for tests no driver can explain
  case "$1" in
    touchpad) echo TOUCHPAD_RESULT ;;   touchscreen) echo TOUCHSCREEN_RESULT ;;
    sound)    echo SOUND_RESULT ;;      camera)      echo CAMERA_RESULT ;;
    sdcard)   echo SD_RESULT ;;         wireless)    echo WIFI_RESULT ;;
    network)  echo ETHERNET_RESULT ;;   usb)         echo USB_RESULT ;;
    *) return 1 ;;
  esac
}

driver_followup() {   # test result-key verdicts-before
  local v failed=0 what types
  # only a verdict this run wrote - one left from earlier is not news
  [ "$(grep -c "^$2=" "$SUMMARY_KV" 2>/dev/null)" -gt "$3" ] || return 0
  v=$(grep "^$2=" "$SUMMARY_KV" | tail -1 | cut -d= -f2-)
  case "$v" in
    FAIL*) failed=1 ;;
    # no device: maybe a driver that never started - but a laptop without a
    # touchscreen is the usual reason, so this one is checked quietly
    "NOT TESTED (no "*|*"not found"*|*"no driver"*) ;;
    *) return 0 ;;
  esac
  case "$1" in
    touchpad)    what=Touchpad;    types="Touch (I2C)|Keyboard / mouse|Serial bus" ;;
    touchscreen) what=Touchscreen; types="Touch (I2C)|Keyboard / mouse|Serial bus" ;;
    sound)       what=Sound;       types="Sound|Multimedia" ;;
    camera)      what=Camera;      types="Camera|Multimedia" ;;
    sdcard)      what="SD card";   types="Storage|System|Other|USB device" ;;
    wireless)    what=Wi-Fi;       types="Wi-Fi|Network" ;;
    network)     what=Ethernet;    types="Ethernet|Network" ;;
    usb)         what="USB ports"; types="USB controller" ;;
  esac
  /opt/diag/drivercheck.sh --for "$what" "$types" "$failed" || return 0
  tui_confirm "Run the test again?" yes "A driver for it was fixed just now." "" \
    "Run the test again to see whether it works?" && run_test "$1"
  return 0
}

run_test() {   # one dispatcher, so both layouts stay in step
  local rkey n0=0
  rkey=$(driver_key "$1") && n0=$(grep -c "^$rkey=" "$SUMMARY_KV" 2>/dev/null)
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
    charging) /opt/diag/chargetest.sh ;;
    camera)   /opt/diag/cameratest.sh ;;
    sdcard)   /opt/diag/sdtest.sh ;;
    lid)      /opt/diag/lidtest.sh ;;
    gpu)      /opt/diag/gputest.sh ;;
    fan)      /opt/diag/fantest.sh ;;
    errlog)   /opt/diag/errlog.sh ;;
    network)  /opt/diag/nettest.sh ;;
    system)   /opt/diag/sysinfo.sh ;;
    dmi)      /opt/diag/dmicapture.sh ;;
    imaging)  /opt/diag/imaging.sh ;;
    drivers)  /opt/diag/drivercheck.sh ;;
    results)  view_report ;;
    save)     /opt/diag/savereport.sh ;;
  esac
  [ -n "$rkey" ] && driver_followup "$1" "$rkey" "${n0:-0}"
  return 0
}

# New tiles go at the end: the numbers already in Ash's hands stay put.
peripherals_menu() {
  local acts=(all screen touchpad touchscreen sound usb charging camera network wireless drivers sdcard lid fan)
  while :; do
    tui_grid "Peripherals" "arrows to move, Enter to select      Q = back" \
      "Run them all|grid" \
      "Screen|screen|$(test_result SCREEN_RESULT)" \
      "Touchpad|touchpad|$(test_result TOUCHPAD_RESULT)" \
      "Touchscreen|touchscreen|$(test_result TOUCHSCREEN_RESULT)" \
      "Sound|sound|$(test_result SOUND_RESULT)" \
      "USB ports|usb|$(test_result USB_RESULT)" \
      "Charging|charge|$(test_result CHARGE_RESULT)" \
      "Camera|camera|$(test_result CAMERA_RESULT)" \
      "Ethernet Network|network|$(test_result ETHERNET_RESULT)" \
      "Wireless test|wifi|$(test_result WIFI_RESULT)" \
      "Driver check|download|$(test_result DRIVER_RESULT)" \
      "SD card|sdcard|$(test_result SD_RESULT)" \
      "Lid sensor|lid|$(test_result LID_RESULT)" \
      "Fan|fan|$(test_result FAN_RESULT)" || return
    if [ "${acts[$((TUI_CHOICE-1))]}" = all ]; then
      local t
      for t in screen touchpad touchscreen sound usb charging camera network wireless sdcard lid fan; do run_test "$t"; done
    else
      run_test "${acts[$((TUI_CHOICE-1))]}"
    fi
  done
}

compact_menu() {
  # GPU beside CPU and RAM as tile 5 (Ash, 1.24); Disk imaging beside Keyboard
  # (1.22) - it was last, 18
  local acts=(fullrun disk cpu ram gpu battery keyboard imaging peripherals showall wificonnect drivers dmi results save shell system settings errlog)
  tui_grid "Choose a test" "arrows or its number (two digits for 10+), Enter to select      Q = power menu" \
    "Full run|play" \
    "HDD / SSD|disk|$(test_result DISK_RESULT DISK_CTRL DISK_SELFTEST DISK_SMART)" \
    "CPU|cpu|$(test_result CPU_RESULT)" \
    "RAM|ram|$(test_result RAM_RESULT)" \
    "GPU|gpu|$(test_result GPU_RESULT)" \
    "Battery|battery|$(test_result BATTERY_RESULT)" \
    "Keyboard|keyboard|$(test_result KEYBOARD_RESULT)" \
    "Disk imaging|clone|$(test_result IMAGING_RESULT)" \
    "Peripherals|grid" "Show all tests|expand" "Wi-Fi|wifi" \
    "Driver check|download|$(test_result DRIVER_RESULT)" "DMI capture|chip" "Results|list" "Save report|save" "Command prompt|terminal" \
    "System|info" "Settings|gear" "Error log|log|$(test_result ERRLOG_RESULT)" || return 1
  case "${acts[$((TUI_CHOICE-1))]}" in
    peripherals) peripherals_menu ;;
    showall)     set_layout all ;;
    *)           run_test "${acts[$((TUI_CHOICE-1))]}" ;;
  esac
  return 0
}

expanded_menu() {
  local acts=(fullrun disk cpu ram gpu battery keyboard imaging screen touchpad touchscreen sound usb charging camera sdcard lid fan network wificonnect wireless drivers errlog dmi results save shell system settings)
  tui_grid "Every test" "arrows or its number, Enter to select      Q = back to the short list" \
    "Full run|play" \
    "HDD / SSD|disk|$(test_result DISK_RESULT DISK_CTRL DISK_SELFTEST DISK_SMART)" \
    "CPU|cpu|$(test_result CPU_RESULT)" "RAM|ram|$(test_result RAM_RESULT)" \
    "GPU|gpu|$(test_result GPU_RESULT)" \
    "Battery|battery|$(test_result BATTERY_RESULT)" \
    "Keyboard|keyboard|$(test_result KEYBOARD_RESULT)" \
    "Disk imaging|clone|$(test_result IMAGING_RESULT)" \
    "Screen|screen|$(test_result SCREEN_RESULT)" \
    "Touchpad|touchpad|$(test_result TOUCHPAD_RESULT)" \
    "Touchscreen|touchscreen|$(test_result TOUCHSCREEN_RESULT)" \
    "Sound|sound|$(test_result SOUND_RESULT)" \
    "USB ports|usb|$(test_result USB_RESULT)" "Charging|charge|$(test_result CHARGE_RESULT)" \
    "Camera|camera|$(test_result CAMERA_RESULT)" \
    "SD card|sdcard|$(test_result SD_RESULT)" "Lid sensor|lid|$(test_result LID_RESULT)" \
    "Fan|fan|$(test_result FAN_RESULT)" \
    "Ethernet Network|network|$(test_result ETHERNET_RESULT)" "Wi-Fi|wifi" \
    "Wireless test|wifi|$(test_result WIFI_RESULT)" \
    "Driver check|download|$(test_result DRIVER_RESULT)" \
    "Error log|log|$(test_result ERRLOG_RESULT)" "DMI capture|chip" \
    "Results|list" "Save report|save" "Command prompt|terminal" \
    "System|info" "Settings|gear" \
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
