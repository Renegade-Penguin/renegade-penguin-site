#!/usr/bin/env bash
# Targeted test for the answer-first lede and the FAQ on five pages (issue #95). Builds production
# and checks, on each of the five pages: exactly one p.answer equal to the approved lede and the
# first element after the h1, exactly four details.faq with the exact question and answer text,
# and an H2 "Questions" id=questions. Every other page has none of these. No dashes, no bare "crypto".
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUGO="${HUGO:-hugo}"
BASE="${TEST_TMP_BASE:-$HOME/.local/share/renegade-penguin-site-dev}"
mkdir -p "$BASE" || exit 1
TMP="$(mktemp -d -p "$BASE" faq.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
"$HUGO" --minify --destination "$TMP/prod" >/dev/null || fail "production build"
python3 -I - "$TMP/prod" <<'PY'
import html
import pathlib
import re
import sys

EXPECT = {
    "/services/advisory/": (
        "Renegade Penguin provides ongoing virtual CISO and CIO style guidance for small and midsize organizations. It is for organizations that need senior security and IT direction without hiring a full-time executive.",
        [
            ("How does the advisory engagement begin?", "It begins with a one-time paid assessment. Part of that fee is credited if the organization signs a retainer within 60 days."),
            ("Is the retainer a long-term commitment?", "No. The retainer runs month to month with no lock-in."),
            ("What does ongoing advisory work include?", "It can include roadmaps, policy and risk ownership, vendor evaluation, incident preparation, leadership reporting, and reviews of contracts and security questionnaires."),
            ("What is outside the advisory retainer?", "It is not a managed security service, help desk, outsourced IT department, penetration test, legal opinion, or assurance against incidents. Hands-on engineering is scoped as a separate project."),
        ],
    ),
    "/services/projects/": (
        "Renegade Penguin handles fixed-scope defensive engineering, hardening, and AI security reviews. These projects are for organizations that need defined security work, documented deliverables, and clear exclusions.",
        [
            ("What systems can a defensive engineering project cover?", "Projects can cover identity and access, endpoints, servers, networks, cloud services, SaaS, logging, recovery, secure baselines, incident playbooks, architecture, and data flows."),
            ("Can a project include a security roadmap?", "Yes. Roadmaps can be aligned to NIST CSF, CIS Controls, ISO 27001, or the HIPAA Security Rule."),
            ("How is a project scoped and quoted?", "A scoping call establishes the work before it is quoted. The written scope defines the deliverables and exclusions."),
            ("What can the final deliverables include?", "Deliverables may include findings, prioritized recommendations, configuration changes, diagrams, runbooks, decision records, and a handoff session."),
        ],
    ),
    "/pricing/": (
        "Renegade Penguin publishes starting points, not automatic quotes. A free 30-minute fit call checks for fit, then a scoping call confirms the work before a paid assessment or other engagement begins.",
        [
            ("Does every advisory engagement start with an assessment?", "Yes. Ongoing advisory work starts with a paid assessment before moving to a retainer."),
            ("How do retainers work?", "Retainers run month to month with 30 days notice. Unused hours reset each month, with limited carry."),
            ("What is excluded from the listed starting points?", "Unless included in writing, fees exclude licenses, hardware, travel, taxes, legal services, penetration testing, continuous monitoring, managed services, emergency response, and outside specialists."),
            ("Does Renegade Penguin charge for speaking and education?", "Fees apply to corporate and vendor speaking. Community and non-corporate education is free, provided at cost, or arranged separately."),
        ],
    ),
    "/ohio/": (
        "Renegade Penguin helps Ohio organizations assess controls and build written cybersecurity programs aligned to recognized frameworks. This work may support businesses evaluating the affirmative defense described in Ohio Revised Code sections 1354.02 and 1354.03.",
        [
            ("What do these Ohio Revised Code sections provide?", "They give certain covered businesses an affirmative defense in some data breach lawsuits when they create, maintain, and follow a qualifying written cybersecurity program."),
            ("What must the cybersecurity program address?", "It must reasonably conform to a recognized framework and fit the business's size, activities, information, and resources."),
            ("Does the affirmative defense prevent a breach or lawsuit?", "No. An affirmative defense is not immunity, does not prevent a breach, and does not prevent someone from filing a lawsuit."),
            ("Can Renegade Penguin determine whether a business is eligible?", "Eligibility depends on the facts. The firm can assess controls and help build a framework-aligned program, but it does not provide legal advice. Organizations should talk to qualified counsel."),
        ],
    ),
    "/who-we-help/healthcare-dental/": (
        "Renegade Penguin helps healthcare and dental practices examine how they protect patient information. The work covers HIPAA Security Rule risk analysis, vendor and business associate questions, and readiness for ransomware and operational disruption.",
        [
            ("What does a HIPAA Security Rule risk analysis examine?", "It describes how electronic protected health information moves through the practice, where it is stored, who can reach it, and what could affect it."),
            ("Can a consultant certify our practice or sign off on our HIPAA status?", "No. HIPAA certification does not exist, and no consultant can issue one."),
            ("Will Renegade Penguin sign a business associate agreement?", "The firm signs a business associate agreement when its work involves protected health information, subject to case-by-case review before work begins."),
            ("What does ransomware and disruption readiness cover?", "It examines whether backups can be restored, which systems return first, what downtime procedures apply, and who makes the necessary decisions."),
        ],
    ),
}


