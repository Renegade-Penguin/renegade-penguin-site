"""Structural checks on built html, svg and css, using the stdlib html parser.

Usage: python3 -I scripts/check-html.py <dir> <production|staging>
Prints one line per violation: "<check>\t<file>\t<detail>" and always exits 0;
scripts/check-output.sh decides what to report. Checks emitted:
  no_script, inline_handler, external_host, noindex, unsafe_scheme, meta_refresh,
  active_embed, base_element

Which files are parsed: names whose lower-cased form ends in .html, .htm, .xhtml,
.xht or .shtml (documents), .svg (scanned, no noindex requirement), and any other
file that is not a known binary type but starts like an html document.
"""
import codecs
import os
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urlsplit

ALLOWED_HOSTS = {"chiefgyk3d.com", "github.com", "renegadepenguinllc.com"}
OWN_HOST = "renegadepenguinllc.com"
URL_ATTRS = {"src", "action", "formaction", "poster", "data", "background"}
DOC_EXT = (".html", ".htm", ".xhtml", ".xht", ".shtml")
BINARY_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico",
    ".woff", ".woff2", ".ttf", ".otf",
}
BANNED_TAGS = {"iframe", "object", "embed", "frame", "frameset", "applet"}
CSS_URL = re.compile(r"url\(\s*[\"']?\s*([^)\"'\s]+)", re.I)
CSS_IMPORT = re.compile(r"@import\s+(?:url\(\s*)?[\"']?\s*([^\"';)\s]+)", re.I)


def url_host(value):
    """Return the lower-cased host of a url value, or None when it has no host."""
    v = value.strip().replace("\\", "/")
    if not v:
        return None
    try:
        host = urlsplit(v).hostname
    except ValueError:
        return "(unparseable url)"
    return host.lower() if host else None


def foreign_host(value):
    """Return the host if value points at a host that is not allowed, else None."""
    h = url_host(value)
    if h is None or h in ALLOWED_HOSTS:
        return None
    return h


BAD_SCHEMES = {"javascript", "vbscript", "data"}
SCHEME_ATTRS = URL_ATTRS | {"href", "xlink:href"}
SCHEME_RE = re.compile(r"^([a-z][a-z0-9+.-]*):")


def unsafe_scheme(value):
    """Return the scheme if value uses javascript:, vbscript: or data:, else None.

    Browsers drop tab, CR and LF anywhere in a url and trim leading and trailing
    C0 controls and spaces, so do the same before looking at the scheme.
    """
    v = re.sub(r"[\t\r\n]", "", value)
    v = v.strip("".join(chr(c) for c in range(0x21)))
    m = SCHEME_RE.match(v.lower())
    if m and m.group(1) in BAD_SCHEMES:
        return m.group(1)
    return None


def css_urls(text):
    return CSS_URL.findall(text) + CSS_IMPORT.findall(text)


def read_text(path):
    """Read a file as text; honor a UTF-16 or UTF-8 byte order mark."""
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
        return raw.decode("utf-16", errors="replace")
    if raw.startswith(codecs.BOM_UTF8):
        return raw[3:].decode("utf-8", errors="replace")
    return raw.decode("utf-8", errors="replace")


def looks_like_html(text):
    head = text[:1024].lower()
    return "<!doctype html" in head or "<html" in head


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
        if tag in BANNED_TAGS:
            self.add("active_embed", "<%s> element" % tag)
        if "srcdoc" in a:
            self.add("active_embed", "srcdoc attribute on <%s>" % tag)
        if tag == "base":
            self.add("base_element", "<base> element")
        for k in a:
            if k.startswith("on"):
                self.add("inline_handler", "attribute %s on <%s>" % (k, tag))
        for k in SCHEME_ATTRS & set(a):
            s = unsafe_scheme(a[k])
            if s:
                self.add("unsafe_scheme", "%s: url on <%s> %s" % (s, tag, k))
        if tag == "meta" and a.get("http-equiv", "").strip().lower() == "refresh":
            self.add("meta_refresh", "meta http-equiv=refresh")
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
            # Any anchor that leaves this site's own origin needs rel=noopener,
            # including anchors to the allowed hosts. Relative links are exempt.
            h = url_host(a["href"])
            if h and h != OWN_HOST and "noopener" not in a.get("rel", "").lower().split():
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
            lower = name.lower()
            if lower.endswith(".css"):
                for u in css_urls(read_text(path)):
                    h = foreign_host(u)
                    if h:
                        print("external_host\t%s\tcss url %s" % (path, h))
                continue
            if os.path.splitext(lower)[1] in BINARY_EXT:
                continue
            text = read_text(path)
            is_doc = True
            if lower.endswith(DOC_EXT):
                pass
            elif lower.endswith(".svg"):
                is_doc = False
            elif not looks_like_html(text):
                continue
            c = Checker(path, env)
            c.feed(text)
            c.close()
            for chk, p, detail in c.out:
                print("%s\t%s\t%s" % (chk, p, detail))
            if not is_doc:
                continue
            if env == "production" and c.robots_noindex:
                print("noindex\t%s\tproduction page has a robots noindex meta" % path)
            if env == "staging" and not c.robots_noindex:
                print("noindex\t%s\tstaging page lacks a robots noindex meta" % path)


main()
