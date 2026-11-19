#!/usr/bin/env bash
# Ensure the Cloudflare Pages project exists (API only, never the dashboard).
# Required env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID.
# Dry run by default; --apply performs the POST.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

cf_init "ensure-pages-project" "$@"

path="/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$CF_PROJECT"
cf_read "$path"

case "$CF_STATUS" in
  200)
    printf 'ok: Pages project %s already exists; nothing to do\n' "$CF_PROJECT"
    exit 0
    ;;
  404)
    code=$(printf '%s' "$CF_BODY" | jq -r '.errors[0].code // empty' 2>/dev/null || true)
    if [ "$code" != "8000007" ]; then
      cf_die "404 without error code 8000007 (got '${code:-none}'); refusing to guess"
    fi
    printf 'project %s not found (code 8000007); creating\n' "$CF_PROJECT"
    ;;
  *)
    cf_die "GET project returned HTTP $CF_STATUS $(cf_errors)"
    ;;
esac

body=$(jq -cn --arg n "$CF_PROJECT" '{name: $n, production_branch: "main"}')
cf_write POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects" "$body"
if [ "$APPLY" = 1 ]; then
  printf 'ok: created Pages project %s\n' "$CF_PROJECT"
fi
