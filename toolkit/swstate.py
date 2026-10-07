#!/usr/bin/env python3
"""The state of the machine's switches, read from the kernel's input devices.

    swstate.py [kind ...]     one line per switch: event TAB device name TAB kind TAB 0|1
    kinds: lid, tablet, headphone, mic, lineout, jack (no kind = all of them)

The lid sensor, the 2-in-1 hinge and the audio jacks are all "switches" to the
kernel (EV_SW). Their *current* position is asked for with EVIOCGSW, which
works on a device another program has grabbed - ui.py grabs the keyboards,
and the lid switch's state is still readable here. Nothing is written.

The numbers come from a C probe against /usr/include/linux (input.h,
input-event-codes.h), not from hand calculation:
    EVIOCGSW(len) = 0x8000451b | len << 16
    SW_LID 0, SW_TABLET_MODE 1, SW_HEADPHONE_INSERT 2, SW_MICROPHONE_INSERT 4,
    SW_LINEOUT_INSERT 6, SW_JACK_PHYSICAL_INSERT 7, SW_CNT 17
"""
import fcntl
import os
import sys

KINDS = {"lid": 0, "tablet": 1, "headphone": 2, "mic": 4, "lineout": 6, "jack": 7}
SW_BYTES = 8                                    # SW_CNT is 17 bits; more is allowed


def eviocgsw(n):
    return 0x8000451B | (n << 16)


def devices():
    """(event node, name, supported switch bits) for every device with switches."""
    out = []
    try:
        with open("/proc/bus/input/devices") as f:
            text = f.read()
    except OSError:
        return out
    for chunk in text.split("\n\n"):
        name, node, sw = "", "", 0
        for line in chunk.splitlines():
            if line.startswith("N: Name="):
                name = line.split("=", 1)[1].strip().strip('"')
            elif line.startswith("H: Handlers="):
                for h in line.split("=", 1)[1].split():
                    if h.startswith("event"):
                        node = h
            elif line.startswith("B: SW="):
                # the bitmap as the kernel prints it: hex words, highest first
                for w in line.split("=", 1)[1].split():
                    sw = (sw << 64) | int(w, 16)
        if node and sw:
            out.append((node, name, sw))
    return out


def state(node):
    """The switch bitmap now, or None when the device cannot be read."""
    try:
        fd = os.open("/dev/input/" + node, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        buf = bytearray(SW_BYTES)
        fcntl.ioctl(fd, eviocgsw(SW_BYTES), buf, True)
        return int.from_bytes(bytes(buf), "little")
    except OSError:
        return None
    finally:
        os.close(fd)


def main(argv):
    want = [k for k in argv if k in KINDS] or list(KINDS)
    for node, name, sw in devices():
        now = state(node)
        if now is None:
            continue
        for kind in want:
            bit = KINDS[kind]
            if sw >> bit & 1:
                print("%s\t%s\t%s\t%d" % (node, name.replace("\t", " "), kind, now >> bit & 1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
