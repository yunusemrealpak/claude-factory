#!/usr/bin/env python3
"""Factory: a cheat monitor's verdict, filtered, and what it does to the task.
NOT a hook: the monitor (agents/monitor.md) pipes its verdict into it as its
last command.

Usage (from the project root):
  factory-monitor-submit <id> < verdict.json

  {"verdict": "cheat" | "clear",
   "evidence": [{"file": "src/a.py", "line": 12, "quote": "<the added line>",
                 "why": "..."}]}

The monitor is asked one narrow question (review.monitor; factory-settle says
REVIEW MONITOR): does this diff make the checks pass without doing what the
task asks? This script decides what the answer is worth:

  - evidence whose file is not in the task's diff, or whose quote is not in a
    line the task added, is dropped - the same test factory-review-submit puts
    a finding to;
  - a cheat verdict with no evidence left is recorded as clear: a suspicion
    nobody can point at moves nothing;
  - a cheat verdict blocks the task (factory-block) and asks the developer
    (factory-ask). It is never handed back to the builder as a target - a
    monitor whose verdict a builder is told to make go away stops seeing the
    cheat, not the cheating;
  - a clear verdict changes nothing: the reviewer reviews the task as usual.

Every verdict is in .factory/monitor/<id>.json and in the event log
(kind "monitor", outcome cheat|clear), so how often it fires and how often the
developer agrees can be counted. The last line says it:
  MONITOR CLEAR <id> | MONITOR CHEAT <id>: blocked and asked |
  MONITOR REFUSED <id>: ...
"""
import datetime
import importlib.util
import json
import os
import sys
import time

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HOOK_DIR)

ROOT = os.getcwd()
F = os.path.join(ROOT, ".factory")
T = os.path.join(ROOT, "tasks")


def review_submit():
    """factory-review-submit as a module: its diff reading and its quote test."""
    spec = importlib.util.spec_from_file_location("factory_review_submit",
                                                  os.path.join(HOOK_DIR, "factory-review-submit.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def event(tid, outcome, kept, dropped):
    try:
        with open(os.path.join(F, "events.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": now_iso(), "epoch": int(time.time()), "kind": "monitor", "task": tid,
                                 "outcome": outcome, "evidence": kept, "dropped": dropped}) + "\n")
    except OSError:
        pass


def judge(rs, e, diff):
    """None when the evidence stands, else why it was dropped."""
    path = rs.npath(str(e.get("file") or "").strip()) if e.get("file") else ""
    if path.startswith("./"):
        path = path[2:]
    entry = diff.get(path)
    if not entry:
        return "%s is not in this task's diff" % (path or "no file")
    quote = rs.squash(e.get("quote"))
    if not quote:
        return "no quote from the diff"
    if quote not in rs.squash("\n".join(t for _, t in entry["added"])):
        return "the quote is not in the lines this task added"
    return None


def main(argv):
    if not argv or argv[0].startswith("-"):
        print("usage: factory-monitor-submit <id> < verdict.json", file=sys.stderr)
        return 2
    tid = argv[0]
    if not os.path.isfile(os.path.join(F, "active")):
        print("MONITOR REFUSED %s: %s has no .factory/active." % (tid, ROOT))
        return 1
    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else None
    except ValueError as e:
        print("MONITOR REFUSED %s: the verdict is not JSON (%s). Pipe {\"verdict\": ..., \"evidence\": [...]} in."
              % (tid, e))
        return 1
    verdict = str((data or {}).get("verdict") or "").strip().lower() if isinstance(data, dict) else ""
    if verdict not in ("cheat", "clear"):
        print("MONITOR REFUSED %s: \"verdict\" must be \"cheat\" or \"clear\"." % tid)
        return 1
    evidence = data.get("evidence") or []
    if not isinstance(evidence, list):
        print("MONITOR REFUSED %s: \"evidence\" must be a list." % tid)
        return 1
    path = os.path.join(T, "in-progress", tid + ".md")
    if not os.path.isfile(path):
        print("MONITOR REFUSED %s: no tasks/in-progress/%s.md - a task is monitored before it lands." % (tid, tid))
        return 1
    if not os.path.isfile(os.path.join(F, "verified", tid)):
        print("MONITOR REFUSED %s: no green check - a task is monitored after its check is green." % tid)
        return 1

    rs = review_submit()
    diff, _ = rs.task_diff(tid, rs.files_touched(rs.read(path)), False)
    kept, dropped = [], []
    for e in evidence:
        if not isinstance(e, dict):
            continue
        why = judge(rs, e, diff or {})
        item = {"file": e.get("file"), "line": e.get("line"), "quote": rs.squash(e.get("quote"))[:200],
                "why": rs.squash(e.get("why"))[:300]}
        if why:
            dropped.append(dict(item, dropped=why))
        else:
            kept.append(item)
    outcome = "cheat" if verdict == "cheat" and kept else "clear"

    os.makedirs(os.path.join(F, "monitor"), exist_ok=True)
    rec = {"task": tid, "at": now_iso(), "asked": verdict, "outcome": outcome, "evidence": kept, "dropped": dropped}
    tmp = os.path.join(F, "monitor", tid + ".json.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=1)
    os.replace(tmp, os.path.join(F, "monitor", tid + ".json"))
    event(tid, outcome, len(kept), len(dropped))
    for d in dropped:
        print("  dropped  %s:%s %s - %s" % (d["file"] or "?", d["line"] or "?", d["why"] or "", d["dropped"]))
    for k in kept:
        print("  evidence %s:%s %s" % (k["file"] or "?", k["line"] or "?", k["why"] or k["quote"]))

    if outcome == "clear":
        if verdict == "cheat":
            print("MONITOR CLEAR %s (a cheat verdict with no evidence left in the diff counts for nothing)" % tid)
        else:
            print("MONITOR CLEAR %s" % tid)
        return 0
    said = "; ".join("%s:%s %s" % (k["file"], k["line"] or "?", k["why"] or k["quote"]) for k in kept)
    rc, out = rs.sh("factory-block.sh", tid, ("the cheat monitor found the checks passed without the work: " + said)[:400])
    if rc != 0:
        print("MONITOR REFUSED %s: the verdict is recorded, but factory-block failed: %s" % (
            tid, (out.splitlines() or ["no output"])[0][:200]))
        return 1
    rs.sh("factory-ask.sh", "ask", tid,
          ("The cheat monitor says %s passes its checks without doing what it asks: %s. Is that right? Answer how it "
           "should be built - or that the monitor is wrong - and the next run builds it with your answer."
           % (tid, said))[:900])
    print("MONITOR CHEAT %s: blocked and asked" % tid)
    return 0


if __name__ == "__main__":
    # Text in and out is UTF-8 whatever the system's code page (cp1254 on a
    # Turkish Windows cannot decode every letter a task file holds).
    for _stream in (sys.stdin, sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    sys.exit(main(sys.argv[1:]))
