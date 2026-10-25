#!/usr/bin/env python3
"""Factory: delivers one closed change - push, pull request, CI, merge, main CI.

NOT a hook and NOT an agent. A script the finish step starts (detached) and the
session brief resumes; it is the only thing in the factory that publishes, and
it does so only when `factory-autonomy` says the developer consented to it.

Usage (from the project root, or with FACTORY_ROOT):
    factory-publish.py <change-id>        deliver that change (resumes if begun)
    factory-publish.py --resume-all       continue every change that stopped
    factory-publish.py --status           one line per change that has a record
    factory-publish.py --ack-audit <id>   the developer has read the audit's high
                                          findings; let the merge go ahead

State lives in .factory/publish/<id>.json, one step at a time, and every step
can be run twice: a kill -9, a sleeping laptop or an expired `gh auth` leaves a
record that the next call carries on from. Nothing here checks out or pulls
while a run is active.

Levels (factory-autonomy): local - nothing happens; pr - the branch is pushed
and the pull request opened, then it stops; merge - the rest.

Risk classes decide what merging needs:
    C  migrations, workflows, release config, CODEOWNERS, CLAUDE.md, a major
       dependency bump          -> the pull request only, a person merges it
    B  a file matches risk_paths -> `risk_review: before` and no failed review
    A  everything else
A high-severity finding in the change's audit (.factory/audit/<id>.md) holds any
class until acknowledged.

Exit: 0 delivered or deliberately stopped; 1 held (the output says why);
      2 usage or not a factory project.
"""
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HOOK_DIR)
from factory_compat import argv, bash, pid_alive  # noqa: E402
ROOT = os.path.abspath(os.environ.get("FACTORY_ROOT") or os.getcwd())
F = os.path.join(ROOT, ".factory")
P = os.path.join(F, "publish")
GH = os.environ.get("FACTORY_GH", "gh")
POLL_S = float(os.environ.get("FACTORY_PUBLISH_POLL_S", "20"))
CI_WAIT_POLLS = int(os.environ.get("FACTORY_PUBLISH_CI_POLLS", "6"))
TERMINAL = ("done", "pr_only", "reverted", "abandoned")

CLASS_C = ["*/migrations/*", "*/migration/*", "*/.github/workflows/*", ".github/workflows/*", "*/codeowners",
           "*/.github/codeowners", "*/claude.md", "*/fastlane/*", "*/.releaserc*", "*/release.config.*",
           "*/.goreleaser*", "*/release-please-config.json", "*/.changeset/*"]
DEP_FILES = ("package.json", "pubspec.yaml", "go.mod", "cargo.toml", "composer.json", "gemfile",
             "requirements.txt", "pyproject.toml")


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def run(cmd, check_env=None, timeout=None, stdin=None):
    env = dict(os.environ)
    env["FACTORY_ROOT"] = ROOT
    if check_env:
        env.update(check_env)
    try:
        r = subprocess.run(argv(cmd), capture_output=True, text=True, cwd=ROOT, env=env, timeout=timeout, input=stdin)
        return r.returncode, r.stdout, r.stderr
    except FileNotFoundError as e:
        return 127, "", str(e)
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"


def git(*a):
    return run(["git"] + list(a))


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def write_json(path, obj):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=1)
    os.replace(tmp, path)


