# Contact form Pages Function

`api/contact.js` handles `POST /api/contact` on the same origin as the site (Cloudflare Pages
Functions, no CORS, no separate Worker). `api/_mail.js` is the only module that touches the mail
binding. Issue #4 built it; issue #5 deploys and verifies it in staging.

What it does, in order: reject non-POST (405), reject a body over 20000 bytes (413), drop a
filled honeypot field `website` with a 303 to `/contact/thanks/` and no mail, validate and trim
the fields (400 with a plain message), verify the Turnstile token server side (400), send one
plain text mail with Reply-To set to the visitor (on failure a 424 HTML page with the fallback address, never a 5xx because Cloudflare replaces those with its own page, and no personal data in logs),
then 303 to `/contact/thanks/`.

## Required settings (names only; no values live in this repository)

| Name | Kind | Purpose |
| --- | --- | --- |
| `TURNSTILE_SECRET` | encrypted secret | Turnstile secret key for siteverify. From the secret manager dev environment. |
| `EXPECTED_HOSTNAME` | plain variable | Hostname Turnstile must report (the site host, or the staging host in staging). |
| `MAIL_FROM` | plain variable | Sender address on a domain onboarded to Cloudflare Email Service. |
| `MAIL_TO` | plain variable | Recipient. Optional; defaults to `contact@renegadepenguinllc.com`. Never taken from the form. |
| `MAIL_WORKER` | service binding | The mail Worker (`worker/mail`, see `docs/mail-worker.md`), called with `env.MAIL_WORKER.fetch`. |

The Turnstile sitekey is public and is not read here: it is the Hugo param
`params.turnstileSitekey` in `hugo.toml` (empty by default, set per environment with
`HUGO_PARAMS_TURNSTILESITEKEY`). With no sitekey the contact page builds without the widget and
without the Turnstile script, so a build without a key makes no third-party request, and the
form shows only the no-JavaScript fallback in the page copy.

## Deployment state

The mail Worker is deployed. `MAIL_SHARED_SECRET` (Worker and Pages) and `TURNSTILE_SECRET` (Pages;
Doppler name `TURNSTILE_SECRET_KEY`) are set from Doppler dev. The `MAIL_WORKER` binding and the
`EXPECTED_HOSTNAME` and `MAIL_FROM` variables come from `wrangler.jsonc` at the repo root, which is
the source of truth for them (they cannot be edited in the dashboard). Email Sending onboarding of
the domain is the remaining dashboard step (issue #35).

## Unverified

The exact Email Service binding call has not been confirmed to work from a Pages Function. Confirm
it in staging (issue #5). If it does not, only `api/_mail.js` changes. The live Turnstile widget has
not been tested in a browser against the contact route CSP in `static/_headers`; `style-src` may
need adjusting once it is.

## Tests

```
node --test functions/test/contact.test.js
```

Node 20 or newer, no install. The tests pass fakes for fetch and the mail adapter; nothing leaves
the machine.
