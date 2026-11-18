"""Denylist scan of normalized text, to complement the raw byte scan.

Usage: python3 -I scripts/check-scrub.py <dir> <patterns-file>
Prints "scrub_terms\t<file>\t<detail>" per problem and always exits 0.

Every file except known binary types must be valid UTF-8 and contain no NUL
characters (a UTF-16 file would hide ASCII terms behind NUL bytes). Each file is then
matched, case-insensitively after removing invisible formatting characters, Unicode
NFKC normalization and whitespace collapsing, in three forms:
  1. the text as written;
  2. the text with HTML character references decoded (repeated until stable, at most
     5 passes, so double-encoded references are caught);
  3. the text with every tag removed and replaced by nothing (so a term split across
     elements is still found), then decoded as in form 2.
"""
import html
import os
import re
import sys
import unicodedata
from html.parser import HTMLParser

BINARY_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico",
    ".woff", ".woff2", ".ttf", ".otf",
}


# Default_Ignorable_Code_Point ranges, pinned from the Unicode 15.1 DerivedCoreProperties
# table (invisible characters that can split a word without changing how it looks).
# Not derived from the running Python's unicodedata, so a newer or older Python cannot
# change what is stripped. Surrogates and noncharacter gaps are not listed.
DEFAULT_IGNORABLE = (
    (0x00AD, 0x00AD),
    (0x034F, 0x034F),
    (0x061C, 0x061C),
    (0x115F, 0x1160),
    (0x17B4, 0x17B5),
    (0x180B, 0x180F),
    (0x200B, 0x200F),
    (0x202A, 0x202E),
    (0x2060, 0x206F),
    (0x3164, 0x3164),
    (0xFE00, 0xFE0F),
    (0xFEFF, 0xFEFF),
    (0xFFA0, 0xFFA0),
    (0xFFF0, 0xFFF8),
    (0x1BCA0, 0x1BCA3),
    (0x1D173, 0x1D17A),
    (0xE0000, 0xE0FFF),
)
IGNORABLE_RE = re.compile(
    "[" + "".join("%s-%s" % (chr(lo), chr(hi)) for lo, hi in DEFAULT_IGNORABLE) + "]"
)


def strip_ignorable(s):
    return IGNORABLE_RE.sub("", s)


def norm(s):
    s = unicodedata.normalize("NFKC", strip_ignorable(s)).casefold()
    s = strip_ignorable(s)
    return re.sub(r"\s+", " ", s).strip()


def unescape_stable(s):
    for _ in range(5):
        n = html.unescape(s)
        if n == s:
            break
        s = n
    return s


class TextOnly(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []

    def handle_data(self, data):
        self.parts.append(data)


def forms(text):
    stripped = TextOnly()
    stripped.feed(text)
    stripped.close()
    return [
        norm(text),
        norm(unescape_stable(text)),
        norm(unescape_stable("".join(stripped.parts))),
    ]


def main():
    root, pattern_file = sys.argv[1], sys.argv[2]
    with open(pattern_file, encoding="utf-8", errors="replace") as fh:
        patterns = [norm(p.rstrip("\r\n")) for p in fh]
    patterns = [p for p in patterns if p]
    for dp, _dirs, files in os.walk(root):
        for name in sorted(files):
            path = os.path.join(dp, name)
            if os.path.splitext(name.lower())[1] in BINARY_EXT:
                continue
            with open(path, "rb") as fh:
                raw = fh.read()
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                print("scrub_terms\t%s\ttext file is not valid UTF-8" % path)
                continue
            if "\x00" in text:
                # BOM-less UTF-16 decodes as UTF-8 with NULs between the letters.
                print("scrub_terms\t%s\ttext file contains NUL characters (UTF-16?)" % path)
                continue
            fs = forms(text)
            if any(p in f for p in patterns for f in fs):
                print("scrub_terms\t%s\tdenylisted term found after decoding and tag removal" % path)


try:
    main()
except Exception as exc:  # fail closed: a crash must never read as a pass
    print("checker error: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
    sys.exit(70)
