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
# Attach staging.renegadepenguinllc.com to the Pages project.
# Steps: attach the domain, create the proxied CNAME (the API does NOT create
# it and the domain stays pending without it), PATCH to retry validation, then
# require status active. Only the staging hostname is ever touched.
# Required env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ZONE_ID.
# Dry run by default; --apply performs the writes.
set -euo pipefail

case ${BASH_SOURCE[0]} in */*) here=${BASH_SOURCE[0]%/*} ;; *) here=. ;; esac
# shellcheck source=lib.sh
. "$here/lib.sh"

cf_init "attach-staging-domain" "$@" -- CLOUDFLARE_ZONE_ID

dom_path="/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$CF_PROJECT/domains"
dom_item="$dom_path/$CF_STAGING_HOST"

# 1. Attach the hostname to the project.
cf_read "$dom_item"
case "$CF_STATUS" in
  200) printf 'domain %s already attached\n' "$CF_STAGING_HOST" ;;
  404)
    cf_write POST "$dom_path" "$(jq -cn --arg n "$CF_STAGING_HOST" '{name: $n}')"
    ;;
  *) cf_die "GET domain returned HTTP $CF_STATUS $(cf_errors)" ;;
esac

# 2. Proxied CNAME staging -> <project>.pages.dev (not created by step 1).
dns_path="/zones/$CLOUDFLARE_ZONE_ID/dns_records"
cf_read "$dns_path?type=CNAME&name=$CF_STAGING_HOST"
if [ "$CF_STATUS" != 200 ]; then
  cf_die "GET dns_records returned HTTP $CF_STATUS $(cf_errors)"
fi
found=$(printf '%s' "$CF_BODY" | jq -r '.result | length')
if [ "$found" -gt 0 ]; then
  printf 'CNAME %s already exists\n' "$CF_STAGING_HOST"
else
  body=$(jq -cn --arg c "$CF_PROJECT.pages.dev" \
    '{type: "CNAME", name: "staging", content: $c, proxied: true, ttl: 1}')
  cf_write POST "$dns_path" "$body"
fi

# 3. Ask Pages to retry validation.
cf_write PATCH "$dom_item" '{}'

# 4. Done only when the domain reports active.
if [ "$APPLY" != 1 ]; then
  printf 'dry run: would then GET %s and require status active\n' "$dom_item"
  exit 0
fi
cf_read "$dom_item"
if [ "$CF_STATUS" != 200 ]; then
  cf_die "GET domain returned HTTP $CF_STATUS $(cf_errors)"
fi
status=$(printf '%s' "$CF_BODY" | jq -r '.result.status // "unknown"')
if [ "$status" = "active" ]; then
  printf 'ok: %s is active\n' "$CF_STAGING_HOST"
else
  printf 'pending: %s status is %s; re-run this script to retry validation\n' "$CF_STAGING_HOST" "$status" >&2
  exit 2
fi
