"""Write the generated claims fixtures (invisible characters, attributes, title, price spans).

Usage: python3 -I scripts/gen-claims-fixtures.py <outdir>
Creates <outdir>/claims-bad-<name>/index.html and <outdir>/claims-ok-<name>/index.html.
Invisible and fullwidth characters are written as escapes so the repository holds none.
"""
import os
import sys

ZW = "​"
SHY = "­"
NBH = "‑"

PAGE = "<!doctype html><html lang=en><head><meta charset=utf-8>%s<title>%s</title></head><body><main>%s</main></body></html>\n"


def page(body="<p>ok</p>", head="", title="T"):
    return PAGE % (head, title, body)


BAD = {
    # finding 1: the price span is still scanned for banned phrases
    "price-span-banned": page('<p><span data-price>guaranteed 100% certified $9</span></p>'),
    # finding 2: invisible and lookalike characters
    "zwsp-entity": page("<p>guaran&#8203;tee</p>"),
    "zwsp-raw": page("<p>guaran%stee</p>" % ZW),
    "shy-certified": page("<p>certi%sfied</p>" % SHY),
    "zwsp-dollar": page("<p>$%s5,000</p>" % ZW),
    "fullwidth-dollar": page("<p>＄5,000</p>"),
    "nonbreaking-hyphen": page("<p>battle%stested</p>" % NBH),
    "percent-space": page("<p>100 %</p>"),
    "battle-space": page("<p>battle tested</p>"),
    # finding 3: attributes and title
    "alt": page('<img alt="guaranteed" src=x>'),
    "title-attr": page('<a title="100% certified">x</a>'),
    "aria-label": page('<button aria-label="guaranteed">x</button>'),
    "meta-description": page(head='<meta name="description" content="guaranteed 100%">'),
    "meta-og": page(head='<meta property="og:description" content="never failed">'),
    "meta-twitter": page(head='<meta name="twitter:title" content="battle-tested">'),
    "title-element": page(title="guaranteed"),
    "title-dollar": page(title="$5,000"),
    "alt-dollar": page('<img alt="from $5,000" src=x>'),
    # finding 4: unbalanced price spans
    "price-unclosed": page("<p><span data-price>$5</span> then <span data-price>$9</p><p>and $7 hides here</p>"),
    # no end tag at all anywhere after the price span: only the end-of-document check can see it
    "price-never-closed": "<!doctype html><html lang=en><title>T</title><p>a <span data-price>$5 and $9 forever",
    "price-unclosed-tail":page("<p>a <span data-price>$5 and $9 forever</p>"),
    # finding 5: price adjacent to a banned phrase, inline split
    "price-then-banned": page("<p><span data-price>$5</span>100%</p>"),
    "inline-split": page("<p>guar<b>antee</b></p>"),
}

OK = {
    # block elements separate text, so a word split across blocks is not a match (pinned)
    "blocks-split": page("<p>guaran</p><p>tee</p>"),
    # a price span separates text on both sides, so it never joins words (pinned)
    "price-separates": page("<p>guaran<span data-price>$5</span>tee</p>"),
    "price-text-then-word": page("<p><span data-price>guaran</span>tee</p>"),
    "word-then-price-text": page("<p>guaran<span data-price>tee</span></p>"),
    "block-start-separates": page("<div>guaran<p>tee</p></div>"),
    "block-end-separates": page("<div><p>guaran</p>tee</div>"),
    # script and style text is ignored
    "script-style-text": page('<style>.a:after{content:"$5 guaranteed"}</style><script>var a="$5 100% certified"</script>'),
    "allowed-phrases": page("<p>We are not certified, and there is no certification. Aligned to the NIST CSF.</p>"),
    "price-balanced": page("<p><span data-price>$5</span> and <span data-price><span>$9</span></span></p>"),
    "plain-meta": page(head='<meta name="description" content="Practical security advice">'),
}


def write(outdir, kind, name, html):
    d = os.path.join(outdir, "claims-%s-%s" % (kind, name))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(html)


def main():
    outdir = sys.argv[1]
    for name, html in BAD.items():
        write(outdir, "bad", name, html)
    for name, html in OK.items():
        write(outdir, "ok", name, html)


main()
