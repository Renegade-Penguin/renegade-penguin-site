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

echo "-- HTTP 500 with success true: nothing may reach doppler"
t_reset
t_resp GET "$LIST" 200 '{"success":true,"result":[]}'
t_resp POST "$W" 500 "$CREATED"
t_run "$S" --apply
t_rc 1 "HTTP 500 is a failure even with success true"
if grep -q 'secrets set' "$T/doppler-argv.log"; then t_fail "doppler set invoked after HTTP 500"; else t_ok "doppler set never invoked after HTTP 500"; fi
if [ -e "$T/doppler-stdin.log" ]; then t_fail "doppler received bytes after HTTP 500"; else t_ok "doppler received no bytes after HTTP 500"; fi
t_token_never_leaks

echo "-- concatenated JSON documents on create: nothing may reach doppler"
for combo in "false-true" "true-false" "true-true"; do
  t_reset
  t_resp GET "$LIST" 200 '{"success":true,"result":[]}'
  case "$combo" in
    false-true) body='{"success":false,"errors":[]}'"$CREATED" ;;
    true-false) body="$CREATED"'{"success":false,"errors":[]}' ;;
    *) body="$CREATED$CREATED" ;;
  esac
  t_resp POST "$W" 200 "$body"
  t_run "$S" --apply
  t_rc 1 "concatenated documents ($combo) are rejected"
  if grep -q 'secrets set' "$T/doppler-argv.log"; then t_fail "doppler set invoked ($combo)"; else t_ok "doppler set never invoked ($combo)"; fi
  t_token_never_leaks
done

echo "-- create body holding a NUL byte: rejected before any delivery"
t_reset
t_resp GET "$LIST" 200 '{"success":true,"result":[]}'
printf '{"success":true,"result":{"sitekey":"0xSITEKEY","secret":"%s","x":"a\0b"}}' "$TEST_SECRET" >"$T/nul.body"
t_resp_file POST "$W" 200 "$T/nul.body"
t_run "$S" --apply
t_rc 1 "NUL-bearing create response is rejected"
if grep -q 'secrets set' "$T/doppler-argv.log"; then t_fail "doppler set invoked after a NUL body"; else t_ok "doppler set never invoked after a NUL body"; fi
t_token_never_leaks

echo "-- create body with invalid UTF-8 inside a JSON string"
t_reset
t_resp GET "$LIST" 200 '{"success":true,"result":[]}'
printf '{"success":true,"result":{"sitekey":"0xSITEKEY","secret":"%s","x":"a\xffb"}}' "$TEST_SECRET" >"$T/utf8.body"
t_resp_file POST "$W" 200 "$T/utf8.body"
t_run "$S" --apply
# jq replaces the bad byte with U+FFFD and accepts the document; documented.
t_rc 0 "invalid UTF-8 in an unrelated string is accepted (documented)"
if [ "$(cat "$T/doppler-stdin.log")" = "$TEST_SECRET" ]; then t_ok "secret still delivered intact"; else t_fail "secret altered"; fi
t_token_never_leaks

echo "-- exported RESP_PRIVATE / CF_TOKEN_PRIVATE must not reach children"
t_reset
t_env RESP_PRIVATE=placeholder CF_TOKEN_PRIVATE=placeholder
t_resp GET "$LIST" 200 '{"success":true,"result":[]}'
t_resp POST "$W" 200 "$CREATED"
t_run "$S" --apply
t_rc 0 "apply with pre-exported private variables"
t_token_never_leaks

echo "-- malformed list response"
t_reset
t_resp GET "$LIST" 200 'not json'
t_run "$S" --apply
t_rc 1 "malformed JSON is a failure"
t_expect_writes 0 "no write after malformed read"

t_bad_widget() { # label JSON-WIDGET-LIST
  t_reset
  t_resp GET "$LIST" 200 '{"success":true,"result":'"$2"'}'
  t_resp POST "$W" 200 "$CREATED"
  t_run "$S" --apply
  t_rc 1 "$1 fails closed"
  t_expect_out "The secret of an existing widget cannot be recovered" "$1 says the secret cannot be recovered"
  t_expect_out "Delete the widget (DELETE /accounts/acct123/challenges/widgets/0xEXIST), then re-run" "$1 gives the recovery step"
  t_expect_out "sitekey: 0xEXIST" "$1 may print the sitekey"
  t_expect_writes 0 "$1 makes no write"
  no_doppler "$1"
  t_token_never_leaks
}

echo "-- existing widget with the wrong domains or mode fails closed"
t_bad_widget "missing apex domain" '[{"name":"renegade-penguin-contact","sitekey":"0xEXIST","mode":"managed","domains":["staging.renegadepenguinllc.com"]}]'
t_bad_widget "missing staging domain" '[{"name":"renegade-penguin-contact","sitekey":"0xEXIST","mode":"managed","domains":["renegadepenguinllc.com"]}]'
t_bad_widget "no domains" '[{"name":"renegade-penguin-contact","sitekey":"0xEXIST","mode":"managed"}]'
t_bad_widget "wrong mode" '[{"name":"renegade-penguin-contact","sitekey":"0xEXIST","mode":"invisible","domains":["staging.renegadepenguinllc.com","renegadepenguinllc.com"]}]'

echo "-- two widgets with the same name fail closed"
t_reset
t_resp GET "$LIST" 200 '{"success":true,"result":[{"name":"renegade-penguin-contact","sitekey":"0xA","mode":"managed","domains":["staging.renegadepenguinllc.com","renegadepenguinllc.com"]},{"name":"renegade-penguin-contact","sitekey":"0xB","mode":"managed","domains":["staging.renegadepenguinllc.com","renegadepenguinllc.com"]}]}'
t_run "$S" --apply
t_rc 1 "duplicate widget names fail"
t_expect_writes 0 "no write for duplicate names"

echo "-- apply, widget exists"
t_reset
t_resp GET "$LIST" 200 '{"success":true,"result":[{"name":"renegade-penguin-contact","sitekey":"0xEXIST","mode":"managed","domains":["staging.renegadepenguinllc.com","renegadepenguinllc.com"]}]}'
t_run "$S" --apply
t_rc 0 "apply when it exists and matches"
t_expect_writes 0 "already-exists makes no duplicate"
t_expect_out "sitekey: 0xEXIST" "existing sitekey printed"
no_doppler "existing widget"
t_token_never_leaks
t_finish
