#!/usr/bin/env python3
"""Factory fast check. NOT a hook: the builder runs it once its task is written.

Usage (from the project root):
  factory-check <task-id>          the task's check - format, analyze, the tests
                                   the change reaches, the task's acceptance
  factory-check --full             the whole tree - analyze, format, every test;
                                   run once, when the board is built
  factory-check affected <path>... which test files a change to these paths reaches

Why this exists. The old gate ran build, the whole test suite, architecture
rules and lint on every task, and ran it again for the integrator: on a real
board the full suite ran two to four times per task while the model that asked
for it waited. Measured on a Flutter project, a single test file takes 1.6s, the
40-file suite 8.8s, and the same 40 files bundled into one entrypoint 2.5s - the
machine is not what is slow. What is slow is how often, and on what.

So a task is judged on what it touched:
  - format:   the touched Dart files are formatted in place, so a format finding
              is never a red gate again
  - analyze:  the touched files plus every file that imports them
  - tests:    the test files that transitively import a touched file (the import
              graph), bundled into one entrypoint when there is more than one
  - accept:   the task's own acceptance command, executed here rather than
              reported by the agent
and the whole tree is judged once, by --full, when every task has landed.

The guards of gates/verify.sh carry over unchanged in meaning: the marker is
removed before anything runs, a self-certifying acceptance is refused, the test
census may not shrink, a run that exercised no test is not green, and a failure
seen before on the same task is NO PROGRESS rather than another attempt.

What another task has half-written is not this task's to answer for. Files that
differ from HEAD but are not in this task's "## Files touched" list belong to
work still in flight; they are left out of the analysis and the test selection
here, and judged by --full once they have landed.

Stacks. Dart and Flutter projects (a pubspec.yaml) get all of the above with
built-in commands; "check" in .factory/config.json overrides any of them. Any
other stack without a "check" block is delegated to gates/verify.sh, so this
is safe to call everywhere.

Exit: 0 green, 1 red, 2 usage or setup error.
"""
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.getcwd()
F = os.path.join(ROOT, ".factory")

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
    """Leading --- block as a dict of raw strings; first copy of a key wins."""
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
    text = read(path)
    lines = text.split("\n")
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
    missing = ["%s: %s" % (k, v) for k, v in updates.items() if k not in seen]
    lines[end:end] = missing
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
                    p = word[0]
                    if p.startswith("./"):
                        p = p[2:]
                    out.append(p)
    return sorted(set(out))


def task_file(task_id):
    for col in ("in-progress", "backlog", "blocked", "done"):
        p = os.path.join(ROOT, "tasks", col, task_id + ".md")
        if os.path.isfile(p):
            return p, col
    return None, None


def git(*args):
    try:
        r = subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True, text=True)
        return r.returncode, r.stdout
    except OSError:
        return 1, ""


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
        paths.add(path)
    return paths


class Lock:
    """One flutter/dart toolchain run at a time per project. Two of them in one
    tree share .dart_tool and the build directory, and have been seen to kill
    each other's test process; a check lasts seconds, so waiting is cheap."""

    def __init__(self, name, stale_after=900):
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
# the Dart import graph
# ---------------------------------------------------------------------------

PRUNE = {".dart_tool", "build", ".git", ".factory", "node_modules", "Pods", ".symlinks",
         ".fvm", ".idea", ".vscode", "ios", "android", "macos", "linux", "windows", "web"}
DIRECTIVE = re.compile(r"^\s*(import|export|part)\b(?!\s+of\b)([^;]*);", re.M)
STRING = re.compile(r"""(['"])(.+?)\1""")
# A change here can reach any test: dependencies, analyzer rules, code generation,
# fixtures and assets a test may load by path.
ALL_TRIGGERS = re.compile(r"^(pubspec\.(yaml|lock)|analysis_options\.yaml|build\.yaml|l10n\.yaml|"
                          r"dart_test\.yaml|test/.*|assets/.*|lib/.*)$")
# Platform code and prose that no Dart test can observe.
NO_TESTS = re.compile(r"^(android|ios|macos|linux|windows|web|docs?|\.github)/|\.(md|txt)$")


