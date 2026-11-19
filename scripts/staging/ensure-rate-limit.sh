#!/usr/bin/env bash
# Ensure one zone rate-limit rule for POST /api/contact (phase http_ratelimit):
# 5 requests per 10 minutes per IP, block for 10 minutes.
# The phase entrypoint is read first; PUT replaces the whole ruleset, so the
# PUT body is the existing rules plus ours, never ours alone.
# Required env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ZONE_ID.
# Dry run by default; --apply performs the PUT.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

RULE_REF="renegade-penguin-contact-ratelimit"

cf_init "ensure-rate-limit" "$@" -- CLOUDFLARE_ZONE_ID

path="/zones/$CLOUDFLARE_ZONE_ID/rulesets/phases/http_ratelimit/entrypoint"
cf_read "$path"

existing='[]'
case "$CF_STATUS" in
  200)
    if [ "$(printf '%s' "$CF_BODY" | jq --arg r "$RULE_REF" '[.result.rules[]? | select(.ref == $r)] | length')" -gt 0 ]; then
      printf 'ok: rule %s already present; nothing to do\n' "$RULE_REF"
      exit 0
    fi
    existing=$(printf '%s' "$CF_BODY" | jq -c '.result.rules // []')
    ;;
  404)
    printf 'no entrypoint ruleset yet; it will be created with only our rule\n'
    ;;
  *)
    cf_die "GET entrypoint returned HTTP $CF_STATUS $(cf_errors)"
    ;;
esac

body=$(jq -cn --argjson ex "$existing" --arg ref "$RULE_REF" '
  {rules: ($ex + [{
    ref: $ref,
    description: "Contact form: 5 POST per 10 min per IP",
    expression: "(http.request.uri.path eq \"/api/contact\" and http.request.method eq \"POST\")",
    action: "block",
    ratelimit: {
      characteristics: ["ip.src"],
      period: 600,
      requests_per_period: 5,
      mitigation_timeout: 600
    }
  }])}')
cf_write PUT "$path" "$body"
if [ "$APPLY" = 1 ]; then
  printf 'ok: rule %s added (%s existing rule(s) kept)\n' "$RULE_REF" "$(printf '%s' "$existing" | jq length)"
fi
