#!/usr/bin/env bash
# Targeted build test for the trust and legal pages (issue #20): pages, footer links,
# canonical links, sitemap, JSON-LD, security.txt and its headers.
set -euo pipefail
cd "$(dirname "$0")/.."
HUGO="${HUGO:-hugo}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

"$HUGO" --minify --destination "$OUT" >/dev/null || fail "hugo build exited non-zero"

for p in privacy terms accessibility security-policy about; do
  f="$OUT/$p/index.html"
  [ -f "$f" ] || fail "/$p/ missing"
  h1=$(grep -o '<h1[ >]' "$f" | wc -l)
  [ "$h1" = "1" ] || fail "/$p/ must have exactly one h1, found $h1"
  grep -Eq '<link rel="?canonical"? href="?https://renegadepenguinllc\.com/'"$p"'/"?>' "$f" || fail "/$p/ has no canonical link"
  grep -q "https://renegadepenguinllc.com/$p/" "$OUT/sitemap.xml" || fail "/$p/ is not in the sitemap"
  # The footer links to each legal page, from every page.
  for q in privacy terms accessibility security-policy; do
    grep -Eq "href=\"?/$q/[\" >]" "$f" || fail "/$p/ footer has no link to /$q/"
  done
done
[ -f "$OUT/contact/thanks/index.html" ] || fail "the thanks page was not built"
if grep -q '/thanks' "$OUT/sitemap.xml"; then fail "the thanks page is in the sitemap"; fi
if grep -qi '404' "$OUT/sitemap.xml"; then fail "the 404 page is in the sitemap"; fi
[ -f "$OUT/404.html" ] || fail "404.html missing"
if grep -qi 'rel="\?canonical' "$OUT/404.html"; then fail "404.html must not carry a canonical link"; fi

# JSON-LD (issue #80 graph shape): one @graph per page with the Organization everywhere, the Person
# on About and Home only, valid JSON, and no invented contact or commercial facts.
python3 -I - "$OUT" <<'PY' || fail "JSON-LD check failed"
import json, os, re, sys
root = sys.argv[1]
pat = re.compile(r'<script type="?application/ld\+json"?>(.*?)</script>', re.S)
BANNED = ("address", "streetAddress", "telephone", "review", "aggregateRating", "price", "offers")


def types(n):
    t = n.get("@type", [])
    return t if isinstance(t, list) else [t]


def walk(node):
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)


def check(rel, body):
    blocks = [json.loads(b) for b in pat.findall(body)]
    if len(blocks) != 1 or not isinstance(blocks[0].get("@graph"), list):
        return "%s: want one ld+json block with a @graph" % rel
    graph = blocks[0]["@graph"]
    orgs = [n for n in graph if "Organization" in types(n)]
    if len(orgs) != 1:
        return "%s: want one Organization, got %d" % (rel, len(orgs))
    org = orgs[0]
    if org.get("name") != "Renegade Penguin LLC" or org.get("sameAs") != ["https://github.com/Renegade-Penguin"]:
        return "%s: unexpected Organization %s" % (rel, org)
    persons = [n for n in graph if "Person" in types(n)]
    if bool(persons) != (rel in ("about/index.html", "index.html")):
        return "%s: Person present is %s" % (rel, bool(persons))
    for p in persons:
        if p.get("worksFor", {}).get("@id") != org["@id"]:
            return "Person.worksFor does not point at the Organization"
    for n in walk(graph):
        for banned in BANNED:
            if banned in n:
                return "%s: JSON-LD carries an invented %s" % (rel, banned)
        if "email" in n and n["email"] != "contact@renegadepenguinllc.com":
            return "%s: JSON-LD email is not the published contact address" % rel
    return None


seen = 0
for dp, _d, fs in os.walk(root):
    for f in fs:
        if not f.endswith(".html"):
            continue
        path = os.path.join(dp, f)
        rel = os.path.relpath(path, root)
        problem = check(rel, open(path, encoding="utf-8").read())
        if problem:
            sys.exit(problem)
        seen += 1
if seen < 5:
    sys.exit("only %d pages checked" % seen)
# Negative case: the guard must reject an invented telephone and a stray email.
def blk(g):
    return '<script type="application/ld+json">' + json.dumps({"@graph": g}) + "</script>"


good = {"@type": "Organization", "@id": "o", "name": "Renegade Penguin LLC", "sameAs": ["https://github.com/Renegade-Penguin"]}
assert check("contact/index.html", blk([good])) is None, "negative case baseline"
assert check("contact/index.html", blk([dict(good, telephone="1")])), "telephone not rejected"
assert check("contact/index.html", blk([dict(good, email="x@example.com")])), "stray email not rejected"
PY

# security.txt per RFC 9116, and its Content-Type route in _headers.
s="$OUT/.well-known/security.txt"
[ -f "$s" ] || fail ".well-known/security.txt missing from the build"
for field in 'Contact: mailto:contact@renegadepenguinllc.com' 'Preferred-Languages: en' \
  'Canonical: https://renegadepenguinllc.com/.well-known/security.txt' \
  'Policy: https://renegadepenguinllc.com/security-policy/'; do
  grep -qxF "$field" "$s" || fail "security.txt lacks '$field'"
done
grep -Eq '^Expires: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$s" || fail "security.txt has no RFC 3339 Expires"
if grep -qi '^Encryption:' "$s"; then fail "security.txt has an Encryption line but no key was supplied"; fi
awk '/^\/\.well-known\/security\.txt$/ {r=1; next} /^[^ ]/ {r=0} r && /^  Content-Type: text\/plain; charset=utf-8$/ {ok=1} END {exit ok ? 0 : 1}' "$OUT/_headers" ||
  fail "_headers has no text/plain; charset=utf-8 route for security.txt"
echo "PASS: trust pages ok"
