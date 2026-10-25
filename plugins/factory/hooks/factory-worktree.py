#!/usr/bin/env python3
"""Factory: a checkout of its own for each builder - fast.isolation "worktree"
in .factory/config.json, off unless set. NOT a hook: factory-start and
factory-settle run it.

Without it, every builder of a run edits the one project tree, and a check sees
the half-written files of the others. With it, a task gets
.factory-worktrees/task-<id>: a git worktree on branch factory/task/<id>, made
from HEAD, with the factory's files copied in (.factory/active, config.json,
run-start.json, lessons, criteria, changes) and the config's isolation_links
linked in. Its builder edits and checks there.

Settling brings the work into the project tree one task at a time, under
.factory/locks/integrate. The task's listed files are merged three ways (git
merge-file): the commit the checkout started from, the project tree now, and
the checkout. Its task file and its decisions.md line come along. Then
factory-check runs again in the project tree, and only that check's marker can
land the task. A conflict, or a check that is red there, puts the project tree
back as it was and is an attempt: RETRY. The next attempt's checkout is moved
onto HEAD first, with any conflict marked in the file for its builder to
resolve. Landed or sent to review, the checkout and its branch are removed.

The checkout is not under .factory/: no agent may write or cd there.

  factory-worktree prepare <id>   factory-start, before it moves the task
  factory-worktree task <id>      factory-start, after: the task file goes in,
                                  and the WORKDIR line comes out
  factory-worktree settle <id> [...]  factory-settle, for a task with a checkout
  factory-worktree remove <id>    the checkout and its branch go
  factory-worktree path <id>      the checkout's project directory, if any

Exit: 0 done (settle: what factory-settle returned); 1 refused (the output
says why); 2 usage.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HOOK_DIR)
from factory_compat import bash, npath  # noqa: E402

DIR = ".factory-worktrees"
BRANCH = "factory/task/%s"
COPY_FILES = ("active", "config.json", "run-start.json", "baseline.json")
COPY_DIRS = ("lessons", "criteria", "changes")
TASK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def say(*lines):
    for line in lines:
        if line:
            print(line)
    sys.stdout.flush()


def fwd(path):
    return str(path).replace("\\", "/")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def read_bytes(path):
    """A file's bytes; None when there is no file there."""
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as fh:
        return fh.read()


def put(path, data):
    """Write data there, or remove the file when data is None."""
    if data is None:
        if os.path.isfile(path) or os.path.islink(path):
            os.remove(path)
        return
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def last(out):
    lines = [l for l in (out or "").splitlines() if l.strip()]
    return lines[-1] if lines else ""


def git(cwd, *args):
    r = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True)
    return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")