def txt(s):
    return html.unescape(re.sub(r"<[^>]+>", "", s)).strip()


def check(rel, doc, want):
    """Return a list of problems for one page. want is (lede, [(q, a)]) or None (no FAQ allowed)."""
    errs = []
    art = re.search(r"<article[ >].*?</article>", doc, re.S)
    if not art:
        if want is None:
            # The home page keeps its own FAQ section, outside an article; only an answer paragraph is barred here.
            return [] if not re.search(r"<p class=\"?answer\"?>", doc) else ["%s: answer outside an article" % rel]
        return ["%s: no article" % rel]
    art = art.group(0)
    answers = re.findall(r"<p class=\"?answer\"?>(.*?)</p>", art, re.S)
    details = re.findall(r"<details class=\"?faq\"?>\s*<summary>(.*?)</summary>\s*<p>(.*?)</p>\s*</details>", art, re.S)
    qh = re.findall(r"<h2[^>]*>\s*Questions\s*</h2>", art)
    if want is None:
        # Exemption (issue #98): pages under /guides/ keep their verbatim hand-written Questions H2 with H3
        # questions and inline links; scripts/test-guides.sh asserts the 4 H3 questions on each. Only that
        # H2 is allowed there: p.answer and details.faq stay barred, and every other page keeps the full rule.
        if rel.startswith("/guides/"):
            qh = []
        if answers or details or qh:
            errs.append("%s: has answer/faq/Questions but should not" % rel)
        return errs
    lede, items = want
    if len(answers) != 1:
        errs.append("%s: %d p.answer, want 1" % (rel, len(answers)))
    elif txt(answers[0]) != lede:
        errs.append("%s: lede text differs: %r" % (rel, txt(answers[0])))
    first = re.match(r"<article[^>]*>\s*<h1[^>]*>.*?</h1>\s*<p class=\"?answer\"?>", art, re.S)
    if not first:
        errs.append("%s: the answer is not the first element after the h1" % rel)
    if len(details) != 4:
        errs.append("%s: %d details.faq, want 4" % (rel, len(details)))
    elif [(txt(a), txt(b)) for a, b in details] != items:
        errs.append("%s: FAQ text differs from the approved copy" % rel)
    if len(qh) != 1 or not re.search(r"<h2[^>]*\bid=\"?questions\"?[ >]", art):
        errs.append("%s: want one H2 Questions with id=questions" % rel)
    # The Questions section is last: no H2 after it.
    m = re.search(r"<h2[^>]*\bid=\"?questions\"?[ >]", art)
    if m and re.search(r"<h2[ >]", art[m.end():]):
        errs.append("%s: an H2 follows Questions" % rel)
    blob = " ".join([lede] + [q + " " + a for q, a in items])
    for ch in (chr(0x2014), chr(0x2013)):
        if ch in blob:
            errs.append("%s: dash in copy" % rel)
    if re.search(r"\bcrypto\b", blob, re.I):
        errs.append("%s: bare crypto in copy" % rel)
    return errs


