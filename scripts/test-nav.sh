#!/usr/bin/env bash
# Targeted test for the data-driven header menu and the slim footer (issue #87). Builds the site and
# asserts: every URL in data/nav.toml resolves in the built site, the header carries no script, every
# dropdown link is in the header HTML, the footer holds exactly the trust links, the nav entries
# flagged footer = true (issue #91) and chiefgyk3d.com, every page that used to be footer-only is
# linked from the header, ids are unique per page and aria-current marks the active page. Negative
# cases prove each guard bites. The popover markup itself is checked by scripts/test-a11y.sh.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" nav.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
"$HUGO" --minify --destination "$TMP/out" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  fail "hugo build failed"
}
python3 -I - "$TMP/out" data/nav.toml <<'PY' || fail "nav checks"
import os
import re
import sys
import tomllib

out, navfile = sys.argv[1], sys.argv[2]
TRUST = ["/privacy/", "/terms/", "/accessibility/", "/security-policy/", "/security-and-handling/",
         "/confidentiality-and-case-studies/", "https://chiefgyk3d.com/"]
# Issue #91: pages that were reachable only through a closed (display:none) panel are linked from the footer.
FOOTER_NAV = ["/who-we-help/", "/case-studies/"]
REMOVED = ["/when-not-to-hire/", "/how-we-work/", "/who-we-help/", "/experience/", "/community/",
           "/sample-scope-of-work/", "/case-studies/", "/ohio/"]


def region(doc, tag):
    m = re.search(r"<%s[ >].*?</%s>" % (tag, tag), doc, re.S)
    return m.group(0) if m else ""


def hrefs(frag):
    return re.findall(r'<a [^>]*?href="?([^" >]+)', frag)


def read(path):
    with open(os.path.join(out, path.strip("/"), "index.html"), encoding="utf-8") as f:
        return f.read()


def check_header_no_script(doc):
    return ["header has a script"] if "<script" in region(doc, "header") else []


def check_footer(doc):
    got = sorted(hrefs(region(doc, "footer")))
    errs = []
    want = sorted(TRUST + FOOTER_NAV)
    if got != want:
        errs.append("footer links %s, wanted %s" % (got, want))
    if len(got) != len(set(got)):
        errs.append("footer repeats a link: %s" % got)
    return errs


def check_triggers(doc, n):
    head = region(doc, "header")
    tags = [t for t in re.findall(r"<button [^>]*>", head) if re.search(r"popovertarget=\"?dd-", t)]
    errs = [] if len(tags) == n else ["%d dropdown triggers, wanted %d" % (len(tags), n)]
    ids = re.findall(r'\sid="?([^" >]+)', head)
    for t in tags:
        c = re.search(r'popovertarget="?([^" >]+)', t)
        if "aria-haspopup" in t:
            errs.append("trigger must not carry aria-haspopup (there is no menu): %s" % t)
        if "aria-expanded" in t:
            errs.append("trigger must not carry aria-expanded: %s" % t)
        if not c or c.group(1) not in ids:
            errs.append("trigger popovertarget does not resolve to a panel id: %s" % t)
    return errs


def check_header_links(doc, urls):
    have = set(hrefs(region(doc, "header")))
    return ["header lacks %s" % u for u in urls if u not in have]


def check_ids(doc):
    ids = re.findall(r'\sid="?([^" >]+)', doc)
    return ["duplicate id %s" % i for i in sorted(set(i for i in ids if ids.count(i) > 1))]


def check_current(doc, path):
    cur = re.findall(r'<a [^>]*?href="?([^" >]+)"?[^>]*aria-current="?page', region(doc, "header"))
    return [] if path in cur else ["aria-current page missing for %s, saw %s" % (path, cur)]


with open(navfile, "rb") as f:
    nav = tomllib.load(f)
groups = nav.get("groups", {})
assert len(groups) == 3, ("expected three groups", list(groups))
urls = []
for g in groups.values():
    assert g["heading"] and g["blurb"] and g["url"] and g["items"], g
    urls.append(g["url"])
    for it in g["items"]:
        assert it["label"] and it["description"] and it["url"], it
        urls.append(it["url"])
assert len(nav["top"]) <= 6, "at most 6 top-level items keep the header on one row at 1440"
urls = sorted(set(urls))
assert len(urls) >= 16, ("too few nav urls", urls)

errs = []
for u in urls:
    if not os.path.isfile(os.path.join(out, u.strip("/"), "index.html")):
        errs.append("nav url not built: %s" % u)
home = read("/")
errs += check_header_no_script(home)
errs += check_footer(home)
errs += check_triggers(home, len(groups))
errs += check_header_links(home, urls + REMOVED)
for p in (u for u in urls):
    doc = read(p)
    errs += ["%s: %s" % (p, e) for e in check_ids(doc) + check_header_no_script(doc) + check_footer(doc)]
for p, label in (("/about/", "about"), ("/services/", "services"), ("/pricing/", "pricing")):
    errs += check_current(read(p), p)
if errs:
    print("\n".join(errs))
    sys.exit(1)

# Negative cases: each guard must flag a bad fixture.
bad_head = "<header><script>x</script></header>"
assert check_header_no_script(bad_head), "script guard does not bite"
bad_foot = "<footer>" + "".join('<a href="%s">x</a>' % u for u in TRUST + ["/ohio/"]) + "</footer>"
assert check_footer(bad_foot), "extra footer link guard does not bite"
assert check_footer("<footer>" + "".join('<a href="%s">x</a>' % u for u in TRUST + [TRUST[0]]) + "</footer>"), "duplicate footer link guard does not bite"
assert check_footer("<footer>" + "".join('<a href="%s">x</a>' % u for u in TRUST[1:]) + "</footer>"), "missing footer link guard does not bite"
assert check_header_links("<header></header>", ["/ohio/"]), "header link guard does not bite"
assert check_ids('<p id="a"></p><p id="a"></p>'), "duplicate id guard does not bite"
assert check_current('<header><a href="/x/">x</a></header>', "/about/"), "aria-current guard does not bite"
assert check_triggers("<header><button popovertarget=nope>x</button></header>", 1), "dangling popovertarget guard does not bite"
assert check_triggers("<header><button popovertarget=dd-x aria-haspopup=true>x</button><div id=dd-x></div></header>", 1), "aria-haspopup guard does not bite"
assert check_triggers("<header><a href=/x/>x</a></header>", 1), "missing trigger guard does not bite"
assert not check_triggers("<header><button type=button popovertarget=dd-x>x</button><div id=dd-x popover></div></header>", 1), "good trigger fixture should pass"
print("test-nav: ok (%d nav urls)" % len(urls))
PY
echo "PASS: nav"
