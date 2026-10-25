#!/usr/bin/env python3
"""Factory fast check. NOT a hook: a builder runs it once its task is written.

Usage (from the project root):
  factory-check <task-id>          judge one task on what it touched
  factory-check --full             judge the whole tree once, with the project's
                                   own gate commands
  factory-check units <path>...    which units a change to these paths reaches
  factory-check census [--json]    the test census of HEAD
  factory-check count <file>       the number of tests a runner's output reports
  factory-check selfcert <command> exit 0 when an acceptance command is
                                   self-certifying (for factory-lint)
  factory-check readonly <path>... the tests among these paths that HEAD has
                                   and no task in progress may change
  factory-check fingerprint <id>   the digest of the task's listed files now
                                   (factory-land compares it with the marker's)

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

When every error a failing stage points at is in a file another task has in
flight - changed, uncommitted, not on this task's list - the failure is not
this task's: nothing is recorded against it, and the check waits, holding no
lock and spending nothing, for that work to land or change (check.foreign_wait
seconds, default 120), then runs again. Still blocked at the end: WAITING.

Exit: 0 green, 1 red, 2 usage or setup error, 3 waiting on another task's
work in flight.
"""
import contextlib
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HOOK_DIR)
from factory_compat import bash, npath, rel, strip_root  # noqa: E402
ROOT = os.getcwd()
F = os.path.join(ROOT, ".factory")

# What counts as a test file, a suppression marker and a reported test count
# when the project does not say. The same table gates/verify.sh carries.
TEST_FILES = (r"(Tests?\.cs|_test\.go|(^|/)test_[^/]*\.py|_test\.py|_test\.dart|\.test\.[jt]sx?|\.spec\.[jt]sx?|"
              r"_spec\.rb|Tests?\.java|Tests?\.kt|_test\.rs|Tests?\.swift|Test\.php)$")
SKIP = (r"\[Ignore\(|\(Skip\s*=|\.skip\(|(^|[^a-zA-Z])xit\(|(^|[^a-zA-Z])xdescribe\(|@Ignore([^a-zA-Z]|$)|"
        r"@Disabled|@pytest\.mark\.skip|@unittest\.skip|(^|[^a-zA-Z])t\.Skip\(|#\[ignore\]|skip:\s*true|"
        r"Assert\.Inconclusive|markTestSkipped")
# What decides how the tests run without being a test itself. A file of these
# that HEAD has is read-only for an agent, like the tests (readonly_tests).
TEST_INFRA = (r"(^|/)(conftest\.py|pytest\.ini|jest\.config\.[^/]+|vitest\.config\.[^/]+|karma\.conf\.[^/]+|"
              r"\.mocharc[^/]*|playwright\.config\.[^/]+|cypress\.config\.[^/]+|phpunit\.xml[^/]*)$|"
              r"^\.github/workflows/")
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
                    out.append(npath(word[0][2:] if word[0].startswith("./") else word[0]))
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
            r = subprocess.run([bash(), "-c", spec], cwd=ROOT, capture_output=True, text=True)
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
        paths = [npath(p) for p in raw if p]
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
            if p == "." or path == p or path.startswith(p + "/"):
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


# flutter test / dart test: every line is a running tally, "00:03 +12 ~1 -2: name"
# (passed, skipped, failed). The last tally is the largest; summing them counts
# each test many times. The compact reporter rewrites one line with \r.
DART_TALLY = re.compile(r"^\s*\d+:\d\d \+(\d+)(?: ~\d+)?(?: -\d+)?: ", re.M)


def count_tests(out, check):
    """Tests a run reported, or None when the output is not recognised."""
    if check.get("count"):
        nums = [int(n) for n in re.findall(check["count"], out, re.M) if str(n).isdigit()]
        return sum(nums) if nums else None
    if ZERO_TESTS.search(out):
        return 0
    tally = [int(n) for n in DART_TALLY.findall(out.replace("\r", "\n"))]
    if tally:
        return max(tally)
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
        if not tf.search(p):
            continue
        rc, before = git("show", "HEAD:./" + p)
        existed = rc == 0
        now = os.path.join(ROOT, p)
        if existed and not os.path.exists(now):
            removed.append(p)
            continue
        after = skips_in(read(now), skip_re)
        added += max(0, after - (skips_in(before, skip_re) if existed else 0))
    return removed, added


ASSERTION = re.compile(r"\b(assert\w*|expect\w*|should\w*|verify|XCTAssert\w*|Assert\.\w+)\b|\.(toBe|toEqual|toThrow|toHaveBeen\w*)\(")


def changed_assertions(listed, check):
    """Assertion lines a task removed or rewrote in test files that already
    exist in HEAD: {path: count}. An added test is a new assertion; only a
    changed existing one can make a red suite green without fixing anything."""
    tf, _ = census_regexes(check)
    rx = re.compile(check["assertion"]) if check.get("assertion") else ASSERTION
    out = {}
    for p in listed:
        if not tf.search(p):
            continue
        rc, _ = git("cat-file", "-e", "HEAD:./" + p)
        if rc != 0:
            continue
        rc, diff = git("diff", "HEAD", "-U0", "--", p)
        if rc != 0:
            continue
        n = sum(1 for l in diff.splitlines() if l.startswith("-") and not l.startswith("---") and rx.search(l))
        if n:
            out[p] = n
    return out


# --- cheat signatures ---------------------------------------------------------
# What makes a suite pass without the code working, in the shapes the reward-
# hacking studies caught (OpenAI's exit(0) and SkipTest, METR's patched graders
# and stack reads): looked for in the lines this task added, never in what HEAD
# already had. A systemic one is red. An ambiguous one - an __eq__ that is always
# true has honest uses - sends the task to a reviewer, never to red.
CODE_FILE = re.compile(r"\.(py|pyw|js|mjs|cjs|jsx|ts|tsx|mts|cts|rb|go|rs|java|kt|kts|cs|php|dart|swift|scala|ex|exs|lua)$",
                       re.I)
ENTRY_POINT = re.compile(r"(^|/)(__main__\.py|main\.[a-z]+|cli\.[a-z]+|[^/]*_cli\.py|manage\.py|setup\.py|"
                         r"noxfile\.py|fabfile\.py|tasks\.py)$|(^|/)(bin|scripts|cli|cmd|tools)/")
MAIN_GUARD = re.compile(r"""^if\s+__name__\s*==\s*['"]__main__['"]\s*:""", re.M)
READ_CALL = re.compile(r"\b(open|read_text|read_bytes|readFile|readFileSync|readdir|readdirSync|listdir|scandir|"
                       r"walk|i?glob|rglob|readlines|createReadStream|ReadAllText|ReadAllLines|ReadFile)\s*\(")
TEST_PATH = re.compile(r"""["'`][^"'`\n]*(?<![\w-])(tests?|__tests__|specs?)([/\\][^"'`\n]*)?["'`]|"""
                       r"""["'`][^"'`\n]*(test_\w+\.py|\w+_test\.(py|go)|\.(test|spec)\.[cm]?[jt]sx?|conftest\.py)["'`]""")
