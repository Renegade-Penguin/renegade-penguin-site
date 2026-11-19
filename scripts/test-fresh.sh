#!/usr/bin/env bash
# Test for scripts/check-fresh.py and its wiring in scripts/check-output.sh.
# Trees are generated at run time (the checks depend on the clock), never committed.
set -euo pipefail
cd "$(dirname "$0")/.."
FRESH="scripts/check-fresh.py"
CHECK="scripts/check-output.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
soft() {
  echo "FAIL: $*" >&2
  FAILS=$((FAILS + 1))
}

YEAR="$(date -u +%Y)"
stamp() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }

# mk <name> <year> <expires-or-"none"> [extra body html]: a minimal clean-shaped tree.
mk() {
  local d="$WORK/$1"
  mkdir -p "$d/.well-known"
  printf '%s' "<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title></head><body><a href=#main>Skip</a><main id=main><h1>T</h1><p>Plain.</p>${4:-}</main><footer><span>&copy; $2 Fixture</span></footer></body></html>" >"$d/index.html"
  if [ "$3" != none ]; then
    printf 'Contact: mailto:a@example.org\nExpires: %s\nPreferred-Languages: en\n' "$3" >"$d/.well-known/security.txt"
  fi
  echo "$d"
}

ok_case() { # <label> <dir>
  local out rc=0
  out="$(python3 -I "$FRESH" "$2" 2>&1)" || rc=$?
  if [ "$rc" = 0 ]; then echo "ok: $1 passes"; else soft "$1: expected pass, got exit $rc: $out"; fi
}
bad_case() { # <label> <dir> <expected text>
  local out rc=0
  out="$(python3 -I "$FRESH" "$2" 2>&1)" || rc=$?
  if [ "$rc" != 1 ]; then
    soft "$1: expected exit 1, got $rc: $out"
  elif ! grep -qF "$3" <<<"$out"; then
    soft "$1: output lacks '$3': $out"
  else
    echo "ok: $1 fails"
  fi
}

GOOD="$(stamp '+180 days')"
ok_case "clean tree" "$(mk clean "$YEAR" "$GOOD")"
ok_case "skip link href=#main is not a placeholder" "$(mk skip "$YEAR" "$GOOD" '<a href="#top">Top</a>')"
ok_case "word containing lorem is not the word lorem" "$(mk dolorem "$YEAR" "$GOOD" '<p>dolorem and florempo</p>')"
ok_case "Expires 364 days ahead" "$(mk e364 "$YEAR" "$(stamp '+364 days')")"

bad_case "href=#" "$(mk hash "$YEAR" "$GOOD" '<a href="#">x</a>')" 'href="#"'
bad_case "unquoted href=#" "$(mk hash2 "$YEAR" "$GOOD" '<a href=#>x</a>')" 'href="#"'
bad_case "empty href" "$(mk empty "$YEAR" "$GOOD" '<a href="">x</a>')" 'empty href'
bad_case "href with no value" "$(mk novalue "$YEAR" "$GOOD" '<a href>x</a>')" 'empty href'
bad_case "lorem" "$(mk lorem "$YEAR" "$GOOD" '<p>Lorem ipsum dolor</p>')" 'lorem'
bad_case "lorem in a link text, upper case" "$(mk lorem2 "$YEAR" "$GOOD" '<a href=/x/>LOREM</a>')" 'lorem'
bad_case "last year in the footer" "$(mk oldyear "$((YEAR - 1))" "$GOOD")" 'not the current year'
bad_case "next year in the footer" "$(mk newyear "$((YEAR + 1))" "$GOOD")" 'not the current year'
bad_case "footer without a year" "$(mk noyear "" "$GOOD")" 'no copyright year'
bad_case "expired security.txt" "$(mk expired "$YEAR" "$(stamp '-1 day')")" 'in the past'
bad_case "Expires 367 days ahead" "$(mk far "$YEAR" "$(stamp '+367 days')")" 'more than 365 days'
bad_case "security.txt missing" "$(mk nosec "$YEAR" none)" 'missing'
bad_case "Expires not a date" "$(mk garbage "$YEAR" "next year")" 'RFC 3339'

# No Expires field, a second Expires field and no Contact field.
d="$(mk noexp "$YEAR" "$GOOD")"
printf 'Contact: mailto:a@example.org\n' >"$d/.well-known/security.txt"
bad_case "security.txt without Expires" "$d" 'exactly one Expires'
d="$(mk twoexp "$YEAR" "$GOOD")"
printf 'Contact: mailto:a@example.org\nExpires: %s\nExpires: %s\n' "$GOOD" "$GOOD" >"$d/.well-known/security.txt"
bad_case "security.txt with two Expires" "$d" 'exactly one Expires'
d="$(mk nocontact "$YEAR" "$GOOD")"
printf 'Expires: %s\n' "$GOOD" >"$d/.well-known/security.txt"
bad_case "security.txt without Contact" "$d" 'no Contact'

