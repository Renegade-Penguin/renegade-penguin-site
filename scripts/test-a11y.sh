#!/usr/bin/env bash
# Targeted test for the accessibility fixes from the staging audit (issue #91). Builds the site and
# asserts, on every built page: no aria-haspopup; every disclosure trigger is a <button type=button>
# with popovertarget pointing at an existing id that carries a popover attribute; every dropdown
# panel holds links and no other interactive control; the phone Menu is a named popover button
# (no checkbox hack); the footer links /case-studies/ and /who-we-help/ with the nav label text;
# every nav target has a link outside a collapsed panel somewhere on the site; the on-this-page nav
# is named; main takes focus (tabindex -1); the case strip sits in a landmark; the brand image is
# decorative; no executable <script> anywhere in a default build (JSON-LD data excepted) (the CSP stays as it is); on a
# sitekey build (HUGO_PARAMS_TURNSTILESITEKEY=fixturekey) the same rule, except that /contact/ carries exactly the one
# pinned Turnstile tag (the rule test-crosslinks.sh check_scripts and test-pages.sh pin); and the stylesheet
# has a forced-colors rule that keeps the partner logo tiles dark. Negative cases prove each guard bites.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" a11y.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
"$HUGO" --minify --destination "$TMP/out" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  fail "hugo build failed"
}
# The deployed configuration sets the Turnstile sitekey, which adds one script tag on /contact/.
HUGO_PARAMS_TURNSTILESITEKEY=fixturekey "$HUGO" --minify --destination "$TMP/key" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  fail "sitekey build failed"
}
python3 -I - "$TMP/out" data/nav.toml "$TMP/key" <<'PY' || fail "a11y checks"
import os
import re
import sys
import tomllib
from html.parser import HTMLParser

out, navfile, keyout = sys.argv[1], sys.argv[2], sys.argv[3]
VOID = {"meta", "link", "br", "img", "input", "hr", "source", "wbr"}
INTERACTIVE = {"button", "input", "select", "textarea", "summary", "details", "iframe"}


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
        return " ".join(("".join(self.text) + "".join(" " + k.alltext() for k in self.kids)).split())

    def inside(self, pred):
        n = self.parent
        while n is not None:
            if pred(n):
                return True
            n = n.parent
        return False


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


def parse(doc):
    p = Parser()
    p.feed(doc)
    return p.root


def nodes(root, tag=None, cls=None):
    return [n for n in root.walk() if (tag is None or n.tag == tag) and (cls is None or cls in n.classes())]


def is_panel(n):
    return "dropdown" in n.classes()


def check_no_haspopup(root):
    return ["aria-haspopup on <%s>" % n.tag for n in root.walk() if "aria-haspopup" in n.attrs]


def check_triggers(root, n_groups):
    ids = {n.attrs["id"]: n for n in root.walk() if "id" in n.attrs}
    btns = [n for n in root.walk() if "popovertarget" in n.attrs]
    errs = []
    for b in btns:
        t = b.attrs["popovertarget"]
        if b.tag != "button":
            errs.append("popovertarget on <%s>, must be <button>" % b.tag)
        if b.attrs.get("type") != "button":
            errs.append("trigger %s lacks type=button" % t)
        if "aria-expanded" in b.attrs:
            errs.append("trigger %s carries a static aria-expanded" % t)
        if not b.alltext():
            errs.append("trigger %s has no name" % t)
        tgt = ids.get(t)
        if tgt is None:
            errs.append("popovertarget %s does not resolve to an id" % t)
        elif "popover" not in tgt.attrs:
            errs.append("target %s has no popover attribute" % t)
    panels = [b for b in btns if b.attrs.get("popovertarget", "").startswith("dd-")]
    if len(panels) != n_groups:
        errs.append("%d dropdown triggers, wanted %d" % (len(panels), n_groups))
    for n in root.walk():
        if n.tag == "a" and "aria-controls" in n.attrs:
            errs.append("link with aria-controls (old trigger pattern): %s" % n.attrs.get("href"))
        if n.attrs.get("role") in ("group", "menu", "menuitem") and n.inside(lambda p: p.tag == "header"):
            errs.append("role=%s in the header" % n.attrs["role"])
    return errs


def check_panels(root, n_groups):
    ps = [n for n in root.walk() if is_panel(n)]
    errs = [] if len(ps) == n_groups else ["%d panels, wanted %d" % (len(ps), n_groups)]
    for p in ps:
        if "popover" not in p.attrs:
            errs.append("panel %s lacks popover" % p.attrs.get("id"))
        kids = list(p.walk())
        if not any(k.tag == "a" and k.attrs.get("href") for k in kids):
            errs.append("panel %s has no link" % p.attrs.get("id"))
        for k in kids:
            if k.tag in INTERACTIVE or "tabindex" in k.attrs or "onclick" in k.attrs:
                errs.append("panel %s holds a non-link control <%s>" % (p.attrs.get("id"), k.tag))
    return errs


