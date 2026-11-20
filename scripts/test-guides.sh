#!/usr/bin/env bash
# Targeted test for the guides section (issue #98). Builds the site and asserts: the /guides/ hub and the
# four guide pages exist with the exact titles and seoTitles, the hub links every guide, each guide's first
# paragraph is present, each has at least 3 internal links from the allowed path list and every internal
# link resolves to a built page, each has a Questions section with exactly 4 H3 questions, the sitemap
# lists the hub and the guides, and no page carries an em or en dash. Negative cases prove each guard bites.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" guides.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
"$HUGO" --minify --destination "$TMP/out" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  fail "hugo build failed"
}
python3 -I - "$TMP/out" <<'PY' || fail "guides checks"
import html
import os
import re
import sys

out = sys.argv[1]
DASHES = (chr(0x2014), chr(0x2013))
ALLOWED = {
    "/services/advisory/", "/services/projects/", "/services/education-speaking/", "/services/",
    "/who-we-help/small-business/", "/who-we-help/", "/how-we-work/", "/pricing/",
    "/sample-scope-of-work/", "/contact/", "/when-not-to-hire/", "/ohio/", "/guides/what-is-a-vciso/",
}
HUB = ("/guides/", "Guides", "Cybersecurity Guides | Renegade Penguin")
GUIDES = [
    ("/guides/what-is-a-vciso/", "What Is a Virtual CISO?", "What Is a Virtual CISO? | Renegade Penguin",
     "A virtual chief information security officer, or virtual CISO, provides ongoing security leadership"),
    ("/guides/vciso-vs-vcio/", "Virtual CISO vs. Virtual CIO", "vCISO vs. vCIO: Which Do You Need? | Renegade Penguin",
     "A virtual CISO leads security decisions, while a virtual chief information officer"),
    ("/guides/ai-security-review-small-organizations/", "AI Security Reviews for Small Organizations",
     "AI Security Review Guide | Renegade Penguin", "An AI security review is a fixed-scope examination"),
    ("/guides/why-hands-on-advice-holds-up/", "Why Hands-On Security Advice Holds Up",
     "Why Hands-On Advice Holds Up | Renegade Penguin", "Advice holds up when it accounts for how systems actually behave"),
]


def built(url):
    return os.path.join(out, url.strip("/"), "index.html")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def article(doc):
    m = re.search(r"<article[ >].*?</article>", doc, re.S)
    return m.group(0) if m else ""


def text(frag):
    return html.unescape(re.sub(r"<[^>]+>", "", frag))


def check_page(url, title, seo, first, doc, sitemap):
    errs = []
    t = re.search(r"<title>(.*?)</title>", doc, re.S)
    if not t or html.unescape(t.group(1)) != seo:
        errs.append("%s: <title> is not %r" % (url, seo))
    h1 = re.findall(r"<h1[ >].*?</h1>", doc, re.S)
    if len(h1) != 1 or text(h1[0]) != title:
        errs.append("%s: h1 is not exactly %r" % (url, title))
    art = article(doc)
    if first:
        # The first <p> element after the h1 inside the article must open with the expected sentence.
        after_h1 = art.split("</h1>", 1)[-1]
        p1 = re.search(r"<p[ >].*?</p>", after_h1, re.S)
        if not p1 or not text(p1.group(0)).startswith(first):
            errs.append("%s: the first paragraph does not open with the expected sentence" % url)
    if any(d in doc for d in DASHES):
        errs.append("%s: contains an em or en dash" % url)
    if "<loc>https://" not in sitemap or not re.search(r"<loc>[^<]*" + re.escape(url) + r"</loc>", sitemap):
        errs.append("%s: not in the sitemap" % url)
    if first:  # guide pages only
        links = re.findall(r'<a [^>]*?href="?(/[^" >#]*)', art)
        internal = [l for l in links if l.startswith("/") and not l.startswith("//")]
        good = [l for l in internal if l in ALLOWED]
        if len(set(good)) < 3:
            errs.append("%s: %d distinct allowed internal links, wanted 3 or more" % (url, len(set(good))))
        for l in internal:
            if l not in ALLOWED:
                errs.append("%s: internal link outside the allowed list: %s" % (url, l))
            if not os.path.isfile(built(l)):
                errs.append("%s: internal link does not resolve: %s" % (url, l))
        m = re.search(r"<h2[^>]*>Questions</h2>(.*)$", art, re.S)
        if not m:
            errs.append("%s: no Questions section" % url)
        elif len(re.findall(r"<h3[ >]", m.group(1))) != 4:
            errs.append("%s: Questions section does not have 4 H3 questions" % url)
    return errs


sitemap = read(out + "/sitemap.xml")
errs = []
docs = {}
for url, title, seo, first in GUIDES:
    if not os.path.isfile(built(url)):
        errs.append("%s: not built" % url)
        continue
    docs[url] = read(built(url))
    errs += check_page(url, title, seo, first, docs[url], sitemap)
if not os.path.isfile(built(HUB[0])):
    errs.append("/guides/: not built")
else:
    hub = read(built(HUB[0]))
    errs += check_page(HUB[0], HUB[1], HUB[2], None, hub, sitemap)
    for url, _t, _s, _f in GUIDES:
        if not re.search(r'href="?' + re.escape(url) + r'[" >]', article(hub)):
            errs.append("/guides/: does not link %s" % url)
for e in errs:
    print(e)
assert not errs, "%d violation(s)" % len(errs)
assert len(docs) == 4, "collected %d guide pages, wanted 4" % len(docs)

# negative cases: each guard bites on a mutated copy of a real page
url, title, seo, first = GUIDES[0]
base = docs[url]
def bad(label, mutated, **kw):
    got = check_page(kw.get("url", url), kw.get("title", title), kw.get("seo", seo), first, mutated, kw.get("sm", sitemap))
    assert got, "guard missed: " + label
bad("wrong seoTitle", base, seo="Some Other Title | Renegade Penguin")
bad("wrong h1", base, title="Not The Title")
bad("missing first paragraph", base.replace("provides ongoing security leadership", "provides something"))
# the sentence moved out of the first paragraph into a later one must fail
fp = re.search(r"<p[ >].*?</p>", article(base).split("</h1>", 1)[-1], re.S).group(0)
moved = base.replace(fp, "<p>Some other opening paragraph.</p>", 1).replace("</article>", fp + "</article>", 1)
assert first in text(article(moved)), "negative fixture lost the sentence"
bad("sentence moved to a later paragraph", moved)
bad("dash", base.replace("</article>", " " + DASHES[0] + "</article>"))
bad("not in sitemap", base, sm="<loc>https://x.test/other/</loc>")
bad("broken link", base.replace('href=/services/advisory/', 'href=/services/nope/').replace('href="/services/advisory/"', 'href="/services/nope/"'))
bad("link outside allowed list", base.replace("</article>", '<a href="/ohio/extra/">x</a></article>'))
few = re.sub(r'<a [^>]*?href="?/(?!contact/)[^" >]*"?[^>]*>(.*?)</a>', r"\1", base)
bad("fewer than 3 internal links", few)
bad("no questions section", re.sub(r"<h2[^>]*>Questions</h2>", "<h2>Other</h2>", base))
bad("three questions", re.sub(r"<h3[ >]", "<h4 ", base, count=1))
PY
