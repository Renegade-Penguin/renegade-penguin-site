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
# The dash fixtures are built at run time with chr() so no dash is committed.
# A final step builds the real site in production and staging and runs the checker.
# Case failures are collected and reported together; the exit code is non-zero if any.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK="scripts/check-output.sh"
FIX="scripts/fixtures"
HUGO="${HUGO:-hugo}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
soft() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

[ -x "$CHECK" ] || fail "$CHECK missing or not executable"

TERMS="$WORK/terms.txt"
printf '%s\n' 'zzbannedtermzz' > "$TERMS"

stage() { # <base> [overlay-dir] -> echoes a fresh tree path
  # stage runs in a command substitution, so a counter would not persist; use mktemp.
  local d
  d="$(mktemp -d "$WORK/tree.XXXXXX")"
  cp -R "$FIX/$1/." "$d/"
  if [ -n "${2:-}" ]; then cp -R "$2/." "$d/"; fi
  echo "$d"
}

run_check() { # <dir> <env> [VAR=1 ...]; sets RC and OUT. Later VAR=... wins.
  local dir="$1" envn="$2"; shift 2
  set +e
  OUT="$(env EXPECT_ENV="$envn" SCRUB_TERMS_FILE="$TERMS" "$@" "$CHECK" "$dir" 2>&1)"
  RC=$?
  set -e
}

expect_pass() { # <label> <tree> <env>
  run_check "$2" "$3"
  if [ "$RC" != "0" ]; then soft "$1: expected pass, got exit $RC: $OUT"; return 0; fi
  echo "ok: $1 passes"
}

bite() { # <label> <tree> <env> <check-name> <SKIP var>
  local label="$1" tree="$2" envn="$3" name="$4" skip="$5"
  run_check "$tree" "$envn"
  if [ "$RC" = "0" ]; then soft "$label: expected failure, got exit 0"; return 0; fi
  if ! printf '%s\n' "$OUT" | grep -q "^FAIL $name:"; then soft "$label: no 'FAIL $name:' line in: $OUT"; return 0; fi
  run_check "$tree" "$envn" "$skip=1"
  if [ "$RC" != "0" ]; then soft "$label: with $skip=1 expected pass, got exit $RC: $OUT"; return 0; fi
  echo "ok: $label fails on $name and passes with $skip=1"
}

# bite_terms <label> <tree> <termsfile|UNSET> <message fragment>
bite_terms() {
  local label="$1" tree="$2" tf="$3" frag="$4"
  set +e
  if [ "$tf" = UNSET ]; then
    OUT="$(env -u SCRUB_TERMS_FILE EXPECT_ENV=production "$CHECK" "$tree" 2>&1)"
  else
    OUT="$(env SCRUB_TERMS_FILE="$tf" EXPECT_ENV=production "$CHECK" "$tree" 2>&1)"
  fi
  RC=$?
  set -e
  if [ "$RC" = "0" ]; then soft "$label: expected failure, got exit 0"; return 0; fi
  if ! printf '%s\n' "$OUT" | grep -q "^FAIL scrub_terms: .*$frag"; then soft "$label: no scrub_terms line with '$frag' in: $OUT"; return 0; fi
  set +e
  if [ "$tf" = UNSET ]; then
    OUT="$(env -u SCRUB_TERMS_FILE SKIP_SCRUB_TERMS=1 EXPECT_ENV=production "$CHECK" "$tree" 2>&1)"
  else
    OUT="$(env SCRUB_TERMS_FILE="$tf" SKIP_SCRUB_TERMS=1 EXPECT_ENV=production "$CHECK" "$tree" 2>&1)"
  fi
  RC=$?
  set -e
  if [ "$RC" != "0" ]; then soft "$label: with SKIP_SCRUB_TERMS=1 expected pass, got exit $RC: $OUT"; return 0; fi
  echo "ok: $label fails on scrub_terms and passes with SKIP_SCRUB_TERMS=1"
}

expect_pass "clean (production)" "$(stage clean)" production
expect_pass "clean-staging (staging)" "$(stage clean-staging)" staging

run_check "$(stage clean)" bogus
if [ "$RC" = "0" ]; then soft "bogus EXPECT_ENV must fail"; else echo "ok: bogus EXPECT_ENV rejected"; fi

