#!/usr/bin/env python3
"""Factory fast check. NOT a hook: a builder runs it once its task is written.

Usage (from the project root):
  factory-check <task-id>          judge one task on what it touched
  factory-check --full             judge the whole tree once, with the project's
                                   own gate commands
  factory-check units <path>...    which units a change to these paths reaches
  factory-check census [--json]    the test census of HEAD

Nothing in here knows a language, a framework or a build tool. What a project is
made of and how it is built and tested is data the project supplies:

  commands.*   in .factory/config.json - build, test, arch, lint - the same
               commands gates/verify.sh runs. They are the project's truth.
  check.*      optional, narrows them for a single task:
    format     a command that fixes formatting in place, "{files}" = the files
               the task touched. Absent: nothing is reformatted.
    build, lint, arch
               overrides for the per-task stages. Absent: commands.*. May use
               "{files}" (touched files) and "{paths}" (the reached units'
               paths, or "." when the change reaches everything).
    units      the parts of the project a change can be confined to - packages,
               projects, modules, feature folders, whatever the project is made
               of: [{"name", "path", "deps": [names], "test": "<command>"}], or a
               command that prints that list as JSON. "paths": [...] instead of
               "path" when a unit's code and its tests live in separate trees.
               A unit without "test" uses "unit_test" with "{path}" (its first
               path), "{paths}" and "{name}" filled in; a unit whose test is ""
               or null has no tests of its own.
    unit_test  the default per-unit test command.
    max_units  above this many units with tests, run commands.test once
               instead (default 10).
    ignore     path globs no test can observe (default: prose and docs).
    test_files / skip / count
               regexes overriding what counts as a test file, a suppression
               marker, and the number of tests a run reported.

The task check
  1. guards that cost nothing - a self-certifying acceptance, an empty
     "## Files touched", and the task's own census: did THIS task delete a test
     file or add a skip marker, judged against HEAD rather than against a
     baseline other tasks in flight keep rewriting
  2. format, build, lint, arch
  3. tests - with units: the tests of every unit the task touched and every
     unit that depends on one of them. A touched file outside every unit can
     reach anything, and so can a change with no units declared: the whole
     suite runs, as it would in the gate.
  4. the task's acceptance command, executed here rather than reported
  5. a change that ran no test at all is not green (untested_ok: true waives it)

The full check runs commands.build, test, arch and lint exactly as the gate
would, refuses a test stage that reported zero tests, and compares the test
census of HEAD with the one recorded when the run was planned.

Every stage's output goes to .factory/logs/; the caller gets a short summary and
the failing part. A failure seen before on the same task is NO PROGRESS.

Exit: 0 green, 1 red, 2 usage or setup error.
"""
import fnmatch
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.getcwd()
F = os.path.join(ROOT, ".factory")

# What counts as a test file, a suppression marker and a reported test count
# when the project does not say. The same table gates/verify.sh carries.
TEST_FILES = (r"(Tests?\.cs|_test\.go|(^|/)test_[^/]*\.py|_test\.py|_test\.dart|\.test\.[jt]sx?|\.spec\.[jt]sx?|"
              r"_spec\.rb|Tests?\.java|Tests?\.kt|_test\.rs|Tests?\.swift|Test\.php)$")
SKIP = (r"\[Ignore\(|\(Skip\s*=|\.skip\(|(^|[^a-zA-Z])xit\(|(^|[^a-zA-Z])xdescribe\(|@Ignore([^a-zA-Z]|$)|"
        r"@Disabled|@pytest\.mark\.skip|@unittest\.skip|(^|[^a-zA-Z])t\.Skip\(|#\[ignore\]|skip:\s*true|"
        r"Assert\.Inconclusive|markTestSkipped")
ZERO_TESTS = re.compile(r"no test files|no tests ran|no tests found|no tests were found|found 0 tests|ran 0 tests|"
                        r"Tests:\s+0 total|Total tests:\s*0\b|total:\s*0\b", re.I)
# Plain-English summary phrasings many runners share. A runner that says it
# differently gets its own regex in check.count - written by /factory:init, which
# knows the project's runner; nothing here does. One pattern wins; within it
# every match is summed, because a workspace prints one summary per package.
COUNTS = [
    r"(?i)total tests:\s*(\d+)",
    r"(?i)\btests?:\s*(\d+)\s*passed",
    r"(?i)\bpassed:\s*(\d+)",
    r"(?i)(\d+)\s+(?:tests?\s+)?passed",
]
DEFAULT_IGNORE = ["*.md", "*.txt", "docs/*", "doc/*", "LICENSE*", ".github/ISSUE_TEMPLATE/*"]

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def read(path, default=""):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return default