# name, verdict, where (product: not a test or test infrastructure; any: every
# file), the pattern, what it does.
CHEATS = [
    ("exit-zero", "red", "product",
     r"\bsys\.exit\(\s*(0|None|False)?\s*\)|\bos\._exit\s*\(|\bprocess\.exit\(\s*0?\s*\)|"
     r"(?<![\w.])(exit|quit)\(\s*0?\s*\)",
     "exits with success outside an entry point - a test run that reaches it passes without running"),
    ("skip-outside-tests", "red", "product",
     r"\b(unittest\.)?SkipTest\b|\bpytest\.(skip|xfail)\s*\(|\bpytest\.mark\.(skip|skipif|xfail)\b",
     "skips tests from product code"),
    ("frame-read", "red", "product",
     r"\binspect\.(stack|currentframe|getouterframes|getinnerframes|trace)\s*\(|\bsys\._(getframe|current_frames)\s*\(",
     "reads the call stack - product code that looks at who is calling can tell a test from a user"),
    ("reads-tests", "red", "product", None,
     "product code opens a test file - an answer read from the test is not an answer"),
    ("report-patch", "red", "any",
     r"\bpytest_runtest_makereport\b|\bpytest_report_teststatus\b|\bTestReport\b|\b_pytest\.(reports|runner)\b|"
     r"\.outcome\s*=\s*['\"]passed|\bTestResult\.(addFailure|addError|wasSuccessful)\s*=[^=]",
     "rewrites how a test result is reported"),
    ("eq-always-true", "review", "any",
     r"\b__eq__\s*=\s*lambda[^:\n]*:\s*True\b|\bequals\s*\([^)]*\)\s*(:\s*\w+\s*)?\{\s*return\s+true\b",
     "an equality that is always true makes every assertion of equality pass"),
    ("framework-patch", "review", "any",
     r"\bObject\.defineProperty\(\s*(expect|jest|vi|assert|chai|it|test|describe|global|globalThis)\b|"
     r"(?<![\w.])(expect|assert|chai|jest|vi)\.\w+\s*=[^=]|\bunittest\.TestCase\.\w+\s*=[^=]|"
     r"\b(builtins\.)?__import__\s*=[^=]",
     "replaces part of the test framework"),
]
EQ_DEF = re.compile(r"^[ \t]*def[ \t]+__(eq|ne)__[ \t]*\([^)]*\)[^:\n]*:[ \t]*(?:#[^\n]*)?"
                    r"(?:\n(?:[ \t]*(?:#[^\n]*)?|[ \t]*(?:\"\"\"[\s\S]*?\"\"\"|'\'\'[\s\S]*?'\'\'))[ \t]*)*"
                    r"(?:\n[ \t]*|[ \t]*)return[ \t]+(True|False)[ \t]*(?:#[^\n]*)?$", re.M)
COMMENT = re.compile(r"^\s*(#|//|/\*|\*|--)")


def added_lines(p):
    """{line number: text} of what this task added to p, judged against HEAD
    (every line of a file HEAD does not have), and the file's text."""
    full = os.path.join(ROOT, p)
    try:
        if not os.path.isfile(full) or os.path.getsize(full) > 2000000:
            return {}, ""
    except OSError:
        return {}, ""
    text = read(full)
    if "\0" in text[:8192]:
        return {}, ""
    rc, _ = git("cat-file", "-e", "HEAD:./" + p)
    if rc != 0:
        return {i + 1: l for i, l in enumerate(text.splitlines())}, text
    rc, diff = git("diff", "HEAD", "-U0", "--no-color", "--no-ext-diff", "--", p)
    out, n, hunk = {}, 0, False
    for l in diff.splitlines():
        m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", l)
        if m:
            n, hunk = int(m.group(1)), True
        elif hunk and l.startswith("+"):
            out[n] = l[1:].rstrip("\r")
            n += 1
    return out, text


def cheat_allowed(allow, name, path):
    for a in allow:
        rule, _, glob = str(a).partition(":")
        if rule in (name, "*") and (not glob or covers([glob], path)):
            return True
    return False


def cheat_signatures(listed, check):
    """The cheat signatures in this task's added lines: (red, review), each a list
    of (path, line, name, why, text). check.cheat_allow ("rule" or "rule:glob")
    and check.entry_points (globs) are the developer's way out of a false hit."""
    test_re, _ = census_regexes(check)
    infra = re.compile(TEST_INFRA)
    allow = check.get("cheat_allow") or []
    entries = [str(g) for g in check.get("entry_points") or []]
    red, review = [], []
    for p in listed:
        if not CODE_FILE.search(p):
            continue
        added, text = added_lines(p)
        if not added:
            continue
        product = not (test_re.search(p) or infra.search(p))
        entry = bool(ENTRY_POINT.search(p) or covers(entries, p) or text.startswith("#!") or MAIN_GUARD.search(text))
        hits = []
        for no, line in sorted(added.items()):
            if COMMENT.match(line):
                continue
            for name, verdict, where, pattern, why in CHEATS:
                if where == "product" and not product or name == "exit-zero" and entry:
                    continue
                if pattern is None:
                    found = READ_CALL.search(line) and TEST_PATH.search(line)
                else:
                    found = re.search(pattern, line)
                if found:
                    hits.append((no, name, verdict, why, line.strip()))
        if p.endswith((".py", ".pyw")):
            for m in EQ_DEF.finditer(text):
                no = text.count("\n", 0, m.start()) + 1
                if no in added and (m.group(1), m.group(2)) in (("eq", "True"), ("ne", "False")):
                    hits.append((no, "eq-always-true", "review", CHEATS[5][4], added[no].strip()))
        for no, name, verdict, why, line in hits:
            if cheat_allowed(allow, name, p):
                continue
            (red if verdict == "red" else review).append((p, no, name, why, line[:160]))
    return red, review


def run_base():
    """The commit this run started from (run-start.json "head"), when git has
    it; else None."""
    try:
        sha = (json.loads(read(os.path.join(F, "run-start.json")) or "{}") or {}).get("head") or ""
    except ValueError:
        sha = ""
    if sha and git("cat-file", "-e", sha + "^{commit}")[0] == 0:
        return sha
    return None


# What the developer approved and the builder may not change: the task's
# acceptance and its exemptions. A builder writes its task file (Files touched,
# notes), so these are read from the task file as committed when the run
# started (factory-plan --start commits the board), else as committed in HEAD -
# never from the working tree.
APPROVED_KEYS = ("acceptance", "needs_human", "untested_ok", "allow_test_removal", "modifies_tests", "dependencies")
EXEMPTIONS = ("untested_ok", "allow_test_removal", "modifies_tests")
DECLARED = ("dependencies",)


def approved_frontmatter(task_id):
    """The task's frontmatter as committed at the run's base, else at HEAD; {}
    when no commit has the task file."""
    for base in [b for b in (run_base(), "HEAD") if b]:
        for col in ("backlog", "in-progress", "done", "blocked"):
            rc, text = git("show", "%s:./tasks/%s/%s.md" % (base, col, task_id))
            if rc == 0:
                return frontmatter(text)
    return {}


def unanchored_task(task_id):
    """True when this run planned the task (run-start.json "tasks") but no
    commit has its file, although git could hold it: the snapshot that anchors
    its approval did not happen."""
    try:
        planned = (json.loads(read(os.path.join(F, "run-start.json")) or "{}") or {}).get("tasks") or []
    except ValueError:
        planned = []
    if task_id not in planned or git("rev-parse", "--verify", "-q", "HEAD")[0] != 0:
        return False
    for col in ("in-progress", "backlog"):
        p = "tasks/%s/%s.md" % (col, task_id)
        if os.path.isfile(os.path.join(ROOT, p)):
            return git("check-ignore", "-q", "--", p)[0] != 0
    return False


def is_true(fm, key):
    return str(fm.get(key, "")).strip().lower() == "true"


def approval_changes(fm, approved):
    """Approved keys the working tree's task file changed: [(key, now, approved)].
    Only an exemption switched on or an acceptance rewritten counts; a builder
    turning an exemption off only makes its own check stricter."""
    out = []
    for key in EXEMPTIONS:
        if key == "modifies_tests":
            granted = modifies_tests_globs(approved)
            if "*" not in granted and set(modifies_tests_globs(fm)) - set(granted):
                out.append(key)
        elif is_true(fm, key) and not is_true(approved, key):
            out.append(key)
    granted = set(declared_dependencies(approved))
    if "*" not in granted and set(declared_dependencies(fm)) - granted:
        out.append("dependencies")
    if approved and fm.get("acceptance", "").strip() != approved.get("acceptance", "").strip():
        out.append("acceptance")
    return out


