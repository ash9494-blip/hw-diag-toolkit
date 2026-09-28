#!/bin/bash
for k in "$@"; do python3 "$(dirname "$0")/mc.py" sendkey $k >/dev/null; sleep 0.7; done
