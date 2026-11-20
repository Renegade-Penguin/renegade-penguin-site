#!/usr/bin/env bash
# Targeted test for the next-steps panel and the on-this-page panel (issue #93). Builds the site and
# asserts: every page listed as an item in data/nav.toml (and no other page) has exactly one next-steps
# panel with 1 to 4 related links that resolve, never point at the page itself, plus a Book a Fit Call
# button to /contact/; every page with 3 or more H2s in its article (hub, home, contact and 404 pages
# excepted) has an on-this-page nav whose links all resolve to heading ids on that page; ids are unique;
# the panels add no script tags. Negative cases prove each guard bites.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" nextsteps.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
build_fail() {
  cat "$TMP/build.err" >&2
  fail "hugo build failed"
}
"$HUGO" --minify --destination "$TMP/out" >/dev/null 2>"$TMP/build.err" || build_fail
python3 -I - "$TMP/out" data/nav.toml <<'PY' || fail "next-steps checks"
import os
import re
import sys
import tomllib

out, navfile = sys.argv[1], sys.argv[2]
# Pages that never get the panel or the on-this-page nav (hubs have their own fit strip and cards).
EXEMPT_TOC = {"/", "/services/", "/who-we-help/", "/contact/", "/contact/thanks/", "/404.html"}


def built(url):
    path = os.path.join(out, url.strip("/"), "index.html") if url != "/404.html" else os.path.join(out, "404.html")
    return path if os.path.isfile(path) else None


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def panels(doc):
    return re.findall(r"<section class=\"?next-steps\"?[ >].*?</section>", doc, re.S)


def hrefs(frag):
    return re.findall(r'<a [^>]*?href="?([^" >]+)', frag)


def check_panel(doc, url, expected):
    found = panels(doc)
    if not expected:
        return ["%s: has a next-steps panel but is not in the list" % url] if found else []
    if len(found) != 1:
        return ["%s: %d next-steps panels, wanted 1" % (url, len(found))]
    errs = []
    panel = found[0]
    related = re.findall(r"<li><a [^>]*?href=\"?([^\" >]+)", panel)
    if not 1 <= len(related) <= 4:
        errs.append("%s: %d related links, wanted 1 to 4" % (url, len(related)))
    if len(set(related)) != len(related):
        errs.append("%s: related links repeat: %s" % (url, related))
    for r in related:
        if r == url:
            errs.append("%s: related links include the page itself" % url)
        if not built(r):
            errs.append("%s: related link does not resolve: %s" % (url, r))
    if "/contact/" not in hrefs(panel):
        errs.append("%s: panel has no /contact/ button" % url)
    if "<script" in panel:
        errs.append("%s: panel has a script" % url)
    return errs


def check_toc(doc, url):
    art = re.search(r"<article[ >].*?</article>", doc, re.S)
    n = len(re.findall(r"<h2[ >]", art.group(0))) if art else 0
    asides = re.findall(r"<aside class=\"?page-toc\"?[ >].*?</aside>", doc, re.S)
    if n < 3:
        return ["%s: %d H2s but has an on-this-page nav" % (url, n)] if asides else []
    if len(asides) != 1:
        return ["%s: %d H2s, %d on-this-page navs, wanted 1" % (url, n, len(asides))]
    ids = set(re.findall(r'\sid="?([^" >]+)', doc))
    links = re.findall(r'<a [^>]*?href="?#([^" >]+)', re.search(r"<nav[ >].*?</nav>", asides[0], re.S).group(0)) if "<nav" in asides[0] else []
    errs = []
    if len(links) != n:
        errs.append("%s: %d H2s but %d on-this-page links" % (url, n, len(links)))
    for l in links:
        if l not in ids:
            errs.append("%s: on-this-page link #%s has no matching id" % (url, l))
    if "#main" not in [h for h in re.findall(r'href="?(#[^" >]+)', asides[0])] or "main" not in ids:
        errs.append("%s: back to top link does not resolve" % url)
    return errs


def check_ids(doc, url):
    ids = re.findall(r'\sid="?([^" >]+)', doc)
    return ["%s: duplicate id %s" % (url, i) for i in sorted(set(i for i in ids if ids.count(i) > 1))]