def modifies_tests_globs(fm):
    """Which of the tests HEAD has the task was approved to change:
    "modifies_tests: true" - any; "modifies_tests: [tests/api/*, conftest.py]" -
    those; anything else - none."""
    v = str(fm.get("modifies_tests", "")).strip()
    if v.lower() == "true":
        return ["*"]
    if v.startswith("[") and v.endswith("]"):
        return [g.strip().strip("'\"") for g in v[1:-1].split(",") if g.strip().strip("'\"")]
    return []


def covers(globs, path):
    """A glob covers a path it matches, or a directory the path is under."""
    p = npath(path)
    return any(g == "*" or fnmatch.fnmatchcase(p, g) or p.startswith(npath(g).rstrip("/") + "/") for g in globs)


def readonly_tests(paths):
    """Of these root-relative paths, the ones no agent may write now: a test
    file (check.test_files) or test infrastructure (TEST_INFRA) that HEAD has,
    which no task in progress was approved to change (modifies_tests, as
    approved). New tests and new infrastructure are always the agent's to
    write."""
    test_re, _ = census_regexes(load_config().get("check") or {})
    infra = re.compile(TEST_INFRA)
    cands = sorted({npath(p) for p in paths if p})
    cands = [p for p in cands if not p.startswith("../") and p != ".." and not os.path.isabs(p)
             and not re.match(r"^[A-Za-z]:", p) and (test_re.search(p) or infra.search(p))]
    if not cands:
        return []
    rc, out = git("ls-tree", "-r", "-z", "--name-only", "HEAD", "--", *cands)
    if rc != 0:
        return []
    in_head = set(x for x in out.split("\0") if x)
    hits = [p for p in cands if p in in_head]
    if not hits:
        return []
    globs = []
    lane = os.path.join(ROOT, "tasks", "in-progress")
    for name in sorted(os.listdir(lane)) if os.path.isdir(lane) else []:
        if name.endswith(".md"):
            globs += modifies_tests_globs(approved_frontmatter(name[:-3]))
    return [p for p in hits if not covers(globs, p)]


# How the tests run, where a project keeps it beside other things: a change to
# it changes what "green" means without touching a test.
TEST_CONFIG_SECTIONS = {"pyproject.toml": "tool.pytest.ini_options", "setup.cfg": "tool:pytest", "tox.ini": "pytest"}


def test_config_of(path, text):
    """The part of a package.json, pyproject.toml, setup.cfg or tox.ini that says
    how the tests run; None for any other file."""
    base = os.path.basename(path)
    if base == "package.json":
        try:
            d = json.loads(text or "{}")
        except ValueError:
            return text
        d = d if isinstance(d, dict) else {}
        scripts = d.get("scripts") if isinstance(d.get("scripts"), dict) else {}
        return json.dumps({"scripts.test": scripts.get("test"), "jest": d.get("jest"), "mocha": d.get("mocha"),
                           "vitest": d.get("vitest")}, sort_keys=True)
    section = TEST_CONFIG_SECTIONS.get(base)
    if not section:
        return None
    out, inside = [], False
    for line in (text or "").splitlines():
        st = line.strip()
        if st.startswith("[") and st.endswith("]"):
            inside = st[1:-1].strip() == section
            continue
        if inside and st and not st.startswith(("#", ";")):
            out.append(st)
    return "\n".join(out)


def test_config_changes(listed):
    """Listed files whose test configuration differs from HEAD's."""
    out = []
    for p in listed:
        if test_config_of(p, "") is None:
            continue
        rc, before = git("show", "HEAD:./" + p)
        if rc != 0:
            continue  # new: it changes nothing that was there
        now = read(os.path.join(ROOT, p))
        if test_config_of(p, before) != test_config_of(p, now):
            what = "scripts.test" if os.path.basename(p) == "package.json" else \
                "[%s]" % TEST_CONFIG_SECTIONS[os.path.basename(p)]
            out.append("%s %s" % (p, what))
    return out


# What the run is judged by: the gate and the factory's config. No task changes
# them. factory-plan --start records a digest of each in run-start.json; every
# check compares against it. config.json's hard_blocks is left out: the
# developer's own session sets it (/factory:bans), and it is not the gate.
PROTECTED = ("gates", ".factory/config.json")


# What an editor, a file browser or Python leaves beside a file: never the gate.
JUNK = re.compile(r"(^|/)(\.DS_Store|Thumbs\.db|desktop\.ini|__pycache__/.*|[^/]*\.pyc|[^/]*\.sw[a-p]|[^/]*~|\.#[^/]*)$",
                  re.I)


