#!/usr/bin/env bash
# Fixture-driven test for scripts/check-output.sh.
#
# Fixtures are tiny hand-made output trees under scripts/fixtures/:
#   clean/          a passing production tree
#   clean-staging/  a passing staging tree
#   bad-*/          an OVERLAY: only the files that differ. The test copies the
#                   chosen base tree, lays the overlay on top, and runs the checker.
# Each bad fixture must (1) fail with the check enabled, with a message naming the
# check, and (2) pass with SKIP_<NAME>=1, which proves it bites exactly that check.
# The em/en dash fixture is built at run time with chr() so no dash is committed.
# A final step builds the real site in production and staging and runs the checker.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK="scripts/check-output.sh"
FIX="scripts/fixtures"
HUGO="${HUGO:-hugo}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$CHECK" ] || fail "$CHECK missing or not executable"

TERMS="$WORK/terms.txt"
printf '%s\n' 'zzbannedtermzz' > "$TERMS"

# stage <base> <overlay-dir-or-empty> -> echoes a fresh tree path
n=0
stage() {
  n=$((n + 1))
  local d="$WORK/tree$n"
  mkdir -p "$d"
  cp -R "$FIX/$1/." "$d/"
  if [ -n "${2:-}" ]; then cp -R "$2/." "$d/"; fi
  echo "$d"
}

run_check() { # <dir> <env> [VAR=1 ...]; sets RC and OUT
  local dir="$1" envn="$2"; shift 2
  set +e
  OUT="$(env EXPECT_ENV="$envn" SCRUB_TERMS_FILE="$TERMS" "$@" "$CHECK" "$dir" 2>&1)"
  RC=$?
  set -e
}

# expect_pass <label> <tree> <env>
expect_pass() {
  run_check "$2" "$3"
  [ "$RC" = "0" ] || fail "$1: expected pass, got exit $RC: $OUT"
  echo "ok: $1 passes"
}

# bite <label> <tree> <env> <check-name> <SKIP var>
bite() {
  local label="$1" tree="$2" envn="$3" name="$4" skip="$5"
  run_check "$tree" "$envn"
  [ "$RC" != "0" ] || fail "$label: expected failure, got exit 0"
  printf '%s\n' "$OUT" | grep -q "^FAIL $name:" || fail "$label: no 'FAIL $name:' line in: $OUT"
  run_check "$tree" "$envn" "$skip=1"
  [ "$RC" = "0" ] || fail "$label: with $skip=1 expected pass, got exit $RC: $OUT"
  echo "ok: $label fails on $name and passes with $skip=1"
}

expect_pass "clean (production)" "$(stage clean)" production
expect_pass "clean-staging (staging)" "$(stage clean-staging)" staging

# Usage errors are not a pass.
run_check "$(stage clean)" bogus
[ "$RC" != "0" ] || fail "bogus EXPECT_ENV must fail"
echo "ok: bogus EXPECT_ENV rejected"

bite "script tag"             "$(stage clean "$FIX/bad-no-script")"           production no_script       SKIP_NO_SCRIPT
bite "inline handler"         "$(stage clean "$FIX/bad-inline-handler")"      production inline_handler  SKIP_INLINE_HANDLER
bite "external img src"       "$(stage clean "$FIX/bad-external-img")"        production external_host   SKIP_EXTERNAL_HOST
bite "external link tag"      "$(stage clean "$FIX/bad-external-linktag")"    production external_host   SKIP_EXTERNAL_HOST
bite "external css import"    "$(stage clean "$FIX/bad-external-css")"        production external_host   SKIP_EXTERNAL_HOST
bite "anchor without noopener" "$(stage clean "$FIX/bad-external-anchor")"    production external_host   SKIP_EXTERNAL_HOST
bite "term in body"           "$(stage clean "$FIX/bad-scrub-body")"          production scrub_terms     SKIP_SCRUB_TERMS
bite "term in title"          "$(stage clean "$FIX/bad-scrub-title")"         production scrub_terms     SKIP_SCRUB_TERMS
bite "term in alt"            "$(stage clean "$FIX/bad-scrub-alt")"           production scrub_terms     SKIP_SCRUB_TERMS
bite "noindex in production"  "$(stage clean "$FIX/bad-noindex-production")"  production noindex         SKIP_NOINDEX
bite "staging missing noindex" "$(stage clean-staging "$FIX/bad-staging-no-noindex")" staging noindex     SKIP_NOINDEX
bite "staging robots allows"  "$(stage clean-staging "$FIX/bad-staging-no-disallow")" staging robots      SKIP_ROBOTS
bite "missing CSP"            "$(stage clean "$FIX/bad-csp")"                 production csp             SKIP_CSP
bite "missing about link"     "$(stage clean "$FIX/bad-about-link")"          production about_link      SKIP_ABOUT_LINK

# Dash fixtures are generated so the characters never appear in the repo.
for cp in 0x2014 0x2013; do
  t="$(stage clean)"
  python3 -I -c '
import sys
p = sys.argv[1] + "/index.html"
s = open(p, encoding="utf-8").read()
s = s.replace("</main>", "<p>a" + chr(int(sys.argv[2], 16)) + "b</p></main>")
open(p, "w", encoding="utf-8").write(s)
' "$t" "$cp"
  bite "dash U+${cp#0x}" "$t" production dashes SKIP_DASHES
done

# Real build, production and staging.
HUGO_OUT="$WORK/real"
mkdir -p "$HUGO_OUT/prod" "$HUGO_OUT/stg"
"$HUGO" --minify --destination "$HUGO_OUT/prod" >/dev/null || fail "production hugo build failed"
HUGO_PARAMS_ENVIRONMENT=staging "$HUGO" --minify --destination "$HUGO_OUT/stg" >/dev/null || fail "staging hugo build failed"
expect_pass "real production build" "$HUGO_OUT/prod" production
expect_pass "real staging build" "$HUGO_OUT/stg" staging

# Independent assertions on the real builds (not through check-output.sh).
if grep -rliE 'noindex' "$HUGO_OUT/prod" --include='*.html' | grep -q .; then fail "production build contains noindex"; fi
pages=$(find "$HUGO_OUT/stg" -name '*.html' | wc -l)
[ "$pages" -ge 1 ] || fail "staging build produced no html"
withidx=$(grep -rliE 'noindex' "$HUGO_OUT/stg" --include='*.html' | wc -l)
[ "$pages" = "$withidx" ] || fail "staging: $withidx of $pages html pages carry noindex"
grep -qx 'Disallow: /' "$HUGO_OUT/stg/robots.txt" || fail "staging robots.txt lacks 'Disallow: /'"
# Negative: the production tree must fail the staging expectation.
run_check "$HUGO_OUT/prod" staging
[ "$RC" != "0" ] || fail "production build must fail the staging expectation"
echo "ok: real builds carry the right indexing signals"

echo "PASS: check-output tests"
