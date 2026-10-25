#!/usr/bin/env python3
"""Factory: settle a task once its builder is done with it. NOT a hook: the
builder runs it as its last command, and the loop's recheck runs it after a
wait.

Usage (from the project root):
  factory-settle <id> ["<why>"]                after the builder's last check
  factory-settle <id> --no-wait ["<why>"]      the same, when nothing else is
                                               building: a wait is an attempt
  factory-settle <id> --conflict "<question>"  the task cannot be built as written
  factory-settle <id> --refused ["<why>"]      factory-start refused the task

What happens next is decided here, from disk - never from what the builder
says about its own work:

  - Green (a marker whose files are unchanged since the check):
      `review: always` (as approved, in HEAD), or a risk match while
      fast.risk_review is "before": REVIEW - nothing lands until a reviewer
      passes it (factory-review-submit lands it then).
      Otherwise factory-land commits it. A risk match while risk_review is
      "after" lands and says REVIEW-AFTER: a reviewer reads the commit, and
      until its verdict is in (.factory/reviews/<id>.json says "owed") the
      change is not delivered.
  - The check is waiting on another task's work: WAITING, naming the tasks.
    Nothing is counted against this task - unless --no-wait says nothing else
    is building, so the work it waits on will not land in this run.
  - .factory/STOP: HALTED. Nothing is counted either.
  - Anything else is one attempt, recorded in .factory/attempts/<id>. At
    retry_limit attempts - all of them, the first included - or at a second
    NO PROGRESS, the task is blocked (its work parked) and nobody retries it.
  - --conflict blocks the task and asks the developer the question.
  - --refused lands a task that an earlier attempt already moved to done, and
    otherwise leaves the board as it is.

The last line is the verdict:
  SETTLED <id> LANDED <sha> [REVIEW-AFTER] | REVIEW | WAITING on <ids> |
  RETRY <n>/<limit>: <why> | BLOCKED: <why> | UNCOMMITTED: <line> |
  HALTED: <why> | REFUSED: <why>
SETTLE REFUSED <id>: ... (exit 1) means the builder has something to do first.
"""
import datetime
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


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def config():
    try:
        return json.loads(read(os.path.join(F, "config.json")) or "{}")
    except ValueError:
        return {}


def sh(script, *args):
    r = subprocess.run([bash(), os.path.join(HOOK_DIR, script)] + list(args), capture_output=True, text=True,
                       cwd=ROOT, errors="replace", env=dict(os.environ, FACTORY_ROOT=ROOT))
    return r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()


def py(script, *args):
    r = subprocess.run([sys.executable, os.path.join(HOOK_DIR, script)] + list(args), capture_output=True,
                       text=True, cwd=ROOT, errors="replace")
    return r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()


def last(out):
    lines = [l for l in out.splitlines() if l.strip()]
    return lines[-1] if lines else ""


def lane_of(tid):
    for col in ("in-progress", "backlog", "done", "blocked", "proposed"):
        if os.path.isfile(os.path.join(T, col, tid + ".md")):
            return col
    return None


def load_plan():
    spec = importlib.util.spec_from_file_location("factory_plan", os.path.join(HOOK_DIR, "factory-plan.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def review_always(tid, col):
    """As approved: HEAD's copy of the task file decides, so an agent cannot
    talk its way out of a review by editing the working copy. Where HEAD has
    no copy, the working tree's."""
    head = load_plan().committed_task(tid)
    fm = head[1] if head else load_plan().frontmatter(os.path.join(T, col, tid + ".md"))
    return (fm.get("review") or "").strip().lower() == "always"


def heartbeat():
    lock = os.path.join(F, "run.lock")
    if os.path.exists(lock):
        try:
            os.utime(lock, None)
        except OSError:
            pass


def last_no_progress(tid):
    """Was the last check of this task a NO PROGRESS? The marker carries the
    attempt it was written at; the failure history, how many checks failed."""
    np = read(os.path.join(F, "no-progress", tid))
    m = re.search(r"^attempt=(\d+)", np, re.M)
    if not m:
        return False
    hist = [l for l in read(os.path.join(F, "failures", tid + ".log")).splitlines() if l.strip()]
    return int(m.group(1)) == len(hist)


def attempts(tid):
    return [l for l in read(os.path.join(F, "attempts", tid)).splitlines() if l.strip()]


def record_attempt(tid, status, why):
    d = os.path.join(F, "attempts")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, tid), "a", encoding="utf-8") as fh:
        fh.write("%s %s %s\n" % (now_iso(), status, " ".join((why or "-").split())[:300]))