# A page that is not the home page also needs the year; the home page needs a footer at all.
d="$(mk sub "$YEAR" "$GOOD")"
mkdir -p "$d/about"
printf '%s' "<!doctype html><html lang=en><head><title>A</title></head><body><main><h1>A</h1></main><footer>&copy; $((YEAR - 1))</footer></body></html>" >"$d/about/index.html"
bad_case "stale footer year on a sub page" "$d" 'about/index.html'
d="$(mk nofooter "$YEAR" "$GOOD")"
printf '%s' '<!doctype html><html lang=en><head><title>T</title></head><body><main><h1>T</h1></main></body></html>' >"$d/index.html"
bad_case "home page without a footer" "$d" 'no footer copyright year'

# New Year: the accepted years are judged in UTC with one hour of slack either side.
cat >"$WORK/clock.py" <<'PY'
import importlib.util, sys
from datetime import datetime, timezone
spec = importlib.util.spec_from_file_location("check_fresh", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def utc(*a):
    return datetime(*a, tzinfo=timezone.utc)
cases = [
    (utc(2027, 6, 1, 12, 0, 0), {2027}),                    # mid-year: only this year
    (utc(2027, 1, 1, 0, 30, 0), {2026, 2027}),              # just after New Year: last year too
    (utc(2026, 12, 31, 23, 30, 0), {2026, 2027}),           # just before: next year too
    (utc(2027, 1, 1, 1, 0, 1), {2027}),                     # more than an hour after: last year fails
    (utc(2026, 12, 31, 22, 59, 59), {2026}),                # more than an hour before: next year fails
]
for now, want in cases:
    got = m.accepted_years(now)
    if got != want:
        sys.exit("accepted_years(%s) = %s, want %s" % (now, sorted(got), sorted(want)))
print("ok")
PY
rc=0
out="$(python3 -I "$WORK/clock.py" "$FRESH" 2>&1)" || rc=$?
if [ "$rc" = 0 ] && [ "$out" = ok ]; then echo "ok: New Year slack is one hour in UTC"; else soft "New Year clock cases: exit $rc: $out"; fi

# A failing helper must be non-zero, never a pass: bad usage exits 70.
rc=0
python3 -I "$FRESH" "$WORK/does-not-exist" >/dev/null 2>&1 || rc=$?
[ "$rc" = 70 ] && echo "ok: missing directory exits 70" || soft "missing directory: expected exit 70, got $rc"
rc=0
python3 -I "$FRESH" >/dev/null 2>&1 || rc=$?
[ "$rc" = 70 ] && echo "ok: no arguments exits 70" || soft "no arguments: expected exit 70, got $rc"

# Wiring in check-output.sh: the fresh check fails the build and SKIP_FRESH=1 turns it off.
wire() { # <tree>; builds on the clean fixture so every other check stays quiet
  local d="$WORK/wire-$1"
  rm -rf "$d"
  cp -R scripts/fixtures/clean "$d"
  mkdir -p "$d/.well-known"
  python3 -I -c '
import sys, os
d, year, exp = sys.argv[1], sys.argv[2], sys.argv[3]
for dp, _x, fs in os.walk(d):
    for f in fs:
        if f.endswith(".html"):
            p = os.path.join(dp, f)
            s = open(p, encoding="utf-8").read().replace("<footer>", "<footer><span>&copy; " + year + "</span>")
            open(p, "w", encoding="utf-8").write(s)
open(d + "/.well-known/security.txt", "w").write("Contact: mailto:a@example.org\nExpires: " + exp + "\n")
' "$d" "$YEAR" "$GOOD"
  echo "$d"
}
TERMS="$WORK/terms.txt"
printf '%s\n' 'zzbannedtermzz' >"$TERMS"
run() { env EXPECT_ENV=production SCRUB_TERMS_FILE="$TERMS" "$@" "$CHECK" "$T" 2>&1; }
T="$(wire good)"
rc=0
out="$(run)" || rc=$?
[ "$rc" = 0 ] && echo "ok: wired check passes a fresh tree" || soft "wired check on a fresh tree: exit $rc: $out"
T="$(wire stale)"
printf 'Contact: mailto:a@example.org\nExpires: %s\n' "$(stamp '-3 days')" >"$T/.well-known/security.txt"
rc=0
out="$(run)" || rc=$?
if [ "$rc" != 0 ] && grep -q '^FAIL fresh:' <<<"$out"; then echo "ok: check-output reports FAIL fresh"; else soft "stale tree: expected FAIL fresh, got exit $rc: $out"; fi
rc=0
out="$(run SKIP_FRESH=1)" || rc=$?
[ "$rc" = 0 ] && echo "ok: SKIP_FRESH=1 disables the check" || soft "SKIP_FRESH=1: exit $rc: $out"

# A crashing helper fails closed through check-output.sh.
stub="$WORK/stub"
mkdir -p "$stub"
cp -R scripts/. "$stub/"
printf '%s\n' 'raise RuntimeError("stub crash")' >"$stub/check-fresh.py"
T="$(wire crash)"
rc=0
out="$(env EXPECT_ENV=production SCRUB_TERMS_FILE="$TERMS" "$stub/check-output.sh" "$T" 2>&1)" || rc=$?
if [ "$rc" != 0 ] && grep -q '^FAIL fresh:' <<<"$out"; then echo "ok: crashing check-fresh.py fails the build"; else soft "crash stub: exit $rc: $out"; fi

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS case(s)" >&2
  exit 1
fi
echo "PASS: fresh tests"
