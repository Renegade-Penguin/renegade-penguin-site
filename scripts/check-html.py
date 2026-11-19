"""Structural checks on built html, svg and css, using the stdlib html parser.

Usage: python3 -I scripts/check-html.py <dir> <production|staging>
Prints one line per violation: "<check>\t<file>\t<detail>" and always exits 0;
scripts/check-output.sh decides what to report. Checks emitted:
  no_script, inline_handler, external_host, noindex, unsafe_scheme, meta_refresh,
  active_embed, base_element, duplicate_attr

no_script has one exception: exactly one <script src="https://challenges.cloudflare.com/turnstile/v0/api.js">
(optional async and defer, no other attribute, no inline body) in the built file contact/index.html.

Which files are parsed: names whose lower-cased form ends in .html, .htm, .xhtml,
.xht or .shtml (documents), .svg (scanned, no noindex requirement), and any other
file that is not a known binary type and whose first non-blank, non-comment content
is a tag (see sniff).
"""
import codecs
import json
import os
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urlsplit

ALLOWED_HOSTS = {"chiefgyk3d.com", "github.com", "renegadepenguinllc.com"}
OWN_HOST = "renegadepenguinllc.com"
# The one script exception: Cloudflare Turnstile, on the built contact page only.
TURNSTILE_SRC = "https://challenges.cloudflare.com/turnstile/v0/api.js"
TURNSTILE_PAGE = "contact/index.html"
# The exception does not hold inside these (template content and foreign content never run it).
INERT_CONTEXTS = {
    "template", "svg", "math",  # template content and foreign content
    "noscript", "title", "textarea", "xmp", "iframe", "noembed", "plaintext", "style",  # text, not markup, in a browser
}
# Foreign-content elements may really self-close; for every other inert element a trailing
# slash is ignored by browsers, so it counts as open (fail closed).
SELF_CLOSING_OK = {"svg", "math"}
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


LEADING_COMMENT = re.compile(r"\s*<!--.*?-->", re.S)
DOC_START = re.compile(r"<!doctype\s+html|<(html|head|body)\b")
TAG_START = re.compile(r"<[a-z]")


def sniff(text):
    """Classify a file with no recognized extension by its first non-blank content.

    Leading whitespace and comments are skipped, however long. Returns "doc" when it
    opens like an html document, "fragment" when it opens with any other tag (parsed
    for the structural checks, no noindex requirement), else None. An unterminated
    leading comment counts as a fragment (fail closed).
    """
    t = text
    while True:
        m = LEADING_COMMENT.match(t)
        if not m:
            break
        t = t[m.end():]
    t = t.lstrip()
    low = t.lower()
    if low.startswith("<!--"):
        return "fragment"
    if DOC_START.match(low):
        return "doc"
    if TAG_START.match(low):
        return "fragment"
    return None


JSONLD = "application/ld+json"
# A JSON-LD block is inert data, but "<!--" or "<script" inside it can put a browser's
# script-data parser in the double-escaped state, where the closing tag no longer ends
# the element; so neither may appear, and "</script" cannot (it would end the element).
SCRIPT_TRAPS = ("<!--", "<script", "</script")


def jsonld_problem(body):
    """Return why a JSON-LD body is not allowed, or None when it is plain JSON."""
    low = body.lower()
    for trap in SCRIPT_TRAPS:
        if trap in low:
            return "body contains %s" % trap
    try:
        json.loads(body)
    except ValueError:
        return "body is not valid JSON"
    return None


