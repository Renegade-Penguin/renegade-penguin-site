#!/usr/bin/env python3
"""Check the partner logo files against the provenance record (issue #120).

Usage: python3 -I scripts/check-logos.py [ROOT]
ROOT is the repository root (default: the parent of this script's directory). The checks:
  1. every file under static/brand/partners/ is on the allow list (the two organizations that
     publish an official kit), has an entry in docs/logo-provenance.md, and its sha256 matches;
  2. every provenance entry names a file that exists, and the entry carries a source URL,
     a retrieval date and the statement "used unaltered";
  3. each file is a valid PNG (signature, IHDR, IEND) or a sanitized SVG, under 150 KB,
     with sane pixel dimensions, and its pixel size matches the one recorded.
Exit 0 clean, 1 on any finding (each is printed as FAIL: ...) or when nothing was collected.
"""
import hashlib
import os
import re
import struct
import sys

ALLOWED = ("lorikeet-security.png", "cointelegraph.png")
MAX_BYTES = 150 * 1024
PNG_SIG = b"\x89PNG\r\n\x1a\n"
SVG_BAD = (r"<script", r"foreignobject", r"\bon[a-z]+\s*=", r"javascript:", r"data:", r"<image", r"<use\b",
           r"xlink:href\s*=\s*[\"'](?!#)", r"\bhref\s*=\s*[\"'](?!#)", r"<!entity", r"@import", r"url\(\s*[\"']?(?!#)")


def png_size(data):
    if not data.startswith(PNG_SIG):
        raise ValueError("not a PNG")
    if data[12:16] != b"IHDR":
        raise ValueError("no IHDR chunk first")
    w, h = struct.unpack(">II", data[16:24])
    if not data.endswith(b"IEND\xaeB`\x82"):
        raise ValueError("no IEND chunk at the end")
    return w, h


def svg_problems(text):
    low = text.lower()
    return [p for p in SVG_BAD if re.search(p, low)]


def parse_provenance(path):
    """Entries are '## slug' sections with '- Key: value' lines; values may sit in backticks."""
    entries = []
    cur = None
    for line in open(path, encoding="utf-8").read().splitlines():
        if line.startswith("## "):
            cur = {"slug": line[3:].strip()}
            entries.append(cur)
            continue
        m = re.match(r"^- ([A-Za-z0-9 ]+): (.*)$", line)
        if m and cur is not None:
            cur[m.group(1).strip().lower()] = m.group(2).strip().strip("`")
    return entries


def check(root):
    fails = []
    pdir = os.path.join(root, "static", "brand", "partners")
    prov = os.path.join(root, "docs", "logo-provenance.md")
    files = sorted(f for f in os.listdir(pdir)) if os.path.isdir(pdir) else []
    if not files:
        return ["no files collected under static/brand/partners/"]
    if not os.path.isfile(prov):
        return ["docs/logo-provenance.md is missing"]
    entries = {e.get("path", ""): e for e in parse_provenance(prov) if "path" in e}
    for f in files:
        rel = "static/brand/partners/" + f
        full = os.path.join(pdir, f)
        if f not in ALLOWED:
            fails.append("%s is not an allowed partner logo" % rel)
        e = entries.get(rel)
        if e is None:
            fails.append("%s has no provenance entry" % rel)
        data = open(full, "rb").read()
        digest = hashlib.sha256(data).hexdigest()
        if e is not None:
            if e.get("sha256") != digest:
                fails.append("%s sha256 %s does not match the record %s" % (rel, digest, e.get("sha256")))
            for k in ("organization", "source", "retrieved", "terms", "type", "size"):
                if not e.get(k):
                    fails.append("%s provenance lacks %s" % (rel, k))
            if e.get("retrieved") != "2026-11-20":
                fails.append("%s provenance retrieved date is not 2026-11-20" % rel)
            if not str(e.get("source", "")).startswith("https://"):
                fails.append("%s provenance source is not an https URL" % rel)
            if "used unaltered" not in e.get("altered", "").lower():
                fails.append("%s provenance lacks the statement 'used unaltered'" % rel)
        if len(data) >= MAX_BYTES:
            fails.append("%s is %d bytes, 150 KB or more" % (rel, len(data)))
        if f.endswith(".png"):
            try:
                w, h = png_size(data)
            except ValueError as ex:
                fails.append("%s: %s" % (rel, ex))
                continue
            if not (16 <= w <= 4000 and 16 <= h <= 4000):
                fails.append("%s has odd dimensions %dx%d" % (rel, w, h))
            if e is not None and e.get("size") != "%dx%d" % (w, h):
                fails.append("%s pixel size %dx%d does not match the record %s" % (rel, w, h, e.get("size")))
        elif f.endswith(".svg"):
            for p in svg_problems(data.decode("utf-8", "replace")):
                fails.append("%s: svg contains a forbidden construct (%s)" % (rel, p))
        else:
            fails.append("%s is neither PNG nor SVG" % rel)
    for rel in entries:
        if not os.path.isfile(os.path.join(root, rel)):
            fails.append("provenance entry %s has no file" % rel)
    return fails


def main(argv):
    root = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    fails = check(root)
    for f in fails:
        print("FAIL: " + f)
    if fails:
        return 1
    print("PASS: partner logos match the provenance record")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
