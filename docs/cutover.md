# Production cutover runbook (apex renegadepenguinllc.com)

Issue: Renegade-Penguin/renegade-penguin-site#102. This file is the plan; scripts and config for it
are in this change. Nothing here has been run.

How to read the markers. `REPO-VERIFIED (file)` means the fact is stated or enforced by a file in
this repository, named in the parentheses. `UNVERIFIED-NEEDS-DOCS` means it depends on Cloudflare
(or another vendor) behavior that this repository cannot confirm; check the vendor documentation
before the step is run. A step that carries neither marker is a local action with no vendor
behavior in it.

## Purpose and status

Status: NOT APPLIED. No project, secret, domain, DNS record, rule, token or Doppler config has been
created or changed by this change. The files added are a proposal:

| File | Role |
| --- | --- |
| `docs/cutover.md` | this runbook and the access plan |
| `wrangler.production.jsonc` | proposed config of the production Pages project; used only with an explicit `--config` |
| `scripts/deploy-production.sh` | dry run by default; `--apply` is refused without the owner's approval and real scrub terms |
| `scripts/test-cutover-prep.sh` | static test of all of the above, no network |

Goal: serve the production build of the site at `https://renegadepenguinllc.com/`, indexable, with
the contact form working, without touching mail DNS records, and with a rollback that restores what
the apex serves today.

## Preconditions checklist

Every row must be checked off, with its evidence noted on #102, before step 1 of the ordered steps.

