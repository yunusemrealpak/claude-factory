#!/usr/bin/env python3
"""Factory: the board as a build plan. NOT a hook: the /factory:fast workflow
reads it before it starts anything.

Usage (from the project root):
  factory-plan            human-readable
  factory-plan --json     one JSON object, what the workflow consumes
  add --proposed to plan tasks/proposed as well - how /factory:init measures a
  task list before it is approved; nothing is ever dispatched from there
  add --start to record the run's starting point in .factory/run-start.json:
  HEAD and its test census, which the full check at the end compares against

Every task in tasks/backlog or tasks/in-progress that an agent may work on,
with the dependencies it still has to wait for - only ones that are themselves
in the plan, so the workflow can schedule the whole board at once and start each
task the moment the last thing it needs has landed. A task whose dependency can
never land in this run (blocked, needs a human, stalled, not on the board) is
held, with the reason, and so is everything downstream of it.

Nothing here decides anything a person should: tasks/proposed is not the board,
needs_human work is held, and a dependency cycle or an id collision stops the
plan outright.
"""
import json
import os
import re
import subprocess
import time
import sys

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HOOK_DIR)
from factory_compat import bash  # noqa: E402
ROOT = os.getcwd()
F = os.path.join(ROOT, ".factory")
FACTORY_PATHS = ("tasks/", "decisions.md", ".factory/", "gates/", "specs/", "CLAUDE.md", ".gitignore", ".claude/")


def frontmatter(path):
    data = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            if fh.readline().strip() != "---":
                return data
            for line in fh:
                if line.strip() == "---":
                    break
                key, sep, value = line.partition(":")
                if sep and key.strip() not in data:
                    data[key.strip()] = value.strip()
    except OSError:
        pass
    return data


def lane(name):
    d = os.path.join(ROOT, "tasks", name)
    try:
        return sorted(n[:-3] for n in os.listdir(d) if n.endswith(".md"))
    except OSError:
        return []


def files_touched(path):
    """The paths a task file lists under "## Files touched"."""
    out, on = [], False
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("## "):
                    on = line.strip() == "## Files touched"
                elif on and line.lstrip().startswith("- "):
                    out.append(line.lstrip()[2:].strip().strip("`"))
    except OSError:
        pass
    return [p for p in out if p]


def change_of_task(tid):
    """The change a task belongs to: the C<n>- prefix of its id; a task without
    one belongs to C1, the change every project starts with."""
    m = re.match(r"^(C[0-9]+)-", tid)
    return m.group(1) if m else "C1"


