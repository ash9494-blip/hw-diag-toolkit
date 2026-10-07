#!/usr/bin/env python3
"""
How the rest of the machine's tests look from inside the laptop.

The RAM, CPU, battery, charging, USB, Wi-Fi and Ethernet tests, one short
animation each, in the same frame and with the same tools as the drive
animations (ssdanim.py): the title and tabs, a diagram, a side panel, a strip
and a caption for every step. Each diagram is the part of the laptop its test
works on - the memory and its bus, the processor and its cooler, the battery
and the charge path, a USB socket's contacts, the Wi-Fi card's antenna leads,
the four pairs of an Ethernet cable.

The captions follow what the scripts really do (ramtest.sh, cputest.sh,
battery.sh, chargetest.sh, usbtest.sh, wifitest.sh, nettest.sh): if a script
changes, change its caption here too.

Live, while a test runs, the picture follows the test's own figures wherever
it can: the temperature colours the processor and speeds the fan, the charge
level fills the cells, a dropped charger connection sparks at the jack, the
negotiated speed lights the cable's pairs, the sockets are the ones the test
found. It never shows a fault the test has not found, the side panel carries
the test's own lines, and the test's instruction to the operator ("Unplug the
charger") is the line under the title.

One file for the set, as ssdanim.py is for the drives - a deliberate
exception to the usual file size: each scene is a self-contained section
(layout, static drawing, moving parts, panel, strip) over the helpers at the
top, and is read and changed as one piece with its test.

Standalone, for checking without a framebuffer (ui.py is imported for the
fonts, header and palette):
  hwanim.py --check            render every step of every scene, explained and
                               live, in every theme and three screen sizes
  hwanim.py --frames DIR [--size WxH] [--theme T] [--fps N] [--scene NAME]
  hwanim.py --text [NAME]      the captions as plain text (the text interface
                               shows this instead); drive scenes go to ssdanim
"""
import math, os, re, sys
from types import SimpleNamespace as NS

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ssdanim as sa
from ssdanim import clamp, lerp, ease, seg, mix, hrand, thousands, Pal

FPS = sa.FPS
NOTE = "illustration - not this machine"

# ---------------------------------------------------------------- the scripts
# (seconds, caption) per step, in the order of the home screen.
SCENES = [
    ("ram", "RAM test", "", [
        (7, "A test inside Linux can only use memory Linux is not using. The toolkit takes "
            "what is free, keeps 512 MB back so nothing runs short, and tests 75 % of the rest. "
            "The part in use needs MemTest86+ from the boot menu."),
        (8, "Memory stress test: stressapptest starts one worker per processor thread. They "
            "fill the region with patterns, then copy blocks from one address to another as "
            "fast as the memory bus will carry them."),
        (8, "Every block carries a checksum. After each copy the worker checks the block "
            "arrived unchanged: one flipped bit is a miscompare, logged as a hardware error "
            "with its address."),
        (7, "The point is load: minutes of the bus flat out, the modules warming up. Memory "
            "that fails only when busy or hot - random reboots, blue screens - fails here."),
        (8, "Memory pattern test: memtester locks the region and splits it in two halves. Each "
            "pattern - stuck address, random values, walking ones and zeros, checkerboard and "
            "more - goes into both, and the halves are compared word by word."),
        (7, "Any difference is a FAIL. Reseat the modules and test again; if it still fails, "
            "test one module at a time - and confirm with MemTest86+ before replacing anything."),
    ]),
    ("cpu", "CPU stress test", "stress-ng", [
        (6, "First, 10 s at rest: the toolkit reads the temperature sensor inside the processor "
            "(coretemp on Intel, k10temp on AMD) for an idle baseline, with the clock speed and "
            "the throttle counter."),
        (8, "Then stress-ng loads every thread: one worker each, working through every kind of "
            "calculation in turn - integer, floating point, bit operations - so every part of "
            "every core is busy."),
        (9, "Nearly all of that power becomes heat. It must cross the thermal paste into the "
            "cold plate, run along the heat pipe to the fins and leave on the fan's air. Dry "
            "paste, dusty fins or a tired fan - and the heat stays in the chip."),
        (8, "Every 2 s: temperature, clock speed and the throttle counter. Too hot, and the "
            "processor slows itself down to survive - each slowdown is a throttle event."),
        (8, "Peak under 90 C = PASS, 90 to 96 C = MARGINAL (runs hot), 97 C or more = FAIL. "
            "Four readings in a row at 100 C stop the test early to protect the chip. Then 5 s "
            "of rest: a good cooler pulls the heat out fast."),
    ]),
    ("battery", "Battery drain test", "", [
        (7, "Step 1, charge to full: the drain test measures the energy the pack gives back, so "
            "it starts full. A pack that stops short of 100 % - worn, or held by a charge "
            "limit - can start from where it stopped: press S."),
        (6, "Step 2, unplug the charger. The test starts by itself the moment the battery "
            "takes over and its status turns to Discharging."),
        (9, "Step 3, drain - idle, or with one or every thread loaded. Every 30 s the toolkit "
            "reads the pack's own figures (charge, energy, voltage, power) and writes them to "
            "the USB stick, so the log survives the machine switching off."),
        (9, "The gauge chip in the pack claims what a full charge holds. The test counts the "
            "energy that actually came out and compares it with the design capacity and with "
            "that claim. When the machine dies, boot the toolkit again: it finds the log."),
        (8, "80 % of the design or more = PASS. 60 to 79 % = WORN. Under 60 %, or under 70 % "
            "of the gauge's claim = FAIL. Switching off while still showing over 15 % = FAIL: "
            "the cells can no longer hold their voltage."),
    ]),
    ("charge", "Charging test", "", [
        (6, "Unplug: the firmware keeps a 'charger connected' flag. The toolkit watches it, and "
            "the battery's own status, to see the machine notice the charger going."),
        (7, "Plug in: the flag must come on and the battery must start charging. Seen but not "
            "charging = the battery, a charger of the wrong wattage, or the charge circuit. A "
            "charge limit set in the BIOS is respected, never changed."),
        (8, "Charge rate: one minute measuring the power going into the battery. Under 15 % of "
            "the pack's size an hour - about 7 W for a 45 Wh pack - is slow: a weak charger or a "
            "worn battery. Near full, every pack slows down on purpose."),
        (9, "Wiggle: 30 s of gently moving the plug. The flag is read 4 times a second and the "
            "kernel's power events are recorded too, so even a drop too short to see is counted. "
            "Any drop = a loose DC jack, its solder joints, or the cable."),
        (8, "USB-C: with the charger out, a USB-C charger goes into each USB-C port that can "
            "take power, one at a time. The port must see it and the battery must charge; what "
            "the charger offers (volts, amps) is read from the firmware."),
    ]),
    ("usb", "USB port test", "", [
        (7, "A socket can only be tested with something plugged into it. The USB controller "
            "lists more ports than the case has sockets - the camera and Bluetooth hang off it "
            "too - so only sockets that take a device count."),
        (8, "Plug in: the controller sees the device, resets it and agrees a speed. USB 2 talks "
            "over one pair of contacts (D+ and D-) at up to 480 Mbit/s; a USB 3 device adds two "
            "pairs of its own on five more contacts, for 5 Gbit/s or more."),
        (7, "Then the device says what it is - its USB version and its class: storage, "
            "keyboard, mouse, camera. Its row appears at once, with the speed the link really "
            "came up at."),
        (8, "A USB 3 device that came up at 480 Mbit/s or less means the SuperSpeed contacts in "
            "that socket are dirty, bent or broken: MARGINAL. A USB 2 device at USB 2 speed is "
            "normal - a mouse runs at 12 Mbit/s."),
        (6, "Unplug it and the row stays, marked tested. The stick the toolkit booted from is "
            "shown but never counted - only a device plugged in during the test proves a socket."),
    ]),
    ("wifi", "Wireless test", "", [
        (8, "Scan: the radio listens on every channel and lists each access point it hears, "
            "with its signal in dBm. No password is needed - hearing them at all proves the card "
            "and its antennas are alive."),
        (8, "Signal: -55 dBm or better is excellent, below -80 nothing works reliably. An "
            "antenna lead left off after a screen or hinge repair reads -85 or worse even right "
            "next to the access point."),
        (8, "Stability: on the network joined from the Wi-Fi page, every 2 s the toolkit reads "
            "the signal, the link rate and which access point it is on - and pings the gateway."),
        (7, "A link that drops while the machine sits still is a fault in the card or its "
            "antennas, not coverage: FAIL. Lost pings are counted, and roaming to another access "
            "point is noted."),
        (7, "Last, the internet: three name lookups, three HTTPS sites, and one 20 MB download "
            "for an indicative speed."),
    ]),
    ("ether", "Ethernet test", "", [
        (8, "Link: with a live cable in, the network chip and the switch at the other end "
            "exchange pulses and agree a speed. 1000 Mbit/s uses all four pairs of wires in the "
            "cable; 100 Mbit/s uses only two."),
        (7, "So a gigabit port that comes up at 100 is a warning: one broken pair in the cable, "
            "or a bent pin in the socket. Try a known-good cable before blaming the board."),
        (8, "Address: DHCP. The laptop asks for one (Discover), the router offers one (Offer), "
            "the laptop takes it (Request) and the router confirms (Ack). Link up but no "
            "address = FAIL."),
        (8, "Traffic: two pings to the gateway, four to 1.1.1.1 on the internet - any loss "
            "shows - and one name lookup. All working = PASS; an address but no internet, or no "
            "DNS = MARGINAL."),
    ]),
]
NAMES = [s[0] for s in SCENES]
SHORT = {"ram": "RAM", "cpu": "CPU", "battery": "Battery", "charge": "Charging",
         "usb": "USB", "wifi": "Wi-Fi", "ether": "Ethernet"}
# live: the side panel's heading, and what the moving parts are a picture of
WORDS = {"ram": ("THIS MEMORY, NOW", "the memory test is"),
         "cpu": ("THIS PROCESSOR, NOW", "the processor and its cooler are"),
         "battery": ("THIS BATTERY, NOW", "the battery is"),
         "charge": ("THIS CHARGER, NOW", "the charger and the battery are"),
         "usb": ("THESE SOCKETS, NOW", "the sockets are"),
         "wifi": ("THIS RADIO, NOW", "the radio is"),
         "ether": ("THIS PORT, NOW", "the network port is")}


# ---------------------------------------------------------------- the stage
class Bench(sa.Canvas):
    """The drive animations' frame with a different diagram per scene. Each
    scene's geometry is worked out once per screen size, on first use."""

    def __init__(self, scr, pal):
        sa.Canvas.__init__(self, scr, pal)
        self.facts = None          # live: the test's figures, {label: (value, tone)}
        self.lines = []            # live: the test's lines, [(row, text, tone)]
        self.opts = []
        self.hist = []             # live: what a scene remembers between frames
        self._lay = {}

    def lay(self, name):
        if name not in self._lay:
            self._lay[name] = LAYOUT[name](self)
        return self._lay[name]

    def background(self, i):
        img = self.cached(i)
        if img is None:
            name = SCENES[i][0]
            img, d = self.chrome(SCENES, SHORT, i)
            STATIC[name](self, d, self.lay(name))
            self._bg[i] = img
        return img


# ---------------------------------------------------------------- the test's figures
def live(st):
    return st.facts is not None


def fact(st, *labels):
    """Live: what the test shows against the first of these labels (lower
    case) that is on its screen, or None."""
    for lab in labels:
        v = (st.facts or {}).get(lab)
        if v is not None:
            return v[0]
    return None


def line_with(st, text):
    """Live: the first of the test's lines containing this text, or None."""
    for _, t, _ in st.lines:
        if text in t:
            return t
    return None


def number(text, default=None):
    """The first number in a figure: '78 C' -> 78.0, '-54 dBm' -> -54.0."""
    m = re.search(r"-?\d+(?:\.\d+)?", (text or "").replace(",", ""))
    return float(m.group()) if m else default


def remember(st, value, keep=20.0):
    """Live: a value per frame, kept for the last `keep` seconds of the phase."""
    if st.hist and st.hist[-1][0] > st.clock:
        st.hist = []                       # a new phase began
    st.hist.append((st.clock, value))
    while st.hist and st.hist[0][0] < st.clock - keep:
        st.hist.pop(0)
    return st.hist


# ---------------------------------------------------------------- drawing
def heat(P, temp):
    """A part's colour at a temperature: its own grey when cool, amber from
    60 C, red from 90 C - the bands the CPU test judges by."""
    if temp is None:
        return P.CHIP
    if temp < 60:
        return mix(P.CHIP, P.SLC, clamp((temp - 35) / 25.0))
    if temp < 85:
        return mix(P.SLC, P.WARN_, clamp((temp - 60) / 25.0))
    return mix(P.WARN_, P.FAIL_, clamp((temp - 85) / 10.0))


def copper(P):
    return mix(mix(P.WARN_, P.FAIL_, 0.35), P.PAPER, 0.30)


