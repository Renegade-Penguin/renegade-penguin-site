#!/usr/bin/env bash
xtrace_was_on=0
case $- in *x*) xtrace_was_on=1 ;; esac
set +x
if [ "$xtrace_was_on" = 1 ]; then
  echo "error: xtrace is enabled; refusing to run so credentials cannot be traced" >&2
  exit 1
fi
# Privatize the token before ANY external command or command substitution:
# a non-exported variable, and the exported one is unset.
unset CF_TOKEN_PRIVATE
# Read by the sourced lib.sh (a cross-file use); it must not be exported.
# shellcheck disable=SC2034
CF_TOKEN_PRIVATE=${CLOUDFLARE_API_TOKEN:-}
unset CLOUDFLARE_API_TOKEN
# Ensure one zone rate-limit rule for POST /api/contact (phase http_ratelimit):
# 5 requests per 10 minutes per IP per data center, block for 10 minutes.
# The plan requires cf.colo.id among the characteristics (API code 20155), so
# counting is per data center per IP.
# The ruleset is never replaced. The phase entrypoint is read first; when it
# exists, only this one rule is ADDED (POST to the ruleset's rules endpoint),
# so rules other people add are never overwritten. The ruleset is created, with
# just this one rule, only when no entrypoint exists yet.
# Required env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ZONE_ID.
# Dry run by default; --apply performs the write.
set -euo pipefail

case ${BASH_SOURCE[0]} in */*) here=${BASH_SOURCE[0]%/*} ;; *) here=. ;; esac
# shellcheck source=lib.sh
. "$here/lib.sh"

RULE_REF="renegade-penguin-contact-ratelimit"

cf_init "ensure-rate-limit" "$@" -- CLOUDFLARE_ZONE_ID

rule=$(jq -cn --arg ref "$RULE_REF" '{
  ref: $ref,
  description: "Contact form: 5 POST per 10 min per data center per IP",
  expression: "(http.request.uri.path eq \"/api/contact\" and http.request.method eq \"POST\")",
  action: "block",
  ratelimit: {
    characteristics: ["cf.colo.id", "ip.src"],
    period: 600,
    requests_per_period: 5,
    mitigation_timeout: 600
  }
}')

path="/zones/$CLOUDFLARE_ZONE_ID/rulesets/phases/http_ratelimit/entrypoint"
cf_read "$path"

case "$CF_STATUS" in
  200)
    ruleset_id=$(printf '%s' "$CF_BODY" | jq -r '.result.id // empty')
    if [ -z "$ruleset_id" ]; then
      cf_die "entrypoint response had no ruleset id"
    fi
    # Compare only the fields we set; the server adds others.
    state=$(printf '%s' "$CF_BODY" | jq -r --argjson want "$rule" '
      def pick: {expression, action, ratelimit: (.ratelimit | {characteristics, period, requests_per_period, mitigation_timeout})};
      [.result.rules[]? | select(.ref == $want.ref)] as $have
      | if ($have | length) == 0 then "absent"
        elif ($have[0] | pick) == ($want | pick) then "identical"
        else "different" end')
    case "$state" in
      identical)
        printf 'ok: rule %s already present; nothing to do\n' "$RULE_REF"
        exit 0
        ;;
      different)
        cf_die "a rule with ref $RULE_REF exists but differs; not overwriting it, fix it by hand"
        ;;
    esac
    cf_write POST "/zones/$CLOUDFLARE_ZONE_ID/rulesets/$ruleset_id/rules" "$rule"
    ;;
  404)
    printf 'no entrypoint ruleset yet; creating it with only our rule\n'
    body=$(jq -cn --argjson r "$rule" \
      '{name: "zone ratelimit entrypoint", kind: "zone", phase: "http_ratelimit", rules: [$r]}')
    cf_write POST "/zones/$CLOUDFLARE_ZONE_ID/rulesets" "$body"
    ;;
  *)
    cf_die "GET entrypoint returned HTTP $CF_STATUS $(cf_errors)"
    ;;
esac
if [ "$APPLY" = 1 ]; then
  printf 'ok: rule %s added\n' "$RULE_REF"
fi
