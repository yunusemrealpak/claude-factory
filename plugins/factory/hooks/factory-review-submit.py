#!/usr/bin/env python3
"""Factory: a reviewer's findings, filtered, and the verdict. NOT a hook: the
reviewer pipes its findings into it as its last command.

Usage (from the project root):
  factory-review-submit <id> [--landed] < findings.json

  {"findings": [{"severity": "P0|P1|P2|P3", "confidence": 0-100,
                 "file": "src/a.py", "line": 12, "quote": "<the line, verbatim>",
                 "category": "correctness", "what": "...", "fix": "...",
                 "pre_existing": false}]}

The reviewer finds; this script judges. A finding is dropped when:
  - its confidence is under 80;
  - it is about code that was there before the task (pre_existing);
  - its category is one the check already runs (lint, style, format, compiler,
    types): a second opinion on those is noise;
  - its file is not in the task's diff, its quote is not in the lines the task
    added, or its line is outside the hunks the task changed - a finding that
    cannot point at the change is not about the change.
Only P0 and P1 findings that survive block; P2 and P3 are notes.

Before landing (the task is green in tasks/in-progress): the verdict goes into
the task file as "## Review", so it is committed with the task. A pass lands the
task (factory-land). A fail drops the green marker - the fix is checked again -
and a second fail blocks the task and asks the developer.

After landing (--landed, the commit is read): the verdict is recorded only. A
failed one holds the delivery of the task's change (factory-deliver).

Every verdict, with what the filter dropped and why, is in
.factory/reviews/<id>.json. The last line says it:
  REVIEW PASS <id>[: LANDED <sha>] | REVIEW FAIL <id> round <n>: ... |
  REVIEW FAIL <id> BLOCKED: ... | REVIEW REFUSED <id>: ...
"""
import datetime
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HOOK_DIR)
from factory_compat import bash, npath  # noqa: E402

ROOT = os.getcwd()
F = os.path.join(ROOT, ".factory")
T = os.path.join(ROOT, "tasks")
MIN_CONFIDENCE = 80
BLOCKING = ("P0", "P1")
CHECKED = {"lint", "linter", "style", "format", "formatting", "formatter", "compiler", "compile", "build", "type",
           "types", "typecheck", "type-check", "typing", "syntax", "naming", "typo", "nit", "nitpick"}
SEVERITY = {"p0": "P0", "critical": "P0", "blocker": "P0", "p1": "P1", "high": "P1", "major": "P1",
            "p2": "P2", "medium": "P2", "minor": "P2", "p3": "P3", "low": "P3", "info": "P3"}
SLACK = 3  # lines around a hunk a finding may point at


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def git(*args):
    r = subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True, text=True, errors="replace")
    return r.returncode, r.stdout


def sh(script, *args):
    r = subprocess.run([bash(), os.path.join(HOOK_DIR, script)] + list(args), capture_output=True, text=True,
                       cwd=ROOT, errors="replace", env=dict(os.environ, FACTORY_ROOT=ROOT))
    return r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()


def files_touched(text):
    out, on = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            on = line.strip() == "## Files touched"
        elif on and line.lstrip().startswith(("- ", "* ")):
            p = line.lstrip()[2:].strip().strip("`").split()
            if p:
                out.append(npath(p[0]))
    return out


def parse_diff(text):
    """{path: {"added": [(line_no, text)], "hunks": [(start, end)]}} from a -U0 diff."""
    files, cur, new_no = {}, None, 0
    for line in text.splitlines():
        if line.startswith("+++ "):
            p = line[4:].strip()
            cur = None if p == "/dev/null" else files.setdefault(p[2:] if p.startswith("b/") else p,
                                                                 {"added": [], "hunks": []})
            continue
        if line.startswith("--- ") or line.startswith("diff --git"):
            continue
        m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
        if m and cur is not None:
            start, count = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
            cur["hunks"].append((start, start + max(count, 1) - 1))
            new_no = start
            continue
        if cur is None:
            continue
        if line.startswith("+"):
            cur["added"].append((new_no, line[1:]))
            new_no += 1
    return files


def new_file(path):
    text = read(os.path.join(ROOT, path))
    lines = text.splitlines()
    return {"added": list(enumerate(lines, 1)), "hunks": [(1, max(len(lines), 1))]}


def task_diff(tid, listed, landed):
    """The task's change, as the reviewer had to read it."""
    if landed:
        _, sha = git("log", "-1", "--format=%H", "--grep", "^Factory-Task: %s$" % tid)
        sha = sha.strip()
        if not sha:
            return None, None
        _, text = git("show", "-U0", "--format=", "--no-color", sha)
        return parse_diff(text), sha[:12]
    _, text = git("diff", "HEAD", "-U0", "--no-color", "--", *listed) if listed else (0, "")
    files = parse_diff(text)
    for p in listed:
        tracked = git("ls-files", "--error-unmatch", "--", p)[0] == 0
        if not tracked and os.path.isfile(os.path.join(ROOT, p)):
            files[p] = new_file(p)
    return files, None


def squash(s):
    return " ".join(str(s or "").split())


def judge(f, diff):
    """None when the finding stands, else why it was dropped."""
    try:
        conf = float(f.get("confidence", 0))
    except (TypeError, ValueError):
        conf = 0
    if conf < MIN_CONFIDENCE:
        return "confidence %g is under %d" % (conf, MIN_CONFIDENCE)
    if f.get("pre_existing") is True:
        return "pre-existing: not this task's change"
    if squash(f.get("category")).lower() in CHECKED:
        return "category %s is one the check already runs" % squash(f.get("category")).lower()
    path = npath(str(f.get("file") or "").strip()) if f.get("file") else ""
    if path.startswith("./"):
        path = path[2:]
    entry = diff.get(path)
    if not entry:
        return "%s is not in this task's diff" % (path or "no file")
    quote = squash(f.get("quote"))
    if not quote:
        return "no quote from the diff"
    added = squash("\n".join(t for _, t in entry["added"]))
    if quote not in added:
        return "the quote is not in the lines this task added"
    try:
        line = int(f.get("line") or 0)
    except (TypeError, ValueError):
        line = 0
    if line and not any(a - SLACK <= line <= b + SLACK for a, b in entry["hunks"]):
        return "line %d is outside the hunks this task changed" % line
    return None


