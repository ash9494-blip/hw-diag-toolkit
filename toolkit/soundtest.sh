#!/bin/bash
# Sound test: speakers, then the microphone.
#
# A speaker fault is almost always one-sided, so the tone is played to one
# channel at a time and the operator says which side they heard. That catches a
# dead speaker AND a swapped channel, which a both-channels test cannot.
#
# The microphone is checked by recording and playing back, then by measuring the
# recorded level: silence means the mic is dead even if the operator is unsure.
. /opt/diag/lib.sh
. /opt/diag/tui.sh

TONE_SECS=2
REC_SECS=4
REC_WAV=$RUN_DIR/mictest.wav

have() { command -v "$1" >/dev/null 2>&1; }

load_sound_modules() {
  modprobe snd_hda_intel 2>/dev/null
  modprobe snd_sof_pci_intel_tgl 2>/dev/null
  modprobe snd_soc_skl 2>/dev/null
  modprobe snd_usb_audio 2>/dev/null
  # give the cards a moment to register
  local i
  for i in 1 2 3 4 5 6; do
    [ -e /proc/asound/cards ] && grep -q '^ *[0-9]' /proc/asound/cards 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

card_list() {
  [ -r /proc/asound/cards ] || return
  awk '/^ *[0-9]+ \[/ {
         id=$0; sub(/^ *[0-9]+ \[/, "", id); sub(/\].*/, "", id); gsub(/ +$/, "", id);
         name=$0; sub(/^[^:]*: */, "", name); gsub(/ +$/, "", name);
         getline detail; gsub(/^ +/, "", detail);
         printf "%s|%s  (%s)\n", id, name, detail
       }' /proc/asound/cards
}

unmute_all() {
  have amixer || return
  local c d
  for c in $(awk '/^ *[0-9]+ \[/{print $1}' /proc/asound/cards 2>/dev/null); do
    # The DSP cards on 11th-gen and newer laptops (SOF) start with their
    # speaker and headphone paths off; the card's use-case profile is what
    # routes them. Cards without a profile just ignore this.
    if have alsaucm; then
      alsaucm -c "hw:$c" set _verb HiFi >/dev/null 2>&1
      for d in Speaker Headphones; do
        alsaucm -c "hw:$c" set _verb HiFi set _enadev "$d" >/dev/null 2>&1
      done
    fi
    amixer -c "$c" scontrols 2>/dev/null | sed 's/^.*'"'"'\(.*\)'"'"'.*$/\1/' | while read -r ctl; do
      case "$ctl" in
        Master|Speaker|Headphone|PCM|Front|Capture|Mic|"Internal Mic"|Digital)
          amixer -c "$c" sset "$ctl" 85% unmute 2>/dev/null >/dev/null
          amixer -c "$c" sset "$ctl" cap 2>/dev/null >/dev/null ;;
      esac
    done
  done
}