class Checker(HTMLParser):
    def __init__(self, path, env, rel=""):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.env = env
        self.rel = rel
        self.turnstile_seen = False
        self.in_turnstile = False
        self.reject_script = False
        self.inert = {}  # open count per INERT_CONTEXTS element: a script there never loads
        self.out = []
        self.in_style = False
        self.robots_noindex = False
        self.script = None  # body parts while inside a JSON-LD script element

    def close(self):
        super().close()
        if self.script is not None:
            self.add("no_script", "script element that is never closed")
            self.script = None

    def add(self, check, detail):
        self.out.append((check, self.path, detail))

    def turnstile_script_ok(self, a):
        """The one script the site allows: the Turnstile api.js, once, on the built
        contact page only. src is the exact url, the only other attributes are async and
        defer (an inline body is judged in handle_data)."""
        return (
            not self.reject_script
            and not any(self.inert.values())
            and self.rel == TURNSTILE_PAGE
            and not self.turnstile_seen
            and a.get("src") == TURNSTILE_SRC
            and set(a) <= {"src", "async", "defer"}
        )

    def jsonld_script_ok(self, a):
        """A JSON-LD data block: type exactly application/ld+json, no src, outside every
        inert context, not self-closing, and not nested in another JSON-LD block."""
        return (
            not self.reject_script
            and not any(self.inert.values())
            and self.script is None
            and a.get("type", "").strip().lower() == JSONLD
            and "src" not in a
        )

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        # Browsers use the first of two same-named attributes, so keep the first and
        # report any repeat (case-insensitive) as a violation of its own.
        a = {}
        for k, v in attrs:
            k = k.lower()
            if k in a:
                self.add("duplicate_attr", "duplicate attribute %s on <%s>" % (k, tag))
                continue
            a[k] = v if v is not None else ""
        if tag == "script":
            if self.turnstile_script_ok(a):
                self.turnstile_seen = True
                self.in_turnstile = True
            elif self.jsonld_script_ok(a):
                self.script = []  # a JSON-LD data block: its body is judged when it ends
            elif not self.reject_script:  # a self-closing script is reported by handle_startendtag
                self.add("no_script", "script element")
        if tag in INERT_CONTEXTS:
            self.inert[tag] = self.inert.get(tag, 0) + 1  # after the script judgment above
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
            if tag == "script" and k == "src" and a[k] == TURNSTILE_SRC:
                continue  # the exact Turnstile url is judged by the script rules only
            h = foreign_host(a[k])
            if h:
                self.add("external_host", "%s=%s on <%s>" % (k, h, tag))
        if "srcset" in a:
            for cand in a["srcset"].split(","):
                # Scheme check on the whole candidate (tab, CR and LF are dropped
                # inside the url as browsers do), then the host check on its url.
                s = unsafe_scheme(cand)
                if s:
                    self.add("unsafe_scheme", "%s: srcset candidate on <%s>" % (s, tag))
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

    def handle_startendtag(self, tag, attrs):
        # Browsers ignore the slash on a script tag and read raw text up to </script>, but this
        # parser does not enter raw-text mode, so a self-closing script is rejected outright.
        if tag.lower() == "script":
            self.add("no_script", "self-closing script element")
            self.reject_script = True
        if tag.lower() in INERT_CONTEXTS and tag.lower() not in SELF_CLOSING_OK:
            self.handle_starttag(tag, attrs)  # the slash is ignored: the element stays open
        else:
            super().handle_startendtag(tag, attrs)
        self.reject_script = False

    def handle_endtag(self, tag):
        t = tag.lower()
        # Only the matching end tag closes an element: a different end tag inside a raw-text
        # element is just text to a browser, so it must not lower the count.
        if self.inert.get(t, 0) > 0:
            self.inert[t] -= 1
        if tag.lower() == "style":
            self.in_style = False
        if tag.lower() == "script":
            self.in_turnstile = False
            if self.script is not None:
                body = "".join(self.script)
                self.script = None
                problem = jsonld_problem(body)
                if problem:
                    self.add("no_script", "JSON-LD script element %s" % problem)

    def handle_data(self, data):
        if self.script is not None:
            self.script.append(data)
        if self.in_turnstile and data.strip():
            self.add("no_script", "inline content in the Turnstile script")
        if (self.in_style or any(self.inert.values())) and "<script" in data.lower():
            # Parsers differ on whether markup inside these elements is text; script markup there is refused.
            self.add("no_script", "script markup inside an inert element")
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
            else:
                kind = sniff(text)
                if kind is None:
                    continue
                is_doc = kind == "doc"
            c = Checker(path, env, os.path.relpath(path, root).replace(os.sep, "/"))
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


try:
    main()
except Exception as exc:  # fail closed: a crash must never read as a pass
    print("checker error: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
    sys.exit(70)
