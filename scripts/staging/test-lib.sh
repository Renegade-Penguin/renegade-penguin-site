#!/usr/bin/env bash
# Shared helpers for the staging tests. Source this file; do not run it.

TEST_TOKEN="TESTTOKEN_SECRET_abc123"
TEST_SECRET="TURNSTILE_WIDGET_SECRET_zzz999"
STAGING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FAILS=0
T=""
T_BASH_FLAGS=()
T_ENV=()

t_setup() {
  T=$(mktemp -d)
  trap 't_cleanup' EXIT
  mkdir -p "$T/bin" "$T/resp" "$T/tmp"
  cp "$STAGING_DIR/testdata/fake-curl.sh" "$T/bin/curl"
  cp "$STAGING_DIR/testdata/fake-doppler.sh" "$T/bin/doppler"
  cp "$STAGING_DIR/testdata/fake-jq.sh" "$T/bin/jq"
  cp "$STAGING_DIR/testdata/fake-leakcheck.sh" "$T/fake-leakcheck.sh"
  cp "$STAGING_DIR/testdata/fake-dirname.sh" "$T/bin/dirname"
  chmod +x "$T/bin/curl" "$T/bin/doppler" "$T/bin/jq" "$T/bin/dirname"
  FAKE_REAL_JQ=$(command -v jq)
  FAKE_REAL_DIRNAME=$(command -v dirname)
  export FAKE_REAL_JQ FAKE_REAL_DIRNAME
  # Markers the fakes look for in their environment and under the script's TMPDIR.
  printf '%s\n%s\n' "$TEST_TOKEN" "$TEST_SECRET" >"$T/markers"
  : >"$T/calls.log"
}

t_cleanup() {
  if [ -n "$T" ] && [ -d "$T" ]; then
    rm -rf "$T"
  fi
}

# t_reset: clear logs, canned responses and leftovers between cases.
t_reset() {
  rm -rf "$T/resp" "$T/tmp"
  mkdir -p "$T/resp" "$T/tmp"
  rm -f "$T"/*.log
  : >"$T/calls.log"
  T_BASH_FLAGS=()
  T_ENV=()
  unset FAKE_DOPPLER_MODE FAKE_DOPPLER_PREFLIGHT
}

# t_resp METHOD PATH STATUS BODY
t_resp() {
  local key
  key=$(printf '%s_%s' "$1" "$2" | tr -c 'A-Za-z0-9\n' '_')
  printf '%s' "$3" >"$T/resp/$key.status"
  printf '%s' "$4" >"$T/resp/$key.body"
}

# t_run SCRIPT [ARGS...]: run with the fake curl/jq/doppler first on PATH.
# T_BASH_FLAGS and T_ENV (arrays) add bash flags and env settings.
# Sets RC and OUT (stdout and stderr combined).
t_run() {
  local script=$1
  shift
  set +e
  OUT=$(env ${T_ENV[@]+"${T_ENV[@]}"} PATH="$T/bin:$PATH" FAKE_DIR="$T" TMPDIR="$T/tmp" \
    CLOUDFLARE_API_TOKEN="$TEST_TOKEN" CLOUDFLARE_ACCOUNT_ID=acct123 CLOUDFLARE_ZONE_ID=zone123 \
    bash ${T_BASH_FLAGS[@]+"${T_BASH_FLAGS[@]}"} "$STAGING_DIR/$script" "$@" 2>&1)
  RC=$?
  set -e
}

t_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAILS=$((FAILS + 1))
}

t_ok() {
  printf 'ok: %s\n' "$*"
}

t_rc() { # expected label
  if [ "$RC" -eq "$1" ]; then t_ok "$2 (exit $1)"; else
    t_fail "$2: expected exit $1, got $RC; output: $OUT"
  fi
}

t_writes() { # count of state-changing calls recorded
  grep -cE '^(POST|PUT|PATCH|DELETE) ' "$T/calls.log" || true
}

t_expect_writes() { # expected label
  local n
  n=$(t_writes)
  if [ "$n" -eq "$1" ]; then t_ok "$2 ($1 write calls)"; else
    t_fail "$2: expected $1 write calls, got $n; calls: $(cat "$T/calls.log")"
  fi
}

t_expect_call() { # fixed-string-in-calls.log label
  if grep -qF -- "$1" "$T/calls.log"; then t_ok "$2"; else
    t_fail "$2: no call containing '$1'; calls: $(cat "$T/calls.log")"
  fi
}

t_expect_no_call() { # fixed-string-in-calls.log label
  if grep -qF -- "$1" "$T/calls.log"; then
    t_fail "$2: unexpected call containing '$1'; calls: $(cat "$T/calls.log")"
  else t_ok "$2"; fi
}

t_expect_out() { # fixed-string-in-OUT label
  if printf '%s' "$OUT" | grep -qF -- "$1"; then t_ok "$2"; else
    t_fail "$2: output lacks '$1'; output: $OUT"
  fi
}

# t_token_never_leaks: the token and widget secret must not be in argv, recorded
# calls, doppler argv, script output, any child environment, or any file under
# the script's TMPDIR (checked by the fakes while the script runs, and again
# here for leftovers). The token must have reached curl through the stdin config.
t_token_never_leaks() {
  local f
  for f in "$T/argv.log" "$T/calls.log" "$T/doppler-argv.log"; do
    if [ -f "$f" ] && grep -qFf "$T/markers" "$f"; then
      t_fail "secret found in $(basename "$f")"
    fi
  done
  if printf '%s' "$OUT" | grep -qFf "$T/markers"; then
    t_fail "secret found in script output"
  fi
  if [ -s "$T/leak.log" ]; then
    t_fail "fake executable saw a secret: $(cat "$T/leak.log")"
  fi
  if [ -e "$T/dirname.log" ]; then
    t_fail "the script ran dirname (an external command) before privatizing the token"
  fi
  if grep -rqFf "$T/markers" "$T/tmp" 2>/dev/null; then
    t_fail "secret found in a file under the script temp dir"
  fi
  if [ -s "$T/argv.log" ] && ! grep -q auth-via-stdin "$T/auth.log" 2>/dev/null; then
    t_fail "token did not reach curl via the stdin config"
  fi
  t_ok "token/secret absent from argv, calls, output, child environments and temp files"
}

t_finish() {
  if [ "$FAILS" -ne 0 ]; then
    printf '%s test(s) failed\n' "$FAILS" >&2
    exit 1
  fi
  printf 'all passed\n'
}
