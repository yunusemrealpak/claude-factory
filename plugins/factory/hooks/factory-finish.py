#!/usr/bin/env python3
"""Factory: close a build. NOT a hook: the loop workflow runs it once, at the
end, whatever happened to the tasks.

Usage (from the project root):
  factory-finish --tasks <id,id,...> [--no-full] [--audit] [--halted "<why>"] [--json]

  --audit    an audit of this run is running alongside: delivery waits for it
  --halted   the run stopped early (STOP, the quota, the infrastructure): its
             base is kept for the next run, and the report says why
  --json     print the whole result as JSON instead of one line

Prints one line - what landed, the full check, where the report is - and writes
the report, readable, to .factory/last-run.md.

What a run reports has to come from disk, not from what its agents said about
themselves: an agent's closing sentence is written before the review, the land
or the block that followed it, and a summary built from those sentences can say
"awaiting review" about a task that landed an hour ago. So for every task of the
run this reads where its file is now and which commit carries it.

It also collects what the builders flagged and did not fix - the "## Open
concerns" section of each task file - and puts it first, with every must-have
a landed task's file lists that is not there (factory-musthaves: a file that
does not exist, a wiring line nobody wrote). A gap a builder noticed
is worth more to the developer than a table of green ticks, and in a tally of
twelve tasks it is exactly the line that gets skipped.

Then the tree is judged as a whole, once: factory-check --full runs the
project's own gate commands and compares the test census with the run's start.
When it is red, factory-bisect names the first task commit of the run that
fails the tests - the place to look, without a second gate after every land.
The change archive is synced, every change whose tasks are all done runs its
own acceptance command, and factory-deliver hands on what is ready: only after
the full check, and after the audit when one runs.

Two opt-in judges run after the full check, both from the config and neither a
model call. check.mutation runs the project's mutation tool on the run's
combined diff when the full check is green: a mutant that survives in code the
run changed is a test that does not assert the behaviour - not red, but the
first thing the report shows, and what the auditor reads
(.factory/mutation/last.txt). check.security.full runs the project's whole-tree
scans (CodeQL, npm audit, pip-audit - whatever it lists), each report in
.factory/scans/<n>.txt; a scan that exits non-zero is something to look at.
Each outcome is an event, and the run's line in metrics.jsonl counts them per
mechanism (budget, mutation, scan, monitor, stuck, lesson_rule), so whether a
mechanism earns its cost is a number.

Last, the run is closed: agents a dead session left open are swept, and
.factory/run.lock is removed - unless the run halted or left work unbuilt, in
which case it stays, marked halted, so the next run keeps this one's base.
"""
import glob
import importlib.util
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HOOK_DIR)
from factory_compat import bash  # noqa: E402
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


def config():
    try:
        return json.loads(read(os.path.join(F, "config.json")) or "{}") or {}
    except ValueError:
        return {}


