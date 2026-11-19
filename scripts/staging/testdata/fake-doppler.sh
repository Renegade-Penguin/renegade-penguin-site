#!/usr/bin/env bash
# Fake doppler: records argv and stdin, and (like the real one) echoes the value.
set -euo pipefail
: "${FAKE_DIR:?}"
printf '%s\n' "$*" >>"$FAKE_DIR/doppler-argv.log"
value=$(cat)
printf '%s' "$value" >"$FAKE_DIR/doppler-stdin.log"
printf 'TURNSTILE_SECRET_KEY = %s\n' "$value"
