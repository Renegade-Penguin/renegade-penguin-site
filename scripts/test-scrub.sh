#!/usr/bin/env bash
# Test for the scrub tooling (issue #9). No network, no Doppler. Two parts:
#   1. scripts/derive-scrub-terms.sh: turns the owner's category:term list into plain terms and
#      fails closed (naming only a category or a line number, never a term) when a category has no
#      real term, a line is malformed, or the input holds a NUL.
#   2. the scrub_shapes rule of scripts/check-output.sh (scripts/check-shapes.py): callsign, grid and
#      private-network shapes, with clearly fake positives, negatives, an allowlist proof, and a proof
#      that a hit fails check-output.sh in both staging and production modes.
# Every value here is obviously fake. The real terms never appear in this repository.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" scrub.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

D=scripts/derive-scrub-terms.sh
[ -f "$D" ] || fail "$D missing"

derive() { # <input file>: sets RC; stdout in $TMP/d.out, stderr in $TMP/d.err
  RC=0
  bash "$D" <"$1" >"$TMP/d.out" 2>"$TMP/d.err" || RC=$?
}
expect_fail() { # <label> <must-appear-in-stderr> ... ; checks RC, empty stdout
  local label="$1"
  shift
  [ "$RC" -ne 0 ] || fail "$label: expected a non-zero exit"
  [ ! -s "$TMP/d.out" ] || fail "$label: stdout must stay empty on failure"
  local want
  for want in "$@"; do
    grep -q -- "$want" "$TMP/d.err" || fail "$label: stderr does not contain '$want': $(cat "$TMP/d.err")"
  done
}
no_term_in_stderr() { # <label>
  if grep -qiE 'fake-|FAKE_|zzterm' "$TMP/d.err"; then fail "$1: a term appears in stderr"; fi
}

# 1. A full, valid list: comments, blanks, allow lines, placeholders, a term with colons and spaces.
cat >"$TMP/good.in" <<'EOF'
# header comment

employer:fake-employer-one
hostname:fake-host-one
serial:FAKE-SERIAL-1
allow:fake-allow
employer:PLACEHOLDER-employer
Serial:placeholder serial
hostname:fake:colon and space.dot
   # indented comment
EOF
printf '%s\n' 'fake-employer-one' 'fake-host-one' 'FAKE-SERIAL-1' 'fake:colon and space.dot' >"$TMP/good.want"
derive "$TMP/good.in"
[ "$RC" -eq 0 ] || fail "good list: exit $RC: $(cat "$TMP/d.err")"
cmp -s "$TMP/d.out" "$TMP/good.want" || fail "good list: output differs: $(cat "$TMP/d.out")"
no_term_in_stderr "good list"
grep -q 'employer=1' "$TMP/d.err" && grep -q 'hostname=2' "$TMP/d.err" && grep -q 'serial=1' "$TMP/d.err" ||
  fail "good list: stderr should report per-category counts: $(cat "$TMP/d.err")"
if grep -qE '^(employer|hostname|serial|allow):' "$TMP/d.out"; then fail "good list: a category prefix reached the output"; fi

# CRLF and a final line with no newline.
printf 'employer:fake-employer-one\r\nhostname:fake-host-one\r\nserial:FAKE-SERIAL-1' >"$TMP/crlf.in"
derive "$TMP/crlf.in"
[ "$RC" -eq 0 ] || fail "crlf: exit $RC: $(cat "$TMP/d.err")"
printf '%s\n' 'fake-employer-one' 'fake-host-one' 'FAKE-SERIAL-1' >"$TMP/crlf.want"
cmp -s "$TMP/d.out" "$TMP/crlf.want" || fail "crlf/no final newline: output differs"

# A term beginning with a space is kept as written (only a trailing CR is trimmed).
printf 'employer: lead space\nhostname:fake-host-one\nserial:FAKE-SERIAL-1\n' >"$TMP/sp.in"
derive "$TMP/sp.in"
[ "$RC" -eq 0 ] && [ "$(sed -n 1p "$TMP/d.out")" = " lead space" ] || fail "a leading space inside a term was trimmed"

