#!/usr/bin/env bash
# Targeted test for Open Graph and Twitter tags and the share card (issue #97). Builds production and
# staging, then asserts for every sitemap page: exactly one of each required og: and twitter: tag with
# non-empty content, og:url equal to the canonical, og:title at most 70 characters, and an og:image that
# resolves to a PNG of exactly 1200x630 inside the build. Staging keeps noindex. Negative cases prove
# each guard bites.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" social.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
"$HUGO" --minify --destination "$TMP/prod" >/dev/null 2>"$TMP/build.err" || fail "production build: $(cat "$TMP/build.err")"
HUGO_PARAMS_ENVIRONMENT=staging "$HUGO" --minify --destination "$TMP/stg" >/dev/null 2>"$TMP/build.err" || fail "staging build: $(cat "$TMP/build.err")"
python3 -I - "$TMP/prod" "$TMP/stg" <<'PY' || fail "social tags"
import re
import struct
import sys
from html.parser import HTMLParser
from urllib.parse import urlparse

prod, stg = sys.argv[1], sys.argv[2]

REQUIRED = [
    "og:site_name", "og:type", "og:title", "og:description", "og:url", "og:image",
    "og:image:width", "og:image:height", "og:image:alt",
    "twitter:card", "twitter:title", "twitter:description", "twitter:image", "twitter:image:alt",
]


class Head(HTMLParser):
    def __init__(self):
        super().__init__()
        self.meta = []
        self.canon = []
        self.robots = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "meta":
            key = a.get("property") or a.get("name")
            if key and (key.startswith("og:") or key.startswith("twitter:")):
                self.meta.append((key, a.get("content")))
            if a.get("name") == "robots":
                self.robots.append(a.get("content"))
        elif tag == "link" and a.get("rel") == "canonical":
            self.canon.append(a.get("href"))


def parse(doc):
    h = Head()
    h.feed(doc)
    return h


def png_size(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    assert data[12:16] == b"IHDR", "no IHDR"
    return struct.unpack(">II", data[16:24])


def check(path, doc, out):
    errs = []
    h = parse(doc)
    tags = {}
    for k, v in h.meta:
        tags.setdefault(k, []).append(v)
    for k in REQUIRED:
        vals = tags.get(k, [])
        if len(vals) != 1:
            errs.append((path, "%s present %d times" % (k, len(vals))))
        elif not (vals[0] or "").strip():
            errs.append((path, "%s is empty" % k))
    if tags.get("twitter:card") and tags["twitter:card"][0] != "summary_large_image":
        errs.append((path, "twitter:card is not summary_large_image"))
    if "twitter:site" in tags:
        errs.append((path, "twitter:site must not be set"))
    if tags.get("og:image:width") and tags["og:image:width"][0] != "1200":
        errs.append((path, "og:image:width is not 1200"))
    if tags.get("og:image:height") and tags["og:image:height"][0] != "630":
        errs.append((path, "og:image:height is not 630"))
    if len(h.canon) != 1 or not tags.get("og:url") or tags["og:url"][0] != h.canon[0]:
        errs.append((path, "og:url %r does not equal canonical %r" % (tags.get("og:url"), h.canon)))
    t = (tags.get("og:title") or [""])[0] or ""
    if len(t) > 70:
        errs.append((path, "og:title %d chars" % len(t)))
    if tags.get("twitter:image") != tags.get("og:image"):
        errs.append((path, "twitter:image differs from og:image"))
    img = (tags.get("og:image") or [""])[0] or ""
    if img:
        u = urlparse(img)
        if u.scheme != "https" or not u.netloc:
            errs.append((path, "og:image is not an absolute https URL: " + img))
        elif u.netloc != urlparse(h.canon[0] if h.canon else "").netloc:
            errs.append((path, "og:image host differs from the canonical host"))
        try:
            with open(out + u.path, "rb") as f:
                size = png_size(f.read(32))
            if size != (1200, 630):
                errs.append((path, "og:image is %dx%d, not 1200x630" % size))
        except (OSError, AssertionError) as e:
            errs.append((path, "og:image does not resolve to a PNG in the build: %s" % e))
    return errs


def pages(out):
    sm = open(out + "/sitemap.xml", encoding="utf-8").read()
    paths = [urlparse(u).path for u in re.findall(r"<loc>([^<]+)</loc>", sm)]
    assert len(paths) >= 20, ("too few public pages collected", len(paths))
    return paths


items = []
for p in pages(prod):
    items.append((p, open(prod + p + "index.html", encoding="utf-8").read()))
errs = []
for p, doc in items:
    errs += check(p, doc, prod)
for e in errs:
    print("%s: %s" % e)
assert not errs, "%d violation(s)" % len(errs)

# staging: still noindex, and the tags still hold
sdoc = open(stg + "/index.html", encoding="utf-8").read()
assert parse(sdoc).robots == ["noindex, nofollow"], "staging lost noindex"
assert not check("/", sdoc, stg), check("/", sdoc, stg)
assert not parse(items[0][1]).robots, "production must not carry noindex"

# negative cases: each guard bites
base = items[0][1]
assert base.count('og:title') >= 1


def mutate(doc, key, new=None):
    pat = re.compile(r'<meta (?:property|name)=%s[^>]*>' % re.escape(key) + '|<meta (?:property|name)="%s"[^>]*>' % re.escape(key))
    return pat.sub(new or "", doc)


assert check("/", mutate(base, "og:image"), prod), "guard missed a missing og:image"
assert check("/", mutate(base, "twitter:card"), prod), "guard missed a missing twitter:card"
dup = re.search(r'<meta (?:property|name)="?og:site_name[^>]*>', base).group(0)
assert check("/", base.replace(dup, dup + dup, 1), prod), "guard missed a duplicate tag"
assert check("/", mutate(base, "og:description", '<meta property="og:description" content="">'), prod), "guard missed an empty tag"
assert check("/", mutate(base, "og:url", '<meta property="og:url" content="https://example.com/x/">'), prod), "guard missed og:url != canonical"
assert check("/", mutate(base, "og:title", '<meta property="og:title" content="%s">' % ("x" * 71)), prod), "guard missed a 71 character og:title"
assert check("/", base.replace("og-card.png", "missing-card.png"), prod), "guard missed an unresolved og:image"
assert check("/", re.sub(r'(og:image" content=)"?[^">]*', r'\1"/x"', base), prod), "guard missed a relative og:image"
assert check("/", base.replace("</head>", '<meta name="twitter:site" content="@x"></head>'), prod), "guard missed twitter:site"
try:
    png_size(b"GIF89a" + b"\0" * 30)
    raise SystemExit("guard missed a non-PNG")
except AssertionError:
    pass
bad = bytearray(open(prod + "/brand/og-card.png", "rb").read(32))
bad[16:24] = struct.pack(">II", 1200, 629)
assert png_size(bytes(bad)) != (1200, 630), "size guard broken"
assert parse(sdoc.replace("noindex, nofollow", "index")).robots != ["noindex, nofollow"], "noindex guard broken"
print("PASS: social tags ok (%d pages)" % len(items))
PY