| # | Precondition | Owner | Verification command or evidence |
| --- | --- | --- | --- |
| 1 | Cloudflare Email Address Obfuscation is off for the zone. It rewrites addresses and injects a script, which the site CSP (`default-src 'none'`, REPO-VERIFIED static/_headers) would block. Dashboard location: UNVERIFIED-NEEDS-DOCS (Scrape Shield). | owner | `for p in / /contact/ /privacy/ /security-policy/; do curl -s "https://staging.renegadepenguinllc.com$p" \| grep -c 'cdn-cgi/l/email-protection'; done` prints only `0`. The zone setting is shared with the apex. |
| 2 | Real scrub terms supplied (#9). The CI list is a placeholder (REPO-VERIFIED .github/workflows/ci.yml). | owner | `test -s "$SCRUB_TERMS_FILE" && ! grep -q zz-ci-placeholder-term-zz "$SCRUB_TERMS_FILE" && echo ok` prints `ok`. The file stays outside the repository. |
| 3 | Production build gate green with the real terms and the owner-placeholder check on (REPO-VERIFIED scripts/check-output.sh). | owner or lead | `HUGO_PARAMS_TURNSTILESITEKEY=<public sitekey> hugo --minify --gc --destination public && EXPECT_ENV=production REQUIRE_NO_OWNER_TOKENS=1 SCRUB_TERMS_FILE="$SCRUB_TERMS_FILE" scripts/check-output.sh public` ends with `check-output: clean (production)`. |
| 4 | Accessibility pass decision (#91) made and recorded. | owner | `gh issue view 91 --repo Renegade-Penguin/renegade-penguin-site --comments` shows the decision (accept as is, or fix first). |
| 5 | Cross-links ready on chiefgyk3d.com: the text in `docs/cross-link-draft.md` and a pull request in the personal site repository that sets the business URL param to the apex, approved but not merged or deployed. | owner | `gh pr view <number> --repo <personal-site-repo>` shows approved, open. The draft itself says to publish only after cutover (REPO-VERIFIED docs/cross-link-draft.md). |
| 6 | Turnstile widget hostnames include the apex. | owner | The widget is created for the staging and apex hostnames (REPO-VERIFIED docs/staging.md, scripts/staging/lib.sh `CF_APEX_HOST`). Confirm with a dry run of `scripts/staging/ensure-turnstile.sh` (reads only); it reports the existing widget, or fails closed when the hostnames or mode differ. Needs token row 6 of the access plan. |
| 7 | Email Sending verified for the sender domain (#35), including a real send. | owner | A staging form submission arrives at the contact address with Reply-To set to the visitor (REPO-VERIFIED docs/mail-worker.md lists this as pending). |
| 8 | Counsel decision recorded. | owner | `gh issue view 102 --repo Renegade-Penguin/renegade-penguin-site --comments` shows the decision. |
| 9 | Snapshot of what the apex serves and holds in DNS today (needed for rollback; this repository does not say what it is). | owner | `dig +short renegadepenguinllc.com A AAAA CNAME` and a zone record export saved outside the repository. A dig of MX, TXT (SPF, DMARC) and the DKIM selector names saved too. |
| 10 | Owner confirms the project name `renegade-penguin-site-prod` and answers the open decisions below. | owner | A comment on #102. |
| 11 | The owner's single approval of the access plan below has been given in the owner's own words. | owner | Quote on #102. |

Open decisions for the owner (recommendation first): (a) project name `renegade-penguin-site-prod`
or another; (b) www: redirect to the apex (recommended) or no www; (c) Turnstile: reuse the existing
widget for the first launch (recommended, its hostnames already include the apex) or create a
production-only widget later and card it; (d) rotate `MAIL_SHARED_SECRET` during cutover (the
Worker and both Pages projects must then change together) or keep the current value.

## Architecture decision

Decision: a SECOND Pages project for the apex, proposed name `renegade-penguin-site-prod`
(a proposal; the owner confirms).

Why. Today the staging hostname is the custom domain of the existing project `renegade-penguin-site`
(REPO-VERIFIED docs/staging.md, scripts/staging/attach-staging-domain.sh) and that project serves the
noindex staging variant (params.environment = staging: a noindex meta on every page and a robots.txt
with `Disallow: /`, REPO-VERIFIED layouts/baseof.html, layouts/home.robots.txt). The variant is chosen
at build time, so one deployment serves one variant. Attaching the apex to the same project would
serve the noindex build at the apex. The staging project also carries `EXPECTED_HOSTNAME` for the
staging host (REPO-VERIFIED wrangler.jsonc): the Turnstile check in the Function compares the
hostname the widget reports with that variable (REPO-VERIFIED functions/api/contact.js), so one
project cannot serve both hostnames with one value.

With two projects staging keeps its noindex build and its own variables, and production gets the
indexable build, the apex value for `EXPECTED_HOSTNAME`, its own secrets and its own deployment
history, so a bad staging deploy cannot reach the apex.

Alternative considered: one project, with a branch per environment (the `main` production deployment
for the apex, a `staging` branch preview for the staging host). Rejected: preview deployments share
the project's production variables unless separate preview variables are kept in sync, the staging
host is already attached as the production custom domain of the existing project, and a branch
mistake would put the noindex build on the apex or the indexable build on staging. How Pages
treats variables and custom domains on preview deployments: UNVERIFIED-NEEDS-DOCS.

The mail Worker `renegade-penguin-mail` is shared by both projects and needs no change.
REPO-VERIFIED (worker/mail/wrangler.jsonc, worker/mail/index.js): no routes, `workers_dev` off,
`preview_urls` off, the recipient pinned in code and in the binding, the sender taken from its own
`MAIL_FROM`, and no reference to a hostname or origin. Callers are identified only by the shared
secret header, so the production project needs the same `MAIL_SHARED_SECRET` value the Worker holds
(docs/mail-worker.md).

Other facts REPO-VERIFIED: the canonical link of every page uses the Hugo `baseURL`, which is the
apex (hugo.toml), so staging pages already name the apex as canonical; the sitemap and its
`Sitemap:` line in the production robots.txt use the same base (layouts/home.robots.txt); the
rate-limit rule on `/api/contact` is zone wide and has no host clause
(scripts/staging/ensure-rate-limit.sh), so it covers the apex with no change. This repository has no
workflow that deploys to Pages (.github/workflows has only ci.yml), so how the staging project is
deployed today is not recorded here.

## Access plan for the owner's single approval

Principles: least privilege, ask once, and drop every write scope when the cutover is done. Before
the approval is requested the lead files a card for the cleanup ("drop cutover write scopes and
revoke the cutover tokens"), so the removal is tracked from the start. The list below is the union of
what the whole job needs; nothing broader is a fallback. Permission names for Cloudflare are
UNVERIFIED-NEEDS-DOCS until the lead checks the token-permission reference; the intent of each row is
what matters.

Doppler layout (the owner's standard: one project per product, environments dev and prd, configs
inside environments). Today the dev secrets live in project `no-php-no-cry`, config
`dev_renegadepenguin` (REPO-VERIFIED docs/staging.md). Proposal, created ONLY with the owner's
approval: a `prd` config for this product, named `prd_renegadepenguin`, holding the production
Cloudflare tokens as a rotated a/b pair (`CLOUDFLARE_API_TOKEN_A`, `CLOUDFLARE_API_TOKEN_B`), plus
`MAIL_SHARED_SECRET` and `TURNSTILE_SECRET_KEY`. The dev tokens are never reused for production. The
project name `no-php-no-cry` is the one the repository documents; whether production belongs in it
or in a dedicated project is the owner's call. Config naming and environment rules in Doppler:
UNVERIFIED-NEEDS-DOCS.

| Action | System | Exact scope or permission | Why | Blast radius | Rollback | Read-only or write |
| --- | --- | --- | --- | --- | --- | --- |
| Create the Pages project, deploy, set Pages secrets | Cloudflare API token (production, a/b pair) | Account level: Cloudflare Pages edit, on the one account | Steps 1 to 3 | Every Pages project in the account (a token cannot be narrowed to one project: UNVERIFIED-NEEDS-DOCS) | Delete the new project (no traffic yet) or revoke the token | write |
| Attach the apex custom domain | Cloudflare API token | Same Pages edit permission | Step 4 | The new project's domains only; the call names one hostname | Detach the domain (rollback section) | write |
| Create the apex CNAME and the optional www record | Cloudflare API token | Zone level: DNS edit, restricted to the zone renegadepenguinllc.com | Step 5 and step 6 | Every record in the zone, including MX, SPF, DKIM and DMARC (record types cannot be excluded: UNVERIFIED-NEEDS-DOCS); limited by procedure: one named record created, a before and after export diffed, mail records never named | Delete the created record, restore the exported previous apex records | write |
| Read the current DNS records for the snapshot and the diff | Cloudflare API token | Zone level: DNS read, same zone | Precondition 9, steps 5 and 9 | None, read only | none needed | read-only |
| Create the www redirect (optional) | Cloudflare API token | Zone level: dynamic redirect rules edit, same zone (permission name UNVERIFIED-NEEDS-DOCS) | Step 6 | The zone's redirect ruleset; it may share a permission group with other rulesets such as the rate-limit rule (UNVERIFIED-NEEDS-DOCS) | Delete the one rule | write |
| Read the Turnstile widget configuration | Cloudflare API token | Account level: Turnstile read (UNVERIFIED-NEEDS-DOCS) | Precondition 6 | None, read only | none needed | read-only |
| Create the production config in Doppler | Doppler | Project `no-php-no-cry`, environment prd, create one config (proposed name `prd_renegadepenguin`); owner approval required | Holds the production tokens and secrets apart from dev | The new config only | Delete the config | write |
| Store the production token pair and the two secrets in that config | Doppler | Write to that one config only; values are set by the owner on stdin with output discarded (`> /dev/null`) | Step 1 and step 2 sources | That config only | Delete the entries, revoke the tokens | write |
| Read the production secrets at deploy time | Doppler | A read-only service token scoped to that one config | Steps 2 and 3 | The two secrets and the token pair in that config | Revoke the service token | read-only |
| Set `MAIL_SHARED_SECRET` and `TURNSTILE_SECRET` on the new Pages project | Cloudflare Pages secrets | Uses the Pages edit permission above; values piped from Doppler on stdin, never in argv | The Function needs both to run | The new project only | Delete the two secrets | write |
| Service binding `MAIL_WORKER` to the existing Worker | Cloudflare Pages deploy | Declared in `wrangler.production.jsonc`; no Workers edit scope is needed because the Worker is not changed (REPO-VERIFIED above); the deploy permission needed to bind a service is UNVERIFIED-NEEDS-DOCS | The form mail path | None to the Worker | Redeploy without the binding, or delete the project | write |
| Search Console and Bing verification and sitemap submit | Owner's own search accounts, dashboard | The owner's login; a DNS TXT record at the apex may be used and then falls under the DNS edit row | Step 9 | None beyond one TXT record | Remove the property or the record | write |
| Cross-link change in the personal site repository and the pin change in its private pipeline | GitHub, owner action | The owner's own access; no token from this plan | Step 10 | The personal site only | Revert the commit | write |
| Post-deploy and smoke checks | Public HTTP | No credentials, plain GET requests and one form submission | Steps 3 and 8 | One test message in the contact inbox | none needed | read-only |

Token handling: wrangler and curl read the token from the environment only; no script in this change
accepts or prints a token (`scripts/deploy-production.sh` accepts only `--dry-run` or `--apply`).
Tokens are rotated as an a/b pair in the prd config; the pair is never the dev pair. After the
cutover: revoke the write tokens and drop their scopes (the cardable cleanup above), keep at most a
read-only token if monitoring needs it.

## Ordered steps

Run in this order. Each step names who runs it, the command or path, the expected result, how to
verify, and the rollback. `<account>` and `<zone>` are the Cloudflare identifiers, kept out of the
repository.

### 1. Create the production Pages project

- Who: owner, with the token from the access plan.
- Command: a POST to `/accounts/<account>/pages/projects` with `{"name": "renegade-penguin-site-prod", "production_branch": "main"}`
  (REPO-VERIFIED: that is the call `scripts/staging/ensure-pages-project.sh` makes; the script itself
  has the staging project name fixed in `scripts/staging/lib.sh` and cannot be reused unchanged).
  Alternative: `wrangler pages project create renegade-penguin-site-prod --production-branch main`
  (UNVERIFIED-NEEDS-DOCS for the exact flags).
- Expected: the project exists with production branch `main` and no deployments.
- Verify: a GET on `/accounts/<account>/pages/projects/renegade-penguin-site-prod` returns
  `production_branch` `main`.
- Rollback: delete the project. No traffic can reach it yet.

### 2. Set production secrets and variables

- Who: owner.
- Variables: `EXPECTED_HOSTNAME` (the apex) and `MAIL_FROM` come from `wrangler.production.jsonc` at
  deploy time (REPO-VERIFIED: that is how the staging file works, functions/README.md; whether
  `pages deploy` applies a file passed with `--config` is UNVERIFIED-NEEDS-DOCS).
- Secrets, values from the Doppler prd config, piped on stdin, never in argv:
  `doppler secrets get MAIL_SHARED_SECRET --project no-php-no-cry --config prd_renegadepenguin --plain | wrangler pages secret put MAIL_SHARED_SECRET --project-name renegade-penguin-site-prod`
  and the same for `TURNSTILE_SECRET_KEY` into `TURNSTILE_SECRET` (the name mapping is REPO-VERIFIED
  in functions/README.md; the `wrangler pages secret put` syntax is UNVERIFIED-NEEDS-DOCS).
- Expected: both secrets listed on the project (names only).
- Verify: `wrangler pages secret list --project-name renegade-penguin-site-prod` shows both names
  (UNVERIFIED-NEEDS-DOCS).
- Rollback: delete the two secrets, or delete the project.

### 3. Deploy the production build to the pages.dev URL and check it there

- Who: owner (the script refuses without the owner's approval variable).
- Command: first the dry run, `scripts/deploy-production.sh`, then
  `OWNER_APPROVED_CUTOVER=yes SCRUB_TERMS_FILE=<real file> HUGO_PARAMS_TURNSTILESITEKEY=<public sitekey> scripts/deploy-production.sh --apply`
  with the token in the environment. It builds the production variant, runs `check-output.sh` with
  `EXPECT_ENV=production REQUIRE_NO_OWNER_TOKENS=1` and the real terms, checks the artifact, then runs
  `wrangler pages deploy public --config wrangler.production.jsonc --project-name renegade-penguin-site-prod --branch main`
  (REPO-VERIFIED scripts/deploy-production.sh; whether `pages deploy` honors `--config` is
  UNVERIFIED-NEEDS-DOCS, and if it does not, the script and the config change before this step).
- Expected: a deployment on `https://renegade-penguin-site-prod.pages.dev` (the name follows the
  project name; UNVERIFIED-NEEDS-DOCS for any suffix Cloudflare adds).
- Verify on that URL: `curl -s https://renegade-penguin-site-prod.pages.dev/robots.txt` has no
  `Disallow: /` and has a `Sitemap:` line; the home page HTML has no `noindex`; `/sitemap.xml`
  returns 200; response headers on `/` and `/contact/` match `static/_headers` (CSP, HSTS, nosniff);
  `/.well-known/security.txt` returns 200; no `email-protection` string in any page; a missing path
  returns the site's 404 page. The contact form cannot be completed here: the widget hostnames do
  not include the pages.dev name (REPO-VERIFIED docs/staging.md lists staging and apex only), so the
  Turnstile check would fail by design. The pages.dev URL serves the indexable build with apex
  canonical links; whether Cloudflare adds a noindex header on pages.dev is UNVERIFIED-NEEDS-DOCS.
- Rollback: delete the deployment, or the project; the apex is untouched.

### 4. Attach the apex custom domain

- Who: owner.
- Command: a POST to `/accounts/<account>/pages/projects/renegade-penguin-site-prod/domains` with
  `{"name": "renegadepenguinllc.com"}` (REPO-VERIFIED shape: the staging attach script posts
  `{name: <host>}` to the same path pattern). It stays pending until DNS points at the project.
- Expected: the domain is listed on the project as pending.
- Verify: GET the same path; status `pending` (UNVERIFIED-NEEDS-DOCS for the status values on an apex).
- Rollback: DELETE the domain item (UNVERIFIED-NEEDS-DOCS) or remove it in the dashboard.

### 5. DNS for the apex

- Who: owner.
- Do first: compare the precondition 9 snapshot with a fresh export; note the ids of every record at
  the apex name that is an A, AAAA or CNAME.
- Command: create a proxied CNAME named `@` (the apex) with content `renegade-penguin-site-prod.pages.dev`
  (REPO-VERIFIED pattern: the staging CNAME is proxied with ttl 1 and points at the project's
  pages.dev name). Cloudflare flattens a CNAME at the apex; UNVERIFIED-NEEDS-DOCS for whether an
  existing apex A, AAAA or CNAME record must be removed first, and in what order, to avoid a gap.
- Leave untouched: every MX, SPF (TXT), DKIM and DMARC record. Nothing in this plan names or edits
  them.
- Expected: the domain on the Pages project turns `active`; HTTPS certificate issued (time:
  UNVERIFIED-NEEDS-DOCS).
- Verify: `curl -sI https://renegadepenguinllc.com/` returns 200 with the site's headers;
  `dig +short MX renegadepenguinllc.com` and the SPF, DKIM and DMARC TXT answers are identical to
  the precondition 9 snapshot (an exact diff, expected empty).
- Rollback: see the rollback section.

### 6. The www decision

- Who: owner decides; owner runs.
- Recommended: redirect `www.renegadepenguinllc.com` to the apex with one redirect rule (301, path
  and query preserved). A redirect rule only runs for traffic that reaches Cloudflare, so a proxied
  `www` DNS record must exist (UNVERIFIED-NEEDS-DOCS for the placeholder pattern). If a `www` record
  already exists, record it first and do not overwrite it.
- Alternative: no www at all; then no record and no rule are created.
- Verify: `curl -sI https://www.renegadepenguinllc.com/contact/` returns 301 with a `location` header
  of `https://renegadepenguinllc.com/contact/`.
- Rollback: delete the rule and the record created for it.

### 7. Switch Turnstile and EXPECTED_HOSTNAME

- Who: owner.
- What this means here: `EXPECTED_HOSTNAME` is already the apex in the production project because it
  is set by `wrangler.production.jsonc` in step 3; the staging project keeps the staging value
  (REPO-VERIFIED wrangler.jsonc). So there is no flip of a live value, only a check that the widget
  reports the apex. The production build must carry the sitekey of a widget whose hostnames include
  the apex (precondition 6).
- Verify: the contact page on the apex has the widget (`curl -s https://renegadepenguinllc.com/contact/ | grep -c cf-turnstile`
  prints a number above 0) and the staging contact page still works.
- Rollback: redeploy with the previous build; the staging project is unaffected.

### 8. Smoke test on the apex, including a real form submission

- Who: owner.
- Steps: open `https://renegadepenguinllc.com/contact/` in a browser, fill the form with an obvious
  test message, submit. Expected: a 303 to `/contact/thanks/`, and the mail arrives at the contact
  address with Reply-To set to the test address (REPO-VERIFIED functions/api/contact.js and
  worker/mail/index.js). Also check the browser console for CSP violations from the Turnstile iframe
  (REPO-VERIFIED functions/README.md and static/_headers say this has not been tested in a browser).
  Then submit again within 10 seconds a few times to see the rate-limit block (REPO-VERIFIED
  scripts/staging/ensure-rate-limit.sh: 5 POSTs per 10 seconds per data center per IP).
- Verify: the message is in the inbox; no error page; the Worker shows no failures.
- Rollback: the rollback section; if only mail fails, the form shows the fallback address page
  (REPO-VERIFIED functions/README.md, a 424 page with the fallback address).

### 9. Search engine steps

- Who: owner.
- Search Console: add the domain property and verify by DNS TXT, or by the HTML or meta method
  (the CSP and static build make the TXT record the simplest; UNVERIFIED-NEEDS-DOCS). A TXT record at
  the apex coexists with SPF and DMARC but is a DNS write: diff the mail records afterward.
- Bing Webmaster Tools: import the Search Console property, or verify separately (UNVERIFIED-NEEDS-DOCS).
- Submit `https://renegadepenguinllc.com/sitemap.xml` in both (REPO-VERIFIED: Hugo generates it and
  the production robots.txt points to it; the thank-you and 404 pages are excluded, scripts/test-trust.sh).
- Verify: both tools report the sitemap as read, with the page count close to the built page count.
- Rollback: remove the property or the sitemap; remove the TXT record.

### 10. chiefgyk3d.com cross-link switch

- Who: owner (personal site repository and its private pipeline).
- Steps: merge the personal repository pull request that sets the business URL param
  (`businessSiteURL`, name as given in the cutover brief, not visible in this repository) to
  `https://renegadepenguinllc.com/`; then change the pin in that site's private pipeline so the new
  build is deployed (owner action). Use the text in `docs/cross-link-draft.md`.
- Verify: `curl -s https://chiefgyk3d.com/ | grep -c renegadepenguinllc.com` is above 0 and the link
  returns 200. The business site already links back to `https://chiefgyk3d.com/` (REPO-VERIFIED
  scripts/check-output.sh `about_link` check).
- Rollback: revert the personal site commit.

### 11. Announce

- Who: owner. Public copy is written by the general model per the owner's rules, after steps 1 to 10
  are verified. Nothing is announced before the smoke test and the search steps are done.

## Rollback

What to undo, in this order, when the apex misbehaves after step 4 or 5:

1. Detach the apex custom domain from `renegade-penguin-site-prod` (API DELETE on the domain item or
   the dashboard; UNVERIFIED-NEEDS-DOCS).
2. Remove the apex CNAME created in step 5, and restore the apex A, AAAA or CNAME records saved in
   the precondition 9 snapshot, if any existed.
3. Mail records are never touched: MX, SPF, DKIM and DMARC were not edited in any step, and the final
   diff of step 5 proves it. If a Search Console TXT record was added, leave it or remove only that
   record.
4. Revert the personal site cross-link if step 10 was done, and remove the sitemap from the search
   tools.

How long: a DNS change on a proxied record is quick on Cloudflare, but the exact time (and the effect
of cached answers on resolvers and browsers) is UNVERIFIED-NEEDS-DOCS. The mail path does not depend
on this and keeps working throughout.

What the owner sees meanwhile: until the old records are restored, the apex may return a Cloudflare
error page or the previous content, depending on what step 5's snapshot shows was there (this
repository does not record it). The staging site and the staging form keep working at all times.

If only a bad deploy is the problem, roll back the deployment of the production project to the
previous one (UNVERIFIED-NEEDS-DOCS for the dashboard or API path) and leave the domain attached.

## Post-launch watch list

- Day 1: the contact form once an hour for the first day, then daily for a week; the inbox for the
  test message and for real ones; `/api/contact` error rate in the Pages project logs.
- Search: Search Console coverage and sitemap status after 2 days and again after a week; the
  apex robots.txt is still `Allow: /` (a regression to the staging variant would set `Disallow: /`).
- Certificate and domain status of the apex on the project: `active`.
- DNS: a weekly diff of the mail records against the snapshot for a month.
- Email: delivery of the form mail (SPF and DKIM alignment as seen in the received headers).
- Headers: `curl -sI` on `/` and `/contact/` still match `static/_headers`.
- Turnstile: the widget dashboard error count; any rise means a hostname or sitekey mismatch.
- Rate limit: blocked POST count on `/api/contact`.
- Cleanup: revoke the write tokens and drop the write scopes (the card filed before approval), then
  delete the Doppler service token if nothing else uses it.

## Tests

`scripts/test-cutover-prep.sh` (static, no network) checks that the production build is indexable
and the staging variant is not, that both wrangler configs obey their allowlists
(`scripts/test-pages-config.sh`), that `scripts/deploy-production.sh` is a dry run by default and
refuses `--apply` without approval and real scrub terms, and that this file keeps the sections, the
access plan table and the two markers. It runs in CI with the other site tests.