def package_name():
    m = re.search(r"^name:\s*([A-Za-z0-9_]+)", read(os.path.join(ROOT, "pubspec.yaml")), re.M)
    return m.group(1) if m else ""


def dart_files():
    out = []
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in PRUNE and not (d.startswith(".") and d != ".")]
        for name in files:
            if name.endswith(".dart"):
                out.append(os.path.relpath(os.path.join(base, name), ROOT))
    return out


def build_graph():
    """rdeps[path] = files that import, export or include path as a part."""
    pkg = package_name()
    rdeps = {}
    files = dart_files()
    for src in files:
        text = read(os.path.join(ROOT, src))
        for m in DIRECTIVE.finditer(text):
            for q in STRING.finditer(m.group(2)):
                uri = q.group(2)
                if uri.startswith("dart:"):
                    continue
                if uri.startswith("package:"):
                    name, _, rest = uri[len("package:"):].partition("/")
                    if name != pkg:
                        continue
                    target = os.path.normpath(os.path.join("lib", rest))
                else:
                    target = os.path.normpath(os.path.join(os.path.dirname(src), uri))
                rdeps.setdefault(target, set()).add(src)
    return rdeps, files


def is_test(path):
    return path.startswith("test" + os.sep) and path.endswith("_test.dart")


def affected(changed, foreign=frozenset()):
    """Returns (test files, reached dart files, reason). test files is None when
    the change can reach any test and the whole suite has to run."""
    rdeps, files = build_graph()
    all_tests = sorted(p for p in files if is_test(p) and p not in foreign)
    for p in changed:
        if p.endswith(".dart"):
            continue
        if NO_TESTS.search(p):
            continue
        if ALL_TRIGGERS.match(p):
            return None, set(files) - set(foreign), "%s can reach any test" % p
    seen, todo = set(), [p for p in changed if p.endswith(".dart")]
    while todo:
        cur = todo.pop()
        if cur in seen or cur in foreign:
            continue
        seen.add(cur)
        todo.extend(rdeps.get(cur, ()))
    reached = {p for p in seen if os.path.exists(os.path.join(ROOT, p))}
    tests = sorted(p for p in reached if is_test(p))
    return tests, reached, "import graph"


# ---------------------------------------------------------------------------
# stacks and commands
# ---------------------------------------------------------------------------


def stack_commands(cfg):
    """Commands for this project, or None when this is not a Dart project and
    no "check" block says otherwise."""
    check = cfg.get("check") or {}
    pubspec = read(os.path.join(ROOT, "pubspec.yaml"))
    if not pubspec and not check:
        return None
    flutter = bool(re.search(r"sdk:\s*flutter", pubspec))
    runner = "flutter test --no-pub" if flutter else "dart test"
    cmds = {
        "stack": "flutter" if flutter else ("dart" if pubspec else "custom"),
        "format": "dart format {files}",
        "analyze": "dart analyze --fatal-infos {files}",
        "test": runner + " {tests}",
        "full_analyze": "flutter analyze" if flutter else "dart analyze --fatal-infos",
        "full_format": "dart format --output=none --set-exit-if-changed .",
        "full_test": runner + " {tests}",
        "bundle": flutter or bool(pubspec),
    }
    cmds.update({k: v for k, v in check.items()})
    return cmds


def fill(cmd, **lists):
    for key, items in lists.items():
        cmd = cmd.replace("{%s}" % key, " ".join(shlex.quote(i) for i in items))
    return cmd


class Run:
    """Collects the output of every step in one log; nothing but the summary and
    a failure excerpt reaches the agent that called the check."""

    def __init__(self, label):
        os.makedirs(os.path.join(F, "logs"), exist_ok=True)
        n = 1
        while os.path.exists(os.path.join(F, "logs", "%s.%d.log" % (label, n))):
            n += 1
        self.log_rel = os.path.join(".factory", "logs", "%s.%d.log" % (label, n))
        self.log = open(os.path.join(ROOT, self.log_rel), "w", encoding="utf-8")
        self.lines = []          # summary lines
        self.failed = []         # (step, excerpt)
        self.sig_text = []       # what the failure signature is computed from

    def step(self, name, cmd):
        self.log.write("### %s: %s\n" % (name, cmd))
        self.log.flush()
        try:
            r = subprocess.run(["bash", "-c", cmd], cwd=ROOT, capture_output=True, text=True)
            out, rc = (r.stdout or "") + (r.stderr or ""), r.returncode
        except OSError as err:
            out, rc = str(err), 127
        self.log.write(out + "\n")
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


