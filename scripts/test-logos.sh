#!/usr/bin/env bash
# Targeted test for the partner logos (issue #120).
# (1)(2) static/brand/partners/ holds only the allowed files, each with a provenance entry and a
#        matching sha256, each a valid PNG or a sanitized SVG, under 150 KB (scripts/check-logos.py);
# (3) the built home page renders eight uniform tiles and the Experience page five, every logo image
#     has alt text, width and height, and no <img> src is external;
# (4) no built CSS rule applies filter, opacity, blend, mask or transform to the logo images;
# (5) the light fill check still passes with the new tiles;
# (6) negative fixtures: an unprovenanced file, a modified byte, a bad SVG and bad CSS each fail.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" logos.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
FAILS=0
soft() {
  echo "FAIL: $*" >&2
  FAILS=$((FAILS + 1))
}

# (1)(2) the real tree.
python3 -I scripts/check-logos.py . || soft "(1)(2) logo files and provenance"

# (6) negative fixtures on a scratch copy of the tree.
F="$TMP/fx"
mkdir -p "$F/static/brand" "$F/docs" || exit 1
cp -r static/brand/partners "$F/static/brand/" || soft "(6) fixture copy"
cp docs/logo-provenance.md "$F/docs/" || soft "(6) fixture copy"
python3 -I scripts/check-logos.py "$F" >/dev/null || soft "(6) the untouched fixture copy must pass"
cp static/brand/penguin-color.png "$F/static/brand/partners/netjets.png"
rc=0
python3 -I scripts/check-logos.py "$F" >"$TMP/neg1.out" || rc=$?
[ "$rc" = "1" ] || soft "(6) an unprovenanced file must exit 1, got $rc"
grep -q "netjets.png has no provenance entry" "$TMP/neg1.out" || soft "(6) the unprovenanced file was not named"
rm -f "$F/static/brand/partners/netjets.png"
printf 'x' >>"$F/static/brand/partners/cointelegraph.png"
rc=0
python3 -I scripts/check-logos.py "$F" >"$TMP/neg2.out" || rc=$?
[ "$rc" = "1" ] || soft "(6) a modified byte must exit 1, got $rc"
grep -q "cointelegraph.png sha256" "$TMP/neg2.out" || soft "(6) the modified file was not named"
python3 -I - <<'PY' || soft "(6) svg and css guard negatives"
import importlib.util

spec = importlib.util.spec_from_file_location("cl", "scripts/check-logos.py")
cl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cl)
assert cl.svg_problems('<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h4v4z"/></svg>') == []
for bad in ('<svg><script>1</script></svg>', '<svg><foreignObject/></svg>', '<svg onload="x()"/>',
            '<svg><image href="https://x.example/a.png"/></svg>', '<svg><use href="https://x.example/a.svg#a"/></svg>'):
    assert cl.svg_problems(bad), bad
PY

# Build the site once for (3) and (4).
OUT="$TMP/out"
"$HUGO" --minify --destination "$OUT" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  soft "hugo build failed"
}

# (3) and (4): the built pages and CSS.
python3 -I - "$OUT" <<'PY' || soft "(3)(4) built pages and CSS"
import glob
import re
import struct
import sys
import tomllib
from html.parser import HTMLParser

out = sys.argv[1]
data = tomllib.load(open("data/home/worked-with.toml", "rb"))
names = [i["title"] for g in data["groups"] for i in g["items"]]
assert len(names) == 8, names
logos = {i["title"]: i for g in data["groups"] for i in g["items"] if "logo" in i}
assert sorted(logos) == ["Cointelegraph", "Lorikeet Security"], sorted(logos)
# Smallest size each organization's own terms allow, as the display size set by the width and height
# attributes: Lorikeet, 140 px wide; Cointelegraph, 32 points (about 43 px) for the mark, which fills
# about 62 percent of the height of the supplied PNG, so the image height must be at least 70 px.
MIN = {"Lorikeet Security": ("width", 140), "Cointelegraph": ("height", 70)}


class T(HTMLParser):
    """Collects the partner tiles (li.partner-tile) and every img on the page."""

    def __init__(self):
        super().__init__()
        self.tiles = []
        self.cur = None
        self.imgs = []
        self.list_ok = []
        self.stack = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        c = (a.get("class") or "").split()
        self.stack.append((tag, c))
        if tag == "li" and "partner-tile" in c:
            self.cur = {"text": "", "img": None}
            self.tiles.append(self.cur)
            self.list_ok.append(any(t == "ul" and "partner-tiles" in cc for t, cc in self.stack[:-1]))
        if tag == "img":
            self.imgs.append(a)
            if self.cur is not None:
                self.cur["img"] = a

    def handle_endtag(self, tag):
        if self.stack:
            self.stack.pop()
        if tag == "li":
            self.cur = None

    def handle_data(self, d):
        if self.cur is not None:
            self.cur["text"] += d


