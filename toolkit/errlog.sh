#!/bin/bash
# Hardware error log: what the kernel has logged since this boot that points
# at a fault no other test looks for.
#
# Some faults never fail a test while it runs - they leave a line in the
# kernel log instead: a USB socket drawing too much current, a SATA link
# that resets, an NVMe drive that stops answering for a moment, PCIe
# retries, the processor's own machine-check errors, a Wi-Fi card whose
# firmware crashed. This reads that log (read only - never cleared, see
# CLAUDE.md "Never dmesg -C") and names each kind of fault with what to do.
#
# The log covers this session, so it says most after the other tests have
# run: Full run calls it last (errlog.sh --quiet).
#
# Each rule is a regular expression over the dmesg text with the timestamps
# removed. What a healthy machine logs at every boot (an empty SATA port's
# "link down", ACPI firmware warnings) is deliberately not matched.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

R_ID=(); R_SEV=(); R_LABEL=(); R_RE=(); R_CAUSE=(); R_ACTION=()
rule() { R_ID+=("$1"); R_SEV+=("$2"); R_LABEL+=("$3"); R_RE+=("$4"); R_CAUSE+=("$5"); R_ACTION+=("$6"); }

rule usb_oc err "USB over-current" \
  'over-current (condition|change)' \
  "a USB socket drew too much current" \
  "A shorted socket or device. Look into the socket for bent or touching pins and debris, and test with nothing plugged in; if it still happens, the socket or its fuse on the board."
rule usb_enum warn "USB device would not start" \
  'device descriptor read/(64|8), error|device not accepting address|unable to enumerate USB device|Maybe the USB cable is bad' \
  "a USB device failed to start" \
  "A worn socket, a bad cable or a dying device. The USB test shows which socket; try a different device in it. For an internal device (camera, Bluetooth) reseat its cable."
rule sata err "SATA link errors" \
  'ata[0-9]+(\.[0-9]+)?: (exception Emask|failed command|SError|hard resetting link|COMRESET failed|link is slow to respond)|BadCRC|ICRC ' \
  "the SATA drive's connection reset or garbled data" \
  "Reseat the drive. On models with a flex cable between the board and the drive bay, replace the cable - the commonest cause. If it persists with a new cable, the drive."
rule nvme err "NVMe drive resets" \
  'nvme[0-9]+.*(timeout, aborting|timeout, reset controller|controller is down|resetting controller|Removing after probe failure|Device not ready)' \
  "the NVMe drive stopped answering and was reset" \
  "Reseat the drive and run the controller check (HDD / SSD). Repeated resets mean a failing drive or a bad M.2 slot."
rule io err "Drive read/write errors" \
  'I/O error, dev (sd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)|Buffer I/O error on dev (sd|nvme|mmcblk)|critical medium error|Medium Error' \
  "a drive returned read or write errors" \
  "Run SMART and the surface scan on that drive (HDD / SSD). If the errors are on the boot USB stick, use another stick."
rule mce err "Processor machine-check errors" \
  'mce: \[Hardware Error\]|Machine check events logged|Machine Check Exception' \
  "the processor reported internal hardware errors" \
  "The CPU, its cache, the memory controller or the RAM. Run MemTest86+ (boot menu) and the CPU stress test, and check it is not overheating. Errors with clean RAM point at the board or the CPU."
rule edac err "Memory errors" \
  'EDAC [A-Za-z0-9_]+: [0-9]+ (CE|UE)|EDAC.*(Corrected|Uncorrected) error' \
  "the memory controller reported memory errors" \
  "Reseat the RAM, then run MemTest86+ (boot menu) one module at a time."
rule pcie_unc err "PCIe errors that lost data" \
  'AER: (Uncorrected|Uncorrectable) \((Fatal|Non-Fatal)\)|PCIe Bus Error: severity=(Uncorrected|Uncorrectable)' \
  "a PCIe device's link failed in a way that lost data" \
  "Reseat the device named here (M.2 SSD, Wi-Fi card) and check its slot for damage. If it returns, the device or the slot is failing."
rule pcie_cor warn "PCIe link retries" \
  'AER: Corrected error|PCIe Bus Error: severity=Corrected' \
  "a PCIe link had to retry" \
  "A few are harmless; dozens point at a poorly seated M.2 device or a worn slot. Reseat the device named here."
rule thermal warn "Overheating" \
  'temperature above threshold|cpu clock throttled|critical temperature reached|Package temperature above threshold' \
  "the processor overheated during this session" \
  "Clean the fan and heatsink and replace the thermal paste. The CPU test shows how hot it runs under load."
