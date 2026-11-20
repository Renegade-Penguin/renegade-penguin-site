#!/usr/bin/env python3
"""Every email address and mailto link in a built site must sit inside email_off markers.

Usage: python3 -I scripts/check-email-off.py <dir>
Exit 0 when clean; otherwise non-zero with one "FAIL <rule>: <file>: <detail>" line per violation.

Cloudflare Email Address Obfuscation rewrites addresses and mailto links in served HTML into
/cdn-cgi/l/email-protection#... links and injects a decoder script our CSP blocks. The documented
opt-out is to surround the address with <!--email_off--> and <!--/email_off-->. Cloudflare leaves
alone text inside script, noscript, textarea, xmp and head, and any attribute other than a-href, so
the check ignores those too. Rules:
  unwrapped-address   an address in page text outside a marker pair
  unwrapped-mailto    an <a href="mailto:..."> outside a marker pair
  marker-unbalanced   a marker opened twice, closed without opening, or never closed
  rewritten           the raw page carries email-protection, data-cfemail or the decoder
"""
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

ADDR = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
REWRITE = re.compile(r"email-protection|data-cfemail|email-decode|__cf_email__", re.I)
SKIP_TAGS = {"script", "noscript", "textarea", "xmp", "head"}


class Scan(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.off = False
        self.skip = 0
        self.findings = []

    def handle_comment(self, data):
        d = data.strip().lower()
        if d == "email_off":
            if self.off:
                self.findings.append(("marker-unbalanced", "email_off opened twice"))
            self.off = True
        elif d == "/email_off":
            if not self.off:
                self.findings.append(("marker-unbalanced", "/email_off without an opener"))
            self.off = False

    def handle_starttag(self, tag, attrs):
        if tag in SKIP_TAGS:
            self.skip += 1
            return
        if tag == "a" and not self.skip and not self.off:
            for k, v in attrs:
                if k == "href" and (v or "").strip().lower().startswith("mailto:"):
                    self.findings.append(("unwrapped-mailto", v))

    def handle_endtag(self, tag):
        if tag in SKIP_TAGS and self.skip:
            self.skip -= 1

    def handle_data(self, data):
        if self.skip or self.off:
            return
        for m in ADDR.finditer(data):
            self.findings.append(("unwrapped-address", m.group(0)))

    def close(self):
        super().close()
        if self.off:
            self.findings.append(("marker-unbalanced", "email_off never closed"))


def scan(path):
    raw = path.read_text(encoding="utf-8", errors="replace")
    out = []
    if REWRITE.search(raw):
        out.append(("rewritten", "email-protection or decoder marker in the page"))
    p = Scan()
    p.feed(raw)
    p.close()
    return out + p.findings


def main(argv):
    if len(argv) != 2 or not Path(argv[1]).is_dir():
        print("usage: check-email-off.py <dir>", file=sys.stderr)
        return 2
    root = Path(argv[1])
    pages = sorted(root.rglob("*.html"))
    if not pages:
        print("FAIL no-pages: no html files under %s" % root)
        return 1
    bad = 0
    for page in pages:
        for rule, detail in scan(page):
            print("FAIL %s: %s: %s" % (rule, page.relative_to(root), detail))
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