root = pathlib.Path(sys.argv[1])
fails = []
seen = 0
for p in sorted(root.rglob("index.html")):
    rel = "/" + str(p.relative_to(root).parent).replace(".", "") + "/"
    rel = rel.replace("//", "/")
    doc = p.read_text(encoding="utf-8")
    fails += check(rel, doc, EXPECT.get(rel))
    seen += 1
for rel in EXPECT:
    if not (root / rel.strip("/") / "index.html").is_file():
        fails.append("%s: page not built" % rel)
if seen < 10:
    fails.append("collected too few pages: %d" % seen)

# Negative cases: each guard must bite on a tampered copy of a good page.
if not fails:
    rel = "/services/advisory/"
    good = (root / "services/advisory/index.html").read_text(encoding="utf-8")
    w = EXPECT[rel]
    assert not check(rel, good, w), "good page must pass"
    lede = w[0]
    cases = {
        "lede text": good.replace(lede, lede + " x", 1),
        "second answer": good.replace("</article>", "<p class=answer>y</p></article>", 1),
        "not first": re.sub(r"(</h1>)", r"\1<p>intro</p>", good, count=1),
        "faq answer text": good.replace("<p>" + w[1][1][1], "<p>" + w[1][1][1] + "!", 1),
        "faq count": re.sub(r"<details class=\"?faq\"?>.*?</details>", "", good, count=1, flags=re.S),
        "no Questions h2": re.sub(r"<h2[^>]*>\s*Questions\s*</h2>", "", good),
    }
    for name, doc in cases.items():
        assert check(rel, doc, w), "guard does not bite: " + name
    assert check("/contact/", good, None), "no-faq guard does not bite"
    # The /guides/ exemption covers only a hand-written Questions H2; everything else stays barred there.
    gpath = "/guides/what-is-a-vciso/"
    guide = (root / "guides/what-is-a-vciso/index.html").read_text(encoding="utf-8")
    assert re.search(r"<h2[^>]*>\s*Questions\s*</h2>", guide), "guide fixture lost its Questions H2"
    assert not check(gpath, guide, None), "guide with a hand-written Questions H2 must pass"
    assert check(gpath, guide.replace("</article>", "<p class=answer>y</p></article>", 1), None), "guide p.answer not barred"
    assert check(gpath, guide.replace("</article>", "<details class=faq><summary>q</summary><p>a</p></details></article>", 1), None), "guide details.faq not barred"
    assert check("/contact/", guide, None), "Questions H2 on a non-guide page not barred"
    assert check("/other/", guide, None), "Questions H2 outside /guides/ not barred"
    assert check("/guidesx/a/", guide, None), "prefix lookalike of /guides/ not barred"
    dashed = ("A" + chr(0x2014) + "B", w[1])
    assert any("dash" in e for e in check(rel, good, dashed)), "dash guard does not bite"
    crypto = (w[0] + " crypto", w[1])
    assert any("crypto" in e for e in check(rel, good, crypto)), "crypto guard does not bite"

for f in fails:
    print("FAIL: " + f, file=sys.stderr)
sys.exit(1 if fails else 0)
PY
rc=$?
[ "$rc" = 0 ] && echo "test-faq: ok"
exit "$rc"
