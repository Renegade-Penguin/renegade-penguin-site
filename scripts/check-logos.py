#!/usr/bin/env python3
"""Check the partner logo files against the provenance record (issue #120).

Usage: python3 -I scripts/check-logos.py [ROOT]
ROOT is the repository root (default: the parent of this script's directory). The checks:
  1. every file under static/brand/partners/ is on the allow list, has an entry in
     docs/logo-provenance.md, and its sha256 matches;
  2. every provenance entry names a file that exists and carries an organization, an https source
     URL, the retrieval date, the size, the terms, "used unaltered" (the bytes), and a treatment
     that is exactly "unaltered" or "mono-light"; the two kit logos (Lorikeet, Cointelegraph) must be
     "unaltered"; every other file must carry the line "permission not obtained; used on owner
     instruction 2026-11-20T14:38Z (quote: just use their logos)";
  3. each file is a valid PNG, JPEG, WebP or sanitized SVG, under 150 KB, with sane dimensions that match
     the recorded size.
Exit 0 clean, 1 on any finding (each is printed as FAIL: ...) or when nothing was collected.
"""
import hashlib
import os
import re
import struct
import sys

KIT = ("lorikeet-security.png", "cointelegraph.png")
ALLOWED = KIT + ("netjets.svg", "henry-schein.jpg", "gc-dental.webp", "call-theory.svg", "call-center-village.png")
TREATMENTS = ("unaltered", "mono-light")
PERMISSION = "permission not obtained; used on owner instruction 2026-11-20T14:38Z (quote: just use their logos)"
MAX_BYTES = 150 * 1024
PNG_SIG = b"\x89PNG\r\n\x1a\n"
SVG_BAD = (r"<script", r"foreignobject", r"\bon[a-z]+\s*=", r"javascript:", r"data:", r"<image", r"<use\b",
           r"xlink:href\s*=\s*[\"'](?!#)", r"\bhref\s*=\s*[\"'](?!#)", r"<!entity", r"@import", r"<style",
           r"url\(\s*[\"']?(?!#)")


def need(data, n, what):
    """Raise ValueError unless data holds at least n bytes (the header is not truncated)."""
    if len(data) < n:
        raise ValueError("truncated %s (%d bytes, at least %d needed)" % (what, len(data), n))