# Generates a WAV of a sine tone in one channel. Done here rather than with
# speaker-test so the tone is identical every time and the same file can be
# reused for the level check.
make_tone() {   # file  channel(left|right|both)  freq
  python3 - "$1" "$2" "$3" "$TONE_SECS" <<'PY'
import math, struct, sys, wave
path, chan, freq, secs = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
rate = 48000
n = int(rate * secs)
w = wave.open(path, "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
frames = bytearray()
for i in range(n):
    # 20 ms fade in and out, so the speaker is not asked to step instantly
    env = min(1.0, i / (rate * 0.02), (n - i) / (rate * 0.02))
    v = int(22000 * env * math.sin(2 * math.pi * freq * i / rate))
    l = v if chan in ("left", "both") else 0
    r = v if chan in ("right", "both") else 0
    frames += struct.pack("<hh", l, r)
w.writeframes(bytes(frames)); w.close()
PY
}

play() { aplay -q "$1" >/dev/null 2>&1; }

# Peak and RMS of a recording, as a percentage of full scale.
wav_level() {
  python3 - "$1" <<'PY'
import sys, wave, struct, math
try:
    w = wave.open(sys.argv[1], "rb")
    n = w.getnframes(); ch = w.getnchannels()
    data = w.readframes(n)
    w.close()
    if not data:
        print("0 0"); raise SystemExit
    cnt = len(data) // 2
    vals = struct.unpack("<%dh" % cnt, data[:cnt * 2])
    peak = max(abs(v) for v in vals)
    rms = math.sqrt(sum(float(v) * v for v in vals) / len(vals))
    print("%d %d" % (peak * 100 // 32767, int(rms) * 100 // 32767))
except Exception:
    print("0 0")
PY
}

# ---------------------------------------------------------------- run
tui_frame "Sound test" "please wait"
tui_line 6 "Looking for sound hardware..." muted
tui_flush

if ! load_sound_modules; then
  rsection "SOUND TEST"
  rsilent "RESULT: NOT TESTED -- no sound card was found"
  set_kv SOUND_RESULT "NOT TESTED (no sound card)"
  tui_frame "Sound test" "Enter to go back"
  tui_badge 6 UNKNOWN "no sound card found"
  tui_line 9  "The kernel did not register an audio device on this machine."
  tui_line 10 "On a laptop that usually means the codec is not responding." muted
  tui_line 12 "Driver check (home screen) shows which driver took the sound" ""
  tui_line 13 "controller, what it complained about, and fetches missing firmware." muted
  tui_flush; tui_anykey
  exit 0
fi

CARDS=$(card_list)
NCARDS=$(printf '%s\n' "$CARDS" | grep -c . )
unmute_all

if ! have aplay; then
  tui_msg "Sound test" "alsa-utils is missing from this image, so nothing can be played."
  exit 0
fi

tui_frame "Sound test - speakers" "listen, then answer"
row=6
tui_line $row "Sound card:" muted; row=$((row+1))
while IFS='|' read -r id desc; do
  [ -z "$id" ] && continue
  tui_line $row "  $desc" ""; row=$((row+1))
done <<< "$CARDS"
row=$((row+1))
tui_line $row "Turn the volume up. A tone will play on ONE side at a time." ""
tui_flush
sleep 1

make_tone "$RUN_DIR/tone_l.wav" left  440
make_tone "$RUN_DIR/tone_r.wav" right 660

tui_frame "Sound test - speakers" "playing the LEFT channel"
tui_line 6 "Playing a tone on the LEFT speaker now." ""
tui_line 8 "Listen to which side it comes from." muted
tui_flush
play "$RUN_DIR/tone_l.wav"
sleep 0.4

LEFT_ANS=left
tui_menu "Where did the first tone come from?" "answer honestly - this is the whole test" \
  "Left|correct" \
  "Right|the channels are swapped" \
  "Both sides|the balance is wrong or one speaker is bleeding" \
  "Nothing at all|no sound on that side" \
  && case "$TUI_CHOICE" in 1) LEFT_ANS=left ;; 2) LEFT_ANS=right ;; 3) LEFT_ANS=both ;; 4) LEFT_ANS=none ;; esac

tui_frame "Sound test - speakers" "playing the RIGHT channel"
tui_line 6 "Playing a different tone on the RIGHT speaker now." ""
tui_flush
play "$RUN_DIR/tone_r.wav"
sleep 0.4

RIGHT_ANS=right
tui_menu "Where did the second tone come from?" "" \
  "Right|correct" \
  "Left|the channels are swapped" \
  "Both sides|the balance is wrong or one speaker is bleeding" \
  "Nothing at all|no sound on that side" \
  && case "$TUI_CHOICE" in 1) RIGHT_ANS=right ;; 2) RIGHT_ANS=left ;; 3) RIGHT_ANS=both ;; 4) RIGHT_ANS=none ;; esac

SPK_STATE=PASS; SPK_NOTE="both speakers respond and the channels are the right way round"
if [ "$LEFT_ANS" = none ] && [ "$RIGHT_ANS" = none ]; then
  SPK_STATE=FAIL; SPK_NOTE="no sound came out at all"
elif [ "$LEFT_ANS" = none ]; then
  SPK_STATE=FAIL; SPK_NOTE="the left speaker is silent"
elif [ "$RIGHT_ANS" = none ]; then
  SPK_STATE=FAIL; SPK_NOTE="the right speaker is silent"
elif [ "$LEFT_ANS" = right ] && [ "$RIGHT_ANS" = left ]; then
  SPK_STATE=FAIL; SPK_NOTE="the channels are wired the wrong way round"
elif [ "$LEFT_ANS" = both ] || [ "$RIGHT_ANS" = both ]; then
  SPK_STATE=WARN; SPK_NOTE="a tone meant for one side came out of both"
