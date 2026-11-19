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

# Segment pages and the Ohio explainer.
segs="small-business healthcare-dental aviation critical-infrastructure"
[ -f "$OUT/who-we-help/index.html" ] || fail "/who-we-help/ missing"
for s in $segs; do
  f="$OUT/who-we-help/$s/index.html"
  [ -f "$f" ] || fail "/who-we-help/$s/ missing"
  [ "$(grep -o '<h1[ >]' "$f" | wc -l)" = "1" ] || fail "/who-we-help/$s/ must have exactly one h1"
  grep -Eq "href=\"?/who-we-help/$s/[\" >]" "$OUT/who-we-help/index.html" ||
    fail "/who-we-help/ must link /who-we-help/$s/"
done
[ -f "$OUT/ohio/index.html" ] || fail "/ohio/ missing"
grep -Eq 'href="?/who-we-help/[" >]' "$OUT/index.html" || fail "main nav must link /who-we-help/"
grep -Eq 'href="?/ohio/[" >]' "$OUT/index.html" || fail "footer must link /ohio/"
# The Ohio page must carry the owner verification placeholder until the owner resolves it.
grep -q '{{OWNER:verify wording against the statute text' "$OUT/ohio/index.html" ||
  fail "/ohio/ must contain the owner verification placeholder"
echo "PASS: pages ok"
