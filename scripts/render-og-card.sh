#!/usr/bin/env bash
# Render static/brand/og-card.png (1200x630) from assets-src/og-card/og-card.html with headless
# chromium, and record the renderer version in assets-src/og-card/RENDERER.txt. The PNG is a committed
# artifact: regenerate it only with this script and commit RENDERER.txt with it.
# Override the binary with CHROMIUM=/path/to/chromium.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
CHROMIUM="${CHROMIUM:-/usr/bin/chromium}"
SRC="assets-src/og-card/og-card.html"
OUT="static/brand/og-card.png"
REC="assets-src/og-card/RENDERER.txt"
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
[[ -x $CHROMIUM ]] || fail "chromium not found at $CHROMIUM"
[[ -f $SRC ]] || fail "missing $SRC"
"$CHROMIUM" --version >"$REC" 2>/dev/null || fail "could not read the chromium version"
[[ -s $REC ]] || fail "empty chromium version"
"$CHROMIUM" --headless --disable-gpu --hide-scrollbars --window-size=1200,630 \
  --screenshot="$PWD/$OUT" "file://$PWD/$SRC" >/dev/null 2>&1 || fail "render failed"
[[ -s $OUT ]] || fail "no output written to $OUT"
echo "rendered $OUT with $(cat "$REC")"
