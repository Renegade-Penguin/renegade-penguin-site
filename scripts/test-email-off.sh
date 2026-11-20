#!/usr/bin/env bash
# Targeted test for the email_off markers (scripts/check-email-off.py). Builds production and
# staging, requires the markers to survive the minifier, and proves the checker bites on fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."
HUGO="${HUGO:-hugo}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
check() { python3 -I scripts/check-email-off.py "$1"; }

# --- negative fixtures: the checker must bite ---
fx() { # fx <name> <body html>: writes a one-page site, echoes the dir
  mkdir -p "$TMP/fx-$1"
  printf '<!doctype html><html lang=en><head><title>t</title></head><body>%s</body></html>' "$2" >"$TMP/fx-$1/index.html"
  echo "$TMP/fx-$1"
}
d=$(fx bare '<p>Write to a@example.org today</p>')
check "$d" >/dev/null && fail "fixture: an unwrapped address must fail"
d=$(fx mailto '<p><a href=mailto:a@x.org>mail</a></p>')
check "$d" >/dev/null && fail "fixture: an unwrapped mailto link must fail"
d=$(fx unbalanced '<p><!--email_off-->a@example.org</p>')
check "$d" >/dev/null && fail "fixture: an unclosed marker must fail"
d=$(fx rewritten '<p><a href=/cdn-cgi/l/email-protection#abc>[email protected]</a></p>')
check "$d" >/dev/null && fail "fixture: an email-protection rewrite must fail"
d=$(fx wrapped '<p><!--email_off--><a href=mailto:a@example.org>a@example.org</a><!--/email_off--></p>')
check "$d" >/dev/null || fail "fixture: a wrapped address and mailto link must pass"
d=$(fx ignored '<p title=a@example.org data-x=a@example.org>ok</p><script type=application/ld+json>{"email":"a@example.org"}</script><textarea>a@example.org</textarea>')
sed -i 's|<title>t</title>|<title>a@example.org</title><meta name=x content=a@example.org>|' "$d/index.html"
check "$d" >/dev/null || fail "fixture: addresses in head, attributes, script and textarea must be ignored"

# --- the real site, both variants ---
"$HUGO" --minify --destination "$TMP/prod" >/dev/null 2>"$TMP/build.err" || fail "production build: $(cat "$TMP/build.err")"
HUGO_PARAMS_ENVIRONMENT=staging "$HUGO" --minify --destination "$TMP/stg" >/dev/null 2>"$TMP/build.err" || fail "staging build: $(cat "$TMP/build.err")"
for v in prod stg; do
  pages=$(find "$TMP/$v" -name '*.html' | wc -l)
  [ "$pages" -gt 10 ] || fail "$v: only $pages html pages collected"
  list=$(grep -rl --include='*.html' -e '<!--email_off-->' "$TMP/$v" || true)
  markers=$(printf '%s\n' "$list" | grep -c . || true)
  [ "$markers" -ge 4 ] || fail "$v: markers survive on only $markers pages (minifier dropped them?)"
  check "$TMP/$v" || fail "$v: an address or mailto link is outside email_off markers"
  leak=$(grep -rl --include='*.html' -e 'email-protection' "$TMP/$v" || true)
  [ -z "$leak" ] || fail "$v: email-protection in built html: $leak"
done
echo "PASS: email_off ok"
