"""Parse a Cloudflare Pages _headers file and validate its Content-Security-Policy.

Usage: python3 -I scripts/check-headers.py <path to _headers>
Prints one problem per line and always exits 0; scripts/check-output.sh reports them.
Rules: a CSP exists; default-src is present; every directive that takes a source list
holds only 'none' or 'self' (so no wildcard, scheme, host, unsafe-* token or nonce);
base-uri, form-action and frame-ancestors are present.
"""
import sys

SAFE = {"'none'", "'self'"}
REQUIRED = ("base-uri", "form-action", "frame-ancestors")
LOCKED = ("default-src", "script-src", "style-src", "connect-src")
# Directives that take no source list; every other directive may hold only SAFE tokens.
EXEMPT = {"sandbox", "upgrade-insecure-requests", "block-all-mixed-content",
          "report-uri", "report-to", "require-trusted-types-for", "trusted-types"}


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
        if d in LOCKED and not toks:
            problems.append("%s is empty" % d)
        for t in toks:
            if t not in SAFE:
                problems.append("%s has disallowed token %s" % (d, t))
    for d in REQUIRED:
        if d not in dirs:
            problems.append("%s missing" % d)
    return problems


def main():
    try:
        with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        print("_headers missing or unreadable")
        return
    found = False
    for line in lines:
        s = line.strip()
        if s.lower().startswith("content-security-policy:"):
            found = True
            for p in check_policy(s.split(":", 1)[1]):
                print(p)
    if not found:
        print("no Content-Security-Policy line")


main()
