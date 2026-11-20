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
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from textnorm import forms, norm  # noqa: E402  (path set just above; -I drops the script dir)

BINARY_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico",
    ".woff", ".woff2", ".ttf", ".otf",
}


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
