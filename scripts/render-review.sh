#!/usr/bin/env bash
# Build the STAGING variant and serve it on 127.0.0.1 for visual review.
#
# Usage: scripts/render-review.sh [start|stop|status]   (default: start)
# Env: RENDER_REVIEW_STATE      state dir (default ~/.local/share/renegade-penguin-site-dev)
#      RENDER_REVIEW_PORT_FIRST first port to try (default 8765; tries 36 ports)
# The local server is for visual review only: Cloudflare Pages applies _headers
# and a plain http.server does not. Never launches a browser.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="$HOME/.local/share/renegade-penguin-site-dev"
STATE="${RENDER_REVIEW_STATE:-$DEV}"
OUT="$STATE/out/review"
PIDF="$STATE/serve.pid" # line 1: pid, line 2: process start ticks
URLF="$STATE/serve.url"
LOG="$STATE/serve.log"
LOCKF="$STATE/serve.lock"
PORT_FIRST="${RENDER_REVIEW_PORT_FIRST:-8765}"
case "$PORT_FIRST" in
  '' | *[!0-9]*)
    echo "render-review: RENDER_REVIEW_PORT_FIRST must be digits only" >&2
    exit 2
    ;;
esac
if [ "${#PORT_FIRST}" -gt 5 ] || [ "$((10#$PORT_FIRST))" -lt 1 ] || [ "$((10#$PORT_FIRST))" -gt 65500 ]; then
  echo "render-review: RENDER_REVIEW_PORT_FIRST must be between 1 and 65500" >&2
  exit 2
fi
PORT_LAST=$((10#$PORT_FIRST + 35))

hugo_bin() {
  if command -v hugo >/dev/null 2>&1; then
    command -v hugo
  elif [ -x "$DEV/bin/hugo" ]; then
    echo "$DEV/bin/hugo"
  else
    echo "render-review: hugo not found on PATH or in $DEV/bin" >&2
    return 1
  fi
}

# Process start time in clock ticks (field 22 of /proc/<pid>/stat).
get_ticks() { # <pid>
  local s f
  s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  s="${s##*) }"
  read -ra f <<<"$s"
  echo "${f[19]}"
}

# True only when <pid> is exactly the server this script spawns: same uid, exact
# argv (port from the URL file, exact output directory), and matching start ticks.
is_our_server() { # <pid> <recorded-ticks>
  local pid="$1" want_ticks="$2" url port uid
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  [ -r "/proc/$pid/cmdline" ] || return 1
  url="$(cat "$URLF" 2>/dev/null)" || return 1
  port="${url#http://127.0.0.1:}"
  port="${port%/}"
  case "$port" in '' | *[!0-9]*) return 1 ;; esac
  uid="$(awk '/^Uid:/ {print $2}' "/proc/$pid/status" 2>/dev/null)" || return 1
  [ "$uid" = "$(id -u)" ] || return 1
  local -a got want
  readarray -d '' -t got <"/proc/$pid/cmdline" 2>/dev/null || return 1
  want=(python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$OUT")
  [ "${#got[@]}" = "${#want[@]}" ] || return 1
  local i
  for i in "${!want[@]}"; do
    [ "${got[$i]}" = "${want[$i]}" ] || return 1
  done
  [ -n "$want_ticks" ] && [ "$(get_ticks "$pid")" = "$want_ticks" ] || return 1
  return 0
}

read_pidfile() { # sets REC_PID, REC_TICKS
  REC_PID=""
  REC_TICKS=""
  [ -r "$PIDF" ] || return 0
  {
    read -r REC_PID || true
    read -r REC_TICKS || true
  } <"$PIDF"
}

port_free() { # <port>
  python3 -I -c 'import socket,sys
s=socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()' "$1"
}

cmd_status() {
  read_pidfile
  if is_our_server "$REC_PID" "$REC_TICKS"; then
    echo "running: $(cat "$URLF" 2>/dev/null || echo unknown)"
  else
    echo "not running"
  fi
}

# stop takes no lock on purpose: it only kills a process that passes the full
# own-server check, so a racing start can at worst make it report not running or
# kill the server that start is replacing; it never kills anything else (fails closed).
cmd_stop() {
  if [ ! -e "$PIDF" ]; then
    echo "not running"
    return 0
  fi
  read_pidfile
  if is_our_server "$REC_PID" "$REC_TICKS"; then
    local err
    if ! err="$(kill "$REC_PID" 2>&1)"; then
      echo "render-review: could not kill pid $REC_PID: $err (files left in place)" >&2
      return 1
    fi
    local i
    for i in $(seq 1 20); do
      [ -d "/proc/$REC_PID" ] || break
      sleep 0.1
    done
    if [ -d "/proc/$REC_PID" ] && is_our_server "$REC_PID" "$REC_TICKS"; then
      echo "server did not exit: pid $REC_PID" >&2
      return 1
    fi
    rm -f "$PIDF" "$URLF"
    echo "stopped server pid $REC_PID"
  else
    rm -f "$PIDF" "$URLF"
    echo "not running (stale pid file removed, nothing killed)"
  fi
}

cmd_start() {
  mkdir -p "$STATE"
  exec 9>"$LOCKF"
  flock 9

  read_pidfile
  if is_our_server "$REC_PID" "$REC_TICKS"; then
    echo "already running: $(cat "$URLF")"
    return 0
  fi
  rm -f "$PIDF" "$URLF"

  local port="" p
  for p in $(seq "$PORT_FIRST" "$PORT_LAST"); do
    if port_free "$p"; then
      port="$p"
      break
    fi
  done
  [ -n "$port" ] || {
    echo "render-review: no free port in $PORT_FIRST-$PORT_LAST" >&2
    return 1
  }
  local url="http://127.0.0.1:$port/"

  local hugo
  hugo="$(hugo_bin)"
  rm -rf "$OUT"
  (cd "$ROOT" && HUGO_PARAMS_ENVIRONMENT=staging "$hugo" --minify --baseURL "$url" --destination "$OUT" >/dev/null 9>&-)

  python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$OUT" \
    >"$LOG" 2>&1 </dev/null 9>&- &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  local ticks
  ticks="$(get_ticks "$pid" || true)"
  printf '%s\n%s\n' "$pid" "$ticks" >"$PIDF"
  echo "$url" >"$URLF"

  local i
  for i in $(seq 1 20); do
    if curl -fsS -o /dev/null "$url" 2>/dev/null &&
      kill -0 "$pid" 2>/dev/null && is_our_server "$pid" "$ticks"; then
      echo "$url"
      echo "note: visual review only; Pages applies _headers and this local server does not."
      return 0
    fi
    sleep 0.25
  done
  echo "render-review: our server did not come up at $url" >&2
  if [ "$(get_ticks "$pid" 2>/dev/null || true)" = "$ticks" ]; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDF" "$URLF"
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-start}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    *)
      echo "usage: $0 [start|stop|status]" >&2
      exit 2
      ;;
  esac
fi
