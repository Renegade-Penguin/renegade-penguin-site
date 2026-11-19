"""Fail when a built page still holds an unresolved owner placeholder.

Usage: python3 -I scripts/check-owner-tokens.py <dir>
Prints "<file><TAB><detail>" per page whose visible text or attribute values contain the
owner placeholder marker; exit 1 when there is any finding, 0 when clean, 70 when the helper
itself fails (fail closed: a crash never reads as a pass). Opt-in from check-output.sh.
"""
import os
import re
import sys
from html.parser import HTMLParser

MARKER = chr(123) * 2 + "OWNER:"
HTML_SUFFIXES = (".html", ".htm")


class Collector(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []

    def handle_data(self, data):
        self.parts.append(data)

    def handle_comment(self, data):
        self.parts.append(data)

    def handle_starttag(self, tag, attrs):
        for _name, value in attrs:
            if value:
                self.parts.append(value)

    handle_startendtag = handle_starttag


def has_marker(text):
    # Whitespace inside the marker is tolerated so a split token still counts.
    compact = re.sub(r"\s+", "", text)
    return MARKER in compact


def main():
    found = 0
    for root, _dirs, files in os.walk(sys.argv[1]):
        for name in sorted(files):
            if not name.endswith(HTML_SUFFIXES):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            parser = Collector()
            parser.feed(text)
            parser.close()
            if has_marker("".join(parser.parts)):
                print("%s\tunresolved owner placeholder" % path)
                found += 1
    sys.exit(1 if found else 0)


try:
    main()
except SystemExit:
    raise
except Exception as exc:  # fail closed: a crash must never read as a pass
    print("checker error: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
    sys.exit(70)
