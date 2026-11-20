# Partner logo provenance

Seven organizations are shown with a logo; the eighth, SML Labs, stays a styled text tile (see the end).

Two organizations publish an official logo kit whose terms allow this use: Lorikeet Security and
Cointelegraph. Their files are shown unaltered, with no CSS effect at all.

For the other five (NetJets, Henry Schein, GC Dental, Call Theory, Call Center Village) permission was NOT
obtained. The owner decided to use their logos anyway, on 2026-11-20 at 14:38Z: "just use their logos". Each
of those files comes from the organization's own site (never an aggregator, stock site or search engine), is
the original bytes as published, and was not traced, redrawn or recreated. Their terms for logo use were not
reviewed. If an organization asks, remove its file, its data entry and its entry here.

Every file is served from the site's own origin. The bytes are never edited. The Treatment field says how it
is shown: `unaltered` means no CSS effect; `mono-light` means the one class `.partner-logo--mono` (a fixed
grayscale, invert, screen blend and modest opacity, so a dark mark or a white background reads as a muted
light mark on the dark tile, with no light plate). Size is set only by the img width and height attributes.
`scripts/test-logos.sh` fails when a file under `static/brand/partners/` has no entry here, its sha256 or
size differs, its treatment is missing or not one of the two values, a kit logo has a mono treatment, a
non-kit file lacks the permission line, or the built page applies an effect that its treatment does not
allow. Keep the entry format: a `## slug` heading and one `- Key: value` line per field.

## lorikeet-security

- Organization: Lorikeet Security
- Path: `static/brand/partners/lorikeet-security.png`
- Source: https://lorikeetsecurity.com/images/lorikeet-logo-banner.png
- Kit page: https://lorikeetsecurity.com/brand-guidelines
- Retrieved: 2026-11-20
- Sha256: `8ab3bb411cae7f7ec9c87c7e09f721f86580b6e7bb9b6d3e50ec27e87d53ad57`
- Type: PNG, RGBA, white logotype on a transparent background, for dark backgrounds
- Size: `695x216`
- Terms: Lorikeet's brand guidelines (https://lorikeetsecurity.com/brand-guidelines) offer this file for dark backgrounds and forbid recoloring, gradients, shadows and 3D effects, placing the white logo on a light background, a horizontal lockup narrower than 140 px, and less clear space than the shield height on all four sides.
- Treatment: unaltered
- Altered: used unaltered

## cointelegraph

- Organization: Cointelegraph
- Path: `static/brand/partners/cointelegraph.png`
- Source: https://s3.cointelegraph.com/storage/uploads/view/4753c94c313bafb58a792bc6be2df4b0.zip
- Kit page: https://cointelegraph.com/about
- Guidelines: https://s3.cointelegraph.com/storage/uploads/view/2782e99eac59882c88fdac171dce4422.pdf
- Member: `Cointelegraph All Brand Resources/Cointelegraph_logo/CT logo WhiteYellow tag.png`
- Retrieved: 2026-11-20
- Sha256: `b3aade70a7dd69e9d42b06c82758e1ee5f6287b338944181d7d14d3a97b17a29`
- Type: PNG, RGBA, yellow icon and wordmark with a white tagline on a transparent background, for dark backgrounds
- Size: `1262x362`
- Terms: Cointelegraph's brand resources (https://cointelegraph.com/about) and logo guidelines require the logo with its icon (no text only wordmark), white or brand color backgrounds, no non-brand colors, shading or alternative compositions, a minimum height of 32 points, and the free zone kept around the logo.
- Treatment: unaltered
- Altered: used unaltered

## netjets

- Organization: NetJets
- Path: `static/brand/partners/netjets.svg`
- Source: https://www.netjets.com/en-us/
- Source note: the page header carries the logo as one self-contained inline svg element (class Logo___StyledSvgIcon, title NetJets); it was copied out verbatim, byte for byte, as the whole file. The page itself is the only first-party source found; netjets.com serves no standalone logo file.
- Retrieved: 2026-11-20
- Sha256: `6c5b7294ae596e6537cc1edf375d4c8fe762d2f3b275b3e409ca460acb49d0d8`
- Type: SVG, one title and one path, black by default, no script, style, href or external reference
- Size: `646.18x128.09`
- Terms: NetJets publishes no logo kit that was found, and its terms for logo use were not reviewed.
- Permission: permission not obtained; used on owner instruction 2026-11-20T14:38Z (quote: just use their logos)
- Treatment: mono-light
- Altered: used unaltered

