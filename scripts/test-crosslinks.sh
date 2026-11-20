#!/usr/bin/env bash
# Targeted test for the business to personal cross-references (issue #134). Builds production and
# staging, then asserts on the built output:
#   B1  the Person node sameAs equals data/person.toml exactly (home and About, both builds), the JSON
#       parses, the list holds Twitch and Kick together or neither, and the Organization sameAs is the
#       GitHub organization alone;
#   B4/B5  the About credential sentence links https://chiefgyk3d.com/resume/ (one link per target in the
#       body, none to the personal home there), the home block keeps its one link to the personal home;
#   B8  every link to the personal home carries rel="me noopener", the resume link keeps noopener;
#   B7  /llms.txt exists in both builds, equals scripts/fixtures/llms-business.txt with BASE_URL replaced by
#       the apex, starts with the H1, resolves every relative link to a built page, leaves no placeholder,
#       is not in the sitemap and is not blocked by the production robots.txt.
# Negative fixtures mutate a copy of the built output and prove each guard bites.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" crosslinks.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
"$HUGO" --minify --destination "$TMP/prod" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  fail "production build failed"
}
HUGO_PARAMS_ENVIRONMENT=staging "$HUGO" --minify --destination "$TMP/stg" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  fail "staging build failed"
}

cat >"$TMP/check.py" <<'PY'
import json
import os
import re
import sys
import tomllib
from html.parser import HTMLParser

HOME = "https://chiefgyk3d.com/"
RESUME = "https://chiefgyk3d.com/resume/"
APEX = "https://renegadepenguinllc.com"
PERSON = "https://chiefgyk3d.com/#person"


