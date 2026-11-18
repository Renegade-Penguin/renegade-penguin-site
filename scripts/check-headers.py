"""Parse a Cloudflare Pages _headers file and validate its security headers.

Usage: python3 -I scripts/check-headers.py <path to _headers>
Prints one problem per line and always exits 0; scripts/check-output.sh reports them.

The file is parsed into route blocks: a route line has no leading whitespace and the
header lines under it are indented. Rules:
  - nothing detaches ("! Name") Content-Security-Policy or a protected header, and no
    block repeats a protected header name (case-insensitive);
  - exactly one Content-Security-Policy is set in the "/*" block, and each of the five
    protected headers appears there once with an acceptable value (nosniff;
    same-origin; a safe referrer policy; a deny-all feature=() Permissions-Policy; HSTS
    with one standalone max-age directive of 10 digits or fewer, at least one year);
  - no other block sets Content-Security-Policy or sets a protected header
    (X-Content-Type-Options, Referrer-Policy, Strict-Transport-Security,
    Permissions-Policy, Cross-Origin-Opener-Policy) differently from the "/*" block;
  - in that policy default-src is present, every directive that takes a source list
    holds only 'none' or 'self' (no wildcard, scheme, host, unsafe-* token or nonce),
    report-uri and report-to hold only a relative path, and base-uri, form-action
    and frame-ancestors are present.
"""
import re
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
PROTECTED = SECURITY_HEADERS | {CSP}
SITE_ROUTE = "/*"
REFERRER_OK = {"no-referrer", "same-origin", "strict-origin", "strict-origin-when-cross-origin"}


HSTS_MIN = 31536000
DENY_ALL = re.compile(r"^[a-z][a-z0-9-]*=\(\)$")


def hsts_ok(value):
    """Semicolon-separated directives with exactly one standalone max-age directive:
    digits only (at most 10, so no huge integer conversion), at least one year."""
    ages = []
    for part in value.split(";"):
        name, sep, val = part.strip().partition("=")
        if name.strip().lower() == "max-age":
            ages.append(val.strip() if sep else "")
    if len(ages) != 1:
        return False
    age = ages[0]
    return age.isascii() and age.isdigit() and len(age) <= 10 and int(age) >= HSTS_MIN


def permissions_ok(value):
    """Non-empty, comma-separated, every directive of the deny-all form feature=()."""
    items = [i.strip() for i in value.split(",")]
    return bool(value.strip()) and all(DENY_ALL.match(i) for i in items)


# Acceptable values for the protected headers when set in the "/*" block.
VALUE_RULES = {
    "x-content-type-options": lambda v: v.lower() == "nosniff",
    "cross-origin-opener-policy": lambda v: v.lower() == "same-origin",
    "referrer-policy": lambda v: v.lower() in REFERRER_OK,
    "strict-transport-security": hsts_ok,
    "permissions-policy": permissions_ok,
}


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
    # Every block: no detach of a protected header, no repeated protected name.
    seen_by_route = {}
    for route, hs in blocks:
        seen = seen_by_route.setdefault(route, set())
        for name, _value, detached in hs:
            if name not in PROTECTED:
                continue
            if detached:
                problems.append("route %s detaches %s" % (route, name))
            if name in seen:
                problems.append("route %s repeats %s" % (route, name))
            seen.add(name)
    # The "/*" block: the set headers, as the server will apply them.
    star = [h for route, hs in blocks if route == SITE_ROUTE for h in hs if not h[2]]
    star_csp = [h for h in star if h[0] == CSP]
    if not star_csp:
        problems.append("no Content-Security-Policy in the %s block" % SITE_ROUTE)
    elif len(star_csp) > 1:
        problems.append("more than one Content-Security-Policy in the %s block" % SITE_ROUTE)
    else:
        problems.extend(check_policy(star_csp[0][1]))
    base = {}
    for name, value, _detached in star:
        if name in SECURITY_HEADERS:
            base[name] = value
            if not VALUE_RULES[name](value):
                problems.append("%s has an unacceptable value in %s" % (name, SITE_ROUTE))
    for name in sorted(SECURITY_HEADERS):
        if name not in base:
            problems.append("%s missing from the %s block" % (name, SITE_ROUTE))
    for route, hs in blocks:
        if route == SITE_ROUTE:
            continue
        for name, value, detached in hs:
            if detached:
                continue
            if name == CSP:
                problems.append("route %s sets Content-Security-Policy" % route)
            elif name in SECURITY_HEADERS and base.get(name) != value:
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


try:
    main()
except Exception as exc:  # fail closed: a crash must never read as a pass
    print("checker error: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
    sys.exit(70)