rule wifi_fw warn "Wi-Fi firmware crashes" \
  'iwlwifi.*(Microcode SW error|Hardware error detected|Failed to start RT ucode)|ath1[01]k.*firmware crashed|brcmfmac.*(firmware has halted|bus is down)|rtw8[89].*failed to (download|poll)|mt7[69][0-9]+.*(Message .* timeout|firmware .*fail)' \
  "the Wi-Fi card's firmware crashed" \
  "Reseat the card. A card that keeps crashing is failing; Driver check can refresh its firmware first."
rule bt warn "Bluetooth not answering" \
  'Bluetooth: hci[0-9]+: (command 0x[0-9a-f]+ tx timeout|Reading Intel version command failed|Failed to send firmware data|Opcode 0x[0-9a-f]+ failed)' \
  "the Bluetooth adapter did not answer" \
  "On a combined Wi-Fi/Bluetooth card, reseat the card; its Bluetooth half also hangs off an internal USB lead."
rule i2c warn "Touchpad / touchscreen bus errors" \
  'i2c_hid(_acpi)? [^ ]+: (failed|error|unexpected)|i2c_designware [^ ]+: (controller timed out|timeout)' \
  "the touchpad or touchscreen controller did not answer on its bus" \
  "Reseat the touchpad or screen flex cable. Driver check shows whether the device came up."
rule mmc warn "SD card reader errors" \
  'mmc[0-9]+: (error -|Timeout waiting|Card stuck|tuning execution failed)' \
  "the SD card reader reported errors" \
  "Try another card; if every card errors, the reader or its socket."

DMESG_TXT=$RUN_DIR/errlog-dmesg.txt
HITS=$RUN_DIR/errlog-hits.txt

