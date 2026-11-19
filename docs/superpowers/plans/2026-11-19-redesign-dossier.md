# Dossier redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the visual layer of the Hugo site in the owner-approved "Dossier" direction, with data-driven home sections, restyled inner pages, cross-links to chiefgyk3d.com, and a staging deploy.

**Architecture:** Same Hugo stack and checks. A new token and component layer (grid background, section numbering, stamps, redaction bars, exhibit tiles, Orbitron display type) lives in `assets/css/`. Home sections are data files under `data/home/` rendered by partials; copy is authored by Codex and placed verbatim. Inner pages inherit the new shell through `baseof.html`, `list.html`, `single.html`.

**Tech Stack:** Hugo 0.168.0 (`.hugo-version`), CSS only (no script), POSIX shell and Python 3 stdlib checks, self-hosted Jost and Orbitron.

**Spec:** `docs/superpowers/specs/2026-11-19-redesign-dossier-design.md` (approved 2026-11-19). Visual reference: `~/.local/share/renegade-penguin-site-dev/mockups/redesign-v1/c/index.html` and its screenshots `scratchpad/c-1440.png`, `c-390.png` (the lead compares rendered output to it side by side before merging).

## Global Constraints

- Dark only; never a light or cream fill. Palette: accent `#FBB03B`, bg `#0F0F0F`, surface `#202020`, text `#F0F0F0`, muted `#B5ADA2`, rule `#3A3530`. New tokens allowed only if `python3 -I scripts/check-contrast.py assets/css/tokens.css` still exits 0.
- No script element (except the existing `/contact/` Turnstile exception), no third-party origin; CSP in `static/_headers` stays self-only. Fonts: Jost and Orbitron self-hosted woff2 in `static/fonts/` with license text beside them.
- No em dashes or en dashes anywhere (`scripts/find-dashes.py`). American English. Prices only through the `pricing` shortcode from `data/pricing.toml`.
- Public copy is authored by Codex via `codex exec ... < prompt-file` and placed verbatim; implementers never reword. Claims allowed are only those listed in the spec's "Owner-approved claims". No real client, breach, faith or group names; no callsign, employer, hostname or serial.
- Unapproved owner facts ship as `{{OWNER:<what is needed>}}` placeholders so the owner-token gate blocks a production deploy.
- Accessibility: WCAG 2.2 AA, visible focus, 44px targets (`--tap`), `prefers-reduced-motion` disables any stamp rotation or glow animation, redaction bars never carry meaning alone.
- Branch per task from `redesign-dossier` base; PR links issue #43 ("Refs #43", the final PR "Closes #43"); `CI green` required; merged by the head-pinned watcher. Implementers run targeted checks only.

## Review Focus

- A light or cream fill anywhere in new CSS (any `background` lighter than `--text` at 60 percent luminance outside text/buttons): Task 1 adds a CSS check test.
- A `<script`, `<link` or `@import` to an off-site origin: the existing `check-output.sh` must stay clean on both builds.
- Horizontal overflow at 390 px on any template: Task 4 renders every page type at 390 and 1440.
- Home copy strings typed into a template instead of `data/home/`: Task 2 test greps the home template for literal sentences.
- An unapproved claim word ("certified", "guarantee", "100%", "compliant" as a promise, any outcome figure for the journalist work) in any data or content file: existing claims checker extended in Task 2.

---

### Task 1: Tokens, fonts and the Dossier shell

