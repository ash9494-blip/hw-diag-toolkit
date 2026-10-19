#!/usr/bin/env python3
"""On-screen languages (1.21): Settings -> Language.

The bash scripts and the renderer keep writing English. Every string the
renderer measures or draws passes through T() at the font - install() wraps
Pillow's FreeTypeFont.getmask2 / getbbox / getlength - so a word is measured
and drawn in the same language whichever path drew it, and no test script
changes. The tests' own logic still sees English (hwanim reads a test's
figures by their English kv labels), and the saved report stays English.

A string with Chinese, Japanese or Korean in it is drawn in Noto Sans CJK
(the face for the language in use), whatever font was asked for: Carlito,
DejaVu, Bebas and Comfortaa have no such glyphs, and PIL has no per-glyph
fallback - a missing glyph is a box.

Catalogues: toolkit/i18n/<lang>.json, {"English": "translation"}. A key may
hold {0}, {1}... where the script put a value ("Moving on in {0}s"): the
value is matched and put back, itself translated when it is a known phrase.
A string with no entry is cut at ": " and " - " and the parts tried alone,
then left in English. English (UK) is spelling rules, not a catalogue.

    python3 i18n.py --check            every catalogue loads and keeps its {n}s
    python3 i18n.py --try zh_CN "text"  what a string becomes
"""
import json
import os
import re
import sys

LANGS = [("en", "English"), ("en_GB", "English (UK)"), ("zh_CN", "简体中文"),
         ("zh_TW", "繁體中文"), ("ja", "日本語"), ("ko", "한국어")]
CAT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "i18n")

