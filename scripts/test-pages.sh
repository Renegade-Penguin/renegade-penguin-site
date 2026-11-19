#!/usr/bin/env bash
# Targeted page test. Builds the site and asserts the six pages.
set -euo pipefail
cd "$(dirname "$0")/.."
HUGO="${HUGO:-hugo}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

"$HUGO" --minify --destination "$OUT" >/dev/null || fail "hugo build exited non-zero"
pages="/ /services/ /experience/ /community/ /about/ /contact/"
for p in $pages; do
  f="$OUT${p}index.html"
  [ -f "$f" ] || fail "$p missing"
  h1=$(grep -o '<h1[ >]' "$f" | wc -l)
  [ "$h1" = "1" ] || fail "$p must have exactly one h1, found $h1"
  for q in $pages; do
    [ "$q" = "$p" ] && continue
    grep -Eq "href=\"?${q}[\" >]" "$f" || fail "$p has no nav link to $q"
  done
done
if grep -q '<form' "$OUT/contact/index.html"; then fail "/contact/ must not contain a form"; fi
grep -Eq '<a [^>]*href="?https://chiefgyk3d\.com/"?[^>]*rel="?noopener' "$OUT/about/index.html" ||
  grep -Eq '<a [^>]*rel="?noopener"?[^>]*href="?https://chiefgyk3d\.com/' "$OUT/about/index.html" ||
  fail "/about/ must link https://chiefgyk3d.com/ with rel=noopener"
echo "PASS: pages ok"
