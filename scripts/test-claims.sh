#!/usr/bin/env bash
# Targeted test for scripts/check-claims.py and the pricing shortcode.
# Fixtures: scripts/fixtures/claims-bad-*/ must fail, claims-ok-*/ must pass.
# A scratch site with a tier or field removed from data/pricing.toml must fail the build.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
HUGO="${HUGO:-hugo}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
soft() {
  echo "FAIL: $*" >&2
  FAILS=$((FAILS + 1))
}

command -v "$HUGO" >/dev/null 2>&1 || {
  echo "FAIL: hugo not found (set HUGO)" >&2
  exit 1
}
[ -f scripts/check-claims.py ] || {
  echo "FAIL: scripts/check-claims.py missing" >&2
  exit 1
}

bad=0
ok=0
for d in scripts/fixtures/claims-*/; do
  name="$(basename "$d")"
  rc=0
  out="$(python3 -I scripts/check-claims.py "$d" 2>&1)" || rc=$?
  case "$name" in
    claims-bad-*)
      bad=$((bad + 1))
      if [ "$rc" != "1" ]; then soft "$name: expected exit 1, got $rc: $out"; else echo "ok: $name fails"; fi
      ;;
    claims-ok-*)
      ok=$((ok + 1))
      if [ "$rc" != "0" ]; then soft "$name: expected exit 0, got $rc: $out"; else echo "ok: $name passes"; fi
      ;;
  esac
done
# Collect loosely, assert strictly: the fixtures must have been found.
[ "$bad" -ge 8 ] || soft "expected at least 8 bad fixtures, found $bad"
[ "$ok" -ge 3 ] || soft "expected at least 3 ok fixtures, found $ok"

# A missing directory is an error, never a pass.
rc=0
python3 -I scripts/check-claims.py "$TMP/does-not-exist" >/dev/null 2>&1 || rc=$?
[ "$rc" != "0" ] || soft "check-claims.py passed a missing directory"

# Shortcode: scratch site with page + data.
scratch() { # <name> <data file content>
  local d="$TMP/$1"
  mkdir -p "$d/content/p" "$d/data"
  cp "$ROOT/hugo.toml" "$d/"
  cp -r "$ROOT/layouts" "$ROOT/assets" "$ROOT/static" "$d/"
  printf -- '---\ntitle: "Home"\n---\n' >"$d/content/_index.md"
  printf -- '---\ntitle: "P"\n---\n\n{{< pricing tier="advisory" field="hourly" >}}\n' >"$d/content/p/_index.md"
  printf '%s' "$2" >"$d/data/pricing.toml"
  echo "$d"
}
FULL='[advisory]
hourly = "H"
retainer = "R"
minimum = "M"
drivers = "D"
'
d="$(scratch good "$FULL")"
"$HUGO" --source "$d" --destination "$d/out" >/dev/null 2>"$TMP/good.err" || {
  cat "$TMP/good.err" >&2
  soft "build with a complete tier failed"
}
grep -q '<span data-price>H</span>' "$d/out/p/index.html" 2>/dev/null || soft "shortcode output not wrapped in span data-price"

d="$(scratch no-tier '[projects]
hourly = "H"
retainer = "R"
minimum = "M"
drivers = "D"
')"
if "$HUGO" --source "$d" --destination "$d/out" >/dev/null 2>"$TMP/nt.err"; then
  soft "build must fail when the tier is missing from data/pricing.toml"
else
  grep -qi 'advisory' "$TMP/nt.err" || soft "missing-tier error does not name the tier: $(tail -n 1 "$TMP/nt.err")"
  echo "ok: missing tier fails the build"
fi

d="$(scratch no-field '[advisory]
retainer = "R"
minimum = "M"
')"
if "$HUGO" --source "$d" --destination "$d/out" >/dev/null 2>"$TMP/nf.err"; then
  soft "build must fail when the field is missing from the tier"
else
  echo "ok: missing field fails the build"
fi

# Every tier in the real data file defines every field and carries the approval flag.
python3 -I - <<'PY' || soft "data/pricing.toml does not define every tier and field"
import tomllib
d = tomllib.load(open("data/pricing.toml", "rb"))
for t in ("advisory", "projects", "ai_review", "speaking"):
    for f in ("hourly", "retainer", "minimum", "drivers"):
        v = d.get(t, {}).get(f)
        assert isinstance(v, str) and v.strip(), (t, f)
src = open("data/pricing.toml", encoding="utf-8").read()
assert src.count("# owner approval pending") >= 4
PY

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS case(s)" >&2
  exit 1
fi
echo "PASS: claims ok"
