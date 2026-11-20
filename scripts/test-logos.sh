#!/usr/bin/env bash
# Targeted test for the partner logos (issue #120).
# (1)(2) static/brand/partners/ holds only the allowed files, each with a provenance entry, a matching
#        sha256 and a treatment, each a valid image under 150 KB (scripts/check-logos.py);
# (3) the built home page renders eight uniform tiles and the Experience page five, every logo image
#     has alt text, width and height, and no <img> src is external;
# (4) the built CSS lets only .partner-logo--mono carry filter, blend or opacity, and the class is on an
#     image exactly when its provenance treatment is mono-light; unaltered logos carry no effect;
# (5) the light fill check still passes with the new tiles;
# (6) negative fixtures: an unprovenanced file, a modified byte, a missing or bad treatment, a kit logo
#     with a mono treatment, a missing permission line, a bad SVG and bad CSS or HTML each fail.
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

# (6) negative fixtures on scratch copies of the tree.
python3 -I - "$TMP" <<'PY' || soft "(6) provenance negative fixtures"
import importlib.util
import os
import re
import shutil
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("cl", "scripts/check-logos.py")
cl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cl)
tmp = sys.argv[1]
n = [0]


def tree():
    """A fresh copy of the partner files and the provenance record."""
    n[0] += 1
    root = os.path.join(tmp, "fx%d" % n[0])
    os.makedirs(root + "/static/brand")
    os.makedirs(root + "/docs")
    shutil.copytree("static/brand/partners", root + "/static/brand/partners")
    shutil.copy("docs/logo-provenance.md", root + "/docs/")
    return root


def edit_prov(root, fn):
    p = root + "/docs/logo-provenance.md"
    s = open(p, encoding="utf-8").read()
    out = fn(s)
    assert out != s, "the fixture edit changed nothing"
    open(p, "w", encoding="utf-8").write(out)


def expect_fail(label, root, needle):
    fails = cl.check(root)
    assert any(needle in f for f in fails), (label, needle, fails)


assert cl.check(tree()) == [], cl.check(tree())
assert len(os.listdir("static/brand/partners")) == 7, os.listdir("static/brand/partners")

r = tree()  # an unprovenanced file
shutil.copy("static/brand/penguin-color.png", r + "/static/brand/partners/extra.png")
expect_fail("unprovenanced", r, "extra.png has no provenance entry")

r = tree()  # a provenanced entry whose file was dropped, and an unprovenanced allowed name
os.remove(r + "/static/brand/partners/netjets.svg")
expect_fail("missing file", r, "provenance entry static/brand/partners/netjets.svg has no file")

# a modified byte, in a png, an svg, a jpg and a webp
for f, tail in (("cointelegraph.png", b"x"), ("netjets.svg", b" "), ("henry-schein.jpg", b"x"), ("gc-dental.webp", b"x")):
    r = tree()
    with open(r + "/static/brand/partners/" + f, "ab") as fh:
        fh.write(tail)
    expect_fail("modified byte " + f, r, f + " sha256")

r = tree()  # a missing treatment
edit_prov(r, lambda s: re.sub(r"- Treatment: mono-light\n", "", s, count=1))
expect_fail("missing treatment", r, "provenance lacks treatment")

r = tree()  # a treatment outside the two allowed values
edit_prov(r, lambda s: s.replace("- Treatment: mono-light", "- Treatment: sepia", 1))
expect_fail("bad treatment", r, "treatment 'sepia' is not one of")

r = tree()  # a kit logo may never carry an effect
edit_prov(r, lambda s: re.sub(r"(## lorikeet-security.*?- Treatment: )unaltered", r"\1mono-light", s, count=1, flags=re.S))
expect_fail("kit mono", r, "lorikeet-security.png is a kit logo and must have treatment unaltered")

r = tree()  # no permission line on a non-kit logo
edit_prov(r, lambda s: s.replace("- Permission: permission not obtained", "- Note: permission not obtained", 1))
expect_fail("no permission line", r, "provenance lacks the permission line")

r = tree()  # a bad svg with matching provenance would still fail the svg check
p = r + "/static/brand/partners/call-theory.svg"
open(p, "w").write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 375 374.999991"><script>1</script></svg>')
expect_fail("bad svg", r, "forbidden construct")

assert cl.svg_problems('<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h4v4z" clip-path="url(#a)"/></svg>') == []
for bad in ('<svg><script>1</script></svg>', '<svg><foreignObject/></svg>', '<svg onload="x()"/>',
            '<svg><image href="https://x.example/a.png"/></svg>', '<svg><use href="https://x.example/a.svg#a"/></svg>',
            '<svg><path style="fill:url(https://x.example/a)"/></svg>'):
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
import importlib.util
import os
import re
import sys
import tomllib
from html.parser import HTMLParser

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("cl", "scripts/check-logos.py")
cl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cl)
out = sys.argv[1]
data = tomllib.load(open("data/home/worked-with.toml", "rb"))
items = [i for g in data["groups"] for i in g["items"]]
names = [i["title"] for i in items]
assert len(names) == 8, names
logos = {i["title"]: i for i in items if "logo" in i}
assert len(logos) >= 2, sorted(logos)
text_only = sorted(n for n in names if n not in logos)
assert text_only == ["SML Labs"], text_only  # the image is unusable on the dark tile; see docs/logo-provenance.md
treat = cl.treatments(".")
prov = {e["path"]: e for e in cl.parse_provenance("docs/logo-provenance.md") if "path" in e}
for name, it in logos.items():
    f = os.path.basename(it["logo"])
    assert it["logo"] == "/brand/partners/" + f, it
    assert os.path.isfile("static" + it["logo"]), it
    assert it["treatment"] == treat[f], (name, it["treatment"], treat[f])
    assert prov["static/brand/partners/" + f]["organization"] == name, (name, f)
