#!/usr/bin/env python3
"""Two whole-screen skins for ui.py, picked in Settings -> Colour theme:

    mecha    Mecha Command Deck - the bench as a launch deck: every test a
             chamfered system bay with a status lamp, signal orange for the
             one thing selected, hazard stripes on the deck's furniture.
    kawaii   Kawaii Pastel - the toolkit as a sticker sheet: white stickers
             with a lavender backing on blush pink, a scalloped header band,
             results as reward stamps.

ui.py hands its drawing here while one of these themes is active (THEME_SKIN);
the palettes live with the others in ui.THEMES. Positions never change: every
test script places its lines by row number, and the skins draw the same rows,
card box and header height - only what is around and under the words changes,
so no script needs to know which skin is on.

Ash's rules for both (1.20): no mascot, no busy art behind text, no Japanese
lettering. Decoration - hazard stripes, scallops, sparkles, candy stripes -
only goes where no word is drawn.

Display faces: Bebas Neue (mecha) and Comfortaa (kawaii), from the
fonts-bebas-neue / fonts-comfortaa packages that finalize_chroot.sh installs
and asserts. Body text stays Carlito, numbers DejaVu Sans Mono. A missing
display face falls back to Carlito Bold - never to PIL's 11 px bitmap.

    python3 skins.py --check      render every skinned screen (the build runs this)
    python3 skins.py --shots DIR  the same, saved as PNGs to look at
"""
import math
import os
import sys

from PIL import Image, ImageDraw

BEBAS_B = "/usr/share/fonts/opentype/bebas-neue/BebasNeue-Bold.otf"
BEBAS_R = "/usr/share/fonts/opentype/bebas-neue/BebasNeue-Regular.otf"
COMFY_B = "/usr/share/fonts/truetype/comfortaa/Comfortaa-Bold.ttf"

# Colours that belong to a skin rather than to the shared palette roles.
MECHA = dict(BAR=(18, 18, 22), HAZ_A=(255, 196, 0), HAZ_B=(17, 17, 19), TAB=(40, 40, 47),
             TEXT_ON=(11, 11, 13))
KAWAII = dict(BAND=(255, 199, 222), BACKING=(217, 204, 255), SEL_EDGE=(80, 48, 214),
              CHIP=(255, 236, 244), STAR_EDGE=(186, 160, 255), CANDY=(146, 120, 255),
              HONEY=(255, 196, 72))


# ---------------------------------------------------------------- fonts
_FONTS = {}


def fonts(scr, U):
    """The skin's faces at the current panel and text size."""
    ts = scr.s * U.TEXT_SCALE
    key = (scr.s, U.TEXT_SCALE)          # some faces use the two separately
    hit = _FONTS.get(key)
    if hit is not None:
        return hit
    f = type("F", (), {})()
    f.bebas_xl = U.font([BEBAS_B] + U.UI_B, int(46 * ts))
    # the card title sits in a fixed band above row 6: it grows with the text
    # size only so far, or it runs into the first line
    f.bebas_title = U.font([BEBAS_B] + U.UI_B, int(46 * scr.s * min(U.TEXT_SCALE, 1.15)))
    f.bebas_l = U.font([BEBAS_B] + U.UI_B, int(34 * ts))
    f.bebas_m = U.font([BEBAS_B] + U.UI_B, int(28 * ts))
    f.bebas_s = U.font([BEBAS_R] + U.UI_B, int(22 * ts))
    f.comfy_l = U.font([COMFY_B] + U.UI_B, int(30 * ts))
    f.comfy_title = U.font([COMFY_B] + U.UI_B, int(30 * scr.s * min(U.TEXT_SCALE, 1.15)))
    f.comfy_m = U.font([COMFY_B] + U.UI_B, int(24 * ts))
    f.comfy_s = U.font([COMFY_B] + U.UI_B, int(19 * ts))
    f.comfy_xs = U.font([COMFY_B] + U.UI_B, int(15 * ts))
    f.comfy_xxs = U.font([COMFY_B] + U.UI_B, int(12 * ts))
    f.mono_s = U.font(U.MONO_R, int(13 * ts))
    f.mono_m = U.font(U.MONO_B, int(17 * ts))
    # tile names, largest first: a layout takes the biggest that fits. The
    # second ladder is in normal-size steps whatever the text size: at 150 %
    # on a 1366x768 panel no grown size left the icons more than a speck, and
    # the jump from the smallest grown size to normal size was too coarse.
    f.names = {}
    for skin, face, px in (("mecha", BEBAS_B, (28, 25, 22, 19)), ("kawaii", COMFY_B, (19, 17, 15, 13))):
        lo = px[-1]
        sizes = sorted({int(p * ts) for p in px} | {int(p * scr.s) for p in (lo + 4, lo + 2, lo, lo - 2)},
                       reverse=True)
        f.names[skin] = [U.font([face] + U.UI_B, sz) for sz in sizes]
    _FONTS[key] = f
    return f


def sub_lines(scr, U, d, font, avail):
    """The machine: model over CPU and memory. As on the manual sheet, the CPU
    name is tidied and shortened first - the memory figure is never cut."""
    parts = scr.sub.split("\n")[:2]
    if len(parts) > 1:
        p = U.re.sub(r"\((R|TM|tm|r)\)|\bCPU\b|\b\d+(st|nd|rd|th) Gen\b", "", parts[1])
        p = U.re.sub(r"\s+", " ", p).strip()
        if d.textlength(p, font=font) > avail and " - " in p:
            cpu, mem = p.rsplit(" - ", 1)
            mem = " - " + mem
            p = scr._clip(d, cpu, font, avail - d.textlength(mem, font=font)) + mem
        parts[1] = p
    parts[0] = scr._clip(d, parts[0], font, avail)
    return parts


# ---------------------------------------------------------------- primitives
def mix(a, b, t):
    return tuple(int(x + (y - x) * t) for x, y in zip(a, b))


def chamfer_pts(box, cut, corners="tl br"):
    """A rectangle with 45-degree cuts at the named corners."""
    x0, y0, x1, y1 = box
    c = {k: cut if k in corners else 0 for k in ("tl", "tr", "br", "bl")}
    return [(x0 + c["tl"], y0), (x1 - c["tr"], y0), (x1, y0 + c["tr"]), (x1, y1 - c["br"]),
            (x1 - c["br"], y1), (x0 + c["bl"], y1), (x0, y1 - c["bl"]), (x0, y0 + c["tl"])]