fi

# ---------------------------------------------------------------- headphone jack
# The jack is its own part: the socket wears, and its plug-detect switch
# sticks - sound then stays on the speakers with headphones in, or the
# speakers stay silent after they come out. The switch is read like the
# lid's (swstate.py), or from the codec's "Headphone Jack" control; a codec
# that reports neither still gets the listening test.
HP_STATE=SKIP; HP_NOTE="not tested"; HP_DET=""; HP_IN=""; HP_OUT=""; HP_L=""; HP_R=""

hp_state() {   # -> in | out | "" (nothing reports the jack)
  local v c
  v=$(python3 /opt/diag/swstate.py headphone 2>/dev/null | head -1 | cut -f4)
  case "$v" in 1) echo in; return ;; 0) echo out; return ;; esac
  for c in $(awk '/^ *[0-9]+ \[/{print $1}' /proc/asound/cards 2>/dev/null); do
    v=$(amixer -c "$c" cget iface=CARD,name='Headphone Jack' 2>/dev/null | sed -n 's/.*: values=//p')
    case "$v" in on) echo in; return ;; off) echo out; return ;; esac
  done
}

hp_wait() {   # want seconds -> 0 once the jack reads it, 1 timed out, 2 skipped
  local t
  printf 'hp-%s\n' "$1" > "$RUN_DIR/sound.step"   # what is wanted - the VM harness reads it
  for (( t = 0; t < $2 * 2; t++ )); do
    [ "$(hp_state)" = "$1" ] && return 0
    _ask waitkey 0.5
    case "$(printf '%s' "$UI_ANS" | tr '[:upper:]' '[:lower:]')" in q|s) return 2 ;; esac
  done
  return 1
}

# Where a tone was heard -> EAR. Not called inside $( ): the menu talks to
# the renderer and its answer must land in this shell.
hp_ear() {   # title
  EAR=none
  tui_menu "$1" "" \
    "Left ear|" "Right ear|" "Both ears|" "Nothing at all|" \
    "From the laptop's speakers|not the headphones" || return 0
  case "$TUI_CHOICE" in 1) EAR=left ;; 2) EAR=right ;; 3) EAR=both ;; 4) EAR=none ;; *) EAR=speakers ;; esac
}

if tui_menu "Headphone jack" "a pair of headphones or earphones to hand?" \
     "Test the headphone jack|plug headphones in - the socket and its plug-detect switch" \
     "Skip|no headphones to hand" && [ "$TUI_CHOICE" = 1 ]; then
  HP_DET=$(hp_state)
  if [ "$HP_DET" = out ]; then
    tui_frame "Sound test - headphone jack" "S = skip"
    tui_line 6 "Plug the headphones into the headphone jack." ""
    tui_line 8 "The jack's plug-detect switch should notice within a second." muted
    tui_flush
    hp_wait in 30; case $? in 0) HP_IN=yes ;; 1) HP_IN=no ;; *) HP_IN=skipped ;; esac
  else
    [ "$HP_DET" = in ] && HP_IN="already in"
    tui_msg "Headphone jack" "Plug the headphones in, then press Enter." \
      "$( [ -z "$HP_DET" ] && echo "(This codec does not report the jack, so only your ears can tell.)")"
  fi
  if [ "$HP_IN" != skipped ]; then
    tui_frame "Sound test - headphone jack" "playing the LEFT channel"
    tui_line 6 "Playing a tone on the LEFT channel - listen in the headphones." ""; tui_flush
    play "$RUN_DIR/tone_l.wav"; sleep 0.3
    hp_ear "Where did that tone come from?"; HP_L=$EAR
    tui_frame "Sound test - headphone jack" "playing the RIGHT channel"
    tui_line 6 "Playing a different tone on the RIGHT channel." ""; tui_flush
    play "$RUN_DIR/tone_r.wav"; sleep 0.3
    hp_ear "And that one?"; HP_R=$EAR
    if [ -n "$HP_DET" ]; then
      tui_frame "Sound test - headphone jack" "S = skip"
      tui_line 6 "Now take the headphones out." ""
      tui_line 8 "The sound should go back to the speakers." muted
      tui_flush
      hp_wait out 30; case $? in 0) HP_OUT=yes ;; 1) HP_OUT=no ;; *) HP_OUT=skipped ;; esac
    fi

    HP_STATE=PASS; HP_NOTE="both ears, and plug-in and removal noticed"
    [ -z "$HP_DET" ] && HP_NOTE="both ears (this codec does not report plug-in)"
    if [ "$HP_L" = speakers ] || [ "$HP_R" = speakers ]; then
      HP_STATE=FAIL
      HP_NOTE="sound stayed on the speakers with headphones in - the jack's plug-detect switch"
    elif [ "$HP_L" = none ] && [ "$HP_R" = none ]; then
      HP_STATE=FAIL; HP_NOTE="nothing in either ear - try another pair; if still silent, the jack"
    elif [ "$HP_L" = none ] || [ "$HP_R" = none ]; then
      HP_STATE=FAIL
      HP_NOTE="the $( [ "$HP_L" = none ] && echo left || echo right ) ear is silent - try another pair; if the same, a worn jack contact"
    elif [ "$HP_L" = right ] && [ "$HP_R" = left ]; then
      HP_STATE=FAIL; HP_NOTE="left and right are swapped in the jack"
    elif [ "$HP_IN" = no ]; then
      HP_STATE=WARN; HP_NOTE="sound reaches the headphones, but plugging in was not reported"
    elif [ "$HP_OUT" = no ]; then
      HP_STATE=WARN; HP_NOTE="removing the headphones was not noticed - the speakers may stay muted"
    elif [ "$HP_L" = both ] || [ "$HP_R" = both ]; then
      HP_STATE=WARN; HP_NOTE="a tone meant for one ear came out of both"
    fi
  fi