def parse(path):
    t = T()
    t.feed(open(path, encoding="utf-8").read())
    return t


def check(t, want):
    assert len(t.tiles) == want, "tile count %d, wanted %d" % (len(t.tiles), want)
    assert all(t.list_ok), "a tile is outside ul.partner-tiles"
    seen = []
    for tile in t.tiles:
        img = tile["img"]
        if img is None:
            name = " ".join(tile["text"].split())
            assert name in names and name not in logos, ("text tile is not a text-only organization", name)
        else:
            name = img.get("alt", "")
            assert name in logos, ("logo alt is not a logo organization", name)
            assert tile["text"].strip() == "", ("logo tile also carries text, read twice", name, tile["text"])
            assert img["src"] == logos[name]["logo"], (img["src"], logos[name])
            for k in ("width", "height"):
                assert re.fullmatch(r"[1-9][0-9]*", img.get(k, "")), (name, k, img.get(k))
            assert img.get("decoding") == "async", (name, "decoding")
            key, floor = MIN[name]
            assert int(img[key]) >= floor, (name, key, img[key], floor)
            ratio = int(img["width"]) / int(img["height"])
            sw, sh = struct.unpack(">II", open("static" + logos[name]["logo"], "rb").read()[16:24])
            assert abs(ratio - sw / sh) < 0.02, (name, "aspect ratio changed", ratio, sw / sh)
        seen.append(name)
    assert len(set(seen)) == len(seen), ("a tile appears twice", seen)
    for img in t.imgs:
        src = img.get("src", "")
        assert src.startswith("/") and not src.startswith("//"), ("external or relative img src", src)
        assert img.get("alt", "").strip(), ("img without alt", src)
    return seen


home = parse(out + "/index.html")
seen = check(home, 8)
assert sorted(seen) == sorted(names), (sorted(seen), sorted(names))
exp = parse(out + "/experience/index.html")
past = [i["title"] for i in data["groups"][0]["items"]]
assert check(exp, 5) == past, "experience tiles are not the five past organizations in order"
assert any(img.get("src", "").startswith("/brand/partners/") for img in home.imgs), "no logo img collected"

# Negative: the guard bites on a missing alt, an external src and a missing tile.
html = open(out + "/index.html", encoding="utf-8").read()
for label, bad in (
    ("no alt", re.sub(r'alt="?Lorikeet Security"?', 'alt=""', html)),
    ("external src", re.sub(r'src=("?)/brand/partners/', r'src=\1https://x.example/brand/partners/', html, count=1)),
    ("missing tile", re.sub(r"<li[^>]*partner-tile[^>]*>", "<li>", html, count=1)),
):
    t = T()
    t.feed(bad)
    try:
        check(t, 8)
    except AssertionError:
        pass
    else:
        raise SystemExit("guard did not fail on: " + label)

# (4) CSS: no effect on the logo images.
css = "".join(open(f, encoding="utf-8").read() for f in glob.glob(out + "/**/*.css", recursive=True))
assert css, "no built css collected"
EFFECT = re.compile(r"(?:^|[;{\s])(?:filter|backdrop-filter|opacity|mix-blend-mode|mask[a-z-]*|transform|rotate|scale|object-position|clip-path)\s*:")


def effects(sheet):
    bad = []
    for sel, body in re.findall(r"([^{}@]+)\{([^{}]*)\}", sheet):
        if "partner-logo" in sel and EFFECT.search(";" + body):
            bad.append((sel.strip(), body))
    return bad


assert "partner-logo" in css, "no rule for the logo selector collected"
assert effects(css) == [], effects(css)
assert effects(".partner-tile .partner-logo{filter:grayscale(1)}")
assert effects(".partner-logo{opacity:.6}")
assert effects(".partner-logo{mix-blend-mode:screen}")
assert effects(".x .partner-logo{transform:scale(1.2)}")
assert not effects(".partner-logo{max-width:100%;height:auto}")
PY

# (5) the light fill check, now with the new tiles in the CSS.
scripts/test-no-light-fills.sh >/dev/null 2>&1 || soft "(5) test-no-light-fills failed"

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS case(s)" >&2
  exit 1
fi
echo "PASS: logos ok"
