"""Shape scan: identifiers that look private, found without any terms list.

Usage: python3 -I scripts/check-shapes.py <dir> [allow-file]
Prints "scrub_shapes\t<file>\t<detail>" per file and shape, and always exits 0 (a crash or a bad
allowlist exits non-zero, which the caller reports as a failure). The detail names the shape, the
count and a character offset; it NEVER carries the matched text.

Shapes (the same ones the personal repository's WordPress converter checks, tuned for a business
site where a false positive blocks the deploy):
  callsign   amateur radio callsign: 1-2 uppercase letters, one digit, 2-4 uppercase letters, not
             part of a longer word (so B2B, B2C, W3C, H1B and SOC2 do not match). The
             documentation placeholders N0CALL and N0TST match on purpose: they are not
             legitimate on the public site. Callsigns that start with a digit are not covered.
  grid       Maidenhead locator: two letters A-R, two digits, two lowercase letters a-x (six
             characters, always flagged), or the four character form only when the word grid,
             locator, maidenhead or qth is right before it (a bare AB12 is too common to flag).
  private IPv4 address: 10/8, 172.16/12, 192.168/16.
  private hostname: a dotted name ending .local, .lan, .internal or .home.arpa.

Text is normalized like check-scrub.py (invisible characters removed, NFKC, whitespace collapsed)
but case is kept, because the callsign and grid shapes depend on it. Each file is scanned as written,
with character references decoded, and with the tags removed (joined across inline tags such as <b>,
and separated by a space), so a shape split across inline elements or hidden in an attribute or a
script block is still found. A file that
is not UTF-8, or holds a NUL, is skipped here: scrub_terms (check-scrub.py) fails the build for it.

Allowlist (default scripts/scrub-shapes-allow.txt, or the second argument): one exact token per line
as "TOKEN<TAB>reason"; a line without a reason is an error. Only an exact match is exempt.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from textnorm import forms  # noqa: E402  (path set just above; -I drops the script dir)

BINARY_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico",
    ".woff", ".woff2", ".ttf", ".otf",
}
EDGE = r"A-Za-z0-9_"  # a shape is never part of a longer word
CALLSIGN = re.compile(r"(?<![%s])[A-Z]{1,2}[0-9][A-Z]{2,4}(?![%s])" % (EDGE, EDGE))
GRID6 = re.compile(r"(?<![%s])[A-R]{2}[0-9]{2}[a-x]{2}(?![%s])" % (EDGE, EDGE))
GRID4 = re.compile(r"(?<![%s])[A-R]{2}[0-9]{2}(?![%s])" % (EDGE, EDGE))
GRID_CONTEXT = re.compile(
    r"(?:grid(?:\s+(?:square|locator))?|locator|maidenhead|qth)(?:\s+(?:is|at|in))?\W{0,4}$", re.I
)
OCTET = r"(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
PRIVATE_IP = re.compile(
    # An address is delimited on both sides: not glued to a letter, digit, underscore, hyphen or a
    # dot before it (x10.9.8.7, 1.10.9.8.7), and not continued after it by such a character or by a dot
    # plus one (10.9.8.7abc, 10.9.8.7.6, 10.9.8.7.example). A sentence-ending dot still matches.
    r"(?<![A-Za-z0-9_.-])(?:10\.%(o)s\.%(o)s\.%(o)s|172\.(?:1[6-9]|2[0-9]|3[01])\.%(o)s\.%(o)s|192\.168\.%(o)s\.%(o)s)"
    r"(?![A-Za-z0-9_-]|\.[A-Za-z0-9_-])"
    % {"o": OCTET}
)
PRIVATE_NAME = re.compile(
    r"(?<![A-Za-z0-9.-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+(?:local|lan|internal|home\.arpa)"
    r"(?![A-Za-z0-9-]|\.[A-Za-z0-9])",
    re.I,
)
FORM_NAMES = ("as written", "decoded", "text, inline tags joined", "text, tags spaced")


def load_allow(path):
    allow = set()
    with open(path, encoding="utf-8") as fh:
        for number, raw in enumerate(fh, 1):
            line = raw.rstrip("\r\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            token, tab, reason = line.partition("\t")
            if not tab or not token or not reason.strip():
                raise ValueError("allowlist line %d: expected TOKEN<TAB>reason" % number)
            allow.add(token)
    return allow


def grid4_hits(text, allow):
    return [
        m
        for m in GRID4.finditer(text)
        if m.group(0) not in allow and GRID_CONTEXT.search(text[max(0, m.start() - 32):m.start()])
    ]


def find(text, allow):
    """Match objects per shape name for one normalized form."""
    def keep(regex):
        return [m for m in regex.finditer(text) if m.group(0) not in allow]

    return {
        "callsign shape": keep(CALLSIGN),
        "grid shape": keep(GRID6) + grid4_hits(text, allow),
        "private IPv4 address shape": keep(PRIVATE_IP),
        "private hostname shape": keep(PRIVATE_NAME),
    }


def scan(text, allow):
    """(shape, count, offset, form name) per shape found in any form of the text. The count is the
    largest over the forms (the same hit seen in several forms is one hit)."""
    best = {}
    for form_name, form in zip(FORM_NAMES, forms(text, fold=False, seps=("inline", " "))):
        for shape, hits in find(form, allow).items():
            if not hits:
                continue
            first = min(m.start() for m in hits)
            if shape not in best:
                best[shape] = [len(hits), first, form_name]
            else:
                best[shape][0] = max(best[shape][0], len(hits))
    return [(shape, v[0], v[1], v[2]) for shape, v in best.items()]


def main():
    root = sys.argv[1]
    allow_path = (
        sys.argv[2]
        if len(sys.argv) > 2
        else os.path.join(os.path.dirname(os.path.abspath(__file__)), "scrub-shapes-allow.txt")
    )
    allow = load_allow(allow_path)
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
                continue  # scrub_terms already fails the build for a file that is not UTF-8
            if "\x00" in text:
                continue  # likewise for a NUL (UTF-16) file: scrub_terms reports it
            for shape, count, offset, form_name in scan(text, allow):
                print(
                    "scrub_shapes\t%s\t%s: %d hit(s), first at offset %d (%s)"
                    % (path, shape, count, offset, form_name)
                )


try:
    main()
except Exception as exc:  # fail closed: a crash must never read as a pass; no matched text here
    print("checker error: %s" % type(exc).__name__, file=sys.stderr)
    sys.exit(70)
