#!/usr/bin/env bash
# Static test for the production cutover preparation (issue #102). No network, nothing applied.
# Asserts:
#   1. the production build is indexable (no noindex meta, robots.txt does not Disallow all,
#      sitemap.xml present) and the staging variant stays noindex with Disallow all;
#   2. both wrangler configs obey their allowlists (scripts/test-pages-config.sh);
#   3. scripts/deploy-production.sh: dry run exits 0 and prints every step; --apply without the
#      approval env, with a missing, empty or placeholder scrub file, or with extra arguments exits
#      non-zero and runs nothing (fake hugo and wrangler record any call); the script text pins the
#      production flags and orders the checks before the deploy;
#   4. docs/cutover.md has the required headings, the access plan table and both marker strings;
#   5. no file of the change holds a token-looking string or an em or en dash.
# Negative cases prove each guard bites.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" cutover.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Indexability of the two builds.
"$HUGO" --minify --destination "$TMP/prod" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  fail "production build failed"
}
HUGO_PARAMS_ENVIRONMENT=staging "$HUGO" --minify --destination "$TMP/staging" >/dev/null 2>"$TMP/build.err" || {
  cat "$TMP/build.err" >&2
  fail "staging build failed"
}
cat >"$TMP/index.py" <<'PY'
import os
import re
import sys

NOINDEX = re.compile(r"<meta[^>]*name=\"?robots\"?[^>]*noindex", re.I)


def pages(root):
    for base, _dirs, files in os.walk(root):
        for name in files:
            if name.endswith(".html"):
                yield os.path.join(base, name)


def blocks_all(path):
    star = False
    in_group = False
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            low = line.lower()
            if low.startswith("user-agent:"):
                if not in_group:
                    star = False
                in_group = True
                if line.split(":", 1)[1].strip() == "*":
                    star = True
            elif low.startswith("disallow:"):
                in_group = False
                if star and line.split(":", 1)[1].strip() == "/":
                    return True
            elif line:
                in_group = False
    return False


def check_production(root):
    errors = []
    files = list(pages(root))
    if not files:
        errors.append("no html pages found")
    for path in files:
        with open(path, encoding="utf-8") as fh:
            if NOINDEX.search(fh.read()):
                errors.append("noindex meta in " + path)
    robots = os.path.join(root, "robots.txt")
    if not os.path.isfile(robots):
        errors.append("robots.txt missing")
    elif blocks_all(robots):
        errors.append("robots.txt disallows everything")
    if not os.path.isfile(os.path.join(root, "sitemap.xml")):
        errors.append("sitemap.xml missing")
    return errors


def check_staging(root):
    errors = []
    files = list(pages(root))
    if not files:
        errors.append("no html pages found")
    for path in files:
        with open(path, encoding="utf-8") as fh:
            if not NOINDEX.search(fh.read()):
                errors.append("no noindex meta in " + path)
    robots = os.path.join(root, "robots.txt")
    if not os.path.isfile(robots):
        errors.append("robots.txt missing")
    elif not blocks_all(robots):
        errors.append("robots.txt does not disallow everything")
    return errors


prod, staging = sys.argv[1], sys.argv[2]
errs = check_production(prod) + ["staging: " + e for e in check_staging(staging)]
if errs:
    sys.exit("; ".join(errs[:5]))
# Negative cases: each guard must fire on the opposite variant.
if not check_production(staging):
    sys.exit("negative case did not fail: production check on the staging build")
if not check_staging(prod):
    sys.exit("negative case did not fail: staging check on the production build")
print("ok: production indexable, staging noindex")
PY
python3 -I "$TMP/index.py" "$TMP/prod" "$TMP/staging" || fail "build variants"

# 2. Both wrangler configs.
bash scripts/test-pages-config.sh || fail "wrangler configs"

# 3. The deploy script.
S=scripts/deploy-production.sh
[ -f "$S" ] || fail "$S missing"
mkdir -p "$TMP/bin"
for tool in hugo wrangler; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 0\n' "$tool" "$TMP" >"$TMP/bin/$tool"
  chmod +x "$TMP/bin/$tool"
