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
    -X)
      method=$2
      shift 2
      ;;
    -o)
      out=$2
      shift 2
      ;;
    -w)
      wfmt=$2
      shift 2
      ;;
    -K)
      cfg=$2
      shift 2
      ;;
    --max-time) shift 2 ;;
    --data-binary)
      body=$(cat "${2#@}")
      shift 2
      ;;
    -*) shift ;;
    *)
      url=$1
      shift
      ;;
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
# The body is a file, copied bytewise (it may hold NUL or invalid UTF-8).
if [ -f "$FAKE_DIR/resp/$key.body" ]; then
  bodyfile="$FAKE_DIR/resp/$key.body"
else
  bodyfile="$FAKE_DIR/default.body"
  printf '{"success":true,"errors":[],"result":{}}' >"$bodyfile"
fi
# Like the live API: a rate-limit rule counting by ip.src without cf.colo.id is
# rejected with HTTP 400 code 20155 (unless a canned response was given).
if [ ! -f "$FAKE_DIR/resp/$key.status" ] && [ "$method" = POST ] &&
  [[ "$body" == *'"characteristics":'* ]] && [[ "$body" != *'"cf.colo.id"'* ]]; then
  status=400
  bodyfile="$FAKE_DIR/default.body"
  printf '%s' '{"success":false,"errors":[{"code":20155,"message":"'"'"'[ip.src]'"'"' is not a valid value for characteristics because characteristics field is missing '"'"'cf.colo.id'"'"', this is required"}],"result":null}' >"$bodyfile"
fi
# Like the Free plan: only a 10 s counting period and a 10 s mitigation timeout
# are entitled; anything else is rejected with HTTP 400 (unless canned).
if [ ! -f "$FAKE_DIR/resp/$key.status" ] && [ "$method" = POST ]; then
  for field in period mitigation_timeout; do
    if [[ "$body" =~ \"$field\":([0-9]+) ]] && [ "${BASH_REMATCH[1]}" != 10 ]; then
      status=400
      bodyfile="$FAKE_DIR/default.body"
      printf '%s' '{"success":false,"errors":[{"code":20120,"message":"not entitled to use the '"${field//_/ }"' '"${BASH_REMATCH[1]}"', can only use a '"${field//_/ }"' among [10]"}],"result":null}' >"$bodyfile"
    fi
  done
fi
size=$(wc -c <"$bodyfile")
size=${size//[[:space:]]/}

if [ -n "$out" ]; then
  cat "$bodyfile" >"$out"
else
  cat "$bodyfile"
fi
# Expand the -w tokens the scripts use; real curl also expands \n.
fmt=$wfmt
fmt=${fmt//'%{stderr}'/}
fmt=${fmt//'%{http_code}'/$status}
fmt=${fmt//'%{size_download}'/$size}
fmt=${fmt//'\n'/$'\n'}
case "$wfmt" in
  *'%{stderr}'*) printf '%s' "$fmt" >&2 ;;
  *) printf '%s' "$fmt" ;;
esac
