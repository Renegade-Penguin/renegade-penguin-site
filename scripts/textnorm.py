"""Shared text helpers: the pinned Default_Ignorable_Code_Point table and the strip helper.

Imported by check-scrub.py and check-claims.py (each adds this directory to sys.path, since
python3 -I does not).
"""
import re


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
