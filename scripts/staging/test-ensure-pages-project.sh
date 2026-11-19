#!/usr/bin/env bash
# Mocked test for ensure-pages-project.sh. No network.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test-lib.sh
. "$here/test-lib.sh"
t_setup

S=ensure-pages-project.sh
P=/accounts/acct123/pages/projects/renegade-penguin-site
MISSING='{"success":false,"errors":[{"code":8000007,"message":"Project not found."}],"result":null}'

echo "-- dry run, project missing"
t_reset
t_resp GET "$P" 404 "$MISSING"
t_run "$S"
t_rc 0 "dry run"
t_expect_writes 0 "dry run makes no write call"
t_expect_out "WOULD POST /accounts/acct123/pages/projects" "dry run prints the POST"
t_expect_out '"production_branch":"main"' "dry run prints the body"
t_token_never_leaks

echo "-- apply, project missing"
t_reset
t_resp GET "$P" 404 "$MISSING"
t_run "$S" --apply
t_rc 0 "apply"
t_expect_writes 1 "apply makes one write"
t_expect_call 'POST /accounts/acct123/pages/projects {"name":"renegade-penguin-site","production_branch":"main"}' "apply POSTs name and production_branch"
t_token_never_leaks

echo "-- apply, project exists"
t_reset
t_resp GET "$P" 200 '{"success":true,"result":{"name":"renegade-penguin-site"}}'
t_run "$S" --apply
t_rc 0 "apply when it exists"
t_expect_writes 0 "already-exists makes no duplicate"
t_token_never_leaks

echo "-- 404 with another code is not treated as missing"
t_reset
t_resp GET "$P" 404 '{"success":false,"errors":[{"code":7003,"message":"No route"}]}'
t_run "$S" --apply
t_rc 1 "unexpected 404 fails"
t_expect_writes 0 "unexpected 404 makes no write"

echo "-- HTTP 200 with success false on the read is a failure"
t_reset
t_resp GET "$P" 200 '{"success":false,"errors":[{"code":1,"message":"x"}],"result":null}'
t_run "$S" --apply
t_rc 1 "read with success false fails"
t_expect_writes 0 "no write after bad read"

echo "-- concatenated JSON documents on the read are failures"
for combo in "false-true" "true-false" "true-true"; do
  t_reset
  case "$combo" in
    false-true) body='{"success":false}{"success":true,"result":{}}' ;;
    true-false) body='{"success":true,"result":{}}{"success":false}' ;;
    *) body='{"success":true,"result":{}}{"success":true,"result":{}}' ;;
  esac
  t_resp GET "$P" 200 "$body"
  t_run "$S" --apply
  t_rc 1 "concatenated documents ($combo) fail"
  t_expect_writes 0 "no write after concatenated documents ($combo)"
done

echo "-- a non-object top-level value is a failure"
t_reset
t_resp GET "$P" 200 '[{"success":true}]'
t_run "$S" --apply
t_rc 1 "array envelope fails"

echo "-- malformed JSON on the read is a failure"
t_reset
t_resp GET "$P" 200 'not json'
t_run "$S" --apply
t_rc 1 "malformed JSON fails"
t_expect_writes 0 "no write after malformed read"

echo "-- HTTP 200 with success false on the write is a failure"
t_reset
t_resp GET "$P" 404 "$MISSING"
t_resp POST /accounts/acct123/pages/projects 200 '{"success":false,"errors":[{"code":1,"message":"nope"}],"result":null}'
t_run "$S" --apply
t_rc 1 "write with success false fails"
t_expect_out "error:" "reports an error"

echo "-- missing env"
t_reset
set +e
OUT=$(env -u CLOUDFLARE_ACCOUNT_ID PATH="$T/bin:$PATH" FAKE_DIR="$T" CLOUDFLARE_API_TOKEN="$TEST_TOKEN" \
  bash "$STAGING_DIR/$S" 2>&1)
RC=$?
set -e
t_rc 1 "missing account id fails"
t_finish
