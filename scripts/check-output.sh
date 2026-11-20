#!/usr/bin/env bash
# Output checker for a built site.
#
# Usage: EXPECT_ENV=production|staging SCRUB_TERMS_FILE=<file> scripts/check-output.sh <dir>
# Exit 0 when clean; otherwise non-zero with one "FAIL <check>: <detail>" line per violation.
# Checks: no_script, inline_handler, external_host, noindex, unsafe_scheme, meta_refresh,
# active_embed, base_element, duplicate_attr (html parser, check-html.py), scrub_terms (raw scan plus
# check-scrub.py), robots, csp (check-headers.py), about_link, dashes, claims (check-claims.py).
# SCRUB_TERMS_FILE is required (blank lines and lines starting with # are ignored).
# Each check can be disabled for the revert-proof test with SKIP_<NAME>=1:
# SKIP_NO_SCRIPT, SKIP_INLINE_HANDLER, SKIP_EXTERNAL_HOST, SKIP_NOINDEX, SKIP_SCRUB_TERMS,
# SKIP_ROBOTS, SKIP_CSP, SKIP_ABOUT_LINK, SKIP_DASHES, SKIP_UNSAFE_SCHEME, SKIP_META_REFRESH,
# SKIP_ACTIVE_EMBED, SKIP_BASE_ELEMENT, SKIP_DUPLICATE_ATTR, SKIP_CLAIMS, SKIP_OWNER_TOKENS,
# SKIP_FRESH, SKIP_OWNER_REVIEW.
# Opt-in check: owner_review runs only when REQUIRE_OWNER_APPROVAL=1 and EXPECT_ENV=production (the real
# cutover sets it; CI and staging do not) and fails on any page carrying the x-owner-review pending meta.
# Opt-in check: owner_tokens (check-owner-tokens.py) runs only when REQUIRE_NO_OWNER_TOKENS=1 and
# fails on any page text holding an unresolved owner placeholder.
# fresh (check-fresh.py): no placeholder links or lorem, a current footer year, a security.txt
# that has not expired and is at most a year out.
set -euo pipefail

DIR="${1:-}"
[ -n "$DIR" ] && [ -d "$DIR" ] || {
  echo "usage: EXPECT_ENV=production|staging $0 <dir>" >&2
  exit 2
}
case "${EXPECT_ENV:-}" in
  production | staging) ;;
  *)
    echo "EXPECT_ENV must be production or staging" >&2
    exit 2
    ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
VIOLATIONS=0
PATTERNS=""
trap '[ -z "$PATTERNS" ] || rm -f "$PATTERNS"' EXIT

report() { # <check> <detail>
  echo "FAIL $1: $2"
  VIOLATIONS=$((VIOLATIONS + 1))
}

enabled() { # <check>; honors SKIP_<NAME>=1
  local var
  var="SKIP_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  [ "${!var:-}" != "1" ]
}

# run_helper <check> <script> [args...]: run a python helper under python3 -I and keep its
# output in HELPER_OUT. Any non-zero status (a crash included) is reported as a violation
# of <check>, so a failing helper can never read as a pass.
run_helper() {
  local check="$1" status=0
  shift
  HELPER_OUT="$(python3 -I "$@" 2>&1)" || status=$?
  if [ "$status" -ne 0 ]; then
    report "$check" "helper failed with status $status: $(printf '%s' "$HELPER_OUT" | tail -n 1)"
    HELPER_OUT=""
  fi
  return 0
}

# Structural findings come from the html parser, once for the whole tree.
run_helper html_checker "$HERE/check-html.py" "$DIR" "$EXPECT_ENV"
HTML_FINDINGS="$HELPER_OUT"

from_parser() { # <check>
  local c f d
  while IFS=$'\t' read -r c f d; do
    [ "$c" = "$1" ] && report "$1" "$d ($f)"
  done <<<"$HTML_FINDINGS"
  return 0
}

