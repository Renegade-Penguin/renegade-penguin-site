#!/usr/bin/env python3
"""Static guard for .github/workflows/ci.yml and .github/dependabot.yml.

Run as: python3 -I scripts/test-ci-workflow.py [workflow] [dependabot]
Stdlib only, line based (no YAML parser). Asserts:
  - a job named exactly "CI green" exists
  - every `uses:` carries a 40-hex SHA and a `# v...` version comment
  - no pull_request_target
  - no github.event.* expression inside a run script
  - dependabot has the github-actions ecosystem with cooldown default-days 7
Each guard has a negative case run against a bad sample, proving it bites.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
USES = re.compile(r"^\s*(?:-\s+)?uses:\s*(\S+)(.*)$")
PIN = re.compile(r"@[0-9a-f]{40}$")
VCOMMENT = re.compile(r"#\s*v\d")


def block(lines, key, indent):
    """Lines of the mapping entry `key:` at exactly `indent` spaces, up to the next
    line indented `indent` or less. Empty list when the key is absent."""
    head = " " * indent + key + ":"
    for i, line in enumerate(lines):
        if line.rstrip() == head or line.startswith(head + " "):
            out = []
            for nxt in lines[i + 1:]:
                if nxt.strip() and len(nxt) - len(nxt.lstrip()) <= indent:
                    break
                out.append(nxt)
            return out
    return []


def direct(blk, key, indent):
    """Value text of `key:` at exactly `indent` spaces inside a block, else None."""
    pre = " " * indent + key + ":"
    for line in blk:
        if line.startswith(pre) and (len(line) == len(pre) or line[len(pre)] == " "):
            return line[len(pre):].split(" #")[0].strip()
    return None


def check_gate(lines):
    errs = []
    jobs = block(lines, "jobs", 0)
    gate = block(jobs, "ci-green", 2)
    if not gate:
        return ["no ci-green job"]
    if direct(gate, "name", 4) != "CI green":
        errs.append('ci-green job name is not exactly "CI green" (job level)')
    if direct(gate, "if", 4) != "always()":
        errs.append("ci-green job lacks if: always()")
    needs = direct(gate, "needs", 4)
    got = sorted(x.strip() for x in needs.strip("[]").split(",")) if needs else []
    if got != ["ci", "security", "shell"]:
        errs.append("ci-green needs is not exactly ci, shell, security: %s" % got)
    sec = block(jobs, "security", 2)
    perms = block(sec, "permissions", 4)
    for scope in ("id-token", "security-events", "pull-requests"):
        if direct(perms, scope, 6) != "write":
            errs.append("security job does not grant %s: write" % scope)
    top = [l for l in block(lines, "permissions", 0) if l.strip()]
    if [l.strip() for l in top] != ["contents: read"]:
        errs.append("workflow-level permissions are not exactly contents: read: %s" % top)
    return errs


def check_workflow(text):
    errs = check_gate(text.splitlines())
    lines = text.splitlines()
    if "pull_request_target" in text:
        errs.append("pull_request_target present")
    uses = 0
    for n, line in enumerate(lines, 1):
        m = USES.match(line)
        if not m:
            continue
        uses += 1
        ref, rest = m.group(1), m.group(2)
        if not PIN.search(ref):
            errs.append("line %d: uses not pinned to a 40-hex SHA: %s" % (n, ref))
        if not VCOMMENT.search(rest):
            errs.append("line %d: uses lacks a # v comment: %s" % (n, ref))
    if uses == 0:
        errs.append("no uses: lines collected")
    # github.event.* inside a run script (a `run:` block or a command input)
    in_run = False
    indent = 0
    for n, line in enumerate(lines, 1):
        stripped = line.strip()
        cur = len(line) - len(line.lstrip())
        if re.match(r"^\s*(?:-\s+)?(run|command|build-command|setup-command|test-command):", line):
            in_run = True
            indent = cur
            if "github.event" in line:
                errs.append("line %d: github.event in a script" % n)
            continue
        if in_run:
            if stripped and cur <= indent:
                in_run = False
            elif "github.event" in line:
                errs.append("line %d: github.event in a script" % n)
    return errs


def check_dependabot(text):
    errs = []
    if "package-ecosystem: github-actions" not in text:
        errs.append("github-actions ecosystem missing")
    m = re.search(r"^\s+cooldown:\s*\n\s+default-days:\s*(\d+)\s*$", text, re.M)
    if not m or int(m.group(1)) != 7:
        errs.append("cooldown default-days is not 7")
    return errs


GOOD_WF = (
    "permissions:\n  contents: read\n\njobs:\n  security:\n    uses: o/r/.github/workflows/x.yml@"
    + "a" * 40
    + " # v1.0.0\n    permissions:\n      contents: read\n      security-events: write\n"
    + "      pull-requests: write\n      id-token: write\n"
    + "  ci-green:\n    name: CI green\n    if: always()\n    needs: [ci, shell, security]\n"
    + "    steps:\n      - name: x\n"
)


def self_test():
    bad = {
        "unpinned": GOOD_WF.replace("a" * 40, "main"),
        "no comment": GOOD_WF.replace(" # v1.0.0", ""),
        "no CI green": GOOD_WF.replace("CI green", "done"),
        "step named CI green only": GOOD_WF.replace("    name: CI green", "    name: done") + "      - name: CI green\n",
        "no always": GOOD_WF.replace("    if: always()\n", ""),
        "needs short": GOOD_WF.replace("[ci, shell, security]", "[ci, shell]"),
        "needs extra": GOOD_WF.replace("[ci, shell, security]", "[ci, shell, security, x]"),
        "no id-token": GOOD_WF.replace("      id-token: write\n", ""),
        "no security-events": GOOD_WF.replace("      security-events: write\n", ""),
        "no pull-requests": GOOD_WF.replace("      pull-requests: write\n", ""),
        "top perms wider": GOOD_WF.replace("permissions:\n  contents: read\n\njobs", "permissions:\n  contents: read\n  id-token: write\n\njobs", 1),
        "prt": GOOD_WF + "on: pull_request_target\n",
        "event in run": GOOD_WF + "    steps:\n      - run: |\n          echo ${{ github.event.pull_request.title }}\n",
    }
    problems = []
    if check_workflow(GOOD_WF):
        problems.append("good sample rejected: %s" % check_workflow(GOOD_WF))
    for name, text in bad.items():
        if not check_workflow(text):
            problems.append("guard did not bite: %s" % name)
    gd = "updates:\n  - package-ecosystem: github-actions\n    cooldown:\n      default-days: 7\n"
    if check_dependabot(gd):
        problems.append("good dependabot sample rejected")
    if not check_dependabot(gd.replace("7", "3")):
        problems.append("guard did not bite: cooldown 3")
    if not check_dependabot(gd.replace("    cooldown:\n      default-days: 7\n", "")):
        problems.append("guard did not bite: no cooldown")
    return problems


def main():
    wf = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".github/workflows/ci.yml")
    db = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, ".github/dependabot.yml")
    errs = ["self-test: " + p for p in self_test()]
    for path, fn in ((wf, check_workflow), (db, check_dependabot)):
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
        except OSError as e:
            errs.append("cannot read %s: %s" % (path, e))
            continue
        errs += ["%s: %s" % (os.path.basename(path), e) for e in fn(text)]
    for e in errs:
        print("FAIL: " + e, file=sys.stderr)
    if errs:
        return 1
    print("test-ci-workflow: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