def describe(f):
    where = "%s%s" % (f.get("file") or "?", ":%s" % f["line"] if f.get("line") else "")
    fix = squash(f.get("fix"))
    return "[%s] %s %s%s" % (f["severity"], where, squash(f.get("what")) or "(no description)",
                            " -> " + fix if fix else "")


def record(tid, mode, entry):
    d = os.path.join(F, "reviews")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, tid + ".json")
    try:
        rec = json.loads(read(path) or "{}")
    except ValueError:
        rec = {}
    rec.setdefault("task", tid)
    rec["rounds"] = rec.get("rounds") or []
    entry["round"] = 1 + sum(1 for r in rec["rounds"] if r.get("mode") == mode)
    entry["mode"] = mode
    rec["rounds"].append(entry)
    rec["verdict"], rec["mode"], rec["at"] = entry["verdict"], mode, entry["at"]
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=1)
    os.replace(tmp, path)
    return entry["round"]


def write_review(path, entry):
    lines = ["", "## Review %s" % entry["at"], "verdict: %s" % entry["verdict"], "findings:"]
    lines += ["- " + d for d in entry["blocking"]] or ["- none that block"]
    if entry["notes"]:
        lines += ["notes:"] + ["- " + d for d in entry["notes"]]
    if entry["dropped"]:
        lines += ["dropped by the filter: %d (.factory/reviews/)" % len(entry["dropped"])]
    with open(path, "a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def main(argv):
    if not argv or argv[0].startswith("-"):
        print("usage: factory-review-submit <id> [--landed] < findings.json", file=sys.stderr)
        return 2
    tid, landed = argv[0], "--landed" in argv[1:]
    if not os.path.isfile(os.path.join(F, "active")):
        print("REVIEW REFUSED %s: %s has no .factory/active." % (tid, ROOT))
        return 1
    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except ValueError as e:
        print("REVIEW REFUSED %s: the findings are not JSON (%s). Pipe {\"findings\": [...]} in." % (tid, e))
        return 1
    found = data.get("findings") if isinstance(data, dict) else data
    if not isinstance(found, list):
        print("REVIEW REFUSED %s: no \"findings\" list in the input." % tid)
        return 1

    col = "done" if landed else "in-progress"
    path = os.path.join(T, col, tid + ".md")
    if not os.path.isfile(path):
        print("REVIEW REFUSED %s: no tasks/%s/%s.md - %s" % (
            tid, col, tid, "a landed review reads a task in done" if landed else "only a task in progress is "
            "reviewed before it lands"))
        return 1
    if not landed and not os.path.isfile(os.path.join(F, "verified", tid)):
        print("REVIEW REFUSED %s: no green check - a task is reviewed after its check is green." % tid)
        return 1
    diff, sha = task_diff(tid, files_touched(read(path)), landed)
    if diff is None:
        print("REVIEW REFUSED %s: no commit carries Factory-Task: %s." % (tid, tid))
        return 1

    blocking, notes, dropped = [], [], []
    for f in found:
        if not isinstance(f, dict):
            continue
        f = dict(f)
        f["severity"] = SEVERITY.get(squash(f.get("severity")).lower(), "P2")
        why = judge(f, diff)
        if why:
            dropped.append({"finding": describe(f), "why": why})
        elif f["severity"] in BLOCKING:
            blocking.append(describe(f))
        else:
            notes.append(describe(f))
    entry = {"at": now_iso(), "verdict": "fail" if blocking else "pass", "blocking": blocking, "notes": notes,
             "dropped": dropped, "commit": sha}
    n = record(tid, "after" if landed else "before", entry)
    for d in dropped:
        print("  dropped  %s - %s" % (d["finding"], d["why"]))
    for d in notes:
        print("  note     %s" % d)
    for d in blocking:
        print("  BLOCKING %s" % d)

    if landed:
        if blocking:
            change = tid.split("-")[0] if re.match(r"^C[0-9]+-", tid) else "C1"
            print("REVIEW FAIL %s (landed): %d blocking finding(s) - the delivery of %s is held until the developer "
                  "looks (.factory/reviews/%s.json)" % (tid, len(blocking), change, tid))
        else:
            print("REVIEW PASS %s (landed)" % tid)
        return 0

    write_review(path, entry)
    if not blocking:
        rc, out = sh("factory-land.sh", tid)
        line = [l for l in out.splitlines() if l.strip()][-1:] or ["factory-land printed nothing"]
        print("REVIEW PASS %s: %s" % (tid, line[0]))
        return 0
    try:
        os.remove(os.path.join(F, "verified", tid))
    except OSError:
        pass
    if n >= 2:
        reason = "review failed twice: " + "; ".join(blocking)[:300]
        sh("factory-block.sh", tid, reason)
        sh("factory-ask.sh", "ask", tid, "A reviewer failed %s twice: %s. Should it be built differently, or is "
           "the review wrong?" % (tid, "; ".join(blocking)[:500]))
        print("REVIEW FAIL %s BLOCKED: %s" % (tid, reason))
        return 0
    print("REVIEW FAIL %s round %d: %d blocking finding(s) - a fresh builder fixes exactly these" % (
        tid, n, len(blocking)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
