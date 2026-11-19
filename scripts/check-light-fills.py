#!/usr/bin/env python3
"""Fail when a CSS background resolves to a light color outside the allowed selectors.

Usage: python3 -I scripts/check-light-fills.py file.css [more.css ...]
Looks at background and background-color declarations (shorthand too), resolves
var(--token) from :root custom properties, and checks every hex or rgb() color.
Relative luminance above 0.30 fails unless every selector of the rule is on the
allow list (buttons and the skip link). Exit 0 clean, 1 on a finding or no CSS read.
"""
import re
import sys

LIMIT = 0.30
ALLOWED = (".btn-primary", ".skip", ".cta", ".contact-form button")
NAMED = {"white": "#ffffff", "ivory": "#fffff0", "beige": "#f5f5dc", "cornsilk": "#fff8dc", "linen": "#faf0e6"}


def lum(rgb):
    def ch(c):
        c /= 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def colors(value):
    out = []
    for h in re.findall(r"#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b", value):
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        out.append(tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)))
    for m in re.findall(r"rgba?\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)", value):
        out.append(tuple(int(x) for x in m))
    for w in re.findall(r"[a-z]+", value):
        if w in NAMED:
            out.extend(colors(NAMED[w]))
    return out


def main(paths):
    css = ""
    for p in paths:
        with open(p, encoding="utf-8") as f:
            css += f.read() + "\n"
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    tokens = dict(re.findall(r"(--[\w-]+)\s*:\s*([^;}]+)", css))

    def resolve(v, depth=0):
        if depth > 8:
            return v
        return re.sub(r"var\(\s*(--[\w-]+)[^)]*\)", lambda m: resolve(tokens.get(m.group(1), ""), depth + 1), v)

    seen = 0
    bad = 0
    for sel, body in re.findall(r"([^{}]+)\{([^{}]*)\}", css):
        sels = [s.strip() for s in sel.split(",")]
        for prop, val in re.findall(r"(?:^|;)\s*(background(?:-color)?)\s*:\s*([^;]+)", body):
            seen += 1
            if all(any(s.startswith(a) for a in ALLOWED) for s in sels):
                continue
            for c in colors(resolve(val)):
                if lum(c) > LIMIT:
                    print(f"LIGHT-FILL: {sel.strip()} {prop}: {val.strip()} (luminance {lum(c):.2f})")
                    bad += 1
    if seen == 0:
        print("NOTHING-CHECKED: no background declarations found")
        return 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
