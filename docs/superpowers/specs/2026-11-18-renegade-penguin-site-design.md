# Renegade Penguin LLC site: design

Date: 2026-11-18. Status: draft, awaiting owner approval. Nothing is built.

## Intent and why

renegadepenguinllc.com is registered on Cloudflare and serves nothing. It becomes
the business front door for Renegade Penguin LLC: IT and cybersecurity
consulting, speaking, education, community work and quiet pro bono work.

chiefgyk3d.com sells the person and the content. This site sells the business as
a whole to buyers (owners, IT leads, CISOs, program organizers). The two link to
each other. The LLC site is not advertised loudly: chiefgyk3d.com points to it
from its business contact area only.

The owner wants to be hireable by organizations from one person to many thousands
of people, and wants the community and open-source side visible as part of the
offer, not hidden from it.

## Goals

- A buyer lands, understands in under a minute who this is, what is offered and
  how to reach them.
- Credibility without naming anyone: sectors, scale range, approach, public open
  source work.
- A contact path that can later route to shared mailboxes and distribution lists
  (a Microsoft 365 domain alias is planned; not yet).
- Reuse the proven chiefgyk3d.com stack so the site is cheap to run and safe.
- Visibly related to the personal brand, with cross-links both ways.

## Non-goals

- No blog or content-creation hub (that stays on chiefgyk3d.com).
- No client portal, booking engine, payments or CMS in this version.
- No light mode.
- No named clients, no named breached companies, no named pro bono recipients.

## Anti-goals (a failure even if it technically works)

- Any sentence that lets a reader identify a client, a pro bono recipient or a
  breached company.
- The employer's name, the work account handle, hostnames, serials, callsign or
  grid square anywhere in the repo, built output or git history.
- Corporate stock-photo look that loses the penguin entirely, or a loud
  self-promotion tone that fights the quiet-sibling positioning.
- A claim on the site the owner cannot back with a source if challenged.

## Constraints

- Security is priority zero. Static output only, strict CSP, no third-party
  scripts, no trackers.
- Dark mode only; no cream or white large fills.
- American English, no em dashes. Copyright line names Renegade Penguin LLC.
- Short pages fit 1920x1080 without scrolling (about 1920x930 viewport).
- Brand rules from the private brand repo apply: rifle penguin without the Star
  of David, no invented palette or logo treatment, no wordmark font invented.
  Jost and the amber/charcoal tokens are the interim sibling look; the LLC
  wordmark is an owner decision (open item).
- CI calls the GYST reusable workflows, gate named `CI green`, pinned by commit
  with the version comment. Dependencies pinned; new releases held 7 days.
- Secrets live in Doppler (project and environment layout per the owner's
  standard, dev before prd). No GitHub secret fallbacks with values.
- WCAG AA contrast, keyboard operable, Lighthouse and page-weight thresholds
  from the web-quality pack.

## Approaches considered

- **A. Separate site cloned from the no-php-no-cry stack (chosen).** Own repo,
  own Cloudflare Pages project, own GYST callers. Trade: the theme is copied at
  first, so a design fix lands twice until B.
- **B. Shared Hugo theme module first.** Cleanest, fits the GYST consolidation
  rule, but touches the live personal site before this one exists. Filed as a
  follow-up issue after the new site has shaped the theme.
- **C. One site for both domains.** Rejected: different audiences and a shared
  blast radius.

Owner chose A, with B as a follow-up.

## Decided by the owner

- Approach A; B filed as a follow-up.
- Positioning: business as a whole (education, community, consulting, speaking);
  chiefgyk3d.com is the personal brand and links here from business contact.
- Offer content to cover: consulting with a "no sacred cow" approach to vendors
  and approaches, cybersecurity posture and direction, AI security, defensive
  engineering, OSINT, OPSEC and threat modeling education, speaking.
- Experience to state: medical, dental, private aviation, critical
  infrastructure and MSP work for small business; engagements from one person to
  organizations of many thousands. A trusted network of specialists (for example
  telecommunications for call centers, penetration testing) joins as a team when
  an engagement needs it. Defense-first engineering, tested against offensive
  friends and associates. Much of the work is open source because community
  comes first.
- Community work, described without names: free help for smaller and minority
  communities that lack resources, which has included houses of worship, and for
  domestic violence support organizations (OSINT, OPSEC, threat modeling to
  shake off abusive partners and stalking). Do not name faiths or groups.