def build(proposed=False, change=None):
    out = {"ok": True, "problems": [], "warnings": [], "tasks": [], "held": []}
    if not os.path.isfile(os.path.join(F, "active")):
        out.update(ok=False, problems=["no .factory/active here - not a factory project, or not its root"])
        return out
    try:
        cfg = json.load(open(os.path.join(F, "config.json"), encoding="utf-8"))
    except (OSError, ValueError):
        cfg = {}
    fast = cfg.get("fast") or {}
    out["workers"] = int(fast.get("workers") or 4)
    out["risk_review"] = fast.get("risk_review") or "after"
    out["audit"] = fast.get("audit", True) is not False
    # retry_limit counts attempts at a task, the first included.
    out["retry_limit"] = max(1, int(cfg.get("retry_limit") or 2))
    out["effort"] = {"build": fast.get("effort_build") or "medium",
                     "escalate": fast.get("effort_escalate") or "high",
                     "review": fast.get("effort_review") or "high",
                     "audit": fast.get("effort_audit") or "high"}

    ids = subprocess.run([bash(), os.path.join(HOOK_DIR, "factory-ids.sh"), "check", ROOT],
                         capture_output=True, text=True)
    if ids.returncode != 0:
        out["problems"] += [l for l in ids.stdout.splitlines() if l.strip()] or ["factory-ids check failed"]

    lanes = {n: lane(n) for n in ("backlog", "in-progress", "done", "blocked")}
    out["counts"] = {k.replace("-", "_"): len(v) for k, v in lanes.items()}
    done = set(lanes["done"])
    if lanes["in-progress"]:
        out["warnings"].append("taken over from an earlier run, still in tasks/in-progress: " + " ".join(lanes["in-progress"]))

    meta, held = {}, {}
    if proposed:
        lanes["proposed"] = lane("proposed")
    for col in ("backlog", "in-progress") + (("proposed",) if proposed else ()):
        for tid in lanes[col]:
            fm = frontmatter(os.path.join(ROOT, "tasks", col, tid + ".md"))
            deps = [d.strip().strip("\"'") for d in re.split(r"[,\s]+", fm.get("depends_on", "").strip("[]")) if d.strip()]
            meta[tid] = {"deps": [d for d in deps if d not in done], "fm": fm,
                         "files": files_touched(os.path.join(ROOT, "tasks", col, tid + ".md"))}
            if fm.get("needs_human", "").lower() == "true":
                held[tid] = "needs_human - a decision for the developer"
            elif os.path.exists(os.path.join(F, "no-progress", tid)):
                held[tid] = "stalled - the check saw the same failure twice; it needs a different approach"
    blocked = set(lanes["blocked"])

    if change:
        # One change at a time: the others stay on the board, untouched. A task
        # of this change that waits on another change says so - it is not
        # ready, and the reason names the change to land first.
        other = {t for t in meta if change_of_task(t) != change}
        for tid in list(meta):
            if tid in other:
                continue
            for d in meta[tid]["deps"]:
                if d in other:
                    held[tid] = "waits on %s of change %s, which has to be delivered first" % (d, change_of_task(d))
                    break
        for tid in other:
            meta.pop(tid, None)
            held.pop(tid, None)

    changed = True
    while changed:  # a task waiting on something that cannot land is held too
        changed = False
        for tid, m in meta.items():
            if tid in held:
                continue
            for d in m["deps"]:
                why = None
                if d in held:
                    why = "waits on %s, which is held" % d
                elif d in blocked:
                    why = "waits on %s, which is blocked" % d
                elif d not in meta:
                    why = "waits on %s, which is not on the board" % d
                if why:
                    held[tid], changed = why, True
                    break

    active = {t: m for t, m in meta.items() if t not in held}
    state = {}

    def visit(t, path):
        if state.get(t) == 2:
            return None
        if state.get(t) == 1:
            return path[path.index(t):] + [t]
        state[t] = 1
        for d in active[t]["deps"]:
            cyc = visit(d, path + [t])
            if cyc:
                return cyc
        state[t] = 2
        return None

    for t in sorted(active):
        cyc = visit(t, [])
        if cyc:
            out["problems"].append("dependency cycle: " + " -> ".join(cyc))
            break

    for t in sorted(active):
        fm = active[t]["fm"]
        out["tasks"].append({"id": t, "title": (fm.get("title") or t)[:60], "deps": active[t]["deps"],
                             "review": fm.get("review", "").lower() == "always",
                             "allow_test_removal": fm.get("allow_test_removal", "").lower() == "true"})
    out["held"] = [{"id": t, "reason": r} for t, r in sorted(held.items())]

    # The shape of the graph bounds the run more than any worker count does:
    # tasks on one chain run one after another however many builders there are.
    if not out["problems"] and active:
        depth, parent = {}, {}

        def level(t):
            if t not in depth:
                best = None
                for d in active[t]["deps"]:
                    if d in active and (best is None or level(d) > level(best)):
                        best = d
                depth[t] = 1 + (level(best) if best else 0)
                parent[t] = best
            return depth[t]

        for t in active:
            level(t)
        end = max(sorted(active), key=lambda t: depth[t])
        chain = []
        while end:
            chain.append(end)
            end = parent[end]
        per_level = {}
        for t in active:
            per_level[depth[t]] = per_level.get(depth[t], 0) + 1
        out["critical_path"] = list(reversed(chain))
        out["width"] = max(per_level.values())
        if len(active) >= 4 and len(chain) * 2 > len(active):
            # What chains them is usually a file they all list: say which.
            seen = {}
            for t in chain:
                for f in set(active[t]["files"]):
                    seen[f] = seen.get(f, 0) + 1
            shared = sorted(((n, f) for f, n in seen.items() if n >= 3), key=lambda x: (-x[0], x[1]))[:4]
            why = (" Files they share: " + ", ".join("%s (%d tasks)" % (f, n) for n, f in shared)
                   + ". One file listed by many tasks forces them into a line; split it, or give each task its own.") if shared else ""
            out["warnings"].append(
                "%d of %d tasks sit on one dependency chain (%s): they run one after another however many "
                "builders there are. Merge links that belong together, or move work that must be serial to the end.%s"
                % (len(chain), len(active), " -> ".join(chain[:12]) + (" ..." if len(chain) > 12 else ""), why))

    try:
        st = subprocess.run(["git", "-C", ROOT, "status", "--porcelain", "--", "."], capture_output=True, text=True)
        mine = [l[3:] for l in st.stdout.splitlines() if l[3:] and not l[3:].startswith(FACTORY_PATHS)]
        if mine:
            out["warnings"].append("uncommitted work that is not the factory's (never swept into a task commit, "
                                   "unless a task edits the same file): " + " ".join(mine[:12])
                                   + (" ..." if len(mine) > 12 else ""))
    except OSError:
        pass

    if out["problems"]:
        out["ok"] = False
    elif not out["tasks"]:
        out["warnings"].append("nothing to build: no task in tasks/backlog or tasks/in-progress can run")
    return out


