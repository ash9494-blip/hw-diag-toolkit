#!/usr/bin/env python3
"""
How the HDD / SSD tests look from inside the drive.

One short animation per drive test - benchmark, install simulation, surface
read scan, drive self-test, SMART health and the controller - drawn by the
same renderer as the rest of the toolkit: ui.py hands over its screen, its
keyboard and the current palette, so every theme and text size works.

The frame and the drawing tools (Canvas), the player and live mode are shared
with hwanim.py, which draws the rest of the machine's tests the same way.

Each one shows what the toolkit puts on the bus and what the controller and
the flash do with it. The captions follow what the scripts really do (the fio
profiles in disktest.sh, the stamped 256 MB chunks in installsim.sh, badblocks,
the NVMe self-test, the SMART log), so if a script changes, change its caption
here too. Every figure on screen is an illustration and says so: an operator
must never mistake one of these for a measurement of the machine on the bench.

Standalone, for checking without a framebuffer (ui.py is imported for the
fonts, header and palette):
  ssdanim.py --check                      render every step of every animation
  ssdanim.py --frames DIR [--size WxH] [--theme T] [--fps N] [--scene NAME]
                                          write PNG frames, for a preview video
  ssdanim.py --text [NAME]                the captions as plain text (the text
                                          interface shows this instead)
"""
import math, os, random, sys, time

FPS = 15                  # target; a slow machine drops frames, the clock does not slow

# ---------------------------------------------------------------- the scripts
# (seconds, caption). The visuals for each step are in the scene's draw().
SCENES = [  # in the order of the HDD / SSD menu
    ("smart", "SMART health", "smartctl", [
        (6, "SMART health asks the controller for its own records - counters it has kept since "
            "the factory. Nothing is tested; it is read out (NVMe: Get Log Page)."),
        (7, "Identify: model, firmware revision, and the controller chip itself from its PCI ID. "
            "A fault often belongs to a controller + firmware pair, not to the brand on the label."),
        (8, "PCIe link: read while the drive is busy, because drives drop to a slow link at idle "
            "to save power. Full speed on all lanes is right; fewer lanes or a lower generation "
            "means reseat and clean the M.2 contacts."),
        (8, "Wear: each flash cell survives a few thousand write/erase cycles. Written in its life "
            "/ capacity = full-drive writes, the minimum cycles each cell has done. "
            "Percentage Used is the drive's own wear estimate."),
        (7, "Spare blocks stand in for cells that wear out. Available Spare falling towards its "
            "threshold means the drive is running out of replacements: replace it."),
        (6, "Media errors, power-on hours, unsafe shutdowns and temperature come from the same "
            "log. The overall verdict - PASSED or FAILED - is the drive's own."),
    ]),
    ("ctrl", "Controller check", "fio", [
        (7, "The controller check first names the chip that runs the drive (from its PCI ID) and "
            "its firmware. Then: does it have DRAM of its own, or borrow laptop RAM (HMB) for "
            "its map - and was it given any?"),
        (5, "Before the load, the drive's own counters are written down: temperature, "
            "heat-throttle events, the error log, media errors and PCIe link retries."),
        (9, "Then one minute of 4 KB random reads, 128 at once (4 jobs x queue 32). Small random "
            "reads work the controller hardest: a map lookup and a trip to a chip for every one. "
            "Read only - nothing is written."),
        (8, "Every 2 s the toolkit checks the temperature against the drive's own warning limit, "
            "the PCIe link speed and width, and the kernel log. A controller that hangs gets "
            "reset by Linux: FAIL."),
        (11, "Then the drive is left idle for 1, 2, 4 and 8 s. Idle, the controller powers down "
             "(APST) and the robots sleep. The next read is timed: a controller slow to wake is "
             "the one that vanishes or freezes the laptop."),
        (7, "Finally the counters are compared. New resets, I/O errors, media errors or "
            "uncorrectable PCIe errors = FAIL. Heat throttling, link retries, a slow wake-up or "
            "a freeze over 0.5 s = WARN."),
    ]),
    ("bench", "Benchmark", "fio", [
        (7, "fio runs the four CrystalDiskMark profiles, 5 s each, with direct I/O: the laptop's "
            "RAM cache is bypassed, so only the drive is measured. Each robot is one flash "
            "channel of the controller, fetching and storing blocks on its own chip."),
        (7, "SEQ1M Q8T1 - eight 1 MiB reads queued at once. The controller splits every request "
            "across all its channels, so all four robots fetch together: the highest MB/s."),
        (6, "SEQ1M Q1T1 - one 1 MiB request at a time. The next is only sent when the last one "
            "comes back, so the flash sits idle in between."),
        (7, "RND4K Q32T1 - 32 small 4 KiB reads at random addresses. Each is looked up in the "
            "FTL map, then sent to whichever chip holds it. Many chips busy at once: counted as IOPS."),
        (9, "RND4K Q1T1 - one 4 KiB read at a time, slowed down here about 20,000x: map lookup, "
            "flash read (~60 us), ECC check, back to the host. The lowest figure, and the one "
            "that feels like Windows."),
        (7, "Read + write mode repeats each profile writing. 5 s of writing lands in the SLC "
            "cache - fast cells kept free for bursts - so these are burst figures. Sustained "
            "writing is the install simulation's job."),
        (6, "Between passes the toolkit checks the drive temperature and that the drive is still "
            "on the bus. PASS = every pass gave throughput and the drive never dropped out."),
    ]),
    ("install", "Install simulation", "dd", [
        (6, "Windows setup writes 25-30 GB in one unbroken stream. This writes 48 GB the same way, "
            "in 256 MB steps, timing every step. The data is random, so the controller "
            "cannot compress it to cheat."),
        (7, "The first gigabytes land in the SLC cache: part of the flash run in fast 1-bit mode. "
            "The speed graph is high and flat - the benchmark never gets past this point."),
        (6, "Each 256 MB step has its serial number stamped into its first 4 KiB, so the "
            "read-back can tell if the drive hands back the wrong piece."),
        (9, "Around 20-40 GB the cache is full. The controller must now fold SLC into slow 3-bit "
            "TLC while new data keeps arriving, and the speed falls off a cliff. The cliff is "
            "normal. Dropping off the bus here is the fault this test is built to catch."),
        (7, "Read-back: every chunk is read again. A wrong serial = the drive lost track of where "
            "it put data (mapping fault). Changed bytes = silent corruption. Both FAIL."),
        (7, "Before and after, the drive's own counters are compared: PCIe errors, link width, "
            "media errors, thermal timers. If it fails, they say why: link, heat, firmware or flash."),
    ]),
    ("surface", "Surface read scan", "badblocks", [
        (5, "badblocks reads every 4 KiB block of the drive in order, first address to last, "
            "and lists any the drive cannot return. Nothing is written."),
        (8, "The host asks for addresses in order, but an SSD has no fixed layout: the "
            "controller's FTL map sends each address to wherever that data really lives."),
        (8, "Every read passes the ECC engine. Weak cells are corrected silently inside the drive. "
            "Only data that cannot be recovered comes back as a read error: a bad block."),
        (7, "Addresses that hold no data (never written, or trimmed) are answered from the map "
            "with zeros - the flash is not read. On an SSD a clean scan proves the data in use."),
        (6, "Any unreadable block is a FAIL: the drive holds data it can no longer give back. "
            "In this example one block failed, so the drive should be replaced."),
    ]),
    ("selftest", "Drive self-test", "smartctl", [
        (6, "The toolkit sends one command - Device Self-test - and from then on only asks for "
            "progress every 2 s. The test itself runs entirely inside the drive."),
        (8, "Short test (about 2 min): the controller checks its own RAM, its SMART data and its "
            "metadata, then samples the flash."),
        (8, "Extended test: the same, plus the controller reads all of its flash itself - the "
            "drive's own surface scan, with nothing crossing the bus."),
        (7, "If a segment fails, the drive stops and logs which. The toolkit reads the newest "
            "log entry: 0 = no error, PASS. 5-7 = the drive found a fault in itself, FAIL."),
        (6, "Your data is not changed. The drive keeps answering normal requests while it "
            "tests - just a little slower."),
    ]),
]
NAMES = [s[0] for s in SCENES]
# for the tabs: six full titles do not fit across a 1024 px screen
SHORT = {"smart": "SMART", "ctrl": "Controller", "bench": "Benchmark",
         "install": "Install sim.", "surface": "Surface scan", "selftest": "Self-test"}


# ---------------------------------------------------------------- small maths
def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else hi if v > hi else v

def lerp(a, b, u):
    return a + (b - a) * u

def ease(u):
    u = clamp(u)
    return u * u * (3 - 2 * u)

def seg(u, a, b):
    """Progress of u through the window [a, b], 0..1."""
    return clamp((u - a) / (b - a)) if b > a else float(u >= b)

def mix(c1, c2, t):
    return tuple(int(round(lerp(a, b, t))) for a, b in zip(c1, c2))

def hrand(*k):
    """Deterministic noise: the same frame always looks the same, so a paused
    or exported frame matches what was on screen."""
    return random.Random(hash(k) & 0xFFFFFFFF).random()

def thousands(n):
    return "{:,}".format(int(n))


# ---------------------------------------------------------------- palette
class Pal:
    def __init__(self, p):
        for k, v in p.items():
            setattr(self, k, v)
        # derived tints - computed, so every theme gets matching ones
        self.SOFT  = mix(self.ACCENT, self.PAPER, 0.80)
        self.DATA  = mix(self.ACCENT, self.PAPER, 0.55)
        self.SLC   = mix(self.WARN_,  self.PAPER, 0.72)
        self.SLCD  = mix(self.WARN_,  self.PAPER, 0.35)
        self.OKT   = mix(self.PASS_,  self.PAPER, 0.62)
        self.BADT  = self.FAIL_
        self.SPARE = mix(self.MUTED,  self.PAPER, 0.75)
        self.BOARD = mix(self.PASS_,  self.PAPER, 0.93)
        self.CHIP  = mix(self.INK,    self.PAPER, 0.88)
        self.GOLD  = mix(self.WARN_,  self.PAPER, 0.25)
        self.DIM   = mix(self.LINE,   self.PAPER, 0.35)


# ---------------------------------------------------------------- the stage
PKGS, ROWS, COLS = 4, 3, 6          # flash packages (one per channel), blocks in each
SLC_COLS = 2                        # the first two columns of every package: the SLC cache
SPARE_COL = COLS - 1                # the last column: spare blocks, in the SMART scene


