#!/usr/bin/env bash
# Targeted build test for the AI crawler policy and the sitemap (issue #94). Builds production and
# staging and asserts on the built output: production robots.txt allows the search and answer bots,
# blocks the training crawlers and carries the Sitemap line; staging robots.txt is exactly a
# disallow-all group; the sitemap lists no excluded page and gives every URL a valid lastmod date.
# Negative cases mutate the built files and prove each guard bites.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" robots.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

"$HUGO" --minify --destination "$TMP/prod" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  fail "production build failed"
}
HUGO_PARAMS_ENVIRONMENT=staging "$HUGO" --minify --destination "$TMP/stg" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  fail "staging build failed"
}

cat >"$TMP/check.py" <<'PY'
import re
import sys

kind, path = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
ALLOW = ["Googlebot", "Bingbot", "OAI-SearchBot", "ChatGPT-User", "PerplexityBot", "Claude-SearchBot", "Claude-User"]
BLOCK = ["GPTBot", "ClaudeBot", "Google-Extended", "CCBot"]
EXCLUDED = ["/contact/thanks/", "/case-studies/", "404"]
errors = []


def groups(body):
    out, agents, rules, last_ua = {}, [], [], False
    for raw in body.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        k, _, v = line.partition(":")
        k, v = k.strip().lower(), v.strip()
        if k == "sitemap":
            continue
        if k == "user-agent":
            if not last_ua:
                for a in agents:
                    out.setdefault(a, []).extend(rules)
                agents, rules = [], []
            agents.append(v)
            last_ua = True
        else:
            last_ua = False
            rules.append((k, v))
    for a in agents:
        out.setdefault(a, []).extend(rules)
    return out


if kind == "prod":
    g = groups(text)
    for a in ALLOW:
        if ("allow", "/") not in g.get(a, []) or ("disallow", "/") in g.get(a, []):
            errors.append("search or answer bot not allowed: " + a)
    for a in BLOCK:
        if g.get(a) != [("disallow", "/")]:
            errors.append("training crawler not blocked: " + a)
    if ("disallow", "/") in g.get("*", []):
        errors.append("production blocks all crawlers")
    if "*" not in g:
        errors.append("no default group")
    if "Sitemap: https://renegadepenguinllc.com/sitemap.xml" not in text.splitlines():
        errors.append("no absolute Sitemap line")
elif kind == "stg":
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    if lines != ["User-agent: *", "Disallow: /"]:
        errors.append("staging robots.txt is not exactly disallow all: %r" % lines)
elif kind == "sitemap":
    urls = re.findall(r"<url>(.*?)</url>", text, re.S)
    if not urls:
        errors.append("sitemap has no urls")
    for u in urls:
        loc = re.search(r"<loc>(.*?)</loc>", u)
        lm = re.search(r"<lastmod>(.*?)</lastmod>", u)
        name = loc.group(1) if loc else "?"
        for x in EXCLUDED:
            if x in name:
                errors.append("excluded page in sitemap: " + name)
        if not lm or not re.fullmatch(r"20\d\d-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])(T[\d:.+Z-]+)?", lm.group(1)):
            errors.append("missing or invalid lastmod: " + name)
for e in errors:
    print(e)
sys.exit(1 if errors else 0)
PY

check() { python3 -I "$TMP/check.py" "$1" "$2"; }
# Positive cases on the real build.
check prod "$TMP/prod/robots.txt" || fail "production robots.txt"
check stg "$TMP/stg/robots.txt" || fail "staging robots.txt"
check sitemap "$TMP/prod/sitemap.xml" || fail "production sitemap"

# Negative cases: each mutated copy must be rejected.
neg() {
  local kind="$1" src="$2" name="$3" expr="$4"
  sed -E "$expr" "$src" >"$TMP/neg.txt"
  if cmp -s "$src" "$TMP/neg.txt"; then
    fail "negative case $name did not change the file"
  fi
  if check "$kind" "$TMP/neg.txt" >/dev/null; then
    fail "negative case $name was accepted"
  fi
}
P="$TMP/prod/robots.txt"
S="$TMP/prod/sitemap.xml"
neg prod "$P" "allow bot removed" 's/^User-agent: Claude-User$/User-agent: Nobody/'
neg prod "$P" "search bot blocked" '/^User-agent: Googlebot$/,/^$/ s/^Allow: \/$/Disallow: \//'
neg prod "$P" "training bot unblocked" '/^User-agent: GPTBot$/,/^$/ s/^Disallow: \/$/Allow: \//'
neg prod "$P" "training bot dropped" 's/^User-agent: CCBot$/User-agent: Nobody/'
neg prod "$P" "all blocked" '/^User-agent: \*$/,/^$/ s/^Allow: \/$/Disallow: \//'
neg prod "$P" "sitemap line gone" 's/^Sitemap:.*$/# none/'
neg stg "$TMP/stg/robots.txt" "staging allows" 's/^Disallow: \/$/Allow: \//'
neg sitemap "$S" "lastmod removed" 's#<lastmod>[^<]*</lastmod>##'
neg sitemap "$S" "lastmod invalid" 's#<lastmod>[^<]*</lastmod>#<lastmod>soon</lastmod>#'
neg sitemap "$S" "thanks listed" 's#<loc>https://renegadepenguinllc.com/about/</loc>#<loc>https://renegadepenguinllc.com/contact/thanks/</loc>#'
neg sitemap "$S" "case studies listed" 's#<loc>https://renegadepenguinllc.com/about/</loc>#<loc>https://renegadepenguinllc.com/case-studies/</loc>#'

echo "test-robots: ok"
