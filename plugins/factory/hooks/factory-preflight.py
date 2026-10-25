#!/usr/bin/env python3
"""Factory: everything a run needs settled before a builder is paid. NOT a hook:
/factory:run runs it once and hands what it prints to the loop workflow.

Usage (from the project root):
  factory-preflight [--json] [--change C]

In order, each step deterministic:

  1. .factory/STOP - a hard ban was hit, or the developer stopped the factory.
     Nothing starts until the developer removes it.
  2. The working tree. Uncommitted work outside the factory's own paths stops a
     run above autonomy level local, because a run there publishes what it
     builds; at local it is a warning (a task that edits the same file commits
     those edits with its own).
  3. Task ids: factory-ids check.
  4. The inbox. A question the developer answered sends its task back to the
     backlog, with the answer written into the task file; an answered task that
     was needs_human is no longer (the answer is the decision it waited for).
  5. needs_human work goes to tasks/blocked, with its question in the inbox -
     asked once, never dispatched.
  6. Lint. A task file that does not lint is blocked and asked about: a builder
     would only be paid to refuse it.
  7. Breakers: the week's quota at level merge, commits that were never pushed.
  8. Permissions. A headless session (claude -p) without an allow rule for the
     loop workflow is told so: it would wait on a prompt nobody answers.
  9. The plan: the dependency graph (factory-plan), the board snapshot that
     factory-check reads approvals from, and the run's base. An unfinished run
     (.factory/run.lock) started again for the same change keeps its base.

Prints the minimal plan the loop consumes: the task ids with their
dependencies and review flag, the run's limits and its base. The tasks'
content is not in it - every builder reads its own task file from disk.

Exit 0 when the run may start (ok: true), 1 when it may not.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HOOK_DIR)
from factory_compat import bash  # noqa: E402

ROOT = os.getcwd()
F = os.path.join(ROOT, ".factory")
T = os.path.join(ROOT, "tasks")
LOOP = "factory:loop"


def load_plan():
    spec = importlib.util.spec_from_file_location("factory_plan", os.path.join(HOOK_DIR, "factory-plan.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def sh(script, *args):
    r = subprocess.run([bash(), os.path.join(HOOK_DIR, script)] + list(args), capture_output=True, text=True,
                       cwd=ROOT, errors="replace", env=dict(os.environ, FACTORY_ROOT=ROOT))
    return r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def write(path, text):
    tmp = path + ".preflight.tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    os.replace(tmp, path)


def lane_of(tid):
    for col in ("backlog", "in-progress", "blocked", "done", "proposed"):
        if os.path.isfile(os.path.join(T, col, tid + ".md")):
            return col
    return None


def set_fm(text, key, value):
    """text with one frontmatter key rewritten (added when missing)."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return text
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            for j in range(1, i):
                if lines[j].split(":", 1)[0].strip() == key:
                    lines[j] = "%s: %s" % (key, value)
                    return "\n".join(lines)
            lines.insert(i, "%s: %s" % (key, value))
            return "\n".join(lines)
    return text


def questions():
    """(path, frontmatter, text) of every question in the inbox."""
    d = os.path.join(F, "questions")
    out = []
    try:
        names = sorted(n for n in os.listdir(d) if re.match(r"^Q[0-9]+\.md$", n))
    except OSError:
        return out
    for n in names:
        text = read(os.path.join(d, n))
        fm = {}
        for line in text.split("\n---", 1)[0].splitlines()[1:]:
            k, sep, v = line.partition(":")
            if sep:
                fm.setdefault(k.strip(), v.strip())
        out.append((os.path.join(d, n), fm, text))
    return out


def section(text, title):
    m = re.search(r"^##\s+%s[^\n]*\n(.*?)(?=^##\s|\Z)" % re.escape(title), text, re.M | re.S)
    return m.group(1).strip() if m else ""


def consume_answers(notes):
    """Answered questions -> their tasks back in the backlog. Returns the ids
    whose needs_human the answer cleared."""
    cleared = set()
    for path, fm, text in questions():
        if fm.get("status") != "answered":
            continue
        tid, qid = fm.get("task", ""), fm.get("id", os.path.basename(path)[:-3])
        col = lane_of(tid) if tid else None
        if col in (None, "done", "proposed"):
            write(path, re.sub(r"^status: answered$", "status: consumed", text, count=1, flags=re.M))
            continue
        tf = os.path.join(T, col, tid + ".md")
        task = read(tf)
        answer = section(text, "Cevap") or section(text, "Answer")
        asked = section(text, "Soru") or section(text, "Question")
        if "## Developer answer (%s)" % qid not in task:
            task = task.rstrip("\n") + "\n\n## Developer answer (%s)\n\nQuestion: %s\n\nAnswer: %s\n" % (
                qid, " ".join(asked.split())[:400], answer)
        if re.search(r"^needs_human:\s*true\s*$", task, re.M | re.I):
            task = set_fm(task, "needs_human", "false")
            cleared.add(tid)
        task = set_fm(set_fm(task, "stage", "queued"), "owner", "")
        write(tf, task)
        if col == "blocked":
            os.makedirs(os.path.join(T, "backlog"), exist_ok=True)
            os.replace(tf, os.path.join(T, "backlog", tid + ".md"))
        write(path, re.sub(r"^status: answered$", "status: consumed", text, count=1, flags=re.M))
        notes.append("%s answered: %s is back in the backlog with the answer in its file" % (qid, tid))
    return cleared