NOTO = {False: "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        True: "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"}
# face numbers inside the .ttc (checked against the noble package); +5 = mono
FACE = {"ja": 0, "ko": 1, "zh_CN": 2, "zh_TW": 3}
# CJK glyphs fill the em square, Latin capitals about 70 % of it: at the same
# size a CJK line looked a size larger than the English beside it
CJK_SCALE = 0.92

CJK = re.compile(r"[⺀-鿿　-ヿ㄰-㆏가-힯豈-﫿＀-￯]")
HANGUL = re.compile(r"[㄰-㆏가-힯]")
KANA = re.compile(r"[぀-ヿ]")
LETTERS = re.compile(r"[A-Za-z]{2}")
SEPARATORS = re.compile(r"(: | - |  +| / )")
# the full stop put back after a sentence matched without it
FULL_STOP = {"zh_CN": "。", "zh_TW": "。", "ja": "。"}

LANG = "en"
_exact = {}
_upper = {}
_patterns = {}          # first literal word -> [(regex, template)]
_cache = {}
_GB = {}


def _first_word(key):
    m = re.match(r"\s*([A-Za-z][A-Za-z'-]*)", key)
    return m.group(1).lower() if m else "*"


def _compile(key):
    parts = re.split(r"(\{\d+\})", key)
    rx = ""
    for i, p in enumerate(parts):
        if re.fullmatch(r"\{\d+\}", p):
            lazy = "" if i == len(parts) - 2 else "?"
            rx += "(?P<g%s>.+%s)" % (p[1:-1], lazy)
        else:
            rx += re.escape(p)
    return re.compile("^" + rx + "$")


def load(code):
    """Switch language; unknown codes mean English."""
    global LANG, _exact, _upper, _patterns, _cache
    LANG = code if code in dict(LANGS) else "en"
    _exact, _upper, _patterns, _cache = {}, {}, {}, {}
    if LANG in ("en", "en_GB"):
        return LANG
    try:
        with open(os.path.join(CAT_DIR, LANG + ".json"), encoding="utf-8") as f:
            cat = json.load(f)
    except (OSError, ValueError) as e:
        sys.stderr.write("i18n: no catalogue for %s (%s) - English\n" % (LANG, e))
        LANG = "en"
        return LANG
    for k, v in cat.items():
        if not v or k.startswith("_"):
            continue
        if re.search(r"\{\d+\}", k):
            try:
                _patterns.setdefault(_first_word(k), []).append((_compile(k), v))
            except re.error:
                continue
        else:
            _exact[k] = v
            # capitals and squeezed spacing find it too: the manual sheet
            # draws its hint as " ".join(hint.upper().split())
            _upper.setdefault(" ".join(k.upper().split()), v)
    # the longest keys first: "Moving on to the CPU test in {0}s" before "Moving on {0}"
    for lst in _patterns.values():
        lst.sort(key=lambda p: -len(p[0].pattern))
    return LANG


def _fill(template, m):
    out = template
    for name, val in m.groupdict().items():
        out = out.replace("{%s}" % name[1:], T(val))
    return out


def _one(core):
    hit = _exact.get(core)
    if hit is None:
        hit = _upper.get(" ".join(core.upper().split()))
    if hit is not None:
        return hit
    for bucket in (_first_word(core), "*"):
        for rx, tpl in _patterns.get(bucket, ()):
            m = rx.match(core)
            if m:
                return _fill(tpl, m)
    if core.isupper():          # a key matched in capitals ("CHOOSE A TEST")
        low = core.capitalize()
        for rx, tpl in _patterns.get(_first_word(low), ()):
            m = rx.match(low)
            if m:
                return _fill(tpl, m)
    return None


def _tr(s):
    if not LETTERS.search(s):
        return s
    if LANG == "en_GB":
        return s if CJK.search(s) else _gb(s)
    core = s.strip()
    lead, trail = s[:len(s) - len(s.lstrip())], s[len(s.rstrip()):]
    hit = _one(core)
    if hit is None and core.endswith(".") and not core.endswith(".."):
        # "...was not started from a USB stick." - a sentence built in the
        # script with its full stop; the catalogue has it without
        hit = _one(core[:-1])
        if hit is not None and hit[-1:] not in ".。!！?？":
            hit += FULL_STOP.get(LANG, ".")
    if hit is not None:
        return lead + hit + trail
    # Already translated (T runs at the cut and again at the font), or a name
    # in its own script. Whole matches above still count - "Now using: 简体中文
    # - Chinese (Simplified)" stayed English when any CJK skipped it (1.21) -
    # but never piecewise.
    if CJK.search(core):
        return s
    # "Problem: firmware missing - needs ..." - the parts alone
    parts = SEPARATORS.split(core)
    if len(parts) > 1:
        done, any_hit = [], False
        for p in parts:
            if SEPARATORS.fullmatch(p) or not LETTERS.search(p):
                done.append(p)
                continue
            h = _one(p.strip())
            if h is None and p.endswith("."):
                h = _one(p.strip()[:-1])
            any_hit = any_hit or h is not None
            done.append(p if h is None else h)
        if any_hit:
            return lead + "".join(done) + trail
    return s


def T(s):
    """The string in the language in use (itself when there is no entry)."""
    if LANG == "en" or not s or not isinstance(s, str):
        return s
    hit = _cache.get(s)
    if hit is None:
        if len(_cache) > 20000:
            _cache.clear()
        hit = _cache[s] = _tr(s)
    return hit


# ---------------------------------------------------------------- English (UK)
# Only the words that differ. "-ize" is not a rule: it would make "size" "sise".
for us, uk in (("color", "colour"), ("colors", "colours"), ("colored", "coloured"),
               ("gray", "grey"), ("center", "centre"), ("centered", "centred"),
               ("analyze", "analyse"), ("analyzes", "analyses"), ("analyzed", "analysed"),
               ("organize", "organise"), ("organized", "organised"),
               ("initialize", "initialise"), ("initialized", "initialised"),
               ("optimize", "optimise"), ("optimized", "optimised"),
               ("recognize", "recognise"), ("recognized", "recognised"),
               ("recognizes", "recognises"), ("behavior", "behaviour"),
               ("favorite", "favourite"), ("catalog", "catalogue"), ("fiber", "fibre"),
               ("aluminum", "aluminium"), ("license", "licence"), ("canceled", "cancelled"),
               ("canceling", "cancelling"), ("labeled", "labelled"), ("labeling", "labelling"),
               ("traveled", "travelled"), ("modeling", "modelling"), ("meter", "metre"),
               ("meters", "metres"), ("liter", "litre"),
               ("summarize", "summarise"), ("minimize", "minimise"), ("maximize", "maximise"),
               ("prioritize", "prioritise"), ("customize", "customise"),
               ("serialize", "serialise"), ("synchronize", "synchronise")):
    _GB[us] = uk
_GB_RX = re.compile(r"\b(" + "|".join(sorted(_GB, key=len, reverse=True)) + r")\b", re.I)


def _gb(s):
    def sub(m):
        w = m.group(0)
        uk = _GB[w.lower()]
        if w.isupper():
            return uk.upper()
        if w[0].isupper():
            return uk[0].upper() + uk[1:]
        return uk
    return _GB_RX.sub(sub, s)


# ---------------------------------------------------------------- the font hook
_alt_cache = {}


def _alt(font, text):
    """Noto Sans CJK standing in for `font` (same weight, size scaled)."""
    path = getattr(font, "path", "") or ""
    bold = "Bold" in path or "Bebas" in path
    face = FACE.get(LANG)
    if face is None:
        face = 1 if HANGUL.search(text) else 0 if KANA.search(text) else 2
    if "Mono" in path:
        face += 5
    key = (bold, face, font.size)
    f = _alt_cache.get(key)
    if f is None:
        from PIL import ImageFont
        try:
            f = ImageFont.truetype(NOTO[bold], max(6, int(round(font.size * CJK_SCALE))), index=face)
        except OSError:
            f = False
        _alt_cache[key] = f
    return f or None


def install():
    """Wrap Pillow's text methods once: T() first, Noto for CJK text."""
    from PIL import ImageFont
    F = ImageFont.FreeTypeFont
    if getattr(F, "_diag_i18n", False):
        return
    for name in ("getmask2", "getbbox", "getlength"):
        orig = getattr(F, name)

        def wrapped(self, text, *a, _orig=orig, _name=name, **k):
            key = None
            if isinstance(text, str) and text:
                text = T(text)
                # Widths are asked for over and over (3,200 per redraw of the
                # home sheet - the pointer froze 150 ms on every tile it
                # crossed, 1.22). Keyed by the font file, size and face, so a
                # text-size change rebuilding the fonts can never hit a stale
                # one, and by language: the same Han text takes the Japanese
                # face in ja and the Chinese one in zh_CN - different widths.
                if _name == "getlength" and not a and not k:
                    key = (LANG, getattr(self, "path", None), self.size, getattr(self, "index", 0), text)
                    hit = _len_cache.get(key)
                    if hit is not None:
                        return hit
                if CJK.search(text) and not getattr(self, "_diag_cjk", False):
                    alt = _alt(self, text)
                    if alt is not None:
                        alt._diag_cjk = True
                        out = _orig(alt, text, *a, **k)
                        if key is not None:
                            _len_put(key, out)
                        return out
            out = _orig(self, text, *a, **k)
            if key is not None:
                _len_put(key, out)
            return out
        setattr(F, name, wrapped)
    F._diag_i18n = True


_len_cache = {}


def _len_put(key, value):
    if len(_len_cache) > 50000:
        _len_cache.clear()
    _len_cache[key] = value


_HANJA = r"⺀-鿿　-ヿ豈-﫿＀-￯"   # Chinese, kana, CJK punctuation
# closing marks ride with the unit before them, so a line never starts with
# one - the home hint wrapped as "...两位数" / "），按 Enter" (1.21):
# 、。，．：；！？）］｝〕〉》」』】ー・
_CLOSE = ("、。，．：；！？）］｝"
          "〕〉》」』】ー・")
_UNIT = re.compile("(?:[" + _HANJA + "]|[^\\s" + _HANJA + "]+)[" + _CLOSE + "]*\\s*")


def tokens(text):
    """Units a line may break between: words, and each Chinese / Japanese
    character on its own (they need no space to break). Korean breaks at
    spaces, like English. Each unit keeps the spaces written after it, so
    join() puts back exactly what was there - guessing them dropped the
    space in a file name ("报告 2025.docx" drew as "报告2025.docx", 1.21)."""
    return _UNIT.findall(text.strip())


def join(units):
    """The units back into a line as they were written, with no space left
    hanging where the line was broken. Join a list of units, never a line
    already joined plus the next unit - its trailing space is gone."""
    return "".join(units).strip()


# ---------------------------------------------------------------- check
def _check():
    bad = 0
    for code, _ in LANGS:
        if code in ("en", "en_GB"):
            continue
        p = os.path.join(CAT_DIR, code + ".json")
        try:
            with open(p, encoding="utf-8") as f:
                cat = json.load(f)
        except (OSError, ValueError) as e:
            print("i18n: %s: %s" % (code, e)); bad += 1
            continue
        for k, v in cat.items():
            if k.startswith("_") or not v:
                continue
            if sorted(re.findall(r"\{\d+\}", v)) != sorted(re.findall(r"\{\d+\}", k)):
                print("i18n: %s: placeholders differ: %r -> %r" % (code, k, v)); bad += 1
        load(code)
        n = len(_exact) + sum(map(len, _patterns.values()))
        print("i18n: %s: %d strings translated" % (code, n))
    load("en")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(_check())
    if len(sys.argv) > 2 and sys.argv[1] == "--try":
        load(sys.argv[2])
        for s in sys.argv[3:]:
            print("%r -> %r" % (s, T(s)))
        sys.exit(0)
    print(__doc__)
