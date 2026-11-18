#!/usr/bin/env bash
# Output checker for a built site.
#
# Usage: EXPECT_ENV=production|staging SCRUB_TERMS_FILE=<file> scripts/check-output.sh <dir>
# Exit 0 when clean; otherwise non-zero with one "FAIL <check>: <detail>" line per violation.
# Checks: no_script, inline_handler, external_host, noindex, unsafe_scheme, meta_refresh,
# active_embed, base_element, duplicate_attr (html parser, check-html.py), scrub_terms (raw scan plus
# check-scrub.py), robots, csp (check-headers.py), about_link, dashes.
# SCRUB_TERMS_FILE is required (blank lines and lines starting with # are ignored).
# Each check can be disabled for the revert-proof test with SKIP_<NAME>=1:
# SKIP_NO_SCRIPT, SKIP_INLINE_HANDLER, SKIP_EXTERNAL_HOST, SKIP_NOINDEX, SKIP_SCRUB_TERMS,
# SKIP_ROBOTS, SKIP_CSP, SKIP_ABOUT_LINK, SKIP_DASHES, SKIP_UNSAFE_SCHEME, SKIP_META_REFRESH,
# SKIP_ACTIVE_EMBED, SKIP_BASE_ELEMENT, SKIP_DUPLICATE_ATTR.
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

# Structural findings come from the html parser, once for the whole tree.
HTML_FINDINGS="$(python3 -I "$HERE/check-html.py" "$DIR" "$EXPECT_ENV")"

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
  local f
  # Every regular file, any extension, case-insensitive, fixed strings, binary as text.
  f="$(find "$DIR" -type f -print0 | xargs -0 -r grep -aliF -f "$PATTERNS" || true)"
  [ -z "$f" ] || report scrub_terms "denylisted term found in: $(echo $f)"
  # Normalized scan: UTF-8 required, character references decoded, tags removed.
  local c file detail
  while IFS=$'\t' read -r c file detail; do
    [ -n "$c" ] && report scrub_terms "$detail ($file)"
  done < <(python3 -I "$HERE/check-scrub.py" "$DIR" "$PATTERNS")
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
  if [ "$EXPECT_ENV" = staging ]; then
    robots_blocks_all "$r" || report robots "staging robots.txt needs a 'User-agent: *' group with 'Disallow: /'"
  else
    ! robots_blocks_all "$r" || report robots "production robots.txt blocks everything"
  fi
}

csp() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && report csp "$p"
  done < <(python3 -I "$HERE/check-headers.py" "$DIR/_headers")
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
  local f
  f="$(python3 -I "$HERE/find-dashes.py" "$DIR")"
  [ -z "$f" ] || report dashes "em or en dash in: $(echo $f)"
}

for c in no_script inline_handler external_host unsafe_scheme meta_refresh active_embed base_element duplicate_attr scrub_terms noindex robots csp about_link dashes; do
  if enabled "$c"; then "$c"; fi
done

if [ "$VIOLATIONS" -gt 0 ]; then
  echo "check-output: $VIOLATIONS violation(s)" >&2
  exit 1
fi
echo "check-output: clean ($EXPECT_ENV)"
