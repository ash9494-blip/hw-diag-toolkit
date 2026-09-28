#!/bin/bash
# Fetch firmware blobs the drivers asked for and did not get.
#
# The kernel modules are all on the image, but the firmware files are not:
# linux-firmware is 651 MB, most of it for hardware no laptop has. Instead the
# kernel tells us exactly what it wanted - every failed request appears in the
# kernel log - so only those files are fetched, and they are cached on the USB
# stick so the same model never has to download twice.
#
# Nothing here touches the machine being tested. Files land in the live system's
# RAM overlay and in a cache folder on the stick.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

FW_DIR=/usr/lib/firmware
MIRROR=${DIAG_FW_MIRROR:-http://archive.ubuntu.com/ubuntu}

# Which Ubuntu package carries a given firmware path. Fetching the one package
# that covers the request beats pulling all 651 MB.
fw_package() {
  case "$1" in
    intel/ibt-*|intel/ice/*|intel/irci*|intel/ipu*) echo linux-firmware-intel-misc ;;
    iwlwifi-*|intel/iwlwifi*)                       echo linux-firmware-intel-wireless ;;
    intel/sof*|intel/avs*)                          echo firmware-sof-signed ;;
    rtl_nic/*|rtlwifi/*|rtw88/*|rtw89/*|rtl_bt/*)   echo linux-firmware-realtek ;;
    amdgpu/*|amd/*|amd_sev*)                        echo linux-firmware-amd-graphics ;;
    ath10k/*|ath11k/*|ath12k/*|ath9k*|qca/*)        echo linux-firmware-qualcomm-wireless ;;
    brcm/*|cypress/*)                               echo linux-firmware-broadcom-wireless ;;
    mediatek/*|mt76*)                               echo linux-firmware-mediatek ;;
    i915/*)                                         echo linux-firmware-intel-graphics ;;
    nvidia/*)                                       echo linux-firmware-nvidia-graphics ;;
    *)                                              echo linux-firmware-misc ;;
  esac
}

# Hardware the kernel can see but is not driving.
#
# A missing firmware blob is only half the story. The other half is a device
# sitting on the bus with no driver bound to it at all - which is what you get
# when the module is absent rather than the firmware, and it is the case a
# firmware-only scan silently misses. lspci marks those, so they are collected
# here and reported alongside, which is what makes this behave like Windows
# Update rather than a one-trick fetcher.
unclaimed_devices() {
  lspci -nnk 2>/dev/null | awk '
    /^[0-9a-f]{2}:/ { dev=$0; drv=""; next }
    /Kernel driver in use:/ { drv=$0 }
    /^$/ { if (dev != "" && drv == "") print dev; dev=""; drv="" }
    END  { if (dev != "" && drv == "") print dev }'
}

# Map an unclaimed device to the package that would drive it, where we can
# name one. Class codes are more reliable than model strings here.
device_package() {
  case "$1" in
    *"Network controller"*|*"802.11"*)   echo linux-firmware-intel-wireless ;;
    *"Ethernet controller"*)             echo linux-firmware-realtek ;;
    *"Multimedia audio"*|*"Audio device"*) echo firmware-sof-signed ;;
    *"Bluetooth"*)                       echo linux-firmware-intel-misc ;;
    *)                                   echo "" ;;
  esac
}

# Every firmware file a driver asked for and did not receive.
missing_firmware() {
  # Both the live log and the copy taken at boot: whichever still has the
  # lines, they are found. Duplicates are removed by the sort below.
  { cat "$RUN_DIR/boot-firmware.log" 2>/dev/null; dmesg 2>/dev/null; } \
    | grep -oE "[Dd]irect firmware load for [^ ]+ failed|firmware: failed to load [^ ]+" \
    | sed -E 's/.*(load for|load) //; s/ failed//' \
    | sort -u \
    | while IFS= read -r f; do
        [ -n "$f" ] || continue
        # Ubuntu ships firmware zstd-compressed and the kernel decompresses on
        # load, so the file on disk may carry a suffix the request did not.
        [ -e "$FW_DIR/$f" ] || [ -e "$FW_DIR/$f.zst" ] || [ -e "$FW_DIR/$f.xz" ] \
          || printf '%s\n' "$f"
      done
}

net_up() {
  local i w c
  for i in /sys/class/net/*; do
    w=${i##*/}
    case "$w" in lo) continue ;; esac
    c=$(cat "$i/carrier" 2>/dev/null)
    [ "$c" = 1 ] && { printf '%s\n' "$w"; return 0; }
  done
  return 1
}

