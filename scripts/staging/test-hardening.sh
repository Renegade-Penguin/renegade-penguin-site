#!/usr/bin/env bash
# Mocked test: every staging script refuses to run with xtrace on, and never
# prints the token or widget secret even then. No network.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test-lib.sh
. "$here/test-lib.sh"
t_setup

MSG="error: xtrace is enabled; refusing to run so credentials cannot be traced"
LIST="/accounts/acct123/challenges/widgets?per_page=100"
CREATED='{"success":true,"result":{"sitekey":"0xSITEKEY","secret":"'"$TEST_SECRET"'"}}'

for s in ensure-pages-project.sh attach-staging-domain.sh ensure-turnstile.sh ensure-rate-limit.sh; do
  echo "-- $s under bash -x"
  t_reset
  t_resp GET "$LIST" 200 '{"success":true,"result":[]}'
  t_resp POST /accounts/acct123/challenges/widgets 200 "$CREATED"
  t_bash_flags -x
  t_run "$s" --apply
  t_rc 1 "$s refuses under bash -x"
  t_expect_out "$MSG" "$s prints the fixed refusal"
  if printf '%s' "$OUT" | grep -qFf "$T/markers"; then t_fail "$s traced a secret under bash -x"; else t_ok "$s traced no secret"; fi
  if [ -s "$T/calls.log" ]; then t_fail "$s made a call while tracing"; else t_ok "$s made no call while tracing"; fi

  echo "-- $s with SHELLOPTS=xtrace"
  t_reset
  t_env SHELLOPTS=xtrace
  t_run "$s" --apply
  t_rc 1 "$s refuses with SHELLOPTS=xtrace"
  t_expect_out "$MSG" "$s prints the fixed refusal (SHELLOPTS)"
  if printf '%s' "$OUT" | grep -qFf "$T/markers"; then t_fail "$s traced a secret (SHELLOPTS)"; else t_ok "$s traced no secret (SHELLOPTS)"; fi
done
t_finish
