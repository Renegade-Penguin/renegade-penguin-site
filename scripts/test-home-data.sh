#!/usr/bin/env bash
# Targeted test for the data-driven home page (issue #43, Task 2).
# (a) every data/home section file exists and parses as TOML with the documented schema;
# (b) the home templates hold no literal sentence of 40 or more characters;
# (c) the built home page has one h1, one hero primary button, the sector chips, ten numbered
#     sections and six external repo links, with no owner placeholder, inside "Built in the open";
# (d) a banned claim word placed in a home data file reaches the page and check-claims fails it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" home-data.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
FAILS=0
soft() {
  echo "FAIL: $*" >&2
  FAILS=$((FAILS + 1))
}

python3 -I - <<'PY' || soft "(a) data/home files missing or malformed"
import tomllib

names = ["hero", "what-we-do", "not-typical", "worked-with", "engagement", "no-vendor-pitches", "built-in-the-open",
         "speaking", "pricing-teaser", "behind", "faq"]
for n in names:
    with open("data/home/%s.toml" % n, "rb") as f:
        d = tomllib.load(f)
    for k in ("eyebrow", "title"):
        assert isinstance(d.get(k), str) and d[k].strip(), (n, k)
    if n == "worked-with":
        assert d.get("intro", "").strip(), (n, "intro")
        gs = d.get("groups")
        assert isinstance(gs, list) and len(gs) == 2, (n, "groups")
        for g, want in zip(gs, (5, 3)):
            assert isinstance(g.get("label"), str) and g["label"].strip(), (n, "group label")
            assert isinstance(g.get("items"), list) and len(g["items"]) == want, (n, g.get("label"), "item count")
            for it in g["items"]:
                assert set(it) == {"title"} and it["title"].strip(), (n, "item shape", it)
        assert "note" not in gs[0], (n, "group 1 has no note")
        assert isinstance(gs[1].get("note"), str) and gs[1]["note"].strip(), (n, "group 2 note")
        assert [i["title"] for i in gs[0]["items"]] == ["NetJets", "Cointelegraph", "Henry Schein", "GC Dental", "SML Labs"], gs[0]
        assert [i["title"] for i in gs[1]["items"]] == ["Lorikeet Security", "Call Theory", "Call Center Village"], gs[1]
    if n in ("what-we-do", "not-typical", "engagement", "no-vendor-pitches", "built-in-the-open", "pricing-teaser", "faq"):
        assert isinstance(d.get("items"), list) and d["items"], (n, "items")
        for it in d["items"]:
            assert isinstance(it.get("title"), str) and it["title"].strip(), (n, "item title")
            if n != "no-vendor-pitches":
                assert isinstance(it.get("body"), str) and it["body"].strip(), (n, "item body")
        if n == "built-in-the-open":
            assert len(d["items"]) == 6, (n, len(d["items"]))
            for it in d["items"]:
                assert it.get("url") == "https://github.com/ChiefGyk3D/" + it["title"], (n, it)
                assert "{{OWNER:" not in it["title"] + it["body"], (n, it)
        if n == "not-typical":
            assert len(d["items"]) == 11, (n, len(d["items"]))
            assert d["items"][0]["title"] == "Systems First", d["items"][0]
            assert [i["title"] for i in d["items"]][5:11] == ["Travel Data Exposure", "Darknet Perspective", "Every Angle Tested", "Emerging Technology Tracked", "Beyond Compliance", "Evidence Before Claims"], d["items"]
        if n == "engagement":
            assert [i.get("stamp") for i in d["items"]] == ["FREE", "CREDITED", "DELIVERED"]
b = tomllib.load(open("data/home/behind.toml", "rb"))
assert b["handle"] == "ChiefGyk3D" and b["link_url"] == "https://chiefgyk3d.com/"
assert b["first_name"].strip() and " " not in b["first_name"].strip()
assert tomllib.load(open("data/home/hero.toml", "rb"))["chips"]
assert tomllib.load(open("data/home/hero.toml", "rb"))["intro"].strip().startswith("Renegade Penguin is run by")
PY

python3 -I - <<'PY' || soft "(b) home templates hold a literal sentence"
import glob
import re

