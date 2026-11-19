#!/usr/bin/env bash
xtrace_was_on=0; case $- in *x*) xtrace_was_on=1 ;; esac
set +x
if [ "$xtrace_was_on" = 1 ]; then
  echo "error: xtrace is enabled; refusing to run so credentials cannot be traced" >&2
  exit 1
fi
# Privatize the token before ANY external command or command substitution:
# a non-exported variable, and the exported one is unset.
unset CF_TOKEN_PRIVATE
CF_TOKEN_PRIVATE=${CLOUDFLARE_API_TOKEN:-}
unset CLOUDFLARE_API_TOKEN
# Ensure the Turnstile widget renegade-penguin-contact exists.
# Prints only the sitekey. The widget secret is never printed, never written to
# a file, never exported and never in argv. It reaches `doppler secrets set` on
# stdin (stdin form). Doppler's stdout and stderr are both discarded; only its
# exit status is used.
# Why one private variable: the HTTP status is known only when curl finishes,
# after the body, so a pure stream cannot gate delivery on a 2xx status. The
# response is therefore held in the single non-exported variable RESP_PRIVATE
# from curl's exit until the doppler call returns, checked (2xx status and a
# single-object success:true envelope) first, and unset immediately after. No
# byte reaches doppler unless both checks pass.
# Required env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID.
# Dry run by default; --apply performs the create and the Doppler write.
set -euo pipefail

case ${BASH_SOURCE[0]} in */*) here=${BASH_SOURCE[0]%/*} ;; *) here=. ;; esac
# shellcheck source=lib.sh
. "$here/lib.sh"

WIDGET_NAME="renegade-penguin-contact"
DOPPLER_PROJECT="no-php-no-cry"
DOPPLER_CONFIG="dev_renegadepenguin"

# create_widget BODY: POST the widget and, only if the HTTP status is 2xx AND
# the body is exactly one object with success true, hand the secret to doppler.
# Sets WIDGET_SITEKEY, WIDGET_STATE (stored, failed or skipped) and CF_STATUS.
create_widget() {
  local body=$1 status trailer size
  local LC_ALL=C # so ${#var} below counts bytes
  # Clear any inherited value AND its export attribute before the response is
  # assigned, so no child process can ever inherit the response.
  unset RESP_PRIVATE
  WIDGET_SITEKEY=""
  WIDGET_STATE=skipped
  printf '%s' "$body" >"$CF_TMP/body"
  # The trailer "<status> <bytes downloaded>" follows the body after a newline
  # (curl expands \n in -w). Trailing newlines of the body are preserved
  # because the trailer is the last thing in the substitution.
  RESP_PRIVATE=$(cf_auth_config |
    curl -sS --max-time 30 -K - -X POST -w '\n%{http_code} %{size_download}' \
      --data-binary "@$CF_TMP/body" "$CF_API_BASE$base") || RESP_PRIVATE=""
  trailer=${RESP_PRIVATE##*$'\n'}
  if [[ "$trailer" =~ ^[0-9]{3}\ [0-9]+$ ]]; then
    status=${trailer%% *}
    size=${trailer##* }
    RESP_PRIVATE=${RESP_PRIVATE%$'\n'*}
    # NUL guard without a file: command substitution drops NUL bytes, so the
    # captured length differs from what curl downloaded. Reject before the
    # envelope check and before anything reaches doppler.
    if [ "${#RESP_PRIVATE}" -ne "$size" ]; then
      status="$status-bad-size"
      RESP_PRIVATE=""
    fi
  else
    # Unexpected shape: never let body text (which may hold the secret) be
    # mistaken for a status or printed.
    status=000
    RESP_PRIVATE=""
  fi
  CF_STATUS=$status
  if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
    if printf '%s' "$RESP_PRIVATE" | jq -es "$CF_ENVELOPE_FILTER" >/dev/null 2>&1; then
      WIDGET_SITEKEY=$(printf '%s' "$RESP_PRIVATE" | jq -r '.result.sitekey // empty' 2>/dev/null || true)
      if printf '%s' "$RESP_PRIVATE" | jq -e '(.result.secret // "") | type == "string" and length > 0' >/dev/null 2>&1; then
        # Both checks passed. The secret goes only to doppler's stdin; its
        # stdout and stderr are discarded and only the exit status is kept.
        if printf '%s' "$RESP_PRIVATE" | jq -j '.result.secret' 2>/dev/null |
          doppler secrets set TURNSTILE_SECRET_KEY --project "$DOPPLER_PROJECT" --config "$DOPPLER_CONFIG" >/dev/null 2>&1; then
          WIDGET_STATE=stored
        else
          WIDGET_STATE=failed
        fi
      fi
    else
      CF_STATUS="$status-bad-body"
    fi
  fi
  unset RESP_PRIVATE
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
create_widget "$body"
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
