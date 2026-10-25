#!/usr/bin/env python3
"""Factory: is this plan ready to be built while nobody watches? NOT a hook:
`factory-lint --plan` runs it, /factory:init shows its verdict on the approval
screen, and factory-preflight refuses to start a run on a FAIL.

Usage (from the project root):
  factory-lint --plan [<Cn>...] [--json]

Every check reads the task files and the change's requirement list - no model,
no tokens. `factory-lint <id>` judges one task file; this judges the plan the
files add up to, which is where a night run gets stuck: a requirement no task
builds, two tasks waiting on each other, a criterion nobody could decide, a
task too big for one builder, an acceptance command that never ends or can
never fail.

  - Requirements. When .factory/changes/<Cn>.requirements.md lists them
    (`- FR-001: <requirement>`), every requirement needs a task that names it
    in `covers: [FR-001]`, and every task needs one it covers (Phase 0
    scaffolding, P0-*, excepted). A task covering an id the list does not have
    is a FAIL too.
  - The graph: no dependency on a task that is not on the board, no cycle.
  - Open questions: [NEEDS CLARIFICATION], TODO, TKTK or ??? left in a task
    file or the requirement list (inside `code` they are quoted, not open).
  - Scope: at most plan.max_criteria acceptance criteria (8) and
    plan.max_files paths named in a task (15). Past that, split it.
  - The acceptance command: not a watch mode or a server that never exits,
    and not one that cannot fail (`true`, `exit 0`, `echo ...`, `... || true`).
  - At most five clarifying questions in the list's `## Clarifications`.

The verdict is PASS, CONCERNS or FAIL. A small change (plan.small_change
tasks or fewer, 3 by default) never FAILs on scope, coverage or markers - only
on a broken graph, which no run can build around: a plan check should not cost
a one-line fix more ceremony than the fix.

Output: one line per finding, a COVERAGE table, and `PLAN <Cn>: <verdict>`
per change; exit 1 when any change FAILs. --json prints the same as one object.
"""
import json
import os
import re
import sys

sys.dont_write_bytecode = True
ROOT = os.getcwd()
F = os.path.join(ROOT, ".factory")
T = os.path.join(ROOT, "tasks")
LANES = ("proposed", "backlog", "in-progress", "blocked", "done")
OPEN_LANES = ("proposed", "backlog", "in-progress", "blocked")
MARKERS = [
    (re.compile(r"\[NEEDS CLARIFICATION", re.I), "[NEEDS CLARIFICATION]"),
    (re.compile(r"\bTODO\b"), "TODO"),
    (re.compile(r"\bTKTK\b"), "TKTK"),
    (re.compile(r"\?\?\?"), "???"),
]
# What never exits on its own. `--watchAll=false` (a CI flag that turns watch
# off) and `npm run start-server-and-test` (which exits) are not watch modes.
END = r"(?=$|[\s;&|)])"
WATCH = re.compile(r"(--watch(All)?(?![\w-])(?!=(false|0)\b)|(^|[\s;&|(])watch\s|\bnodemon\b|\btail\s+-[a-zA-Z]*f|"
                   r"\b(npm|yarn|pnpm|bun)\s+(run\s+)?(dev|start|serve)" + END + r"|\b(flask|rails)\s+(run|server|s)" + END
                   + r"|\bmanage\.py\s+runserver\b|\bdotnet\s+watch\b|\bcargo\s+watch\b)")
CANNOT_FAIL = re.compile(r"^\s*(true|:|exit\s+0|echo\b[^|;&]*|printf\b[^|;&]*)\s*$|\|\|\s*(true|:|exit\s+0)\s*$|;\s*(true|exit\s+0)\s*$")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def config():
    try:
        return json.loads(read(os.path.join(F, "config.json")) or "{}")
    except ValueError:
        return {}