done
# A dummy token proves it is never printed or echoed back.
DUMMY_TOKEN="dummy-token-for-leak-test-0123"
run() { # <name> <expected: zero|nonzero> <env assignments...> -- <args...>
  local name="$1" want="$2" st=0
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  [ "$#" -gt 0 ] && shift
  : >"$TMP/calls"
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$HOME" HUGO="$TMP/bin/hugo" WRANGLER="$TMP/bin/wrangler" \
    CLOUDFLARE_API_TOKEN="$DUMMY_TOKEN" "${envs[@]}" \
    bash "$S" "$@" >"$TMP/out" 2>&1 || st=$?
  case "$want" in
    zero) [ "$st" -eq 0 ] || fail "$name: expected exit 0, got $st: $(tail -n 3 "$TMP/out")" ;;
    nonzero) [ "$st" -ne 0 ] || fail "$name: expected non-zero exit" ;;
  esac
  [ ! -s "$TMP/calls" ] || fail "$name: ran a tool: $(cat "$TMP/calls")"
  if grep -q "$DUMMY_TOKEN" "$TMP/out"; then fail "$name: the token was printed"; fi
}

run "dry run (no args)" zero --
for step in "preflight" "build production" "check-output" "wrangler pages deploy" "renegade-penguin-site-prod"; do
  grep -q "$step" "$TMP/out" || fail "dry run does not print step: $step"
done
grep -qi "dry run" "$TMP/out" || fail "dry run does not say it is a dry run"
run "dry run (explicit)" zero -- --dry-run
run "apply without approval" nonzero -- --apply
run "apply with wrong approval value" nonzero OWNER_APPROVED_CUTOVER=true -- --apply
grep -qi "OWNER_APPROVED_CUTOVER" "$TMP/out" || fail "refusal does not name OWNER_APPROVED_CUTOVER"
run "approval but no scrub file variable" nonzero OWNER_APPROVED_CUTOVER=yes HUGO_PARAMS_TURNSTILESITEKEY=fixturekey -- --apply
run "approval but missing scrub file" nonzero OWNER_APPROVED_CUTOVER=yes HUGO_PARAMS_TURNSTILESITEKEY=fixturekey SCRUB_TERMS_FILE="$TMP/nope.txt" -- --apply
grep -qi "SCRUB_TERMS_FILE" "$TMP/out" || fail "refusal does not name SCRUB_TERMS_FILE"
: >"$TMP/empty.txt"
run "approval but empty scrub file" nonzero OWNER_APPROVED_CUTOVER=yes HUGO_PARAMS_TURNSTILESITEKEY=fixturekey SCRUB_TERMS_FILE="$TMP/empty.txt" -- --apply
printf '# only a comment\n\n' >"$TMP/comments.txt"
run "approval but comment-only scrub file" nonzero OWNER_APPROVED_CUTOVER=yes HUGO_PARAMS_TURNSTILESITEKEY=fixturekey SCRUB_TERMS_FILE="$TMP/comments.txt" -- --apply
printf '# placeholder\nzz-ci-placeholder-term-zz\n' >"$TMP/placeholder.txt"
run "approval but CI placeholder scrub file" nonzero OWNER_APPROVED_CUTOVER=yes HUGO_PARAMS_TURNSTILESITEKEY=fixturekey SCRUB_TERMS_FILE="$TMP/placeholder.txt" -- --apply
printf '# real terms stand-in\nsome-real-term\n' >"$TMP/real.txt"
run "approval and real scrub file but no sitekey" nonzero OWNER_APPROVED_CUTOVER=yes SCRUB_TERMS_FILE="$TMP/real.txt" -- --apply
grep -qi "HUGO_PARAMS_TURNSTILESITEKEY" "$TMP/out" || fail "refusal does not name the sitekey"
run "unknown argument" nonzero -- --token abc
run "apply with a stray argument" nonzero OWNER_APPROVED_CUTOVER=yes HUGO_PARAMS_TURNSTILESITEKEY=fixturekey SCRUB_TERMS_FILE="$TMP/real.txt" -- --apply extra
# The approval alone never makes a dry run apply anything.
run "dry run with approval set" zero OWNER_APPROVED_CUTOVER=yes -- --dry-run
run "dry run (version step)" zero --
for step in "wrangler --version" "3.45.0" "clean staging directory" "REQUIRE_OWNER_APPROVAL=1"; do
  grep -q "$step" "$TMP/out" || fail "dry run does not print: $step"
