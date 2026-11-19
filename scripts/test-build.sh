#!/usr/bin/env bash
# Targeted build test for the scaffold. Builds the site and asserts the basics.
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
[ -f "$OUT/index.html" ] || fail "index.html missing"
[ -f "$OUT/_headers" ] || fail "_headers not copied"
n=$(grep -c '^/\*$' "$OUT/_headers" || true)
[ "$n" = "1" ] || fail "_headers must have exactly one /* block, found $n"
# Only JSON-LD data blocks (type application/ld+json, not executable) may be script elements.
if grep -rhoE '<script[^>]*>' "$OUT" --include='*.html' | grep -vE '^<script type="?application/ld\+json"?>$' | grep -q .; then fail "<script found in html"; fi
grep -q '<html lang=en' "$OUT/index.html" || grep -q '<html lang="en"' "$OUT/index.html" || fail "html lang=en missing"
grep -q '<meta name=viewport' "$OUT/index.html" || grep -q '<meta name="viewport"' "$OUT/index.html" || fail "viewport meta missing"
h1=$(grep -o '<h1[ >]' "$OUT/index.html" | wc -l)
[ "$h1" = "1" ] || fail "home page must have exactly one h1, found $h1"
[ -f "$OUT/fonts/orbitron-latin-wght-normal.woff2" ] || fail "orbitron font missing from build"
[ -f "$OUT/fonts/OFL-Orbitron.txt" ] || fail "Orbitron license text missing from build"
grep -q 'class=case-strip' "$OUT/index.html" || grep -q 'class="case-strip"' "$OUT/index.html" || fail "home page missing case-strip"
grep -qE '<link rel=stylesheet [^>]*integrity=' "$OUT/index.html" || grep -qE '<link rel="stylesheet"[^>]*integrity=' "$OUT/index.html" || fail "stylesheet link has no integrity attribute"
echo "PASS: build ok"
