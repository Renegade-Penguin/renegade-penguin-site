#!/usr/bin/env bash
# Test for the Pages project config: wrangler.jsonc at the repo root must bind the
# mail Worker and carry exactly the staging vars, and must hold no secrets.
# The var values are pinned here on purpose: changing them (the apex cutover, issue #7)
# requires editing this test, so it is a deliberate change.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -I - <<'PY'
import json
import re
import sys

ALLOWED_VARS = {
    "EXPECTED_HOSTNAME": "staging.renegadepenguinllc.com",
    "MAIL_FROM": "noreply@renegadepenguinllc.com",
}


def parse(raw):
    # Strip whole-line // comments (the file has no URLs or // inside strings).
    text = "\n".join(re.sub(r"^\s*//.*$", "", line) for line in raw.splitlines())
    return json.loads(text)


def check(cfg):
    errors = []
    if not cfg.get("name"):
        errors.append("missing name")
    if not cfg.get("pages_build_output_dir"):
        errors.append("missing pages_build_output_dir")
    services = cfg.get("services", [])
    if {"binding": "MAIL_WORKER", "service": "renegade-penguin-mail"} not in services:
        errors.append("services must bind MAIL_WORKER to renegade-penguin-mail")
    variables = cfg.get("vars", {})
    for key in variables:
        if key not in ALLOWED_VARS:
            errors.append("unexpected var: " + key)
    for key, want in ALLOWED_VARS.items():
        if variables.get(key) != want:
            errors.append(
                "var %s must equal %r (changing it requires editing this test)" % (key, want)
            )
    return errors


try:
    with open("wrangler.jsonc", encoding="utf-8") as fh:
        raw = fh.read()
except OSError as exc:
    sys.exit("FAIL: cannot read wrangler.jsonc: %s" % exc)
try:
    cfg = parse(raw)
except ValueError as exc:
    sys.exit("FAIL: wrangler.jsonc does not parse: %s" % exc)

errors = check(cfg)
if errors:
    sys.exit("FAIL: " + "; ".join(errors))

# Negative cases: the check must bite.
bad_extra = json.loads(json.dumps(cfg))
bad_extra["vars"]["TURNSTILE_SECRET"] = "x"
bad_host = json.loads(json.dumps(cfg))
bad_host["vars"]["EXPECTED_HOSTNAME"] = "renegadepenguinllc.com"
bad_service = json.loads(json.dumps(cfg))
bad_service["services"] = []
for label, case in (
    ("extra var", bad_extra),
    ("changed hostname", bad_host),
    ("missing service binding", bad_service),
):
    if not check(case):
        sys.exit("FAIL: negative case did not fail: " + label)

print("ok: wrangler.jsonc")
PY
