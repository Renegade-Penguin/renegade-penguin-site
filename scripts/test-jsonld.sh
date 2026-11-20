#!/usr/bin/env bash
# Targeted test for the JSON-LD graph (issue #80). Builds production and staging, then checks every
# page: exactly one application/ld+json script holding one @graph, unique @id values, every @id
# reference resolves in the graph, the Person id, no sameAs to the personal site on the organization,
# no review, rating, price, address or phone keys, and FAQPage text equal to the visible FAQ text.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" jsonld.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
"$HUGO" --minify --destination "$TMP/prod" >/dev/null || {
  echo "FAIL: production build" >&2
  exit 1
}
HUGO_PARAMS_ENVIRONMENT=staging "$HUGO" --minify --destination "$TMP/stg" >/dev/null || {
  echo "FAIL: staging build" >&2
  exit 1
}
python3 -I - "$TMP/prod" "$TMP/stg" <<'PY'
import html
import json
import pathlib
import re
import sys
import tomllib

PERSON = "https://chiefgyk3d.com/#person"
with open("data/person.toml", "rb") as f:
    PERSON_SAMEAS = tomllib.load(f)["same_as"]  # issue #134: the Person sameAs comes from this data file
BANNED = {"review", "aggregateRating", "reviewRating", "rating", "ratingValue", "price", "priceRange",
          "offers", "address", "streetAddress", "telephone", "faxNumber"}
# FAQPage is allowed on exactly these pages (issue #95): the home page and the five answer-first pages.
FAQ_PAGES = {"/", "/services/advisory/", "/services/projects/", "/pricing/", "/ohio/",
             "/who-we-help/healthcare-dental/"}
fails = []


def fail(msg):
    fails.append(msg)


def walk(node, fn):
    if isinstance(node, dict):
        fn(node)
        for v in node.values():
            walk(v, fn)
    elif isinstance(node, list):
        for v in node:
            walk(v, fn)


def types(n):
    t = n.get("@type", [])
    return t if isinstance(t, list) else [t]


def graph_of(path):
    body = path.read_text(encoding="utf-8")
    blocks = re.findall(r'<script[^>]*type="?application/ld\+json"?[^>]*>(.*?)</script>', body, re.S)
    if len(blocks) != 1:
        fail("%s: %d ld+json scripts, want 1" % (path, len(blocks)))
        return None, body
    try:
        data = json.loads(blocks[0])
    except ValueError:
        fail("%s: JSON does not parse" % path)
        return None, body
    if not isinstance(data, dict) or "@graph" not in data or not isinstance(data["@graph"], list):
        fail("%s: no @graph" % path)
        return None, body
    return data, body


