#!/usr/bin/env python3
"""Contrast and dark-only check for the design tokens.

Usage: python3 -I scripts/check-contrast.py assets/css/tokens.css [more.css ...]

With a single argument, main.css beside it is scanned too when it exists.
Stdlib only. Contrast uses the WCAG 2.2 relative luminance formula.

Checks (each failure prints one line starting with its tag):
  MISSING-TOKEN      a required color token is not defined
  UNPARSEABLE-COLOR  a color token is not a 3 or 6 digit hex value
  LOW-CONTRAST       a required pair is below its ratio
  FORBIDDEN-TOKEN    a file after the first redefines a required token
  LIGHT-MEDIA        a prefers-color-scheme query other than dark (or negated)
  COLOR-SCHEME-LIGHT a color-scheme value contains light
  WHITE-FILL         near-white in background, background-color, background-image
  NEAR-WHITE-TOKEN   near-white in a bg, surface or background custom property
  VAR-CYCLE          var() indirection cycles or nests deeper than 8
  IMPORT             @import (CSS must be self-contained)
A near-white value is allowed for the --text token only. CSS comments are
stripped and CSS escapes are decoded before any matching.
"""
import colorsys
import os
import re
import sys

REQUIRED = ["accent", "on-accent", "bg", "surface", "text", "muted", "link", "focus"]
# (foreground, background, minimum ratio)
PAIRS = [
    ("text", "bg", 4.5),
    ("text", "surface", 4.5),
    ("muted", "bg", 4.5),
    ("muted", "surface", 4.5),
    ("link", "bg", 4.5),
    ("on-accent", "accent", 4.5),
    ("focus", "bg", 3.0),
]
NAMED_WHITE = ["white", "ivory", "snow", "whitesmoke", "ghostwhite", "floralwhite",
               "mintcream", "azure", "aliceblue", "honeydew", "lavenderblush"]
MAX_DEPTH = 8

HEX_RE = re.compile(r"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")
VALUE = r"((?:url\([^)]*\)|[^;}])*)"
TOKEN_RE = re.compile(r"(--[A-Za-z0-9_-]+)\s*:\s*" + VALUE)
BG_DECL_RE = re.compile(r"(?<![\w-])background(?:-color|-image)?\s*:\s*" + VALUE, re.I)
HEX_ANY_RE = re.compile(r"#([0-9a-fA-F]+)(?![\w-])")
FUNC_RE = re.compile(r"(rgba?|hsla?)\(([^()]*)\)", re.I)
NAMED_RE = re.compile(r"(?<![\w-])(%s)(?![\w-])" % "|".join(NAMED_WHITE), re.I)
IMPORTANT_RE = re.compile(r"\s*!\s*important\s*$", re.I)


class ResolveError(Exception):
    pass


def strip_comments(text):
    return re.sub(r"/\*.*?\*/", "", text, flags=re.S)


def decode_escapes(css):
    """Decode CSS escapes: hex escapes (1 to 6 digits, optional space), then single-char."""
    def hexrep(m):
        cp = int(m.group(1), 16)
        if cp == 0 or cp > 0x10FFFF or 0xD800 <= cp <= 0xDFFF:
            return "\ufffd"
        return chr(cp)
    css = re.sub(r"\\([0-9a-fA-F]{1,6})(?:\r\n|[ \t\r\n\f])?", hexrep, css)
    return re.sub(r"\\([^\n\r\f])", r"\1", css)


def parse_hex(value):
    m = HEX_RE.match(value.strip())
    if not m:
        return None
    h = m.group(1)
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def luminance(rgb):
    def lin(c):
        c = c / 255.0
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def _num(tok):
    """Number 0-255, or a percentage mapped onto 0-255."""
    if tok.endswith("%"):
        return float(tok[:-1]) * 255.0 / 100.0
    return float(tok)


def near_white(value):
    """True when value holds a color whose channels are all at least 0xF0.

    Forms: hex of 3, 4, 6 or 8 digits (alpha ignored), rgb()/rgba() in comma or
    space syntax with numbers or percentages, hsl()/hsla() (lightness 94% or
    more, or channels that convert to near-white), and near-white named colors.
    """
    if NAMED_RE.search(value):
        return True
    for m in HEX_ANY_RE.finditer(value):
        h = m.group(1)
        if len(h) in (3, 4):
            chans = [int(c * 2, 16) for c in h[:3]]
        elif len(h) in (6, 8):
            chans = [int(h[i:i + 2], 16) for i in (0, 2, 4)]
        else:
            continue
        if all(c >= 0xF0 for c in chans):
            return True
    for m in FUNC_RE.finditer(value):
        kind = m.group(1).lower()
        args = [a for a in re.split(r"[,\s/]+", m.group(2).strip()) if a]
        if len(args) < 3:
            continue
        try:
            if kind.startswith("rgb"):
                if all(_num(a) >= 0xF0 for a in args[:3]):
                    return True
            else:
                light = float(args[2].rstrip("%"))
                if light >= 94.0:
                    return True
                hue = float(re.sub(r"[a-zA-Z]+$", "", args[0]))
                sat = float(args[1].rstrip("%"))
                r, g, b = colorsys.hls_to_rgb((hue % 360.0) / 360.0, light / 100.0, sat / 100.0)
                if all(c * 255.0 >= 0xF0 for c in (r, g, b)):
                    return True
        except ValueError:
            continue
    return False