# 2. Fail closed: each category with only placeholders, and an empty input.
for cat in employer hostname serial; do
  : >"$TMP/miss.in"
  for c in employer hostname serial; do
    if [ "$c" = "$cat" ]; then
      printf '%s:PLACEHOLDER-%s\n' "$c" "$c" >>"$TMP/miss.in"
    else
      printf '%s:fake-%s-one\n' "$c" "$c" >>"$TMP/miss.in"
    fi
  done
  derive "$TMP/miss.in"
  expect_fail "no real $cat" "$cat"
  for other in employer hostname serial; do
    [ "$other" = "$cat" ] || ! grep -q -w "$other" "$TMP/d.err" || fail "no real $cat: the message also names $other"
  done
  no_term_in_stderr "no real $cat"
done
: >"$TMP/none.in"
derive "$TMP/none.in"
expect_fail "empty input" employer hostname serial
printf '# only a comment\nallow:fake-allow\n' >"$TMP/c.in"
derive "$TMP/c.in"
expect_fail "comments and allow only" employer hostname serial

# 3. Fail closed on bad lines: the message names the line number and never the term.
printf 'employer:fake-employer-one\ncolor:fake-unknown-term\nhostname:fake-host-one\nserial:FAKE-SERIAL-1\n' >"$TMP/badcat.in"
derive "$TMP/badcat.in"
expect_fail "unknown category" "line 2"
no_term_in_stderr "unknown category"
printf 'employer:fake-employer-one\nhostname:fake-host-one\nserial:FAKE-SERIAL-1\nfake-line-without-prefix\n' >"$TMP/nopre.in"
derive "$TMP/nopre.in"
expect_fail "no category prefix" "line 4"
no_term_in_stderr "no category prefix"
printf 'employer:fake-employer-one\nhostname:\nserial:FAKE-SERIAL-1\n' >"$TMP/emptyterm.in"
derive "$TMP/emptyterm.in"
expect_fail "empty term" "line 2"
printf 'employer:fake-employer-one\nhostname:fake-host-one\nserial:FAKE-SERIAL-1\nallow:\n' >"$TMP/emptyallow.in"
derive "$TMP/emptyallow.in"
expect_fail "empty allow" "line 4"
printf 'employer:fake-employer-one\nhostname:fake-host\000one\nserial:FAKE-SERIAL-1\n' >"$TMP/nul.in"
derive "$TMP/nul.in"
expect_fail "NUL byte" "line 2"
no_term_in_stderr "NUL byte"

echo "ok: derive-scrub-terms.sh"

# ---------------------------------------------------------------------------------------------
# 2. The scrub_shapes rule (scripts/check-shapes.py through scripts/check-output.sh).
# Positives use CLEARLY FAKE shapes. Each case is one tiny page; the helper must report the category
# and the file, and must never print the matched text.
H=scripts/check-shapes.py
[ -f "$H" ] || fail "$H missing"
TAB="$(printf '\t')"

shape_run() { # <dir> [allow-file]: sets RC and OUT from the helper
  RC=0
  OUT="$(python3 -I "$H" "$@" 2>&1)" || RC=$?
}
page() { # <dir> <file> <body>: writes a minimal page
  mkdir -p "$1"
  printf '<!doctype html><html><head><title>t</title></head><body>%s</body></html>\n' "$3" >"$1/$2"
}
positive() { # <label> <category phrase> <matched text that must not be echoed> <html body> [file]
  local label="$1" phrase="$2" secret="$3" body="$4" file="${5:-index.html}"
  local dir="$TMP/pos-$label"
  rm -rf "$dir"
  if [ "$file" = index.html ]; then page "$dir" index.html "$body"; else
    mkdir -p "$dir"
    printf '%s\n' "$body" >"$dir/$file"
  fi
  shape_run "$dir"
  [ "$RC" -eq 0 ] || fail "positive $label: helper exit $RC: $OUT"
  printf '%s\n' "$OUT" | grep -q "^scrub_shapes${TAB}.*${file}${TAB}.*${phrase}" ||
    fail "positive $label: no '$phrase' finding for $file: $OUT"
  if printf '%s' "$OUT" | grep -qF -- "$secret"; then fail "positive $label: the matched text was printed"; fi
}
negative() { # <label> <html body>
  local dir="$TMP/neg-$1"
  rm -rf "$dir"
  page "$dir" index.html "$2"
  shape_run "$dir"
  [ "$RC" -eq 0 ] || fail "negative $1: helper exit $RC: $OUT"
  [ -z "$OUT" ] || fail "negative $1: expected no finding, got: $OUT"
}

