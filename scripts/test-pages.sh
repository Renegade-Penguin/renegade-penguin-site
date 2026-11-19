#!/usr/bin/env bash
# Targeted page test. Builds the site and asserts the six pages.
set -euo pipefail
cd "$(dirname "$0")/.."
HUGO="${HUGO:-hugo}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

"$HUGO" --minify --destination "$OUT" >/dev/null || fail "hugo build exited non-zero"
pages="/ /services/ /experience/ /community/ /about/ /contact/"
for p in $pages; do
  f="$OUT${p}index.html"
  [ -f "$f" ] || fail "$p missing"
  h1=$(grep -o '<h1[ >]' "$f" | wc -l)
  [ "$h1" = "1" ] || fail "$p must have exactly one h1, found $h1"
  for q in $pages; do
    [ "$q" = "$p" ] && continue
    grep -Eq "href=\"?${q}[\" >]" "$f" || fail "$p has no nav link to $q"
  done
done

# Contact page: the intake form, no third-party request without a sitekey, the exact Turnstile tag with one.
c="$OUT/contact/index.html"
grep -Eq '<form [^>]*action="?/api/contact"?' "$c" || fail "/contact/ needs a form posting to /api/contact"
grep -Eq '<form [^>]*method="?post"?' "$c" || fail "/contact/ form must use method post"
for field in name email organization size need budget timeline heard consent website; do
  grep -Eq "<(input|select|textarea) [^>]*name=\"?${field}[\" >]" "$c" || fail "/contact/ form has no field $field"
  grep -Eq "<label [^>]*for=\"?${field}[\" >]" "$c" || fail "/contact/ field $field has no label"
done
grep -Eq '<input [^>]*name="?website"?[^>]*tabindex="?-1' "$c" || fail "/contact/ honeypot needs tabindex -1"
grep -Eq '<input [^>]*name="?consent"?[^>]*required|<input [^>]*required[^>]*name="?consent' "$c" || fail "/contact/ consent must be required"
if grep -q 'challenges\.cloudflare\.com' "$c"; then fail "/contact/ without a sitekey must not mention Turnstile"; fi
if grep -q 'cf-turnstile' "$c"; then fail "/contact/ without a sitekey must have no widget"; fi
if grep -q '<script' "$c"; then fail "/contact/ without a sitekey must have no script"; fi
if grep -q '[$]' "$c"; then fail "/contact/ must not hold a currency figure"; fi
t="$OUT/contact/thanks/index.html"
[ -f "$t" ] || fail "/contact/thanks/ missing"
grep -q '2 business days' "$t" || fail "/contact/thanks/ must repeat the response promise"
OUT2="$(mktemp -d)"
trap 'rm -rf "$OUT" "$OUT2"' EXIT
HUGO_PARAMS_TURNSTILESITEKEY=fixturekey "$HUGO" --minify --destination "$OUT2" >/dev/null || fail "hugo build with a sitekey exited non-zero"
c2="$OUT2/contact/index.html"
[ "$(grep -o '<script' "$c2" | wc -l)" = "1" ] || fail "/contact/ with a sitekey must have exactly one script"
grep -Eq '<script src="?https://challenges\.cloudflare\.com/turnstile/v0/api\.js"? async defer>' "$c2" || fail "/contact/ Turnstile script tag is not the expected one"
grep -Eq '<div [^>]*class="?cf-turnstile"?' "$c2" || fail "/contact/ with a sitekey needs the widget div"
grep -Eq 'data-sitekey="?fixturekey' "$c2" || fail "/contact/ widget must carry the sitekey param"
grep -Eq 'data-action="?contact' "$c2" || fail "/contact/ widget must carry data-action contact"
if grep -rl '<script' "$OUT2" --include='*.html' | grep -v '/contact/index.html$' | grep -q .; then fail "script outside /contact/ in the sitekey build"; fi
grep -Eq '<a [^>]*href="?https://chiefgyk3d\.com/"?[^>]*rel="?noopener' "$OUT/about/index.html" ||
  grep -Eq '<a [^>]*rel="?noopener"?[^>]*href="?https://chiefgyk3d\.com/' "$OUT/about/index.html" ||
  fail "/about/ must link https://chiefgyk3d.com/ with rel=noopener"
echo "PASS: pages ok"
