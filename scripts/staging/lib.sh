#!/usr/bin/env bash
# Shared helpers for the staging scripts. Source this file; do not run it.
#
# Safety properties:
#   - The token is read only from CLOUDFLARE_API_TOKEN and reaches curl only
#     through a stdin config (curl -K -), never through argv or a file.
#   - Nothing here prints the token. Response bodies are printed only for
#     errors, and only the error list.
#   - Dry run is the default. Writes happen only with --apply.

CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_PROJECT="renegade-penguin-site"
CF_STAGING_HOST="staging.renegadepenguinllc.com"
CF_APEX_HOST="renegadepenguinllc.com"

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
  local v
  for v in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID ${required[@]+"${required[@]}"}; do
    if [ -z "${!v:-}" ]; then
      cf_die "required environment variable $v is not set"
    fi
  done
  # The token goes into a curl config line; reject anything that could break
  # the quoting. Real Cloudflare tokens are [A-Za-z0-9_-].
  if ! [[ "$CLOUDFLARE_API_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
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

# cf_call METHOD PATH [BODY]: perform one real call. Sets CF_STATUS, CF_BODY.
cf_call() {
  local method=$1 path=$2 body=${3:-}
  local out="$CF_TMP/out"
  local args=(-sS --max-time 30 -K - -X "$method" -o "$out" -w '%{http_code}')
  if [ -n "$body" ]; then
    printf '%s' "$body" >"$CF_TMP/body"
    args+=(--data-binary "@$CF_TMP/body")
  fi
  : >"$out"
  # The token is written to curl's stdin config, so it is not in argv.
  CF_STATUS=$(printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' \
    "$CLOUDFLARE_API_TOKEN" | curl "${args[@]}" "$CF_API_BASE$path") || CF_STATUS=000
  CF_BODY=$(cat "$out")
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