have_route() { ip route show default 2>/dev/null | grep -q .; }

fetch() {   # url  destination-file
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import sys, urllib.request, shutil
try:
    with urllib.request.urlopen(sys.argv[1], timeout=60) as r, open(sys.argv[2], "wb") as f:
        shutil.copyfileobj(r, f)
except Exception as e:
    sys.stderr.write(str(e)); sys.exit(1)
PY
}

# Let apt do the lookup.
#
# Scraping the archive pool was the obvious approach and it is wrong: the pool
# holds every version from every Ubuntu release side by side, so "newest file"
# can easily be firmware built for a kernel years away from this one. apt reads
# the noble index and picks the version that actually belongs with this kernel.
#
# A trimmed sources list is used so the update only pulls main/amd64 - a couple
# of megabytes - instead of every component.
FW_SOURCES=$RUN_DIR/fw-sources.list
APT_OPTS=(-o "Dir::Etc::sourcelist=$FW_SOURCES"
          -o "Dir::Etc::sourceparts=/dev/null"
          -o "APT::Get::List-Cleanup=0"
          -o "Acquire::Languages=none")

apt_ready() {
  cat > "$FW_SOURCES" <<'EOF'
deb [arch=amd64] http://archive.ubuntu.com/ubuntu/ noble main
deb [arch=amd64] http://archive.ubuntu.com/ubuntu/ noble-updates main
EOF
  apt-get "${APT_OPTS[@]}" update >"$RUN_DIR/apt.log" 2>&1
}

# Downloads the correct version for this release into $RUN_DIR; echoes the file.
download_pkg() {   # package-name
  local pkg=$1 out
  ( cd "$RUN_DIR" && apt-get "${APT_OPTS[@]}" download "$pkg" ) >>"$RUN_DIR/apt.log" 2>&1 || return 1
  out=$(ls -1t "$RUN_DIR"/${pkg}_*.deb 2>/dev/null | head -1)
  [ -n "$out" ] && printf '%s\n' "$out"
}

install_deb() {   # local .deb -> extracts firmware into FW_DIR
  local deb=$1 tmp=$RUN_DIR/fwx
  rm -rf "$tmp"; mkdir -p "$tmp" || return 1
  # .deb is an ar archive; pull data.tar.* out of it without needing binutils
  # The member is data.tar, data.tar.zst, data.tar.xz or data.tar.gz depending
  # on the package - linux-firmware-realtek ships it uncompressed.
  python3 - "$deb" "$tmp" <<'PY' || return 1
import os, sys
d = open(sys.argv[1], "rb").read()
if not d.startswith(b"!<arch>\n"):
    sys.exit(1)
i = 8
while i < len(d):
    name = d[i:i+16].decode("ascii", "replace").strip().rstrip("/")
    size = int(d[i+48:i+58].decode("ascii").strip())
    body = d[i+60:i+60+size]
    if name.startswith("data.tar"):
        open(os.path.join(sys.argv[2], name), "wb").write(body)
        open(os.path.join(sys.argv[2], "member"), "w").write(name)
        sys.exit(0)
    i += 60 + size + (size % 2)
sys.exit(1)
PY
  local member; member=$(cat "$tmp/member" 2>/dev/null)
  case "$member" in
    data.tar.zst) zstd -dc "$tmp/$member" | tar -x -C "$tmp" ;;
    data.tar.xz)  tar -xJf "$tmp/$member" -C "$tmp" ;;
    data.tar.gz)  tar -xzf "$tmp/$member" -C "$tmp" ;;
    data.tar)     tar -xf  "$tmp/$member" -C "$tmp" ;;
    *)            return 1 ;;
  esac
  # packages use /lib/firmware or /usr/lib/firmware depending on age
  local srcdir=""
  [ -d "$tmp/usr/lib/firmware" ] && srcdir=$tmp/usr/lib/firmware
  [ -z "$srcdir" ] && [ -d "$tmp/lib/firmware" ] && srcdir=$tmp/lib/firmware
  [ -n "$srcdir" ] || return 1
  mkdir -p "$FW_DIR"
  cp -a "$srcdir"/. "$FW_DIR"/ 2>/dev/null
  rm -rf "$tmp"
  return 0
}