def load_config():
    try:
        with open(os.path.join(F, "config.json"), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def frontmatter(text):
    """Leading --- block as a dict of raw strings; the first copy of a key wins."""
    data = {}
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return data
    for line in lines[1:]:
        if line.strip() == "---":
            break
        key, sep, value = line.partition(":")
        if sep and key.strip() not in data:
            data[key.strip()] = value.strip()
    return data


def set_frontmatter(path, updates):
    """Rewrites keys inside the leading --- block, adding the ones it lacks."""
    lines = read(path).split("\n")
    if not lines or lines[0].strip() != "---":
        return
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    if end is None:
        return
    seen = set()
    for i in range(1, end):
        key = lines[i].partition(":")[0].strip()
        if key in updates and key not in seen:
            lines[i] = "%s: %s" % (key, updates[key])
            seen.add(key)
    lines[end:end] = ["%s: %s" % (k, v) for k, v in updates.items() if k not in seen]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def files_touched(text):
    """Same parser as factory-commit.sh: "- path" lines under "## Files touched"."""
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
                    out.append(os.path.normpath(word[0][2:] if word[0].startswith("./") else word[0]))
    return sorted(set(out))


def task_file(task_id):
    for col in ("in-progress", "backlog", "blocked", "done"):
        p = os.path.join(ROOT, "tasks", col, task_id + ".md")
        if os.path.isfile(p):
            return p, col
    return None, None


def git(*args):
    try:
        r = subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True, text=True, errors="replace")
        return r.returncode, r.stdout
    except OSError:
        return 1, ""


def fill(cmd, **lists):
    for key, items in lists.items():
        cmd = cmd.replace("{%s}" % key, " ".join(shlex.quote(i) for i in items))
    return cmd


class Lock:
    """One check at a time per project. Two builds or test runs in one tree
    share its output directories and have been seen to break each other; a check
    lasts seconds to a minute, so waiting is cheap."""

    def __init__(self, name, stale_after=1800):
        self.path = os.path.join(F, "locks", name)
        self.stale_after = stale_after
        self.held = False

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
                    return self  # never wedge the run on a lock

    def __exit__(self, *exc):
        if self.held:
            try:
                os.rmdir(self.path)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# units: what the project says it is made of
# ---------------------------------------------------------------------------


def load_units(check):
    """The unit list from check.units - inline, or printed by a command.
    Returns (units, problem)."""
    spec = check.get("units")
    if not spec:
        return None, None
    if isinstance(spec, str):
        try:
            r = subprocess.run(["bash", "-c", spec], cwd=ROOT, capture_output=True, text=True)
            spec = json.loads(r.stdout)
        except (OSError, ValueError) as err:
            return None, "check.units did not print a JSON list (%s)" % err
    if not isinstance(spec, list):
        return None, "check.units is not a list"
    units = []
    default_test = check.get("unit_test")
    for u in spec:
        if not isinstance(u, dict):
            continue
        raw = u.get("paths") or ([u["path"]] if u.get("path") else [])
        paths = [os.path.normpath(p) for p in raw if p]
        if not paths:
            continue
        name = u.get("name") or paths[0]
        test = u["test"] if "test" in u else default_test
        if test:
            test = (test.replace("{paths}", " ".join(shlex.quote(p) for p in paths))
                    .replace("{path}", shlex.quote(paths[0])).replace("{name}", shlex.quote(name)))
        units.append({"name": name, "paths": paths, "path": paths[0], "deps": list(u.get("deps") or []),
                      "test": test or ""})
    return units, None


def owner(path, units):
    """The unit a path belongs to: the one with the longest matching path."""
    best, best_len = None, -1
    for u in units:
        for p in u["paths"]:
            if p == "." or path == p or path.startswith(p + os.sep):
                length = 0 if p == "." else len(p)
                if length > best_len:
                    best, best_len = u, length
    return best


def ignored(path, patterns):
    return any(fnmatch.fnmatch(path, pat) or fnmatch.fnmatch(os.path.basename(path), pat) for pat in patterns)


