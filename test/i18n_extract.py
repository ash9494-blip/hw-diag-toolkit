#!/usr/bin/env python3
"""Every English string the toolkit can put on screen, for the language
catalogues (toolkit/i18n/<lang>.json).

Shell scripts: quoted literals, with $var / ${var} / $(...) / printf %s turned
into {0} {1}... Python screens: string constants, %s / {} / f-string values
likewise. Menu cells ("name|desc|col") are split at "|". Code-looking strings
(commands, paths, awk / sed programs, tone names) are dropped; what is left
over and is not UI text costs a translation and is never drawn.

    python3 test/i18n_extract.py --count            how many, per file
    python3 test/i18n_extract.py > strings.json     all of them, sorted
    python3 test/i18n_extract.py --merge toolkit/i18n/zh_CN.json
                                  -> the keys that catalogue does not have yet
"""
import ast
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "toolkit")
SKIP_SH = {"tui-text.sh", "start-ui.sh"}
SKIP_PY = {"i18n.py", "imgplan.py"}
CODE = re.compile(r"""(^[-+]|/dev/|/sys/|/proc/|/opt/|/usr/|/run/|/tmp/|/etc/|/lib/|\.ko\b|\\[ntd0]|
                      [;`]|==|&&|\|\||=~|\$\(|\bprintf\b|\bawk\b|\bsed\b|\bgrep\b|^\^|\$[0-9]|
                      \bNR\b|\bNF\b|^\s*\[|\]\s*$|^[a-z_][a-z0-9_]*=|^[A-Z_]+=|%[0-9]*[a-z]\s*$|
                      ^\.|\.(sh|py|conf|log|json|txt|png|deb|ko|bin|ucode)$|^[a-z0-9_.-]+$)""", re.X)
WORD = re.compile(r"[A-Za-z]{2,}")


# Single lowercase words that are the renderer's own vocabulary (tones, keys,
# protocol commands, setting values), never shown as words.
NOT_WORDS = set("""ok warn err muted accent fg dim enter esc space click back hover wheelup
wheeldown menu gridmenu line kv badge bar flush frame setting anykey waitkey pager theme look
lang textscale light dark contrast mecha kawaii manual classic compact card grid bold regular
mono left right top bottom true false utf-8 replace rgb rgba sub title hint items thead trow
para diskmap msg confirm choice anim live stop quiet auto wired wifi pci usb acpi i2c net audio
input video hci bt""".split())


def one_word(s):
    """A lone lowercase word that is screen text ("thorough", "connected")."""
    s = s.strip()
    return bool(re.fullmatch(r"[a-z][a-z-]{2,}", s)) and s not in NOT_WORDS


def ui_like(s):
    s = s.strip()
    if len(s) < 2 or len(s) > 400 or not WORD.search(s) or "\n" in s:
        return False
    if s.count("(") != s.count(")") or "::" in s or re.search(r"\[[0-9a-z]-[0-9a-z]\]", s):
        return False                                    # code fragments, regexes
    if " " not in s and "/" in s and not re.fullmatch(r"[A-Z]/[A-Z]", s):
        return False                                    # paths ("{0}/energy_full")
    if re.search(r"\S {2,}: ", s):                      # report columns ("Model    : {0}")
        return False
    if re.fullmatch(r"\{\d+\}", s):
        return False
    if CODE.search(s):
        # a sentence with a path in it is still a sentence
        if not (" " in s and re.search(r"[A-Z][a-z]+ [a-z]+", s) and not re.search(r"[;`]|==|&&|\$\(", s)):
            return False
    if re.fullmatch(r"[a-z][a-z0-9_-]*", s):          # tone names, commands, keys
        return False
    if re.search(r"[{}]", re.sub(r"\{\d+\}", "", s)):
        return False
    return True


class Counter:
    """{0}, {1}... in order of appearance."""
    def __init__(self):
        self.n = 0

    def __call__(self, _m=None):
        self.n += 1
        return "{%d}" % (self.n - 1)


# ---------------------------------------------------------------- shell
def sh_placeholders(s):
    ph = Counter()
    # $(...) with one level of nesting, ${...}, $((...)), $var, printf %s %d %5.1f
    s = re.sub(r"\$\((?:[^()]|\([^()]*\))*\)", ph, s)
    s = re.sub(r"\$\{(?:[^{}]|\$\{[^{}]*\})*\}", ph, s)    # ${got:-${src##*/}} too
    s = re.sub(r"\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9#?@*]", ph, s)
    s = re.sub(r"%-?[0-9.]*[sdfgx]", ph, s)
    return s.replace("%%", "%")


def sh_literals(text):
    """Quoted strings in a shell script (comments skipped)."""
    out, i, L = [], 0, len(text)
    while i < L:
        c = text[i]
        if c == "#" and (i == 0 or text[i - 1] in " \t\n;"):
            j = text.find("\n", i)
            i = L if j < 0 else j
            continue
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                break
            out.append((text[i + 1:j], i))
            i = j + 1
            continue
        if c == '"':
            j, depth = i + 1, 0
            while j < L:
                if text[j] == "\\":
                    j += 2
                    continue
                if text.startswith("$(", j):
                    depth += 1
                    j += 2
                    continue
                if text[j] == ")" and depth:
                    depth -= 1
                elif text[j] == '"' and not depth:
                    break
                j += 1
            body = text[i + 1:j]
            out.append((body, i))
            if "$(" in body:
                # "$(... || echo "This image holds no partition...")": the
                # quoted text inside the $(...) is drawn too (1.21)
                out.extend((s, i) for s, _ in sh_literals(body))
            i = j + 1
            continue
        i += 1
    return out


