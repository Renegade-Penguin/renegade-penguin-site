#!/usr/bin/env bash
# Test for scripts/check-contrast.py. Builds a passing copy of tokens.css and
# main.css, then failing variants, each of which must exit non-zero with its own
# message tag. CHECK_SCRIPT overrides the script under test (used for mutation
# proofs against a scratch copy). Variants are built with python3 -I, not shell
# escapes, so backslashes and bytes reach the files exactly.
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
# append <name> <file> <text>: add a line to the variant file, text kept verbatim
append() {
  python3 -I -c 'import sys; open(sys.argv[1], "a", encoding="utf-8").write(sys.argv[2] + chr(10))' \
    "$WORK/$1/$2" "$3"
}
# replace <name> <file> <old> <new>: exact replacement, must match
replace() {
  python3 -I -c 'import sys
p, o, n = sys.argv[1:4]
t = open(p, encoding="utf-8").read()
assert o in t, "missing: " + o
open(p, "w", encoding="utf-8").write(t.replace(o, n))' "$WORK/$1/$2" "$3" "$4"
}
# badbytes <name> <file>: overwrite with bytes that are not valid UTF-8
badbytes() {
  python3 -I -c 'import sys; open(sys.argv[1], "wb").write(bytes([0xff, 0xfe, 0x80, 0x41]))' "$WORK/$1/$2"
}
# run <name>: sets OUT and RC from the check on the variant
run() { OUT="$(python3 -I "$CHECK" "$WORK/$1/tokens.css" 2>&1)"; RC=$?; }

# expect_fail <name> <text>: non-zero exit and the text in the output.
expect_fail() {
  run "$1"
  if [ "$RC" = 0 ]; then fail "$1: expected non-zero exit, got 0"; return; fi
  case "$OUT" in
    *"$2"*) echo "ok: $1 -> $2" ;;
    *) fail "$1: message missing $2; got: $OUT" ;;
  esac
}
# expect_pass <name>
expect_pass() {
  run "$1"
  if [ "$RC" = 0 ]; then echo "ok: $1 passes"; else fail "$1: should exit 0; got rc=$RC: $OUT"; fi
}
# expect_rc2 <name> <text>: exit 2, text present, no traceback
expect_rc2() {
  run "$1"
  case "$OUT" in *Traceback*) fail "$1: traceback in output: $OUT"; return ;; esac
  if [ "$RC" != 2 ]; then fail "$1: expected exit 2, got $RC: $OUT"; return; fi
  case "$OUT" in
    *"$2"*) echo "ok: $1 -> $2" ;;
    *) fail "$1: message missing $2; got: $OUT" ;;
  esac
}
# bgcase <name> <tag> <css>: main.css gets a rule; expect the tag
bgcase() { fresh "$1"; append "$1" main.css "$3"; expect_fail "$1" "$2"; }

# Passing copy, plus allowed things that must not be flagged.
fresh pass
expect_pass pass
fresh dark-media-ok
append dark-media-ok main.css '@media (prefers-color-scheme: dark) { html { color: #EEE; } }'
expect_pass dark-media-ok
fresh important-ok
replace important-ok tokens.css '--muted: #B5ADA2;' '--muted: #B5ADA2 !important;'
expect_pass important-ok

# Original variants.
fresh low-muted
replace low-muted tokens.css '--muted: #B5ADA2;' '--muted: #3A3530;'
expect_fail low-muted "LOW-CONTRAST"
bgcase light-media LIGHT-MEDIA '@media (prefers-color-scheme: light) { html { color: #000; } }'
fresh scheme-light
replace scheme-light tokens.css 'color-scheme: dark;' 'color-scheme: dark light;'
expect_fail scheme-light "COLOR-SCHEME-LIGHT"
bgcase white-fill WHITE-FILL '.card { background: #FFFFFF; }'
fresh near-white-surface
replace near-white-surface tokens.css '--surface: #202020;' '--surface: #FAFAFA;'
expect_fail near-white-surface "NEAR-WHITE-TOKEN"
fresh unparseable
replace unparseable tokens.css '--link: #FBB03B;' '--link: goldenrod;'
expect_fail unparseable "UNPARSEABLE-COLOR"
fresh missing
replace missing tokens.css '--focus: #FBB03B;' ''
expect_fail missing "MISSING-TOKEN"