positive callsign callsign N0XYZ '<p>Reach me at N0XYZ anytime</p>'
positive callsign-two-prefix callsign KD9ZZZ '<p>KD9ZZZ is on the air</p>'
positive doc-placeholder-n0call callsign N0CALL '<p>use N0CALL</p>'
positive doc-placeholder-n0tst callsign N0TST '<p>use N0TST.</p>'
positive callsign-encoded callsign 'N0XYZ' '<p>N&#48;XYZ</p>'
positive callsign-split-by-tag callsign 'N0XYZ' '<p>N0<b>XYZ</b></p>'
positive callsign-attribute callsign N0XYZ '<img src="/a.png" alt="op N0XYZ">'
positive callsign-jsonld callsign N0XYZ '<script type="application/ld+json">{"name":"N0XYZ"}</script>'
positive callsign-in-path callsign N0XYZ '<a href="/qrz/N0XYZ/">x</a>'
positive callsign-text-file callsign N0XYZ 'op N0XYZ' notes.txt
positive grid6 grid FN31xx '<p>Grid FN31xx here</p>'
positive doc-placeholder-grid grid FN31pr '<p>locator FN31pr</p>'
positive grid4-with-context grid FN31 '<p>my grid square is FN31</p>'
positive grid4-locator grid FN31 '<p>locator: FN31</p>'
positive ip10 'private IPv4' 10.9.8.7 '<p>ssh 10.9.8.7</p>'
positive ip172 'private IPv4' 172.16.5.4 '<p>172.16.5.4</p>'
positive ip172-31 'private IPv4' 172.31.255.254 '<p>172.31.255.254</p>'
positive ip192 'private IPv4' 192.168.1.50 '<p>http://192.168.1.50/</p>'
positive ip-parens 'private IPv4' 10.9.8.7 '<p>(10.9.8.7)</p>'
positive ip-port 'private IPv4' 10.9.8.7 '<p>10.9.8.7:8080</p>'
positive ip-sentence-end 'private IPv4' 10.9.8.7 '<p>The host is 10.9.8.7.</p>'
positive ip-comma 'private IPv4' 10.9.8.7 '<p>10.9.8.7, then more</p>'
positive ip-cidr 'private IPv4' 192.168.1.1 '<p>192.168.1.1/24</p>'
positive ip172-low 'private IPv4' 172.16.0.1 '<p>172.16.0.1</p>'
positive ip172-high 'private IPv4' 172.31.255.255 '<p>172.31.255.255</p>'
positive name-internal 'private hostname' host.example.internal '<p>host.example.internal</p>'
positive name-local 'private hostname' nas.local '<p>nas.local</p>'
positive name-lan 'private hostname' box.lan '<p>box.lan</p>'
positive name-homearpa 'private hostname' router.home.arpa '<p>router.home.arpa</p>'
positive name-in-attribute 'private hostname' nas.local '<a href="http://nas.local/x">x</a>'

negative words '<p>Hello world, a vCISO for small organizations.</p>'
negative frameworks '<p>ISO 27001, SOC 2, NIST SP800-53, CVE-2024-1234, TLS1.3, AES256, W3C, B2B and B2C.</p>'
negative versions '<p>version 1.2.3 and v10.2.3 and 2.0</p>'
negative hash '<p>sha256-deadbeefcafe0123456789abcdef0123456789abcdef0123</p>'
negative public-ips '<p>172.32.0.1, 172.15.0.1, 192.169.0.1, 11.0.0.1 and 10.0.0</p>'
negative ip-glued-letters '<p>x10.9.8.7abc and 10.9.8.7abc</p>'
negative ip-hostname-label '<p>10.9.8.7.example and 192.168.1.1.nip.example</p>'
negative ip-longer-dotted '<p>version 1.10.9.8.7 and 10.9.8.7.6 and 11.9.8.7 and 172.32.0.1</p>'
negative public-names '<p>example.com, localhost, a.localhost, my.localized.page and lan.example.org</p>'
negative four-char-no-context '<p>FN31 ID10 AB12 and OK23 are codes</p>'
negative lowercase '<p>n0xyz and fn31xx are lowercase</p>'
negative one-letter-suffix '<p>H1B visa, A1C level, B2B</p>'
negative css-class '<div class="btn-primary col-md-6 h1 w3-bar"></div>'

