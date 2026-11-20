#!/usr/bin/env bash
# Targeted test for search titles and descriptions (issue #79). Builds the site and asserts, for every
# public (sitemap-listed) page: title at most 60 characters, meta description 120 to 160 characters,
# and titles and descriptions unique across pages. A negative case proves the guard bites.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" seo.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
"$HUGO" --minify --destination "$TMP/out" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  echo "FAIL: hugo build failed" >&2
  exit 1
}
python3 -I - "$TMP/out" <<'PY' || { echo "FAIL: seo titles and descriptions" >&2; exit 1; }
import html
import re
import sys
from urllib.parse import urlparse

out = sys.argv[1]
def pages():
    sm = open(out + "/sitemap.xml", encoding="utf-8").read()
    paths = [urlparse(u).path for u in re.findall(r"<loc>([^<]+)</loc>", sm)]
    assert len(paths) >= 20, ("too few public pages collected", paths)
    return paths

def extract(doc):
    t = re.search(r"<title>(.*?)</title>", doc, re.S)
    d = re.search(r'<meta name="?description"? content="?(.*?)"?\s*/?>', doc, re.S)
    t = html.unescape(t.group(1)) if t else None
    if d:
        m = re.search(r'<meta name=(?:"description"|description) content=(?:"([^"]*)"|([^>]*?))\s*/?>', doc)
        d = html.unescape(m.group(1) if m.group(1) is not None else m.group(2))
    return t, d

def check(items):
    errs = []
    seen_t, seen_d = {}, {}
    for path, doc in items:
        t, d = extract(doc)
        if not t:
            errs.append((path, "no title"))
        elif len(t) > 60:
            errs.append((path, "title %d chars: %s" % (len(t), t)))
        if not d:
            errs.append((path, "no description"))
        elif not 120 <= len(d) <= 160:
            errs.append((path, "description %d chars: %s" % (len(d), d)))
        if t:
            if t in seen_t:
                errs.append((path, "title duplicates %s" % seen_t[t]))
            seen_t.setdefault(t, path)
        if d:
            if d in seen_d:
                errs.append((path, "description duplicates %s" % seen_d[d]))
            seen_d.setdefault(d, path)
    return errs

items = []
for p in pages():
    f = out + p + "index.html"
    items.append((p, open(f, encoding="utf-8").read()))
errs = check(items)
for e in errs:
    print("%s: %s" % e)
assert not errs, "%d violation(s)" % len(errs)

# negative cases: the guard bites on a long title, a short description and a duplicate
base = items[0][1]
long_t = re.sub(r"<title>.*?</title>", "<title>" + "x" * 61 + "</title>", base, flags=re.S)
assert check([("/a/", long_t)]), "guard missed a 61 character title"
short_d = re.sub(r'(<meta name="?description"? content=)("?)[^">]*', r"\1\2short", base)
assert check([("/a/", short_d)]), "guard missed a short description"
assert any("duplicates" in e[1] for e in check([("/a/", base), ("/b/", base)])), "guard missed duplicates"
print("PASS: seo ok (%d pages)" % len(items))
PY
