#!/bin/bash
# Start the graphical renderer, if this machine can run it.
# Exits non-zero when it cannot, and the toolkit then uses the text interface.
RUN=/run/diag
mkdir -p "$RUN"

[ -e /dev/fb0 ] || exit 1
command -v python3 >/dev/null 2>&1 || exit 1
python3 -c 'import PIL' >/dev/null 2>&1 || exit 1

rm -f "$RUN/ui.cmd" "$RUN/ui.reply" "$RUN/ui.pid"
python3 /opt/diag/ui.py > "$RUN/ui.log" 2>&1 &
echo $! > "$RUN/ui.pid"

# The renderer creates its FIFOs, then sets up the framebuffer. If that fails it
# dies straight away, which is what the liveness check below catches.
for _ in $(seq 1 50); do
  if [ -p "$RUN/ui.cmd" ] && [ -p "$RUN/ui.reply" ]; then
    sleep 0.4
    kill -0 "$(cat "$RUN/ui.pid")" 2>/dev/null && exit 0
    exit 1
  fi
  kill -0 "$(cat "$RUN/ui.pid")" 2>/dev/null || exit 1
  sleep 0.1
done
exit 1
