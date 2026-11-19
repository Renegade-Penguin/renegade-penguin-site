#!/usr/bin/env bash
# Mocked test for attach-staging-domain.sh. No network.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test-lib.sh
. "$here/test-lib.sh"
t_setup

S=attach-staging-domain.sh
D=/accounts/acct123/pages/projects/renegade-penguin-site/domains
H=staging.renegadepenguinllc.com
DNS="/zones/zone123/dns_records?type=CNAME&name=$H"
NF='{"success":false,"errors":[{"code":8000007,"message":"not found"}],"result":null}'

echo "-- dry run, nothing exists"
t_reset
t_resp GET "$D/$H" 404 "$NF"
t_resp GET "$DNS" 200 '{"success":true,"result":[]}'
t_run "$S"
t_rc 0 "dry run"
t_expect_writes 0 "dry run makes no write call"
t_expect_out "WOULD POST $D" "dry run prints domain attach"
t_expect_out "WOULD POST /zones/zone123/dns_records" "dry run prints CNAME create"
t_expect_out "WOULD PATCH $D/$H" "dry run prints PATCH"
t_token_never_leaks

echo "-- apply, nothing exists, becomes active"
t_reset
t_resp GET "$D/$H" 404 "$NF"
t_resp GET "$DNS" 200 '{"success":true,"result":[]}'
t_run "$S" --apply
# The fake GET for the domain keeps returning 404; make the final read active.
t_rc 1 "apply fails if the domain never reads back active/exists"

t_reset
printf '' >"$T/calls.log"
# Sequence: GET domain 404 first, then after POST the same path reads active.
# The fake is stateless, so use the already-attached case for the active path.
t_resp GET "$D/$H" 200 '{"success":true,"result":{"name":"'"$H"'","status":"active"}}'
t_resp GET "$DNS" 200 '{"success":true,"result":[]}'
t_run "$S" --apply
t_rc 0 "apply, attached, CNAME missing, active"
t_expect_call "POST /zones/zone123/dns_records" "CNAME created"
t_expect_call '"type":"CNAME","name":"staging","content":"renegade-penguin-site.pages.dev","proxied":true' "CNAME is proxied to pages.dev"
t_expect_call "PATCH $D/$H" "validation retried with PATCH"
t_expect_writes 2 "only CNAME and PATCH written (domain already attached)"
t_token_never_leaks

echo "-- apply, attach needed"
t_reset
t_resp GET "$D/$H" 404 "$NF"
t_resp GET "$DNS" 200 '{"success":true,"result":[{"name":"'"$H"'"}]}'
t_run "$S" --apply
t_expect_call "POST $D" "domain attached via POST"
t_expect_call '{"name":"staging.renegadepenguinllc.com"}' "attach body names the staging host"
t_expect_writes 2 "attach and PATCH; existing CNAME not duplicated"

echo "-- pending domain exits 2"
t_reset
t_resp GET "$D/$H" 200 '{"success":true,"result":{"status":"pending"}}'
t_resp GET "$DNS" 200 '{"success":true,"result":[{"name":"'"$H"'"}]}'
t_run "$S" --apply
t_rc 2 "pending is not done"
t_expect_out "pending" "says pending"
t_expect_writes 1 "only the validation PATCH"

echo "-- never touches the production hostname"
t_reset
t_resp GET "$D/$H" 200 '{"success":true,"result":{"status":"active"}}'
t_resp GET "$DNS" 200 '{"success":true,"result":[{"name":"'"$H"'"}]}'
t_run "$S" --apply
t_token_never_leaks
if grep -E 'domains/renegadepenguinllc\.com|"name":"(renegadepenguinllc\.com|@)"' "$T/calls.log" >/dev/null; then
  t_fail "a call targeted the production hostname"
else
  t_ok "no call targets the production hostname"
fi
t_finish
