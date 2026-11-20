#!/usr/bin/env bash
# Targeted test for contextual internal links (issue #96). Builds the site and asserts: every leaf page
# among the services, pricing, Ohio, how-we-work, when-not-to-hire, sample scope, who-we-help leaves,
# guides leaves, about and experience pages receives at least 2 contextual inbound links from other pages
# (links inside the article body only: never the header nav, footer, next-steps panel, on-this-page list,
# the auto-rendered page list on list pages, the FAQ block or hub cards); each of the 14 pages carries its
# sentence verbatim as the last paragraph of the article body; every internal link in those sentences
# resolves to a built page; none of them links to its own page. Negative cases prove each guard bites.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" links.XXXXXX)" || exit 1
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
python3 -I - "$TMP/out" <<'PY' || fail "contextual link checks"
import html
import os
import re
import sys

out = sys.argv[1]
MIN_INBOUND = 2
FIXED = [
    "/services/advisory/", "/services/projects/", "/services/education-speaking/", "/pricing/", "/ohio/",
    "/how-we-work/", "/when-not-to-hire/", "/sample-scope-of-work/", "/about/", "/experience/",
]
SENTENCES = {
    "/services/advisory/": "Learn [what a virtual CISO does](/guides/what-is-a-vciso/), compare [virtual CISO and virtual CIO roles](/guides/vciso-vs-vcio/), review a [sample retainer scope](/sample-scope-of-work/), or consider [when not to hire](/when-not-to-hire/).",
    "/services/projects/": "Read the [AI security review guide](/guides/ai-security-review-small-organizations/), see [how engagements run](/how-we-work/), review [pricing and assessments](/pricing/), or consider [ongoing advisory support](/services/advisory/).",
    "/services/education-speaking/": "Learn [about Renegade Penguin](/about/), review [relevant experience](/experience/), explore [pricing and assessments](/pricing/), or [schedule a free fit call](/contact/).",
    "/pricing/": "For more context, read [what a virtual CISO does](/guides/what-is-a-vciso/), review a [sample retainer scope](/sample-scope-of-work/), see [how engagements run](/how-we-work/), and consider [when not to hire](/when-not-to-hire/).",
    "/how-we-work/": "Next, explore [what a virtual CISO does](/guides/what-is-a-vciso/), review [ongoing advisory support](/services/advisory/) and a [sample retainer scope](/sample-scope-of-work/), or see [pricing and assessments](/pricing/).",
    "/when-not-to-hire/": "You can also compare [virtual CISO and virtual CIO roles](/guides/vciso-vs-vcio/), explore [fixed-scope security projects](/services/projects/), see [support for small businesses](/who-we-help/small-business/), or review [pricing and assessments](/pricing/).",
    "/sample-scope-of-work/": "To place this scope in context, explore [ongoing advisory support](/services/advisory/), read [what a virtual CISO does](/guides/what-is-a-vciso/), review [pricing and assessments](/pricing/), and see [how engagements run](/how-we-work/).",
    "/ohio/": "Ohio organizations can explore [small-business security support](/who-we-help/small-business/), [ongoing advisory services](/services/advisory/), and [fixed-scope security projects](/services/projects/), then [schedule a free fit call](/contact/).",
    "/who-we-help/small-business/": "Small-business leaders can learn [what a virtual CISO does](/guides/what-is-a-vciso/), compare [virtual CISO and virtual CIO roles](/guides/vciso-vs-vcio/), explore [ongoing advisory support](/services/advisory/), and review [pricing and assessments](/pricing/).",
    "/who-we-help/healthcare-dental/": "Healthcare and dental teams can read the [AI security review guide](/guides/ai-security-review-small-organizations/), explore [fixed-scope security projects](/services/projects/), review [Ohio cybersecurity framework guidance](/ohio/), and see [pricing and assessments](/pricing/).",
    "/who-we-help/aviation/": "Aviation organizations can explore [ongoing advisory support](/services/advisory/), review [fixed-scope security projects](/services/projects/) and [relevant experience](/experience/), or [schedule a free fit call](/contact/).",
    "/who-we-help/critical-infrastructure/": "Critical infrastructure teams can explore [ongoing advisory support](/services/advisory/), review [fixed-scope security projects](/services/projects/), compare [virtual CISO and virtual CIO roles](/guides/vciso-vs-vcio/), or [schedule a free fit call](/contact/).",
    "/about/": "For more context, review [relevant experience](/experience/), explore [ongoing advisory support](/services/advisory/), learn [what a virtual CISO does](/guides/what-is-a-vciso/), or see [who Renegade Penguin helps](/who-we-help/).",
    "/experience/": "Learn more [about Renegade Penguin](/about/), explore [ongoing advisory support](/services/advisory/) and [fixed-scope security projects](/services/projects/), or read the [AI security review guide](/guides/ai-security-review-small-organizations/).",
}
LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


