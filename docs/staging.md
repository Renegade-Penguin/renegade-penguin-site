# Staging setup scripts

These scripts build the staging environment for the site with the Cloudflare
API. They never touch the production hostname (`renegadepenguinllc.com` itself
is only listed as an allowed Turnstile domain; no Pages domain, DNS record or
rule is created or changed for it). Nothing here uses the dashboard.

## Behavior

- Dry run by default. Reads (GET) run so the script can tell what exists; every
  write is printed as `WOULD <method> <path>` and not sent. Pass `--apply` to
  perform the writes.
- Idempotent: re-running changes nothing that already exists.
- The token is read from `CLOUDFLARE_API_TOKEN` only, moved into a private
  non-exported variable (the exported one is unset at once, so child processes
  never inherit it), and handed to curl through a stdin config, never argv. It
  is never printed.
- Every script refuses to run (exit 1) if shell tracing (`bash -x`,
  `SHELLOPTS=xtrace`) is on, so credentials cannot be traced.
- The token is captured into the private variable in the first lines of each
  script, before any external command or command substitution.
- A call succeeds only on a 2xx status and a body that is exactly one JSON
  object with `success: true`; anything else (malformed JSON, several
  concatenated documents, an array) is a failure.
- Private variables (`CF_TOKEN_PRIVATE`, `RESP_PRIVATE`, `CF_BODY`, ...) are
  unset before they are assigned, so a value exported by the caller can never
  leave them exported to child processes.
- NUL guard, without a file: curl reports the bytes it downloaded
  (`size_download`) and the script compares that with the byte length
  (`LC_ALL=C`) of what the shell captured. Command substitution drops NUL
  bytes, so a body containing one is rejected before the envelope check and
  before anything reaches Doppler.
- Invalid UTF-8 inside a JSON string is ACCEPTED: jq replaces the bad bytes
  with U+FFFD and parses the document. It is only an issue if the bad bytes are
  inside the widget secret itself, which would then be stored altered; real
  Turnstile secrets are plain ASCII.

## Required environment

| Variable | Needed by |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | all |
| `CLOUDFLARE_ACCOUNT_ID` | all |
| `CLOUDFLARE_ZONE_ID` | `attach-staging-domain.sh`, `ensure-rate-limit.sh` |

`ensure-turnstile.sh` also needs a logged-in `doppler` CLI with write access to
project `no-php-no-cry`, config `dev_renegadepenguin`.

## Order to run

Run each in dry run first, read the output, then re-run with `--apply`.

1. `scripts/staging/ensure-pages-project.sh` creates the Pages project
   `renegade-penguin-site` (production branch `main`) if it is missing.
2. `scripts/staging/attach-staging-domain.sh` attaches
   `staging.renegadepenguinllc.com`, creates the proxied CNAME `staging` to
   `renegade-penguin-site.pages.dev` (the API does not create it, and the
   domain stays pending without it), PATCHes to retry validation, and succeeds
   only when the domain reads `active`. Exit 2 means still pending; re-run it.
3. `scripts/staging/ensure-turnstile.sh` creates the managed Turnstile widget
   `renegade-penguin-contact` for the staging and apex hostnames. It prints
   only the sitekey. The secret goes to Doppler on stdin only
   (`doppler secrets set TURNSTILE_SECRET_KEY --project no-php-no-cry --config dev_renegadepenguin`);
   it is never written to a file, exported, put in argv or printed, and
   Doppler's output is discarded. Nothing is sent to Doppler unless the HTTP
   status is 2xx and the body is exactly one JSON object with `success: true`.
   Because curl reports the status only after the body, the response is held in
   one private, non-exported shell variable from curl's exit until the Doppler
   call returns, and unset immediately; a pure stream could not gate delivery on
   the status. Before creating, it reads the Doppler config metadata and stops
   if that fails. If the widget is created but storing the secret fails, it
   prints the sitekey and the recovery step (delete or rotate that widget) and
   exits non-zero. Cloudflare returns the secret only at creation, so an
   existing widget is reported and the secret is not re-sent. Note: the
   preflight confirms the config is readable; write permission cannot be
   checked without writing, so a write failure is caught only by the recovery
   path above.
4. `scripts/staging/ensure-rate-limit.sh` adds one rate-limit rule to the zone
   (phase `http_ratelimit`): POST `/api/contact`, 5 per 10 minutes per IP,
   block for 10 minutes. It never replaces the ruleset. It reads the phase
   entrypoint first: if the ruleset exists it POSTs only this one rule to that
   ruleset's rules endpoint (an identical rule already present is skipped; a
   rule with the same ref but different content stops the script); the ruleset
   is created, with just this rule, only if none exists. Which periods and timeouts are allowed
   depends on the Cloudflare plan; if the API rejects the values the script
   stops with the error and changes nothing.

## Residual risk

A caller who controls the shell environment before launch (for example `PS4`,
`SHELLOPTS` or `BASH_XTRACEFD`) can expose an environment-delivered token.
Launch these scripts only from your own trusted shell. The xtrace refusal
protects against accidental tracing only; it is not a defense against a hostile
launch environment.

## Tests

Mocked, no network (a fake `curl`, `jq` and `doppler` go first on PATH; they
fail the test if the token or widget secret appears in their environment or in
any file under the script's temp dir):

```
for t in scripts/staging/test-*.sh; do [ "$t" = scripts/staging/test-lib.sh ] || bash "$t"; done
```