class Canvas:
    """The frame every animation shares - title and tabs, the diagram area on
    the left, the side panel, the strip under the diagram and the caption -
    and the drawing primitives. Stage below draws an SSD in the diagram area;
    hwanim.py draws the rest of the machine in the same frame. Built once per
    screen size; frames are drawn onto a copy of a cached background so only
    the moving parts cost time."""

    def __init__(self, scr, pal):
        self.scr = scr
        self.P = pal
        s = self.s = scr.s
        self.W, self.H = scr.W, scr.H
        x0, y0, x1, y1 = scr._card_box()
        self.card = (x0, y0, x1, y1)
        pad = scr.pad
        self.ix0, self.ix1 = x0 + pad, x1 - pad
        self.title_y = y0 + int(pad * 0.8)
        self.tabs_y = self.title_y + int(46 * s)
        self.main_top = self.tabs_y + int(44 * s)

        self.f_cap = scr.f_body
        self.cap_lh = int(29 * s)
        self.cap_h = 3 * self.cap_lh + int(22 * s)
        self.cap_top = y1 - int(pad * 0.7) - self.cap_h
        main_bot = self.cap_top - int(14 * s)

        iw = self.ix1 - self.ix0
        panel_w = int(iw * 0.31)
        self.panel = (self.ix1 - panel_w, self.main_top, self.ix1, main_bot)
        dx0, dx1 = self.ix0, self.panel[0] - int(22 * s)
        self.strip_h = int(52 * s)
        self.strip_box = (dx0, main_bot - self.strip_h, dx1, main_bot)
        self.area = (dx0, self.main_top, dx1, main_bot - self.strip_h - int(10 * s))
        self.lt = 0.0               # seconds into the current step
        self.clock = 0.0            # live: seconds since the test's phase began
        self.bots = []
        self.bot_size(int(26 * s))
        self._tc = {}
        self._bg = {}
        self._bg_t = 0.0

    def bot_size(self, bh, box=None):
        """Robot height in pixels; the rest of a robot follows from it."""
        self.bh = bh
        self.bw = int(bh * 0.62)
        self.box = box if box else max(5, int(bh * 0.30))
        self.arm = int(self.bw * 0.45)

    def bot(self, xy, held=None, seed=0, busy=False, mood=""):
        """A robot standing at xy (where its wheels touch), for scenes that
        place their own; drawn last, by draw_bots, so nothing hides it."""
        self.bots.append((xy, held, seed, busy, mood))

    def cached(self, key):
        """A background built earlier - none once the header clock is stale."""
        now = time.time()
        if now - self._bg_t > 20:
            self._bg = {}; self._bg_t = now
        return self._bg.get(key)

    def chrome(self, scenes, short, scene_i):
        """A new background with what every scene has: the header, the card,
        the title, the tabs and the side panel's frame."""
        from PIL import Image, ImageDraw
        P, s, scr = self.P, self.s, self.scr
        img = Image.new("RGB", (self.W, self.H), P.GROUND)
        d = ImageDraw.Draw(img)
        scr._draw_header(img, d)
        scr._card(d)
        self.title_text(d, (self.ix0, self.title_y), "How it works - " + scenes[scene_i][1],
                        right=self.ix1 - int(110 * s))
        self.text(d, (self.ix1, self.title_y + int(6 * s)),
                  "%d of %d" % (scene_i + 1, len(scenes)), scr.f_small, P.MUTED, "ra")
        # the tabs: where this one sits among the rest
        x = self.ix0
        ty = self.tabs_y + int(4 * s)
        for i, sc in enumerate(scenes):
            on = i == scene_i
            f = scr.f_bodyb if on else scr.f_small
            tw = d.textlength(short[sc[0]], font=f)
            self.text(d, (x, ty + int(12 * s)), short[sc[0]], f, P.INK if on else P.MUTED, "lm")
            if on:
                d.rectangle([x, ty + int(28 * s), x + tw, ty + int(31 * s)], fill=P.ACCENT)
            x += tw + int(30 * s)
        d.line([self.ix0, ty + int(31 * s), self.ix1, ty + int(31 * s)], fill=P.LINE, width=1)
        self.rr(d, self.panel, fill=P.PAPER, outline=P.LINE, width=max(1, int(2 * s)))
        return img, d

    # ---- primitives --------------------------------------------------
    def rr(self, d, box, fill=None, outline=None, width=1, r=None):
        r = int(6 * self.s) if r is None else r
        x0, y0, x1, y1 = box
        if x1 - x0 < 2 or y1 - y0 < 2:
            return
        d.rounded_rectangle([x0, y0, x1, y1], min(r, (x1 - x0) // 2, (y1 - y0) // 2),
                            fill=fill, outline=outline, width=width)

    def text(self, d, xy, t, f, fill, anchor="la"):
        """Text through a cache of rendered masks. FreeType rasterising was
        three quarters of every frame, and nearly all of it is the same words
        frame after frame; pasting a stored mask costs almost nothing."""
        if not t:
            return
        im = getattr(d, "_image", None)
        key = (t, id(f), anchor)
        m = self._tc.get(key)
        if m is None:
            from PIL import Image, ImageDraw
            try:
                bb = f.getbbox(t, anchor=anchor)
            except Exception:          # a bitmap fallback font knows no anchors
                bb = None
            if bb is None or im is None:
                d.text(xy, t, font=f, fill=fill, anchor=anchor)
                return
            mask = Image.new("L", (max(1, bb[2] - bb[0]), max(1, bb[3] - bb[1])), 0)
            ImageDraw.Draw(mask).text((-bb[0], -bb[1]), t, font=f, fill=255, anchor=anchor)
            if len(self._tc) > 3000:
                self._tc.clear()
            m = self._tc[key] = (mask, bb[0], bb[1])
        mask, ox, oy = m
        x, y = int(round(xy[0] + ox)), int(round(xy[1] + oy))
        im.paste(fill, (x, y, x + mask.size[0], y + mask.size[1]), mask)

    @staticmethod
    def along(pts, u):
        """Point at fraction u along a polyline."""
        u = clamp(u)
        lens = [math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:])]
        tot = sum(lens) or 1
        want = u * tot
        for (a, b), L in zip(zip(pts, pts[1:]), lens):
            if want <= L or L == 0:
                k = want / L if L else 0
                return (a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k)
            want -= L
        return pts[-1]

    def dot(self, d, xy, r, fill):
        x, y = xy
        d.ellipse([x - r, y - r, x + r, y + r], fill=fill)

    def wrap(self, d, text, f, width, maxlines=3):
        words, lines, cur = text.split(), [], ""
        for w in words:
            t = (cur + " " + w).strip()
            if d.textlength(t, font=f) <= width or not cur:
                cur = t
            else:
                lines.append(cur); cur = w
        if cur:
            lines.append(cur)
        if len(lines) > maxlines:
            lines = lines[:maxlines]
            lines[-1] = lines[-1].rstrip(".,") + "..."
        return lines

    # ---- labels and highlights ------------------------------------
    def glow(self, d, box, col=None, w=None):
        x0, y0, x1, y1 = box
        g = int(3 * self.s)
        self.rr(d, (x0 - g, y0 - g, x1 + g, y1 + g), outline=col or self.P.ACCENT,
                width=w or max(2, int(3 * self.s)))

    def chip_label(self, d, box, text, col=None, above=False):
        s = self.s
        x = (box[0] + box[2]) // 2
        y = box[1] - int(5 * s) if above else box[3] + int(5 * s)
        self.text(d, (x, y), text, self.scr.f_tiny, col or self.P.ACCENT, "md" if above else "ma")

    def _skin(self):
        """ui.py's active skin (the 1.20 anime themes), or (None, None).
        The module is found through the screen object: on the image ui.py is
        the program, "__main__", and a lookup of "ui" by name found nothing -
        the checks import it as "ui", so only the VM showed the plain title."""
        U = sys.modules.get(type(self.scr).__module__)
        sk = getattr(U, "SKIN", None) if U is not None else None
        return (U, sk) if sk else (None, None)

    def title_text(self, d, xy, text, right=None):
        """The screen title: in a skinned theme, in that skin's own face and
        with the rule its card titles carry, running to `right`."""
        U, sk = self._skin()
        if sk:
            # through the cached text path: this is drawn every frame
            f, caps = U.skins.anim_title_style(self.scr, U)
            t = text.upper() if caps else text
            self.text(d, xy, t, f, self.P.INK)
            if right is not None:
                U.skins.anim_title_rule(self.scr, U, d, f, xy, t, right)
            return
        self.text(d, xy, text, self.scr.f_h, self.P.INK)

    def live_tag(self, d, xy, text="LIVE"):
        U, sk = self._skin()
        if sk:
            return U.skins.anim_tag(self.scr, U, d, xy, text)
        self.tag(d, xy, text, bg=self.P.ACCENT)

    def tag(self, d, xy, text, fg=None, bg=None, f=None):
        """A small filled label, for callouts on the diagram."""
        P, s = self.P, self.s
        f = f or self.scr.f_tiny
        tw = d.textlength(text, font=f)
        x, y = xy
        box = (int(x - tw / 2 - 6 * s), int(y - 11 * s), int(x + tw / 2 + 6 * s), int(y + 11 * s))
        self.rr(d, box, fill=bg or P.ACCENT, r=int(5 * s))
        self.text(d, (x, y), text, f, fg or P.PAPER, "mm")

    # ---- robots ---------------------------------------------------
    # A scene's workers. Each is drawn last, on top of everything, so a
    # robot is never hidden behind what it carries.
    def draw_bots(self, d, t):
        P, h, w = self.P, self.bh, self.bw
        body = mix(P.INK, P.PAPER, 0.20)
        lw = max(1, int(h * 0.07))
        for (x, yb), held, p, busy, mood in self.bots:
            bob = 0 if busy else math.sin(t * 2.2 + p * 1.7) * h * 0.025
            # wheels, turning while it drives
            r = h * 0.10
            for dx in (-0.27 * w, 0.27 * w):
                cx, cy = x + dx, yb - r
                d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=P.INK)
                a = t * 9 if busy else 0.6
                d.line([cx, cy, cx + math.cos(a) * r * 0.8, cy + math.sin(a) * r * 0.8],
                       fill=P.PAPER, width=1)
            # body, with a chest light that blinks while it works
            self.rr(d, (x - w / 2, yb - h * 0.52, x + w / 2, yb - h * 0.17), fill=body,
                    r=max(2, int(h * 0.08)))
            on = busy and int(t * 5 + p) % 2 == 0
            self.dot(d, (x, yb - h * 0.345), max(1.5, h * 0.05), P.ACCENT if on else P.MUTED)
            # head
            hy0, hy1 = yb - h * 0.88 + bob, yb - h * 0.56 + bob
            d.line([x, hy1, x, yb - h * 0.52], fill=body, width=lw)
            self.rr(d, (x - w * 0.42, hy0, x + w * 0.42, hy1), fill=body, r=max(2, int(h * 0.08)))
            ey = (hy0 + hy1) / 2
            blink = hrand(int(t * 3), p) < 0.08 or mood == "sleep"
            for ex in (x - w * 0.17, x + w * 0.17):
                if blink:
                    d.line([ex - h * 0.05, ey, ex + h * 0.05, ey], fill=P.PASS_, width=lw)
                elif mood == "happy":
                    d.arc([ex - h * 0.06, ey - h * 0.05, ex + h * 0.06, ey + h * 0.06], 200, 340,
                          fill=P.PASS_, width=lw)
                else:
                    self.dot(d, (ex, ey), max(1.5, h * 0.055), P.PASS_)
            d.line([x, hy0, x, hy0 - h * 0.12], fill=body, width=lw)
            self.dot(d, (x, hy0 - h * 0.12), max(1.5, h * 0.05), P.ACCENT if busy else P.MUTED)
            # arms: the right one holds the box out in front
            sx, sy = x + w / 2, yb - h * 0.42
            d.line([x - w / 2, sy, x - w / 2 - w * 0.12, yb - h * 0.24], fill=body, width=lw)
            if held:
                hx, hy = x + w / 2 + self.arm, yb - h * 0.35
                d.line([sx, sy, hx - self.box / 2, hy], fill=body, width=lw)
                bs = self.box / 2
                d.rectangle([hx - bs, hy - bs, hx + bs, hy + bs], fill=held, outline=P.INK)
                d.line([hx - bs, hy - bs * 0.3, hx + bs, hy - bs * 0.3], fill=P.INK)   # tape
            else:
                d.line([sx, sy, sx + w * 0.12, yb - h * 0.24], fill=body, width=lw)
            if mood == "sleep":
                z = (t * 0.8 + p * 0.3) % 1.0
                self.text(d, (x + w * 0.4 + z * w * 0.5, hy0 - z * h * 0.45), "z",
                          self.scr.f_bodyb, mix(P.MUTED, P.PAPER, z * 0.5), "ld")
            if mood == "shrug":
                self.text(d, (x, hy0 - h * 0.2), "?", self.scr.f_noteb, P.MUTED, "md")
        self.bots = []

    # ---- the address strip ------------------------------------------
    def strip_frame(self, d, left, right, title):
        P, s = self.P, self.s
        x0, y0, x1, y1 = self.strip_box
        self.text(d, (x0, y0), title, self.scr.f_tiny, P.MUTED)
        by0, by1 = y0 + int(20 * s), y1 - int(10 * s)
        self.rr(d, (x0, by0, x1, by1), fill=P.PAPER, outline=P.MUTED, r=int(4 * s))
        self.text(d, (x0, by1 + int(1 * s)), left, self.scr.f_tiny, P.MUTED, "la")
        self.text(d, (x1, by1 + int(1 * s)), right, self.scr.f_tiny, P.MUTED, "ra")
        return x0, by0, x1, by1

    def strip_fill(self, d, a, b, col):
        x0, by0, x1, by1 = self._sb
        m = max(1, int(2 * self.s))
        xa, xb = lerp(x0, x1, clamp(a)), lerp(x0, x1, clamp(b))
        if xb - xa > 2 * m + 1:
            d.rectangle([int(xa) + m, by0 + m, int(xb) - m, by1 - m], fill=col)

    def strip_cursor(self, d, u, col=None):
        x0, by0, x1, by1 = self._sb
        x = int(lerp(x0, x1, clamp(u)))
        d.line([x, by0 - int(4 * self.s), x, by1 + int(4 * self.s)], fill=col or self.P.ACCENT,
               width=max(2, int(3 * self.s)))
        return x

    def addr_strip(self, d, left, right, title):
        self._sb = self.strip_frame(d, left, right, title)

    # ---- the side panel ---------------------------------------------
    def panel_title(self, d, text, note="illustration - not this drive"):
        P, s = self.P, self.s
        x0, y0, x1, y1 = self.panel
        self.text(d, (x0 + int(14 * s), y0 + int(12 * s)), text, self.scr.f_noteb, P.INK)
        if note:
            self.text(d, (x0 + int(14 * s), y1 - int(10 * s)), note, self.scr.f_tiny, P.MUTED, "ld")
        return x0 + int(14 * s), y0 + int(42 * s), x1 - int(14 * s), y1 - int(34 * s)

    def kv(self, d, x0, x1, y, k, v, tone=None, f=None):
        P = self.P
        self.text(d, (x0, y), k, self.scr.f_small, P.MUTED)
        self.text(d, (x1, y), v, f or self.scr.f_bodyb, tone or P.INK, "ra")

    def badge(self, d, x, y, word, tone):
        P, s = self.P, self.s
        f = self.scr.f_bodyb
        tw = d.textlength(word, font=f)
        self.rr(d, (x, y, x + int(tw + 28 * s), y + int(34 * s)), fill=tone, r=int(8 * s))
        self.text(d, (x + int(14 * s), y + int(17 * s)), word, f, P.PAPER, "lm")
        return x + int(tw + 28 * s)

    # ---- caption ----------------------------------------------------
    def caption(self, d, text, step, nsteps, u, paused):
        P, s, scr = self.P, self.s, self.scr
        x0, x1 = self.ix0, self.ix1
        y = self.cap_top
        d.line([x0, y - int(4 * s), x1, y - int(4 * s)], fill=P.LINE)
        # step dots, then the line for this step's progress
        dx = x0
        for i in range(nsteps):
            r = int(5 * s)
            cy = y + int(12 * s)
            if i < step:
                self.dot(d, (dx + r, cy), r, P.MUTED)
            elif i == step:
                self.dot(d, (dx + r, cy), r, P.ACCENT)
            else:
                d.ellipse([dx, cy - r, dx + 2 * r, cy + r], outline=P.MUTED)
            dx += 3 * r + int(4 * s)
        lx0 = dx + int(10 * s)
        lx1 = lx0 + int(160 * s)
        cy = y + int(12 * s)
        d.line([lx0, cy, lx1, cy], fill=P.LINE, width=max(2, int(3 * s)))
        d.line([lx0, cy, int(lerp(lx0, lx1, u)), cy], fill=P.ACCENT, width=max(2, int(3 * s)))
        self.text(d, (lx1 + int(14 * s), cy), "step %d of %d" % (step + 1, nsteps),
                  scr.f_tiny, P.MUTED, "lm")
        if paused:
            self.tag(d, (x1 - int(46 * s), cy), "PAUSED", bg=P.WARN_)
        ty = y + int(28 * s)
        for i, line in enumerate(self.wrap(d, text, self.f_cap, x1 - x0)):
            self.text(d, (x0, ty + i * self.cap_lh), line, self.f_cap, P.INK)


