#!/usr/bin/env bash
# Test for the Pages project config: wrangler.jsonc at the repo root must bind the
# mail Worker and carry staging vars, and must hold no secrets.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -I - <<'PY'
import json
import re
import sys

try:
    with open("wrangler.jsonc", encoding="utf-8") as fh:
        raw = fh.read()
except OSError as exc:
    sys.exit("FAIL: cannot read wrangler.jsonc: %s" % exc)

# Strip whole-line // comments (the file has no URLs or // inside strings).
text = "\n".join(re.sub(r"^\s*//.*$", "", line) for line in raw.splitlines())
try:
    cfg = json.loads(text)
except ValueError as exc:
    sys.exit("FAIL: wrangler.jsonc does not parse: %s" % exc)

errors = []
if not cfg.get("name"):
    errors.append("missing name")
if not cfg.get("pages_build_output_dir"):
    errors.append("missing pages_build_output_dir")
services = cfg.get("services", [])
if {"binding": "MAIL_WORKER", "service": "renegade-penguin-mail"} not in services:
    errors.append("services must bind MAIL_WORKER to renegade-penguin-mail")
variables = cfg.get("vars", {})
for needed in ("EXPECTED_HOSTNAME", "MAIL_FROM"):
    if not variables.get(needed):
        errors.append("vars missing " + needed)
for name in variables:
    for bad in ("SECRET", "TOKEN", "KEY"):
        if bad in name.upper():
            errors.append("secret-looking var name: " + name)
if errors:
    sys.exit("FAIL: " + "; ".join(errors))
print("ok: wrangler.jsonc")
PY