def reach(files, units, ignore):
    """Units a change reaches: the owners of the changed files and everything
    that depends on them. None means the change can reach anything."""
    touched = set()
    for f in files:
        if ignored(f, ignore):
            continue
        u = owner(f, units)
        if u is None:
            return None, "%s belongs to no unit, so it can reach anything" % f
        touched.add(u["name"])
    rdeps = {}
    for u in units:
        for d in u["deps"]:
            rdeps.setdefault(d, set()).add(u["name"])
    seen, todo = set(), list(touched)
    while todo:
        n = todo.pop()
        if n in seen:
            continue
        seen.add(n)
        todo.extend(rdeps.get(n, ()))
    order = [u for u in units if u["name"] in seen]
    return order, "%d unit(s) touched, %d reached" % (len(touched), len(order))


# ---------------------------------------------------------------------------
# counting tests
# ---------------------------------------------------------------------------


def count_tests(out, check):
    """Tests a run reported, or None when the output is not recognised."""
    if check.get("count"):
        nums = [int(n) for n in re.findall(check["count"], out, re.M) if str(n).isdigit()]
        return sum(nums) if nums else None
    if ZERO_TESTS.search(out):
        return 0
    for pat in COUNTS:
        found = re.findall(pat, out, re.M)
        if not found:
            continue
        total = sum(int(n) for n in found if str(n).isdigit())
        if total > 0:
            return total
    return None


# ---------------------------------------------------------------------------
# census
# ---------------------------------------------------------------------------


def census_regexes(check):
    return re.compile(check.get("test_files") or TEST_FILES), re.compile(check.get("skip") or SKIP)


def skips_in(text, skip_re):
    return sum(1 for line in text.splitlines() for _ in skip_re.finditer(line))


def task_census(listed, fm, check):
    """What this task did to the tests, judged against HEAD: test files it
    deleted, suppression markers it added. Other tasks in flight cannot move
    this number, because it only looks at this task's own files."""
    tf, skip_re = census_regexes(check)
    removed, added = [], 0
    for p in listed:
        if not tf.search(p.replace(os.sep, "/")):
            continue
        rc, before = git("show", "HEAD:./" + p.replace(os.sep, "/"))
        existed = rc == 0
        now = os.path.join(ROOT, p)
        if existed and not os.path.exists(now):
            removed.append(p)
            continue
        after = skips_in(read(now), skip_re)
        added += max(0, after - (skips_in(before, skip_re) if existed else 0))
    return removed, added


def head_census(check):
    """Test files and suppression markers in HEAD."""
    tf, skip_re = census_regexes(check)
    rc, out = git("ls-tree", "-r", "--name-only", "HEAD", "--", ".")
    if rc != 0:
        return None
    rc2, prefix = git("rev-parse", "--show-prefix")
    prefix = prefix.strip() if rc2 == 0 else ""
    files = [p[len(prefix):] if prefix and p.startswith(prefix) else p for p in out.splitlines()]
    files = [p for p in files if tf.search(p)]
    per_file = {}
    for p in files:
        _, text = git("show", "HEAD:./" + p)
        per_file[p] = skips_in(text, skip_re)
    _, head = git("rev-parse", "--short", "HEAD")
    return {"head": head.strip(), "test_files": len(files), "skipped": sum(per_file.values()), "files": per_file}


# ---------------------------------------------------------------------------
# a run: every step logged, a short summary for the caller
# ---------------------------------------------------------------------------


class Run:
    def __init__(self, label):
        os.makedirs(os.path.join(F, "logs"), exist_ok=True)
        n = 1
        while os.path.exists(os.path.join(F, "logs", "%s.%d.log" % (label, n))):
            n += 1
        self.log_rel = os.path.join(".factory", "logs", "%s.%d.log" % (label, n))
        self.log = open(os.path.join(ROOT, self.log_rel), "w", encoding="utf-8")
        self.lines, self.failed, self.sig_text = [], [], []

    def step(self, name, cmd):
        self.log.write("### %s: %s\n" % (name, cmd))
        self.log.flush()
        started = time.time()
        try:
            r = subprocess.run(["bash", "-c", cmd], cwd=ROOT, capture_output=True, text=True, errors="replace")
            out, rc = (r.stdout or "") + (r.stderr or ""), r.returncode
        except OSError as err:
            out, rc = str(err), 127
        self.log.write(out + "\n### %s: exit %d in %.1fs\n" % (name, rc, time.time() - started))
        self.log.flush()
        return rc, out

    def ok(self, name, detail=""):
        self.lines.append("  %-8s PASS%s" % (name, " (%s)" % detail if detail else ""))

    def note(self, name, detail):
        self.lines.append("  %-8s %s" % (name, detail))

    def fail(self, name, detail, excerpt=""):
        self.lines.append("  %-8s FAIL%s" % (name, " (%s)" % detail if detail else ""))
        self.failed.append((name, excerpt))
        self.sig_text.append("### %s\n%s\n%s" % (name, detail, excerpt))

    def close(self):
        self.log.close()