done

# The Wrangler version pre-check runs only with --apply, after the other refusals, and stops before
# any build or deploy when Wrangler is older than 3.45.0 or prints no version.
version_case() { # <name> <wrangler --version output>
  local name="$1" st=0
  mkdir -p "$TMP/oldbin"
  printf '#!/bin/sh\necho "wrangler $*" >> "%s/wcalls"\n[ "$1" = "--version" ] && echo "%s"\nexit 0\n' "$TMP" "$2" >"$TMP/oldbin/wrangler"
  chmod +x "$TMP/oldbin/wrangler"
  : >"$TMP/calls"
  : >"$TMP/wcalls"
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$HOME" HUGO="$TMP/bin/hugo" WRANGLER="$TMP/oldbin/wrangler" \
    OWNER_APPROVED_CUTOVER=yes HUGO_PARAMS_TURNSTILESITEKEY=fixturekey SCRUB_TERMS_FILE="$TMP/real.txt" \
    CLOUDFLARE_API_TOKEN="$DUMMY_TOKEN" bash "$S" --apply >"$TMP/out" 2>&1 || st=$?
  [ "$st" -ne 0 ] || fail "$name: expected non-zero exit"
  [ ! -s "$TMP/calls" ] || fail "$name: built or checked after a bad version: $(cat "$TMP/calls")"
  [ "$(cat "$TMP/wcalls")" = "wrangler --version" ] || fail "$name: wrangler ran more than --version: $(cat "$TMP/wcalls")"
  grep -q "3.45.0" "$TMP/out" || fail "$name: refusal does not name 3.45.0"
}
version_case "wrangler 3.44.0" "wrangler 3.44.0"
version_case "wrangler 2.20.0" "wrangler 2.20.0"
version_case "wrangler prints no version" "wrangler"