class Stage(Canvas):
    """The SSD: the laptop, the PCIe bus and the drive's board, with the
    robots that are its flash channels."""

    def __init__(self, scr, pal):
        Canvas.__init__(self, scr, pal)
        self.dramless = True        # the scenes' example drive; Live sets the real one
        s = self.s
        dx0, dy0, dx1, dy1 = self.area
        dw = dx1 - dx0

        # host | bus | board
        hx1 = dx0 + int(dw * 0.17)
        self.host = (dx0, dy0 + int(24 * s), hx1, dy1 - int(8 * s))
        bx0 = hx1 + int(dw * 0.085)
        self.board = (bx0, dy0, dx1, dy1)
        bx1 = dx1
        bh = dy1 - dy0
        self.bus_x = (hx1, bx0 + int(34 * s))
        midy = (dy0 + dy1) // 2
        lane_gap = int(9 * s)
        self.lanes = [midy - int(1.5 * lane_gap) + i * lane_gap for i in range(4)]

        # controller and its DRAM / HMB chip
        cs = int(min(bh * 0.46, (bx1 - bx0) * 0.25))
        cx0 = bx0 + int(34 * s)
        cy0 = midy - cs // 2 - int(14 * s)
        self.ctrl = (cx0, cy0, cx0 + cs, cy0 + cs)
        dh = int(cs * 0.24)
        self.dram = (cx0 + int(cs * 0.12), cy0 + cs + int(12 * s),
                     cx0 + cs - int(cs * 0.12), cy0 + cs + int(12 * s) + dh)
        ci = int(8 * s)
        inner_w = cs - 2 * ci
        top = cy0 + int(cs * 0.20)
        hq = int(cs * 0.30); hm = int(cs * 0.20); he = int(cs * 0.20); g = int(cs * 0.03)
        self.c_queue = (cx0 + ci, top, cx0 + ci + inner_w, top + hq)
        self.c_map = (cx0 + ci, top + hq + g, cx0 + ci + inner_w, top + hq + g + hm)
        self.c_ecc = (cx0 + ci, top + hq + 2 * g + hm, cx0 + ci + inner_w, top + hq + 2 * g + hm + he)

        # flash packages, 2 x 2
        nx0 = self.ctrl[2] + int((bx1 - bx0) * 0.12)
        nx1 = bx1 - int(16 * s)
        ny0 = dy0 + int(30 * s)
        ny1 = dy1 - int(14 * s)
        gx = int(16 * s); gy = int(14 * s)
        pw = (nx1 - nx0 - gx) // 2
        ph = (ny1 - ny0 - gy) // 2
        self.pkgs = []
        for i in range(PKGS):
            px = nx0 + (i % 2) * (pw + gx)
            py = ny0 + (i // 2) * (ph + gy)
            self.pkgs.append((px, py, px + pw, py + ph))
        lab = int(20 * s)
        self.cells = {}
        for p, (px0, py0, px1, py1) in enumerate(self.pkgs):
            gx0, gy0 = px0 + int(7 * s), py0 + lab
            gw, gh = px1 - int(7 * s) - gx0, py1 - int(7 * s) - gy0
            cw, ch = gw / COLS, gh / ROWS
            m = max(1, int(2 * s))
            for r in range(ROWS):
                for c in range(COLS):
                    self.cells[(p, r, c)] = (int(gx0 + c * cw) + m, int(gy0 + r * ch) + m,
                                             int(gx0 + (c + 1) * cw) - m, int(gy0 + (r + 1) * ch) - m)
        # One trace per channel, controller -> package. The left column is
        # reached directly; the right column through the corridor between the
        # rows and the gap between the columns, so no trace crosses a package.
        pk = self.pkgs
        sx = self.ctrl[2]
        cor = (pk[0][3] + pk[2][1]) // 2
        gapx = (pk[0][2] + pk[1][0]) // 2
        o = max(2, int(3 * s))
        span = pk[0][0] - sx
        order = {0: 0.30, 1: 0.45, 3: 0.60, 2: 0.75}      # where each leaves the chip
        trunk = {0: 0.62, 1: 0.30, 3: 0.40, 2: 0.62}      # where each turns
        self.traces = [None] * PKGS
        for p in range(PKGS):
            sy = self.ctrl[1] + int(cs * order[p])
            kx = sx + int(span * trunk[p])
            ty = (pk[p][1] + pk[p][3]) // 2
            if p in (0, 2):
                self.traces[p] = [(sx, sy), (kx, sy), (kx, ty), (pk[p][0], ty)]
            else:
                cy = cor - o if p == 1 else cor + o
                gx = gapx - o if p == 1 else gapx + o
                self.traces[p] = [(sx, sy), (kx, sy), (kx, cy), (gx, cy), (gx, ty), (pk[p][0], ty)]
        self._bot_geometry()

    # ---- the static picture -----------------------------------------
    def background(self, scene_i, labels):
        """Header, card, title, tabs, host, board outline, chips, traces.
        Rebuilt when the scene changes and every 20 s, for the header clock."""
        key = (scene_i, labels)
        img = self.cached(key)
        if img is not None:
            return img
        img, d = self.chrome(SCENES, SHORT, scene_i)
        P, s, scr = self.P, self.s, self.scr
        name, title, prog, beats = SCENES[scene_i]

        # host
        hx0, hy0, hx1, hy1 = self.host
        self.rr(d, self.host, fill=P.PAPER, outline=P.MUTED, width=max(1, int(2 * s)))
        self.text(d, ((hx0 + hx1) // 2, hy0 - int(6 * s)), "THIS LAPTOP", scr.f_note, P.MUTED, "md")
        hh = hy1 - hy0
        self.h_cpu = (hx0 + int(8 * s), hy0 + int(hh * 0.10), hx1 - int(8 * s), hy0 + int(hh * 0.40))
        self.h_ram = (hx0 + int(8 * s), hy0 + int(hh * 0.52), hx1 - int(8 * s), hy0 + int(hh * 0.90))
        self.rr(d, self.h_cpu, fill=P.CHIP, outline=P.LINE)
        self.text(d, ((self.h_cpu[0] + self.h_cpu[2]) // 2, self.h_cpu[1] + int(6 * s)),
                  "CPU", scr.f_tiny, P.MUTED, "ma")
        self.text(d, ((self.h_cpu[0] + self.h_cpu[2]) // 2, (self.h_cpu[1] + self.h_cpu[3]) // 2 + int(8 * s)),
                  prog, scr.f_noteb, P.INK, "mm")
        self.rr(d, self.h_ram, fill=P.CHIP, outline=P.LINE)
        self.text(d, ((self.h_ram[0] + self.h_ram[2]) // 2, self.h_ram[1] + int(6 * s)),
                  "RAM", scr.f_tiny, P.MUTED, "ma")

        # bus
        bx0, bx1 = self.bus_x
        for y in self.lanes:
            d.line([bx0, y, bx1, y], fill=P.LINE, width=max(2, int(3 * s)))
        self.text(d, ((hx1 + self.board[0]) // 2, self.lanes[0] - int(10 * s)), "PCIe", scr.f_note, P.MUTED, "md")

        # board, connector fingers, chips
        b = self.board
        self.rr(d, b, fill=P.BOARD, outline=P.MUTED, width=max(1, int(2 * s)), r=int(10 * s))
        fx = b[0] + int(4 * s)
        for i in range(10):
            fy = self.lanes[0] - int(30 * s) + i * int(9 * s)
            if self.lanes[-1] + int(40 * s) > fy:
                d.rectangle([fx, fy, fx + int(10 * s), fy + int(5 * s)], fill=P.GOLD)
        self.text(d, (b[0] + int(30 * s), b[1] + int(8 * s)), "SSD  (M.2 NVMe)", scr.f_noteb, P.INK)

        for tr in self.traces:
            d.line(tr, fill=P.LINE, width=max(2, int(3 * s)), joint="curve")

        c = self.ctrl
        self.rr(d, c, fill=P.CHIP, outline=P.INK, width=max(1, int(2 * s)))
        self.text(d, ((c[0] + c[2]) // 2, c[1] + int(7 * s)), "CONTROLLER", scr.f_noteb, P.INK, "ma")
        for box, lab in zip((self.c_queue, self.c_map, self.c_ecc), labels):
            self.rr(d, box, fill=P.PAPER, outline=P.LINE)
            self.text(d, (box[0] + int(5 * s), box[1] + int(3 * s)), lab, scr.f_tiny, P.MUTED)
        self.rr(d, self.dram, fill=P.CHIP, outline=P.MUTED)
        self.text(d, ((self.dram[0] + self.dram[2]) // 2, (self.dram[1] + self.dram[3]) // 2),
                  "DRAM / HMB", scr.f_tiny, P.MUTED, "mm")

        for p, box in enumerate(self.pkgs):
            self.rr(d, box, fill=P.CHIP, outline=P.MUTED)
            self.text(d, (box[0] + int(7 * s), box[1] + int(3 * s)),
                      "NAND  ch %d" % p, scr.f_tiny, P.MUTED)

        # what the robots are, on every scene
        self.text(d, (self.strip_box[2], self.strip_box[1]), "robot = one flash channel of the controller",
                  scr.f_tiny, P.MUTED, "ra")
        self._bg[key] = img
        return img

    # ---- moving parts -----------------------------------------------
    def cell(self, d, key, fill, outline=None):
        b = self.cells[key]
        d.rectangle(b, fill=fill, outline=outline)

    def draw_cells(self, d, state):
        """state(p, r, c) -> fill colour (or None for empty)."""
        P = self.P
        for k in self.cells:
            col = state(*k)
            self.cell(d, k, col if col else P.PAPER, P.LINE if not col else None)

    def slc_tint(self, d):
        """Mark the SLC columns faintly so the cache region is always visible."""
        P = self.P
        for p in range(PKGS):
            a = self.cells[(p, 0, 0)]; b = self.cells[(p, ROWS - 1, SLC_COLS - 1)]
            d.rectangle([a[0] - 2, a[1] - 2, b[2] + 2, b[3] + 2], outline=P.SLCD)

    def lane_packet(self, d, u, lane, to_drive=True, filled=True, big=False, label=None):
        """A packet on a bus lane: u 0..1 along the trip."""
        P, s = self.P, self.s
        bx0, bx1 = self.bus_x
        x0, x1 = (self.host[2], self.ctrl[0]) if to_drive else (self.ctrl[0], self.host[2])
        x = lerp(x0, x1, ease(u)) if True else 0
        y = self.lanes[lane % 4]
        w = int((16 if big else 9) * s); h = int((7 if big else 5) * s)
        box = (int(x - w / 2), int(y - h), int(x + w / 2), int(y + h))
        if filled:
            self.rr(d, box, fill=P.ACCENT, r=int(2 * s))
        else:
            self.rr(d, box, fill=P.PAPER, outline=P.ACCENT, width=max(1, int(2 * s)), r=int(2 * s))
        if label:
            # in the gap between laptop and board, where nothing else is drawn
            self.tag(d, ((self.host[2] + self.board[0]) / 2, self.lanes[-1] + int(24 * s)), label,
                     bg=P.ACCENT)

    def lit_lanes(self, d, k):
        """Brightness of the bus: 0 idle .. 1 flat out."""
        P = self.P
        col = mix(P.LINE, P.ACCENT, clamp(k) * 0.55)
        bx0, bx1 = self.bus_x
        for y in self.lanes:
            d.line([bx0, y, bx1, y], fill=col, width=max(2, int(3 * self.s)))

    def trace_pulse(self, d, p, u, r=None):
        r = r or max(2, int(4 * self.s))
        self.dot(d, self.along(self.traces[p], u), r, self.P.ACCENT)

    def trace_lit(self, d, p, k=1.0):
        col = mix(self.P.LINE, self.P.ACCENT, 0.6 * clamp(k))
        d.line(self.traces[p], fill=col, width=max(2, int(3 * self.s)), joint="curve")

    def queue(self, d, depth, busy):
        """Command slots inside the controller."""
        P, s = self.P, self.s
        x0, y0, x1, y1 = self.c_queue
        y0 += int(20 * s)
        cols = min(depth, 8)
        rows = (depth + cols - 1) // cols
        cw = (x1 - x0 - int(8 * s)) / cols
        ch = min((y1 - y0 - int(4 * s)) / max(rows, 1), cw)
        for i in range(depth):
            r, c = divmod(i, cols)
            bx = x0 + int(4 * s) + c * cw
            by = y0 + r * ch
            m = max(1, int(1.5 * s))
            d.rectangle([int(bx) + m, int(by) + m, int(bx + cw) - m, int(by + ch) - m],
                        fill=P.ACCENT if i < busy else P.PAPER, outline=P.LINE)

    def callout(self, d, text, bg=None):
        """The board's caption spot, under the DRAM chip."""
        f = self.scr.f_tiny
        tw = d.textlength(text, font=f)
        x = self.board[0] + int(20 * self.s) + tw / 2
        self.tag(d, (x, self.dram[3] + int(46 * self.s)), text, bg=bg or self.P.INK)

    # ---- the robots -------------------------------------------------
    # One robot per flash channel: the controller's way of getting data onto
    # and off its own chip, drawn as a warehouse robot carrying boxes. A
    # scene books trips with job() / walk() / idle(); they are drawn last, on
    # top of everything, so a robot is never hidden behind what it carries.
    def _bot_geometry(self):
        c = self.cells[(0, 0, 0)]
        cw, ch = c[2] - c[0], c[3] - c[1]
        self.bot_size(max(int(ch * 1.45), int(26 * self.s)), max(5, int(min(cw, ch) * 0.85)))

    def stand(self, key):
        """Where a robot stands to reach a block: just left of it, hand in it."""
        b = self.cells[key]
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        return (cx - self.bw / 2 - self.arm, cy + self.bh * 0.35)

    def dock(self, p):
        """The robot's place at the door of its chip, where the trace arrives."""
        px0, py0, px1, py1 = self.pkgs[p]
        return (px0 - self.bw * 0.15, (py0 + py1) / 2 + self.bh * 0.35)

    def idle(self, p, mood=""):
        self.bots.append((self.dock(p), None, p, False, mood))

    def job(self, p, stops, carry, v):
        """Dock -> each stop in turn -> dock, v 0..1 through the trip.
        carry[i] is the box held on leg i (leg 0 leaves the dock), so
        [None, X] fetches a block (a read) and [X, None] shelves one (a write).
        Returns (done, at): which stops are finished, and the stop being
        worked at right now, so the scene can colour the shelves to match."""
        pts = [self.dock(p)] + [self.stand(k) for k in stops] + [self.dock(p)]
        n = len(stops)
        tl, tp = 0.7 / (n + 1), 0.3 / max(n, 1)
        v = clamp(v)
        done, at = [False] * n, None
        acc = 0.0
        pos, held = pts[-1], carry[-1]
        for i in range(n + 1):
            if v < acc + tl:
                k = ease((v - acc) / tl)
                pos = (lerp(pts[i][0], pts[i + 1][0], k), lerp(pts[i][1], pts[i + 1][1], k))
                held = carry[i]
                break
            acc += tl
            if i < n:
                if v < acc + tp:
                    k = (v - acc) / tp
                    pos, at = pts[i + 1], stops[i]
                    held = carry[i] if k < 0.5 else carry[i + 1]
                    done[i] = k >= 0.5
                    break
                acc += tp
                done[i] = True
        self.bots.append((pos, held, p, v < 1.0, ""))
        return done, at

    def walk(self, p, keys, f):
        """Walk along a row of blocks, f = how many have been passed."""
        f = clamp(f, 0, len(keys) - 1e-6)
        i = int(f); k = f - i
        a = self.stand(keys[i])
        b = self.stand(keys[min(i + 1, len(keys) - 1)])
        hop = ease(seg(k, 0.6, 1.0))
        self.bots.append(((lerp(a[0], b[0], hop), lerp(a[1], b[1], hop)), None, p, True, ""))
        return i


# ---------------------------------------------------------------- scenes
# Each draw(st, d, step, u, t): step index, u = progress 0..1 through it,
# t = seconds since the scene began (for things that keep moving), and st.lt =
# seconds since the step began. Shelves (cells) are drawn by the scene; the
# robots it books are drawn afterwards by frame().

BENCH = [  # profile, read MB/s, IOPS, write MB/s - example figures for a PCIe 3.0 drive
    ("SEQ1M Q8T1", 3412, 3254, 2890),
    ("SEQ1M Q1T1", 1985, 1893, 1720),
    ("RND4K Q32T1", 512, 125000, 410),
    ("RND4K Q1T1", 62, 15100, 160),
]


def used_drive(p, r, c):
    """A drive in use: most blocks hold data, a few are free."""
    return hrand(p, r, c, 21) > 0.18


def seq_cell(p, j, cols=COLS):
    j %= ROWS * cols
    return (p, j % ROWS, j // ROWS)


def rnd_cell(p, *k):
    return (p, int(hrand(p, 31, *k) * ROWS), int(hrand(p, 32, *k) * COLS))


def scene_bench(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    lt = st.lt
    st.addr_strip(d, "LBA 0", "end of the drive", "Addresses the host sees")
    st.strip_fill(d, 0, 0.12 if step else 0.12 * ease(u), P.SOFT)
    x = st.strip_cursor(d, 0.12, P.MUTED)
    st.text(d, (x + int(6 * s), st._sb[1] + int(2 * s)), "test region", scr.f_tiny, P.MUTED)

    lit = {k: P.DATA for k in st.cells if used_drive(*k)}
    if step == 0:
        # direct I/O: the page cache in RAM is stepped round
        r = st.h_ram
        k = ease(seg(u, 0.2, 0.6))
        st.text(d, ((r[0] + r[2]) // 2, (r[1] + r[3]) // 2 + int(6 * s)), "page cache",
                scr.f_tiny, P.MUTED, "mm")
        if k > 0:
            d.line([r[0] + int(6 * s), r[3] - int(6 * s),
                    int(lerp(r[0] + 6 * s, r[2] - 6 * s, k)), int(lerp(r[3] - 6 * s, r[1] + 6 * s, k))],
                   fill=P.FAIL_, width=max(2, int(3 * s)))
        if u > 0.6:
            st.chip_label(d, r, "bypassed", P.FAIL_)
        st.queue(d, 8, 0)
        for p in range(PKGS):
            st.idle(p)
    elif step in (1, 2):
        # sequential: one 1 MiB request is striped over all four channels, so
        # all four robots fetch the same shelf position together
        per = 1.0
        if step == 1:
            v, busy = (lt / per) % 1.0, True
            jobn = int(lt / per)
        else:
            cyc = 1.7
            ph = lt % cyc
            v, busy = ph / per, ph < per
            jobn = int(lt / cyc)
            if not busy:
                st.lane_packet(d, (ph - per) / (cyc - per), 0, True, False, label="next request")
        st.queue(d, 8 if step == 1 else 1, (8 if step == 1 else 1) if busy else 0)
        for p in range(PKGS):
            if busy:
                key = seq_cell(p, jobn)
                done, at = st.job(p, [key], [None, P.ACCENT], v)
                if at:
                    lit[key] = P.ACCENT
                if v > 0.8:
                    st.trace_lit(d, p); st.trace_pulse(d, p, 1 - seg(v, 0.8, 1.0))
            else:
                st.idle(p)
        if busy:
            for i in range(4):
                st.lane_packet(d, ((t * 1.4) + i / 4) % 1, i, False, True, big=True)
        st.lit_lanes(d, 1.0 if busy else 0.15)
    elif step == 3:
        st.queue(d, 32, 32 if int(t * 6) % 7 else 29)
        st.glow(d, st.c_map)
        per = 0.75
        for p in range(PKGS):
            f = lt / per + p * 0.23
            key = rnd_cell(p, int(f))
            done, at = st.job(p, [key], [None, P.ACCENT], f % 1.0)
            if at:
                lit[key] = P.ACCENT
            st.trace_lit(d, p, 0.7)
            if f % 1.0 > 0.8:
                st.trace_pulse(d, p, 1 - seg(f % 1.0, 0.8, 1.0))
        for i in range(8):
            st.lane_packet(d, ((t * 1.7) + i / 8) % 1, i, i % 2 == 0, i % 2 == 1)
        st.lit_lanes(d, 0.7)
    elif step == 4:
        st.queue(d, 1, 1)
        trip = 3.0
        k = int(lt / trip)
        v = (lt % trip) / trip
        p = int(hrand(k, 1) * PKGS)
        key = rnd_cell(p, k, 4)
        for q in range(PKGS):
            if q != p:
                st.idle(q)
        if v < 0.15:
            st.lane_packet(d, v / 0.15, 1, True, False, label="4 KiB read")
            stage = "1  request arrives"; st.idle(p)
        elif v < 0.28:
            st.glow(d, st.c_map); stage = "2  FTL map: which chip?"; st.idle(p)
        elif v < 0.38:
            st.trace_lit(d, p); st.trace_pulse(d, p, seg(v, 0.28, 0.38))
            stage = "3  to the channel's robot"; st.idle(p)
        elif v < 0.70:
            w = seg(v, 0.38, 0.70)
            done, at = st.job(p, [key], [None, P.ACCENT], w)
            if at:
                lit[key] = P.ACCENT
            stage = "4  flash read ~60 us"
        elif v < 0.84:
            st.idle(p)
            st.trace_lit(d, p); st.trace_pulse(d, p, 1 - seg(v, 0.70, 0.84))
            st.glow(d, st.c_ecc); stage = "5  ECC check"
        else:
            st.idle(p)
            st.lane_packet(d, seg(v, 0.84, 1.0), 1, False, True, label="data")
            stage = "6  back to the host"
        st.callout(d, stage, P.INK)
    elif step == 5:
        # writing: the robots shelve boxes into the SLC cache, kept free for this
        st.queue(d, 8, 8)
        per = 0.95
        jobn = int(lt / per)
        v = (lt / per) % 1.0
        for k in st.cells:
            if k[2] < SLC_COLS:
                lit.pop(k, None)
        for p in range(PKGS):
            key = seq_cell(p, jobn, SLC_COLS)
            done, at = st.job(p, [key], [P.ACCENT, None], v)
            for j in range(min(jobn, ROWS * SLC_COLS)):
                lit[seq_cell(p, j, SLC_COLS)] = P.SLCD
            if done[0]:
                lit[key] = P.SLCD
            if v < 0.2:
                st.trace_lit(d, p); st.trace_pulse(d, p, seg(v, 0.0, 0.2))
        for i in range(4):
            st.lane_packet(d, ((t * 1.4) + i / 4) % 1, i, True, True, big=True)
        st.lit_lanes(d, 1.0)
        st.text(d, (st.pkgs[0][0], st.pkgs[0][1] - int(6 * s)), "SLC cache (fast, 1 bit per cell)",
                scr.f_tiny, P.WARN_, "ld")
    else:   # step 6: verdict
        st.queue(d, 8, 0)
        st.glow(d, st.board, P.PASS_)
        st.chip_label(d, st.board, "still on the bus - %d C" % (41 + int(u * 3)), P.PASS_, above=False)
        for p in range(PKGS):
            st.idle(p, "happy")

    st.draw_cells(d, lambda p, r, c: lit.get((p, r, c)))
    if step >= 5:
        st.slc_tint(d)

    # panel: the result table filling in
    x0, y0, x1, y1 = st.panel_title(d, "RESULTS TABLE")
    cw = (x1 - x0)
    cols_x = [x0, x0 + int(cw * 0.64), x1]
    st.text(d, (cols_x[0], y0), "Profile", scr.f_tiny, P.MUTED)
    st.text(d, (cols_x[1], y0), "MB/s", scr.f_tiny, P.MUTED, "ra")
    st.text(d, (cols_x[2], y0), "IOPS", scr.f_tiny, P.MUTED, "ra")
    rh = int(36 * s)
    for i, (name, mb, iops, wmb) in enumerate(BENCH):
        y = y0 + int(24 * s) + i * rh
        active = step == i + 1
        if active:
            st.rr(d, (x0 - int(6 * s), y - int(4 * s), x1 + int(6 * s), y + rh - int(6 * s)), fill=P.SOFT)
        if step > i + 1 or active:
            k = 1.0 if step > i + 1 else ease(seg(u, 0.15, 0.85))
            mbs, ios = thousands(mb * k), thousands(iops * k)
        else:
            mbs = ios = "-"
        st.text(d, (cols_x[0], y), name, scr.f_tiny, P.INK)
        st.text(d, (cols_x[1], y), mbs, scr.f_noteb, P.INK, "ra")
        st.text(d, (cols_x[2], y), ios, scr.f_noteb, P.INK, "ra")
        if step >= 5:
            wk = 1.0 if step > 5 else ease(u)
            st.text(d, (cols_x[1], y + int(16 * s)), "write " + thousands(wmb * wk), scr.f_tiny,
                    P.WARN_, "ra")
    if step == 6 and u > 0.3:
        st.badge(d, x0, y0 + int(24 * s) + 4 * rh + int(10 * s), "PASS", P.PASS_)


INSTALL_GB = 48.0
CACHE_GB = 20.0


def install_speed(gb):
    """The curve every consumer SSD draws: flat in the cache, then the cliff."""
    n = (hrand(int(gb * 4)) - 0.5)
    if gb < CACHE_GB:
        return 1750 + 90 * n
    if gb < CACHE_GB + 1.5:
        return lerp(1750, 430, (gb - CACHE_GB) / 1.5) + 60 * n
    return 430 + 110 * n


def scene_install(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    lt = st.lt
    # how far the write has got, GB
    g = [0, lerp(0, 16, ease(u)), lerp(16, 19, u), lerp(19, INSTALL_GB, ease(u)),
         INSTALL_GB, INSTALL_GB][step]
    chunk = int(g * 4)                                    # 256 MB steps
    writing = 0 < step < 4 or (step == 0 and u > 0.6)
    verify = clamp(u * 1.05) if step == 4 else (1.0 if step > 4 else 0.0)

    # the RAM: the random buffer, and (DRAM-less drives) the drive's own map
    r = st.h_ram
    st.text(d, ((r[0] + r[2]) // 2, r[1] + int(26 * s)), "random", scr.f_tiny, P.INK, "ma")
    st.text(d, ((r[0] + r[2]) // 2, r[1] + int(42 * s)), "256 MB", scr.f_tiny, P.INK, "ma")
    if step == 3 and st.dramless:
        hm = (r[0] + int(4 * s), r[3] - int(22 * s), r[2] - int(4 * s), r[3] - int(4 * s))
        k = seg(u, 0.35, 0.5)
        if k > 0:
            st.rr(d, hm, fill=mix(P.PAPER, P.WARN_, 0.35 * k))
            st.text(d, ((hm[0] + hm[2]) // 2, (hm[1] + hm[3]) // 2), "HMB", scr.f_tiny, P.INK, "mm")
            st.glow(d, st.dram, P.WARN_)
            if u > 0.5:
                st.chip_label(d, st.dram, "no DRAM? map lives in laptop RAM", P.WARN_)

    # the shelves: SLC fills, then is emptied into TLC while new boxes arrive
    slc_per = SLC_COLS * ROWS
    tlc_per = (COLS - SLC_COLS - 1) * ROWS                 # the last column stays free
    lit = {}
    if g <= CACHE_GB:
        slc_n = [int(slc_per * PKGS * g / CACHE_GB + (PKGS - 1 - p)) // PKGS for p in range(PKGS)]
        tlc_n = [0] * PKGS
    else:
        over = (g - CACHE_GB) / (INSTALL_GB - CACHE_GB)
        tlc_n = [min(tlc_per, int(tlc_per * over * 1.05)) for p in range(PKGS)]
        slc_n = [slc_per - int(slc_per * 0.45 * (0.5 + 0.5 * math.sin(t * 2.5 + p))) for p in range(PKGS)]
    for p in range(PKGS):
        for j in range(slc_n[p]):
            lit[seq_cell(p, j, SLC_COLS)] = P.SLCD
        for j in range(tlc_n[p]):
            q, rr_, c = seq_cell(p, j, COLS - SLC_COLS - 1)
            lit[(q, rr_, c + SLC_COLS)] = P.DATA

    for p in range(PKGS):
        if writing and g < CACHE_GB:
            per = 0.6
            f = lt / per + p * 0.25
            key = seq_cell(p, min(slc_n[p], slc_per - 1), SLC_COLS)
            done, at = st.job(p, [key], [P.ACCENT, None], f % 1.0)
            if done[0]:
                lit[key] = P.SLCD
            if f % 1.0 < 0.2:
                st.trace_lit(d, p); st.trace_pulse(d, p, seg(f % 1.0, 0, 0.2))
        elif writing:
            # past the cache: most trips now move an old box out of SLC into
            # TLC - that work, not the host, is what the robots are busy with
            per = 1.5
            f = lt / per + p * 0.31
            n = int(f)
            if n % 3:
                a = seq_cell(p, int(hrand(p, n) * slc_per), SLC_COLS)
                j = min(tlc_n[p], tlc_per - 1)
                q, rr_, c = seq_cell(p, j, COLS - SLC_COLS - 1)
                b = (q, rr_, c + SLC_COLS)
                done, at = st.job(p, [a, b], [None, P.SLCD, None], f % 1.0)
                if done[0]:
                    lit.pop(a, None)
                if done[1]:
                    lit[b] = P.DATA
            else:
                key = seq_cell(p, int(hrand(p, n, 2) * slc_per), SLC_COLS)
                done, at = st.job(p, [key], [P.ACCENT, None], f % 1.0)
                if done[0]:
                    lit[key] = P.SLCD
                if f % 1.0 < 0.2:
                    st.trace_lit(d, p); st.trace_pulse(d, p, seg(f % 1.0, 0, 0.2))
        elif step == 4:
            # read-back: every box is fetched again and its serial checked
            order = [k for k in sorted(lit, key=lambda k: (k[2], k[1])) if k[0] == p]
            per = 0.7
            f = lt / per + p * 0.2
            n = int(f)
            for k in order[:n]:
                lit[k] = P.OKT
            if order and n < len(order):
                key = order[n]
                done, at = st.job(p, [key], [None, lit.get(key, P.DATA)], f % 1.0)
                if at:
                    lit[key] = P.ACCENT
                if done[0]:
                    lit[key] = P.OKT
            else:
                st.idle(p, "happy")
        else:
            st.idle(p, "happy" if step == 5 else "")
    if step >= 3 and g > CACHE_GB and step < 4:
        st.callout(d, "robots busy moving SLC -> TLC", P.WARN_)

    st.draw_cells(d, lambda p, r_, c: lit.get((p, r_, c)))
    st.slc_tint(d)
    st.text(d, (st.pkgs[0][0], st.pkgs[0][1] - int(6 * s)), "SLC", scr.f_tiny, P.WARN_, "ld")
    st.text(d, (st.cells[(0, 0, SLC_COLS)][0], st.pkgs[0][1] - int(6 * s)), "TLC (3 bits per cell)",
            scr.f_tiny, P.MUTED, "ld")

    # the bus
    if writing:
        fast = g < CACHE_GB
        for i in range(4 if fast else 1):
            st.lane_packet(d, ((t * (1.6 if fast else 0.5)) + i / 4) % 1, i, True, True, big=True)
        st.lit_lanes(d, 1.0 if fast else 0.3)
    elif step == 4:
        for i in range(3):
            st.lane_packet(d, ((t * 1.5) + i / 3) % 1, i, False, True, big=True)
        st.lit_lanes(d, 0.8)
    st.queue(d, 1, 1 if writing or step == 4 else 0)

    # the address strip: the 48 GB written, chunk by chunk
    st.addr_strip(d, "0", "48 GB", "Addresses written - 256 MB steps")
    st.strip_fill(d, 0, g / INSTALL_GB, P.DATA)
    x = st._sb[0]
    if step >= 4:
        st.strip_fill(d, 0, verify, P.OKT)
        x = st.strip_cursor(d, verify, P.PASS_)
    elif g > 0:
        x = st.strip_cursor(d, g / INSTALL_GB)
    if step in (2, 4) or (step == 1 and u > 0.5):
        n = chunk if step != 4 else int(verify * INSTALL_GB * 4)
        txt = "#%04d" % n if step != 4 else "asked #%04d  got #%04d" % (n, n)
        st.tag(d, (clamp(x, st._sb[0] + 60 * s, st._sb[2] - 90 * s), st._sb[1] - int(14 * s)), txt,
               bg=P.PASS_ if step == 4 else P.INK, f=scr.f_note)

    # panel
    x0, y0, x1, y1 = st.panel_title(d, "SPEED PER STEP" if step < 5 else "THE DRIVE'S OWN COUNTERS")
    if step < 5:
        gx0, gy0, gx1, gy1 = x0, y0 + int(4 * s), x1, y0 + int((y1 - y0) * 0.55)
        d.line([gx0, gy1, gx1, gy1], fill=P.MUTED)
        d.line([gx0, gy0, gx0, gy1], fill=P.MUTED)
        st.text(d, (gx0 + int(4 * s), gy0), "2000 MB/s", scr.f_tiny, P.MUTED)
        st.text(d, (gx1, gy1 + int(2 * s)), "48 GB", scr.f_tiny, P.MUTED, "ra")
        cx = gx0 + (gx1 - gx0) * CACHE_GB / INSTALL_GB
        for yy in range(int(gy0), int(gy1), max(4, int(8 * s))):
            d.line([cx, yy, cx, yy + max(2, int(4 * s))], fill=P.LINE)
        pts = []
        for i in range(int(g * 4) + 1):
            gb = i / 4.0
            pts.append((gx0 + (gx1 - gx0) * gb / INSTALL_GB,
                        gy1 - (gy1 - gy0) * install_speed(gb) / 2000))
        if len(pts) > 1:
            d.line(pts, fill=P.ACCENT, width=max(2, int(2 * s)))
        if g >= CACHE_GB + 2:
            st.text(d, (cx + int(6 * s), gy0 + int(18 * s)), "cache full", scr.f_tiny, P.WARN_)
        y = gy1 + int(24 * s)
        now = install_speed(g) if writing and g > 0 else 0
        st.kv(d, x0, x1, y, "Written", "%.1f GB of 48" % g)
        st.kv(d, x0, x1, y + int(30 * s), "Now", ("%d MB/s" % now) if now else "-")
        temp = 38 + int(30 * clamp(g / INSTALL_GB))
        st.kv(d, x0, x1, y + int(60 * s), "Drive temp", "%d C" % temp,
              P.WARN_ if temp >= 75 else P.PASS_)
        if step == 4:
            st.kv(d, x0, x1, y + int(90 * s), "Mismatches", "0", P.PASS_)
    else:
        rows = [("PCIe errors", "0 -> 0"), ("Link width", "x4 -> x4"),
                ("Media errors", "0 -> 0"), ("Critical-temp time", "0 -> 0 min"),
                ("Peak temperature", "68 C")]
        for i, (k, v) in enumerate(rows):
            if u * 6 > i:
                st.kv(d, x0, x1, y0 + i * int(32 * s), k, v, P.PASS_, f=scr.f_noteb)
        if u > 0.75:
            st.badge(d, x0, y0 + 5 * int(32 * s) + int(8 * s), "PASS", P.PASS_)


def surface_pos(step, u):
    return [lerp(0, 0.08, u), lerp(0.08, 0.30, u), lerp(0.30, 0.55, u),
            lerp(0.55, 1.0, ease(u)), 1.0][step]

UNMAPPED = 0.64          # the trimmed / never-written part of the example drive
BAD_AT = 0.47
BAD_CELL = (1, 2, 4)


def scene_surface(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    lt = st.lt
    pos = surface_pos(step, u)
    unmapped_now = pos >= UNMAPPED and step < 4
    bad_found = pos >= BAD_AT
    sec = SCENES[NAMES.index("surface")][3][step][0]

    lit = {k: P.DATA for k in st.cells if used_drive(*k)}
    lit[BAD_CELL] = P.DATA
    if step < 3 and not unmapped_now:
        # the addresses arrive in order; the map scatters them over the chips,
        # so every robot is sent to a different, unpredictable shelf
        per = 0.8
        for p in range(PKGS):
            f = lt / per + p * 0.25
            n = int(f)
            key = rnd_cell(p, n, step)
            while key not in lit or key == BAD_CELL:
                n += 7; key = rnd_cell(p, n, step)
            carry = P.ACCENT
            if step == 2 and p == BAD_CELL[0] and abs(lt / per - 0.55 * sec / per) < 1.0:
                key, carry = BAD_CELL, P.FAIL_
            done, at = st.job(p, [key], [None, carry], f % 1.0)
            if at:
                lit[key] = P.ACCENT if carry != P.FAIL_ else P.FAIL_
            if f % 1.0 > 0.8:
                st.trace_lit(d, p); st.trace_pulse(d, p, 1 - seg(f % 1.0, 0.8, 1.0))
    else:
        for p in range(PKGS):
            st.idle(p, "shrug" if step == 3 else "")
    if bad_found:
        lit[BAD_CELL] = P.BADT
    st.draw_cells(d, lambda p, r, c: lit.get((p, r, c)))

    # the strip: LBA 0 .. end, with the unmapped part hatched
    st.addr_strip(d, "LBA 0", "last LBA", "Addresses the host asks for - in order")
    st.strip_fill(d, 0, min(pos, UNMAPPED), P.DATA)
    x0, by0, x1, by1 = st._sb
    ux = int(lerp(x0, x1, UNMAPPED))
    if step >= 3:
        for xx in range(ux, x1, max(5, int(9 * s))):
            d.line([xx, by1 - int(2 * s), min(x1, xx + int(8 * s)), by0 + int(2 * s)], fill=P.LINE)
        st.text(d, ((ux + x1) // 2, by0 - int(4 * s)), "no data stored here", scr.f_tiny, P.MUTED, "md")
        if pos > UNMAPPED:
            st.strip_fill(d, UNMAPPED, pos, P.SPARE)
    if bad_found:
        bx = int(lerp(x0, x1, BAD_AT))
        d.rectangle([bx - max(1, int(2 * s)), by0, bx + max(1, int(2 * s)), by1], fill=P.FAIL_)
    cx = st.strip_cursor(d, pos)

    if step < 4:
        st.queue(d, 1, 1)
        st.glow(d, st.c_map)
        mx = (st.c_map[0] + st.c_map[2]) // 2
        d.line([(cx, by0), (cx, st.board[3] + int(6 * s)), (mx, st.board[3] + int(6 * s)), (mx, st.dram[3])],
               fill=P.ACCENT, width=max(1, int(2 * s)))
        if not unmapped_now:
            for i in range(3):
                st.lane_packet(d, ((t * 1.8) + i / 3) % 1, i, False, True)
            st.lit_lanes(d, 0.7)
        else:
            for i in range(4):
                st.lane_packet(d, ((t * 2.6) + i / 4) % 1, i, False, False, label="zeros" if i == 0 else None)
            st.lit_lanes(d, 0.5)
            st.callout(d, "answered from the map - robots not needed", P.INK)
    if step == 2:
        if abs(pos - BAD_AT) < 0.035:
            st.callout(d, "ECC cannot recover - read error", P.FAIL_)
            st.glow(d, st.c_ecc, P.FAIL_)
        elif int(t * 3) % 4 == 0:
            st.glow(d, st.c_ecc, P.PASS_)
            st.callout(d, "ECC fixed a weak bit", P.PASS_)

    # panel
    x0p, y0p, x1p, y1p = st.panel_title(d, "SCAN")
    blocks = int(pos * 125000000)          # 4 KiB blocks on a 512 GB drive
    st.kv(d, x0p, x1p, y0p, "Read", "%d %%" % int(pos * 100))
    st.kv(d, x0p, x1p, y0p + int(30 * s), "Blocks", thousands(blocks), f=scr.f_noteb)
    st.kv(d, x0p, x1p, y0p + int(60 * s), "Bad blocks", "1" if bad_found else "0",
          P.FAIL_ if bad_found else P.PASS_)
    corr = int(pos * min(pos, UNMAPPED) * 160)
    st.kv(d, x0p, x1p, y0p + int(98 * s), "Fixed by ECC", thousands(corr), P.MUTED, f=scr.f_noteb)
    st.text(d, (x0p, y0p + int(124 * s)), "inside the drive - the host never sees these",
            scr.f_tiny, P.MUTED)
    if step == 4:
        st.badge(d, x0p, y0p + int(160 * s), "FAIL", P.FAIL_)
        st.text(d, (x0p, y0p + int(204 * s)), "1 unreadable block - replace", scr.f_small, P.FAIL_)


SEGMENTS = ["RAM check", "SMART check", "Volatile memory backup", "Metadata validation",
            "NVM integrity", "Data integrity", "Media check"]


def scene_selftest(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    lt = st.lt
    lit = {k: P.DATA for k in st.cells if used_drive(*k)}
    # bus: one command, then a progress question every 2 s
    if step == 0 and u < 0.45:
        st.lane_packet(d, u / 0.45, 1, True, False, label="Device Self-test")
        st.queue(d, 1, 1)
    else:
        st.queue(d, 1, 0)
        ph = (t % 2.0) / 2.0
        if ph < 0.5:
            st.lane_packet(d, ph * 2, 2, True, False, label="progress?")
        elif ph < 0.8:
            pct = {0: 2, 1: int(u * 100), 2: int(u * 100), 3: 100, 4: 60}[step]
            st.lane_packet(d, (ph - 0.5) / 0.3, 2, False, True, label="%d%%" % pct)
    st.lit_lanes(d, 0.0)

    if step == 0 and u > 0.45:
        st.glow(d, st.ctrl)
    seg_done = 0
    if step == 1:
        seg_done = int(u * (len(SEGMENTS) + 0.99))
        cur = min(seg_done, len(SEGMENTS) - 1)
        target = [st.dram, st.c_map, st.dram, st.c_map, st.c_ecc, st.c_ecc, None][cur]
        if target:
            st.glow(d, target)
        if cur == 6:
            # media check, sampled: each robot inspects a few shelves
            per = 0.9
            for p in range(PKGS):
                f = lt / per + p * 0.25
                key = rnd_cell(p, int(f), 9)
                done, at = st.job(p, [key], [None, None], f % 1.0)
                if at:
                    lit[key] = P.ACCENT
        else:
            for p in range(PKGS):
                st.idle(p)
    elif step == 2:
        # extended: every robot walks every shelf of its own chip
        seg_done = len(SEGMENTS)
        order = [(r, c) for c in range(COLS) for r in range(ROWS)]
        f = ease(u) * (len(order) - 0.01)
        for p in range(PKGS):
            keys = [(p, r, c) for r, c in order]
            i = st.walk(p, keys, f)
            for k in keys[:i]:
                lit[k] = P.OKT
            lit[keys[i]] = P.ACCENT
        st.glow(d, st.c_ecc)
    else:
        seg_done = len(SEGMENTS)
        for k in st.cells:
            lit[k] = P.OKT
        for p in range(PKGS):
            if step == 4 and p == 1:
                continue
            st.idle(p, "happy" if step == 3 else "")
        if step == 4:
            # an ordinary read passes straight through mid-test
            v = (lt % 2.6) / 2.6
            key = rnd_cell(1, int(lt / 2.6), 4)
            if v < 0.25:
                st.lane_packet(d, v / 0.25, 0, True, False, label="normal read")
                st.idle(1)
            elif v < 0.75:
                done, at = st.job(1, [key], [None, P.ACCENT], seg(v, 0.25, 0.75))
                if at:
                    lit[key] = P.ACCENT
            else:
                st.idle(1)
                st.lane_packet(d, seg(v, 0.75, 1.0), 0, False, True, label="your data")
    st.draw_cells(d, lambda p, r, c: lit.get((p, r, c)))
    if step >= 1:
        st.callout(d, "bus quiet - the drive tests itself", P.INK)

    # strip: what the host is doing - almost nothing
    # strip: what the host is doing - almost nothing. The last 40 s scroll
    # past, one tick for each "how far along?"
    st.addr_strip(d, "40 s ago", "now", "What crosses the bus - one 'how far along?' every 2 s")
    x0, by0, x1, by1 = st._sb
    for k in range(int(t // 2) + 1):
        age = t - k * 2.0
        if age <= 40:
            xx = x1 - (x1 - x0) * age / 40
            d.line([xx, by0 + int(3 * s), xx, by1 - int(3 * s)], fill=P.ACCENT, width=max(1, int(2 * s)))

    # panel: the segments, then the log
    x0p, y0p, x1p, y1p = st.panel_title(d, "SELF-TEST SEGMENTS" if step < 3 else "SELF-TEST LOG",
                                        note="NVMe segments; SATA works the same way")
    if step < 3:
        rh = int(27 * s)
        for i, name in enumerate(SEGMENTS):
            y = y0p + i * rh
            done = i < seg_done
            cur = i == seg_done and 1 <= step < 3
            col = P.PASS_ if done else (P.ACCENT if cur else P.MUTED)
            st.text(d, (x0p, y), ("OK" if done else ".."), scr.f_noteb, col)
            label = name + ("  (sampled)" if i == 6 and step == 1 else "") + \
                    ("  (all of it)" if i == 6 and step == 2 else "")
            st.text(d, (x0p + int(34 * s), y), label, scr.f_small, P.INK if done or cur else P.MUTED)
        y = y0p + 7 * rh + int(8 * s)
        st.text(d, (x0p, y), "Short test" if step < 2 else "Extended test", scr.f_bodyb, P.INK)
    else:
        st.text(d, (x0p, y0p), "Newest entry", scr.f_tiny, P.MUTED)
        st.text(d, (x0p, y0p + int(22 * s)), "Extended", scr.f_bodyb, P.INK)
        st.text(d, (x0p, y0p + int(50 * s)), "Completed without error", scr.f_small, P.PASS_)
        st.text(d, (x0p, y0p + int(74 * s)), "result code 0", scr.f_note, P.MUTED)
        y = y0p + int(108 * s)
        for code, txt, tone in (("0", "no error - PASS", P.PASS_), ("1-4, 8-9", "aborted - INCOMPLETE", P.WARN_),
                                ("5-7", "a segment failed - FAIL", P.FAIL_)):
            st.text(d, (x0p, y), code, scr.f_noteb, tone)
            st.text(d, (x0p + int(86 * s), y), txt, scr.f_small, P.INK)
            y += int(26 * s)
        if step == 3 and u > 0.5:
            st.badge(d, x0p, y + int(8 * s), "PASS", P.PASS_)


def wear_of(p, r, c):
    return 0.08 + 0.18 * hrand(p, r, c, 11)


def scene_smart(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    lt = st.lt
    lit = {}
    x0p, y0p, x1p, y1p = st.panel_title(d, ["SMART / HEALTH LOG", "IDENTIFY", "PCIe LINK",
                                            "WEAR", "SPARE BLOCKS", "SMART / HEALTH LOG"][step])
    busy_bots = set()
    if step == 0:
        if u < 0.35:
            st.lane_packet(d, u / 0.35, 1, True, False, label="Get Log Page")
        elif u < 0.6:
            st.glow(d, st.c_ecc)
        else:
            st.lane_packet(d, seg(u, 0.6, 0.9), 1, False, True, label="512 bytes")
        st.queue(d, 1, 1 if u < 0.6 else 0)
        rows = [("Critical warning", "none"), ("Temperature", "38 C"), ("Available spare", "100 %"),
                ("Percentage used", "12 %"), ("Data units written", "71,875,000"),
                ("Power-on hours", "3,412")]
        if u > 0.85:
            for i, (k, v) in enumerate(rows):
                st.kv(d, x0p, x1p, y0p + i * int(30 * s), k, v, f=scr.f_noteb)
        else:
            st.text(d, (x0p, y0p), "waiting for the drive...", scr.f_small, P.MUTED)
        for k in st.cells:
            lit[k] = P.DATA if used_drive(*k) else None
    elif step == 1:
        st.glow(d, st.ctrl)
        st.queue(d, 1, 0)
        if u < 0.3:
            st.lane_packet(d, u / 0.3, 1, True, False, label="Identify")
        elif u < 0.6:
            st.lane_packet(d, seg(u, 0.3, 0.6), 1, False, True, label="4 KiB")
        rows = [("Model", "example 512GB"), ("Firmware", "rev. 1.0"),
                ("Controller", "from PCI ID"), ("Interface", "NVMe 1.3"),
                ("Namespace", "1")]
        for i, (k, v) in enumerate(rows):
            if u > 0.55 + i * 0.07:
                st.kv(d, x0p, x1p, y0p + i * int(30 * s), k, v, f=scr.f_noteb)
        st.callout(d, "the chip that actually fails", P.INK)
        for k in st.cells:
            lit[k] = P.DATA if used_drive(*k) else None
    elif step == 2:
        busy = u > 0.4
        st.queue(d, 1, 1 if busy else 0)
        st.lit_lanes(d, 1.0 if busy else 0.1)
        for k in st.cells:
            lit[k] = P.DATA if used_drive(*k) else None
        if busy:
            for i in range(4):
                st.lane_packet(d, ((t * 1.6) + i / 4) % 1, i, False, True, big=True)
            per = 0.9
            for p in range(PKGS):
                f = lt / per
                key = seq_cell(p, int(f))
                done, at = st.job(p, [key], [None, P.ACCENT], f % 1.0)
                busy_bots.add(p)
                if at:
                    lit[key] = P.ACCENT
        lab = "busy (512 MB read): 8 GT/s - PCIe 3.0 x4" if busy else "idle: 2.5 GT/s - power saving"
        st.callout(d, lab, P.PASS_ if busy else P.MUTED)
        rows = [("Link now", "PCIe 3.0 x4" if busy else "(reading...)"),
                ("Drive supports", "PCIe 3.0 x4"), ("Laptop slot", "PCIe 3.0 x4")]
        for i, (k, v) in enumerate(rows):
            st.kv(d, x0p, x1p, y0p + i * int(30 * s), k, v,
                  P.PASS_ if (i == 0 and busy) else None, f=scr.f_noteb)
        st.text(d, (x0p, y0p + int(104 * s)), "x2 of x4, or a lower PCIe, = reseat", scr.f_small, P.WARN_)
        st.text(d, (x0p, y0p + int(128 * s)), "and clean the M.2 contacts", scr.f_small, P.WARN_)
    elif step == 3:
        st.queue(d, 1, 0)
        # wear shading on every block, and one robot cycling a block:
        # write it, erase it, write it again - each round is one P/E cycle
        for k in st.cells:
            lit[k] = mix(P.PAPER, P.MUTED, wear_of(*k) + 0.25 * ease(u) * hrand(*k, 12))
        demo = (0, 1, 3)
        per = 2.0
        n = int(lt / per)
        v = (lt % per) / per
        if v < 0.5:
            done, at = st.job(0, [demo], [P.ACCENT, None], v * 2)
            lit[demo] = P.ACCENT if done[0] else P.PAPER
            word = "write"
        else:
            done, at = st.job(0, [demo], [None, None], (v - 0.5) * 2)
            lit[demo] = P.PAPER if done[0] else P.ACCENT
            word = "erase"
        busy_bots.add(0)
        st.chip_label(d, st.cells[demo], "%s - cycle %s" % (word, thousands(1210 + n)), P.ACCENT)
        st.kv(d, x0p, x1p, y0p, "Written in its life", "36.8 TB", f=scr.f_noteb)
        st.kv(d, x0p, x1p, y0p + int(30 * s), "Capacity", "512 GB", f=scr.f_noteb)
        d.line([x0p, y0p + int(58 * s), x1p, y0p + int(58 * s)], fill=P.LINE)
        st.kv(d, x0p, x1p, y0p + int(64 * s), "Full-drive writes", "72", f=scr.f_noteb)
        st.text(d, (x0p, y0p + int(90 * s)), "= minimum cycles per cell", scr.f_tiny, P.MUTED)
        if u > 0.45:
            st.kv(d, x0p, x1p, y0p + int(118 * s), "Percentage used", "12 %", f=scr.f_noteb)
            st.kv(d, x0p, x1p, y0p + int(148 * s), "Projected life", "~600 writes", f=scr.f_noteb)
            st.kv(d, x0p, x1p, y0p + int(178 * s), "Remaining", "~88 %", P.PASS_, f=scr.f_noteb)
    elif step == 4:
        st.queue(d, 1, 0)
        for k in st.cells:
            lit[k] = P.SPARE if k[2] == SPARE_COL else mix(P.PAPER, P.MUTED, wear_of(*k))
        worn, spare = (2, 2, 4), (2, 0, SPARE_COL)
        lit[worn] = P.DATA
        v = seg(u, 0.15, 0.85)
        done, at = st.job(2, [worn, spare], [None, P.DATA, None], v)
        busy_bots.add(2)
        if u > 0.12:
            lit[worn] = P.BADT
        if done[1]:
            lit[spare] = P.DATA
        st.text(d, (st.pkgs[1][2], st.pkgs[1][1] - int(6 * s)), "last column of each chip: spare blocks",
                scr.f_tiny, P.MUTED, "rd")
        sp = 97 if done[1] else 100
        st.kv(d, x0p, x1p, y0p, "Available spare", "%d %%" % sp, P.PASS_, f=scr.f_noteb)
        st.kv(d, x0p, x1p, y0p + int(30 * s), "Warns below", "10 %", f=scr.f_noteb)
        st.text(d, (x0p, y0p + int(70 * s)), "A worn-out block is retired and", scr.f_small, P.INK)
        st.text(d, (x0p, y0p + int(94 * s)), "its data moved to a spare.", scr.f_small, P.INK)
        st.text(d, (x0p, y0p + int(124 * s)), "At the threshold: replace the drive.", scr.f_small, P.WARN_)
    else:
        st.queue(d, 1, 0)
        for k in st.cells:
            lit[k] = P.DATA if used_drive(*k) else None
        rows = [("Media errors", "0", P.PASS_), ("Error log entries", "0", P.PASS_),
                ("Unsafe shutdowns", "14", None), ("Power-on hours", "3,412", None),
                ("Temperature", "38 C", P.PASS_)]
        for i, (k, v, tone) in enumerate(rows):
            if u * 6 > i:
                st.kv(d, x0p, x1p, y0p + i * int(30 * s), k, v, tone, f=scr.f_noteb)
        if u > 0.8:
            st.badge(d, x0p, y0p + 5 * int(30 * s) + int(10 * s), "PASSED", P.PASS_)
    for p in range(PKGS):
        if p not in busy_bots:
            st.idle(p, "happy" if step == 5 and u > 0.8 else "")
    st.draw_cells(d, lambda p, r, c: lit.get((p, r, c)))
    if step == 4:
        for k in st.cells:
            if k[2] == SPARE_COL and lit.get(k) == P.SPARE:
                b = st.cells[k]
                d.line([b[0], b[3], b[2], b[1]], fill=P.MUTED, width=max(1, int(2 * s)))

    # strip: the drive's counters live on the controller, not at an address
    st.addr_strip(d, "", "", "Where the answers come from")
    x0, by0, x1, by1 = st._sb
    st.text(d, ((x0 + x1) // 2, (by0 + by1) // 2),
            "the controller's own log - no user data is read", scr.f_tiny, P.MUTED, "mm")


WAKE_GAPS = (1, 2, 4, 8)            # seconds idle before each timed read, as in ctrltest.sh
WAKE_MS = (4, 6, 9, 11)             # example answers


def scene_ctrl(st, d, step, u, t):
    P, s, scr = st.P, st.s, st.scr
    lt = st.lt
    lit = {k: P.DATA for k in st.cells if used_drive(*k)}
    x0p, y0p, x1p, y1p = st.panel_title(d, ["THE CHIP", "BEFORE", "UNDER LOAD", "UNDER LOAD",
                                            "WAKING UP", "BEFORE -> AFTER"][step])
    rh = int(30 * s)

    # This example is a DRAM-less controller, the kind ctrltest.sh was written
    # for: no memory chip of its own, its map kept in borrowed laptop RAM.
    # Playing live over a drive that has DRAM, it is drawn as it is.
    dr = st.dram
    r = st.h_ram
    hm = (r[0] + int(4 * s), r[3] - int(24 * s), r[2] - int(4 * s), r[3] - int(4 * s))
    if not st.dramless:
        st.rr(d, dr, fill=P.CHIP, outline=P.MUTED)
        st.text(d, ((dr[0] + dr[2]) // 2, (dr[1] + dr[3]) // 2), "DRAM: its map", scr.f_tiny, P.INK, "mm")
    else:
        st.rr(d, dr, fill=P.BOARD, outline=P.LINE)
        st.text(d, ((dr[0] + dr[2]) // 2, (dr[1] + dr[3]) // 2), "no DRAM chip", scr.f_tiny, P.MUTED, "mm")
        st.rr(d, hm, fill=mix(P.PAPER, P.WARN_, 0.35))
        st.text(d, ((hm[0] + hm[2]) // 2, (hm[1] + hm[3]) // 2), "HMB: its map", scr.f_tiny, P.INK, "mm")
    if step == 0 and u > 0.45 and st.dramless:
        # the borrowed memory: a dotted line from the chip back to laptop RAM
        a = (st.ctrl[0], st.c_map[1] + (st.c_map[3] - st.c_map[1]) // 2)
        b = (hm[2], (hm[1] + hm[3]) // 2)
        pts = [a, (a[0] - int(12 * s), a[1]), (a[0] - int(12 * s), b[1]), b]
        for i in range(len(pts) - 1):
            (xa, ya), (xb, yb) = pts[i], pts[i + 1]
            n = max(1, int(math.hypot(xb - xa, yb - ya) / (8 * s)))
            for k in range(0, n, 2):
                d.line([lerp(xa, xb, k / n), lerp(ya, yb, k / n),
                        lerp(xa, xb, (k + 1) / n), lerp(ya, yb, (k + 1) / n)],
                       fill=P.WARN_, width=max(1, int(2 * s)))
        st.glow(d, hm, P.WARN_)

    sleeping = False
    if step == 0:
        st.queue(d, 1, 0)
        if u < 0.25:
            st.lane_packet(d, u / 0.25, 1, True, False, label="Identify")
        elif u < 0.45:
            st.lane_packet(d, seg(u, 0.25, 0.45), 1, False, True, label="4 KiB")
        st.glow(d, st.ctrl)
        st.callout(d, "the chip, named by its PCI ID", P.INK)
        rows = [("Controller chip", "[vendor:device]"), ("Firmware", "rev. 1.0"),
                ("Memory", "no DRAM"), ("Borrows (HMB)", "64 MB - given")]
        for i, (k, v) in enumerate(rows):
            if u > 0.3 + i * 0.12:
                st.kv(d, x0p, x1p, y0p + i * rh, k, v,
                      P.WARN_ if i >= 2 else None, f=scr.f_noteb)
        if u > 0.85:
            st.text(d, (x0p, y0p + 4 * rh + int(10 * s)), "No HMB given = WARN: slow,", scr.f_small, P.WARN_)
            st.text(d, (x0p, y0p + 5 * rh + int(6 * s)), "and the type most likely to stall", scr.f_small, P.WARN_)
    elif step == 1:
        st.queue(d, 1, 0)
        if u < 0.3:
            st.lane_packet(d, u / 0.3, 1, True, False, label="SMART log")
        elif u < 0.6:
            st.glow(d, st.c_ecc)
            st.lane_packet(d, seg(u, 0.3, 0.6), 1, False, True, label="512 bytes")
        rows = [("Temperature", "41 C"), ("Throttle events", "0"), ("Error log", "3"),
                ("Media errors", "0"), ("PCIe retries (AER)", "0")]
        for i, (k, v) in enumerate(rows):
            if u > 0.55 + i * 0.07:
                st.kv(d, x0p, x1p, y0p + i * rh, k, v, f=scr.f_noteb)
        st.callout(d, "written down now, compared at the end", P.INK)
    elif step in (2, 3):
        # 4 jobs x queue 32 = 128 small random reads in flight: every robot
        # flat out, and the map consulted for every single one
        st.queue(d, 32, 32 if int(t * 7) % 5 else 30)
        st.text(d, (st.c_queue[2] - int(4 * s), st.c_queue[1] + int(3 * s)), "x4 jobs",
                scr.f_tiny, P.ACCENT, "ra")
        if int(t * 8) % 2:
            st.glow(d, st.c_map)
        per = 0.5
        for p in range(PKGS):
            f = lt / per + p * 0.23
            key = rnd_cell(p, int(f), 7)
            done, at = st.job(p, [key], [None, P.ACCENT], f % 1.0)
            if at:
                lit[key] = P.ACCENT
            st.trace_lit(d, p, 0.8)
            if f % 1.0 > 0.8:
                st.trace_pulse(d, p, 1 - seg(f % 1.0, 0.8, 1.0))
        for i in range(10):
            st.lane_packet(d, ((t * 1.9) + i / 10) % 1, i, i % 2 == 0, i % 2 == 1)
        st.lit_lanes(d, 1.0)
        secs = int(lerp(0, 30, u)) if step == 2 else int(lerp(30, 60, u))
        temp = int(lerp(41, 55, u)) if step == 2 else int(lerp(55, 63, u))
        st.kv(d, x0p, x1p, y0p, "Time", "%d of 60 s" % secs)
        st.kv(d, x0p, x1p, y0p + rh, "Reads a second", thousands(238000 + 9000 * hrand(int(t * 2))),
              f=scr.f_noteb)
        st.kv(d, x0p, x1p, y0p + 2 * rh, "Temperature", "%d C (warns 80)" % temp,
              P.WARN_ if temp >= 80 else P.PASS_, f=scr.f_noteb)
        st.kv(d, x0p, x1p, y0p + 3 * rh, "PCIe link", "3.0 x4", P.PASS_, f=scr.f_noteb)
        st.kv(d, x0p, x1p, y0p + 4 * rh, "Kernel resets", "0", P.PASS_, f=scr.f_noteb)
        if step == 3:
            # the checks, every 2 s: each item lights as it is looked at
            k = int(lt / 0.5) % 4
            yy = y0p + (1 + k) * rh + int(rh * 0.45)
            d.line([x0p - int(8 * s), yy - int(10 * s), x0p - int(8 * s), yy + int(10 * s)],
                   fill=P.ACCENT, width=max(2, int(3 * s)))
            st.text(d, (x0p, y0p + 5 * rh + int(8 * s)), "A hang = Linux resets the controller", scr.f_small, P.FAIL_)
            st.text(d, (x0p, y0p + 6 * rh + int(4 * s)), "= FAIL. The link dropping = WARN.", scr.f_small, P.FAIL_)
            st.callout(d, "every 2 s: heat, link, kernel log", P.INK)
        else:
            st.callout(d, "128 small reads at once - read only", P.INK)
    elif step == 4:
        # idle -> deep power saving -> one timed read. The four gaps are
        # compressed to fit, in the same order and proportion as the real ones.
        st.queue(d, 1, 0)
        sec = SCENES[NAMES.index("ctrl")][3][4][0]
        spans = [0.6 + 0.25 * g for g in WAKE_GAPS]
        k = sum(spans) / sec
        acc, cur, v = 0.0, len(WAKE_GAPS) - 1, 1.0
        for i, sp in enumerate(spans):
            if lt < (acc + sp) / k:
                cur, v = i, (lt * k - acc) / sp
                break
            acc += sp
        idle_part = (0.25 * WAKE_GAPS[cur]) / spans[cur]
        asleep = v < idle_part
        if asleep:
            sleeping = True
            st.lit_lanes(d, 0.0)
            for p in range(PKGS):
                st.idle(p, "sleep" if v > idle_part * 0.3 else "")
            st.callout(d, "idle %d s: powering down (APST)" % WAKE_GAPS[cur], P.MUTED)
        else:
            w = seg(v, idle_part, 1.0)
            p = cur % PKGS
            key = rnd_cell(p, cur, 3)
            if w < 0.3:
                st.lane_packet(d, w / 0.3, 1, True, False, label="one 4 KB read")
                for q in range(PKGS):
                    st.idle(q, "sleep" if w < 0.2 else "")
            else:
                done, at = st.job(p, [key], [None, P.ACCENT], seg(w, 0.3, 0.95))
                if at:
                    lit[key] = P.ACCENT
                for q in range(PKGS):
                    if q != p:
                        st.idle(q)
            if v > 0.9:
                st.callout(d, "woke and answered in %d ms" % WAKE_MS[cur], P.PASS_)
            else:
                st.callout(d, "waking up... (timing it)", P.ACCENT)
        for i in range(len(WAKE_GAPS)):
            if i < cur or (i == cur and not asleep and v > 0.9):
                st.kv(d, x0p, x1p, y0p + i * rh, "after %d s idle" % WAKE_GAPS[i], "%d ms" % WAKE_MS[i],
                      P.PASS_, f=scr.f_noteb)
            elif i == cur:
                st.kv(d, x0p, x1p, y0p + i * rh, "after %d s idle" % WAKE_GAPS[i], "...", P.MUTED,
                      f=scr.f_noteb)
        st.text(d, (x0p, y0p + 4 * rh + int(10 * s)), "Slow to wake (over 3x what it", scr.f_small, P.WARN_)
        st.text(d, (x0p, y0p + 5 * rh + int(6 * s)), "promises) = WARN: the drive that", scr.f_small, P.WARN_)
        st.text(d, (x0p, y0p + 6 * rh + int(2 * s)), "vanishes or freezes the laptop.", scr.f_small, P.WARN_)
    else:
        st.queue(d, 1, 0)
        rows = [("Kernel resets", "0"), ("I/O errors", "0"), ("Media errors", "0 -> 0"),
                ("PCIe errors (AER)", "0 -> 0"), ("Throttle events", "0 -> 0"),
                ("Worst freeze", "38 ms"), ("Slowest wake", "11 ms")]
        for i, (k, v) in enumerate(rows):
            if u * 8 > i:
                st.kv(d, x0p, x1p, y0p + i * int(28 * s), k, v, P.PASS_, f=scr.f_noteb)
        if u > 0.8:
            st.badge(d, x0p, y0p + 7 * int(28 * s) + int(8 * s), "PASS", P.PASS_)
        for p in range(PKGS):
            st.idle(p, "happy" if u > 0.8 else "")

    if sleeping:
        for k in lit:
            lit[k] = mix(lit[k], P.PAPER, 0.5) if lit[k] else None
    st.draw_cells(d, lambda p, r_, c: lit.get((p, r_, c)))

    # strip: the kernel log, watched for resets while the load runs
    st.addr_strip(d, "", "", "Kernel log - watched for controller resets and time-outs")
    x0, by0, x1, by1 = st._sb
    if step in (2, 3):
        el = (u if step == 2 else 1.0 + u) / 2.0
        st.strip_fill(d, 0, el, P.OKT)
        st.strip_cursor(d, el, P.PASS_)
        st.text(d, ((x0 + x1) // 2, (by0 + by1) // 2), "no resets, no time-outs", scr.f_tiny, P.INK, "mm")
    elif step >= 4:
        st.strip_fill(d, 0, 1.0, P.OKT)
        st.text(d, ((x0 + x1) // 2, (by0 + by1) // 2), "clean for the whole minute", scr.f_tiny, P.INK, "mm")


DRAW = {"ctrl": scene_ctrl, "bench": scene_bench, "install": scene_install, "surface": scene_surface,
        "selftest": scene_selftest, "smart": scene_smart}
LABELS = {"bench": ("queue", "FTL map", "ECC"), "install": ("queue", "FTL map", "ECC"),
          "surface": ("queue", "FTL map", "ECC"), "selftest": ("queue", "self-test", "ECC"),
          "smart": ("queue", "identify", "SMART log"),
          "ctrl": ("queue", "FTL map", "SMART log")}


def locate(beats, t):
    """(step, progress through it) for t seconds into a scene."""
    acc = 0.0
    for i, (sec, _) in enumerate(beats):
        if t < acc + sec:
            return i, (t - acc) / sec
        acc += sec
    return len(beats) - 1, 1.0


def total(beats):
    return float(sum(b[0] for b in beats))


# ---------------------------------------------------------------- the set
# What frame(), play() and Live need from a set of animations. This module is
# one set (the drive tests); hwanim.py is the other and passes itself as kit.
def make_stage(scr, pal):
    return Stage(scr, Pal(pal))


def backdrop(st, i):
    return st.background(i, LABELS[SCENES[i][0]])


def live_words(name):
    """Live: the side panel's heading, and the note under the title."""
    return ("THIS DRIVE, NOW",
            "The moving parts are a picture of what the drive is doing; every figure is read from this drive.")


KIT = sys.modules[__name__]


def frame(st, scene_i, t, paused=False, kit=None):
    from PIL import ImageDraw
    K = kit or KIT
    name, title, prog, beats = K.SCENES[scene_i]
    img = K.backdrop(st, scene_i).copy()
    d = ImageDraw.Draw(img)
    step, u = locate(beats, t)
    st.lt = u * beats[step][0]
    K.DRAW[name](st, d, step, u, t)
    st.draw_bots(d, t)
    st.caption(d, beats[step][1], step, len(beats), u, paused)
    st.text(d, (st.scr.M + int(4 * st.s), st.H - st.scr.ftr // 2),
            "Left / Right: other tests     Space: pause     Enter: next step     Esc: back",
            st.scr.f_small, st.P.MUTED, "lm")
    return img


# ---------------------------------------------------------------- playing
def play(scr, kb, pal, start="bench", kit=None):
    """Runs until Esc / Q / right-click. Moves on to the next animation when one
    finishes, so picking the first plays the whole set."""
    K = kit or KIT
    st = K.make_stage(scr, pal)
    i = K.NAMES.index(start) if start in K.NAMES else 0
    clock = 0.0
    last = time.time()
    paused = False
    kb.drain()
    while True:
        now = time.time()
        if not paused:
            clock += min(now - last, 0.25)     # a stall is not a reason to skip a step
        last = now
        beats = K.SCENES[i][3]
        if clock >= total(beats):
            i = (i + 1) % len(K.SCENES); clock = 0.0
            continue
        scr.fb.blit(frame(st, i, clock, paused, K))
        spent = time.time() - now
        key, _ = kb.poll(1.0 if paused else max(0.01, 1.0 / FPS - spent))
        if key in (None, "hover", "wheelup", "wheeldown"):
            continue
        if key in ("esc", "q", "back", "backspace"):
            break
        if key in ("right", "down", "pgdn"):
            i = (i + 1) % len(K.SCENES); clock = 0.0
        elif key in ("left", "up", "pgup"):
            i = (i - 1) % len(K.SCENES); clock = 0.0
        elif key in ("space", "p"):
            paused = not paused
        elif key in ("enter", "click"):
            step, _ = locate(beats, clock)
            clock = sum(b[0] for b in beats[:step + 1]) + 0.001
        elif key and key.isdigit() and 1 <= int(key) <= len(K.SCENES):
            i = int(key) - 1; clock = 0.0
        last = time.time()
    kb.drain()
    return "ok"


# ---------------------------------------------------------------- live
# The same scenes, playing while the real test runs (Ash: "i want the
# animation show when the test is running"). The test says which scene and
# which of its steps fit the phase it is in - the load, the rest, the
# read-back - and those steps loop for as long as the phase lasts. Everything
# that would be an illustration is covered: the title, the side panel and the
# strip under the drive carry the test's own title, figures and progress bar,
# the same lines it draws on its usual screen. Only the moving parts are a
# picture, and the caption explains them.
class Live:
    def __init__(self, scr, pal, kit=None):
        self.K = kit or KIT
        self.st = self.K.make_stage(scr, pal)
        self.i, self.first, self.last, self.t0 = 0, 0, 0, time.time()
        self.fps = float(FPS)

    def set(self, name, first=0, last=None, *opts):
        # opts: "own" when the drive has DRAM of its own, "none" when it
        # borrows laptop RAM (unknown: drawn as the DRAM-less example);
        # "fps=N" for fewer frames - a battery drain must not be paying for a
        # smooth picture; anything else is the scene's own (hwanim.py).
        K = self.K
        opts = [o for o in opts if o]
        self.st.dramless = "own" not in opts
        self.st.opts = opts
        self.fps = float(FPS)
        for o in opts:
            if o.startswith("fps="):
                try:
                    self.fps = max(0.5, min(float(FPS), float(o[4:])))
                except ValueError:
                    pass
        self.i = K.NAMES.index(name) if name in K.NAMES else 0
        n = len(K.SCENES[self.i][3])
        self.first = max(0, min(int(first), n - 1))
        self.last = self.first if last is None else max(self.first, min(int(last), n - 1))
        self.t0 = time.time()

    def _tone(self, t):
        P = self.st.P
        return {"ok": P.PASS_, "warn": P.WARN_, "err": P.FAIL_,
                "muted": P.MUTED, "accent": P.ACCENT}.get(t, P.INK)

    def prepare(self, items):
        """Before the scene is drawn - hwanim.py hands the test's figures to
        its pictures here. The drive scenes draw from their own script."""

    def frame(self, title, hint, items, now=None):
        from PIL import ImageDraw
        K, st, P, s = self.K, self.st, self.st.P, self.st.s
        name, _, _, beats = K.SCENES[self.i]
        span = beats[self.first:self.last + 1]
        now = now if now is not None else time.time()
        lt = (now - self.t0) % total(span)
        step, u, acc = self.first, 0.0, 0.0
        for k, (sec, _) in enumerate(span):
            if lt < acc + sec:
                step, u = self.first + k, (lt - acc) / sec
                break
            acc += sec
        sec = beats[step][0]
        t = sum(b[0] for b in beats[:step]) + u * sec
        img = K.backdrop(st, self.i).copy()
        d = ImageDraw.Draw(img)
        st.lt = u * sec
        st.clock = now - self.t0
        self.prepare(items)
        K.DRAW[name](st, d, step, u, t)
        st.draw_bots(d, t)
        self._title(d, title)
        self._panel(d, items)
        self._strip(d, items)
        st.caption(d, beats[step][1], step, len(beats), u, False)
        st.text(d, (st.scr.M + int(4 * s), st.H - st.scr.ftr // 2), hint or "",
                st.scr.f_small, P.MUTED, "lm")
        return img

    def _title(self, d, title):
        st, P, s = self.st, self.st.P, self.st.s
        d.rectangle([st.ix0, st.title_y - int(8 * s), st.ix1, st.main_top - int(6 * s)], fill=P.PAPER)
        st.title_text(d, (st.ix0, st.title_y), title, right=st.ix1 - int(80 * s))
        st.live_tag(d, (st.ix1 - int(30 * s), st.title_y + int(16 * s)))
        st.text(d, (st.ix0, st.tabs_y + int(4 * s)), self.K.live_words(self.K.NAMES[self.i])[1],
                st.scr.f_small, P.MUTED)

    # A test with no progress bar: False covers the strip all the same (the
    # drive scenes' strips are illustrations); hwanim.py keeps its scenes'.
    KEEP_STRIP = False

    def _keep_line(self, text, tone):
        """Which of the test's lines go in the panel. The drive tests' plain
        lines are explanations, and the caption has those."""
        return tone in ("ok", "warn", "err", "accent")

    def _panel_foot(self):
        """A note at the foot of the panel, or None."""
        return None

    def _bar_label(self):
        """What the test's progress bar measures."""
        return "Progress of the test"

    def _panel(self, d, items):
        st, P, s = self.st, self.st.P, self.st.s
        x0, y0, x1, y1 = st.panel
        st.rr(d, st.panel, fill=P.PAPER, outline=P.LINE, width=max(1, int(2 * s)))
        ix0, ix1 = x0 + int(14 * s), x1 - int(14 * s)
        st.text(d, (ix0, y0 + int(12 * s)), self.K.live_words(self.K.NAMES[self.i])[0],
                st.scr.f_noteb, P.INK)
        y, lh = y0 + int(46 * s), int(26 * s)
        def row_of(it):
            try: return int(it[1])
            except (TypeError, ValueError): return 99
        bottom = y1 - int(8 * s)
        foot = self._panel_foot()
        if foot:
            st.text(d, (ix0, y1 - int(10 * s)), foot, st.scr.f_tiny, P.MUTED, "ld")
            bottom -= int(22 * s)
        # a table (the benchmark's results) becomes one entry per row
        head = next((i[2] for i in items if i[0] == "thead"), [])
        rows = []
        for it in items:
            if it[0] == "trow" and it[2]:
                cells = [str(c) for c in it[2]]
                vals = ["%s %s" % (h, c) for h, c in zip(head[1:], cells[1:]) if c not in ("", "-")]
                rows.append(("kv", it[1], cells[0], ", ".join(vals) or "waiting", ""))
            elif it[0] in ("kv", "line"):
                rows.append(it)
        # Lay every entry out first. When they do not all fit, the earliest
        # go: tests put what the drive is (chip, model) first and what it is
        # doing now (time, temperature, errors) after, and the live figures
        # are the ones worth the space.
        blocks = []                           # (height, [(text, font, colour, dy)])
        for it in sorted(rows, key=row_of):
            if it[0] == "kv":
                v = str(it[3])
                f = st.scr.f_bodyb if len(v) <= 24 else st.scr.f_body   # long names smaller
                parts = [(it[2], st.scr.f_small, P.MUTED, int(21 * s))]
                for ln in st.wrap(d, v, f, ix1 - ix0, maxlines=2):
                    parts.append((ln, f, self._tone(it[4] if len(it) > 4 else ""), lh))
                blocks.append((sum(p[3] for p in parts) + int(4 * s), parts))
            else:
                tone = it[3] if len(it) > 3 else ""
                if not str(it[2]).strip() or not self._keep_line(str(it[2]), tone):
                    continue
                parts = [(ln, st.scr.f_small, self._tone(tone), int(22 * s))
                         for ln in st.wrap(d, str(it[2]), st.scr.f_small, ix1 - ix0, maxlines=3)]
                blocks.append((sum(p[3] for p in parts), parts))
        while blocks and sum(b[0] for b in blocks) > bottom - y:
            blocks.pop(0)
        for height, parts in blocks:
            for text, f, col, dy in parts:
                st.text(d, (ix0, y), text, f, col)
                y += dy
            y += height - sum(p[3] for p in parts)

    def _strip(self, d, items):
        st, P, s = self.st, self.st.P, self.st.s
        x0, y0, x1, y1 = st.strip_box
        bars = [i for i in items if i[0] == "bar"]
        if not bars and self.KEEP_STRIP:
            return
        # the scene's own strip labels sit just below the box, and its callouts
        # can hang just above it - cover from the board's edge down
        d.rectangle([x0, y0 - int(8 * s), x1, y1 + int(7 * s)], fill=P.PAPER)
        if not bars:
            return
        pct = clamp(bars[-1][2] / 100.0)
        st.text(d, (x0, y0), self._bar_label(), st.scr.f_tiny, P.MUTED)
        st.text(d, (x1, y0), "%d%%" % int(pct * 100), st.scr.f_tiny, P.MUTED, "ra")
        by0, by1 = y0 + int(20 * s), y1 - int(10 * s)
        st.rr(d, (x0, by0, x1, by1), fill=P.PAPER, outline=P.MUTED, r=int(4 * s))
        m = max(1, int(2 * s))
        xb = int(lerp(x0, x1, pct))
        if xb - x0 > 2 * m + 1:
            d.rectangle([x0 + m, by0 + m, xb - m, by1 - m], fill=P.ACCENT)


# ---------------------------------------------------------------- standalone
def _screen_for(w, h, theme):
    """ui.py's screen, drawing into nothing - for checks and preview frames."""
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    import ui
    ui.apply_theme(theme)
    ui.load_settings = lambda: None

    class _FB:
        cursor = None
        def __init__(self): self.w, self.h = w, h
        def blit(self, img): pass
    scr = ui.Screen(_FB())
    scr.sub = "TOSHIBA dynabook EXAMPLE\nIntel Core i5 - 16384 MB"
    return scr


def _stage_for(w, h, theme):
    scr = _screen_for(w, h, theme)
    return Stage(scr, Pal(__import__("ui").anim_palette()))


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


def main(argv):
    def opt(k, dflt):
        return argv[argv.index(k) + 1] if k in argv else dflt
    size = opt("--size", "1280x800")
    w, h = (int(v) for v in size.lower().split("x"))
    theme = opt("--theme", "light")
    if "--text" in argv:
        rest = [a for a in argv[argv.index("--text") + 1:] if not a.startswith("--")]
        print(_text(rest))
        return 0
    if "--check" in argv:
        # every step of every scene, at its start, middle and end, in every
        # theme - the build runs this so a broken animation stops the build
        # instead of the toolkit on a customer's machine
        n = 0
        for th in ("light", "dark", "contrast", "mecha", "kawaii"):
            st = _stage_for(w, h, th)
            for si, (_, _, _, beats) in enumerate(SCENES):
                acc = 0.0
                for sec, _ in beats:
                    for k in (0.02, 0.5, 0.98):
                        img = frame(st, si, acc + sec * k)
                        assert img.size == (w, h)
                        n += 1
                    acc += sec
            # live mode: every step of every scene with a test's own lines over it
            live = Live(st.scr, __import__("ui").anim_palette())
            sample = [("kv", "10", "Time", "28 of 60 s", ""),
                      ("kv", "13", "Temperature", "49 C now, 49 C peak (warning at 70 C)", "warn"),
                      ("line", "15", "a long alert line that has to wrap inside the narrow panel", "err"),
                      ("line", "16", "an explanation the caption already covers", "muted"),
                      ("bar", "22", 46)]
            for si, (name, _, _, beats) in enumerate(SCENES):
                for k in range(len(beats)):
                    live.set(name, k, k)
                    img = live.frame("Controller check - /dev/nvme0n1", "Q = stop", sample,
                                     now=live.t0 + beats[k][0] * 0.5)
                    assert img.size == (w, h)
                    n += 1
        print("ssdanim: %d frames rendered OK" % n)
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
            n = int(total(beats) * fps)
            for f in range(n):
                frame(st, si, f / fps).save(os.path.join(out, "%s_%05d.png" % (name, f)))
            print("%s: %d frames" % (name, n))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