def blob(top, rev, path):
    """path (from the repository's top) as commit rev has it; None when it has no file there."""
    r = subprocess.run(["git", "-C", top, "cat-file", "blob", "%s:%s" % (rev, path)], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def head(cwd):
    rc, out, _ = git(cwd, "rev-parse", "--verify", "-q", "HEAD")
    return out.strip() if rc == 0 else ""


def prefix_of(cwd):
    """Where the project sits in its repository: "" at the top, else "sub/dir/"."""
    rc, out, _ = git(cwd, "rev-parse", "--show-prefix")
    return out.strip() if rc == 0 else ""


def toplevel(cwd):
    rc, out, _ = git(cwd, "rev-parse", "--show-toplevel")
    return os.path.normpath(out.strip()) if rc == 0 and out.strip() else cwd


def same(a, b):
    return os.path.normcase(os.path.realpath(a)) == os.path.normcase(os.path.realpath(b))


def config(proj):
    try:
        with open(os.path.join(proj, ".factory", "config.json"), encoding="utf-8") as fh:
            cfg = json.load(fh)
        return cfg if isinstance(cfg, dict) else {}
    except (OSError, ValueError):
        return {}


def enabled(proj):
    fast = config(proj).get("fast") or {}
    return isinstance(fast, dict) and str(fast.get("isolation") or "").strip().lower() == "worktree"


def checkout_of(main, tid):
    """(top, project) of the task's checkout: the git worktree, and the project
    directory inside it (the same as top unless the project is a subdirectory
    of its repository)."""
    top = os.path.join(main, DIR, "task-" + tid)
    prefix = prefix_of(main).strip("/")
    return top, (os.path.join(top, *prefix.split("/")) if prefix else top)


def registered(main, top):
    rc, out, _ = git(main, "worktree", "list", "--porcelain")
    return rc == 0 and any(l.startswith("worktree ") and same(l[9:].strip(), top) for l in out.splitlines())


def has_checkout(main, tid):
    top, proj = checkout_of(main, tid)
    return os.path.isfile(os.path.join(proj, ".factory", "worktree")) and registered(main, top)


def main_of(proj):
    """The project tree a checkout belongs to - from git, never from the
    checkout's own files, which its builder can write."""
    rc, common, _ = git(proj, "rev-parse", "--git-common-dir")
    if rc != 0 or not common.strip():
        return None
    common = common.strip()
    if not os.path.isabs(common):
        common = os.path.join(proj, common)
    common = os.path.normpath(common)
    if os.path.basename(common) != ".git":
        return None
    prefix = prefix_of(proj).strip("/")
    top = os.path.dirname(common)
    return os.path.join(top, *prefix.split("/")) if prefix else top


def files_touched(text):
    """The paths under "## Files touched" - the parser of factory-commit.sh and
    factory-check.py."""
    out, inside = [], False
    for line in text.splitlines():
        if re.match(r"^##\s+Files touched\s*$", line):
            inside = True
            continue
        if inside and line.startswith("#"):
            break
        if inside:
            m = re.match(r"^\s*[-*]\s+(.*)$", line)
            if m:
                word = m.group(1).replace("`", "").split()
                if word:
                    out.append(npath(word[0][2:] if word[0].startswith("./") else word[0]))
    return sorted(set(out))


def usable(p):
    """A listed path factory-commit would commit, apart from the task file and
    decisions.md, which come over on their own terms."""
    return not (not p or p == "." or os.path.isabs(p) or re.match(r"^[A-Za-z]:", p) or p == ".." or
                p.startswith("../") or p in (".factory", ".git", "decisions.md") or
                p.startswith((".factory/", ".git/", "tasks/")))


def merge3(ours, base, theirs, labels):
    """(bytes, clean): the two sides merged against their base. A conflict in
    text is the merge with <<<<<<< markers and clean False; one that cannot be
    written as markers (a binary file, a file one side removed) is (None, False)."""
    if ours == theirs:
        return ours, True
    if ours == base:
        return theirs, True
    if theirs == base:
        return ours, True
    if ours is None or theirs is None or any(x is not None and b"\0" in x for x in (ours, base, theirs)):
        return None, False
    d = tempfile.mkdtemp(prefix="factory-merge-")
    try:
        names = []
        for name, data in (("ours", ours), ("base", base or b""), ("theirs", theirs)):
            path = os.path.join(d, name)
            with open(path, "wb") as fh:
                fh.write(data)
            names.append(path)
        r = subprocess.run(["git", "merge-file", "-p", "-L", labels[0], "-L", labels[1], "-L", labels[2]] + names,
                           capture_output=True)
        if r.returncode > 127:  # negative: git could not merge at all
            return None, False
        return r.stdout, r.returncode == 0
    finally:
        shutil.rmtree(d, ignore_errors=True)


def append_new(target, base, mine):
    """target, with the lines mine added to base appended - decisions.md, where
    two tasks each add a line at the end and neither undoes the other."""
    t = target or b""
    old, have = set((base or b"").splitlines()), set(t.splitlines())
    new = [l for l in (mine or b"").splitlines() if l.strip() and l not in old and l not in have]
    if not new:
        return target
    nl = b"\r\n" if b"\r\n" in t else b"\n"
    if t and not t.endswith(b"\n"):
        t += nl
    return t + nl.join(new) + nl


def link(src, dst):
    """dst points at src: a symlink, or on Windows without the right to make
    one, a directory junction (as factory-check's gate isolation does)."""
    try:
        os.symlink(src, dst, target_is_directory=os.path.isdir(src))
        return True
    except (OSError, NotImplementedError):
        pass
    if os.name == "nt" and os.path.isdir(src):
        try:
            import _winapi
            _winapi.CreateJunction(src, dst)
            return True
        except (ImportError, OSError, AttributeError):
            pass
    return False


def unlink(dst):
    """Drop a link without reaching what it points at: unlink a symlink, rmdir
    a junction. A real directory with files in it stays."""
    for fn in (os.unlink, os.rmdir):
        try:
            fn(dst)
            return
        except OSError:
            pass


class Lock:
    """One integration at a time: each one changes the project tree and checks
    it. Stale after 30 minutes, the longest a check is let run."""

    def __init__(self, path, stale_after=1800):
        self.path, self.stale_after, self.held = path, stale_after, False

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        waited = 0.0
        while True:
            try:
                os.mkdir(self.path)
                self.held = True
                return self
            except FileExistsError:
                try:
                    if time.time() - os.path.getmtime(self.path) > self.stale_after:
                        os.rmdir(self.path)
                        continue
                except OSError:
                    pass
                time.sleep(0.25)
                waited += 0.25
                if waited > self.stale_after:
                    return self

    def __exit__(self, *exc):
        if self.held:
            try:
                os.rmdir(self.path)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# prepare / task: factory-start
# ---------------------------------------------------------------------------

def exclude(main, more=()):
    """The checkouts, the record each one keeps of itself, and the links put
    into them are nobody's to commit: .git/info/exclude, which every worktree
    of the repository reads. (A linked node_modules is a file to git, which a
    "node_modules/" rule does not cover.)"""
    rc, common, _ = git(main, "rev-parse", "--git-common-dir")
    if rc != 0 or not common.strip():
        return
    common = common.strip()
    common = common if os.path.isabs(common) else os.path.join(main, common)
    prefix = prefix_of(main)
    want = ["/%s%s/" % (prefix, DIR), "/%s.factory/worktree" % prefix, "/%s.factory/worktree-links" % prefix]
    want += ["/%s%s" % (prefix, l) for l in more]
    path = os.path.join(common, "info", "exclude")
    text = read(path)
    add = [w for w in want if w not in text.splitlines()]
    if add:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(("" if not text or text.endswith("\n") else "\n") + "\n".join(add) + "\n")


def copy_factory(main, proj, tid):
    src, dst = os.path.join(main, ".factory"), os.path.join(proj, ".factory")
    os.makedirs(dst, exist_ok=True)
    names = list(COPY_FILES) + sorted(n for n in os.listdir(src) if n.startswith("autonomy"))
    for name in names:
        s, d = os.path.join(src, name), os.path.join(dst, name)
        if os.path.isfile(s):
            shutil.copy2(s, d)
        elif os.path.isfile(d):
            os.remove(d)
    for name in COPY_DIRS:
        s, d = os.path.join(src, name), os.path.join(dst, name)
        if os.path.isdir(d):
            shutil.rmtree(d, ignore_errors=True)
        if os.path.isdir(s):
            shutil.copytree(s, d)
    extra = os.path.join("gates", "extra.sh")
    if os.path.isfile(os.path.join(main, extra)) and not os.path.exists(os.path.join(proj, extra)):
        os.makedirs(os.path.join(proj, "gates"), exist_ok=True)
        shutil.copy2(os.path.join(main, extra), os.path.join(proj, extra))
    with open(os.path.join(dst, "worktree"), "w", encoding="utf-8") as fh:
        fh.write("task=%s\nbranch=%s\nmain=%s\n" % (tid, BRANCH % tid, fwd(main)))


def make_links(main, proj):
    """isolation_links (node_modules, a venv: what the build reads and git does
    not hold), linked in from the project tree. The list of links is kept, so
    removing the checkout drops them first and never reaches through one."""
    path = os.path.join(proj, ".factory", "worktree-links")
    have = [l for l in read(path).splitlines() if l.strip()]
    notes = []
    for l in config(main).get("isolation_links") or []:
        l = npath(str(l))
        if not usable(l) or l in have:
            continue
        s, d = os.path.join(main, l), os.path.join(proj, l)
        if not os.path.exists(s) or os.path.lexists(d):
            continue
        os.makedirs(os.path.dirname(d) or proj, exist_ok=True)
        if link(s, d):
            have.append(l)
        else:
            notes.append("WORKTREE NOTE: could not link %s into the checkout" % l)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("".join(l + "\n" for l in have))
    exclude(main, have)
    return notes


def refresh(main, top):
    """An earlier attempt's checkout, moved onto HEAD with its work: a file
    only HEAD changed takes HEAD's version, a file both changed is merged, and
    a conflict is left in the file, marked, for this attempt to resolve."""
    old, new = head(top), head(main)
    if not old or not new or old == new:
        return []
    prefix = prefix_of(main)
    rc, out, err = git(main, "diff", "--no-renames", "--name-only", "-z", old, new)
    if rc != 0:
        return ["WORKTREE NOTE: could not compare %s with HEAD (%s); the checkout stays where it was" %
                (old[:7], last(err))]
    conflicts = []
    paths = [p for p in out.split("\0") if p and not p.startswith(prefix + ".factory/")]
    for p in paths:
        here = os.path.join(top, p)
        w, b, h = read_bytes(here), blob(main, old, p), blob(main, new, p)
        if w == b:
            put(here, h)
        elif w == h:
            continue
        elif p == prefix + "decisions.md":
            put(here, append_new(h, b, w))
        else:
            merged, clean = merge3(w, b, h, ("this task", "where it started (%s)" % old[:7], "HEAD (%s)" % new[:7]))
            if merged is not None:
                put(here, merged)
            if not clean:
                conflicts.append(p[len(prefix):] if prefix and p.startswith(prefix) else p)
    git(top, "reset", "-q", "--mixed", new)
    notes = ["MOVED: this task's checkout started from %s; HEAD is now %s, and its work was carried onto it "
             "(%d file(s) changed in between)." % (old[:7], new[:7], len(paths))]
    for c in conflicts:
        notes.append("CONFLICT %s: this task and work that landed since both changed it. Resolve it in the "
                     "checkout first: the file holds the <<<<<<< markers (or, for a binary or removed file, this "
                     "task's version)." % c)
    return notes


def prepare(tid):
    main = os.getcwd()
    if not enabled(main):
        return 0
    if not head(main):
        say("WORKTREE SKIPPED for %s: there is no commit to make a checkout from yet - this task builds in the "
            "project tree." % tid)
        return 0
    top, proj = checkout_of(main, tid)
    exclude(main)
    notes = []
    if os.path.lexists(top):
        if not registered(main, top):
            say("WORKTREE REFUSED for %s: %s is there but is not a worktree of this repository. Move it away, "
                "then start the task again." % (tid, fwd(top)))
            return 1
        notes = refresh(main, top)
    else:
        os.makedirs(os.path.dirname(top), exist_ok=True)
        git(main, "worktree", "prune")
        rc, out, err = git(main, "-c", "core.hooksPath=/dev/null", "worktree", "add", "-q", "-B", BRANCH % tid,
                           top, "HEAD")
        if rc != 0:
            say("WORKTREE REFUSED for %s: git worktree add failed: %s" % (tid, last(err or out)))
            return 1
    copy_factory(main, proj, tid)
    say(*(notes + make_links(main, proj)))
    return 0


def task(tid):
    main = os.getcwd()
    if not has_checkout(main, tid):
        return 0
    top, proj = checkout_of(main, tid)
    src = os.path.join(main, "tasks", "in-progress", tid + ".md")
    if os.path.isfile(src):
        dst = os.path.join(proj, "tasks", "in-progress", tid + ".md")
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        for col in ("proposed", "backlog", "blocked", "done"):
            put(os.path.join(proj, "tasks", col, tid + ".md"), None)
    say("WORKDIR %s" % fwd(proj),
        "(This task has a checkout of its own, fast.isolation: worktree. Read, write and edit its files only under "
        "WORKDIR, by absolute path, and run every command on the code there, factory-check %s too: "
        "cd \"%s\" && ... . Run factory-block and factory-settle from the project root: cd \"%s\" && ... - "
        "settling is what brings the work over and checks it there, so give it a 10-minute Bash timeout.)"
        % (tid, fwd(proj), fwd(main)))
    return 0


# ---------------------------------------------------------------------------
# settle: factory-settle
# ---------------------------------------------------------------------------

def plain(main, tid, args):
    """factory-settle in the project tree, as if there were no checkout."""
    r = subprocess.run([sys.executable, os.path.join(HOOK_DIR, "factory-settle.py"), tid] + list(args), cwd=main,
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=dict(os.environ, FACTORY_WORKTREE_HANDOFF="1"))
    return r.returncode, ((r.stdout or "") + (r.stderr or "")).rstrip()


def run_py(cwd, script, *args):
    r = subprocess.run([sys.executable, os.path.join(HOOK_DIR, script)] + list(args), cwd=cwd, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return r.returncode, ((r.stdout or "") + (r.stderr or "")).rstrip()


def lane_of(main, tid):
    for col in ("in-progress", "backlog", "done", "blocked", "proposed"):
        if os.path.isfile(os.path.join(main, "tasks", col, tid + ".md")):
            return col
    return None


def sync(main, proj, tid):
    """What the checkout's builder and check wrote that settling in the project
    tree reads: the task file (its list, its attempts) and the failure record
    that tells a NO PROGRESS."""
    s = os.path.join(proj, "tasks", "in-progress", tid + ".md")
    d = os.path.join(main, "tasks", "in-progress", tid + ".md")
    if os.path.isfile(s) and os.path.isfile(d):
        shutil.copy2(s, d)
    sf, df = os.path.join(proj, ".factory"), os.path.join(main, ".factory")
    for rel in (os.path.join("failures", tid + ".log"), os.path.join("no-progress", tid)):
        put(os.path.join(df, rel), read_bytes(os.path.join(sf, rel)))
    fails = os.path.join(sf, "failures")
    for name in sorted(os.listdir(fails)) if os.path.isdir(fails) else []:
        if name.startswith("sig-") and not os.path.exists(os.path.join(df, "failures", name)):
            shutil.copy2(os.path.join(fails, name), os.path.join(df, "failures", name))
    # A checkout holds no other task's work in flight: nothing it waits on.
    put(os.path.join(df, "waiting", tid), None)


def hardblock(main, path):
    r = subprocess.run([bash(), os.path.join(HOOK_DIR, "factory-hardblock.sh"), "check", fwd(main), "path"],
                       input=path, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return r.returncode, (r.stdout or "").strip()


def expand(top, listed, prefix, revs):
    """The files behind the listed paths, from the repository's top: a listed
    directory is every file under it, in the checkout or in either commit."""
    out = []
    for p in listed:
        tp = prefix + p
        found = set()
        for rev in revs:
            rc, o, _ = git(top, "ls-tree", "-r", "--name-only", "-z", rev, "--", tp)
            found.update(x for x in o.split("\0") if x)
        out.append(tp) if not found or found == {tp} else out.extend(sorted(found))
    return sorted(set(out))


def expand_checkout(wt_top, files, prefix, listed):
    """Files added under a listed directory in the checkout, which no commit has yet."""
    extra = set()
    for p in listed:
        d = os.path.join(wt_top, prefix + p)
        if os.path.isdir(d) and not os.path.islink(d):
            for root, _dirs, names in os.walk(d):
                for n in names:
                    extra.add(fwd(os.path.relpath(os.path.join(root, n), wt_top)))
    return sorted(set(files) | extra)


def settle(tid, rest):
    here = os.getcwd()
    if os.path.isfile(os.path.join(here, ".factory", "worktree")):
        main = main_of(here)
        if not main or not os.path.isfile(os.path.join(main, ".factory", "active")):
            say("SETTLE REFUSED %s: %s is a task's checkout, but its project tree cannot be found." % (tid, fwd(here)))
            return 1
        os.chdir(main)
    main = os.getcwd()
    if not has_checkout(main, tid) or (rest and rest[0] in ("--conflict", "--refused")):
        rc, out = plain(main, tid, rest)
        say(out)
        return rc
    lane = lane_of(main, tid)
    if lane not in ("in-progress", "backlog") or os.path.exists(os.path.join(main, ".factory", "STOP")):
        rc, out = plain(main, tid, rest)
        say(out)
        return rc
    top, proj = checkout_of(main, tid)
    # Only the project tree's own check, after the work is merged in, may say green there.
    put(os.path.join(main, ".factory", "verified", tid), None)
    sync(main, proj, tid)
    no_wait = bool(rest) and rest[0] == "--no-wait"
    why = " ".join(rest[1:] if no_wait else rest).strip()
    marker = os.path.join(proj, ".factory", "verified", tid)
    if not os.path.isfile(marker):
        rc, out = plain(main, tid, rest)
        say(out)
        return rc
    want = re.search(r"^files=(\S+)", read(marker), re.M)
    rc, now = run_py(proj, "factory-check.py", "fingerprint", tid)
    if not want or rc != 0 or now.strip() != want.group(1):
        say("SETTLE REFUSED %s: its files changed after the green check in its checkout (or its list did). Run "
            "cd \"%s\" && factory-check %s again, then factory-settle %s from the project root."
            % (tid, fwd(proj), tid, tid))
        return 1
    return integrate(main, top, proj, tid, no_wait, why)


def integrate(main, wt_top, proj, tid, no_wait, why):
    lead = ["--no-wait"] if no_wait else []
    wt_marker = os.path.join(proj, ".factory", "verified", tid)
    main_marker = os.path.join(main, ".factory", "verified", tid)

    def attempt(reason):
        # The checkout's green does not stand for the next try: it checks again.
        put(wt_marker, None)
        rc, out = plain(main, tid, lead + [reason])
        say(out)
        return rc

    with Lock(os.path.join(main, ".factory", "locks", "integrate")):
        top, prefix = toplevel(main), prefix_of(main)
        base, now = head(wt_top), head(main)
        listed = [p for p in files_touched(read(os.path.join(proj, "tasks", "in-progress", tid + ".md"))) if usable(p)]

        # The guard judged the checkout's writes against the project tree's
        # root; what may come over is judged here again, against its own.
        for p in listed:
            rc, rule = hardblock(main, p)
            if rc == 6:
                return attempt("its checkout changes %s, a test HEAD has, which this task was not approved to "
                               "change (modifies_tests) - nothing was brought over" % p)
            if rc != 0:
                rule = rule if rc == 3 and rule else "rule-list-unreadable"
                subprocess.run([bash(), os.path.join(HOOK_DIR, "factory-hardblock.sh"), "trip", fwd(main), rule,
                                "worktree", "checkout:" + tid], capture_output=True)
                put(wt_marker, None)
                say("HARD BLOCK %s: its checkout changes %s (%s), which no agent of a factory run may write - "
                    "nothing was brought over, and the run is halted." % (tid, p, rule))
                rc, out = plain(main, tid, lead + ["hard block %s in its checkout" % rule])
                say(out)
                return rc

        files = expand_checkout(wt_top, expand(top, listed, prefix, [r for r in (base, now) if r]), prefix, listed)
        dirty = ""
        if files:
            _, dirty, _ = git(top, "status", "--porcelain", "--untracked-files=all", "--", *files)
        if dirty.strip():
            names = sorted(set(l[3:].strip() for l in dirty.splitlines() if len(l) > 3))
            return attempt("the project tree has uncommitted changes to %s, which this task changes too (a task "
                           "waiting for its review, or work of the developer's) - nothing was brought over"
                           % " ".join(names[:5]))

        merged, conflicts = {}, []
        for p in files:
            ours, b, theirs = read_bytes(os.path.join(top, p)), blob(top, base, p), read_bytes(os.path.join(wt_top, p))
            data, clean = merge3(ours, b, theirs, ("HEAD", "start", tid))
            if clean:
                merged[p] = data
            else:
                conflicts.append(p[len(prefix):] if prefix and p.startswith(prefix) else p)
        if conflicts:
            return attempt("it conflicts with work landed since its checkout was made (%s..%s): %s - the project "
                           "tree is untouched; the next attempt starts on HEAD with the conflict marked"
                           % (base[:7], now[:7], " ".join(conflicts[:5])))

        saved = dict((p, read_bytes(os.path.join(top, p))) for p in merged)
        changed = [p for p in merged if merged[p] != saved[p]]
        dec = os.path.join(main, "decisions.md")
        dec_saved = read_bytes(dec)

        def restore():
            for p in changed:
                put(os.path.join(top, p), saved[p])
            put(dec, dec_saved)

        # A settle stopped by a timeout (SIGTERM) must not leave the project
        # tree half merged: the files go back, and the lock is let go.
        previous = signal.signal(signal.SIGTERM, lambda *_: sys.exit(143)) if hasattr(signal, "SIGTERM") else None
        try:
            for p in changed:
                put(os.path.join(top, p), merged[p])
            put(dec, append_new(dec_saved, blob(top, base, prefix + "decisions.md"),
                                read_bytes(os.path.join(proj, "decisions.md"))))
            rc, out = run_py(main, "factory-check.py", tid)
        except BaseException:
            restore()
            put(main_marker, None)
            raise
        finally:
            if previous is not None:
                signal.signal(signal.SIGTERM, previous)

        if rc == 0 and os.path.isfile(main_marker):
            say("INTEGRATED %s: %d file(s) from its checkout merged onto HEAD %s; the check in the project tree "
                "is green." % (tid, len(changed), now[:7]))
            src, out2 = plain(main, tid, lead + ([why] if why else []))
            if re.match(r"^SETTLED \S+ (LANDED|REVIEW)", last(out2)):
                remove(main, tid)
                say("WORKTREE REMOVED %s: the checkout and branch %s are gone." % (tid, BRANCH % tid))
            say(out2)
            return src

        restore()
        put(main_marker, None)
        put(os.path.join(main, ".factory", "waiting", tid), None)
        say("INTEGRATION RED %s: green in its checkout, not on the project tree once merged onto HEAD %s - the "
            "project tree is back as it was. What the check there said:" % (tid, now[:7]))
        for line in [l for l in out.splitlines() if l.strip()][-30:]:
            say("  | " + line)
        return attempt("green in its checkout, red on the project tree once merged onto %s: %s" % (now[:7], last(out)))


# ---------------------------------------------------------------------------
# remove / path
# ---------------------------------------------------------------------------

def remove(main, tid):
    top, proj = checkout_of(main, tid)
    if not os.path.lexists(top):
        return 0
    # The links go first, by themselves: removing the checkout must never reach
    # through one into the project tree.
    for l in read(os.path.join(proj, ".factory", "worktree-links")).splitlines():
        if l.strip():
            unlink(os.path.join(proj, l.strip()))
    git(main, "worktree", "remove", "--force", top)
    if os.path.lexists(top):
        shutil.rmtree(top, ignore_errors=True)
    git(main, "worktree", "prune")
    git(main, "branch", "-D", BRANCH % tid)
    try:
        os.rmdir(os.path.join(main, DIR))
    except OSError:
        pass
    return 0


def main(argv):
    cmds = ("prepare", "task", "settle", "remove", "path")
    if len(argv) < 2 or argv[0] not in cmds or not TASK_ID.match(argv[1]):
        print("usage: factory-worktree %s <task-id>" % "|".join(cmds), file=sys.stderr)
        return 2
    cmd, tid, rest = argv[0], argv[1], argv[2:]
    if cmd == "prepare":
        return prepare(tid)
    if cmd == "task":
        return task(tid)
    if cmd == "settle":
        return settle(tid, rest)
    here = os.getcwd()
    if os.path.isfile(os.path.join(here, ".factory", "worktree")):
        here = main_of(here) or here
    if cmd == "remove":
        return remove(here, tid)
    if not has_checkout(here, tid):
        return 1
    print(fwd(checkout_of(here, tid)[1]))
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