# 1. Near-white fills in every form.
bgcase fill-hex3 WHITE-FILL '.a { background: #fff; }'
bgcase fill-hex4 WHITE-FILL '.a { background: #ffff; }'
bgcase fill-hex8 WHITE-FILL '.a { background-color: #FFFFFF80; }'
bgcase fill-near-hex6 WHITE-FILL '.a { background: #F0F0F0; }'
bgcase fill-rgb-comma WHITE-FILL '.a { background: rgb(255, 255, 255); }'
bgcase fill-rgba-space WHITE-FILL '.a { background: rgb(250 250 250 / 50%); }'
bgcase fill-rgb-pct WHITE-FILL '.a { background-color: rgb(100% 100% 100%); }'
bgcase fill-hsl WHITE-FILL '.a { background: hsl(0 0% 96%); }'
bgcase fill-hsla-sat WHITE-FILL '.a { background: hsla(120, 100%, 95%, 1); }'
bgcase fill-ivory WHITE-FILL '.a { background: ivory; }'
bgcase fill-azure-upper WHITE-FILL '.a { background-color: AZURE; }'
bgcase fill-lavenderblush WHITE-FILL '.a { background: LavenderBlush; }'
bgcase fill-gradient WHITE-FILL '.a { background-image: linear-gradient(#000, snow); }'
bgcase fill-url-shorthand WHITE-FILL '.a { background: url(x.png) #FEFEFE no-repeat; }'
bgcase fill-white-kw WHITE-FILL '.a { background: white; }'
bgcase token-near-white NEAR-WHITE-TOKEN ':root { --page-bg: #fff; }'
bgcase token-hsl-surface NEAR-WHITE-TOKEN ':root { --card-surface: hsl(40 20% 97%); }'
# not flagged: a dark gradient, and a near-white color in a non-background property.
fresh fill-dark-ok
append fill-dark-ok main.css '.a { background: linear-gradient(#000, #222); border-color: #fff; }'
expect_pass fill-dark-ok
# CSS escapes are decoded before matching.
bgcase escaped-media LIGHT-MEDIA '@media (prefers-color-scheme: \6Cight) { html { color: #000; } }'
bgcase escaped-property WHITE-FILL '.a { \62 ackground: #fff; }'
bgcase escaped-color-scheme COLOR-SCHEME-LIGHT ':root { color-scheme: \6Cight; }'

# 2. var() indirection.
fresh var-indirect
append var-indirect main.css ':root { --paper: #fff; }'
append var-indirect main.css '.a { background: var(--paper); }'
expect_fail var-indirect WHITE-FILL
fresh var-nested
append var-nested main.css ':root { --paper: #fff; --sheet: var(--paper); }'
append var-nested main.css '.a { background-color: var(--sheet); }'
expect_fail var-nested WHITE-FILL
bgcase var-fallback WHITE-FILL '.a { background: var(--nope, white); }'
fresh var-token-chain
append var-token-chain main.css ':root { --paper: #fff; --card-surface: var(--paper); }'
expect_fail var-token-chain NEAR-WHITE-TOKEN
fresh var-cycle
append var-cycle main.css ':root { --a: var(--b); --b: var(--a); }'
append var-cycle main.css '.x { background: var(--a); }'
expect_fail var-cycle VAR-CYCLE
fresh var-dark-ok
append var-dark-ok main.css '.a { background: var(--surface); }'
expect_pass var-dark-ok

# 3. main.css must not define the required tokens.
bgcase main-defines-muted FORBIDDEN-TOKEN '.a { --muted: #111; }'
bgcase main-defines-bg FORBIDDEN-TOKEN ':root { --bg: #111; }'

# 4. Non-UTF-8 input: exit 2, clear message, no traceback.
fresh utf8-main
badbytes utf8-main main.css
expect_rc2 utf8-main "not valid UTF-8"
fresh utf8-tokens
badbytes utf8-tokens tokens.css
expect_rc2 utf8-tokens "not valid UTF-8"

# 6. Boundary: #747474 on black is 4.49:1 (fail), #757575 passes.
fresh edge-fail
replace edge-fail tokens.css '--bg: #0F0F0F;' '--bg: #000000;'
replace edge-fail tokens.css '--surface: #202020;' '--surface: #000000;'
replace edge-fail tokens.css '--muted: #B5ADA2;' '--muted: #747474;'
expect_fail edge-fail "4.49"
fresh edge-pass
replace edge-pass tokens.css '--bg: #0F0F0F;' '--bg: #000000;'
replace edge-pass tokens.css '--surface: #202020;' '--surface: #000000;'
replace edge-pass tokens.css '--muted: #B5ADA2;' '--muted: #757575;'
expect_pass edge-pass

# 7. @import and non-dark prefers-color-scheme.
bgcase import-main IMPORT '@import url(other.css);'
fresh import-tokens
append import-tokens tokens.css '@import "other.css";'
expect_fail import-tokens IMPORT
bgcase media-not LIGHT-MEDIA '@media not (prefers-color-scheme: dark) { html { color: #000; } }'
bgcase media-no-preference LIGHT-MEDIA '@media (prefers-color-scheme: no-preference) { html { color: #000; } }'

if [ "$FAILS" != 0 ]; then
  echo "FAILED: $FAILS case(s)" >&2
  exit 1
fi
echo "PASS: contrast checks ok"
