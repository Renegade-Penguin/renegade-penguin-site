#!/usr/bin/env bash
# Targeted test for layouts/_markup/render-link.html. Builds scratch copies of the site.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
HUGO="${HUGO:-hugo}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# scratch_site <name> <markdown body>: copies config and layouts, writes the body into the
# /about/ page (the home page lays out a hero and cards, it does not render a body), echoes the dir.
scratch_site() {
  local d="$TMP/$1"
  mkdir -p "$d/content/about"
  cp "$ROOT/hugo.toml" "$d/"
  cp -r "$ROOT/layouts" "$ROOT/assets" "$ROOT/static" "$ROOT/data" "$d/"
  printf -- '---\ntitle: "Home"\n---\n' >"$d/content/_index.md"
  printf -- '---\ntitle: "About"\n---\n\n%s\n' "$2" >"$d/content/about/_index.md"
  echo "$d"
}

# --- allowed links ---
d=$(scratch_site ok '[a](https://example.org/) [b](HTTPS://EVIL.example/) [c](//evil.example/x) [d](/contact/) [e](#frag) [f](mailto:a@example.org) [g](https://renegadepenguinllc.com/about/) [h](http://renegadepenguinllc.com/) [i](https://example.org/ "T&Q") [j](tel:5550100) [k](../x/)')
"$HUGO" --source "$d" --destination "$d/out" >/dev/null 2>"$TMP/ok.err" || {
  cat "$TMP/ok.err" >&2
  fail "build with allowed links failed"
}
html="$d/out/about/index.html"
tag() { grep -o "<a [^>]*href=\"$1\"[^>]*>" "$html" | head -1 || true; }
need_rel() {
  local t
  t=$(tag "$1")
  [ -n "$t" ] || fail "no anchor for $1"
  echo "$t" | grep -q 'rel="noopener"' || fail "$1 must carry rel=noopener: $t"
}
no_rel() {
  local t
  t=$(tag "$1")
  [ -n "$t" ] || fail "no anchor for $1"
  if echo "$t" | grep -q 'rel='; then fail "$1 must not carry rel: $t"; fi
}
need_rel 'https://example.org/'
need_rel 'HTTPS://EVIL.example/'
need_rel '//evil.example/x'
no_rel '/contact/'
no_rel '#frag'
no_rel 'mailto:a@example.org'
no_rel 'https://renegadepenguinllc.com/about/'
no_rel 'http://renegadepenguinllc.com/'
no_rel 'tel:5550100'
no_rel '../x/'
grep -q 'title="T&amp;Q"' "$html" || grep -q 'title="T&#38;Q"' "$html" || fail "link title missing or not escaped"

# --- forbidden schemes must fail the build ---
for bad in 'javascript:alert(1)' 'JaVaScRiPt:alert(1)' 'data:text/html,x' 'vbscript:x'; do
  d=$(scratch_site "bad" "[x]($bad)")
  if "$HUGO" --source "$d" --destination "$d/out" >/dev/null 2>"$TMP/bad.err"; then fail "build must fail for $bad"; fi
  grep -q 'disallowed' "$TMP/bad.err" || fail "error for $bad must name the problem: $(cat "$TMP/bad.err")"
  rm -rf "$d"
done
# --- control characters, spaces and backslashes must fail the build ---
# Bodies are generated with python so the shell source holds no control characters.
gen_body() {
  python3 -I -c '
import sys
t, n, c1, bs = chr(9), chr(10), chr(1), chr(92)
cases = {
  "tab-in-scheme": "java" + t + "script:alert(1)",
  "leading-tab": t + "https://example.org/",
  "leading-newline": n + "javascript:alert(1)",
  "trailing-space": "https://example.org/ ",
  "ctrl-01": "https://example.org/" + c1 + "x",
  "backslash": "https:" + bs + bs + "evil.example/",
}
print("[x](<" + cases[sys.argv[1]] + ">)")
' "$1"
}
for name in tab-in-scheme leading-tab trailing-space ctrl-01 backslash; do
  d=$(scratch_site "ctl" "$(gen_body "$name")")
  if "$HUGO" --source "$d" --destination "$d/out" >/dev/null 2>"$TMP/bad.err"; then fail "build must fail for control/space/backslash case $name"; fi
  grep -q 'disallowed' "$TMP/bad.err" || fail "error for $name must name the problem: $(cat "$TMP/bad.err")"
  rm -rf "$d"
done
# A newline inside <...> is not a link in Markdown, so it never reaches the hook.
# Either the build fails, or the output must hold no javascript: href.
d=$(scratch_site "nl" "$(gen_body leading-newline)")
if "$HUGO" --source "$d" --destination "$d/out" >/dev/null 2>"$TMP/nl.err"; then
  if grep -qi 'href="[^"]*javascript:' "$d/out/about/index.html"; then fail "leading-newline javascript: reached an href"; fi
fi
rm -rf "$d"

# --- no whitespace between a closing anchor and following punctuation, on the BUILT site ---
# The hook once ended with a newline, which browsers collapse into a space before , . ; : ) ? !
cat >"$TMP/tight.py" <<'PY'
import os
import re
import sys

BAD = re.compile(r"</a>(?:</span>)*\s+[,.;:)?!]")


def scan(root):
    """Return (pages scanned, offending snippets) for every <p> in every built page."""
    pages, bad = 0, []
    for dp, _dn, fns in os.walk(root):
        for fn in fns:
            if not fn.endswith(".html"):
                continue
            pages += 1
            path = os.path.join(dp, fn)
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            for p in re.findall(r"<p[ >].*?</p>", text, re.S):
                for m in BAD.finditer(p):
                    bad.append("%s: %r" % (path, p[max(0, m.start() - 30) : m.end() + 5]))
    return pages, bad


def tight(root, page, before, after):
    with open(os.path.join(root, page, "index.html"), encoding="utf-8") as fh:
        text = fh.read()
    return re.search(re.escape(before) + r"</a>" + re.escape(after), text) is not None


mode, root = sys.argv[1], sys.argv[2]
if mode == "scan":
    pages, bad = scan(root)
    if pages < 10:
        sys.exit("only %d pages scanned" % pages)
    if bad:
        sys.exit("space before punctuation after a link:\n" + "\n".join(bad[:10]))
elif mode == "negative":
    pages, bad = scan(root)
    if pages != 1 or len(bad) != 1:
        sys.exit("negative fixture was not flagged: pages=%d bad=%d" % (pages, len(bad)))
elif mode == "examples":
    if not tight(root, "services/advisory", "what a virtual CISO does", ","):
        sys.exit("advisory: comma does not directly follow the vCISO link")
    if not tight(root, "services", "Ohio guidance page", "."):
        sys.exit("services: period does not directly follow the Ohio guidance link")
PY
real="$TMP/real"
"$HUGO" --source "$ROOT" --destination "$real" >/dev/null 2>"$TMP/real.err" || {
  cat "$TMP/real.err" >&2
  fail "build of the real site failed"
}
python3 -I "$TMP/tight.py" scan "$real" || fail "whitespace before punctuation after a link"
python3 -I "$TMP/tight.py" examples "$real" || fail "example sentences are not tight"
mkdir -p "$TMP/neg"
printf '<p>see <a href="/x/">a link</a>\n, then more</p>\n' >"$TMP/neg/index.html"
python3 -I "$TMP/tight.py" negative "$TMP/neg" || fail "negative fixture must be flagged"
echo "PASS: render-link ok"