RESULT = re.compile(r"(?:^|\s)\+(\d+)(?: ~(\d+))?(?: -(\d+))?: ")


def count_tests(out):
    """(passed, failed) from the last progress line of a dart/flutter reporter."""
    last = None
    for m in RESULT.finditer(out):
        last = m
    if not last:
        if re.search(r"No tests? (ran|were found|found)|no test files", out, re.I):
            return 0, 0
        return None, None
    return int(last.group(1)), int(last.group(3) or 0)


def excerpt(out, limit=60):
    """The part of a failing run worth reading: from the first failing test or
    error line onwards, capped. The full output is in the log."""
    lines = out.splitlines()
    start = next((i for i, l in enumerate(lines)
                  if re.search(r"\[E\]|error|Error:|Expected:|FAIL|Exception|failed", l)), max(0, len(lines) - limit))
    picked = [l for l in lines[start:] if not re.match(r"^\d\d:\d\d \+\d+(?: ~\d+)?: ", l)]
    if len(picked) > limit:
        picked = picked[:limit - 1] + ["... (%d more lines in the log)" % (len(picked) - limit + 1)]
    return "\n".join(picked)[:6000]


def run_tests(run, cmds, tests, label, bundle_ok):
    """Runs the given test files, bundled into one entrypoint when that is safe.
    Returns (ok, passed). A bundled failure is confirmed unbundled before it is
    reported, so a bundling artefact can never be the reason a task goes red."""
    if not tests:
        return True, 0
    bundled = None
    if bundle_ok and cmds.get("bundle") and len(tests) > 1 and not has_test_configs():
        bundled = write_bundle(label, tests, cmds.get("stack") == "flutter")
    if bundled:
        rc, out = run.step("tests (bundled)", fill(cmds["test"], tests=[bundled]))
        passed, failed = count_tests(out)
        try:
            os.remove(os.path.join(ROOT, bundled))
        except OSError:
            pass
        if rc == 0:
            return True, passed or 0
        run.log.write("### bundled run failed - confirming unbundled\n")
    rc, out = run.step("tests", fill(cmds["test"], tests=tests))
    passed, failed = count_tests(out)
    if rc == 0:
        if bundled:
            run.note("tests", "bundled run failed but the files pass one by one - bundling skipped")
        return True, passed or 0
    run.fail("tests", "%s failed" % (failed if failed is not None else "some"), excerpt(out))
    return False, passed or 0


def has_test_configs():
    for base, dirs, files in os.walk(os.path.join(ROOT, "test")):
        if "flutter_test_config.dart" in files:
            return True
    return False


def write_bundle(label, tests, flutter):
    """One entrypoint importing every selected test file, each under a group
    named after it: one compile and one test process instead of one per file."""
    rel_dir = os.path.join(".dart_tool", "factory")
    os.makedirs(os.path.join(ROOT, rel_dir), exist_ok=True)
    rel = os.path.join(rel_dir, "bundle_%s.dart" % re.sub(r"[^A-Za-z0-9_]", "_", label))
    body = ["// Generated by factory-check; removed after the run.",
            "import 'package:%s' show group;" % ("flutter_test/flutter_test.dart" if flutter else "test/test.dart")]
    names = []
    for i, t in enumerate(tests):
        alias = "t%d" % i
        names.append((alias, t))
        body.append("import '%s' as %s;" % (os.path.relpath(t, rel_dir), alias))
    body.append("void main() {")
    for alias, t in names:
        body.append("  group('%s', () { %s.main(); });" % (t.replace("'", ""), alias))
    body.append("}")
    with open(os.path.join(ROOT, rel), "w", encoding="utf-8") as fh:
        fh.write("\n".join(body) + "\n")
    return rel


# ---------------------------------------------------------------------------
# the guards gates/verify.sh carries, with the same meaning
# ---------------------------------------------------------------------------

