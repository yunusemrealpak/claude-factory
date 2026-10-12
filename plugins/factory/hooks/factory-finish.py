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
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

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


def deliver_closed(ids):
    """A change that closed in this run is handed to the publisher, detached: it
    waits on CI and must not hold the run's end. The pending mark is what lets a
    later session pick it up if this one never gets to (a level that was local,
    a sleeping laptop). The publisher itself refuses below level pr."""
    if not ids:
        return
    pub = os.path.join(F, "publish")
    try:
        os.makedirs(pub, exist_ok=True)
    except OSError:
        return
    for cid in ids:
        try:
            if not os.path.exists(os.path.join(pub, cid + ".json")):
                open(os.path.join(pub, cid + ".pending"), "w").close()
            subprocess.Popen(["python3", os.path.join(HOOK_DIR, "factory-publish.py"), cid], cwd=ROOT,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except OSError:
            pass


HELPER_SUFFIXES = ("land", "block", "recheck")


def pricer():
    """factory-cost's price table, loaded from its sibling file."""
    try:
        spec = importlib.util.spec_from_file_location("factory_cost", os.path.join(HOOK_DIR, "factory-cost.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.price
    except Exception:
        return lambda model: None


def agent_labels():
    """agent id -> description, from the transcripts' .meta.json files: the way
    to name a turn the module could not label when the agent was spawned."""
    pdir = os.path.join(os.path.expanduser("~"), ".claude", "projects", re.sub(r"[^A-Za-z0-9]", "-", ROOT))
    out = {}
    for path in glob.glob(os.path.join(pdir, "*", "subagents", "**", "agent-*.meta.json"), recursive=True):
        try:
            with open(path, encoding="utf-8") as fh:
                desc = json.load(fh).get("description")
        except (OSError, ValueError):
            continue
        if desc:
            out[os.path.basename(path)[len("agent-"):-len(".meta.json")]] = desc
    return out


def split_label(label, ids):
    """("T-01 retry") -> ("T-01", "retry"); run-level steps have no task."""
    label = (label or "").strip()
    first, _, rest = label.partition(" ")
    if first in ids:
        return first, rest
    # Workflow descriptions may carry a prefix before the label.
    m = re.search(r"\b(%s)\b\s*(.*)$" % "|".join(re.escape(i) for i in ids), label) if ids else None
    return (m.group(1), m.group(2).strip()) if m else (None, label)


def metrics(ids, board, started):
    """One line for this run in .factory/metrics.jsonl: what the run cost and
    how it went, from the module's usage.jsonl. The point is a number to compare
    from one run to the next, so the same fields are written every time."""
    landed = [b["id"] for b in board if b["lane"] == "done"]
    rec = {"ts": int(time.time()), "tasks": len(ids), "landed": len(landed)}
    rows = []
    for line in read(os.path.join(F, "usage.jsonl")).splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not started or (row.get("ts") or 0) >= started:
            rows.append(row)
    rec["turns"] = len(rows)
    by_label = {}
    names = agent_labels() if any(not r.get("label") for r in rows) else {}
    price = pricer()
    total = helpers = unlabeled = lead = 0.0
    tasks_usd, retried = {}, set()
    for r in rows:
        label = r.get("label") or names.get(r.get("agent"))
        p = price(r.get("model"))
        usd = 0.0
        if p:
            usd = ((r.get("input") or 0) * p[0] + (r.get("output") or 0) * p[1]
                   + (r.get("cache_read") or 0) * p[2] + (r.get("cache_write") or 0) * p[3]) / 1e6
        total += usd
        tid, kind = split_label(label, ids)
        # The session that runs the workflow is not an unknown: its turns are
        # what waiting on the run costs, and the number to bring down.
        is_lead = r.get("type") == "main" or r.get("agent") == "main"
        if is_lead:
            lead += usd
        elif not label:
            unlabeled += usd
        if (r.get("type") or "").endswith("runner") or (tid and kind.split(" ")[0] in HELPER_SUFFIXES) \
                or label in ("plan", "finish"):
            helpers += usd
        if tid:
            tasks_usd[tid] = tasks_usd.get(tid, 0.0) + usd
            if kind.startswith(("retry", "fix")):
                retried.add(tid)
    first_try = [t for t in landed if t not in retried]
    stalled = [i for i in ids if os.path.exists(os.path.join(F, "no-progress", i))]
    rec.update({
        "first_try_green": len(first_try),
        "first_try_rate": round(len(first_try) / len(ids), 2) if ids else None,
        "stalled": len(stalled),
        "stalled_rate": round(len(stalled) / len(ids), 2) if ids else None,
        "usd_total": round(total, 3) if rows else None,
        "usd_per_landed": round(total / len(landed), 3) if rows and landed else None,
        "helpers_share": round(helpers / total, 3) if total else None,
        "lead_share": round(lead / total, 3) if total else None,
        "lead_turns": sum(1 for r in rows if r.get("type") == "main" or r.get("agent") == "main"),
        "unlabeled_share": round(unlabeled / total, 3) if total else None,
        "usd_by_task": {k: round(v, 3) for k, v in sorted(tasks_usd.items())},
    })
    try:
        with open(os.path.join(F, "metrics.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")
    except OSError:
        pass
    return rec


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
    closed_now = re.findall(r"^CLOSED-NOW\s+(C[0-9]+)-", sync, re.M)
    for name in re.findall(r"^unverified\s+(\S+)", sync, re.M):
        cid = name.split("-")[0]
        _, out = run(["bash", os.path.join(HOOK_DIR, "factory-accept.sh"), cid])
        verdict = next((l for l in out.splitlines() if re.match(r"ACCEPT (GREEN|RED|NONE)", l)), "ACCEPT ? " + cid)
        acceptance.append({"change": cid, "result": verdict})
    if acceptance:
        _, sync = run(["bash", os.path.join(HOOK_DIR, "factory-change.sh"), "sync"])
        closed_now += re.findall(r"^CLOSED-NOW\s+(C[0-9]+)-", sync, re.M)
    deliver_closed(sorted(set(closed_now)))
    run(["bash", os.path.join(HOOK_DIR, "factory-dash.sh")])

    started = 0
    try:
        started = int(json.loads(read(os.path.join(F, "run-start.json")) or "{}").get("started") or 0)
    except (ValueError, TypeError):
        pass
    m = metrics(ids, board, started)

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
    if m["usd_total"] is not None:
        lines += ["", "Cost: $%.2f over %d turn(s), $%s per landed task, helpers %.0f%% and the lead session %.0f%% (%d turn(s)) of it; first try green %d/%d." % (
            m["usd_total"], m["turns"], m["usd_per_landed"] if m["usd_per_landed"] is not None else "-",
            100 * (m["helpers_share"] or 0), 100 * (m["lead_share"] or 0), m["lead_turns"],
            m["first_try_green"], m["tasks"])]
    lines += ["", "## Full check: %s" % full["verdict"], "", "```", full["output"], "```", ""]
    if acceptance:
        lines += ["## Change acceptance", ""] + ["- %s" % a["result"] for a in acceptance] + [""]
    with open(os.path.join(F, "last-run.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
