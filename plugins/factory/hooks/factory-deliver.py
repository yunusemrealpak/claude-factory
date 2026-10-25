#!/usr/bin/env python3
"""Factory: hand a finished change to the publisher - only when everything
that judges it has spoken. NOT a hook: factory-finish and the auditor both run
it, and whichever of them is last hands the change on.

Usage (from the project root):
  factory-deliver --if-ready [<C>...] [--audit] [--skip-audit]

  <C>          changes the run closed; with none, the ones still waiting
  --audit      an audit of this run is running: wait for its file
  --skip-audit hand on without the audit (the developer's call, when the
               auditor never finished)

A change is handed on (.factory/publish/<C>.pending, and the publisher started
detached) only when, all together:
  - this run's full check is green for the commit that is HEAD now, on a
    tree with nothing uncommitted in product code (.factory/full-check);
  - no review of the change's tasks failed (.factory/reviews/<id>.json, or a
    "verdict: fail" under the task's last ## Review), and none that runs after
    landing is still owed;
  - when an audit runs: its file, .factory/audit/<C>.md, was written by this
    run, and every high finding in it is accepted (.factory/publish/<C>.ack).

What has not happened yet - the full check or the audit still running - is a
wait: .factory/publish/<C>.wait, and the next call looks again. What failed is
a hold, said once, and nothing is handed on. The publisher still refuses
anything below autonomy level pr.

Lines: DELIVER <C> | DELIVER WAIT <C>: <why> | DELIVER HELD <C>: <why> |
DELIVER SKIPPED <C>: <why>. Exit 0 always - delivery never fails a run.
"""
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
P = os.path.join(F, "publish")
T = os.path.join(ROOT, "tasks")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def git(*args):
    r = subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True, text=True, errors="replace")
    return r.returncode, r.stdout.strip()


def run_started():
    try:
        return int(json.loads(read(os.path.join(F, "run-start.json")) or "{}").get("started") or 0)
    except (ValueError, TypeError):
        return 0


def kv(text):
    return dict(l.split("=", 1) for l in text.splitlines() if "=" in l)


def of_change(tid, cid):
    m = re.match(r"^(C[0-9]+)-", tid)
    return (m.group(1) if m else "C1") == cid


def change_tasks(cid):
    out = []
    for col in ("done", "in-progress", "backlog", "blocked"):
        try:
            out += [n[:-3] for n in os.listdir(os.path.join(T, col)) if n.endswith(".md") and of_change(n[:-3], cid)]
        except OSError:
            pass
    return sorted(set(out))


def failed_reviews(cid):
    bad = []
    for tid in change_tasks(cid):
        try:
            rec = json.loads(read(os.path.join(F, "reviews", tid + ".json")) or "{}")
        except ValueError:
            rec = {}
        if rec.get("verdict") == "fail":
            bad.append(tid)
            continue
        if rec.get("verdict") == "owed":
            continue
        verdicts = re.findall(r"^verdict:\s*(pass|fail)", read(os.path.join(T, "done", tid + ".md")), re.M)
        if verdicts and verdicts[-1] == "fail":
            bad.append(tid)
    return bad


def owed_reviews(cid):
    out = []
    for tid in change_tasks(cid):
        try:
            if json.loads(read(os.path.join(F, "reviews", tid + ".json")) or "{}").get("verdict") == "owed":
                out.append(tid)
        except ValueError:
            pass
    return out


def full_check_state(started):
    """None when green at HEAD for this run; else ("wait"|"held", why)."""
    path = os.path.join(F, "full-check")
    rec = kv(read(path))
    try:
        fresh = os.path.getmtime(path) >= started - 1
    except OSError:
        fresh = False
    if not rec or not fresh:
        return "wait", "the full check of this run has not finished"
    _, head = git("rev-parse", "HEAD")
    if rec.get("head") != head:
        return "held", "the full check ran on %s, and HEAD is %s now - run factory-check --full" % (
            (rec.get("head") or "?")[:12], head[:12])
    if rec.get("verdict") != "green":
        return "held", "the full check is red (%s)" % (rec.get("log") or ".factory/logs")
    if rec.get("clean") == "no":
        return "held", "product code was uncommitted when the full check ran"
    return None