SELF_CERT = re.compile(r"decisions\.md|tasks/[^ ]*\.md")
RUNS_CODE = re.compile(r"(dotnet|npm|pnpm|yarn|npx|node|flutter|melos|dart|pytest|python3?|go test|cargo|mvn|"
                       r"gradle|gradlew|make|bash gates/|jest|vitest|rspec|phpunit|curl|psql|docker|factory-check)")
SKIP_RE = re.compile(r"\[Ignore\(|\(Skip\s*=|\.skip\(|(^|[^a-zA-Z])xit\(|(^|[^a-zA-Z])xdescribe\(|@Ignore([^a-zA-Z]|$)|"
                     r"@pytest\.mark\.skip|@unittest\.skip|(^|[^a-zA-Z])t\.Skip\(|#\[ignore\]|skip:\s*true|Assert\.Inconclusive")
CENSUS_PRUNE = {"node_modules", "bin", "obj", ".git", "build", ".dart_tool", "Pods", "vendor", "target",
                "dist", ".next", ".factory"}
CENSUS_NAME = re.compile(r"(Tests?\.cs|_test\.go|^test_.*\.py|_test\.py|_test\.dart|\.test\.[jt]sx?|"
                         r"\.spec\.[jt]sx?|_spec\.rb|Tests?\.java|_test\.rs)$")


def census(foreign=frozenset()):
    """Test files and suppression markers in the tree - leaving out another
    task's work in flight, which is counted when that task lands."""
    n_files = n_skips = 0
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in CENSUS_PRUNE]
        for name in files:
            if CENSUS_NAME.search(name) and os.path.relpath(os.path.join(base, name), ROOT) not in foreign:
                n_files += 1
                n_skips += sum(1 for line in read(os.path.join(base, name)).splitlines()
                               for _ in SKIP_RE.finditer(line))
    return n_files, n_skips


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
    """Same files and meaning as the gate's record_failure, so /factory:retro
    and the no-progress rule see both."""
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


# ---------------------------------------------------------------------------
# the task check
# ---------------------------------------------------------------------------


def acceptance_covered(acc, tests):
    """An acceptance that only runs test files the selection already ran adds
    nothing but its own startup time."""
    try:
        words = shlex.split(acc)
    except ValueError:
        return False
    if len(words) < 3 or words[0] not in ("flutter", "dart") or words[1] != "test":
        return False
    paths = [w for w in words[2:] if not w.startswith("-")]
    return bool(paths) and all(os.path.normpath(p) in tests for p in paths)


