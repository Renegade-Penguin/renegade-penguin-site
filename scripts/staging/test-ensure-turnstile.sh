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
NOSECRET='{"success":true,"result":{"sitekey":"0xSITEKEY","name":"renegade-penguin-contact"}}'
SETARGV='secrets set TURNSTILE_SECRET_KEY --project no-php-no-cry --config dev_renegadepenguin'
PREFLIGHT='configs get --project no-php-no-cry --config dev_renegadepenguin'

no_doppler() { # label
  if [ -f "$T/doppler-argv.log" ]; then t_fail "$1: doppler was called"; else t_ok "$1: doppler not called"; fi
}

echo "-- dry run, no widget"
t_reset
t_resp GET "$LIST" 200 '{"success":true,"result":[{"name":"other","sitekey":"0xOTHER"}]}'
t_run "$S"
t_rc 0 "dry run"
t_expect_writes 0 "dry run makes no write call"
no_doppler "dry run"
t_expect_out "WOULD POST $W" "dry run prints the POST"
t_expect_out '"mode":"managed"' "managed mode"
t_expect_out 'staging.renegadepenguinllc.com' "staging domain bound"
t_token_never_leaks

echo "-- apply, creates widget (doppler echoes on stdout)"
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
if grep -qF "$SETARGV" "$T/doppler-argv.log"; then t_ok "doppler argv has name, project and config only"; else
  t_fail "unexpected doppler argv: $(cat "$T/doppler-argv.log")"
fi
# The preflight must come before the create.
if [ "$(head -n1 "$T/doppler-argv.log")" = "$PREFLIGHT --json" ]; then t_ok "preflight read ran first"; else
  t_fail "no preflight read first: $(cat "$T/doppler-argv.log")"
fi

echo "-- apply, doppler writes the value to stderr"
t_reset
export FAKE_DOPPLER_MODE=stderr
t_resp GET "$LIST" 200 '{"success":true,"result":[]}'
t_resp POST "$W" 200 "$CREATED"
t_run "$S" --apply
t_rc 0 "apply (stderr echo)"
t_token_never_leaks

echo "-- apply, doppler set fails and echoes the value on stderr"
t_reset
export FAKE_DOPPLER_MODE=fail
t_resp GET "$LIST" 200 '{"success":true,"result":[]}'
t_resp POST "$W" 200 "$CREATED"
t_run "$S" --apply
t_rc 1 "storage failure exits non-zero"
t_expect_out "widget renegade-penguin-contact WAS CREATED but its secret was NOT saved to Doppler" "fixed partial-apply message"
t_expect_out "sitekey: 0xSITEKEY" "message carries the sitekey"
t_expect_out "Recovery: delete the widget (DELETE /accounts/acct123/challenges/widgets/0xSITEKEY) or rotate its secret" "message carries the recovery step"
t_token_never_leaks

echo "-- apply, create response has no secret"
t_reset
t_resp GET "$LIST" 200 '{"success":true,"result":[]}'
t_resp POST "$W" 200 "$NOSECRET"
t_run "$S" --apply
t_rc 1 "missing secret exits non-zero"
t_expect_out "WAS CREATED but its secret was NOT saved" "partial-apply message for missing secret"
if grep -q 'secrets set' "$T/doppler-argv.log"; then t_fail "doppler set called without a secret"; else t_ok "doppler set not called without a secret"; fi

echo "-- preflight fails: nothing is created"
t_reset
export FAKE_DOPPLER_PREFLIGHT=fail
t_resp GET "$LIST" 200 '{"success":true,"result":[]}'
t_resp POST "$W" 200 "$CREATED"
t_run "$S" --apply
t_rc 1 "preflight failure exits non-zero"
t_expect_writes 0 "no widget created when the destination is unusable"
t_expect_out "cannot read Doppler config no-php-no-cry/dev_renegadepenguin; nothing was created" "fixed preflight message"
t_token_never_leaks

echo "-- HTTP 200 with success false on create"
t_reset
t_resp GET "$LIST" 200 '{"success":true,"result":[]}'
t_resp POST "$W" 200 '{"success":false,"errors":[{"code":1,"message":"nope"}],"result":null}'
t_run "$S" --apply
t_rc 1 "success false is a failure"
if grep -q 'secrets set' "$T/doppler-argv.log"; then t_fail "doppler set called after failed create"; else t_ok "doppler set not called after failed create"; fi

echo "-- malformed list response"
t_reset
t_resp GET "$LIST" 200 'not json'
t_run "$S" --apply
t_rc 1 "malformed JSON is a failure"
t_expect_writes 0 "no write after malformed read"

echo "-- apply, widget exists"
t_reset
t_resp GET "$LIST" 200 '{"success":true,"result":[{"name":"renegade-penguin-contact","sitekey":"0xEXIST"}]}'
t_run "$S" --apply
t_rc 0 "apply when it exists"
t_expect_writes 0 "already-exists makes no duplicate"
t_expect_out "sitekey: 0xEXIST" "existing sitekey printed"
no_doppler "existing widget"
t_token_never_leaks
t_finish
