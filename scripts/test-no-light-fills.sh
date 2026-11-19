#!/usr/bin/env bash
# Test for scripts/check-light-fills.py: the cream fixture must fail (exit 1,
# naming both rules), the real CSS must pass.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fails=0
fail() {
  echo "FAIL: $*" >&2
  fails=$((fails + 1))
}

out=$(python3 -I scripts/check-light-fills.py scripts/fixtures/light-fill/cream.css 2>&1)
rc=$?
[ "$rc" = "1" ] || fail "cream fixture must exit 1, got $rc"
printf '%s\n' "$out" | grep -q '^LIGHT-FILL: .band' || fail "cream fixture: .band not reported"
printf '%s\n' "$out" | grep -q '^LIGHT-FILL: .hero' || fail "cream fixture: .hero not reported"

python3 -I scripts/check-light-fills.py assets/css/tokens.css assets/css/main.css
rc=$?
[ "$rc" = "0" ] || fail "real CSS must exit 0, got $rc"

[ "$fails" = "0" ] || exit 1
echo "PASS: no light fills"
