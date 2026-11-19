"""Freshness checks on a built site: no placeholder links, no filler text, a current footer
year, and a security.txt whose Expires is neither past nor more than a year away.

Usage: python3 -I scripts/check-fresh.py <dir>
Prints one "<file>\t<detail>" line per finding and exits 1 when there are any; exits 0 when
clean. An unexpected error exits 70 (fail closed), never 0.

Rules:
  - an <a> whose href is exactly "#" or empty (the attribute with no value included);
  - the word "lorem" in a page (case-insensitive, whole word);
  - every page with a <footer> must show a copyright year (a (c) sign followed by four
    digits) equal to the year of the system clock at check time, and the site's
    index.html must have such a footer. The Hugo footer prints the build year, so a
    stale build, or a hard-coded year, fails;
  - <dir>/.well-known/security.txt must exist, have a Contact field, and exactly one
    Expires field in RFC 3339 form that is in the future and at most 365 days ahead.
"""
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser

DOC_EXT = (".html", ".htm", ".xhtml", ".xht", ".shtml")
LOREM = re.compile(r"\blorem\b", re.I)
YEAR = re.compile(r"(?:©|\(c\))\s*((?:19|20)\d\d)\b", re.I)
RFC3339 = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?([Zz]|[+-]\d{2}:\d{2})$")
MAX_AHEAD = timedelta(days=365)


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.bad_links = 0
        self.footer_depth = 0
        self.footer_text = []
        self.has_footer = False

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if tag == "footer":
            self.has_footer = True
            self.footer_depth += 1
        if tag == "a":
            for k, v in attrs:
                if k.lower() == "href":  # the first href counts, as in a browser
                    if (v or "").strip() in ("", "#"):
                        self.bad_links += 1
                    break

    def handle_endtag(self, tag):
        if tag.lower() == "footer" and self.footer_depth:
            self.footer_depth -= 1

    def handle_data(self, data):
        if self.footer_depth:
            self.footer_text.append(data)


def read(path):
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8", errors="replace")


def check_pages(root, year, out):
    saw_root_footer = False
    for dp, _dirs, files in os.walk(root):
        for name in sorted(files):
            if not name.lower().endswith(DOC_EXT):
                continue
            path = os.path.join(dp, name)
            rel = os.path.relpath(path, root)
            text = read(path)
            p = Page()
            p.feed(text)
            p.close()
            if p.bad_links:
                out.append((rel, "%d link(s) with href=\"#\" or an empty href" % p.bad_links))
            if LOREM.search(text):
                out.append((rel, "placeholder text: lorem"))
            if p.has_footer:
                years = YEAR.findall(" ".join(p.footer_text))
                if not years:
                    out.append((rel, "footer has no copyright year"))
                elif any(int(y) != year for y in years):
                    out.append((rel, "footer year %s is not the current year %d"
                                % (",".join(years), year)))
                elif rel == "index.html":
                    saw_root_footer = True
    if not saw_root_footer and not any(r == "index.html" for r, _ in out):
        out.append(("index.html", "no footer copyright year on the home page"))


def parse_expires(value):
    m = RFC3339.match(value.strip())
    if not m:
        return None
    y, mo, d, h, mi, s = (int(x) for x in m.groups()[:6])
    tz = m.group(7)
    try:
        if tz in ("Z", "z"):
            offset = timezone.utc
        else:
            sign = 1 if tz[0] == "+" else -1
            offset = timezone(sign * timedelta(hours=int(tz[1:3]), minutes=int(tz[4:6])))
        return datetime(y, mo, d, h, mi, s, tzinfo=offset)
    except ValueError:
        return None


def check_security_txt(root, now, out):
    rel = os.path.join(".well-known", "security.txt")
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        out.append((rel, "missing"))
        return
    fields = {}
    for line in read(path).splitlines():
        if line.startswith("#") or ":" not in line:
            continue
        k, _sep, v = line.partition(":")
        fields.setdefault(k.strip().lower(), []).append(v.strip())
    if not fields.get("contact"):
        out.append((rel, "no Contact field"))
    exp = fields.get("expires", [])
    if len(exp) != 1:
        out.append((rel, "needs exactly one Expires field, found %d" % len(exp)))
        return
    when = parse_expires(exp[0])
    if when is None:
        out.append((rel, "Expires is not an RFC 3339 date-time: %s" % exp[0]))
    elif when <= now:
        out.append((rel, "Expires %s is in the past" % exp[0]))
    elif when - now > MAX_AHEAD:
        out.append((rel, "Expires %s is more than 365 days ahead" % exp[0]))


def main():
    root = sys.argv[1]
    if not os.path.isdir(root):
        print("%s is not a directory" % root, file=sys.stderr)
        return 70
    now = datetime.now(timezone.utc)
    out = []
    check_pages(root, datetime.now().year, out)
    check_security_txt(root, now, out)
    for rel, detail in out:
        print("%s\t%s" % (rel, detail))
    return 1 if out else 0


try:
    sys.exit(main())
except SystemExit:
    raise
except Exception as exc:  # fail closed: a crash must never read as a pass
    print("checker error: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
    sys.exit(70)