- A clear warning about serious security weaknesses, given to an organization
  years ago and ignored until the cost became unavoidable. Kept vague by owner
  decision (2026-11-19): no sector, no company type, no breach type, no name.
- Look: quieter sibling of the personal brand (amber on dark charcoal, Jost,
  the penguin as a mark), not a corporate stock look. (Owner has not objected;
  treated as accepted.)

## Design

Stack: Hugo (version pinned to what no-php-no-cry uses), static output, Cloudflare
Pages project for renegadepenguinllc.com, GYST caller workflows, strict CSP and
`_headers`, deploy workflow gated on `CI green`, credentials from Doppler.

Pages:

| Page | Purpose |
| --- | --- |
| Home | One-line pitch, three offers, credibility strip (sectors, scale, open source), contact call to action |
| Services | Consulting (posture and roadmap, vendor-neutral), AI security, defensive engineering, threat modeling and OSINT/OPSEC education, speaking |
| Experience | Sectors, scale range, the specialist network, the anonymized warning story |
| Community | Pro bono work and open source, described without names, how to ask for help |
| About | Renegade Penguin LLC, the person, link to chiefgyk3d.com |
| Contact | Business inquiries; route to be chosen (see open items) |

Cross-links: footer and About link to chiefgyk3d.com; chiefgyk3d.com gets a
business-contact link in its own repo through its own pull request.

Repo: `Renegade-Penguin/renegade-penguin-site`, public, under the Renegade-Penguin
organization because the site is tied directly to the LLC (owner decision,
2026-11-18; a few projects may migrate to that org later). Public because GYST
security needs it and the open-source ethos fits; there is no private pin layer,
since the content is not secret (assistant call). Because the repo is in the org,
CI that touches the owner's personal GitHub objects (for example project-board
sync) cannot use an org-owned private App on personal repos; any such automation
uses a GitHub App token installed where it is needed, never a PAT.

Secrets: Doppler, reusing the no-php-no-cry project with separate dev and prd
environments for this site, since the two are closely related (owner decision,
2026-11-18). The owner plans to consolidate all websites (including Reach
Around) into one Doppler project with an environment per site later, around when
this site goes to production and its Cloudflare keys are created. The build
should not make that move harder: name secrets so they relocate cleanly. The
assistant tells the owner when the first Cloudflare token is needed; nothing is
requested before then.

Contact: a Cloudflare Worker form behind Turnstile, delivering to a mailbox the
owner names (owner decision). Launch mark: the penguin with interim Jost text
(owner decision).

## Left to the builder

Hugo layouts and CSS built from the existing tokens; page copy drafts for owner
review (public copy is authored by a general model through Codex per the owner's
routing rule, used verbatim after the leak and claim checks); the Pages project
creation and domain attach through the existing scripts (the CNAME is created
separately; the API attach does not create it); smoke tests; the accessibility
and performance checks.

## Assistant calls (marked so the owner can check them)

- Stage first. The site goes live on a test hostname under the domain (dev
  tier) with its own smoke tests; the apex cutover is a separate step on the
  owner's word, matching the dev-before-prd rule.
- Cloudflare credentials follow the rotated a/b token pair pattern, dev and prd
  separate, held in Doppler. Which Doppler project holds them is an owner
  decision (existing `cloudflare` project versus a new per-product project;
  new projects need his OK).
- The domain currently has no mail records. Until the 365 alias exists, publish
  a null SPF and a reject DMARC so nobody can spoof the domain. Adding the
  alias later means replacing those records with the 365 set; track it as a
  checklist item on the mail issue.
- Tracking: one epic ("Renegade Penguin site") and issues for the build, the
  copy, the apex cutover, the mail records, the chiefgyk3d.com cross-link and
  follow-up B (shared theme module), all on a board with Kind, Epic and Effort.
- Process note: no issue can be filed until the repo exists, so the first
  action after approval is creating the repo, filing the epic and issues, and
  adding the repo to SAFO `tracking_repos` (guard file; owner OK required).

## Open items (owner)

1. Destination mailbox for the contact form (and later the 365 alias and shared
   mailboxes).
2. Confirm every credibility claim is backable (sectors, scale, in-person
   warning) and that no past confidentiality terms conflict.
3. Doppler: which secret names and which environments, once the first
   Cloudflare token is needed.
4. A designed LLC wordmark, later (launch uses the interim mark).
