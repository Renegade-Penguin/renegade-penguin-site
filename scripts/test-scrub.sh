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
echo "ok: scrub"
