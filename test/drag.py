#!/usr/bin/env python3
"""Drive the VM's absolute mouse through QMP - for the partition editor's
drag (and any click), which HMP mouse_move cannot do (CLAUDE.md: the active
mouse is the absolute vmmouse).

    python3 test/drag.py click X Y              left click at screen pixels
    python3 test/drag.py drag X0 Y0 X1 Y1 [N]   press at X0,Y0, move in N steps, release
    python3 test/drag.py move X Y               just move the pointer

Coordinates are screen pixels; --size WxH if the VM is not 1280x800.
"""
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from qmp import Q  # noqa: E402

W, H = 1280, 800


def ax(x, y):
    return [{"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / (W - 1))}},
            {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / (H - 1))}}]


def btn(down):
    return [{"type": "btn", "data": {"down": down, "button": "left"}}]


def main(argv):
    global W, H
    if "--size" in argv:
        i = argv.index("--size")
        W, H = (int(v) for v in argv[i + 1].split("x"))
        del argv[i:i + 2]
    q = Q()
    op, nums = argv[1], [int(v) for v in argv[2:]]
    if op == "move":
        q.touch(ax(*nums[:2]))
    elif op == "click":
        q.touch(ax(*nums[:2])); time.sleep(0.15)
        q.touch(btn(True)); time.sleep(0.1)
        q.touch(btn(False))
    elif op == "drag":
        x0, y0, x1, y1 = nums[:4]
        n = nums[4] if len(nums) > 4 else 12
        q.touch(ax(x0, y0)); time.sleep(0.2)
        q.touch(btn(True)); time.sleep(0.2)
        for k in range(1, n + 1):
            q.touch(ax(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n))
            time.sleep(0.08)
        time.sleep(0.2)
        q.touch(btn(False))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