# Controlled full --apply path. The real deploy-production.sh runs from a copy of a tiny repo tree in
# $TMP, with fake hugo, wrangler and check-output that record every call (with its arguments) in one
# log. Nothing real is built, checked or deployed; no network.
APPLY_REPO="$TMP/applyrepo"
APPLY_LOG="$TMP/apply.log"
apply_case() { # <name> <wrangler version> <fake check-output exit code> <expected exit: zero|nonzero>
  local name="$1" wver="$2" check_rc="$3" want="$4" st=0
  rm -rf "$APPLY_REPO" "$TMP/fakebin"
  mkdir -p "$APPLY_REPO/scripts" "$APPLY_REPO/functions/api" "$TMP/fakebin"
  cp "$S" "$APPLY_REPO/scripts/deploy-production.sh"
  cp wrangler.production.jsonc "$APPLY_REPO/wrangler.production.jsonc"
  echo "export default {};" >"$APPLY_REPO/functions/api/fixture.js"
  : >"$APPLY_LOG"
  rm -f "$TMP/deploydir"
  printf '%s\n' '#!/bin/sh' \
    'echo "CHECK EXPECT_ENV=$EXPECT_ENV REQUIRE_NO_OWNER_TOKENS=$REQUIRE_NO_OWNER_TOKENS REQUIRE_OWNER_APPROVAL=$REQUIRE_OWNER_APPROVAL ARGS=$*" >>"$LOG"' \
    'exit "$FAKE_CHECK_RC"' >"$APPLY_REPO/scripts/check-output.sh"
  printf '%s\n' '#!/bin/sh' \
    'echo "HUGO ARGS=$* HUGO_ENVIRONMENT=$HUGO_ENVIRONMENT HUGO_PARAMS_ENVIRONMENT=$HUGO_PARAMS_ENVIRONMENT SITEKEY=$HUGO_PARAMS_TURNSTILESITEKEY" >>"$LOG"' \
    'dest=public; prev=""' \
    'for a in "$@"; do' \
    '  [ "$prev" = "--destination" ] && dest="$a"' \
    '  prev="$a"' \
    'done' \
    'mkdir -p "$dest"' \
    'echo ok >"$dest/index.html"' \
    'printf "User-agent: *\nAllow: /\n" >"$dest/robots.txt"' \
    'echo "<urlset/>" >"$dest/sitemap.xml"' >"$TMP/fakebin/hugo"
  printf '%s\n' '#!/bin/sh' \
    'if [ "$1" = "--version" ]; then' \
    '  echo "W-VERSION ARGS=$*" >>"$LOG"' \
    '  echo "wrangler $FAKE_WRANGLER_VERSION"' \
    '  exit 0' \
    'fi' \
    'echo "DEPLOY ARGS=$*" >>"$LOG"' \
    'echo "DETAIL files=$(ls "$PWD" | tr "\n" " ")" >>"$LOG"' \
    'if cmp -s "$PWD/wrangler.jsonc" "$PROD_CONFIG"; then echo "DETAIL config=production" >>"$LOG"; else echo "DETAIL config=other" >>"$LOG"; fi' \
    'if [ -f "$PWD/functions/api/fixture.js" ]; then echo "DETAIL functions=present" >>"$LOG"; fi' \
    'if [ -f "$PWD/public/index.html" ]; then echo "DETAIL public=present" >>"$LOG"; fi' \
    'echo "$PWD" >"$DEPLOYDIR_FILE"' >"$TMP/fakebin/wrangler"
  chmod +x "$APPLY_REPO/scripts/check-output.sh" "$TMP/fakebin/hugo" "$TMP/fakebin/wrangler"
  env -i PATH="$TMP/fakebin:/usr/bin:/bin" HOME="$HOME" LOG="$APPLY_LOG" FAKE_CHECK_RC="$check_rc" \
    FAKE_WRANGLER_VERSION="$wver" PROD_CONFIG="$APPLY_REPO/wrangler.production.jsonc" \
    DEPLOYDIR_FILE="$TMP/deploydir" OWNER_APPROVED_CUTOVER=yes HUGO_PARAMS_TURNSTILESITEKEY=fixturekey \
    SCRUB_TERMS_FILE="$TMP/real.txt" CLOUDFLARE_API_TOKEN="$DUMMY_TOKEN" \
    bash "$APPLY_REPO/scripts/deploy-production.sh" --apply >"$TMP/out" 2>&1 || st=$?
  case "$want" in
    zero) [ "$st" -eq 0 ] || fail "$name: expected exit 0, got $st: $(tail -n 3 "$TMP/out")" ;;
    nonzero) [ "$st" -ne 0 ] || fail "$name: expected non-zero exit" ;;
  esac
  if grep -q "$DUMMY_TOKEN" "$APPLY_LOG" "$TMP/out"; then fail "$name: the token appears in a call or in the output"; fi
}
# Tags of the recorded calls, in order, as one string.
apply_order() { grep -E '^(W-VERSION|HUGO|CHECK|DEPLOY) ' "$APPLY_LOG" | cut -d' ' -f1 | tr '\n' ' '; }

apply_case "full apply" "3.45.0" 0 zero
[ "$(apply_order)" = "W-VERSION HUGO CHECK DEPLOY " ] || fail "full apply: wrong call order: $(apply_order)"
grep -qx 'W-VERSION ARGS=--version' "$APPLY_LOG" || fail "full apply: wrangler --version not called as expected"
grep -qx 'HUGO ARGS=--minify --gc --destination public HUGO_ENVIRONMENT=production HUGO_PARAMS_ENVIRONMENT=production SITEKEY=fixturekey' "$APPLY_LOG" ||
  fail "full apply: hugo was not the production variant: $(grep '^HUGO ' "$APPLY_LOG")"
if grep -qi 'staging' "$APPLY_LOG"; then fail "full apply: a staging parameter reached a call"; fi
grep -qx 'CHECK EXPECT_ENV=production REQUIRE_NO_OWNER_TOKENS=1 REQUIRE_OWNER_APPROVAL=1 ARGS=public' "$APPLY_LOG" ||
  fail "full apply: check-output got the wrong environment or arguments: $(grep '^CHECK ' "$APPLY_LOG")"
