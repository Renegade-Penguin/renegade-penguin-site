#!/usr/bin/env bash
# Mocked test for ensure-turnstile.sh. No network, no real doppler.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test-lib.sh
. "$here/test-lib.sh"
t_setup

S=ensure-turnstile.sh
W=/accounts/acct123/challenges/widgets
LIST="$W?per_page=100"
CREATED='{"success":true,"result":{"sitekey":"0xSITEKEY","secret":"'"$TEST_SECRET"'","name":"renegade-penguin-contact"}}'

echo "-- dry run, no widget"
t_reset
t_resp GET "$LIST" 200 '{"success":true,"result":[{"name":"other","sitekey":"0xOTHER"}]}'
t_run "$S"
t_rc 0 "dry run"
t_expect_writes 0 "dry run makes no write call"
if [ -f "$T/doppler-argv.log" ]; then t_fail "dry run called doppler"; else t_ok "dry run does not call doppler"; fi
t_expect_out "WOULD POST $W" "dry run prints the POST"
t_expect_out '"mode":"managed"' "managed mode"
t_expect_out 'staging.renegadepenguinllc.com' "staging domain bound"
t_token_never_leaks

echo "-- apply, creates widget"
t_reset
t_resp GET "$LIST" 200 '{"success":true,"result":[]}'
t_resp POST "$W" 200 "$CREATED"
t_run "$S" --apply
t_rc 0 "apply"
t_expect_writes 1 "one create"
t_expect_call '"name":"renegade-penguin-contact","domains":["staging.renegadepenguinllc.com","renegadepenguinllc.com"],"mode":"managed"' "create body"
t_expect_out "sitekey: 0xSITEKEY" "sitekey printed"
t_token_never_leaks
if [ "$(cat "$T/doppler-stdin.log")" = "$TEST_SECRET" ]; then t_ok "secret reached doppler on stdin"; else t_fail "secret did not reach doppler stdin"; fi
if grep -qF 'secrets set TURNSTILE_SECRET_KEY --project no-php-no-cry --config dev_renegadepenguin' "$T/doppler-argv.log"; then
  t_ok "doppler argv has name, project and config only"
else
  t_fail "unexpected doppler argv: $(cat "$T/doppler-argv.log")"
fi

echo "-- apply, widget exists"
t_reset
t_resp GET "$LIST" 200 '{"success":true,"result":[{"name":"renegade-penguin-contact","sitekey":"0xEXIST"}]}'
t_run "$S" --apply
t_rc 0 "apply when it exists"
t_expect_writes 0 "already-exists makes no duplicate"
t_expect_out "sitekey: 0xEXIST" "existing sitekey printed"
if [ -f "$T/doppler-argv.log" ]; then t_fail "doppler called for existing widget"; else t_ok "doppler not called for existing widget"; fi
t_token_never_leaks
t_finish
