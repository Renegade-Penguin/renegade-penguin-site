#!/usr/bin/env bash
xtrace_was_on=0; case $- in *x*) xtrace_was_on=1 ;; esac
set +x
if [ "$xtrace_was_on" = 1 ]; then
  echo "error: xtrace is enabled; refusing to run so credentials cannot be traced" >&2
  exit 1
fi
# Ensure the Turnstile widget renegade-penguin-contact exists.
# Prints only the sitekey. The widget secret is never printed and never touches
# a file or a general shell variable: the create response streams from curl
# into jq, and jq feeds the secret straight into the stdin of
# `doppler secrets set` (stdin form, so it is not in argv). Doppler's stdout and
# stderr are both discarded; only its exit status is used.
# Required env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID.
# Dry run by default; --apply performs the create and the Doppler write.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

WIDGET_NAME="renegade-penguin-contact"
DOPPLER_PROJECT="no-php-no-cry"
DOPPLER_CONFIG="dev_renegadepenguin"

# create_widget_streaming BODY: POST the widget and store its secret without
# the secret ever being held outside a pipe. Sets WIDGET_SITEKEY and
# WIDGET_STATE (stored, failed or skipped), and CF_STATUS (HTTP code).
create_widget_streaming() {
  local body=$1 meta ok
  printf '%s' "$body" >"$CF_TMP/body"
  # curl stdout (the response) is piped straight to jq. The HTTP status goes to
  # stderr via %{stderr} into a file; it carries no secret. jq prints three
  # non-secret lines (success flag, sitekey, has-secret flag) and then the raw
  # secret with no newline. The reading group consumes the three lines and
  # hands the rest (the secret) to doppler as its stdin.
  meta=$(cf_auth_config |
    curl -sS --max-time 30 -K - -X POST -w '%{stderr}%{http_code}' \
      --data-binary "@$CF_TMP/body" "$CF_API_BASE$base" 2>"$CF_TMP/status" |
    jq -j '(.success == true | tostring), "\n", (.result.sitekey // ""), "\n",
           ((.result.secret // "") | length > 0 | tostring), "\n", (.result.secret // "")' 2>/dev/null |
    {
      IFS= read -r ok || ok=""
      IFS= read -r sk || sk=""
      IFS= read -r has || has=""
      state=skipped
      if [ "$ok" = true ] && [ "$has" = true ]; then
        if doppler secrets set TURNSTILE_SECRET_KEY --project "$DOPPLER_PROJECT" --config "$DOPPLER_CONFIG" >/dev/null 2>&1; then
          state=stored
        else
          state=failed
        fi
      fi
      printf '%s|%s|%s\n' "$ok" "$sk" "$state"
    }) || meta=""
  CF_STATUS=$(grep -oE '[0-9]{3}$' "$CF_TMP/status" || true)
  ok=${meta%%|*}
  WIDGET_SITEKEY=${meta#*|}
  WIDGET_SITEKEY=${WIDGET_SITEKEY%%|*}
  WIDGET_STATE=${meta##*|}
  if [ "$ok" != true ]; then
    CF_STATUS="${CF_STATUS:-000}-not-success"
  fi
}

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

if [ "$APPLY" != 1 ]; then
  printf 'WOULD READ doppler configs get --project %s --config %s (preflight, metadata only)\n' \
    "$DOPPLER_PROJECT" "$DOPPLER_CONFIG"
  printf 'WOULD POST %s\n      body: %s\n' "$base" "$body"
  printf 'dry run: would then pipe the secret to: doppler secrets set TURNSTILE_SECRET_KEY --project %s --config %s\n' \
    "$DOPPLER_PROJECT" "$DOPPLER_CONFIG"
  exit 0
fi

# Preflight: the destination must be reachable BEFORE the widget is created,
# so a failure cannot leave a widget whose secret has nowhere to go. This reads
# config metadata only; no secret values are read or printed.
printf 'READ  doppler configs get --project %s --config %s\n' "$DOPPLER_PROJECT" "$DOPPLER_CONFIG"
if ! doppler configs get --project "$DOPPLER_PROJECT" --config "$DOPPLER_CONFIG" --json </dev/null >/dev/null 2>&1; then
  cf_die "cannot read Doppler config $DOPPLER_PROJECT/$DOPPLER_CONFIG; nothing was created"
fi

printf 'WRITE POST %s\n' "$base"
create_widget_streaming "$body"
case "$CF_STATUS" in
  2??) ;;
  *) cf_die "POST $base returned HTTP $CF_STATUS; nothing was stored" ;;
esac
if [ -z "$WIDGET_SITEKEY" ]; then
  cf_die "create response had no sitekey; check the Cloudflare account for a stray widget named $WIDGET_NAME"
fi
if [ "$WIDGET_STATE" != stored ]; then
  printf 'error: widget %s WAS CREATED but its secret was NOT saved to Doppler.\n' "$WIDGET_NAME" >&2
  printf 'sitekey: %s\n' "$WIDGET_SITEKEY" >&2
  printf 'Recovery: delete the widget (DELETE /accounts/%s/challenges/widgets/%s) or rotate its secret, then re-run.\n' \
    "$CLOUDFLARE_ACCOUNT_ID" "$WIDGET_SITEKEY" >&2
  exit 1
fi
printf 'ok: created widget %s\nsitekey: %s\n' "$WIDGET_NAME" "$WIDGET_SITEKEY"
printf 'secret stored in Doppler (%s/%s) as TURNSTILE_SECRET_KEY\n' "$DOPPLER_PROJECT" "$DOPPLER_CONFIG"
