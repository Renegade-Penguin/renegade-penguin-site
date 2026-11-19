# Mail Worker

Status: built and tested, not deployed. Nothing in Cloudflare exists for it yet (issue #31).

## Why

Pages Functions do not list `send_email` as a supported binding (Cloudflare docs read 2026-11-19).
So the contact form mail goes through a small separate Worker that owns the `send_email` binding.
The Pages Function reaches it through a service binding.

```
browser -> Pages Function (functions/api/contact.js)
        -> functions/api/_mail.js  --MAIL_WORKER service binding-->  worker/mail/index.js
                                                                      --EMAIL send_email binding--> contact address
```

## Design

- `worker/mail/index.js` accepts only `POST` with JSON `{ subject, text, replyTo }`. Other methods
  get 405. Bad JSON, missing or non-string fields, over-length fields, a control, bidi, BOM,
  soft-hyphen or lone-surrogate character in `subject` or `replyTo`, or a `replyTo` that is not one
  email address get 400.
- Limits: subject 200, replyTo 200, text 20000 characters.
- The recipient is fixed in code and in the binding (`destination_address`), so a request cannot
  change it. The sender comes only from the Worker variable `MAIL_FROM`.
- Responses are fixed short strings (`ok`, `bad request`, `method not allowed`, `send failed`). A
  send failure is a generic 502. Request content and error details are never echoed or logged.
- `wrangler.jsonc` sets no routes, `workers_dev` false and `preview_urls` false, so the Worker has
  no public address. Only a service binding can call it.
- `hasControlChars` is copied from `functions/api/_mail.js`. The two copies must stay identical;
  `worker/mail/test/mail.test.js` fails if they diverge.

## Binding names

| Where | Name | Kind |
| --- | --- | --- |
| Mail Worker | `EMAIL` | `send_email` binding, destination pinned to the contact address |
| Mail Worker | `MAIL_FROM` | plain variable; the placeholder in `wrangler.jsonc` must be replaced with the real sender |
| Pages project | `MAIL_WORKER` | service binding to `renegade-penguin-mail` |
| Pages project | `MAIL_FROM` | plain variable, checked by the adapter for control characters |
| Mail Worker | `MAIL_SHARED_SECRET` | encrypted secret; the Worker requires header `x-mail-auth` to equal it |
| Pages project | `MAIL_SHARED_SECRET` | encrypted secret; the adapter sends it as `x-mail-auth` |

## Shared secret

`MAIL_SHARED_SECRET` is a Doppler-managed secret set as an encrypted secret on both sides: the
Worker and the Pages project. Rotate each side independently (set the new value on both, then
redeploy). Never put it in the repository or in wrangler `vars`. The Worker compares in constant
time before reading the body, and fails closed with 401 when it is unset or empty. The adapter
refuses to send without it. Other Worker checks: `Content-Type` must be `application/json` (415),
the body is read incrementally and capped at 61200 bytes (413), and every direction-control
character (U+061C, U+200E, U+200F and the embeddings, overrides and isolates) is rejected in
`subject` and `replyTo`.

## Not done yet

- Deploying the Worker, onboarding the sender domain to Cloudflare Email Service, and adding the
  `MAIL_WORKER` service binding to the Pages project.
- Verifying the whole path in staging (issue #5).
- Running `node --test worker/mail/test/mail.test.js` in CI (the CI job lists only the functions
  test today).

## Tests

```
node --test worker/mail/test/mail.test.js
node --test functions/test/contact.test.js
```