def check(root, staging):
    pages = sorted(root.rglob("index.html"))
    seen = {}
    for p in pages:
        rel = "/" + str(p.relative_to(root).parent).replace(".", "") + "/"
        rel = rel.replace("//", "/")
        if rel == "/404/" or "thanks" in rel:
            pass
        data, body = graph_of(p)
        if data is None:
            continue
        g = data["@graph"]
        ids = [n["@id"] for n in g if "@id" in n]
        if len(ids) != len(set(ids)):
            fail("%s: duplicate @id" % rel)
        idset = set(ids)

        def refs(n):
            if set(n) == {"@id"} and n["@id"] not in idset:
                fail("%s: unresolved reference %s" % (rel, n["@id"]))
            for k in BANNED:
                if k in n:
                    fail("%s: banned key %s" % (rel, k))
            if any(t in ("Review", "AggregateRating", "Offer") for t in types(n)):
                fail("%s: banned type" % rel)
        walk(g, refs)
        byid = {n["@id"]: n for n in g if "@id" in n}
        orgs = [n for n in g if any(t in ("Organization", "ProfessionalService") for t in types(n))]
        if len(orgs) != 1:
            fail("%s: want one organization, got %d" % (rel, len(orgs)))
            continue
        org = orgs[0]
        if "chiefgyk3d.com" in json.dumps(org.get("sameAs", [])):
            fail("%s: organization sameAs holds the personal site" % rel)
        if org.get("name") != "Renegade Penguin LLC" or not org.get("sameAs"):
            fail("%s: organization name or sameAs" % rel)
        if not org["@id"].startswith("https://renegadepenguinllc.com/"):
            fail("%s: organization id is not the production base: %s" % (rel, org["@id"]))
        sites = [n for n in g if "WebSite" in types(n)]
        if len(sites) != 1 or sites[0].get("publisher") != {"@id": org["@id"]}:
            fail("%s: WebSite node or publisher" % rel)
        persons = [n for n in g if "Person" in types(n)]
        want_person = rel in ("/", "/about/")
        if want_person != bool(persons):
            fail("%s: Person presence is %s" % (rel, bool(persons)))
        for n in persons:
            if n["@id"] != PERSON or n.get("worksFor") != {"@id": org["@id"]}:
                fail("%s: Person id or worksFor" % rel)
            if n.get("jobTitle") != "Founder, Renegade Penguin LLC" or n.get("sameAs") != PERSON_SAMEAS:
                fail("%s: Person jobTitle or sameAs" % rel)
        if want_person and org.get("founder") != {"@id": PERSON}:
            fail("%s: founder must reference the Person" % rel)
        services = [n for n in g if "Service" in types(n)]
        want_service = rel in ("/services/advisory/", "/services/projects/", "/services/education-speaking/")
        if len(services) != (1 if want_service else 0):
            fail("%s: %d Service nodes" % (rel, len(services)))
        for s in services:
            if s.get("provider") != {"@id": org["@id"]} or not s.get("name") or not s.get("description"):
                fail("%s: Service provider, name or description" % rel)
        crumbs = [n for n in g if "BreadcrumbList" in types(n)]
        if rel == "/":
            if crumbs:
                fail("/: home must have no BreadcrumbList")
        else:
            if len(crumbs) != 1:
                fail("%s: want one BreadcrumbList" % rel)
            else:
                items = crumbs[0]["itemListElement"]
                if [i["position"] for i in items] != list(range(1, len(items) + 1)) or len(items) < 2:
                    fail("%s: breadcrumb positions" % rel)
                if items[0]["name"] != "Home" or items[-1]["item"] != "https://renegadepenguinllc.com" + rel:
                    fail("%s: breadcrumb ends: %s" % (rel, items))
        faqs = [n for n in g if "FAQPage" in types(n)]
        if rel in FAQ_PAGES:
            if len(faqs) != 1:
                fail("%s: want one FAQPage" % rel)
            else:
                got = [(q["name"], q["acceptedAnswer"]["text"]) for q in faqs[0]["mainEntity"]]
                vis = [(html.unescape(re.sub(r"<[^>]+>", "", a)).strip(), html.unescape(re.sub(r"<[^>]+>", "", b)).strip())
                       for a, b in re.findall(r'<details class="?faq"?>\s*<summary>(.*?)</summary>\s*<p>(.*?)</p>', body, re.S)]
                if not vis or got != vis:
                    fail("%s: FAQPage text differs from the visible FAQ: %r vs %r" % (rel, got, vis))
        elif faqs:
            fail("%s: FAQPage on a page without a visible FAQ" % rel)
        seen[rel] = True
    for must in ("/", "/about/", "/services/", "/services/advisory/", "/services/projects/",
                 "/services/education-speaking/", "/contact/", "/pricing/", "/ohio/",
                 "/who-we-help/healthcare-dental/"):
        if must not in seen:
            fail("%s: page not checked in %s" % (must, root))
    if len(seen) < 10:
        fail("collected too few pages: %d" % len(seen))
    return seen


a = check(pathlib.Path(sys.argv[1]), False)
b = check(pathlib.Path(sys.argv[2]), True)
# Staging keeps the same graph shape: identical graphs page for page.
for rel in a:
    pa = pathlib.Path(sys.argv[1]) / rel.strip("/") / "index.html"
    pb = pathlib.Path(sys.argv[2]) / rel.strip("/") / "index.html"
    ga, _ = graph_of(pa)
    gb, _ = graph_of(pb)
    if ga != gb:
        fail("%s: staging graph differs from production" % rel)
# Negative case: the guard must bite on a graph with a dangling reference and a banned key.
bad = {"@graph": [{"@id": "x", "@type": "Organization", "founder": {"@id": "nope"}, "telephone": "1"}]}
idset = {"x"}
dangling = []
walk(bad, lambda n: dangling.append(n) if set(n) == {"@id"} and n["@id"] not in idset else None)
hit = []
walk(bad, lambda n: hit.extend(k for k in BANNED if k in n))
assert dangling and hit, "negative case did not bite"
for f in fails:
    print("FAIL: " + f, file=sys.stderr)
sys.exit(1 if fails else 0)
PY
rc=$?
[ "$rc" = 0 ] && echo "test-jsonld: ok"
exit "$rc"
