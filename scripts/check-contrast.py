#!/usr/bin/env python3
"""Contrast and dark-only check for the design tokens.

Usage: python3 -I scripts/check-contrast.py assets/css/tokens.css [more.css ...]

With a single argument, main.css beside it is scanned too when it exists.
Stdlib only. Contrast uses the WCAG 2.2 relative luminance formula.

Checks (each failure prints one line starting with its tag):
  MISSING-TOKEN     a required color token is not defined
  UNPARSEABLE-COLOR a color token is not a 3 or 6 digit hex value
  LOW-CONTRAST      a required pair is below its ratio
  LIGHT-MEDIA       prefers-color-scheme: light appears
  COLOR-SCHEME-LIGHT a color-scheme value contains light
  WHITE-FILL        white or near-white in a background declaration
  NEAR-WHITE-TOKEN  white or near-white in a bg, surface or background token
A near-white value is allowed for the --text token only.
"""
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
HEX_RE = re.compile(r"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")
TOKEN_RE = re.compile(r"(--[A-Za-z0-9_-]+)\s*:\s*([^;}]*)")
BG_DECL_RE = re.compile(r"(?<![\w-])background(?:-color)?\s*:\s*([^;}]*)", re.I)
HEX_ANY_RE = re.compile(r"#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b")
RGB_WHITE_RE = re.compile(r"rgba?\(\s*255\s*[, ]\s*255\s*[, ]\s*255\b", re.I)
WHITE_KW_RE = re.compile(r"(?<![\w-])white(?![\w-])", re.I)


def strip_comments(text):
    return re.sub(r"/\*.*?\*/", "", text, flags=re.S)


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


def has_white(value):
    """True for keyword white, rgb(255,255,255), or a hex with all channels >= 0xF0."""
    if WHITE_KW_RE.search(value) or RGB_WHITE_RE.search(value):
        return True
    for m in HEX_ANY_RE.finditer(value):
        rgb = parse_hex("#" + m.group(1))
        if rgb and all(c >= 0xF0 for c in rgb):
            return True
    return False


def check_tokens(css, errors):
    tokens = {}
    for name, value in TOKEN_RE.findall(css):
        tokens[name[2:]] = value.strip()
    colors = {}
    for name in REQUIRED:
        if name not in tokens:
            errors.append("MISSING-TOKEN: required color token --%s is not defined" % name)
            continue
        rgb = parse_hex(tokens[name])
        if rgb is None:
            errors.append("UNPARSEABLE-COLOR: --%s value %r is not a 3 or 6 digit hex color"
                          % (name, tokens[name]))
            continue
        colors[name] = rgb
    for name, value in tokens.items():
        if name in REQUIRED:
            continue
        if value.startswith("#") and parse_hex(value) is None:
            errors.append("UNPARSEABLE-COLOR: --%s value %r is not a 3 or 6 digit hex color"
                          % (name, value))
    for fg, bg, minimum in PAIRS:
        if fg in colors and bg in colors:
            r = ratio(colors[fg], colors[bg])
            if r < minimum:
                errors.append("LOW-CONTRAST: --%s on --%s is %.2f:1, needs %.1f:1"
                              % (fg, bg, r, minimum))
    return tokens


def check_dark_only(path, css, errors):
    if re.search(r"prefers-color-scheme\s*:\s*light", css, re.I):
        errors.append("LIGHT-MEDIA: %s uses prefers-color-scheme: light" % path)
    for m in re.finditer(r"(?<![\w-])color-scheme\s*:\s*([^;}]*)", css, re.I):
        if re.search(r"\blight\b", m.group(1), re.I):
            errors.append("COLOR-SCHEME-LIGHT: %s has color-scheme value %r" % (path, m.group(1).strip()))
    for m in BG_DECL_RE.finditer(css):
        if has_white(m.group(1)):
            errors.append("WHITE-FILL: %s has a white or near-white background: %s"
                          % (path, m.group(0).strip()))
    for name, value in TOKEN_RE.findall(css):
        lname = name.lower()
        if lname == "--text":
            continue
        if any(k in lname for k in ("bg", "surface", "background")) and has_white(value):
            errors.append("NEAR-WHITE-TOKEN: %s token %s is white or near-white (%s)"
                          % (path, name, value.strip()))


def main(argv):
    if not argv:
        print("usage: check-contrast.py tokens.css [more.css ...]", file=sys.stderr)
        return 2
    paths = list(argv)
    if len(paths) == 1:
        sibling = os.path.join(os.path.dirname(paths[0]), "main.css")
        if os.path.isfile(sibling):
            paths.append(sibling)
    errors = []
    tokens_css = None
    for i, p in enumerate(paths):
        try:
            with open(p, encoding="utf-8") as f:
                css = strip_comments(f.read())
        except OSError as e:
            print("FAIL: cannot read %s: %s" % (p, e), file=sys.stderr)
            return 2
        if i == 0:
            tokens_css = css
        check_dark_only(p, css, errors)
    check_tokens(tokens_css, errors)
    if errors:
        for e in errors:
            print("FAIL: " + e, file=sys.stderr)
        return 1
    print("PASS: contrast and dark-only checks ok (%s)" % ", ".join(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
