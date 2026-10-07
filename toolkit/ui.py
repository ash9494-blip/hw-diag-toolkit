#!/usr/bin/env python3
"""
Graphical front end for the Hardware Diagnostic Toolkit.

Draws straight to the Linux framebuffer with Pillow, so the interface can have
rounded corners, real typography and a white ground - none of which a character
cell console can do. Every frame is composed off-screen and blitted in one
write, which is also what removes the menu flicker.

The bash test scripts are unchanged: tui.sh forwards their existing tui_* calls
into this process over a FIFO. If the framebuffer cannot be opened, tui.sh
falls back to its original ANSI implementation and nothing is lost.
"""
import os, sys, mmap, fcntl, struct, select, time, signal, glob, re

from PIL import Image, ImageDraw, ImageFont

RUN = os.environ.get("DIAG_RUN", "/run/diag")
CMD = RUN + "/ui.cmd"
REPLY = RUN + "/ui.reply"

# ---------------------------------------------------------------- palette
GROUND = (234, 238, 244)
PAPER  = (255, 255, 255)
INK    = (17, 23, 32)
MUTED  = (106, 118, 132)
LINE   = (226, 232, 241)
ACCENT = (47, 109, 246)
ACC_SOFT = (234, 241, 255)
PASS_  = (15, 122, 79);  PASS_SOFT = (230, 244, 237)
WARN_  = (154, 100, 0);  WARN_SOFT = (253, 241, 221)
FAIL_  = (192, 52, 47);  FAIL_SOFT = (251, 234, 234)
SHADOW = (208, 215, 226)

# Named palettes.
#
# The bench is not always a well-lit desk: a dark room at night, a machine on a
# trolley in a bright workshop, and the operator reading at arm's length are all
# different problems. Each theme is a complete set, so nothing has to guess a
# derived colour, and every one keeps text well clear of its background.
THEMES = {
    "light": dict(
        GROUND=(234, 238, 244), PAPER=(255, 255, 255), INK=(17, 23, 32),
        MUTED=(106, 118, 132),  LINE=(226, 232, 241),  ACCENT=(47, 109, 246),
        PASS_=(15, 122, 79),  PASS_SOFT=(230, 244, 237),
        WARN_=(154, 100, 0),  WARN_SOFT=(253, 241, 221),
        FAIL_=(192, 52, 47),  FAIL_SOFT=(251, 234, 234),
        SHADOW=(208, 215, 226)),
    "dark": dict(
        GROUND=(15, 20, 27),   PAPER=(26, 33, 44),    INK=(228, 234, 243),
        MUTED=(140, 153, 170), LINE=(44, 55, 71),     ACCENT=(96, 158, 255),
        PASS_=(74, 212, 149), PASS_SOFT=(22, 52, 41),
        WARN_=(240, 187, 78), WARN_SOFT=(59, 46, 18),
        FAIL_=(255, 122, 112), FAIL_SOFT=(63, 29, 28),
        SHADOW=(10, 14, 19)),
    "contrast": dict(
        # PAPER is lifted off pure black so the card still has an edge; the
        # text contrast is unaffected at this level.
        GROUND=(0, 0, 0),      PAPER=(22, 22, 22),    INK=(255, 255, 255),
        MUTED=(200, 200, 200), LINE=(255, 255, 255),  ACCENT=(255, 214, 0),
        PASS_=(0, 255, 120),  PASS_SOFT=(0, 48, 24),
        WARN_=(255, 214, 0),  WARN_SOFT=(56, 46, 0),
        FAIL_=(255, 80, 80),  FAIL_SOFT=(64, 0, 0),
        SHADOW=(0, 0, 0)),
}
THEME_NAME = "light"

# Multiplies every font size and the row pitch with it, so the layout keeps its
# proportions instead of text overflowing boxes that stayed put.
TEXT_SCALE = 1.0

# How the home grid and the menus are drawn. "manual" (1.13): the service-
# manual sheet - drawing frame, title block, numbered callouts, a parts list
# carrying each test's result. "classic": the white tiles and cards of 1.0-1.12.
# Test screens keep the card look either way; this is navigation only.
LOOK = "manual"


def _diag_rev():
    """The toolkit version for the title block, read from lib.sh - the one
    place it is set - so it can never disagree with the report."""
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib.sh")) as f:
            for line in f:
                if line.startswith('DIAG_VERSION="'):
                    return line.split('"')[1]
    except OSError:
        pass
    return "-"

DIAG_REV = _diag_rev()

SETTINGS_FILE = os.path.join(os.environ.get("DIAG_RUN", "/run/diag"), "settings.conf")

def load_settings():
    """Applied before the first frame, so the operator's choice survives a
    restart of the renderer as well as a change made while it is running."""
    global TEXT_SCALE, LOOK
    try:
        with open(SETTINGS_FILE) as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k == "theme":
                    apply_theme(v)
                elif k == "look" and v in ("manual", "classic"):
                    LOOK = v
                elif k == "textscale":
                    try: TEXT_SCALE = max(0.75, min(2.5, float(v)))
                    except ValueError: pass
    except OSError:
        pass


def apply_theme(name):
    """Rebind the palette globals. Everything draws from these by name, so a
    rebind is all it takes - no colour is cached anywhere else."""
    global THEME_NAME, TONES
    pal = THEMES.get(name)
    if not pal:
        return False
    THEME_NAME = name
    g = globals()
    for k, v in pal.items():
        g[k] = v
    TONES = {
        "":       g["INK"],   "fg": g["INK"],     "muted": g["MUTED"],
        "dim":    g["MUTED"], "ok": g["PASS_"],   "warn":  g["WARN_"],
        "err":    g["FAIL_"], "accent": g["ACCENT"],
    }
    _STENCIL_CACHE.clear()      # icons are baked in the old colour
    _BRAND_CACHE.clear()
    return True

def anim_palette():
    """The current colours by name, for ssdanim.py - it runs in this process
    but is a separate module, so it cannot see the rebound globals itself."""
    g = globals()
    return {k: g[k] for k in THEMES["light"]}

TONES = {
    "":       INK,   "fg": INK,     "muted": MUTED, "dim": MUTED,
    "ok":     PASS_, "warn": WARN_, "err":   FAIL_, "accent": ACCENT,
}
BADGE = {
    "PASS": (PASS_, PASS_SOFT), "OK": (PASS_, PASS_SOFT),
    "WARN": (WARN_, WARN_SOFT), "MARGINAL": (WARN_, WARN_SOFT),
    "STOPPED": (WARN_, WARN_SOFT), "PARTIAL": (WARN_, WARN_SOFT),
    "FAIL": (FAIL_, FAIL_SOFT), "UNKNOWN": (MUTED, GROUND),
}

RADIUS = 20

# ---------------------------------------------------------------- framebuffer
class Framebuffer:
    def __init__(self, dev="/dev/fb0"):
        fake = os.environ.get("DIAG_FB_FILE")
        if fake:                       # test harness: render into a plain file
            self.w, self.h = [int(x) for x in
                              os.environ.get("DIAG_FB_SIZE", "1280,800").split(",")]
            self.bpp = 32
            self.stride = self.w * 4
            self.rowbytes = self.stride
            self.rawmode = "BGRX"
            if not os.path.exists(fake) or os.path.getsize(fake) != self.stride * self.h:
                with open(fake, "wb") as f:
                    f.write(b"\0" * (self.stride * self.h))
            self.fd = os.open(fake, os.O_RDWR)
            self.map = mmap.mmap(self.fd, self.stride * self.h,
                                 mmap.MAP_SHARED, mmap.PROT_WRITE | mmap.PROT_READ)
            return
        base = "/sys/class/graphics/fb0/"
        with open(base + "virtual_size") as f:
            self.w, self.h = [int(x) for x in f.read().strip().split(",")]
        with open(base + "bits_per_pixel") as f:
            self.bpp = int(f.read().strip())
        try:
            with open(base + "stride") as f:
                self.stride = int(f.read().strip())
        except OSError:
            self.stride = self.w * self.bpp // 8
        if self.bpp not in (16, 32):
            raise RuntimeError("unsupported framebuffer depth %d" % self.bpp)
        self.fd = os.open(dev, os.O_RDWR)
        self.map = mmap.mmap(self.fd, self.stride * self.h,
                             mmap.MAP_SHARED, mmap.PROT_WRITE | mmap.PROT_READ)
        self.rawmode = "BGRX" if self.bpp == 32 else "BGR;16"
        self.rowbytes = self.w * self.bpp // 8

    last = None                    # the frame on screen, without the pointer
    cursor = None                  # Cursor, once main() has made one

    def blit(self, img):
        data = img.tobytes("raw", self.rawmode)
        if self.stride == self.rowbytes:
            self.map.seek(0)
            self.map.write(data)
        else:                      # padded scanlines
            for y in range(self.h):
                self.map.seek(y * self.stride)
                self.map.write(data[y * self.rowbytes:(y + 1) * self.rowbytes])
        self.last = img
        if self.cursor is not None:
            self.cursor.drawn = None
            self.cursor.paint()

    def blit_region(self, patch, x, y):
        """Write a small image at (x, y). The mouse pointer moves many times a
        second; a full-frame write for each movement made it crawl."""
        w, h = patch.size
        bpp = self.rowbytes // self.w
        data = patch.tobytes("raw", self.rawmode)
        rb = w * bpp
        for r in range(h):
            self.map.seek((y + r) * self.stride + x * bpp)
            self.map.write(data[r * rb:(r + 1) * rb])

    def close(self):
        try: self.map.close()
        except Exception: pass
        try: os.close(self.fd)
        except Exception: pass