# b <label> <base> <overlay> <env> <check> <skip>
b() { bite "$1" "$(stage "$2" "$FIX/$3")" "$4" "$5" "$6"; }

# Structural checks (HTML parser)
b "script tag"              clean bad-no-script         production no_script       SKIP_NO_SCRIPT
b "uppercase SCRIPT"        clean bad-script-upper      production no_script       SKIP_NO_SCRIPT
b "script split by newline" clean bad-script-split      production no_script       SKIP_NO_SCRIPT
b "inline handler"          clean bad-inline-handler    production inline_handler  SKIP_INLINE_HANDLER
b "handler after a > in an attribute value" clean bad-handler-gt production inline_handler SKIP_INLINE_HANDLER
b "handler on its own line" clean bad-handler-newline   production inline_handler  SKIP_INLINE_HANDLER
b "external img src"        clean bad-external-img      production external_host   SKIP_EXTERNAL_HOST
b "src with spaces around =" clean bad-src-spaces       production external_host   SKIP_EXTERNAL_HOST
b "second srcset candidate" clean bad-srcset            production external_host   SKIP_EXTERNAL_HOST
b "external link tag"       clean bad-external-linktag  production external_host   SKIP_EXTERNAL_HOST
b "external css import"     clean bad-external-css      production external_host   SKIP_EXTERNAL_HOST
b "style element url( )"    clean bad-style-element     production external_host   SKIP_EXTERNAL_HOST
b "style attribute url( )"  clean bad-style-attr        production external_host   SKIP_EXTERNAL_HOST
b "style element @import"   clean bad-style-import      production external_host   SKIP_EXTERNAL_HOST
b "iframe src"              clean bad-iframe            production external_host   SKIP_EXTERNAL_HOST
b "form action"             clean bad-form-action       production external_host   SKIP_EXTERNAL_HOST
b "anchor without noopener" clean bad-external-anchor   production external_host   SKIP_EXTERNAL_HOST
b "anchor split across lines" clean bad-anchor-split    production external_host   SKIP_EXTERNAL_HOST

# Denylist: every file, case-insensitive
b "term in body"            clean bad-scrub-body        production scrub_terms     SKIP_SCRUB_TERMS
b "term in title"           clean bad-scrub-title       production scrub_terms     SKIP_SCRUB_TERMS
b "term in alt"             clean bad-scrub-alt         production scrub_terms     SKIP_SCRUB_TERMS
b "term in sitemap.xml"     clean bad-scrub-sitemap     production scrub_terms     SKIP_SCRUB_TERMS
b "mixed-case term in an extensionless file" clean bad-scrub-extless production scrub_terms SKIP_SCRUB_TERMS

# Denylist file handling (required, comments and blanks stripped, never empty)
CLEANTREE="$(stage clean)"
BADTREE="$(stage clean "$FIX/bad-scrub-body")"
: > "$WORK/empty.txt"
printf '%s\n' '# only a comment' '' '   ' > "$WORK/comments.txt"
printf '%s\n' '' '# a comment' '' 'zzbannedtermzz' '' > "$WORK/mixed.txt"
bite_terms "SCRUB_TERMS_FILE unset"       "$CLEANTREE" UNSET "SCRUB_TERMS_FILE required"
bite_terms "SCRUB_TERMS_FILE unreadable"  "$CLEANTREE" "$WORK/does-not-exist" "SCRUB_TERMS_FILE required"
bite_terms "empty terms file"             "$CLEANTREE" "$WORK/empty.txt" "no patterns"
bite_terms "comments-only terms file"     "$CLEANTREE" "$WORK/comments.txt" "no patterns"
bite_terms "blank line plus one pattern (bad tree)" "$BADTREE" "$WORK/mixed.txt" "denylisted"
set +e
OUT="$(env SCRUB_TERMS_FILE="$WORK/mixed.txt" EXPECT_ENV=production "$CHECK" "$CLEANTREE" 2>&1)"; RC=$?
set -e
if [ "$RC" != "0" ]; then soft "blank line plus pattern must pass a clean tree: $OUT"; else echo "ok: blank line plus pattern passes a clean tree"; fi