# What a task's approval is (factory-check.py APPROVED_KEYS holds the same).
APPROVED_KEYS = ("acceptance", "needs_human", "untested_ok", "allow_test_removal", "modifies_tests", "dependencies")


def git(*args):
    r = subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def committed_task(tid):
    """(path, frontmatter) of the task file as HEAD has it, in any lane; None
    when HEAD has none."""
    rc, out, _ = git("ls-tree", "-r", "--name-only", "HEAD", "--", "tasks")
    for p in out.splitlines() if rc == 0 else []:
        if p.rsplit("/", 1)[-1] == tid + ".md":
            rc, text, _ = git("show", "HEAD:./" + p)
            if rc == 0:
                fm = {}
                lines = text.splitlines()
                if lines and lines[0].strip() == "---":
                    for line in lines[1:]:
                        if line.strip() == "---":
                            break
                        key, sep, value = line.partition(":")
                        if sep and key.strip() not in fm:
                            fm[key.strip()] = value.strip()
                return p, fm
    return None


def snapshot_board(plan):
    """The task files this run builds, committed as approved before anything
    starts. factory-check reads a task's acceptance and exemptions from this
    commit, never from the working tree a builder writes. Only those files go
    in: anything else staged or changed stays as it was.

    A task file HEAD already has is committed again only when what was approved
    is unchanged (a builder's notes, a stage): a run never approves a change to
    a task it builds - that would let one run launder its own untested_ok. Such
    a change is a problem the developer settles by committing the file.

    Returns (short sha or None, problems, warnings)."""
    problems, warnings = [], []
    if git("rev-parse", "--is-inside-work-tree")[0] != 0:
        return None, problems, warnings
    paths = []
    for t in plan["tasks"]:
        for col in ("backlog", "in-progress"):
            p = "tasks/%s/%s.md" % (col, t["id"])
            on_disk = os.path.isfile(os.path.join(ROOT, p))
            tracked = git("ls-files", "--error-unmatch", "--", p)[0] == 0
            if not (on_disk or tracked):
                continue
            head = committed_task(t["id"])
            if head and on_disk:
                now = frontmatter(os.path.join(ROOT, p))
                changed = [k for k in APPROVED_KEYS if now.get(k, "").strip() != head[1].get(k, "").strip()]
                if changed:
                    problems.append("%s: %s changes what was approved (%s) since %s was committed - a run never "
                                    "approves a change to a task it builds. If you made the change, commit the task "
                                    "file; otherwise put it back" % (t["id"], p, ", ".join(changed), head[0]))
                    continue
            paths.append(p)
    if problems or not paths:
        return None, problems, warnings
    ignored = [p for p in paths if git("check-ignore", "-q", "--", p)[0] == 0]
    if ignored:
        warnings.append("task files are gitignored (%s): what was approved cannot be committed, so factory-check "
                        "reads each task's approval from the working tree" % " ".join(ignored[:5]))
        paths = [p for p in paths if p not in ignored]
        if not paths:
            return None, problems, warnings
    rc, st, _ = git("status", "--porcelain", "--", *paths)
    if rc != 0 or not st.strip():
        return None, problems, warnings
    msg = "factory: board snapshot (%d task(s))" % len(plan["tasks"])
    # No project hook judges this commit: it holds task files only, and a
    # commit-msg rule that refused it would leave the approvals unanchored.
    for step in (["add", "-A", "--"] + paths,
                 ["commit", "-q", "--no-verify", "-m", msg, "-m", "Factory-Board: snapshot", "--"] + paths):
        rc, out, err = git(*step)
        if rc != 0:
            why = ((err or out).strip().splitlines() or ["git " + step[0] + " failed"])[0]
            problems.append("the board snapshot could not be committed (%s). factory-check reads each task's "
                            "approval from it, so the run does not start: commit the task files yourself, or fix "
                            "what git refused" % why)
            return None, problems, warnings
    return (git("rev-parse", "--short", "HEAD")[1].strip() or None), problems, warnings