grep -qx 'DEPLOY ARGS=pages deploy public --project-name renegade-penguin-site-prod --branch main' "$APPLY_LOG" ||
  fail "full apply: wrong deploy arguments: $(grep '^DEPLOY ' "$APPLY_LOG")"
if grep -q -- '--config' "$APPLY_LOG"; then fail "full apply: --config was passed"; fi
grep -qx 'DETAIL config=production' "$APPLY_LOG" || fail "full apply: wrangler.jsonc in the deploy directory is not the production config"
grep -qx 'DETAIL functions=present' "$APPLY_LOG" || fail "full apply: functions/ missing from the deploy directory"
grep -qx 'DETAIL public=present' "$APPLY_LOG" || fail "full apply: public/ missing from the deploy directory"
grep -q 'DETAIL files=.*wrangler.jsonc' "$APPLY_LOG" || fail "full apply: no wrangler.jsonc in the deploy directory"
deploy_dir="$(cat "$TMP/deploydir")"
[ "$deploy_dir" != "$APPLY_REPO" ] || fail "full apply: deployed from the repository root, not a clean directory"
[ ! -e "$deploy_dir" ] || fail "full apply: the staging directory was not removed"
if grep -qE '[A-Za-z0-9_-]{32,}' "$APPLY_LOG"; then fail "full apply: a long secret-looking value is in a call log"; fi

apply_case "full apply with a newer wrangler" "4.1.2" 0 zero
[ "$(apply_order)" = "W-VERSION HUGO CHECK DEPLOY " ] || fail "newer wrangler: wrong call order: $(apply_order)"

# Negative: a failing output check must stop before the deploy.
apply_case "failing check-output" "3.45.0" 1 nonzero
[ "$(apply_order)" = "W-VERSION HUGO CHECK " ] || fail "failing check-output: expected no deploy, calls were: $(apply_order)"
if grep -q '^DEPLOY ' "$APPLY_LOG"; then fail "failing check-output: wrangler pages deploy was called"; fi

# Negative: a failing version check must never reach hugo.
apply_case "old wrangler" "3.44.0" 0 nonzero
[ "$(apply_order)" = "W-VERSION " ] || fail "old wrangler: expected only the version call, calls were: $(apply_order)"
echo "ok: deploy-production.sh full apply path (fakes)"
echo "ok: deploy-production.sh refusals and dry run"

# The script text pins the production flags and orders the checks before the deploy.
python3 -I - "$S" <<'PY' || fail "deploy script text"
import re
import sys

REQUIRED = [
    "HUGO_ENVIRONMENT=production",
    "HUGO_PARAMS_ENVIRONMENT=production",
    "EXPECT_ENV=production",
    "REQUIRE_NO_OWNER_TOKENS=1",
    'cp wrangler.production.jsonc "$stage/wrangler.jsonc"',
    "--project-name renegade-penguin-site-prod",
    "--branch main",
    "3.45.0",
]


def check(text):
    errors = []
    code = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )
    for want in REQUIRED:
        if want not in code:
            errors.append("missing " + want)
    # The dry-run printout mentions every step first, so order is judged on the last occurrence
    # of the check and the deploy (the real commands) and on the real, quoted build call.
    # The real output check (the last line naming check-output.sh) must set both opt-in gates.
    check_lines = [ln for ln in code.splitlines() if "scripts/check-output.sh" in ln]
    if not check_lines:
        errors.append("no check-output invocation")
    else:
        for gate in ("REQUIRE_OWNER_APPROVAL=1", "REQUIRE_NO_OWNER_TOKENS=1"):
            if gate not in check_lines[-1]:
                errors.append("the output check must set " + gate)
    check_at = code.rfind("scripts/check-output.sh")
    deploy_at = code.rfind("pages deploy")
    if check_at < 0 or deploy_at < 0 or check_at > deploy_at:
        errors.append("check-output must run before the deploy")
    version_at = code.find("sort -V")
    build_at = code.find('"$HUGO" --minify')
    if version_at < 0 or build_at < 0 or version_at > build_at:
        errors.append("the wrangler version check must run before the build")
    if "--config" in code:
        errors.append("deploy must not rely on --config (copy the file as wrangler.jsonc)")
    if re.search(r"\|\|\s*true", code):
        errors.append("|| true found")
    if re.search(r"--(api-)?token|CLOUDFLARE_API_TOKEN=", code):
        errors.append("a token is placed on a command line")
    return errors


