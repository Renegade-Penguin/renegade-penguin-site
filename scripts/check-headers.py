"""Parse a Cloudflare Pages _headers file and validate its Content-Security-Policy.

Usage: python3 -I scripts/check-headers.py <path to _headers>
Prints one problem per line and always exits 0; scripts/check-output.sh reports them.
Rules: a CSP exists; default-src is 'none' or 'self' only; script-src, style-src and
connect-src (when present) are 'none' or 'self' only; base-uri, form-action and
frame-ancestors are present.
"""
import sys

SAFE = {"'none'", "'self'"}
REQUIRED = ("base-uri", "form-action", "frame-ancestors")
LOCKED = ("default-src", "script-src", "style-src", "connect-src")


def check_policy(policy):
    problems = []
    dirs = {}
    for part in policy.split(";"):
        toks = part.split()
        if toks:
            dirs.setdefault(toks[0].lower(), [t.lower() for t in toks[1:]])
    if "default-src" not in dirs:
        problems.append("default-src missing")
    for d in LOCKED:
        if d in dirs:
            toks = dirs[d]
            if not toks:
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
