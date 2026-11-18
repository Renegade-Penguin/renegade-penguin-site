#!/usr/bin/env bash
# Targeted build test for the scaffold. Builds the site and asserts the basics.
set -euo pipefail
cd "$(dirname "$0")/.."
HUGO="${HUGO:-hugo}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

"$HUGO" --minify --destination "$OUT" >/dev/null || fail "hugo build exited non-zero"
[ -f "$OUT/index.html" ] || fail "index.html missing"
[ -f "$OUT/_headers" ] || fail "_headers not copied"
n=$(grep -c '^/\*$' "$OUT/_headers" || true)
[ "$n" = "1" ] || fail "_headers must have exactly one /* block, found $n"
if grep -rl '<script' "$OUT" --include='*.html' | grep -q .; then fail "<script found in html"; fi
grep -q '<html lang=en' "$OUT/index.html" || grep -q '<html lang="en"' "$OUT/index.html" || fail "html lang=en missing"
grep -q '<meta name=viewport' "$OUT/index.html" || grep -q '<meta name="viewport"' "$OUT/index.html" || fail "viewport meta missing"
h1=$(grep -o '<h1[ >]' "$OUT/index.html" | wc -l)
[ "$h1" = "1" ] || fail "home page must have exactly one h1, found $h1"
echo "PASS: build ok"
