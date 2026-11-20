# Production cutover runbook (apex renegadepenguinllc.com)

Issue: Renegade-Penguin/renegade-penguin-site#102. This file is the plan; scripts and config for it
are in this change. Nothing here has been run.

How to read the markers.

- `REPO-VERIFIED (file)`: stated or enforced by a file in this repository.
- `DOCS-VERIFIED 2026-11-19 [label]`: confirmed in the vendor documentation read on 2026-11-19; the
  label names a row of the Sources table at the end of this file.
- `UNDOCUMENTED`: the documentation is silent or ambiguous. Each such item carries an explicit
  mitigation step, so the step is safe without the answer.
- `UNVERIFIED-NEEDS-DOCS`: not yet checked at all (one item remains, precondition 1).

A step that carries no marker is a local action with no vendor behavior in it.

## Purpose and status

Status: NOT APPLIED. No project, secret, domain, DNS record, rule, token or Doppler config has been
created or changed by this change. The files added are a proposal:

| File | Role |
| --- | --- |
| `docs/cutover.md` | this runbook and the access plan |
| `wrangler.production.jsonc` | proposed config of the production Pages project; copied as `wrangler.jsonc` into a clean staging directory by the deploy script |
| `scripts/deploy-production.sh` | dry run by default; `--apply` is refused without the owner's approval, real scrub terms and Wrangler 3.45.0 or newer |
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
| 6 | Turnstile widget hostnames include the apex. | owner | The widget is created for the staging and apex hostnames (REPO-VERIFIED docs/staging.md, scripts/staging/lib.sh `CF_APEX_HOST`). Confirm with a dry run of `scripts/staging/ensure-turnstile.sh` (reads only); it reports the existing widget, or fails closed when the hostnames or mode differ. Needs the Turnstile read token row of the access plan. |
| 7 | Email Sending verified for the sender domain (#35), including a real send. | owner | A staging form submission arrives at the contact address with Reply-To set to the visitor (REPO-VERIFIED docs/mail-worker.md lists this as pending). |
| 8 | Counsel decision recorded. | owner | `gh issue view 102 --repo Renegade-Penguin/renegade-penguin-site --comments` shows the decision. |
| 9 | Snapshot of what the apex serves and holds in DNS today, needed for rollback (this repository does not say what it is), and a CAA check. | owner | `dig +short renegadepenguinllc.com A AAAA CNAME` and a zone record export saved outside the repository; `dig MX`, `dig TXT` (SPF, DMARC) and the DKIM selector names saved too. `dig CAA renegadepenguinllc.com`: if any CAA record exists it must allow Cloudflare's certificate authorities (the custom domains page lists letsencrypt.org, pki.goog and ssl.com; DOCS-VERIFIED 2026-11-19 [custom-domains]), otherwise the apex certificate is blocked. |
| 10 | Owner confirms the project name `renegade-penguin-site-prod` and answers the open decisions below. Project names start with a lowercase letter or digit and hold only lowercase letters, digits and hyphens (DOCS-VERIFIED 2026-11-19 [project-api]). | owner | A comment on #102. |
| 11 | The owner's single approval of the access plan below has been given in the owner's own words. | owner | Quote on #102. |
| 12 | The zone renegadepenguinllc.com is active in the same Cloudflare account as the new Pages project. A custom domain must be a zone on the account that holds the project, and a CNAME to a different account is blocked with error 1014 (DOCS-VERIFIED 2026-11-19 [custom-domains], [cname-flat]). | owner | A GET on the zone shows `status` active and the same account id as the project. |
| 13 | Issue #106 is merged: `static/_headers` carries the `X-Robots-Tag: noindex` rules for the pages.dev hosts (see step 3). That file change is a separate issue handled by another agent; this runbook only depends on it. | owner or lead | `grep -c 'X-Robots-Tag: noindex' static/_headers` is at least 2 on main, and the two pages.dev rules are present. |

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
for the apex, a `staging` branch preview for the staging host). Rejected, for these reasons:

