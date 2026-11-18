#!/usr/bin/env bash
# Targeted test for scripts/render-review.sh. Starts and stops real local servers,
# fully isolated: a mktemp state dir and a high port range (18765+).
# SCRIPT=<path> runs the test against another copy of the script (mutation check).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/render-review.sh}"
REAL="$(cd "$HOME/.local/share/renegade-penguin-site-dev" && pwd -P)"
# A candidate state dir is acceptable only as a direct rr-test.* child of the real dir.
state_ok() { # <candidate>
  local c
  c="$(realpath -m -- "$1")" || return 1
  [ "$c" != "$REAL" ] || return 1
  [ "$(dirname "$c")" = "$REAL" ] || return 1
  case "$(basename "$c")" in rr-test.*) return 0 ;; *) return 1 ;; esac
}
STATE="$(mktemp -d "$REAL/rr-test.XXXXXX")"
if ! state_ok "$STATE"; then echo "refusing to run against state dir $STATE" >&2; rm -rf "$STATE"; exit 2; fi
STATE="$(cd "$STATE" && pwd -P)"
export RENDER_REVIEW_STATE="$STATE"
export RENDER_REVIEW_PORT_FIRST=18765
PIDF="$STATE/serve.pid"
URLF="$STATE/serve.url"
EXTRA_PIDS=""
FAILS=0

fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $*"; }

alive() { [ -n "${1:-}" ] && [ -d "/proc/$1" ]; }

listeners() { # count listeners on 18765-18800
  ss -ltnH 2>/dev/null | awk '{n=split($4,a,":"); p=a[n]+0; if (p>=18765 && p<=18800) c++} END{print c+0}'
}

ticks_of() { # <pid>; field 22 of /proc/<pid>/stat
  local s f
  s="$(cat "/proc/$1/stat")"; s="${s##*) }"
  read -ra f <<< "$s"
  echo "${f[19]}"
}

cleanup() {
  if [ -n "$STATE" ] && [ "$STATE" != "$REAL" ] && [ -x "$SCRIPT" ]; then
    "$SCRIPT" stop >/dev/null 2>&1 || true
  fi
  local p
  for p in $EXTRA_PIDS; do if alive "$p"; then kill "$p" 2>/dev/null; fi; done
  if [ -n "$STATE" ] && [ "$STATE" != "$REAL" ]; then rm -rf "$STATE"; fi
}
trap cleanup EXIT

