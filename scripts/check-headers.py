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

One exception, the contact page (issue #4): the "/contact/*" block must replace the
all-routes policy, because Cloudflare would otherwise apply both and the browser enforces
their intersection. It lists "! Content-Security-Policy" and then sets exactly one policy,
which follows every rule above except that script-src and frame-src may also hold
https://challenges.cloudflare.com (Turnstile). That origin is allowed nowhere else, and no
other route may set or detach a policy. The other security headers are inherited from "/*".
"""
import re
import sys

SAFE = {"'none'", "'self'"}
TURNSTILE = "https://challenges.cloudflare.com"
CONTACT_ROUTE = "/contact/*"
CONTACT_ALLOW = {"script-src": {TURNSTILE}, "frame-src": {TURNSTILE}}
REQUIRED = ("base-uri", "form-action", "frame-ancestors")
LOCKED = ("default-src", "script-src", "style-src", "connect-src")
# Directives with a source list: every token must be 'none', 'self' or an extra the caller allows.
SOURCE_LIST = {
    "default-src", "script-src", "script-src-elem", "script-src-attr", "style-src",
    "style-src-elem", "style-src-attr", "img-src", "font-src", "connect-src", "media-src",
    "object-src", "child-src", "frame-src", "worker-src", "manifest-src", "prefetch-src",
    "base-uri", "form-action", "frame-ancestors",
}
# Directives with their own grammar, each handled explicitly in check_policy.
NO_VALUE = {"upgrade-insecure-requests", "block-all-mixed-content"}
SANDBOX_FLAGS = {
    "allow-downloads", "allow-forms", "allow-modals", "allow-orientation-lock",
    "allow-pointer-lock", "allow-popups", "allow-popups-to-escape-sandbox",
    "allow-presentation", "allow-same-origin", "allow-scripts",
    "allow-storage-access-by-user-activation", "allow-top-navigation",
    "allow-top-navigation-by-user-activation", "allow-top-navigation-to-custom-protocols",
}
TRUSTED_TYPES_OK = {"'none'", "'allow-duplicates'"}
REPORTING = ("report-uri", "report-to")
GROUP_NAME = re.compile(r"^[a-z0-9][a-z0-9_.-]*$")  # tokens are lower-cased before the check
KNOWN = SOURCE_LIST | NO_VALUE | set(REPORTING) | {"sandbox", "require-trusted-types-for", "trusted-types"}
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


def check_policy(policy, extra=None):
    """extra maps a directive name to additional source tokens allowed in it."""
    extra = extra or {}
    problems = []
    dirs = {}
    parsed = []
    # Parse every directive first: the name is the first token and must be a known one, so a
    # source standing where a name belongs (or a misspelled name) is a finding, not skipped.
    for part in policy.split(";"):
        toks = part.split()
        if not toks:
            continue
        name, args = toks[0].lower(), [t.lower() for t in toks[1:]]
        if name not in KNOWN:
            problems.append("unknown directive %s" % name)
            continue
        if name in dirs:
            problems.append("%s appears more than once" % name)
        dirs.setdefault(name, args)
        parsed.append((name, args))
    if "default-src" not in dirs:
        problems.append("default-src missing")
    for d, toks in parsed:
        if d in NO_VALUE:
            if toks:
                problems.append("%s takes no value, found %s" % (d, toks[0]))
        elif d == "sandbox":
            for t in toks:
                if t not in SANDBOX_FLAGS:
                    problems.append("sandbox has disallowed token %s" % t)
        elif d == "require-trusted-types-for":
            for t in toks:
                if t != "'script'":
                    problems.append("require-trusted-types-for has disallowed token %s" % t)
        elif d == "trusted-types":
            for t in toks:
                if t not in TRUSTED_TYPES_OK:
                    problems.append("trusted-types has disallowed token %s" % t)
        elif d == "report-to":
            # One group name (a token, defined by a Reporting-Endpoints or Report-To header), not a url.
            if len(toks) != 1 or not GROUP_NAME.match(toks[0]):
                problems.append("report-to must be one group name (letters, digits, - _ .)")
        elif d == "report-uri":
            for t in toks:
                if t != "'none'" and not relative_path(t):
                    problems.append("%s must be a relative path, found %s" % (d, t))
        else:  # a source list
            if d in LOCKED and not toks:
                problems.append("%s is empty" % d)
            for t in toks:
                if t not in SAFE and t not in extra.get(d, ()):
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


def grammar_problems(raw):
    """Strictness on top of the Cloudflare grammar: plain LF, space indentation, route
    lines that hold only the path. The site's own file never needs anything else."""
    problems = []
    if "\r" in raw:
        problems.append("_headers must use plain LF line endings (found a carriage return)")
    for n, line in enumerate(raw.split("\n"), 1):
        line = line.rstrip("\r")  # a carriage return is reported once, above
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[0] == "\t" or line.startswith(" \t"):
            problems.append("line %d: tab indentation is not allowed" % n)
        elif not line[0].isspace():
            if line != line.strip():
                problems.append("line %d: route line has trailing whitespace" % n)
            elif len(line.split()) != 1:
                problems.append("line %d: route line must hold only the path" % n)
    return problems


def check_blocks(blocks):
    problems = []
    routes = [route for route, _hs in blocks]
    for route in sorted(set(routes)):
        if routes.count(route) > 1:
            problems.append("route %s appears more than once" % route)
    # Every block: no detach of a protected header, no repeated protected name.
    seen_by_route = {}
    for route, hs in blocks:
        seen = seen_by_route.setdefault(route, set())
        for name, _value, detached in hs:
            if name not in PROTECTED:
                continue
            if route == CONTACT_ROUTE and name == CSP:
                continue  # judged below: detach, then set one policy
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
        if route == CONTACT_ROUTE:
            ops = [(h[2], h[1]) for h in hs if h[0] == CSP]
            if len(ops) == 2 and ops[0][0] and not ops[1][0]:
                problems.extend(check_policy(ops[1][1], CONTACT_ALLOW))
            elif ops:
                problems.append("route %s must detach Content-Security-Policy, then set exactly one" % route)
        for name, value, detached in hs:
            if detached:
                continue
            if name == CSP and route != CONTACT_ROUTE:
                problems.append("route %s sets Content-Security-Policy" % route)
            elif name in SECURITY_HEADERS and base.get(name) != value:
                problems.append("route %s changes %s" % (route, name))
    return problems


def main():
    try:
        # newline="" keeps carriage returns so they can be reported.
        with open(sys.argv[1], encoding="utf-8", errors="replace", newline="") as fh:
            raw = fh.read()
    except OSError:
        print("_headers missing or unreadable")
        return
    lines = [line.rstrip("\r") for line in raw.split("\n")]
    for p in grammar_problems(raw) + check_blocks(parse_blocks(lines)):
        print(p)


try:
    main()
except Exception as exc:  # fail closed: a crash must never read as a pass
    print("checker error: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
    sys.exit(70)