def protected_files():
    """The files under gates/ git would see (tracked, or new and not
    ignored), else every file there."""
    rc, out = git("ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "gates")
    if rc == 0:
        names = [p for p in out.split("\0") if p.strip()]
    else:
        names = [rel(os.path.join(d, n), ROOT) for d, _, ns in os.walk(os.path.join(ROOT, "gates")) for n in ns]
    return sorted({npath(p) for p in names if not JUNK.search(npath(p))})


def protected_digest():
    """{path: sha256} of every file under gates/ and of config.json."""
    out = {}
    for p in protected_files():
        try:
            with open(os.path.join(ROOT, p), "rb") as fh:
                out[p] = hashlib.sha256(fh.read()).hexdigest()
        except OSError:
            pass
    cfg = os.path.join(F, "config.json")
    if os.path.isfile(cfg):
        raw = read(cfg)
        try:
            data = json.loads(raw)
            if isinstance(data, dict):
                data.pop("hard_blocks", None)
            raw = json.dumps(data, sort_keys=True, separators=(",", ":"))
        except ValueError:
            pass
        out[".factory/config.json"] = hashlib.sha256(raw.encode("utf-8")).hexdigest()
    return out


def protected_changes(listed=()):
    """How the gate or the config differ from what the run started with: short
    reasons, empty when nothing did."""
    out = []
    mine = sorted(p for p in listed if any(p == x or p.startswith(x + "/") for x in PROTECTED))
    if mine:
        out.append("the task lists " + " ".join(mine))
    try:
        start = (json.loads(read(os.path.join(F, "run-start.json")) or "{}") or {}).get("protected")
    except ValueError:
        start = None
    if isinstance(start, dict):
        now = protected_digest()
        changed = sorted(p for p in set(start) | set(now) if start.get(p) != now.get(p))
        if changed:
            out.append("changed since the run started: " + " ".join(changed[:10]))
    return out


# Dependency manifests. A package a task adds is code nobody on the project
# wrote or reviewed, and a green suite says nothing about where it came from: a
# task changes a manifest only when its approved task file declares
# `dependencies: [name, ...]`. Lockfiles are left to the risk review
# (factory-risk): tools rewrite them on their own, so they say little about
# intent.
MANIFESTS = ("package.json", "deno.json", "pubspec.yaml", "requirements*.txt", "constraints*.txt", "pipfile",
             "pyproject.toml", "setup.py", "setup.cfg", "go.mod", "go.work", "cargo.toml", "*.csproj", "*.fsproj",
             "*.vbproj", "packages.config", "directory.packages.props", "gemfile", "*.gemspec", "build.gradle",
             "build.gradle.kts", "libs.versions.toml", "pom.xml", "composer.json", "package.swift", "podfile",
             "cartfile", "mix.exs", "vcpkg.json", "conanfile.txt", "conanfile.py")


def is_manifest(path):
    base = npath(path).rsplit("/", 1)[-1].lower()
    return any(fnmatch.fnmatchcase(base, m) for m in MANIFESTS)


def declared_dependencies(fm):
    """The packages a task may add, as its approved frontmatter names them:
    `dependencies: [a, b]`; `true` allows any; nothing, `[]` or `false` none."""
    raw = str(fm.get("dependencies", "") or "").strip()
    if raw.lower() == "true":
        return ["*"]
    if raw.lower() in ("", "false", "[]", "none"):
        return []
    return [d.strip().strip("\"'") for d in re.split(r"[,\s]+", raw.strip("[]")) if d.strip().strip("\"'")]


def file_digest(path):
    try:
        with open(os.path.join(ROOT, path), "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return ""


def dirty_manifests():
    """{path: sha256} of every dependency manifest that differs from HEAD."""
    return {p: file_digest(p) for p in sorted(dirty_paths()) if is_manifest(p)}


def manifest_changes(task_id, listed):
    """(mine, unowned, open_listing): the manifests this task lists that differ
    from HEAD; the ones that differ, no task in progress lists and were not
    already so when the run started; and whether another task in progress has
    listed nothing yet, so an unowned one may be its work."""
    dirty = dirty_manifests()
    if not dirty:
        return [], [], False
    claimed = {npath(p) for p in listed}
    mine = sorted(p for p in dirty if p in claimed)
    open_listing = False
    d = os.path.join(ROOT, "tasks", "in-progress")
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not name.endswith(".md") or name[:-3] == task_id:
            continue
        other = files_touched(read(os.path.join(d, name)))
        open_listing = open_listing or not other
        claimed.update(npath(p) for p in other)
    try:
        before = (json.loads(read(os.path.join(F, "run-start.json")) or "{}") or {}).get("manifests") or {}
    except ValueError:
        before = {}
    unowned = sorted(p for p, h in dirty.items() if p not in claimed and before.get(p) != h)
    return mine, unowned, open_listing


# A module the task adds that would be imported in place of a package - the
# local stub that makes a verification library say yes. Python resolves a
# top-level module before site-packages, so a new <name>.py or <name>/ at the
# top of the repo, of src/ or of a unit, named like a package the project
# depends on (or a guarded standard-library module), shadows it. Anything written under
# node_modules/ is a package nobody installed.
# The standard-library and test-tool names worth guarding: the ones a stub would
# take to make a check pass, and the two Python imports at startup. A project's
# own calendar/ or email/ package is its business; its own unittest.py is not.
GUARDED = ("unittest doctest importlib subprocess json re os typing pathlib logging inspect builtins "
           "site sitecustomize usercustomize pytest _pytest pluggy hypothesis").split()
SHADOW_EXEMPT = {"test", "tests", "__init__", "__main__", "conftest", "setup", "main", "app", "config"}


def python_names():
    """Module names a new top-level module must not take: the guarded ones,
    the project's declared Python dependencies, and what a local virtualenv
    has installed."""
    names = set(GUARDED)

    def add(dist):
        n = re.split(r"[\s<>=!~;\[(@]", dist.strip(), 1)[0].strip().lower().replace("-", "_").replace(".", "_")
        if n and not n.startswith("#"):
            names.add(n)

    for p in [x for x in os.listdir(ROOT) if fnmatch.fnmatchcase(x.lower(), "requirements*.txt")] if os.path.isdir(ROOT) else []:
        for line in read(os.path.join(ROOT, p)).splitlines():
            if line.strip() and not line.strip().startswith(("#", "-")):
                add(line)
    pyproject = read(os.path.join(ROOT, "pyproject.toml"))
    m = re.search(r"(?ms)^dependencies\s*=\s*\[(.*?)\]", pyproject)
    for dist in re.findall(r"[\"']([^\"']+)[\"']", m.group(1)) if m else []:
        add(dist)
    m = re.search(r"(?ms)^\[tool\.poetry\.dependencies\]\s*$(.*?)(^\[|\Z)", pyproject)
    for line in m.group(1).splitlines() if m else []:
        if "=" in line and not line.strip().startswith("#"):
            add(line.split("=", 1)[0])
    for venv in (".venv", "venv", "env"):
        for sp in [os.path.join(ROOT, venv, "Lib", "site-packages")] + sorted(
                os.path.join(ROOT, venv, "lib", d, "site-packages")
                for d in (os.listdir(os.path.join(ROOT, venv, "lib")) if os.path.isdir(os.path.join(ROOT, venv, "lib")) else [])):
            for n in os.listdir(sp) if os.path.isdir(sp) else []:
                if n.endswith((".dist-info", ".egg-info", ".pth")) or n.startswith("_distutils"):
                    continue
                names.add((n[:-3] if n.endswith(".py") else n).lower())
    return names - SHADOW_EXEMPT


def shadow_modules(listed, units):
    """[(path, reason)] for the new files this task adds that shadow a package."""
    roots = {"", "src", "lib"} | {p for u in (units or []) for p in u["paths"]}
    out, names = [], None
    for p in sorted({npath(x) for x in listed}):
        if not os.path.exists(os.path.join(ROOT, p)) or git("cat-file", "-e", "HEAD:./" + p)[0] == 0:
            continue
        if "node_modules" in p.split("/"):
            out.append((p, "it is under node_modules/, where only the package manager writes"))
            continue
        if not p.endswith(".py"):
            continue
        head, _, base = p.rpartition("/")
        if base == "__init__.py":
            head, _, name = head.rpartition("/")
        else:
            name = base[:-3]
        if head not in roots:
            continue
        names = python_names() if names is None else names
        if name.lower() in names:
            out.append((p, "a top-level module named %s is imported in place of the package of that name" % name))
    return out


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
        self.log_rel = ".factory/logs/%s.%d.log" % (label, n)
        self.log = open(os.path.join(ROOT, self.log_rel), "w", encoding="utf-8")
        self.lines, self.failed, self.sig_text, self.raw = [], [], [], []
        self.cwd, self.isolated = ROOT, False  # see isolated()

    def step(self, name, cmd):
        self.log.write("### %s: %s\n" % (name, cmd))
        self.log.flush()
        started = time.time()
        try:
            r = subprocess.run([bash(), "-c", cmd], cwd=self.cwd, capture_output=True, text=True, errors="replace")
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

    def fail(self, name, detail, excerpt="", raw=None):
        self.lines.append("  %-8s FAIL%s" % (name, " (%s)" % detail if detail else ""))
        self.failed.append((name, excerpt))
        if raw:
            self.raw.append(raw)
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
        run.fail(name, "exit %d" % rc, excerpt(out), raw=out)
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


def work_fingerprint(task_id):
    """A hash of the content of every file the task lists under "## Files touched".
    The signature alone cannot tell "nothing changed" from "most of it is fixed":
    it drops line numbers and counts, so four identical errors fixed out of five
    still read as the same failure. Empty when the task lists nothing readable."""
    path = ""
    for col in ("in-progress", "backlog"):
        cand = os.path.join(ROOT, "tasks", col, task_id + ".md")
        if os.path.isfile(cand):
            path = cand
            break
    if not path:
        return ""
    h = hashlib.sha256()
    seen = 0
    for rel in sorted(set(files_touched(read(path)))):
        full = os.path.join(ROOT, rel)
        try:
            with open(full, "rb") as fh:
                h.update(rel.encode("utf-8") + b"\0" + fh.read() + b"\0")
            seen += 1
        except OSError:
            h.update(rel.encode("utf-8") + b"\0missing\0")
    return h.hexdigest()[:12] if seen else ""


def record_failure(task_id, text):
    fail_dir = os.path.join(F, "failures")
    os.makedirs(fail_dir, exist_ok=True)
    sig = failure_signature(text)
    sha = hashlib.sha256(sig.encode("utf-8")).hexdigest()[:12]
    sig_file = os.path.join(fail_dir, "sig-%s.txt" % sha)
    if not (os.path.exists(sig_file) and os.path.getsize(sig_file) > 0):
        with open(sig_file, "w", encoding="utf-8") as fh:
            fh.write(sig + "\n")
    work = work_fingerprint(task_id)
    hist = os.path.join(fail_dir, task_id + ".log")
    past = read(hist)
    # The same signature is "no progress" only when the task's own files are also
    # unchanged since that attempt. A history line without a fingerprint (written
    # before 3.1, or a task that lists no files) keeps the old rule.
    repeat = False
    for line in past.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] == sha:
            before = next((p[5:] for p in parts if p.startswith("work=")), "")
            if not work or not before or before == work:
                repeat = True
                break
    attempt = len([l for l in past.splitlines() if l.strip()]) + 1
    with open(hist, "a", encoding="utf-8") as fh:
        fh.write("%s %s attempt=%d%s\n" % (now_iso(), sha, attempt, " work=" + work if work else ""))
    if repeat:
        os.makedirs(os.path.join(F, "no-progress"), exist_ok=True)
        with open(os.path.join(F, "no-progress", task_id), "w", encoding="utf-8") as fh:
            fh.write("signature=%s\nattempt=%d\ndetail=.factory/failures/sig-%s.txt\n" % (sha, attempt, sha))
    return sha, attempt, repeat


def files_fingerprint(listed):
    """One digest of the task's listed files as they are now - each path with its
    bytes, or as gone. The marker keeps it; factory-land computes it again, so a
    file changed after the green check is not committed as checked."""
    import hashlib
    h = hashlib.sha256()
    for p in sorted(set(listed)):
        full = os.path.join(ROOT, p)
        h.update(p.encode("utf-8") + b"\0")
        if os.path.isfile(full):
            with open(full, "rb") as fh:
                h.update(hashlib.sha256(fh.read()).hexdigest().encode())
        elif os.path.isdir(full):
            h.update(b"dir")
        else:
            h.update(b"gone")
        h.update(b"\n")
    return h.hexdigest()


def tree_hash():
    try:
        r = subprocess.run([bash(), os.path.join(HOOK_DIR, "factory-gate-skip.sh"), "hash", ROOT],
                           capture_output=True, text=True)
        return r.stdout.strip() or "unknown"
    except OSError:
        return "unknown"


TEXT_READERS = {"grep", "egrep", "fgrep", "rg", "cat", "test", "[", "head", "tail", "wc", "awk", "sed", "diff",
                "cmp", "ls", "echo", "printf", "true", "stat", "file", "find"}


def self_certifying(acc):
    """An acceptance command whose only evidence is a file the agent writes
    itself: it names a markdown file (decisions.md, a task file, notes.md), and
    every command in it only reads text. Nothing about any language - a command
    that runs anything else is taken as running the code. factory-lint asks the
    same question through "factory-check selfcert"."""
    if not acc or not re.search(r"\.(md|markdown)\b", acc, re.I):
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


def dirty_paths():
    """Project-relative paths that differ from HEAD or are untracked."""
    rc, prefix = git("rev-parse", "--show-prefix")
    if rc != 0:
        return set()
    prefix = prefix.strip()
    rc, out = git("status", "--porcelain", "-z", "--untracked-files=all", "--", ".")
    if rc != 0:
        return set()
    paths, parts, i = set(), out.split("\0"), 0
    while i < len(parts):
        entry = parts[i]
        i += 1
        if len(entry) < 4:
            continue
        status, path = entry[:2], entry[3:]
        if status[0] in "RC":  # a rename carries its source as the next field
            i += 1
        if prefix and path.startswith(prefix):
            path = path[len(prefix):]
        paths.add(npath(path))
    return paths


def untracked_paths():
    """Project-relative paths git does not track and does not ignore."""
    rc, out = git("ls-files", "--others", "--exclude-standard", "-z", "--", ".")
    return [npath(p) for p in out.split("\0") if p] if rc == 0 else []


def stray_untracked(task_id, listed, units, check):
    """Untracked files inside the units this task's files belong to that its
    "## Files touched" does not name - the generated migration, the new file
    nobody listed, and so left out of the task's commit. Files another task in
    progress lists are that task's. Returns (strays, open_listing): open_listing
    is true when another task in progress has listed nothing yet, so a stray
    could be its work and cannot be blamed on this one."""
    mine = {owner(npath(p), units)["name"] for p in listed if owner(npath(p), units)}
    if not mine:
        return [], False
    ignore = check.get("ignore") or DEFAULT_IGNORE
    claimed = {npath(p) for p in listed}
    open_listing = False
    d = os.path.join(ROOT, "tasks", "in-progress")
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not name.endswith(".md") or name[:-3] == task_id:
            continue
        other = files_touched(read(os.path.join(d, name)))
        open_listing = open_listing or not other
        claimed.update(npath(p) for p in other)
    strays = []
    for p in untracked_paths():
        if p in claimed or ignored(p, ignore) or p == "decisions.md" or p.split("/")[0] in (".factory", "tasks"):
            continue
        u = owner(p, units)
        if u and u["name"] in mine:
            strays.append(p)
    return sorted(strays), open_listing


def claude_md_over(paths, limit):
    """CLAUDE.md files longer than limit lines: [(path, lines)]. Every agent
    loads these on every turn, so their size is a per-token cost of the run."""
    over = []
    for p in paths:
        if os.path.basename(p) == "CLAUDE.md" and os.path.isfile(os.path.join(ROOT, p)):
            n = len(read(os.path.join(ROOT, p)).splitlines())
            if n > limit:
                over.append((p, n))
    return over


ERROR_LINE = re.compile(r"(?i)\b(error|errors|failed|failure|exception|fatal)\b|\[E\]")
# A Windows tool prints C:\p\lib\a.cs: the drive is part of the token.
PATH_TOKEN = re.compile(r"(?:(?<!\w)[A-Za-z]:[\\/])?[\w@+.\-/\\]+\.\w{1,10}")


def first_repo_file(line):
    """The first token on a line that names a file in this project. Compilers,
    linters and test runners all put the location of a problem there."""
    real = os.path.realpath(ROOT)
    for m in PATH_TOKEN.finditer(line):
        tok = m.group(0).strip("'\"()[],:").replace("\\", "/")
        inside = strip_root(tok, (real, ROOT))
        if inside is not None:
            tok = inside
        if tok.startswith("./"):
            tok = tok[2:]
        if tok and not os.path.isabs(tok) and os.path.isfile(os.path.join(ROOT, tok)):
            return npath(tok)
    return None


def foreign_blockers(outputs, listed):
    """When every error a failing stage points at is in a file another task has
    in flight - changed, not committed, not on this task's list - the failure is
    that task's, not this one's. Returns those files, or [] when any error is
    somewhere this task has to answer for."""
    dirty = dirty_paths()
    foreign = {p for p in dirty if p not in set(listed)}
    located = set()
    for out in outputs:
        for line in out.splitlines():
            if ERROR_LINE.search(line):
                f = first_repo_file(line)
                if f:
                    located.add(f)
    return sorted(located) if located and located <= foreign else []


def wait_for(files, deadline):
    """Blocks, spending nothing, until one of the files lands or changes."""
    def state():
        dirty = dirty_paths()
        out = {}
        for f in files:
            try:
                out[f] = (f in dirty, os.path.getmtime(os.path.join(ROOT, f)))
            except OSError:
                out[f] = (False, None)
        return out
    before = state()
    while time.time() < deadline:
        time.sleep(3)
        if state() != before:
            return True
    return False


def _link(src, dst):
    """dst points at src: a symlink, or on Windows without the right to make one,
    a directory junction. False when neither can be made."""
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


@contextlib.contextmanager
def isolated(run, cfg, listed=None, force=False, keep=(), label="isolate"):
    """"gate_isolation": true. HEAD checked out into a throwaway worktree with the
    project's git hooks off, the paths in "isolation_links" linked in from the
    main tree (what the build reads and nobody writes: node_modules, a venv), and
    for a task check the task's own files copied over it - exactly what the
    task's commit will hold. A neighbour's half-written file is not there to break
    the check, and a file the task leaves off its list is not there to save it.
    The stages of the run go there (run.cwd); off, nothing happens. force: on
    whatever the config says; keep: listed files that stay as HEAD has them."""
    if not force and cfg.get("gate_isolation") is not True:
        yield
        return
    rc, _ = git("rev-parse", "--verify", "-q", "HEAD")
    if rc != 0:
        run.note(label, "skipped - there is no commit to build a clean tree from yet")
        yield
        return
    parent = tempfile.mkdtemp(prefix="factory-wt-")
    tree = os.path.join(parent, "tree")
    links = []
    try:
        rc, _ = git("-c", "core.hooksPath=/dev/null", "worktree", "add", "--detach", "--quiet", tree, "HEAD")
        if rc != 0:
            run.fail(label, "could not check HEAD out into a worktree")
            yield
            return
        _, prefix = git("rev-parse", "--show-prefix")
        work = os.path.join(tree, prefix.strip())
        copied = 0
        for p in listed or []:
            if p in keep or os.path.isabs(p) or p == ".." or p.startswith(("../", ".factory/", ".git/")):
                continue
            src, dst = os.path.join(ROOT, p), os.path.join(work, p)
            if os.path.isdir(src):
                shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
            elif os.path.exists(src):
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
            elif os.path.isdir(dst):
                shutil.rmtree(dst, ignore_errors=True)  # listed but gone: the task deleted it
            elif os.path.lexists(dst):
                os.remove(dst)
            copied += 1
        extra = os.path.join("gates", "extra.sh")
        if os.path.isfile(os.path.join(ROOT, extra)) and not os.path.exists(os.path.join(work, extra)):
            os.makedirs(os.path.join(work, "gates"), exist_ok=True)
            shutil.copy2(os.path.join(ROOT, extra), os.path.join(work, extra))
        for link in cfg.get("isolation_links") or []:
            src, dst = os.path.join(ROOT, str(link)), os.path.join(work, str(link))
            if not os.path.exists(src) or os.path.lexists(dst):
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if _link(src, dst):
                links.append(dst)
            else:
                run.note(label, "could not link %s into the clean tree" % link)
        run.cwd = work
        if label == "isolate":  # the marker's isolated= is about the check's own stages
            run.isolated = True
            run.note(label, "HEAD%s, in a clean worktree" % (" + %d listed file(s)" % copied if listed is not None else ""))
        yield
    finally:
        run.cwd = ROOT
        # The links go first, by themselves: removing the tree must never reach
        # through one into the main tree.
        for dst in links:
            try:
                if os.path.isdir(dst) and not os.path.islink(dst):
                    os.rmdir(dst)  # a junction: rmdir drops the link, not what it points at
                else:
                    os.unlink(dst)
            except OSError:
                pass
        git("worktree", "remove", "--force", tree)
        shutil.rmtree(parent, ignore_errors=True)
        git("worktree", "prune")


def extra_stage(run, arg):
    """gates/extra.sh, the project's own stages: the last stage of every check,
    given the task id or --full. It is under gates/, so no task can change it."""
    if not os.path.isfile(os.path.join(ROOT, "gates", "extra.sh")):
        return None
    rc, out = run.step("extra", "bash gates/extra.sh " + shlex.quote(arg))
    if rc == 0:
        run.ok("extra")
    else:
        run.fail("extra", "gates/extra.sh exit %d" % rc, excerpt(out), raw=out)
    return rc == 0


def gate_mode(cfg):
    """full (the default): commands.test is required. staged (a greenfield board
    before its toolchain exists): a stage without a command is skipped, at least
    one stage has to run green, and min_tests holds once a test command is set."""
    return "staged" if (cfg.get("gate_mode") or "full") == "staged" else "full"


def tests_configured(commands, units):
    return bool(commands.get("test")) or bool(units and any(u.get("test") for u in units))


def changed_head_tests(listed, check):
    """The test files HEAD has that this task changed and kept: the ones an
    approved modifies_tests let it change."""
    test_re, _ = census_regexes(check)
    out = []
    for p in listed:
        if not test_re.search(p) or not os.path.isfile(os.path.join(ROOT, p)):
            continue
        rc, _ = git("cat-file", "-e", "HEAD:./" + p)
        if rc == 0 and git("diff", "--quiet", "HEAD", "--", p)[0] == 1:
            out.append(p)
    return out


def frozen_suite(run, ctx):
    """A task that changed a test HEAD has (modifies_tests approved it): HEAD's
    version of that test, run against the task's code in a clean worktree. The
    test was the evidence the old behaviour was right; if the old test fails now,
    the change of behaviour is a reviewer's call, not the builder's - a review
    reason, never red."""
    check, commands, units = ctx["check"], ctx["commands"], ctx["units"]
    if check.get("frozen_suite", True) is False or not tests_configured(commands, units):
        return
    changed = changed_head_tests(ctx["listed"], check)
    if not changed:
        return
    reached, _ = (reach(changed, units, check.get("ignore") or DEFAULT_IGNORE) if units is not None
                  else (None, ""))
    targets = ([("suite", commands["test"])] if reached is None or not any(u["test"] for u in reached)
               else [(u["name"], u["test"]) for u in reached if u["test"]])
    targets = [t for t in targets if t[1]]
    if not targets:
        return
    failed = []
    with isolated(run, ctx["cfg"], ctx["listed"], force=True, keep=set(changed), label="frozen"):
        if run.cwd == ROOT:
            run.note("frozen", "skipped - no clean tree to run HEAD's tests in")
            return
        for name, cmd in targets:
            rc, _ = run.step("frozen %s" % name, cmd)
            if rc != 0:
                failed.append("%s exit %d" % (name, rc))
    if failed:
        why = ("HEAD's version of %s fails against this task's code (%s) - the task changed a test the old code "
               "passed" % (", ".join(changed[:5]), ", ".join(failed)))
        run.note("frozen", why)
        ctx["review"].append("frozen suite: " + why)
    else:
        run.note("frozen", "HEAD's version of %s still passes against the new code" % ", ".join(changed[:5]))


def run_stages(run, ctx):
    """format, then - in the clean tree when gate_isolation is on - build, lint,
    arch, the reached tests, the acceptance command and gates/extra.sh.
    Returns (tests_ran, counted)."""
    cfg, check, commands = ctx["cfg"], ctx["check"], ctx["commands"]
    existing, listed, acc = ctx["existing"], ctx["listed"], ctx["acc"]
    units = ctx["units"]
    tests_ran, counted = 0, False
    staged = gate_mode(cfg) == "staged"
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
        with isolated(run, cfg, listed):
            tests_ran, counted, _ = _task_stages(run, ctx, existing, listed, acc, units, reached, why, paths, staged)
        if not run.failed:
            frozen_suite(run, ctx)
    return tests_ran, counted


def _task_stages(run, ctx, existing, listed, acc, units, reached, why, paths, staged):
    """Everything after format, where the run's steps run (run.cwd). Returns
    (tests_ran, counted, green stages)."""
    cfg, check, commands = ctx["cfg"], ctx["check"], ctx["commands"]
    tests_ran, counted, commands_run, green = 0, False, [], 0
    for stage in ("build", "lint", "arch"):
        if run.failed:
            break
        cmd = check.get(stage) if stage in check else commands.get(stage)
        if cmd and "{files}" in cmd and not existing:
            run.note(stage, "skipped (no touched file left to give it)")
        elif cmd:
            passed, _ = run_stage(run, stage, cmd, files=existing, paths=paths)
            green += 1 if passed else 0
            commands_run.append(fill(cmd, files=existing, paths=paths))

    if not run.failed:
        if not tests_configured(commands, units):
            targets = []
            if staged:
                run.note("tests", "skipped (no test command yet, gate_mode=staged)")
            else:
                run.fail("tests", "MISSING - gate_mode=full requires commands.test",
                         "the developer sets commands.test in .factory/config.json")
        elif reached is None and not commands.get("test"):
            targets = []
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
                run.fail("tests", "%s: exit %d" % (name, rc), excerpt(out), raw=out)
                break
        if not targets:
            counted = True  # nothing the change reaches has tests: zero ran, and that is known
        elif not run.failed:
            green += 1
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
                green += 1
                if n is not None:
                    tests_ran += n
                    counted = True
                run.ok("accept", "%d test(s)" % n if n else "")
            else:
                run.fail("accept", "exit %d" % rc, excerpt(out), raw=out)
    if not run.failed and extra_stage(run, ctx["task_id"]):
        green += 1
    if staged and not run.failed and not green:
        run.fail("staged", "nothing ran: staged mode needs at least one green stage",
                 "configure commands.build (or test, lint, arch) in .factory/config.json, or give the task an "
                 "acceptance command that runs something")
    return tests_ran, counted, green


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
    worktree_fm = frontmatter(text)
    approved = approved_frontmatter(task_id)
    tampered = approval_changes(worktree_fm, approved)
    unanchored = not approved and unanchored_task(task_id)
    # The approved values win; a task no commit has yet (an older board, never
    # snapshot) keeps its acceptance from the working tree and has no exemptions.
    fm = dict(worktree_fm)
    for key in APPROVED_KEYS:
        if approved:
            fm[key] = approved.get(key, "")
        elif key in EXEMPTIONS or key in DECLARED:
            fm[key] = ""
    listed = files_touched(text)
    ctx = {"cfg": cfg, "check": check, "commands": commands, "units": units, "listed": listed, "task_id": task_id,
           "existing": [p for p in listed if os.path.exists(os.path.join(ROOT, p))], "acc": fm.get("acceptance", "")}
    print("CHECK %s: %d file(s) touched" % (task_id, len(listed)))
    sys.stdout.flush()

    deadline = time.time() + float(check.get("foreign_wait", 120))
    waits = 0
    while True:
        run = Run(task_id)
        ctx["review"] = []
        # --- guards that cost nothing: always this task's own ----------------
        if tampered:
            run.fail("approval", "the task file changes what was approved: " + ", ".join(tampered),
                     "a task's acceptance and its exemptions (untested_ok, allow_test_removal, modifies_tests, "
                     "dependencies) are "
                     "the developer's, set before the run. Put them back as they were; if the task cannot pass "
                     "without the change, block it and say why")
        if unanchored:
            run.fail("approval", "the task file is in no commit, so what was approved cannot be told apart from "
                     "what a builder wrote",
                     "factory-plan --start commits the board when a run starts; commit the task file (or start the "
                     "run again) and check again")
        moved = protected_changes(listed)
        if moved:
            run.fail("protected", "what the run is judged by changed: " + "; ".join(moved),
                     "no task changes gates/ or .factory/config.json. Undo the change by editing the file back; "
                     "if the task needs it, block it and say why")
        if fm.get("needs_human", "").lower() != "true" and self_certifying(ctx["acc"]):
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
        test_globs = modifies_tests_globs(fm)
        if listed:
            how = [c for c in test_config_changes(listed) if not covers(test_globs, c.split(" ")[0])]
            if how:
                run.fail("census", "this task changes how the tests run: " + ", ".join(how),
                         "what makes the suite green is not the task's to change. Put it back as it is in HEAD; if "
                         "the task needs it, block it and say why - the developer approves it with modifies_tests "
                         "in the task file")
        if check.get("modifies_tests_guard") and listed:
            changed = {p: n for p, n in changed_assertions(listed, check).items() if not covers(test_globs, p)}
            if changed:
                run.fail("census", "this task changes existing assertions: " + ", ".join(
                             "%s (%d)" % (p, n) for p, n in sorted(changed.items())),
                         "a test that was green is not edited to pass. Fix the code. If the behaviour truly changed, "
                         "declare modifies_tests: true in the task file and commit that before the build")
        mine_deps, unowned_deps, open_deps = manifest_changes(task_id, listed)
        allowed = declared_dependencies(fm)
        if mine_deps and not allowed:
            run.fail("deps", "this task changes dependency manifest(s) its approved task file does not declare: "
                     + " ".join(mine_deps[:10]),
                     "a new or upgraded package is the developer's decision. Put the manifest back as it is in "
                     "HEAD and do without it; if the task cannot be done without the package, block it and name "
                     "the package and why - the developer approves it with dependencies: [name] in the task file")
        elif mine_deps:
            run.note("deps", "declared: %s (%s)" % (", ".join(allowed), " ".join(mine_deps[:5])))
        if unowned_deps:
            what = "dependency manifest(s) changed in the tree that no task lists: " + " ".join(unowned_deps[:10])
            if open_deps:
                run.note("deps", what + " - another task in progress has not listed its files yet")
            else:
                run.fail("deps", what,
                         "the check ran with them, but they are in no task's commit. If this task changed one, list "
                         "it (it has to be declared too); otherwise put it back as it is in HEAD")
        for p, why in shadow_modules(listed, units) if listed else []:
            run.fail("deps", "%s shadows a package: %s" % (p, why),
                     "give the module a name no package or standard-library module has, and import the real "
                     "package where the task needs it")
        if listed and check.get("cheat_guard", True) is not False:
            red, review = cheat_signatures(listed, check)
            if red:
                run.fail("cheat", "a cheat signature in the change: " + ", ".join(
                             "%s:%d %s" % (p, no, name) for p, no, name, _, _ in red[:8]),
                         "\n".join("  %s:%d %s - %s\n      %s" % (p, no, name, why, line)
                                   for p, no, name, why, line in red[:8]) +
                         "\nThese make a suite pass without the code working. Take it out. If it is right here (a "
                         "command's own exit, a pytest plugin), do not work around it: block the task and say why - "
                         "the developer allows it with check.cheat_allow or check.entry_points in .factory/config.json")
            for p, no, name, why, line in review:
                ctx["review"].append("cheat signature %s at %s:%d - %s" % (name, p, no, why))
            if review:
                run.note("cheat", "%d for a reviewer: %s" % (len(review), ", ".join(
                    "%s:%d %s" % (p, no, name) for p, no, name, _, _ in review[:5])))
        limit = int(check.get("claude_md_max_lines", 200) or 0)
        for p, n in claude_md_over(listed, limit) if limit and listed else []:
            run.fail("claude_md", "%s is %d lines, the limit is %d" % (p, n, limit),
                     "every agent loads CLAUDE.md on every turn: move reference material into docs/ and "
                     "leave a pointer (check.claude_md_max_lines changes the limit, 0 turns it off)")
        if listed and units is not None and check.get("untracked_guard", True) is not False:
            strays, open_listing = stray_untracked(task_id, listed, units, check)
            if strays and open_listing:
                run.note("untracked", "%s - not listed, but another task in progress has not listed its files yet"
                         % " ".join(strays[:5]))
            elif strays:
                run.fail("untracked", "untracked file(s) in this task's unit that \"## Files touched\" does not name: "
                         + " ".join(strays[:10]),
                         "a file the list leaves out is left out of the task's commit. Add each one that belongs to "
                         "this change to the list, and delete the ones that do not")
        guarded = bool(run.failed)

        tests_ran, counted = (0, False) if guarded else run_stages(run, ctx)
        min_tests = int(cfg.get("min_tests", 1) or 1)
        if not run.failed and counted and tests_ran < min_tests and tests_configured(commands, units):
            if fm.get("untested_ok", "").lower() == "true":
                run.note("tests", "no test exercised this change - waived by untested_ok")
            else:
                run.fail("tests", "no test exercised this change (%d ran, minimum %d)" % (tests_ran, min_tests),
                         "none of the tests the check ran covers what this task changed. Add the tests the "
                         "acceptance criteria describe, or put the test that covers it in the acceptance command.")
        if not run.failed and not counted and check.get("count"):
            run.fail("tests", "check.count is set and matched nothing in the test output",
                     "the tests ran, but their count could not be read, so \"no test ran\" cannot be told apart "
                     "from \"the regex is wrong\". Fix check.count for this runner's summary line.")
        run.close()

        blockers = foreign_blockers(run.raw, listed) if run.failed and not guarded and run.raw else []
        if not blockers:
            break
        # Another task's half-written work, not this task's failure: nothing is
        # recorded against this task, and the check waits - outside the lock, so
        # the other task can finish - for that work to land or change.
        waits += 1
        print("  waiting  the failure is in work another task has in flight: %s" % " ".join(blockers[:5]))
        sys.stdout.flush()
        if time.time() >= deadline or waits > 3 or not wait_for(blockers, deadline):
            for line in run.lines:
                print(line)
            print("--- full log: %s" % run.log_rel)
            print("CHECK RESULT: WAITING for %s - the failure is in work another task has in flight (%s). "
                  "Nothing here is this task's to fix: change nothing, and report that the task is waiting."
                  % (task_id, " ".join(blockers[:5])))
            return 3

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
        # review=: what a reviewer has to see before this lands (factory-risk
        # reads it). In the marker, which no agent may write.
        fh.write("%s\n%sisolated=%s\ncheck=fast\ncommit=%s\ntree=%s\nfiles=%s\n%s"
                 % (now_iso(), "tests=%d\n" % tests_ran if counted else "", "yes" if run.isolated else "no",
                    head.strip() or "unknown", tree_hash(), files_fingerprint(listed),
                    "".join("review=%s\n" % r.replace("\n", " ") for r in ctx["review"])))
    hist = os.path.join(F, "failures", task_id + ".log")
    if os.path.exists(hist):
        os.makedirs(os.path.join(F, "failures", "resolved"), exist_ok=True)
        os.replace(hist, os.path.join(F, "failures", "resolved", task_id + ".log"))
    np = os.path.join(F, "no-progress", task_id)
    if os.path.exists(np):
        os.remove(np)
    if ctx["review"]:
        print("CHECK RESULT: GREEN for %s (marker written) - and %d reason(s) for a reviewer: factory-risk %s "
              "names them" % (task_id, len(ctx["review"]), task_id))
        return 0
    print("CHECK RESULT: GREEN for %s (marker written)" % task_id)
    return 0


# ---------------------------------------------------------------------------
# the whole tree
# ---------------------------------------------------------------------------


def check_full():
    cfg = load_config()
    check = cfg.get("check") or {}
    commands = cfg.get("commands") or {}
    full_mode = gate_mode(cfg) == "full"
    run = Run("full")
    tests_ran = None
    green = 0
    with Lock("check"), isolated(run, cfg):
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
            green += 1
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
        if extra_stage(run, "--full"):
            green += 1
        full_isolated = run.isolated
        if not full_mode and not green and not run.failed:
            run.fail("staged", "nothing ran: staged mode needs at least one green stage",
                     "configure commands.build (or test, lint, arch) in .factory/config.json")

    # The run as a whole may not have lost tests either: HEAD now against HEAD
    # when the run was planned.
    start = {}
    try:
        start = json.loads(read(os.path.join(F, "run-start.json")) or "{}")
    except ValueError:
        pass
    now = head_census(check)
    if start and now:
        # A task that declared allow_test_removal - in the approved task file,
        # not the working tree - answers for its own files only.
        allowed = set()
        for tid in start.get("tasks", []):
            p, _ = task_file(tid)
            text = read(p) if p else ""
            if is_true(approved_frontmatter(tid), "allow_test_removal"):
                allowed.update(files_touched(text))
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

    moved = protected_changes()
    if moved:
        run.fail("protected", "what the run is judged by changed: " + "; ".join(moved),
                 "no task changes gates/ or .factory/config.json: find the change (git log -- gates .factory/config.json) "
                 "and undo it before this run's work is trusted")

    limit = int(check.get("claude_md_max_lines", 200) or 0)
    if limit:
        rc, tracked = git("ls-files", "--", "CLAUDE.md", "*/CLAUDE.md")
        over = claude_md_over([p for p in tracked.splitlines() if p], limit) if rc == 0 else []
        if over:
            run.fail("claude_md", "over %d lines: %s" % (limit, ", ".join("%s (%d)" % o for o in over[:5])),
                     "every agent loads CLAUDE.md on every turn: move reference material into docs/ "
                     "(check.claude_md_max_lines changes the limit, 0 turns it off)")
        else:
            run.ok("claude_md", "no CLAUDE.md over %d lines" % limit)

    run.close()
    for line in run.lines:
        print(line)
    verdict = "red" if run.failed else "green"
    with open(os.path.join(F, "full-check"), "w", encoding="utf-8") as fh:
        fh.write("verdict=%s\nat=%s\ntests=%s\nisolated=%s\ntree=%s\nlog=%s\n"
                 % (verdict, now_iso(), tests_ran if tests_ran is not None else "unknown",
                    "yes" if full_isolated else "no", tree_hash(), run.log_rel))
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
    if argv and argv[0] == "selfcert":
        # For factory-lint: exit 0 when the acceptance command is self-certifying.
        return 0 if self_certifying(" ".join(argv[1:])) else 1
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
        reached, why = reach([npath(p) for p in argv[1:]], units, check.get("ignore") or DEFAULT_IGNORE)
        if reached is None:
            print("ALL " + why)
        else:
            for u in reached:
                print("%s %s" % (u["name"], u["path"]))
        return 0
    if argv[0] == "readonly":
        # The test files and test infrastructure among these paths that HEAD has
        # and no task in progress may change: one per line, exit 1 when any.
        hits = readonly_tests(argv[1:])
        for p in hits:
            print(p)
        return 1 if hits else 0
    if argv[0] == "fingerprint" and len(argv) == 2:
        # For factory-land: the task's listed files as they are now.
        path, _ = task_file(argv[1])
        if not path:
            print("CHECK: no task file for %s under tasks/" % argv[1])
            return 2
        print(files_fingerprint(files_touched(read(path))))
        return 0
    if argv[0] == "count":
        # For gates/verify.sh: the number of tests a run reported, by check.count
        # or the plain-English defaults; nothing when it cannot tell.
        n = count_tests(read(argv[1]) if len(argv) > 1 else sys.stdin.read(), load_config().get("check") or {})
        if n is not None:
            print(n)
        return 0
    if argv[0] == "census":
        c = head_census(load_config().get("check") or {})
        if c:
            c["protected"] = protected_digest()
            c["manifests"] = dirty_manifests()
        print(json.dumps(c) if "--json" in argv else "HEAD %s: %s test file(s), %s suppression(s)"
              % (c["head"], c["test_files"], c["skipped"]) if c else "CENSUS: not a git repository")
        return 0 if c else 2
    return check_task(argv[0])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