assert sorted(os.path.basename(i["logo"]) for i in logos.values()) == sorted(os.listdir("static/brand/partners")), "a file is not used"
# The two kit logos stay unaltered; the dark-on-transparent and white-background logos take the one mono class.
assert {n: i["treatment"] for n, i in logos.items()} == {
    "Cointelegraph": "unaltered", "Lorikeet Security": "unaltered", "Call Center Village": "unaltered",
    "Call Theory": "unaltered", "GC Dental": "unaltered", "NetJets": "mono-light", "Henry Schein": "mono-light"}, logos
# Smallest size each organization's own terms allow, as the display size set by the width and height
# attributes: Lorikeet, 140 px wide; Cointelegraph, 32 points (about 43 px) for the mark, which fills about
# 62 percent of the height of the supplied PNG, so the image height must be at least 70 px. The others
# state no minimum: keep at least 24 px of height.
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
            key, floor = MIN.get(name, ("height", 24))
            assert int(img[key]) >= floor, (name, key, img[key], floor)
            f = os.path.basename(logos[name]["logo"])
            sw, sh = (float(x) for x in cl.image_size(f, open("static" + logos[name]["logo"], "rb").read()).split("x"))
            assert abs(int(img["width"]) / int(img["height"]) - sw / sh) < 0.02 * sw / sh, (name, "aspect ratio changed")
            classes = (img.get("class") or "").split()
            mono = "partner-logo--mono" in classes
            assert mono == (treat[f] == "mono-light"), ("mono class and provenance treatment disagree", name, classes, treat[f])
            if treat[f] == "unaltered":
                assert classes[0] == "partner-logo" and all(c.startswith("zone-") or c == "partner-logo" for c in classes), (name, classes)
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

# Negative: the guards bite on a missing alt, an external src, a missing tile, an effect class on an
# unaltered logo, and a missing effect class on a mono-light logo.
html = open(out + "/index.html", encoding="utf-8").read()
mono_name = next(n for n, i in logos.items() if i["treatment"] == "mono-light")
unaltered_name = "Lorikeet Security"


def add_class(doc, org, cls):
    return re.sub(r'(class="?partner-logo [^">]*)("?[^>]*alt="?%s"?)' % re.escape(org), r"\1 %s\2" % cls, doc, count=1)


bad_docs = (
    ("no alt", re.sub(r'alt="?Lorikeet Security"?', 'alt=""', html)),
    ("external src", re.sub(r'src=("?)/brand/partners/', r'src=\1https://x.example/brand/partners/', html, count=1)),
    ("missing tile", re.sub(r"<li[^>]*partner-tile[^>]*>", "<li>", html, count=1)),
    ("mono class on an unaltered logo", add_class(html, unaltered_name, "partner-logo--mono")),
    ("mono class missing", html.replace(" partner-logo--mono", "", 1)),
)
for label, bad in bad_docs:
    assert bad != html, "the fixture edit changed nothing: " + label
    t = T()
    t.feed(bad)
    try:
        check(t, 8)
    except AssertionError:
        pass
    else:
        raise SystemExit("guard did not fail on: " + label)

# (4) CSS: only .partner-logo--mono may carry an effect, and only filter, blend and opacity.
css = "".join(open(f, encoding="utf-8").read() for f in glob.glob(out + "/**/*.css", recursive=True))
assert css, "no built css collected"
EFFECT = re.compile(r"(?:^|[;{\s])(?:filter|backdrop-filter|opacity|mix-blend-mode|mask[a-z-]*|transform|rotate|scale|object-position|clip-path)\s*:")
MONO_OK = {"filter", "mix-blend-mode", "opacity"}


def effects(sheet):
    bad = []
    for sel, body in re.findall(r"([^{}@]+)\{([^{}]*)\}", sheet):
        if "partner-logo" not in sel:
            continue
        if sel.strip() == ".partner-logo--mono":
            props = {d.split(":")[0].strip() for d in body.split(";") if ":" in d}
            if not props <= MONO_OK:
                bad.append((sel.strip(), body))
        elif EFFECT.search(";" + body):
            bad.append((sel.strip(), body))
    return bad


assert "partner-logo" in css, "no rule for the logo selector collected"
assert re.search(r"\.partner-logo--mono\{[^}]*filter:", css), "the mono rule is missing"
assert re.search(r"\.partner-logo\.zone-default\{[^}]*margin:1\.5rem", css), "default clear space rule missing"
assert effects(css) == [], effects(css)
assert effects(".partner-tile .partner-logo{filter:grayscale(1)}")
assert effects(".partner-logo{opacity:.6}")
assert effects(".partner-logo.zone-shield{mix-blend-mode:screen}")
assert effects(".x .partner-logo{transform:scale(1.2)}")
assert effects(".partner-logo--mono{transform:scale(1.2)}")
assert effects(".partner-logo--mono{filter:invert(1);mask:none}")
assert effects(".partner-logo--mono .x{filter:invert(1)}")
assert not effects(".partner-logo--mono{filter:invert(1);mix-blend-mode:screen;opacity:.8}")
assert not effects(".partner-logo{max-width:100%;height:auto}")
PY

# (5) the light fill check, now with the new tiles in the CSS.
scripts/test-no-light-fills.sh >/dev/null 2>&1 || soft "(5) test-no-light-fills failed"

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS case(s)" >&2
  exit 1
fi
echo "PASS: logos ok"