def resolve(value, vars_, depth=0):
    """Replace var(--name[, fallback]) with its value; fail closed on cycles."""
    if depth > MAX_DEPTH:
        raise ResolveError("var() nesting exceeds %d or cycles" % MAX_DEPTH)
    out = []
    i = 0
    low = value.lower()
    while True:
        j = low.find("var(", i)
        if j < 0:
            out.append(value[i:])
            break
        out.append(value[i:j])
        k = j + 4
        level = 1
        while k < len(value) and level:
            if value[k] == "(":
                level += 1
            elif value[k] == ")":
                level -= 1
            k += 1
        inner = value[j + 4:k - 1] if level == 0 else value[j + 4:]
        comma, level2 = -1, 0
        for idx, ch in enumerate(inner):
            if ch == "(":
                level2 += 1
            elif ch == ")":
                level2 -= 1
            elif ch == "," and level2 == 0:
                comma = idx
                break
        name = (inner if comma < 0 else inner[:comma]).strip()
        fallback = None if comma < 0 else inner[comma + 1:]
        if name in vars_:
            out.append(resolve(vars_[name], vars_, depth + 1))
        elif fallback is not None:
            out.append(resolve(fallback, vars_, depth + 1))
        i = k
    return "".join(out)


def clean_value(value):
    return IMPORTANT_RE.sub("", value.strip()).strip()


def token_map(css):
    return {name: clean_value(value) for name, value in TOKEN_RE.findall(css)}


def check_tokens(tokens, errors):
    colors = {}
    for name in REQUIRED:
        key = "--" + name
        if key not in tokens:
            errors.append("MISSING-TOKEN: required color token --%s is not defined" % name)
            continue
        rgb = parse_hex(tokens[key])
        if rgb is None:
            errors.append("UNPARSEABLE-COLOR: --%s value %r is not a 3 or 6 digit hex color"
                          % (name, tokens[key]))
            continue
        colors[name] = rgb
    for key, value in tokens.items():
        if key[2:] in REQUIRED:
            continue
        if value.startswith("#") and parse_hex(value) is None:
            errors.append("UNPARSEABLE-COLOR: %s value %r is not a 3 or 6 digit hex color"
                          % (key, value))
    for fg, bg, minimum in PAIRS:
        if fg in colors and bg in colors:
            r = ratio(colors[fg], colors[bg])
            if r < minimum:
                errors.append("LOW-CONTRAST: --%s on --%s is %.2f:1, needs %.1f:1"
                              % (fg, bg, r, minimum))


def check_dark_only(path, css, vars_, errors):
    for m in re.finditer(r"prefers-color-scheme\s*(?::\s*([\w-]*))?", css, re.I):
        value = (m.group(1) or "").lower()
        if value != "dark":
            errors.append("LIGHT-MEDIA: %s uses a prefers-color-scheme query other than dark (%s)"
                          % (path, m.group(0).strip()))
    if re.search(r"@media[^{]*\bnot\b[^{]*prefers-color-scheme", css, re.I):
        errors.append("LIGHT-MEDIA: %s negates a prefers-color-scheme query" % path)
    for m in re.finditer(r"(?<![\w-])color-scheme\s*:\s*([^;}]*)", css, re.I):
        if re.search(r"\blight\b", m.group(1), re.I):
            errors.append("COLOR-SCHEME-LIGHT: %s has color-scheme value %r" % (path, m.group(1).strip()))
    if re.search(r"@import\b", css, re.I):
        errors.append("IMPORT: %s uses @import; CSS must be self-contained" % path)
    for m in BG_DECL_RE.finditer(css):
        try:
            resolved = resolve(m.group(1), vars_)
        except ResolveError as e:
            errors.append("VAR-CYCLE: %s %s in: %s" % (path, e, m.group(0).strip()))
            continue
        if near_white(resolved):
            errors.append("WHITE-FILL: %s has a white or near-white background: %s"
                          % (path, m.group(0).strip()))
    for name, value in TOKEN_RE.findall(css):
        lname = name.lower()
        if lname == "--text":
            continue
        if any(k in lname for k in ("bg", "surface", "background")):
            try:
                resolved = resolve(clean_value(value), vars_)
            except ResolveError as e:
                errors.append("VAR-CYCLE: %s %s in token %s" % (path, e, name))
                continue
            if near_white(resolved):
                errors.append("NEAR-WHITE-TOKEN: %s token %s is white or near-white (%s)"
                              % (path, name, clean_value(value)))


def main(argv):
    if not argv:
        print("usage: check-contrast.py tokens.css [more.css ...]", file=sys.stderr)
        return 2
    paths = list(argv)
    if len(paths) == 1:
        sibling = os.path.join(os.path.dirname(paths[0]), "main.css")
        if os.path.isfile(sibling):
            paths.append(sibling)
    sheets = []
    for p in paths:
        try:
            with open(p, encoding="utf-8") as f:
                raw = f.read()
        except OSError as e:
            print("FAIL: cannot read %s: %s" % (p, e), file=sys.stderr)
            return 2
        except ValueError:
            print("FAIL: cannot read %s: not valid UTF-8" % p, file=sys.stderr)
            return 2
        sheets.append(decode_escapes(strip_comments(raw)))
    vars_ = {}
    for css in sheets:
        vars_.update(token_map(css))
    errors = []
    for i, (p, css) in enumerate(zip(paths, sheets)):
        check_dark_only(p, css, vars_, errors)
        if i > 0:
            for name in token_map(css):
                if name[2:] in REQUIRED:
                    errors.append("FORBIDDEN-TOKEN: %s defines %s; required contrast tokens "
                                  "belong only in %s" % (p, name, paths[0]))
    check_tokens(token_map(sheets[0]), errors)
    if errors:
        for e in errors:
            print("FAIL: " + e, file=sys.stderr)
        return 1
    print("PASS: contrast and dark-only checks ok (%s)" % ", ".join(paths))
    return 0


if __name__ == "__main__":
    try:
        code = main(sys.argv[1:])
    except Exception as exc:  # fail closed: a crash must never read as a pass
        print("checker error: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        code = 70
    sys.exit(code)
