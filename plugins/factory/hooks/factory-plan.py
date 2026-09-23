#!/usr/bin/env python3
"""Factory: the board as a build plan. NOT a hook: the /factory:fast workflow
reads it before it starts anything.

Usage (from the project root):
  factory-plan            human-readable
  factory-plan --json     one JSON object, what the workflow consumes

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
import sys

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
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


def build():
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
    out["effort"] = {"build": fast.get("effort_build") or "medium",
                     "escalate": fast.get("effort_escalate") or "xhigh",
                     "review": fast.get("effort_review") or "high"}

    ids = subprocess.run(["bash", os.path.join(HOOK_DIR, "factory-ids.sh"), "check", ROOT],
                         capture_output=True, text=True)
    if ids.returncode != 0:
        out["problems"] += [l for l in ids.stdout.splitlines() if l.strip()] or ["factory-ids check failed"]

    lanes = {n: lane(n) for n in ("backlog", "in-progress", "done", "blocked")}
    out["counts"] = {k.replace("-", "_"): len(v) for k, v in lanes.items()}
    done = set(lanes["done"])
    if lanes["in-progress"]:
        out["warnings"].append("taken over from an earlier run, still in tasks/in-progress: " + " ".join(lanes["in-progress"]))

    meta, held = {}, {}
    for col in ("backlog", "in-progress"):
        for tid in lanes[col]:
            fm = frontmatter(os.path.join(ROOT, "tasks", col, tid + ".md"))
            deps = [d.strip().strip("\"'") for d in re.split(r"[,\s]+", fm.get("depends_on", "").strip("[]")) if d.strip()]
            meta[tid] = {"deps": [d for d in deps if d not in done], "fm": fm}
            if fm.get("needs_human", "").lower() == "true":
                held[tid] = "needs_human - a decision for the developer"
            elif os.path.exists(os.path.join(F, "no-progress", tid)):
                held[tid] = "stalled - the check saw the same failure twice; it needs a different approach"
    blocked = set(lanes["blocked"])

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
                             "review": fm.get("review", "").lower() == "always"})
    out["held"] = [{"id": t, "reason": r} for t, r in sorted(held.items())]

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


def main(argv):
    plan = build()
    if "--json" in argv:
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
        print("SUMMARY ok=%s tasks=%d held=%d workers=%s" % (str(plan["ok"]).lower(), len(plan["tasks"]),
                                                             len(plan["held"]), plan.get("workers", "-")))
    return 0 if plan["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
