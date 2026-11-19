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
OURS_FULL='{"id":"r9","ref":"renegade-penguin-contact-ratelimit","description":"Contact form: 5 POST per 10 s per data center per IP","expression":"(http.request.uri.path eq \"/api/contact\" and http.request.method eq \"POST\")","action":"block","ratelimit":{"characteristics":["cf.colo.id","ip.src"],"period":10,"requests_per_period":5,"mitigation_timeout":10,"counting_expression":""},"last_updated":"x"}'
OURS_DIFF='{"id":"r9","ref":"renegade-penguin-contact-ratelimit","expression":"true","action":"log","ratelimit":{"characteristics":["cf.colo.id","ip.src"],"period":10,"requests_per_period":1000,"mitigation_timeout":10}}'
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
t_expect_out "WOULD POST /zones/<zone>/rulesets" "dry run prints the create"
t_expect_out '"requests_per_period":5' "5 requests"
t_expect_out '"period":10,' "10 second period"
t_expect_out '"mitigation_timeout":10}' "block 10 seconds"
t_token_never_leaks

echo "-- dry run, existing ruleset"
t_reset
t_resp GET "$E" 200 "$HAVE_OTHER"
t_run "$S"
t_rc 0 "dry run with ruleset"
t_expect_writes 0 "dry run makes no write call"
t_expect_out "WOULD POST ${RULES/zone123/<zone>}" "dry run prints the add-rule call"

echo "-- apply, no entrypoint: create ruleset with only our rule"
t_reset
t_resp GET "$E" 404 "$NF"
t_run "$S" --apply
t_rc 0 "apply"
t_expect_writes 1 "one create"
t_expect_call 'POST /zones/zone123/rulesets {"name":"zone ratelimit entrypoint","kind":"zone","phase":"http_ratelimit","rules":[{' "ruleset created with a rules list"
t_expect_call 'http.request.uri.path eq \"/api/contact\" and http.request.method eq \"POST\"' "path and POST only"
t_expect_call '"characteristics":["cf.colo.id","ip.src"]' "per data center and IP"
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

echo "-- the fake API rejects characteristics without cf.colo.id (guard bites)"
t_reset
t_resp GET "$E" 404 "$NF"
t_run "$S" --apply
t_rc 0 "script's own rule is accepted by the strict fake"
OLDBODY='{"name":"n","kind":"zone","phase":"http_ratelimit","rules":[{"ratelimit":{"characteristics":["ip.src"]}}]}'
set +e
code=$(printf 'header = "Authorization: Bearer x"\n' | PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_REAL_JQ="$FAKE_REAL_JQ" FAKE_REAL_DIRNAME="$FAKE_REAL_DIRNAME" TMPDIR="$T/tmp" \
  bash "$T/bin/curl" -sS -K - -X POST --data-binary @<(printf '%s' "$OLDBODY") -w '%{http_code}' -o /dev/null https://api.cloudflare.com/client/v4/zones/zone123/rulesets)
set -e
if [ "$code" = 400 ]; then t_ok "old ip.src-only body gets HTTP 400"; else t_fail "fake accepted a body without cf.colo.id (got $code)"; fi

echo "-- the fake API rejects periods and timeouts other than 10 (guard bites)"
t_reset
t_resp GET "$E" 404 "$NF"
t_run "$S" --apply
t_rc 0 "script's own 10 s rule is accepted by the Free-plan fake"
post_code() { # json body -> http code
  printf 'header = "Authorization: Bearer x"\n' | PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_REAL_JQ="$FAKE_REAL_JQ" FAKE_REAL_DIRNAME="$FAKE_REAL_DIRNAME" TMPDIR="$T/tmp" \
    bash "$T/bin/curl" -sS -K - -X POST --data-binary @<(printf '%s' "$1") -w '%{http_code}' -o /dev/null https://api.cloudflare.com/client/v4/zones/zone123/rulesets
}
set +e
code=$(post_code '{"rules":[{"ratelimit":{"characteristics":["cf.colo.id","ip.src"],"period":600,"requests_per_period":5,"mitigation_timeout":10}}]}')
code2=$(post_code '{"rules":[{"ratelimit":{"characteristics":["cf.colo.id","ip.src"],"period":10,"requests_per_period":5,"mitigation_timeout":600}}]}')
set -e
if [ "$code" = 400 ]; then t_ok "period 600 gets HTTP 400"; else t_fail "fake accepted period 600 (got $code)"; fi
if [ "$code2" = 400 ]; then t_ok "mitigation_timeout 600 gets HTTP 400"; else t_fail "fake accepted timeout 600 (got $code2)"; fi

echo "-- identifiers are masked in all output"
ACCT=0123456789abcdef0123456789abcdef
ZONE=fedcba9876543210fedcba9876543210
EM=/zones/$ZONE/rulesets/phases/http_ratelimit/entrypoint
no_ids() { # label
  if printf '%s' "$OUT" | grep -qE '[0-9a-f]{32}'; then
    t_fail "$1: a 32-hex identifier is in the output: $OUT"
  else t_ok "$1: no 32-hex identifier in the output"; fi
}
t_reset
t_set_account "$ACCT"
t_set_zone "$ZONE"
t_resp GET "$EM" 200 "$HAVE_OTHER"
t_run "$S"
t_rc 0 "masked dry run"
t_expect_out "READ  GET /zones/<zone>/rulesets/phases/http_ratelimit/entrypoint" "read path masked"
t_expect_out "WOULD POST /zones/<zone>/rulesets/rs1/rules" "would path masked"
no_ids "dry run"
t_reset
t_set_account "$ACCT"
t_set_zone "$ZONE"
t_resp GET "$EM" 200 "$HAVE_OTHER"
t_run "$S" --apply
t_expect_out "WRITE POST /zones/<zone>/rulesets/rs1/rules" "write path masked"
no_ids "apply"
t_expect_call "POST /zones/$ZONE/rulesets/rs1/rules" "the real zone id is still used for the call"
t_reset
t_set_account "$ACCT"
t_set_zone "$ZONE"
t_resp GET "$EM" 200 "$HAVE_OTHER"
t_resp POST "/zones/$ZONE/rulesets/rs1/rules" 400 '{"success":false,"errors":[{"code":20155,"message":"x"}]}'
t_run "$S" --apply
t_rc 1 "masked error run"
t_expect_out "error: POST /zones/<zone>/rulesets/rs1/rules returned HTTP 400" "error path masked"
no_ids "error"
t_reset
t_set_account "$ACCT"
t_set_zone "$ZONE"
t_resp GET "$EM" 403 '{"success":false,"errors":[{"code":10000,"message":"auth"}]}'
t_run "$S"
no_ids "failed read"

t_finish