def blocked_reason(tid):
    text = read(os.path.join(T, "blocked", tid + ".md"))
    m = re.search(r"^##\s+Blocked reason\s*$(.*?)(?=^##\s|\Z)", text, re.M | re.S)
    lines = [l.strip() for l in (m.group(1) if m else "").splitlines() if l.strip()]
    return lines[-1].lstrip("-* ").strip() if lines else "it is in tasks/blocked"


def owe_review(tid):
    d = os.path.join(F, "reviews")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, tid + ".json")
    if not os.path.exists(path):
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"task": tid, "verdict": "owed", "mode": "after", "at": now_iso(), "rounds": []}, fh)


def land(tid, risk_lines):
    rc, out = sh("factory-land.sh", tid)
    for line in out.splitlines()[:-1]:
        if line.startswith(("COMMIT", "LAND")):
            print(line)
    line = last(out)
    m = re.match(r"^LANDED \S+ (\S+)", line)
    if m:
        for r in risk_lines:
            print(r)
        if risk_lines:
            owe_review(tid)
        print("SETTLED %s LANDED %s%s" % (tid, m.group(1), " REVIEW-AFTER" if risk_lines else ""))
        return 0
    if line.startswith("LAND SKIPPED"):
        print("SETTLED %s LANDED (already in tasks/done)" % tid)
        return 0
    if line.startswith("LAND UNCOMMITTED"):
        print("SETTLED %s UNCOMMITTED: %s" % (tid, line))
        return 0
    print("SETTLE REFUSED %s: %s" % (tid, line or "factory-land printed nothing"))
    return 1


def settle(tid, why, no_wait=False):
    col = lane_of(tid)
    if col == "done":
        return land(tid, [])
    if col == "blocked":
        print("SETTLED %s BLOCKED: %s" % (tid, blocked_reason(tid)))
        return 0
    if col not in ("in-progress", "backlog"):
        print("SETTLE REFUSED %s: no task file in tasks/in-progress or tasks/backlog." % tid)
        return 1
    if os.path.exists(os.path.join(F, "STOP")):
        first = (read(os.path.join(F, "STOP")).strip().splitlines() or ["set"])[0]
        print("SETTLED %s HALTED: .factory/STOP is set (%s)" % (tid, first))
        return 0

    marker = os.path.join(F, "verified", tid)
    if os.path.isfile(marker):
        want = re.search(r"^files=(\S+)", read(marker), re.M)
        if want:
            rc, now = py("factory-check.py", "fingerprint", tid)
            if rc != 0 or now.strip() != want.group(1):
                print("SETTLE REFUSED %s: its files changed after the green check (or its list did). Run "
                      "factory-check %s again, then factory-settle %s." % (tid, tid, tid))
                return 1
        rc, out = sh("factory-risk.sh", tid)
        risk_lines = [l for l in out.splitlines() if l.startswith("RISK")] if rc == 1 else []
        mode = ((config().get("fast") or {}).get("risk_review") or "after").lower()
        always = review_always(tid, col)
        if always or (risk_lines and mode == "before"):
            for r in risk_lines:
                print(r)
            if always:
                print("REVIEW %s: the task is marked review: always" % tid)
            print("SETTLED %s REVIEW" % tid)
            return 0
        return land(tid, risk_lines)

    waiting = read(os.path.join(F, "waiting", tid))
    if waiting and no_wait:
        os.remove(os.path.join(F, "waiting", tid))
        why = (why + " - " if why else "") + "it waited on work that will not land in this run (%s)" % " ".join(
            (re.search(r"^files=(.*)$", waiting, re.M) or re.search(r"(.*)", "")).group(1).split()[:5])
    elif waiting:
        tasks = re.search(r"^tasks=(.*)$", waiting, re.M)
        files = re.search(r"^files=(.*)$", waiting, re.M)
        on = (tasks.group(1).strip() if tasks else "") or (files.group(1).strip() if files else "") or "work in flight"
        print("SETTLED %s WAITING on %s" % (tid, ",".join(on.split())))
        return 0

    status = "no_progress" if last_no_progress(tid) else "red"
    record_attempt(tid, status, why)
    done = attempts(tid)
    limit = max(1, int(config().get("retry_limit") or 2))
    stalls = sum(1 for l in done if l.split()[1:2] == ["no_progress"])
    reason = (why or "the check did not go green").strip()
    if len(done) >= limit or stalls >= 2:
        what = "a second NO PROGRESS" if stalls >= 2 else "%d attempt(s), the limit" % len(done)
        msg = "%s after %s: %s" % (status, what, reason)
        rc, out = sh("factory-block.sh", tid, msg[:400])
        if rc != 0:
            print("SETTLE REFUSED %s: factory-block failed: %s" % (tid, last(out)))
            return 1
        print("SETTLED %s BLOCKED: %s" % (tid, msg))
        return 0
    print("SETTLED %s RETRY %d/%d: %s - %s" % (tid, len(done), limit, status, reason))
    return 0


