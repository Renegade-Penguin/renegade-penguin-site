# Draft: "Work with me" link for chiefgyk3d.com

Status: draft for the owner to review and apply. Nothing in this repository edits the personal site.

## Placement

- A "Work with me" item in the main navigation of chiefgyk3d.com, after "About".
- One short block at the end of the About page and on the Resume page.
- Optional: a single line in the footer of every page.

## Suggested text

Navigation label: Work with me

About page block:

> Need a security architecture advisor? I run Renegade Penguin LLC, an independent security advisory. No vendor pitches, just clear answers. Start with a free fit call: https://renegadepenguinllc.com/contact/

Footer line:

> Hire me through Renegade Penguin LLC: https://renegadepenguinllc.com/

## How the link is switched on

- In the personal site repository, `params.businessSiteURL` in `hugo.toml` ships empty, and a test there requires it to stay empty. Do not put the business apex in `hugo.toml`.
- That repository's `deploy.yml` sets the staging host for the dev build.
- The owner's private production pipeline sets the environment variable `HUGO_PARAMS_BUSINESSSITEURL=https://renegadepenguinllc.com` for the production build only.
- Rollback: unset that variable and rebuild, or move the pin back.

## Mentor mention

If the owner wants the mentor mention on chiefgyk3d.com to match the business site, use the same wording the business site uses, only after the owner confirms it.

## Notes

- Use the production hostname only after the production cutover (issue #7). Until then do not publish these links; staging is not indexed and is not for public links.
- The business site already links back to https://chiefgyk3d.com/ from its "Who is behind this" block.