## henry-schein

- Organization: Henry Schein
- Path: `static/brand/partners/henry-schein.jpg`
- Source: https://www.henryschein.com/us-en/images/corporate/henry-schein-logo-01-21CC8902.jpg
- Source note: the first of three logo files offered on the company press kits page, https://www.henryschein.com/us-en/corporate/press-kits-henry-schein.aspx
- Retrieved: 2026-11-20
- Sha256: `86d8c969bdba107b75a9538efac1bb220b61bb92d2249aecf1af9c24a9d79e5e`
- Type: JPEG, progressive, opaque white background, logo only (no tagline)
- Size: `600x150`
- Terms: Henry Schein offers the file on its press kits page; the terms for logo use on that page were not reviewed.
- Permission: permission not obtained; used on owner instruction 2026-11-20T14:38Z (quote: just use their logos)
- Treatment: mono-light
- Altered: used unaltered

## gc-dental

- Organization: GC Dental
- Path: `static/brand/partners/gc-dental.webp`
- Source: https://www.gc.dental/america/themes/custom/gc/gcfujibase/images/logo.webp
- Source note: the header logo of the GC America site, https://www.gc.dental/america
- Retrieved: 2026-11-20
- Sha256: `185ade3e39b0522ee197550b001f8f7b6243af9067aab3457184e8e12458b2a5`
- Type: WebP, RGBA, green GC mark, a Smile for the World badge and a gray slogan line, on a transparent background
- Size: `509x64`
- Terms: GC publishes no logo kit that was found, and its terms for logo use were not reviewed.
- Permission: permission not obtained; used on owner instruction 2026-11-20T14:38Z (quote: just use their logos)
- Treatment: unaltered
- Altered: used unaltered

## call-theory

- Organization: Call Theory
- Path: `static/brand/partners/call-theory.svg`
- Source: https://calltheory.com/calltheory-icon.svg
- Source note: the site icon, which is also the logo in the site header (the same drawing as the inline svg in the header of https://calltheory.com/). It is the company's own mark; the Orbital product mark is not used.
- Retrieved: 2026-11-20
- Sha256: `dde94e6bbff14299118cb94112a46db049948b143f16705edb8449e5089a66c5`
- Type: SVG, paths and clip paths only (internal url(#id) references), white disc with black, purple and blue marks, no script, style, href or external reference
- Size: `375x374.999991`
- Terms: Call Theory publishes no logo kit that was found, and its terms for logo use were not reviewed.
- Permission: permission not obtained; used on owner instruction 2026-11-20T14:38Z (quote: just use their logos)
- Treatment: unaltered
- Altered: used unaltered

## call-center-village

- Organization: Call Center Village
- Path: `static/brand/partners/call-center-village.png`
- Source: https://callcentervillage.com/_next/static/media/2026-callcentervillage-logo.ba0e4b98.png
- Source note: the header logo of the Call Center Village site (the 2026 Social Engineering badge)
- Retrieved: 2026-11-20
- Sha256: `876cfb763b82e9ebda85aae96ffca1f5b9d4dec7a5c9d076375896cfeff3d8ef`
- Type: PNG, RGBA, round badge on a transparent background
- Size: `500x500`
- Terms: Call Center Village publishes no logo kit that was found, and its terms for logo use were not reviewed.
- Permission: permission not obtained; used on owner instruction 2026-11-20T14:38Z (quote: just use their logos)
- Treatment: unaltered
- Altered: used unaltered

## sml-labs (no file)

SML Labs stays a styled text tile. The only usable first-party logo is
https://smlglobal.com/sites/default/files/sml_logo-cropped.png (648x420, PNG): its mark is dark blue with
opaque white letters and an opaque white panel, so on the dark tile it either vanishes (original colors,
about 2:1 contrast) or becomes a solid white block (mono treatment), which the dark-only rule forbids. The
only other first-party logo, https://smlglobal.com/themes/custom/sml/images/mobi_logo.gif, is 73x49 and too
small. No file of it is shipped.
