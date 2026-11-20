#!/usr/bin/env bash
# Targeted test for the /services/ and /who-we-help/ landing pages (issue #88). Builds the site and
# asserts: four service cards and five who-we-help cards with the agreed titles, every card button
# links to a built page (and an existing anchor), every service card shows a price span, the three
# start steps carry FREE, PAID and BUILT stamps, the fit strip links /contact/, the page body keeps its
# links, no page was lost, one h1 and no heading skips, and every .grid has a grid-n class equal to its
# child count. Negative cases prove each guard bites.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" hubs.XXXXXX)" || exit 1
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
python3 -I - "$TMP/out" <<'PY' || fail "hub checks"
import os
import re
import sys
from html.parser import HTMLParser

out = sys.argv[1]
VOID = {"meta", "link", "br", "img", "input", "hr", "source", "wbr"}


class Node:
    def __init__(self, tag, attrs, parent):
        self.tag, self.attrs, self.parent = tag, dict(attrs), parent
        self.kids, self.text = [], []

    def classes(self):
        return (self.attrs.get("class") or "").split()

    def walk(self):
        yield self
        for k in self.kids:
            yield from k.walk()

    def alltext(self):
        return " ".join("".join(self.text).split()) + "".join(" " + k.alltext() for k in self.kids)


class Parser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.root = Node("root", [], None)
        self.cur = self.root

    def handle_starttag(self, tag, attrs):
        n = Node(tag, attrs, self.cur)
        self.cur.kids.append(n)
        if tag not in VOID:
            self.cur = n

    def handle_endtag(self, tag):
        n = self.cur
        while n is not None and n.tag != tag:
            n = n.parent
        if n is not None and n.parent is not None:
            self.cur = n.parent

    def handle_data(self, data):
        self.cur.text.append(data)


def parse(html):
    p = Parser()
    p.feed(html)
    return p.root


def read(rel):
    with open(os.path.join(out, rel.strip("/"), "index.html"), encoding="utf-8") as f:
        return f.read()


def find(root, cls=None, tag=None):
    return [n for n in root.walk() if (cls is None or cls in n.classes()) and (tag is None or n.tag == tag)]


def hrefs(node):
    return [n.attrs.get("href") for n in node.walk() if n.tag == "a" and n.attrs.get("href")]


def ids_of(html):
    return set(re.findall(r'\sid="?([^" >]+)', html))


def link_ok(href):
    path, _, frag = href.partition("#")
    f = os.path.join(out, path.strip("/"), "index.html")
    if not os.path.isfile(f):
        return "link target not built: %s" % href
    if frag:
        with open(f, encoding="utf-8") as fh:
            if frag not in ids_of(fh.read()):
                return "anchor missing on target: %s" % href
    return None


def check_cards(root, titles, count, price):
    errs = []
    cards = find(root, "hub-card")
    if len(cards) != count:
        errs.append("%d hub cards, wanted %d" % (len(cards), count))
    got = [" ".join(find(c, tag="h2")[0].alltext().split()) if find(c, tag="h2") else "" for c in cards]
    if got != titles:
        errs.append("card titles %s, wanted %s" % (got, titles))
    for c, t in zip(cards, got):
        btns = [n for n in find(c, "btn", "a")]
        if len(btns) != 1:
            errs.append("%s: %d buttons" % (t, len(btns)))
            continue
        bad = link_ok(btns[0].attrs.get("href", ""))
        if bad:
            errs.append("%s: %s" % (t, bad))
        if price:
            spans = [n for n in c.walk() if n.tag == "span" and "data-price" in n.attrs]
            if len(spans) != 1 or not spans[0].alltext().strip():
                errs.append("%s: needs exactly one filled price span" % t)
    return errs


def check_grids(root, label):
    errs = []
    grids = find(root, "grid")
    if not grids:
        errs.append("%s: no grid found" % label)
    for g in grids:
        n = len(g.kids)
        want = "grid-n%d" % n
        if want not in g.classes():
            errs.append("%s: grid has %d children but classes %s" % (label, n, g.classes()))
    return errs


def check_headings(root, label):
    errs = []
    levels = [int(n.tag[1]) for n in root.walk() if re.fullmatch(r"h[1-6]", n.tag)]
    if levels.count(1) != 1:
        errs.append("%s: %d h1" % (label, levels.count(1)))
    prev = 0
    for lv in levels:
        if lv > prev + 1:
            errs.append("%s: heading skip h%d to h%d" % (label, prev, lv))
        prev = lv
    return errs