def conflict(tid, question):
    question = " ".join((question or "the task contradicts itself").split())[:600]
    if lane_of(tid) not in ("in-progress", "backlog"):
        print("SETTLE REFUSED %s: only a task in tasks/in-progress or tasks/backlog can be blocked." % tid)
        return 1
    rc, out = sh("factory-block.sh", tid, "spec conflict: " + question[:300])
    if rc != 0:
        print("SETTLE REFUSED %s: factory-block failed: %s" % (tid, last(out)))
        return 1
    rc, out = sh("factory-ask.sh", "ask", tid, question)
    asked = re.search(r"^ASKED (Q\d+)", out, re.M)
    print("SETTLED %s BLOCKED: spec conflict, asked %s: %s" % (tid, asked.group(1) if asked else "(not asked)", question))
    return 0


def main(argv):
    if not argv or argv[0].startswith("-"):
        print("usage: factory-settle <id> [\"<why>\"] | <id> --conflict \"<question>\" | <id> --refused [\"<why>\"]",
              file=sys.stderr)
        return 2
    tid, rest = argv[0], argv[1:]
    if not os.path.isfile(os.path.join(F, "active")):
        print("SETTLE REFUSED %s: %s has no .factory/active." % (tid, ROOT))
        return 1
    # fast.isolation "worktree": a task with a checkout of its own, or a settle
    # run from inside one, goes through factory-worktree. It brings the work
    # into this tree and comes back here, with the handoff set, for the verdict.
    if not os.environ.get("FACTORY_WORKTREE_HANDOFF") and (
            os.path.isfile(os.path.join(F, "worktree")) or
            os.path.isdir(os.path.join(ROOT, ".factory-worktrees", "task-" + tid))):
        return subprocess.call([sys.executable, os.path.join(HOOK_DIR, "factory-worktree.py"), "settle", tid] + rest)
    heartbeat()
    if rest and rest[0] == "--conflict":
        return conflict(tid, " ".join(rest[1:]))
    if rest and rest[0] == "--refused":
        if lane_of(tid) == "done":
            return land(tid, [])
        why = " ".join(rest[1:]).strip() or "factory-start refused it"
        print("SETTLED %s REFUSED: %s" % (tid, " ".join(why.split())[:300]))
        return 0
    no_wait = bool(rest) and rest[0] == "--no-wait"
    return settle(tid, " ".join(rest[1:] if no_wait else rest), no_wait)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
