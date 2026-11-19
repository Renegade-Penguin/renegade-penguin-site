#!/usr/bin/env bash
# Fake doppler. Records argv. For "secrets set" it records stdin to
# $FAKE_DIR/doppler-stdin.log and, like the real one, echoes the value.
# FAKE_DOPPLER_MODE: ok (echo on stdout, default), stderr (echo on stderr),
# fail (echo on stderr, exit 1). FAKE_DOPPLER_PREFLIGHT=fail makes
# "configs get" fail.
set -euo pipefail
: "${FAKE_DIR:?}"
# shellcheck source=fake-leakcheck.sh
. "$FAKE_DIR/fake-leakcheck.sh"
fake_leakcheck doppler
printf '%s\n' "$*" >>"$FAKE_DIR/doppler-argv.log"

if [ "${1:-}" = "configs" ]; then
  if [ "${FAKE_DOPPLER_PREFLIGHT:-ok}" = "fail" ]; then
    exit 1
  fi
  printf '{"name":"dev_renegadepenguin"}\n'
  exit 0
fi

value=$(cat)
printf '%s' "$value" >"$FAKE_DIR/doppler-stdin.log"
case "${FAKE_DOPPLER_MODE:-ok}" in
  ok) printf 'TURNSTILE_SECRET_KEY = %s\n' "$value" ;;
  stderr) printf 'TURNSTILE_SECRET_KEY = %s\n' "$value" >&2 ;;
  fail)
    printf 'TURNSTILE_SECRET_KEY = %s\n' "$value" >&2
    exit 1
    ;;
esac