# ---------------------------------------------------------------- run
tui_frame "Get firmware" "please wait"
tui_line 6 "Checking what the drivers asked for..." muted
tui_flush

mapfile -t MISSING < <(missing_firmware)
if [ "${#MISSING[@]}" -eq 0 ]; then
  tui_frame "Get firmware" "Enter to go back"
  tui_badge 6 OK "nothing is missing"
  tui_line 9  "No driver on this machine has asked for firmware it did not get." ""
  tui_line 10 "If something still does not work, it is not a missing blob." muted
  mapfile -t UNCLAIMED < <(unclaimed_devices)
  if [ "${#UNCLAIMED[@]}" -gt 0 ]; then
    tui_line 12 "${#UNCLAIMED[@]} device(s) have no driver bound, which may still" warn
    tui_line 13 "mean something is unusable. Listed in the report." muted
    rsection "DRIVER CHECK"
    rsilent "Devices the kernel sees but is not driving:"
    for d in "${UNCLAIMED[@]}"; do rsilent "  $d"; done
  fi
  tui_flush; tui_anykey
  exit 0
fi

mapfile -t UNCLAIMED < <(unclaimed_devices)
mapfile -t PKGS < <({
  for f in "${MISSING[@]}"; do fw_package "$f"; done
  for dvc in "${UNCLAIMED[@]}"; do device_package "$dvc"; done
} | grep -v '^$' | sort -u)

tui_frame "Get firmware" "Enter to continue, Q to go back"
row=6
tui_line $row "${#MISSING[@]} firmware file(s) were asked for and not found:" ""; row=$((row+2))
for f in "${MISSING[@]}"; do
  [ $row -gt 16 ] && { tui_line $row "  ..." muted; row=$((row+1)); break; }
  tui_line $row "  $f" warn; row=$((row+1))
done
row=$((row+1))
tui_line $row "This needs a network cable. ${#PKGS[@]} package(s) will be downloaded" ""; row=$((row+1))
tui_line $row "and cached on the USB stick so this model never repeats it." muted
tui_flush
tui_anykey

