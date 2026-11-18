"""Structural checks on built html and css, using the stdlib html parser.

Usage: python3 -I scripts/check-html.py <dir> <production|staging>
Prints one line per violation: "<check>\t<file>\t<detail>" and always exits 0;
scripts/check-output.sh decides what to report. Checks emitted:
  no_script, inline_handler, external_host, noindex
"""
import os
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urlsplit

ALLOWED_HOSTS = {"chiefgyk3d.com", "github.com", "renegadepenguinllc.com"}
URL_ATTRS = {"src", "action", "formaction", "poster", "data", "background"}
CSS_URL = re.compile(r"url\(\s*[\"']?\s*([^)\"'\s]+)", re.I)
CSS_IMPORT = re.compile(r"@import\s+(?:url\(\s*)?[\"']?\s*([^\"';)\s]+)", re.I)


def foreign_host(value):
    """Return the host if value points at a host that is not allowed, else None."""
    v = value.strip().replace("\\", "/")
    if not v:
        return None
    try:
        host = urlsplit(v).hostname
    except ValueError:
        return "(unparseable url)"
    if host is None:
        return None
    return None if host.lower() in ALLOWED_HOSTS else host.lower()


def css_urls(text):
    return CSS_URL.findall(text) + CSS_IMPORT.findall(text)


class Checker(HTMLParser):
    def __init__(self, path, env):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.env = env
        self.out = []
        self.in_style = False
        self.robots_noindex = False

    def add(self, check, detail):
        self.out.append((check, self.path, detail))

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        a = {}
        for k, v in attrs:
            a[k.lower()] = v if v is not None else ""
        if tag == "script":
            self.add("no_script", "script element")
        for k in a:
            if k.startswith("on"):
                self.add("inline_handler", "attribute %s on <%s>" % (k, tag))
        for k in URL_ATTRS & set(a):
            h = foreign_host(a[k])
            if h:
                self.add("external_host", "%s=%s on <%s>" % (k, h, tag))
        if "srcset" in a:
            for cand in a["srcset"].split(","):
                parts = cand.split()
                if parts:
                    h = foreign_host(parts[0])
                    if h:
                        self.add("external_host", "srcset candidate %s on <%s>" % (h, tag))
        if tag == "link" and "href" in a:
            h = foreign_host(a["href"])
            if h:
                self.add("external_host", "link href %s" % h)
        if tag == "a" and "href" in a:
            h = foreign_host(a["href"])
            if h and "noopener" not in a.get("rel", "").lower().split():
                self.add("external_host", "link to %s lacks rel=noopener" % h)
        if "style" in a:
            for u in css_urls(a["style"]):
                h = foreign_host(u)
                if h:
                    self.add("external_host", "style attribute url %s" % h)
        if tag == "style":
            self.in_style = True
        if tag == "meta" and a.get("name", "").strip().lower() == "robots":
            if "noindex" in a.get("content", "").lower():
                self.robots_noindex = True

    def handle_endtag(self, tag):
        if tag.lower() == "style":
            self.in_style = False

    def handle_data(self, data):
        if self.in_style:
            for u in css_urls(data):
                h = foreign_host(u)
                if h:
                    self.add("external_host", "style element url %s" % h)


def main():
    root, env = sys.argv[1], sys.argv[2]
    for dp, _dirs, files in os.walk(root):
        for name in sorted(files):
            path = os.path.join(dp, name)
            if name.endswith(".css"):
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for u in css_urls(fh.read()):
                        h = foreign_host(u)
                        if h:
                            print("external_host\t%s\tcss url %s" % (path, h))
                continue
            if not name.endswith(".html"):
                continue
            with open(path, encoding="utf-8", errors="replace") as fh:
                c = Checker(path, env)
                c.feed(fh.read())
                c.close()
            for chk, p, detail in c.out:
                print("%s\t%s\t%s" % (chk, p, detail))
            if env == "production" and c.robots_noindex:
                print("noindex\t%s\tproduction page has a robots noindex meta" % path)
            if env == "staging" and not c.robots_noindex:
                print("noindex\t%s\tstaging page lacks a robots noindex meta" % path)


main()