# Indexing signals
b "noindex in production"   clean bad-noindex-production production noindex        SKIP_NOINDEX
b "staging missing noindex" clean-staging bad-staging-no-noindex staging noindex   SKIP_NOINDEX
b "noindex only in prose (staging)" clean-staging bad-staging-noindex-prose staging noindex SKIP_NOINDEX
b "staging robots allows"   clean-staging bad-staging-no-disallow staging robots   SKIP_ROBOTS
b "staging robots no User-agent" clean-staging bad-robots-no-useragent staging robots SKIP_ROBOTS

# Headers
b "missing CSP"             clean bad-csp               production csp             SKIP_CSP
b "script-src * unsafe-inline" clean bad-csp-script-wild production csp            SKIP_CSP
b "default-src * alone"     clean bad-csp-default-wild  production csp             SKIP_CSP
b "no frame-ancestors"      clean bad-csp-no-frame-ancestors production csp        SKIP_CSP
b "no base-uri"             clean bad-csp-no-base-uri   production csp             SKIP_CSP
b "no form-action"          clean bad-csp-no-form-action production csp            SKIP_CSP
b "style-src unsafe-inline" clean bad-csp-unsafe-inline production csp             SKIP_CSP
b "script-src unsafe-eval"  clean bad-csp-unsafe-eval   production csp             SKIP_CSP
b "connect-src https:"      clean bad-csp-https         production csp             SKIP_CSP
b "default-src data:"       clean bad-csp-data          production csp             SKIP_CSP
b "style-src host source"   clean bad-csp-host          production csp             SKIP_CSP

b "missing about link"      clean bad-about-link        production about_link      SKIP_ABOUT_LINK

# Dash fixtures are generated so the characters never appear in the repo.
dash_case() { # <codepoint> <file that receives the dash>
  local cp="$1" file="$2" t
  t="$(stage clean)"
  python3 -I -c '
import sys
p = sys.argv[1] + "/" + sys.argv[2]
d = chr(int(sys.argv[3], 16))
s = open(p, encoding="utf-8").read()
if p.endswith(".html"):
    s = s.replace("</main>", "<p>a" + d + "b</p></main>")
else:
    s = s + "a" + d + "b\n"
open(p, "w", encoding="utf-8").write(s)
' "$t" "$file" "$cp"
  bite "dash U+${cp#0x} in $file" "$t" production dashes SKIP_DASHES
}
dash_case 0x2014 index.html
dash_case 0x2013 index.html
dash_case 0x2014 sitemap.xml
dash_case 0x2013 css/site.css
dash_case 0x2014 robots.txt

# Real build, production and staging.
HUGO_OUT="$WORK/real"
mkdir -p "$HUGO_OUT/prod" "$HUGO_OUT/stg"
"$HUGO" --minify --destination "$HUGO_OUT/prod" >/dev/null || fail "production hugo build failed"
HUGO_PARAMS_ENVIRONMENT=staging "$HUGO" --minify --destination "$HUGO_OUT/stg" >/dev/null || fail "staging hugo build failed"
expect_pass "real production build" "$HUGO_OUT/prod" production
expect_pass "real staging build" "$HUGO_OUT/stg" staging

# Independent assertions on the real builds (not through check-output.sh).
if grep -rliE 'noindex' "$HUGO_OUT/prod" --include='*.html' | grep -q .; then soft "production build contains noindex"; fi
pages=$(find "$HUGO_OUT/stg" -name '*.html' | wc -l)
[ "$pages" -ge 1 ] || fail "staging build produced no html"
withidx=$(grep -rliE 'noindex' "$HUGO_OUT/stg" --include='*.html' | wc -l)
[ "$pages" = "$withidx" ] || soft "staging: $withidx of $pages html pages carry noindex"
grep -qx 'Disallow: /' "$HUGO_OUT/stg/robots.txt" || soft "staging robots.txt lacks 'Disallow: /'"
run_check "$HUGO_OUT/prod" staging
if [ "$RC" = "0" ]; then soft "production build must fail the staging expectation"; fi
echo "checked: real builds carry the right indexing signals"

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS case(s)" >&2
  exit 1
fi
echo "PASS: check-output tests"