def frontmatter(text):
    m = re.match(r"^---[ \t]*\n(.*?)\n---[ \t]*(\n|$)", text, re.S)
    out = {}
    for line in (m.group(1).splitlines() if m else []):
        k, sep, v = line.partition(":")
        if sep and re.match(r"^[a-z_]+$", k.strip()) and k.strip() not in out:
            out[k.strip()] = v.strip()
    return out


def listed(value):
    return [x.strip().strip("'\"") for x in value.strip().strip("[]").split(",") if x.strip().strip("'\"")]


def change_of(tid):
    m = re.match(r"^(C[0-9]+)-", tid)
    return m.group(1) if m else "C1"


def section(text, name):
    m = re.search(r"^## %s[ \t]*\n(.*?)(?=^## |\Z)" % re.escape(name), text, re.S | re.M)
    return m.group(1) if m else ""


def unquoted(text):
    """The text with fenced blocks and `code` spans taken out: a marker quoted
    there is the subject of the task, not a question left open."""
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    return re.sub(r"`[^`\n]*`", "", text)


def board():
    tasks = {}
    for lane in LANES:
        d = os.path.join(T, lane)
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            if n.endswith(".md"):
                text = read(os.path.join(d, n))
                tasks[n[:-3]] = {"lane": lane, "text": text, "fm": frontmatter(text)}
    return tasks


def requirements(cid):
    text = read(os.path.join(F, "changes", cid + ".requirements.md"))
    if not text:
        return None, ""
    ids = []
    for m in re.finditer(r"^\s*(?:[-*]\s*|#+\s*)?(FR-[0-9]+)\b", text, re.M):
        if m.group(1) not in ids:
            ids.append(m.group(1))
    return ids, text


def cycles(tasks, ids):
    """Each cycle once, as the list of ids around it."""
    found, seen, stack, on = [], set(), [], set()

    def visit(t):
        seen.add(t)
        stack.append(t)
        on.add(t)
        for d in listed(tasks[t]["fm"].get("depends_on", "")):
            if d not in tasks:
                continue
            if d in on:
                cyc = stack[stack.index(d):] + [d]
                key = frozenset(cyc)
                if key not in [frozenset(c) for c in found]:
                    found.append(cyc)
            elif d not in seen:
                visit(d)
        stack.pop()
        on.discard(t)

    for t in ids:
        if t not in seen:
            visit(t)
    return found


def paths_named(text):
    named = set()
    for sec in ("Files touched", "Constraints", "Context"):
        for m in re.finditer(r"(?<![\w/.-])((?:[\w.-]+/)+[\w.*-]+|[\w-]+\.[a-zA-Z0-9]{1,6})(?![\w/])", section(text, sec)):
            p = m.group(1)
            if not re.match(r"^\d+(\.\d+)+$", p):
                named.add(p)
    return named