files = ["layouts/home.html"] + sorted(glob.glob("layouts/_partials/home-*.html"))
assert len(files) >= 10, files  # home.html plus one partial per section, collected loosely
bad = 0
for p in files:
    s = open(p, encoding="utf-8").read()
    s = re.sub(r"\{\{-?.*?-?\}\}", " ", s, flags=re.S)  # Hugo actions
    s = re.sub(r"<[^>]*>", "\n", s, flags=re.S)  # tags and their attributes
    for line in s.splitlines():
        t = " ".join(line.split())
        if len(t) >= 40:
            print("%s: %s" % (p, t))
            bad += 1
raise SystemExit(1 if bad else 0)
PY

OUT="$TMP/out"
"$HUGO" --minify --destination "$OUT" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  soft "(c) hugo build failed"
}
python3 -I - "$OUT/index.html" <<'PY' || soft "(c) built home page shape"
import sys
import tomllib
from html.parser import HTMLParser

class P(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack = []
        self.h1 = 0
        self.primary_main = 0
        self.chips = []
        self.secs = []
        self.order = []
        self.in_main = False
        self.cur = None
        self.sec_text = {}
        self.sec_idx = None
        self.details = 0
        self.text_for = None
        self.repo_links = []
        self.ww_h3 = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        c = (a.get("class") or "").split()
        if tag == "main":
            self.in_main = True
        if tag == "h1":
            self.h1 += 1
        if self.in_main and tag == "a" and "btn-primary" in c:
            self.primary_main += 1
        if tag == "li" and "chip" in c:
            self.text_for = "chip"
        if tag == "span" and "no" in c and self.in_main:
            self.text_for = "no"
        if tag == "section" and "home-sec" in c:
            self.sec_idx = a.get("id")
            self.order.append(self.sec_idx)
            self.sec_text[self.sec_idx] = ""
        if tag == "h3" and self.sec_idx == "worked-with":
            self.ww_h3 += 1
        if tag == "details":
            self.details += 1
        if tag == "a" and self.sec_idx == "built-in-the-open":
            self.repo_links.append((a.get("href"), a.get("rel")))

    def handle_endtag(self, tag):
        if tag == "main":
            self.in_main = False
        if tag == "section":
            self.sec_idx = None
        if tag in ("li", "span"):
            self.text_for = None

    def handle_data(self, d):
        if self.text_for == "chip":
            self.chips.append(d.strip())
        elif self.text_for == "no":
            self.secs.append(d.strip())
        if self.sec_idx:
            self.sec_text[self.sec_idx] += d

p = P()
p.feed(open(sys.argv[1], encoding="utf-8").read())
hero = tomllib.load(open("data/home/hero.toml", "rb"))
assert p.h1 == 1, "h1 count %d" % p.h1
assert p.primary_main == 1, "hero primary buttons %d" % p.primary_main
assert p.chips == hero["chips"], p.chips
assert len(p.secs) == 10, p.secs
assert [s.lstrip("§") for s in p.secs] == ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10"], p.secs
assert p.order == ["what-we-do", "not-typical", "worked-with", "how-it-works", "no-vendor-pitches", "built-in-the-open", "speaking", "engagement-models", "behind-the-work", "faq"], p.order
assert "{{OWNER:" not in p.sec_text.get("built-in-the-open", ""), "owner placeholder remains"
assert len(p.repo_links) == 6, p.repo_links
assert all(h.startswith("https://github.com/ChiefGyk3D/") and r == "noopener" for h, r in p.repo_links), p.repo_links
assert p.ww_h3 == 2, "worked-with h3 count %d (group labels only)" % p.ww_h3
assert p.details == 5, "faq details %d" % p.details
PY

# (e) adaptive grids: every card grid carries grid-n<count> matching its real child count, and the built
# CSS has the per-count rules, so no row can render an empty cell (issues #59 and #62).
python3 -I - "$OUT" <<'PY' || soft "(e) adaptive grid classes and rules"
import glob
import re
import sys
import tomllib
from html.parser import HTMLParser

out = sys.argv[1]
css = "".join(open(f, encoding="utf-8").read() for f in glob.glob(out + "/**/*.css", recursive=True))
assert css, "no built css collected"
# wide span per item for the counts that exist on the home page, plus the stretch rules
for n, span in ((3, 4), (4, 3), (6, 4), (8, 3), (9, 4), (10, 3), (11, 3), (12, 3)):
    assert re.search(r"\.grid\.grid-n%d>\*(?:,[^{]*)?\{[^}]*span %d" % (n, span), css), "grid-n%d wide rule missing" % n
assert re.search(r"\.grid\.grid-n5>:nth-child\(n\+4\)\{[^}]*span 6", css), "grid-n5 stretch rule missing"
assert re.search(r"\.grid\.grid-n10>:nth-child\(n\+9\)\{[^}]*span 6", css), "grid-n10 stretch rule missing"
assert re.search(r"\.grid\.grid-n11>:nth-child\(n\+9\)\{[^}]*span 4", css), "grid-n11 stretch rule missing"
assert re.search(r"@media[^{]*560px[^{]*\{[^@]*span 12", css), "phone one column rule missing"
assert re.search(r"@media[^{]*900px[^{]*\{[^@]*span 6", css), "medium two column rule missing"
assert re.search(r"@media[^{]*900px[^{]*\{[^@]*:last-child:nth-child\(odd\)[^}]*span 12", css), "medium odd last item rule missing"
assert "grid-six" not in css, "dead grid-six css remains"

sections = {"what-we-do": "what-we-do", "not-typical": "not-typical", "worked-with": "worked-with", "how-it-works": "engagement",
            "no-vendor-pitches": "no-vendor-pitches", "built-in-the-open": "built-in-the-open",
            "engagement-models": "pricing-teaser"}

class G(HTMLParser):
    """Collects, per home-sec id, the grid's class list and direct child count."""
    def __init__(self):
        super().__init__()
        self.sec = None
        self.depth = None
        self.found = {}
        self.cur = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        c = (a.get("class") or "").split()
        if tag == "section" and "home-sec" in c:
            self.sec = a.get("id")
        if self.sec and self.cur is None and "grid" in c:
            self.cur = self.sec
            self.found.setdefault(self.cur, []).append({"classes": c, "children": 0})
            self.depth = 0
            return
        if self.cur is not None:
            if self.depth == 0:
                self.found[self.cur][-1]["children"] += 1
            if tag not in ("br", "img", "input", "hr", "meta", "link"):
                self.depth += 1

    def handle_endtag(self, tag):
        if self.cur is not None:
            if self.depth == 0:
                self.cur = None
            else:
                self.depth -= 1
        if tag == "section":
            self.sec = None

def check(html):
    g = G()
    g.feed(html)
    assert set(g.found) == set(sections), sorted(g.found)
    for sid, grids in g.found.items():
        d = tomllib.load(open("data/home/%s.toml" % sections[sid], "rb"))
        wants = [len(x["items"]) for x in d["groups"]] if "groups" in d else [len(d["items"])]
        assert len(grids) == len(wants), (sid, len(grids), wants)
        for data, want in zip(grids, wants):
            assert data["children"] == want, (sid, data, want)
            assert "grid-n%d" % want in data["classes"], ("count class missing or wrong", sid, data["classes"], want)
    return {s: d[0]["children"] for s, d in g.found.items()}

html = open(out + "/index.html", encoding="utf-8").read()
counts = check(html)
assert {3, 4, 6, 11} <= set(counts.values()), counts
assert counts["not-typical"] == 11, counts
assert counts["worked-with"] == 5, counts
assert "grid-six" not in html
# negative case: the guard bites when a grid loses its count class
for bad in (re.sub(r"grid-n11", "grid-x", html), re.sub(r"grid-n3", "", html, count=1), re.sub(r"grid-n5", "grid-x", html, count=1)):
    try:
        check(bad)
    except AssertionError:
        pass
    else:
        raise SystemExit("guard did not fail on a grid without its count class")
PY

# (d) end to end: a banned word in a home data file reaches the page and check-claims fails it.
S="$TMP/scratch"
mkdir -p "$S"
cp -r hugo.toml content data layouts assets static "$S/"
sed -i 's/^title = "IT is not expensive. IT disasters are."/title = "Guaranteed 100% answers"/' "$S/data/home/hero.toml"
grep -q 'Guaranteed' "$S/data/home/hero.toml" || soft "(d) scratch edit did not apply"
"$HUGO" --source "$S" --destination "$S/out" >/dev/null 2>&1 || soft "(d) scratch build failed"
rc=0
python3 -I scripts/check-claims.py "$S/out" >/dev/null 2>&1 || rc=$?
[ "$rc" = "1" ] || soft "(d) banned word in data/home/hero.toml: check-claims expected exit 1, got $rc"

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS case(s)" >&2
  exit 1
fi
echo "PASS: home data ok"
