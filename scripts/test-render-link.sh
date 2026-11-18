#!/usr/bin/env bash
# Targeted test for layouts/_markup/render-link.html. Builds scratch copies of the site.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
HUGO="${HUGO:-hugo}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# scratch_site <name> <markdown body>: copies config and layouts, writes one page, echoes the dir.
scratch_site() {
  local d="$TMP/$1"
  mkdir -p "$d/content"
  cp "$ROOT/hugo.toml" "$d/"
  cp -r "$ROOT/layouts" "$ROOT/assets" "$ROOT/static" "$d/"
  printf -- '---\ntitle: "Home"\n---\n\n%s\n' "$2" > "$d/content/_index.md"
  echo "$d"
}

# --- allowed links ---
d=$(scratch_site ok '[a](https://example.org/) [b](HTTPS://EVIL.example/) [c](//evil.example/x) [d](/contact/) [e](#frag) [f](mailto:a@example.org) [g](https://renegadepenguinllc.com/about/) [h](http://renegadepenguinllc.com/) [i](https://example.org/ "T&Q") [j](tel:5550100) [k](../x/)')
"$HUGO" --source "$d" --destination "$d/out" >/dev/null 2>"$TMP/ok.err" || { cat "$TMP/ok.err" >&2; fail "build with allowed links failed"; }
html="$d/out/index.html"
tag() { grep -o "<a [^>]*href=\"$1\"[^>]*>" "$html" | head -1 || true; }
need_rel() { local t; t=$(tag "$1"); [ -n "$t" ] || fail "no anchor for $1"; echo "$t" | grep -q 'rel="noopener"' || fail "$1 must carry rel=noopener: $t"; }
no_rel() { local t; t=$(tag "$1"); [ -n "$t" ] || fail "no anchor for $1"; if echo "$t" | grep -q 'rel='; then fail "$1 must not carry rel: $t"; fi; }
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
  if grep -qi 'href="[^"]*javascript:' "$d/out/index.html"; then fail "leading-newline javascript: reached an href"; fi
fi
rm -rf "$d"
echo "PASS: render-link ok"