no_script() { from_parser no_script; }
inline_handler() { from_parser inline_handler; }
external_host() { from_parser external_host; }
noindex() { from_parser noindex; }
unsafe_scheme() { from_parser unsafe_scheme; }
meta_refresh() { from_parser meta_refresh; }

active_embed() {
  from_parser active_embed
}

base_element() {
  from_parser base_element
}

duplicate_attr() {
  from_parser duplicate_attr
}

scrub_terms() {
  if [ -z "${SCRUB_TERMS_FILE:-}" ] || [ ! -r "$SCRUB_TERMS_FILE" ] || [ ! -f "$SCRUB_TERMS_FILE" ]; then
    report scrub_terms "SCRUB_TERMS_FILE required"
    return 0
  fi
  PATTERNS="$(mktemp)"
  grep -vE '^[[:space:]]*(#|$)' "$SCRUB_TERMS_FILE" >"$PATTERNS" || true
  if [ ! -s "$PATTERNS" ]; then
    report scrub_terms "no patterns in SCRUB_TERMS_FILE (only blanks and comments)"
    return 0
  fi
  local f status=0
  # Every regular file, any extension, case-insensitive, fixed strings, binary as text.
  # grep exits 0 on a match, 1 on none and 2 on an error; an error must not read as clean.
  f="$(grep -railF -f "$PATTERNS" "$DIR" 2>&1)" || status=$?
  case "$status" in
    0)
      report scrub_terms "denylisted term found in: $(echo $f)"
      ;;
    1) ;;
    *)
      report scrub_terms "raw scan failed with status $status: $(printf '%s' "$f" | tail -n 1)"
      ;;
  esac
  # Normalized scan: UTF-8 required, character references decoded, tags removed.
  local c file detail
  run_helper scrub_terms "$HERE/check-scrub.py" "$DIR" "$PATTERNS"
  while IFS=$'\t' read -r c file detail; do
    [ -n "$c" ] && report scrub_terms "$detail ($file)"
  done <<<"$HELPER_OUT"
  return 0
}

# True when robots.txt has a "User-agent: *" group containing "Disallow: /".
robots_blocks_all() {
  awk '
    BEGIN { found = 0; star = 0; inua = 0 }
    tolower($0) ~ /^[ \t]*user-agent:/ {
      v = $0; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t\r]*$/, "", v)
      if (!inua) star = 0
      inua = 1
      if (v == "*") star = 1
      next
    }
    tolower($0) ~ /^[ \t]*disallow:/ {
      inua = 0
      v = $0; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t\r]*$/, "", v)
      if (star && v == "/") found = 1
      next
    }
    /^[ \t\r]*$/ { next }
    { inua = 0 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

robots() {
  local r="$DIR/robots.txt"
  if [ ! -f "$r" ]; then
    report robots "robots.txt missing"
    return 0
  fi
  # awk exits 0 when the group is found, 1 when not, 2 on an error (never a pass).
  local status=0
  robots_blocks_all "$r" || status=$?
  if [ "$status" -gt 1 ]; then
    report robots "robots.txt check failed with status $status"
  elif [ "$EXPECT_ENV" = staging ]; then
    [ "$status" -eq 0 ] || report robots "staging robots.txt needs a 'User-agent: *' group with 'Disallow: /'"
  else
    [ "$status" -ne 0 ] || report robots "production robots.txt blocks everything"
  fi
}

csp() {
  local p
  run_helper csp "$HERE/check-headers.py" "$DIR/_headers"
  while IFS= read -r p; do
    [ -n "$p" ] && report csp "$p"
  done <<<"$HELPER_OUT"
  return 0
}

about_link() {
  local a="$DIR/about/index.html"
  if [ ! -f "$a" ]; then
    report about_link "about/index.html missing"
    return 0
  fi
  grep -qiE "href=[\"']?https://chiefgyk3d\.com" "$a" ||
    report about_link "about/index.html has no link to chiefgyk3d.com"
}

dashes() {
  run_helper dashes "$HERE/find-dashes.py" "$DIR"
  [ -z "$HELPER_OUT" ] || report dashes "em or en dash in: $(echo $HELPER_OUT)"
}

claims() {
  # check-claims.py exits 1 when it has findings (printed as "<file><TAB><detail>"); any other
  # non-zero status is a helper failure and is never read as a pass.
  local f d status=0 out
  out="$(python3 -I "$HERE/check-claims.py" "$DIR" 2>&1)" || status=$?
  if [ "$status" -gt 1 ]; then
    report claims "helper failed with status $status: $(printf '%s' "$out" | tail -n 1)"
    return 0
  fi
  while IFS=$'\t' read -r f d; do
    [ -n "$f" ] && report claims "$d ($f)"
  done <<<"$out"
  return 0
}

owner_tokens() {
  # Opt-in: only when REQUIRE_NO_OWNER_TOKENS=1 (the deploy workflow sets it; CI keeps the
  # placeholders green). check-owner-tokens.py exits 1 with "<file><TAB><detail>" lines when a
  # page holds an unresolved owner placeholder; any other non-zero status is a helper failure.
  # Unset, empty and 0 skip; 1 runs; any other value fails closed so "true" or "yes" cannot skip.
  case "${REQUIRE_NO_OWNER_TOKENS:-}" in
    "" | 0) return 0 ;;
    1) ;;
    *)
      report owner_tokens "REQUIRE_NO_OWNER_TOKENS must be 0, 1 or empty, got an unexpected value"
      return 0
      ;;
  esac
  local f d status=0 out
  out="$(python3 -I "$HERE/check-owner-tokens.py" "$DIR" 2>&1)" || status=$?
  if [ "$status" -gt 1 ]; then
    report owner_tokens "helper failed with status $status: $(printf '%s' "$out" | tail -n 1)"
    return 0
  fi
  while IFS=$'\t' read -r f d; do
    [ -n "$f" ] && report owner_tokens "$d ($f)"
  done <<<"$out"
  return 0
}