def check_menu_button(root):
    hit = [b for b in root.walk() if b.tag == "button" and b.attrs.get("popovertarget") == "menu-panel"]
    errs = []
    if len(hit) != 1:
        return ["%d Menu buttons, wanted 1" % len(hit)]
    if hit[0].alltext().lower() != "menu":
        errs.append("Menu button name is %r" % hit[0].alltext())
    for n in root.walk():
        if n.tag == "input" and n.attrs.get("type") == "checkbox" and "menu-toggle" in n.classes():
            errs.append("old checkbox hack is still present")
    return errs


def check_footer_links(root, want):
    foot = [n for n in root.walk() if n.tag == "footer"]
    if not foot:
        return ["no footer"]
    got = {}
    for a in foot[0].walk():
        if a.tag == "a" and a.attrs.get("href"):
            got[a.attrs["href"]] = a.alltext()
    return ["footer lacks %s labelled %r (has %r)" % (u, l, got.get(u)) for u, l in want.items() if got.get(u) != l]


def check_reach(roots, urls):
    seen = set()
    for r in roots:
        for a in r.walk():
            if a.tag == "a" and a.attrs.get("href") and not a.inside(is_panel):
                seen.add(a.attrs["href"])
    return ["no link outside a collapsed panel to %s" % u for u in urls if u not in seen]


def check_toc(root):
    errs = []
    for n in root.walk():
        if n.tag == "nav" and n.attrs.get("id") == "TableOfContents":
            if not (n.attrs.get("aria-label") or n.attrs.get("aria-labelledby")):
                errs.append("on-this-page nav has no accessible name")
    return errs


def check_main(root):
    m = nodes(root, "main")
    if len(m) != 1:
        return ["%d main elements" % len(m)]
    return [] if m[0].attrs.get("tabindex") == "-1" else ["main lacks tabindex=-1"]


def check_strip(root):
    errs = []
    for s in nodes(root, cls="case-strip"):
        named = bool(s.attrs.get("aria-label"))
        landmark = (s.tag == "section" and named) or (s.attrs.get("role") == "region" and named)
        if not landmark and not s.inside(lambda p: p.tag in ("header", "main", "footer", "nav")):
            errs.append("case strip is outside any landmark")
    return errs


def check_brand(root):
    errs = []
    for b in nodes(root, cls="brand"):
        for i in b.walk():
            # minify writes alt="" as a bare alt attribute, which parses as None
            if i.tag == "img" and ("alt" not in i.attrs or i.attrs["alt"] not in ("", None)):
                errs.append("brand image must be decorative (alt empty): %r" % i.attrs.get("alt"))
    for n in root.walk():
        if n.tag == "img" and "holding a rifle" in (n.attrs.get("alt") or ""):
            errs.append("verbose mascot alt text: %r" % n.attrs["alt"])
    return errs


# The one script a non-default build may add, on /contact/ only: the exact src with async and defer, the pattern
# scripts/test-crosslinks.sh check_scripts and scripts/test-pages.sh pin (layouts/contact/list.html).
TURNSTILE = {"src": "https://challenges.cloudflare.com/turnstile/v0/api.js", "async": None, "defer": None}


def check_no_script(root, name="", want_ts=False):
    # JSON-LD is data, not executable, and needs no script-src; any other script would. The only exception is the
    # pinned Turnstile tag on contact/index.html in a sitekey build (want_ts), and then it must be the only extra
    # script. Inline content in any non-JSON-LD script is always rejected.
    errs = []
    scripts = nodes(root, "script")
    extra = [n for n in scripts if n.attrs.get("type") != "application/ld+json"]
    if any(n.attrs.get("type") == "application/ld+json" and n.attrs.get("src") for n in scripts):
        errs.append("JSON-LD script with a src")
    if any("".join(n.text).strip() for n in extra):
        errs.append("inline script content")
    allowed = [TURNSTILE] if want_ts and name == "contact/index.html" else []
    if [n.attrs for n in extra] != allowed:
        errs.append("executable <script> in the page")
    return errs


def check_forced_colors(css):
    blocks = re.findall(r"@media\s*\(\s*forced-colors\s*:\s*active\s*\)\s*\{((?:[^{}]*\{[^{}]*\})*)\}", css)
    for b in blocks:
        for sel, body in re.findall(r"([^{}]+)\{([^{}]*)\}", b):
            if ".partner-tile" in sel and re.search(r"forced-color-adjust\s*:\s*none", body) and re.search(r"border[^;]*:[^;]*(CanvasText|ButtonBorder|LinkText|Highlight)", body, re.I):
                return []
    return ["no forced-colors rule keeps .partner-tile dark with forced-color-adjust:none and a system-color border"]