def built(url):
    path = os.path.join(out, url.strip("/"), "index.html")
    return os.path.isfile(path)


def read(url):
    with open(os.path.join(out, url.strip("/"), "index.html"), encoding="utf-8") as f:
        return f.read()


def article(doc):
    """The page article (not hub pages): from its opening tag to the last closing tag."""
    m = re.search(r'<article class="?page"?>', doc)
    if not m:
        return None
    end = doc.rfind("</article>")
    return doc[m.end():end] if end > m.end() else None


def body(art):
    """Article body: the article minus the FAQ block and the auto-rendered page list."""
    art = re.sub(r"<section class=\"?page-faq\"?[ >].*?</section>", "", art, flags=re.S)
    art = re.sub(r"<ul class=\"?page-list\"?>.*?</ul>", "", art, flags=re.S)
    return art


def hrefs(frag):
    return re.findall(r'<a [^>]*?href="?([^" >]+)', frag)


def last_paragraph(frag):
    paras = re.findall(r"<p(?: [^>]*)?>(.*?)</p>", frag, re.S)
    if not paras:
        return None
    p = paras[-1]
    p = re.sub(r'<a [^>]*?href="?([^" >]+)"?[^>]*>(.*?)</a>', lambda m: "[%s](%s)" % (m.group(2), m.group(1)), p)
    text = html.unescape(re.sub(r"<[^>]+>", "", p))
    # The link render hook puts a newline after each anchor; whitespace there is not content.
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"\) ([,.])", r")\1", text)


def inbound(pages):
    """pages: url -> document. Returns url -> sorted list of other pages with a contextual link to it."""
    got = {}
    for src, doc in pages.items():
        art = article(doc)
        if art is None:
            continue
        for h in set(hrefs(body(art))):
            h = h.split("#")[0]
            if h != src:
                got.setdefault(h, set()).add(src)
    return {k: sorted(v) for k, v in got.items()}


def check_inbound(pages, leaves):
    got = inbound(pages)
    errs = []
    for leaf in leaves:
        if len(got.get(leaf, [])) < MIN_INBOUND:
            errs.append("%s: %d contextual inbound links, wanted at least %d" % (leaf, len(got.get(leaf, [])), MIN_INBOUND))
    return errs


def check_sentence(url, doc, sentence, exists):
    art = article(doc)
    if art is None:
        return ["%s: no page article" % url]
    errs = []
    if last_paragraph(body(art)) != sentence:
        errs.append("%s: last body paragraph is not the sentence verbatim" % url)
    for text, target in LINK.findall(sentence):
        if target == url:
            errs.append("%s: sentence links to itself" % url)
        if not exists(target):
            errs.append("%s: sentence link does not resolve: %s" % (url, target))
    return errs


def leaves_of(section):
    base = os.path.join(out, section)
    return ["/%s/%s/" % (section, d) for d in sorted(os.listdir(base)) if os.path.isfile(os.path.join(base, d, "index.html"))]


# ---- real site ----
leaves = FIXED + leaves_of("who-we-help") + leaves_of("guides")
leaves = [u for u in leaves if built(u)]
if len(leaves) < 17:
    print("FAIL: collected only %d leaves: %s" % (len(leaves), leaves))
    sys.exit(1)