def open_question(tid):
    return any(fm.get("task") == tid and fm.get("status") == "open" for _, fm, _ in questions())


def block_and_ask(tid, reason, question, notes):
    rc, out = sh("factory-block.sh", tid, reason)
    if rc != 0:
        notes.append("%s: could not be blocked (%s)" % (tid, out.splitlines()[0] if out else "factory-block failed"))
        return
    if not open_question(tid):
        sh("factory-ask.sh", "ask", tid, question)
    notes.append("%s blocked and asked: %s" % (tid, reason))


def frontmatter(path):
    data = {}
    lines = read(path).splitlines()
    if not lines or lines[0].strip() != "---":
        return data
    for line in lines[1:]:
        if line.strip() == "---":
            break
        k, sep, v = line.partition(":")
        if sep:
            data.setdefault(k.strip(), v.strip())
    return data


def route_needs_human(notes):
    for col in ("backlog", "in-progress"):
        try:
            names = sorted(n[:-3] for n in os.listdir(os.path.join(T, col)) if n.endswith(".md"))
        except OSError:
            continue
        for tid in names:
            fm = frontmatter(os.path.join(T, col, tid + ".md"))
            if fm.get("needs_human", "").lower() != "true":
                continue
            title = fm.get("title") or tid
            block_and_ask(tid, "needs_human: a decision or an action only the developer can take",
                          "%s - this task is marked needs_human. What should be done? Answer here (or do it and "
                          "say so); the next run builds the task with your answer in its file." % title, notes)


def route_lint(notes, change):
    rc, out = sh("factory-lint.sh", "--all")
    if rc == 0:
        return
    bad = {}
    for line in out.splitlines():
        m = re.match(r"^LINT ([A-Za-z0-9._-]+): (.*)$", line)
        if m:
            bad.setdefault(m.group(1), []).append(m.group(2))
    for tid, problems in sorted(bad.items()):
        if lane_of(tid) not in ("backlog", "in-progress"):
            continue
        if change and not (tid.startswith(change + "-") or (change == "C1" and not re.match(r"^C[0-9]+-", tid))):
            continue
        block_and_ask(tid, "the task file does not lint: " + "; ".join(problems)[:300],
                      "The task file of %s does not lint: %s. Fix the task file and commit it, then answer here; "
                      "the next run picks it up." % (tid, "; ".join(problems)[:600]), notes)


def owed_reviews(change):
    """Landed tasks whose review after landing never came back: the loop runs
    those reviewers first, and their change is not delivered until they do."""
    out = []
    d = os.path.join(F, "reviews")
    try:
        names = sorted(n[:-5] for n in os.listdir(d) if n.endswith(".json"))
    except OSError:
        return out
    for tid in names:
        if change and not (tid.startswith(change + "-") or (change == "C1" and not re.match(r"^C[0-9]+-", tid))):
            continue
        try:
            owed = json.loads(read(os.path.join(d, tid + ".json")) or "{}").get("verdict") == "owed"
        except ValueError:
            owed = False
        if owed and lane_of(tid) == "done":
            out.append(tid)
    return out


def autonomy_level():
    rc, out = sh("factory-autonomy.sh")
    return (out.split() or ["local"])[0] if rc == 0 or out else "local"


def workflow_allowed():
    """Is there an allow rule for the loop workflow in the settings a session reads?"""
    home = os.path.expanduser("~")
    for p in (os.path.join(ROOT, ".claude", "settings.json"), os.path.join(ROOT, ".claude", "settings.local.json"),
              os.path.join(home, ".claude", "settings.json")):
        try:
            allow = ((json.loads(read(p) or "{}").get("permissions") or {}).get("allow") or [])
        except (ValueError, AttributeError):
            continue
        if any(r in ("Workflow", "Workflow(%s)" % LOOP, "Workflow(*)") for r in allow if isinstance(r, str)):
            return True
    return False