- Pages does not support branch-based configuration. The dashboard keeps separate production and
  preview variable sets, so previews do not share production variables there; but once a config
  file is used, its top-level `vars` and `services` apply to production and preview alike and can
  differ only through an `env.preview` block per project, not per branch (DOCS-VERIFIED 2026-11-19
  [bindings], [wr-config]). A single project therefore cannot give staging and the apex different
  `EXPECTED_HOSTNAME` values by branch.
- The staging host is already attached as the production custom domain of the existing project, and
  a custom domain on a preview needs a branch alias with proxied records (DOCS-VERIFIED 2026-11-19
  [previews], [custom-domains]).
- A branch mistake would put the noindex build on the apex or the indexable build on staging.

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
what the whole job needs; nothing broader is a fallback.

Permission names come from the Cloudflare permissions reference (DOCS-VERIFIED 2026-11-19
[perm]). That page lists two names for some groups; the dashboard label and the API group name may
differ. Before approval, confirm the Single Redirect and Turnstile groups against the live list with
`GET /user/tokens/permission_groups` and use the names it returns.

Doppler layout (the owner's standard: one project per product, environments dev and prd, configs
inside environments). Today the dev secrets live in project `no-php-no-cry`, config
`dev_renegadepenguin` (REPO-VERIFIED docs/staging.md). Proposal, created ONLY with the owner's
approval: a branch config of the `prd` root config, named `prd_renegadepenguin`, next to
`dev_renegadepenguin` in the same project (DOCS-VERIFIED 2026-11-19 [doppler-branch]). It holds the
production Cloudflare tokens as a rotated a/b pair (`CLOUDFLARE_API_TOKEN_A`,
`CLOUDFLARE_API_TOKEN_B`), plus `MAIL_SHARED_SECRET` and `TURNSTILE_SECRET_KEY`; values shared by
production configs go in the `prd` root and per-use values in the branch. The dev tokens are never
reused for production. The project name `no-php-no-cry` is the one the repository documents;
whether production belongs in it or in a dedicated project is the owner's call.

