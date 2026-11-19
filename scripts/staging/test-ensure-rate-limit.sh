#!/usr/bin/env bash
# Mocked test for ensure-rate-limit.sh. No network.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test-lib.sh
. "$here/test-lib.sh"
t_setup

S=ensure-rate-limit.sh
E=/zones/zone123/rulesets/phases/http_ratelimit/entrypoint
OTHER='{"id":"abc","ref":"someone-elses","expression":"true","action":"block","description":"keep me"}'
HAVE_OTHER='{"success":true,"result":{"id":"rs1","rules":['"$OTHER"']}}'
HAVE_OURS='{"success":true,"result":{"id":"rs1","rules":['"$OTHER"',{"ref":"renegade-penguin-contact-ratelimit"}]}}'
NF='{"success":false,"errors":[{"code":10003,"message":"not found"}],"result":null}'

echo "-- dry run, no entrypoint"
t_reset
t_resp GET "$E" 404 "$NF"
t_run "$S"
t_rc 0 "dry run"
t_expect_writes 0 "dry run makes no write call"
t_expect_out "WOULD PUT $E" "dry run prints the PUT"
t_expect_out '"requests_per_period":5' "5 requests"
t_expect_out '"period":600' "per 10 minutes"
t_expect_out '"mitigation_timeout":600' "block 10 minutes"
t_token_never_leaks

echo "-- apply, no entrypoint"
t_reset
t_resp GET "$E" 404 "$NF"
t_run "$S" --apply
t_rc 0 "apply"
t_expect_writes 1 "one PUT"
t_expect_call 'http.request.uri.path eq \"/api/contact\" and http.request.method eq \"POST\"' "path and POST only"
t_expect_call '"characteristics":["ip.src"]' "per IP"
t_expect_call '"action":"block"' "block action"
t_token_never_leaks

echo "-- apply, existing rules preserved"
t_reset
t_resp GET "$E" 200 "$HAVE_OTHER"
t_run "$S" --apply
t_rc 0 "apply with existing rules"
t_expect_writes 1 "one PUT"
t_expect_call '"ref":"someone-elses"' "existing rule kept in PUT body"
t_expect_call '"description":"keep me"' "existing rule content kept"
t_expect_call '"ref":"renegade-penguin-contact-ratelimit"' "our rule added"
t_token_never_leaks

echo "-- apply, our rule already there"
t_reset
t_resp GET "$E" 200 "$HAVE_OURS"
t_run "$S" --apply
t_rc 0 "apply when present"
t_expect_writes 0 "already-exists makes no duplicate"
t_token_never_leaks

echo "-- unexpected GET status fails closed"
t_reset
t_resp GET "$E" 403 '{"success":false,"errors":[{"code":10000,"message":"auth"}]}'
t_run "$S" --apply
t_rc 1 "403 fails"
t_expect_writes 0 "no write after failed read"
t_finish