with open(sys.argv[1], encoding="utf-8") as fh:
    text = fh.read()
errors = check(text)
if errors:
    sys.exit("; ".join(errors))
head_part, gate_sep, tail_part = text.rpartition("REQUIRE_OWNER_APPROVAL=1 ")
last_gate_removed = head_part + tail_part
mutants = {
    "no production env": text.replace("EXPECT_ENV=production", "EXPECT_ENV=staging"),
    "owner approval off": text.replace("REQUIRE_OWNER_APPROVAL=1", "REQUIRE_OWNER_APPROVAL=0"),
    "owner approval missing on the real call": last_gate_removed,
    "owner tokens off": text.replace("REQUIRE_NO_OWNER_TOKENS=1", "REQUIRE_NO_OWNER_TOKENS=0"),
    "no staged config": text.replace('cp wrangler.production.jsonc "$stage/wrangler.jsonc"', "true"),
    "config flag": text + "\nwrangler pages deploy --config x\n",
    "no version check": text.replace("sort -V", "sort"),
    "old version floor": text.replace("3.45.0", "3.0.0"),
    "wrong project": text.replace("renegade-penguin-site-prod", "renegade-penguin-site"),
    "token in argv": text + "\nwrangler --token abc\n",
}
for label, mutant in mutants.items():
    if not check(mutant):
        sys.exit("negative case did not fail: " + label)
print("ok: deploy script text")
PY

# 4. The runbook.
python3 -I - docs/cutover.md <<'PY' || fail "docs/cutover.md"
import re
import sys

HEADINGS = [
    "Purpose and status",
    "Preconditions checklist",
    "Architecture decision",
    "Access plan for the owner's single approval",
    "Ordered steps",
    "Rollback",
    "Post-launch watch list",
]
COLUMNS = ["Action", "System", "Exact scope or permission", "Why", "Blast radius", "Rollback",
           "Read-only or write"]
# Strings the docs-verified runbook must carry (report 2026-11-19, issue #102).
REQUIRED_STRINGS = [
    "DOCS-VERIFIED",
    "UNDOCUMENTED",
    "Cloudflare Pages Edit",
    "DNS Write",
    "DNS Read",
    "Single Redirect Edit",
    "Dynamic URL Redirects Write",
    "Turnstile Read",
    "permission_groups",
    "3.45.0",
    "subdomain",
    "dig CAA",
    "same Cloudflare account",
    "static/_headers",
    "#106",
    "X-Robots-Tag",
    "branch config",
    "must never be removed",
    "clean staging directory",
    "managed robots.txt",
    "REQUIRE_OWNER_APPROVAL=1",
    "removing owner_review from the five files under content/guides",
    "layouts/home.robots.txt",
    "Claude-SearchBot",
    "ChatGPT-User",
    "GPTBot",
    "Google-Extended",
    "CCBot",
]
FORBIDDEN_STRINGS = [
    "leave it or remove only that record",
    "whether Cloudflare adds a noindex header on pages.dev",
    "preview deployments share",
]


def check(text):
    errors = []
    heads = re.findall(r"^#{1,3}\s+(.*?)\s*$", text, re.M)
    for want in HEADINGS:
        if not any(h.startswith(want) for h in heads):
            errors.append("missing heading: " + want)
    header = "| " + " | ".join(COLUMNS) + " |"
    if header not in text:
        errors.append("access plan table header missing")
    else:
        lines = text.splitlines()
        at = lines.index(header)
        body = []
        for ln in lines[at + 2:]:
            if not ln.startswith("| "):
                break
            if ln.count("|") == len(COLUMNS) + 1:
                body.append(ln)
        if len(body) < 8:
            errors.append("access plan table has fewer than 8 rows")
    if "REPO-VERIFIED" not in text:
        errors.append("REPO-VERIFIED missing")
    if "UNVERIFIED-NEEDS-DOCS" not in text:
        errors.append("UNVERIFIED-NEEDS-DOCS missing")
    for want in REQUIRED_STRINGS:
        if want not in text:
            errors.append("missing string: " + want)
    for bad in FORBIDDEN_STRINGS:
        if bad in text:
            errors.append("stale text present: " + bad)
    marker = "## Rollback"
    if marker in text:
        section = text.split(marker, 1)[1]
        cname_at = section.find("Delete the apex CNAME")
        domain_at = section.find("Remove the custom domain")
        if cname_at < 0 or domain_at < 0 or cname_at > domain_at:
            errors.append("rollback must delete the apex CNAME before removing the custom domain")
    if "NOT APPLIED" not in text:
        errors.append("NOT APPLIED status missing")
    if "renegade-penguin-site-prod" not in text:
        errors.append("proposed project name missing")
    return errors


