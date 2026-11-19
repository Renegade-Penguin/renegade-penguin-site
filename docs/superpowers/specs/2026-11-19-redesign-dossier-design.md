# Business site redesign: "Dossier" direction (issue #43)

Date: 2026-11-19. Status: approved by the owner on 2026-11-19, with the owner's answer that the "Who is behind this" block shows the handle ChiefGyk3D and the owner's first name (no last name). The list of repos for "Built in the open" is still owner-pending and ships as owner placeholders until approved. Mockups: ~/.local/share/renegade-penguin-site-dev/mockups/redesign-v1/c/ (served at 127.0.0.1:8743/c/ while the mockup server runs).

## Intent and why

The owner (a senior security engineer, about 16 years in the field) wants the Renegade Penguin LLC site to win corporate security-architecture and speaking work by looking far more polished than vCISO competitor sites, in the owner's own brand, and by making the owner the named, credible expert who gives "cold hard answers" without vendor pitches. The site must also route people both ways between the business site and the owner's personal site, chiefgyk3d.com, where the blog, journal, socials and content live.

## Goals

- Rebuild the visual layer of the existing Hugo site in the Dossier direction: fine grid background, "Case file" framing, section numbering (section sign plus number), monospace labels, rotated stamps, redaction-bar details, exhibit tiles, Orbitron display headings, Jost body, amber `#FBB03B` as a signal color on `#0F0F0F` / `#202020`.
- One primary call to action everywhere: "Book a fit call".
- Home page structure (from the chosen mockup): header, case-file strip, hero, sector chips, What we do (4 items), How an engagement runs (3 steps with FREE / CREDITED / DELIVERED stamps), No vendor pitches, Built in the open (GitHub exhibits), Speaking, Pricing, Who is behind this, Questions, footer.
- Apply the same system to the Services, Speaking, Pricing, About and Contact pages and the 404.
- Cross-links: a "Who is behind this" block on the business site pointing to chiefgyk3d.com; a drafted "Work with me" link for chiefgyk3d.com (the owner applies it; no agent edits the personal site).
- Speaking copy states that community and non-corporate education is free, at cost, or a variation by arrangement; corporate and vendor events are paid. (Already partly shipped in #42; extend.)
- Positioning copy: cold hard answers, vendor-neutral (open source and proprietary judged on results; no resale, no referral fees), shift left, secure programs, vetting initial staffing and requirements, GitHub portfolio as proof of how the owner builds.

## Non-goals and anti-goals

- No light mode, no cream or white large fills (owner is light sensitive); the cream redaction bars in the mockup become dark or amber-tinted.
- No JavaScript framework; no third-party script, font host or image host. The CSP stays `default-src 'none'` style (self only).
- No fabricated proof: no placeholder client names, no mock dashboards, no invented statistics, no real client or breach or faith/group names.
- No outcome claims about the journalist work. No second blog on this site.
- No production cutover (apex stays untouched; #7 is separate and needs the owner's word).
- Does not fix pricing figures (#15), the nine owner placeholders, or the mail/Email Sending work (#34, #35, #36).

## Owner-approved claims (from the owner's messages, 2026-11-19)

- About 16 years in the field.
- Worked in private aviation, critical infrastructure, cryptocurrency, and MSP work in healthcare, legal and dental settings (sectors only).
- Knows and uses open source and proprietary technology; recommends by results, no vendor sales pitches.
- Led security for journalists operating in and leaving Russia and Ukraine (no outcome figures, no Telegram story).
- Helped develop early OSINT practices for tracing cryptocurrency transactions.
- Mentored by Elissa Shevinsky, who has publicly endorsed the owner and served as a reference; named with that basis. Owner to confirm exact wording and ask her if she wants a say.
- Credentials only as listed publicly on chiefgyk3d.com (CISSP 2024; Security+, Network+, A+ Feb 2026); the claims checker must see each one sourced.
- Fit call is free (20 to 30 minutes, decides whether and how to work together); the full assessment is paid and credited toward an engagement. The owner approved this model by message; the wording stays "owner approval pending" in data until they confirm the final text.
- The owner's role direction (moving toward security architecture) means copy leans on "advisor" and "architect".

## Approaches considered

1. Restyle in place: fast, structure mostly unchanged. Rejected: does not reach the "sleeker than competitors" bar.
2. Mockup first, then rebuild (chosen by the owner). Three directions were mocked (A Frame, B Editorial, C Dossier); the owner picked C.
3. Shared theme module with chiefgyk3d.com first (#8): good long term, delays the visible result. Kept as a follow-up.

## Constraints

- Existing build rules hold: Hugo pinned in `.hugo-version`, CI "CI green", output checks (`check-output.sh`: no inline script, headers, scrub, claims, owner-token gate), contrast checker (`check-contrast.py` on tokens), no em or en dashes, American English.
- Orbitron is added as a self-hosted woff2 with its license text beside it (the owner's personal site already serves it; SIL OFL 1.1). Jost stays.
- Accessibility: WCAG 2.2 AA contrast, visible focus, 44px targets, reduced-motion respected for any stamp rotation or glow, a skip link, semantic headings, no meaning carried by redaction bars alone.
- Short pages fit about 1920x930 without scrolling where practical; long pages exempt.
- Public copy is authored by ChatGPT via Codex and used verbatim; the owner approves it (#3) before production. Agents implement templates and CSS and never reword.
- Cross-site rule: the business site never prints the owner's callsign, employer, hostnames or serials.

## Left to the builder

- Hugo template and CSS structure (partials for the case-file header, section heading, stamp, exhibit tile, redaction bar), token additions in `assets/css/tokens.css` (the contrast gate must still pass), mobile layout, image and mascot asset handling (the mascot comes from the owner's brand files in the private brand repo, owner approval needed before any mascot asset is committed; until then a neutral placeholder mark).
- Page-by-page rollout order: home first, then services, speaking, pricing, about, contact.

## Process

Per page batch: Codex drafts copy from a prompt file; an implementer builds templates and CSS in a worktree; targeted checks locally, CI is the judge; the lead compares the rendered page against the Dossier mockup before merging; deploy to staging; owner reviews on `staging.renegadepenguinllc.com`.

## Lead's calls (settled from the builder check; owner may overrule)

- Home and section copy lives in Hugo data files and front matter (one data file per section), authored by Codex and rendered by templates; nothing hardcoded in templates, so the claims checker and the owner-token gate see every string.
- Every other page (who-we-help, how-we-work, when-not-to-hire, case-studies, community, ohio, legal) inherits the new base layout and CSS through shared partials and is restyled by the same system; their copy is unchanged unless it conflicts with the approved claims.
- The already committed `static/brand/penguin-color.png` stays as the hero mascot; no new mascot assets are committed without the owner.
- New tokens may be added to `assets/css/tokens.css` freely as long as `check-contrast.py` passes; redaction bars use `--surface` and `--rule` tones, never a light fill.
- "Book a fit call" links to `/contact/` (subject hint in the link text and a short note above the form); no booking tool and no third-party script. The form itself works only after #34 to #36.
- Rollout: PRs merge to main through the head-pinned watcher; the lead rebuilds the staging variant and redeploys with the pinned wrangler script, then verifies the live staging URL.

## Open owner decisions

- Final wording for the fit call and assessment text, and the first-step pricing; vendor-event rate if different (#15).
- Elissa Shevinsky line wording.
- Whether to show the owner's handle; pronouns for the bio (currently unknown; copy uses neutral phrasing); the nine `{{OWNER:...}}` placeholders (BAA stance, PGP key, certifications held, governing law, counsel review, years in field now answered as about 16, aviation rules to reference, Ohio statute verification).
- Approving the drafted chiefgyk3d.com "Work with me" link and the mentor mention there.