def event(kind, **kw):
    try:
        row = {"ts": now_iso(), "epoch": int(time.time()), "kind": kind}
        row.update(kw)
        with open(os.path.join(F, "events.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, separators=(",", ":")) + "\n")
    except OSError:
        pass


def notify(text, tag="delivery"):
    """Through factory-notify: the desktop, and ntfy when the project set one
    up. It mutes and detaches (--bg); only its test log (FACTORY_NOTIFY_LOG)
    gets past FACTORY_NO_NOTIFY."""
    if os.environ.get("FACTORY_NO_NOTIFY") == "1" and not os.environ.get("FACTORY_NOTIFY_LOG"):
        return
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "factory-notify.py")
    if not os.path.isfile(script):
        return
    try:
        subprocess.run([sys.executable, script, "Factory · %s" % os.path.basename(ROOT), text, "--tag", tag, "--bg"],
                       cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=20)
    except (OSError, subprocess.SubprocessError):
        pass


def config():
    return read_json(os.path.join(F, "config.json"), {}) or {}


def level():
    rc, out, _ = run([bash(), os.path.join(HOOK_DIR, "factory-autonomy.sh")], timeout=30)
    word = (out.split() or ["local"])[0]
    return word if word in ("local", "pr", "merge") else "local"


def is_auth_error(text):
    t = text.lower()
    return any(s in t for s in ("gh auth login", "authentication", "http 401", "bad credentials",
                                "not logged in", "token", "gh_token", "requires authentication"))


# --- state -------------------------------------------------------------------
def sfile(cid):
    return os.path.join(P, cid + ".json")


def load(cid):
    return read_json(sfile(cid))


def save(st):
    st["updated"] = now_iso()
    write_json(sfile(st["change"]), st)


def say(st, text):
    st.setdefault("log", []).append("%s %s" % (now_iso(), text))
    st["log"] = st["log"][-40:]
    save(st)
    print(text)
    event("publish", change=st["change"], state=st.get("state"), note=text[:200])


def hold(st, reason):
    st["held"] = reason
    say(st, "PUBLISH HELD %s at %s: %s" % (st["change"], st["state"], reason))
    return 1


def take_lock(cid):
    os.makedirs(P, exist_ok=True)
    lock = os.path.join(P, cid + ".lock")
    try:
        other = int(open(lock).read().strip() or 0)
    except (OSError, ValueError):
        other = 0
    if other and other != os.getpid() and pid_alive(other):
        return None
    with open(lock, "w") as fh:
        fh.write(str(os.getpid()))
    return lock


def drop_lock(lock):
    try:
        os.unlink(lock)
    except OSError:
        pass


# --- looking at the change ---------------------------------------------------
def change_dir(cid):
    base = os.path.join(F, "changes")
    try:
        for n in sorted(os.listdir(base)):
            if n.startswith(cid + "-") and os.path.isdir(os.path.join(base, n)):
                return os.path.join(base, n), n[len(cid) + 1:]
    except OSError:
        pass
    return None, None


def run_active():
    """A run holds .factory/run.lock from its preflight to its finish, and its
    checks keep the file's time fresh. A lock untouched for two hours is a run
    that died: the next preflight takes over its base, and nothing waits on it."""
    lock = os.path.join(F, "run.lock")
    try:
        if time.time() - os.path.getmtime(lock) >= 2 * 3600:
            return False
        rec = json.load(open(lock, encoding="utf-8"))
    except (OSError, ValueError):
        return os.path.exists(lock)
    return not (isinstance(rec, dict) and rec.get("state") == "halted")


def tree_clean():
    rc, out, _ = git("status", "--porcelain")
    if rc != 0:
        return False
    keep = re.compile(r"^(tasks/|decisions\.md|\.factory/|gates/|specs/|\.claude/)")
    return not [l[3:] for l in out.splitlines() if not keep.match(l[3:].strip('"'))]


def glob_hit(path, pats):
    low = "/" + path.lower()
    for p in pats:
        p = p.lower()
        if not (p.startswith("/") or p.startswith("*")):
            p = "*/" + p
        if fnmatch.fnmatchcase(low, p):
            return p
    return None


def major_bumps(base, sha, files):
    out = []
    for f in files:
        if os.path.basename(f).lower() not in DEP_FILES:
            continue
        rc, diff, _ = git("diff", "--unified=0", "origin/%s...%s" % (base, sha), "--", f)
        old, new = {}, {}
        for line in diff.splitlines():
            m = re.match(r'^([-+])\s*[-"\']?\s*([A-Za-z0-9_@/.\-]+)["\']?\s*[:=]?\s*["\']?[\^~>=<\s]*v?(\d+)\.', line)
            if m and not line.startswith(("---", "+++")):
                (old if m.group(1) == "-" else new)[m.group(2)] = int(m.group(3))
        out += ["%s %s: %d -> %d" % (f, k, old[k], v) for k, v in new.items() if k in old and v > old[k]]
    return out


def audit_highs(cid):
    """The high findings of this change's own audit. Never another change's, and
    never a file an earlier run left: .factory/audit/<C>.md is the change's."""
    if os.path.exists(os.path.join(P, cid + ".ack")):
        return []
    try:
        text = open(os.path.join(F, "audit", cid + ".md"), encoding="utf-8").read()
    except OSError:
        return []
    return re.findall(r"^##\s*high\b[^\n]*", text, re.I | re.M)


def failed_reviews(cid):
    """Tasks of this change whose last recorded review says fail."""
    out = []
    d = os.path.join(ROOT, "tasks", "done")
    try:
        names = os.listdir(d)
    except OSError:
        return out
    for n in names:
        tid = n[:-3] if n.endswith(".md") else None
        if not tid or (re.match(r"^C[0-9]+-", tid) and not tid.startswith(cid + "-")):
            continue
        if not re.match(r"^C[0-9]+-", tid) and cid != "C1":
            continue
        try:
            rec = json.load(open(os.path.join(F, "reviews", tid + ".json"), encoding="utf-8"))
        except (OSError, ValueError):
            rec = {}
        if isinstance(rec, dict) and rec.get("verdict") == "fail":
            out.append(tid)
            continue
        try:
            verdicts = re.findall(r"^verdict:\s*(pass|fail)", open(os.path.join(d, n), encoding="utf-8").read(), re.M)
        except OSError:
            continue
        if verdicts and verdicts[-1] == "fail":
            out.append(tid)
    return out


def classify(st, files):
    cfg = config()
    reasons = []
    c = [f for f in files if glob_hit(f, CLASS_C)]
    if c:
        reasons.append("class C paths: " + ", ".join(c[:6]))
    bumps = major_bumps(st["base"], st["sha"], files)
    if bumps:
        c = c or bumps
        reasons.append("major dependency bump: " + "; ".join(bumps[:4]))
    if c:
        return "C", reasons
    pats = cfg.get("risk_paths") or []
    b = [f for f in files if glob_hit(f, pats)]
    if b:
        return "B", ["risk_paths match: " + ", ".join(b[:6])]
    return "A", []


def merge_gate(st):
    """Returns a reason the merge must wait, or None."""
    highs = audit_highs(st["change"])
    if highs:
        return "the auditor's high-severity finding(s) are unacknowledged: %s (factory-publish --ack-audit %s)" % (
            "; ".join(h.strip("# ").strip() for h in highs[:3]), st["change"])
    if st.get("class") == "B":
        if (config().get("fast") or {}).get("risk_review") != "before":
            return "class B (risk_paths) needs fast.risk_review = before; it is not set"
        bad = failed_reviews(st["change"])
        if bad:
            return "class B and a review failed on %s" % ", ".join(bad)
    return None


# --- the steps ---------------------------------------------------------------
def pr_body(st, d):
    parts = []
    for name, cap in (("summary.md", 9000), ("goal.md", 3000)):
        try:
            parts.append(open(os.path.join(d, name), encoding="utf-8").read()[:cap])
        except OSError:
            pass
    try:
        audit = open(os.path.join(F, "audit", st["change"] + ".md"), encoding="utf-8").read()[:4000]
        parts.append("## Audit\n\n" + audit)
    except OSError:
        pass
    parts.append("---\nClass %s%s. Opened by the factory publisher (change %s)." % (
        st.get("class", "?"), (": " + "; ".join(st.get("reasons", []))) if st.get("reasons") else "", st["change"]))
    return "\n\n".join(parts)


def step_new(st):
    cfg = config()
    deliv = cfg.get("delivery") or {}
    st["base"] = deliv.get("base") or "main"
    d, slug = change_dir(st["change"])
    if not d:
        return hold(st, "no change %s under .factory/changes" % st["change"])
    st["slug"] = slug
    st["branch"] = "factory/%s-%s" % (st["change"], slug)
    cur = git("symbolic-ref", "--short", "-q", "HEAD")[1].strip()
    if deliv.get("branch") == "per-change" and git("rev-parse", "--verify", "-q", "refs/heads/" + st["branch"])[0] == 0:
        src = "refs/heads/" + st["branch"]
    elif cur == st["branch"]:
        src = "HEAD"
    else:
        src = "HEAD"
    rc, sha, err = git("rev-parse", "--verify", src)
    if rc != 0:
        return hold(st, "cannot resolve %s: %s" % (src, err.strip()))
    st["sha"] = sha.strip()
    rc, _, err = git("fetch", "-q", "origin", st["base"])
    if rc != 0:
        return hold(st, "could not fetch origin/%s (%s)" % (st["base"], (err or "").strip()[:120]))
    rc, files, _ = git("diff", "--name-only", "origin/%s...%s" % (st["base"], st["sha"]))
    files = [f for f in files.splitlines() if f]
    st["files"] = files[:200]
    if not files:
        st["state"] = "done"
        st["held"] = None
        say(st, "PUBLISH DONE %s: nothing to publish, origin/%s already has it" % (st["change"], st["base"]))
        return 0
    rc, tr, _ = git("log", "--format=%(trailers:key=Factory-Task,valueonly,separator=%x2C)",
                    "origin/%s..%s" % (st["base"], st["sha"]))
    st["tasks"] = sorted({t.strip() for l in tr.splitlines() for t in l.split(",") if t.strip()})
    st["class"], st["reasons"] = classify(st, files)
    st["state"] = "classified"
    st["held"] = None
    say(st, "PUBLISH %s class %s (%d file(s))%s" % (st["change"], st["class"], len(files),
                                                      ": " + "; ".join(st["reasons"]) if st["reasons"] else ""))
    return None


def step_push(st):
    rc, _, err = git("push", "origin", "%s:refs/heads/%s" % (st["sha"], st["branch"]))
    if rc != 0:
        if is_auth_error(err):
            return hold(st, "push refused, git/gh is not authenticated: " + err.strip()[-160:])
        return hold(st, "push failed: " + err.strip()[-200:])
    st["state"] = "pushed"
    st["held"] = None
    say(st, "PUBLISH %s pushed %s (%s)" % (st["change"], st["branch"], st["sha"][:9]))
    return None


def step_pr(st):
    d, _ = change_dir(st["change"])
    body = os.path.join(P, st["change"] + ".body.md")
    with open(body, "w", encoding="utf-8") as fh:
        fh.write(pr_body(st, d))
    title = "%s: %s" % (st["change"], st["slug"].replace("-", " "))
    rc, out, err = run([GH, "pr", "create", "--base", st["base"], "--head", st["branch"], "--title", title,
                        "--body-file", body])
    text = out + "\n" + err
    if rc != 0 and "already exists" not in text:
        if is_auth_error(text):
            return hold(st, "gh is not authenticated (gh auth login): " + text.strip()[-160:])
        return hold(st, "gh pr create failed: " + text.strip()[-200:])
    m = re.search(r"/pull/(\d+)", text)
    if not m:
        rc, out, err = run([GH, "pr", "view", st["branch"], "--json", "number", "-q", ".number"])
        m = re.search(r"(\d+)", out)
    if not m:
        return hold(st, "could not read the pull request number from gh")
    st["pr"] = int(m.group(1))
    st["state"] = "pr_open"
    st["held"] = None
    say(st, "PUBLISH %s pull request #%d opened" % (st["change"], st["pr"]))
    return None


def step_checks(st):
    rc, out, err = run([GH, "pr", "checks", str(st["pr"]), "--watch", "--fail-fast"])
    text = out + "\n" + err
    if rc == 0 or "no checks reported" in text.lower():
        st["state"] = "checks_green"
        st["held"] = None
        st["ci_note"] = "no checks configured" if rc != 0 else "green"
        say(st, "PUBLISH %s checks %s" % (st["change"], st["ci_note"]))
        return None
    if is_auth_error(text):
        return hold(st, "gh is not authenticated while watching checks: " + text.strip()[-160:])
    if rc in (127, 124):
        return hold(st, "gh did not run (%s)" % text.strip()[-120:])
    notify("%s: PR #%s checks are red" % (st["change"], st["pr"]))
    return hold(st, "pull request checks failed or did not finish (gh exit %d): %s" % (rc, text.strip()[-200:]))


def step_merge(st):
    why = merge_gate(st)
    if why:
        return hold(st, why)
    rc, out, err = run([GH, "pr", "view", str(st["pr"]), "--json", "state,headRefOid,mergeCommit"])
    try:
        view = json.loads(out)
    except ValueError:
        view = None
    if view is None:
        if is_auth_error(out + err):
            return hold(st, "gh is not authenticated: " + (out + err).strip()[-160:])
        return hold(st, "could not read pull request #%s: %s" % (st["pr"], (out + err).strip()[-160:]))
    if view.get("state") == "MERGED":
        st["merge_sha"] = (view.get("mergeCommit") or {}).get("oid")
        st["state"] = "merged"
        st["held"] = None
        say(st, "PUBLISH %s #%s was already merged" % (st["change"], st["pr"]))
        return None
    if view.get("state") == "CLOSED":
        st["state"] = "abandoned"
        return hold(st, "pull request #%s was closed without merging" % st["pr"])
    if view.get("headRefOid") != st["sha"]:
        return hold(st, "the pull request head moved (%s, expected %s); not merging a commit that was not tested" % (
            str(view.get("headRefOid"))[:9], st["sha"][:9]))
    deliv = config().get("delivery") or {}
    method = "--squash" if deliv.get("merge_method") == "squash" else "--rebase"
    trailers = "\n".join(["Factory-Change: " + st["change"]] + ["Factory-Task: " + t for t in st.get("tasks", [])])
    for attempt in (method, "--squash" if method == "--rebase" else None):
        if attempt is None:
            break
        args = [GH, "pr", "merge", str(st["pr"]), attempt, "--match-head-commit", st["sha"]]
        if attempt == "--squash":
            args += ["--body", trailers]
        rc, out, err = run(args)
        text = out + "\n" + err
        if rc == 0:
            st["method"] = attempt.lstrip("-")
            break
        if "not allowed" in text.lower() and attempt == "--rebase":
            continue
        if is_auth_error(text):
            return hold(st, "gh is not authenticated at merge: " + text.strip()[-160:])
        return hold(st, "merge refused: " + text.strip()[-220:])
    else:
        return hold(st, "merge refused by the repository settings")
    rc, out, _ = run([GH, "pr", "view", str(st["pr"]), "--json", "mergeCommit", "-q", ".mergeCommit.oid"])
    st["merge_sha"] = out.strip() or None
    st["state"] = "merged"
    st["held"] = None
    say(st, "PUBLISH %s #%s merged (%s)" % (st["change"], st["pr"], st.get("method")))
    return None


def sync_local(st):
    """Bring the local base up to the merged work, only when nothing is in the
    way: no run active, a clean tree. Never fatal; the next call retries."""
    git("fetch", "-q", "origin", st["base"])
    if run_active():
        st["sync_pending"] = "a run is active; the local branch is left alone"
        return
    if not tree_clean():
        st["sync_pending"] = "the working tree has changes; the local branch is left alone"
        return
    cur = git("symbolic-ref", "--short", "-q", "HEAD")[1].strip()
    if cur == st["branch"]:
        if git("switch", "-q", st["base"])[0] != 0:
            st["sync_pending"] = "could not switch to %s" % st["base"]
            return
        cur = st["base"]
    if cur == st["base"]:
        rc, _, err = git("merge", "--ff-only", "-q", "origin/" + st["base"])
        if rc != 0:
            rc, _, err = git("rebase", "-q", "origin/" + st["base"])
            if rc != 0:
                git("rebase", "--abort")
                st["sync_pending"] = "local %s could not be brought to origin/%s: %s" % (st["base"], st["base"], err.strip()[-100:])
                return
    git("branch", "-D", st["branch"])
    git("push", "-q", "origin", "--delete", st["branch"])
    st.pop("sync_pending", None)
    run([bash(), os.path.join(HOOK_DIR, "factory-change.sh"), "sync", st["change"]])


def step_after_merge(st):
    sync_local(st)
    st["state"] = "main_ci"
    st["held"] = None
    say(st, "PUBLISH %s merged work fetched%s" % (st["change"], (" (" + st["sync_pending"] + ")") if st.get("sync_pending") else ""))
    return None


def record_breaker(kind, st):
    row = {"ts": now_iso(), "epoch": int(time.time()), "kind": kind, "change": st["change"]}
    try:
        with open(os.path.join(P, "breaker.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")
    except OSError:
        pass
    rows = []
    try:
        rows = [json.loads(l) for l in open(os.path.join(P, "breaker.jsonl"), encoding="utf-8") if l.strip()]
    except (OSError, ValueError):
        pass
    week = time.time() - 7 * 86400
    reverts = [r for r in rows if r.get("kind") == "revert" and r.get("epoch", 0) >= week]
    tail = [r["kind"] for r in rows if r.get("kind") in ("main_red", "main_green")][-2:]
    why = None
    if len(reverts) >= 2:
        why = "2 automatic reverts in 7 days"
    elif tail == ["main_red", "main_red"]:
        why = "main CI was red twice in a row"
    if why and not os.path.exists(os.path.join(F, "autonomy-cap")):
        with open(os.path.join(F, "autonomy-cap"), "w", encoding="utf-8") as fh:
            fh.write("pr\nbreaker: %s (%s)\n" % (why, now_iso()))
        event("breaker", reason=why)
        notify("Factory breaker: %s. Level is pr until you say 'auto devam et'." % why, "stop")
        return why
    return None


def fix_task(st, run_url):
    tid = "FIX-%s-main-red" % st["change"]
    n, path = 1, None
    while True:
        path = os.path.join(ROOT, "tasks", "proposed", "%s%s.md" % (tid, "" if n == 1 else "-%d" % n))
        if not os.path.exists(path):
            break
        n += 1
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tid = os.path.basename(path)[:-3]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("---\nid: %s\ntitle: Main CI went red after %s was merged\nmodule: core\ndepends_on: []\nacceptance: true\n"
                 "needs_human: true\nreview: always\nretries: 0\nowner:\nstage: proposed\nstage_since:\n---\n\n"
                 "## Goal\nCI on %s failed after pull request #%s (change %s) merged%s. The factory reverted it; find what the "
                 "pull request's CI did not show, fix it, and redeliver.\n\n## Files touched\n\n## Attempts\n" % (
                     tid, st["change"], st["base"], st.get("pr"), st["change"], (": " + run_url) if run_url else ""))
    return tid


def revert(st):
    rc, out, err = run([GH, "pr", "view", str(st["pr"]), "--json", "id", "-q", ".id"])
    node = out.strip()
    url = None
    if rc == 0 and node:
        q = "mutation($id:ID!){revertPullRequest(input:{pullRequestId:$id}){revertPullRequest{number url}}}"
        rc, out, err = run([GH, "api", "graphql", "-f", "query=" + q, "-f", "id=" + node])
        m = re.search(r'"url"\s*:\s*"([^"]+)"', out)
        url = m.group(1) if m else None
    return url, (out + err)


def step_main_ci(st):
    sha = st.get("merge_sha")
    if not sha:
        rc, out, _ = git("rev-parse", "origin/" + st["base"])
        sha = out.strip()
    runs = []
    for i in range(max(1, CI_WAIT_POLLS)):
        rc, out, err = run([GH, "run", "list", "--branch", st["base"], "--commit", sha, "--json",
                            "databaseId,status,conclusion,url", "--limit", "10"])
        try:
            runs = json.loads(out) if rc == 0 else []
        except ValueError:
            runs = []
        if rc != 0 and is_auth_error(out + err):
            return hold(st, "gh is not authenticated while looking for main's CI: " + (out + err).strip()[-120:])
        if runs:
            break
        time.sleep(POLL_S)
    if not runs:
        st["state"] = "done"
        st["held"] = None
        say(st, "PUBLISH DONE %s: merged; no CI run on %s for %s" % (st["change"], st["base"], sha[:9]))
        record_breaker("main_green", st)
        return 0
    red_url = None
    for r in runs:
        if r.get("status") == "completed" and r.get("conclusion") == "success":
            continue
        rc, out, err = run([GH, "run", "watch", str(r["databaseId"]), "--exit-status"])
        if rc != 0:
            if is_auth_error(out + err):
                return hold(st, "gh is not authenticated while watching main's CI")
            red_url = r.get("url") or str(r["databaseId"])
            break
    if not red_url:
        st["state"] = "done"
        st["held"] = None
        say(st, "PUBLISH DONE %s: merged and main CI is green" % st["change"])
        record_breaker("main_green", st)
        return 0
    url, detail = revert(st)
    tid = fix_task(st, red_url)
    st["state"] = "reverted"
    st["held"] = None
    st["revert"] = url
    why = record_breaker("main_red", st) or record_breaker("revert", st)
    notify("%s: main CI went red; %s" % (st["change"], "revert PR opened" if url else "revert failed, look now"))
    say(st, "PUBLISH REVERTED %s: main CI red (%s); revert %s; fix task %s%s" % (
        st["change"], red_url, url or "NOT opened (" + detail.strip()[-80:] + ")", tid,
        "; BREAKER: " + why if why else ""))
    return 1


# --- driver ------------------------------------------------------------------
def deliver(cid):
    if not os.path.isfile(os.path.join(F, "active")):
        print("factory-publish: no .factory/active here")
        return 2
    d, slug = change_dir(cid)
    if not d:
        print("factory-publish: no change %s" % cid)
        return 2
    if not os.path.exists(os.path.join(d, "closed")):
        print("PUBLISH SKIPPED %s: the change is not closed yet" % cid)
        return 0
    lvl = level()
    st = load(cid)
    if st and st.get("state") in TERMINAL:
        print("PUBLISH %s: already %s" % (cid, st["state"]))
        return 0
    if lvl == "local":
        print("PUBLISH SKIPPED %s: autonomy level is local (say 'auto devam et' to allow pull requests)" % cid)
        return 0
    lock = take_lock(cid)
    if lock is None:
        print("PUBLISH %s: another publisher is running it" % cid)
        return 0
    try:
        if not st:
            st = {"change": cid, "state": "new", "held": None, "started": now_iso()}
            st["tasks"] = []
        st["pid"] = os.getpid()
        st["held"] = None
        save(st)
        try:
            os.unlink(os.path.join(P, cid + ".pending"))
        except OSError:
            pass
        for _ in range(12):
            s = st["state"]
            if s == "new":
                r = step_new(st)
            elif s == "classified":
                r = step_push(st)
            elif s == "pushed":
                r = step_pr(st)
            elif s == "pr_open":
                if st.get("class") == "C" or lvl != "merge":
                    st["state"] = "pr_only"
                    note = "class C: a person merges it" if st.get("class") == "C" else "autonomy level is %s" % lvl
                    say(st, "PUBLISH STOPPED %s at pull request #%s (%s)" % (cid, st["pr"], note))
                    if st.get("class") == "C":
                        notify("%s: class C pull request #%s waits for you" % (cid, st["pr"]))
                    r = 0
                else:
                    r = step_checks(st)
            elif s == "checks_green":
                if lvl != "merge":
                    st["state"] = "pr_only"
                    say(st, "PUBLISH STOPPED %s at pull request #%s (autonomy level is %s)" % (cid, st["pr"], lvl))
                    r = 0
                else:
                    r = step_merge(st)
            elif s == "merged":
                r = step_after_merge(st)
            elif s == "main_ci":
                r = step_main_ci(st)
            else:
                r = 0
            if r is not None:
                break
        st["pid"] = None
        save(st)
        try:
            subprocess.run([sys.executable, os.path.join(HOOK_DIR, "factory-digest.py")], cwd=ROOT, capture_output=True,
                           env=dict(os.environ, FACTORY_ROOT=ROOT), timeout=60)
        except (OSError, subprocess.SubprocessError):
            pass
        return r if r is not None else 0
    finally:
        drop_lock(lock)


def main(argv):
    if os.environ.get("FACTORY_PUBLISH_CAFFEINATED") != "1" and shutil.which("caffeinate") \
            and os.environ.get("FACTORY_NO_CAFFEINATE") != "1" and argv and argv[0] not in ("--status",):
        os.environ["FACTORY_PUBLISH_CAFFEINATED"] = "1"
        os.execvp("caffeinate", ["caffeinate", "-i", sys.executable, os.path.abspath(__file__)] + argv)
    if not argv:
        print(__doc__)
        return 2
    if argv[0] == "--status":
        for n in sorted(os.listdir(P)) if os.path.isdir(P) else []:
            if n.endswith(".json"):
                st = read_json(os.path.join(P, n), {})
                print("%s %s%s%s" % (st.get("change"), st.get("state"), " #%s" % st["pr"] if st.get("pr") else "",
                                     " HELD: " + st["held"] if st.get("held") else ""))
        return 0
    if argv[0] == "--ack-audit" and len(argv) > 1:
        os.makedirs(P, exist_ok=True)
        open(os.path.join(P, argv[1] + ".ack"), "w").write(now_iso())
        print("ACKED %s: the audit's high findings no longer hold the merge" % argv[1])
        return 0
    if argv[0] == "--resume-all":
        rc = 0
        todo = []
        for n in sorted(os.listdir(P)) if os.path.isdir(P) else []:
            if n.endswith(".json"):
                st = read_json(os.path.join(P, n), {})
                if st.get("state") not in TERMINAL and st.get("change"):
                    todo.append(st["change"])
            elif n.endswith(".pending"):
                todo.append(n[:-len(".pending")])
        for cid in sorted(set(todo)):
            rc = max(rc, deliver(cid))
        return rc
    if re.match(r"^C[0-9]+$", argv[0]):
        return deliver(argv[0])
    print("usage: factory-publish.py <change-id> | --resume-all | --status | --ack-audit <id>")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
