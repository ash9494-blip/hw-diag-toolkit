#!/bin/bash
python3 "$(dirname "$0")/mc.py" screendump /tmp/diagvm/s.ppm >/dev/null 2>&1
python3 -c "from PIL import Image; Image.open('/tmp/diagvm/s.ppm').save('/tmp/diagvm/$1.png')"
