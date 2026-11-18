#!/usr/bin/env bash
# Targeted test for scripts/render-review.sh. Starts and stops real local servers.
# SCRIPT=<path> runs the test against another copy of the script (mutation check).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/render-review.sh}"
STATE="$HOME/.local/share/renegade-penguin-site-dev"
PIDF="$STATE/serve.pid"
URLF="$STATE/serve.url"
BUSY_PID=""
FAILS=0

fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $*"; }

cleanup() {
  "$SCRIPT" stop >/dev/null 2>&1 || true
  if [ -n "$BUSY_PID" ] && kill -0 "$BUSY_PID" 2>/dev/null; then kill "$BUSY_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable" >&2; exit 1; }
"$SCRIPT" stop >/dev/null 2>&1 || true

# 1. start
OUT1="$("$SCRIPT" start)"; rc=$?
[ "$rc" = "0" ] || fail "start exit $rc"
URL="$(printf '%s\n' "$OUT1" | grep -Eo 'http://127\.0\.0\.1:[0-9]+/' | head -1)"
[ -n "$URL" ] && ok "start printed $URL" || fail "no URL printed"
PID="$(cat "$PIDF" 2>/dev/null || true)"
[ -n "$PID" ] && [ -d "/proc/$PID" ] && ok "pid $PID alive" || fail "pid file or process missing"
[ "$(cat "$URLF" 2>/dev/null)" = "$URL" ] && ok "url file matches" || fail "url file mismatch"
printf '%s\n' "$OUT1" | grep -qi 'visual review only' && ok "note printed" || fail "visual-review note missing"

for p in "" services/ about/; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "${URL}${p}")"
  [ "$code" = "200" ] && ok "GET /$p 200" || fail "GET /$p got $code"
done
curl -fsS "$URL" | grep -qi 'noindex' && ok "home has noindex" || fail "home lacks noindex"

# 2. start again
OUT2="$("$SCRIPT" start)"; rc=$?
[ "$rc" = "0" ] || fail "second start exit $rc"
printf '%s\n' "$OUT2" | grep -qF "$URL" && ok "second start prints same URL" || fail "second start URL differs"
[ "$(cat "$PIDF")" = "$PID" ] && ok "same pid" || fail "pid changed"
n=0
for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  c="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null || true)"
  case "$c" in *http.server*127.0.0.1*" --directory "*review*) n=$((n + 1)) ;; esac
done
[ "$n" = "1" ] && ok "one server only" || fail "found $n review servers"

# 3. status
"$SCRIPT" status | grep -q 'running' && ok "status running" || fail "status not running"
"$SCRIPT" status | grep -qF "$URL" || fail "status lacks URL"

# 4. stop
"$SCRIPT" stop >/dev/null; rc=$?
[ "$rc" = "0" ] || fail "stop exit $rc"
[ ! -d "/proc/$PID" ] && ok "pid gone" || fail "pid $PID still alive"
{ [ ! -e "$PIDF" ] && [ ! -e "$URLF" ]; } && ok "files removed" || fail "files remain"
"$SCRIPT" status | grep -q 'not running' && ok "status not running" || fail "status after stop"

# 5. stop again
"$SCRIPT" stop | grep -q 'not running' && ok "second stop says not running" || fail "second stop message"

# 6. stale pid file: the test shell's own PID is not an http.server
echo "$$" > "$PIDF"; echo "http://127.0.0.1:1/" > "$URLF"
"$SCRIPT" stop >/dev/null 2>&1; rc=$?
kill -0 "$$" 2>/dev/null && ok "stale pid not killed" || fail "stale pid was killed"
[ "$rc" = "0" ] || fail "stale stop exit $rc"
{ [ ! -e "$PIDF" ] && [ ! -e "$URLF" ]; } && ok "stale files removed" || fail "stale files remain"

# 7. busy port 8765 makes the script choose 8766
python3 -I -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1",8765)); s.listen(1); time.sleep(120)' &
BUSY_PID=$!
sleep 0.5
OUT3="$("$SCRIPT" start)"; rc=$?
[ "$rc" = "0" ] || fail "busy-port start exit $rc"
printf '%s\n' "$OUT3" | grep -qF 'http://127.0.0.1:8766/' && ok "chose 8766" || fail "did not choose 8766: $OUT3"
"$SCRIPT" stop >/dev/null
kill "$BUSY_PID" 2>/dev/null || true; BUSY_PID=""

if [ "$FAILS" -gt 0 ]; then echo "FAILED: $FAILS check(s)" >&2; exit 1; fi
echo "PASS: render-review"