def event(kind, **kw):
    try:
        row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "epoch": int(time.time()), "kind": kind}
        row.update(kw)
        with open(os.path.join(F, "events.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, separators=(",", ":")) + "\n")
    except OSError:
        pass


def shell(cmd, timeout):
    """(exit code or None on a timeout, output) of one command, through bash.
    The output goes to a file, not a pipe, and a timeout stops the command's
    whole process tree: a mutation tool runs the suite in children of its own,
    and one left holding a pipe would keep the finish waiting."""
    with tempfile.TemporaryFile() as out:
        kw = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
        try:
            p = subprocess.Popen([bash(), "-c", cmd], stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                 cwd=ROOT, **kw)
        except OSError as err:
            return 127, str(err)
        try:
            rc = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            rc = None
            try:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True)
                else:
                    os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill()
        out.seek(0)
        return rc, out.read().decode("utf-8", "replace")


# What metrics.jsonl counts per run: every mechanism that can catch something
# writes an event of its kind, with its outcome (budget: its level).
MECHANISMS = ("budget", "mutation", "scan", "monitor", "stuck", "lesson_rule")


def mechanisms(started):
    """{kind: {outcome: count}} of this run's mechanism events."""
    counts = {}
    for line in read(os.path.join(F, "events.jsonl")).splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        kind = e.get("kind") if isinstance(e, dict) else None
        if kind not in MECHANISMS:
            continue
        try:
            if started and int(e.get("epoch") or 0) < started:
                continue
        except (TypeError, ValueError):
            continue
        outcome = str((e.get("level") if kind == "budget" else e.get("outcome")) or "unknown")
        counts.setdefault(kind, {})
        counts[kind][outcome] = counts[kind].get(outcome, 0) + 1
    return counts


def full_scans(cfg):
    """check.security.full: the project's whole-tree scans. Returns (results,
    attention). A non-zero exit is something to look at, never red."""
    sec = (cfg.get("check") or {}).get("security")
    if not isinstance(sec, dict) or sec.get("enabled") is False:
        return [], []
    cmds = sec.get("full") or []
    if isinstance(cmds, str):
        cmds = [cmds]
    cmds = [c for c in cmds if isinstance(c, str) and c.strip()]
    if not cmds:
        return [], []
    d = os.path.join(F, "scans")
    os.makedirs(d, exist_ok=True)
    for old in glob.glob(os.path.join(d, "*.txt")):
        try:
            os.remove(old)
        except OSError:
            pass
    timeout = float(sec.get("timeout_min") or 30) * 60
    results, attention = [], []
    for i, cmd in enumerate(cmds, 1):
        rc, out = shell(cmd, timeout)
        rel = ".factory/scans/%d.txt" % i
        with open(os.path.join(ROOT, rel), "w", encoding="utf-8") as fh:
            fh.write("$ %s\n%s\n\n%s" % (cmd, "timed out after %g min" % (timeout / 60) if rc is None
                                          else "exit %d" % rc, out))
        try:
            tool = shlex.split(cmd)[0]
        except (ValueError, IndexError):
            tool = cmd.split(" ")[0]
        outcome = "clean" if rc == 0 else "timeout" if rc is None else "found"
        event("scan", scope="full", tool=os.path.basename(tool), outcome=outcome, exit=rc)
        if rc != 0:
            attention.append({"id": "scan", "concern": "%s %s - %s" % (
                cmd, "timed out" if rc is None else "exited %d" % rc, rel)})
        results.append({"command": cmd, "exit": rc, "report": rel})
    return results, attention


# cargo-mutants prints "MISSED <file:line:col>: ..." / "CAUGHT ...", StrykerJS
# "[Survived] <mutator>" / "[Killed] ..."; check.mutation.survived and .killed
# replace these for any other tool (group 1 of survived: file:line, optional).
DEFAULT_SURVIVED = r"(?i)^\s*(?:MISSED\b|\[SURVIVED\]|SURVIVED\b)(?:[^\n]*?(\S+\.\w+:\d+))?"
DEFAULT_KILLED = r"(?i)^\s*(?:CAUGHT\b|\[KILLED\]|KILLED\b)"


def in_changed(path, changed):
    """Is a path a tool reports one of the files the run changed? A tool run in
    a sub-project prints its paths from there, so a suffix match counts."""
    path = path.replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    return any(c == path or c.endswith("/" + path) or path.endswith("/" + c) for c in changed)


def mutation(cfg, start_head, verdict):
    """check.mutation on the run's combined diff, after a green full check.
    Returns (result or None, attention)."""
    mut = (cfg.get("check") or {}).get("mutation")
    if not isinstance(mut, dict) or not mut.get("command") or mut.get("enabled") is False:
        return None, []
    if verdict != "green":
        why = "the full check is %s" % verdict
        event("mutation", outcome="skipped", why=why)
        return {"status": "skipped", "why": why}, []
    if not start_head:
        return {"status": "skipped", "why": "no record of the commit the run started from"}, []
    rc, diff = run(["git", "diff", "--no-color", "--no-ext-diff", "%s..HEAD" % start_head])
    if rc != 0 or not diff.strip():
        return {"status": "skipped", "why": "the run changed nothing"}, []
    d = os.path.join(F, "mutation")
    os.makedirs(d, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for ext in ("*.diff", "*.log"):  # the last ten runs' are kept
        for old in sorted(glob.glob(os.path.join(d, ext)))[:-9]:
            try:
                os.remove(old)
            except OSError:
                pass
    diff_rel = ".factory/mutation/%s.diff" % stamp
    with open(os.path.join(ROOT, diff_rel), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(diff)
    _, names = run(["git", "diff", "--name-only", "%s..HEAD" % start_head])
    files = [p for p in (n.strip() for n in names.splitlines()) if p and os.path.isfile(os.path.join(ROOT, p))]
    cmd = mut["command"].replace("{diff}", shlex.quote(diff_rel)).replace(
        "{files}", " ".join(shlex.quote(p) for p in files))
    timeout = float(mut.get("timeout_min") or 30) * 60
    code, out = shell(cmd, timeout)
    log_rel = ".factory/mutation/%s.log" % stamp
    with open(os.path.join(ROOT, log_rel), "w", encoding="utf-8") as fh:
        fh.write("$ %s\n%s\n" % (cmd, out))
    changed = set(p.strip() for p in names.splitlines() if p.strip())
    try:
        surv_re = re.compile(mut.get("survived") or DEFAULT_SURVIVED, re.M)
        killed_re = re.compile(mut.get("killed") or DEFAULT_KILLED, re.M)
    except re.error as err:
        why = "check.mutation's regex does not compile: %s" % err
        event("mutation", outcome="error", why=why)
        return {"status": "error", "why": why, "command": cmd}, []
    survivors, elsewhere = [], 0
    for line in out.splitlines():
        m = surv_re.search(line)
        if not m:
            continue
        loc = m.group(1) if surv_re.groups >= 1 and m.group(1) else None
        mm = re.match(r"^(.+?):\d+", loc) if loc else None
        if mm and not in_changed(mm.group(1), changed):
            elsewhere += 1  # in a file this run did not change: the tool ran wider than the diff
            continue
        survivors.append(" ".join(line.split())[:300])
    killed = sum(1 for line in out.splitlines() if killed_re.search(line))
    if code is None:
        status = "timeout"
    elif survivors:
        status = "survived"
    elif code != 0 and not killed:
        status = "failed"
    else:
        status = "clean"
    with open(os.path.join(d, "last.txt"), "w", encoding="utf-8") as fh:
        fh.write("# Mutation testing of %s..HEAD (%s)\n$ %s\n%s\n" % (
            start_head[:12], stamp, cmd, "timed out after %g min" % (timeout / 60) if code is None else "exit %d" % code))
        fh.write("status: %s; survived in changed files: %d; killed: %d; survived elsewhere: %d\n\n"
                 % (status, len(survivors), killed, elsewhere))
        fh.write("".join("%s\n" % l for l in survivors))
        fh.write("\nfull output: %s\n" % log_rel)
    event("mutation", outcome=status, survived=len(survivors), killed=killed)
    attention = []
    if survivors:
        attention.append({"id": "mutation", "concern": "%d mutant(s) survived in code this run changed - a test "
                          "that does not assert the behaviour: %s (.factory/mutation/last.txt)"
                          % (len(survivors), "; ".join(survivors[:3]))})
    return {"status": status, "survived": len(survivors), "killed": killed, "command": cmd,
            "report": ".factory/mutation/last.txt"}, attention


def deliver(ids, audit):
    """A change that closed in this run goes to factory-deliver, which hands it
    to the publisher only when the full check is green at HEAD and the audit,
    when one runs, has spoken."""
    if not ids:
        return []
    _, out = run([sys.executable, os.path.join(HOOK_DIR, "factory-deliver.py"), "--if-ready"] + list(ids)
                 + (["--audit"] if audit else []))
    return [l for l in out.splitlines() if l.startswith("DELIVER")]


def bisect(start_head):
    """The first task commit of this run that fails the tests, when the full
    check is red. None when there is nothing to search or it is turned off."""
    try:
        cfg = json.loads(read(os.path.join(F, "config.json")) or "{}")
    except ValueError:
        cfg = {}
    if (cfg.get("finish") or {}).get("bisect", True) is False or not start_head:
        return None
    if not ((cfg.get("commands") or {}).get("test") or "").strip():
        return None
    _, n = run(["git", "rev-list", "--count", "--grep", "^Factory-Task: ", "%s..HEAD" % start_head])
    try:
        n = int(n.strip() or 0)
    except ValueError:
        n = 0
    if n < 1:
        return None
    _, out = run([bash(), os.path.join(HOOK_DIR, "factory-bisect.sh"), "--max", str(n)])
    for line in out.splitlines():
        if line.startswith(("FIRST BAD", "BISECT CLEAN", "BISECT INCONCLUSIVE")):
            return line.strip()
    return "BISECT gave no answer: " + (out.strip().splitlines() or ["(no output)"])[-1][:200]


def close_run(ids, halted):
    """run.lock goes when the run is over. A run that halted, or left a task of
    its own unbuilt, keeps it - marked halted - so the next run keeps its base
    and nothing mistakes it for a run still going."""
    lock = os.path.join(F, "run.lock")
    left = [i for i in ids for col in ("backlog", "in-progress")
            if os.path.isfile(os.path.join(ROOT, "tasks", col, i + ".md"))]
    if not halted and not left:
        try:
            os.remove(lock)
        except OSError:
            pass
        return left
    try:
        rec = json.loads(read(lock) or "{}")
    except ValueError:
        rec = {}
    if rec:
        rec["state"] = "halted"
        rec["halted"] = halted or "%d task(s) of this run were not built" % len(left)
        with open(lock, "w", encoding="utf-8") as fh:
            json.dump(rec, fh)
    return left


HELPER_SUFFIXES = ("land", "block", "recheck", "settle")


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
                or label in ("plan", "finish", "preflight"):
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
        "mechanisms": mechanisms(started),
    })
    try:
        with open(os.path.join(F, "metrics.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")
    except OSError:
        pass
    return rec


def retro_state():
    """Is a retrospective due, and may the run start it by itself? The marker is
    written either way (the brief shows it); `retro.mode: full` is the only
    setting under which the workflow runs the retro agent unasked."""
    try:
        r = subprocess.run([sys.executable, os.path.join(HOOK_DIR, "factory-retro-apply.py"), "due"],
                           capture_output=True, text=True, cwd=ROOT, errors="replace")
        due = r.returncode == 0
    except OSError:
        due = False
    mode = "suggest"
    try:
        mode = (json.loads(read(os.path.join(F, "config.json")) or "{}").get("retro") or {}).get("mode") or "suggest"
    except (ValueError, AttributeError):
        pass
    return {"due": due, "mode": mode}


def reviews(ids):
    """Failed reviews on file for the run's tasks - a task that landed before its
    review carries the verdict in .factory/reviews/<id>.json and nowhere else."""
    out = []
    for tid in ids:
        try:
            rec = json.loads(read(os.path.join(F, "reviews", tid + ".json")) or "{}")
        except ValueError:
            continue
        rounds = rec.get("rounds") or []
        if rec.get("verdict") == "owed":
            out.append({"id": tid, "concern": "its review after landing never finished - the change is not delivered "
                                              "until it does (the next /factory:run reviews it)"})
        if rec.get("verdict") == "fail" and rounds:
            for f in (rounds[-1].get("blocking") or [])[:5]:
                out.append({"id": tid, "concern": "review failed%s: %s" % (
                    " after landing" if rec.get("mode") == "after" else "", f)})
    return out


def musthaves(ids):
    """factory-musthaves over the landed tasks: what their files say must exist."""
    if not ids:
        return []
    try:
        spec = importlib.util.spec_from_file_location("factory_musthaves",
                                                      os.path.join(HOOK_DIR, "factory-musthaves.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.check(ids)
    except Exception:  # noqa: BLE001 - the report is still written without it
        return []


def main(argv):
    if not os.path.isfile(os.path.join(F, "active")):
        print(json.dumps({"error": "no .factory/active here"}) if "--json" in argv else
              "FINISH REFUSED: no .factory/active here")
        return 1
    halted = argv[argv.index("--halted") + 1] if "--halted" in argv and argv.index("--halted") + 1 < len(argv) else ""
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
        # The last review in the task file, when it failed.
        found_reviews = re.findall(r"^##\s+Review\b[^\n]*\n(.*?)(?=^#{1,2}\s|\Z)", text, re.M | re.S)
        if found_reviews and re.search(r"^verdict:\s*fail", found_reviews[-1], re.M) \
                and not os.path.exists(os.path.join(F, "reviews", tid + ".json")):
            found = [l.strip()[2:] for l in found_reviews[-1].splitlines() if l.strip().startswith("- ")]
            for f in found[:5] or ["the review failed without listing findings"]:
                attention.append({"id": tid, "concern": "review failed: " + f})
    attention += reviews(ids)
    must = musthaves([b["id"] for b in board if b["lane"] == "done"])
    for r in must:
        for miss in r["missing"]:
            attention.append({"id": r["id"], "concern": "must-have missing: " + miss})

    try:
        start_head = json.loads(read(os.path.join(F, "run-start.json")) or "{}").get("head")
    except ValueError:
        start_head = None
    full = {"verdict": "skipped", "output": "nothing landed, so there was nothing new to judge"}
    first_bad = None
    if "--no-full" not in argv and any(b["lane"] == "done" for b in board):
        rc, out = run([sys.executable, os.path.join(HOOK_DIR, "factory-check.py"), "--full"])
        lines = out.splitlines()
        full = {"verdict": "green" if rc == 0 else "red",
                "output": "\n".join(lines[-60:] if rc else [l for l in lines if l.startswith("  ") or "FULL" in l])}
        if rc != 0:
            first_bad = bisect(start_head)
            if first_bad:
                attention.insert(0, {"id": "full check", "concern": "red; " + first_bad})
    cfg = config()
    scans, more = full_scans(cfg) if full["verdict"] != "skipped" else ([], [])
    attention += more
    mut, more = mutation(cfg, start_head, full["verdict"]) if full["verdict"] != "skipped" else (None, [])
    attention += more

    _, sync = run([bash(), os.path.join(HOOK_DIR, "factory-change.sh"), "sync"])
    acceptance = []
    closed_now = re.findall(r"^CLOSED-NOW\s+(C[0-9]+)-", sync, re.M)
    for name in re.findall(r"^unverified\s+(\S+)", sync, re.M):
        cid = name.split("-")[0]
        _, out = run([bash(), os.path.join(HOOK_DIR, "factory-accept.sh"), cid])
        verdict = next((l for l in out.splitlines() if re.match(r"ACCEPT (GREEN|RED|NONE)", l)), "ACCEPT ? " + cid)
        acceptance.append({"change": cid, "result": verdict})
    if acceptance:
        _, sync = run([bash(), os.path.join(HOOK_DIR, "factory-change.sh"), "sync"])
        closed_now += re.findall(r"^CLOSED-NOW\s+(C[0-9]+)-", sync, re.M)
    delivery = deliver(sorted(set(closed_now)), "--audit" in argv)
    run([bash(), os.path.join(HOOK_DIR, "factory-sweep.sh"), "run-end", ROOT])
    run([bash(), os.path.join(HOOK_DIR, "factory-dash.sh")])

    started = 0
    try:
        started = int(json.loads(read(os.path.join(F, "run-start.json")) or "{}").get("started") or 0)
    except (ValueError, TypeError):
        pass
    m = metrics(ids, board, started)

    left = close_run(ids, halted)
    result = {
        "attention": attention,
        "board": board,
        "full_check": full["verdict"],
        "full_output": full["output"],
        "first_bad": first_bad,
        "changes": [l for l in sync.splitlines() if l.strip()],
        "acceptance": acceptance,
        "delivery": delivery,
        "halted": halted or None,
        "left": left,
        "retro": retro_state(),
        "must_haves": {"checked": sum(r["checked"] for r in must),
                       "missing": sum(len(r["missing"]) for r in must)},
        "mutation": mut,
        "scans": scans,
        "mechanisms": m.get("mechanisms") or {},
    }

    lines = ["# Last run", ""]
    if halted:
        lines += ["Halted: %s. The next /factory:run continues from this run's base." % halted, ""]
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
    if mut:
        lines += ["## Mutation: %s" % mut["status"], ""]
        lines += ["%s." % mut["why"] if mut.get("why") else "%d survived in changed files, %d killed - %s"
                  % (mut.get("survived", 0), mut.get("killed", 0), mut.get("report", "")), ""]
    if scans:
        lines += ["## Scans", ""] + ["- `%s`: %s (%s)" % (s_["command"], "timed out" if s_["exit"] is None
                                                          else "exit %d" % s_["exit"], s_["report"])
                                     for s_ in scans] + [""]
    if acceptance:
        lines += ["## Change acceptance", ""] + ["- %s" % a["result"] for a in acceptance] + [""]
    if delivery:
        lines += ["## Delivery", ""] + ["- %s" % d for d in delivery] + [""]
    if result["retro"].get("due"):
        lines += ["A retrospective is due: /factory:retro.", ""]
    with open(os.path.join(F, "last-run.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    if "--json" in argv:
        print(json.dumps(result))
        return 0
    landed = sum(1 for b in board if b["lane"] == "done")
    blocked = sum(1 for b in board if b["lane"] == "blocked")
    parts = ["FINISH %d/%d landed" % (landed, len(board))]
    if blocked:
        parts.append("%d blocked" % blocked)
    if left:
        parts.append("%d not built" % len(left))
    parts.append("full check %s" % full["verdict"] + ("; %s" % first_bad if first_bad else ""))
    if result["must_haves"]["missing"]:
        parts.append("%d must-have(s) missing" % result["must_haves"]["missing"])
    if mut and mut.get("survived"):
        parts.append("%d mutant(s) survived" % mut["survived"])
    if attention:
        parts.append("%d to look at" % len(attention))
    for d in delivery:
        m = re.match(r"^DELIVER (WAIT |HELD |SKIPPED )?(C[0-9]+)", d)
        if m:
            parts.append("%s %s" % (m.group(2), {"WAIT ": "waits", "HELD ": "held", "SKIPPED ": "already handed on"}
                                    .get(m.group(1), "handed on")))
    if halted:
        parts.append("halted: %s" % halted)
    if result["retro"].get("due"):
        parts.append("retro due")
    line = "; ".join(parts) + " - report .factory/last-run.md"
    print(line)
    # The developer is not watching: the run's one line goes to the desktop and,
    # when notify.ntfy is set, to the phone (factory-notify; muted in tests).
    run([sys.executable, os.path.join(HOOK_DIR, "factory-notify.py"),
         "Factory: run %s" % ("halted" if halted else "finished"), line, "--tag", "finish", "--bg"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