def excerpt(out, limit=60):
    """The part of a failing run worth reading: from the first line that looks
    like an error onwards, capped. The whole output is in the log."""
    lines = out.splitlines()
    start = next((i for i, l in enumerate(lines)
                  if re.search(r"\berror\b|\bERROR\b|\[E\]|FAIL|Exception|Expected|assert|panic|failed", l)),
                 max(0, len(lines) - limit))
    picked = lines[start:]
    if len(picked) > limit:
        picked = picked[:limit - 1] + ["... (%d more lines in the log)" % (len(picked) - limit + 1)]
    return "\n".join(picked)[:6000]


def run_stage(run, name, cmd, **lists):
    rc, out = run.step(name, fill(cmd, **lists))
    if rc == 0:
        run.ok(name)
    else:
        run.fail(name, "exit %d" % rc, excerpt(out))
    return rc == 0, out


# ---------------------------------------------------------------------------
# failure history: same files and meaning as the gate's
# ---------------------------------------------------------------------------


def failure_signature(text):
    norm = []
    for line in text.splitlines():
        if not re.search(r"(^|[^a-z])(error|fail(ed|ure|s)?|exception|panic|assert|violation|missing)([^a-z]|$)",
                         line, re.I):
            continue
        line = line.replace(os.path.realpath(ROOT), "<root>").replace(ROOT, "<root>")
        line = re.sub(r"/(private/)?(tmp|var/folders)/[^ :\"]*", "<tmp>", line)
        line = re.sub(r"[0-9a-f]{7,40}", "<sha>", line)
        line = re.sub(r"[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.]+Z?", "<ts>", line)
        line = re.sub(r"[0-9]+", "<n>", line)
        norm.append(re.sub(r"\s+", " ", line).strip())
    if not norm:
        norm = [re.sub(r"\s+", " ", re.sub(r"[0-9]+", "<n>", l)).strip() for l in text.splitlines()[-40:]]
    return "\n".join(sorted(set(norm)))


def record_failure(task_id, text):
    fail_dir = os.path.join(F, "failures")
    os.makedirs(fail_dir, exist_ok=True)
    sig = failure_signature(text)
    sha = hashlib.sha256(sig.encode("utf-8")).hexdigest()[:12]
    sig_file = os.path.join(fail_dir, "sig-%s.txt" % sha)
    if not (os.path.exists(sig_file) and os.path.getsize(sig_file) > 0):
        with open(sig_file, "w", encoding="utf-8") as fh:
            fh.write(sig + "\n")
    hist = os.path.join(fail_dir, task_id + ".log")
    past = read(hist)
    repeat = (" %s " % sha) in past
    attempt = len([l for l in past.splitlines() if l.strip()]) + 1
    with open(hist, "a", encoding="utf-8") as fh:
        fh.write("%s %s attempt=%d\n" % (now_iso(), sha, attempt))
    if repeat:
        os.makedirs(os.path.join(F, "no-progress"), exist_ok=True)
        with open(os.path.join(F, "no-progress", task_id), "w", encoding="utf-8") as fh:
            fh.write("signature=%s\nattempt=%d\ndetail=.factory/failures/sig-%s.txt\n" % (sha, attempt, sha))
    return sha, attempt, repeat


def tree_hash():
    try:
        r = subprocess.run(["bash", os.path.join(HOOK_DIR, "factory-gate-skip.sh"), "hash", ROOT],
                           capture_output=True, text=True)
        return r.stdout.strip() or "unknown"
    except OSError:
        return "unknown"


