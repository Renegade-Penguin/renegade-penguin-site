#!/usr/bin/env bash
# Shared helpers for the staging scripts. Source this file; do not run it.
#
# Safety properties:
#   - The scripts refuse to run with xtrace on (see the guard at the top of
#     each script), so no credential is ever expanded while tracing.
#   - The token is read only from CLOUDFLARE_API_TOKEN. The first lines of each
#     entrypoint (before ANY external command or command substitution) move it
#     into the private, non-exported CF_TOKEN_PRIVATE and unset the exported
#     one, so no child process inherits it. Only the shell expands it, into
#     curl's stdin config (curl -K -), never argv and never a file.
#   - An API response is accepted only if it is exactly one JSON object with
#     .success == true (CF_ENVELOPE_FILTER, used with jq -es).
#   - Nothing here prints the token. Response bodies are printed only for
#     errors, and only the error list.
#   - Dry run is the default. Writes happen only with --apply.

CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_PROJECT="renegade-penguin-site"
CF_STAGING_HOST="staging.renegadepenguinllc.com"
CF_APEX_HOST="renegadepenguinllc.com"

# Exactly one top-level value, an object, with success true. Use with jq -es.
CF_ENVELOPE_FILTER='length == 1 and (.[0] | type == "object") and .[0].success == true'

# Clear any inherited value and its export attribute before assigning.
unset APPLY CF_STATUS CF_BODY CF_TMP
APPLY=0
CF_STATUS=""
CF_BODY=""
CF_TMP=""

cf_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cf_cleanup() {
  if [ -n "$CF_TMP" ] && [ -d "$CF_TMP" ]; then
    rm -rf "$CF_TMP"
  fi
}

# cf_init <script-name> "$@": parse flags, check env, make a temp dir.
# Extra env var names to require follow after a literal "--".
cf_init() {
  local name=$1
  shift
  case $- in
    *x*) cf_die "xtrace is enabled; refusing to run so credentials cannot be traced" ;;
  esac
  local args=() required=() seen_sep=0 a
  for a in "$@"; do
    if [ "$seen_sep" = 1 ]; then
      required+=("$a")
    elif [ "$a" = "--" ]; then
      seen_sep=1
    else
      args+=("$a")
    fi
  done
  for a in ${args[@]+"${args[@]}"}; do
    case "$a" in
      --apply) APPLY=1 ;;
      -h | --help)
        printf 'usage: %s [--apply]\nDry run by default; --apply performs the writes.\n' "$name"
        exit 0
        ;;
      *) cf_die "unknown argument: $a" ;;
    esac
  done
  # The entrypoint already moved the token into CF_TOKEN_PRIVATE and unset the
  # exported one, before running any external command.
  local v
  if [ -z "$CF_TOKEN_PRIVATE" ]; then
    cf_die "required environment variable CLOUDFLARE_API_TOKEN is not set"
  fi
  for v in CLOUDFLARE_ACCOUNT_ID ${required[@]+"${required[@]}"}; do
    if [ -z "${!v:-}" ]; then
      cf_die "required environment variable $v is not set"
    fi
  done
  # The token goes into a curl config line; reject anything that could break
  # the quoting. Real Cloudflare tokens are [A-Za-z0-9_-].
  if ! [[ "$CF_TOKEN_PRIVATE" =~ ^[A-Za-z0-9_-]+$ ]]; then
    cf_die "CLOUDFLARE_API_TOKEN has unexpected characters"
  fi
  CF_TMP=$(mktemp -d)
  trap cf_cleanup EXIT
  if [ "$APPLY" = 1 ]; then
    printf '== %s: APPLY mode\n' "$name"
  else
    printf '== %s: DRY RUN (no writes; pass --apply to perform them)\n' "$name"
  fi
}

# cf_auth_config: the curl config (stdin form) carrying the token header.
# printf is a builtin, so the token is not in any process argv.
cf_auth_config() {
  printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' \
    "$CF_TOKEN_PRIVATE"
}

# cf_call METHOD PATH [BODY]: perform one real call. Sets CF_STATUS, CF_BODY.
# A 2xx whose body is not JSON with .success == true gets CF_STATUS "<code>-bad-body".
cf_call() {
  local method=$1 path=$2 body=${3:-}
  local out="$CF_TMP/out"
  local args=(-sS --max-time 30 -K - -X "$method" -o "$out" -w '%{http_code} %{size_download}')
  local trailer size=0
  local LC_ALL=C # so ${#var} below counts bytes
  if [ -n "$body" ]; then
    printf '%s' "$body" >"$CF_TMP/body"
    args+=(--data-binary "@$CF_TMP/body")
  fi
  : >"$out"
  trailer=$(cf_auth_config | curl "${args[@]}" "$CF_API_BASE$path") || trailer=""
  # Keep trailing newlines of the body (the sentinel x is stripped again).
  CF_BODY=$(cat "$out"; printf x)
  CF_BODY=${CF_BODY%x}
  if [[ "$trailer" =~ ^([0-9]{3})\ ([0-9]+)$ ]]; then
    CF_STATUS=${BASH_REMATCH[1]}
    size=${BASH_REMATCH[2]}
  else
    CF_STATUS=000
  fi
  # NUL guard without a second file: command substitution drops NUL bytes, so
  # the captured length differs from what curl downloaded. Reject such a body
  # before the envelope check.
  if [ "${#CF_BODY}" -ne "$size" ]; then
    CF_STATUS="$CF_STATUS-bad-size"
  fi
  case "$CF_STATUS" in
    2??)
      if ! printf '%s' "$CF_BODY" | jq -es "$CF_ENVELOPE_FILTER" >/dev/null 2>&1; then
        CF_STATUS="$CF_STATUS-bad-body"
      fi
      ;;
  esac
}

# cf_errors: print only the error list from CF_BODY.
cf_errors() {
  printf '%s' "$CF_BODY" | jq -c '.errors // empty' 2>/dev/null || true
}

# cf_read PATH: GET, allowed in dry run. Does not fail on 404; the caller decides.
cf_read() {
  printf 'READ  GET %s\n' "$1"
  cf_call GET "$1"
}

# cf_write METHOD PATH BODY: a state-changing call. Dry run prints it only.
# The body must never contain a secret.
cf_write() {
  local method=$1 path=$2 body=${3:-}
  if [ "$APPLY" != 1 ]; then
    printf 'WOULD %s %s\n' "$method" "$path"
    if [ -n "$body" ]; then
      printf '      body: %s\n' "$body"
    fi
    CF_STATUS=dry
    CF_BODY=""
    return 0
  fi
  printf 'WRITE %s %s\n' "$method" "$path"
  cf_call "$method" "$path" "$body"
  case "$CF_STATUS" in
    2??) ;;
    *)
      printf 'error: %s %s returned HTTP %s %s\n' "$method" "$path" "$CF_STATUS" "$(cf_errors)" >&2
      exit 1
      ;;
  esac
}
