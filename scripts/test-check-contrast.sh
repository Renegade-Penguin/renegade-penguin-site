#!/usr/bin/env bash
# Test for scripts/check-contrast.py. Builds a passing copy of tokens.css and
# main.css, then failing variants, each of which must exit non-zero with its own
# distinct message tag. CHECK_SCRIPT overrides the script under test (used for
# mutation proofs against a scratch copy).
set -uo pipefail
cd "$(dirname "$0")/.."
CHECK="${CHECK_SCRIPT:-scripts/check-contrast.py}"
BASE="$HOME/.local/share/renegade-penguin-site-dev"
mkdir -p "$BASE"
WORK="$(mktemp -d "$BASE/contrast-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

# fresh <name>: new dir holding pristine copies of tokens.css and main.css
fresh() {
  mkdir -p "$WORK/$1"
  cp assets/css/tokens.css assets/css/main.css "$WORK/$1/"
}

# expect_fail <name> <tag>: run on the variant, require non-zero exit and the tag.
expect_fail() {
  local out rc
  out="$(python3 -I "$CHECK" "$WORK/$1/tokens.css" 2>&1)"; rc=$?
  if [ "$rc" = 0 ]; then fail "$1: expected non-zero exit, got 0"; return; fi
  case "$out" in
    *"$2"*) echo "ok: $1 -> $2" ;;
    *) fail "$1: message missing $2; got: $out" ;;
  esac
}

# Passing copy.
fresh pass
if out="$(python3 -I "$CHECK" "$WORK/pass/tokens.css" 2>&1)"; then
  echo "ok: pass copy"
else
  fail "pass copy should exit 0; got: $out"
fi

# Low-contrast muted.
fresh low-muted
sed -i 's/--muted: #B5ADA2;/--muted: #3A3530;/' "$WORK/low-muted/tokens.css"
expect_fail low-muted "LOW-CONTRAST"

# Light prefers-color-scheme media query (in main.css, found beside tokens.css).
fresh light-media
printf '%s\n' '@media (prefers-color-scheme: light) { html { color: #000; } }' >> "$WORK/light-media/main.css"
expect_fail light-media "LIGHT-MEDIA"

# color-scheme value containing light.
fresh scheme-light
sed -i 's/color-scheme: dark;/color-scheme: dark light;/' "$WORK/scheme-light/tokens.css"
expect_fail scheme-light "COLOR-SCHEME-LIGHT"

# White fill in a background declaration.
fresh white-fill
printf '%s\n' '.card { background: #FFFFFF; }' >> "$WORK/white-fill/main.css"
expect_fail white-fill "WHITE-FILL"

# Near-white --surface token.
fresh near-white-surface
sed -i 's/--surface: #202020;/--surface: #FAFAFA;/' "$WORK/near-white-surface/tokens.css"
expect_fail near-white-surface "NEAR-WHITE-TOKEN"

# Unparseable color.
fresh unparseable
sed -i 's/--link: #FBB03B;/--link: goldenrod;/' "$WORK/unparseable/tokens.css"
expect_fail unparseable "UNPARSEABLE-COLOR"

# Missing required token.
fresh missing
sed -i '/--focus: /d' "$WORK/missing/tokens.css"
expect_fail missing "MISSING-TOKEN"

# The near-white --text token is allowed (the real tokens use one): pass copy proves it.
if [ "$FAILS" != 0 ]; then
  echo "FAILED: $FAILS case(s)" >&2
  exit 1
fi
echo "PASS: contrast checks ok"
