#!/usr/bin/env bash
# Ensure the Turnstile widget renegade-penguin-contact exists.
# Prints only the sitekey. The widget secret is NEVER written to stdout: it is
# piped as stdin to `doppler secrets set` (stdin form, so it is not in argv),
# and that command's own output (which echoes the value) goes to /dev/null.
# Required env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID.
# Dry run by default; --apply performs the create and the Doppler write.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

WIDGET_NAME="renegade-penguin-contact"
DOPPLER_PROJECT="no-php-no-cry"
DOPPLER_CONFIG="dev_renegadepenguin"

cf_init "ensure-turnstile" "$@"

base="/accounts/$CLOUDFLARE_ACCOUNT_ID/challenges/widgets"
cf_read "$base?per_page=100"
if [ "$CF_STATUS" != 200 ]; then
  cf_die "GET widgets returned HTTP $CF_STATUS $(cf_errors)"
fi
sitekey=$(printf '%s' "$CF_BODY" | jq -r --arg n "$WIDGET_NAME" \
  '[.result[]? | select(.name == $n)][0].sitekey // empty')

if [ -n "$sitekey" ]; then
  printf 'widget %s already exists\nsitekey: %s\n' "$WIDGET_NAME" "$sitekey"
  printf 'note: the secret is only returned at creation; it was not re-sent to Doppler\n'
  exit 0
fi

body=$(jq -cn --arg n "$WIDGET_NAME" --arg a "$CF_STAGING_HOST" --arg b "$CF_APEX_HOST" \
  '{name: $n, domains: [$a, $b], mode: "managed"}')
cf_write POST "$base" "$body"
if [ "$APPLY" != 1 ]; then
  printf 'dry run: would then pipe the secret to: doppler secrets set TURNSTILE_SECRET_KEY --project %s --config %s\n' \
    "$DOPPLER_PROJECT" "$DOPPLER_CONFIG"
  exit 0
fi

sitekey=$(printf '%s' "$CF_BODY" | jq -r '.result.sitekey // empty')
if [ -z "$sitekey" ]; then
  cf_die "create response had no sitekey"
fi
if [ -z "$(printf '%s' "$CF_BODY" | jq -r '.result.secret // empty')" ]; then
  cf_die "create response had no secret; widget exists, set the secret in Doppler by hand"
fi

# The secret goes ONLY to Doppler's stdin. Not to stdout, not to argv.
printf '%s' "$CF_BODY" | jq -j '.result.secret' |
  doppler secrets set TURNSTILE_SECRET_KEY --project "$DOPPLER_PROJECT" --config "$DOPPLER_CONFIG" >/dev/null
printf 'ok: created widget %s\nsitekey: %s\n' "$WIDGET_NAME" "$sitekey"
printf 'secret stored in Doppler (%s/%s) as TURNSTILE_SECRET_KEY\n' "$DOPPLER_PROJECT" "$DOPPLER_CONFIG"
