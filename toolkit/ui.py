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
import os, sys, mmap, fcntl, struct, select, time, signal

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

SETTINGS_FILE = os.path.join(os.environ.get("DIAG_RUN", "/run/diag"), "settings.conf")

def load_settings():
    """Applied before the first frame, so the operator's choice survives a
    restart of the renderer as well as a change made while it is running."""
    global TEXT_SCALE
    try:
        with open(SETTINGS_FILE) as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k == "theme":
                    apply_theme(v)
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

    def blit(self, img):
        data = img.tobytes("raw", self.rawmode)
        if self.stride == self.rowbytes:
            self.map.seek(0)
            self.map.write(data)
        else:                      # padded scanlines
            for y in range(self.h):
                self.map.seek(y * self.stride)
                self.map.write(data[y * self.rowbytes:(y + 1) * self.rowbytes])

    def close(self):
        try: self.map.close()
        except Exception: pass
        try: os.close(self.fd)
        except Exception: pass


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
    def __init__(self, grab=True):
        self.script = os.environ.get("DIAG_UI_KEYS")
        self.fds, self.paths = [], []
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
        if not self.fds:
            time.sleep(min(timeout, 0.5))
            return None, None
        end = time.time() + timeout
        while True:
            left = end - time.time()
            if left <= 0:
                return None, None
            r, _, _ = select.select(self.fds, [], [], left)
            for fd in r:
                try: data = os.read(fd, EVENT_SIZE * 64)
                except OSError: continue
                for i in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                    _, _, etype, code, value = struct.unpack(
                        EVENT_FMT, data[i:i + EVENT_SIZE])
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

    def drain(self):
        if self.script:
            return
        for fd in self.fds:
            try:
                while os.read(fd, EVENT_SIZE * 64):
                    pass
            except OSError:
                pass

    def close(self):
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
    def render(self):
        img = Image.new("RGB", (self.W, self.H), GROUND)
        d = ImageDraw.Draw(img)

        # header
        cy = self.hdr // 2
        r = int(7 * self.s)
        _draw_brand(img, self.M, cy, int(2.3 * r))
        d.text((self.M + 3 * r, cy), "Hardware Diagnostic Toolkit",
               font=self.f_brand, fill=INK, anchor="lm")
        if self.sub:
            for i, part in enumerate(self.sub.split("\n")[:2]):
                d.text((self.W - self.M, cy - int(9 * self.s) + i * int(19 * self.s)),
                       part, font=self.f_small, fill=MUTED, anchor="rm")

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
            for i, (label, active, on, off) in enumerate(
                    (("YES", yes, (PASS_, PAPER), (GROUND, MUTED)),
                     ("NO", not yes, (FAIL_, PAPER), (GROUND, MUTED)))):
                w = int(150 * self.s)
                x = left + i * (w + int(20 * self.s))
                bg, fg = on if active else off
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
                    d.text((x, y), c, font=f, fill=INK, anchor="la")
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
            _, sel, entries = it
            y = self.row_y(6) + int(6 * self.s)
            # A long menu tightens its rows rather than running off the card.
            room = (self.H - self.ftr - self.pad) - y
            rh = int(46 * self.s)
            if entries and len(entries) * rh > room:
                rh = max(int(30 * self.s), room // len(entries))
            # Still too many (a busy office can put 40 networks in a wifi
            # list): show a window that follows the selection instead of
            # drawing rows off the bottom of the screen where they cannot be
            # seen or reached.
            allrows = list(enumerate(entries))
            fit = max(1, room // rh)
            if len(allrows) > fit:
                start = min(max(0, sel - fit // 2), len(allrows) - fit)
                allrows = allrows[start:start + fit]
            # One description column for the whole menu, pushed out far enough
            # that the longest name cannot run into it.
            namex = left + int(38 * self.s)
            descx = max(left + int(230 * self.s),
                        namex + int(20 * self.s) + max(
                            [d.textlength(n, font=self.f_bodyb) for n, _ in entries] or [0]))
            for slot, (i, (name, desc)) in enumerate(allrows):
                top = y + slot * rh
                if i == sel:
                    d.rounded_rectangle([left - int(14 * self.s), top - int(8 * self.s),
                                         right + int(14 * self.s), top + rh - int(14 * self.s)],
                                        max(4, self.radius // 2), fill=ACCENT)
                    nc, dc, ic = PAPER, (219, 231, 255), (219, 231, 255)
                else:
                    nc, dc, ic = INK, MUTED, MUTED
                d.text((left, top), str(i + 1), font=self.f_mono, fill=ic, anchor="la")
                d.text((namex, top), name, font=self.f_bodyb, fill=nc, anchor="la")
                if desc:
                    d.text((descx, top), self._clip(d, desc, self.f_body, right - descx),
                           font=self.f_body, fill=dc, anchor="la")

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
        for i, (name, icon) in enumerate(entries):
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
        cy = self.hdr // 2
        rr = int(7 * self.s)
        _draw_brand(img, self.M, cy, int(2.3 * rr))
        d.text((self.M + 3 * rr, cy), "Hardware Diagnostic Toolkit",
               font=self.f_brand, fill=INK, anchor="lm")
        if self.sub:
            for i, part in enumerate(self.sub.split("\n")[:2]):
                d.text((self.W - self.M, cy - int(9 * self.s) + i * int(19 * self.s)),
                       part, font=self.f_small, fill=MUTED, anchor="rm")
        if self.title:
            d.text((self.M, self.hdr + int(14 * self.s)), self.title,
                   font=self.f_h, fill=INK, anchor="la")
        self._draw_grid(d, img, sel, entries)
        if self.hint:
            d.text((self.M + int(4 * self.s), self.H - self.ftr // 2), self.hint,
                   font=self.f_small, fill=MUTED, anchor="lm")
        self.fb.blit(img)

    # ---- blocking widgets ------------------------------------------
    def menu(self, kb, title, hint, entries):
        sel = 0
        self.title, self.hint = title, hint
        kb.drain()                           # discard anything typed before this screen
        while True:
            self.items = [("menu", sel, entries)]
            self.render()
            name, code = kb.poll(3600)
            if name == "up":     sel = (sel - 1) % len(entries)
            elif name == "down": sel = (sel + 1) % len(entries)
            elif name == "enter": return sel + 1
            elif name in ("esc", "q"): return 0
            elif name and name.isdigit():
                pick = _pick_number(kb, name, len(entries))
                if pick: return pick

    def gridmenu(self, kb, title, hint, entries):
        """entries: list of (label, icon). Arrow keys move in two dimensions."""
        sel = 0
        self.title, self.hint = title, hint
        kb.drain()
        while True:
            cols, _, _, _, _ = self._grid_geometry(len(entries))
            self.render_grid(sel, entries)
            name, code = kb.poll(3600)
            n = len(entries)
            if   name == "left":  sel = (sel - 1) % n
            elif name == "right": sel = (sel + 1) % n
            elif name == "up":    sel = (sel - cols) % n if sel - cols >= 0 else sel
            elif name == "down":  sel = sel + cols if sel + cols < n else sel
            elif name == "enter": return sel + 1
            elif name in ("esc", "q"): return 0
            elif name and name.isdigit():
                pick = _pick_number(kb, name, n)
                if pick: return pick

    def msg(self, kb, title, lines):
        self.title, self.hint = title, "Enter to continue"
        self.items = [("line", 6 + i, l, "") for i, l in enumerate(lines)]
        self.render()
        self._wait_dismiss(kb)

    def confirm(self, kb, title, default, lines):
        yes = (default != "no")
        self.title, self.hint = title, "arrows or Y / N, Enter to confirm"
        kb.drain()
        while True:
            items = [("line", 6 + i, l, "") for i, l in enumerate(lines)]
            # Both choices, always. A single pill showing the current value read
            # as though it were the only option available.
            items.append(("choice", 6 + len(lines) + 1, yes))
            self.items = items
            self.render()
            name, _ = kb.poll(3600)
            if name in ("left", "right", "up", "down"): yes = not yes
            elif name == "y": return 1
            elif name == "n": return 0
            elif name in ("esc", "q"): return 0
            elif name == "enter": return 1 if yes else 0

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
            if name in ("enter", "esc", "q", "space"):
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
            if name == "down": top = min(max(0, len(lines) - per), top + 1)
            elif name == "up": top = max(0, top - 1)
            elif name == "pgdn": top = min(max(0, len(lines) - per), top + per)
            elif name == "pgup": top = max(0, top - per)
            elif name in ("q", "esc", "enter"): return


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
            padname = any(w in low for w in ("touchpad", "trackpad", "synaptics",
                                             "elan", "alps", "glidepoint", "clickpad"))
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
            r, _, _ = select.select([cmd_fd], [], [], 0.12)
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
                    sys.stderr.write("> %s\n" % raw.decode("utf-8", "replace")[:160])
                    sys.stderr.flush()
                # A blocking command must not sit on the keyboard while the
                # screen still shows the previous frame.
                if dirty and op in ("waitkey", "anykey", "menu", "confirm",
                                    "input", "msg", "pager", "kbtest", "gridmenu", "ptrtest", "camtest", "tstest"):
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
                        elif key == "textscale":
                            try:
                                globals()["TEXT_SCALE"] = max(0.75, min(2.5, float(val)))
                            except ValueError:
                                pass
                        scr._build_fonts()
                        dirty = True
                    elif op == "flush":
                        scr.render(); dirty = False; building = None
                    elif op == "menu":
                        entries = []
                        for e in parts[3:]:
                            name, _, desc = e.partition("|")
                            entries.append((name.strip(), desc.strip()))
                        reply(scr.menu(kb, parts[1], parts[2], entries)); dirty = False
                    elif op == "gridmenu":
                        entries = []
                        for e in parts[3:]:
                            label, _, icon = e.partition("|")
                            entries.append((label.strip(), icon.strip() or "info"))
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
                        name, _ = kb.poll(float(parts[1]))
                        reply(name or "")
                    elif op == "camtest":
                        reply(camera_test(scr, kb)); dirty = True
                    elif op == "ptrtest":
                        reply(pointer_test(scr, kb, parts[1] if len(parts) > 1
                                           else "touchpad")); dirty = True
                    elif op == "kbtest":
                        reply(keyboard_test(scr, kb)); dirty = True
                    elif op == "tstest":
                        reply(touchscreen_test(scr, kb)); dirty = True
                    elif op == "quit":
                        cleanup()
                except Exception as exc:          # never let one bad command kill the UI
                    import traceback
                    sys.stderr.write("ui: %s FAILED: %s\n%s\n"
                                     % (op, exc, traceback.format_exc()))
                    sys.stderr.flush()
                    if op in ("menu", "confirm", "input", "msg", "anykey",
                              "pager", "waitkey", "kbtest", "gridmenu", "ptrtest", "camtest", "tstest"):
                        reply("")
            now = time.time()
            if dirty and now - last_paint >= 0.1 and \
                    (building is None or now - building > 1.5):
                scr.render(); dirty = False; last_paint = now; building = None
    finally:
        cleanup()


if __name__ == "__main__":
    main()