with open(navfile, "rb") as f:
    nav = tomllib.load(f)
groups = nav["groups"]
urls = set()
foot_want = {}
for g in groups.values():
    urls.add(g["url"])
    if g.get("footer"):
        foot_want[g["url"]] = g["label"]
    for it in g["items"]:
        urls.add(it["url"])
        if it.get("footer"):
            foot_want[it["url"]] = it["label"]
assert foot_want.get("/case-studies/") == "Case Studies", ("nav.toml must flag Case Studies for the footer", foot_want)
assert "/who-we-help/" in foot_want, ("nav.toml must flag the Who we help hub for the footer", foot_want)
for t in nav["top"]:
    if "url" in t:
        urls.add(t["url"])

def load_pages(top):
    found = {}
    for dp, _, fs in os.walk(top):
        for fn in fs:
            if fn.endswith(".html"):
                with open(os.path.join(dp, fn), encoding="utf-8") as f:
                    found[os.path.relpath(os.path.join(dp, fn), top)] = parse(f.read())
    return found


pages = load_pages(out)
key_pages = load_pages(keyout)
assert len(key_pages) == len(pages), ("sitekey build has a different page set", len(key_pages), len(pages))
assert len(pages) >= 20, ("too few pages collected", len(pages))
header_pages = {k: v for k, v in pages.items() if nodes(v, "header")}
assert len(header_pages) >= 20, "too few pages with a header"

errs = []
for name, root in pages.items():
    es = check_no_haspopup(root) + check_no_script(root, name) + check_toc(root)
    if name != "404.html":
        es += check_main(root)
    if name in header_pages:
        es += check_triggers(root, len(groups)) + check_panels(root, len(groups)) + check_menu_button(root)
        es += check_strip(root) + check_brand(root) + check_footer_links(root, foot_want)
    errs += ["%s: %s" % (name, e) for e in es]
for name, root in key_pages.items():
    errs += ["sitekey build %s: %s" % (name, e) for e in check_no_script(root, name, True)]
assert [n.attrs for n in nodes(key_pages["contact/index.html"], "script") if n.attrs.get("type") != "application/ld+json"] == [TURNSTILE], "sitekey build lost its Turnstile tag (the positive fixture would prove nothing)"
errs += check_reach(list(pages.values()), sorted(urls))
tocs = [n for r in pages.values() for n in nodes(r, "nav") if n.attrs.get("id") == "TableOfContents"]
assert len(tocs) >= 4, ("expected on-this-page navs to check", len(tocs))

css_files = [os.path.join(dp, fn) for dp, _, fs in os.walk(out) for fn in fs if fn.endswith(".css")]
assert css_files, "no built CSS collected"
css = "".join(open(p, encoding="utf-8").read() for p in css_files)
errs += check_forced_colors(css)
if errs:
    print("\n".join(errs))
    sys.exit(1)