# ---------------------------------------------------------------- mouse pointer
def _cursor_sprite(h):
    """The classic arrow: white with a dark outline, so it shows on any
    background. Drawn four times oversize and scaled down for smooth edges."""
    S = 4
    n = h * S
    pts = [(0.0, 0.0), (0.0, 0.80), (0.22, 0.63), (0.36, 0.96), (0.48, 0.91),
           (0.34, 0.59), (0.60, 0.59)]
    pad = 2 * S
    img = Image.new("RGBA", (int(0.64 * n) + 2 * pad, n + 2 * pad), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.polygon([(pad + x * n, pad + y * n) for x, y in pts],
              fill=(255, 255, 255, 255), outline=(20, 20, 20, 255), width=max(2, S * 2))
    return img.resize((img.width // S, img.height // S), Image.LANCZOS)


class Cursor:
    """The mouse pointer, painted over the frame on screen in a small region.

    Hidden until a pointing device first moves, and switched off entirely
    during the full-screen tests: on the black page of the screen test a white
    arrow is indistinguishable from a stuck pixel."""
    def __init__(self, fb, s):
        self.fb = fb
        self.sprite = _cursor_sprite(max(16, int(26 * s)))
        self.x, self.y = fb.w // 2, fb.h // 2
        self.visible = False
        self.enabled = True
        self.drawn = None

    def _box(self):
        w, h = self.sprite.size
        return (self.x, self.y, min(self.fb.w, self.x + w), min(self.fb.h, self.y + h))

    def paint(self):
        if not (self.visible and self.enabled) or self.fb.last is None:
            return
        box = self._box()
        if box[2] <= box[0] or box[3] <= box[1]:
            return
        patch = self.fb.last.crop(box).convert("RGB")
        patch.paste(self.sprite, (0, 0), self.sprite)
        self.fb.blit_region(patch, box[0], box[1])
        self.drawn = box

    def erase(self):
        if self.drawn and self.fb.last is not None:
            b = self.drawn
            self.fb.blit_region(self.fb.last.crop(b).convert("RGB"), b[0], b[1])
        self.drawn = None

    def move_to(self, x, y):
        x = max(0, min(self.fb.w - 1, int(x)))
        y = max(0, min(self.fb.h - 1, int(y)))
        if self.visible and (x, y) == (self.x, self.y):
            return
        self.erase()
        self.x, self.y = x, y
        self.visible = True
        self.paint()

    def set_enabled(self, on):
        if not on:
            self.erase()
        self.enabled = on
        if on:
            self.paint()


def _in(box, xy):
    return bool(box) and box[0] <= xy[0] < box[2] and box[1] <= xy[1] < box[3]


# ---------------------------------------------------------------- wifi status
def wifi_status():
    """(state, bars, ssid) for the header icon, from sysfs and procfs only -
    this runs every few seconds and must not start processes.

    state: none (no adapter), off (radio blocked), down (not connected),
           noip (joined, no address) or up.
    """
    try:
        names = sorted(os.listdir("/sys/class/net"))
    except OSError:
        return ("none", 0, "")
    ifs = [n for n in names if os.path.isdir("/sys/class/net/%s/wireless" % n)
           or os.path.exists("/sys/class/net/%s/phy80211" % n)]
    if not ifs:
        return ("none", 0, "")
    blocked, radios = 0, 0
    for r in glob.glob("/sys/class/rfkill/rfkill*"):
        try:
            if open(r + "/type").read().strip() != "wlan":
                continue
            radios += 1
            if open(r + "/soft").read().strip() == "1" or open(r + "/hard").read().strip() == "1":
                blocked += 1
        except OSError:
            continue
    try:
        routes = open("/proc/net/route").read().split("\n")[1:]
    except OSError:
        routes = []
    try:
        wl = open("/proc/net/wireless").read().split("\n")[2:]
    except OSError:
        wl = []
    ssid_file = ""
    try:
        ssid_file = open("/run/diag/wifi.state").read().strip()
    except OSError:
        pass
    for i in ifs:
        try:
            oper = open("/sys/class/net/%s/operstate" % i).read().strip()
        except OSError:
            continue
        if oper != "up":
            continue
        level = None
        for line in wl:
            f = line.split()
            if f and f[0].rstrip(":") == i and len(f) > 3:
                try: level = int(float(f[3].rstrip(".")))
                except ValueError: pass
        bars = 1
        if level is not None:
            bars = 3 if level >= -60 else (2 if level >= -72 else 1)
        has_ip = any(r.split("\t")[0] == i for r in routes if r.strip())
        ssid = ""
        if ssid_file.startswith(i + "\t"):
            ssid = ssid_file.split("\t", 1)[1]
        return ("up" if has_ip else "noip", bars, ssid)
    if radios and blocked == radios:
        return ("off", 0, "")
    return ("down", 0, "")


def _draw_wifi_status(d, cx, cy, size, st):
    """Three arcs and a dot. Connected: lit arcs for signal strength. Joined but
    no address: amber. Not connected: grey. Off or no adapter: grey, struck
    through."""
    state, bars, _ = st
    u = size / 24.0
    by = cy + 7 * u                           # centre of the arcs, at the dot
    w = max(2, int(2.4 * u))
    if state == "up":
        # Unlit arcs halfway between grey and the background: LINE vanished
        # against the header and one bar read as a bare dot.
        dim = tuple((a + b) // 2 for a, b in zip(MUTED, GROUND))
        cols = [INK if k < bars else dim for k in range(3)]
        dotc = INK
    elif state == "noip":
        cols = [WARN_] * 3; dotc = WARN_
    else:
        cols = [MUTED] * 3; dotc = MUTED
    for k, rad in enumerate((6.0, 10.5, 15.0)):
        r = rad * u
        d.arc([cx - r, by - r, cx + r, by + r], 225, 315, fill=cols[k], width=w)
    rd = 2.0 * u
    d.ellipse([cx - rd, by - rd, cx + rd, by + rd], fill=dotc)
    if state in ("off", "none"):
        d.line([(cx - 11 * u, cy - 9 * u), (cx + 11 * u, cy + 9 * u)], fill=MUTED, width=w)


# ---------------------------------------------------------------- tile icons
# Line art drawn with primitives - no image files to ship, and it scales with
# the panel. Each function draws inside a square box centred on (cx, cy).
# ---------------------------------------------------------------- brand mark
# PIL draws shapes with hard, aliased edges: a small filled circle on a laptop
# panel comes out visibly stepped, which is what made the old dot look rough.
# Everything here is drawn oversized and resampled down, so the curves land on
# smooth, blended pixels. Cached per size - it is the same mark on every screen
# and there is no reason to redraw it each frame.
_BRAND_CACHE = {}

def _brandmark(px):
    """The toolkit's own mark: a rounded chip carrying a diagnostic pulse."""
    px = max(10, int(px))
    hit = _BRAND_CACHE.get(px)
    if hit is not None:
        return hit
    S = 8
    n = px * S
    m = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    dd = ImageDraw.Draw(m)
    dd.rounded_rectangle([0, 0, n - 1, n - 1], radius=int(n * 0.30), fill=ACCENT)
    w = max(2, int(n * 0.10))
    pts = [(n * 0.17, n * 0.55), (n * 0.34, n * 0.55), (n * 0.44, n * 0.30),
           (n * 0.57, n * 0.74), (n * 0.66, n * 0.48), (n * 0.83, n * 0.48)]
    dd.line(pts, fill=PAPER, width=w, joint="curve")
    for px0, py0 in (pts[0], pts[-1]):          # rounded ends
        dd.ellipse([px0 - w / 2, py0 - w / 2, px0 + w / 2, py0 + w / 2], fill=PAPER)
    m = m.resize((px, px), Image.LANCZOS)
    _BRAND_CACHE[px] = m
    return m


# ---------------------------------------------------------------- icon files
# Ash supplied the icon set as 24x24 stroke artwork exported to PNG. They are a
# single flat colour with an alpha channel, so the alpha is used as a stencil
# and filled with whatever colour the tile needs - which is the only way a tile
# can invert to white when it is selected without shipping a second set.
ICON_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")
ICON_FILES = {
    "play": "01-full-run",      "disk": "02-hdd-ssd",    "cliff": "03-install-sim",
    "cpu": "04-cpu",            "ram": "05-ram",         "battery": "06-battery",
    "keyboard": "07-keyboard",  "touchpad": "08-touchpad", "sound": "09-sound",
    "usb": "10-usb",            "camera": "11-camera",   "network": "12-network",
    "wifi": "13-wireless",      "info": "14-system",     "pencil": "15-machine-details",
    "chip": "16-dmi-capture",   "download": "17-get-firmware", "list": "18-results",
    "save": "19-save-report",
}
_STENCIL_CACHE = {}

def _icon_file(name, size, col):
    """The supplied artwork at `size`, recoloured. None when not supplied."""
    key = (name, size, col)
    hit = _STENCIL_CACHE.get(key)
    if hit is not None:
        return hit
    stem = ICON_FILES.get(name)
    if not stem:
        return None
    path = os.path.join(ICON_DIR, stem + ".png")
    if not os.path.exists(path):
        return None
    try:
        src = Image.open(path).convert("RGBA").resize((size, size), Image.LANCZOS)
    except Exception:
        return None
    out = Image.new("RGBA", (size, size), tuple(col) + (255,))
    out.putalpha(src.getchannel("A"))
    _STENCIL_CACHE[key] = out
    return out


def _icon_smooth(name, base, cx, cy, size, col):
    """Paint a tile icon with anti-aliased edges.

    _icon draws with PIL primitives straight onto the screen, so every
    diagonal and curve came out stepped. Painting the same artwork four
    times oversized onto its own transparent tile and resampling it down
    blends those edges, which is most of what makes the grid look sharp.
    """
    size = max(8, int(size))
    lay = _icon_file(name, size, col)
    if lay is None:
        # Not in the supplied set - draw it, oversized then resampled so its
        # edges match the artwork's own anti-aliasing.
        S = 4
        n = size * S
        lay = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        _icon(name, ImageDraw.Draw(lay), n / 2.0, n / 2.0, n, col)
        lay = lay.resize((size, size), Image.LANCZOS)
    base.paste(lay, (int(cx - size // 2), int(cy - size // 2)), lay)


def _draw_brand(base, x, cy, size):
    """Paste the mark onto an RGB canvas, keeping its soft edges."""
    mk = _brandmark(size)
    base.paste(mk, (int(x), int(cy - mk.height // 2)), mk)


def _icon(name, d, cx, cy, size, col):
    """One coherent set, drawn on a 24x24 grid.

    Rules the whole set obeys, so the tiles read as one family:
      * a single stroke weight everywhere, scaled from the tile size
      * round caps and joins - PIL has neither, so `pl` fakes them with a dot
        at every vertex, which is what stops the shapes looking chipped
      * outline by default; solid fill only where it carries meaning
        (the play triangle, an indicator dot, the camera shutter)
      * artwork kept inside a 3..21 box so every icon has the same optical
        size - without that, wide icons look bigger than tall ones
    """
    u = size / 24.0
    def X(v): return cx + (v - 12) * u
    def Y(v): return cy + (v - 12) * u
    w = max(2, int(1.7 * u))              # the supplied set's stroke weight
    r_cap = w / 2.0

    def dot(x, y, rad=None):
        rad = r_cap if rad is None else rad * u
        d.ellipse([X(x) - rad, Y(y) - rad, X(x) + rad, Y(y) + rad], fill=col)

    def pl(pts, close=False, caps=True):
        """Polyline with round joins and caps."""
        p = [(X(a), Y(b)) for a, b in pts]
        if close:
            p = p + [p[0]]
        d.line(p, fill=col, width=w, joint="curve")
        ends = p if close else p
        for (px, py) in (ends if caps else p[1:-1]):
            d.ellipse([px - r_cap, py - r_cap, px + r_cap, py + r_cap], fill=col)

    def ln(x0, y0, x1, y1):
        pl([(x0, y0), (x1, y1)])

    def box(x0, y0, x1, y1, rad=2.5):
        d.rounded_rectangle([X(x0), Y(y0), X(x1), Y(y1)], rad * u,
                            outline=col, width=w)

    def solidbox(x0, y0, x1, y1, rad=1.5):
        d.rounded_rectangle([X(x0), Y(y0), X(x1), Y(y1)], rad * u, fill=col)

    def circ(x, y, rad, fill=None):
        d.ellipse([X(x - rad), Y(y - rad), X(x + rad), Y(y + rad)],
                  outline=col, width=w, fill=fill)

    def arc(x, y, rad, a0, a1):
        d.arc([X(x - rad), Y(y - rad), X(x + rad), Y(y + rad)], a0, a1,
              fill=col, width=w)

    # ---------------------------------------------------------------- run
    if name == "play":                                    # full run
        circ(12, 12, 9)
        d.polygon([(X(9.8), Y(7.6)), (X(16.6), Y(12)), (X(9.8), Y(16.4))], fill=col)

    elif name == "grid":                                  # peripherals
        for x in (3.5, 13.5):
            for y in (3.5, 13.5):
                box(x, y, x + 7, y + 7, 2.0)

    elif name == "expand":                                # show every tile
        for x in (3.5, 13.5):
            for y in (3.5, 13.5):
                box(x, y, x + 7, y + 7, 1.8)
        ln(8.5, 12, 15.5, 12); ln(12, 8.5, 12, 15.5)

    # ---------------------------------------------------------------- storage
    elif name == "disk":                                  # HDD / SSD
        d.ellipse([X(3.5), Y(3.5), X(20.5), Y(8.5)], outline=col, width=w)
        ln(3.5, 6, 3.5, 18); ln(20.5, 6, 20.5, 18)
        d.arc([X(3.5), Y(9.5), X(20.5), Y(14.5)], 0, 180, fill=col, width=w)
        d.arc([X(3.5), Y(15.5), X(20.5), Y(20.5)], 0, 180, fill=col, width=w)

    elif name == "cliff":                                 # install simulation
        # The shape of the test itself: fast while the cache absorbs the write,
        # then the drop to raw flash a short benchmark never reaches.
        pl([(3.5, 4), (3.5, 20.5), (20.5, 20.5)])         # axes
        pl([(6, 7.5), (11.2, 7.5), (13.6, 16.5), (20, 16.5)])
        dot(13.6, 16.5, 1.7)

    elif name == "surface":                               # surface scan
        # the supplied hdd-ssd mark, under a magnifier
        box(3, 4.5, 17, 14.5, 2.0)
        circ(10, 9.5, 2.6)
        dot(10, 9.5, 0.7)
        circ(15.8, 15.8, 4.4)
        pl([(19.0, 19.0), (21.2, 21.2)])

    # ---------------------------------------------------------------- core
    elif name == "cpu":
        box(6.5, 6.5, 17.5, 17.5, 2.2)
        box(10, 10, 14, 14, 1.0)
        for v in (9, 12, 15):
            ln(v, 3.2, v, 6.5); ln(v, 17.5, v, 20.8)
            ln(3.2, v, 6.5, v); ln(17.5, v, 20.8, v)

    elif name == "ram":
        box(3, 7.5, 21, 16.5, 2.2)
        for x in (7, 10, 13, 17):
            ln(x, 10, x, 14)
        ln(8, 16.5, 8, 18.5); ln(16, 16.5, 16, 18.5)

    elif name == "battery":
        box(2.5, 7.5, 19, 16.5, 2.4)
        solidbox(4.8, 9.8, 13.5, 14.2, 1.0)
        pl([(20.4, 10.4), (20.4, 13.6)])

    elif name == "charge":                                # charging - the battery with a bolt
        box(2.5, 7.5, 19, 16.5, 2.4)
        pl([(20.4, 10.4), (20.4, 13.6)])
        d.polygon([(X(12.4), Y(8.9)), (X(7.6), Y(12.6)), (X(10.4), Y(12.6)),
                   (X(9.4), Y(15.1)), (X(14.2), Y(11.4)), (X(11.4), Y(11.4))], fill=col)

    # ---------------------------------------------------------------- input
    elif name == "keyboard":
        box(2.5, 6.5, 21.5, 17.5, 2.4)
        for y in (9.6, 12.4):
            for x in (5.4, 8.4, 11.4, 14.4, 17.4):
                dot(x, y, 0.85)
        ln(8, 15.2, 16, 15.2)

    elif name == "touchscreen":                           # screen with a tap on it
        box(2.5, 4, 21.5, 16.5, 2.2)
        ln(12, 16.5, 12, 20); ln(8, 20, 16, 20)
        # a fingertip landing: solid dot with one ring spreading out from it
        dot(12, 10.2, 1.6)
        circ(12, 10.2, 3.8)

    elif name == "screen":                                # dead-pixel test
        # a monitor whose panel is a grid of pixels, one of them dark
        box(2.5, 4, 21.5, 16.5, 2.2)
        ln(12, 16.5, 12, 20); ln(8, 20, 16, 20)
        for gx in (7.5, 12, 16.5):
            for gy in (7.8, 12.6):
                if (gx, gy) == (16.5, 7.8):
                    circ(gx, gy, 1.3)
                else:
                    dot(gx, gy, 1.3)

    elif name == "touchpad":
        box(3.5, 5, 20.5, 19, 2.6)
        ln(3.5, 14.6, 20.5, 14.6)
        ln(12, 14.6, 12, 19)

    # ---------------------------------------------------------------- sound
    elif name == "sound":
        d.polygon([(X(4), Y(9.5)), (X(8), Y(9.5)), (X(12), Y(5.5)),
                   (X(12), Y(18.5)), (X(8), Y(14.5)), (X(4), Y(14.5))], fill=col)
        arc(12, 12, 5.0, 300, 60)
        arc(12, 12, 8.0, 305, 55)

    # ---------------------------------------------------------------- ports
    elif name == "usb":
        ln(12, 4.5, 12, 19.5)
        dot(12, 20.2, 1.6)
        d.polygon([(X(12), Y(3)), (X(10.3), Y(6.2)), (X(13.7), Y(6.2))], fill=col)
        pl([(12, 13), (7.5, 9.5), (7.5, 8)])
        circ(7.5, 6.6, 1.5, fill=col)
        pl([(12, 16), (16.5, 12.5), (16.5, 11)])
        solidbox(15.1, 8.4, 17.9, 11.0, 0.6)

    # ---------------------------------------------------------------- camera
    elif name == "camera":
        box(2.5, 7, 21.5, 19.5, 2.6)
        pl([(8, 7), (9.6, 4.5), (14.4, 4.5), (16, 7)])
        circ(12, 13.2, 3.6)

    # ---------------------------------------------------------------- network
    elif name == "network":                               # wired ethernet
        box(4, 9, 20, 19.5, 2.2)
        for x in (7.2, 9.8, 12.4, 15, 17.6):
            ln(x, 11.4, x, 13.6)
        ln(12, 4.5, 12, 9)
        ln(8.5, 4.5, 15.5, 4.5)

    elif name == "wifi":                                  # wireless
        for rad in (10.0, 6.8, 3.6):
            arc(12, 14.5, rad, 212, 328)
        dot(12, 18.5, 1.5)

    # ---------------------------------------------------------------- info
    elif name == "info":
        circ(12, 12, 9)
        dot(12, 7.6, 1.15)
        ln(12, 11, 12, 16.4)

    elif name == "pencil":                                # machine details
        pl([(4.2, 19.8), (5.8, 15.6), (16.4, 5), (19, 7.6), (8.4, 18.2)],
           close=True)
        ln(14.6, 6.8, 17.2, 9.4)

    elif name == "chip":                                  # DMI capture - an ID card
        box(2.5, 5, 21.5, 19, 2.6)
        circ(7.8, 11, 2.3)
        arc(4.4, 13.2, 3.6, 200, 340)
        ln(13.5, 9.8, 19, 9.8)
        ln(13.5, 12.6, 19, 12.6)
        ln(13.5, 15.4, 17, 15.4)

    elif name == "download":                              # get firmware
        pl([(12, 2.5), (12, 9.6)])
        d.polygon([(X(8.4), Y(7.4)), (X(15.6), Y(7.4)), (X(12), Y(12))], fill=col)
        box(6.5, 13, 17.5, 21, 2.0)
        for v in (9, 12, 15):
            ln(v, 21, v, 22.5)
        ln(4.8, 15.5, 6.5, 15.5); ln(4.8, 18.5, 6.5, 18.5)
        ln(17.5, 15.5, 19.2, 15.5); ln(17.5, 18.5, 19.2, 18.5)

    elif name == "list":                                  # results
        for y in (6.8, 12, 17.2):
            dot(5, y, 1.25)
            ln(9.5, y, 19.5, y)

    elif name == "save":                                  # save the report
        pl([(5, 21), (5, 3), (14.5, 3), (19, 7.5), (19, 21)], close=True)
        pl([(14.5, 3), (14.5, 7.5), (19, 7.5)])           # folded corner
        pl([(12, 10.5), (12, 16.6)])
        d.polygon([(X(9.2), Y(14.2)), (X(14.8), Y(14.2)), (X(12), Y(18.2))], fill=col)

    elif name == "gear":                                  # settings
        circ(12, 12, 4.2)
        # eight teeth around the hub
        import math as _m
        for k in range(8):
            a = _m.radians(k * 45)
            x0 = 12 + 6.4 * _m.cos(a); y0 = 12 + 6.4 * _m.sin(a)
            x1 = 12 + 9.6 * _m.cos(a); y1 = 12 + 9.6 * _m.sin(a)
            pl([(x0, y0), (x1, y1)])

    elif name == "terminal":                              # command prompt
        box(2.5, 4.5, 21.5, 19.5, 2.4)
        pl([(6.5, 9.5), (10.5, 12), (6.5, 14.5)])
        ln(12.5, 15.2, 17.5, 15.2)

    elif name == "mouse":
        box(6.5, 3, 17.5, 21, 5.5)
        ln(12, 7, 12, 11)

    else:
        # A name with no artwork draws a plain ring rather than nothing, so a
        # missing icon is visible on the tile instead of silently blank.
        circ(12, 12, 8)


# ---------------------------------------------------------------- console mode
KDSETMODE, KD_TEXT, KD_GRAPHICS = 0x4B3A, 0x00, 0x01


def console(mode):
    """Stop (or restart) the kernel console drawing over us."""
    if os.environ.get("DIAG_FB_FILE"):
        return True
    for dev in ("/dev/tty0", "/dev/console"):
        try:
            fd = os.open(dev, os.O_RDWR)
            fcntl.ioctl(fd, KDSETMODE, mode)
            os.close(fd)
            return True
        except Exception:
            continue
    return False


# ---------------------------------------------------------------- input
EVIOCGRAB = 0x40044590   # _IOW('E', 0x90, int) - value checked against the header
EV_KEY = 0x01
EVENT_FMT = "llHHi" if struct.calcsize("l") == 8 else "iiHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)

KEYNAME = {
    1: "esc", 28: "enter", 96: "enter", 103: "up", 108: "down", 105: "left",
    106: "right", 57: "space", 14: "backspace", 15: "tab",
    2: "1", 3: "2", 4: "3", 5: "4", 6: "5", 7: "6", 8: "7", 9: "8", 10: "9", 11: "0",
    16: "q", 17: "w", 18: "e", 19: "r", 20: "t", 21: "y", 22: "u", 23: "i", 24: "o",
    25: "p", 30: "a", 31: "s", 32: "d", 33: "f", 34: "g", 35: "h", 36: "j", 37: "k",
    38: "l", 44: "z", 45: "x", 46: "c", 47: "v", 48: "b", 49: "n", 50: "m",
    104: "pgup", 109: "pgdn", 102: "home", 107: "end",
}
SHIFTED = {2: "!", 3: "@", 4: "#", 5: "$", 6: "%", 7: "^", 8: "&", 9: "*", 10: "(", 11: ")"}

class Keyboard:
    """Reads keyboards straight from evdev and grabs them, so nothing leaks to
    the console and there is no 10-second limit imposed by an external tool."""
    # Mouse, touchpad and touchscreen turn into these names, alongside keys.
    # click: at click_xy. back: right button or two-finger tap - same as Esc.
    # hover: the pointer moved (rate-limited). wheelup / wheeldown: scrolling.
    POINTER_EVENTS = ("click", "back", "hover", "wheelup", "wheeldown")

    def __init__(self, grab=True):
        self.script = os.environ.get("DIAG_UI_KEYS")
        self.fds, self.paths = [], []
        self.cursor = None        # set by main(); no pointer support until then
        self.tick = None          # called about once a second while waiting
        self.s = 1.0
        self.ptr = {}             # fd -> pointing-device state
        self.shared = {}          # keyboard fd -> pointer state, same device
        self.ptr_scan = 0.0
        self.click_xy = (0, 0)
        self._last_hover = 0.0
        self._last_tick = 0.0
        if self.script:
            self.sfd = os.open(self.script, os.O_RDONLY | os.O_NONBLOCK)
            self.sbuf = b""
            self.shift = False
            self.caps = False
            return
        for path in self._keyboards():
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                if grab:
                    try: fcntl.ioctl(fd, EVIOCGRAB, 1)
                    except Exception: pass
                self.fds.append(fd); self.paths.append(path)
            except Exception:
                pass
        self.shift = False
        # Caps Lock is tracked here because the test grabs the keyboard, so the
        # console never sees the key and cannot do it for us.
        self.caps = False

    @staticmethod
    def _keyboards():
        out, block = [], {}
        try:
            with open("/proc/bus/input/devices") as f:
                text = f.read()
        except OSError:
            return out
        for chunk in text.split("\n\n"):
            if "kbd" not in chunk:
                continue
            for line in chunk.splitlines():
                if line.startswith("H: Handlers="):
                    for h in line.split("=", 1)[1].split():
                        if h.startswith("event"):
                            out.append("/dev/input/" + h)
        return out

    def poll(self, timeout):
        """Returns (name, keycode) of the next key press, or (None, None)."""
        if self.script:
            end = time.time() + timeout
            while time.time() < end:
                r, _, _ = select.select([self.sfd], [], [], 0.05)
                if r:
                    self.sbuf += os.read(self.sfd, 4096)
                if b"\n" in self.sbuf:
                    raw, self.sbuf = self.sbuf.split(b"\n", 1)
                    name = raw.decode().strip()
                    if name:
                        return name, 0
            return None, None
        end = time.time() + timeout
        while True:
            now = time.time()
            left = end - now
            if left <= 0:
                return None, None
            if self.cursor is not None and now - self.ptr_scan > 3.0:
                self._scan_pointers()             # a USB mouse plugged in later
            fds = self.fds + list(self.ptr)
            if not fds:
                time.sleep(min(left, 0.5))
                self._do_tick()
                if not self.fds and self.cursor is None:
                    return None, None
                continue
            # Wake at least once a second so the clock and Wi-Fi icon in the
            # header keep up while a menu sits waiting.
            r, _, _ = select.select(fds, [], [], min(left, 1.0))
            if time.time() - self._last_tick >= 1.0:
                self._do_tick()
            for fd in r:
                if fd in self.ptr:
                    ev = self._read_pointer(fd)
                    if ev == "hover":
                        if time.time() - self._last_hover < 0.04:
                            continue
                        self._last_hover = time.time()
                    if ev:
                        return ev, 0
                    continue
                try: data = os.read(fd, EVENT_SIZE * 64)
                except OSError: continue
                pev = None
                for i in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                    _, _, etype, code, value = struct.unpack(
                        EVENT_FMT, data[i:i + EVENT_SIZE])
                    st = self.shared.get(fd)
                    if st is not None and (etype != EV_KEY or code >= BTN_LEFT):
                        ev = self._ptr_event(st, etype, code, value)
                        if ev and (pev is None or pev == "hover"):
                            pev = ev
                        continue
                    if etype != EV_KEY:
                        continue
                    if code in (42, 54):
                        self.shift = bool(value)
                        continue
                    if code == 58:                 # Caps Lock toggles on press
                        if value == 1:
                            self.caps = not self.caps
                        continue
                    if value != 1:        # press only, ignore repeat/release
                        continue
                    name = KEYNAME.get(code)
                    if self.shift and code in SHIFTED:
                        name = SHIFTED[code]
                    return name, code
                if pev == "hover" and time.time() - self._last_hover < 0.04:
                    pev = None
                if pev:
                    if pev == "hover":
                        self._last_hover = time.time()
                    return pev, 0

    def drain(self):
        if self.script:
            return
        for fd in self.fds + list(self.ptr):
            try:
                while os.read(fd, EVENT_SIZE * 64):
                    pass
            except OSError:
                pass
        for st in list(self.ptr.values()) + list(self.shared.values()):
            st.update(touch=False, last=None, btn=[], dx=0, dy=0, wheel=0)

    # ---- pointing devices ------------------------------------------
    # Read alongside the keyboards but never grabbed: the touchpad and mouse
    # tests grab their device while they run, and a grab is exclusive, so the
    # pointer simply goes quiet during those tests instead of fighting them.
    def _do_tick(self):
        self._last_tick = time.time()
        if self.tick:
            try: self.tick()
            except Exception: pass

    def _scan_pointers(self):
        self.ptr_scan = time.time()
        have = {st["path"] for st in self.ptr.values()}
        have |= {st["path"] for st in self.shared.values()}
        for path, name, kind in Pointer._devices():
            if path in have:
                continue
            # A keyboard-and-mouse receiver can be one event node. The keyboard
            # side already holds it grabbed, which is exclusive, so its pointer
            # events are routed from the keyboard read instead.
            shared = path in self.paths
            if shared:
                fd = self.fds[self.paths.index(path)]
            else:
                try:
                    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                except OSError:
                    continue
            # Ranges for every kind: a "mouse" can be absolute too (USB
            # tablets, KVM switches, VMware/QEMU's vmmouse) - it reports where
            # the pointer IS, not how far it moved.
            rng = Pointer._absrange(fd)
            xr = rng.get(ABS_X) or rng.get(ABS_MT_POSITION_X) or (0, 1000)
            yr = rng.get(ABS_Y) or rng.get(ABS_MT_POSITION_Y) or (0, 1000)
            # A touchpad crossed edge to edge moves the pointer about 1.2
            # screen widths - close to what libinput feels like.
            k = 1.2 * self.cursor.fb.w / max(1, xr[1] - xr[0])
            (self.shared if shared else self.ptr)[fd] = {
                            "path": path, "kind": kind, "rng": rng, "xr": xr, "yr": yr,
                            "k": k, "x": None, "y": None, "last": None, "touch": False,
                            "t0": 0.0, "moved": 0.0, "fingers": 1, "clicked": False,
                            "scroll": 0.0, "dx": 0, "dy": 0, "wheel": 0, "btn": []}

    def _read_pointer(self, fd):
        st = self.ptr[fd]
        try:
            data = os.read(fd, EVENT_SIZE * 64)
        except BlockingIOError:
            return None
        except OSError:                       # ENODEV: the device was unplugged
            try: os.close(fd)
            except OSError: pass
            del self.ptr[fd]
            return None
        if not data:
            return None
        out = None
        for i in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
            _, _, etype, code, value = struct.unpack(EVENT_FMT, data[i:i + EVENT_SIZE])
            ev = self._ptr_event(st, etype, code, value)
            if ev and (out is None or out == "hover"):
                out = ev
        return out

    def _ptr_event(self, st, etype, code, value):
        """One evdev event into the device state; a pointer event at each
        SYN_REPORT, when the frame is complete."""
        rng = st["rng"]
        if etype == EV_REL:
            if code == REL_X: st["dx"] += value
            elif code == REL_Y: st["dy"] += value
            elif code == REL_WHEEL: st["wheel"] += value
        elif etype == EV_ABS:
            # Single-touch axes when the device has them, else slot data.
            if code == ABS_X or (code == ABS_MT_POSITION_X and ABS_X not in rng):
                st["x"] = value; st["absmoved"] = True
            elif code == ABS_Y or (code == ABS_MT_POSITION_Y and ABS_Y not in rng):
                st["y"] = value; st["absmoved"] = True
        elif etype == EV_KEY:
            st["btn"].append((code, value))
        elif etype == EV_SYN:
            return self._pointer_frame(st)
        return None

    def _pointer_frame(self, st):
        c = self.cursor
        now = time.time()
        kind = st["kind"]
        ev = None
        btns, st["btn"] = st["btn"], []
        for code, value in btns:
            if code in (BTN_TOOL_DOUBLETAP, BTN_TOOL_TRIPLETAP, BTN_TOOL_QUADTAP) and value:
                st["fingers"] = max(st["fingers"], 2)
            if code == BTN_TOUCH:
                if value:
                    st.update(touch=True, t0=now, moved=0.0, last=None, fingers=1,
                              clicked=False, scroll=0.0)
                else:
                    # A tap: short, barely moving, no physical click during it.
                    tap = (st["touch"] and now - st["t0"] < 0.25
                           and st["moved"] < 14 * self.s and not st["clicked"])
                    st["touch"] = False
                    st["last"] = None
                    if kind == "touchscreen":
                        ev = "click"
                    elif tap:
                        ev = "back" if st["fingers"] >= 2 else "click"
            elif code == BTN_LEFT and value == 1:
                # Clickpads report a two-finger press as a left button.
                ev = "back" if (kind == "touchpad" and st["fingers"] >= 2) else "click"
                st["clicked"] = True
            elif code == BTN_RIGHT and value == 1:
                ev = "back"
        moved = False
        if kind == "mouse" and st.get("absmoved") and st["x"] is not None \
                and st["y"] is not None:
            # An absolute mouse: map its position straight onto the screen.
            (x0, x1), (y0, y1) = st["xr"], st["yr"]
            c.move_to((st["x"] - x0) * c.fb.w / max(1, x1 - x0),
                      (st["y"] - y0) * c.fb.h / max(1, y1 - y0))
            st["absmoved"] = False
            moved = True
        elif kind == "mouse":
            dx, dy = st["dx"], st["dy"]
            if dx or dy:
                # A little acceleration, so a small mouse still crosses a wide
                # panel without being lifted.
                acc = 1.0 + min(2.0, (abs(dx) + abs(dy)) / 12.0)
                c.move_to(c.x + dx * acc, c.y + dy * acc)
                moved = True
        elif kind == "touchscreen":
            if st["touch"] and st["x"] is not None and st["y"] is not None:
                (x0, x1), (y0, y1) = st["xr"], st["yr"]
                c.move_to((st["x"] - x0) * c.fb.w / max(1, x1 - x0),
                          (st["y"] - y0) * c.fb.h / max(1, y1 - y0))
                moved = True
        elif st["touch"] and st["x"] is not None and st["y"] is not None:
            if st["last"] is not None:
                dx = (st["x"] - st["last"][0]) * st["k"]
                dy = (st["y"] - st["last"][1]) * st["k"]
                st["moved"] += abs(dx) + abs(dy)
                if st["fingers"] >= 2:             # two fingers: scroll
                    st["scroll"] += dy
                    if abs(st["scroll"]) > 45 * self.s:
                        ev = ev or ("wheelup" if st["scroll"] < 0 else "wheeldown")
                        st["scroll"] = 0.0
                else:
                    c.move_to(c.x + dx, c.y + dy)
                    moved = True
            st["last"] = (st["x"], st["y"])
        if st["wheel"]:
            ev = ev or ("wheelup" if st["wheel"] > 0 else "wheeldown")
        st["dx"] = st["dy"] = st["wheel"] = 0
        if ev:
            self.click_xy = (c.x, c.y)
            return ev
        return "hover" if moved else None

    def close(self):
        for fd in list(self.ptr):
            try: os.close(fd)
            except Exception: pass
        self.ptr = {}
        if self.script:
            try: os.close(self.sfd)
            except Exception: pass
            return
        for fd in self.fds:
            try: fcntl.ioctl(fd, EVIOCGRAB, 0)
            except Exception: pass
            try: os.close(fd)
            except Exception: pass


# ---------------------------------------------------------------- screen
def _pick_number(kb, name, n):
    """A menu can have more than nine entries, so a digit may be the first of
    two. Wait briefly for a second digit when one could still make a valid
    choice; otherwise take the single digit straight away."""
    if not (name and name.isdigit()):
        return None
    first = int(name)
    if first == 0:
        return 10 if n >= 10 else None
    if first * 10 <= n:                      # a second digit could still follow
        nxt, _ = kb.poll(0.7)
        if nxt and nxt.isdigit():
            both = first * 10 + int(nxt)
            if 1 <= both <= n:
                return both
    return first if 1 <= first <= n else None


def font(path_list, size):
    """A scalable font, or a loud complaint.

    load_default() is a fixed ~11px bitmap that silently ignores `size`, so
    falling back to it turns one missing file into permanently tiny text with
    no other symptom. Say so on stderr - the toolkit log keeps it - rather than
    letting it pass unnoticed.
    """
    for p in path_list:
        try: return ImageFont.truetype(p, size)
        except Exception: continue
    sys.stderr.write("ui: no usable font among %s - falling back to the "
                     "fixed bitmap, text will be tiny\n" % (path_list,))
    return ImageFont.load_default()

PLEX = "/usr/share/fonts/truetype/ibm-plex/"
DEJA = "/usr/share/fonts/truetype/dejavu/"
# Carlito is metric-compatible with Calibri and redistributable, which Calibri
# itself is not. Same proportions, same feel, no licence problem on a bootable
# image handed to a customer.
CARL = "/usr/share/fonts/truetype/crosextra/"
UI_R  = [CARL + "Carlito-Regular.ttf", PLEX + "IBMPlexSans-Regular.ttf",  DEJA + "DejaVuSans.ttf"]
UI_B  = [CARL + "Carlito-Bold.ttf",    PLEX + "IBMPlexSans-SemiBold.ttf", DEJA + "DejaVuSans-Bold.ttf"]
# DejaVu is listed first for the monospaced faces because it is the one the
# image actually ships. IBM Plex Mono stays as a preference for anyone building
# with it installed.
MONO_R = [PLEX + "IBMPlexMono-Regular.ttf", DEJA + "DejaVuSansMono.ttf"]
MONO_B = [PLEX + "IBMPlexMono-Medium.ttf",  DEJA + "DejaVuSansMono-Bold.ttf"]

class Screen:
    def _build_fonts(self):
        """(Re)make every font and the row pitch for the current text scale."""
        s = self.s * TEXT_SCALE
        self.f_brand = font(UI_B, int(27 * s))
        self.f_body  = font(UI_R, int(22 * s))
        self.f_bodyb = font(UI_B, int(22 * s))
        self.f_small = font(UI_R, int(18 * s))
        self.f_tile  = font(UI_B, int(20 * s))
        self.f_tiny  = font(UI_R, int(15 * s))
        self.f_mono  = font(MONO_R, int(20 * s))
        self.f_monob = font(MONO_B, int(20 * s))
        self.f_read  = font(MONO_R, int(40 * s))
        self.f_h     = font(UI_B,   int(30 * s))
        self.f_big   = font(MONO_B, int(42 * s))
        self.readh   = int(52 * s)
        self.rowh    = int(34 * s)
        # the service-manual sheet: notes and cell labels, part names, titles
        self.f_note  = font(MONO_R, int(15 * s))
        self.f_noteb = font(MONO_B, int(16 * s))
        self.f_part  = font(UI_B,   int(21 * s))
        self.f_ttl   = font(UI_B,   int(24 * s))

    def __init__(self, fb):
        self.fb = fb
        W, H = fb.w, fb.h
        self.W, self.H = W, H
        s = H / 800.0                       # everything scales off an 800px panel
        self.s = s
        self._build_fonts()

        self.M    = int(W * 0.045)
        self.pad  = int(34 * s)
        self.hdr  = int(74 * s)
        self.ftr  = int(56 * s)
        self.radius = max(6, int(RADIUS * s))

        self.title = ""; self.hint = ""; self.sub = ""
        self.items = []          # display list

        # Header status - clock and Wi-Fi - and what is on screen, so the
        # status can be redrawn while a menu waits.
        self.status = {"clock": "", "date": "", "wifi": ("none", 0, "")}
        self._status_t = 0.0
        self._wifi_t = 0.0
        self.status_box = None   # where the Wi-Fi icon is, for clicks
        self.mode = "card"       # card | grid | full (a test owns the screen)
        self._grid_args = None
        self.menu_rows = []      # (index, box) of the menu rows drawn
        self._menu_first = 0     # first row of a scrolled menu's window
        self.choice_boxes = []   # (value, box) of the YES / NO pills

    # ---- primitives -------------------------------------------------
    def _card_box(self):
        """Where the white card sits. Split out of _card so callers that only
        need the geometry do not have to be drawing something."""
        return self.M, self.hdr, self.W - self.M, self.H - self.ftr

    def _card(self, d):
        x0, y0, x1, y1 = self._card_box()
        d.rounded_rectangle([x0, y0 + int(3 * self.s), x1, y1 + int(3 * self.s)],
                            self.radius, fill=SHADOW)
        d.rounded_rectangle([x0, y0, x1, y1], self.radius, fill=PAPER)
        return x0, y0, x1, y1

    def row_y(self, row):
        """Maps the row numbers the bash scripts already use onto pixels.
        Row 6 is the first content line, which sits below the screen title."""
        top = self.hdr + self.pad + (int(52 * self.s) if self.title else 0)
        return top + int((float(row) - 6) * self.rowh)

    # ---- frame ------------------------------------------------------
    # ---- header status ----------------------------------------------
    def refresh_status(self):
        """Clock every second, Wi-Fi every three. True when anything changed."""
        now = time.time()
        if now - self._status_t < 1.0:
            return False
        self._status_t = now
        lt = time.localtime()
        wifi = self.status["wifi"]
        if now - self._wifi_t >= 3.0:
            self._wifi_t = now
            try:
                wifi = wifi_status()
            except Exception:
                wifi = ("none", 0, "")
        new = {"clock": time.strftime("%H:%M", lt),
               "date": time.strftime("%a %d %b", lt), "wifi": wifi}
        changed = new != self.status
        self.status = new
        return changed

    def tick(self):
        """Called about once a second while waiting: redraw when the minute
        turns or the Wi-Fi state changes - never over a test's own screen."""
        if self.mode not in ("card", "grid"):
            return
        if not self.refresh_status():
            return
        if self.mode == "grid" and self._grid_args:
            self.render_grid(*self._grid_args)
        elif self.mode == "card":
            self.render()

    def _draw_header(self, img, d):
        s = self.s
        cy = self.hdr // 2
        r = int(7 * s)
        _draw_brand(img, self.M, cy, int(2.3 * r))
        d.text((self.M + 3 * r, cy), "Hardware Diagnostic Toolkit",
               font=self.f_brand, fill=INK, anchor="lm")
        self.refresh_status()
        # Right to left: clock over date, the Wi-Fi icon, the machine name.
        x = self.W - self.M
        clock, date = self.status["clock"], self.status["date"]
        d.text((x, cy - int(9 * s)), clock, font=self.f_bodyb, fill=INK, anchor="rm")
        d.text((x, cy + int(13 * s)), date, font=self.f_tiny, fill=MUTED, anchor="rm")
        x -= max(d.textlength(clock, font=self.f_bodyb),
                 d.textlength(date, font=self.f_tiny)) + int(22 * s)
        isz = int(30 * s)
        _draw_wifi_status(d, x - isz // 2, cy, isz, self.status["wifi"])
        pad = int(10 * s)
        self.status_box = [x - isz - pad, cy - isz // 2 - pad, x + pad, cy + isz // 2 + pad]
        x -= isz + int(26 * s)
        if self.sub:
            for i, part in enumerate(self.sub.split("\n")[:2]):
                d.text((x, cy - int(9 * s) + i * int(19 * s)),
                       part, font=self.f_small, fill=MUTED, anchor="rm")

    def render(self):
        self.mode = "card"
        if LOOK == "manual" and any(it[0] == "menu" for it in self.items):
            return self._render_sheet_menu()
        img = Image.new("RGB", (self.W, self.H), GROUND)
        d = ImageDraw.Draw(img)
        self._draw_header(img, d)

        x0, y0, x1, y1 = self._card(d)
        tx = x0 + self.pad

        if self.title:
            d.text((tx, y0 + self.pad), self.title, font=self.f_h, fill=INK, anchor="la")

        for it in self.items:
            self._draw_item(d, it, tx, x1 - self.pad)

        if self.hint:
            d.text((self.M + int(4 * self.s), self.H - self.ftr // 2), self.hint,
                   font=self.f_small, fill=MUTED, anchor="lm")
        self.fb.blit(img)

    def _clip(self, d, text, font, width):
        """Nothing may be drawn past the edge of the card."""
        if width <= 0 or d.textlength(text, font=font) <= width:
            return text
        lo, hi = 0, len(text)
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if d.textlength(text[:mid] + "...", font=font) <= width:
                lo = mid
            else:
                hi = mid - 1
        return text[:lo].rstrip() + "..."

    def _draw_item(self, d, it, left, right):
        kind = it[0]
        if kind == "kv":
            _, row, label, value, tone = it
            y = self.row_y(row)
            vx = left + int(300 * self.s)
            d.text((left, y), self._clip(d, label, self.f_body, int(290 * self.s)),
                   font=self.f_body, fill=MUTED, anchor="la")
            d.text((vx, y), self._clip(d, value, self.f_monob, right - vx),
                   font=self.f_monob, fill=TONES.get(tone, INK), anchor="la")
        elif kind == "read":
            # Report text, at double size. Positioned in pixels rather than on
            # the row grid, because at this size the rows no longer divide the
            # card evenly.
            _, ypx, text, tone = it
            d.text((left, ypx), text, font=self.f_read,
                   fill=TONES.get(tone, INK), anchor="la")
        elif kind == "line":
            _, row, text, tone = it
            d.text((left, self.row_y(row)),
                   self._clip(d, text, self.f_body, right - left),
                   font=self.f_body, fill=TONES.get(tone, INK), anchor="la")
        elif kind == "bar":
            _, row, pct = it
            y = self.row_y(row) + int(6 * self.s)
            h = int(14 * self.s)
            w = right - left - int(80 * self.s)
            d.rounded_rectangle([left, y, left + w, y + h], h // 2, fill=GROUND)
            fillw = int(w * max(0, min(100, pct)) / 100)
            if fillw > h:
                d.rounded_rectangle([left, y, left + fillw, y + h], h // 2, fill=ACCENT)
            d.text((right, y + h // 2), "%d%%" % pct, font=self.f_mono,
                   fill=MUTED, anchor="rm")
        elif kind == "badge":
            _, row, state, text = it
            y = self.row_y(row)
            fg, bg = BADGE.get(state.upper(), (MUTED, GROUND))
            w = int(d.textlength(state, font=self.f_monob)) + int(40 * self.s)
            h = int(40 * self.s)
            d.rounded_rectangle([left, y - int(6 * self.s), left + w, y - int(6 * self.s) + h],
                                h // 2, fill=bg)
            d.text((left + w // 2, y - int(6 * self.s) + h // 2), state,
                   font=self.f_monob, fill=fg, anchor="mm")
            if text:
                d.text((left + w + int(20 * self.s), y + int(14 * self.s)), text,
                       font=self.f_body, fill=INK, anchor="lm")
        elif kind == "choice":
            _, row, yes = it
            y = self.row_y(row)
            h = int(46 * self.s)
            self.choice_boxes = []
            for i, (label, active, on, off) in enumerate(
                    (("YES", yes, (PASS_, PAPER), (GROUND, MUTED)),
                     ("NO", not yes, (FAIL_, PAPER), (GROUND, MUTED)))):
                w = int(150 * self.s)
                x = left + i * (w + int(20 * self.s))
                bg, fg = on if active else off
                self.choice_boxes.append((i == 0, [x, y - int(8 * self.s), x + w,
                                                   y - int(8 * self.s) + h]))
                d.rounded_rectangle([x, y - int(8 * self.s), x + w, y - int(8 * self.s) + h],
                                    h // 2, fill=bg,
                                    outline=bg if active else LINE, width=2)
                d.text((x + w // 2, y - int(8 * self.s) + h // 2), label,
                       font=self.f_bodyb, fill=fg, anchor="mm")
            d.text((left + 2 * (int(150 * self.s) + int(20 * self.s)) + int(10 * self.s),
                    y - int(8 * self.s) + h // 2),
                   "arrows to change, Enter to confirm  -  or press Y / N",
                   font=self.f_small, fill=MUTED, anchor="lm")
        elif kind == "trow":
            _, row, cols = it
            y = self.row_y(row)
            widths = [0.30, 0.19, 0.17, 0.19, 0.15]
            span = right - left
            x = left
            for i, c in enumerate(cols[:5]):
                w = span * widths[i]
                f = self.f_bodyb if i == 0 else self.f_monob
                if i == 0:
                    # a long network name must not run into the next column
                    d.text((x, y), self._clip(d, c, f, int(w) - int(12 * self.s)),
                           font=f, fill=INK, anchor="la")
                else:
                    d.text((x + w, y), c, font=f,
                           fill=INK if i in (1, 3) else MUTED, anchor="ra")
                x += w
        elif kind == "thead":
            _, row, cols = it
            y = self.row_y(row)
            widths = [0.30, 0.19, 0.17, 0.19, 0.15]
            span = right - left
            x = left
            for i, c in enumerate(cols[:5]):
                w = span * widths[i]
                d.text((x if i == 0 else x + w, y), c.upper(), font=self.f_small,
                       fill=MUTED, anchor="la" if i == 0 else "ra")
                x += w
            d.line([left, y + int(26 * self.s), right, y + int(26 * self.s)], fill=LINE, width=1)
        elif kind == "menu":
            self._draw_menu(d, it[1], it[2], left, right)

    def _draw_menu(self, d, sel, entries, left, right):
        """A list of choices. Each entry is (name, desc), and desc may carry
        several "|"-separated cells, which are drawn as aligned columns.

        The Wi-Fi list on a real TECRA A40-J was what forced this rewrite:
        with 18 networks the rows tightened to 30 px while the highlight kept
        fixed offsets, so the bar sliced through the selected row's text;
        and the columns were space-padded strings in a proportional font, so
        signal, band and security wandered from row to row.
        """
        s = self.s
        y = self.row_y(6) + int(6 * s)
        room = (self.H - self.ftr - self.pad) - y
        # The row can never be shorter than the text plus breathing room, so
        # the highlight always wraps it. A long list scrolls instead of
        # squashing further.
        asc, desc_px = self.f_bodyb.getmetrics()
        minrh = asc + desc_px + int(14 * s)
        rh = int(46 * s)
        if entries and len(entries) * rh > room:
            rh = max(minrh, room // len(entries))
        fit = max(1, room // rh)
        allrows = list(enumerate(entries))
        first = 0
        self.menu_rows = []
        if len(allrows) > fit:
            # The window only moves when the selection leaves it. Recentring on
            # every move made the list slide under a mouse pointer, which then
            # hovered a different row, which slid the list again.
            first = self._menu_first
            if sel < first:
                first = sel
            elif sel >= first + fit:
                first = sel - fit + 1
            first = min(max(0, first), len(allrows) - fit)
            self._menu_first = first
            allrows = allrows[first:first + fit]
            # Where the window is in the whole list - the only sign that
            # there is more above or below.
            d.text((right, self.hdr + self.pad + int(6 * s)),
                   "%d-%d of %d" % (first + 1, first + len(allrows), len(entries)),
                   font=self.f_small, fill=MUTED, anchor="ra")

        cells = [[c.strip() for c in desc.split("|")] if desc else []
                 for _, desc in entries]
        ncols = max([len(c) for c in cells] or [0])
        gap = int(32 * s)
        numw = d.textlength(str(len(entries)), font=self.f_mono)
        namex = left + max(int(38 * s), int(numw) + int(14 * s))
        namew_all = max([d.textlength(n, font=self.f_bodyb) for n, _ in entries] or [0])

        if ncols <= 1:
            # One description column, pushed out far enough that the longest
            # name cannot run into it.
            colx = [max(left + int(230 * s), namex + int(20 * s) + namew_all)]
            colw = [right - colx[0]]
            namew = colx[0] - namex - int(20 * s)
        else:
            # Every column as wide as its widest cell; the name column gets
            # what is left and long names are shortened with "...".
            colw = [0] * ncols
            for c in cells:
                for k, v in enumerate(c):
                    colw[k] = max(colw[k], d.textlength(v, font=self.f_body))
            need = sum(colw) + gap * ncols
            namew = min(namew_all, right - namex - need)
            namew = max(namew, int(160 * s))
            colx, x = [], namex + namew + gap
            for w in colw:
                colx.append(x)
                x += w + gap

        vgap = max(2, int(4 * s))
        for slot, (i, (name, _)) in enumerate(allrows):
            top = y + slot * rh
            cy = top + (rh - vgap) // 2
            self.menu_rows.append((i, [left - int(14 * s), top,
                                       right + int(14 * s), top + rh - vgap]))
            if i == sel:
                d.rounded_rectangle([left - int(14 * s), top,
                                     right + int(14 * s), top + rh - vgap],
                                    max(4, self.radius // 2), fill=ACCENT)
                nc, dc, ic = PAPER, (219, 231, 255), (219, 231, 255)
            else:
                nc, dc, ic = INK, MUTED, MUTED
            d.text((left, cy), str(i + 1), font=self.f_mono, fill=ic, anchor="lm")
            d.text((namex, cy), self._clip(d, name, self.f_bodyb, namew),
                   font=self.f_bodyb, fill=nc, anchor="lm")
            for k, v in enumerate(cells[i]):
                if k >= len(colx) or not v:
                    continue
                w = right - colx[k] if k == len(colx) - 1 else colw[k]
                d.text((colx[k], cy), self._clip(d, v, self.f_body, w),
                       font=self.f_body, fill=dc, anchor="lm")

    # ---- the service-manual sheet (LOOK == "manual") -----------------
    # Home and menus drawn as a page of the service manual a technician opens
    # before a board swap: a drawing frame with zone markers, a title block,
    # each test a line-art part with a numbered balloon callout, and a parts
    # list that carries every test's result for this session. The theme's
    # accent is the revision colour and marks only the current selection.
    # Everything is flat line work - no shadows, no gradients - so it costs no
    # more to draw than the tiles it replaced.
    def _sheet_colours(self):
        mix = lambda a, b, t: tuple(int(x + (y - x) * t) for x, y in zip(a, b))
        return {"sheet": mix(PAPER, GROUND, 0.25), "ink": INK, "ink2": MUTED,
                "hair": LINE, "sel": ACCENT, "selbg": mix(PAPER, ACCENT, 0.13)}

    def _sheet_frame(self, d, c):
        """Outer and inner border, zone markers 1-8 across and A-D down."""
        s, W, H = self.s, self.W, self.H
        d.rectangle([0, 0, W, H], fill=c["sheet"])
        m = int(14 * s)
        inner = int(34 * s)
        d.rectangle([m, m, W - m, H - m], outline=c["ink"], width=max(2, int(2 * s)))
        d.rectangle([inner, inner, W - inner, H - inner], outline=c["ink"], width=1)
        for k in range(8):
            x = inner + (W - 2 * inner) * (k + 0.5) / 8
            for y in ((m + inner) / 2, H - (m + inner) / 2):
                d.text((x, y), str(k + 1), font=self.f_note, fill=c["ink2"], anchor="mm")
            if k:
                xx = inner + (W - 2 * inner) * k // 8
                d.line([(xx, m), (xx, inner)], fill=c["ink2"])
                d.line([(xx, H - inner), (xx, H - m)], fill=c["ink2"])
        for k in range(4):
            y = inner + (H - 2 * inner) * (k + 0.5) / 4
            for x in ((m + inner) / 2, W - (m + inner) / 2):
                d.text((x, y), "ABCD"[k], font=self.f_note, fill=c["ink2"], anchor="mm")
        return inner

    def _spaced(self, d, xy, text, font, fill, sp):
        x, y = xy
        for ch in text:
            d.text((x, y), ch, font=font, fill=fill, anchor="lm")
            x += d.textlength(ch, font=font) + sp
        return x - xy[0] - sp

    def _title_block(self, img, d, c, inner):
        """The header as a title block: name, then ruled cells right to left -
        time with the Wi-Fi icon, date, revision, and the machine itself with
        its CPU and memory on the second line, as the old header had it."""
        s, W = self.s, self.W
        self.refresh_status()
        y0, y1 = inner, inner + int(62 * s)
        d.line([(inner, y1), (W - inner, y1)], fill=c["ink"])
        cy = (y0 + y1) // 2
        x = inner + int(18 * s)
        _draw_brand(img, x, cy, int(16 * s))
        namew = self._spaced(d, (x + int(26 * s), cy), "HARDWARE DIAGNOSTIC TOOLKIT",
                             self.f_bodyb, c["ink"], max(1, int(2 * s)))
        left_limit = x + int(26 * s) + namew + int(20 * s)

        pad = int(14 * s)
        xr = W - inner
        # time + Wi-Fi, as wide as they need at the current text size
        isz = int(26 * s)
        cw = int(max(150 * s, d.textlength(self.status["clock"], font=self.f_noteb)
                     + isz + 3 * pad, d.textlength("TIME", font=self.f_note) + isz + 3 * pad))
        d.line([(xr - cw, y0), (xr - cw, y1)], fill=c["ink"])
        d.text((xr - cw + pad, cy - int(11 * s)), "TIME", font=self.f_note, fill=c["ink2"], anchor="lm")
        d.text((xr - pad, cy + int(9 * s)), self.status["clock"], font=self.f_noteb,
               fill=c["ink"], anchor="rm")
        icx = xr - cw + pad + isz // 2
        _draw_wifi_status(d, icx, cy + int(9 * s), isz, self.status["wifi"])
        self.status_box = [xr - cw, y0, xr - int(70 * s), y1]
        xr -= cw
        for label, val in (("DATE", self.status["date"].upper()), ("REV", DIAG_REV)):
            cw = int(max(d.textlength(val, font=self.f_noteb),
                         d.textlength(label, font=self.f_note)) + 2 * pad)
            d.line([(xr - cw, y0), (xr - cw, y1)], fill=c["ink"])
            d.text((xr - cw + pad, cy - int(11 * s)), label, font=self.f_note, fill=c["ink2"], anchor="lm")
            d.text((xr - cw + pad, cy + int(10 * s)), val, font=self.f_noteb, fill=c["ink"], anchor="lm")
            xr -= cw
        # The machine: model over CPU and memory, in whatever width is left.
        # Ash asked for the CPU and RAM line to stay in the header, so the
        # memory figure is never the part that gets cut: the CPU name is
        # tidied ("(R)", "(TM)" and the like are noise at this size) and only
        # the CPU is shortened if the line still does not fit.
        if self.sub:
            parts = self.sub.split("\n")[:2]
            if len(parts) > 1:
                parts[1] = re.sub(r"\((R|TM|tm|r)\)|\bCPU\b|\b\d+(st|nd|rd|th) Gen\b", "", parts[1])
                parts[1] = re.sub(r"\s+", " ", parts[1]).strip()
            avail = xr - left_limit - 2 * pad
            if avail > int(120 * s):
                # +2: a width rounded down by int() made the text a fraction
                # of a pixel "too wide" and it was shortened for nothing.
                cw = int(min(avail, max(d.textlength(p, font=self.f_small) for p in parts))) + 2 * pad + 2
                inner_w = cw - 2 * pad
                d.line([(xr - cw, y0), (xr - cw, y1)], fill=c["ink"])
                for i, p in enumerate(parts):
                    if i == 1 and d.textlength(p, font=self.f_small) > inner_w and " - " in p:
                        cpu, mem = p.rsplit(" - ", 1)
                        mem = " - " + mem
                        p = self._clip(d, cpu, self.f_small,
                                       inner_w - d.textlength(mem, font=self.f_small)) + mem
                    yy = cy + (i - (len(parts) - 1) / 2) * int(21 * s)
                    d.text((xr - cw + pad, yy), self._clip(d, p, self.f_small, inner_w),
                           font=self.f_small, fill=c["ink"] if i == 0 else c["ink2"], anchor="lm")
        return y1

    def _sheet_title(self, d, c, inner, top, right_note=""):
        s = self.s
        if self.title:
            self._spaced(d, (inner + int(22 * s), top + int(34 * s)), self.title.upper(),
                         self.f_ttl, c["ink"], max(1, int(1.5 * s)))

    def _balloon(self, d, c, cx, cy, n, on):
        r = int(17 * self.s)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c["sel"] if on else c["sheet"],
                  outline=c["sel"] if on else c["ink"], width=max(2, int(1.6 * self.s)))
        d.text((cx, cy), str(n), font=self.f_noteb, fill=c["sheet"] if on else c["ink"],
               anchor="mm")
        return r

    def _wrap2(self, d, text, font, avail):
        """One line, or two at the best word break - a name is never cut short
        while it can wrap (the first tiles truncated "Machine details")."""
        if d.textlength(text, font=font) <= avail or " " not in text:
            return [text]
        ws = text.split()
        return min(([" ".join(ws[:k]), " ".join(ws[k:])] for k in range(1, len(ws))),
                   key=lambda p: max(d.textlength(t, font=font) for t in p))

    def _sheet_layout(self, labels):
        """Columns, part size and origin for the parts. The column count is
        the one giving the biggest parts where every name still fits: a fixed
        4 put 23 tests in six rows of small squares with names cut short
        ("Keybo...")."""
        n = len(labels)
        d = ImageDraw.Draw(Image.new("L", (1, 1)))
        s = self.s
        inner = int(34 * s)
        top = inner + int(62 * s)
        lx0 = self.W - inner - int(self.W * 0.27)
        ax0, ay0 = inner + int(44 * s), top + int(80 * s)
        ax1, ay1 = lx0 - int(36 * s), self.H - inner - int(20 * s)
        gx_, gy_ = int(34 * s), int(30 * s)   # gy_ leaves room for the balloons
        best = None
        for cols in range(1, min(n, 8) + 1):
            rows = (n + cols - 1) // cols
            pw = (ax1 - ax0 - (cols - 1) * gx_) // cols
            ph = min(pw, (ay1 - ay0 - (rows - 1) * gy_) // rows)
            pw = min(pw, int(ph * 1.45))
            if pw <= 0 or ph <= 0:
                continue
            f = self._part_font(d, labels, pw - int(16 * s), int(ph * 0.5))
            fits = all(d.textlength(t, font=f) <= pw - int(16 * s)
                       for lb in labels for t in self._wrap2(d, lb, f, pw - int(16 * s)))
            key = (fits, pw * ph)
            if best is None or key > best[0]:
                best = (key, cols, rows, pw, ph)
        _, cols, rows, pw, ph = best
        gx = ax0 + ((ax1 - ax0) - (cols * pw + (cols - 1) * gx_)) // 2
        return cols, pw, ph, gx, ay0, gx_, gy_, lx0

    def _sheet_cols(self, entries):
        return self._sheet_layout([e[0] for e in entries])[0]

    def _part_font(self, d, labels, avail, room):
        """One size for every part on the sheet - mixed sizes made the long
        grid look untidy. The largest where every name fits in two lines."""
        for f in (self.f_part, self.f_body, self.f_small):
            lh = int(f.size * 1.15)
            if 2 * lh > room:
                continue
            if all(d.textlength(t, font=f) <= avail
                   for lb in labels for t in self._wrap2(d, lb, f, avail)):
                return f
        return self.f_small

    def _render_sheet_grid(self, sel, entries):
        img = Image.new("RGB", (self.W, self.H), GROUND)
        d = ImageDraw.Draw(img)
        c = self._sheet_colours()
        s = self.s
        inner = self._sheet_frame(d, c)
        top = self._title_block(img, d, c, inner)
        cols, pw, ph, gx, ay0, gapx, gapy, lx0 = self._sheet_layout([e[0] for e in entries])
        d.line([(lx0, top), (lx0, self.H - inner)], fill=c["ink"])
        self._parts_list(d, c, sel, entries, lx0, top, self.W - inner, self.H - inner)
        self._sheet_title(d, c, inner, top)
        d.text((lx0 - int(22 * s), top + int(34 * s)), "FIG. 1", font=self.f_note,
               fill=c["ink2"], anchor="rm")
        pad = int(8 * s)
        avail = pw - int(16 * s)
        f = self._part_font(d, [e[0] for e in entries], avail, int(ph * 0.5))
        lh = int(f.size * 1.15)
        # name block anchored to the bottom and sized for the most lines any
        # name needs, so icons and names line up along each row
        nl = max(len(self._wrap2(d, e[0], f, avail)) for e in entries)
        tb_top = ph - pad - nl * lh
        isz = min(int(ph * 0.34), int((tb_top - pad) * 0.72), int(pw * 0.4))
        self.grid_boxes = []
        for i, e in enumerate(entries):
            label, icon = e[0], e[1]
            x0 = gx + (i % cols) * (pw + gapx)
            y0 = ay0 + (i // cols) * (ph + gapy)
            self.grid_boxes.append([x0, y0, x0 + pw, y0 + ph])
            on = i == sel
            col = c["sel"] if on else c["ink"]
            d.rectangle([x0, y0, x0 + pw, y0 + ph], outline=col,
                        width=max(3, int(3 * s)) if on else 1)
            _icon_smooth(icon, img, x0 + pw // 2, y0 + (tb_top + pad) // 2, isz, col)
            lines = self._wrap2(d, label, f, avail)
            ty = y0 + tb_top + (nl - len(lines)) * lh // 2 + lh // 2
            for k, ln in enumerate(lines):
                d.text((x0 + pw // 2, ty + k * lh), self._clip(d, ln, f, avail),
                       font=f, fill=col, anchor="mm")
            # the callout: balloon off the corner, leader into the part
            bx, by = x0 - int(4 * s), y0 - int(4 * s)
            rr = self._balloon(d, c, bx, by, i + 1, on)
            tip = (x0 + int(22 * s), y0 + int(22 * s))
            d.line([(bx + rr * 0.7, by + rr * 0.7), tip], fill=col, width=1)
            dr = max(2, int(2.5 * s))
            d.ellipse([tip[0] - dr, tip[1] - dr, tip[0] + dr, tip[1] + dr], fill=col)
        self.fb.blit(img)

    def _parts_list(self, d, c, sel, entries, x0, y0, x1, y1):
        """Every test with its result this session - the whole machine at a
        glance, without opening anything."""
        s = self.s
        rh = min(int(40 * s), (y1 - y0 - int(80 * s)) // (len(entries) + 2))
        y = y0 + int(14 * s)
        self._spaced(d, (x0 + int(18 * s), y + rh // 2), "PARTS LIST", self.f_bodyb,
                     c["ink"], max(1, int(1.5 * s)))
        y += rh
        d.text((x0 + int(18 * s), y + rh // 2), "NO.", font=self.f_note, fill=c["ink2"], anchor="lm")
        d.text((x0 + int(70 * s), y + rh // 2), "ITEM", font=self.f_note, fill=c["ink2"], anchor="lm")
        d.text((x1 - int(18 * s), y + rh // 2), "RESULT", font=self.f_note, fill=c["ink2"], anchor="rm")
        y += rh
        d.line([(x0, y), (x1, y)], fill=c["ink"])
        # 22 rows at 150 % text overlapped: step the item text down to fit
        fi = next((f for f in (self.f_body, self.f_small, self.f_note) if f.size * 1.1 <= rh),
                  self.f_note)
        for i, e in enumerate(entries):
            on = i == sel
            res = e[2] if len(e) > 2 else ""
            if on:
                d.rectangle([x0 + 1, y + 1, x1 - 1, y + rh - 1], fill=c["selbg"])
            cy = y + rh // 2
            d.text((x0 + int(18 * s), cy), "%02d" % (i + 1),
                   font=self.f_noteb if on else self.f_note,
                   fill=c["sel"] if on else c["ink2"], anchor="lm")
            resw = d.textlength(res or "-", font=self.f_noteb)
            d.text((x0 + int(70 * s), cy),
                   self._clip(d, e[0], fi, x1 - x0 - int(100 * s) - resw),
                   font=fi, fill=c["ink"], anchor="lm")
            if res:
                col = PASS_ if res.startswith("PASS") else (FAIL_ if res.startswith("FAIL") else c["ink2"])
                d.text((x1 - int(18 * s), cy), res, font=self.f_noteb, fill=col, anchor="rm")
            else:
                d.text((x1 - int(18 * s), cy), "-", font=self.f_note, fill=c["ink2"], anchor="rm")
            y += rh
            d.line([(x0, y), (x1, y)], fill=c["hair"])
        if self.hint:
            avail = x1 - x0 - int(36 * s)
            lines = self._wrap2(d, " ".join(self.hint.upper().split()), self.f_note, avail)
            lh = int(self.f_note.size * 1.3)
            for k, ln in enumerate(lines):
                d.text((x0 + int(18 * s), y1 - int(22 * s) - (len(lines) - 1 - k) * lh),
                       self._clip(d, ln, self.f_note, avail),
                       font=self.f_note, fill=c["ink2"], anchor="lm")

    def _render_sheet_menu(self):
        """A menu as a parts-list table: balloons for numbers, one column per
        '|' cell, a heading row taken from the entries themselves."""
        img = Image.new("RGB", (self.W, self.H), GROUND)
        d = ImageDraw.Draw(img)
        c = self._sheet_colours()
        s = self.s
        inner = self._sheet_frame(d, c)
        top = self._title_block(img, d, c, inner)
        self._sheet_title(d, c, inner, top)
        for it in self.items:
            if it[0] == "menu":
                self._sheet_table(d, c, it[1], it[2], inner + int(22 * s), top + int(66 * s),
                                  self.W - inner - int(22 * s), self.H - inner - int(48 * s))
        if self.hint:
            d.text((inner + int(22 * s), self.H - inner - int(24 * s)), self.hint.upper(),
                   font=self.f_note, fill=c["ink2"], anchor="lm")
        self.fb.blit(img)

    def _sheet_table(self, d, c, sel, entries, x0, y0, x1, y1):
        s = self.s
        rh = max(int(40 * s), int(self.f_bodyb.size * 1.9))
        cells = [[t.strip() for t in desc.split("|")] if desc else [] for _, desc in entries]
        ncols = max([len(t) for t in cells] or [0])
        namex = x0 + int(80 * s)
        gap = int(40 * s)
        colw = [max([d.textlength(t[k], font=self.f_body) for t in cells if len(t) > k] or [0])
                for k in range(ncols)]
        namew = max([d.textlength(n, font=self.f_bodyb) for n, _ in entries] or [0])
        need = sum(colw) + gap * ncols
        namew = max(int(160 * s), min(namew, x1 - namex - need))
        colx, x = [], namex + namew + gap
        for w in colw:
            colx.append(x); x += w + gap
        d.text((x0 + int(14 * s), y0 + rh // 2), "NO.", font=self.f_note, fill=c["ink2"], anchor="lm")
        d.text((namex, y0 + rh // 2), "ITEM", font=self.f_note, fill=c["ink2"], anchor="lm")
        if ncols == 1:
            d.text((colx[0], y0 + rh // 2), "DESCRIPTION", font=self.f_note, fill=c["ink2"], anchor="lm")
        y = y0 + rh
        d.line([(x0, y), (x1, y)], fill=c["ink"], width=max(2, int(1.5 * s)))
        room = max(1, (y1 - y) // rh)
        # the window only moves when the selection leaves it (see _draw_menu)
        first = 0
        if len(entries) > room:
            first = self._menu_first
            if sel < first: first = sel
            elif sel >= first + room: first = sel - room + 1
            first = min(max(0, first), len(entries) - room)
            self._menu_first = first
            d.text((x1, y0 - int(30 * s)),
                   "%d-%d OF %d" % (first + 1, first + room, len(entries)),
                   font=self.f_note, fill=c["ink2"], anchor="rm")
        self.menu_rows = []
        for slot, i in enumerate(range(first, min(len(entries), first + room))):
            name = entries[i][0]
            on = i == sel
            top = y + slot * rh
            cy = top + rh // 2
            self.menu_rows.append((i, [x0, top, x1, top + rh]))
            if on:
                d.rectangle([x0, top + 1, x1, top + rh - 1], fill=c["selbg"])
            self._balloon(d, c, x0 + int(34 * s), cy, i + 1, on)
            d.text((namex, cy), self._clip(d, name, self.f_bodyb, namew),
                   font=self.f_bodyb, fill=c["sel"] if on else c["ink"], anchor="lm")
            for k, v in enumerate(cells[i]):
                w = (x1 - colx[k] - int(10 * s)) if k == ncols - 1 else colw[k]
                d.text((colx[k], cy), self._clip(d, v, self.f_body, w),
                       font=self.f_body, fill=c["ink"] if on else c["ink2"], anchor="lm")
            d.line([(x0, top + rh), (x1, top + rh)], fill=c["hair"])

    def _grid_geometry(self, n):
        """Squares, as large as will fit, centred. Returns (cols, tile, gap, x0, y0)."""
        avail_w = self.W - 2 * self.M
        top = self.hdr + int(56 * self.s)
        avail_h = self.H - self.ftr - top - int(10 * self.s)
        gap = int(18 * self.s)
        best = None
        for cols in range(3, 8):
            rows = (n + cols - 1) // cols
            tile = min((avail_w - (cols - 1) * gap) // cols,
                       (avail_h - (rows - 1) * gap) // rows)
            if tile < int(90 * self.s):
                continue
            if best is None or tile > best[1]:
                best = (cols, tile, rows)
        if best is None:
            cols = 6; rows = (n + 5) // 6
            tile = max(int(70 * self.s),
                       min((avail_w - 5 * gap) // 6, (avail_h - (rows - 1) * gap) // rows))
            best = (cols, tile, rows)
        cols, tile, rows = best
        gw = cols * tile + (cols - 1) * gap
        gh = rows * tile + (rows - 1) * gap
        x0 = (self.W - gw) // 2
        y0 = top + max(0, (avail_h - gh) // 2)
        return cols, tile, gap, x0, y0

    def _draw_grid(self, d, img, sel, entries):
        n = len(entries)
        cols, tile, gap, gx, gy = self._grid_geometry(n)
        r = max(6, int(16 * self.s))
        for i, e in enumerate(entries):
            name, icon = e[0], e[1]
            cx0 = gx + (i % cols) * (tile + gap)
            cy0 = gy + (i // cols) * (tile + gap)
            box = [cx0, cy0, cx0 + tile, cy0 + tile]
            if i == sel:
                d.rounded_rectangle([box[0], box[1] + int(4 * self.s),
                                     box[2], box[3] + int(4 * self.s)], r, fill=SHADOW)
                d.rounded_rectangle(box, r, fill=ACCENT)
                icol, tcol, ncol = PAPER, PAPER, (200, 219, 255)
            else:
                d.rounded_rectangle([box[0], box[1] + int(3 * self.s),
                                     box[2], box[3] + int(3 * self.s)], r, fill=SHADOW)
                d.rounded_rectangle(box, r, fill=PAPER, outline=LINE, width=1)
                icol, tcol, ncol = ACCENT, INK, MUTED
            d.text((cx0 + int(12 * self.s), cy0 + int(9 * self.s)), str(i + 1),
                   font=self.f_tiny, fill=ncol, anchor="la")
            _icon_smooth(icon, img, cx0 + tile // 2, cy0 + int(tile * 0.42),
                         int(tile * 0.36), icol)
            label = self._clip(d, name, self.f_tile, tile - int(16 * self.s))
            d.text((cx0 + tile // 2, cy0 + int(tile * 0.80)), label,
                   font=self.f_tile, fill=tcol, anchor="mm")

    def render_grid(self, sel, entries):
        img = Image.new("RGB", (self.W, self.H), GROUND)
        d = ImageDraw.Draw(img)
        self.mode = "grid"
        self._grid_args = (sel, entries)
        if LOOK == "manual":
            return self._render_sheet_grid(sel, entries)
        self._draw_header(img, d)
        if self.title:
            d.text((self.M, self.hdr + int(14 * self.s)), self.title,
                   font=self.f_h, fill=INK, anchor="la")
        self._draw_grid(d, img, sel, entries)
        if self.hint:
            d.text((self.M + int(4 * self.s), self.H - self.ftr // 2), self.hint,
                   font=self.f_small, fill=MUTED, anchor="lm")
        self.fb.blit(img)

    # ---- blocking widgets ------------------------------------------
    def _pointer_xy(self, kb, name):
        c = kb.cursor
        return kb.click_xy if name == "click" else ((c.x, c.y) if c else (-1, -1))

    def menu(self, kb, title, hint, entries):
        """Returns the 1-based choice, 0 for back, or "wifi" when the header
        Wi-Fi icon was clicked (or W pressed) - tui.sh opens the Wi-Fi page and
        then asks this menu again."""
        sel = 0
        n = len(entries)
        self.title, self.hint = title, hint
        self._menu_first = 0
        kb.drain()                           # discard anything typed before this screen
        redraw = True
        while True:
            if redraw:
                self.items = [("menu", sel, entries)]
                self.render()
            redraw = True
            name, code = kb.poll(3600)
            if name is None: redraw = False
            elif name in ("up", "wheelup"):     sel = (sel - 1) % n
            elif name in ("down", "wheeldown"): sel = (sel + 1) % n
            elif name == "enter": return sel + 1
            elif name in ("esc", "q", "back"): return 0
            elif name == "w": return "wifi"
            elif name in ("click", "hover"):
                xy = self._pointer_xy(kb, name)
                if name == "click" and _in(self.status_box, xy):
                    return "wifi"
                hit = next((i for i, b in self.menu_rows if _in(b, xy)), None)
                if hit is None or (name == "hover" and hit == sel):
                    redraw = False
                elif name == "click":
                    return hit + 1
                else:
                    sel = hit
            elif name and name.isdigit():
                pick = _pick_number(kb, name, n)
                if pick: return pick
                redraw = False
            else:
                redraw = False

    def _grid_hit(self, n, xy):
        if LOOK == "manual" and getattr(self, "grid_boxes", None):
            return next((i for i, b in enumerate(self.grid_boxes[:n]) if _in(b, xy)), None)
        cols, tile, gap, gx, gy = self._grid_geometry(n)
        for i in range(n):
            x0 = gx + (i % cols) * (tile + gap)
            y0 = gy + (i // cols) * (tile + gap)
            if x0 <= xy[0] < x0 + tile and y0 <= xy[1] < y0 + tile:
                return i
        return None

    def gridmenu(self, kb, title, hint, entries):
        """entries: list of (label, icon). Arrow keys move in two dimensions;
        the mouse hovers and clicks tiles. Same returns as menu()."""
        sel = 0
        n = len(entries)
        self.title, self.hint = title, hint
        kb.drain()
        redraw = True
        while True:
            # arrow keys move by the columns actually on screen
            cols = self._sheet_cols(entries) if LOOK == "manual" else self._grid_geometry(n)[0]
            if redraw:
                self.render_grid(sel, entries)
            redraw = True
            name, code = kb.poll(3600)
            if name is None: redraw = False
            elif name == "left":  sel = (sel - 1) % n
            elif name == "right": sel = (sel + 1) % n
            elif name == "up":    sel = (sel - cols) % n if sel - cols >= 0 else sel
            elif name == "down":  sel = sel + cols if sel + cols < n else sel
            elif name == "enter": return sel + 1
            elif name in ("esc", "q", "back"): return 0
            elif name == "w": return "wifi"
            elif name in ("click", "hover"):
                xy = self._pointer_xy(kb, name)
                if name == "click" and _in(self.status_box, xy):
                    return "wifi"
                hit = self._grid_hit(n, xy)
                if hit is None or (name == "hover" and hit == sel):
                    redraw = False
                elif name == "click":
                    return hit + 1
                else:
                    sel = hit
            elif name and name.isdigit():
                pick = _pick_number(kb, name, n)
                if pick: return pick
                redraw = False
            else:
                redraw = False

    def msg(self, kb, title, lines):
        self.title, self.hint = title, "Enter to continue"
        self.items = [("line", 6 + i, l, "") for i, l in enumerate(lines)]
        self.render()
        self._wait_dismiss(kb)

    def confirm(self, kb, title, default, lines):
        yes = (default != "no")
        self.title, self.hint = title, "arrows or Y / N, Enter to confirm"
        kb.drain()
        redraw = True
        while True:
            if redraw:
                items = [("line", 6 + i, l, "") for i, l in enumerate(lines)]
                # Both choices, always. A single pill showing the current value
                # read as though it were the only option available.
                items.append(("choice", 6 + len(lines) + 1, yes))
                self.items = items
                self.render()
            redraw = True
            name, _ = kb.poll(3600)
            if name in ("left", "right", "up", "down"): yes = not yes
            elif name == "y": return 1
            elif name == "n": return 0
            elif name in ("esc", "q", "back"): return 0
            elif name == "enter": return 1 if yes else 0
            elif name in ("click", "hover"):
                xy = self._pointer_xy(kb, name)
                hit = next((v for v, b in self.choice_boxes if _in(b, xy)), None)
                if hit is None:
                    redraw = False
                elif name == "click":
                    return 1 if hit else 0
                elif hit == yes:
                    redraw = False
                else:
                    yes = hit
            else:
                redraw = False

    def text_input(self, kb, title, prompt):
        buf = ""
        self.title, self.hint = title, "type, then Enter"
        while True:
            self.items = [("line", 6, prompt, "muted"),
                          ("line", 8, buf + "_", "")]
            if kb.caps:
                self.items.append(("line", 10, "CAPS LOCK is on", "accent"))
            self.render()
            name, code = kb.poll(3600)
            # Typing only - a mouse moving over the password box must not add
            # letters or repaint the screen on every movement.
            while name is None or name in kb.POINTER_EVENTS:
                name, code = kb.poll(3600)
            if name == "enter": return buf
            if name == "esc": return ""
            if name == "backspace": buf = buf[:-1]
            elif name == "space": buf += " "
            elif name and len(name) == 1:
                upper = kb.shift ^ kb.caps      # Caps Lock and Shift cancel out
                buf += (name.upper() if upper and name.isalpha() else name)

    def _wait_dismiss(self, kb):
        kb.drain()
        while True:
            name, _ = kb.poll(3600)
            if name in ("enter", "esc", "q", "space", "click", "back"):
                return

    def pager(self, kb, title, path):
        try:
            with open(path, errors="replace") as f:
                lines = [l.rstrip("\n") for l in f]
        except OSError:
            lines = ["(nothing to show)"]
        # How many of these tall lines fit inside the card, and how wide a line
        # can be before it runs off the edge.
        x0, y0, x1, y1 = self._card_box()
        # Leave room for the screen title the card draws above the text.
        ytop = y0 + self.pad + int(52 * self.s)
        avail_h = y1 - ytop - self.pad
        per = max(3, int(avail_h // self.readh))
        cw = max(1.0, self.f_read.getlength("0"))
        cols = max(20, int(((x1 - x0) - self.pad * 2) / cw))
        # At double size a report line no longer fits across the card, so fold
        # rather than clip - truncating silently ate drive model numbers and the
        # right-hand column of every table.
        wrapped = []
        for l in lines:
            if len(l) <= cols:
                wrapped.append(l)
                continue
            first = True
            while l:
                take = cols if first else cols - 2
                wrapped.append(l[:take] if first else "  " + l[:take])
                l = l[take:]
                first = False
        lines = wrapped or ["(nothing to show)"]

        top = 0
        self.title = title
        kb.drain()
        while True:
            self.hint = "arrows to scroll   Q to go back   line %d of %d" % (top + 1, len(lines))
            self.items = []
            for i, l in enumerate(lines[top:top + per]):
                tone = ""
                if l.startswith("RESULT:"):
                    tone = "ok" if " PASS" in l else ("err" if " FAIL" in l else "warn")
                self.items.append(("read", ytop + i * self.readh, l, tone))
            self.render()
            name, _ = kb.poll(3600)
            while name is None or name in ("hover", "click"):
                name, _ = kb.poll(3600)
            if name == "down": top = min(max(0, len(lines) - per), top + 1)
            elif name == "up": top = max(0, top - 1)
            elif name == "wheeldown": top = min(max(0, len(lines) - per), top + 3)
            elif name == "wheelup": top = max(0, top - 3)
            elif name == "pgdn": top = min(max(0, len(lines) - per), top + per)
            elif name == "pgup": top = max(0, top - per)
            elif name in ("q", "esc", "enter", "back"): return


# ---------------------------------------------------------------- keyboard test
# Layout is (evdev keycode, label, width-units). Menu and Scroll Lock are
# deliberately absent - most laptops do not have them and they only ever showed
# up as "never pressed".
KB_LAYOUT = [
    [(1,"Esc",1),(None,"",1),(59,"F1",1),(60,"F2",1),(61,"F3",1),(62,"F4",1),
     (63,"F5",1),(64,"F6",1),(65,"F7",1),(66,"F8",1),(67,"F9",1),(68,"F10",1),
     (87,"F11",1),(88,"F12",1)],
    [(41,"`",1),(2,"1",1),(3,"2",1),(4,"3",1),(5,"4",1),(6,"5",1),(7,"6",1),
     (8,"7",1),(9,"8",1),(10,"9",1),(11,"0",1),(12,"-",1),(13,"=",1),(14,"Bksp",2)],
    [(15,"Tab",1.5),(16,"Q",1),(17,"W",1),(18,"E",1),(19,"R",1),(20,"T",1),(21,"Y",1),
     (22,"U",1),(23,"I",1),(24,"O",1),(25,"P",1),(26,"[",1),(27,"]",1),(43,"\\",1.5)],
    [(58,"Caps",1.8),(30,"A",1),(31,"S",1),(32,"D",1),(33,"F",1),(34,"G",1),(35,"H",1),
     (36,"J",1),(37,"K",1),(38,"L",1),(39,";",1),(40,"'",1),(28,"Enter",2.2)],
    [(42,"Shift",2.3),(44,"Z",1),(45,"X",1),(46,"C",1),(47,"V",1),(48,"B",1),(49,"N",1),
     (50,"M",1),(51,",",1),(52,".",1),(53,"/",1),(54,"Shift",2.7)],
    [(29,"Ctrl",1.4),(125,"Win",1.2),(56,"Alt",1.2),(57,"Space",6.4),(100,"AltGr",1.2),
     (97,"Ctrl",1.4),(None,"",0.4),(102,"Home",1.2),(104,"PgUp",1.2)],
    [(110,"Ins",1.2),(111,"Del",1.2),(99,"PrtSc",1.4),(119,"Pause",1.4),(None,"",1.0),
     (105,"Left",1.2),(103,"Up",1.2),(108,"Down",1.2),(106,"Right",1.2),
     (None,"",0.4),(107,"End",1.2),(109,"PgDn",1.2)],
]
KB_TIMEOUT = 20          # seconds of no keypress before the test ends

def keyboard_test(scr, kb):
    d_state, d_count, d_down = {}, {}, {}
    for row in KB_LAYOUT:
        for code, label, _ in row:
            if code is not None:
                d_state[code] = "new"; d_count[code] = 0
    total = len(d_state)
    labels = {c: l for row in KB_LAYOUT for c, l, _ in row if c is not None}

    s = scr.s
    unit = int(46 * s)
    gap  = int(6 * s)
    kh   = int(40 * s)
    f_key = font([PLEX + "IBMPlexMono-Regular.ttf", DEJA + "DejaVuSansMono.ttf"], int(15 * s))

    def draw(last_key, remaining):
        img = Image.new("RGB", (scr.W, scr.H), GROUND)
        d = ImageDraw.Draw(img)
        cy = scr.hdr // 2; r = int(7 * s)
        _draw_brand(img, scr.M, cy, int(2.3 * r))
        d.text((scr.M + 3 * r, cy), "Hardware Diagnostic Toolkit",
               font=scr.f_brand, fill=INK, anchor="lm")
        seen = sum(1 for v in d_state.values() if v != "new")
        d.text((scr.W - scr.M, cy), "%d of %d keys registered" % (seen, total),
               font=scr.f_small, fill=MUTED, anchor="rm")

        x0, y0, x1, y1 = scr._card(d)
        d.text((x0 + scr.pad, y0 + scr.pad), "Keyboard test", font=scr.f_h, fill=INK, anchor="la")

        width_units = max(sum(w for _, _, w in row) + (len(row) - 1) * gap / unit
                          for row in KB_LAYOUT)
        kbw = int(width_units * unit)
        kx = (scr.W - kbw) // 2
        ky = y0 + scr.pad + int(60 * s)
        for ri, row in enumerate(KB_LAYOUT):
            x = kx
            for code, label, w in row:
                kw = int(w * unit)
                if code is None:
                    x += kw + gap; continue
                st = d_state[code]
                if   st == "done":  bg, fg, br = PASS_SOFT, PASS_, PASS_
                elif st == "down":  bg, fg, br = ACCENT, PAPER, ACCENT
                elif st == "stuck": bg, fg, br = FAIL_SOFT, FAIL_, FAIL_
                else:               bg, fg, br = GROUND, MUTED, LINE
                d.rounded_rectangle([x, ky, x + kw - gap, ky + kh],
                                    max(3, int(9 * s)), fill=bg, outline=br, width=1)
                d.text((x + (kw - gap) // 2, ky + kh // 2), label,
                       font=f_key, fill=fg, anchor="mm")
                x += kw + gap
            ky += kh + gap

        by = ky + int(22 * s)
        bw = x1 - x0 - 2 * scr.pad - int(80 * s)
        bh = int(14 * s)
        d.rounded_rectangle([x0 + scr.pad, by, x0 + scr.pad + bw, by + bh], bh // 2, fill=GROUND)
        fw = int(bw * seen / total)
        if fw > bh:
            d.rounded_rectangle([x0 + scr.pad, by, x0 + scr.pad + fw, by + bh], bh // 2, fill=ACCENT)
        d.text((x1 - scr.pad, by + bh // 2), "%d%%" % (seen * 100 // total),
               font=scr.f_mono, fill=MUTED, anchor="rm")

        leg = by + int(40 * s)
        lx = x0 + scr.pad
        for col, txt in ((PASS_, "registered"), (ACCENT, "held down"),
                         (FAIL_, "stuck"), (LINE, "not seen yet")):
            d.rounded_rectangle([lx, leg, lx + int(14 * s), leg + int(14 * s)],
                                int(4 * s), fill=col)
            d.text((lx + int(22 * s), leg + int(7 * s)), txt, font=scr.f_small,
                   fill=MUTED, anchor="lm")
            lx += int(d.textlength(txt, font=scr.f_small)) + int(60 * s)

        d.text((scr.M + int(4 * s), scr.H - scr.ftr // 2),
               "press every key    Esc three times to finish    ends %ds after the last key"
               % remaining, font=scr.f_small, fill=MUTED, anchor="lm")
        scr.fb.blit(img)

    kb.drain()
    esc_hits, esc_last = 0, 0.0
    last_activity = time.time()
    draw(None, KB_TIMEOUT)
    while True:
        remaining = int(KB_TIMEOUT - (time.time() - last_activity))
        if remaining <= 0:
            break
        got = _kb_events(kb, 0.2)
        dirty = False
        now = time.time()
        for code, value in got:
            if code not in d_state:
                continue
            last_activity = now; dirty = True
            if value == 1:
                d_state[code] = "down"; d_count[code] += 1; d_down[code] = now
                if code == 1:
                    esc_hits = esc_hits + 1 if now - esc_last <= 3 else 1
                    esc_last = now
            elif value == 0:
                d_state[code] = "done"; d_down.pop(code, None)
        for code, since in list(d_down.items()):
            if now - since >= 5 and d_state.get(code) != "stuck":
                d_state[code] = "stuck"; dirty = True
        if esc_hits >= 3:
            break
        # every key accounted for - no reason to make them wait out the timer
        if all(v != "new" for v in d_state.values()):
            draw(None, 0); time.sleep(0.6)
            break
        if dirty or int(remaining) != int(KB_TIMEOUT - (now - last_activity)):
            draw(None, max(0, remaining))

    missing = [labels[c] for c in sorted(d_state) if d_state[c] == "new"]
    stuck   = [labels[c] for c in sorted(d_state) if d_state[c] == "stuck"]
    repeat  = ["%s(%d)" % (labels[c], d_count[c]) for c in sorted(d_count) if d_count[c] > 12]
    seen    = total - len(missing)
    # "|" rather than TAB: bash's read collapses runs of whitespace delimiters,
    # so an empty stuck list would shift the missing list into its place and
    # every incomplete test would be reported as a stuck key.
    return "%d|%d|%s|%s|%s" % (total, seen, " ".join(stuck),
                               " ".join(missing), " ".join(repeat))


# ---------------------------------------------------------------- pointer test
# Touchpads and mice both arrive as evdev devices. A mouse reports relative
# movement (EV_REL); a touchpad reports absolute finger position (EV_ABS) and
# says how many fingers are down with BTN_TOOL_*. Reading them raw means no
# X server, no libinput, and the test sees exactly what the hardware sends.
EV_SYN, EV_REL, EV_ABS = 0x00, 0x02, 0x03
REL_X, REL_Y, REL_WHEEL, REL_HWHEEL = 0x00, 0x01, 0x08, 0x06
ABS_X, ABS_Y = 0x00, 0x01
ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
ABS_MT_SLOT, ABS_MT_TRACKING_ID = 0x2f, 0x39
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
BTN_TOUCH = 0x14a
BTN_TOOL_FINGER, BTN_TOOL_DOUBLETAP = 0x145, 0x14d
BTN_TOOL_TRIPLETAP, BTN_TOOL_QUADTAP = 0x14e, 0x14f
EVIOCGABS = lambda ax: 0x80184540 + ax          # _IOR('E', 0x40+ax, input_absinfo)

PTR_TIMEOUT = 25
COV_COLS, COV_ROWS = 16, 10


class Pointer:
    """Every touchpad and mouse on the machine, opened raw."""
    def __init__(self, want):                    # want: "touchpad" or "mouse"
        self.fds, self.info, self.names = [], {}, []
        self.learnt = {}          # (fd, axis) -> [min, max] seen, when the
        self.uncalibrated = False # driver gives no usable range of its own
        for path, name, kind in self._devices():
            if kind != want:
                continue
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                continue
            try: fcntl.ioctl(fd, EVIOCGRAB, 1)
            except Exception: pass
            self.fds.append(fd); self.names.append(name)
            if kind in ("touchpad", "touchscreen"):
                self.info[fd] = self._absrange(fd)
        self.kind = want

    def normalise(self, fd, code, value):
        """Absolute position as 0..1. The driver's own range is used when it
        gives one; a few pads report nothing useful, so the range is otherwise
        learnt from what actually arrives. Until enough has arrived to be
        meaningful this returns None, and the caller treats it as activity
        without a position - better than pinning every touch to one cell."""
        rng = self.info.setdefault(fd, {})
        if code in rng:
            lo, hi = rng[code]
            if hi > lo:
                return min(1.0, max(0.0, (value - lo) / float(hi - lo)))
        seen = self.learnt.setdefault((fd, code), [value, value])
        if value < seen[0]: seen[0] = value
        if value > seen[1]: seen[1] = value
        span = seen[1] - seen[0]
        if span < 16:                     # not enough travel to mean anything yet
            self.uncalibrated = True
            return None
        self.uncalibrated = True
        return min(1.0, max(0.0, (value - seen[0]) / float(span)))

    @staticmethod
    def _absrange(fd):
        rng = {}
        for ax in (ABS_X, ABS_Y, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_SLOT):
            try:
                buf = fcntl.ioctl(fd, EVIOCGABS(ax), b"\0" * 24)
                _, lo, hi, _, _, _ = struct.unpack("iiiiii", buf)
                if hi > lo:
                    rng[ax] = (lo, hi)
            except Exception:
                pass
        return rng

    @staticmethod
    def _devices():
        """(path, display name, kind) for every pointing device."""
        out = []
        try:
            with open("/proc/bus/input/devices") as f:
                text = f.read()
        except OSError:
            return out
        for chunk in text.split("\n\n"):
            if "mouse" not in chunk and "event" not in chunk:
                continue
            name, handlers, ev, abs_bits, prop = "", "", "", "", "0"
            for line in chunk.splitlines():
                if line.startswith("N: Name="):  name = line.split("=", 1)[1].strip('"')
                elif line.startswith("H: Handlers="): handlers = line.split("=", 1)[1]
                elif line.startswith("B: EV="):  ev = line.split("=", 1)[1]
                elif line.startswith("B: ABS="): abs_bits = line.split("=", 1)[1]
                elif line.startswith("B: PROP="): prop = line.split("=", 1)[1].strip()
            evp = [h for h in handlers.split() if h.startswith("event")]
            if not evp:
                continue
            low = name.lower()
            # A touchscreen is an absolute device whose coordinates ARE the
            # screen: the kernel marks that INPUT_PROP_DIRECT (bit 1 of PROP).
            # It has to be sorted out first, because by every other test it
            # looks exactly like a touchpad - and the touchpad test used to grab
            # it and report the screen as the pad.
            try: direct = bool(int(prop.split()[-1] or "0", 16) & 0x2)
            except ValueError: direct = False
            if abs_bits and (direct or "touchscreen" in low or "touch screen" in low):
                out.append(("/dev/input/" + evp[0], name, "touchscreen"))
                continue
            # Maker names only at the start of a word: a plain substring test
            # read QEMU's "VirtualPS/2 VMware VMMouse" as an ALPS pad
            # ("virtuALPS"), so the mouse was treated as a touchpad waiting
            # for finger-down events that never come.
            padname = bool(re.search(r"\b(touchpad|trackpad|synaptics|elan|alps|glidepoint|clickpad)",
                                     low))
            # A precision touchpad does not always get a mousedev handler, so
            # the mouse handler cannot be a requirement - absolute axes plus
            # buttons is what actually identifies a pad.
            if padname or (abs_bits and "mouse" not in low):
                kind = "touchpad"
            elif "mouse" in handlers or "mouse" in low or "trackpoint" in low:
                kind = "mouse"
            else:
                continue
            out.append(("/dev/input/" + evp[0], name, kind))
        return out

    def close(self):
        for fd in self.fds:
            try: fcntl.ioctl(fd, EVIOCGRAB, 0)
            except Exception: pass
            try: os.close(fd)
            except Exception: pass


def pointer_test(scr, kb, want):
    p = Pointer(want)
    label = "Touchpad" if want == "touchpad" else "Mouse"
    if not p.fds:
        scr.title = label + " test"
        scr.hint = "Enter to go back"
        scr.items = [("badge", 6, "UNKNOWN", "no %s found on this machine" % want.lower()),
                     ("line", 9, "Nothing on this machine reports itself as a %s." % want, ""),
                     ("line", 10, "For a USB mouse, plug it in and run the test again.", "muted")]
        scr.render(); scr._wait_dismiss(kb)
        return "0|0||none|0|0|0|0"

    s = scr.s
    cov = [[0] * COV_COLS for _ in range(COV_ROWS)]
    buttons = {BTN_LEFT: 0, BTN_RIGHT: 0, BTN_MIDDLE: 0}
    taps = 0
    wheel_up = wheel_dn = hwheel = 0
    max_fingers = 0
    # Almost every laptop built since about 2015 has a clickpad: one hinged
    # surface with no separate right button. There is no BTN_RIGHT to report,
    # so the driver signals a right click as a normal click with two fingers
    # down, or as a two-finger tap. Waiting for BTN_RIGHT on such a pad fails
    # a working touchpad, which is exactly what it was doing.
    cur_fingers = 0
    right_emulated = 0          # two-finger click or tap seen
    dtap_down_at = 0.0
    px, py = 0.5, 0.5                 # pointer position as a fraction of the pad
    trail = []
    moved = 0

    def draw(remaining):
        img = Image.new("RGB", (scr.W, scr.H), GROUND)
        d = ImageDraw.Draw(img)
        cy = scr.hdr // 2; r = int(7 * s)
        _draw_brand(img, scr.M, cy, int(2.3 * r))
        d.text((scr.M + 3 * r, cy), "Hardware Diagnostic Toolkit",
               font=scr.f_brand, fill=INK, anchor="lm")
        seen = sum(1 for row in cov for c in row if c)
        d.text((scr.W - scr.M, cy), "%d%% of the surface covered"
               % (seen * 100 // (COV_COLS * COV_ROWS)),
               font=scr.f_small, fill=MUTED, anchor="rm")

        x0, y0, x1, y1 = scr._card(d)
        d.text((x0 + scr.pad, y0 + scr.pad), label + " test", font=scr.f_h, fill=INK, anchor="la")

        # the pad: one cell per patch of surface, filled in as it is touched
        pw = x1 - x0 - 2 * scr.pad
        ph = int(pw * COV_ROWS / COV_COLS)
        maxh = (y1 - int(150 * s)) - (y0 + scr.pad + int(58 * s))
        if ph > maxh:
            ph = maxh; pw = int(ph * COV_COLS / COV_ROWS)
        ox = x0 + (x1 - x0 - pw) // 2
        oy = y0 + scr.pad + int(58 * s)
        cw, ch = pw / COV_COLS, ph / COV_ROWS
        d.rounded_rectangle([ox, oy, ox + pw, oy + ph], int(12 * s), fill=GROUND)
        for ry in range(COV_ROWS):
            for rx in range(COV_COLS):
                if cov[ry][rx]:
                    d.rectangle([ox + rx * cw + 1, oy + ry * ch + 1,
                                 ox + (rx + 1) * cw - 1, oy + (ry + 1) * ch - 1],
                                fill=PASS_SOFT)
        d.rounded_rectangle([ox, oy, ox + pw, oy + ph], int(12 * s), outline=LINE, width=2)
        for i, (tx, ty) in enumerate(trail[-90:]):
            rr = max(1, int(3 * s))
            d.ellipse([ox + tx * pw - rr, oy + ty * ph - rr,
                       ox + tx * pw + rr, oy + ty * ph + rr], fill=ACCENT)
        rr = int(9 * s)
        d.ellipse([ox + px * pw - rr, oy + py * ph - rr,
                   ox + px * pw + rr, oy + py * ph + rr], fill=ACCENT, outline=PAPER, width=2)

        # buttons and gestures
        by = oy + ph + int(26 * s)
        bw = int(pw / 3.4)
        for i, (code, nm) in enumerate(((BTN_LEFT, "Left"), (BTN_MIDDLE, "Middle"),
                                        (BTN_RIGHT, "Right"))):
            bx = ox + i * int(pw / 3)
            hit = buttons[code] > 0
            if code == BTN_RIGHT and right_emulated:
                hit = True
            d.rounded_rectangle([bx, by, bx + bw, by + int(40 * s)], int(9 * s),
                                fill=PASS_SOFT if hit else GROUND,
                                outline=PASS_ if hit else LINE, width=2)
            label = nm
            if hit:
                if code == BTN_RIGHT and right_emulated and not buttons[code]:
                    label = "Right  %d  (2-finger)" % right_emulated
                else:
                    label = "%s  %d" % (nm, buttons[code])
            d.text((bx + bw // 2, by + int(20 * s)), label,
                   font=scr.f_body, fill=PASS_ if hit else MUTED, anchor="mm")
        gy = by + int(54 * s)
        if want == "touchpad":
            bits = [("tap", taps > 0, "tap: %d" % taps),
                    ("two", max_fingers >= 2, "two fingers"),
                    ("three", max_fingers >= 3, "three fingers")]
        else:
            bits = [("up", wheel_up > 0, "wheel up"),
                    ("dn", wheel_dn > 0, "wheel down"),
                    ("tilt", hwheel > 0, "wheel tilt")]
        gx = ox
        for _, hit, txt in bits:
            col = PASS_ if hit else MUTED
            d.ellipse([gx, gy + int(4 * s), gx + int(12 * s), gy + int(16 * s)],
                      fill=col if hit else LINE)
            d.text((gx + int(20 * s), gy + int(10 * s)), txt, font=scr.f_body,
                   fill=col, anchor="lm")
            gx += int(pw / 3)

        d.text((scr.M + int(4 * s), scr.H - scr.ftr // 2),
               "%s    click every button    Esc three times to finish    "
               "ends %ds after the last movement"
               % ("slide a finger over the whole pad" if want == "touchpad"
                  else "move the mouse and turn the wheel", remaining),
               font=scr.f_small, fill=MUTED, anchor="lm")
        scr.fb.blit(img)

    def mark():
        cx = min(COV_COLS - 1, max(0, int(px * COV_COLS)))
        cyy = min(COV_ROWS - 1, max(0, int(py * COV_ROWS)))
        cov[cyy][cx] += 1
        trail.append((px, py))
        if len(trail) > 400:
            del trail[:200]

    last = time.time()
    esc_hits, esc_last = 0, 0.0
    draw(PTR_TIMEOUT)
    kb.drain()
    while True:
        remaining = int(PTR_TIMEOUT - (time.time() - last))
        if remaining <= 0:
            break
        dirty = False
        rl, _, _ = select.select(p.fds + kb.fds, [], [], 0.05)
        now = time.time()
        for fd in rl:
            try: data = os.read(fd, EVENT_SIZE * 128)
            except OSError: continue
            for i in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                _, _, etype, code, value = struct.unpack(EVENT_FMT, data[i:i + EVENT_SIZE])
                if fd in kb.fds:
                    if etype == EV_KEY and value == 1 and code == 1:
                        esc_hits = esc_hits + 1 if now - esc_last <= 3 else 1
                        esc_last = now
                    continue
                if etype == EV_REL:
                    if code == REL_X:
                        px = min(1.0, max(0.0, px + value / 600.0)); moved += abs(value)
                        last = now; dirty = True; mark()
                    elif code == REL_Y:
                        py = min(1.0, max(0.0, py + value / 400.0)); moved += abs(value)
                        last = now; dirty = True; mark()
                    elif code == REL_WHEEL:
                        if value > 0: wheel_up += 1
                        else: wheel_dn += 1
                        last = now; dirty = True
                    elif code == REL_HWHEEL:
                        hwheel += 1; last = now; dirty = True
                elif etype == EV_ABS:
                    if code in (ABS_X, ABS_MT_POSITION_X, ABS_Y, ABS_MT_POSITION_Y):
                        frac = p.normalise(fd, code, value)
                        if frac is not None:
                            if code in (ABS_X, ABS_MT_POSITION_X): px = frac
                            else: py = frac
                            last = now; dirty = True; mark()
                        else:
                            last = now
                elif etype == EV_KEY:
                    if code in buttons and value == 1:
                        # A physical click with two fingers resting on the pad is
                        # how a clickpad says "right button".
                        if code == BTN_LEFT and cur_fingers >= 2:
                            right_emulated += 1
                        else:
                            buttons[code] += 1
                        last = now; dirty = True
                    elif code == BTN_TOUCH and value == 1:
                        taps += 1; last = now; dirty = True
                    elif code in (BTN_TOOL_FINGER, BTN_TOOL_DOUBLETAP,
                                  BTN_TOOL_TRIPLETAP, BTN_TOOL_QUADTAP):
                        n = {BTN_TOOL_FINGER: 1, BTN_TOOL_DOUBLETAP: 2,
                             BTN_TOOL_TRIPLETAP: 3, BTN_TOOL_QUADTAP: 4}[code]
                        if value == 1:
                            cur_fingers = n
                            max_fingers = max(max_fingers, n)
                            if code == BTN_TOOL_DOUBLETAP:
                                dtap_down_at = now
                        else:
                            # A short two-finger touch that ends without moving
                            # is a two-finger tap: the other right-click.
                            if (code == BTN_TOOL_DOUBLETAP and dtap_down_at
                                    and now - dtap_down_at < 0.4):
                                right_emulated += 1
                                dtap_down_at = 0.0
                            cur_fingers = 0
                        last = now; dirty = True
        if esc_hits >= 3:
            break
        if dirty:
            draw(max(0, remaining))
    p.close()
    kb.drain()

    seen = sum(1 for row in cov for c in row if c)
    coverage = seen * 100 // (COV_COLS * COV_ROWS)
    dead = []
    # Only call a patch dead when the pad told us its real coordinate range.
    # With a learnt range the edges are wherever the finger happened to stop,
    # so "unreached" would mean nothing.
    if coverage >= 35 and not p.uncalibrated:
        for ry in range(COV_ROWS):
            for rx in range(COV_COLS):
                if not cov[ry][rx]:
                    dead.append("%d,%d" % (rx, ry))
    btn = " ".join("%s=%d" % (n, buttons[c]) for c, n in
                   ((BTN_LEFT, "left"), (BTN_MIDDLE, "middle"), (BTN_RIGHT, "right")))
    return "%d|%d|%s|%s|%d|%d|%d|%d" % (
        coverage, len(dead), btn, ", ".join(p.names) or "none",
        taps, max_fingers, wheel_up + wheel_dn + hwheel, right_emulated)


# ---------------------------------------------------------------- touchscreen test
# The whole panel is the test surface: the touch digitiser is laminated to the
# LCD, so a dead strip on the glass sits exactly where it looks dead on screen.
# Three things are checked, in the order the faults turn up on the bench:
#   1. ghost touches - with nobody touching it, a cracked or delaminating
#      digitiser fires touches on its own. Three seconds hands-off catches it.
#   2. coverage - a finger dragged over the whole glass fills the grid; a patch
#      that never fills is a dead zone (usually a crack, or a lifting flex).
#   3. multi-touch - several fingers at once; a panel that only ever reports
#      one has a bad controller or the wrong firmware.
TS_TIMEOUT = 25
TS_GHOST_SECS = 3


def touchscreen_test(scr, kb):
    p = Pointer("touchscreen")
    if not p.fds:
        scr.title = "Touchscreen test"
        scr.hint = "Enter to go back"
        scr.items = [("badge", 6, "UNKNOWN", "no touchscreen found on this machine"),
                     ("line", 9, "Nothing on this machine reports itself as a touchscreen.", ""),
                     ("line", 10, "If the model has one, it may be switched off in the BIOS,", "muted"),
                     ("line", 11, "or its I2C controller may not have come up - check the", "muted"),
                     ("line", 12, "System page for an I2C HID device.", "muted")]
        scr.render(); scr._wait_dismiss(kb)
        return "0|0|none|0|0|0|0|0|"

    W, H = scr.W, scr.H
    s = scr.s
    cols = 16
    rows = max(6, int(round(cols * H / float(W))))
    cov = [[0] * cols for _ in range(rows)]

    # how many contacts the controller says it can track at once
    supported = 1
    for fd in p.fds:
        rng = p.info.get(fd, {})
        if ABS_MT_SLOT in rng:
            supported = max(supported, rng[ABS_MT_SLOT][1] - rng[ABS_MT_SLOT][0] + 1)

    slots = {}           # (fd, slot) -> [x, y] for every finger currently down
    cur_slot = {}        # fd -> slot the next MT event belongs to
    pending = {}         # fd -> [x, y] for single-touch devices
    max_simul = 0
    contacts = 0
    ghost = 0
    trail = []

    f_big = scr.f_h
    f_txt = scr.f_body
    f_sm = scr.f_small

    def cell_of(x, y):
        return (min(cols - 1, max(0, int(x * cols))),
                min(rows - 1, max(0, int(y * rows))))

    # PASS_SOFT is a card tint and all but vanishes against the ground at arm's
    # length, so the covered colour is mixed a third of the way to full green.
    done_col = tuple(int(a + (b - a) * 0.35) for a, b in zip(PASS_SOFT, PASS_))

    def base(show_dead=False):
        img = Image.new("RGB", (W, H), GROUND)
        d = ImageDraw.Draw(img)
        cw, ch = W / float(cols), H / float(rows)
        for ry in range(rows):
            for rx in range(cols):
                x0, y0 = int(rx * cw), int(ry * ch)
                x1, y1 = int((rx + 1) * cw) - 1, int((ry + 1) * ch) - 1
                if cov[ry][rx]:
                    d.rectangle([x0, y0, x1, y1], fill=done_col)
                elif show_dead:
                    d.rectangle([x0, y0, x1, y1], fill=FAIL_SOFT)
                    d.rectangle([x0 + 2, y0 + 2, x1 - 2, y1 - 2], outline=FAIL_, width=2)
                d.rectangle([x0, y0, x1, y1], outline=LINE, width=1)
        return img, d

    def panel(img, lines, y_frac=0.5):
        """A centred card of text drawn on top of the grid."""
        d = ImageDraw.Draw(img)
        pad = int(22 * s)
        widths = [d.textlength(t, font=f) for t, f, _ in lines]
        hs = [int(getattr(f, "size", 16) * 1.45) for _, f, _ in lines]
        bw = int(max(widths) + 2 * pad)
        bh = int(sum(hs) + 2 * pad)
        bx = (W - bw) // 2
        by = int(H * y_frac - bh / 2)
        d.rounded_rectangle([bx, by, bx + bw, by + bh], int(16 * s), fill=PAPER,
                            outline=LINE, width=2)
        y = by + pad
        for (t, f, col), h in zip(lines, hs):
            d.text((W // 2, y + h // 2), t, font=f, fill=col, anchor="mm")
            y += h

    # ------------------------------------------------ phase 1: hands off
    for fd in p.fds:
        try:
            while os.read(fd, EVENT_SIZE * 256):
                pass
        except OSError:
            pass
    kb.drain()
    t0 = time.time()
    last_shown = -1
    while True:
        left = TS_GHOST_SECS - (time.time() - t0)
        if left <= 0:
            break
        if int(left) != last_shown:
            last_shown = int(left)
            img, _ = base()
            panel(img, [("Touchscreen test", f_big, INK),
                        ("Hands off the screen for %d s" % (int(left) + 1), f_txt, INK),
                        ("checking the glass does not touch itself", f_sm, MUTED),
                        ("ghost touches so far: %d" % ghost, f_sm,
                         FAIL_ if ghost else MUTED)])
            scr.fb.blit(img)
        rl, _, _ = select.select(p.fds, [], [], 0.05)
        for fd in rl:
            try: data = os.read(fd, EVENT_SIZE * 128)
            except OSError: continue
            for i in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                _, _, etype, code, value = struct.unpack(EVENT_FMT, data[i:i + EVENT_SIZE])
                if (etype == EV_KEY and code == BTN_TOUCH and value == 1) or \
                   (etype == EV_ABS and code == ABS_MT_TRACKING_ID and value >= 0):
                    ghost += 1
                    last_shown = -1

    # ------------------------------------------------ phase 2: sweep
    def draw(remaining):
        img, d = base()
        cw, ch = W / float(cols), H / float(rows)
        rr = max(2, int(3 * s))
        for tx, ty in trail[-300:]:
            d.ellipse([tx * W - rr, ty * H - rr, tx * W + rr, ty * H + rr], fill=ACCENT)
        R = int(34 * s)
        for n, (fx, fy) in enumerate(list(slots.values())):
            cx, cy = fx * W, fy * H
            d.ellipse([cx - R, cy - R, cx + R, cy + R], outline=ACCENT, width=max(3, int(4 * s)))
            d.text((cx, cy), str(n + 1), font=f_txt, fill=ACCENT, anchor="mm")
        seen = sum(1 for row in cov for c in row if c)
        pct = seen * 100 // (cols * rows)
        # Status is only drawn while nothing is being touched near the middle,
        # so it never sits under the finger it is describing.
        near = any(abs(fx - 0.5) < 0.22 and abs(fy - 0.5) < 0.2 for fx, fy in slots.values())
        if not near:
            panel(img, [("Drag a finger over the whole screen", f_txt, INK),
                        ("%d %% covered   -   most fingers at once: %d of %d"
                         % (pct, max_simul, supported), f_sm, MUTED),
                        ("then put 2 or more fingers down together", f_sm, MUTED),
                        ("Esc three times to finish   -   ends %ds after the last touch"
                         % remaining, f_sm, MUTED)])
        scr.fb.blit(img)

    def mark(x, y):
        cx, cy = cell_of(x, y)
        cov[cy][cx] += 1
        trail.append((x, y))
        if len(trail) > 800:
            del trail[:400]

    last = time.time()
    last_draw = 0.0
    full_at = None
    esc_hits, esc_last = 0, 0.0
    draw(TS_TIMEOUT)
    kb.drain()
    while True:
        now = time.time()
        remaining = int(TS_TIMEOUT - (now - last))
        if remaining <= 0 or esc_hits >= 3:
            break
        if full_at and now - full_at > 1.5 and max_simul >= min(2, supported):
            break                    # everything covered and multi-touch seen
        dirty = False
        rl, _, _ = select.select(p.fds + kb.fds, [], [], 0.03)
        for fd in rl:
            try: data = os.read(fd, EVENT_SIZE * 256)
            except OSError: continue
            for i in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                _, _, etype, code, value = struct.unpack(EVENT_FMT, data[i:i + EVENT_SIZE])
                if fd in kb.fds:
                    if etype == EV_KEY and value == 1 and code == 1:
                        esc_hits = esc_hits + 1 if now - esc_last <= 3 else 1
                        esc_last = now
                    continue
                if etype == EV_ABS:
                    if code == ABS_MT_SLOT:
                        cur_slot[fd] = value
                    elif code == ABS_MT_TRACKING_ID:
                        key = (fd, cur_slot.get(fd, 0))
                        if value < 0:
                            slots.pop(key, None)
                        else:
                            slots[key] = [0.5, 0.5]
                            contacts += 1
                        max_simul = max(max_simul, len(slots))
                        last = now; dirty = True
                    elif code in (ABS_MT_POSITION_X, ABS_MT_POSITION_Y):
                        frac = p.normalise(fd, code, value)
                        key = (fd, cur_slot.get(fd, 0))
                        if frac is None:
                            last = now; continue
                        pt = slots.setdefault(key, [0.5, 0.5])
                        if code == ABS_MT_POSITION_X: pt[0] = frac
                        else: pt[1] = frac
                        mark(pt[0], pt[1])
                        max_simul = max(max_simul, len(slots))
                        last = now; dirty = True
                    elif code in (ABS_X, ABS_Y):
                        # Single-touch panels only; a multi-touch panel sends
                        # these too, as a copy of the first finger.
                        if any(k[0] == fd for k in slots):
                            continue
                        frac = p.normalise(fd, code, value)
                        if frac is None:
                            continue
                        pt = pending.setdefault(fd, [0.5, 0.5])
                        if code == ABS_X: pt[0] = frac
                        else: pt[1] = frac
                        mark(pt[0], pt[1])
                        max_simul = max(max_simul, 1)
                        last = now; dirty = True
                elif etype == EV_KEY and code == BTN_TOUCH and value == 1 and \
                        not any(k[0] == fd for k in slots):
                    contacts += 1
        seen = sum(1 for row in cov for c in row if c)
        if seen == cols * rows and full_at is None:
            full_at = now
        if dirty and now - last_draw > 0.04:
            draw(max(0, remaining)); last_draw = now
    p.close()

    seen = sum(1 for row in cov for c in row if c)
    coverage = seen * 100 // (cols * rows)
    dead = []
    # A patch is only called dead once most of the glass has been swept: with
    # a touchscreen the operator can see exactly what is left, so anything
    # short of that is an unfinished sweep, not a fault.
    if coverage >= 80 and not p.uncalibrated:
        for ry in range(rows):
            for rx in range(cols):
                if not cov[ry][rx]:
                    dead.append("%d,%d" % (rx, ry))

    # Leave the map up so the operator can see WHERE the dead patches are -
    # the result page afterwards can only give a count.
    img, _ = base(show_dead=bool(dead))
    if dead:
        msg = [("%d patch(es) never registered - shown in red" % len(dead), f_txt, FAIL_),
               ("press Enter to continue", f_sm, MUTED)]
    elif coverage < 80:
        msg = [("%d %% of the screen covered - sweep at least 80 %% to judge it"
                % coverage, f_txt, WARN_),
               ("press Enter to continue", f_sm, MUTED)]
    else:
        msg = [("%d %% of the screen covered" % coverage, f_txt, INK),
               ("press Enter to continue", f_sm, MUTED)]
    panel(img, msg, 0.5)
    scr.fb.blit(img)
    kb.drain()
    scr._wait_dismiss(kb)
    kb.drain()

    return "%d|%d|%s|%d|%d|%d|%d|%d|%s" % (
        coverage, len(dead), ", ".join(p.names) or "none", max_simul, ghost,
        contacts, supported, 1 if p.uncalibrated else 0, " ".join(dead[:40]))


# ---------------------------------------------------------------- camera test
# V4L2 straight through ioctl: no ffmpeg, no gstreamer, nothing to install. The
# camera is asked for MJPEG first because Pillow decodes it directly and it is
# what almost every UVC webcam offers; YUYV is the fallback and is converted
# here. Frames are drawn continuously so focus, a dead sensor and the privacy
# shutter can all be judged by eye.
VIDIOC_QUERYCAP  = 0x80685600
VIDIOC_S_FMT     = 0xC0D05605
VIDIOC_REQBUFS   = 0xC0145608
VIDIOC_QUERYBUF  = 0xC0585609
VIDIOC_QBUF      = 0xC058560F
VIDIOC_DQBUF     = 0xC0585611
VIDIOC_STREAMON  = 0x40045612
VIDIOC_STREAMOFF = 0x40045613
V4L2_BUF_TYPE_VIDEO_CAPTURE = 1
V4L2_MEMORY_MMAP = 1
# struct v4l2_buffer field offsets on 64-bit, taken from the kernel headers
# rather than counted by eye - a wrong offset here reads garbage, silently.
V4L2_BUF_INDEX, V4L2_BUF_TYPE = 0, 4
V4L2_BUF_BYTESUSED = 8
V4L2_BUF_MEMORY, V4L2_BUF_M, V4L2_BUF_LENGTH = 60, 64, 72
V4L2_BUF_SIZE = 88

def _fourcc(a): return (ord(a[0]) | ord(a[1]) << 8 | ord(a[2]) << 16 | ord(a[3]) << 24)
PIX_MJPEG = _fourcc("MJPG")
PIX_YUYV  = _fourcc("YUYV")


class Camera:
    def __init__(self, path, want_w=640, want_h=480):
        self.path = path
        self.fd = os.open(path, os.O_RDWR)
        cap = fcntl.ioctl(self.fd, VIDIOC_QUERYCAP, b"\0" * 104)
        self.driver = cap[0:16].rstrip(b"\0").decode("ascii", "replace")
        self.card   = cap[16:48].rstrip(b"\0").decode("ascii", "replace")
        self.pixfmt = None
        # YUYV first. Plenty of webcams emit MJPEG without Huffman tables, which
        # libjpeg refuses outright - every frame would fail to decode and a
        # working camera would be reported as delivering nothing. YUYV is
        # universally supported and is the path that has actually been tested.
        for pf in (PIX_YUYV, PIX_MJPEG):
            fmt = struct.pack("<II", V4L2_BUF_TYPE_VIDEO_CAPTURE, 0)
            fmt += struct.pack("<IIIIIIII", want_w, want_h, pf, 1, 0, 0, 0, 0)
            fmt += b"\0" * (208 - len(fmt))
            try:
                got = fcntl.ioctl(self.fd, VIDIOC_S_FMT, fmt)
            except OSError:
                continue
            w, h, gotfmt = struct.unpack_from("<III", got, 8)
            if gotfmt == pf:
                self.w, self.h, self.pixfmt = w, h, pf
                break
        if self.pixfmt is None:
            raise RuntimeError("camera offers neither MJPEG nor YUYV")

        req = struct.pack("<IIIII", 4, V4L2_BUF_TYPE_VIDEO_CAPTURE, V4L2_MEMORY_MMAP, 0, 0)
        req = fcntl.ioctl(self.fd, VIDIOC_REQBUFS, req)
        self.count = struct.unpack_from("<I", req, 0)[0]
        if self.count < 1:
            raise RuntimeError("camera gave no buffers")
        self.bufs = []
        for i in range(self.count):
            b = bytearray(V4L2_BUF_SIZE)
            struct.pack_into("<II", b, 0, i, V4L2_BUF_TYPE_VIDEO_CAPTURE)
            struct.pack_into("<I", b, V4L2_BUF_MEMORY, V4L2_MEMORY_MMAP)
            r = fcntl.ioctl(self.fd, VIDIOC_QUERYBUF, bytes(b))
            length = struct.unpack_from("<I", r, V4L2_BUF_LENGTH)[0]
            offset = struct.unpack_from("<I", r, V4L2_BUF_M)[0]
            self.bufs.append(mmap.mmap(self.fd, length, mmap.MAP_SHARED,
                                       mmap.PROT_READ, offset=offset))
            fcntl.ioctl(self.fd, VIDIOC_QBUF, r)
        fcntl.ioctl(self.fd, VIDIOC_STREAMON,
                    struct.pack("<I", V4L2_BUF_TYPE_VIDEO_CAPTURE))
        self.streaming = True

    def frame(self, timeout=1.0):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return None
        b = bytearray(V4L2_BUF_SIZE)
        struct.pack_into("<II", b, 0, 0, V4L2_BUF_TYPE_VIDEO_CAPTURE)
        struct.pack_into("<I", b, V4L2_BUF_MEMORY, V4L2_MEMORY_MMAP)
        try:
            got = fcntl.ioctl(self.fd, VIDIOC_DQBUF, bytes(b))
        except OSError:
            return None
        idx = struct.unpack_from("<I", got, V4L2_BUF_INDEX)[0]
        used = struct.unpack_from("<I", got, V4L2_BUF_BYTESUSED)[0]
        raw = self.bufs[idx][:used]
        try:
            if self.pixfmt == PIX_MJPEG:
                import io
                img = Image.open(io.BytesIO(bytes(raw))); img.load()
                img = img.convert("RGB")
            else:
                img = self._yuyv(bytes(raw))
        except Exception:
            img = None
        try: fcntl.ioctl(self.fd, VIDIOC_QBUF, got)
        except OSError: pass
        return img

    def _yuyv(self, raw):
        """YUYV 4:2:2 to RGB, in colour.

        A colour cast - green, pink, washed out - is one of the faults you are
        looking for, so throwing the chroma away would hide it. Per-pixel maths
        in Python would be far too slow at 30 fps, so the three planes are
        sliced out with bytes steps and handed to Pillow, which does the
        conversion in C.  Byte order is Y0 U Y1 V, so U and V are every fourth
        byte and cover two pixels each.
        """
        w, h = self.w, self.h
        need = w * h * 2
        if len(raw) < need:
            raw = raw + b"\0" * (need - len(raw))
        raw = bytes(raw[:need])
        y  = Image.frombytes("L", (w, h), raw[0::2])
        cb = Image.frombytes("L", (w // 2, h), raw[1::4]).resize((w, h))
        cr = Image.frombytes("L", (w // 2, h), raw[3::4]).resize((w, h))
        return Image.merge("YCbCr", (y, cb, cr)).convert("RGB")

    def close(self):
        try:
            if self.streaming:
                fcntl.ioctl(self.fd, VIDIOC_STREAMOFF,
                            struct.pack("<I", V4L2_BUF_TYPE_VIDEO_CAPTURE))
        except Exception: pass
        for b in getattr(self, "bufs", []):
            try: b.close()
            except Exception: pass
        try: os.close(self.fd)
        except Exception: pass


def _cameras():
    out = []
    try:
        names = sorted(n for n in os.listdir("/dev") if n.startswith("video"))
    except OSError:
        return out
    for n in names:
        path = "/dev/" + n
        try:
            fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        except OSError:
            continue
        try:
            cap = fcntl.ioctl(fd, VIDIOC_QUERYCAP, b"\0" * 104)
            caps = struct.unpack_from("<I", cap, 84)[0]
            dcaps = struct.unpack_from("<I", cap, 88)[0]
            use = dcaps if dcaps else caps
            # bit 0 = VIDEO_CAPTURE; metadata and output nodes are skipped
            if use & 0x00000001:
                out.append((path, cap[16:48].rstrip(b"\0").decode("ascii", "replace")))
        except Exception:
            pass
        finally:
            os.close(fd)
    return out


def camera_test(scr, kb):
    cams = _cameras()
    if not cams:
        scr.title = "Camera test"; scr.hint = "Enter to go back"
        scr.items = [("badge", 6, "UNKNOWN", "no camera found"),
                     ("line", 9, "No video capture device is present on this machine.", ""),
                     ("line", 10, "A camera disabled in the BIOS looks exactly like this.", "muted")]
        scr.render(); scr._wait_dismiss(kb)
        return "none|0|0|0|0"

    path, card = cams[0]
    try:
        cam = Camera(path)
    except Exception as exc:
        scr.title = "Camera test"; scr.hint = "Enter to go back"
        scr.items = [("badge", 6, "FAIL", "the camera would not start"),
                     ("line", 9, "%s was found but could not be opened for capture." % card, ""),
                     ("line", 10, str(exc)[:90], "muted")]
        scr.render(); scr._wait_dismiss(kb)
        return "%s|0|0|0|0" % card

    s = scr.s
    frames = 0
    dark = 0
    last_mean = 0
    t0 = time.time()
    fps = 0.0
    kb.drain()

    def draw(img, note):
        canvas = Image.new("RGB", (scr.W, scr.H), GROUND)
        d = ImageDraw.Draw(canvas)
        cy = scr.hdr // 2; r = int(7 * s)
        _draw_brand(canvas, scr.M, cy, int(2.3 * r))
        d.text((scr.M + 3 * r, cy), "Hardware Diagnostic Toolkit",
               font=scr.f_brand, fill=INK, anchor="lm")
        d.text((scr.W - scr.M, cy), "%dx%d   %s   %.0f fps"
               % (cam.w, cam.h, "MJPEG" if cam.pixfmt == PIX_MJPEG else "YUYV", fps),
               font=scr.f_small, fill=MUTED, anchor="rm")

        x0, y0, x1, y1 = scr._card(d)
        d.text((x0 + scr.pad, y0 + scr.pad), "Camera test", font=scr.f_h, fill=INK, anchor="la")
        top = y0 + scr.pad + int(58 * s)
        boxh = (y1 - int(70 * s)) - top
        boxw = int(boxh * cam.w / float(cam.h))
        if boxw > x1 - x0 - 2 * scr.pad:
            boxw = x1 - x0 - 2 * scr.pad
            boxh = int(boxw * cam.h / float(cam.w))
        bx = x0 + (x1 - x0 - boxw) // 2
        if img is not None:
            canvas.paste(img.resize((boxw, boxh)), (bx, top))
        else:
            d.rounded_rectangle([bx, top, bx + boxw, top + boxh], int(10 * s), fill=GROUND)
            d.text((bx + boxw // 2, top + boxh // 2), "waiting for a frame...",
                   font=scr.f_body, fill=MUTED, anchor="mm")
        d.rounded_rectangle([bx, top, bx + boxw, top + boxh], int(10 * s),
                            outline=LINE, width=2)
        if note:
            d.text((bx, top + boxh + int(18 * s)), note, font=scr.f_body,
                   fill=WARN_, anchor="la")
        d.text((scr.M + int(4 * s), scr.H - scr.ftr // 2),
               "check focus, colour and the privacy shutter    "
               "cover the lens to confirm it reacts    Enter or Esc to finish",
               font=scr.f_small, fill=MUTED, anchor="lm")
        scr.fb.blit(canvas)

    draw(None, "")
    last_draw = 0.0
    while True:
        img = cam.frame(0.5)
        now = time.time()
        if img is not None:
            frames += 1
            if frames % 5 == 1:
                small = img.resize((32, 24))
                px = list(small.convert("L").getdata())
                last_mean = sum(px) // len(px)
                if last_mean < 12:
                    dark += 1
            fps = frames / max(0.001, now - t0)
        if now - last_draw >= 0.06:
            note = ""
            if img is not None and last_mean < 12:
                note = "the image is black - lens covered, or a dead sensor"
            draw(img, note)
            last_draw = now
        name, _ = kb.poll(0.001)
        if name in ("enter", "esc", "q", "space"):
            break
        if frames == 0 and now - t0 > 12:
            break
    cam.close()
    kb.drain()
    return "%s|%d|%d|%d|%d" % (card, frames, int(fps), last_mean, dark)


# ---------------------------------------------------------------- screen test
# Full-screen flat colours for dead (always dark), stuck (always lit) and hot
# pixels, plus a grey ramp for banding and a dark grey that shows backlight
# bleed at the edges. The instruction pill fades after a moment so nothing is
# covering the panel while the operator looks; any key brings it back.
PIX_SCREENS = [
    ("Black",  "look for lit dots - stuck or hot pixels",           (0, 0, 0)),
    ("White",  "look for dark dots - dead pixels - and dust",        (255, 255, 255)),
    ("Red",    "a dot missing its red shows dark here",              (255, 0, 0)),
    ("Green",  "a dot missing its green shows dark here",            (0, 255, 0)),
    ("Blue",   "a dot missing its blue shows dark here",             (0, 0, 255)),
    ("Grey",   "look for blotches, pressure marks and uneven tint",  (128, 128, 128)),
    ("Dark grey", "look at the edges for backlight bleed",           (24, 24, 24)),
    ("Ramp",   "the steps should be smooth - bands or lines are a fault", None),
]
PIX_HINT_SECS = 2.5


def _pix_ramp(w, h):
    """Black to white left to right, in 32 visible steps above a smooth one."""
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    steps = 32
    for i in range(steps):
        v = int(i * 255 / (steps - 1))
        d.rectangle([i * w // steps, 0, (i + 1) * w // steps, h // 2], fill=(v, v, v))
    # linear_gradient runs black at the top to white at the bottom; a quarter
    # turn anticlockwise puts black on the left, matching the steps above.
    smooth = Image.linear_gradient("L").rotate(90, expand=True).resize((w, h - h // 2))
    img.paste(Image.merge("RGB", (smooth, smooth, smooth)), (0, h // 2))
    return img


def pixel_test(scr, kb):
    s = scr.s
    W, H = scr.W, scr.H
    seen = set()
    i = 0
    kb.drain()
    hint_until = time.time() + PIX_HINT_SECS
    while True:
        name, why, col = PIX_SCREENS[i]
        seen.add(i)
        img = _pix_ramp(W, H) if col is None else Image.new("RGB", (W, H), col)
        now = time.time()
        if now < hint_until:
            d = ImageDraw.Draw(img)
            text = "%d of %d   %s - %s" % (i + 1, len(PIX_SCREENS), name, why)
            keys = "Space or arrows for the next colour    Esc when finished"
            tw = max(d.textlength(text, font=scr.f_body),
                     d.textlength(keys, font=scr.f_small)) + int(48 * s)
            bh = int(86 * s)
            bx, by = (W - tw) // 2, H - bh - int(40 * s)
            d.rounded_rectangle([bx, by, bx + tw, by + bh], bh // 3,
                                fill=(250, 250, 250), outline=(40, 40, 40), width=2)
            d.text((W // 2, by + int(28 * s)), text, font=scr.f_bodyb,
                   fill=(20, 20, 20), anchor="mm")
            d.text((W // 2, by + int(60 * s)), keys, font=scr.f_small,
                   fill=(90, 90, 90), anchor="mm")
        scr.fb.blit(img)
        key = "hover"
        while key in ("hover", "wheelup", "wheeldown"):   # the pointer is hidden here
            t = time.time()
            wait = (hint_until - t) if t < hint_until else 600
            key, _ = kb.poll(max(0.05, wait))
        if key == "click":
            key = "space"
        elif key == "back":
            key = "esc"
        if key is None:
            # Ten silent minutes (or no keyboard at all) must not leave the
            # machine stuck on a flat colour.
            if time.time() - hint_until > 590:
                break
            continue                               # the hint timed out: repaint clean
        hint_until = time.time() + PIX_HINT_SECS
        if key in ("space", "right", "down", "enter", "pgdn"):
            if i == len(PIX_SCREENS) - 1:
                break
            i += 1
        elif key in ("left", "up", "backspace", "pgup"):
            i = max(0, i - 1)
        elif key in ("esc", "q"):
            break
    kb.drain()
    return "%d|%d" % (len(seen), len(PIX_SCREENS))


def _kb_events(kb, timeout):
    """Raw (code, value) pairs - the keyboard test needs releases too."""
    out = []
    if not kb.fds:
        time.sleep(timeout); return out
    r, _, _ = select.select(kb.fds, [], [], timeout)
    for fd in r:
        try: data = os.read(fd, EVENT_SIZE * 64)
        except OSError: continue
        for i in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
            _, _, etype, code, value = struct.unpack(EVENT_FMT, data[i:i + EVENT_SIZE])
            if etype == EV_KEY and value in (0, 1):
                out.append((code, value))
    return out


# ---------------------------------------------------------------- daemon
def main():
    os.makedirs(RUN, exist_ok=True)
    load_settings()          # palette and text scale, before the first frame
    for p in (CMD, REPLY):
        if not os.path.exists(p):
            os.mkfifo(p, 0o600)

    fb = Framebuffer()
    console(KD_GRAPHICS)
    scr = Screen(fb)
    kb = Keyboard()
    if not kb.script:                    # no pointer in the scripted smoke test
        fb.cursor = kb.cursor = Cursor(fb, scr.s)
        kb.s = scr.s
    kb.tick = scr.tick                   # clock and Wi-Fi icon, while waiting

    def fullscreen(fn, *args):
        """A test that owns the whole screen: no header refresh drawn over it,
        and no pointer - on the black page of the screen test it would pass
        for a stuck pixel."""
        scr.mode = "full"
        if fb.cursor: fb.cursor.set_enabled(False)
        try:
            return fn(*args)
        finally:
            if fb.cursor: fb.cursor.set_enabled(True)

    def cleanup(*_):
        try: kb.close()
        except Exception: pass
        console(KD_TEXT)
        try: fb.close()
        except Exception: pass
        sys.exit(0)
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    scr.title = "Starting up"
    scr.items = [("line", 6, "Detecting hardware...", "muted")]
    scr.render()

    def reply(text):
        # open/write/close each time: the shell opens the read end per request,
        # so a persistent writer would take EPIPE the moment it closed.
        fd = os.open(REPLY, os.O_WRONLY)
        try: os.write(fd, (str(text) + "\n").encode())
        finally: os.close(fd)

    # A test's animation playing while the test runs (ssdanim.Live for the
    # drives, hwanim.Live for the rest). It draws every frame itself, from the
    # test's own title and lines; any screen that asks the operator something
    # stops it first. A test can ask for fewer frames ("fps=1"): a battery
    # drain must not pay for a smooth picture out of the pack it measures.
    live = {"anim": None, "t": 0.0}

    def live_period():
        return 1.0 / live["anim"].fps

    def anim_module(name):
        """The set a scene belongs to. Imported on first use, so a fault in
        an animation can only cost that screen, never the renderer's start."""
        import hwanim
        if name in hwanim.NAMES:
            return hwanim
        import ssdanim
        return ssdanim

    def live_end():
        if live["anim"] is not None:
            live["anim"] = None
            scr.mode = "card"
            if fb.cursor: fb.cursor.set_enabled(True)

    def live_paint():
        """One frame; False (and live mode ended) if the animation failed -
        the test then shows its usual screen instead of a frozen one."""
        try:
            fb.blit(live["anim"].frame(scr.title, scr.hint, scr.items))
            live["t"] = time.time()
            return True
        except Exception as exc:
            import traceback
            sys.stderr.write("ui: live animation FAILED: %s\n%s\n" % (exc, traceback.format_exc()))
            live_end()
            return False

    cmd_fd = os.open(CMD, os.O_RDONLY)
    buf = b""
    dirty = False
    last_paint = 0.0
    # Between "frame" and "flush" a script is still building the screen; a
    # screen that refreshes itself (the USB list, once a second) would
    # otherwise be painted half-built and its lower rows would flicker. The
    # timer paints anyway after a while, for scripts that never flush.
    building = None
    try:
        while True:
            r, _, _ = select.select([cmd_fd], [], [],
                                    min(0.12, live_period()) if live["anim"] is not None else 0.12)
            if r:
                chunk = os.read(cmd_fd, 65536)
                if not chunk:                     # writer closed; reopen
                    os.close(cmd_fd); cmd_fd = os.open(CMD, os.O_RDONLY); continue
                buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                parts = raw.decode("utf-8", "replace").split("\t")
                op = parts[0]
                if op not in ("kv", "line", "bar", "trow"):
                    # TABs shown as " | ": raw, they came out as boxes in the
                    # Toolkit log and ran the fields together.
                    sys.stderr.write("> %s\n" % " | ".join(parts)[:160])
                    sys.stderr.flush()
                # A question or a result ends a live animation: the operator
                # must see the screen that asks, not the drive picture.
                if live["anim"] is not None and op in (
                        "anykey", "menu", "gridmenu", "confirm", "input", "msg", "pager",
                        "kbtest", "ptrtest", "camtest", "tstest", "pixtest", "anim"):
                    live_end(); dirty = True
                # A blocking command must not sit on the keyboard while the
                # screen still shows the previous frame.
                if dirty and live["anim"] is None and op in ("waitkey", "anykey", "menu", "confirm",
                                    "input", "msg", "pager", "kbtest", "gridmenu", "ptrtest", "camtest", "tstest",
                                    "pixtest", "anim"):
                    scr.render(); dirty = False
                try:
                    if op == "frame":
                        scr.title = parts[1] if len(parts) > 1 else ""
                        scr.hint  = parts[2] if len(parts) > 2 else ""
                        scr.items = []; dirty = True
                        building = time.time()
                    elif op == "sub":
                        scr.sub = "\n".join(p for p in parts[1:3] if p.strip())
                        dirty = True
                    elif op == "kv":
                        scr.items = [i for i in scr.items
                                     if not (i[0] == "kv" and i[1] == parts[1])]
                        scr.items.append(("kv", parts[1], parts[2], parts[3],
                                          parts[4] if len(parts) > 4 else "")); dirty = True
                    elif op == "line":
                        scr.items = [i for i in scr.items
                                     if not (i[0] == "line" and i[1] == parts[1])]
                        scr.items.append(("line", parts[1], parts[2],
                                          parts[3] if len(parts) > 3 else "")); dirty = True
                    elif op == "bar":
                        scr.items = [i for i in scr.items if i[0] != "bar"]
                        scr.items.append(("bar", parts[1], int(float(parts[2])))); dirty = True
                    elif op == "badge":
                        scr.items.append(("badge", parts[1], parts[2],
                                          parts[3] if len(parts) > 3 else "")); dirty = True
                    elif op == "thead":
                        scr.items.append(("thead", parts[1], parts[2:])); dirty = True
                    elif op == "trow":
                        scr.items = [i for i in scr.items
                                     if not (i[0] == "trow" and i[1] == parts[1])]
                        scr.items.append(("trow", parts[1], parts[2:])); dirty = True
                    elif op == "setting":
                        # key, value. Applied immediately and kept, so the rest
                        # of the session and the next restart both follow it.
                        key = parts[1] if len(parts) > 1 else ""
                        val = parts[2] if len(parts) > 2 else ""
                        if key == "theme":
                            apply_theme(val)
                        elif key == "look" and val in ("manual", "classic"):
                            globals()["LOOK"] = val
                        elif key == "textscale":
                            try:
                                globals()["TEXT_SCALE"] = max(0.75, min(2.5, float(val)))
                            except ValueError:
                                pass
                        scr._build_fonts()
                        dirty = True
                    elif op == "flush":
                        if live["anim"] is None:
                            scr.render()
                        dirty = False; building = None
                    elif op == "animlive":
                        # scene, first step, last step, then options: "own" /
                        # "none" (the drive's DRAM), "fps=N"
                        name = parts[1] if len(parts) > 1 else ""
                        mod = anim_module(name)
                        if live["anim"] is None or live["anim"].K is not mod:
                            live["anim"] = mod.Live(scr, anim_palette())
                            scr.mode = "full"
                            if fb.cursor: fb.cursor.set_enabled(False)
                        num = lambda k, dflt: int(parts[k]) if len(parts) > k and parts[k].isdigit() else dflt
                        live["anim"].set(name, num(2, 0), num(3, None), *parts[4:])
                        dirty = False
                        if not live_paint():
                            dirty = True
                    elif op == "animstop":
                        live_end(); dirty = True
                    elif op == "menu":
                        entries = []
                        for e in parts[3:]:
                            name, _, desc = e.partition("|")
                            entries.append((name.strip(), desc.strip()))
                        reply(scr.menu(kb, parts[1], parts[2], entries)); dirty = False
                    elif op == "gridmenu":
                        entries = []
                        for e in parts[3:]:
                            # Label|icon|result - the result ("PASS 14:02") is
                            # optional and fills the sheet's parts list
                            label, _, rest = e.partition("|")
                            icon, _, res = rest.partition("|")
                            entries.append((label.strip(), icon.strip() or "info", res.strip()))
                        reply(scr.gridmenu(kb, parts[1], parts[2], entries)); dirty = False
                    elif op == "msg":
                        scr.msg(kb, parts[1], parts[2:]); reply("ok"); dirty = False
                    elif op == "confirm":
                        reply(scr.confirm(kb, parts[1], parts[2], parts[3:])); dirty = False
                    elif op == "input":
                        reply(scr.text_input(kb, parts[1], parts[2])); dirty = False
                    elif op == "anykey":
                        scr._wait_dismiss(kb); reply("ok")
                    elif op == "pager":
                        scr.pager(kb, parts[1], parts[2]); reply("ok"); dirty = False
                    elif op == "waitkey":
                        # Keys only: a test polling for Q must neither return
                        # early nor be stopped because the mouse moved. It
                        # always looks at least once: "waitkey 0" used never
                        # to poll at all, so Q could not stop the tests that
                        # check between long steps (install simulation,
                        # benchmark passes, the heavy controller slices).
                        # A live animation keeps playing while it waits.
                        end = time.time() + float(parts[1])
                        name = None
                        while True:
                            if live["anim"] is not None and not live_paint():
                                dirty = True; scr.render(); dirty = False
                            left = end - time.time()
                            step = min(left, live_period()) if live["anim"] is not None else left
                            name, _ = kb.poll(max(0.01, step))
                            if name is not None and name not in Keyboard.POINTER_EVENTS:
                                break
                            name = None
                            if time.time() >= end:
                                break
                        reply(name or "")
                    elif op == "camtest":
                        reply(fullscreen(camera_test, scr, kb)); dirty = True
                    elif op == "ptrtest":
                        reply(fullscreen(pointer_test, scr, kb, parts[1] if len(parts) > 1
                                         else "touchpad")); dirty = True
                    elif op == "kbtest":
                        reply(fullscreen(keyboard_test, scr, kb)); dirty = True
                    elif op == "tstest":
                        reply(fullscreen(touchscreen_test, scr, kb)); dirty = True
                    elif op == "pixtest":
                        reply(fullscreen(pixel_test, scr, kb)); dirty = True
                    elif op == "anim":
                        # The "how it works" animations: the drive tests
                        # (ssdanim) or the rest of the machine's (hwanim).
                        name = parts[1] if len(parts) > 1 else ""
                        reply(fullscreen(anim_module(name).play, scr, kb, anim_palette(), name)); dirty = True
                    elif op == "ptrprobe":
                        # How many devices of a kind are there right now -
                        # lets touchpad.sh look for a driver before the test
                        # screen, rather than after a "nothing found" page.
                        want = parts[1] if len(parts) > 1 else "touchpad"
                        reply(sum(1 for _, _, k in Pointer._devices() if k == want))
                    elif op == "quit":
                        cleanup()
                except Exception as exc:          # never let one bad command kill the UI
                    import traceback
                    sys.stderr.write("ui: %s FAILED: %s\n%s\n"
                                     % (op, exc, traceback.format_exc()))
                    sys.stderr.flush()
                    if op in ("menu", "confirm", "input", "msg", "anykey",
                              "pager", "waitkey", "kbtest", "gridmenu", "ptrtest", "camtest", "tstest",
                              "pixtest", "ptrprobe", "anim"):
                        reply("")
            now = time.time()
            if live["anim"] is not None:
                if now - live["t"] >= live_period() and not live_paint():
                    dirty = True
            elif dirty and now - last_paint >= 0.1 and \
                    (building is None or now - building > 1.5):
                scr.render(); dirty = False; last_paint = now; building = None
            elif not dirty and building is None:
                scr.tick()           # the header clock, between script frames
    finally:
        cleanup()


if __name__ == "__main__":
    main()