TEXT_READERS = {"grep", "egrep", "fgrep", "rg", "cat", "test", "[", "head", "tail", "wc", "awk", "sed", "diff",
                "cmp", "ls", "echo", "printf", "true", "stat", "file", "find"}


def self_certifying(acc):
    """An acceptance command whose only evidence is a file the agent writes
    itself: it names decisions.md or a task file, and every command in it only
    reads text. Nothing about any language - a command that runs anything else
    is taken as running the code."""
    if not acc or not re.search(r"decisions\.md|tasks/[^ ]*\.md", acc):
        return False
    for part in re.split(r"&&|\|\||;|\|", acc):
        words = part.strip().split()
        while words and ("=" in words[0] or words[0] in ("!", "then", "do")):
            words = words[1:]
        if words and os.path.basename(words[0]) not in TEXT_READERS:
            return False
    return True


def acceptance_covered(acc, commands_run):
    """An acceptance command identical to one the check already ran adds nothing."""
    return acc.strip() in {c.strip() for c in commands_run}


# ---------------------------------------------------------------------------
# the task check
# ---------------------------------------------------------------------------


def check_task(task_id):
    cfg = load_config()
    check = cfg.get("check") or {}
    commands = cfg.get("commands") or {}
    path, col = task_file(task_id)
    if not path:
        print("CHECK: no task file for %s under tasks/" % task_id)
        return 2
    units, units_problem = load_units(check)
    if units_problem:
        print("CHECK: %s - fix .factory/config.json" % units_problem)
        return 2

    marker = os.path.join(F, "verified", task_id)
    if os.path.exists(marker):
        os.remove(marker)
    if col == "in-progress":
        set_frontmatter(path, {"stage": "verifying", "stage_since": now_iso()})

    text = read(path)
    fm = frontmatter(text)
    listed = files_touched(text)
    existing = [p for p in listed if os.path.exists(os.path.join(ROOT, p))]
    run = Run(task_id)
    print("CHECK %s: %d file(s) touched" % (task_id, len(listed)))

    # --- guards that cost nothing ------------------------------------------
    acc = fm.get("acceptance", "")
    if fm.get("needs_human", "").lower() != "true" and self_certifying(acc):
        run.fail("accept", "self-certifying: its only evidence is a file the agent writes itself",
                 "replace it with a command that runs the code, or mark the task needs_human: true")
    if not listed:
        run.fail("files", "the task lists nothing under \"## Files touched\"",
                 "list every file you created, changed or deleted, one \"- path\" per line, then run the check again")
    if fm.get("allow_test_removal", "").lower() != "true" and listed:
        removed, added = task_census(listed, fm, check)
        if removed:
            run.fail("census", "this task deletes test file(s): " + " ".join(removed),
                     "a suite does not get greener by losing tests; restore them")
        if added:
            run.fail("census", "this task adds %d skip marker(s)" % added,
                     "skipping the failing test is not fixing it; remove the skip")

    tests_ran, counted, commands_run = 0, False, []
    if not run.failed:
        reached, why = (reach(listed, units, check.get("ignore") or DEFAULT_IGNORE) if units is not None
                        else (None, "no units declared"))
        paths = ["."] if reached is None else sorted({p for u in reached for p in u["paths"]}) or ["."]
        with Lock("check"):
            if check.get("format") and existing:
                before = {p: read(os.path.join(ROOT, p)) for p in existing}
                ok, out = run_stage(run, "format", check["format"], files=existing)
                changed = sum(1 for p in existing if read(os.path.join(ROOT, p)) != before[p])
                if ok and changed:
                    run.lines[-1] = "  %-8s PASS (%d file(s) reformatted)" % ("format", changed)
            for stage in ("build", "lint", "arch"):
                if run.failed:
                    break
                cmd = check.get(stage) if stage in check else commands.get(stage)
                if cmd and "{files}" in cmd and not existing:
                    run.note(stage, "skipped (no touched file left to give it)")
                elif cmd:
                    ok, _ = run_stage(run, stage, cmd, files=existing, paths=paths)
                    commands_run.append(fill(cmd, files=existing, paths=paths))

            if not run.failed:
                if reached is None and not commands.get("test"):
                    targets = []
                    if (cfg.get("gate_mode") or "full") == "full":
                        run.fail("tests", "MISSING - gate_mode=full requires commands.test")
                elif reached is None:
                    targets = [("suite", commands["test"])]
                    run.note("reach", why + " - the whole suite runs")
                else:
                    targets = [(u["name"], u["test"]) for u in reached if u["test"]]
                    limit = int(check.get("max_units") or 10)
                    if len(targets) > limit and commands.get("test"):
                        # One suite run beats many runs that each pay the runner's start-up.
                        run.note("reach", "%s - %d units with tests, more than %d: the whole suite runs"
                                 % (why, len(targets), limit))
                        targets = [("suite", commands["test"])]
                    else:
                        run.note("reach", "%s: %s" % (why, ", ".join(u["name"] for u in reached) or "none"))
                for name, cmd in targets:
                    if not cmd:
                        continue
                    rc, out = run.step("test %s" % name, cmd)
                    commands_run.append(cmd)
                    n = count_tests(out, check)
                    if n is not None:
                        tests_ran += n
                        counted = True
                    if rc != 0:
                        run.fail("tests", "%s: exit %d" % (name, rc), excerpt(out))
                        break
                if not targets:
                    counted = True  # nothing the change reaches has tests: zero ran, and that is known
                elif not run.failed:
                    run.ok("tests", ("%d test(s)" % tests_ran if counted else "count not recognised")
                           + " in %d target(s)" % len([t for t in targets if t[1]]))

            if not run.failed and acc:
                if re.search(r"verify\.sh|factory-check", acc):
                    run.note("accept", "skipped (it names the gate itself)")
                elif acceptance_covered(acc, commands_run):
                    run.ok("accept", "already ran above")
                else:
                    rc, out = run.step("accept", acc)
                    n = count_tests(out, check)
                    if rc == 0:
                        if n is not None:
                            tests_ran += n
                            counted = True
                        run.ok("accept", "%d test(s)" % n if n else "")
                    else:
                        run.fail("accept", "exit %d" % rc, excerpt(out))

        min_tests = int(cfg.get("min_tests", 1) or 1)
        if not run.failed and counted and tests_ran < min_tests:
            if fm.get("untested_ok", "").lower() == "true":
                run.note("tests", "no test exercised this change - waived by untested_ok")
            else:
                run.fail("tests", "no test exercised this change (%d ran, minimum %d)" % (tests_ran, min_tests),
                         "none of the tests the check ran covers what this task changed. Add the tests the "
                         "acceptance criteria describe, or put the test that covers it in the acceptance command.")

    run.close()
    for line in run.lines:
        print(line)

    if run.failed:
        for name, text_ in run.failed:
            if text_:
                print("--- %s ---" % name)
                print(text_)
        sha, attempt, repeat = record_failure(task_id, "\n".join(run.sig_text))
        print("--- full log: %s" % run.log_rel)
        if repeat:
            print("CHECK RESULT: RED for %s - NO PROGRESS (signature %s, attempt %d): this exact failure already "
                  "happened on this task. Change the approach, do not run the check again unchanged."
                  % (task_id, sha, attempt))
        else:
            print("CHECK RESULT: RED for %s (signature %s, attempt %d)" % (task_id, sha, attempt))
        return 1

    os.makedirs(os.path.join(F, "verified"), exist_ok=True)
    _, head = git("rev-parse", "--short", "HEAD")
    with open(marker, "w", encoding="utf-8") as fh:
        fh.write("%s\n%sisolated=no\ncheck=fast\ncommit=%s\ntree=%s\n"
                 % (now_iso(), "tests=%d\n" % tests_ran if counted else "", head.strip() or "unknown", tree_hash()))
    hist = os.path.join(F, "failures", task_id + ".log")
    if os.path.exists(hist):
        os.makedirs(os.path.join(F, "failures", "resolved"), exist_ok=True)
        os.replace(hist, os.path.join(F, "failures", "resolved", task_id + ".log"))
    np = os.path.join(F, "no-progress", task_id)
    if os.path.exists(np):
        os.remove(np)
    print("CHECK RESULT: GREEN for %s (marker written)" % task_id)
    return 0