owner_review() {
  # Opt-in (issue #98): pages not yet approved by the owner carry <meta name="x-owner-review"
  # content="pending"> (front matter owner_review = "pending"). Only the real production cutover sets
  # REQUIRE_OWNER_APPROVAL=1, so CI and staging builds stay green; staging never fails for it.
  # Unset, empty and 0 skip; 1 runs; any other value fails closed.
  case "${REQUIRE_OWNER_APPROVAL:-}" in
    "" | 0) return 0 ;;
    1) ;;
    *)
      report owner_review "REQUIRE_OWNER_APPROVAL must be 0, 1 or empty, got an unexpected value"
      return 0
      ;;
  esac
  [ "$EXPECT_ENV" = production ] || return 0
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && report owner_review "page awaits owner approval, remove owner_review from its front matter (${f#"$DIR"/})"
  done < <(grep -rliE --include='*.html' --include='*.htm' '<meta[[:space:]]+name=["'"'"']?x-owner-review["'"'"']?[[:space:]]+content=["'"'"']?pending' "$DIR" | sort || true)
  return 0
}

fresh() {
  # check-fresh.py exits 1 when it has findings (printed as "<file><TAB><detail>"); any other
  # non-zero status is a helper failure and is never read as a pass.
  local f d status=0 out
  out="$(python3 -I "$HERE/check-fresh.py" "$DIR" 2>&1)" || status=$?
  if [ "$status" -gt 1 ]; then
    report fresh "helper failed with status $status: $(printf '%s' "$out" | tail -n 1)"
    return 0
  fi
  while IFS=$'\t' read -r f d; do
    [ -n "$f" ] && report fresh "$d ($f)"
  done <<<"$out"
  return 0
}

for c in no_script inline_handler external_host unsafe_scheme meta_refresh active_embed base_element duplicate_attr scrub_terms noindex robots csp about_link dashes claims owner_tokens owner_review fresh; do
  if enabled "$c"; then "$c"; fi
done

if [ "$VIOLATIONS" -gt 0 ]; then
  echo "check-output: $VIOLATIONS violation(s)" >&2
  exit 1
fi
echo "check-output: clean ($EXPECT_ENV)"
