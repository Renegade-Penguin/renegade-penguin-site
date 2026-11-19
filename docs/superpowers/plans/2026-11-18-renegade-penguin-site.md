# Renegade Penguin site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Hugo static site for Renegade Penguin LLC that builds and renders locally for owner review, with CI green, before any hosting.

**Architecture:** A lean clone of the no-php-no-cry stack (Hugo, dark-only tokens, strict CSP, zero scripts). Not the 19k-line script tree: only the pieces this site needs, each with a test. Hosting, the contact Worker and the apex cutover are later plans (issues #4, #5, #7).

**Tech Stack:** Hugo 0.168.0 (same pin as no-php-no-cry `.hugo-version`), POSIX shell checks, Python 3 stdlib (run with `-I`), Playwright for screenshots (outside the repo), GYST reusable workflows.

**Spec:** `docs/superpowers/specs/2026-11-18-renegade-penguin-site-design.md`

## Global Constraints

- Hugo pinned in `.hugo-version` to `0.168.0`; CI verifies the tarball checksum.
- Dark only: `color-scheme: dark`, no `prefers-color-scheme: light`, no white or cream large fills.
- Tokens (from no-php-no-cry): accent `#FBB03B`, on-accent `#1A1A1A`, ground `#0F0F0F`, surface `#202020`, text `#F0F0F0`, muted `#B5ADA2`, rule `#3A3530`. Jost self-hosted (copy `jost-latin-wght-normal.woff2` and `OFL.txt` from `~/src/no-php-no-cry/static/fonts/`). No other font, no font host.
- Zero JavaScript, zero third-party requests. CSP: `default-src 'none'; img-src 'self'; style-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'` in `static/_headers`, plus the same nosniff, referrer, permissions, HSTS and COOP headers as `~/src/no-php-no-cry/static/_headers`.
- Mascot: the approved rifle penguin without the Star of David, copied from `~/src/no-php-no-cry/static/brand/` (public there already); the implementer looks at it at full size and reports the file name.
- American English, no em dashes anywhere (copy, code strings, comments).
- Never in repo or output: employer name, work handle, hostnames, serials, callsign, grid square, any client or breached-company name, any faith or group name. `scripts/check-output.sh` enforces this against a denylist read from a file named by `SCRUB_TERMS_FILE` (not committed; terms come from the owner).
- Copyright line: "Renegade Penguin LLC".
- Short pages fit 1920x930 without scrolling; long pages exempt.
- GYST callers pinned by commit with `# vX.Y.Z` comment: use the exact `parallel-ci`, `bash-ci` and `security` pins from `~/src/no-php-no-cry/.github/workflows/ci.yml` (v1.36.0, `ff658b7c11a55eea1394af5fd1a3a1b4b09d9cd0`). Gate job named `CI green`.
- Agents run targeted checks only; CI is the judge.

## Review Focus

- A 320 px wide screen: no horizontal scroll, nav still reachable. Test: Task 5 screenshot at 320 px, `check-output.sh` asserts the viewport meta tag.
- Staging build must never be indexed: `HUGO_PARAMS_ENVIRONMENT=staging` gives `noindex` on every page and a disallow-all `robots.txt`. Test: Task 3.
- A leaked denylist term in any built page, including `<title>`, alt text and the sitemap. Test: Task 3 fixture with a planted term fails the check.
- A stray `<script>`, inline handler or external URL in a layout. Test: Task 3 fixtures for each fail the check.
- Missing cross-link: About and footer must link to `https://chiefgyk3d.com/`. Test: Task 3.

---

### Task 1: Scaffold, tokens, layouts

**Files:**
- Create: `.hugo-version` (`0.168.0`), `hugo.toml`, `assets/css/tokens.css`, `assets/css/main.css`, `layouts/baseof.html`, `layouts/home.html`, `layouts/single.html`, `layouts/list.html`, `layouts/404.html`, `layouts/_partials/header.html`, `layouts/_partials/footer.html`, `layouts/home.robots.txt`, `static/_headers`, `static/fonts/` (Jost, OFL), `static/brand/` (penguin), `.gitignore` (`public/`, `resources/`), `LICENSE` and `LICENSE-CONTENT` copied from no-php-no-cry then edited to name the right owner and ask the lead if unsure.
- Test: `scripts/test-build.sh`

**Interfaces:**
- Produces: params `environment` (`production` default, `staging` override), partials `header.html` and `footer.html`, nav data in `hugo.toml` `[[menus.main]]` (Home, Services, Experience, Community, About, Contact).

- [ ] **Step 1: Write `scripts/test-build.sh`.** It builds with `hugo --minify --destination "$(mktemp -d)"`, then asserts: exit 0; `index.html` exists; `_headers` copied with exactly one `/*` block; no `<script` in any html file; `<html lang="en">`; `<meta name="viewport"`; one `<h1>` on the home page.
- [ ] **Step 2: Run it to see it fail** (`scripts/test-build.sh`; expected FAIL: no config).
- [ ] **Step 3: Implement the scaffold.** `hugo.toml`: `baseURL = "https://renegadepenguinllc.com/"`, `title = "Renegade Penguin LLC"`, `disableKinds = ["taxonomy","term","RSS"]`, `[outputs] home = ["html","robots"]`, `enableGitInfo = false`. Tokens and CSS from the Global Constraints values; header has the penguin image (with alt text) and Jost text "Renegade Penguin LLC" as an interim wordmark; footer has the copyright line and a link to chiefgyk3d.com. Layouts read `.Params.environment` through `site.Params.environment` for the noindex meta and `home.robots.txt` (disallow all when staging).
- [ ] **Step 4: Run `scripts/test-build.sh`; expected PASS.**
- [ ] **Step 5: Commit** (`git add -A; git commit`, message ending with the attribution line the lead supplies in the brief).

### Task 2: Pages

**Files:**
- Create: `content/_index.md`, `content/services/_index.md`, `content/experience/_index.md`, `content/community/_index.md`, `content/about/_index.md`, `content/contact/_index.md`
- Test: `scripts/test-pages.sh`

**Interfaces:**
- Consumes: Task 1 layouts and menus.
- Copy source: the lead places owner-approved copy in `content/` using the files from the copy task (copy is issue #3, authored through Codex by the lead; the contact form is issue #4). Until it lands, pages carry the placeholder line `Draft copy pending.` and the page titles only; the implementer writes no marketing copy. The About placeholder also carries one link line, `Personal site: chiefgyk3d.com`, linking `https://chiefgyk3d.com/` with `rel="noopener"`.

- [ ] **Step 1: Write `scripts/test-pages.sh`.** Builds, then asserts each of `/`, `/services/`, `/experience/`, `/community/`, `/about/`, `/contact/` exists with exactly one `<h1>` and a nav link to each other page; asserts `/contact/` contains no `<form` (the Worker form is issue #4); asserts `/about/` links `https://chiefgyk3d.com/` with `rel="noopener"`.
- [ ] **Step 2: Run, expect FAIL.** **Step 3:** create the six content files with front matter `title` and `description`, and `layouts/single.html` and `list.html` rendering `.Content`. **Step 4:** run, expect PASS. **Step 5:** commit.

### Task 3: Output checker

**Files:**
- Create: `scripts/check-output.sh`, `scripts/test-check-output.sh`, `scripts/fixtures/` (tiny hand-made output trees)
- Test: `scripts/test-check-output.sh`

**Interfaces:**
- Produces: `scripts/check-output.sh <dir>` with env `EXPECT_ENV` (`production` or `staging`) and optional `SCRUB_TERMS_FILE`; exit 0 clean, non-zero with one line per violation.

- [ ] **Step 1: Write `scripts/test-check-output.sh`.** Fixtures that must each fail with a message: a `<script>` tag; an `onclick=` attribute; an `https://` URL to a host other than `chiefgyk3d.com`, `github.com` and `renegadepenguinllc.com` in any `src`, `href` on `link`, or `@import`; a term from a temp `SCRUB_TERMS_FILE` in body, title and alt; production tree with `noindex`; staging tree without `noindex` or with `robots.txt` lacking `Disallow: /`; `_headers` missing a CSP line; a missing chiefgyk3d.com link on `about/index.html`; an em dash in any html. One clean fixture must pass. Revert-proof: the test runs each check against the clean fixture with the check disabled by a `SKIP_<NAME>=1` env and confirms it then passes the bad fixture (so each fixture bites).
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement** `scripts/check-output.sh` in bash with `set -euo pipefail`, using `grep -r` and one function per check named after the fixture. **Step 4: Run; expect PASS; also run the real build through it** (`hugo --minify --destination ~/.local/share/renegade-penguin-site-dev/out`, `EXPECT_ENV=production scripts/check-output.sh <dir>`). **Step 5: Commit.**

### Task 4: Contrast and dark-only check

**Files:**
- Create: `scripts/check-contrast.py`, `scripts/test-check-contrast.sh`
- Test: `scripts/test-check-contrast.sh`

**Interfaces:**
- Produces: `python3 -I scripts/check-contrast.py assets/css/tokens.css` exits 0 when text/ground, text/surface, muted/ground, link/ground, on-accent/accent each reach 4.5:1 and focus/ground reaches 3:1; exits non-zero when `tokens.css` contains `prefers-color-scheme: light` or any `#FFF`/`#FFFFFF`/`white` fill.

- [ ] **Step 1: Write the test** with a passing copy of `tokens.css` and three failing variants (low-contrast muted, light media query, white fill). **Step 2:** run, FAIL. **Step 3:** implement with stdlib (relative luminance formula, WCAG 2.2). **Step 4:** run, PASS. **Step 5:** commit.

### Task 5: Render for review

**Files:**
- Create: `scripts/render-review.sh`
- Output (not committed): `~/.local/share/renegade-penguin-site-dev/shots/`

- [ ] **Step 1:** `scripts/render-review.sh` builds the staging variant to `~/.local/share/renegade-penguin-site-dev/out`, serves it on `127.0.0.1` on a free port with `python3 -m http.server`, prints the local URL, and stops the server by saved PID on `scripts/render-review.sh stop` (it writes the PID to `~/.local/share/renegade-penguin-site-dev/serve.pid`). It takes screenshots itself only if Python `playwright` imports; otherwise it does not, and the lead takes them with the Playwright MCP tools. **Step 2:** run `scripts/render-review.sh` and fetch `/` with curl; expect HTTP 200. **Step 3:** the lead screenshots the six pages at 1920x930 and 320x700 and views them against the brand reference images side by side and reports to the owner. **Step 4:** commit the script only.

### Task 6: CI

**Files:**
- Create: `.github/workflows/ci.yml`, `.github/dependabot.yml` (with the 7-day cooldown), `.gitignore` additions
- Modify: branch protection on `main` (required check `CI green`) through `gh api`, by the lead

- [ ] **Step 1:** `ci.yml` modeled on no-php-no-cry's: `ci` job calls `parallel-ci.yml` with the Hugo setup command, build command (production, then staging build to `$RUNNER_TEMP/public-staging`), jobs running `scripts/check-output.sh`, `scripts/test-check-output.sh`, `scripts/test-build.sh`, `scripts/test-pages.sh`, `python3 -I scripts/check-contrast.py assets/css/tokens.css`, `scripts/test-check-contrast.sh`; `shell` calls `bash-ci.yml`; `security` calls `security.yml`; `ci-green` job named `CI green`, `if: always()`, needs all three. Egress policy `audit` first, as no-php-no-cry does, with a follow-up note. **Step 2:** open the PR (no direct pushes to main); the lead watches the PR's own run with the head-pinned watcher in the background. **Step 3:** after green, the lead enables `CI green` as required.

## Self-review

- Spec coverage: pages, cross-links, dark-only, strict CSP, staging noindex, GYST CI covered by Tasks 1 to 6. Contact Worker, hosting, DNS, mail records, cutover and shared theme are issues #4 to #8, later plans. Copy is issue #3, lead-run through Codex.
- Names consistent: `EXPECT_ENV`, `SCRUB_TERMS_FILE`, `SKIP_<NAME>` appear only in Task 3 and its callers.
