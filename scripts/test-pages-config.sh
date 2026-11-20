#!/usr/bin/env bash
# Test for the Pages project configs. Two files are checked:
#   wrangler.jsonc             the live (staging) config: binds the mail Worker, carries exactly the
#                              staging vars, holds no secrets.
#   wrangler.production.jsonc  the PROPOSED production config (issue #102, not applied): a separate
#                              Pages project, the same binding, exactly the allowed vars with the
#                              apex hostname, holds no secrets.
# The var values are pinned here on purpose: changing them requires editing this test, so it is a
# deliberate change. wrangler reads wrangler.jsonc by default; the production file is used only with
# an explicit --config (scripts/deploy-production.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -I - <<'PY'
import json
import re
import sys

MAIL = "noreply@renegadepenguinllc.com"
STAGING = {
    "file": "wrangler.jsonc",
    "name": "renegade-penguin-site",
    "vars": {"EXPECTED_HOSTNAME": "staging.renegadepenguinllc.com", "MAIL_FROM": MAIL},
}
PRODUCTION = {
    "file": "wrangler.production.jsonc",
    "name": "renegade-penguin-site-prod",
    "vars": {"EXPECTED_HOSTNAME": "renegadepenguinllc.com", "MAIL_FROM": MAIL},
}
ALLOWED_KEYS = {"name", "pages_build_output_dir", "compatibility_date", "vars", "services"}
SECRET_WORDS = re.compile(r"secret|token|password|api_key", re.I)


def parse(raw):
    # Strip whole-line // comments (the files have no URLs or // inside strings).
    text = "\n".join(re.sub(r"^\s*//.*$", "", line) for line in raw.splitlines())
    return json.loads(text)


def check(cfg, spec):
    errors = []
    if cfg.get("name") != spec["name"]:
        errors.append("name must be %r" % spec["name"])
    if cfg.get("pages_build_output_dir") != "./public":
        errors.append("pages_build_output_dir must be ./public")
    if not cfg.get("compatibility_date"):
        errors.append("missing compatibility_date")
    for key in cfg:
        if key not in ALLOWED_KEYS:
            errors.append("unexpected top-level key: " + key)
    services = cfg.get("services", [])
    if services != [{"binding": "MAIL_WORKER", "service": "renegade-penguin-mail"}]:
        errors.append("services must bind only MAIL_WORKER to renegade-penguin-mail")
    variables = cfg.get("vars", {})
    for key in variables:
        if key not in spec["vars"]:
            errors.append("unexpected var: " + key)
    for key, want in spec["vars"].items():
        if variables.get(key) != want:
            errors.append(
                "var %s must equal %r (changing it requires editing this test)" % (key, want)
            )
    for key in variables:
        if SECRET_WORDS.search(key):
            errors.append("secret-looking var name: " + key)
    return errors


def load(spec):
    try:
        with open(spec["file"], encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        sys.exit("FAIL: cannot read %s: %s" % (spec["file"], exc))
    try:
        return raw, parse(raw)
    except ValueError as exc:
        sys.exit("FAIL: %s does not parse: %s" % (spec["file"], exc))


def clone(cfg):
    return json.loads(json.dumps(cfg))


loaded = {}
for spec in (STAGING, PRODUCTION):
    raw, cfg = load(spec)
    errors = check(cfg, spec)
    if errors:
        sys.exit("FAIL: %s: %s" % (spec["file"], "; ".join(errors)))
    loaded[spec["file"]] = (raw, cfg)

# The two files must not be interchangeable.
stg_cfg = loaded[STAGING["file"]][1]
prod_cfg = loaded[PRODUCTION["file"]][1]
if stg_cfg["name"] == prod_cfg["name"]:
    sys.exit("FAIL: staging and production configs share a project name")
if stg_cfg["vars"]["EXPECTED_HOSTNAME"] == prod_cfg["vars"]["EXPECTED_HOSTNAME"]:
    sys.exit("FAIL: staging and production configs share EXPECTED_HOSTNAME")

# The production file says in its header that it is a proposal and not the live config.
prod_raw = loaded[PRODUCTION["file"]][0]
head = "\n".join(prod_raw.splitlines()[:12]).lower()
if "proposal" not in head or "--config" not in head:
    sys.exit("FAIL: wrangler.production.jsonc header must say it is a proposal used only with --config")

# Negative cases: every check must bite, for both files.
for spec, cfg in ((STAGING, stg_cfg), (PRODUCTION, prod_cfg)):
    cases = {}
    extra = clone(cfg)
    extra["vars"]["TURNSTILE_SECRET"] = "x"
    cases["extra var"] = extra
    host = clone(cfg)
    host["vars"]["EXPECTED_HOSTNAME"] = "other.example"
    cases["changed hostname"] = host
    service = clone(cfg)
    service["services"] = []
    cases["missing service binding"] = service
    name = clone(cfg)
    name["name"] = "renegade-penguin-other"
    cases["changed project name"] = name
    key = clone(cfg)
    key["account_id"] = "x"
    cases["extra top-level key"] = key
    for label, case in cases.items():
        if not check(case, spec):
            sys.exit("FAIL: negative case did not fail: %s (%s)" % (label, spec["file"]))
# Staging values must not pass as production and the reverse.
if not check(stg_cfg, PRODUCTION):
    sys.exit("FAIL: staging config passed the production allowlist")
if not check(prod_cfg, STAGING):
    sys.exit("FAIL: production config passed the staging allowlist")

print("ok: wrangler.jsonc and wrangler.production.jsonc")
PY