def audit_state(cid, started, expected, skip):
    path = os.path.join(F, "audit", cid + ".md")
    if skip:
        return None
    try:
        fresh = os.path.getmtime(path) >= started - 1
    except OSError:
        fresh = False
    if not fresh:
        return ("wait", "the audit of this run has not finished") if expected else None
    highs = re.findall(r"^##\s*high\b[^\n]*", read(path), re.I | re.M)
    if highs and not os.path.exists(os.path.join(P, cid + ".ack")):
        return "held", "the audit found %d high finding(s) (.factory/audit/%s.md) - accept them with %s, or fix " \
                       "them" % (len(highs), cid, ".factory/publish/%s.ack" % cid)
    return None


def start_publisher(cid):
    try:
        subprocess.Popen([sys.executable, os.path.join(HOOK_DIR, "factory-publish.py"), cid], cwd=ROOT,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except OSError:
        pass


def deliver(cid, expected, skip, started):
    wait = os.path.join(P, cid + ".wait")
    if os.path.exists(os.path.join(P, cid + ".json")) or os.path.exists(os.path.join(P, cid + ".pending")):
        if os.path.exists(wait):
            os.remove(wait)
        return "DELIVER SKIPPED %s: already handed to the publisher" % cid
    if expected is None:
        expected = "audit=1" in read(wait)
    states = [full_check_state(started)]
    bad = failed_reviews(cid)
    if bad:
        states.append(("held", "a review failed: %s (.factory/reviews/)" % " ".join(bad)))
    owing = owed_reviews(cid)
    if owing:
        states.append(("wait", "the review of %s after it landed has not finished" % " ".join(owing)))
    states.append(audit_state(cid, started, expected, skip))
    held = [s for s in states if s and s[0] == "held"]
    waiting = [s for s in states if s and s[0] == "wait"]
    if held:
        if os.path.exists(wait):
            os.remove(wait)
        return "DELIVER HELD %s: %s" % (cid, "; ".join(w for _, w in held))
    if waiting:
        with open(wait, "w", encoding="utf-8") as fh:
            fh.write("at=%d\naudit=%d\n" % (int(time.time()), 1 if expected else 0))
        return "DELIVER WAIT %s: %s" % (cid, "; ".join(w for _, w in waiting))
    open(os.path.join(P, cid + ".pending"), "w").close()
    if os.path.exists(wait):
        os.remove(wait)
    start_publisher(cid)
    return "DELIVER %s: handed to the publisher" % cid


def main(argv):
    if "--if-ready" not in argv:
        print("usage: factory-deliver --if-ready [<C>...] [--audit] [--skip-audit]", file=sys.stderr)
        return 2
    if not os.path.isfile(os.path.join(F, "active")):
        return 0
    ids = [a for a in argv if re.match(r"^C[0-9]+$", a)]
    os.makedirs(P, exist_ok=True)
    lock = os.path.join(F, "locks", "deliver")
    os.makedirs(os.path.dirname(lock), exist_ok=True)
    for _ in range(300):
        try:
            os.mkdir(lock)
            break
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(lock) > 120:
                    os.rmdir(lock)
                    continue
            except OSError:
                pass
            time.sleep(0.2)
    try:
        if not ids:
            ids = sorted(n[:-5] for n in os.listdir(P) if n.endswith(".wait"))
        started = run_started()
        for cid in ids:
            # --audit says an audit is running; without it, a wait recorded
            # earlier remembers whether one was.
            print(deliver(cid, True if "--audit" in argv else None, "--skip-audit" in argv, started))
    finally:
        try:
            os.rmdir(lock)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
