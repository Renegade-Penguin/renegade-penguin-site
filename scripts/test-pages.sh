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
# JSON-LD data blocks (type application/ld+json, issue #20) are not scripts that run: ignore them.
if grep -o '<script[^>]*>' "$c" | grep -vq 'application/ld+json'; then fail "/contact/ without a sitekey must have no script"; fi
if grep -q '[$]' "$c"; then fail "/contact/ must not hold a currency figure"; fi
t="$OUT/contact/thanks/index.html"
[ -f "$t" ] || fail "/contact/thanks/ missing"
grep -q '2 business days' "$t" || fail "/contact/thanks/ must repeat the response promise"
OUT2="$(mktemp -d)"
trap 'rm -rf "$OUT" "$OUT2"' EXIT
HUGO_PARAMS_TURNSTILESITEKEY=fixturekey "$HUGO" --minify --destination "$OUT2" >/dev/null || fail "hugo build with a sitekey exited non-zero"
c2="$OUT2/contact/index.html"
[ "$(grep -o '<script[^>]*>' "$c2" | grep -vc 'application/ld+json')" = "1" ] || fail "/contact/ with a sitekey must have exactly one script"
grep -Eq '<script src="?https://challenges\.cloudflare\.com/turnstile/v0/api\.js"? async defer>' "$c2" || fail "/contact/ Turnstile script tag is not the expected one"
grep -Eq '<div [^>]*class="?cf-turnstile"?' "$c2" || fail "/contact/ with a sitekey needs the widget div"
grep -Eq 'data-sitekey="?fixturekey' "$c2" || fail "/contact/ widget must carry the sitekey param"
grep -Eq 'data-action="?contact' "$c2" || fail "/contact/ widget must carry data-action contact"
if grep -rHo '<script[^>]*>' "$OUT2" --include='*.html' | grep -v 'application/ld+json' | grep -v '/contact/index.html:' | grep -q .; then fail "script outside /contact/ in the sitekey build"; fi
grep -Eq '<a [^>]*href="?https://chiefgyk3d\.com/"?[^>]*rel="?noopener' "$OUT/about/index.html" ||
  grep -Eq '<a [^>]*rel="?noopener"?[^>]*href="?https://chiefgyk3d\.com/' "$OUT/about/index.html" ||
  fail "/about/ must link https://chiefgyk3d.com/ with rel=noopener"

# Task 3: every built page inherits the Dossier shell.
while IFS= read -r f; do
  rel="${f#"$OUT"}"
  grep -q 'class="case-strip"\|class=case-strip' "$f" || fail "$rel has no case strip"
  grep -Eq '<a class="?skip"? href="?#main' "$f" || fail "$rel has no skip link"
  grep -Eq '<main[ >]' "$f" || fail "$rel has no main landmark"
  [ "$(grep -o '<h1[ >]' "$f" | wc -l)" = "1" ] || fail "$rel must have exactly one h1"
done < <(find "$OUT" -name '*.html' -not -path "$OUT/brand/*" | sort)
n_built=$(find "$OUT" -name '*.html' | wc -l)
[ "$n_built" -ge 10 ] || fail "shell loop saw only $n_built pages"
# Case strip text comes from front matter file and status, with defaults.
grep -q 'RP-0001' "$OUT/index.html" || fail "default case strip file text missing on home"
# Header: one row at wide widths means a short main nav; the long tail lives in the footer nav.
hdr=$(sed -n '/<header class="\?site-header/,/<\/header>/p' "$OUT/index.html" | tr '\n' ' ')
hcount=$(printf '%s' "$hdr" | grep -o '<li>' | wc -l)
[ "$hcount" -le 6 ] || fail "header nav shows $hcount items; at most 6 keep it on one row at 1440"
for t in /when-not-to-hire/ /how-we-work/ /who-we-help/ /experience/ /community/; do
  foot=$(sed -n '/<footer/,/<\/footer>/p' "$OUT/index.html")
  printf '%s' "$foot" | grep -Eq "href=\"?$t[\" >]" || fail "footer nav must reach $t"
done
# Speaking page copy and About body.
sp=$(sed 's/<[^>]*>/ /g' "$OUT/services/education-speaking/index.html" | tr -s ' \n' ' ')
printf '%s' "$sp" | grep -q 'Community and non-corporate education is offered free' || fail "speaking page lacks the community education paragraph"
printf '%s' "$sp" | grep -q 'Corporate and vendor events are paid engagements' || fail "speaking page lacks the corporate paragraph"
ab=$(sed 's/<[^>]*>/ /g' "$OUT/about/index.html" | tr -s ' \n' ' ')
printf '%s' "$ab" | grep -q 'independent security advisor behind Renegade Penguin LLC' || fail "about page lacks the new body"

# Segment pages and the Ohio explainer.
segs="small-business healthcare-dental aviation critical-infrastructure"
[ -f "$OUT/who-we-help/index.html" ] || fail "/who-we-help/ missing"
for s in $segs; do
  f="$OUT/who-we-help/$s/index.html"
  [ -f "$f" ] || fail "/who-we-help/$s/ missing"
  [ "$(grep -o '<h1[ >]' "$f" | wc -l)" = "1" ] || fail "/who-we-help/$s/ must have exactly one h1"
  grep -Eq "href=\"?/who-we-help/$s/[\" >]" "$OUT/who-we-help/index.html" ||
    fail "/who-we-help/ must link /who-we-help/$s/"
done
[ -f "$OUT/ohio/index.html" ] || fail "/ohio/ missing"
grep -Eq 'href="?/who-we-help/[" >]' "$OUT/index.html" || fail "main nav must link /who-we-help/"
grep -Eq 'href="?/ohio/[" >]' "$OUT/index.html" || fail "footer must link /ohio/"
# The Ohio page must carry the owner verification placeholder until the owner resolves it.
grep -q '{{OWNER:verify wording against the statute text' "$OUT/ohio/index.html" ||
  fail "/ohio/ must contain the owner verification placeholder"
echo "PASS: pages ok"
