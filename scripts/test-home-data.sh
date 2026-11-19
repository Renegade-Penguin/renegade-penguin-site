#!/usr/bin/env bash
# Targeted test for the data-driven home page (issue #43, Task 2).
# (a) every data/home section file exists and parses as TOML with the documented schema;
# (b) the home templates hold no literal sentence of 40 or more characters;
# (c) the built home page has one h1, one hero primary button, the sector chips, nine numbered
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

names = ["hero", "what-we-do", "not-typical", "engagement", "no-vendor-pitches", "built-in-the-open",
         "speaking", "pricing-teaser", "behind", "faq"]
for n in names:
    with open("data/home/%s.toml" % n, "rb") as f:
        d = tomllib.load(f)
    for k in ("eyebrow", "title"):
        assert isinstance(d.get(k), str) and d[k].strip(), (n, k)
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
            assert len(d["items"]) == 6, (n, len(d["items"]))
        if n == "engagement":
            assert [i.get("stamp") for i in d["items"]] == ["FREE", "CREDITED", "DELIVERED"]
b = tomllib.load(open("data/home/behind.toml", "rb"))
assert b["handle"] == "ChiefGyk3D" and b["link_url"] == "https://chiefgyk3d.com/"
assert b["first_name"].strip() and " " not in b["first_name"].strip()
assert tomllib.load(open("data/home/hero.toml", "rb"))["chips"]
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
        self.in_main = False
        self.cur = None
        self.sec_text = {}
        self.sec_idx = None
        self.details = 0
        self.text_for = None
        self.repo_links = []

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
            self.sec_text[self.sec_idx] = ""
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
assert len(p.secs) == 9, p.secs
assert [s.lstrip("§") for s in p.secs] == ["01", "02", "03", "04", "05", "06", "07", "08", "09"], p.secs
assert "{{OWNER:" not in p.sec_text.get("built-in-the-open", ""), "owner placeholder remains"
assert len(p.repo_links) == 6, p.repo_links
assert all(h.startswith("https://github.com/ChiefGyk3D/") and r == "noopener" for h, r in p.repo_links), p.repo_links
assert p.details == 5, "faq details %d" % p.details
PY

# (d) end to end: a banned word in a home data file reaches the page and check-claims fails it.
S="$TMP/scratch"
mkdir -p "$S"
cp -r hugo.toml content data layouts assets static "$S/"
sed -i 's/^title = "Cold answers. Clear risk."/title = "Guaranteed 100% answers"/' "$S/data/home/hero.toml"
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