fi

# ---------------------------------------------------------------- microphone
MIC_STATE=SKIP; MIC_NOTE="not tested"; PEAK=0; RMS=0
if have arecord && arecord -l 2>/dev/null | grep -q '^card'; then
  tui_frame "Sound test - microphone" "speak now"
  tui_line 6  "Recording for ${REC_SECS} seconds - say something out loud." ""
  tui_line 8  "It will be played straight back to you." muted
  tui_flush
  sleep 0.6
  rm -f "$REC_WAV"
  arecord -q -f cd -d "$REC_SECS" "$REC_WAV" >/dev/null 2>&1
  read -r PEAK RMS <<< "$(wav_level "$REC_WAV")"
  PEAK=${PEAK:-0}; RMS=${RMS:-0}

  tui_frame "Sound test - microphone" "playing it back"
  tui_line 6 "Playing back what the microphone picked up." ""
  tui_kv   8 "Peak level" "${PEAK} %"
  tui_flush
  play "$REC_WAV"
  sleep 0.3

  if [ "$PEAK" -lt 2 ]; then
    MIC_STATE=FAIL; MIC_NOTE="the recording was silent (peak ${PEAK} %)"
  else
    MIC_ANS=yes
    tui_menu "Did you hear your own voice played back?" "" \
      "Yes, clearly|the microphone works" \
      "Yes, but very faint or distorted|" \
      "No, nothing|" \
      && case "$TUI_CHOICE" in 1) MIC_ANS=yes ;; 2) MIC_ANS=faint ;; 3) MIC_ANS=no ;; esac
    case "$MIC_ANS" in
      yes)   MIC_STATE=PASS; MIC_NOTE="recorded and played back cleanly (peak ${PEAK} %)" ;;
      faint) MIC_STATE=WARN; MIC_NOTE="recorded but faint or distorted (peak ${PEAK} %)" ;;
      no)    MIC_STATE=FAIL; MIC_NOTE="nothing audible on playback (peak ${PEAK} %)" ;;
    esac
  fi
else
  MIC_NOTE="no capture device on this machine"
fi

# ---------------------------------------------------------------- report
rsection "SOUND TEST"
rsilent "Sound cards       : $NCARDS"
while IFS='|' read -r id desc; do
  [ -z "$id" ] && continue
  rsilent "  $desc"
done <<< "$CARDS"
rsilent ""
rsilent "Left tone heard   : $LEFT_ANS"
rsilent "Right tone heard  : $RIGHT_ANS"
rsilent "Speakers          : $SPK_STATE - $SPK_NOTE"
rsilent "Headphone jack    : $HP_STATE - $HP_NOTE"
[ "$HP_STATE" != SKIP ] && rsilent "  heard: left tone $HP_L, right tone $HP_R; plug-in ${HP_IN:-not reported}, removal ${HP_OUT:-not reported}"
rsilent "Microphone        : $MIC_STATE - $MIC_NOTE"
[ "$PEAK" -gt 0 ] && rsilent "Recorded level    : peak ${PEAK} %   average ${RMS} %"
rsilent ""