# --- network ---
# Wireless counts. The Wi-Fi page on the main menu brings a link up once for the
# whole session, so if one is already routing there is nothing to do here; only
# fall back to hunting for a cable when there is not.
if ip route 2>/dev/null | grep -q '^default'; then
  IFACE=$(ip route 2>/dev/null | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
else
  IFACE=$(net_up)
fi
if [ -z "$IFACE" ]; then
  tui_frame "Get firmware" "Enter to go back"
  tui_badge 6 UNKNOWN "no network"
  tui_line 9  "This needs to reach the Ubuntu archive to fetch anything." ""
  tui_line 11 "Either plug in a network cable, or go back to the main menu" ""
  tui_line 12 "and use Wi-Fi to connect - then come back here." ""
  tui_line 14 "A USB ethernet adapter works too if this machine has no port." muted
  tui_flush; tui_anykey
  exit 0
fi
if ! have_route; then
  tui_frame "Get firmware" "please wait"
  tui_line 6 "Asking for an address on $IFACE..." muted
  tui_flush
  timeout 25 dhclient -1 "$IFACE" >/dev/null 2>&1
fi
if ! have_route; then
  tui_msg "No address" "DHCP did not give this machine an address on $IFACE." "" \
    "Check the cable and that the socket is live."
  exit 0
fi

# --- cache on the stick, if one is mounted ---
CACHE=""
STORAGE_PROMPT="Where should downloads be cached?  (Q to skip caching)"
if pick_storage && mount_storage; then
  CACHE="$STORAGE_MNT/DiagFirmware"
  mkdir -p "$CACHE" 2>/dev/null || CACHE=""
fi

tui_frame "Get firmware" "reading the package index"
tui_line 6 "Asking the Ubuntu archive what belongs with this kernel..." muted
tui_flush
if ! apt_ready; then
  [ -n "$CACHE" ] && umount_storage
  tui_msg "Could not reach the archive" \
    "$(tail -2 "$RUN_DIR/apt.log" 2>/dev/null | head -1)" "" \
    "Check that this network allows archive.ubuntu.com."
  exit 0
fi

GOT=0; FAILED=0
for pkg in "${PKGS[@]}"; do
  tui_frame "Get firmware" "downloading"
  tui_line 6 "Package: $pkg" ""
  tui_flush

  deb=""
  if [ -n "$CACHE" ]; then
    deb=$(ls -1 "$CACHE"/${pkg}_*.deb 2>/dev/null | sort -V | tail -1)
  fi
  if [ -n "$deb" ] && [ -s "$deb" ]; then
    tui_line 8 "Already cached on the stick." ok; tui_flush
  else
    tui_line 8 "Downloading..." muted; tui_flush
    deb=$(download_pkg "$pkg")
    if [ -z "$deb" ]; then FAILED=$((FAILED+1)); continue; fi
    [ -n "$CACHE" ] && cp "$deb" "$CACHE/" 2>/dev/null
  fi

  tui_line 10 "Unpacking $(basename "$deb")" muted; tui_flush
  if install_deb "$deb"; then GOT=$((GOT+1)); else FAILED=$((FAILED+1)); fi
done

[ -n "$CACHE" ] && { sync; umount_storage; }

# Ask the drivers to try again now the files are there.
if [ "$GOT" -gt 0 ]; then
  tui_frame "Get firmware" "reloading drivers"
  tui_line 6 "Asking the drivers to look again..." muted
  tui_flush
  for m in snd_sof_pci_intel_tgl snd_hda_intel uvcvideo r8169 e1000e; do
    modprobe -r "$m" 2>/dev/null; modprobe "$m" 2>/dev/null
  done
  sleep 2
fi

STILL=$(missing_firmware | grep -c . )

rsection "FIRMWARE DOWNLOAD"
rsilent "Requested by drivers : ${#MISSING[@]}"
rsilent "Packages fetched     : $GOT"
rsilent "Packages failed      : $FAILED"
rsilent "Still missing        : $STILL"
for f in "${MISSING[@]}"; do rsilent "  asked for: $f"; done
rsilent "RESULT: $GOT package(s) installed, $STILL file(s) still missing"
set_kv FIRMWARE_FETCH "$GOT fetched, $STILL still missing"

tui_frame "Firmware" "Enter to go back"
if [ "$GOT" -gt 0 ] && [ "$STILL" -eq 0 ]; then
  tui_badge 6 PASS "everything the drivers asked for is now present"
elif [ "$GOT" -gt 0 ]; then
  tui_badge 6 PARTIAL "some files arrived, some did not"
else
  tui_badge 6 FAIL "nothing could be downloaded"
fi
tui_kv 9  "Packages fetched" "$GOT"
tui_kv 10 "Still missing"    "$STILL" "$([ "$STILL" -eq 0 ] && echo ok || echo warn)"
row=12
if [ "$GOT" -gt 0 ]; then
  tui_line $row "Run the sound or camera test again - the driver has been reloaded." ""; row=$((row+1))
  [ -n "$CACHE" ] && tui_line $row "Cached on the stick in DiagFirmware, so the next one is instant." muted
else
  tui_line $row "Check the cable, or that this network allows archive.ubuntu.com." muted
fi
tui_flush
tui_anykey