# Allowlist: an exact token with a reason exempts that token only; a reason is mandatory.
printf '# exact tokens the site legitimately contains, one per line: TOKEN<TAB>reason\n' >"$TMP/allow-empty.txt"
printf 'N0XYZ\tfake token used only by this test\n' >"$TMP/allow-one.txt"
printf 'N0XYZ\n' >"$TMP/allow-noreason.txt"
dir="$TMP/allow"
rm -rf "$dir"
page "$dir" index.html '<p>N0XYZ and KD9ZZZ</p>'
shape_run "$dir" "$TMP/allow-empty.txt"
printf '%s\n' "$OUT" | grep -q "callsign shape: 2 " || fail "allowlist: expected two callsign hits without an allowlist: $OUT"
shape_run "$dir" "$TMP/allow-one.txt"
printf '%s\n' "$OUT" | grep -q "callsign shape: 1 " || fail "allowlist: the exact token should leave exactly one hit: $OUT"
page "$dir" index.html '<p>N0XYZ only</p>'
shape_run "$dir" "$TMP/allow-one.txt"
[ -z "$OUT" ] && [ "$RC" -eq 0 ] || fail "allowlist: an allowlisted token was still reported: $OUT"
page "$dir" index.html '<p>N0XYZA is a different token, and N0XYZABC is too long to be a callsign</p>'
shape_run "$dir" "$TMP/allow-one.txt"
printf '%s\n' "$OUT" | grep -q "callsign shape: 1 " || fail "allowlist: a different token must still be reported (exact match only): $OUT"
shape_run "$dir" "$TMP/allow-noreason.txt"
[ "$RC" -ne 0 ] || fail "allowlist: an entry without a reason must fail closed"
echo "ok: check-shapes.py fixtures"

# check-output.sh: a hit fails the rule in staging AND production (scrub_terms behaves the same: it is
# not environment dependent, the staging site is public too), and SKIP_SCRUB_SHAPES=1 proves the bite.
FIX=scripts/fixtures
TERMS="$TMP/terms.txt"
printf '%s\n' 'zzbannedtermzz' >"$TERMS"
for mode in production staging; do
  base=clean
  [ "$mode" = staging ] && base=clean-staging
  tree="$TMP/co-$mode"
  rm -rf "$tree"
  mkdir -p "$tree"
  cp -R "$FIX/$base/." "$tree/"
  RC=0
  OUT="$(SKIP_FRESH=1 EXPECT_ENV=$mode SCRUB_TERMS_FILE="$TERMS" scripts/check-output.sh "$tree" 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] || fail "check-output $mode: the clean fixture should pass: $OUT"
  robots=''
  [ "$mode" = staging ] && robots='<meta name="robots" content="noindex">'
  printf '<!doctype html><html><head><title>t</title>%s</head><body><p>op N0XYZ at 10.9.8.7</p></body></html>\n' "$robots" >"$tree/shape.html"
  RC=0
  OUT="$(SKIP_FRESH=1 EXPECT_ENV=$mode SCRUB_TERMS_FILE="$TERMS" scripts/check-output.sh "$tree" 2>&1)" || RC=$?
  [ "$RC" -ne 0 ] || fail "check-output $mode: a callsign shape did not fail the gate"
  printf '%s\n' "$OUT" | grep -q '^FAIL scrub_shapes: .*(.*shape.html)' || fail "check-output $mode: no scrub_shapes failure line: $OUT"
  if printf '%s' "$OUT" | grep -qE 'N0XYZ|10\.9\.8\.7'; then fail "check-output $mode: the matched text was printed"; fi
  RC=0
  OUT="$(SKIP_SCRUB_SHAPES=1 SKIP_FRESH=1 EXPECT_ENV=$mode SCRUB_TERMS_FILE="$TERMS" scripts/check-output.sh "$tree" 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] || fail "check-output $mode: SKIP_SCRUB_SHAPES=1 should pass the same tree: $OUT"
done
echo "ok: check-output.sh scrub_shapes in production and staging"

# The real site, built in both variants, holds no shape (the rule is tuned on this output).
HUGO="${HUGO:-hugo}"
"$HUGO" --minify --destination "$TMP/real-prod" >/dev/null 2>"$TMP/build.err" || fail "production build failed: $(cat "$TMP/build.err")"
HUGO_PARAMS_ENVIRONMENT=staging "$HUGO" --minify --destination "$TMP/real-staging" >/dev/null 2>"$TMP/build.err" || fail "staging build failed: $(cat "$TMP/build.err")"
for v in prod staging; do
  shape_run "$TMP/real-$v"
  [ "$RC" -eq 0 ] || fail "real $v build: helper exit $RC: $OUT"
  [ -z "$OUT" ] || fail "real $v build: shape findings: $OUT"
done
echo "ok: the real site has no shapes"
echo "ok: scrub"