pages = {}
for root, _dirs, files in os.walk(out):
    if "index.html" in files:
        url = "/" + os.path.relpath(root, out).strip(".") + "/"
        url = "/" if url == "//" else url.replace("//", "/")
        with open(os.path.join(root, "index.html"), encoding="utf-8") as f:
            pages[url] = f.read()
for u in leaves:
    if u not in pages:
        print("FAIL: leaf not found among built pages: " + u)
        sys.exit(1)
errs = check_inbound(pages, leaves)
got = inbound(pages)
print("inbound contextual links per page:")
for u in leaves:
    print("  %2d  %s  <- %s" % (len(got.get(u, [])), u, ", ".join(got.get(u, []))))
if len(SENTENCES) != 14:
    errs.append("expected 14 sentences, have %d" % len(SENTENCES))
for url, sentence in SENTENCES.items():
    if url not in pages:
        errs.append("%s: page not built" % url)
        continue
    errs += check_sentence(url, pages[url], sentence, built)
for e in errs:
    print("FAIL: " + e)
# The negative cases below run even when the real site fails, so a red run still proves the guards bite.

# ---- negative cases: each guard must bite on a synthetic input ----
NAV = "<header><nav><a href=/a/>A</a><a href=/b/>B</a></nav></header>"
NEXT = "</article><section class=next-steps><ul><li><a href=/a/>A</a></ul></section>"


def page(inner):
    return NAV + "<article class=page><h1>t</h1>" + inner + NEXT


def neg(name, errs_list):
    if not errs_list:
        print("FAIL: negative case did not bite: " + name)
        sys.exit(1)


good = {
    "/x/": page("<p>See <a href=/a/>A</a>.</p>"),
    "/y/": page("<p>See <a href=/a/>A</a>.</p>"),
    "/a/": page("<p>leaf</p>"),
}
if check_inbound(good, ["/a/"]):
    print("FAIL: synthetic good inbound case flagged")
    sys.exit(1)
neg("one inbound link only", check_inbound({"/x/": good["/x/"], "/a/": good["/a/"]}, ["/a/"]))
neg("nav-only link does not count", check_inbound({"/x/": page("<p>none</p>"), "/y/": page("<p>none</p>"), "/a/": good["/a/"]}, ["/a/"]))
neg("next-steps link does not count", check_inbound({"/x/": page("<p>none</p>"), "/y/": page("<p>none</p>"), "/a/": good["/a/"]}, ["/a/"]))
listed = page("<p>x</p><ul class=page-list><li><a href=/a/>A</a></ul>")
neg("page-list link does not count", check_inbound({"/x/": listed, "/y/": listed, "/a/": good["/a/"]}, ["/a/"]))
faq = page("<p>x</p><section class=page-faq><p><a href=/a/>A</a></p></section>")
neg("faq link does not count", check_inbound({"/x/": faq, "/y/": faq, "/a/": good["/a/"]}, ["/a/"]))
selfp = page("<p><a href=/a/>A</a></p>")
neg("self link does not count", check_inbound({"/a/": selfp, "/y/": good["/y/"]}, ["/a/"]))
sent = "See [A](/a/) and [B](/b/)."
okdoc = page("<p>x</p><p>See <a href=/a/>A</a> and <a href=/b/>B</a>.</p>")
if check_sentence("/z/", okdoc, sent, lambda t: True):
    print("FAIL: synthetic good sentence case flagged")
    sys.exit(1)
neg("sentence not last", check_sentence("/z/", page("<p>See <a href=/a/>A</a> and <a href=/b/>B</a>.</p><p>after</p>"), sent, lambda t: True))
neg("sentence altered", check_sentence("/z/", page("<p>See <a href=/a/>A</a> and <a href=/b/>C</a>.</p>"), sent, lambda t: True))
neg("sentence missing link", check_sentence("/z/", page("<p>See A and B.</p>"), sent, lambda t: True))
neg("unresolved link", check_sentence("/z/", okdoc, sent, lambda t: t != "/b/"))
neg("self link in sentence", check_sentence("/a/", okdoc, sent, lambda t: True))
neg("no article", check_sentence("/z/", "<p>x</p>", sent, lambda t: True))
if errs:
    sys.exit(1)
print("test-links: ok")
PY