def check_fit(root, label):
    strips = find(root, "fit-strip")
    if len(strips) != 1:
        return ["%s: %d fit strips" % (label, len(strips))]
    return [] if "/contact/" in hrefs(strips[0]) else ["%s: fit strip does not link /contact/" % label]


def check_body(root, label, want):
    body = find(root, "hub-body")
    if len(body) != 1:
        return ["%s: %d hub-body blocks" % (label, len(body))]
    have = hrefs(body[0])
    return ["%s: body lost link %s" % (label, w) for w in want if w not in have]


def check_steps(root):
    steps = find(root, "step")
    stamps = [" ".join(s.alltext().split()) for s in find(root, "stamp")]
    errs = [] if len(steps) == 3 else ["%d start steps, wanted 3" % len(steps)]
    if stamps != ["FREE", "PAID", "BUILT"]:
        errs.append("stamps %s, wanted FREE PAID BUILT" % stamps)
    return errs


SERVICES = ["Security and IT Advisory", "Security Projects", "AI Security Review", "Education and Speaking"]
WHO = ["Small Businesses", "Medical and Dental Practices", "Private Aviation", "Critical Infrastructure", "Ohio Organizations"]

errs = []
svc = parse(read("/services/"))
errs += check_cards(svc, SERVICES, 4, True)
errs += check_grids(svc, "/services/") + check_headings(svc, "/services/") + check_fit(svc, "/services/")
errs += check_steps(svc)
errs += check_body(svc, "/services/", ["/pricing/", "/when-not-to-hire/", "/ohio/"])
who = parse(read("/who-we-help/"))
errs += check_cards(who, WHO, 5, False)
errs += check_grids(who, "/who-we-help/") + check_headings(who, "/who-we-help/") + check_fit(who, "/who-we-help/")
errs += check_body(who, "/who-we-help/", ["/services/", "/contact/"])
for c in find(who, "hub-card"):
    if len(find(c, "hub-quote")) != 1:
        errs.append("who-we-help card lacks one hub-quote")
for p in ("/", "/about/", "/pricing/", "/ohio/", "/when-not-to-hire/", "/how-we-work/", "/experience/", "/community/",
          "/case-studies/", "/services/advisory/", "/services/projects/", "/services/education-speaking/",
          "/who-we-help/small-business/", "/who-we-help/healthcare-dental/", "/who-we-help/aviation/",
          "/who-we-help/critical-infrastructure/", "/contact/"):
    if not os.path.isfile(os.path.join(out, p.strip("/"), "index.html")):
        errs.append("page lost: %s" % p)
if errs:
    print("\n".join(errs))
    sys.exit(1)

# Negative cases: each guard must flag a bad fixture.
card = '<div class="grid grid-n2"><article class="hub-card"><h2>A</h2><a class="btn" href="/nope/">x</a></article></div>'
bad = parse(card)
assert check_cards(bad, ["A"], 1, False), "missing link target guard does not bite"
assert check_cards(bad, ["A", "B"], 2, False), "card count guard does not bite"
assert check_cards(parse('<article class="hub-card"><h2>A</h2><a class="btn" href="/contact/">x</a></article>'), ["A"], 1, True), "price span guard does not bite"
assert check_grids(bad, "x"), "grid-n count guard does not bite"
assert check_grids(parse("<p>none</p>"), "x"), "empty grid guard does not bite"
assert check_headings(parse("<h1>a</h1><h3>b</h3>"), "x"), "heading skip guard does not bite"
assert check_headings(parse("<h1>a</h1><h1>b</h1>"), "x"), "h1 count guard does not bite"
assert check_fit(parse('<div class="fit-strip"><a href="/x/">x</a></div>'), "x"), "fit strip guard does not bite"
assert check_body(parse('<div class="hub-body"><a href="/a/">x</a></div>'), "x", ["/pricing/"]), "body link guard does not bite"
assert check_steps(parse('<ol><li class="step"><span class="stamp">FREE</span></li></ol>')), "step guard does not bite"
print("test-hubs: ok")
PY
echo "PASS: hubs"
