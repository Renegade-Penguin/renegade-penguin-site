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
# Ensure the Cloudflare Pages project exists (API only, never the dashboard).
# Required env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID.
# Dry run by default; --apply performs the POST.
set -euo pipefail

case ${BASH_SOURCE[0]} in */*) here=${BASH_SOURCE[0]%/*} ;; *) here=. ;; esac
# shellcheck source=lib.sh
. "$here/lib.sh"

cf_init "ensure-pages-project" "$@"

path="/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$CF_PROJECT"
cf_read "$path"

case "$CF_STATUS" in
  200)
    # Validate the existing project; never change it silently.
    branch=$(printf '%s' "$CF_BODY" | jq -r '.result.production_branch // "(none)"')
    if [ "$branch" != "main" ]; then
      cf_die "Pages project $CF_PROJECT exists but its production branch is not main; not changing it. Fix it by hand, then re-run"
    fi
    printf 'ok: Pages project %s already exists with production branch main; nothing to do\n' "$CF_PROJECT"
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