with open(navfile, "rb") as f:
    nav = tomllib.load(f)
listed = sorted({it["url"] for g in nav["groups"].values() for it in g["items"]})
assert len(listed) >= 16, ("too few listed pages", listed)

pages = []
for root, _dirs, files in os.walk(out):
    if "index.html" in files:
        rel = os.path.relpath(root, out)
        pages.append("/" if rel == "." else "/%s/" % rel)
if os.path.isfile(os.path.join(out, "404.html")):
    pages.append("/404.html")
assert len(pages) >= 20, ("too few built pages", pages)

errs = []
for u in listed:
    if not built(u):
        errs.append("listed page not built: %s" % u)
tocs = 0
for p in pages:
    doc = read(built(p))
    errs += check_panel(doc, p, p in listed)
    errs += check_ids(doc, p)
    if p not in EXEMPT_TOC:
        errs += check_toc(doc, p)
        tocs += len(re.findall(r"<aside class=\"?page-toc", doc))
    elif "page-toc" in doc:
        errs.append("%s: exempt page has an on-this-page nav" % p)
assert tocs >= 8, ("too few on-this-page navs built", tocs)
for trust in ("/privacy/", "/terms/", "/security-and-handling/"):
    if 'class=page-toc' not in read(built(trust)) and 'class="page-toc"' not in read(built(trust)):
        errs.append("%s: trust page lacks the on-this-page nav" % trust)
if errs:
    print("\n".join(errs))
    sys.exit(1)

# Negative cases: each guard must flag a bad fixture.
good = '<section class=next-steps><ul><li><a href=/pricing/>P</a></li></ul><a href=/contact/>B</a></section>'
assert not check_panel(good, "/about/", True), "good panel fixture must pass"
assert check_panel("<main></main>", "/about/", True), "missing panel guard does not bite"
assert check_panel(good + good, "/about/", True), "duplicate panel guard does not bite"
assert check_panel(good, "/privacy/", False), "unlisted page panel guard does not bite"
assert check_panel(good.replace("/pricing/", "/about/"), "/about/", True), "self link guard does not bite"
assert check_panel(good.replace("/pricing/", "/nope/"), "/about/", True), "dead link guard does not bite"
assert check_panel(good.replace("/contact/", "/x/"), "/about/", True), "CTA guard does not bite"
many = '<section class=next-steps><ul>' + "".join('<li><a href=/pricing/>P</a></li>' for _ in range(5)) + '</ul><a href=/contact/>B</a></section>'
assert check_panel(many, "/about/", True), "link count guard does not bite"
assert check_panel(good.replace("</section>", "<script>x</script></section>"), "/about/", True), "script guard does not bite"
art = "<article><h2 id=a>A</h2><h2 id=b>B</h2><h2 id=c>C</h2></article>"
aside = "<aside class=page-toc><nav><ul><li><a href=#a>A</a></li><li><a href=#b>B</a></li><li><a href=#c>C</a></li></ul></nav><a href=#main>T</a></aside>"
okdoc = "<main id=main>" + art + aside + "</main>"
assert not check_toc(okdoc, "/x/"), ("good toc fixture must pass", check_toc(okdoc, "/x/"))
assert check_toc("<main id=main>" + art + "</main>", "/x/"), "missing toc guard does not bite"
assert check_toc(okdoc.replace("href=#c", "href=#zzz"), "/x/"), "dead toc link guard does not bite"
assert check_toc(okdoc.replace("<li><a href=#c>C</a></li>", ""), "/x/"), "toc link count guard does not bite"
assert check_toc(okdoc.replace('id=main', 'id=other'), "/x/"), "back to top guard does not bite"
assert check_toc("<main id=main><article><h2 id=a>A</h2></article>" + aside + "</main>", "/x/"), "toc on short page guard does not bite"
assert check_ids('<p id="a"></p><p id="a"></p>', "/x/"), "duplicate id guard does not bite"
print("test-nextsteps: ok (%d listed pages, %d on-this-page navs)" % (len(listed), tocs))
PY
echo "PASS: nextsteps"