class Anchors(HTMLParser):
    """Anchors with the region they sit in: footer, behind-the-work section or article."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.items = []
        self.stack = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ("footer", "article") or (tag == "section" and a.get("id") == "behind-the-work"):
            self.stack.append((tag, a.get("id") or tag))
        if tag == "a" and a.get("href"):
            region = self.stack[-1][1] if self.stack else "other"
            self.items.append((region, a["href"], (a.get("rel") or "").split()))

    def handle_endtag(self, tag):
        if tag in ("footer", "article", "section") and self.stack and self.stack[-1][0] == tag:
            self.stack.pop()


def anchors(path):
    p = Anchors()
    with open(path, encoding="utf-8") as f:
        p.feed(f.read())
    return p.items


def pages(root):
    for dp, _d, files in os.walk(root):
        for n in files:
            if n.endswith(".html"):
                yield os.path.join(dp, n)


def person_data():
    with open("data/person.toml", "rb") as f:
        return tomllib.load(f)["same_as"]


def graph(path):
    body = open(path, encoding="utf-8").read()
    blocks = re.findall(r'<script[^>]*type="?application/ld\+json"?[^>]*>(.*?)</script>', body, re.S)
    if len(blocks) != 1:
        return None
    return json.loads(blocks[0])["@graph"]


def check_jsonld(root, want):
    errs = []
    if len(want) < 2 or len(set(want)) != len(want) or not all(u.startswith("https://") for u in want):
        errs.append("data/person.toml same_as is not a list of unique https URLs")
    tw = any("twitch.tv" in u for u in want)
    ki = any("kick.com" in u for u in want)
    if tw != ki:
        errs.append("Twitch and Kick must be listed together or not at all")
    for rel in ("index.html", "about/index.html"):
        try:
            g = graph(os.path.join(root, rel))
        except ValueError:
            errs.append(rel + ": JSON-LD does not parse")
            continue
        if g is None:
            errs.append(rel + ": want one ld+json block")
            continue
        persons = [n for n in g if n.get("@type") == "Person"]
        if len(persons) != 1 or persons[0].get("@id") != PERSON:
            errs.append(rel + ": want one Person with the shared id")
            continue
        if persons[0].get("sameAs") != want:
            errs.append(rel + ": Person sameAs differs from data/person.toml")
        orgs = [n for n in g if "Organization" in (n["@type"] if isinstance(n["@type"], list) else [n["@type"]])]
        if len(orgs) != 1 or orgs[0].get("sameAs") != ["https://github.com/Renegade-Penguin"]:
            errs.append(rel + ": Organization sameAs must stay the GitHub organization alone")
    return errs


def check_links(root):
    errs = []
    seen = 0
    for p in pages(root):
        rel = os.path.relpath(p, root)
        items = anchors(p)
        seen += 1
        for region, href, rels in items:
            if href.startswith("https://chiefgyk3d.com"):
                if "noopener" not in rels:
                    errs.append("%s: %s lacks noopener" % (rel, href))
                if href == HOME and "me" not in rels:
                    errs.append("%s: home link in %s lacks rel=me" % (rel, region))
                if href == RESUME and "me" in rels:
                    errs.append("%s: resume link must not carry rel=me" % rel)
        for region in {r for r, _h, _x in items}:
            hrefs = [h for r, h, _x in items if r == region and h.startswith("https://chiefgyk3d.com")]
            if len(hrefs) != len(set(hrefs)):
                errs.append("%s: two links to the same personal URL in %s" % (rel, region))
        footer = [h for r, h, _x in items if r == "footer" and h == HOME]
        if len(footer) != 1:
            errs.append("%s: want one footer link to the personal home, got %d" % (rel, len(footer)))
    if seen < 10:
        errs.append("collected too few pages: %d" % seen)
    about = anchors(os.path.join(root, "about/index.html"))
    body = [(h, x) for r, h, x in about if r == "article"]
    if [h for h, _x in body if h == RESUME] != [RESUME]:
        errs.append("about body: want exactly one link to the resume")
    if any(h == HOME for h, _x in body):
        errs.append("about body: must not link the personal home (one primary link per target)")
    home = anchors(os.path.join(root, "index.html"))
    block = [(h, x) for r, h, x in home if r == "behind-the-work"]
    if [h for h, _x in block] != [HOME]:
        errs.append("home behind block: want exactly one link, to the personal home: %r" % block)
    elif block[0][1] != ["me", "noopener"]:
        errs.append("home behind block: rel must be me noopener: %r" % block)
    for rel in ("index.html", "about/index.html", "pricing/index.html"):
        f = [(h, x) for r, h, x in anchors(os.path.join(root, rel)) if r == "footer" and h == HOME]
        if not f or f[0][1] != ["me", "noopener"]:
            errs.append("%s: footer rel must be me noopener: %r" % (rel, f))
    return errs


def check_llms(root, expected):
    errs = []
    path = os.path.join(root, "llms.txt")
    if not os.path.isfile(path):
        return ["llms.txt missing"]
    text = open(path, encoding="utf-8").read()
    if not text.startswith("# Renegade Penguin LLC\n"):
        errs.append("llms.txt does not start with the H1")
    if "BASE_URL" in text:
        errs.append("llms.txt keeps a BASE_URL placeholder")
    if text.rstrip() != expected.replace("BASE_URL", APEX).rstrip():
        errs.append("llms.txt differs from the approved copy with the apex base")
    targets = re.findall(r"\]\(([^)]+)\)", text)
    rel_targets = [t for t in targets if t.startswith(APEX + "/")]
    if len(rel_targets) < 10:
        errs.append("collected too few site links: %d" % len(rel_targets))
    for t in targets:
        if t.startswith(APEX + "/"):
            d = os.path.join(root, t[len(APEX) + 1:].strip("/"), "index.html")
            if not os.path.isfile(d):
                errs.append("llms.txt link resolves to no built page: " + t)
        elif t != RESUME:
            errs.append("llms.txt links an unexpected target: " + t)
    return errs


def check_policy(root, prod):
    errs = []
    sm = os.path.join(root, "sitemap.xml")
    if os.path.isfile(sm) and "llms" in open(sm, encoding="utf-8").read():
        errs.append("sitemap lists llms.txt")
    if prod:
        robots = open(os.path.join(root, "robots.txt"), encoding="utf-8").read()
        if re.search(r"(?im)^\s*disallow:\s*/llms", robots):
            errs.append("robots.txt blocks llms.txt")
    return errs


def run(root, prod, want, expected):
    return check_jsonld(root, want) + check_links(root) + check_llms(root, expected) + check_policy(root, prod)


if __name__ == "__main__":
    mode, root = sys.argv[1], sys.argv[2]
    expected = open("scripts/fixtures/llms-business.txt", encoding="utf-8").read()
    errs = run(root, mode == "prod", person_data(), expected)
    for e in errs:
        print(e)
    sys.exit(1 if errs else 0)
PY

check() { python3 -I "$TMP/check.py" "$1" "$2"; }
check prod "$TMP/prod" || fail "production cross-reference checks"
check stg "$TMP/stg" || fail "staging cross-reference checks"
# The staging build uses the same apex as the canonical links, never the staging host.
grep -q 'https://renegadepenguinllc.com/about/' "$TMP/stg/llms.txt" || fail "staging llms.txt must use the apex"
if grep -qi 'staging' "$TMP/stg/llms.txt"; then fail "staging llms.txt must not name the staging host"; fi
grep -Eq '<link rel="?canonical"? href="?https://renegadepenguinllc.com/about/' "$TMP/stg/about/index.html" || fail "staging canonical is not the apex (llms.txt base would be inconsistent)"

# Negative fixtures: each mutated copy of the production output must be rejected.
neg() {
  local name="$1" file="$2" expr="$3" kind="${4:-prod}"
  rm -rf "$TMP/neg"
  cp -r "$TMP/prod" "$TMP/neg"
  cp "$TMP/prod/$file" "$TMP/neg/$file.orig"
  sed -E -i "$expr" "$TMP/neg/$file"
  if cmp -s "$TMP/neg/$file" "$TMP/neg/$file.orig"; then
    fail "negative case $name did not change the file"
  fi
  rm "$TMP/neg/$file.orig"
  if check "$kind" "$TMP/neg" >/dev/null; then
    fail "negative case $name was accepted"
  fi
}
neg "sameAs entry dropped" index.html 's#"https://github.com/ChiefGyk3D",?##'
neg "sameAs extra entry" about/index.html 's#"https://twitch.tv/chiefgyk3d"#"https://twitch.tv/chiefgyk3d","https://example.com/x"#'
neg "organization sameAs widened" index.html 's#"sameAs":\["https://github.com/Renegade-Penguin"\]#"sameAs":["https://github.com/Renegade-Penguin","https://chiefgyk3d.com/"]#'
neg "about link back to home" about/index.html 's#href=https://chiefgyk3d.com/resume/#href=https://chiefgyk3d.com/#'
neg "about resume link rel me" about/index.html 's#(href=https://chiefgyk3d.com/resume/) rel=noopener#\1 rel="me noopener"#'
neg "footer rel without me" index.html 's#rel="me noopener">chiefgyk3d.com#rel=noopener>chiefgyk3d.com#'
neg "home block rel without me" index.html 's#class=btn href=https://chiefgyk3d.com/ rel="me noopener"#class=btn href=https://chiefgyk3d.com/ rel=noopener#'
neg "llms placeholder left" llms.txt 's#https://renegadepenguinllc.com/about/#BASE_URL/about/#'
neg "llms link to a missing page" llms.txt 's#renegadepenguinllc.com/pricing/#renegadepenguinllc.com/no-such-page/#'
neg "llms without the H1" llms.txt '1s/^# /## /'
neg "llms copy edited" llms.txt 's/about 16 years/about 17 years/'
neg "llms in the sitemap" sitemap.xml 's#</urlset>#<url><loc>https://renegadepenguinllc.com/llms.txt</loc></url></urlset>#'
neg "robots blocks llms" robots.txt 's#^Allow: /$#Disallow: /llms.txt#'
# A second link to the same personal URL in one block: duplicate the home block link.
rm -rf "$TMP/neg"
cp -r "$TMP/prod" "$TMP/neg"
sed -E -i 's#(<a class=btn href=https://chiefgyk3d.com/ rel="me noopener">[^<]*</a>)#\1 \1#' "$TMP/neg/index.html"
if check prod "$TMP/neg" >/dev/null; then fail "negative case duplicate link in one block was accepted"; fi
# A missing llms.txt.
rm -rf "$TMP/neg"
cp -r "$TMP/prod" "$TMP/neg"
rm "$TMP/neg/llms.txt"
if check prod "$TMP/neg" >/dev/null; then fail "negative case missing llms.txt was accepted"; fi
echo "test-crosslinks: ok"
