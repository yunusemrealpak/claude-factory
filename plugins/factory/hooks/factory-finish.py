#!/usr/bin/env python3
"""Factory: close a build. NOT a hook: the /factory:fast workflow runs it once,
at the end, whatever happened to the tasks.

Usage (from the project root):
  factory-finish --tasks <id,id,...> [--no-full]

Prints one JSON object and writes the same report, readable, to
.factory/last-run.md.

What a run reports has to come from disk, not from what its agents said about
themselves: an agent's closing sentence is written before the review, the land
or the block that followed it, and a summary built from those sentences can say
"awaiting review" about a task that landed an hour ago. So for every task of the
run this reads where its file is now and which commit carries it.

It also collects what the builders flagged and did not fix - the "## Open
concerns" section of each task file - and puts it first. A gap a builder noticed
is worth more to the developer than a table of green ticks, and in a tally of
twelve tasks it is exactly the line that gets skipped.

Then the tree is judged as a whole, once: factory-check --full runs the
project's own gate commands and compares the test census with the run's start;
the change archive is synced and every change whose tasks are all done runs its
own acceptance command.
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
LANES = ("done", "blocked", "in-progress", "backlog")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def section(text, title):
    m = re.search(r"^##\s+%s\s*$(.*?)(?=^#{1,2}\s|\Z)" % re.escape(title), text, re.M | re.S)
    if not m:
        return []
    return [l.strip()[2:].strip() if l.strip().startswith(("- ", "* ")) else l.strip()
            for l in m.group(1).splitlines() if l.strip() and not l.strip().startswith("<")]


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, errors="replace")
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main(argv):
    if not os.path.isfile(os.path.join(F, "active")):
        print(json.dumps({"error": "no .factory/active here"}))
        return 1
    ids = []
    if "--tasks" in argv and argv.index("--tasks") + 1 < len(argv):
        ids = [i for i in re.split(r"[,\s]+", argv[argv.index("--tasks") + 1]) if i]
    if not ids:
        try:
            ids = json.loads(read(os.path.join(F, "run-start.json")) or "{}").get("tasks", [])
        except ValueError:
            ids = []

    board, attention = [], []
    for tid in ids:
        lane, text = "missing", ""
        for col in LANES:
            p = os.path.join(ROOT, "tasks", col, tid + ".md")
            if os.path.isfile(p):
                lane, text = col, read(p)
                break
        _, sha = run(["git", "log", "-1", "--format=%h", "--grep", "^Factory-Task: %s$" % tid])
        entry = {"id": tid, "lane": lane, "commit": sha.strip() or None}
        if lane == "blocked":
            reasons = section(text, "Blocked reason")
            entry["reason"] = reasons[-1] if reasons else "no reason recorded"
        board.append(entry)
        for c in section(text, "Open concerns"):
            attention.append({"id": tid, "concern": c})
        # The last review on file, when it failed - a task that landed before
        # its review carries the verdict here and nowhere else.
        reviews = re.findall(r"^##\s+Review\b[^\n]*\n(.*?)(?=^#{1,2}\s|\Z)", text, re.M | re.S)
        if reviews and re.search(r"^verdict:\s*fail", reviews[-1], re.M):
            found = [l.strip()[2:] for l in reviews[-1].splitlines() if l.strip().startswith("- ")]
            for f in found[:5] or ["the review failed without listing findings"]:
                attention.append({"id": tid, "concern": "review failed: " + f})

    full = {"verdict": "skipped", "output": "nothing landed, so there was nothing new to judge"}
    if "--no-full" not in argv and any(b["lane"] == "done" for b in board):
        rc, out = run(["python3", os.path.join(HOOK_DIR, "factory-check.py"), "--full"])
        lines = out.splitlines()
        full = {"verdict": "green" if rc == 0 else "red",
                "output": "\n".join(lines[-60:] if rc else [l for l in lines if l.startswith("  ") or "FULL" in l])}

    _, sync = run(["bash", os.path.join(HOOK_DIR, "factory-change.sh"), "sync"])
    acceptance = []
    for name in re.findall(r"^unverified\s+(\S+)", sync, re.M):
        cid = name.split("-")[0]
        _, out = run(["bash", os.path.join(HOOK_DIR, "factory-accept.sh"), cid])
        verdict = next((l for l in out.splitlines() if re.match(r"ACCEPT (GREEN|RED|NONE)", l)), "ACCEPT ? " + cid)
        acceptance.append({"change": cid, "result": verdict})
    if acceptance:
        _, sync = run(["bash", os.path.join(HOOK_DIR, "factory-change.sh"), "sync"])
    run(["bash", os.path.join(HOOK_DIR, "factory-dash.sh")])

    result = {
        "attention": attention,
        "board": board,
        "full_check": full["verdict"],
        "full_output": full["output"],
        "changes": [l for l in sync.splitlines() if l.strip()],
        "acceptance": acceptance,
    }

    lines = ["# Last run", ""]
    if attention:
        lines += ["## Needs your attention", ""] + ["- %s: %s" % (a["id"], a["concern"]) for a in attention] + [""]
    lines += ["## Tasks", "", "| task | where it is | commit | note |", "| --- | --- | --- | --- |"]
    lines += ["| %s | %s | %s | %s |" % (b["id"], b["lane"], b["commit"] or "-", b.get("reason", "")) for b in board]
    lines += ["", "## Full check: %s" % full["verdict"], "", "```", full["output"], "```", ""]
    if acceptance:
        lines += ["## Change acceptance", ""] + ["- %s" % a["result"] for a in acceptance] + [""]
    with open(os.path.join(F, "last-run.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