# The verdict has to name the part that actually failed. Saying "FAIL (both
# speakers respond...)" because the microphone was silent is worse than useless
# on a job sheet.
case "$SPK_STATE:$MIC_STATE" in
  FAIL:FAIL) STATE=FAIL; HEADLINE="$SPK_NOTE, and $MIC_NOTE" ;;
  FAIL:*)    STATE=FAIL; HEADLINE="$SPK_NOTE" ;;
  *:FAIL)    STATE=FAIL; HEADLINE="speakers are fine, but $MIC_NOTE" ;;
  WARN:*)    STATE=WARN; HEADLINE="$SPK_NOTE" ;;
  *:WARN)    STATE=WARN; HEADLINE="speakers are fine, but the microphone $MIC_NOTE" ;;
  *:SKIP)    STATE=PART; HEADLINE="speakers pass; this machine has no microphone to test" ;;
  *)         STATE=PASS; HEADLINE="speakers and microphone both good" ;;
esac
# The jack is named on its own: "FAIL (speakers are fine...)" for a dead jack
# would send the repair to the wrong part.
case "$HP_STATE" in
  FAIL) if [ "$STATE" = FAIL ]; then HEADLINE="$HEADLINE; headphone jack: $HP_NOTE"
        else STATE=FAIL; HEADLINE="headphone jack: $HP_NOTE"; fi ;;
  WARN) if [ "$STATE" = PASS ] || [ "$STATE" = PART ]; then STATE=WARN; HEADLINE="headphone jack: $HP_NOTE"; fi ;;
  PASS) [ "$STATE" = PASS ] && HEADLINE="speakers, headphone jack and microphone all good" ;;
esac
case "$STATE" in
  FAIL) VERDICT="FAIL ($HEADLINE)" ;;
  WARN) VERDICT="MARGINAL ($HEADLINE)" ;;
  PART) VERDICT="PARTIAL ($HEADLINE)" ;;
  *)    VERDICT="PASS ($HEADLINE)" ;;
esac
rsilent "RESULT: $VERDICT"
set_kv SOUND_RESULT "$VERDICT"
rm -f "$RUN_DIR/tone_l.wav" "$RUN_DIR/tone_r.wav"

tui_frame "Sound test finished" "Enter to go back"
case "$STATE" in
  PASS) tui_badge 6 PASS "$HEADLINE" ;;
  WARN) tui_badge 6 MARGINAL "$HEADLINE" ;;
  FAIL) tui_badge 6 FAIL "$HEADLINE" ;;
  *)    tui_badge 6 PARTIAL "$HEADLINE" ;;
esac
tui_kv 9  "Left tone"  "$LEFT_ANS"  "$([ "$LEFT_ANS"  = left  ] && echo ok || echo err)"
tui_kv 10 "Right tone" "$RIGHT_ANS" "$([ "$RIGHT_ANS" = right ] && echo ok || echo err)"
tui_kv 11 "Microphone" "$MIC_STATE" "$([ "$MIC_STATE" = PASS ] && echo ok || echo warn)"
if [ "$MIC_STATE" != SKIP ]; then
  tui_kv 12 "Recorded peak" "${PEAK} % of full scale" \
    "$([ "${PEAK:-0}" -ge 2 ] 2>/dev/null && echo ok || echo err)"
fi
tui_kv 13 "Headphone jack" "$HP_STATE" "$(case "$HP_STATE" in PASS) echo ok ;; SKIP) echo muted ;; FAIL) echo err ;; *) echo warn ;; esac)"
tui_line 15 "Speakers: $SPK_NOTE" "$([ "$SPK_STATE" = PASS ] && echo ok || echo err)"
tui_line 16 "Headphones: $HP_NOTE" "$(case "$HP_STATE" in PASS) echo ok ;; SKIP) echo muted ;; FAIL) echo err ;; *) echo warn ;; esac)"
tui_line 17 "Microphone: $MIC_NOTE" "$([ "$MIC_STATE" = PASS ] && echo ok || echo err)"
tui_flush
tui_anykey
