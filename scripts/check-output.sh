#!/usr/bin/env bash
# Output checker for a built site.
#
# Usage: EXPECT_ENV=production|staging [SCRUB_TERMS_FILE=file] scripts/check-output.sh <dir>
# Exit 0 when clean; otherwise non-zero with one "FAIL <check>: <detail>" line per violation.
# Each check can be disabled for the revert-proof test with SKIP_<NAME>=1, where <NAME>
# is the upper-cased check name (SKIP_NO_SCRIPT, SKIP_EXTERNAL_HOST, ...).
set -euo pipefail

DIR="${1:-}"
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "usage: EXPECT_ENV=production|staging $0 <dir>" >&2; exit 2; }
case "${EXPECT_ENV:-}" in
  production | staging) ;;
  *) echo "EXPECT_ENV must be production or staging" >&2; exit 2 ;;
esac

ALLOWED_HOSTS="chiefgyk3d.com github.com renegadepenguinllc.com"
HERE="$(cd "$(dirname "$0")" && pwd)"
VIOLATIONS=0

report() { # <check> <detail>
  echo "FAIL $1: $2"
  VIOLATIONS=$((VIOLATIONS + 1))
}

enabled() { # <check>; honors SKIP_<NAME>=1
  local var="SKIP_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  [ "${!var:-}" != "1" ]
}

html_files() { find "$DIR" -type f -name '*.html'; }
text_files() { find "$DIR" -type f \( -name '*.html' -o -name '*.css' \); }

host_allowed() { # <host>
  local h
  h="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for a in $ALLOWED_HOSTS; do [ "$h" = "$a" ] && return 0; done
  return 1
}

# Reads URL-ish matches on stdin, prints each host that is not allowed.
bad_hosts() {
  local m host
  while IFS= read -r m; do
    host="${m#*//}"
    host="${host%%[/:?#]*}"
    host_allowed "$host" || printf '%s\n' "$host"
  done
}

no_script() {
  local f
  f="$(html_files | xargs -r grep -liE '<script' || true)"
  [ -z "$f" ] || report no_script "<script> found in: $(echo $f)"
}

inline_handler() {
  local f
  f="$(html_files | xargs -r grep -lE '<[^>]*[[:space:]]on[a-zA-Z]+[[:space:]]*=' || true)"
  [ -z "$f" ] || report inline_handler "inline event handler attribute in: $(echo $f)"
}

external_host() {
  local h tag href
  # Resources: src/srcset/action/poster/data, <link href>, @import, url(...)
  while IFS= read -r h; do
    [ -n "$h" ] && report external_host "disallowed host in a resource reference: $h"
  done < <(
    text_files | xargs -r grep -ohiE \
      -e "(src|srcset|action|formaction|poster|data)=[\"']?(https?:)?//[^\"' >/)]+" \
      -e "<link\b[^>]*[[:space:]]href=[\"']?(https?:)?//[^\"' >/]+" \
      -e "@import[[:space:]]*(url\()?[\"']?(https?:)?//[^\"' >/)]+" \
      -e "url\([\"']?(https?:)?//[^\"' >/)]+" | bad_hosts
  )
  # Anchors to other hosts must carry rel containing noopener.
  while IFS= read -r tag; do
    href="$(printf '%s' "$tag" | grep -oiE "href=[\"']?(https?:)?//[^\"' >/]+" | head -n1 || true)"
    [ -n "$href" ] || continue
    h="$(printf '%s\n' "$href" | bad_hosts)"
    [ -n "$h" ] || continue
    printf '%s' "$tag" | grep -qiE "rel=[\"']?[^\"'>]*noopener" ||
      report external_host "link to $h lacks rel=noopener"
  done < <(html_files | xargs -r grep -ohiE '<a\b[^>]*>' || true)
}

scrub_terms() {
  [ -n "${SCRUB_TERMS_FILE:-}" ] || return 0
  [ -f "$SCRUB_TERMS_FILE" ] || { report scrub_terms "SCRUB_TERMS_FILE not found"; return; }
  local f
  f="$(text_files | xargs -r grep -liF -f "$SCRUB_TERMS_FILE" || true)"
  [ -z "$f" ] || report scrub_terms "denylisted term found in: $(echo $f)"
}

noindex() {
  local all with
  if [ "$EXPECT_ENV" = production ]; then
    with="$(html_files | xargs -r grep -liE 'noindex' || true)"
    [ -z "$with" ] || report noindex "production html contains noindex: $(echo $with)"
  else
    all="$(html_files | xargs -r grep -LiE 'noindex' || true)"
    [ -z "$all" ] || report noindex "staging html lacks noindex: $(echo $all)"
  fi
}

robots() {
  local r="$DIR/robots.txt"
  if [ ! -f "$r" ]; then report robots "robots.txt missing"; return; fi
  if [ "$EXPECT_ENV" = staging ]; then
    grep -qE '^Disallow:[[:space:]]*/[[:space:]]*$' "$r" || report robots "staging robots.txt lacks 'Disallow: /'"
  else
    ! grep -qE '^Disallow:[[:space:]]*/[[:space:]]*$' "$r" || report robots "production robots.txt blocks everything"
  fi
}

csp() {
  local h="$DIR/_headers"
  if [ ! -f "$h" ]; then report csp "_headers missing"; return; fi
  grep -qE '^[[:space:]]*Content-Security-Policy:.*default-src' "$h" ||
    report csp "_headers has no Content-Security-Policy line with default-src"
}

about_link() {
  local a="$DIR/about/index.html"
  if [ ! -f "$a" ]; then report about_link "about/index.html missing"; return; fi
  grep -qiE "href=[\"']?https://chiefgyk3d\.com" "$a" ||
    report about_link "about/index.html has no link to chiefgyk3d.com"
}

dashes() {
  local f
  f="$(python3 -I "$HERE/find-dashes.py" "$DIR")"
  [ -z "$f" ] || report dashes "em or en dash in: $(echo $f)"
}

for c in no_script inline_handler external_host scrub_terms noindex robots csp about_link dashes; do
  if enabled "$c"; then "$c"; fi
done

if [ "$VIOLATIONS" -gt 0 ]; then
  echo "check-output: $VIOLATIONS violation(s)" >&2
  exit 1
fi
echo "check-output: clean ($EXPECT_ENV)"
