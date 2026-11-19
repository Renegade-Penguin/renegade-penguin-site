#!/usr/bin/env bash
# Instrumented dirname: the entrypoints must not call it at all (they derive
# their directory with parameter expansion). If one does, this records the call
# and checks the environment for markers before running the real dirname.
set -euo pipefail
: "${FAKE_DIR:?}" "${FAKE_REAL_DIRNAME:?}"
# shellcheck source=fake-leakcheck.sh
. "$FAKE_DIR/fake-leakcheck.sh"
printf 'dirname was called\n' >>"$FAKE_DIR/dirname.log"
fake_leakcheck dirname
exec "$FAKE_REAL_DIRNAME" "$@"