[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable" >&2; exit 1; }

# 0. product script has no env-driven command hooks; refusal logic bites
grep -Eq '_KILL_CMD|RENDER_REVIEW_[A-Z_]*CMD' "$SCRIPT" && fail "product script has an env command hook" || ok "no env command hook in script"
state_ok "$REAL" && fail "state_ok accepted the real dir" || ok "state_ok refuses the real dir"
state_ok "$REAL/other" && fail "state_ok accepted a non-rr-test child" || ok "state_ok refuses other child"
state_ok "$REAL/rr-test.x/sub" && fail "state_ok accepted a grandchild" || ok "state_ok refuses grandchild"
state_ok "/tmp/rr-test.x" && fail "state_ok accepted an outside dir" || ok "state_ok refuses outside dir"
state_ok "$STATE" && ok "state_ok accepts the test dir" || fail "state_ok refused the test dir"

# 1. start (fresh: nothing on stderr)
OUT1="$("$SCRIPT" start 2> "$STATE/err1")"; rc=$?
[ ! -s "$STATE/err1" ] && ok "fresh start prints nothing on stderr" || fail "stderr on fresh start: $(cat "$STATE/err1")"
[ "$rc" = "0" ] || fail "start exit $rc"
URL="$(printf '%s\n' "$OUT1" | grep -Eo 'http://127\.0\.0\.1:[0-9]+/' | head -1)"
[ "$URL" = "http://127.0.0.1:18765/" ] && ok "start printed $URL" || fail "unexpected URL '$URL'"
PID="$(head -1 "$PIDF" 2>/dev/null || true)"
alive "$PID" && ok "pid $PID alive" || fail "pid file or process missing"
[ "$(sed -n 2p "$PIDF" 2>/dev/null)" = "$(ticks_of "$PID")" ] && ok "start ticks recorded" || fail "ticks line missing or wrong"
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
[ "$(head -1 "$PIDF")" = "$PID" ] && ok "same pid" || fail "pid changed"
[ "$(listeners)" = "1" ] && ok "one listener" || fail "listeners: $(listeners)"

# 3. status
"$SCRIPT" status | grep -q 'running' && ok "status running" || fail "status not running"
"$SCRIPT" status | grep -qF "$URL" || fail "status lacks URL"

# 3b. permission-denied kill (function injection, no env hook in the product script)
DOUT="$( ( source "$SCRIPT"; kill() { echo "kill: Operation not permitted" >&2; return 1; }; cmd_stop ) 2>&1 )"; rc=$?
[ "$rc" = "1" ] && ok "denied kill exits 1" || fail "denied kill exit $rc"
printf '%s\n' "$DOUT" | grep -q 'could not kill pid' && ok "denied kill message" || fail "denied kill message missing: $DOUT"
{ [ -e "$PIDF" ] && [ -e "$URLF" ]; } && ok "denied kill leaves files" || fail "denied kill removed files"
alive "$PID" && ok "server still alive after denied kill" || fail "server gone after denied kill"

# 3c. kill that returns 0 without killing: files kept, exit 1
DOUT="$( ( source "$SCRIPT"; kill() { return 0; }; cmd_stop ) 2>&1 )"; rc=$?
[ "$rc" = "1" ] && ok "no-op kill exits 1" || fail "no-op kill exit $rc"
printf '%s\n' "$DOUT" | grep -q "server did not exit: pid $PID" && ok "no-op kill message" || fail "no-op kill message missing: $DOUT"
{ [ -e "$PIDF" ] && [ -e "$URLF" ]; } && ok "no-op kill keeps files" || fail "no-op kill removed files"
alive "$PID" && ok "server alive after no-op kill" || fail "server gone after no-op kill"

# 4. stop
"$SCRIPT" stop >/dev/null; rc=$?
[ "$rc" = "0" ] || fail "stop exit $rc"
alive "$PID" && fail "pid $PID still alive" || ok "pid gone"
{ [ ! -e "$PIDF" ] && [ ! -e "$URLF" ]; } && ok "files removed" || fail "files remain"
"$SCRIPT" status | grep -q 'not running' && ok "status not running" || fail "status after stop"

# 5. stop again
"$SCRIPT" stop | grep -q 'not running' && ok "second stop says not running" || fail "second stop message"

# 6. stale pid file naming a throwaway sleep (not an http.server)
sleep 300 &
SP=$!; EXTRA_PIDS="$EXTRA_PIDS $SP"
printf '%s\n%s\n' "$SP" "$(ticks_of "$SP")" > "$PIDF"; echo "http://127.0.0.1:18765/" > "$URLF"
"$SCRIPT" stop >/dev/null 2>&1; rc=$?
alive "$SP" && ok "stale pid (sleep) not killed" || fail "stale pid was killed"
[ "$rc" = "0" ] || fail "stale stop exit $rc"
{ [ ! -e "$PIDF" ] && [ ! -e "$URLF" ]; } && ok "stale files removed" || fail "stale files remain"
kill "$SP" 2>/dev/null

# 7. decoy: python3 -I with http.server and 127.0.0.1 in argv, but not our argv
python3 -I -c 'import time; time.sleep(300)' http.server 127.0.0.1 &
DP=$!; EXTRA_PIDS="$EXTRA_PIDS $DP"
sleep 0.3
printf '%s\n%s\n' "$DP" "$(ticks_of "$DP")" > "$PIDF"; echo "http://127.0.0.1:18765/" > "$URLF"
"$SCRIPT" stop >/dev/null 2>&1
alive "$DP" && ok "decoy not killed" || fail "decoy was killed"
{ [ ! -e "$PIDF" ] && [ ! -e "$URLF" ]; } && ok "decoy files removed" || fail "decoy files remain"
kill "$DP" 2>/dev/null

# 8. wrong start ticks must not kill the real server
"$SCRIPT" start > /dev/null; rc=$?
[ "$rc" = "0" ] || fail "restart exit $rc"
RP="$(head -1 "$PIDF")"; EXTRA_PIDS="$EXTRA_PIDS $RP"
printf '%s\n%s\n' "$RP" "1" > "$PIDF"
"$SCRIPT" stop >/dev/null 2>&1
alive "$RP" && ok "wrong ticks: not killed" || fail "wrong ticks: server was killed"
{ [ ! -e "$PIDF" ] && [ ! -e "$URLF" ]; } && ok "wrong-ticks files removed" || fail "wrong-ticks files remain"
if alive "$RP"; then kill "$RP" 2>/dev/null; fi
sleep 0.5

# 9. two parallel starts: same URL, both exit 0, one listener
A="$STATE/a.out"; B="$STATE/b.out"
"$SCRIPT" start > "$A" 2>&1 & PA=$!
"$SCRIPT" start > "$B" 2>&1 & PB=$!
wait "$PA"; ra=$?; wait "$PB"; rb=$?
{ [ "$ra" = "0" ] && [ "$rb" = "0" ]; } && ok "parallel starts exit 0" || fail "parallel exits $ra $rb"
UA="$(grep -Eo 'http://127\.0\.0\.1:[0-9]+/' "$A" | head -1)"
UB="$(grep -Eo 'http://127\.0\.0\.1:[0-9]+/' "$B" | head -1)"
{ [ -n "$UA" ] && [ "$UA" = "$UB" ]; } && ok "parallel starts same URL" || fail "parallel URLs '$UA' '$UB'"
[ "$(listeners)" = "1" ] && ok "parallel: one listener" || fail "parallel listeners: $(listeners)"
"$SCRIPT" status | grep -q 'running' && ok "parallel: tracked" || fail "parallel: untracked"
"$SCRIPT" stop >/dev/null
sleep 0.3
[ "$(listeners)" = "0" ] && ok "no listener after stop" || fail "listeners after stop: $(listeners)"

# 10. busy first port makes the script choose the next one
python3 -I -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1",18765)); s.listen(1); time.sleep(120)' &
BP=$!; EXTRA_PIDS="$EXTRA_PIDS $BP"
sleep 0.5
OUT3="$("$SCRIPT" start)"; rc=$?
[ "$rc" = "0" ] || fail "busy-port start exit $rc"
printf '%s\n' "$OUT3" | grep -qF 'http://127.0.0.1:18766/' && ok "chose 18766" || fail "did not choose 18766: $OUT3"
"$SCRIPT" stop >/dev/null
kill "$BP" 2>/dev/null

if [ "$FAILS" -gt 0 ]; then echo "FAILED: $FAILS check(s)" >&2; exit 1; fi
echo "PASS: render-review"
