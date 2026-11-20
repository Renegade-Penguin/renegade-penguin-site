"""Shared text helpers: the pinned Default_Ignorable_Code_Point table, the strip helper and the
normalization used by the scrub scans.

Imported by check-scrub.py, check-shapes.py and check-claims.py (each adds this directory to
sys.path, since python3 -I does not).
"""
import html
import re
import unicodedata
from html.parser import HTMLParser


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


def norm(s, fold=True):
    # One strip, before NFKC: no code point outside the table normalizes into it (checked
    # over all of Unicode for this table), so a second strip after NFKC would be dead code.
    # fold=False keeps the case (the shape checks need to tell A from a).
    s = unicodedata.normalize("NFKC", strip_ignorable(s))
    if fold:
        s = s.casefold()
    return re.sub(r"\s+", " ", s).strip()


def unescape_stable(s):
    for _ in range(5):
        n = html.unescape(s)
        if n == s:
            break
        s = n
    return s


class TextOnly(HTMLParser):
    """Text content with every tag removed. sep is put where a tag was: "" joins the text on both
    sides (catches a term split across elements), " " keeps the words apart, and "inline" joins
    only across inline tags (a word split by <b> is rejoined, but text in separate blocks, such as
    a title and a paragraph, stays apart)."""

    INLINE = frozenset(
        "a abbr b bdi bdo cite code data del dfn em font i ins kbd mark q s samp small span strike "
        "strong sub sup time tt u var wbr".split()
    )

    def __init__(self, sep=""):
        super().__init__(convert_charrefs=True)
        self.sep = sep
        self.parts = []

    def handle_data(self, data):
        self.parts.append(data)

    def _tag(self, tag, *_args):
        if self.sep == "inline":
            self.parts.append("" if tag.lower() in self.INLINE else " ")
        elif self.sep:
            self.parts.append(self.sep)

    handle_starttag = handle_endtag = handle_startendtag = _tag


def forms(text, fold=True, seps=("",)):
    """The text as written, with character references decoded, and with every tag removed
    (once per separator in seps), each normalized by norm()."""
    out = [norm(text, fold), norm(unescape_stable(text), fold)]
    for sep in seps:
        stripped = TextOnly(sep)
        stripped.feed(text)
        stripped.close()
        out.append(norm(unescape_stable("".join(stripped.parts)), fold))
    return out