# "${v:-not reported by the firmware}", "${ver:+  (version $ver)}": the text
# inside is drawn too, but the whole ${...} became one {n} (1.21)
SH_DEFAULT = re.compile(r"\$\{[A-Za-z_]\w*:?[-+]((?:[^{}]|\$\{[^{}]*\})*)\}")

# Drawn, but the scan cannot see it: a lone word kept in a variable and shown
# as a menu cell (one_word trusts only tui_ lines and literal cells).
EXTRA = {
    "inside": "imglib.sh",      # pick_drive: where the drive is (or "USB")
    "built-in": "gputest.sh",   # G_KIND: which GPU it is
    "discrete": "gputest.sh",
}

# Lines that only write the report or a log: the report stays English.
REPORT_LINE = re.compile(r"^\s*(rsilent|rsection|set_kv|rlog|log|dbg)\b|>>\s*\"?\$(REPORT_TXT|RUN_DIR|LOG)|>&2\s*$")


def from_sh(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = "\n".join("" if REPORT_LINE.search(l) else l for l in f.read().split("\n"))
    found = []
    lines = text.split("\n")
    for lit, at in sh_literals(text):
        if lit.count("\n") > 2:                          # awk / python programs
            continue
        line = lines[text.count("\n", 0, at)]
        cells = lit.split("|") if "|" in lit and "||" not in lit else [lit]
        # a lone word counts only where it is clearly drawn: a tui_ call or a menu cell
        words_ok = "tui_" in line or len(cells) > 1
        for inner in SH_DEFAULT.findall(lit):
            s = sh_placeholders(inner).replace('\\"', '"').replace("\\$", "$")
            if ui_like(s):
                found.append(s.strip())
        for cell in cells:
            s = sh_placeholders(cell).replace('\\"', '"').replace("\\$", "$")
            if ui_like(s) or (words_ok and one_word(s)):
                found.append(s.strip())
    return found


# ---------------------------------------------------------------- python
def py_fmt(s):
    ph = Counter()
    s = re.sub(r"%-?[0-9.]*[sdfgxr]", ph, s)
    s = re.sub(r"\{[^{}]*\}", ph, s)
    return s.replace("%%", "%")


def from_py(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        tree = ast.parse(f.read())
    found = []
    docs = set()        # docstrings are notes for the next programmer, not screen text
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.ClassDef, ast.AsyncFunctionDef)) \
                and node.body and isinstance(node.body[0], ast.Expr) \
                and isinstance(node.body[0].value, ast.Constant):
            docs.add(id(node.body[0].value))
    for node in ast.walk(tree):
        if id(node) in docs:
            continue
        if isinstance(node, ast.JoinedStr):
            ph, parts = Counter(), []
            for v in node.values:
                if isinstance(v, ast.Constant) and isinstance(v.value, str):
                    parts.append(v.value)
                else:
                    parts.append(ph())
            s = "".join(parts)
            if ui_like(s):
                found.append(s.strip())
        elif isinstance(node, ast.Constant) and isinstance(node.value, str):
            v = node.value
            if v.count("\n") > 2:                       # docstrings
                continue
            for cell in (v.split("|") if "|" in v else [v]):
                s = py_fmt(cell)
                if (ui_like(s) or one_word(s) or prose(s)) and not s.startswith(("ui:", "i18n:")):
                    found.append(s.strip())
    return found


def prose(s):
    """A Python sentence with "; " in it - ui_like drops every ";" as shell
    code, and mrimg.py's reasons ("an incremental or differential image -
    only full images open here; restore it with Macrium...") never reached
    the catalogues (1.23)."""
    parts = s.strip().split("; ")
    return len(parts) > 1 and all(ui_like(p) for p in parts) \
        and len(WORD.findall(s)) >= 5


def collect():
    seen = {}
    for name in sorted(os.listdir(ROOT)):
        p = os.path.join(ROOT, name)
        try:
            if name.endswith(".sh") and name not in SKIP_SH:
                got = from_sh(p)
            elif name.endswith(".py") and name not in SKIP_PY:
                got = from_py(p)
            else:
                continue
        except (SyntaxError, UnicodeDecodeError) as e:
            sys.stderr.write("skip %s: %s\n" % (name, e))
            continue
        for s in got:
            seen.setdefault(s, name)
    for s, name in EXTRA.items():
        seen.setdefault(s, name)
    return seen


if __name__ == "__main__":
    strings = collect()
    if "--merge" in sys.argv:
        cat = sys.argv[sys.argv.index("--merge") + 1]
        try:
            with open(cat, encoding="utf-8") as f:
                have = json.load(f)
        except OSError:
            have = {}
        todo = {k: v for k, v in strings.items() if k not in have}
        json.dump(todo, sys.stdout, ensure_ascii=False, indent=0, sort_keys=True)
    elif "--count" in sys.argv:
        by = {}
        for s, f in strings.items():
            by[f] = by.get(f, 0) + 1
        for f, n in sorted(by.items(), key=lambda x: -x[1]):
            print("%5d  %s" % (n, f))
        print("%5d  total" % len(strings))
    else:
        json.dump(strings, sys.stdout, ensure_ascii=False, indent=0, sort_keys=True)