# PCIe error counters the kernel keeps per device even when the log is
# rate-limited: "TOTAL_ERR_COR 12" in aer_dev_correctable and friends.
aer_counts() {   # -> "cor nonfatal fatal" summed over every device
  local d c=0 n=0 f=0 v
  for d in /sys/bus/pci/devices/*; do
    v=$(awk '/^TOTAL_ERR_COR/{print $2}' "$d/aer_dev_correctable" 2>/dev/null);   c=$((c + ${v:-0}))
    v=$(awk '/^TOTAL_ERR_NONFATAL/{print $2}' "$d/aer_dev_nonfatal" 2>/dev/null); n=$((n + ${v:-0}))
    v=$(awk '/^TOTAL_ERR_FATAL/{print $2}' "$d/aer_dev_fatal" 2>/dev/null);       f=$((f + ${v:-0}))
  done
  echo "$c $n $f"
}

# The parts named in the matching lines: USB ports, ata links, PCI devices.
where_of() {   # matching lines on stdin -> "usb1-port2, 0000:02:00.0 (Samsung ...)"
  local out="" x name
  while read -r x; do
    [ -z "$x" ] && continue
    case "$x" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f]:*)
        name=$(lspci -s "$x" 2>/dev/null | sed 's/^[^ ]* //; s/^[^:]*: //' | cut -c1-40)
        out+="$x${name:+ ($name)}, " ;;
      *) out+="$x, " ;;
    esac
  done < <(grep -oE 'usb[0-9]+-port[0-9]+|ata[0-9]+(\.[0-9]+)?|nvme[0-9]+|mmc[0-9]+|hci[0-9]+|dev (sd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)|[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' \
           | sed 's/^dev //' | sort -u | head -4)
  printf '%s' "${out%, }"
}

collect() {
  # menu.sh keeps the whole boot log (boot-dmesg.log) because the ring
  # buffer rolls over on a chatty machine; it and everything logged after it.
  local boot=$RUN_DIR/boot-dmesg.log last=0
  if [ -s "$boot" ]; then
    last=$(tail -1 "$boot" | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p')
    { cat "$boot"; dmesg_since "${last:-0}"; } | sed -E 's/^\[ *[0-9.]+\] //' > "$DMESG_TXT"
  else
    dmesg 2>/dev/null | sed -E 's/^\[ *[0-9.]+\] //' > "$DMESG_TXT"
  fi
  : > "$HITS"
  FOUND=(); WORST=""
  local k n lines where cor nonf fat
  read -r cor nonf fat <<< "$(aer_counts)"
  for k in "${!R_ID[@]}"; do
    lines=$(grep -E -i -- "${R_RE[$k]}" "$DMESG_TXT")
    n=$(printf '%s' "$lines" | grep -c .)
    # the counters back the log up when it was rate-limited
    case "${R_ID[$k]}" in
      pcie_unc) [ $((nonf + fat)) -gt "$n" ] && n=$((nonf + fat)) ;;
      pcie_cor) [ "$cor" -gt "$n" ] && n=$cor
                [ "$n" -lt 10 ] && n=0 ;;     # a handful is normal
    esac
    [ "$n" -gt 0 ] || continue
    where=$(printf '%s\n' "$lines" | where_of)
    FOUND+=("$k|$n|$where")
    { printf '== %s (%s) - %d\n' "${R_LABEL[$k]}" "${R_SEV[$k]}" "$n"
      printf '%s\n' "$lines" | grep . | head -3 | cut -c1-160 | sed 's/^/   /'; } >> "$HITS"
    if [ "${R_SEV[$k]}" = err ]; then WORST=err; elif [ -z "$WORST" ]; then WORST=warn; fi
  done
}

first_label() {   # sev -> the label of the first finding of that severity
  local f k
  for f in "${FOUND[@]}"; do
    k=${f%%|*}
    [ "${R_SEV[$k]}" = "$1" ] && { printf '%s' "${R_LABEL[$k]}"; return; }
  done
}

report() {
  local f k n where
  rsection "HARDWARE ERROR LOG"
  rsilent "Kernel log since boot : $(wc -l < "$DMESG_TXT") lines, $(awk '{print int($1/60)}' /proc/uptime) min of uptime"
  rsilent "Checked for           : USB over-current and start-up failures, SATA and NVMe"
  rsilent "                        link errors, drive I/O errors, processor machine checks,"
  rsilent "                        memory errors, PCIe errors, overheating, Wi-Fi / Bluetooth"
  rsilent "                        firmware failures, touchpad bus and SD reader errors"
  if [ ${#FOUND[@]} -eq 0 ]; then
    rsilent "Found                 : nothing that points at a hardware fault"
  else
    rsilent ""
    for f in "${FOUND[@]}"; do
      IFS='|' read -r k n where <<< "$f"
      rsilent "$(printf '%-5s %s - %s time(s)%s' "$( [ "${R_SEV[$k]}" = err ] && echo FAULT || echo WARN )" \
        "${R_LABEL[$k]}" "$n" "${where:+, $where}")"
      rsilent "      Cause: ${R_CAUSE[$k]}"
      printf '%s\n' "${R_ACTION[$k]}" | fold -s -w 70 | sed 's/^/      /' >> "$REPORT_TXT"
    done
    rsilent ""
    rsilent "The kernel's own words (first lines of each):"
    sed 's/^/  /' "$HITS" >> "$REPORT_TXT"
  fi
  local ne=0 nw=0
  for f in "${FOUND[@]}"; do
    k=${f%%|*}; [ "${R_SEV[$k]}" = err ] && ne=$((ne+1)) || nw=$((nw+1))
  done
  case "$WORST" in
    err)  VERDICT="FAIL ($ne kind(s) of fault$( [ "$nw" -gt 0 ] && echo ", $nw warning(s)") in the kernel log - first: $(first_label err))" ;;
    warn) VERDICT="WARN ($nw thing(s) worth a look in the kernel log - first: $(first_label warn))" ;;
    *)    VERDICT="PASS (nothing in the kernel log points at a hardware fault)" ;;
  esac
  rsilent "RESULT: $VERDICT"
  set_kv ERRLOG_RESULT "$VERDICT"
  return 0
}

show() {
  local f k n where sev row=9 first=""
  tui_frame "Hardware error log" "Enter to go back"
  case "$WORST" in
    err)  tui_badge 6 FAIL "the kernel logged hardware faults" ;;
    warn) tui_badge 6 WARN "the kernel logged things worth a look" ;;
    *)    tui_badge 6 PASS "nothing points at a hardware fault" ;;
  esac
  if [ ${#FOUND[@]} -eq 0 ]; then
    tui_line 9  "Since this boot, the kernel logged none of: USB over-current, SATA or NVMe" ""
    tui_line 10 "link errors, drive I/O errors, processor machine checks, PCIe errors," ""
    tui_line 11 "overheating, Wi-Fi or Bluetooth firmware failures." ""
    tui_line 13 "The log covers this session: it says most after the other tests have run." muted
  else
    # faults first, then warnings - the first one is explained in full
    for sev in err warn; do
      for f in "${FOUND[@]}"; do
        IFS='|' read -r k n where <<< "$f"
        [ "${R_SEV[$k]}" = "$sev" ] || continue
        [ -z "$first" ] && first=$k
        [ $row -gt 15 ] && continue
        tui_kv $row "${R_LABEL[$k]}" "$n time(s)${where:+ - $where}" "$sev"
        row=$((row+1))
      done
    done
    row=$((row+1))
    row=$(tui_para $row "${R_LABEL[$first]}: ${R_CAUSE[$first]}." "${R_SEV[$first]}")
    row=$(tui_para $row "${R_ACTION[$first]}" "")
    [ ${#FOUND[@]} -gt 1 ] && [ "$row" -le 21 ] && \
      tui_line $row "What to do for each one, and the kernel's own lines, are in the report." muted
  fi
  tui_flush
  tui_anykey
}

collect
report
[ "$1" = --quiet ] || show
exit 0