def chamfer(d, box, cut, fill=None, outline=None, width=1, corners="tl br"):
    pts = chamfer_pts(box, cut, corners)
    if fill is not None:
        d.polygon(pts, fill=fill)
    if outline is not None:
        d.line(pts + [pts[0]], fill=outline, width=width, joint="curve")


_HAZ = {}


def hazard(w, h, period, a, b):
    """Diagonal stripes, period px wide, as a tile - cached, it never changes."""
    key = (w, h, period, a, b)
    img = _HAZ.get(key)
    if img is None:
        img = Image.new("RGB", (max(1, w), max(1, h)), b)
        d = ImageDraw.Draw(img)
        for x in range(-h - period, w + period, period):
            d.polygon([(x, h), (x + h, 0), (x + h + period // 2, 0), (x + period // 2, h)], fill=a)
        _HAZ[key] = img
    return img


def sparkle(d, cx, cy, r, fill, edge=None):
    """A four-point star: the kawaii world's only ornament, kept to margins."""
    k = 0.30
    pts = []
    for i in range(8):
        a = math.pi / 4 * i - math.pi / 2
        rr = r if i % 2 == 0 else r * k
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    d.polygon(pts, fill=fill, outline=edge)


def spaced(d, xy, text, font, fill, sp, anchor="lm"):
    x, y = xy
    for ch in text:
        d.text((x, y), ch, font=font, fill=fill, anchor=anchor)
        x += d.textlength(ch, font=font) + sp
    return x - xy[0] - sp


def tone_of(res, U):
    """A result string ("PASS 14:02", "FAIL 09:11", "WARN ...") -> its colour."""
    r = (res or "").upper()
    if r.startswith("PASS"):
        return U.PASS_
    if r.startswith("FAIL"):
        return U.FAIL_
    if r[:4] in ("WARN", "MARG", "PART", "STOP"):
        return U.WARN_
    return None


def stamp_cols(U, col, on=False):
    """(fill, text) of a kawaii result stamp. WARN is honey with plum text:
    white on the amber was the weakest pair on the sheet. On a selected
    (violet) row or sticker the stamp turns white with the result colour."""
    if on:
        return U.PAPER, col
    if col == U.WARN_:
        return KAWAII["HONEY"], U.INK
    return col, U.PAPER


def num_pill(d, U, f, x0, cy, r, text, fill, tcol):
    """A kawaii number: a circle, stretched into a pill once it holds two
    digits - "10" to "17" ran out of the circle."""
    w = max(2 * r, int(d.textlength(text, font=f.mono_m) + r))
    d.rounded_rectangle([x0, cy - r, x0 + w, cy + r], r, fill=fill)
    d.text((x0 + w / 2.0, cy), text, font=f.mono_m, fill=tcol, anchor="mm")
    return w


def check_mark(d, cx, cy, r, col, w):
    d.line([(cx - r, cy), (cx - r * 0.3, cy + r * 0.7), (cx + r, cy - r * 0.7)], fill=col, width=w,
           joint="curve")


def cross_mark(d, cx, cy, r, col, w):
    d.line([(cx - r, cy - r), (cx + r, cy + r)], fill=col, width=w)
    d.line([(cx - r, cy + r), (cx + r, cy - r)], fill=col, width=w)


# ---------------------------------------------------------------- header
def header(scr, U, img, d):
    (_mecha_header if U.SKIN == "mecha" else _kawaii_header)(scr, U, img, d)


def _readout(d, scr, f, xr, y0, y1, label, value, U, icon=None):
    """A boxed readout, right edge at xr; returns its left edge."""
    s = scr.s
    pad = int(10 * s)
    vw = d.textlength(value, font=f.mono_m) + (int(30 * s) if icon else 0)
    w = int(max(vw, d.textlength(label, font=f.mono_s)) + 2 * pad)
    x0 = xr - w
    d.rectangle([x0, y0, xr, y1], outline=U.LINE, width=1)
    # at large text the box no longer holds label over value: the value wins
    both = f.mono_s.size + f.mono_m.size + int(10 * s) <= y1 - y0
    if both:
        d.text((x0 + pad, y0 + int(4 * s)), label, font=f.mono_s, fill=U.MUTED, anchor="la")
        d.text((xr - pad, y1 - int(5 * s)), value, font=f.mono_m, fill=U.INK, anchor="rd")
    else:
        d.text((xr - pad, (y0 + y1) // 2), value, font=f.mono_m, fill=U.INK, anchor="rm")
    if icon:
        icon(x0 + pad + int(11 * s), y1 - int(14 * s) if both else (y0 + y1) // 2)
    return x0


def _mecha_header(scr, U, img, d):
    s, W = scr.s, scr.W
    f = fonts(scr, U)
    h = scr.hdr - int(10 * s)            # the bar stops short of the card below it
    d.rectangle([0, 0, W, h], fill=MECHA["BAR"])
    d.line([(0, h - 1), (W, h - 1)], fill=U.LINE, width=max(2, int(2 * s)))
    hw = int(46 * s)
    img.paste(hazard(hw, h - 1, max(8, int(16 * s)), MECHA["HAZ_A"], MECHA["HAZ_B"]), (0, 0))
    x = hw + int(20 * s)
    U._draw_brand(img, x, h // 2, int(24 * s))
    x += int(34 * s)
    namew = spaced(d, (x, h // 2 + int(2 * s)), "HARDWARE DIAGNOSTIC TOOLKIT", f.bebas_l, U.INK,
                   max(1, int(1.5 * s)))
    left_limit = x + namew + int(24 * s)
    scr.refresh_status()
    y0, y1 = int(9 * s), h - int(9 * s)
    xr = W - int(16 * s)
    isz = int(22 * s)
    clock, date = scr.status["clock"], scr.status["date"].upper()
    xl = _readout(d, scr, f, xr, y0, y1, "TIME", clock, U,
                  icon=lambda cx, cy: U._draw_wifi_status(d, cx, cy, isz, scr.status["wifi"]))
    scr.status_box = [xl, y0, xr, y1]
    xr = xl - int(8 * s)
    xr = _readout(d, scr, f, xr, y0, y1, "DATE", date, U) - int(8 * s)
    xr = _readout(d, scr, f, xr, y0, y1, "REV", U.DIAG_REV, U) - int(8 * s)
    if scr.sub:
        avail = xr - left_limit
        if avail > int(140 * s):
            pad = int(10 * s)
            parts = sub_lines(scr, U, d, scr.f_tiny, avail - 2 * pad)
            w = int(max(d.textlength(p, font=scr.f_tiny) for p in parts) + 2 * pad) + 2
            d.rectangle([xr - w, y0, xr, y1], outline=U.LINE, width=1)
            for i, p in enumerate(parts):
                yy = (y0 + y1) // 2 + (i - (len(parts) - 1) / 2) * int(17 * s)
                d.text((xr - w + pad, yy), p, font=scr.f_tiny,
                       fill=U.INK if i == 0 else U.MUTED, anchor="lm")


def _kawaii_header(scr, U, img, d):
    s, W = scr.s, scr.W
    f = fonts(scr, U)
    band = KAWAII["BAND"]
    # the scalloped edge: half-circles hanging under the band, ending just
    # above the card so the two never touch
    r = max(5, int(10 * s))
    h = scr.hdr - r - int(4 * s)
    d.rectangle([0, 0, W, h], fill=band)
    for x in range(-r, W + 2 * r, 2 * r):
        d.ellipse([x, h - r, x + 2 * r, h + r], fill=band)
    # sparkles in the band's corners, clear of every word
    m = scr.M
    sparkle(d, m * 0.42, h * 0.38, int(10 * s), U.PAPER, KAWAII["STAR_EDGE"])
    sparkle(d, m * 0.78, h * 0.70, int(5 * s), KAWAII["STAR_EDGE"])
    sparkle(d, W - m * 0.42, h * 0.36, int(9 * s), U.PAPER, KAWAII["STAR_EDGE"])
    x = m
    U._draw_brand(img, x, h // 2, int(24 * s))
    name = "Hardware Diagnostic Toolkit"
    d.text((x + int(34 * s), h // 2), name, font=f.comfy_l, fill=U.INK, anchor="lm")
    left_limit = x + int(34 * s) + d.textlength(name, font=f.comfy_l) + int(24 * s)
    scr.refresh_status()
    xr = W - m
    ch = int(34 * s)
    cy = h // 2

    def chip(xr, text, font, icon=None):
        pad = int(14 * s)
        w = int(d.textlength(text, font=font) + 2 * pad + (int(28 * s) if icon else 0))
        d.rounded_rectangle([xr - w, cy - ch // 2, xr, cy + ch // 2], ch // 2, fill=U.PAPER)
        d.text((xr - pad, cy), text, font=font, fill=U.INK, anchor="rm")
        if icon:
            icon(xr - w + pad + int(10 * s), cy)
        return xr - w

    isz = int(22 * s)
    xl = chip(xr, scr.status["clock"], f.mono_m,
              icon=lambda cx, cy_: U._draw_wifi_status(d, cx, cy_, isz, scr.status["wifi"]))
    scr.status_box = [xl, cy - ch // 2, xr, cy + ch // 2]
    xr = chip(xl - int(8 * s), scr.status["date"], scr.f_small) - int(16 * s)
    if scr.sub:
        avail = xr - left_limit
        if avail > int(140 * s):
            for i, p in enumerate(sub_lines(scr, U, d, scr.f_tiny, avail)):
                yy = cy + (i - 0.5) * int(18 * s)
                d.text((xr, yy), p, font=scr.f_tiny,
                       fill=U.INK if i == 0 else mix(U.INK, band, 0.25), anchor="rm")


# ---------------------------------------------------------------- the card
def card(scr, U, d):
    s = scr.s
    x0, y0, x1, y1 = scr._card_box()
    if U.SKIN == "mecha":
        cut = int(26 * s)
        chamfer(d, (x0, y0, x1, y1), cut, fill=U.PAPER, outline=U.LINE, width=max(2, int(2 * s)))
        # corner brackets on the two square corners - HUD framing. Grey, not
        # orange: orange is kept for the one thing that is selected.
        L, w = int(38 * s), max(3, int(3 * s))
        d.line([(x1 - L, y0), (x1, y0), (x1, y0 + L)], fill=U.MUTED, width=w, joint="curve")
        d.line([(x0, y1 - L), (x0, y1), (x0 + L, y1)], fill=U.MUTED, width=w, joint="curve")
    else:
        r = int(26 * s)
        o = (int(7 * s), int(9 * s))
        d.rounded_rectangle([x0 + o[0], y0 + o[1], x1 + o[0], y1 + o[1]], r, fill=KAWAII["BACKING"])
        d.rounded_rectangle([x0, y0, x1, y1], r, fill=U.PAPER, outline=U.LINE,
                            width=max(2, int(2 * s)))
        # sparkles in the ground margin beside the card, never on it
        m = scr.M
        sparkle(d, x1 + m * 0.5, y0 + int(24 * s), int(11 * s), U.PAPER, KAWAII["STAR_EDGE"])
        sparkle(d, x1 + m * 0.62, y0 + int(54 * s), int(5 * s), KAWAII["STAR_EDGE"])
        sparkle(d, x0 - m * 0.5, y1 - int(40 * s), int(8 * s), U.PAPER, KAWAII["STAR_EDGE"])
    return x0, y0, x1, y1


def title(scr, U, d, tx, y0, x1):
    s = scr.s
    f = fonts(scr, U)
    if U.SKIN == "mecha":
        t = scr.title.upper()
        y = y0 + scr.pad + int(20 * s)
        w = spaced(d, (tx, y), t, f.bebas_title, U.INK, max(1, int(1 * s)))
        # a HUD rule from the title to the card edge, ending in a key -
        # stopping short where a long menu prints "11-22 of 26" up there
        lx0 = tx + w + int(18 * s)
        lx1 = x1 - scr.pad - (int(150 * s) if any(it[0] == "menu" for it in scr.items) else 0)
        if lx1 - lx0 > int(80 * s):
            d.line([(lx0, y), (lx1, y)], fill=U.LINE, width=max(1, int(2 * s)))
            d.rectangle([lx1 - int(46 * s), y - int(2 * s), lx1, y + int(2 * s)], fill=U.MUTED)
    else:
        ty = y0 + scr.pad - int(2 * s)
        d.text((tx, ty), scr.title, font=f.comfy_title, fill=U.INK, anchor="la")
        # a dotted rule across the card between the title and row 6 - the
        # squiggle that was here read as a doodle, and at 150 % it met the
        # first badge. Left out when the gap is too thin to hold it.
        bottom = ty + sum(f.comfy_title.getmetrics())
        y = scr.row_y(6) - int(14 * s)
        if y - bottom >= int(4 * s):
            r, step = max(1, int(1.6 * s)), max(6, int(10 * s))
            for x in range(int(tx + r), int(x1 - scr.pad), step):
                d.ellipse([x - r, y - r, x + r, y + r], fill=U.LINE)


# ---------------------------------------------------------------- the animations
# ssdanim / hwanim draw their own frames; their title and LIVE chip come from
# here so a How-it-works screen speaks the same language as the rest.
def anim_title_style(scr, U):
    """(font, set in capitals) for an animation screen's title."""
    f = fonts(scr, U)
    return (f.bebas_title, True) if U.SKIN == "mecha" else (f.comfy_title, False)


def anim_title_rule(scr, U, d, f, xy, text, right):
    """The rule the skin's card titles carry, beside an animation's title
    (xy is its top-left, anchor "la"). Beside rather than under: the
    diagram's first line sits close below the title on these screens."""
    s = scr.s
    x0 = int(xy[0] + d.textlength(text, font=f) + 18 * s)
    if right - x0 < int(80 * s):
        return
    y = int(xy[1] + sum(f.getmetrics()) * 0.5)
    if U.SKIN == "mecha":
        d.line([(x0, y), (right, y)], fill=U.LINE, width=max(1, int(2 * s)))
        d.rectangle([right - int(46 * s), y - int(2 * s), right, y + int(2 * s)], fill=U.MUTED)
    else:
        r, step = max(1, int(1.6 * s)), max(6, int(10 * s))
        for x in range(x0, int(right), step):
            d.ellipse([x - r, y - r, x + r, y + r], fill=U.LINE)


def anim_tag(scr, U, d, xy, text):
    """The LIVE chip, centred on xy: a chamfered plate on the deck, a pill on
    the sticker sheet."""
    s = scr.s
    f = fonts(scr, U)
    x, y = xy
    if U.SKIN == "mecha":
        tw = d.textlength(text, font=f.bebas_s)
        box = (int(x - tw / 2 - 10 * s), int(y - 13 * s), int(x + tw / 2 + 10 * s), int(y + 13 * s))
        chamfer(d, box, int(7 * s), fill=MECHA["TAB"], outline=U.LINE, width=max(1, int(2 * s)))
        d.text((x, y + int(1 * s)), text, font=f.bebas_s, fill=U.INK, anchor="mm")
    else:
        tw = d.textlength(text, font=f.comfy_xs)
        box = (int(x - tw / 2 - 12 * s), int(y - 12 * s), int(x + tw / 2 + 12 * s), int(y + 12 * s))
        d.rounded_rectangle(box, (box[3] - box[1]) // 2, fill=U.ACCENT)
        d.text((x, y), text, font=f.comfy_xs, fill=U.PAPER, anchor="mm")


# ---------------------------------------------------------------- items
def bar(scr, U, d, it, left, right):
    s = scr.s
    _, row, pct = it
    pct = max(0, min(100, pct))
    y = scr.row_y(row) + int(6 * s)
    h = int(16 * s)
    w = right - left - int(80 * s)
    if U.SKIN == "mecha":
        n = max(10, w // int(14 * s))
        gap = max(2, int(3 * s))
        sw = (w - (n - 1) * gap) / float(n)
        lit = int(round(n * pct / 100.0))
        for k in range(n):
            x = left + k * (sw + gap)
            d.rectangle([x, y, x + sw, y + h], fill=U.ACCENT if k < lit else MECHA["TAB"])
    else:
        d.rounded_rectangle([left, y, left + w, y + h], h // 2, fill=KAWAII["CHIP"], outline=U.LINE)
        fw = int(w * pct / 100)
        if fw > h:
            # candy stripes inside the fill - no word is ever drawn in a bar
            fill = Image.new("RGB", (fw, h), U.ACCENT)
            fd = ImageDraw.Draw(fill)
            per = max(8, int(16 * s))
            for x in range(-h, fw + per, per):
                fd.polygon([(x, h), (x + h, 0), (x + h + per // 2, 0), (x + per // 2, h)],
                           fill=KAWAII["CANDY"])
            mask = Image.new("L", (fw, h), 0)
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, fw - 1, h - 1], h // 2, fill=255)
            d._image.paste(fill, (left, y), mask)
    d.text((right, y + h // 2), "%d%%" % pct, font=scr.f_mono, fill=U.MUTED, anchor="rm")


def badge(scr, U, d, it, left):
    s = scr.s
    f = fonts(scr, U)
    _, row, state, text = it
    st = state.upper()
    y = scr.row_y(row) - int(6 * s)
    h = int(40 * s)
    col = {"PASS": U.PASS_, "OK": U.PASS_, "FAIL": U.FAIL_, "WARN": U.WARN_, "MARGINAL": U.WARN_,
           "STOPPED": U.WARN_, "PARTIAL": U.WARN_}.get(st)
    if U.SKIN == "mecha":
        fill = col or MECHA["TAB"]
        tcol = MECHA["TEXT_ON"] if col else U.INK
        tw = d.textlength(st, font=f.bebas_m)
        x = left
        hz = hazard(int(22 * s), h, max(8, int(14 * s)), MECHA["HAZ_A"], MECHA["HAZ_B"])
        if st == "FAIL":
            # the alert plate: hazard flanks either side of the word
            d._image.paste(hz, (x, y))
            x += int(26 * s)
        w = int(tw + 2 * int(18 * s))
        chamfer(d, (x, y, x + w, y + h), int(10 * s), fill=fill)
        d.text((x + w // 2, y + h // 2 + int(2 * s)), st, font=f.bebas_m, fill=tcol, anchor="mm")
        x += w
        if st == "FAIL":
            d._image.paste(hz, (x + int(4 * s), y))
            x += int(26 * s)
    else:
        fill, tcol = stamp_cols(U, col) if col else (KAWAII["CHIP"], U.INK)
        tw = d.textlength(st, font=f.comfy_m)
        mark = int(14 * s) if st in ("PASS", "OK", "FAIL") else 0
        w = int(tw + 2 * int(18 * s) + (mark + int(8 * s) if mark else 0))
        x = left
        d.rounded_rectangle([x, y, x + w, y + h], h // 2, fill=fill)
        tx = x + int(18 * s)
        if mark:
            cy = y + h // 2
            if st == "FAIL":
                cross_mark(d, tx + mark // 2, cy, mark * 0.38, tcol, max(2, int(3 * s)))
            else:
                check_mark(d, tx + mark // 2, cy, mark * 0.45, tcol, max(2, int(3 * s)))
            tx += mark + int(8 * s)
        d.text((tx, y + h // 2), st, font=f.comfy_m, fill=tcol, anchor="lm")
        x += w
    if text:
        d.text((x + int(20 * s), y + h // 2), text, font=scr.f_body, fill=U.INK, anchor="lm")


def choice(scr, U, d, it, left):
    s = scr.s
    f = fonts(scr, U)
    _, row, yes = it
    y = scr.row_y(row) - int(8 * s)
    h = int(46 * s)
    w = int(150 * s)
    scr.choice_boxes = []
    for i, (label, active, col) in enumerate((("YES", yes, U.PASS_), ("NO", not yes, U.FAIL_))):
        x = left + i * (w + int(20 * s))
        box = [x, y, x + w, y + h]
        scr.choice_boxes.append((i == 0, box))
        if U.SKIN == "mecha":
            if active:
                chamfer(d, box, int(12 * s), fill=col)
                d.text((x + w // 2, y + h // 2 + int(2 * s)), label, font=f.bebas_m,
                       fill=MECHA["TEXT_ON"], anchor="mm")
            else:
                chamfer(d, box, int(12 * s), outline=U.LINE, width=max(2, int(2 * s)))
                d.text((x + w // 2, y + h // 2 + int(2 * s)), label, font=f.bebas_m, fill=U.MUTED,
                       anchor="mm")
        else:
            if active:
                d.rounded_rectangle([x + int(4 * s), y + int(5 * s), x + w + int(4 * s), y + h + int(5 * s)],
                                    h // 2, fill=KAWAII["BACKING"])
                d.rounded_rectangle(box, h // 2, fill=col)
                d.text((x + w // 2, y + h // 2), label, font=f.comfy_m, fill=U.PAPER, anchor="mm")
            else:
                d.rounded_rectangle(box, h // 2, fill=U.PAPER, outline=U.LINE, width=max(2, int(2 * s)))
                d.text((x + w // 2, y + h // 2), label, font=f.comfy_m, fill=U.MUTED, anchor="mm")
    d.text((left + 2 * (w + int(20 * s)) + int(10 * s), y + h // 2),
           "arrows to change, Enter to confirm  -  or press Y / N",
           font=scr.f_small, fill=U.MUTED, anchor="lm")


def menu_row(scr, U, d, box, on, n, left, cy):
    """One menu row's ground and number; returns (name colour, desc colour)."""
    s = scr.s
    f = fonts(scr, U)
    if U.SKIN == "mecha":
        if on:
            chamfer(d, box, int(10 * s), fill=U.ACCENT)
            d.text((left, cy), "%02d" % n, font=scr.f_monob, fill=MECHA["TEXT_ON"], anchor="lm")
            return MECHA["TEXT_ON"], mix(MECHA["TEXT_ON"], U.ACCENT, 0.25)
        d.text((left, cy), "%02d" % n, font=scr.f_mono, fill=U.MUTED, anchor="lm")
        return U.INK, U.MUTED
    r = max(10, int(13 * s), int(f.mono_m.size * 0.62))
    px = left - int(2 * s)
    if on:
        x0, y0, x1, y1 = box
        hh = y1 - y0
        d.rounded_rectangle([x0 + int(4 * s), y0 + int(4 * s), x1 + int(4 * s), y1 + int(4 * s)], hh // 2,
                            fill=KAWAII["BACKING"])
        d.rounded_rectangle(box, hh // 2, fill=U.ACCENT)
        num_pill(d, U, f, px, cy, r, str(n), U.PAPER, U.ACCENT)
        # the description in plain white too: tinted toward the violet it
        # measured 4.17:1; the name is told apart by its bold weight
        return U.PAPER, U.PAPER
    num_pill(d, U, f, px, cy, r, str(n), KAWAII["BAND"], U.INK)
    return U.INK, U.MUTED


def hint(scr, U, d):
    if not scr.hint:
        return
    # Carlito in sentence case on both: the help line is read, not glanced at,
    # and 13 px mono capitals were the hardest words on the deck to make out
    y = scr.H - scr.ftr // 2
    d.text((scr.M + int(4 * scr.s), y), scr.hint, font=scr.f_small, fill=U.MUTED, anchor="lm")


def render(scr, U):
    """A card screen: the header, the card, the title, then every item at the
    rows the script gave it."""
    img = Image.new("RGB", (scr.W, scr.H), U.GROUND)
    d = ImageDraw.Draw(img)
    header(scr, U, img, d)
    x0, y0, x1, y1 = card(scr, U, d)
    tx = x0 + scr.pad
    if scr.title:
        title(scr, U, d, tx, y0, x1)
    for it in scr.items:
        k = it[0]
        if k == "bar":
            bar(scr, U, d, it, tx, x1 - scr.pad)
        elif k == "badge":
            badge(scr, U, d, it, tx)
        elif k == "choice":
            choice(scr, U, d, it, tx)
        else:
            scr._draw_item(d, it, tx, x1 - scr.pad)
    hint(scr, U, d)
    scr.fb.blit(img)


# ---------------------------------------------------------------- home grid
# Inside a tile: a band at the top for the number (and lamp or stamp), the
# name block at the bottom sized for the most lines any name needs, and the
# icon in what is left - which must stay a real icon, not a speck.
# Where the icon may start: on a bay only the corners of the top band are
# used (tab, lamp; the hazard strip ends 24 px down), so the icon may rise
# into its middle; a sticker's number and stamp can be wide, so it may not.
ICON_TOP = {"mecha": 30, "kawaii": 44}
BOTTOM_PAD = 10


ICON_MIN = 28        # px at scale 1: below this an icon stops being one
NAME_INSET = 12      # px at scale 1, both sides together: names sit low, clear of the corners


def _tile_fit(scr, U, d, labels, pw, ph):
    """The largest name font for this tile size where every name fits in two
    lines and the icon keeps its share of the tile (claimed before the name:
    at 1024x768 and at 150 % the names used to take it all) -> (font, lines,
    line height) and whether it fits at all. If nothing fits, the font that
    leaves the icon the most room."""
    s = scr.s
    avail = pw - int(NAME_INSET * s)
    top = int(ICON_TOP[U.SKIN] * s)
    need = max(ph * 0.30, ICON_MIN * s)
    sizes = fonts(scr, U).names[U.SKIN]
    best = None
    for nf in sizes:
        wraps = [scr._wrap2(d, lb, nf, avail) for lb in labels]
        if not all(d.textlength(t, font=nf) <= avail for w in wraps for t in w):
            continue
        nl = max(len(w) for w in wraps)
        lh = int(nf.size * 1.12)
        room = ph - top - nl * lh - int(BOTTOM_PAD * s)
        if room >= need:
            return nf, nl, lh, True
        if best is None or room > best[3]:
            best = (nf, nl, lh, room)
    if best is not None:
        return best[0], best[1], best[2], False
    nf = sizes[-1]
    return nf, 2, int(nf.size * 1.12), False


def _grid_layout(scr, U, n, labels):
    """Columns and tile size for the grid beside the status column: the
    biggest tiles where every name fits and the icons stay icons. The normal
    gutter first; a tighter one only when nothing fits with it."""
    s, W, H = scr.s, scr.W, scr.H
    d = ImageDraw.Draw(Image.new("L", (1, 1)))
    colw = int(W * 0.25)
    ax0 = scr.M
    ax1 = W - scr.M - colw - int(30 * s)
    ay0 = scr.hdr + int(78 * s)
    ay1 = H - scr.ftr
    best = None
    for gap in (22, 14):
        gx_ = gy_ = int(gap * s)
        for cols in range(2, 9):
            rows = (n + cols - 1) // cols
            pw = (ax1 - ax0 - (cols - 1) * gx_) // cols
            ph = min(int(pw * 0.9), (ay1 - ay0 - (rows - 1) * gy_) // rows)
            # a little wider than tall at most; 1.35 left 1024x768's Comfortaa
            # names at 12 px with width to spare beside the grid
            pw = min(pw, int(ph * 1.5))
            if pw <= 0 or ph <= 0:
                continue
            nf, nl, lh, fits = _tile_fit(scr, U, d, labels, pw, ph)
            key = (fits, pw * ph, nf.size)
            if best is None or key > best[0]:
                best = (key, cols, rows, pw, ph, nf, nl, lh, gx_, gy_)
        if best is not None and best[0][0]:
            break
    _, cols, rows, pw, ph, nf, nl, lh, gx_, gy_ = best
    # left-aligned under the heading; any spare width goes to the gap before
    # the status column, not split either side of the grid
    return (cols, pw, ph, ax0, ay0, gx_, gy_, (W - scr.M - colw, ay0 - int(8 * s), W - scr.M, ay1),
            (nf, nl, lh))


def _labels(U, entries):
    return [e[0].upper() if U.SKIN == "mecha" else e[0] for e in entries]


def grid_cols(scr, U, entries):
    return _grid_layout(scr, U, len(entries), _labels(U, entries))[0]


def render_grid(scr, U, sel, entries):
    img = Image.new("RGB", (scr.W, scr.H), U.GROUND)
    d = ImageDraw.Draw(img)
    s = scr.s
    f = fonts(scr, U)
    header(scr, U, img, d)
    labels = _labels(U, entries)
    cols, pw, ph, gx, gy, gapx, gapy, colbox, (nf, nl, lh) = _grid_layout(scr, U, len(entries), labels)
    if scr.title:
        ty = scr.hdr + int(40 * s)
        if U.SKIN == "mecha":
            spaced(d, (scr.M, ty), scr.title.upper(), f.bebas_xl, U.INK, max(1, int(1 * s)))
            d.text((colbox[0] - int(30 * s), ty), "%d BAYS" % len(entries), font=f.mono_m,
                   fill=U.MUTED, anchor="rm")
        else:
            d.text((scr.M, ty), scr.title, font=f.comfy_l, fill=U.INK, anchor="lm")
    scr.grid_boxes = []
    for i, e in enumerate(entries):
        x0 = gx + (i % cols) * (pw + gapx)
        y0 = gy + (i // cols) * (ph + gapy)
        box = (x0, y0, x0 + pw, y0 + ph)
        scr.grid_boxes.append(list(box))
        res = e[2] if len(e) > 2 else ""
        draw = _mecha_bay if U.SKIN == "mecha" else _kawaii_sticker
        draw(scr, U, img, d, box, i, labels[i], e[1], res, i == sel, nf, nl, lh)
    _status_column(scr, U, d, colbox, sel, entries)
    hint(scr, U, d)
    scr.fb.blit(img)


def _icon_and_name(scr, U, img, d, box, label, icon, icol, ncol, nf, nl, lh):
    """Name block at the bottom (nl lines), the icon centred in the rest."""
    s = scr.s
    x0, y0, x1, y1 = box
    pw, ph = x1 - x0, y1 - y0
    avail = pw - int(NAME_INSET * s)
    tb = y1 - int(BOTTOM_PAD * s) - nl * lh
    top = y0 + int(ICON_TOP[U.SKIN] * s)
    isz = max(int(12 * s), min(int((tb - top) * 0.86), int(pw * 0.36), int(ph * 0.36)))
    U._icon_smooth(icon, img, (x0 + x1) // 2, (top + tb) // 2, isz, icol)
    lines = scr._wrap2(d, label, nf, avail)
    ty = tb + (nl - len(lines)) * lh // 2 + lh // 2
    for k, ln in enumerate(lines):
        d.text(((x0 + x1) // 2, ty + k * lh), scr._clip(d, ln, nf, avail), font=nf, fill=ncol, anchor="mm")


def _mecha_bay(scr, U, img, d, box, i, label, icon, res, on, nf, nl, lh):
    s = scr.s
    f = fonts(scr, U)
    x0, y0, x1, y1 = box
    pw, ph = x1 - x0, y1 - y0
    cut = int(min(pw, ph) * 0.13)
    col = tone_of(res, U)
    # a failed bay is outlined red, so a FAIL is found from across the bench
    # without reading lamps; selection (orange) still wins
    edge = U.ACCENT if on else (U.FAIL_ if col == U.FAIL_ else U.LINE)
    chamfer(d, box, cut, fill=U.PAPER, outline=edge,
            width=max(3, int(3 * s)) if (on or col == U.FAIL_) else max(2, int(2 * s)))
    # the bay number on its tab, just past the cut corner
    num = "%02d" % (i + 1)
    tw = int(d.textlength(num, font=f.mono_m) + int(14 * s))
    th = int(24 * s)
    tx0, ty0 = x0 + cut + int(4 * s), y0 + int(8 * s)
    d.rectangle([tx0, ty0, tx0 + tw, ty0 + th], fill=U.ACCENT if on else MECHA["TAB"])
    d.text((tx0 + tw // 2, ty0 + th // 2), num, font=f.mono_m,
           fill=MECHA["TEXT_ON"] if on else U.MUTED, anchor="mm")
    # the status lamp in its bezel: unlit, green, amber or red
    lr = max(4, int(7 * s))
    br = lr + max(2, int(3 * s))
    lx, ly = x1 - int(18 * s), ty0 + th // 2
    d.ellipse([lx - br, ly - br, lx + br, ly + br], fill=MECHA["BAR"], outline=U.LINE,
              width=max(1, int(2 * s)))
    d.ellipse([lx - lr, ly - lr, lx + lr, ly + lr], fill=col or MECHA["TAB"])
    # selected: hazard stripes along the top, between the tab and the lamp
    if on:
        hx0, hx1 = tx0 + tw + int(10 * s), lx - br - int(8 * s)
        if hx1 - hx0 > int(20 * s):
            img.paste(hazard(hx1 - hx0, int(8 * s), max(8, int(12 * s)), MECHA["HAZ_A"], MECHA["HAZ_B"]),
                      (hx0, ty0 + th // 2 - int(4 * s)))
    col = U.ACCENT if on else U.INK
    _icon_and_name(scr, U, img, d, box, label, icon, col, col, nf, nl, lh)


def _kawaii_sticker(scr, U, img, d, box, i, label, icon, res, on, nf, nl, lh):
    s = scr.s
    f = fonts(scr, U)
    x0, y0, x1, y1 = box
    pw, ph = x1 - x0, y1 - y0
    r = int(min(pw, ph) * 0.16)
    o = int(8 * s) if on else int(5 * s)
    d.rounded_rectangle([x0 + o, y0 + o + int(1 * s), x1 + o, y1 + o + int(1 * s)], r, fill=KAWAII["BACKING"])
    if on:
        d.rounded_rectangle(box, r, fill=U.ACCENT, outline=KAWAII["SEL_EDGE"], width=max(2, int(2 * s)))
    else:
        d.rounded_rectangle(box, r, fill=U.PAPER, outline=U.LINE, width=max(2, int(2 * s)))
    # the number badge: round, a pill from 10 up
    br = max(10, int(14 * s), int(f.mono_m.size * 0.62))
    by = y0 + int(10 * s) + br
    num_pill(d, U, f, x0 + int(10 * s), by, br, str(i + 1),
             U.PAPER if on else KAWAII["BAND"], U.ACCENT if on else U.INK)
    # the result stamp, top right
    col = tone_of(res, U)
    if col:
        word = res.split()[0].upper()[:4]
        cw = int(d.textlength(word, font=f.comfy_xs) + int(16 * s))
        chh = max(int(22 * s), int(f.comfy_xs.size * 1.45))
        cx1, cy0 = x1 - int(10 * s), by - chh // 2
        sf, st = stamp_cols(U, col, on)
        d.rounded_rectangle([cx1 - cw, cy0, cx1, cy0 + chh], chh // 2, fill=sf)
        d.text((cx1 - cw // 2, cy0 + chh // 2), word, font=f.comfy_xs, fill=st, anchor="mm")
    # the icon in violet, the name in plum - both white on the selected sticker
    _icon_and_name(scr, U, img, d, box, label, icon, U.PAPER if on else U.ACCENT,
                   U.PAPER if on else U.INK, nf, nl, lh)
    if on:
        sparkle(d, x1 + int(2 * s), y1 + int(2 * s), int(13 * s), U.PAPER, KAWAII["STAR_EDGE"])


def _result_word(d, f, mecha, res, name, fi, room, chip_pad):
    """The status column's result word and its font. The test's name has the
    first claim on the row: a long result ("NOT TESTED") steps down a size,
    then to a short form, before the name is shortened."""
    word = res.split()[0].upper() if res else "-"
    if word == "NOT":
        word = "NOT TESTED"
    short = {"NOT TESTED": "N/T", "MARGINAL": "MARG", "PARTIAL": "PART", "STOPPED": "STOP"}
    big, small = (f.mono_m, f.mono_s) if mecha else (f.comfy_xs, f.comfy_xxs)
    namew = d.textlength(name, font=fi) + chip_pad
    for w, rf in ((word, big), (word, small), (short.get(word, word), small)):
        if namew + d.textlength(w, font=rf) <= room:
            return w, rf
    return short.get(word, word), small


def _status_column(scr, U, d, colbox, sel, entries):
    """Every test with its result this session - SYSTEM STATUS on the deck, the
    Checklist on the sticker sheet."""
    s = scr.s
    f = fonts(scr, U)
    x0, y0, x1, y1 = colbox
    mecha = U.SKIN == "mecha"
    if mecha:
        chamfer(d, colbox, int(18 * s), fill=U.PAPER, outline=U.LINE, width=max(2, int(2 * s)))
    else:
        r = int(22 * s)
        d.rounded_rectangle([x0 + int(6 * s), y0 + int(7 * s), x1 + int(6 * s), y1 + int(7 * s)], r,
                            fill=KAWAII["BACKING"])
        d.rounded_rectangle(colbox, r, fill=U.PAPER, outline=U.LINE, width=max(2, int(2 * s)))
    pad = int(16 * s)
    hf = f.bebas_m if mecha else f.comfy_m
    # centred far enough down that the heading clears the panel top at 150 %
    ty = y0 + int(12 * s) + int(hf.size * 0.55)
    if mecha:
        spaced(d, (x0 + pad, ty), "SYSTEM STATUS", hf, U.INK, max(1, int(1 * s)))
    else:
        d.text((x0 + pad, ty), "Checklist", font=hf, fill=U.INK, anchor="lm")
    top = ty + max(int(24 * s), int(hf.size * 0.5) + int(10 * s))
    rh = min(int(36 * s), (y1 - top - int(12 * s)) // max(1, len(entries)))
    fi = next((ft for ft in (scr.f_body, scr.f_small, scr.f_tiny) if ft.size * 1.15 <= rh), scr.f_tiny)
    # the name column starts after the widest number - at 150 % text a fixed
    # offset ran "10" into "Driver check"
    numw = d.textlength("%02d" % len(entries), font=f.mono_m) + int(10 * s)
    for i, e in enumerate(entries):
        on = i == sel
        res = e[2] if len(e) > 2 else ""
        y = top + i * rh
        cy = y + rh // 2
        if on:
            if mecha:
                # light enough that a red FAIL on it keeps 4.5:1
                d.rectangle([x0 + 2, y, x1 - 2, y + rh - 1], fill=mix(U.PAPER, U.ACCENT, 0.16))
            else:
                d.rounded_rectangle([x0 + int(6 * s), y + 1, x1 - int(6 * s), y + rh - 1], (rh - 2) // 2,
                                    fill=U.ACCENT)
        col = tone_of(res, U)
        if mecha:
            lr = max(3, int(5 * s))
            lx = x0 + pad + lr
            if col:
                d.ellipse([lx - lr, cy - lr, lx + lr, cy + lr], fill=col)
            else:
                d.ellipse([lx - lr, cy - lr, lx + lr, cy + lr], outline=U.LINE, width=1)
            nx = lx + lr + int(10 * s)
            d.text((nx, cy), "%02d" % (i + 1), font=f.mono_m,
                   fill=U.ACCENT if on else U.MUTED, anchor="lm")
            namex = nx + numw
            ncol = U.INK
        else:
            nx = x0 + pad
            d.text((nx, cy), "%d" % (i + 1), font=f.mono_m, fill=U.PAPER if on else U.MUTED, anchor="lm")
            namex = nx + numw
            ncol = U.PAPER if on else U.INK
        word, rf = _result_word(d, f, mecha, res, e[0], fi, x1 - pad - int(12 * s) - namex,
                                0 if mecha or not col else int(14 * s))
        rw = d.textlength(word, font=rf)
        if col and not mecha:
            chw = int(rw + int(14 * s))
            chh = max(int(18 * s), rh - int(10 * s))
            sf, st = stamp_cols(U, col, on)
            d.rounded_rectangle([x1 - pad - chw, cy - chh // 2, x1 - pad, cy + chh // 2], chh // 2, fill=sf)
            d.text((x1 - pad - chw // 2, cy), word, font=rf, fill=st, anchor="mm")
            rw = chw
        else:
            d.text((x1 - pad, cy), word, font=rf,
                   fill=(col or (U.PAPER if (on and not mecha) else U.MUTED)), anchor="rm")
        d.text((namex, cy), scr._clip(d, e[0], fi, x1 - pad - rw - int(12 * s) - namex), font=fi,
               fill=ncol, anchor="lm")


# ---------------------------------------------------------------- check
class _FB:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.last = None

    def blit(self, img):
        self.last = img


SAMPLE_GRID = [
    ("Full run", "play", ""), ("HDD / SSD", "disk", "PASS 09:12"), ("CPU", "cpu", "PASS 09:31"),
    ("RAM", "ram", "FAIL 09:40"), ("Battery", "battery", "WARN 10:02"), ("Keyboard", "keyboard", "FAIL 10:20"),
    ("Peripherals", "grid", ""), ("Show all tests", "expand", ""), ("Wi-Fi", "wifi", ""),
    ("Driver check", "download", "PASS 09:05"), ("DMI capture", "chip", ""), ("Results", "list", ""),
    ("Save report", "save", ""), ("Command prompt", "terminal", ""), ("System", "info", ""),
    ("Settings", "gear", ""), ("Error log", "log", "NOT TESTED"),
]
SAMPLE_MENU = [("1 minute", "quick sanity check"), ("5 minutes", "normal check"),
               ("10 minutes", "recommended when chasing a heat problem"), ("20 minutes", "thorough"),
               ("How this test works", "animated: the load, the heat, the cooler")]
SAMPLE_CARD = [
    ("badge", 6, "FAIL", "the wired connection does not work"),
    ("kv", 8, "Link", "enp0s31f6: yes, 100 Mbps full", "warn"),
    ("kv", 9, "Address", "192.168.1.23/24", "ok"),
    ("kv", 10, "Gateway", "192.168.1.1  0.6 ms avg, 1.2 ms worst, 0% lost", "ok"),
    ("kv", 11, "Wire errors", "14 during the test (crc_errors: 14)", "err"),
    ("line", 13, "Likely cause: linked at 100 Mbit/s although both ends can do 1000", "warn"),
    ("line", 14, "Gigabit needs all 8 wires: a broken pair in the cable or a bent pin.", ""),
    ("bar", 16, 62),
]


def screens(U, w, h, scale=1.0):
    """Every kind of screen a skin draws, as images."""
    U.TEXT_SCALE = scale
    scr = U.Screen(_FB(w, h))
    scr._build_fonts()
    scr.sub = "Dynabook Inc. TECRA A40-J\n11th Gen Intel(R) Core(TM) i7-1165G7 @ 2.80GHz - 15621 MB"
    out = []
    scr.title, scr.hint = "Choose a test", "arrows or its number, Enter to select      Q = power menu"
    scr.render_grid(3, SAMPLE_GRID)
    out.append(("home", scr.fb.last))
    scr.title, scr.hint = "CPU stress test - how long?", "arrows + ENTER, Q to go back"
    scr.items = [("menu", 2, SAMPLE_MENU)]
    scr.render()
    out.append(("menu", scr.fb.last))
    scr.title, scr.hint = "Ethernet network test finished", "Enter to go back"
    scr.items = list(SAMPLE_CARD)
    scr.render()
    out.append(("card", scr.fb.last))
    scr.title, scr.hint = "Full diagnostic run", "arrows or Y / N, Enter to confirm"
    scr.items = [("line", 6, "1.  System info, drivers, battery, SMART", ""),
                 ("line", 7, "2.  CPU stress and temperature log", ""),
                 ("badge", 9, "PASS", "reads cards"), ("badge", 11, "MARGINAL", "connects, not cleanly"),
                 ("choice", 14, True)]
    scr.render()
    out.append(("confirm", scr.fb.last))
    U.TEXT_SCALE = 1.0
    return out


def main(argv):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    os.environ.setdefault("DIAG_RUN", "/tmp/skincheck")
    os.makedirs(os.environ["DIAG_RUN"], exist_ok=True)
    import ui as U
    shots = argv[argv.index("--shots") + 1] if "--shots" in argv else None
    if not shots and "--check" not in argv:
        print(__doc__)
        return 2
    sizes = ((1280, 800), (1366, 768), (1920, 1080), (1024, 768))
    n = 0
    for skin in ("mecha", "kawaii"):
        U.apply_theme(skin)
        for (w, h) in sizes:
            for scale in ((1.0, 1.5) if (w, h) == (1366, 768) else (1.0,)):
                for name, img in screens(U, w, h, scale):
                    assert img is not None and img.size == (w, h), (skin, name, w, h)
                    n += 1
                    if shots:
                        os.makedirs(shots, exist_ok=True)
                        img.save(os.path.join(shots, "%s-%s-%dx%d%s.png" % (
                            skin, name, w, h, "" if scale == 1.0 else "-x%g" % scale)))
    U.apply_theme("light")
    print("skins: %d screens rendered OK" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
