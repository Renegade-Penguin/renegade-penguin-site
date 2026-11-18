"""List html, xml, css, txt and json files under a directory that contain an em dash or an en dash.

The characters are built with chr() so this source holds no dash itself.
Usage: python3 -I scripts/find-dashes.py <dir>
Prints one path per offending file; exit 0 unless the helper itself fails (70).
"""
import os
import sys

DASHES = (chr(0x2014), chr(0x2013))
SUFFIXES = (".html", ".xml", ".css", ".txt", ".json")


def main():
    for root, _dirs, files in os.walk(sys.argv[1]):
        for name in sorted(files):
            if not name.endswith(SUFFIXES):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            if any(d in text for d in DASHES):
                print(path)


try:
    main()
except Exception as exc:  # fail closed: a crash must never read as a pass
    print("checker error: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
    sys.exit(70)
