#!/usr/bin/env bash
# Fake jq: checks the environment and TMPDIR for markers, then runs the real jq.
set -euo pipefail
: "${FAKE_DIR:?}" "${FAKE_REAL_JQ:?}"
# shellcheck source=fake-leakcheck.sh
. "$FAKE_DIR/fake-leakcheck.sh"
fake_leakcheck jq
exec "$FAKE_REAL_JQ" "$@"