def record_start(plan):
    """The test census of HEAD before anything lands. Each task's check can only
    see its own files; this is what lets the end of the run see all of them."""
    r = subprocess.run([sys.executable, os.path.join(HOOK_DIR, "factory-check.py"), "census", "--json"],
                       capture_output=True, text=True, cwd=ROOT)
    try:
        census = json.loads(r.stdout)
    except ValueError:
        return
    census["tasks"] = [t["id"] for t in plan["tasks"]]
    census["started"] = int(time.time())
    with open(os.path.join(F, "run-start.json"), "w", encoding="utf-8") as fh:
        json.dump(census, fh)


def delivery_gate(change):
    """What stops a run from starting at the level it runs at. Returns a list of
    problems (empty when the run may start)."""
    problems = []
    level = "local"
    try:
        r = subprocess.run([bash(), os.path.join(HOOK_DIR, "factory-autonomy.sh")],
                           capture_output=True, text=True, cwd=ROOT, timeout=20)
        level = (r.stdout.strip() or "local").split()[0]
    except (OSError, subprocess.SubprocessError, IndexError):
        pass
    if change:
        b = subprocess.run([bash(), os.path.join(HOOK_DIR, "factory-branch.sh"), change],
                           capture_output=True, text=True, cwd=ROOT, env=dict(os.environ, FACTORY_ROOT=ROOT))
        if b.returncode != 0:
            problems.append((b.stdout.strip() or b.stderr.strip() or "factory-branch refused").splitlines()[0])
    if level == "merge":
        q = subprocess.run([bash(), os.path.join(HOOK_DIR, "factory-quota.sh"), "check"],
                           capture_output=True, text=True, cwd=ROOT, env=dict(os.environ, FACTORY_ROOT=ROOT))
        if q.returncode != 0:
            problems.append((q.stdout.strip() or "quota check failed").splitlines()[0]
                            + " - at level merge a new change does not start on a guess")
    return problems


def main(argv):
    change = None
    if "--change" in argv:
        i = argv.index("--change")
        change = argv[i + 1] if i + 1 < len(argv) else None
    plan = build(proposed="--proposed" in argv, change=change)
    if change:
        plan["change"] = change
    if "--start" in argv and plan["ok"] and "--proposed" not in argv:
        gate = delivery_gate(change)
        if gate:
            plan["ok"] = False
            plan["problems"] += gate
    if "--start" in argv and plan["ok"] and "--proposed" not in argv:
        snap, problems, warnings = snapshot_board(plan)
        plan["warnings"] += warnings
        if problems:
            plan["ok"] = False
            plan["problems"] += problems
        elif snap:
            plan["snapshot"] = snap
    if "--start" in argv and plan["ok"] and "--proposed" not in argv:
        record_start(plan)
        try:
            plan["start_head"] = json.load(open(os.path.join(F, "run-start.json"))).get("head")
        except (OSError, ValueError):
            pass
        for t in plan["tasks"]:
            t.pop("allow_test_removal", None)
    if "--json" in argv:
        for t in plan["tasks"]:
            t.pop("allow_test_removal", None)
        print(json.dumps(plan, separators=(",", ":")))
    else:
        for p in plan["problems"]:
            print("PROBLEM " + p)
        for w in plan["warnings"]:
            print("WARNING " + w)
        for t in plan["tasks"]:
            print("PLAN  %s%s %s" % (t["id"], " after " + ",".join(t["deps"]) if t["deps"] else "",
                                     "(review)" if t["review"] else ""))
        for h in plan["held"]:
            print("HELD  %s %s" % (h["id"], h["reason"]))
        if plan.get("critical_path"):
            print("CRITICAL %d task(s): %s" % (len(plan["critical_path"]), " -> ".join(plan["critical_path"])))
        print("SUMMARY ok=%s tasks=%d held=%d workers=%s width=%s chain=%s" % (
            str(plan["ok"]).lower(), len(plan["tasks"]), len(plan["held"]), plan.get("workers", "-"),
            plan.get("width", "-"), len(plan.get("critical_path") or [])))
    return 0 if plan["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
