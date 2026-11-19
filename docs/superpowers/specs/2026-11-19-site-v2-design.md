# Renegade Penguin site v2: look, offer structure and client content

Issues: #14 (look), #15 (pricing), #16 (research), #17 (cross-links), #4 (contact Worker). Epic #1.
Research (local, not committed): `research/client-needs.md`, `research/competition.md` under `~/.local/share/renegade-penguin-site-dev/`.

## Intent

Turn the merged draft site into a site a prospective client can buy from: a clear offer, published price ranges, a process, proof, and a way to reach the owner. The business side of a one-person practice that also plays a personal-brand game elsewhere. It must read as a quiet sibling of chiefgyk3d.com, not an ad for it.

## Decisions (owner, 2026-11-19)

- Look C: split layout, amber-edged left panel with the penguin and name, stacked service cards on the right. Dark only.
- Offer in three tiers: (1) advisory retainer, vCISO/vCIO flavored, sold as "security and IT advisory"; (2) projects: defensive engineering, hardening, AI security review, with a minimum project fee; (3) education and speaking. Pro bono is a quiet community lane, never priced or named.
- Pricing: publish ranges and what drives them, month-to-month, no lock-in. Ranges are proposals until the owner signs off (research suggests advisory $225 to $300 per hour, retainer $3k to $9k per month, projects from about $5k, AI review fixed scope near $7.5k, keynote from $5k). Minimum size is enforced by price, not headcount.
- Contact: intake form through a Cloudflare Worker, Turnstile on the contact page only. That page alone loads one script from challenges.cloudflare.com and gets its own CSP block; every other page stays no-JS and no-third-party.
- Mailbox: contact@renegadepenguinllc.com for now.
- Cross-links with chiefgyk3d.com and Reach Around are designed in #17 and land in each site's own repo.

## Goals

- A visitor can tell in 10 seconds who it is for, what it costs, and how to start.
- Proof without logos: anonymized sample deliverables and composite case studies, with a stated confidentiality policy.
- Honest content competitors skip: when not to hire a vCISO, vendor-neutrality and conflict-of-interest statement, exclusions and assumptions.

## Non-goals and anti-goals

- No fake testimonials, absolute claims ("100%", "never failed an audit"), unsourced fear statistics, gated pricing, lock-ins, countdowns or sticky CTAs.
- No claim of certification or compliance: write "aligned to" NIST CSF, CIS and similar. No credential is named unless the owner confirms it is held.
- No client, breached-company, faith or group names. The breach story stays anonymized.
- No hosting, DNS or apex cutover in this plan (issues #5, #7).

## Approaches considered

1. Rebuild everything at once: slow, risky for review. Rejected.
2. Vertical slices, look first then content by priority, each its own PR: chosen. Each slice is reviewable and keeps main deployable.
3. Content first, look last: the owner wants the look improved first. Rejected.

## Owner gates (cannot be decided by the builder)

- Price ranges and the minimum project fee.
- Credentials named on the About page.
- Insurance statement wording (broker review), NDA, MSA, BAA stance (counsel review).
- Any statement about Ohio Revised Code 1354 (read the statute first; counsel before publishing).
- Case-study composites and the scrub-terms file.

## Copy rule

All public and non-technical copy is authored by ChatGPT through Codex and used verbatim; implementers place it. Owner approves each page before merge.
