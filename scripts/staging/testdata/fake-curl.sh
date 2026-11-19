#!/usr/bin/env bash
# Fake curl for the staging tests. Never touches the network.
# Records the full argv, and one line per call ("METHOD path body") to
# $FAKE_DIR/calls.log. Reads the stdin config when given -K -.
# Responses: $FAKE_DIR/resp/<METHOD>_<path with non-alnum as _>.{status,body};
# default is 200 with {"success":true,"errors":[],"result":{}}.
# Without -o the body goes to stdout; a -w containing %{stderr} sends the status
# to stderr, otherwise it follows the body on stdout (like real curl).
set -euo pipefail

: "${FAKE_DIR:?}"
# shellcheck source=fake-leakcheck.sh
. "$FAKE_DIR/fake-leakcheck.sh"
fake_leakcheck curl
printf '%s\n' "$*" >>"$FAKE_DIR/argv.log"

method=GET out="" body="" cfg="" url="" wfmt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    -w) wfmt=$2; shift 2 ;;
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
  resp=$(cat "$FAKE_DIR/resp/$key.body")
else
  resp='{"success":true,"errors":[],"result":{}}'
fi

if [ -n "$out" ]; then
  printf '%s' "$resp" >"$out"
else
  printf '%s' "$resp"
fi
case "$wfmt" in
  *'%{stderr}'*) printf '%s' "$status" >&2 ;;
  '\n'*) printf '\n%s' "$status" ;; # real curl expands \n in -w
  *) printf '%s' "$status" ;;
esac
