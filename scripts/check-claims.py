#!/usr/bin/env python3
"""Claims check for built html: banned marketing phrases and bare dollar figures.

Usage: python3 -I scripts/check-claims.py <dir>
Walks .html files, reads text with an html parser (no regexes over markup), and prints
one "<file>\t<detail>" line per finding. Exit 0 clean, 1 findings, 70 on a helper error.

What is scanned:
  - visible text, plus the <title> element, plus the attributes alt, title, aria-label and the
    content of meta description, og:* and twitter:* tags. script and style text is ignored.
  - text inside <span data-price> (emitted by the pricing shortcode) is scanned for banned
    phrases but is the only place a dollar figure (a dollar sign followed by a digit) is allowed.
Intended behavior, pinned by fixtures:
  - inline elements join text (guar<b>antee</b> is one word); block elements, void elements and
    price spans separate it (<p>guaran</p><p>tee</p> and <span data-price>$5</span>100% do not join).
  - text is NFKC-normalized, case-folded, with invisible default-ignorable characters removed;
    every dash, hyphen and space counts as one separator ("battle tested" = "battle-tested"),
    and "100 %" is "100%".
  - "not certified" is allowed; any other "certified" is banned.
  - an unbalanced price span (never closed, or closed by an outer tag) is itself a finding.
"""
import os
import sys
import unicodedata
from html.parser import HTMLParser

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from textnorm import strip_ignorable

# One constant: phrases that must not appear in scanned text (matched after normalization).
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
SKIP_TEXT = frozenset(("script", "style"))
VOID = frozenset("area base br col embed hr img input link meta source track wbr".split())
TEXT_ATTRS = ("alt", "title", "aria-label")


def norm(text):
    """NFKC, case-folded, invisible characters removed, dashes and spaces as one separator."""
    text = unicodedata.normalize("NFKC", strip_ignorable(text)).casefold()
    chars = []
    for ch in text:
        if ch.isspace() or unicodedata.category(ch) == "Pd":
            chars.append(" ")
        else:
            chars.append(ch)
    text = " ".join("".join(chars).split())
    while " %" in text:
        text = text.replace(" %", "%")
    return text


def meta_is_text(attrs):
    key = (attrs.get("name") or attrs.get("property") or "").strip().lower()
    return key == "description" or key.startswith("og:") or key.startswith("twitter:")


class Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.banned_parts = []  # everything scanned for banned phrases
        self.dollar_parts = []  # the same, minus price span text
        self.price_depth = 0
        self.skip_depth = 0
        self.stack = []
        self.unbalanced = False

    def add(self, text, in_price=None):
        if in_price is None:
            in_price = self.price_depth > 0
        self.banned_parts.append(text)
        self.dollar_parts.append(" " if in_price else text)

    def sep(self):
        self.add(" ", False)

    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v or "") for k, v in attrs}
        for key in TEXT_ATTRS:
            if key in a:
                self.sep()
                self.add(a[key])
                self.sep()
        if tag == "meta" and meta_is_text(a) and "content" in a:
            self.sep()
            self.add(a["content"])
            self.sep()
        if tag in VOID:
            self.sep()
            return
        is_price = tag == "span" and "data-price" in a
        self.stack.append((tag, is_price))
        if is_price:
            self.price_depth += 1
            self.sep()
        if tag in SKIP_TEXT:
            self.skip_depth += 1
        if tag not in INLINE:
            self.sep()

    def handle_endtag(self, tag):
        # Pop to the matching open tag; ignore stray end tags.
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                for n, (t, is_price) in enumerate(self.stack[i:]):
                    if is_price:
                        self.price_depth -= 1
                        if n > 0:
                            self.unbalanced = True  # closed by an outer tag, not by its own </span>
                    if t in SKIP_TEXT:
                        self.skip_depth -= 1
                del self.stack[i:]
                if tag == "span":
                    self.sep()
                break
        if tag not in INLINE:
            self.sep()

    def handle_data(self, data):
        if self.skip_depth:
            self.sep()
            return
        self.add(data)

    def close(self):
        super().close()
        if self.price_depth > 0:
            self.unbalanced = True


def has_dollar_figure(text):
    return any(ch == "$" and text[i + 1].isdigit() for i, ch in enumerate(text[:-1]))


def findings(path):
    # Undecodable bytes are the scrub check's business; here they only must not crash the scan.
    with open(path, encoding="utf-8", errors="replace") as fh:
        source = fh.read()
    parser = Text()
    parser.feed(source)
    parser.close()
    banned_text = norm("".join(parser.banned_parts))
    for ok in ALLOWED:
        banned_text = banned_text.replace(norm(ok), " ")
    out = ["banned phrase: %s" % p for p in BANNED if norm(p) in banned_text]
    if has_dollar_figure(norm("".join(parser.dollar_parts))):
        out.append("dollar figure outside <span data-price>")
    if parser.unbalanced:
        out.append("unbalanced <span data-price>")
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