**Files:**
- Create: `static/fonts/orbitron-latin-wght-normal.woff2` (copy from `~/.local/share/renegade-penguin-site-dev/mockups/redesign-v1/fonts/`), `static/fonts/OFL-Orbitron.txt` (SIL OFL text; copyright line from the font's own file), `layouts/_partials/case-strip.html`, `layouts/_partials/section-head.html`, `layouts/_partials/stamp.html`
- Modify: `assets/css/tokens.css`, `assets/css/main.css`, `layouts/baseof.html`, `layouts/_partials/header.html`, `layouts/_partials/footer.html`, `static/_headers` (no CSP change expected), `scripts/test-build.sh`
- Test: `scripts/test-build.sh`, `scripts/check-contrast.py`, new `scripts/test-no-light-fills.sh`

**Interfaces:**
- Produces: CSS classes `.dossier-grid` (page background), `.case-strip`, `.sec` (numbered section head, contents set by partial `section-head.html` taking `dict "n" "01" "title" "What we do" "tag" "SCOPE OF WORK"`), `.stamp` (partial `stamp.html` taking a string), `.redact` (dark striped bar, `aria-hidden="true"`), `.exhibit` (tile), `.btn` and `.btn-primary`; tokens `--font-display`, `--grid-line`, `--grid-major`, `--stamp`, `--redact-a`, `--redact-b`.
- Consumes: existing `.panel`, `.card` (kept, restyled).

- [ ] **Step 1: Write the failing tests.** In `scripts/test-no-light-fills.sh` (bash, set -euo pipefail, uses grep and python3 -I) assert that no `background`/`background-color` value in `assets/css/*.css` resolves to a color with relative luminance above 0.30 except on selectors `.btn-primary`, `.skip`, `.cta`; run it against a fixture CSS in `scripts/fixtures/` containing a cream fill and expect exit 1, then against the real CSS and expect exit 0. Add to `test-build.sh` assertions: `fonts/orbitron-latin-wght-normal.woff2` exists in the build, the home page contains `class="case-strip"`, and the stylesheet link has an `integrity` attribute.
- [ ] **Step 2: Run them** (`bash scripts/test-no-light-fills.sh`, `HUGO=~/.local/share/renegade-penguin-site-dev/bin/hugo bash scripts/test-build.sh`) and confirm the new assertions FAIL.
- [ ] **Step 3: Implement** the tokens (`--font-display: Orbitron, ...`, `@font-face` for Orbitron with `font-display: swap`), the component CSS from the mockup (grid background via layered `linear-gradient`, chamfered `.btn`, rotated `.stamp` wrapped in `@media (prefers-reduced-motion: no-preference)` for the rotation), the partials with the signatures above, and the header (nav plus one `.btn-primary` "Book a fit call" linking to `/contact/`) and footer (case-file style line "END OF FILE"). Keep every selector used by existing templates working.
- [ ] **Step 4: Run** the three checks plus `python3 -I scripts/check-contrast.py assets/css/tokens.css` and `python3 -I scripts/find-dashes.py` on changed files; all exit 0.
- [ ] **Step 5: Commit** "Dossier shell: tokens, Orbitron, components (#43)".

### Task 2: Home page, data-driven

**Files:**
- Create: `data/home/hero.toml`, `data/home/what-we-do.toml`, `data/home/engagement.toml`, `data/home/no-vendor-pitches.toml`, `data/home/built-in-the-open.toml`, `data/home/speaking.toml`, `data/home/pricing-teaser.toml`, `data/home/behind.toml`, `data/home/faq.toml`, `layouts/_partials/home-*.html` (one per section)
- Modify: `layouts/home.html`, `content/_index.md`, `scripts/check-claims.py` and its fixtures (add banned words from the spec), `scripts/test-claims.sh`
- Test: `scripts/test-build.sh`, `scripts/test-claims.sh`, new `scripts/test-home-data.sh`

**Interfaces:**
- Consumes: Task 1 partials and classes.
- Produces: `data/home/*.toml` schema: every file has `eyebrow`, `title`, and an array `items` of tables with `title` and `body` where the mockup shows items; `engagement.toml` items add `stamp` (FREE, CREDITED, DELIVERED); `behind.toml` has `handle = "ChiefGyk3D"`, `first_name`, `role`, `link_text`, `link_url = "https://chiefgyk3d.com/"`; `built-in-the-open.toml` items are `{{OWNER:repo name}}` placeholders until the owner approves the list; `pricing-teaser.toml` reads figures only through the `pricing` shortcode.
- Copy source: `~/.local/share/renegade-penguin-site-dev/copy/home-dossier-out.md`, produced by the lead's Codex run from the spec before this task starts; the implementer places it verbatim into the data files.

- [ ] **Step 1: Write failing tests.** `scripts/test-home-data.sh` asserts (a) each section file above exists and parses as TOML (python3 -I with tomllib), (b) `layouts/home.html` and `layouts/_partials/home-*.html` contain no literal sentence of 40 or more characters outside Hugo actions and attributes, (c) the built home page has exactly one `h1`, one `.btn-primary` hero button, the sectors chips, the 8 numbered sections, and the owner-placeholder marker inside "Built in the open". Extend `check-claims.py` fixtures so a home data file containing "guarantee" or "100%" fails.
- [ ] **Step 2: Run and confirm FAIL**.
- [ ] **Step 3: Implement** the data files with the copy file's text verbatim, the section partials (each takes the data file via `site.Data.home.<name>`), and `home.html` composing: hero with mascot `/brand/penguin-color.png` (kept), sector chips, the numbered sections in the mockup's order, FAQ as native `<details>`.
- [ ] **Step 4: Run** `test-home-data.sh`, `test-build.sh`, `test-claims.sh`, `test-pages.sh`, find-dashes; all exit 0. Run `EXPECT_ENV=staging ... check-output.sh` on a staging build; the owner-token finding for "Built in the open" is expected only when the owner-token gate flag is set; the default build is clean.
- [ ] **Step 5: Commit** "Home: Dossier sections from data files (#43)".

### Task 3: Inner pages inherit the shell

**Files:**
- Modify: `layouts/list.html`, `layouts/single.html`, `layouts/404.html`, `layouts/contact/list.html` (chrome only; form and Turnstile markup unchanged), `assets/css/main.css`, `content/services/_index.md`, `content/services/education-speaking.md`, `content/about/_index.md`
- Test: `scripts/test-pages.sh`, `scripts/test-build.sh`, `scripts/check-output.sh` on both builds

**Interfaces:** Consumes Task 1 components; produces page headers in case-file style (`case-strip` with FILE and STATUS text from front matter `file` and `status`, both optional with defaults) so Task 4 can screenshot every page type.

- [ ] **Step 1: Failing tests** in `scripts/test-pages.sh`: every built page has the case strip, one `h1`, a skip link, and `main` landmark; the contact page still has exactly one script element (the Turnstile exception) when a sitekey is set and none otherwise; the speaking page contains the sentence "Community and non-corporate education is free" in the page text (copy authored by Codex first, see Step 3).
- [ ] **Step 2: Run, confirm FAIL**.
- [ ] **Step 3: Implement** the layouts; extend `content/services/education-speaking.md` and `content/about/_index.md` with Codex-authored copy placed verbatim from `~/.local/share/renegade-penguin-site-dev/copy/inner-dossier-out.md` (lead produces it; includes the approved claims, the Elissa Shevinsky mention with the owner-confirmed basis, the shortened journalist line, and a "Who is behind this" paragraph linking to chiefgyk3d.com).
- [ ] **Step 4: Run** test-pages, test-build, check-output on production and staging builds, find-dashes; all exit 0.
- [ ] **Step 5: Commit** "Inner pages: Dossier shell and speaking/about copy (#43)".

### Task 4: Rendered verification and staging deploy

**Files:** none in the repo except fixes it surfaces.

**Interfaces:** Consumes Tasks 1 to 3 merged on `redesign-dossier`.

- [ ] **Step 1:** Build the staging variant into the dev folder; render the home page and one page of each type (service, list, single, contact, 404) at 1440x900 and 390x844 with headless Chromium; list any page with horizontal overflow (`document.documentElement.scrollWidth > innerWidth`) and fix it.
- [ ] **Step 2:** The lead compares the home render to the mockup c screenshots side by side; mismatches become fixes in this task.
- [ ] **Step 3:** Run `check-contrast.py`, the keyboard order check (Tab through the home page and record the focus sequence), and `check-output.sh` for both builds.
- [ ] **Step 4:** After merge to main, the lead redeploys staging with `deploy-staging.sh` and verifies the live URL (HTTP 200, new section markers present, CSP header unchanged).
- [ ] **Step 5:** Draft the `chiefgyk3d.com` "Work with me" link text as `docs/cross-link-draft.md` for the owner to apply (no edits to the personal site).
