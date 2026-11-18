#!/usr/bin/env bash
# Build the STAGING variant and serve it on 127.0.0.1 for visual review.
#
# Usage: scripts/render-review.sh [start|stop|status]   (default: start)
# The local server is for visual review only: Cloudflare Pages applies _headers
# and a plain http.server does not. Never launches a browser.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$HOME/.local/share/renegade-penguin-site-dev"
OUT="$STATE/out/review"
PIDF="$STATE/serve.pid"
URLF="$STATE/serve.url"
LOG="$STATE/serve.log"
PORT_FIRST=8765
PORT_LAST=8800

hugo_bin() {
  if command -v hugo >/dev/null 2>&1; then command -v hugo
  elif [ -x "$STATE/bin/hugo" ]; then echo "$STATE/bin/hugo"
  else echo "render-review: hugo not found on PATH or in $STATE/bin" >&2; return 1
  fi
}

# True when PID is alive and its command line is our http.server on 127.0.0.1.
is_our_server() { # <pid>
  local pid="$1" cmd
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  [ -r "/proc/$pid/cmdline" ] || return 1
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  case "$cmd" in *http.server*) ;; *) return 1 ;; esac
  case "$cmd" in *127.0.0.1*) ;; *) return 1 ;; esac
  return 0
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
  local pid
  pid="$(cat "$PIDF" 2>/dev/null || true)"
  if is_our_server "$pid"; then
    echo "running: $(cat "$URLF" 2>/dev/null || echo unknown)"
  else
    echo "not running"
  fi
}

cmd_stop() {
  if [ ! -e "$PIDF" ]; then
    echo "not running"
    return 0
  fi
  local pid
  pid="$(cat "$PIDF" 2>/dev/null || true)"
  if is_our_server "$pid"; then
    kill "$pid"
    local i
    for i in $(seq 1 20); do
      [ -d "/proc/$pid" ] || break
      sleep 0.1
    done
    rm -f "$PIDF" "$URLF"
    echo "stopped server pid $pid"
  else
    rm -f "$PIDF" "$URLF"
    echo "not running (stale pid file removed, nothing killed)"
  fi
}

cmd_start() {
  local pid
  pid="$(cat "$PIDF" 2>/dev/null || true)"
  if is_our_server "$pid"; then
    echo "already running: $(cat "$URLF")"
    return 0
  fi
  rm -f "$PIDF" "$URLF"

  local port="" p
  for p in $(seq "$PORT_FIRST" "$PORT_LAST"); do
    if port_free "$p"; then port="$p"; break; fi
  done
  [ -n "$port" ] || { echo "render-review: no free port in $PORT_FIRST-$PORT_LAST" >&2; return 1; }
  local url="http://127.0.0.1:$port/"

  local hugo
  hugo="$(hugo_bin)"
  mkdir -p "$STATE"
  rm -rf "$OUT"
  (cd "$ROOT" && HUGO_PARAMS_ENVIRONMENT=staging "$hugo" --minify --baseURL "$url" --destination "$OUT" >/dev/null)

  nohup python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$OUT" \
    >"$LOG" 2>&1 < /dev/null &
  pid=$!
  disown "$pid" 2>/dev/null || true
  echo "$pid" > "$PIDF"
  echo "$url" > "$URLF"

  local i
  for i in $(seq 1 20); do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then
      echo "$url"
      echo "note: visual review only; Pages applies _headers and this local server does not."
      return 0
    fi
    sleep 0.25
  done
  echo "render-review: server did not answer at $url" >&2
  kill "$pid" 2>/dev/null || true
  rm -f "$PIDF" "$URLF"
  return 1
}

case "${1:-start}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  *) echo "usage: $0 [start|stop|status]" >&2; exit 2 ;;
esac
