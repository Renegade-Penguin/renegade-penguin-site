#!/usr/bin/env python3
"""Claims check for built html: banned marketing phrases and bare dollar figures.

Usage: python3 -I scripts/check-claims.py <dir>
Walks .html files, reads visible text with an html parser (no regexes over markup), and prints
one "<file>\t<detail>" line per finding. Exit 0 clean, 1 findings, 70 on a helper error.
A dollar sign followed by a digit is allowed only inside <span data-price>, which the pricing
shortcode emits. "not certified" is allowed; "certified" otherwise is banned.
"""
import os
import sys
from html.parser import HTMLParser

# One constant: phrases that must not appear in visible text (compared case-insensitively).
BANNED = (
    "100%",
    "guarantee",  # also matches guaranteed
    "certified",
    "compliant",
    "never failed",
    "battle-tested",
)
# Phrases removed before the banned list is applied.
ALLOWED = ("not certified",)

INLINE = frozenset(
    "a abbr b bdi bdo cite code data dfn em i kbd mark q s samp small span strong sub sup time u var".split()
)
SKIP_TEXT = frozenset(("script", "style", "title"))
VOID = frozenset("area base br col embed hr img input link meta source track wbr".split())


class Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []  # visible text outside price spans
        self.price_depth = 0
        self.skip_depth = 0
        self.stack = []

    def handle_starttag(self, tag, attrs):
        if tag in VOID:
            self.out.append(" ")
            return
        is_price = tag == "span" and any(k == "data-price" for k, _v in attrs)
        self.stack.append((tag, is_price))
        if is_price:
            self.price_depth += 1
        if tag in SKIP_TEXT:
            self.skip_depth += 1
        if tag not in INLINE:
            self.out.append(" ")

    def handle_startendtag(self, tag, attrs):
        self.out.append(" ")

    def handle_endtag(self, tag):
        # Pop to the matching open tag; ignore stray end tags.
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                for t, is_price in self.stack[i:]:
                    if is_price:
                        self.price_depth -= 1
                    if t in SKIP_TEXT:
                        self.skip_depth -= 1
                del self.stack[i:]
                break
        if tag not in INLINE:
            self.out.append(" ")
        elif self.price_depth == 0:
            self.out.append("")

    def handle_data(self, data):
        if self.skip_depth or self.price_depth:
            self.out.append(" ")  # a price never joins the words around it
            return
        self.out.append(data)


def has_dollar_figure(text):
    for i, ch in enumerate(text[:-1]):
        if ch == "$" and text[i + 1].isdigit():
            return True
    return False


def findings(path):
    # Undecodable bytes are the scrub check's business; here they only must not crash the scan.
    with open(path, encoding="utf-8", errors="replace") as fh:
        source = fh.read()
    parser = Text()
    parser.feed(source)
    parser.close()
    text = " ".join("".join(parser.out).split()).lower()
    for ok in ALLOWED:
        text = text.replace(ok, " ")
    found = [p for p in BANNED if p in text]
    out = ["banned phrase: %s" % p for p in found]
    if has_dollar_figure(text):
        out.append("dollar figure outside <span data-price>")
    return out


def main():
    root = sys.argv[1]
    if not os.path.isdir(root):
        raise NotADirectoryError(root)
    bad = 0
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if not name.lower().endswith(".html"):
                continue
            path = os.path.join(dirpath, name)
            for detail in findings(path):
                print("%s\t%s" % (path, detail))
                bad += 1
    return 1 if bad else 0


try:
    sys.exit(main())
except SystemExit:
    raise
except Exception as exc:  # fail closed: a crash must never read as a pass
    print("checker error: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
    sys.exit(70)