# Negative cases: each guard must flag a bad fixture.
assert check_no_haspopup(parse('<a href="/x/" aria-haspopup="true">x</a>')), "aria-haspopup guard does not bite"
good = '<header><button type="button" popovertarget="dd-a">A</button><div id="dd-a" class="dropdown" popover="auto"><a href="/a/">a</a></div></header>'
assert not check_triggers(parse(good), 1) and not check_panels(parse(good), 1), "good fixture should pass"
assert check_triggers(parse(good.replace("button", "div")), 1), "non-button trigger guard does not bite"
assert check_triggers(parse(good.replace('type="button" ', "")), 1), "missing type=button guard does not bite"
assert check_triggers(parse(good.replace('popovertarget="dd-a"', 'popovertarget="nope"')), 1), "dangling popovertarget guard does not bite"
assert check_triggers(parse(good.replace(' popover="auto"', "")), 1), "missing popover attribute guard does not bite"
assert check_triggers(parse(good.replace(">A<", "><")), 1), "nameless trigger guard does not bite"
assert check_triggers(parse(good.replace('type="button"', 'type="button" aria-expanded="false"')), 1), "static aria-expanded guard does not bite"
assert check_triggers(parse(good), 2), "trigger count guard does not bite"
assert check_triggers(parse('<header><a href="/a/" aria-controls="dd-a">A</a></header>'), 0), "old link trigger guard does not bite"
assert check_triggers(parse('<header><div role="group"></div></header>'), 0), "role=group guard does not bite"
assert check_panels(parse(good.replace('<a href="/a/">a</a>', '<a href="/a/">a</a><button>x</button>')), 1), "panel control guard does not bite"
assert check_panels(parse(good.replace('<a href="/a/">a</a>', "text")), 1), "linkless panel guard does not bite"
assert check_menu_button(parse("<header><label>Menu</label></header>")), "missing Menu button guard does not bite"
assert check_menu_button(parse('<button type="button" popovertarget="menu-panel"></button>')), "nameless Menu button guard does not bite"
assert check_menu_button(parse('<button popovertarget="menu-panel">Menu</button><input class="menu-toggle" type="checkbox">')), "checkbox hack guard does not bite"
assert not check_menu_button(parse('<button popovertarget="menu-panel">Menu</button>')), "good Menu button should pass"
assert check_footer_links(parse('<footer><a href="/case-studies/">Case studies</a></footer>'), {"/case-studies/": "Case Studies"}), "footer label guard does not bite"
assert check_footer_links(parse("<footer></footer>"), {"/case-studies/": "Case Studies"}), "footer link guard does not bite"
assert not check_footer_links(parse('<footer><a href="/case-studies/">Case Studies</a></footer>'), {"/case-studies/": "Case Studies"}), "good footer should pass"
assert check_reach([parse(good)], ["/a/"]), "reach guard does not bite (link only inside a panel)"
assert not check_reach([parse(good + '<footer><a href="/a/">a</a></footer>')], ["/a/"]), "reach good fixture should pass"
assert check_toc(parse('<nav id="TableOfContents"></nav>')), "toc name guard does not bite"
assert not check_toc(parse('<nav id="TableOfContents" aria-label="On this page"></nav>')), "toc good fixture should pass"
assert check_main(parse("<main></main>")), "main tabindex guard does not bite"
assert check_strip(parse('<div class="case-strip"></div>')), "case strip landmark guard does not bite"
assert not check_strip(parse('<section class="case-strip" aria-label="Case file"></section>')), "case strip good fixture should pass"
assert check_brand(parse('<a class="brand"><img alt="Renegade Penguin mascot: a penguin holding a rifle"></a>')), "brand alt guard does not bite"
assert check_brand(parse('<a class="brand"><img src="/x.png"></a>')), "brand missing alt guard does not bite"
assert not check_brand(parse('<a class="brand"><img alt src="/x.png"></a>')) and not check_brand(parse('<a class="brand"><img alt="" src="/x.png"></a>')), "empty alt should pass"
assert check_no_script(parse("<script>x</script>")), "script guard does not bite"
assert check_no_script(parse('<script src="/x.js"></script>')), "script src guard does not bite"
assert check_no_script(parse('<script type="application/ld+json" src="/x.js"></script>')), "ld+json src guard does not bite"
assert not check_no_script(parse('<script type="application/ld+json">{}</script>')), "JSON-LD should be allowed"
TS = '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>'
LD = '<script type="application/ld+json">{}</script>'
C = "contact/index.html"
assert not check_no_script(parse(LD + TS), C, True), "sitekey contact fixture should pass"
assert check_no_script(parse(LD + TS), "community/index.html", True), "Turnstile on another page guard does not bite"
assert check_no_script(parse(LD + TS + '<script src="https://example.com/x.js"></script>'), C, True), "extra script on contact guard does not bite"
assert check_no_script(parse(LD + TS + "<script>x()</script>"), C, True), "inline script on contact guard does not bite"
assert check_no_script(parse(LD + TS.replace("turnstile/v0/api.js", "turnstile/v0/other.js")), C, True), "wrong src guard does not bite"
assert check_no_script(parse(LD + TS.replace(" defer", "")), C, True), "missing defer guard does not bite"
assert check_no_script(parse(LD + TS.replace("</script>", "x()</script>")), C, True), "inline content in the Turnstile tag guard does not bite"
assert check_no_script(parse(LD + TS + TS), C, True), "second Turnstile tag guard does not bite"
assert check_no_script(parse(LD + TS), C, False), "Turnstile tag in the default build guard does not bite"
assert check_no_script(parse(LD + TS), C), "default argument must expect no extra script"
assert check_forced_colors(".partner-tile{background:red}"), "forced-colors guard does not bite (no rule)"
assert check_forced_colors("@media (forced-colors:active){.partner-tile{background:#202020}}"), "forced-colors guard does not bite (no adjust)"
assert not check_forced_colors("@media (forced-colors:active){.partner-tile{forced-color-adjust:none;background:#202020;border:1px solid CanvasText}}"), "forced-colors good fixture should pass"
print("test-a11y: ok (%d pages, %d nav urls)" % (len(pages), len(urls)))
PY
echo "PASS: a11y"
