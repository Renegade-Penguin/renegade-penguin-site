"""Parse a Cloudflare Pages _headers file and validate its security headers.

Usage: python3 -I scripts/check-headers.py <path to _headers>
Prints one problem per line and always exits 0; scripts/check-output.sh reports them.

The file is parsed into route blocks: a route line has no leading whitespace and the
header lines under it are indented. Rules:
  - exactly one Content-Security-Policy is set in the "/*" block;
  - no other block sets Content-Security-Policy, and no other block sets or detaches
    X-Content-Type-Options, Referrer-Policy, Strict-Transport-Security,
    Permissions-Policy or Cross-Origin-Opener-Policy differently from the "/*" block;
  - in that policy default-src is present, every directive that takes a source list
    holds only 'none' or 'self' (no wildcard, scheme, host, unsafe-* token or nonce),
    report-uri and report-to hold only a relative path, and base-uri, form-action
    and frame-ancestors are present.
"""
import sys

SAFE = {"'none'", "'self'"}
REQUIRED = ("base-uri", "form-action", "frame-ancestors")
LOCKED = ("default-src", "script-src", "style-src", "connect-src")
# Directives that take no source list; every other directive may hold only SAFE tokens.
EXEMPT = {"sandbox", "upgrade-insecure-requests", "block-all-mixed-content",
          "require-trusted-types-for", "trusted-types"}
REPORTING = ("report-uri", "report-to")
CSP = "content-security-policy"
SECURITY_HEADERS = {
    "x-content-type-options", "referrer-policy", "strict-transport-security",
    "permissions-policy", "cross-origin-opener-policy",
}
SITE_ROUTE = "/*"


def relative_path(tok):
    return tok.startswith("/") and not tok.startswith("//") and ":" not in tok


def check_policy(policy):
    problems = []
    dirs = {}
    for part in policy.split(";"):
        toks = part.split()
        if toks:
            dirs.setdefault(toks[0].lower(), [t.lower() for t in toks[1:]])
    if "default-src" not in dirs:
        problems.append("default-src missing")
    for d, toks in dirs.items():
        if d in EXEMPT:
            continue
        if d in REPORTING:
            for t in toks:
                if t != "'none'" and not relative_path(t):
                    problems.append("%s must be a relative path, found %s" % (d, t))
            continue
        if d in LOCKED and not toks:
            problems.append("%s is empty" % d)
        for t in toks:
            if t not in SAFE:
                problems.append("%s has disallowed token %s" % (d, t))
    for d in REQUIRED:
        if d not in dirs:
            problems.append("%s missing" % d)
    return problems


def parse_blocks(lines):
    """Return a list of (route, [(header_name_lower, value, detached)])."""
    blocks = []
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[0] not in " \t":
            blocks.append((line.strip(), []))
            continue
        if not blocks:
            continue
        s = line.strip()
        detached = s.startswith("!")
        if detached:
            s = s[1:].strip()
        name, _sep, value = s.partition(":")
        # A detached header has no value; None never equals a real value.
        blocks[-1][1].append((name.strip().lower(), None if detached else value.strip(), detached))
    return blocks


def check_blocks(blocks):
    problems = []
    star = [h for route, hs in blocks if route == SITE_ROUTE for h in hs]
    star_csp = [h for h in star if h[0] == CSP and not h[2]]
    if not star_csp:
        problems.append("no Content-Security-Policy in the %s block" % SITE_ROUTE)
    elif len(star_csp) > 1:
        problems.append("more than one Content-Security-Policy in the %s block" % SITE_ROUTE)
    else:
        problems.extend(check_policy(star_csp[0][1]))
    base = {h[0]: h[1] for h in star if not h[2] and h[0] in SECURITY_HEADERS}
    for route, hs in blocks:
        if route == SITE_ROUTE:
            continue
        for name, value, detached in hs:
            if name == CSP:
                problems.append("route %s sets Content-Security-Policy" % route)
            elif name in SECURITY_HEADERS:
                if detached:
                    problems.append("route %s detaches %s" % (route, name))
                elif not detached and base.get(name) != value:
                    problems.append("route %s changes %s" % (route, name))
    return problems


def main():
    try:
        with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        print("_headers missing or unreadable")
        return
    for p in check_blocks(parse_blocks(lines)):
        print(p)


main()