def image_size(name, data):
    """Return the pixel size as 'WxH' (an SVG gives its viewBox size).

    Raises ValueError, and only ValueError, for any invalid or truncated input: every header length is
    checked before it is unpacked."""
    if name.endswith(".png"):
        need(data, 33, "PNG header")  # signature 8 + IHDR chunk 25
        if not data.startswith(PNG_SIG) or data[12:16] != b"IHDR":
            raise ValueError("not a PNG")
        if not data.endswith(b"IEND\xaeB`\x82"):
            raise ValueError("no IEND chunk at the end")
        w, h = struct.unpack(">II", data[16:24])
        return "%dx%d" % (w, h)
    if name.endswith(".jpg"):
        need(data, 4, "JPEG")
        if not data.startswith(b"\xff\xd8\xff") or not data.endswith(b"\xff\xd9"):
            raise ValueError("not a JPEG")
        i = 2
        while i + 4 <= len(data):
            if data[i] != 0xFF:
                raise ValueError("bad JPEG marker")
            marker = data[i + 1]
            (seg,) = struct.unpack(">H", data[i + 2:i + 4])
            if marker in (0xC0, 0xC1, 0xC2):
                need(data, i + 9, "JPEG frame header")
                if seg < 8:
                    raise ValueError("bad JPEG frame header length")
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return "%dx%d" % (w, h)
            if seg < 2:
                raise ValueError("bad JPEG segment length")
            i += 2 + seg
        raise ValueError("no JPEG frame header")
    if name.endswith(".webp"):
        need(data, 16, "WebP header")
        if data[:4] != b"RIFF" or data[8:12] != b"WEBP":
            raise ValueError("not a WebP")
        kind = data[12:16]
        if kind == b"VP8X":
            need(data, 30, "WebP VP8X header")
            w = int.from_bytes(data[24:27], "little") + 1
            h = int.from_bytes(data[27:30], "little") + 1
        elif kind == b"VP8L":
            need(data, 25, "WebP VP8L header")
            if data[20] != 0x2F:
                raise ValueError("bad WebP VP8L signature")
            bits = int.from_bytes(data[21:25], "little")
            w, h = (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        elif kind == b"VP8 ":
            need(data, 30, "WebP VP8 header")
            if data[23:26] != b"\x9d\x01\x2a":
                raise ValueError("bad WebP VP8 start code")
            w, h = struct.unpack("<HH", data[26:30])
            w, h = w & 0x3FFF, h & 0x3FFF
        else:
            raise ValueError("unknown WebP chunk")
        return "%dx%d" % (w, h)
    if name.endswith(".svg"):
        m = re.search(rb'viewBox="\s*[-0-9.]+[ ,]+[-0-9.]+[ ,]+([0-9.]+)[ ,]+([0-9.]+)\s*"', data)
        if not m:
            raise ValueError("svg without a viewBox")
        try:
            float(m.group(1))
            float(m.group(2))
        except ValueError:
            raise ValueError("svg viewBox is not numeric")
        return "%sx%s" % (m.group(1).decode(), m.group(2).decode())
    raise ValueError("neither PNG, JPEG, WebP nor SVG")


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


def treatments(root):
    """Map file name -> treatment from the provenance record."""
    prov = os.path.join(root, "docs", "logo-provenance.md")
    return {os.path.basename(e["path"]): e.get("treatment", "") for e in parse_provenance(prov) if "path" in e}


def check(root):
    fails = []
    pdir = os.path.join(root, "static", "brand", "partners")
    prov = os.path.join(root, "docs", "logo-provenance.md")
    files = sorted(os.listdir(pdir)) if os.path.isdir(pdir) else []
    if not files:
        return ["no files collected under static/brand/partners/"]
    if not os.path.isfile(prov):
        return ["docs/logo-provenance.md is missing"]
    entries = {e.get("path", ""): e for e in parse_provenance(prov) if "path" in e}
    for f in files:
        rel = "static/brand/partners/" + f
        data = open(os.path.join(pdir, f), "rb").read()
        e = entries.get(rel)
        if f not in ALLOWED:
            fails.append("%s is not an allowed partner logo" % rel)
        if e is None:
            fails.append("%s has no provenance entry" % rel)
        else:
            digest = hashlib.sha256(data).hexdigest()
            if e.get("sha256") != digest:
                fails.append("%s sha256 %s does not match the record %s" % (rel, digest, e.get("sha256")))
            for k in ("organization", "source", "retrieved", "terms", "type", "size", "treatment"):
                if not e.get(k):
                    fails.append("%s provenance lacks %s" % (rel, k))
            if e.get("retrieved") != "2026-11-20":
                fails.append("%s provenance retrieved date is not 2026-11-20" % rel)
            if not str(e.get("source", "")).startswith("https://"):
                fails.append("%s provenance source is not an https URL" % rel)
            if "used unaltered" not in e.get("altered", "").lower():
                fails.append("%s provenance lacks the statement 'used unaltered'" % rel)
            t = e.get("treatment", "")
            if t and t not in TREATMENTS:
                fails.append("%s treatment %r is not one of %s" % (rel, t, ", ".join(TREATMENTS)))
            if f in KIT and t != "unaltered":
                fails.append("%s is a kit logo and must have treatment unaltered" % rel)
            if f not in KIT and e.get("permission") != PERMISSION:
                fails.append("%s provenance lacks the permission line" % rel)
        if len(data) >= MAX_BYTES:
            fails.append("%s is %d bytes, 150 KB or more" % (rel, len(data)))
        try:
            size = image_size(f, data)
            w, h = (float(x) for x in size.split("x"))
        except ValueError as ex:
            fails.append("%s: %s" % (rel, ex))
            continue
        except (struct.error, IndexError, OverflowError) as ex:  # second layer; image_size should not raise these
            fails.append("%s: unreadable image (%s)" % (rel, ex))
            continue
        if not (16 <= w <= 4000 and 16 <= h <= 4000):
            fails.append("%s has odd dimensions %s" % (rel, size))
        if e is not None and e.get("size") != size:
            fails.append("%s size %s does not match the record %s" % (rel, size, e.get("size")))
        if f.endswith(".svg"):
            for p in svg_problems(data.decode("utf-8", "replace")):
                fails.append("%s: svg contains a forbidden construct (%s)" % (rel, p))
    for rel in entries:
        if not os.path.isfile(os.path.join(root, rel)):
            fails.append("provenance entry %s has no file" % rel)
    return fails


def main(argv):
    root = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    try:
        fails = check(root)
    except Exception as ex:  # never a traceback: a checker crash is a failure with a message
        fails = ["the checker could not read the tree (%s: %s)" % (type(ex).__name__, ex)]
    for f in fails:
        print("FAIL: " + f)
    if fails:
        return 1
    print("PASS: partner logos match the provenance record")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