with open(sys.argv[1], encoding="utf-8") as fh:
    text = fh.read()
errors = check(text)
if errors:
    sys.exit("; ".join(errors))
mutants = {
    "heading": text.replace("## Rollback", "## Undo"),
    "table": text.replace("| Blast radius |", "| Radius |"),
    "marker": text.replace("UNVERIFIED-NEEDS-DOCS", "TBD"),
    "status": text.replace("NOT APPLIED", "APPLIED"),
    "permission name": text.replace("Dynamic URL Redirects Write", "redirect edit"),
    "stale removal text": text + "\nleave it or remove only that record\n",
    "rollback order": text.replace("Delete the apex CNAME", "Zz", 1).replace("Remove the custom domain", "Delete the apex CNAME", 1),
    "version floor": text.replace("3.45.0", "3.0.0"),
}
for label, mutant in mutants.items():
    if not check(mutant):
        sys.exit("negative case did not fail: " + label)
print("ok: docs/cutover.md")
PY

# 5. No token-looking string and no em or en dash in the files of this change.
python3 -I - <<'PY' || fail "secret and dash scan"
import re
import sys

FILES = [
    "docs/cutover.md",
    "wrangler.production.jsonc",
    "scripts/deploy-production.sh",
    "scripts/test-cutover-prep.sh",
    "scripts/test-pages-config.sh",
]
PATTERNS = [
    re.compile("(?:ghp|gho|ghs|ghu)_[A-Za-z0-9]{20,}"),
    re.compile("github_pat_[A-Za-z0-9_]{20,}"),
    re.compile("AKIA[0-9A-Z]{16}"),
    re.compile("xox[baprs]-[A-Za-z0-9-]{10,}"),
    re.compile("-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile("dp\\.(?:st|sa|ct|pt)\\.[A-Za-z0-9]{20,}"),
]
LONG = re.compile("[A-Za-z0-9_-]{32,}")
DASHES = (chr(0x2014), chr(0x2013))


def scan(name, text):
    errors = []
    for pat in PATTERNS:
        if pat.search(text):
            errors.append(name + ": token pattern " + pat.pattern)
    for word in LONG.findall(text):
        if re.search("[0-9]", word) and re.search("[A-Za-z]", word):
            errors.append(name + ": long mixed word (token-looking)")
    for dash in DASHES:
        if dash in text:
            errors.append(name + ": em or en dash")
    return errors


errors = []
for name in FILES:
    try:
        with open(name, encoding="utf-8") as fh:
            errors += scan(name, fh.read())
    except OSError as exc:
        errors.append("cannot read %s: %s" % (name, exc))
if errors:
    sys.exit("; ".join(errors))
# Negative cases, built at run time so this file stays clean.
samples = {
    "github token": "ghp" + "_" + "A1" * 15,
    "aws key": "AKIA" + "ABCDEFGH12345678",
    "private key": "-----BEGIN " + "RSA PRIVATE KEY-----",
    "long mixed word": "a1" * 20,
    "em dash": "x " + chr(0x2014) + " y",
    "en dash": "x " + chr(0x2013) + " y",
}
for label, sample in samples.items():
    if not scan("sample", sample):
        sys.exit("negative case did not fail: " + label)
print("ok: no token-looking strings or dashes")
PY

echo "ok: cutover prep"