def check_task(task_id):
    cfg = load_config()
    path, col = task_file(task_id)
    if not path:
        print("CHECK: no task file for %s under tasks/" % task_id)
        return 2
    cmds = stack_commands(cfg)
    if cmds is None:
        return delegate_to_gate(task_id)

    marker = os.path.join(F, "verified", task_id)
    if os.path.exists(marker):
        os.remove(marker)
    if col == "in-progress":
        set_frontmatter(path, {"stage": "verifying", "stage_since": now_iso()})

    text = read(path)
    fm = frontmatter(text)
    listed = files_touched(text)
    run = Run(task_id)
    print("CHECK %s: %d file(s) touched" % (task_id, len(listed)))

    # --- guards that cost nothing ------------------------------------------
    acc = fm.get("acceptance", "")
    if fm.get("needs_human", "").lower() != "true" and acc and SELF_CERT.search(acc) and not RUNS_CODE.search(acc):
        run.fail("accept", "self-certifying: its only evidence is a file the agent writes itself",
                 "replace it with a command that runs the code, or mark the task needs_human: true")
    if not listed:
        run.fail("files", "the task lists nothing under \"## Files touched\"",
                 "list every file you created, changed or deleted, one \"- path\" per line, then run the check again")
    foreign = frozenset(p for p in dirty_paths() if p not in listed)
    n_files, n_skips = census(foreign)
    baseline = {}
    try:
        baseline = json.loads(read(os.path.join(F, "baseline.json")) or "{}")
    except ValueError:
        pass
    if baseline and fm.get("allow_test_removal", "").lower() != "true":
        if n_files < int(baseline.get("test_files", 0) or 0):
            run.fail("census", "test files went from %s to %d" % (baseline.get("test_files"), n_files),
                     "a suite does not get greener by losing tests; restore them")
        if n_skips > int(baseline.get("skipped", 0) or 0):
            run.fail("census", "suppressions went from %s to %d" % (baseline.get("skipped"), n_skips),
                     "skipping the failing test is not fixing it; remove the skip")

    tests_ran = 0
    if not run.failed:
        existing = [p for p in listed if os.path.exists(os.path.join(ROOT, p))]
        dart_listed = [p for p in existing if p.endswith(".dart")]

        with Lock("toolchain"):
            # format: fix, do not judge
            if dart_listed and cmds.get("format"):
                before = {p: read(os.path.join(ROOT, p)) for p in dart_listed}
                rc, out = run.step("format", fill(cmds["format"], files=dart_listed))
                changed = sum(1 for p in dart_listed if read(os.path.join(ROOT, p)) != before[p])
                if rc == 0:
                    run.ok("format", "%d file(s) reformatted" % changed if changed else "")
                else:
                    run.fail("format", "the formatter could not parse a file", excerpt(out))

            selected, reached, why = affected(listed, foreign) if not run.failed else ([], set(), "")
            whole = selected is None
            if whole:
                rdeps, files = build_graph()
                selected = sorted(p for p in files if is_test(p) and p not in foreign)
                run.note("select", "whole suite: %s" % why)

            # analyze: the touched files and everything that imports them
            if not run.failed and cmds.get("analyze"):
                targets = sorted(p for p in (set(dart_listed) | reached) if p.endswith(".dart")
                                 and os.path.exists(os.path.join(ROOT, p)) and p not in foreign)
                if whole or len(targets) > 300:
                    targets = ["."]  # the whole package: cheaper than a huge argument list
                if targets:
                    rc, out = run.step("analyze", fill(cmds["analyze"], files=targets))
                    if rc == 0:
                        run.ok("analyze", "%d file(s)" % len(targets))
                    else:
                        run.fail("analyze", "", excerpt(out, 40))

            # tests the change reaches
            if not run.failed and selected:
                ok, passed = run_tests(run, cmds, selected, task_id, bundle_ok=True)
                if ok:
                    tests_ran += passed
                    run.ok("tests", "%d test(s) in %d file(s)" % (passed, len(selected)))

            # the task's own acceptance, run here rather than reported
            if not run.failed and acc:
                if re.search(r"verify\.sh|factory-check", acc):
                    run.note("accept", "skipped (it names the gate itself)")
                elif acceptance_covered(acc, set(selected)):
                    run.ok("accept", "covered by the selected tests")
                else:
                    rc, out = run.step("accept", acc)
                    passed, _ = count_tests(out)
                    if rc == 0:
                        tests_ran += passed or 0
                        run.ok("accept", "%d test(s)" % passed if passed else "")
                    else:
                        run.fail("accept", "exit %d" % rc, excerpt(out))

        min_tests = int(cfg.get("min_tests", 1) or 1)
        untested_ok = fm.get("untested_ok", "").lower() == "true"
        if not run.failed and dart_listed and tests_ran < min_tests and untested_ok:
            run.note("tests", "no test reaches this change - waived by untested_ok")
        elif not run.failed and dart_listed and tests_ran < min_tests:
            run.fail("tests", "no test exercised this change (%d ran, minimum %d)" % (tests_ran, min_tests),
                     "no test file imports the files this task changed. Add tests for them, or put the test "
                     "that covers them in the acceptance command.")

    run.close()
    for line in run.lines:
        print(line)
    print("  %-8s %d test file(s), %d suppression(s)" % ("census", n_files, n_skips))

    if run.failed:
        for name, text_ in run.failed:
            if text_:
                print("--- %s ---" % name)
                print(text_)
        sha, attempt, repeat = record_failure(task_id, "\n".join(run.sig_text))
        print("--- full log: %s" % run.log_rel)
        if repeat:
            print("CHECK RESULT: RED for %s - NO PROGRESS (signature %s, attempt %d): this exact failure already "
                  "happened on this task. Change the approach, do not run the check again unchanged." % (task_id, sha, attempt))
        else:
            print("CHECK RESULT: RED for %s (signature %s, attempt %d)" % (task_id, sha, attempt))
        return 1

    os.makedirs(os.path.join(F, "verified"), exist_ok=True)
    _, head = git("rev-parse", "--short", "HEAD")
    with open(marker, "w", encoding="utf-8") as fh:
        fh.write("%s\ntests=%d\ntest_files=%d\nskipped=%d\nisolated=no\ncheck=fast\ncommit=%s\ntree=%s\n"
                 % (now_iso(), tests_ran, n_files, n_skips, head.strip() or "unknown", tree_hash()))
    with open(os.path.join(F, "baseline.json"), "w", encoding="utf-8") as fh:
        json.dump({"test_files": n_files, "skipped": n_skips, "updated": now_iso(), "by": task_id}, fh)
    hist = os.path.join(F, "failures", task_id + ".log")
    if os.path.exists(hist):
        os.makedirs(os.path.join(F, "failures", "resolved"), exist_ok=True)
        os.replace(hist, os.path.join(F, "failures", "resolved", task_id + ".log"))
    np = os.path.join(F, "no-progress", task_id)
    if os.path.exists(np):
        os.remove(np)
    print("CHECK RESULT: GREEN for %s (marker written)" % task_id)
    return 0