def headless():
    ep = os.environ.get("CLAUDE_CODE_ENTRYPOINT", "")
    return os.environ.get("FACTORY_HEADLESS") == "1" or ep.startswith("sdk")


def preflight(change):
    out = {"ok": True, "problems": [], "warnings": [], "notes": [], "tasks": [], "held": []}
    if not os.path.isfile(os.path.join(F, "active")):
        out.update(ok=False, problems=["no .factory/active here - not a factory project, or not its root"])
        return out
    stop = os.path.join(F, "STOP")
    if os.path.exists(stop):
        first = (read(stop).strip().splitlines() or ["(empty)"])[0]
        out.update(ok=False, problems=["HALTED: .factory/STOP is set (%s). Only the developer removes it." % first])
        return out

    P = load_plan()
    level = autonomy_level()
    rc, st, _ = P.git("status", "--porcelain", "--", ".")
    mine = [l[3:] for l in st.splitlines() if l[3:] and not l[3:].strip('"').startswith(P.FACTORY_PATHS)] if rc == 0 else []
    if mine and level != "local":
        out["problems"].append(
            "uncommitted work outside the factory's paths (%s) and the autonomy level is %s: a run at this level "
            "publishes what it builds. Commit or stash it, or run this one at local (factory-autonomy off)"
            % (" ".join(mine[:8]) + (" ..." if len(mine) > 8 else ""), level))

    sh("factory-sweep.sh", "run-start", ROOT)
    cleared = consume_answers(out["notes"])
    route_needs_human(out["notes"])
    route_lint(out["notes"], change)

    rc, msg = sh("factory-unpushed.sh", "check")
    if rc != 0:
        out["problems"].append(msg.splitlines()[0] if msg else "the unpushed breaker is open")
    if headless() and not workflow_allowed():
        out["warnings"].append("this session is headless and no settings file allows Workflow(%s): the loop waits on "
                               "a permission prompt nobody answers. Add the allow rule, or start with "
                               "--permission-mode auto" % LOOP)

    plan = P.build(change=change)
    out["problems"] += plan["problems"]
    out["warnings"] += [w for w in plan["warnings"] if not w.startswith("uncommitted work") or level == "local"]
    out["held"] = plan["held"]
    for k in ("workers", "risk_review", "audit", "effort", "counts"):
        if k in plan:
            out[k] = plan[k]
    try:
        cfg = json.loads(read(os.path.join(F, "config.json")) or "{}")
    except ValueError:
        cfg = {}
    out["retro_mode"] = (cfg.get("retro") or {}).get("mode") or "suggest"
    out["owed"] = owed_reviews(change)
    out["attempts"] = plan.get("retry_limit", 2)
    if plan.get("critical_path"):
        out["chain"], out["width"] = len(plan["critical_path"]), plan.get("width")
    if change:
        out["change"] = change
    if not out["problems"]:
        out["problems"] += P.delivery_gate(change)
    if out["problems"]:
        out["ok"] = False
        return out
    out["tasks"] = [{"id": t["id"], "deps": t["deps"], "review": t["review"]} for t in plan["tasks"]]
    if not out["tasks"]:
        return out
    snap, problems, warnings = P.snapshot_board(plan, exempt={t: ("needs_human",) for t in cleared})
    out["warnings"] += warnings
    if problems:
        out.update(ok=False, problems=problems, tasks=[])
        return out
    if snap:
        out["snapshot"] = snap
    out["base"] = P.record_start(plan, change)
    start = P.read_json(os.path.join(F, "run-start.json")) or {}
    out["start_head"] = start.get("head")
    if out["base"] == "kept":
        out["notes"].append("an unfinished run of this change was found: its base %s is kept"
                            % (out["start_head"] or "?")[:12])
    return out


def main(argv):
    change = None
    if "--change" in argv:
        i = argv.index("--change")
        change = argv[i + 1] if i + 1 < len(argv) and argv[i + 1].strip() else None
    out = preflight(change)
    if "--json" in argv:
        print(json.dumps(out, separators=(",", ":")))
    else:
        for p in out["problems"]:
            print("PROBLEM " + p)
        for w in out["warnings"]:
            print("WARNING " + w)
        for n in out["notes"]:
            print("NOTE    " + n)
        for t in out["tasks"]:
            print("PLAN    %s%s%s" % (t["id"], " after " + ",".join(t["deps"]) if t["deps"] else "",
                                      " (review)" if t["review"] else ""))
        for h in out["held"]:
            print("HELD    %s %s" % (h["id"], h["reason"]))
        print("PREFLIGHT ok=%s tasks=%d held=%d base=%s" % (str(out["ok"]).lower(), len(out["tasks"]),
                                                          len(out["held"]), out.get("base", "-")))
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
