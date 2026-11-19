#!/usr/bin/env bash
# Fake curl for the staging tests. Never touches the network.
# Records the full argv, and one line per call ("METHOD path body") to
# $FAKE_DIR/calls.log. Reads the stdin config when given -K -.
# Responses: $FAKE_DIR/resp/<METHOD>_<path with non-alnum as _>.{status,body};
# default is 200 with {"success":true,"result":{}}.
set -euo pipefail

: "${FAKE_DIR:?}"
printf '%s\n' "$*" >>"$FAKE_DIR/argv.log"

method=GET out="" body="" cfg="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    -K) cfg=$2; shift 2 ;;
    --max-time) shift 2 ;;
    --data-binary) body=$(cat "${2#@}"); shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done

if [ "$cfg" = "-" ]; then
  if grep -q 'Authorization: Bearer ' </dev/stdin; then
    echo "auth-via-stdin" >>"$FAKE_DIR/auth.log"
  fi
fi

path=${url#https://api.cloudflare.com/client/v4}
printf '%s %s %s\n' "$method" "$path" "$body" >>"$FAKE_DIR/calls.log"

key=$(printf '%s_%s' "$method" "$path" | tr -c 'A-Za-z0-9\n' '_')
if [ -f "$FAKE_DIR/resp/$key.status" ]; then
  status=$(cat "$FAKE_DIR/resp/$key.status")
else
  status=200
fi
if [ -f "$FAKE_DIR/resp/$key.body" ]; then
  cp "$FAKE_DIR/resp/$key.body" "$out"
else
  printf '{"success":true,"errors":[],"result":{}}' >"$out"
fi
printf '%s' "$status"