# ---------------------------------------------------------------------------
# the whole tree
# ---------------------------------------------------------------------------


def check_full():
    cfg = load_config()
    check = cfg.get("check") or {}
    commands = cfg.get("commands") or {}
    full_mode = (cfg.get("gate_mode") or "full") == "full"
    run = Run("full")
    tests_ran = None
    with Lock("check"):
        for stage in ("build", "test", "arch", "lint"):
            cmd = commands.get(stage)
            if not cmd:
                if full_mode and stage != "arch":
                    run.fail(stage, "MISSING - gate_mode=full requires commands.%s" % stage)
                continue
            rc, out = run.step(stage, cmd)
            if rc != 0:
                run.fail(stage, "exit %d" % rc, excerpt(out))
                continue
            if stage != "test":
                run.ok(stage)
                continue
            tests_ran = count_tests(out, check)
            min_tests = int(cfg.get("min_tests", 1) or 1)
            if tests_ran is None:
                run.ok("test", "count not recognised - set check.count to a regex for this runner's summary")
            elif tests_ran < min_tests:
                run.fail("test", "the suite reported %d test(s), minimum is %d" % (tests_ran, min_tests),
                         "a suite that runs nothing exits 0 and proves nothing")
            else:
                run.ok("test", "%d test(s)" % tests_ran)

    # The run as a whole may not have lost tests either: HEAD now against HEAD
    # when the run was planned.
    start = {}
    try:
        start = json.loads(read(os.path.join(F, "run-start.json")) or "{}")
    except ValueError:
        pass
    now = head_census(check)
    if start and now:
        # A task that declared allow_test_removal answers for its own files only.
        allowed = set()
        for tid in start.get("tasks", []):
            p, _ = task_file(tid)
            text = read(p) if p else ""
            if frontmatter(text).get("allow_test_removal", "").lower() == "true":
                allowed.update(f.replace(os.sep, "/") for f in files_touched(text))
        before, after = start.get("files") or {}, now["files"]
        lost = sorted(f for f in before if f not in after and f not in allowed)
        skipped = sorted(f for f in after if after[f] > before.get(f, 0) and f not in allowed)
        if lost:
            run.fail("census", "test files in HEAD went from %d to %d during this run: %s"
                     % (start.get("test_files", 0), now["test_files"], " ".join(lost[:10])),
                     "find the task commit that removed them - /factory:bisect, or git log -- <file>")
        elif skipped:
            run.fail("census", "skip markers were added during this run: " + " ".join(skipped[:10]),
                     "find the task commit that added them")
        else:
            run.ok("census", "%d test file(s), %d suppression(s); %d/%d when the run started"
                   % (now["test_files"], now["skipped"], start.get("test_files", 0), start.get("skipped", 0)))

    run.close()
    for line in run.lines:
        print(line)
    verdict = "red" if run.failed else "green"
    with open(os.path.join(F, "full-check"), "w", encoding="utf-8") as fh:
        fh.write("verdict=%s\nat=%s\ntests=%s\ntree=%s\nlog=%s\n"
                 % (verdict, now_iso(), tests_ran if tests_ran is not None else "unknown", tree_hash(), run.log_rel))
    if run.failed:
        for name, text_ in run.failed:
            if text_:
                print("--- %s ---" % name)
                print(text_)
        print("--- full log: %s" % run.log_rel)
        print("FULL CHECK: RED")
        return 1
    print("FULL CHECK: GREEN")
    return 0


def main(argv):
    if not os.path.isfile(os.path.join(F, "active")):
        print("CHECK: %s has no .factory/active - not a factory project, or not its root." % ROOT)
        return 2
    if not argv:
        print(__doc__.split("\n\n")[0])
        return 2
    if argv[0] == "--full":
        return check_full()
    if argv[0] == "units":
        check = (load_config().get("check") or {})
        units, problem = load_units(check)
        if problem:
            print("UNITS: " + problem)
            return 2
        if units is None:
            print("ALL no units declared in check.units")
            return 0
        reached, why = reach([os.path.normpath(p) for p in argv[1:]], units, check.get("ignore") or DEFAULT_IGNORE)
        if reached is None:
            print("ALL " + why)
        else:
            for u in reached:
                print("%s %s" % (u["name"], u["path"]))
        return 0
    if argv[0] == "census":
        c = head_census(load_config().get("check") or {})
        print(json.dumps(c) if "--json" in argv else "HEAD %s: %s test file(s), %s suppression(s)"
              % (c["head"], c["test_files"], c["skipped"]) if c else "CENSUS: not a git repository")
        return 0 if c else 2
    return check_task(argv[0])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