def delegate_to_gate(task_id):
    """Not a Dart project and no "check" block: the project's own gate decides.
    Its output goes to the log; the agent sees the GATE lines."""
    gate = os.path.join(ROOT, "gates", "verify.sh")
    if not os.path.isfile(gate):
        print("CHECK: no pubspec.yaml, no \"check\" block in .factory/config.json and no gates/verify.sh")
        return 2
    run = Run(task_id)
    rc, out = run.step("gate", "bash gates/verify.sh %s" % shlex.quote(task_id))
    run.close()
    for line in out.splitlines():
        if line.startswith("GATE") or "NO PROGRESS" in line:
            print(line)
    if rc != 0:
        print("--- failure ---")
        print(excerpt(out))
        print("--- full log: %s" % run.log_rel)
        print("CHECK RESULT: RED for %s" % task_id)
        return 1
    print("CHECK RESULT: GREEN for %s (marker written by gates/verify.sh)" % task_id)
    return 0


# ---------------------------------------------------------------------------
# the whole tree
# ---------------------------------------------------------------------------


def check_full():
    cfg = load_config()
    cmds = stack_commands(cfg)
    run = Run("full")
    if cmds is None:
        c = cfg.get("commands") or {}
        steps = [(k, c.get(k)) for k in ("build", "test", "arch", "lint") if c.get(k)]
        for name, cmd in steps:
            rc, out = run.step(name, cmd)
            (run.ok(name) if rc == 0 else run.fail(name, "exit %d" % rc, excerpt(out)))
    else:
        with Lock("toolchain"):
            for name in ("full_format", "full_analyze"):
                if cmds.get(name):
                    rc, out = run.step(name, cmds[name])
                    label = name.replace("full_", "")
                    (run.ok(label) if rc == 0 else run.fail(label, "", excerpt(out, 40)))
            arch = (cfg.get("commands") or {}).get("arch")
            if arch:
                rc, out = run.step("arch", arch)
                (run.ok("arch") if rc == 0 else run.fail("arch", "", excerpt(out)))
            rdeps, files = build_graph()
            tests = sorted(p for p in files if is_test(p))
            full_cmds = dict(cmds, test=cmds.get("full_test") or cmds["test"])
            ok, passed = run_tests(run, full_cmds, tests, "full", bundle_ok=True)
            if ok:
                run.ok("tests", "%d test(s) in %d file(s)" % (passed, len(tests)))
    run.close()
    for line in run.lines:
        print(line)
    verdict = "red" if run.failed else "green"
    with open(os.path.join(F, "full-check"), "w", encoding="utf-8") as fh:
        fh.write("verdict=%s\nat=%s\ntree=%s\nlog=%s\n" % (verdict, now_iso(), tree_hash(), run.log_rel))
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
        print(__doc__.split("\n\n")[1])
        return 2
    if argv[0] == "--full":
        return check_full()
    if argv[0] == "affected":
        tests, reached, why = affected([os.path.normpath(p) for p in argv[1:]])
        if tests is None:
            print("ALL %s" % why)
        else:
            for t in tests:
                print(t)
        return 0
    return check_task(argv[0])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
