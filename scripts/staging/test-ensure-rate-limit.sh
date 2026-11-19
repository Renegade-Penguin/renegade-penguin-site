#!/usr/bin/env bash
# Mocked test for ensure-rate-limit.sh. No network.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test-lib.sh
. "$here/test-lib.sh"
t_setup

S=ensure-rate-limit.sh
E=/zones/zone123/rulesets/phases/http_ratelimit/entrypoint
RULES=/zones/zone123/rulesets/rs1/rules
OTHER='{"id":"abc","ref":"someone-elses","expression":"true","action":"block","description":"keep me"}'
OURS_FULL='{"id":"r9","ref":"renegade-penguin-contact-ratelimit","description":"Contact form: 5 POST per 10 min per IP","expression":"(http.request.uri.path eq \"/api/contact\" and http.request.method eq \"POST\")","action":"block","ratelimit":{"characteristics":["ip.src"],"period":600,"requests_per_period":5,"mitigation_timeout":600,"counting_expression":""},"last_updated":"x"}'
OURS_DIFF='{"id":"r9","ref":"renegade-penguin-contact-ratelimit","expression":"true","action":"log","ratelimit":{"characteristics":["ip.src"],"period":10,"requests_per_period":1000,"mitigation_timeout":10}}'
HAVE_OTHER='{"success":true,"result":{"id":"rs1","rules":['"$OTHER"']}}'
HAVE_OURS='{"success":true,"result":{"id":"rs1","rules":['"$OTHER"','"$OURS_FULL"']}}'
HAVE_DIFF='{"success":true,"result":{"id":"rs1","rules":['"$OURS_DIFF"']}}'
NF='{"success":false,"errors":[{"code":10003,"message":"not found"}],"result":null}'

no_put() { # label
  if grep -q '^PUT ' "$T/calls.log"; then t_fail "$1: a PUT was sent"; else t_ok "$1: no PUT sent"; fi
}

echo "-- dry run, no entrypoint"
t_reset
t_resp GET "$E" 404 "$NF"
t_run "$S"
t_rc 0 "dry run"
t_expect_writes 0 "dry run makes no write call"
t_expect_out "WOULD POST /zones/zone123/rulesets" "dry run prints the create"
t_expect_out '"requests_per_period":5' "5 requests"
t_expect_out '"period":600' "per 10 minutes"
t_expect_out '"mitigation_timeout":600' "block 10 minutes"
t_token_never_leaks

echo "-- dry run, existing ruleset"
t_reset
t_resp GET "$E" 200 "$HAVE_OTHER"
t_run "$S"
t_rc 0 "dry run with ruleset"
t_expect_writes 0 "dry run makes no write call"
t_expect_out "WOULD POST $RULES" "dry run prints the add-rule call"

echo "-- apply, no entrypoint: create ruleset with only our rule"
t_reset
t_resp GET "$E" 404 "$NF"
t_run "$S" --apply
t_rc 0 "apply"
t_expect_writes 1 "one create"
t_expect_call 'POST /zones/zone123/rulesets {"name":"zone ratelimit entrypoint","kind":"zone","phase":"http_ratelimit","rules":[{' "ruleset created with a rules list"
t_expect_call 'http.request.uri.path eq \"/api/contact\" and http.request.method eq \"POST\"' "path and POST only"
t_expect_call '"characteristics":["ip.src"]' "per IP"
t_expect_call '"action":"block"' "block action"
no_put "create"
t_token_never_leaks

echo "-- apply, ruleset exists: add one rule, never replace"
t_reset
t_resp GET "$E" 200 "$HAVE_OTHER"
t_run "$S" --apply
t_rc 0 "apply with existing rules"
t_expect_writes 1 "one write"
t_expect_call "POST $RULES {" "POST to the ruleset rules endpoint"
t_expect_call '"ref":"renegade-penguin-contact-ratelimit"' "our rule sent"
t_expect_no_call '"ref":"someone-elses"' "body carries only our rule, not the existing ones"
no_put "add"
t_token_never_leaks

echo "-- apply, identical rule already there (extra server fields ignored)"
t_reset
t_resp GET "$E" 200 "$HAVE_OURS"
t_run "$S" --apply
t_rc 0 "apply when present"
t_expect_writes 0 "already-exists makes no duplicate"
t_token_never_leaks

echo "-- apply, same ref but different content: refuse"
t_reset
t_resp GET "$E" 200 "$HAVE_DIFF"
t_run "$S" --apply
t_rc 1 "differing rule is not overwritten"
t_expect_writes 0 "no write"

echo "-- unexpected GET status fails closed"
t_reset
t_resp GET "$E" 403 '{"success":false,"errors":[{"code":10000,"message":"auth"}]}'
t_run "$S" --apply
t_rc 1 "403 fails"
t_expect_writes 0 "no write after failed read"

echo "-- HTTP 200 with success false on add-rule"
t_reset
t_resp GET "$E" 200 "$HAVE_OTHER"
t_resp POST "$RULES" 200 '{"success":false,"errors":[{"code":1,"message":"nope"}],"result":null}'
t_run "$S" --apply
t_rc 1 "success false is a failure"
t_finish