| Action | System | Exact scope or permission | Why | Blast radius | Rollback | Read-only or write |
| --- | --- | --- | --- | --- | --- | --- |
| Create the Pages project, deploy, set Pages secrets | Cloudflare API token (production, a/b pair) | Account level: Cloudflare Pages Edit (the Write-named table calls it Pages Write), on the one account | Steps 1 to 3 | Every Pages project in the account; no per-project scope is documented | Delete the new project (no traffic yet) or revoke the token | write |
| Attach the apex custom domain | Cloudflare API token | Same Cloudflare Pages Edit permission | Step 4 | The new project's domains only; the call names one hostname | Delete the DNS CNAME first, then remove the domain (rollback section) | write |
| Create the apex CNAME and the optional www record | Cloudflare API token | Zone level: DNS Write (dashboard label Zone, DNS, Edit), restricted to the zone renegadepenguinllc.com | Step 5 and step 6 | Every record in the zone, including MX, SPF, DKIM and DMARC (record types cannot be excluded in a token); limited by procedure: one named record created, a before and after export diffed, mail records never named | Delete the created record, restore the exported previous apex records | write |
| Read the current DNS records for the snapshot and the diff | Cloudflare API token | Zone level: DNS Read, same zone | Precondition 9, steps 5 and 9 | None, read only | none needed | read-only |
| Create the www redirect (optional) | Cloudflare API token | Zone level: Single Redirect Edit (API group name Dynamic URL Redirects Write), same zone; confirm the name through GET /user/tokens/permission_groups | Step 6 | The zone's single redirect rules; no Rulesets permission appears at zone level in the reference, so the rate-limit rule is not in this group (confirm in the live list) | Delete the one rule | write |
| Read the Turnstile widget configuration | Cloudflare API token | Account level: Turnstile Read (the API page also accepts Turnstile Sites Read); confirm through GET /user/tokens/permission_groups | Precondition 6 | None, read only | none needed | read-only |
| Create the production config in Doppler | Doppler | Project `no-php-no-cry`, a branch config of the prd root config, proposed name `prd_renegadepenguin`; owner approval required | Holds the production tokens and secrets apart from dev | The new config only | Delete the config | write |
| Store the production token pair and the two secrets in that config | Doppler | Write to that one config only; values are set by the owner on stdin with output discarded (`> /dev/null`) | Step 1 and step 2 sources | That config only | Delete the entries, revoke the tokens | write |
| Read the production secrets at deploy time | Doppler | A service token scoped to that one config, read-only (the default; write left off, DOCS-VERIFIED 2026-11-19 [doppler-svc]) | Steps 2 and 3 | The two secrets and the token pair in that config | Revoke the service token | read-only |
| Set `MAIL_SHARED_SECRET` and `TURNSTILE_SECRET` on the new Pages project | Cloudflare Pages secrets | Uses the Cloudflare Pages Edit permission above; values piped from Doppler on stdin, never in argv | The Function needs both to run | The new project only | Delete the two secrets | write |
| Service binding `MAIL_WORKER` to the existing Worker | Cloudflare Pages deploy | Declared in `wrangler.production.jsonc` (a `services` key, DOCS-VERIFIED 2026-11-19 [wr-config]); no Workers edit scope is needed because the Worker is not changed (REPO-VERIFIED above); any extra permission to bind a service is UNDOCUMENTED, so step 3 reads the binding back after deploy | The form mail path | None to the Worker | Redeploy without the binding, or delete the project | write |
| Search Console and Bing verification and sitemap submit | Owner's own search accounts, dashboard | The owner's login; a DNS TXT record at the apex is used and then falls under the DNS Write row | Step 9 | None beyond one TXT record | The TXT record must stay (step 9); remove the sitemap only | write |
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
- Command: `wrangler pages project create renegade-penguin-site-prod --production-branch main --compatibility-date 2026-11-01`
  (DOCS-VERIFIED 2026-11-19 [wr-cmds]). Or a POST to `/accounts/<account>/pages/projects` with
  `{"name": "renegade-penguin-site-prod", "production_branch": "main"}` (REPO-VERIFIED: that is the
  call `scripts/staging/ensure-pages-project.sh` makes; that script has the staging project name
  fixed in `scripts/staging/lib.sh` and cannot be reused unchanged).
- Expected: the project exists with production branch `main` and no deployments.
- Verify: a GET on `/accounts/<account>/pages/projects/renegade-penguin-site-prod` returns
  `production_branch` `main`. Note its `subdomain` field: that, not the project name, is the
  pages.dev name used in steps 3 and 5, because Cloudflare adds random characters when the name is
  taken (DOCS-VERIFIED 2026-11-19 [direct-upload], [project-api]).
- Rollback: delete the project. No traffic can reach it yet.

### 2. Set production secrets and variables

- Who: owner.
- Variables: `EXPECTED_HOSTNAME` (the apex) and `MAIL_FROM` come from `wrangler.production.jsonc` at
  deploy time. Top-level `vars` and `services` in a config file apply to production and preview
  deployments alike, and once a config file is used the dashboard cannot edit those fields: the file
  is the source of truth (DOCS-VERIFIED 2026-11-19 [wr-config]; the same is REPO-VERIFIED for the
  staging file in functions/README.md). A config-file deploy needs Wrangler 3.45.0 or newer; the
  deploy script checks it (REPO-VERIFIED scripts/deploy-production.sh).
- Secrets, values from the Doppler prd config, piped on stdin, never in argv:
  `doppler secrets get MAIL_SHARED_SECRET --project no-php-no-cry --config prd_renegadepenguin --plain | wrangler pages secret put MAIL_SHARED_SECRET --project-name renegade-penguin-site-prod`
  and the same for `TURNSTILE_SECRET_KEY` into `TURNSTILE_SECRET` (the name mapping is REPO-VERIFIED
  in functions/README.md). The `pages secret put` and `list` syntax is DOCS-VERIFIED 2026-11-19
  [wr-cmds]. Reading the value from stdin is documented for `wrangler secret put` (Workers) but
  UNDOCUMENTED for `pages secret put`, so rehearse first: create a throwaway Pages project, pipe a
  dummy value through the same command, confirm `wrangler pages secret list` shows the name, then
  delete the project. Do not use `secret bulk` with a file; the secret would sit on disk.