def check_change(cid, tasks, cfg):
    plan = cfg.get("plan") or {}
    max_criteria = int(plan.get("max_criteria") or 8)
    max_files = int(plan.get("max_files") or 15)
    small = int(plan.get("small_change") or 3)
    mine = sorted(t for t, v in tasks.items() if change_of(t) == cid and v["lane"] in OPEN_LANES)
    fails, concerns = [], []
    graph = []

    for t in mine:
        for d in listed(tasks[t]["fm"].get("depends_on", "")):
            if d == t:
                graph.append("%s depends on itself" % t)
            elif d not in tasks:
                graph.append("%s depends on %s, which is not a task on the board" % (t, d))
    for cyc in cycles(tasks, mine):
        graph.append("a dependency cycle: %s - no task on it can ever start" % " -> ".join(cyc))

    req, req_text = requirements(cid)
    coverage = []
    if req is None:
        if len(mine) > small:
            concerns.append("no requirement list (.factory/changes/%s.requirements.md): what the tasks cover is "
                            "not checked" % cid)
    else:
        by_req = {r: [] for r in req}
        for t in mine:
            covers = listed(tasks[t]["fm"].get("covers", ""))
            for r in covers:
                if r in by_req:
                    by_req[r].append(t)
                else:
                    fails.append("%s covers %s, which the requirement list does not have" % (t, r))
            if not covers and not t.startswith("P0-"):
                fails.append("%s covers no requirement - add covers: [FR-...] or drop the task (unrequested "
                             "work)" % t)
        for r in req:
            coverage.append((r, by_req[r]))
            if not by_req[r]:
                fails.append("%s has no task that builds it" % r)
        clar = section(req_text, "Clarifications")
        asked = len(re.findall(r"^\s*(?:###\s*|[-*]\s*)Q[0-9]*\b", clar, re.M))
        if asked > 5:
            concerns.append("%d clarifying questions in the requirement list - at most five; settle the rest in "
                            "the spec" % asked)
        for rx, name in MARKERS:
            if rx.search(unquoted(req_text)):
                fails.append("the requirement list still has %s in it" % name)

    for t in mine:
        text, fm = tasks[t]["text"], tasks[t]["fm"]
        body = unquoted(text)
        for rx, name in MARKERS:
            if rx.search(body):
                fails.append("%s still has %s in it - an open question a builder would answer by guessing" % (t, name))
        n = len(re.findall(r"^- \[[ xX]\] ", section(text, "Acceptance criteria"), re.M))
        if n > max_criteria:
            fails.append("%s has %d acceptance criteria (at most %d) - one builder, one check: split it" % (
                t, n, max_criteria))
        named = paths_named(text)
        if len(named) > max_files:
            fails.append("%s names %d paths (at most %d) - split it" % (t, len(named), max_files))
        acc = fm.get("acceptance", "")
        if acc and WATCH.search(acc):
            fails.append("%s: acceptance runs in watch mode or starts a server (%s) - it never exits, so the "
                         "check never ends" % (t, acc))
        if acc and CANNOT_FAIL.search(acc):
            fails.append("%s: acceptance cannot fail (%s) - it proves nothing" % (t, acc))

    soft = len(mine) <= small
    if soft:
        concerns += fails
        fails = []
    fails = graph + fails
    verdict = "FAIL" if fails else "CONCERNS" if concerns else "PASS"
    return {"change": cid, "tasks": len(mine), "requirements": len(req or []), "verdict": verdict,
            "fail": fails, "concerns": concerns, "coverage": [{"requirement": r, "tasks": ts} for r, ts in coverage],
            "small": soft}


def main(argv):
    if not os.path.isfile(os.path.join(F, "active")):
        print("PLAN: no .factory/active here - not a factory project, or not its root.")
        return 2
    tasks = board()
    cfg = config()
    wanted = [a for a in argv if re.match(r"^C[0-9]+$", a)]
    if not wanted:
        wanted = sorted({change_of(t) for t, v in tasks.items() if v["lane"] in OPEN_LANES},
                        key=lambda c: int(c[1:]))
    results = [check_change(c, tasks, cfg) for c in wanted]
    if "--json" in argv:
        print(json.dumps({"changes": results, "verdict": "FAIL" if any(r["verdict"] == "FAIL" for r in results)
                          else "CONCERNS" if any(r["verdict"] == "CONCERNS" for r in results) else "PASS"}))
    else:
        for r in results:
            for f in r["fail"]:
                print("FAIL %s: %s" % (r["change"], f))
            for c in r["concerns"]:
                print("CONCERN %s: %s" % (r["change"], c))
            for row in r["coverage"]:
                print("COVERAGE %s %s -> %s" % (r["change"], row["requirement"], ", ".join(row["tasks"]) or "(none)"))
            print("PLAN %s: %s (%d task(s), %d requirement(s)%s)" % (
                r["change"], r["verdict"], r["tasks"], r["requirements"],
                ", a small change: only a broken graph fails it" if r["small"] else ""))
        if not results:
            print("PLAN: no open task on the board.")
    return 1 if any(r["verdict"] == "FAIL" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
