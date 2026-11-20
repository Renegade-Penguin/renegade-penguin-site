#!/usr/bin/env bash
# Production deploy for the apex cutover (issue #102, docs/cutover.md). NOT APPLIED by default.
#
# Usage: scripts/deploy-production.sh [--dry-run | --apply]
#
# Dry run is the default: every step is printed and nothing is built, checked or deployed.
# --apply is refused unless ALL of these hold:
#   - OWNER_APPROVED_CUTOVER=yes (exactly that value)
#   - SCRUB_TERMS_FILE names a readable file with at least one real pattern (blank lines and
#     comment lines do not count) that is not the CI placeholder list
#   - the production build passes scripts/check-output.sh with REQUIRE_NO_OWNER_TOKENS=1
#     (checked after the build and before any deploy; a failure stops the script)
# Also needed to apply: HUGO_PARAMS_TURNSTILESITEKEY (the public sitekey of the production widget)
# and CLOUDFLARE_API_TOKEN, which wrangler reads from the environment. The token is never read,
# printed or placed on a command line by this script. No arguments other than the two flags are
# accepted, so no secret can be passed in argv.
#
# Optional overrides for tests: HUGO (default hugo) and WRANGLER (default wrangler, which must be
# on PATH; the script never runs npx or installs anything).
set -euo pipefail

xtrace_was_on=0
case $- in *x*) xtrace_was_on=1 ;; esac
set +x
if [ "$xtrace_was_on" = 1 ]; then
  echo "error: xtrace is enabled; refusing to run so credentials cannot be traced" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
HUGO="${HUGO:-hugo}"
WRANGLER="${WRANGLER:-wrangler}"
PLACEHOLDER="zz-ci-placeholder-term-zz"

fail() {
  echo "refused: $*" >&2
  exit 1
}

MODE="dry-run"
if [ "$#" -gt 1 ]; then
  fail "at most one argument (--dry-run or --apply) is accepted"
fi
if [ "$#" -eq 1 ]; then
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --apply) MODE="apply" ;;
    *) fail "unknown argument; only --dry-run and --apply are accepted (secrets never go in argv)" ;;
  esac
fi

if [ "$MODE" = "dry-run" ]; then
  echo "DRY RUN: nothing is built, checked or deployed. Re-run with --apply only after the owner approves."
  echo "step 1 preflight: require OWNER_APPROVED_CUTOVER=yes, a real SCRUB_TERMS_FILE (not the CI placeholder), HUGO_PARAMS_TURNSTILESITEKEY"
  echo "step 2 build production: HUGO_ENVIRONMENT=production HUGO_PARAMS_ENVIRONMENT=production $HUGO --minify --gc --destination public"
  echo "step 3 check-output: EXPECT_ENV=production REQUIRE_NO_OWNER_TOKENS=1 SCRUB_TERMS_FILE=<real file> scripts/check-output.sh public"
  echo "step 4 artifact checks: public/robots.txt has no Disallow all, public/sitemap.xml exists, no noindex meta"
  echo "step 5 wrangler pages deploy: $WRANGLER pages deploy public --config wrangler.production.jsonc --project-name renegade-penguin-site-prod --branch main"
  echo "(the Cloudflare token is read by wrangler from the environment, never from argv)"
  exit 0
fi

# Step 1: preflight. Every refusal happens before any build or deploy.
if [ "${OWNER_APPROVED_CUTOVER:-}" != "yes" ]; then
  fail "--apply needs OWNER_APPROVED_CUTOVER=yes (the owner's approval); nothing was run"
fi
if [ -z "${SCRUB_TERMS_FILE:-}" ]; then
  fail "--apply needs SCRUB_TERMS_FILE set to the real scrub terms file; nothing was run"
fi
if [ ! -f "$SCRUB_TERMS_FILE" ] || [ ! -r "$SCRUB_TERMS_FILE" ]; then
  fail "SCRUB_TERMS_FILE is not a readable file; nothing was run"
fi
if ! grep -qvE '^[[:space:]]*(#|$)' "$SCRUB_TERMS_FILE"; then
  fail "SCRUB_TERMS_FILE has no patterns (only blanks and comments); nothing was run"
fi
if grep -qF "$PLACEHOLDER" "$SCRUB_TERMS_FILE"; then
  fail "SCRUB_TERMS_FILE is the CI placeholder list, not the real terms; nothing was run"
fi
if [ -z "${HUGO_PARAMS_TURNSTILESITEKEY:-}" ]; then
  fail "--apply needs HUGO_PARAMS_TURNSTILESITEKEY (the public sitekey of the production widget); nothing was run"
fi

# Step 2: build the production variant (no staging params). The destination is the project's
# pages_build_output_dir.
echo "step 2: build production"
rm -rf public
HUGO_ENVIRONMENT=production HUGO_PARAMS_ENVIRONMENT=production "$HUGO" --minify --gc --destination public

# Steps 3 and 4: the production gate, before any deploy.
echo "step 3: check-output"
EXPECT_ENV=production REQUIRE_NO_OWNER_TOKENS=1 SCRUB_TERMS_FILE="$SCRUB_TERMS_FILE" scripts/check-output.sh public

echo "step 4: artifact checks"
[ -f public/sitemap.xml ] || fail "public/sitemap.xml missing"
[ -f public/robots.txt ] || fail "public/robots.txt missing"
if grep -qE '^[[:space:]]*Disallow:[[:space:]]*/[[:space:]]*$' public/robots.txt; then
  fail "public/robots.txt disallows everything"
fi
if grep -rqiE '<meta[^>]*name="?robots"?[^>]*noindex' public --include='*.html'; then
  fail "a built page has a noindex meta"
fi

# Step 5: deploy to the production project with the explicit config.
echo "step 5: wrangler pages deploy"
"$WRANGLER" pages deploy public --config wrangler.production.jsonc --project-name renegade-penguin-site-prod --branch main
echo "deployed to the renegade-penguin-site-prod pages.dev URL. Run the post-deploy checks there before attaching the apex (docs/cutover.md)."