- Expected: both secrets listed on the project (names only).
- Verify: `wrangler pages secret list --project-name renegade-penguin-site-prod` shows both names;
  this must be true before step 3.
- Rollback: `wrangler pages secret delete <KEY> --project-name renegade-penguin-site-prod`, or delete
  the project.

### 3. Deploy the production build to the pages.dev URL and check it there

- Who: owner (the script refuses without the owner's approval variable).
- Command: first the dry run, `scripts/deploy-production.sh`, then
  `OWNER_APPROVED_CUTOVER=yes SCRUB_TERMS_FILE=<real file> HUGO_PARAMS_TURNSTILESITEKEY=<public sitekey> scripts/deploy-production.sh --apply`
  with the token in the environment. It checks Wrangler is 3.45.0 or newer, builds the production
  variant, runs `check-output.sh` with `EXPECT_ENV=production REQUIRE_NO_OWNER_TOKENS=1` and the
  real terms, checks the artifact, then deploys from a clean staging directory: the script copies
  `wrangler.production.jsonc` there as `wrangler.jsonc`, with `functions/` and `public/`, and runs
  `wrangler pages deploy public --project-name renegade-penguin-site-prod --branch main`.
- Why a clean staging directory: whether `pages deploy` honors `--config` is UNDOCUMENTED (the flag
  exists as a global flag, but the Pages pages never say deploy reads its settings from it), and the
  repository root holds the staging `wrangler.jsonc`, which must never be picked up by mistake. The
  directory removes both questions. Explicit `--project-name` and `--branch main` stay (`--branch main`
  matches the production branch set in step 1). Whether `pages deploy` itself reads `name` and
  `pages_build_output_dir` from the file is partly UNDOCUMENTED, so the explicit flags stay too.
- Post-deploy configuration check (mitigation for the UNDOCUMENTED items): read the project back
  with a GET on `/accounts/<account>/pages/projects/renegade-penguin-site-prod` and confirm
  `EXPECTED_HOSTNAME` is `renegadepenguinllc.com`, `MAIL_FROM` is the sender, and the `MAIL_WORKER`
  service binding points at `renegade-penguin-mail`, in the production deployment config. The
  response field names are UNDOCUMENTED here; read the response. If any is missing, stop: do not
  attach the apex.
- Expected: a deployment on `https://<subdomain>` from step 1 (DOCS-VERIFIED 2026-11-19
  [direct-upload]).
- Verify on that URL: `curl -s https://<subdomain>/robots.txt` has no `Disallow: /` and has a
  `Sitemap:` line; the home page HTML has no `noindex` meta; `/sitemap.xml` returns 200; response
  headers on `/` and `/contact/` match `static/_headers` (CSP, HSTS, nosniff);
  `/.well-known/security.txt` returns 200; no `email-protection` string in any page; a missing path
  returns the site's 404 page.
- Indexing of the pages.dev host: the production `<project>.pages.dev` host is NOT noindexed by
  default; only preview URLs get `X-Robots-Tag: noindex` (DOCS-VERIFIED 2026-11-19 [serving],
  [previews]). So the production build is indexable at pages.dev too, with apex canonical links. The
  fix is the documented headers rule: `static/_headers` gets blocks for `https://:project.pages.dev/*`
  and `https://:version.:project.pages.dev/*`, each with `X-Robots-Tag: noindex` (absolute URLs must
  start with https and carry no port; DOCS-VERIFIED 2026-11-19 [headers]). Those rules match only
  pages.dev hosts, so the apex is not noindexed. That file change is issue #106, handled
  separately and a precondition (13). With it merged, expect `X-Robots-Tag: noindex` on the pages.dev
  host and none on the apex (the apex check is in step 5).
- The contact form cannot be completed here: the widget hostnames do not include the pages.dev name
  (REPO-VERIFIED docs/staging.md lists staging and apex only), so the Turnstile check fails by design.
- Rollback: roll back or delete the deployment, or delete the project; the apex is untouched.

### 4. Attach the apex custom domain

- Who: owner.
- Command: a POST to `/accounts/<account>/pages/projects/renegade-penguin-site-prod/domains` with
  `{"name": "renegadepenguinllc.com"}` (DOCS-VERIFIED 2026-11-19 [domains-api]; REPO-VERIFIED shape:
  the staging attach script posts the same body to the same path pattern). The domain stays pending
  until DNS points at the project. Attach before creating the record: a manually added CNAME for a
  domain not yet associated with the project in Cloudflare results in a 522 error
  (DOCS-VERIFIED 2026-11-19 [custom-domains]).
- Expected: the domain is listed with status `initializing` or `pending`.
- Verify: GET the same path. The status values are `initializing`, `pending`, `active`,
  `deactivated`, `blocked` and `error` (DOCS-VERIFIED 2026-11-19 [domains-api]). Accept
  `initializing` or `pending` now; treat `error`, `blocked` and `deactivated` as stop.
- Rollback: delete the DNS record first, then the domain (see the rollback section).

### 5. DNS for the apex

- Who: owner, in a quiet window.
- Do first: compare the precondition 9 snapshot with a fresh export; note the id of every record at
  the apex name that is an A, AAAA or CNAME. Prepare both API payloads before starting: delete the
  old record and create the new one.
- Command: delete the old apex A, AAAA or CNAME record, then immediately create a proxied CNAME named
  `@` (the apex) whose content is the `subdomain` value from step 1 (REPO-VERIFIED pattern: the staging
  CNAME is proxied with ttl 1). Run the two calls back to back. A CNAME and an A or AAAA record cannot
  share a name, and the documentation does not state the order or the gap behavior for the zone apex
  (UNDOCUMENTED), so expect a short gap, run both calls together, and keep the reverse payloads ready.
  A CNAME at the apex is flattened by default (DOCS-VERIFIED 2026-11-19 [cname-flat-setup]). The API
  attach is not documented to create the record itself, so it is created manually here; the dashboard
  path may create it automatically (DOCS-VERIFIED 2026-11-19 [custom-domains]).
- Mail records: leave every MX, SPF (TXT), DKIM and DMARC record untouched. Whether a flattened apex
  CNAME coexists correctly with MX and TXT at the same name is UNDOCUMENTED, and the DNS record types
  page warns that queries for other record types on a proxied CNAME name are not supported
  (DOCS-VERIFIED 2026-11-19 [dns-types]). Mitigation, all required: before the cutover rehearse on a
  throwaway zone or a subdomain that has an MX and a TXT at the same name, or get written
  confirmation from Cloudflare support; after the change, the MX, SPF, DKIM and DMARC answers must
  equal the precondition 9 snapshot exactly. The MX and TXT diff is the go or no-go: if any mail
  answer changed, roll back at once. The mail path matters more than the site.
- Expected: the domain on the Pages project turns `active`. No time for DNS propagation or for the
  certificate is documented (UNDOCUMENTED). Poll the domain status every 30 seconds with a cap of 30
  minutes; beyond the cap stop and report. A proxied record has an automatic TTL of 300 seconds
  (DOCS-VERIFIED 2026-11-19 [proxy-status]), so cached answers last about five minutes.
- Verify: `curl -sI https://renegadepenguinllc.com/` returns 200 with the site's headers and no
  `X-Robots-Tag: noindex`; `dig +short MX renegadepenguinllc.com` and the SPF, DKIM and DMARC TXT
  answers are identical to the precondition 9 snapshot (an exact diff, expected empty); `dig CAA`
  is unchanged. Also confirm no Cache Rule or Page Rule applies to the apex: zone settings apply to a
  proxied custom domain and a cache rule can serve stale content after a deploy (DOCS-VERIFIED
  2026-11-19 [custom-domains], [serving]).
- Rollback: see the rollback section. Avoid flipping the record back and forth: a domain whose DNS
  is changed away becomes inactive and visitors see errors until it is active again (DOCS-VERIFIED
  2026-11-19 [custom-domains]).

### 6. The www decision

- Who: owner decides; owner runs.
- Recommended: redirect `www.renegadepenguinllc.com` to the apex with one single redirect rule,
  a wildcard rule (the Free plan has no regex): request URL `https://www.*` to `https://${1}`,
  status 301, preserve the query string (DOCS-VERIFIED 2026-11-19 [redirect-www]). It uses 1 of the
  10 single redirect rules allowed on Free (DOCS-VERIFIED 2026-11-19 [url-fwd]). Redirects require
  that the DNS record be proxied through Cloudflare (DOCS-VERIFIED 2026-11-19 [url-fwd]), so a
  proxied `www` record must exist. A placeholder record at a documentation address is the usual
  pattern but is UNDOCUMENTED in the pages read; if a `www` record already exists, record it and
  do not overwrite it. The documented example redirects HTTPS only: plain `http://www...` is not
  redirected by it; whether Always Use HTTPS covers that is not verified here.
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
- Search Console: add a Domain property and verify by a DNS TXT record: name `@` (or blank), the
  string as the value, then click Verify. A manually added record can take up to two or three days.
  The TXT record must never be removed after verification, even once it succeeds, or verification is
  lost; DNS verification is for a Domain property only (DOCS-VERIFIED 2026-11-19 [gsc]). A TXT record
  at the apex coexists with SPF and DMARC records by the usual DNS rules, but it is a DNS write: diff
  the mail records afterward, as in step 5.
- Bing Webmaster Tools: import the site from Search Console (My Sites, Import, sign in to Google,
  Allow, pick the property). Documented in a 2019 Bing blog post only; the current Bing help page
  was not fetchable on 2026-11-19 (DOCS-VERIFIED 2026-11-19 [bing], limited). Keep the TXT record,
  because Bing rechecks ownership against the Search Console account. Still submit the sitemap in Bing
  by hand.
- Submit `https://renegadepenguinllc.com/sitemap.xml` in both (REPO-VERIFIED: Hugo generates it and
  the production robots.txt points to it; the thank-you and 404 pages are excluded, scripts/test-trust.sh).
- Verify: both tools report the sitemap as read, with the page count close to the built page count.
- Rollback: remove the sitemap submissions only. Do not remove the verification TXT record.

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

What to undo, in this order, when the apex misbehaves after step 4 or 5. The order follows the
documented procedure: the DNS record goes first, then the domain (DOCS-VERIFIED 2026-11-19
[custom-domains]).

1. Delete the apex CNAME created in step 5, and in the same change restore the apex A, AAAA or CNAME
   records saved in the precondition 9 snapshot, if any existed. Have the restore payloads ready.
2. Remove the custom domain from `renegade-penguin-site-prod` (API DELETE on
   `/accounts/<account>/pages/projects/renegade-penguin-site-prod/domains/renegadepenguinllc.com`,
   or Remove domain in the project; DOCS-VERIFIED 2026-11-19 [domains-api]).
3. Mail records are never touched: MX, SPF, DKIM and DMARC were not edited in any step, and the final
   diff of step 5 proves it. The Search Console TXT record, if added, stays: it must never be removed
   after verification.
4. Revert the personal site cross-link if step 10 was done, and remove the sitemap from the search
   tools.

How long: a proxied record has an automatic TTL of 300 seconds, so cached answers last about five
minutes and browsers may differ (DOCS-VERIFIED 2026-11-19 [proxy-status]). No propagation time is
documented (UNDOCUMENTED). The mail path does not depend on this and keeps working throughout.

What the owner sees meanwhile: after the CNAME is deleted and before the old records are restored,
the apex may return a Cloudflare error page or the previous content, depending on what the step 5
snapshot shows was there (this repository does not record it). A custom domain whose DNS points
elsewhere goes inactive and visitors get errors until it is active again (DOCS-VERIFIED 2026-11-19
[custom-domains]); for a temporary pause the docs advise a redirect or origin rule instead. The staging
site and the staging form keep working at all times.

If only a bad deploy is the problem, leave the domain attached and roll back the deployment: Deployments,
All deployments, the three dots, Rollback to this deployment. The production deployment changes
instantly; only a successfully built production deployment is a valid target, and deployments older
than 30 days are deleted except the 100 most recent and the current one (DOCS-VERIFIED 2026-11-19
[rollbacks]). A rollback does not undo secrets or variables set separately, so a configuration mistake
needs a new deploy. An API route for rollback is UNDOCUMENTED.

## Post-launch watch list

- Day 1: the contact form once an hour for the first day, then daily for a week; the inbox for the
  test message and for real ones; `/api/contact` error rate in the Pages project logs.
- Search: Search Console coverage and sitemap status after 2 days and again after a week; the
  apex robots.txt is still `Allow: /` (a regression to the staging variant would set `Disallow: /`).
- Certificate and domain status of the apex on the project: `active`.
- DNS: a weekly diff of the mail records against the snapshot for a month; `dig CAA` unchanged.
- Cache: no Cache Rule or Page Rule on the apex that could serve stale content after a deploy.
- Email: delivery of the form mail (SPF and DKIM alignment as seen in the received headers).
- Headers: `curl -sI` on `/` and `/contact/` still match `static/_headers`; the apex has no
  `X-Robots-Tag: noindex` and the pages.dev host has it (once #106 is merged).
- Turnstile: the widget dashboard error count; any rise means a hostname or sitekey mismatch.
- Rate limit: blocked POST count on `/api/contact`.
- Cleanup: revoke the write tokens and drop the write scopes (the card filed before approval), then
  delete the Doppler service token if nothing else uses it.

## Tests

`scripts/test-cutover-prep.sh` (static, no network) checks that the production build is indexable
and the staging variant is not, that both wrangler configs obey their allowlists
(`scripts/test-pages-config.sh`), that `scripts/deploy-production.sh` is a dry run by default and
refuses `--apply` without approval, real scrub terms and Wrangler 3.45.0 or newer, and that this file
keeps the sections, the access plan table, the permission names, the rollback order and the markers.
It runs in CI with the other site tests.

## Sources

All read on 2026-11-19 (verification report kept outside the repository). Prefix every URL with
`https://developers.cloudflare.com` unless it starts with another host.

| Label | URL |
| --- | --- |
| perm | /fundamentals/api/reference/permissions/ |
| wr-cmds | /workers/wrangler/commands/pages/ |
| wr-config | /pages/functions/wrangler-configuration/ |
| bindings | /pages/functions/bindings/ |
| custom-domains | /pages/configuration/custom-domains/ |
| domains-api | /api/resources/pages/subresources/projects/subresources/domains/ |
| project-api | /api/resources/pages/subresources/projects/methods/get/ |
| direct-upload | /pages/get-started/direct-upload/ |
| headers | /pages/configuration/headers/ |
| serving | /pages/configuration/serving-pages/ |
| previews | /pages/configuration/preview-deployments/ |
| rollbacks | /pages/configuration/rollbacks/ |
| url-fwd | /rules/url-forwarding/ |
| redirect-www | /rules/url-forwarding/examples/redirect-www-to-root/ |
| dns-types | /dns/manage-dns-records/reference/dns-record-types/ |
| cname-flat | /dns/cname-flattening/ |
| cname-flat-setup | /dns/cname-flattening/set-up-cname-flattening/ |
| proxy-status | /dns/proxy-status/ |
| gsc | https://support.google.com/webmasters/answer/9008080 |
| bing | https://blogs.bing.com/webmaster/2019/9/Import-sites-from-Search-Console-to-Bing-Webmaster-Tools/ |
| doppler-branch | https://docs.doppler.com/docs/branch-configs |
| doppler-svc | https://docs.doppler.com/docs/service-tokens |