def rr(st, d, box, fill=None, outline=None, width=1, r=None):
    """A rounded box on whole pixels. Pillow's rounded rectangle raises on a
    fractional box whose corners nearly meet, and these boxes are worked out
    from fractions of the screen."""
    x0, y0, x1, y1 = [int(round(v)) for v in box]
    r = int(6 * st.s) if r is None else int(r)
    r = max(0, min(r, (x1 - x0 - 2) // 2, (y1 - y0 - 2) // 2))
    st.rr(d, (x0, y0, x1, y1), fill=fill, outline=outline, width=width, r=r)


def part(st, d, box, name=None, fill=None, outline=None, sub=None):
    """A component: a box with its name in drafting capitals across the top."""
    P, s = st.P, st.s
    rr(st, d, box, fill=fill or P.CHIP, outline=outline or P.INK, width=max(1, int(2 * s)))
    x = (box[0] + box[2]) // 2
    if name:
        st.text(d, (x, box[1] + int(6 * s)), name, st.scr.f_noteb, P.INK, "ma")
    if sub:
        st.text(d, (x, box[1] + int(27 * s)), sub, st.scr.f_tiny, P.MUTED, "ma")


def note(st, d, xy, text, col=None, anchor="la"):
    st.text(d, xy, text, st.scr.f_tiny, col or st.P.MUTED, anchor)


def heading(st, d, xy, text, anchor="la"):
    """A drafting heading over a part of the diagram ("THIS LAPTOP")."""
    st.text(d, xy, text, st.scr.f_note, st.P.MUTED, anchor)


def flow(st, d, pts, t, speed, n, col, r=None):
    """n dots travelling along a path: energy, heat or air on the move."""
    r = r or max(2, int(3 * st.s))
    for k in range(n):
        st.dot(d, st.along(pts, (t * speed + k / float(n)) % 1.0), r, col)


def packet(st, d, pts, u, col=None, label=None, hollow=False, side=-1):
    """One message on its way along a path, its name on a tag above (side -1)
    or below (1)."""
    P, s = st.P, st.s
    col = col or P.ACCENT
    x, y = st.along(pts, ease(u))
    w, h = int(16 * s), int(6 * s)
    box = (int(x - w / 2), int(y - h), int(x + w / 2), int(y + h))
    if hollow:
        rr(st, d, box, fill=P.PAPER, outline=col, width=max(1, int(2 * s)), r=int(2 * s))
    else:
        rr(st, d, box, fill=col, r=int(2 * s))
    if label:
        st.tag(d, (x, y + side * int(21 * s)), label, bg=col)


def arrow(st, d, a, b, col, w=None):
    s = st.s
    w = w or max(2, int(3 * s))
    hd = int(11 * s)
    ang = math.atan2(b[1] - a[1], b[0] - a[0])
    stem = (b[0] - hd * 0.6 * math.cos(ang), b[1] - hd * 0.6 * math.sin(ang))
    d.line([a, stem], fill=col, width=w)
    d.polygon([b, (b[0] - hd * math.cos(ang - 0.5), b[1] - hd * math.sin(ang - 0.5)),
               (b[0] - hd * math.cos(ang + 0.5), b[1] - hd * math.sin(ang + 0.5))], fill=col)


def bolt(d, cx, cy, h, col):
    """A lightning bolt, drawn: a spark where a connection breaks."""
    pts = [(0.12, -0.5), (-0.24, 0.06), (0.0, 0.06), (-0.12, 0.5), (0.24, -0.08), (0.0, -0.08)]
    d.polygon([(cx + x * h, cy + y * h) for x, y in pts], fill=col)


def tick(d, cx, cy, h, col, w):
    d.line([(cx - 0.45 * h, cy), (cx - 0.1 * h, cy + 0.35 * h), (cx + 0.5 * h, cy - 0.4 * h)],
           fill=col, width=w, joint="curve")


def cross(d, cx, cy, h, col, w):
    d.line([(cx - h / 2, cy - h / 2), (cx + h / 2, cy + h / 2)], fill=col, width=w)
    d.line([(cx - h / 2, cy + h / 2), (cx + h / 2, cy - h / 2)], fill=col, width=w)


def hatch(st, d, box, col, gap=None):
    """Diagonal hatching inside a box: something the test cannot reach."""
    x0, y0, x1, y1 = [int(v) for v in box]
    g = gap or max(4, int(7 * st.s))
    h = y1 - y0
    for k in range(x0 - h, x1, g):
        ax, ay, bx, by = k, y1, k + h, y0
        if ax < x0:
            ay -= x0 - ax; ax = x0
        if bx > x1:
            by += bx - x1; bx = x1
        if ax <= bx:
            d.line([ax, ay, bx, by], fill=col)


def dashed(st, d, pts, col, w=None, dash=None):
    s = st.s
    w = w or max(1, int(2 * s))
    dash = dash or max(4, int(7 * s))
    for (xa, ya), (xb, yb) in zip(pts, pts[1:]):
        n = max(1, int(math.hypot(xb - xa, yb - ya) / dash))
        for k in range(0, n, 2):
            e = min(1.0, (k + 1) / float(n))
            d.line([lerp(xa, xb, k / float(n)), lerp(ya, yb, k / float(n)),
                    lerp(xa, xb, e), lerp(ya, yb, e)], fill=col, width=w)


def dashed_box(st, d, box, col):
    x0, y0, x1, y1 = box
    dashed(st, d, [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)], col)


def cloud(st, d, box, fill, outline):
    """The internet: overlapping circles on a flat base, outlined as one."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    lw = max(1, int(2 * st.s))
    blobs = [(0.27, 0.66, 0.30), (0.50, 0.46, 0.42), (0.74, 0.62, 0.32)]
    base = (x0 + w * 0.10, y0 + h * 0.62, x1 - w * 0.08, y1)
    for grow, col in ((lw, outline), (0, fill)):
        for cx, cy, r in blobs:
            R = r * h + grow
            d.ellipse([x0 + cx * w - R, y0 + cy * h - R, x0 + cx * w + R, y0 + cy * h + R], fill=col)
        rr(st, d, (base[0] - grow, base[1] - grow, base[2] + grow, base[3] + grow), fill=col,
              r=int(h * 0.3))


def battery_cell(st, d, box, level, col):
    """A cell standing up: cap, body, and its charge as a fill from the foot."""
    P, s = st.P, st.s
    x0, y0, x1, y1 = box
    cw = (x1 - x0) * 0.36
    d.rectangle([(x0 + x1) / 2 - cw / 2, y0 - int(5 * s), (x0 + x1) / 2 + cw / 2, y0], fill=P.MUTED)
    rr(st, d, box, fill=P.PAPER, outline=P.INK, width=max(1, int(2 * s)), r=int(6 * s))
    m = max(3, int(4 * s))
    top = y1 - m - (y1 - y0 - 2 * m) * clamp(level)
    if level > 0.005 and y1 - m - top >= 2:
        rr(st, d, (x0 + m, top, x1 - m, y1 - m), fill=col, r=int(3 * s))


def charge_col(P, level):
    return P.OKT if level > 0.2 else mix(P.WARN_, P.PAPER, 0.45) if level > 0.07 else mix(P.FAIL_, P.PAPER, 0.4)


def signal_bars(st, d, x, y, h, lit, col):
    """Five bars of rising height, `lit` of them filled - a signal meter."""
    P, s = st.P, st.s
    bw, g = max(3, int(7 * s)), max(2, int(4 * s))
    for k in range(5):
        bh = h * (k + 1) / 5.0
        box = (x + k * (bw + g), y + h - bh, x + k * (bw + g) + bw, y + h)
        if k < lit:
            d.rectangle(box, fill=col)
        else:
            d.rectangle(box, outline=P.LINE)
    return x + 5 * (bw + g)


def rotate(cx, cy, pts, ang):
    c, n = math.cos(ang), math.sin(ang)
    return [(cx + x * c - y * n, cy + x * n + y * c) for x, y in pts]


def barrel_plug(st, d, tip, y, ang=0.0, col=None):
    """A DC barrel plug, its tip at (tip, y), the cable leaving to the left;
    ang tilts it about the tip (a wiggle). Returns where the cable starts."""
    P, s = st.P, st.s
    tl, th, gl, gh = 15 * s, 5 * s, 30 * s, 9 * s
    metal = rotate(tip, y, [(-tl, -th), (0, -th), (0, th), (-tl, th)], ang)
    grip = rotate(tip, y, [(-tl - gl, -gh), (-tl, -gh), (-tl, gh), (-tl - gl, gh)], ang)
    boot = rotate(tip, y, [(-tl - gl - 12 * s, -gh * 0.5), (-tl - gl, -gh * 0.8),
                           (-tl - gl, gh * 0.8), (-tl - gl - 12 * s, gh * 0.5)], ang)
    d.polygon(metal, fill=P.MUTED)
    d.polygon(boot, fill=col or P.INK)
    d.polygon(grip, fill=col or P.INK)
    return rotate(tip, y, [(-tl - gl - 12 * s, 0)], ang)[0]


def cable(st, d, a, b, col=None, w=None):
    """A cable from a to b, hanging in an easy curve."""
    s = st.s
    mx = (a[0] + b[0]) / 2.0
    sag = abs(b[0] - a[0]) * 0.10 + 6 * s
    pts = [a]
    for k in range(1, 17):
        q = k / 16.0
        x = lerp(lerp(a[0], mx, q), lerp(mx, b[0], q), q)
        y = lerp(a[1], b[1], ease(q)) + math.sin(q * math.pi) * sag
        pts.append((x, y))
    d.line(pts, fill=col or st.P.INK, width=w or max(2, int(4 * s)), joint="curve")


def strip_seq(st, d, items, title):
    """The strip as the test's stages in a row: (label, state) with state
    done / warn / fail / now / todo."""
    P, s = st.P, st.s
    x0, y0, x1, y1 = st.strip_box
    st.text(d, (x0, y0), title, st.scr.f_tiny, P.MUTED)
    by0, by1 = y0 + int(20 * s), y1 - int(10 * s)
    n = max(1, len(items))
    g = int(8 * s)
    w = (x1 - x0 - g * (n - 1)) / float(n)
    for i, (lab, state) in enumerate(items):
        bx = x0 + i * (w + g)
        box = (int(bx), by0, int(bx + w), by1)
        col = {"done": P.PASS_, "warn": P.WARN_, "fail": P.FAIL_, "now": P.ACCENT}.get(state)
        mid = ((box[0] + box[2]) // 2, (by0 + by1) // 2)
        if col:
            rr(st, d, box, fill=col, r=int(4 * s))
            st.text(d, mid, lab, st.scr.f_tiny, P.PAPER, "mm")
        else:
            rr(st, d, box, fill=P.PAPER, outline=P.LINE, r=int(4 * s))
            st.text(d, mid, lab, st.scr.f_tiny, P.MUTED, "mm")


def rows(st, d, box, items, rh=None, until=None):
    """Panel lines: (label, value, tone) as the drive scenes draw them; with
    `until`, row i only once until > i (they appear one after another)."""
    x0, y0, x1, _ = box
    rh = rh or int(30 * st.s)
    for i, it in enumerate(items):
        if until is not None and until <= i:
            break
        k, v = it[0], it[1]
        tone = it[2] if len(it) > 2 else None
        st.kv(d, x0, x1, y0 + i * rh, k, v, tone, f=st.scr.f_noteb)
    return y0 + len(items) * rh


def say(st, d, box, y, text, col=None, f=None):
    """A sentence in the panel, wrapped; returns the next y."""
    f = f or st.scr.f_small
    for ln in st.wrap(d, text, f, box[2] - box[0], maxlines=3):
        st.text(d, (box[0], y), ln, f, col or st.P.INK)
        y += int(23 * st.s)
    return y


def fit(st, d, text, width, f=None):
    """Text cut to a width, with dots when it had to be."""
    f = f or st.scr.f_tiny
    if d.textlength(text, font=f) <= width:
        return text
    while text and d.textlength(text + "..", font=f) > width:
        text = text[:-1]
    return text + ".."


# ---------------------------------------------------------------- RAM
PATTERNS = [("stuck address", None), ("random value", None), ("compare XOR", None),
            ("solid bits", 0xFF), ("checkerboard", 0x55), ("walking ones", "1"),
            ("walking zeros", "0"), ("bit flip", "f"), ("block sequential", 0x0F)]


def pattern_bits(kind, k):
    """The 8 bits a pattern puts in a byte at moment k."""
    if kind is None:
        v = int(hrand(k, 77) * 256)
    elif kind == "1":
        v = 1 << (k % 8)
    elif kind == "0":
        v = 0xFF ^ (1 << (k % 8))
    elif kind == "f":
        v = 0xAA if k % 2 else 0x55
    else:
        v = kind if k % 2 == 0 else (~kind) & 0xFF
    return [(v >> (7 - i)) & 1 for i in range(8)]


def lay_ram(st):
    s = st.s
    x0, y0, x1, y1 = st.area
    W, H = x1 - x0, y1 - y0
    L = NS()
    m = int(10 * s)
    # the processor: four cores, a robot in each, and the memory controller
    L.cpu = (x0, y0 + int(22 * s), x0 + int(W * 0.27), y1 - int(4 * s))
    cx0, cy0, cx1, cy1 = L.cpu
    L.mc = (cx0 + m, cy1 - int(46 * s), cx1 - m, cy1 - m)
    top, bot, g = cy0 + int(58 * s), L.mc[1] - m, int(8 * s)
    cw, ch = (cx1 - cx0 - 2 * m - g) // 2, (bot - top - g) // 2
    L.cores = [(cx0 + m + c * (cw + g), top + r * (ch + g), cx0 + m + c * (cw + g) + cw,
                top + r * (ch + g) + ch) for r in range(2) for c in range(2)]
    L.bh = max(int(18 * s), int(min(ch * 0.64, cw * 0.70)))
    # two SO-DIMMs, each above its slot, four chips each; a chip's cells are
    # its addresses
    mx0, mx1 = x0 + int(W * 0.42), x1 - int(4 * s)
    gap = int(H * 0.10)
    mh = (y1 - y0 - int(26 * s) - gap - int(4 * s)) // 2
    L.mods, L.slots, L.chips, L.cells = [], [], [], {}
    for k in range(2):
        my0 = y0 + int(26 * s) + k * (mh + gap)
        mod = (mx0, my0, mx1, my0 + mh - int(12 * s))
        L.mods.append(mod)
        L.slots.append((mx0 - int(6 * s), mod[3], mx1 + int(2 * s), mod[3] + int(10 * s)))
        inner = (mod[0] + m, mod[1] + int(20 * s), mod[2] - m, mod[3] - int(14 * s))
        cg = int(10 * s)
        chw = (inner[2] - inner[0] - 3 * cg) / 4.0
        for c in range(4):
            bx0 = inner[0] + c * (chw + cg)
            chip = (int(bx0), inner[1], int(bx0 + chw), inner[3])
            L.chips.append(chip)
            pad = int(4 * s)
            cwc = (chip[2] - chip[0] - 2 * pad) / 5.0
            chc = (chip[3] - chip[1] - 2 * pad) / 3.0
            p = max(1, int(1.5 * s))
            for r in range(3):
                for q in range(5):
                    a, b = chip[0] + pad + q * cwc, chip[1] + pad + r * chc
                    L.cells[(k, c, r, q)] = (int(a) + p, int(b) + p, int(a + cwc) - p, int(b + chc) - p)
    # the memory bus: four lanes out of the controller, to either slot
    bx = L.cpu[2] + int((mx0 - L.cpu[2]) * 0.45)
    my = (L.mc[1] + L.mc[3]) // 2
    lg = max(3, int(6 * s))
    L.bus = []
    for k in range(2):
        sy = (L.slots[k][1] + L.slots[k][3]) // 2
        lanes = []
        for i in range(4):
            o = (i - 1.5) * lg
            tx = bx + (o if sy < my else -o)          # turns nest, never cross
            lanes.append([(L.mc[2], my + o), (tx, my + o), (tx, sy + o), (L.slots[k][0], sy + o)])
        L.bus.append(lanes)
    L.bus_label = ((L.cpu[2] + bx) // 2, my - int(2.5 * lg) - int(3 * s))
    # every cell in a fixed shuffled order: the first share of it is tested
    L.order = sorted(L.cells, key=lambda c: hrand(*c, 5))
    return L


def static_ram(st, d, L):
    P, s, scr = st.P, st.s, st.scr
    lw = max(1, int(2 * s))
    rr(st, d, L.cpu, fill=P.PAPER, outline=P.MUTED, width=lw)
    heading(st, d, ((L.cpu[0] + L.cpu[2]) // 2, L.cpu[1] - int(6 * s)), "THIS LAPTOP'S CPU", "md")
    for i, c in enumerate(L.cores):
        rr(st, d, c, fill=P.CHIP, outline=P.LINE)
        note(st, d, (c[0] + int(4 * s), c[1] + int(2 * s)), "core %d" % (i + 1))
    rr(st, d, L.mc, fill=P.CHIP, outline=P.INK, width=lw)
    st.text(d, ((L.mc[0] + L.mc[2]) // 2, (L.mc[1] + L.mc[3]) // 2), "memory controller",
            scr.f_tiny, P.INK, "mm")
    for lanes in L.bus:
        for ln in lanes:
            d.line(ln, fill=P.LINE, width=max(2, int(3 * s)))
    note(st, d, L.bus_label, "memory bus", anchor="md")
    for k, (mod, slot) in enumerate(zip(L.mods, L.slots)):
        rr(st, d, mod, fill=P.BOARD, outline=P.MUTED, width=lw, r=int(4 * s))
        fy0, fy1 = mod[3] - int(9 * s), mod[3] - int(2 * s)
        notch = mod[0] + (mod[2] - mod[0]) * 0.38
        x = mod[0] + int(6 * s)
        while x < mod[2] - int(6 * s):
            if abs(x - notch) > int(7 * s):
                d.rectangle([x, fy0, x + max(1, int(3 * s)), fy1], fill=P.GOLD)
            x += max(3, int(6 * s))
        d.rectangle(slot, fill=P.INK)
        st.text(d, (mod[0] + int(8 * s), mod[1] + int(3 * s)), "SO-DIMM  slot %d" % (k + 1),
                scr.f_tiny, P.MUTED)
    for chip in L.chips:
        rr(st, d, chip, fill=P.CHIP, outline=P.INK, width=1, r=int(3 * s))
    # the key to the cells, over the modules
    x, y = L.mods[0][2], L.mods[0][1] - int(7 * s)
    q = int(10 * s)
    t2 = "Linux and the toolkit: MemTest86+ only"
    x -= int(d.textlength(t2, font=scr.f_tiny))
    st.text(d, (x, y), t2, scr.f_tiny, P.MUTED, "ld")
    box = (x - q - int(6 * s), y - q - int(2 * s), x - int(6 * s), y - int(2 * s))
    d.rectangle(box, fill=P.SPARE)
    hatch(st, d, box, P.MUTED, max(3, int(4 * s)))
    t1 = "tested"
    x = box[0] - int(16 * s) - int(d.textlength(t1, font=scr.f_tiny))
    st.text(d, (x, y), t1, scr.f_tiny, P.MUTED, "ld")
    d.rectangle((x - q - int(6 * s), y - q - int(2 * s), x - int(6 * s), y - int(2 * s)), fill=P.DATA)
    st.text(d, (st.strip_box[2], st.strip_box[1]), "robot = a test worker on one processor thread",
            scr.f_tiny, P.MUTED, "ra")


def scene_ram(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    L = st.lay("ram")
    st.bot_size(L.bh)
    T = st.clock if live(st) else t
    # the share of the installed memory the test holds
    frac = 0.62
    reg = fact(st, "region tested")
    if reg:
        nums = [float(v) for v in re.findall(r"\d+(?:\.\d+)?", reg.replace(",", ""))]
        if len(nums) >= 2 and nums[1] > 0:
            frac = clamp(nums[0] / nums[1], 0.02, 1.0)
    if live(st):
        e = fact(st, "errors found") or ""
        errs = int(number(e, 0)) if re.search(r"\d", e) else 0
    else:
        errs = 1 if step == 5 else 0
    n_test = max(1, int(round(len(L.order) * frac)))
    tested = L.order[:n_test]
    shown = n_test if (live(st) or step > 0) else int(n_test * ease(seg(u, 0.15, 0.85)))
    lit = {}
    for i, c in enumerate(L.order):
        lit[c] = P.DATA if i < shown else ("hatch" if i >= n_test else None)

    # the traffic, worked out first: what each worker carries, and where
    moves, held, work = [], [None] * 4, [False] * 4
    if 1 <= step <= 3:
        per = 1.25 if step < 3 else 0.8
        for k in range(4):
            f = T / per + k * 0.31
            n, v = int(f), f % 1.0
            src = tested[int(hrand(k, n, 1) * n_test) % n_test]
            dst = tested[int(hrand(k, n, 2) * n_test) % n_test]
            work[k] = True
            if v < 0.36:                       # a block comes in from the module
                moves.append((L.bus[src[0]][k][::-1], v / 0.36))
                lit[src] = P.ACCENT
            elif v < 0.62:                     # checked against its checksum
                held[k] = P.ACCENT if v < 0.5 else P.OKT
            else:                              # and copied out to a new address
                moves.append((L.bus[dst[0]][k], (v - 0.62) / 0.38))
                lit[dst] = P.ACCENT
    elif step == 4:
        # memtester: one worker, pattern after pattern, the whole region
        work[0] = True
        front = int(T * 14) % n_test
        for j in range(6):
            lit[tested[(front + j) % n_test]] = P.ACCENT
        v = (T / 0.55) % 1.0
        mod = int(hrand(int(T / 0.55), 3) * 2)
        moves.append((L.bus[mod][0] if v < 0.5 else L.bus[mod][0][::-1], (v % 0.5) * 2))
        held[0] = P.ACCENT
    bad = tested[:min(errs, 3)]
    for c in bad:
        lit[c] = P.FAIL_

    for c, box in L.cells.items():
        col = lit.get(c)
        if col == "hatch":
            d.rectangle(box, fill=P.SPARE)
            hatch(st, d, box, P.MUTED, max(3, int(5 * s)))
        elif col:
            d.rectangle(box, fill=col)
        else:
            d.rectangle(box, fill=P.PAPER, outline=P.LINE)
    if any(work):
        k = 0.75 if step == 3 else 0.45
        for lanes in L.bus:
            for ln in lanes:
                d.line(ln, fill=mix(P.LINE, P.ACCENT, k), width=max(2, int(3 * s)))
    for path, v in moves:
        packet(st, d, path, v)
    if step == 3:
        for mod in L.mods:
            st.glow(d, mod, P.WARN_, max(1, int(2 * s)))
    if bad:
        st.glow(d, L.mods[bad[0][0]], P.FAIL_)
        b = L.cells[bad[0]]
        st.tag(d, ((b[0] + b[2]) / 2, b[1] - int(14 * s)),
               "miscompare at 0x2F3A1C40" if not live(st) else "errors found here", bg=P.FAIL_)

    # the workers, and what the processor is running
    for k, c in enumerate(L.cores):
        if work[k]:
            rr(st, d, c, outline=P.ACCENT, width=max(1, int(2 * s)))
        x = c[0] + int(7 * s) + st.bw / 2
        y = c[3] - int(4 * s)
        if work[k]:
            st.bot((x, y), held[k] or (P.DATA if int(T * 4 + k) % 2 else None), k, True)
        else:
            st.bot((x, y), None, k, False, "sleep" if step == 4 else "")
    if not live(st) and step == 2 and held[0] == P.OKT:
        c = L.cores[0]
        st.tag(d, ((c[0] + c[2]) / 2, c[1] - int(2 * s)), "checksum OK", bg=P.PASS_)
    cx = (L.cpu[0] + L.cpu[2]) // 2
    eng = fact(st, "engine")
    prog = eng.split()[0] if eng else ("memtester" if step >= 4 else "stressapptest")
    st.text(d, (cx, L.cpu[1] + int(8 * s)), prog, scr.f_noteb, P.INK, "ma")
    if step == 4:
        name, kind = PATTERNS[int(T / 1.1) % len(PATTERNS)]
        st.text(d, (cx, L.cpu[1] + int(28 * s)), name, scr.f_tiny, P.MUTED, "ma")
        bits = pattern_bits(kind, int(T / 0.18))
        q, g = max(4, int(8 * s)), max(1, int(2 * s))
        bx = cx - (8 * q + 7 * g) / 2.0
        for i, b in enumerate(bits):
            box = (bx + i * (q + g), L.cpu[1] + int(46 * s) - q, bx + i * (q + g) + q, L.cpu[1] + int(46 * s))
            d.rectangle(box, fill=P.ACCENT if b else P.PAPER, outline=P.ACCENT if b else P.LINE)
    elif step >= 1:
        st.text(d, (cx, L.cpu[1] + int(28 * s)), "one worker per thread", scr.f_tiny, P.MUTED, "ma")

    if live(st):
        return
    # ---- explained: the panel and the strip
    title = ["WHAT CAN BE TESTED", "STRESS TEST", "STRESS TEST", "STRESS TEST",
             "PATTERN TEST", "RESULT"][step]
    box = st.panel_title(d, title, NOTE)
    if step == 0:
        y = rows(st, d, box, [("Installed", "16,384 MB"), ("Free right now", "14,000 MB"),
                              ("Kept back", "- 512 MB"), ("Tested, 75 %", "10,116 MB", P.PASS_)],
                 until=int(u * 6))
        if u > 0.75:
            say(st, d, box, y + int(10 * s), "The other 6 GB: Linux, the toolkit and the margin."
                " MemTest86+ tests all of it.", P.WARN_)
    elif step <= 3:
        copied = 2.4 * ((step - 1) * 8 + st.lt)
        rows(st, d, box, [("Engine", "stressapptest"), ("Workers", "8, one a thread"),
                          ("Copied so far", "%.0f GB" % copied), ("Miscompares", "0", P.PASS_),
                          ("Memory bus", "flat out" if step == 3 else "busy")])
    elif step == 4:
        rows(st, d, box, [("Engine", "memtester"), ("Pattern", PATTERNS[int(T / 1.1) % len(PATTERNS)][0]),
                          ("Pass", "1 of 1"), ("Failures", "0", P.PASS_)])
    else:
        y = rows(st, d, box, [("Errors found", "1", P.FAIL_), ("At address", "0x2F3A1C40")])
        if u > 0.25:
            st.badge(d, box[0], y + int(6 * s), "FAIL", P.FAIL_)
            say(st, d, box, y + int(52 * s), "Reseat the modules and retest, then test one module "
                "at a time.", P.FAIL_)

    st.addr_strip(d, "0", "16 GB installed", "Installed memory")
    sx0, by0, sx1, by1 = st._sb
    k = frac * (ease(seg(u, 0.15, 0.85)) if step == 0 else 1.0)
    st.strip_fill(d, 0, k, P.DATA)
    hx = int(lerp(sx0, sx1, frac))
    hatch(st, d, (hx, by0 + 2, sx1 - 2, by1 - 2), P.LINE, max(5, int(8 * s)))
    if step == 4:
        mx = int(lerp(sx0, sx1, frac / 2))
        d.line([mx, by0 - int(3 * s), mx, by1 + int(3 * s)], fill=P.INK, width=max(2, int(3 * s)))
        note(st, d, ((sx0 + mx) // 2, (by0 + by1) // 2), "half A", P.INK, "mm")
        note(st, d, ((mx + hx) // 2, (by0 + by1) // 2), "half B", P.INK, "mm")
    elif k > 0.3:
        note(st, d, ((sx0 + hx) // 2, (by0 + by1) // 2), "tested from inside Linux", P.INK, "mm")
    note(st, d, ((hx + sx1) // 2, (by0 + by1) // 2), "in use: MemTest86+", P.MUTED, "mm")


# ---------------------------------------------------------------- CPU
def cpu_explained(step, u):
    """(temperature C, clock MHz, throttle events, loaded) for the example: a
    machine that runs hot and throttles once."""
    if step == 0:
        return 41.0, 800, 0, False
    if step == 1:
        return lerp(41, 74, ease(u)), 3900, 0, True
    if step == 2:
        return lerp(74, 85, ease(u)), 3900, 0, True
    if step == 3:
        if u < 0.55:
            return lerp(85, 94, ease(u / 0.55)), 3900, 0, True
        return lerp(94, 89, ease((u - 0.55) / 0.45)), 2600, 1, True
    return lerp(89, 51, ease(u)), 800, 1, False


def lay_cpu(st):
    s = st.s
    x0, y0, x1, y1 = st.area
    W, H = x1 - x0, y1 - y0
    L = NS()
    L.therm = (x0 + int(10 * s), y0 + int(30 * s), x0 + int(26 * s), y1 - int(36 * s))
    side = min(H - int(20 * s), int(W * 0.40))
    px0 = L.therm[2] + int(W * 0.075)
    py0 = y0 + (H - side) // 2 + int(6 * s)
    L.pkg = (px0, py0, px0 + side, py0 + side)
    dm = int(side * 0.15)
    L.die = (px0 + dm, py0 + dm, px0 + side - dm, py0 + side - dm)
    dx0, dy0, dx1, dy1 = L.die
    ins, g = int(8 * s), int(7 * s)
    top = dy0 + ins + int(16 * s)
    cw, ch = (dx1 - dx0 - 2 * ins - g) // 2, (dy1 - top - ins - g) // 2
    L.cores = [(dx0 + ins + c * (cw + g), top + r * (ch + g), dx0 + ins + c * (cw + g) + cw,
                top + r * (ch + g) + ch) for r in range(2) for c in range(2)]
    L.bh = max(int(16 * s), int(min(ch * 0.66, cw * 0.70)))
    pm = int(9 * s)
    L.plate = (dx0 - pm, dy0 - pm, dx1 + pm, dy1 + pm)
    L.sensor = (dx0 + int(8 * s), dy1 - int(8 * s))
    # the cooler: the fin stack at the vent, the fan beside it, the pipe over
    # it, and room past the fins for the hot air to leave
    L.vent = x1 - int(W * 0.07)
    L.fins = (L.vent - int(W * 0.075), y0 + int(H * 0.08), L.vent, y0 + int(H * 0.86))
    r = int(min(H * 0.25, W * 0.11))
    L.fan = (L.fins[0] - int(14 * s) - r, y0 + int(H * 0.62), r)
    py = y0 + int(H * 0.19)
    my = (dy0 + dy1) // 2
    jx = L.plate[2] + int(min(W * 0.06, 34 * s))
    L.pipe = [(L.plate[2] - int(14 * s), my), (jx, my), (jx, py), (L.fins[2] - int(6 * s), py)]
    L.heat = [(dx1 - int(4 * s), my), (jx, my), (jx, py), (L.fins[2] - int(6 * s), py)]
    return L


def therm_y(L, temp):
    return lerp(L.therm[3], L.therm[1], clamp((temp - 30) / 75.0))


def static_cpu(st, d, L):
    P, s, scr = st.P, st.s, st.scr
    lw = max(1, int(2 * s))
    # the thermometer, marked where the CPU test judges
    tx0, ty0, tx1, ty1 = L.therm
    rb = int((tx1 - tx0) * 0.95)
    cx = (tx0 + tx1) // 2
    d.ellipse([cx - rb, ty1 - rb // 2, cx + rb, ty1 + rb + rb // 2], fill=P.PAPER, outline=P.INK, width=lw)
    rr(st, d, (tx0, ty0, tx1, ty1 + rb // 2), fill=P.PAPER, outline=P.INK, width=lw, r=(tx1 - tx0) // 2)
    for v, col in ((40, P.LINE), (60, P.LINE), (80, P.LINE), (90, P.WARN_), (97, P.FAIL_)):
        y = therm_y(L, v)
        d.line([tx1 + int(3 * s), y, tx1 + int(10 * s), y], fill=col if v >= 90 else P.MUTED, width=lw)
        if v >= 90:
            st.text(d, (tx1 + int(13 * s), y), "%d" % v, scr.f_tiny, col, "lm")
    # the package, the cold plate over the die, the heat pipe
    rr(st, d, L.pkg, fill=P.BOARD, outline=P.MUTED, width=lw, r=int(6 * s))
    x0, y0, x1, y1 = L.pkg
    for k in range(6):
        cxk = lerp(x0 + 18 * s, x1 - 18 * s, k / 5.0)
        d.rectangle([cxk - 4 * s, y1 - 11 * s, cxk + 4 * s, y1 - 6 * s], fill=P.GOLD)
    note(st, d, (x0 + int(8 * s), y0 + int(5 * s)), "CPU package")
    cu = copper(P)
    d.line(L.pipe, fill=cu, width=max(5, int(11 * s)), joint="curve")
    dashed_box(st, d, L.plate, cu)
    note(st, d, (L.pipe[2][0] + int(10 * s), L.pipe[2][1] - int(12 * s)), "heat pipe", anchor="ld")
    note(st, d, (L.plate[2], L.plate[1] - int(3 * s)), "cold plate", anchor="rd")
    # fins and fan housing
    fx0, fy0, fx1, fy1 = L.fins
    note(st, d, ((fx0 + fx1) // 2, fy1 + int(4 * s)), "fins", anchor="ma")
    note(st, d, (st.area[2], L.fan[1] + int(L.fan[2] * 0.62)), "air out", anchor="ra")
    fcx, fcy, fr = L.fan
    d.ellipse([fcx - fr, fcy - fr, fcx + fr, fcy + fr], fill=P.PAPER, outline=P.MUTED, width=lw)
    note(st, d, (fcx, fcy + fr + int(4 * s)), "fan", anchor="ma")
    dashed(st, d, [L.sensor, (tx1 + int(12 * s), L.sensor[1])], P.LINE)
    st.text(d, (st.strip_box[2], st.strip_box[1]), "robot = the stress-ng workers on one core",
            scr.f_tiny, P.MUTED, "ra")


def scene_cpu(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    L = st.lay("cpu")
    st.bot_size(L.bh)
    T = st.clock if live(st) else t
    temp, mhz, thr, busy = cpu_explained(step, u)
    if live(st):
        tv = fact(st, "temperature now")
        temp = number(tv) if tv and "no sensor" not in tv else None
        mhz = number(fact(st, "clock speed"))
        thr = int(number(fact(st, "throttle events"), 0))
        busy = 1 <= step <= 3
    vis = temp if temp is not None else 55.0
    hot = clamp((vis - 40) / 50.0)
    slow = thr > 0 and busy and (live(st) or (step == 3 and u >= 0.55))

    # the die and its cores, the colour of their temperature
    die = heat(P, temp)
    rr(st, d, L.die, fill=die, outline=P.INK, width=max(1, int(2 * s)), r=int(5 * s))
    st.text(d, ((L.die[0] + L.die[2]) // 2, L.die[1] + int(4 * s)), "die", scr.f_tiny, P.INK, "ma")
    for i, c in enumerate(L.cores):
        rr(st, d, c, fill=mix(die, P.PAPER, 0.35), outline=P.ACCENT if busy else P.LINE,
              width=max(1, int(2 * s)) if busy else 1, r=int(3 * s))
        x = c[0] + (c[2] - c[0]) * 0.40
        y = c[3] - int(3 * s)
        if busy:
            on = int(T * (2 if slow else 5) + i) % 2
            st.bot((x, y), (P.WARN_ if slow else P.ACCENT) if on else P.DATA, i, True)
        else:
            st.bot((x, y), None, i, False, "sleep" if step == 0 else "")
    st.dot(d, L.sensor, max(2, int(4 * s)), P.INK)

    # heat out along the pipe, through the fins, away on the fan's air
    if busy or vis > 50:
        col = mix(P.WARN_, P.FAIL_, clamp((vis - 70) / 25.0))
        flow(st, d, L.heat, T, 0.18 + 0.30 * hot, int(2 + 9 * hot), col, max(2, int(4 * s)))
    fx0, fy0, fx1, fy1 = L.fins
    fin = heat(P, vis - 22)
    n = 9
    for k in range(n):
        x = lerp(fx0, fx1, (k + 0.5) / n)
        d.rectangle([x - max(1, 1.5 * s), fy0, x + max(1, 1.5 * s), fy1], fill=fin)
    fcx, fcy, fr = L.fan
    spin = (0.6 + 4.0 * hot) if (busy or vis > 45) else 0.4
    ang = T * spin
    for k in range(9):
        a = ang + k * 2 * math.pi / 9
        pts = [(fcx + math.cos(a + o) * fr * rr, fcy + math.sin(a + o) * fr * rr)
               for o, rr in ((0.0, 0.30), (0.30, 0.62), (0.52, 0.88))]
        d.line(pts, fill=P.MUTED, width=max(2, int(fr * 0.07)), joint="curve")
    d.ellipse([fcx - fr * 0.28, fcy - fr * 0.28, fcx + fr * 0.28, fcy + fr * 0.28], fill=P.INK)
    # the fan's air, through the fins and out of the vent, warmer as it works
    air = mix(mix(P.ACCENT, P.PAPER, 0.45), P.WARN_, hot)
    ax1 = st.area[2] - int(4 * s)
    na = 3 + int(3 * hot)
    for j, row in enumerate((-0.40, 0.0, 0.40)):
        y = fcy + row * fr
        for k in range(na):
            f = (T * (0.30 + 0.5 * hot) + k / float(na) + j * 0.17) % 1.0
            xa = lerp(fcx + fr * 0.95, ax1 - 10 * s, f)
            d.line([xa, y, xa + 8 * s, y], fill=air, width=max(2, int(3 * s)))
    arrow(st, d, (L.vent + int(6 * s), fcy), (ax1, fcy), air)

    # the thermometer's fill, and the reading every 2 s
    tx0, ty0, tx1, ty1 = L.therm
    m = max(2, int(3 * s))
    cx = (tx0 + tx1) // 2
    rb = int((tx1 - tx0) * 0.95)
    fill = heat(P, temp) if temp is not None else P.LINE
    if temp is not None:
        fy = therm_y(L, temp)
        d.rectangle([tx0 + m, fy, tx1 - m, ty1 + rb // 2], fill=fill)
    d.ellipse([cx - rb + m, ty1 - rb // 2 + m, cx + rb - m, ty1 + rb + rb // 2 - m], fill=fill)
    st.tag(d, (cx + int(8 * s), ty0 - int(18 * s)),
           ("%d C" % round(temp)) if temp is not None else "no sensor",
           bg=P.FAIL_ if (temp or 0) >= 95 else P.WARN_ if (temp or 0) >= 85 else P.INK)
    if live(st) or step in (0, 3):
        ph = (T % 2.0) / 0.6
        if ph < 1.0:
            st.dot(d, st.along([L.sensor, (tx1 + int(12 * s), L.sensor[1])], ph), max(2, int(4 * s)),
                   P.ACCENT)
    # the clock, under the die
    if mhz:
        txt = "%s MHz" % thousands(mhz)
        if slow:
            txt += " - throttled" + (" %dx" % thr if live(st) and thr > 1 else "")
        st.tag(d, ((L.pkg[0] + L.pkg[2]) / 2, (L.die[3] + L.pkg[3]) / 2 - int(4 * s)), txt,
               bg=P.WARN_ if slow else P.INK)

    if live(st):
        return
    # ---- explained
    if step == 2:
        k = min(3, int(u * 4))
        where = [(L.plate[2], L.plate[1] - int(12 * s), "1  paste -> cold plate"),
                 (L.pipe[2][0], L.pipe[2][1] - int(30 * s), "2  along the heat pipe"),
                 (L.fins[0], L.fins[1] - int(2 * s), "3  into the fins"),
                 (L.fins[0], L.fan[1] + L.fan[2] + int(26 * s), "4  out on the fan's air")][k]
        st.tag(d, (min(where[0], st.area[2] - int(70 * s)), max(st.area[1] + int(10 * s), where[1])),
               where[2], bg=P.INK)
    title = ["IDLE BASELINE", "UNDER LOAD", "UNDER LOAD", "UNDER LOAD", "RESULT"][step]
    box = st.panel_title(d, title, NOTE)
    tone = P.FAIL_ if temp >= 95 else P.WARN_ if temp >= 85 else P.PASS_
    if step == 0:
        y = rows(st, d, box, [("Sensor", "coretemp"), ("Temperature", "41 C"),
                              ("Clock speed", "800 MHz"), ("Throttle count", "0")])
        say(st, d, box, y + int(8 * s), "Five readings, 2 s apart.", P.MUTED)
    elif step <= 3:
        el = int(((step - 1) * 8 + st.lt) * 12)
        peak = 94 if (step == 3 and u >= 0.55) else temp
        rows(st, d, box, [("Temperature now", "%d C" % temp, tone), ("Max so far", "%d C" % peak),
                          ("Clock speed", "%s MHz" % thousands(mhz), P.WARN_ if slow else None),
                          ("Throttle events", "%d" % thr, P.WARN_ if thr else P.PASS_),
                          ("Elapsed", "%d:%02d of 10:00" % (el // 60, el % 60))])
    else:
        y = rows(st, d, box, [("Peak", "94 C", P.WARN_), ("5 s after", "%d C" % temp)])
        if u > 0.3:
            st.badge(d, box[0], y + int(6 * s), "MARGINAL", P.WARN_)
            y += int(50 * s)
            for txt, col in (("under 90 C: PASS", P.PASS_), ("90 to 96 C: MARGINAL", P.WARN_),
                             ("97 C and up: FAIL", P.FAIL_)):
                st.text(d, (box[0], y), txt, scr.f_small, col)
                y += int(24 * s)
    # strip: the temperature through the test
    st.addr_strip(d, "start", "now", "Temperature through the test")
    sx0, by0, sx1, by1 = st._sb
    beats = SCENES[NAMES.index("cpu")][3]
    tot = sa.total(beats)
    pts = []
    k = 0.0
    while k <= t + 1e-6:
        stp, uu = sa.locate(beats, k)
        tc = cpu_explained(stp, uu)[0]
        pts.append((lerp(sx0, sx1, k / tot), lerp(by1 - 2, by0 + 2, clamp((tc - 30) / 75.0))))
        k += 0.25
    for v, col in ((90, P.WARN_), (97, P.FAIL_)):
        yy = lerp(by1 - 2, by0 + 2, (v - 30) / 75.0)
        dashed(st, d, [(sx0 + 2, yy), (sx1 - int(34 * s), yy)], col, max(1, int(s)))
    note(st, d, (sx1 - int(4 * s), by0 + int(2 * s)), "90 / 97", P.WARN_, "ra")
    if len(pts) > 1:
        d.line(pts, fill=P.ACCENT, width=max(2, int(2 * s)), joint="curve")


# ---------------------------------------------------------------- battery
def bat_explained(step, u):
    """(charge %, charging, plug position 0 in .. 1 out) for the example."""
    if step == 0:
        return lerp(72, 100, ease(u)), True, 0.0
    if step == 1:
        out = ease(seg(u, 0.2, 0.45))
        return 100.0, out < 0.5, out
    if step == 2:
        return lerp(100, 64, u), False, 1.0
    if step == 3:
        return lerp(64, 8, u), False, 1.0
    return lerp(8, 0, ease(u)), False, 1.0


def lay_battery(st):
    s = st.s
    x0, y0, x1, y1 = st.area
    W, H = x1 - x0, y1 - y0
    L = NS()
    L.lap = (x0 + int(W * 0.17), y0 + int(22 * s), x1, y1 - int(4 * s))
    lx0, ly0, lx1, ly1 = L.lap
    LH = ly1 - ly0
    L.jy = ly0 + int(LH * 0.26)
    L.jack = (lx0 - int(5 * s), L.jy - int(11 * s), lx0 + int(16 * s), L.jy + int(11 * s))
    L.tip_in, L.tip_out = lx0 + int(3 * s), lx0 - int(W * 0.08)
    L.chg = (lx0 + int(W * 0.07), L.jy - int(H * 0.10), lx0 + int(W * 0.25), L.jy + int(H * 0.10))
    L.cpu = (lx0 + int(W * 0.07), ly0 + int(LH * 0.50), lx0 + int(W * 0.31), ly1 - int(12 * s))
    L.pack = (x1 - int(W * 0.37), ly0 + int(22 * s), x1 - int(12 * s), ly1 - int(12 * s))
    px0, py0, px1, py1 = L.pack
    gap, gh = int(10 * s), int(30 * s)
    cw = (px1 - px0 - 4 * gap) / 3.0
    L.cells = [(int(px0 + gap + k * (cw + gap)), py0 + int(26 * s), int(px0 + gap + k * (cw + gap) + cw),
                py1 - gh - 2 * gap) for k in range(3)]
    L.gauge = (px0 + gap, py1 - gh - gap, px0 + gap + int((px1 - px0) * 0.40), py1 - gap)
    L.sy = ly1 - int(LH * 0.16)
    L.stick = (x0 + int(W * 0.03), L.sy - int(11 * s), lx0 + int(8 * s), L.sy + int(11 * s))
    cy = (L.cpu[1] + L.cpu[3]) // 2
    L.p_in = [(lx0 + int(16 * s), L.jy), (L.chg[0], L.jy)]
    L.p_cell = [(L.chg[2], L.jy), (px0, L.jy)]
    L.p_out = [(px0, cy), (L.cpu[2], cy)]
    L.p_log = [(L.cpu[0], cy + int(10 * s)), (L.cpu[0] - int(14 * s), cy + int(10 * s)),
               (L.cpu[0] - int(14 * s), L.sy), (L.stick[2], L.sy)]
    L.bh = max(int(18 * s), int(min((L.cpu[3] - L.cpu[1]) * 0.55, (L.cpu[2] - L.cpu[0]) * 0.32)))
    return L


def static_battery(st, d, L):
    P, s, scr = st.P, st.s, st.scr
    lw = max(1, int(2 * s))
    rr(st, d, L.lap, fill=P.PAPER, outline=P.MUTED, width=lw, r=int(10 * s))
    heading(st, d, (L.lap[0] + int(12 * s), L.lap[1] - int(6 * s)), "THIS LAPTOP", "ld")
    for p in (L.p_in, L.p_cell, L.p_out):
        d.line(p, fill=P.LINE, width=max(3, int(5 * s)))
    dashed(st, d, L.p_log, P.LINE)
    d.rectangle(L.jack, fill=P.INK)
    note(st, d, (L.jack[0] + int(2 * s), L.jack[3] + int(4 * s)), "DC jack")
    part(st, d, L.chg, None, P.CHIP, P.INK)
    st.text(d, ((L.chg[0] + L.chg[2]) // 2, (L.chg[1] + L.chg[3]) // 2), "charge circuit",
            scr.f_tiny, P.INK, "mm")
    part(st, d, L.cpu, "CPU", P.CHIP, P.INK, "the load while it drains")
    rr(st, d, L.pack, fill=P.CHIP, outline=P.INK, width=lw, r=int(8 * s))
    st.text(d, (L.pack[0] + int(10 * s), L.pack[1] + int(5 * s)), "BATTERY PACK", scr.f_noteb, P.INK)
    rr(st, d, L.gauge, fill=P.BOARD, outline=P.MUTED, r=int(3 * s))
    st.text(d, ((L.gauge[0] + L.gauge[2]) // 2, (L.gauge[1] + L.gauge[3]) // 2), "gauge chip",
            scr.f_tiny, P.INK, "mm")
    # the USB stick that keeps the log
    sx0, sy0, sx1, sy1 = L.stick
    d.rectangle([sx1 - int(16 * s), sy0 + int(4 * s), sx1, sy1 - int(4 * s)], fill=P.MUTED)
    rr(st, d, (sx0, sy0, sx1 - int(16 * s), sy1), fill=P.INK, r=int(4 * s))
    note(st, d, (sx0, sy1 + int(4 * s)), "USB stick: the log", anchor="la")
    st.text(d, (st.strip_box[2], st.strip_box[1]), "robot = load on the CPU while it drains",
            scr.f_tiny, P.MUTED, "ra")


def scene_battery(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    L = st.lay("battery")
    st.bot_size(L.bh)
    T = st.clock if live(st) else t
    level, charging, out = bat_explained(step, u)
    load = "full" if 2 <= step <= 3 else "idle"
    watts = 14.0
    if live(st):
        lv = number(fact(st, "charge level"))
        level = lv if lv is not None else level
        status = (fact(st, "status") or "").lower()
        if status:
            charging = status.startswith("charging")
            out = 1.0 if status.startswith("discharging") else 0.0
        else:
            charging, out = step == 0, (0.0 if step == 0 else 1.0)
        if line_with(st, "reconnected"):
            out = 0.0
        load = (fact(st, "load") or "idle").split()[0].lower()
        if step < 2:
            load = "idle"
        watts = number(fact(st, "drawing now"), 6.0)
    lv = clamp(level / 100.0)
    plugged = out < 0.5

    # the plug, and the cable to the charger off to the left
    tip = lerp(L.tip_in, L.tip_out, out)
    back = barrel_plug(st, d, tip, L.jy)
    d.line([(st.area[0], L.jy + int(10 * s)), (st.area[0] + int(10 * s), L.jy + int(4 * s)), back],
           fill=P.INK, width=max(2, int(4 * s)), joint="curve")
    note(st, d, (st.area[0], L.jy - int(16 * s)), "charger", anchor="ld")
    # power: in through the charge circuit, or out of the cells to the CPU
    if plugged and charging:
        flow(st, d, L.p_in, T, 0.9, 3, P.ACCENT)
        flow(st, d, L.p_cell, T, 0.7, 4, P.ACCENT)
    elif plugged:
        flow(st, d, L.p_in, T, 0.9, 3, P.ACCENT)          # full: the charger runs the laptop
    else:
        flow(st, d, L.p_out, T, 0.25 + 0.04 * min(watts or 6.0, 30), 4, P.ACCENT)
    # the cells, filled to the charge level, the gauge's reading beside them
    col = charge_col(P, lv)
    for k, c in enumerate(L.cells):
        battery_cell(st, d, c, lv, col)
        if plugged and charging and lv < 0.995:
            top = c[3] - (c[3] - c[1]) * lv
            ph = (T * 1.4 + k * 0.3) % 1.0
            d.line([c[0] + int(5 * s), top - ph * 8 * s, c[2] - int(5 * s), top - ph * 8 * s],
                   fill=mix(col, P.PAPER, ph), width=max(1, int(2 * s)))
    st.text(d, (L.gauge[2] + int(10 * s), (L.gauge[1] + L.gauge[3]) // 2), "%d %%" % round(level),
            scr.f_noteb, P.INK, "lm")
    if step == 3 and not live(st):
        # what the gauge claims a full charge is, against the cells' design size
        for c in L.cells:
            y = c[3] - (c[3] - c[1]) * 0.85
            d.line([c[0] - int(3 * s), y, c[2] + int(3 * s), y], fill=P.WARN_, width=max(2, int(2 * s)))
        c = L.cells[0]
        note(st, d, (c[0], c[3] - (c[3] - c[1]) * 0.85 - int(4 * s)), "gauge: full", P.WARN_, "ld")
    # the CPU's load, as robots
    cx0, cy0, cx1, cy1 = L.cpu
    for k in range(2):
        x = lerp(cx0, cx1, 0.30 + k * 0.36)
        y = cy1 - int(5 * s)
        on = (load == "full") or (load == "light" and k == 0)
        if step == 4 and not live(st) and u > 0.5:
            st.bot((x, y), None, k, False, "sleep")
        elif on and not plugged:
            st.bot((x, y), P.ACCENT if int(T * 4 + k) % 2 else P.DATA, k, True)
        else:
            st.bot((x, y), None, k, False, "")
    # a sample to the stick every 30 s (every 3 s here)
    if step == 2 and not live(st):
        v = (T % 3.0) / 1.2
        if v < 1.0:
            packet(st, d, L.p_log, v, label="sample" if v < 0.5 else None)
    ay = L.jy - int(28 * s)
    if not live(st) and step == 1 and 0.05 < out < 0.95:
        arrow(st, d, (L.tip_in - int(20 * s), ay), (L.tip_out - int(24 * s), ay), P.ACCENT)
    if live(st) and step == 1 and plugged:
        arrow(st, d, (L.tip_in - int(20 * s), ay), (L.tip_out - int(24 * s), ay), P.ACCENT)
    if live(st) and step == 0 and not plugged:
        arrow(st, d, (L.tip_out - int(30 * s), ay), (L.tip_in - int(26 * s), ay), P.ACCENT)

    if live(st):
        return
    # ---- explained
    title = ["STEP 1 OF 3", "STEP 2 OF 3", "STEP 3 OF 3", "THE ACCOUNT", "RESULT"][step]
    box = st.panel_title(d, title, NOTE)
    if step == 0:
        rows(st, d, box, [("Charge level", "%d %%" % level, P.ACCENT), ("Status", "Charging"),
                          ("Design capacity", "45.0 Wh"), ("Gauge says full", "38.2 Wh")])
    elif step == 1:
        rows(st, d, box, [("Charge level", "100 %", P.ACCENT),
                          ("Status", "Discharging" if not plugged else "Full", P.PASS_ if not plugged else None)])
    elif step == 2:
        used = 45.0 * (1 - lv) * 0.85
        rows(st, d, box, [("Load", "full"), ("Drawing now", "14.2 W"),
                          ("Energy used", "%.1f Wh" % used), ("Samples on the stick", "%d" % int(st.lt * 9))])
    elif step == 3:
        rows(st, d, box, [("Design capacity", "45.0 Wh"), ("Gauge claims full", "38.2 Wh"),
                          ("Delivered", "%.1f Wh" % lerp(13.0, 35.0, u), P.ACCENT)])
    else:
        y = rows(st, d, box, [("Delivered", "35.6 Wh"), ("Of the design", "79 %", P.WARN_),
                              ("Of the gauge's claim", "93 %", P.PASS_)])
        if u > 0.3:
            st.badge(d, box[0], y + int(6 * s), "WORN", P.WARN_)
            say(st, d, box, y + int(52 * s), "Serviceable - plan a replacement.", P.WARN_)
    # strip: the energy that came out, against the design and the gauge
    got = [0.0, 0.0, lerp(0, 13.0, u), lerp(13.0, 35.0, u), lerp(35.0, 35.6, ease(u))][step]
    st.addr_strip(d, "0 Wh", "45.0 Wh design", "Energy delivered - counted from the pack's own readings")
    sx0, by0, sx1, by1 = st._sb
    st.strip_fill(d, 0, got / 45.0, P.DATA)
    gx = int(lerp(sx0, sx1, 38.2 / 45.0))
    d.line([gx, by0 - int(4 * s), gx, by1 + int(4 * s)], fill=P.WARN_, width=max(2, int(2 * s)))
    note(st, d, (gx - int(4 * s), (by0 + by1) // 2), "gauge: full", P.WARN_, "rm")
    if step == 4:
        for f, lab, col in ((0.60, "60 %", P.FAIL_), (0.80, "80 %", P.PASS_)):
            x = int(lerp(sx0, sx1, f))
            d.line([x, by0, x, by1], fill=col, width=max(2, int(2 * s)))
            note(st, d, (x + int(4 * s), by0 + int(2 * s)), lab, col)


# ---------------------------------------------------------------- charging
def chg_explained(step, u, T):
    """(plug out 0..1, plug wiggle angle, connected, charging, watts, drops,
    USB-C plug in 0..1) for the example."""
    if step == 0:
        out = ease(seg(u, 0.15, 0.40))
        return out, 0.0, out < 0.5, out < 0.5, 0.0, 0, 0.0
    if step == 1:
        out = 1 - ease(seg(u, 0.10, 0.35))
        return out, 0.0, out < 0.5, u > 0.5, 0.0, 0, 0.0
    if step == 2:
        return 0.0, 0.0, True, True, 28.5 + 0.6 * math.sin(T * 1.7), 0, 0.0
    if step == 3:
        drop = 0.42 <= u < 0.50
        ang = 0.11 * math.sin(T * 2 * math.pi * 1.3) + (0.10 if drop else 0.0)
        return 0.0, ang, not drop, not drop, 0.0 if drop else 27.9, 1 if u >= 0.42 else 0, 0.0
    q = ease(seg(u, 0.05, 0.30))
    return 1.0, 0.0, q >= 1.0, u > 0.55, 26.0 if u > 0.55 else 0.0, 0, q


def lay_charge(st):
    s = st.s
    x0, y0, x1, y1 = st.area
    W, H = x1 - x0, y1 - y0
    L = NS()
    L.brick = (x0 + int(12 * s), y0 + int(H * 0.10), x0 + int(W * 0.17), y0 + int(H * 0.40))
    L.lap = (x0 + int(W * 0.38), y0 + int(22 * s), x1, y1 - int(4 * s))
    lx0, ly0, lx1, ly1 = L.lap
    LH = ly1 - ly0
    L.jy = ly0 + int(LH * 0.26)
    L.jack = (lx0 - int(5 * s), L.jy - int(11 * s), lx0 + int(16 * s), L.jy + int(11 * s))
    L.tip_in, L.tip_out = lx0 + int(3 * s), lx0 - int(W * 0.09)
    L.cy = [ly0 + int(LH * 0.62), ly0 + int(LH * 0.82)]
    L.cports = [(lx0 - int(4 * s), y - int(7 * s), lx0 + int(12 * s), y + int(7 * s)) for y in L.cy]
    L.chg = (lx0 + int(W * 0.08), L.jy - int(H * 0.10), lx0 + int(W * 0.26), L.jy + int(H * 0.10))
    L.flag = (L.chg[0], L.chg[3] + int(14 * s), L.chg[2] + int(W * 0.03), L.chg[3] + int(40 * s))
    L.pack = (x1 - int(W * 0.24), ly0 + int(22 * s), x1 - int(12 * s), ly0 + int(LH * 0.80))
    px0, py0, px1, py1 = L.pack
    gap = int(8 * s)
    cw = (px1 - px0 - 4 * gap) / 3.0
    L.cells = [(int(px0 + gap + k * (cw + gap)), py0 + int(26 * s), int(px0 + gap + k * (cw + gap) + cw),
                py1 - gap) for k in range(3)]
    L.p_in = [(lx0 + int(16 * s), L.jy), (L.chg[0], L.jy)]
    L.p_cell = [(L.chg[2], L.jy), (px0, L.jy)]
    L.p_c = [[(lx0 + int(12 * s), y), (L.chg[0] + int(20 * s), y), (L.chg[0] + int(20 * s), L.chg[3])]
             for y in L.cy]
    return L


def static_charge(st, d, L):
    P, s, scr = st.P, st.s, st.scr
    lw = max(1, int(2 * s))
    rr(st, d, L.lap, fill=P.PAPER, outline=P.MUTED, width=lw, r=int(10 * s))
    heading(st, d, (L.lap[0] + int(12 * s), L.lap[1] - int(6 * s)), "THIS LAPTOP", "ld")
    for p in [L.p_in, L.p_cell] + L.p_c:
        d.line(p, fill=P.LINE, width=max(3, int(5 * s)))
    d.rectangle(L.jack, fill=P.INK)
    note(st, d, (L.jack[0] + int(2 * s), L.jack[3] + int(4 * s)), "DC jack")
    for k, c in enumerate(L.cports):
        rr(st, d, c, fill=P.INK, r=int(5 * s))
        note(st, d, (c[2] + int(6 * s), (c[1] + c[3]) // 2), "USB-C %d" % (k + 1), anchor="lm")
    rr(st, d, L.chg, fill=P.CHIP, outline=P.INK, width=lw)
    st.text(d, ((L.chg[0] + L.chg[2]) // 2, (L.chg[1] + L.chg[3]) // 2), "charge circuit",
            scr.f_tiny, P.INK, "mm")
    rr(st, d, L.pack, fill=P.CHIP, outline=P.INK, width=lw, r=int(8 * s))
    st.text(d, (L.pack[0] + int(10 * s), L.pack[1] + int(5 * s)), "BATTERY", scr.f_noteb, P.INK)
    # the charger: wall prongs, the brick
    bx0, by0, bx1, by1 = L.brick
    for k in (0.35, 0.65):
        y = lerp(by0, by1, k)
        d.rectangle([bx0 - int(10 * s), y - int(3 * s), bx0, y + int(3 * s)], fill=P.MUTED)
    rr(st, d, L.brick, fill=P.CHIP, outline=P.INK, width=lw, r=int(8 * s))


def scene_charge(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    L = st.lay("charge")
    T = st.clock if live(st) else t
    out, ang, conn, charging, watts, drops, qc = chg_explained(step, u, T)
    pct = 62 + (u if step >= 2 else 0)
    usbc, offer = step == 4, None
    if live(st):
        conn = (fact(st, "charger") or "").lower() == "connected"
        bv = fact(st, "battery") or ""
        charging = "charging" in bv.lower() and "not charging" not in bv.lower()
        # no reading is drawn as none: the example's 62 % once stood on the
        # A40-J's USB-C step as if read from it (1.18.0)
        pct = number(bv)
        pw = fact(st, "power") or ""
        watts = number(pw, 0.0) if "into" in pw else 0.0
        drops = int(number(fact(st, "connection drops"), 0))
        m = re.search(r"\((\d+) W\)", fact(st, "charger offers") or "")
        offer = int(m.group(1)) if m else None
        usbc = usbc or "usbc" in st.opts                          # the charger in is USB-C
        hint = 0.5 - 0.5 * math.cos(T * 2 * math.pi / 1.8)        # the instruction, acted out
        ang, qc = 0.0, 0.0
        if step == 4:
            # the instruction says whether a plug is wanted in a port or out of one
            leaving = line_with(st, "Unplug") is not None
            if fact(st, "charger") is None:
                conn = conn or (leaving and "first" not in (line_with(st, "Unplug") or ""))
            out = 1.0
            qc = 1.0 - 0.45 * hint if leaving else 1.0 if conn else 0.55 * hint
        elif step == 0:
            out = 0.30 * hint if conn else 1.0
        elif step == 1:
            out = 0.0 if conn else 1.0 - 0.55 * hint
        elif step == 3:
            out, ang = 0.0, 0.11 * math.sin(T * 2 * math.pi * 1.3)
        else:
            out = 0.0 if conn else 1.0
        if usbc and step != 4:
            # the same plug and moves, into the first USB-C port
            qc = 1.0 - out - (0.06 * abs(math.sin(T * 2 * math.pi * 1.3)) if step == 3 else 0.0)
    dropped = step == 3 and not conn
    # the cells first, so the tags over the charge path stay on top
    lv = clamp((pct or 0) / 100.0)
    for c in L.cells:
        battery_cell(st, d, c, lv, charge_col(P, lv))
    # the charger brick, and its plug: the barrel for the jack, or USB-C. Live,
    # the wattage is the one the charger offers, or none - never the example's
    bx0, by0, bx1, by1 = L.brick
    top = "USB-C" if usbc else "charger"
    low = (("%d W" % offer) if offer else "charger" if usbc else "") if live(st) else \
        "charger" if usbc else "65 W"
    cx, cy = (bx0 + bx1) // 2, (by0 + by1) // 2
    st.text(d, (cx, cy - int(9 * s) if low else cy), top, scr.f_tiny, P.INK, "mm")
    if low:
        st.text(d, (cx, cy + int(9 * s)), low, scr.f_tiny, P.MUTED, "mm")
    st.dot(d, (bx1 - int(10 * s), by0 + int(10 * s)), max(2, int(3 * s)), P.PASS_)
    start = (bx1, (by0 + by1) // 2)
    # where the plug meets the laptop: the DC jack, or the first USB-C port
    px, py = (L.cports[0][0], L.cy[0]) if usbc else (L.jack[0], L.jy)
    if usbc:
        y = L.cy[0]
        nose = lerp(L.lap[0] - int(70 * s), L.lap[0] + int(4 * s), qc)
        d.rectangle([nose - int(14 * s), y - int(5 * s), nose, y + int(5 * s)], fill=P.MUTED)
        rr(st, d, (nose - int(40 * s), y - int(8 * s), nose - int(14 * s), y + int(8 * s)), fill=P.INK, r=int(4 * s))
        cable(st, d, start, (nose - int(40 * s), y))
        if not live(st) and 0.35 < u < 0.62:
            st.tag(d, (lerp(L.lap[0], L.chg[0], 0.5) + int(30 * s), y - int(24 * s)),
                   "offers 20 V, 3.25 A (65 W)", bg=P.ACCENT)
    else:
        tip = lerp(L.tip_in, L.tip_out, out)
        back = barrel_plug(st, d, tip, L.jy, ang)
        cable(st, d, start, back)
    # the flag the firmware keeps, as the test reads it
    fx0, fy0, fx1, fy1 = L.flag
    col = P.FAIL_ if dropped else P.PASS_ if conn else P.MUTED
    rr(st, d, L.flag, fill=P.PAPER, outline=col, width=max(1, int(2 * s)), r=(fy1 - fy0) // 2)
    st.dot(d, (fx0 + (fy1 - fy0) // 2, (fy0 + fy1) // 2), max(3, int(5 * s)), col)
    txt = "connection dropped" if dropped else "charger connected" if conn else "no charger"
    st.text(d, (fx0 + (fy1 - fy0), (fy0 + fy1) // 2), txt, scr.f_tiny, P.INK if conn or dropped else P.MUTED, "lm")
    note(st, d, (fx0, fy1 + int(4 * s)), "the firmware's flag, read by the test")
    # power into the battery
    if conn and charging:
        sp = 0.4 + 0.02 * min(watts or 15.0, 60)
        flow(st, d, L.p_c[0] if usbc else L.p_in, T, sp + 0.2, 3, P.ACCENT)
        flow(st, d, L.p_cell, T, sp, 4, P.ACCENT)
        if watts and (step >= 2 or live(st)):
            txt = "%.1f W into the battery" % watts
            half = d.textlength(txt, font=scr.f_tiny) / 2 + 8 * s
            st.tag(d, (L.pack[0] - half - 4 * s, L.jy - int(22 * s)), txt, bg=P.INK)
    if dropped:
        bolt(d, px - int(10 * s), py - int(16 * s), int(26 * s), P.FAIL_)
    if step == 3 and drops:
        st.tag(d, (px - int(36 * s), py + int(30 * s)),
               "%d drop%s" % (drops, "" if drops == 1 else "s"), bg=P.FAIL_)
    # the hand's part: a wiggle, or the way the plug should go
    ax_in, ax_out = (L.lap[0] - int(10 * s), L.lap[0] - int(80 * s)) if usbc else \
        (L.tip_in - int(10 * s), L.tip_out - int(10 * s))
    if step == 3:
        y = py - int(30 * s)
        x = ax_in - int(38 * s)
        d.arc([x - int(16 * s), y - int(16 * s), x + int(16 * s), y + int(16 * s)], 200, 340,
              fill=P.ACCENT, width=max(2, int(2 * s)))
    if live(st) and step in (0, 1) and (conn if step == 0 else not conn):
        y = py - int(30 * s)
        arrow(st, d, (ax_in, y) if step == 0 else (ax_out, y), (ax_out, y) if step == 0 else (ax_in, y), P.ACCENT)
    st.text(d, ((L.pack[0] + L.pack[2]) // 2, L.pack[3] + int(4 * s)),
            "no reading" if pct is None else
            "%d %%  %s" % (round(pct), "charging" if (conn and charging) else "not charging"),
            scr.f_tiny, P.INK, "ma")

    # the strip: the connection as the test sees it, 4 times a second
    conns = []
    if live(st):
        hist = remember(st, (conn, dropped))
        j = len(hist) - 1
        for k in range(80):
            tk = st.clock - k * 0.25
            while j > 0 and hist[j][0] > tk:
                j -= 1
            conns.append(hist[j][1] if hist and hist[j][0] <= tk else None)
    else:
        sec = SCENES[NAMES.index("charge")][3][step][0]
        for k in range(80):
            uk = u - k * 0.25 / sec
            if uk < 0:
                conns.append(None)
            else:
                c = chg_explained(step, uk, T)
                conns.append((c[2], step == 3 and not c[2]))
    st.addr_strip(d, "20 s ago", "now", "Charger connection, read 4 times a second")
    sx0, by0, sx1, by1 = st._sb
    w = (sx1 - sx0) / 80.0
    for k, v in enumerate(conns):
        if v is None:
            continue
        x = sx1 - (k + 1) * w
        col = P.FAIL_ if v[1] else P.PASS_ if v[0] else P.LINE
        d.rectangle([x + 1, by0 + int(4 * s), x + w - 1, by1 - int(4 * s)], fill=col)

    if live(st):
        return
    # ---- explained: the panel
    title = ["UNPLUG", "PLUG IN", "CHARGE RATE", "WIGGLE", "USB-C"][step]
    box = st.panel_title(d, title, NOTE)
    if step in (0, 1):
        rows(st, d, box, [("Charger", "connected" if conn else "not connected", P.PASS_ if conn else P.WARN_),
                          ("Battery", "%d %%  %s" % (pct, "Charging" if charging else "Discharging"))])
    elif step == 2:
        rows(st, d, box, [("Time", "%d of 60 s" % int(u * 60)), ("Power", "%.1f W" % watts),
                          ("Normal for 45 Wh", "7 W or more", P.PASS_)])
    elif step == 3:
        y = rows(st, d, box, [("Time", "%d of 30 s" % int(u * 30)),
                              ("Connection drops", "%d" % drops, P.FAIL_ if drops else P.PASS_)])
        if drops:
            say(st, d, box, y + int(8 * s), "A drop while the plug moves: suspect the DC jack, "
                "its solder joints, or the cable.", P.FAIL_)
    else:
        rows(st, d, box, [("USB-C port 1", "charges" if u > 0.55 else "...", P.PASS_ if u > 0.55 else P.MUTED),
                          ("Offered", "20.0 V, 3.25 A" if u > 0.35 else "...")])


# ---------------------------------------------------------------- USB
def usb_speed_word(sp):
    if sp is None:
        return "", ""
    if sp >= 5000:
        return "%g Gbit/s" % (sp / 1000.0), "SuperSpeed - all nine contacts"
    if sp >= 480:
        return "480 Mbit/s", "High Speed - the USB 2 pair only"
    if sp >= 12:
        return "12 Mbit/s", "Full Speed - USB 1.1"
    return "1.5 Mbit/s", "Low Speed"


def parse_speed(text):
    m = re.search(r"(\d+(?:\.\d+)?)\s*(G|M)bit/s", text or "")
    if not m:
        return None
    v = float(m.group(1))
    return v * 1000 if m.group(2) == "G" else v


def lay_usb(st):
    s = st.s
    x0, y0, x1, y1 = st.area
    W, H = x1 - x0, y1 - y0
    L = NS()
    L.edge = (x0, y0 + int(26 * s), x0 + int(W * 0.70), y0 + int(H * 0.29))
    L.ctl = (x0, y0 + int(H * 0.46), x0 + int(W * 0.19), y0 + int(H * 0.86))
    L.sock = (x0 + int(W * 0.33), y0 + int(H * 0.42), x0 + int(W * 0.73), y1 - int(10 * s))
    sx0, sy0, sx1, sy1 = L.sock
    SH = sy1 - sy0
    L.tongue = (sx0 + int(16 * s), sy0 + int(SH * 0.16), sx1 - int(16 * s), sy0 + int(SH * 0.62))
    tx0, ty0, tx1, ty1 = L.tongue
    th, tw = ty1 - ty0, tx1 - tx0
    L.y3, L.y2 = ty0 + int(th * 0.30), ty0 + int(th * 0.74)
    L.w3, L.w2, L.ch = max(5, int(tw * 0.075)), max(9, int(tw * 0.15)), max(4, int(th * 0.16))
    L.c3 = [(int(lerp(tx0 + tw * 0.12, tx1 - tw * 0.12, k / 4.0)), L.y3) for k in range(5)]
    L.c2 = [(int(lerp(tx0 + tw * 0.16, tx1 - tw * 0.16, k / 3.0)), L.y2) for k in range(4)]
    L.n3 = ["RX-", "RX+", "GND", "TX-", "TX+"]
    L.n2 = ["5 V", "D-", "D+", "GND"]
    # the lanes from the controller: the USB 2 pair, the two SuperSpeed pairs
    lx = L.ctl[2]
    o = max(2, int(3 * s))
    L.lane2 = [[(lx, L.y2 + k), (sx0, L.y2 + k)] for k in (-o, o)]
    L.lane3 = [[(lx, L.y3 + k), (sx0, L.y3 + k)] for k in (-3 * o, -o, o, 3 * o)]
    L.read = (sx1 + int(16 * s), sy0)
    return L


def static_usb(st, d, L):
    P, s, scr = st.P, st.s, st.scr
    lw = max(1, int(2 * s))
    heading(st, d, (L.edge[0], L.edge[1] - int(6 * s)), "THIS LAPTOP'S SOCKETS", "ld")
    rr(st, d, L.edge, fill=P.PAPER, outline=P.MUTED, width=lw, r=int(8 * s))
    part(st, d, L.ctl, "USB", P.CHIP, P.INK, "controller")
    for ln in L.lane2 + L.lane3:
        d.line(ln, fill=P.LINE, width=max(2, int(2 * s)))
    note(st, d, (L.ctl[2] + int(6 * s), L.lane3[0][0][1] - int(4 * s)), "SuperSpeed", anchor="ld")
    note(st, d, (L.ctl[2] + int(6 * s), L.lane2[1][0][1] + int(4 * s)), "USB 2", anchor="la")
    heading(st, d, ((L.sock[0] + L.sock[2]) // 2, L.sock[1] - int(6 * s)), "LOOKING INTO A USB 3 SOCKET", "md")
    rr(st, d, L.sock, fill=P.CHIP, outline=P.INK, width=max(2, int(3 * s)), r=int(6 * s))
    rr(st, d, L.tongue, fill=mix(P.ACCENT, P.PAPER, 0.25), outline=P.INK, width=1, r=int(3 * s))
    note(st, d, ((L.tongue[0] + L.tongue[2]) // 2, L.tongue[3] + int(6 * s) + L.ch),
         "a blue tongue: a USB 3 socket", anchor="ma")


def usb_sockets(st):
    """Live: the sockets the test lists, (A or C, where, state) in its order."""
    out = []
    for lab, (val, tone) in (st.facts or {}).items():
        m = re.match(r"usb-(a|c)\s+(.*)", lab)
        if m:
            state = {"ok": "in", "warn": "slow", "muted": "done", "accent": "start"}.get(tone, "in")
            out.append((m.group(1).upper(), m.group(2).strip(), state))
    return out


def scene_usb(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    L = st.lay("usb")
    T = st.clock if live(st) else t
    if live(st):
        socks = usb_sockets(st)
        cur = next((i for i, k in enumerate(socks) if k[2] in ("in", "slow")), None)
        slow = cur is not None and socks[cur][2] == "slow"
        speed = None
        if cur is not None:
            # the device's headline line carries its speed: the held-back one for
            # a held-back socket, the first full-speed one otherwise
            for _, text, _ in st.lines:
                sp = parse_speed(text)
                if sp is not None and ("held back" in text) == slow:
                    speed = sp
                    break
        plug = 1.0 if cur is not None else 0.5 - 0.5 * math.cos(T * 2 * math.pi / 2.0)
        target = cur if cur is not None else next((i for i, k in enumerate(socks) if k[2] != "done"), 0)
        lit_power = lit2 = cur is not None
        lit3 = cur is not None and speed is not None and speed >= 5000
        bad3 = slow
    else:
        socks = [("A", "1", "todo"), ("A", "2", "todo"), ("C", "3", "start")]
        target = 1 if step == 3 else 0
        plug = [ease(u) * 0.85, 1.0 if u > 0.15 else lerp(0.85, 1.0, u / 0.15), 1.0, 1.0,
                1.0 - ease(seg(u, 0.1, 0.5))][step]
        lit_power = step in (2, 3) or (step == 1 and u > 0.25)
        lit2 = step in (2, 3) or (step == 1 and u > 0.40)
        lit3 = step == 2 or (step == 1 and u > 0.60)
        bad3 = step == 3
        speed = None if step in (0, 4) or (step == 1 and u < 0.75) else (480 if step == 3 else 5000)
        if step >= 2:
            socks[0] = ("A", "1", "in" if step == 2 else "done")
        if step >= 3:
            socks[1] = ("A", "2", "slow")
        if step == 4:
            socks[0] = ("A", "1", "done" if u > 0.5 else "in")
        cur = target
    # this laptop's sockets along its edge
    ex0, ey0, ex1, ey1 = L.edge
    show = list(socks[:7])
    if not live(st) and step == 0:
        show += [("int", "camera", "ghost"), ("int", "Bluetooth", "ghost")]
    slot_w = (ex1 - ex0) / float(max(1, len(show)) + 0.4)
    if not show:
        note(st, d, ((ex0 + ex1) // 2, (ey0 + ey1) // 2), "plug a device into any socket", P.MUTED, "mm")
    for i, (kind, name, state) in enumerate(show):
        cx = ex0 + slot_w * (i + 0.7)
        cy = ey0 + (ey1 - ey0) * 0.42
        w, h = (int(34 * s), int(14 * s)) if kind != "C" else (int(26 * s), int(11 * s))
        box = (int(cx - w / 2), int(cy - h / 2), int(cx + w / 2), int(cy + h / 2))
        col = {"in": P.ACCENT, "slow": P.WARN_, "done": P.PASS_}.get(state, P.MUTED)
        if state == "ghost":
            dashed_box(st, d, box, P.MUTED)
        else:
            rr(st, d, box, fill=P.INK, r=int(5 * s) if kind == "C" else int(2 * s))
            if kind == "A":
                d.rectangle([box[0] + int(4 * s), box[1] + int(3 * s), box[2] - int(4 * s), box[1] + int(7 * s)],
                            fill=mix(P.ACCENT, P.PAPER, 0.25))
            if state in ("in", "slow", "done"):
                rr(st, d, (box[0] - int(3 * s), box[1] - int(3 * s), box[2] + int(3 * s), box[3] + int(3 * s)),
                      outline=col, width=max(2, int(2 * s)), r=int(4 * s))
        lab = ("USB-%s %s" % (kind, name)) if kind in ("A", "C") else name
        st.text(d, (cx, ey1 - int(4 * s)), fit(st, d, lab, slot_w - 6 * s), scr.f_tiny,
                col if state in ("in", "slow", "done") else P.MUTED, "md")
        if state == "done":
            tick(d, box[2] + int(10 * s), box[1] - int(2 * s), int(12 * s), P.PASS_, max(2, int(2 * s)))
        if state == "start":
            note(st, d, (cx, box[1] - int(2 * s)), "at start", anchor="md")
    if not live(st) and step == 0:
        note(st, d, (ex1 - int(8 * s), ey0 + int(4 * s)), "internal - not counted", anchor="ra")
    # the stick, going into (or out of) its socket from above - a short trip,
    # so it never climbs into the heading
    if show and target is not None and target < len(show) and plug >= 0.5:
        cx = ex0 + slot_w * (target + 0.7)
        cy = ey0 + (ey1 - ey0) * 0.42
        top = cy - int(7 * s) - int(10 * s) * (1 - plug)
        rr(st, d, (cx - int(11 * s), top - int(22 * s), cx + int(11 * s), top - int(6 * s)), fill=P.INK, r=int(4 * s))
        d.rectangle([cx - int(8 * s), top - int(6 * s), cx + int(8 * s), top + int(3 * s)], fill=P.MUTED)
    # the contacts, lit as they carry something
    on = P.PASS_
    for k, (x, y) in enumerate(L.c3):
        box = (x - L.w3 // 2, y - L.ch // 2, x + L.w3 // 2, y + L.ch // 2)
        if bad3:
            d.rectangle(box, fill=P.CHIP, outline=P.FAIL_)
        else:
            d.rectangle(box, fill=on if lit3 else P.GOLD)
        st.text(d, (x, box[1] - int(2 * s)), L.n3[k], scr.f_tiny, P.FAIL_ if bad3 else P.INK, "md")
    for k, (x, y) in enumerate(L.c2):
        box = (x - L.w2 // 2, y - L.ch // 2, x + L.w2 // 2, y + L.ch // 2)
        lit = lit2 if k in (1, 2) else lit_power
        d.rectangle(box, fill=on if lit else P.GOLD)
        st.text(d, (x, box[3] + int(2 * s)), L.n2[k], scr.f_tiny, P.INK, "ma")
    if bad3:
        x0_, x1_ = L.c3[0][0] - L.w3, L.c3[-1][0] + L.w3
        d.line([x0_, L.y3, x1_, L.y3], fill=P.FAIL_, width=max(2, int(2 * s)))
    # the lanes carrying the link, and the messages on them
    if lit2:
        for ln in L.lane2:
            d.line(ln, fill=P.ACCENT, width=max(2, int(2 * s)))
    if lit3:
        for ln in L.lane3:
            d.line(ln, fill=P.ACCENT, width=max(2, int(2 * s)))
    if lit3 or lit2:
        lane = L.lane3[1] if lit3 else L.lane2[0]
        for k in range(3):
            packet(st, d, lane[::-1] if k % 2 else lane, (T * 0.9 + k / 3.0) % 1.0)
        if not live(st) and step == 2:
            packet(st, d, L.lane3[2][::-1], (T * 0.5) % 1.0, label="USB 3.2, storage", side=1)
    # the readout: the speed the link came up at
    rx, ry = L.read
    heading(st, d, (rx, ry), "THE LINK")
    word, what = usb_speed_word(speed)
    if word:
        st.text(d, (rx, ry + int(22 * s)), word, scr.f_bodyb, P.WARN_ if bad3 else P.PASS_)
        why = "a USB 3 device held back to USB 2" if bad3 else what
        for i, ln in enumerate(st.wrap(d, why, scr.f_tiny, st.area[2] - rx, maxlines=3)):
            st.text(d, (rx, ry + int(50 * s) + i * int(18 * s)), ln, scr.f_tiny, P.WARN_ if bad3 else P.MUTED)
    else:
        st.text(d, (rx, ry + int(22 * s)), "no device" if live(st) else "...", scr.f_bodyb, P.MUTED)

    if live(st):
        seq = [("%s %s" % (k, n_), {"in": "now", "slow": "warn", "done": "done"}.get(sta, "todo"))
               for k, n_, sta in socks[:8]]
        if seq:
            strip_seq(st, d, seq, "Sockets: green tested, blue in use now, amber held back")
        return
    # ---- explained
    title = ["SOCKETS", "PLUGGED IN", "WHAT IT SAYS", "HELD BACK", "TESTED"][step]
    box = st.panel_title(d, title, NOTE)
    if step == 0:
        rows(st, d, box, [("Ports listed", "14"), ("Sockets on the case", "3"),
                          ("Camera, Bluetooth", "not counted", P.MUTED)])
    elif step == 1:
        rows(st, d, box, [("Power, 5 V", "on" if lit_power else "-", P.PASS_ if lit_power else P.MUTED),
                          ("USB 2 pair", "talking" if lit2 else "-", P.PASS_ if lit2 else P.MUTED),
                          ("SuperSpeed pairs", "talking" if lit3 else "-", P.PASS_ if lit3 else P.MUTED),
                          ("Link", word or "...", P.PASS_ if word else P.MUTED)])
    elif step == 2:
        rows(st, d, box, [("Device", "SanDisk Ultra"), ("Speaks", "USB 3.2"), ("Class", "storage"),
                          ("Link", "5 Gbit/s", P.PASS_)], until=int(u * 7) + 1)
    elif step == 3:
        y = rows(st, d, box, [("Device speaks", "USB 3.2"), ("Link", "480 Mbit/s", P.WARN_)])
        if u > 0.3:
            st.badge(d, box[0], y + int(6 * s), "MARGINAL", P.WARN_)
            say(st, d, box, y + int(52 * s), "Clean or replace that socket - its SuperSpeed contacts "
                "are not touching.", P.WARN_)
    else:
        rows(st, d, box, [("USB-A 1", "tested OK", P.PASS_), ("USB-A 2", "held back", P.WARN_),
                          ("USB-C 3", "boot drive", P.MUTED)])
    states = [[("A 1", "todo"), ("A 2", "todo"), ("C 3", "todo")],
              [("A 1", "now"), ("A 2", "todo"), ("C 3", "todo")],
              [("A 1", "now"), ("A 2", "todo"), ("C 3", "todo")],
              [("A 1", "done"), ("A 2", "warn"), ("C 3", "todo")],
              [("A 1", "done"), ("A 2", "warn"), ("C 3", "todo")]][step]
    strip_seq(st, d, states, "Sockets that took a device during the test")


# ---------------------------------------------------------------- Wi-Fi
APS = [(0, 2, -48), (0, 6, -71), (0, 11, -64), (1, 2, -55), (1, 5, -80), (1, 9, -67), (1, 14, -76),
       (0, 1, -83), (1, 18, -72), (0, 9, -78), (1, 21, -59), (1, 3, -86), (0, 4, -69), (1, 12, -74)]


def rssi_bars(dbm):
    if dbm is None:
        return 0
    return 5 if dbm >= -55 else 4 if dbm >= -67 else 3 if dbm >= -75 else 2 if dbm >= -82 else 1


def lay_wifi(st):
    s = st.s
    x0, y0, x1, y1 = st.area
    W, H = x1 - x0, y1 - y0
    L = NS()
    L.lid = (x0 + int(W * 0.05), y0 + int(22 * s), x0 + int(W * 0.40), y0 + int(H * 0.68))
    lx0, ly0, lx1, ly1 = L.lid
    L.screen = (lx0 + int(14 * s), ly0 + int(22 * s), lx1 - int(14 * s), ly1 - int(10 * s))
    L.base = (x0 + int(W * 0.02), ly1 + int(4 * s), x0 + int(W * 0.43), y1 - int(8 * s))
    aw, ah = int(30 * s), int(8 * s)
    L.ants = [(lx0 + int(10 * s), ly0 + int(7 * s), lx0 + int(10 * s) + aw, ly0 + int(7 * s) + ah),
              (lx1 - int(10 * s) - aw, ly0 + int(7 * s), lx1 - int(10 * s), ly0 + int(7 * s) + ah)]
    bx0, by0, bx1, by1 = L.base
    cw, chh = int(W * 0.10), int((by1 - by0) * 0.42)
    ccx = (bx0 + bx1) // 2
    L.card = (ccx - cw // 2, by1 - int(8 * s) - chh, ccx + cw // 2, by1 - int(8 * s))
    L.conn = [(L.card[0] + int(cw * 0.25), L.card[1]), (L.card[0] + int(cw * 0.75), L.card[1])]
    # each lead: up out of the card, along the hinge, up the side of the lid
    sx_l, sx_r = lx0 + int(8 * s), lx1 - int(8 * s)          # inside the bezel
    hy = ly1 - int(3 * s)
    L.leads = [[L.conn[0], (L.conn[0][0], hy), (sx_l, hy), (sx_l, L.ants[0][3]), (L.ants[0][0], L.ants[0][3])],
               [L.conn[1], (L.conn[1][0], hy), (sx_r, hy), (sx_r, L.ants[1][3]), (L.ants[1][2], L.ants[1][3])]]
    L.ap = (x1 - int(W * 0.26), y0 + int(H * 0.46), x1 - int(W * 0.10), y0 + int(H * 0.62))
    L.ap_c = ((L.ap[0] + L.ap[2]) // 2, L.ap[1] - int(16 * s))
    L.cloud = (x1 - int(W * 0.30), y0 + int(4 * s), x1 - int(W * 0.04), y0 + int(H * 0.24))
    # the signal meter, on the laptop's own screen
    L.meter = ((L.screen[0] + L.screen[2]) // 2 - int(30 * s), (L.screen[1] + L.screen[3]) // 2 + int(20 * s))
    L.air = [((L.ants[1][0] + L.ants[1][2]) // 2, L.ants[1][1]), (L.ap_c[0], L.ap_c[1])]
    L.up = [((L.ap[0] + L.ap[2]) // 2 + int(10 * s), L.ap[1] - int(28 * s)),
            ((L.cloud[0] + L.cloud[2]) // 2, L.cloud[3])]
    L.far = [(L.ap[0] - int(W * 0.15), y0 + int(H * 0.10)), (L.ap[2] - int(W * 0.04), y1 - int(H * 0.08))]
    return L


def draw_ap(st, d, box, col, fill, small=False):
    P, s = st.P, st.s
    x0, y0, x1, y1 = box
    lw = max(1, int(2 * s))
    for f in (0.25, 0.75):
        x = lerp(x0, x1, f)
        d.line([x, y0, x + (f - 0.5) * 12 * s, y0 - int((12 if small else 26) * s)], fill=col, width=lw)
    rr(st, d, box, fill=fill, outline=col, width=lw, r=int(5 * s))
    if not small:
        for k in range(3):
            st.dot(d, (x0 + int(12 * s) + k * int(12 * s), y1 - int(9 * s)), max(2, int(2.5 * s)), P.PASS_)


def static_wifi(st, d, L):
    P, s, scr = st.P, st.s, st.scr
    lw = max(1, int(2 * s))
    heading(st, d, (L.lid[0], L.lid[1] - int(6 * s)), "THIS LAPTOP", "ld")
    rr(st, d, L.lid, fill=P.CHIP, outline=P.INK, width=lw, r=int(8 * s))
    rr(st, d, L.screen, fill=P.PAPER, outline=P.LINE, r=int(3 * s))
    rr(st, d, L.base, fill=P.CHIP, outline=P.INK, width=lw, r=int(6 * s))
    for a in L.ants:
        d.rectangle(a, fill=P.INK)
    note(st, d, ((L.screen[0] + L.screen[2]) // 2, L.screen[1] + int(8 * s)), "antennas in the lid", anchor="ma")
    rr(st, d, L.card, fill=P.BOARD, outline=P.INK, width=1, r=int(3 * s))
    st.text(d, ((L.card[0] + L.card[2]) // 2, (L.card[1] + L.card[3]) // 2 + int(2 * s)), "Wi-Fi card",
            scr.f_tiny, P.INK, "mm")
    cloud(st, d, L.cloud, P.PAPER, P.MUTED)
    st.text(d, ((L.cloud[0] + L.cloud[2]) // 2, (L.cloud[1] + L.cloud[3]) // 2 + int(6 * s)), "internet",
            scr.f_tiny, P.INK, "mm")
    dashed(st, d, L.up, P.MUTED)
    draw_ap(st, d, L.ap, P.INK, P.CHIP)
    note(st, d, ((L.ap[0] + L.ap[2]) // 2, L.ap[3] + int(4 * s)), "access point - the gateway", anchor="ma")


def scene_wifi(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    L = st.lay("wifi")
    T = st.clock if live(st) else t
    off = None                     # which lead has come off the card
    dbm = -54
    down = False
    ping = None
    if live(st):
        sv = fact(st, "signal now")
        down = bool(sv and "down" in sv)
        dbm = number(sv) if sv and not down else None
        pv = fact(st, "gateway ping")
        if pv:
            ping = "lost" if pv.startswith("lost") else number(pv)
    else:
        if step == 1 and u > 0.40:
            off = 1
            dbm = int(lerp(-54, -86, ease(seg(u, 0.40, 0.55))))
        down = step == 3 and 0.30 <= u < 0.62
        ping = 4 if step in (2, 3) else None
    # the far access points the scan hears too
    if step == 0:
        for k, (fx, fy) in enumerate(L.far):
            box = (fx - int(16 * s), fy - int(7 * s), fx + int(16 * s), fy + int(7 * s))
            draw_ap(st, d, box, P.MUTED, P.PAPER, small=True)
            for j in range(2):
                f = (T * 0.45 + j * 0.5 + k * 0.3) % 1.0
                r = lerp(10 * s, 70 * s, f)
                d.arc([fx - r, fy - r, fx + r, fy + r], 150, 210, fill=mix(P.MUTED, P.PAPER, f),
                      width=max(1, int(2 * s)))
    # the leads from the card to the antennas
    for k, ld in enumerate(L.leads):
        col = P.INK if k == 1 else P.MUTED
        if off == k:
            lift = ease(seg(u, 0.40, 0.50)) * 12 * s
            d.line([(ld[0][0] + lift * 0.6, ld[0][1] - lift)] + ld[1:], fill=col, width=max(2, int(2 * s)),
                   joint="curve")
            d.ellipse([ld[0][0] - 5 * s, ld[0][1] - 5 * s, ld[0][0] + 5 * s, ld[0][1] + 5 * s],
                      outline=P.FAIL_, width=max(1, int(2 * s)))
            st.tag(d, (ld[0][0] + int(44 * s), ld[0][1] - int(28 * s)), "lead off", bg=P.FAIL_)
        else:
            d.line(ld, fill=col, width=max(2, int(2 * s)), joint="curve")
            st.dot(d, ld[0], max(3, int(4 * s)), P.GOLD)
    note(st, d, (L.leads[1][1][0] + int(6 * s), L.leads[1][1][1] - int(4 * s)), "main", anchor="ld")
    note(st, d, (L.leads[0][1][0] - int(6 * s), L.leads[0][1][1] - int(4 * s)), "aux", anchor="rd")
    # the radio between the access point and the laptop
    ax, ay = L.ap_c
    if down:
        mx = (L.air[0][0] + L.air[1][0]) / 2.0
        my = (L.air[0][1] + L.air[1][1]) / 2.0
        dashed(st, d, L.air, P.FAIL_)
        cross(d, mx, my, int(18 * s), P.FAIL_, max(2, int(3 * s)))
        st.tag(d, (mx, my - int(26 * s)), "link down", bg=P.FAIL_)
    else:
        strength = 1.0 if dbm is None else clamp((dbm + 95) / 45.0)
        reach = (ax - L.air[0][0]) * (0.35 + 0.65 * strength)
        for j in range(4):
            f = (T * 0.5 + j / 4.0) % 1.0
            r = lerp(14 * s, reach, f)
            d.arc([ax - r, ay - r, ax + r, ay + r], 152, 208, fill=mix(P.ACCENT, P.PAPER, 0.15 + 0.8 * f),
                  width=max(2, int(3 * s)))
    # the signal meter
    mx, my = L.meter
    lit = 0 if down else rssi_bars(dbm)
    col = P.PASS_ if lit >= 4 else P.WARN_ if lit >= 2 else P.FAIL_
    heading(st, d, (mx, my - int(56 * s)), "SIGNAL")
    signal_bars(st, d, mx, my - int(36 * s), int(32 * s), lit, col)
    if live(st) and step == 0:
        st.text(d, (mx, my + int(2 * s)), "listening...", scr.f_tiny, P.MUTED)
    elif dbm is not None and not down:
        st.text(d, (mx, my + int(2 * s)), "%d dBm" % dbm, scr.f_noteb, col)
    # pings to the gateway, and the internet after
    air_path = L.leads[1][::-1] + [L.air[1]]
    if step in (2, 3) and not down:
        v = (T % 2.0) / 2.0
        if v < 0.45:
            packet(st, d, air_path, v / 0.45, P.ACCENT, "ping" if v < 0.3 else None)
        elif v < 0.9:
            lost = ping == "lost"
            lab = "lost" if lost else ("%d ms" % ping if ping is not None else "reply")
            packet(st, d, air_path[::-1], (v - 0.45) / 0.45, P.FAIL_ if lost else P.PASS_,
                   lab if v < 0.75 else None)
    if step == 4:
        downloading = (not live(st) and u > 0.6) or (live(st) and line_with(st, "download") is not None)
        if downloading:
            for k in range(6):
                f = (T * 0.8 + k / 6.0) % 1.0
                st.dot(d, st.along([L.up[1], L.up[0]] + air_path[::-1], f), max(3, int(4 * s)), P.ACCENT)
            st.tag(d, ((L.up[0][0] + L.up[1][0]) / 2 + int(36 * s), (L.up[0][1] + L.up[1][1]) / 2), "20 MB",
                   bg=P.ACCENT)
        else:
            v = (T % 3.0) / 3.0
            lab = "DNS" if (live(st) or u < 0.3) else "HTTPS"
            packet(st, d, air_path + [L.up[0], L.up[1]], v, P.ACCENT, lab if v < 0.85 else None)

    # strip: the channels the radio listens on - no access points made up live
    if step <= 1:
        st.addr_strip(d, "2.4 GHz", "5 GHz", "Listening on every channel")
        sx0, by0, sx1, by1 = st._sb
        split = lerp(sx0, sx1, 0.32)
        d.line([split, by0, split, by1], fill=P.LINE, width=max(1, int(2 * s)))
        x = st.strip_cursor(d, (T * 0.25) % 1.0)
        if not live(st):
            for band, ch, rssi in APS:
                fx = lerp(sx0, split, (ch + 0.5) / 14.0) if band == 0 else lerp(split, sx1, (ch + 0.5) / 25.0)
                if step == 1 or fx < x:
                    hh = (by1 - by0 - 4) * clamp((rssi + 95) / 50.0)
                    d.rectangle([fx - 2 * s, by1 - 2 - hh, fx + 2 * s, by1 - 2], fill=P.DATA)
    elif step == 4 and live(st):
        got = line_with(st, "download") is not None
        strip_seq(st, d, [("names (DNS)", "done" if got else "now"), ("HTTPS sites", "done" if got else "now"),
                          ("download", "now" if got else "todo")], "The internet checks")

    if live(st):
        return
    # ---- explained
    title = ["SCAN", "SIGNAL", "STABILITY", "DROPS", "INTERNET"][step]
    box = st.panel_title(d, title, NOTE)
    if step == 0:
        rows(st, d, box, [("Access points heard", "%d" % int(len(APS) * ease(u))), ("Strongest", "-48 dBm", P.PASS_)])
    elif step == 1:
        y = rows(st, d, box, [("Signal now", "%d dBm" % dbm, P.PASS_ if dbm >= -67 else P.FAIL_),
                              ("Next to the AP", "yes")])
        for txt, col in (("-55 or better: excellent", P.PASS_), ("-67: good", P.PASS_),
                         ("-75: usable", P.WARN_), ("below -82: very weak", P.FAIL_)):
            st.text(d, (box[0], y + int(6 * s)), txt, scr.f_small, col)
            y += int(23 * s)
    elif step == 2:
        rows(st, d, box, [("Signal now", "-54 dBm", P.PASS_), ("Link rate", "866 Mbit/s"),
                          ("Gateway ping", "4 ms", P.PASS_), ("Packets lost", "0 of %d" % int(st.lt / 2 + 1))])
    elif step == 3:
        y = rows(st, d, box, [("Link drops", "1" if u >= 0.30 else "0", P.FAIL_ if u >= 0.30 else P.PASS_),
                              ("Back after", "3 s" if u >= 0.62 else "...")])
        if u >= 0.30:
            say(st, d, box, y + int(8 * s), "Sitting still, next to the AP: check the antenna "
                "leads, then try another card.", P.FAIL_)
    else:
        rows(st, d, box, [("Name lookups", "3 of 3", P.PASS_),
                          ("HTTPS sites", "3 of 3" if u > 0.6 else "...", P.PASS_ if u > 0.6 else None),
                          ("Download", "84 Mbit/s" if u > 0.95 else "...")])
    if step >= 2:
        strip_seq(st, d, [("signal", "done" if step > 2 else "now"), ("gateway ping", "done" if step > 2 else "now"),
                          ("drops", "fail" if step == 3 and u >= 0.3 else "done" if step > 3 else "todo"),
                          ("internet", "now" if step == 4 else "todo")],
                  "What the stability watch and the internet check look at")


# ---------------------------------------------------------------- Ethernet
def lay_ether(st):
    s = st.s
    x0, y0, x1, y1 = st.area
    W, H = x1 - x0, y1 - y0
    L = NS()
    L.lap = (x0, y0 + int(22 * s), x0 + int(W * 0.27), y1 - int(8 * s))
    L.ys = (L.lap[1] + L.lap[3]) // 2 + int(10 * s)
    L.nic = (x0 + int(W * 0.03), L.ys - int(H * 0.15), x0 + int(W * 0.15), L.ys + int(H * 0.15))
    L.sock = (L.lap[2] - int(30 * s), L.ys - int(26 * s), L.lap[2] + int(3 * s), L.ys + int(26 * s))
    L.router = (x1 - int(W * 0.20), L.ys - int(H * 0.16), x1 - int(4 * s), L.ys + int(H * 0.16))
    L.cloud = (x1 - int(W * 0.24), y0 + int(4 * s), x1 - int(W * 0.01), y0 + int(H * 0.24))
    L.nose_in, L.nose_out = L.lap[2] - int(24 * s), L.lap[2] + int(W * 0.12)
    L.gp = max(5, int(12 * s))
    L.up = [((L.router[0] + L.router[2]) // 2, L.router[1]), ((L.cloud[0] + L.cloud[2]) // 2, L.cloud[3])]
    L.ip = ((L.lap[0] + L.lap[2]) // 2, L.lap[1] + int(30 * s))
    return L


def static_ether(st, d, L):
    P, s, scr = st.P, st.s, st.scr
    lw = max(1, int(2 * s))
    heading(st, d, (L.lap[0], L.lap[1] - int(6 * s)), "THIS LAPTOP", "ld")
    rr(st, d, L.lap, fill=P.PAPER, outline=P.MUTED, width=lw, r=int(10 * s))
    part(st, d, L.nic, None, P.CHIP, P.INK)
    st.text(d, ((L.nic[0] + L.nic[2]) // 2, (L.nic[1] + L.nic[3]) // 2 - int(8 * s)), "network",
            scr.f_tiny, P.INK, "mm")
    st.text(d, ((L.nic[0] + L.nic[2]) // 2, (L.nic[1] + L.nic[3]) // 2 + int(8 * s)), "chip",
            scr.f_tiny, P.INK, "mm")
    d.line([(L.nic[2], L.ys), (L.sock[0], L.ys)], fill=P.LINE, width=max(3, int(5 * s)))
    d.rectangle(L.sock, fill=P.INK)
    note(st, d, ((L.sock[0] + L.sock[2]) // 2, L.sock[3] + int(4 * s)), "socket", anchor="ma")
    cloud(st, d, L.cloud, P.PAPER, P.MUTED)
    st.text(d, ((L.cloud[0] + L.cloud[2]) // 2, (L.cloud[1] + L.cloud[3]) // 2 + int(6 * s)),
            "internet  1.1.1.1", scr.f_tiny, P.INK, "mm")
    dashed(st, d, L.up, P.MUTED)
    part(st, d, L.router, "ROUTER", P.CHIP, P.INK, "DHCP, gateway")
    for k in range(4):
        x = L.router[0] + int(10 * s) + k * int(14 * s)
        d.rectangle([x, L.router[3] - int(16 * s), x + int(10 * s), L.router[3] - int(7 * s)], fill=P.INK)


def ether_pairs(st, d, L, x0, x1, lit, broken, T, pulses):
    """The cable: four twisted pairs in a jacket, each lit if it carries the link."""
    P, s = st.P, st.s
    gp = L.gp
    lw = max(1, int(2 * s))
    jt = (x0, L.ys - int(2.4 * gp), x1, L.ys + int(2.4 * gp))
    rr(st, d, jt, fill=P.PAPER, outline=P.MUTED, width=lw, r=int(1.2 * gp))
    lam = 26 * s
    a = gp * 0.26
    for k in range(4):
        yk = L.ys + (k - 1.5) * gp
        on = k < lit
        for w in (0, 1):
            pts = []
            x = x0 + gp
            while x <= x1 - gp:
                ph = 2 * math.pi * (x - x0) / lam + (math.pi if w else 0)
                pts.append((x, yk + a * math.sin(ph)))
                x += 3 * s
            col = (P.ACCENT if w == 0 else mix(P.ACCENT, P.PAPER, 0.45)) if on else P.LINE
            if len(pts) > 1:
                d.line(pts, fill=col, width=max(1, int(1.6 * s)))
        if pulses and on:
            for j in range(2):
                f = (T * 0.6 + j / 2.0 + k * 0.13) % 1.0
                st.dot(d, (lerp(x0 + gp, x1 - gp, f if j == 0 else 1 - f), yk), max(2, int(3 * s)), P.ACCENT)
        if k in broken:
            cross(d, lerp(x0, x1, 0.55), yk, int(10 * s), P.FAIL_, max(2, int(2 * s)))
    note(st, d, (x0 + gp, jt[1] - int(4 * s)), "4 pairs of wires", anchor="ld")


def rj45(st, d, nose, y):
    """The plug, clear plastic, its gold contacts at the nose. Returns where
    the cable leaves it."""
    P, s = st.P, st.s
    L, h = int(30 * s), int(20 * s)
    rr(st, d, (nose, y - h, nose + L, y + h), fill=P.PAPER, outline=P.INK, width=max(1, int(2 * s)), r=int(3 * s))
    for k in range(8):
        yy = y - h + int(4 * s) + k * (2 * h - int(8 * s)) / 7.0
        d.line([nose + int(2 * s), yy, nose + int(9 * s), yy], fill=P.GOLD, width=max(1, int(s)))
    d.line([nose + int(6 * s), y - h, nose + L - int(4 * s), y - h - int(7 * s)], fill=P.INK, width=max(1, int(2 * s)))
    d.rectangle([nose + L, y - int(12 * s), nose + L + int(12 * s), y + int(12 * s)], fill=P.INK)
    return nose + L + int(12 * s)


def scene_ether(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    L = st.lay("ether")
    T = st.clock if live(st) else t
    if live(st):
        link = (fact(st, "cable") or "").lower() == "connected"
        sp = number(fact(st, "negotiated"))
        pairs = 0 if not link else (4 if (sp or 1000) >= 1000 else 2)
        q = 1.0 if link else 0.5 - 0.5 * math.cos(T * 2 * math.pi / 2.0)
        broken = []
        addr = line_with(st, "Address ")
        ip = addr.split()[-1] if addr else None
    else:
        q = ease(seg(u, 0.05, 0.30)) if step == 0 else 1.0
        link = q >= 1.0 and (step > 0 or u > 0.35)
        pairs = 0 if not link else (2 if step == 1 else 4)
        sp = None if not link or (step == 0 and u < 0.7) else (100 if step == 1 else 1000)
        broken = [2] if step == 1 else []
        ip = "192.168.1.23" if (step == 3 or (step == 2 and u > 0.88)) else None
    nose = lerp(L.nose_out, L.nose_in, q)
    back = rj45(st, d, nose, L.ys)
    ether_pairs(st, d, L, back, L.router[0], pairs, broken, T, step == 0)
    if live(st) and step == 0 and not link:
        arrow(st, d, (L.nose_out + int(40 * s), L.ys - int(46 * s)), (L.nose_in + int(10 * s), L.ys - int(46 * s)),
              P.ACCENT)
    # the router's link light
    st.dot(d, (L.router[2] - int(14 * s), L.router[1] + int(12 * s)), max(3, int(4 * s)),
           P.PASS_ if link else P.LINE)
    # the speed agreed
    ty = L.ys + int(2.4 * L.gp) + int(20 * s)
    if link and sp:
        good = sp >= 1000
        txt = ("%d Mbit/s - all 4 pairs" if good else "%d Mbit/s - 2 of 4 pairs") % sp
        st.tag(d, ((back + L.router[0]) / 2, ty), txt, bg=P.PASS_ if good else P.WARN_)
    elif live(st) and not link:
        st.tag(d, ((back + L.router[0]) / 2, ty), "no link yet", bg=P.MUTED)
    # the messages
    path = [(back, L.ys), (L.router[0], L.ys)]
    far = path + [(L.router[0] + int(20 * s), L.ys), L.up[0], L.up[1]]
    if step == 2 and link:
        if live(st):
            k, v = int((T % 4.0) / 1.0), (T % 4.0) % 1.0
        else:
            k, v = min(3, int(u / 0.25)), (u % 0.25) / 0.22
        if v < 1.0:
            name = ["Discover", "Offer", "Request", "Ack"][k]
            packet(st, d, path if k % 2 == 0 else path[::-1], v, P.ACCENT if k % 2 == 0 else P.PASS_, name)
    if step == 3 and link:
        if live(st):
            k, v = int(T / 1.2) % 3, (T % 1.2) / 1.2
        else:
            k, v = (0 if u < 0.3 else 1 if u < 0.75 else 2), (u * 4) % 1.0
        route = path if k == 0 else far
        if v < 0.5:
            packet(st, d, route, v * 2, P.ACCENT, ["ping gateway", "ping 1.1.1.1", "one.one.one.one?"][k])
        else:
            packet(st, d, route[::-1], (v - 0.5) * 2, P.PASS_, "1.1.1.1" if k == 2 else "reply")
    if ip:
        st.tag(d, L.ip, ip, bg=P.PASS_)

    # strip: the stages of the test, in order
    def state(done, now, warn=False):
        return "warn" if (done and warn) else "done" if done else "now" if now else "todo"
    if live(st):
        seq = [("link", state(link, step == 0)), ("speed", state(sp is not None and link, False,
                                                                  sp is not None and sp < 1000)),
               ("address", state(ip is not None, step == 2)), ("gateway", state(False, step == 3)),
               ("internet", state(False, step == 3)), ("DNS", state(False, step == 3))]
    else:
        seq = [("link", state(link, step == 0)), ("speed", state(sp is not None, False, step == 1)),
               ("address", state(ip is not None, step == 2)),
               ("gateway", state(step == 3 and u > 0.3, step == 3 and u <= 0.3)),
               ("internet", state(step == 3 and u > 0.75, step == 3 and 0.3 < u <= 0.75)),
               ("DNS", state(step == 3 and u > 0.95, step == 3 and 0.75 < u <= 0.95))]
    strip_seq(st, d, seq, "What the Ethernet test checks, in order")

    if live(st):
        return
    # ---- explained
    title = ["LINK", "LINK", "ADDRESS", "TRAFFIC"][step]
    box = st.panel_title(d, title, NOTE)
    if step == 0:
        rows(st, d, box, [("Cable", "connected" if link else "...", P.PASS_ if link else P.MUTED),
                          ("Negotiated", "1000 Mbps full" if sp else "...", P.PASS_ if sp else P.MUTED)])
    elif step == 1:
        y = rows(st, d, box, [("Negotiated", "100 Mbps full", P.WARN_), ("Pairs carrying it", "2 of 4", P.WARN_)])
        say(st, d, box, y + int(8 * s), "Swap the cable. Still 100: the socket.", P.WARN_)
    elif step == 2:
        names = ["Discover", "Offer", "Request", "Ack"]
        k = min(4, int(u / 0.25) + 1)
        rows(st, d, box, [(n_, "sent" if i % 2 == 0 else "received", P.PASS_) for i, n_ in enumerate(names[:k])] +
             ([("Address", ip, P.PASS_)] if ip else []))
    else:
        y = rows(st, d, box, [("Gateway", "2 of 2 answered" if u > 0.3 else "...", P.PASS_ if u > 0.3 else None),
                              ("Internet", "4 of 4, 12 ms" if u > 0.75 else "...", P.PASS_ if u > 0.75 else None),
                              ("DNS", "works" if u > 0.95 else "...", P.PASS_ if u > 0.95 else None)])
        if u > 0.95:
            st.badge(d, box[0], y + int(6 * s), "PASS", P.PASS_)


# ---------------------------------------------------------------- the set
LAYOUT = {"ram": lay_ram, "cpu": lay_cpu, "battery": lay_battery, "charge": lay_charge,
          "usb": lay_usb, "wifi": lay_wifi, "ether": lay_ether}
STATIC = {"ram": static_ram, "cpu": static_cpu, "battery": static_battery, "charge": static_charge,
          "usb": static_usb, "wifi": static_wifi, "ether": static_ether}
DRAW = {"ram": scene_ram, "cpu": scene_cpu, "battery": scene_battery, "charge": scene_charge,
        "usb": scene_usb, "wifi": scene_wifi, "ether": scene_ether}


def make_stage(scr, pal):
    return Bench(scr, Pal(pal))


def backdrop(st, i):
    return st.background(i)


def live_words(name):
    head, what = WORDS.get(name, ("THIS MACHINE, NOW", "the machine is"))
    return head, ("The moving parts are a picture of what %s doing; every figure is read from "
                  "this machine." % what)


KIT = sys.modules[__name__]


def play(scr, kb, pal, start="ram"):
    return sa.play(scr, kb, pal, start, KIT)


class Live(sa.Live):
    """ssdanim's live mode over these scenes, with two differences. The
    picture is handed the test's own figures before it is drawn. And these
    tests give the operator something to do - unplug the charger, plug a cable
    in - so the test's instruction, its first plain line, is the line under
    the title, and its other plain lines are status worth the panel."""

    KEEP_STRIP = True

    def __init__(self, scr, pal):
        sa.Live.__init__(self, scr, pal, KIT)

    def prepare(self, items):
        st = self.st
        facts, lines = {}, []
        for it in items:
            if it[0] == "kv":
                facts[str(it[2]).strip().lower()] = (str(it[3]).strip(), it[4] if len(it) > 4 else "")
            elif it[0] == "line" and str(it[2]).strip():
                try:
                    row = float(it[1])
                except (TypeError, ValueError):
                    row = 99.0
                lines.append((row, str(it[2]).strip(), it[3] if len(it) > 3 else ""))
        st.facts = facts
        st.lines = sorted(lines, key=lambda l: l[0])

    def _instruction(self):
        for _, text, tone in self.st.lines:
            if tone == "":
                return text
        return None

    def _title(self, d, title):
        st, P, s = self.st, self.st.P, self.st.s
        say_ = self._instruction()
        if not say_:
            return sa.Live._title(self, d, title)
        d.rectangle([st.ix0, st.title_y - int(8 * s), st.ix1, st.main_top - int(6 * s)], fill=P.PAPER)
        st.text(d, (st.ix0, st.title_y), title, st.scr.f_h, P.INK)
        st.tag(d, (st.ix1 - int(30 * s), st.title_y + int(16 * s)), "LIVE", bg=P.ACCENT)
        cy = st.tabs_y + int(14 * s)
        h = int(14 * s)
        d.polygon([(st.ix0, cy - h // 2), (st.ix0 + int(h * 0.85), cy), (st.ix0, cy + h // 2)], fill=P.ACCENT)
        txt = st.wrap(d, say_, st.scr.f_bodyb, st.ix1 - st.ix0 - int(26 * s), maxlines=1)[0]
        st.text(d, (st.ix0 + int(22 * s), cy), txt, st.scr.f_bodyb, P.INK, "lm")

    def _keep_line(self, text, tone):
        if tone in ("ok", "warn", "err", "accent"):
            return True
        return tone == "" and text != self._instruction()

    def _panel_foot(self):
        return "figures: read from this machine" if self._instruction() else None

    def _bar_label(self):
        return "Charge level" if self.K.NAMES[self.i] == "battery" else "Progress of the test"


# ---------------------------------------------------------------- standalone
LIVE_SAMPLES = {
    "ram": [("kv", "6", "Engine", "stressapptest", ""),
            ("kv", "7", "Region tested", "10342 MB of 16384 MB installed", ""),
            ("kv", "8", "Elapsed", "1:12   of 5:00", ""), ("kv", "9", "Errors found", "none so far", "ok"),
            ("kv", "10", "Free memory", "2950 MB", ""), ("bar", "12", 24),
            ("line", "14", "Log: Stats: Memory Copy: 15000.00M at 6203.45MB/s", "muted")],
    "cpu": [("kv", "6", "CPU", "Intel(R) Core(TM) i5-1135G7 @ 2.40GHz", ""),
            ("kv", "7", "Sensor", "coretemp   (idle was 44 C)", ""),
            ("kv", "9", "Temperature now", "88 C", "warn"), ("kv", "10", "Min / max / avg", "44 C   91 C   79.2 C", "warn"),
            ("kv", "11", "Clock speed", "2900 MHz", ""), ("kv", "12", "Throttle events", "3", "warn"),
            ("kv", "13", "Elapsed", "4:10  of  10:00", ""), ("bar", "15", 41)],
    "battery": [("kv", "6", "Load", "full", ""), ("kv", "7", "Elapsed", "0:42:10", ""),
                ("kv", "9", "Charge level", "63 %   (started at 100 %)", "accent"),
                ("kv", "10", "Drawing now", "14.6 W", ""), ("kv", "11", "Energy used", "15.9 Wh  of 45.0 Wh design", ""),
                ("kv", "12", "Pack voltage", "11.42 V", ""), ("kv", "13", "Time left at this rate", "1:51", ""),
                ("bar", "15", 63)],
    "charge": [("line", "6", "Gently move the charger plug and cable - up, down, side to side.", ""),
               ("line", "7", "As you would to check for a loose jack. Every drop in the connection is counted.", "muted"),
               ("kv", "10", "Time", "12 of 30 s", ""), ("kv", "11", "Connection drops", "1", "err"),
               ("kv", "13", "Charger", "connected", "ok"), ("kv", "14", "Battery", "64%   Charging", ""),
               ("kv", "15", "Power", "27.9 W into the battery", ""),
               ("kv", "16", "Charger offers", "20.0 V up to 3.25 A (65 W)", ""),
               ("kv", "17", "Charger flags", "ADP1 on, USB-C 1 on, USB-C 2 off", "muted"), ("bar", "22", 40)],
    "usb": [("line", "6", "2 socket(s) tested    1 in use now", ""),
            ("kv", "8", "USB-A  bus 1 port 3", "SanDisk Ultra", "ok"),
            ("line", "9", "   USB 3.0 - 5 Gbit/s - storage", ""),
            ("kv", "10", "USB-A  bus 1 port 4", "empty - unplugged", "muted"),
            ("line", "11", "   tested OK - last: Logitech USB Receiver, USB 1.1 - 12 Mbit/s - keyboard + mouse receiver", "muted"),
            ("kv", "12", "USB-C  bus 2 port 1", "Kingston DataTraveler", "warn"),
            ("line", "13", "   USB 2.0 - 480 Mbit/s - storage  -  USB 3.20 device held back to 480 Mbit/s", "warn")],
    "wifi": [("line", "6", "Watching the link and pinging the gateway. Walk away from the AP", "muted"),
             ("kv", "9", "Network", "Bench-5G  5 GHz ch 36", ""), ("kv", "10", "Signal now", "-58 dBm  (good)", "ok"),
             ("kv", "11", "Link rate", "866.7 Mbit/s", ""), ("kv", "12", "Signal range", "-55 to -61 dBm", ""),
             ("kv", "13", "Gateway ping", "3  (avg 4 ms, max 11 ms)", "ok"), ("kv", "14", "Packets lost", "0 of 37", ""),
             ("bar", "22", 12)],
    "ether": [("kv", "6", "Ethernet adapter", "Intel Ethernet Connection I219-LM", ""),
              ("kv", "7", "Interface", "enp0s31f6", ""), ("kv", "8", "MAC address", "8c:16:45:aa:bb:cc", ""),
              ("kv", "9", "Cable", "connected", "ok"), ("kv", "10", "Negotiated", "1000 Mbps Full", "ok"),
              ("line", "12", "Address 192.168.1.23", ""), ("line", "13", "Testing the gateway and the internet...", "")],
}
# the same tests at their worst moments: no sensor, unplugged, link down, no cable
LIVE_EDGE = {
    "ram": [("kv", "9", "Errors found", "3", "err"), ("kv", "7", "Region tested", "200 MB of 2048 MB installed", "")],
    "cpu": [("kv", "9", "Temperature now", "no sensor on this machine", "warn"), ("kv", "11", "Clock speed", "0 MHz", "")],
    "battery": [("kv", "10", "Charge level", "98 %", "accent"), ("kv", "11", "Status", "Discharging", ""),
                ("line", "15", "Plug in the charger and leave it until the battery reaches 100%.", ""),
                ("line", "16", "Charging has stopped at 98% - press S to start the test from here.", "warn")],
    "charge": [("line", "6", "Plug the charger in.", ""), ("kv", "13", "Charger", "not connected", "warn"),
               ("kv", "14", "Battery", "61%   Discharging", "")],
    "usb": [("line", "6", "Plug a device into a socket - it appears here as soon as the", "muted"),
            ("line", "9", "Nothing detected yet.", "")],
    "wifi": [("kv", "10", "Signal now", "link is down", "err"), ("kv", "13", "Gateway ping", "lost  (avg 4 ms, max 11 ms)", "err"),
             ("kv", "15", "Link drops", "1", "err")],
    "ether": [("kv", "9", "Cable", "no link", "warn"), ("line", "11", "Plug a live network cable into the ethernet port.", ""),
              ("line", "12", "Waiting up to 30 seconds...", ""), ("line", "14", "still waiting... 21s", "muted")],
}


def _stage_for(w, h, theme):
    scr = sa._screen_for(w, h, theme)
    return Bench(scr, Pal(__import__("ui").anim_palette()))


def _text(names):
    out = []
    for name, title, prog, beats in SCENES:
        if names and name not in names:
            continue
        out.append(title.upper())
        out.append("")
        for i, (_, cap) in enumerate(beats):
            out.append("%d. %s" % (i + 1, cap))
        out.append("")
    return "\n".join(out)


def check(sizes=((1280, 800),), themes=("light", "dark", "contrast")):
    """Every step of every scene at its start, middle and end, explained;
    then live, each step with a test's own lines, ordinary and at their worst."""
    n = 0
    for th in themes:
        for (w, h) in sizes:
            st = _stage_for(w, h, th)
            for si, (name, _, _, beats) in enumerate(SCENES):
                acc = 0.0
                for sec, _ in beats:
                    for k in (0.02, 0.5, 0.98):
                        img = sa.frame(st, si, acc + sec * k, False, KIT)
                        assert img.size == (w, h)
                        n += 1
                    acc += sec
            lv = Live(st.scr, __import__("ui").anim_palette())
            for name, _, _, beats in SCENES:
                for opts in ((), ("usbc",)) if name == "charge" else ((),):
                    for items in (LIVE_SAMPLES[name], LIVE_EDGE[name], []):
                        for k in range(len(beats)):
                            lv.set(name, k, k, *opts)
                            img = lv.frame("A test - live", "Q = stop", items, now=lv.t0 + beats[k][0] * 0.5)
                            assert img.size == (w, h)
                            n += 1
    return n


def main(argv):
    def opt(k, dflt):
        return argv[argv.index(k) + 1] if k in argv else dflt
    size = opt("--size", "1280x800")
    w, h = (int(v) for v in size.lower().split("x"))
    theme = opt("--theme", "light")
    if "--text" in argv:
        rest = [a for a in argv[argv.index("--text") + 1:] if not a.startswith("--")]
        if rest and not any(r in NAMES for r in rest):
            print(sa._text(rest))           # a drive test: ssdanim has its captions
        else:
            print(_text(rest))
        return 0
    if "--check" in argv:
        # what the build runs: a broken animation stops the build, not a test
        n = check(themes=("light", "dark", "contrast"))
        n += check(sizes=((1024, 768), (1366, 768), (1920, 1080)), themes=("light",))
        print("hwanim: %d frames rendered OK" % n)
        return 0
    if "--frames" in argv:
        out = opt("--frames", ".")
        fps = float(opt("--fps", "12"))
        only = opt("--scene", "")
        os.makedirs(out, exist_ok=True)
        st = _stage_for(w, h, theme)
        for si, (name, _, _, beats) in enumerate(SCENES):
            if only and name != only:
                continue
            n = int(sa.total(beats) * fps)
            for f in range(n):
                sa.frame(st, si, f / fps, False, KIT).save(os.path.join(out, "%s_%05d.png" % (name, f)))
            print("%s: %d frames" % (name, n))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
