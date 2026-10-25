#!/usr/bin/env bash
# Sandbox tests: the fast lane - factory-check (units, reach, guards, the
# per-task census, no-progress, the full check), factory-plan, factory-start,
# factory-land, factory-block, factory-finish, and the telemetry fixes the loop
# relies on. The loop workflow's own schedule is tests/loop-cases.mjs.
#
# The project in the sandbox is written in no language at all: its "toolchain"
# is a handful of shell scripts, its tests are *.t files, and everything the
# check knows about it comes from .factory/config.json. That is the point - the
# check must work for any project whose config says how to build and test it.
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
. "$H/factory-compat.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${FACTORY_TEST_DIR:-$(mktemp -d)}"
export PATH="${PLUGIN}/bin:$PATH"
export FACTORY_NO_NOTIFY=1
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

mktask() {  # <column> <id> <depends> <acceptance> [files-touched...]
  local col="$1" id="$2" deps="$3" acc="$4"; shift 4
  mkdir -p "$P/tasks/$col"
  {
    echo "---"; echo "id: $id"; echo "title: task $id"; echo "module: core"
    echo "depends_on: [$deps]"; echo "acceptance: $acc"
    echo "needs_human: false"; echo "review: on-red"; echo "retries: 0"
    echo "owner:"; echo "stage: queued"; echo "stage_since:"; echo "---"
    echo; echo "## Goal"; echo "Do the thing."; echo
    echo "## Acceptance criteria"; echo "- [ ] it works"; echo
    echo "## Files touched"
    for f in "$@"; do echo "- $f"; done
    echo; echo "## Attempts"
  } > "$P/tasks/$col/$id.md"
}
setfm() {  # <file> <key> <value>
  sed -i.bak "s/^needs_human: false/needs_human: false\\
$2: $3/" "$1" && rm -f "$1.bak"
}

# --- a project in no language: core <- api <- ui, and tools with no tests ----
P="$WORK/poly"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
mkdir -p .factory/verified core/src core/tests api/src api/tests ui/src ui/tests tools tasks/backlog tasks/in-progress tasks/done tasks/blocked
: > .factory/active
for u in core api ui; do printf 'value\n' > $u/src/main.src; printf 'exit 0\n' > $u/tests/main.t; done
printf 'helper\n' > tools/gen.src
# The toolchain. Each script leaves a trace of how it was called.
cat > runner.sh <<'SH'
echo "runner $1" >> .factory/tool.log
n=0; bad=0
for t in $(find "$1" -name '*.t' -not -path './.factory/*' | sort); do
  n=$((n + 2)); bash "$t" || { bad=$((bad + 1)); echo "FAILED $t: expected <1>, actual <2>"; }
done
[ "$n" -eq 0 ] && { echo "no tests found"; exit 0; }
[ "$bad" -gt 0 ] && { echo "$((n - 2 * bad)) passed, $bad failed"; exit 1; }
echo "$n passed"
SH
cat > build.sh <<'SH'
echo "build" >> .factory/tool.log
bad="$(grep -rl BUILD_ERROR core api ui tools)"
[ -n "$bad" ] && { for f in $bad; do echo "$f:1:7: error: unexpected token"; done; echo "Build FAILED."; exit 1; }
exit 0
SH
cat > lint.sh <<'SH'
echo "lint" >> .factory/tool.log
grep -rn LINT_ERROR core api ui tools && exit 1; exit 0
SH
cat > fmt.sh <<'SH'
echo "$@" > .factory/fmt.args
for f in "$@"; do sed -i.bak 's/messy/tidy/' "$f" && rm -f "$f.bak"; done
SH
cat > .factory/config.json <<'JSON'
{ "gate_mode": "full", "min_tests": 1,
  "commands": { "build": "bash build.sh", "test": "bash runner.sh .", "arch": "", "lint": "bash lint.sh" },
  "check": {
    "format": "bash fmt.sh {files}",
    "unit_test": "bash runner.sh {path}",
    "test_files": "\\.t$", "skip": "SKIP",
    "units": [ {"name": "core", "path": "core", "deps": []},
               {"name": "api", "path": "api", "deps": ["core"]},
               {"name": "ui", "path": "ui", "deps": ["api"]},
               {"name": "tools", "path": "tools", "deps": [], "test": null} ] },
  "fast": { "workers": 3 } }
JSON
printf '.factory/\n' > .gitignore
git add -A; git commit -qm base
tools_log() { cat .factory/tool.log 2>/dev/null | tr '\n' ',' ; }

echo "=== units: what a change reaches"
out="$(factory-check units core/src/main.src)"
check "a change reaches its unit and everything that depends on it" '[ "$(printf "%s" "$out" | cut -d" " -f1 | tr "\n" " ")" = "core api ui " ]' "$out"
out="$(factory-check units ui/src/main.src)"
check "a leaf change reaches only its own unit" '[ "$out" = "ui ui" ]' "$out"
out="$(factory-check units README.md docs/guide.md)"
check "prose reaches nothing" '[ -z "$out" ]' "$out"
out="$(factory-check units settings.cfg)"
check "a file outside every unit reaches anything" 'printf "%s" "$out" | grep -q "^ALL settings.cfg belongs to no unit"' "$out"
jq '.check.units += [{"name":"split","paths":["lib/split","test/split"],"deps":["ui"],"test":"true"}]' .factory/config.json > c && mv c .factory/config.json
out="$(factory-check units test/split/x.t)"
check "a unit can own code and tests in separate trees" '[ "$out" = "split lib/split" ]' "$out"
out="$(factory-check units ui/src/main.src)"
check "and it is reached through its dependencies like any other" '[ "$(printf "%s" "$out" | cut -d" " -f1 | tr "\n" " ")" = "ui split " ]' "$out"
jq '.check.units |= map(select(.name != "split"))' .factory/config.json > c && mv c .factory/config.json

echo "=== the task check"
mktask in-progress T-01 "" "bash runner.sh core" core/src/main.src core/tests/main.t
printf 'value messy\n' > core/src/main.src; : > .factory/tool.log
out="$(factory-check T-01)"; rc=$?
check "green on a clean change" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "CHECK RESULT: GREEN for T-01"' "$out"
check "the marker says it came from the fast check" 'grep -q "^check=fast" .factory/verified/T-01 && ! grep -q "^tree=" .factory/verified/T-01 && grep -q "^tests=6" .factory/verified/T-01' "$(cat .factory/verified/T-01 2>/dev/null)"
check "only the touched files are handed to the formatter, and fixed" '[ "$(cat .factory/fmt.args)" = "core/src/main.src core/tests/main.t" ] && grep -q tidy core/src/main.src' "$(cat .factory/fmt.args)"
check "build and lint come from the project commands" 'tools_log | grep -q "^build,lint,"' "$(tools_log)"
check "the tests of the touched unit and its dependents run, nothing else" 'tools_log | grep -q "runner core,runner api,runner ui,$"' "$(tools_log)"
check "an acceptance identical to a command already run is not run twice" 'printf "%s" "$out" | grep -q "accept   PASS (already ran above)"' "$out"
check "the summary stays short" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" -le 10 ]' "$out"
check "stage is stamped verifying" 'grep -q "^stage: verifying" tasks/in-progress/T-01.md'

echo "=== without units, or past max_units, the whole suite runs once"
jq '.check.max_units = 2' .factory/config.json > c && mv c .factory/config.json; : > .factory/tool.log
out="$(factory-check T-01)"
check "three units with tests over a limit of two run the suite once" '[ "$(tools_log)" = "build,lint,runner .,runner core," ]' "$(tools_log) / $out"
jq 'del(.check.max_units) | del(.check.units)' .factory/config.json > c && mv c .factory/config.json; : > .factory/tool.log
out="$(factory-check T-01)"; rc=$?
check "no units declared: commands.test runs, as the gate would" '[ $rc -eq 0 ] && tools_log | grep -q "runner \.,"' "$(tools_log) / $out"
git checkout -q .factory/config.json 2>/dev/null || true
jq '.check.units = "printf %s \"[{\\\"name\\\":\\\"all\\\",\\\"path\\\":\\\".\\\",\\\"deps\\\":[]}]\""' .factory/config.json > c && mv c .factory/config.json
out="$(factory-check units core/src/main.src)"
check "units can be printed by a command instead of listed" '[ "$out" = "all ." ]' "$out"
cat > .factory/config.json <<'JSON'
{ "gate_mode": "full", "min_tests": 1,
  "commands": { "build": "bash build.sh", "test": "bash runner.sh .", "arch": "", "lint": "bash lint.sh" },
  "check": {
    "format": "bash fmt.sh {files}", "unit_test": "bash runner.sh {path}", "test_files": "\\.t$", "skip": "SKIP",
    "units": [ {"name": "core", "path": "core", "deps": []}, {"name": "api", "path": "api", "deps": ["core"]},
               {"name": "ui", "path": "ui", "deps": ["api"]}, {"name": "tools", "path": "tools", "deps": [], "test": null} ] },
  "fast": { "workers": 3 } }
JSON

echo "=== red, then the same red again"
printf 'exit 1\n' > core/tests/main.t
out="$(factory-check T-01)"; rc=$?
check "a failing test is red with an excerpt" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "expected <1>, actual <2>" && printf "%s" "$out" | grep -q "CHECK RESULT: RED for T-01 (signature"' "$out"
check "a red check leaves no marker" '[ ! -f .factory/verified/T-01 ]'
check "the full output goes to a log, not the caller" 'printf "%s" "$out" | grep -q "full log: .factory/logs/T-01."' "$out"
out="$(factory-check T-01)"; rc=$?
check "the identical failure twice is NO PROGRESS" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "NO PROGRESS" && [ -f .factory/no-progress/T-01 ]' "$out"
printf 'value edited\n' >> core/src/main.src
out="$(factory-check T-01)"; rc=$?
check "the same failure after the task's own files changed is RED, not NO PROGRESS" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "CHECK RESULT: RED for T-01 (signature" && ! printf "%s" "$out" | grep -q "NO PROGRESS"' "$out"
out="$(factory-check T-01)"; rc=$?
check "and unchanged again it is NO PROGRESS" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "NO PROGRESS"' "$out"
printf 'exit 0\n' > core/tests/main.t
out="$(factory-check T-01)"; rc=$?
check "green again clears the no-progress flag" '[ $rc -eq 0 ] && [ ! -f .factory/no-progress/T-01 ] && [ -f .factory/failures/resolved/T-01.log ]' "$out"
printf 'value BUILD_ERROR\n' > core/src/main.src
out="$(factory-check T-01)"; rc=$?
check "a build failure is red and quoted" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "build    FAIL" && printf "%s" "$out" | grep -q "core/src/main.src:1:7: error: unexpected token"' "$out"
printf 'value\n' > core/src/main.src

echo "=== guards"
printf 'helper v2\n' > tools/gen.src
mktask in-progress T-02 "" "bash tools-note.sh" tools/gen.src
printf 'echo ok\n' > tools-note.sh
out="$(factory-check T-02)"; rc=$?
check "a change no test exercises is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "no test exercised this change"' "$out"
setfm tasks/in-progress/T-02.md untested_ok true
out="$(factory-check T-02)"; rc=$?
check "untested_ok a builder writes is not an exemption" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "changes what was approved: untested_ok" && ! printf "%s" "$out" | grep -q "waived by untested_ok"' "$out"
git add -f tasks/in-progress/T-02.md; git commit -qm "approve T-02"
out="$(factory-check T-02)"; rc=$?
check "untested_ok in the approved task file waives it" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "waived by untested_ok"' "$out"
sed -i.bak 's/^acceptance: .*/acceptance: true/' tasks/in-progress/T-02.md; rm -f tasks/in-progress/T-02.md.bak
out="$(factory-check T-02)"; rc=$?
check "an acceptance rewritten after approval is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "changes what was approved: acceptance"' "$out"
git checkout -q tasks/in-progress/T-02.md
git checkout -q tools/gen.src
mktask in-progress T-03 "" "grep -q done decisions.md && test -f tasks/done/T-03.md" ui/src/main.src
out="$(factory-check T-03)"; rc=$?
check "an acceptance that only reads files the agent writes is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "self-certifying"' "$out"
mktask in-progress T-03b "" "bash runner.sh ui && grep -q T-03b decisions.md" ui/src/main.src
out="$(factory-check T-03b)"; rc=$?
check "an acceptance that also runs something is not self-certifying" '! printf "%s" "$out" | grep -q "self-certifying"' "$out"
mktask in-progress T-04 "" "bash runner.sh ui"
out="$(factory-check T-04)"; rc=$?
check "an empty Files touched list is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "lists nothing under"' "$out"

echo "=== what the run is judged by"
factory-check census --json > .factory/run-start.json
check "the run's start records the gate and config digests" 'jq -e ".protected[\".factory/config.json\"] | length == 64" .factory/run-start.json >/dev/null'
mktask in-progress T-P1 "" "bash runner.sh core" core/src/main.src
cp .factory/config.json "$WORK/s6-config.keep"
jq '.commands.test = "true"' .factory/config.json > c && mv c .factory/config.json
out="$(factory-check T-P1)"; rc=$?
check "a config changed since the start is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "what the run is judged by changed: changed since the run started: .factory/config.json"' "$out"
cp "$WORK/s6-config.keep" .factory/config.json
jq '.hard_blocks = {"allow": ["git-tag"]}' .factory/config.json > c && mv c .factory/config.json
out="$(factory-check T-P1)"; rc=$?
check "the developer's ban choices are not the gate" '! printf "%s" "$out" | grep -q "what the run is judged by"' "$out"
cp "$WORK/s6-config.keep" .factory/config.json
mkdir -p gates; printf 'exit 0\n' > gates/extra.sh
out="$(factory-check T-P1)"; rc=$?
check "a new file under gates/ is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "changed since the run started: gates/extra.sh"' "$out"
rm -rf gates
mkdir -p gates/__pycache__; : > gates/.DS_Store; : > gates/__pycache__/x.cpython-312.pyc; : > gates/verify.sh.swp
out="$(factory-check T-P1)"; rc=$?
check "...but what an editor or Python leaves beside it is not" '! printf "%s" "$out" | grep -q "what the run is judged by"' "$out"
rm -rf gates
mktask in-progress T-P2 "" "bash runner.sh core" core/src/main.src gates/verify.sh
out="$(factory-check T-P2)"; rc=$?
check "a task that lists the gate is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "the task lists gates/verify.sh"' "$out"
rm -f tasks/in-progress/T-P1.md tasks/in-progress/T-P2.md .factory/run-start.json

echo "=== dependencies a task did not declare"
printf '{"name":"poly","dependencies":{}}\n' > package.json; git add package.json; git commit -qm "manifest"
mktask in-progress T-D1 "" "bash runner.sh core" core/src/main.src package.json
git add -f tasks/in-progress/T-D1.md; git commit -qm "approve T-D1"
printf '{"name":"poly","dependencies":{"left-pad":"1.0.0"}}\n' > package.json
out="$(factory-check T-D1)"; rc=$?
check "a manifest change the approved task does not declare is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "deps     FAIL (this task changes dependency manifest(s) its approved task file does not declare: package.json)"' "$out"
setfm tasks/in-progress/T-D1.md dependencies "[left-pad]"
out="$(factory-check T-D1)"; rc=$?
check "a builder declaring it in its own task file is not a declaration" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "changes what was approved: dependencies"' "$out"
git add -f tasks/in-progress/T-D1.md; git commit -qm "approve left-pad"
out="$(factory-check T-D1)"; rc=$?
check "declared in the approved task file, it passes the guard" '! printf "%s" "$out" | grep -q "deps     FAIL" && printf "%s" "$out" | grep -q "deps     declared: left-pad (package.json)"' "$out"
git checkout -q package.json; git rm -qf tasks/in-progress/T-D1.md; git commit -qm "T-D1 done"
mv tasks/in-progress/T-04.md "$WORK/T-04.keep"
mktask in-progress T-D2 "" "bash runner.sh core" core/src/main.src
printf '{"name":"poly","dependencies":{"evil":"1"}}\n' > package.json
out="$(factory-check T-D2)"; rc=$?
check "a manifest changed in the tree that no task lists is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "changed in the tree that no task lists: package.json"' "$out"
factory-check census --json > .factory/run-start.json
out="$(factory-check T-D2)"; rc=$?
check "...unless it was already so when the run started" '! printf "%s" "$out" | grep -q "no task lists: package.json"' "$out"
rm -f .factory/run-start.json; git checkout -q package.json; mv "$WORK/T-04.keep" tasks/in-progress/T-04.md
printf 'helper\n' > pandas.py; mkdir -p core/hypothesis; : > core/hypothesis/__init__.py
printf 'requests==2.0\n' > requirements.txt; git add requirements.txt; git commit -qm reqs
printf 'x\n' > requests.py; printf 'x\n' > core/helpers.py
mktask in-progress T-D3 "" "bash runner.sh core" core/src/main.src pandas.py requests.py core/helpers.py
out="$(factory-check T-D3)"; rc=$?
check "a new top-level module named like a declared package is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "requests.py shadows a package"' "$out"
check "...while an ordinary new module is not, nor a name the project does not use" '! printf "%s" "$out" | grep -q "core/helpers.py shadows" && ! printf "%s" "$out" | grep -q "pandas.py shadows"' "$out"
mktask in-progress T-D4 "" "bash runner.sh core" core/src/main.src core/hypothesis/__init__.py node_modules/left-pad/index.js
mkdir -p node_modules/left-pad; printf 'x\n' > node_modules/left-pad/index.js
out="$(factory-check T-D4)"; rc=$?
check "a test tool's name at a unit's top, or anything under node_modules/, is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "core/hypothesis/__init__.py shadows" && printf "%s" "$out" | grep -q "node_modules/left-pad/index.js shadows"' "$out"
rm -rf pandas.py requests.py core/helpers.py core/hypothesis node_modules tasks/in-progress/T-D?.md
git rm -q requirements.txt package.json; git commit -qm "drop manifests"

echo "=== the census is judged per task, against HEAD"
rm -f api/tests/main.t
mktask in-progress T-05 "" "bash runner.sh api" api/src/main.src api/tests/main.t
out="$(factory-check T-05)"; rc=$?
check "a task that deletes a tracked test file is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "this task deletes test file(s): api/tests/main.t"' "$out"
setfm tasks/in-progress/T-05.md allow_test_removal true
out="$(factory-check T-05)"; rc=$?
check "allow_test_removal a builder writes is not an exemption" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "changes what was approved: allow_test_removal"' "$out"
git add -f tasks/in-progress/T-05.md; git commit -qm "approve T-05"
out="$(factory-check T-05)"; rc=$?
check "allow_test_removal in the approved task file waives it" '! printf "%s" "$out" | grep -q "census"' "$out"
git checkout -q api/tests/main.t
printf 'exit 0 # SKIP flaky\n' > ui/tests/main.t
mktask in-progress T-06 "" "bash runner.sh ui" ui/tests/main.t
out="$(factory-check T-06)"; rc=$?
check "a task that adds a skip marker is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "adds 1 skip marker"' "$out"
git checkout -q ui/tests/main.t
# Two tasks in flight in one tree. A adds a test file and goes green first; B
# must not read A's unlanded file as a test that went missing - the exact false
# red that blocked four tasks on a real board.
printf 'exit 0\n' > api/tests/extra.t
mktask in-progress T-07 "" "bash runner.sh api" api/src/main.src api/tests/extra.t
mktask in-progress T-08 "" "bash runner.sh ui" ui/src/main.src
printf 'value a\n' > api/src/main.src; printf 'value b\n' > ui/src/main.src
out_a="$(factory-check T-07)"; rc_a=$?
out_b="$(factory-check T-08)"; rc_b=$?
check "tasks in flight together cannot trip each other's census" '[ $rc_a -eq 0 ] && [ $rc_b -eq 0 ]' "$out_a / $out_b"
rm -f api/tests/extra.t; git checkout -q api/src/main.src ui/src/main.src
# The same, when the other task edits a test file that HEAD already has and
# waits for its review: a check that left "foreign" files out of a count taken
# with them in went red here, on a real board, with signature 1586d8da18d0.
printf 'exit 0 # reviewed soon\n' > api/tests/main.t; printf 'value a2\n' > api/src/main.src
mktask in-progress T-07b "" "bash runner.sh api" api/src/main.src api/tests/main.t
out_a="$(factory-check T-07b)"; rc_a=$?
printf 'value b2\n' > ui/src/main.src
out_b="$(factory-check T-08)"; rc_b=$?
check "a task editing a test file HEAD already has cannot trip another task's census" '[ $rc_a -eq 0 ] && [ $rc_b -eq 0 ] && ! printf "%s" "$out_b" | grep -q census' "$out_a / $out_b"
git checkout -q api/tests/main.t api/src/main.src ui/src/main.src

echo "=== another task's half-written work is waited for, not blamed"
jq '.check.foreign_wait = 4' .factory/config.json > c && mv c .factory/config.json
printf 'value c\n' > ui/src/main.src
printf 'half BUILD_ERROR\n' > api/src/half.src
mktask in-progress T-10 "" "bash runner.sh ui" ui/src/main.src
out="$(factory-check T-10)"; rc=$?
check "a failure only in another task's files is WAITING, not red" '[ $rc -eq 3 ] && printf "%s" "$out" | grep -q "CHECK RESULT: WAITING for T-10" && printf "%s" "$out" | grep -q "api/src/half.src"' "$out"
check "and nothing is recorded against this task" '[ ! -f .factory/failures/T-10.log ] && [ ! -f .factory/no-progress/T-10 ]'
jq '.check.foreign_wait = 30' .factory/config.json > c && mv c .factory/config.json
( sleep 4; rm -f api/src/half.src ) &
out="$(factory-check T-10)"; rc=$?
check "when that work lands, the check runs again by itself and goes green" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^  waiting" && printf "%s" "$out" | grep -q "CHECK RESULT: GREEN for T-10"' "$out"
printf 'value BUILD_ERROR\n' > ui/src/main.src
out="$(factory-check T-10)"; rc=$?
check "a failure in the task's own file is red at once" '[ $rc -eq 1 ] && ! printf "%s" "$out" | grep -q "waiting" && [ -f .factory/failures/T-10.log ]' "$out"
printf 'half BUILD_ERROR\n' > api/src/half.src
jq '.check.foreign_wait = 4' .factory/config.json > c && mv c .factory/config.json
out="$(factory-check T-10)"; rc=$?
check "own and foreign errors together are the task's red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "CHECK RESULT: RED"' "$out"
rm -f api/src/half.src; git checkout -q ui/src/main.src
jq 'del(.check.foreign_wait)' .factory/config.json > c && mv c .factory/config.json

echo "=== acceptance is executed, not reported"
printf 'echo "acceptance ran"; exit 1\n' > accept-red.sh
mktask in-progress T-09 "" "bash accept-red.sh" ui/src/main.src
out="$(factory-check T-09)"; rc=$?
check "a failing acceptance command is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "accept   FAIL (exit 1)"' "$out"

echo "=== the full check runs the project's own gate commands"
out="$(factory-plan --json --start)"
check "a planned run records where it started" 'jq -e ".test_files == 3 and (.files | length) == 3 and (.tasks | length) > 0" .factory/run-start.json >/dev/null && jq -e ".start_head | length > 0" <<< "$out" >/dev/null' "$(cat .factory/run-start.json 2>/dev/null)"
: > .factory/tool.log
out="$(factory-check --full)"; rc=$?
check "the full check runs build, test and lint" '[ $rc -eq 0 ] && [ "$(tools_log)" = "build,runner .,lint," ] && printf "%s" "$out" | grep -q "test     PASS (6 test(s))"' "$(tools_log) / $out"
check "its verdict is recorded" 'grep -q "^verdict=green" .factory/full-check && grep -q "^tests=6" .factory/full-check'
check "...with the commit it judged and whether the tree was clean, not a tree fingerprint" 'grep -qx "head=$(git rev-parse HEAD)" .factory/full-check && grep -qE "^clean=(yes|no)$" .factory/full-check && ! grep -q "^tree=" .factory/full-check' "$(cat .factory/full-check)"
# The cases below retune the gate commands between full checks, as a developer
# would between runs: each one records the new config as the run's start.
redigest() { jq --argjson p "$(factory-check census --json | jq -c .protected)" '.protected = $p' .factory/run-start.json > rs && mv rs .factory/run-start.json; }
jq '.commands.test = "echo no tests found"' .factory/config.json > c && mv c .factory/config.json; redigest
out="$(factory-check --full)"; rc=$?
check "a suite that ran zero tests is never a green full check" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "reported 0 test(s)"' "$out"
jq '.commands.test = "echo done"' .factory/config.json > c && mv c .factory/config.json; redigest
out="$(factory-check --full)"; rc=$?
check "an unrecognised count passes but says so" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "count not recognised - set check.count"' "$out"
jq '.commands.test = "echo done; echo \"ran=7\"" | .check.count = "ran=(\\d+)"' .factory/config.json > c && mv c .factory/config.json; redigest
out="$(factory-check --full)"
check "check.count teaches it any runner's summary" 'printf "%s" "$out" | grep -q "test     PASS (7 test(s))"' "$out"
jq '.commands.test = "bash runner.sh ." | del(.check.count)' .factory/config.json > c && mv c .factory/config.json; redigest
git rm -q ui/tests/main.t; git commit -qm "lose a test"
out="$(factory-check --full)"; rc=$?
check "a run that lost a test file in HEAD is red, whoever lost it" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "test files in HEAD went from 3 to 2"' "$out"
git revert --no-edit HEAD >/dev/null

echo "=== plan"
B="$WORK/plan"; rm -rf "$B"; mkdir -p "$B/.factory/no-progress"; cd "$B" || exit 1
git init -q -b main; : > .factory/active; echo '{"fast":{"workers":3,"effort_build":"high"}}' > .factory/config.json
P="$B"
mktask done G "" "x" a
mktask backlog A "" "x" a
mktask backlog B "A, G" "x" a
mktask blocked X "" "x" a
mktask backlog C "X" "x" a
mktask backlog D "C" "x" a
mktask backlog E "" "x" a; sed -i.bak 's/^needs_human: false/needs_human: true/' tasks/backlog/E.md; rm -f tasks/backlog/E.md.bak
mktask backlog F "" "x" a; : > .factory/no-progress/F
mktask in-progress R "" "x" a
j="$(factory-plan --json)"
check "plan lists what can run, with only the deps still to land" '[ "$(jq -r ".tasks[] | .id + \":\" + (.deps | join(\"+\"))" <<< "$j" | tr "\n" " ")" = "A: B:A R: " ]' "$j"
check "blocked dependencies hold their whole chain" '[ "$(jq -c "[.held[] | .id]" <<< "$j")" = "[\"C\",\"D\",\"E\",\"F\"]" ]' "$j"
check "plan carries the fast-lane config" '[ "$(jq -c "[.workers, .effort.build, .effort.escalate]" <<< "$j")" = "[3,\"high\",\"high\"]" ]' "$j"
check "a task left in progress is named" 'jq -e ".warnings | map(select(test(\"in-progress: R\"))) | length == 1" <<< "$j" >/dev/null' "$j"
check "plan measures the graph: its longest chain and its widest level" 'jq -e ".critical_path == [\"A\",\"B\"] and .width == 2" <<< "$j" >/dev/null' "$j"
for n in 1 2 3 4 5; do mktask backlog S$n "$([ $n -gt 1 ] && echo S$((n - 1)))" "x" a; done
j="$(factory-plan --json)"
check "a plan that is mostly one chain says so before anything runs" 'jq -e ".warnings | map(select(test(\"5 of 8 tasks sit on one dependency chain\"))) | length == 1" <<< "$j" >/dev/null' "$j"
rm -f tasks/backlog/S?.md
mkdir -p tasks/proposed; mktask proposed N1 "A" "x" a
j="$(factory-plan --json --proposed)"
check "a proposed task list can be measured before it is approved" 'jq -e "[.tasks[] | .id] | index(\"N1\") != null" <<< "$j" >/dev/null && ! factory-plan --json | jq -e "[.tasks[] | .id] | index(\"N1\") != null" >/dev/null' "$j"
rm -f tasks/proposed/N1.md
mktask backlog K "L" "x" a; mktask backlog L "K" "x" a
j="$(factory-plan --json)"; rc=$?
check "a dependency cycle stops the plan" '[ $rc -eq 1 ] && jq -e ".ok == false and (.problems[0] | test(\"cycle\"))" <<< "$j" >/dev/null' "$j"

echo "=== the board is committed as approved when a run starts"
SN="$WORK/snap"; rm -rf "$SN"; mkdir -p "$SN/.factory" "$SN/src"; cd "$SN" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
: > .factory/active; echo '{"fast":{"workers":2}}' > .factory/config.json; printf '.factory/\n' > .gitignore
printf 'a\n' > src/a.txt; git add -A; git commit -qm base
P="$SN"
mktask backlog Q-01 "" "true" src/a.txt
setfm tasks/backlog/Q-01.md untested_ok true
printf 'mine\n' > src/a.txt; printf 'staged\n' > src/b.txt; git add src/b.txt
j="$(factory-plan --json --start)"
check "start commits the run's task files" 'git log -1 --format=%B | grep -q "^Factory-Board: snapshot" && git show HEAD:./tasks/backlog/Q-01.md | grep -q "^untested_ok: true"' "$j"
check "...and nothing else" '[ "$(git show --name-only --format= HEAD)" = "tasks/backlog/Q-01.md" ] && [ "$(git diff --cached --name-only)" = "src/b.txt" ] && [ "$(git diff --name-only)" = "src/a.txt" ]' "$(git show --stat HEAD)"
check "the plan says which commit it is" '[ "$(jq -r .snapshot <<< "$j")" = "$(git rev-parse --short HEAD)" ]' "$j"
check "run-start points at the snapshot" '[ "$(jq -r .head .factory/run-start.json)" = "$(git rev-parse --short HEAD)" ]'
j="$(factory-plan --json --start)"
check "a board already committed is not committed again" '[ "$(git log --format=%s | grep -c "board snapshot")" = 1 ] && [ "$(jq -r ".snapshot // empty" <<< "$j")" = "" ]' "$j"
sed -i.bak 's/^acceptance: .*/acceptance: echo ok/' tasks/backlog/Q-01.md && rm -f tasks/backlog/Q-01.md.bak
j="$(factory-plan --json --start)"; rc=$?
check "a change to what was approved is not committed as approved: the run does not start" '[ $rc -eq 1 ] && printf "%s" "$j" | grep -q "Q-01: tasks/backlog/Q-01.md changes what was approved (acceptance)" && [ "$(git log --format=%s | grep -c "board snapshot")" = 1 ]' "$j"
git checkout -q tasks/backlog/Q-01.md
mkdir -p tasks/in-progress; mv tasks/backlog/Q-01.md tasks/in-progress/Q-01.md
sed -i.bak 's/^stage: .*/stage: implementing/' tasks/in-progress/Q-01.md && rm -f tasks/in-progress/Q-01.md.bak
j="$(factory-plan --json --start)"; rc=$?
check "a task a dead run left in progress, its approval unchanged, is committed where it is" '[ $rc -eq 0 ] && git show HEAD:./tasks/in-progress/Q-01.md | grep -q "^stage: implementing" && ! git cat-file -e HEAD:./tasks/backlog/Q-01.md 2>/dev/null' "$j"
sed -i.bak 's/^stage: .*/stage: verifying/' tasks/in-progress/Q-01.md && rm -f tasks/in-progress/Q-01.md.bak
git rev-parse HEAD > .git/MERGE_HEAD
j="$(factory-plan --json --start)"; rc=$?
check "a snapshot git refuses stops the run, and says why" '[ $rc -eq 1 ] && printf "%s" "$j" | grep -q "the board snapshot could not be committed"' "$j"
rm -f .git/MERGE_HEAD
mktask in-progress Q-02 "" "true" src/a.txt
printf '{"head":"%s","tasks":["Q-02"]}\n' "$(git rev-parse --short HEAD)" > .factory/run-start.json
out="$(factory-check Q-02 2>&1)"; rc=$?
check "a task this run planned that no commit has is red: its approval has no anchor" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "the task file is in no commit"' "$out"
rm -f tasks/in-progress/Q-02.md .factory/run-start.json
git reset -q; git checkout -q src/a.txt; rm -f src/b.txt

echo "=== start, land, block"
S="$WORK/land"; rm -rf "$S"; mkdir -p "$S/.factory/lessons" "$S/.factory/verified" "$S/src"; cd "$S" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
: > .factory/active; printf '# decisions\n' > decisions.md; printf 'x\n' > src/x.txt; printf '.factory/\n' > .gitignore
git add -A; git commit -qm base
P="$S"
mktask backlog C2-01 "" "bash run.sh" src/x.txt
printf -- '- general: always do X\n' > .factory/lessons/general.md
printf -- '- core: registrations live in core.dart\n' > .factory/lessons/core.md
out="$(factory-start C2-01 builder-1)"; rc=$?
check "start moves the task and stamps it" '[ $rc -eq 0 ] && [ -f tasks/in-progress/C2-01.md ] && grep -q "^owner: builder-1" tasks/in-progress/C2-01.md && grep -q "^stage: implementing" tasks/in-progress/C2-01.md && grep -Eq "^stage_since: [0-9]{4}-" tasks/in-progress/C2-01.md' "$out"
check "start prints the task and its module lessons in one go" 'printf "%s" "$out" | grep -q "## Goal" && printf "%s" "$out" | grep -q "always do X" && printf "%s" "$out" | grep -q "registrations live"' "$out"
mktask done C1-09 "" "x" src/x.txt
printf -- '- C1-09: registrations go through Registry.add - one place to find them\n- C0-00: unrelated decision\n' >> decisions.md
mktask backlog C2-09 "" "bash run.sh" src/x.txt
out="$(factory-start C2-09)"
check "start also prints what earlier tasks of the same module decided" 'printf "%s" "$out" | grep -q "decisions already taken in module core" && printf "%s" "$out" | grep -q "Registry.add" && ! printf "%s" "$out" | grep -q "C0-00"' "$out"
mv tasks/in-progress/C2-09.md tasks/backlog/C2-09.md; rm -f tasks/backlog/C2-09.md tasks/done/C1-09.md
out="$(factory-land C2-01)"; rc=$?
check "land refuses without a green check" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "LAND REFUSED" && [ -f tasks/in-progress/C2-01.md ]' "$out"
printf 'y\n' > src/x.txt; printf 'files=%s\n' "$(factory-check fingerprint C2-01)" > .factory/verified/C2-01
printf 'z\n' > src/x.txt
out="$(factory-land C2-01)"; rc=$?
check "land refuses a task whose file changed after its green check" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "changed after the green check" && [ -f tasks/in-progress/C2-01.md ]' "$out"
printf 'y\n' > src/x.txt
out="$(factory-land C2-01)"; rc=$?
check "land moves to done and commits exactly the task" '[ $rc -eq 0 ] && [ -f tasks/done/C2-01.md ] && printf "%s" "$out" | grep -q "^LANDED C2-01 [0-9a-f]" && git log -1 --format=%B | grep -q "Factory-Task: C2-01"' "$out"
out="$(factory-land C2-01)"
check "landing it again says it is already done and committed" 'printf "%s" "$out" | grep -q "^LAND SKIPPED for C2-01"' "$out"
git rm -q --cached tasks/done/C2-01.md; git commit -qm "drop it from HEAD"
out="$(factory-land C2-01)"
check "...and says so when no commit has it: its dependents cannot start" 'printf "%s" "$out" | grep -q "^LAND UNCOMMITTED C2-01"' "$out"
git add tasks/done/C2-01.md; git commit -qm "back"
check "land records the move and the commit in the event log" 'jq -e "select(.kind==\"commit\" and .task==\"C2-01\")" .factory/events.jsonl >/dev/null && jq -e "select(.kind==\"move\" and .to==\"done\")" .factory/events.jsonl >/dev/null'
mktask backlog C2-02 "" "bash run.sh" src/x.txt
sed -i.bak 's/^title: .*/title: <placeholder>/; s/^acceptance: .*/acceptance: <command>/' tasks/backlog/C2-02.md; rm -f tasks/backlog/C2-02.md.bak
out="$(factory-start C2-02)"; rc=$?
check "start refuses a task that does not lint" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "does not lint" && [ -f tasks/backlog/C2-02.md ]' "$out"
mktask backlog C2-11 "C2-98" "bash run.sh" src/x.txt
out="$(factory-start C2-11)"; rc=$?
check "start refuses a task whose dependency is not done" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "DEPENDENCY C2-98 is not done" && [ -f tasks/backlog/C2-11.md ]' "$out"
mktask done C2-98 "" "x" src/x.txt
out="$(factory-start C2-11)"; rc=$?
check "...or done but not committed" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "DEPENDENCY C2-98 is in tasks/done but not committed"' "$out"
git add tasks/done/C2-98.md; git commit -qm "C2-98 landed"
out="$(factory-start C2-11)"; rc=$?
check "...and starts once it has landed" '[ $rc -eq 0 ] && [ -f tasks/in-progress/C2-11.md ]' "$out"
check "the builder is told to return refused" 'grep -q "Any other" "$PLUGIN/agents/builder.md" && grep -q "return \`refused\`" "$PLUGIN/agents/builder.md"'
rm -f tasks/in-progress/C2-11.md; git rm -q tasks/done/C2-98.md; git commit -qm "drop C2-98"
mktask backlog C2-03 "" "bash run.sh" src/x.txt; touch .factory/verified/C2-03
out="$(factory-block C2-03 "needs the payment provider decided")"
check "block moves the task with its reason and drops its marker" '[ -f tasks/blocked/C2-03.md ] && grep -q "needs the payment provider decided" tasks/blocked/C2-03.md && [ ! -f .factory/verified/C2-03 ]' "$out"
mktask in-progress C2-04 "" "bash run.sh" src/x.txt src/new.txt src/shared.txt
mktask in-progress C2-05 "" "bash run.sh" src/shared.txt
printf 'half\n' > src/x.txt; printf 'new\n' > src/new.txt; printf 'shared\n' > src/shared.txt
out="$(factory-block C2-04 "stuck on the parser")"
check "a blocked task's unlanded work leaves the tree" '[ "$(cat src/x.txt)" = "y" ] && [ ! -e src/new.txt ] && [ -f .factory/parked/C2-04/files/src/x.txt ] && printf "%s" "$out" | grep -q "parked 2 file(s)"' "$out"
check "a file another task in progress lists stays where it is" '[ "$(cat src/shared.txt)" = "shared" ] && grep -q "another task in progress lists them too: src/shared.txt" tasks/blocked/C2-04.md'
check "the reason says where the work went and how to get it back" 'grep -q "factory-block --unpark C2-04" tasks/blocked/C2-04.md'
out="$(factory-block --unpark C2-04)"
check "unpark puts the work back exactly" '[ "$(cat src/x.txt)" = "half" ] && [ "$(cat src/new.txt)" = "new" ] && [ ! -d .factory/parked/C2-04 ]' "$out"
mktask in-progress C2-06 "" "bash run.sh" src/x.txt
out="$(factory-block C2-06 --keep "leave it for the developer")"
check "--keep blocks without parking" '[ "$(cat src/x.txt)" = "half" ] && [ -f tasks/blocked/C2-06.md ] && ! printf "%s" "$out" | grep -q parked' "$out"
rm -f src/new.txt src/shared.txt; git checkout -q src/x.txt


echo "=== generated files are never a reason for review"
R="$WORK/risk"; rm -rf "$R"; mkdir -p "$R/.factory" "$R/db/migrations" "$R/src"; cd "$R" || exit 1
git init -q -b main; : > .factory/active
printf '{"risk_paths":["*/migrations/*","*auth*"],"risk_exclude":["*.snapshot"]}\n' > .factory/config.json
printf 'db/migrations/*.gen linguist-generated=true\n' > .gitattributes
P="$R"
mktask in-progress R-01 "" "x" db/migrations/0001.gen db/migrations/model.snapshot src/app.txt
out="$(factory-risk R-01)"; rc=$?
check "generated migration output does not send a task to review" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "generated or excluded: db/migrations/0001.gen db/migrations/model.snapshot"' "$out"
mktask in-progress R-02 "" "x" db/migrations/0002_drop_users.sql src/auth.txt
out="$(factory-risk R-02)"; rc=$?
check "a hand-written migration still does" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "db/migrations/0002_drop_users.sql matches"' "$out"

echo "=== 2.6: CLAUDE.md size, stray untracked files, an unread test count"
P="$WORK/guards"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
mkdir -p .factory/verified core/src core/tests ui/src ui/tests tasks/backlog tasks/in-progress tasks/done tasks/blocked
: > .factory/active
for u in core ui; do printf 'value\n' > $u/src/main.src; printf 'exit 0\n' > $u/tests/main.t; done
cat > runner.sh <<'SH'
n=0
for t in $(find "$1" -name '*.t' | sort); do n=$((n + 2)); bash "$t" || exit 1; done
echo "$n passed"
SH
cat > .factory/config.json <<'JSON'
{ "gate_mode": "full", "min_tests": 1,
  "commands": { "build": "", "test": "bash runner.sh .", "arch": "", "lint": "" },
  "check": { "unit_test": "bash runner.sh {path}", "test_files": "\\.t$",
    "units": [ {"name": "core", "path": "core", "deps": []}, {"name": "ui", "path": "ui", "deps": ["core"]} ] } }
JSON
printf '.factory/\n' > .gitignore
git add -A; git commit -qm base
: > .factory/tool.log
seq 1 250 | sed 's/^/line /' > core/CLAUDE.md
printf 'v\n' >> core/src/main.src
mktask in-progress M-01 "" "bash runner.sh core" core/src/main.src core/CLAUDE.md
out="$(factory-check M-01)"; rc=$?
check "a CLAUDE.md past the limit is red at the task check" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "core/CLAUDE.md is 250 lines"' "$out"
jq '.check.claude_md_max_lines = 0' .factory/config.json > c && mv c .factory/config.json
out="$(factory-check M-01)"; rc=$?
check "claude_md_max_lines 0 turns the guard off" '! printf "%s" "$out" | grep -q "CLAUDE.md is"' "$out"
jq 'del(.check.claude_md_max_lines)' .factory/config.json > c && mv c .factory/config.json
git add core/CLAUDE.md; git commit -qm "big claude.md" >/dev/null
git checkout -q core/src/main.src
out="$(factory-check --full 2>&1)"
check "and at the full check, over the tracked files" 'printf "%s" "$out" | grep -q "claude_md.*core/CLAUDE.md (250)"' "$out"
git rm -qf core/CLAUDE.md; git commit -qm "drop" >/dev/null
rm -f tasks/in-progress/*.md
mktask in-progress U-01 "" "bash runner.sh core" core/src/main.src
printf 'x\n' >> core/src/main.src; printf 'generated\n' > core/src/migration_001.src
out="$(factory-check U-01)"; rc=$?
check "an untracked file in the task's unit that the list leaves out is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "core/src/migration_001.src"' "$out"
printf -- '- core/src/migration_001.src\n' >> tasks/in-progress/U-01.md
mktask in-progress U-01 "" "bash runner.sh core" core/src/main.src core/src/migration_001.src
out="$(factory-check U-01)"; rc=$?
check "listing it makes the guard pass" '! printf "%s" "$out" | grep -q "untracked"' "$out"
mktask in-progress U-01 "" "bash runner.sh core" core/src/main.src
mktask in-progress U-02 "" "bash runner.sh ui" ui/src/main.src
printf 'y\n' > ui/src/other.src
out="$(factory-check U-01)"
check "an untracked file in another unit is not this task's" '! printf "%s" "$out" | grep -q "other.src"' "$out"
mktask in-progress U-02 "" "bash runner.sh core"
out="$(factory-check U-01)"; rc=$?
check "when another task has listed nothing yet it is a note, not a red" '! printf "%s" "$out" | grep -q "untracked file(s)"' "$out"
rm -f core/src/migration_001.src ui/src/other.src; git checkout -q core/src/main.src; rm -f tasks/in-progress/*.md

cat > count.sh <<'SH'
echo "all tests passed"
SH
jq '.check.count = "([0-9]+) passed" | .check.unit_test = "bash count.sh {path}"' .factory/config.json > c && mv c .factory/config.json
mktask in-progress N-01 "" "bash count.sh" core/src/main.src
printf 'z\n' >> core/src/main.src
out="$(factory-check N-01)"; rc=$?
check "check.count that matches nothing in the output is red, not silently unguarded" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "check.count is set and matched nothing"' "$out"
git checkout -q core/src/main.src; rm -f tasks/in-progress/*.md
jq 'del(.check.count) | .check.unit_test = "bash runner.sh {path}"' .factory/config.json > c && mv c .factory/config.json

echo "=== finish reports from disk"
Z="$WORK/finish"; rm -rf "$Z"; mkdir -p "$Z/.factory" "$Z/src"; cd "$Z" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
: > .factory/active; printf '{"commands":{}}\n' > .factory/config.json; printf 'a\n' > src/a.txt
git add -A; git commit -qm base
P="$Z"
mktask done F-01 "" "x" src/a.txt
printf '\n## Open concerns\n- the id /start returns is never accepted by /next\n' >> tasks/done/F-01.md
printf 'b\n' > src/a.txt; git add -A; git commit -qm "F-01: thing" -m "Factory-Task: F-01"
mktask blocked F-02 "" "x" src/a.txt
printf '\n## Blocked reason\n- 2026-01-01T00:00:00Z: needs the provider decided\n' >> tasks/blocked/F-02.md
mktask backlog F-03 "F-02" "x" src/a.txt
out="$(factory-finish --tasks F-01,F-02,F-03 --no-full)"
check "finish prints one line by default" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 1 ] && printf "%s" "$out" | grep -q "^FINISH 1/3 landed"' "$out"
out="$(factory-finish --tasks F-01,F-02,F-03 --no-full --json)"
check "finish puts what a builder left open first" 'jq -e ".attention == [{\"id\":\"F-01\",\"concern\":\"the id /start returns is never accepted by /next\"}]" <<< "$out" >/dev/null' "$out"
check "finish reads where each task is and which commit carries it" 'jq -e "[.board[] | .lane] == [\"done\",\"blocked\",\"backlog\"] and .board[0].commit != null and .board[1].reason == \"2026-01-01T00:00:00Z: needs the provider decided\"" <<< "$out" >/dev/null' "$out"
check "with nothing new to judge the full check is skipped, and says so" 'jq -e ".full_check == \"skipped\"" <<< "$out" >/dev/null' "$out"
check "the report is written for the developer too" 'grep -q "## Needs your attention" .factory/last-run.md && grep -q "| F-02 | blocked |" .factory/last-run.md'
mktask done F-04 "" "x" src/a.txt
printf '\n## Review 2026-01-02\nverdict: fail\nfindings:\n- src/a.txt:3 tenant filter missing on the list query -> add it\n' >> tasks/done/F-04.md
out="$(factory-finish --tasks F-04 --no-full --json)"
check "a failed review of a task that already landed is reported first" 'jq -e ".attention[0].concern | startswith(\"review failed: src/a.txt:3 tenant filter\")" <<< "$out" >/dev/null' "$out"

echo "=== 2.6.1: what chains a plan, and where the session wakes"
SC="$WORK/chain"; rm -rf "$SC"; mkdir -p "$SC/.factory" "$SC/tasks/backlog"; P="$SC"; cd "$SC" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
: > .factory/active; printf '{"commands":{}}\n' > .factory/config.json
for n in 1 2 3 4; do mktask backlog K$n "$([ $n -gt 1 ] && echo K$((n - 1)))" "x" lib/strings.arb lib/page$n.dart; done
out="$(factory-plan)"
check "a serial chain names the file that holds it together" 'printf "%s" "$out" | grep -q "Files they share: lib/strings.arb (4 tasks)"' "$out"
check "the brief tells the session not to watch a running workflow" 'grep -q "do not attach a Monitor" "$H/factory-brief.sh"'

echo "=== 2.6: the runner agent, helper calls, metrics, the idle brief"
check "runner.md is a cheap, bounded, CLAUDE.md-free agent" 'f="$PLUGIN/agents/runner.md"; grep -q "^name: runner" "$f" && grep -q "^model: haiku" "$f" && grep -q "^effort: low" "$f" && grep -q "^maxTurns: 4" "$f" && grep -q "^omitClaudeMd: true" "$f"'
# metrics.jsonl: one line per finished run
cd "$Z" || exit 1
rm -f .factory/metrics.jsonl
now=$(date +%s)
{
  echo "{\"ts\":$now,\"turn\":1,\"agent\":\"a1\",\"type\":\"factory:builder\",\"label\":\"F-01\",\"model\":\"claude-sonnet-5-5\",\"input\":1000,\"output\":2000,\"cache_read\":10000,\"cache_write\":0}"
  echo "{\"ts\":$now,\"turn\":1,\"agent\":\"a2\",\"type\":\"factory:runner\",\"label\":\"F-01 land\",\"model\":\"claude-haiku-5-5\",\"input\":500,\"output\":100,\"cache_read\":0,\"cache_write\":0}"
  echo "{\"ts\":$now,\"turn\":1,\"agent\":\"main\",\"type\":\"main\",\"label\":null,\"model\":\"claude-opus-5-5\",\"input\":10,\"output\":1000,\"cache_read\":100000,\"cache_write\":0}"
  echo "{\"ts\":$now,\"turn\":1,\"agent\":\"a3\",\"type\":\"factory:runner\",\"label\":\"finish\",\"model\":\"claude-haiku-5-5\",\"input\":500,\"output\":100,\"cache_read\":0,\"cache_write\":0}"
} > .factory/usage.jsonl
factory-finish --tasks F-01 --no-full >/dev/null
check "a finished run appends one metrics line" '[ "$(wc -l < .factory/metrics.jsonl | tr -d " ")" = 1 ] && jq -e ".tasks == 1 and .landed >= 1 and .usd_total > 0 and (.helpers_share > 0 and .helpers_share < 0.1) and .unlabeled_share == 0 and .lead_turns == 1 and .lead_share > 0" .factory/metrics.jsonl >/dev/null' "$(cat .factory/metrics.jsonl 2>/dev/null)"
rm -f .factory/usage.jsonl .factory/metrics.jsonl
factory-finish --tasks F-01 --no-full >/dev/null
check "without usage rows the line says so instead of inventing a cost" 'jq -e ".usd_total == null and .turns == 0" .factory/metrics.jsonl >/dev/null' "$(cat .factory/metrics.jsonl 2>/dev/null)"

# idle board: two-line brief
IDLE="$WORK/idle"; rm -rf "$IDLE"; mkdir -p "$IDLE/.factory" "$IDLE/tasks/"{backlog,in-progress,blocked,done,proposed}; cd "$IDLE" || exit 1
git init -q -b main; : > .factory/active; printf '{"commands":{}}\n' > .factory/config.json
mkdir -p gates; printf '# count_tests guard_test_census guard_acceptance record_failure\nrm -f "${ROOT}/.factory/verified/x"\ntree=1\nisolate() { :; }\n' > gates/verify.sh
: > .gitignore; (bash "$H/factory-upgrade.sh" --apply >/dev/null 2>&1)
out="$(jq -n --arg c "$IDLE" '{cwd:$c, session_id:"S9", hook_event_name:"SessionStart", source:"startup"}' | bash "$H/factory-brief.sh" 2>/dev/null)"
ctx="$(printf "%s" "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
check "an empty board gets a short brief, not the full one" '[ -n "$ctx" ] && [ "$(printf "%s\n" "$ctx" | wc -l | tr -d " ")" -le 3 ] && printf "%s" "$ctx" | grep -q "board is empty"' "$out"
out="$(jq -n --arg c "$IDLE" '{cwd:$c, session_id:"S9", hook_event_name:"SessionStart", source:"compact"}' | bash "$H/factory-brief.sh" 2>/dev/null)"
ctx="$(printf "%s" "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
check "...after a compaction too" '[ -n "$ctx" ] && [ "$(printf "%s\n" "$ctx" | wc -l | tr -d " ")" -le 3 ]' "$out"

# nested config keys are migrated
NEST="$WORK/nest"; rm -rf "$NEST"; mkdir -p "$NEST/gates" "$NEST/tasks/backlog" "$NEST/.factory"; cd "$NEST" || exit 1
: > .factory/active
printf '{"factory_version":"2.5","verify":"gates/verify.sh","fast":{"workers":7},"check":{"count":"x"}}\n' > .factory/config.json
out="$(bash "$H/factory-upgrade.sh" 2>&1)"
check "the report names missing nested keys" 'printf "%s" "$out" | grep -q "fast.effort_escalate" && printf "%s" "$out" | grep -q "check.claude_md_max_lines"' "$out"
bash "$H/factory-upgrade.sh" --apply >/dev/null 2>&1
check "--apply adds them and keeps the project's own values" 'jq -e ".fast.workers == 7 and .fast.effort_escalate == \"high\" and .check.count == \"x\" and .check.claude_md_max_lines == 200" .factory/config.json >/dev/null' "$(cat .factory/config.json)"

echo "=== fixes the fast lane depends on"
Q="$WORK/fixes"; rm -rf "$Q"; mkdir -p "$Q/.factory"; cd "$Q" || exit 1; : > .factory/active
echo 99999999999 > .factory/.dash-stamp
jq -cn --arg c "$Q" '{cwd:$c, hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"factory-commit C2-01"}, tool_response:{stdout:"COMMIT 9f3ab12 C2-01 (C2): a", stderr:""}}' | bash "$H/factory-event.sh"
jq -cn --arg c "$Q" '{cwd:$c, hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"bash gates/verify.sh C2-02"}, tool_response:{stdout:"", stderr:"GATE RESULT: GREEN for C2-02"}}' | bash "$H/factory-event.sh"
jq -cn --arg c "$Q" '{cwd:$c, hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"factory-check C2-03"}, tool_response:{stdout:"CHECK RESULT: RED for C2-03", stderr:""}}' | bash "$H/factory-event.sh"
check "bin-style commits are recorded, read from tool_response" 'jq -e "select(.kind==\"commit\" and .sha==\"9f3ab12\")" .factory/events.jsonl >/dev/null' "$(cat .factory/events.jsonl)"
check "a gate verdict printed on stderr is recorded" 'jq -e "select(.kind==\"gate\" and .task==\"C2-02\" and .verdict==\"green\")" .factory/events.jsonl >/dev/null'
check "a factory-check verdict is recorded as a gate run" 'jq -e "select(.kind==\"gate\" and .task==\"C2-03\" and .verdict==\"red\")" .factory/events.jsonl >/dev/null'

echo "=== classic gates: any runner's count"
K="$WORK/classic"; rm -rf "$K"; mkdir -p "$K/.factory/verified" "$K/gates" "$K/src"; cd "$K" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
: > .factory/active; printf 'a\n' > src/a.txt; printf '.factory/\n' > .gitignore; git add -A; git commit -qm base
echo 99999999999 > .factory/.dash-stamp
python3 "$PLUGIN/tests/extract.py" gates/verify.sh >/dev/null; chmod +x gates/verify.sh
jq -n '{gate_mode:"full", min_tests:1, commands:{build:"true", test:"echo suite done; echo ran=5", arch:"", lint:"true"}, check:{count:"ran=(\\d+)"}}' > .factory/config.json
printf -- '---\nid: K-3\nacceptance: bash gates/verify.sh K-3\n---\n' > .factory/K-3.md
out="$(bash gates/verify.sh K-3 2>&1)"
check "an old gate counts any runner's tests through check.count" 'printf "%s" "$out" | grep -q "GATE test: PASS (5 test(s) ran)"' "$out"

echo "=== 3.3: one gate engine - staged and full"
G="$WORK/engine"; rm -rf "$G"; mkdir -p "$G/.factory" "$G/src"; cd "$G" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
: > .factory/active; printf '.factory/\n' > .gitignore; printf 'a\n' > src/a.txt
git add -A; git commit -qm base
P="$G"
mktask in-progress E-01 "" "true" src/a.txt
setfm tasks/in-progress/E-01.md untested_ok true
git add -f tasks; git commit -qm "approve E-01"
gcfg() { jq -n --arg m "$1" --argjson c "$2" '{gate_mode:$m, min_tests:1, commands:$c}' > .factory/config.json; }
gcfg staged '{"build":"echo built"}'
out="$(factory-check E-01)"; rc=$?
check "staged: a board with only a build command is green when the build is" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "skipped (no test command yet, gate_mode=staged)"' "$out"
sed -i.bak 's/^acceptance: .*/acceptance: bash gates\/verify.sh E-01/' tasks/in-progress/E-01.md && rm -f tasks/in-progress/E-01.md.bak
git add -f tasks; git commit -qm "E-01 acceptance"
gcfg staged '{}'
out="$(factory-check E-01)"; rc=$?
check "staged: nothing configured and nothing run is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "staged mode needs at least one green stage"' "$out"
gcfg staged '{"build":"echo built", "test":"echo no tests ran"}'
setfm tasks/in-progress/E-01.md x y
sed -i.bak '/^untested_ok: true$/d; /^x: y$/d' tasks/in-progress/E-01.md && rm -f tasks/in-progress/E-01.md.bak
git add -f tasks; git commit -qm "E-01 needs a test"
out="$(factory-check E-01)"; rc=$?
check "staged: once a test command is set, min_tests holds" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "no test exercised this change"' "$out"
gcfg full '{"build":"echo built"}'
out="$(factory-check E-01)"; rc=$?
check "full: no test command is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "MISSING - gate_mode=full requires commands.test"' "$out"
gcfg full '{"build":"echo built", "test":"echo 3 passed"}'
out="$(factory-check E-01)"; rc=$?
check "full: build and test configured, lint not, is green" '[ $rc -eq 0 ]' "$out"
gcfg staged '{}'
out="$(factory-check --full)"; rc=$?
check "staged: a full check that ran nothing is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "staged mode needs at least one green stage"' "$out"

echo "=== 3.3: what only the old gate template did"
printf '00:01 +1: loads\n00:02 +11: parses\n00:03 +12: All tests passed!\n' > "$WORK/flutter.out"
check "a flutter run counts its last tally, not the sum of its lines" '[ "$(factory-check count "$WORK/flutter.out")" = 12 ]' "$(factory-check count "$WORK/flutter.out")"
printf '00:04 +7 ~1 -2: Some tests failed.\n' > "$WORK/flutter.out"
check "...with skipped and failed counts beside it" '[ "$(factory-check count "$WORK/flutter.out")" = 7 ]'
mktask in-progress E-02 "" "true" src/a.txt
setfm tasks/in-progress/E-02.md untested_ok true
git add -f tasks; git commit -qm "approve E-02"
gcfg full '{"build":"echo built", "test":"echo 3 passed"}'
mkdir -p gates; printf 'echo "extra got $1"; exit 1\n' > gates/extra.sh
out="$(factory-check E-02)"; rc=$?
check "gates/extra.sh is the last stage of a task check, and its failure is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "extra    FAIL (gates/extra.sh exit 1)" && printf "%s" "$out" | grep -q "extra got E-02"' "$out"
printf 'echo "extra got $1"\n' > gates/extra.sh
out="$(factory-check E-02)"; rc=$?
check "...and its pass is a stage like the others" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "extra    PASS"' "$out"
jq '.commands.lint = "true"' .factory/config.json > c && mv c .factory/config.json
out="$(factory-check --full)"; rc=$?
check "the full check runs it with --full" '[ $rc -eq 0 ] && grep -q "extra got --full" "$(sed -n "s/^log=//p" .factory/full-check)"' "$out"
rm -rf gates
printf 'ok\n' > src/a.txt; mkdir -p deps; printf 'lib\n' > deps/lib.txt; printf 'deps/\n' >> .gitignore
git add -A; git commit -qm "a is ok"
printf 'bad\n' > src/a.txt
jq -n '{gate_mode:"full", min_tests:1, gate_isolation:true, isolation_links:["deps"],
  commands:{build:"grep -q ok src/a.txt && grep -q lib deps/lib.txt", test:"echo 3 passed", lint:"true"}}' > .factory/config.json
out="$(factory-check --full)"; rc=$?
check "an isolated full check builds HEAD, not what is uncommitted, and says so" '[ $rc -eq 0 ] && grep -q "^isolated=yes" .factory/full-check' "$out"
check "...and the tree it linked in is still there afterwards" '[ -f deps/lib.txt ] && [ "$(git worktree list | wc -l | tr -d " ")" = 1 ]' "$(git worktree list)"
jq '.gate_isolation = false' .factory/config.json > c && mv c .factory/config.json
out="$(factory-check --full)"; rc=$?
check "...the same check in the shared tree sees the break" '[ $rc -eq 1 ] && grep -q "^isolated=no" .factory/full-check' "$out"
jq '.gate_isolation = true | .commands.build = "grep -q ok src/a.txt && ! grep -q broken src/b.txt"' .factory/config.json > c && mv c .factory/config.json
printf 'ok\n' > src/a.txt; printf 'broken\n' > src/b.txt
out="$(factory-check E-02)"; rc=$?
check "an isolated task check holds HEAD plus the task's files: a neighbour's file is not there" '[ $rc -eq 0 ] && grep -q "^isolated=yes" .factory/verified/E-02' "$out"
rm -f src/b.txt; git checkout -q src/a.txt

echo "=== 3.3: what makes the suite green is not the task's"
cd "$G" || exit 1
jq -n '{gate_mode:"full", min_tests:1, commands:{build:"echo built", test:"echo 3 passed", lint:"true"}}' > .factory/config.json
printf '{"name":"e","scripts":{"test":"jest","build":"tsc"}}\n' > package.json
printf '[project]\nname = "e"\n\n[tool.pytest.ini_options]\naddopts = "-q"\n' > pyproject.toml
git add -A; git commit -qm "manifests"
mktask in-progress E-03 "" "true" src/a.txt package.json pyproject.toml
setfm tasks/in-progress/E-03.md untested_ok true
setfm tasks/in-progress/E-03.md dependencies '[*]'
git add -f tasks; git commit -qm "approve E-03"
printf '{"name":"e","scripts":{"test":"jest --passWithNoTests","build":"tsc"}}\n' > package.json
out="$(factory-check E-03)"; rc=$?
check "a task that changes scripts.test is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "this task changes how the tests run: package.json scripts.test"' "$out"
printf '{"name":"e","scripts":{"test":"jest","build":"tsc -b"}}\n' > package.json
printf '[project]\nname = "e2"\n\n[tool.pytest.ini_options]\naddopts = "-q"\n' > pyproject.toml
out="$(factory-check E-03)"; rc=$?
check "...the rest of package.json and pyproject.toml is not the tests" '! printf "%s" "$out" | grep -q "how the tests run"' "$out"
printf '[project]\nname = "e"\n\n[tool.pytest.ini_options]\naddopts = "-q -k not_slow"\n' > pyproject.toml
out="$(factory-check E-03)"; rc=$?
check "a change to [tool.pytest.ini_options] is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "pyproject.toml \[tool.pytest.ini_options\]"' "$out"
setfm tasks/in-progress/E-03.md modifies_tests '[pyproject.toml]'
git add -f tasks; git commit -qm "E-03 may change pyproject.toml's tests"
out="$(factory-check E-03)"; rc=$?
check "an approved modifies_tests list covers it" '! printf "%s" "$out" | grep -q "how the tests run"' "$out"
git checkout -q package.json pyproject.toml

echo "=== 3.3: cheat signatures in what a task adds"
C="$WORK/cheat"; rm -rf "$C"; mkdir -p "$C/.factory" "$C/src" "$C/tests"; cd "$C" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
: > .factory/active; printf '.factory/\n' > .gitignore
printf 'import sys\nsys.exit(0)\n' > src/legacy.py
git add -A; git commit -qm base
P="$C"
jq -n '{min_tests:1, commands:{build:"echo built", test:"echo 3 passed", lint:"true"}}' > .factory/config.json
mktask in-progress C-01 "" "true" src/app.py src/app.js src/tool.py src/legacy.py conftest.py
git add -f tasks; git commit -qm "approve C-01"
put() { mkdir -p "$(dirname "$1")"; printf '%b' "$2" > "$1"; }
cx() { out="$(factory-check C-01)"; rc=$?; }
clean() { rm -f src/app.py src/app.js src/tool.py conftest.py; git checkout -q src/legacy.py; }
setcheck() { jq --argjson c "$1" '.check = $c' .factory/config.json > c.tmp && mv c.tmp .factory/config.json; }
put src/app.py 'import sys\n\ndef run():\n    sys.exit(0)\n'; cx
check "sys.exit(0) in product code is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "src/app.py:4 exit-zero"' "$out"
clean; put src/tool.py 'import sys\n\ndef main():\n    sys.exit(0)\n\nif __name__ == "__main__":\n    main()\n'; cx
check "...but not in an entry point" '[ $rc -eq 0 ]' "$out"
clean; put src/app.js 'function done() {\n  process.exit(0)\n}\n'; cx
check "process.exit(0) is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "src/app.js:2 exit-zero"' "$out"
clean; put src/app.js 'function fail() {\n  process.exit(1)\n}\n'; cx
check "...process.exit(1) is not" '[ $rc -eq 0 ]' "$out"
clean; put src/app.py 'import unittest\n\ndef load():\n    raise unittest.SkipTest("later")\n'; cx
check "SkipTest outside the tests is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "skip-outside-tests"' "$out"
clean; put src/app.py 'def skip_header(rows):\n    return rows[1:]\n'; cx
check "...a function named skip is not" '[ $rc -eq 0 ]' "$out"
clean; put src/app.py 'import inspect\n\ndef answer():\n    caller = inspect.stack()[1]\n    return 42\n'; cx
check "inspect.stack() in product code is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "frame-read"' "$out"
clean; put src/app.py 'import inspect\n\ndef params(f):\n    return inspect.signature(f)\n'; cx
check "...inspect.signature is not" '[ $rc -eq 0 ]' "$out"
clean; put src/app.py 'import json\n\ndef answer():\n    return json.load(open("tests/fixtures/expected.json"))\n'; cx
check "product code that opens a test file is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "reads-tests"' "$out"
clean; put src/app.py 'import json\n\ndef answer():\n    log("see tests/ for examples")\n    return json.load(open("data/answer.json"))\n'; cx
check "...opening a data file, or naming tests/ in a message, is not" '[ $rc -eq 0 ]' "$out"
clean; put conftest.py 'import pytest\n\n@pytest.hookimpl(hookwrapper=True)\ndef pytest_runtest_makereport(item, call):\n    outcome = yield\n    outcome.get_result().outcome = "passed"\n'; cx
check "a report hook in a new conftest.py is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "report-patch"' "$out"
clean; put conftest.py 'import pytest\n\n@pytest.fixture\ndef client():\n    return object()\n'; cx
check "...a fixture is not" '[ $rc -eq 0 ]' "$out"
clean; put src/app.py '# never sys.exit(0) here: the caller decides\ndef run():\n    return 0\n'; cx
check "a comment that names a signature is not one" '[ $rc -eq 0 ]' "$out"
clean; printf '\ndef extra():\n    return 1\n' >> src/legacy.py; cx
check "what HEAD already had is not this task's" '[ $rc -eq 0 ]' "$out"
clean; put src/app.py 'import sys\n\ndef run():\n    sys.exit(0)\n'; setcheck '{"entry_points":["src/app.py"]}'; cx
check "check.entry_points makes a file an entry point" '[ $rc -eq 0 ]' "$out"
clean; put src/app.py 'import inspect\n\ndef where():\n    return inspect.stack()[1].filename\n'; setcheck '{"cheat_allow":["frame-read:src/*"]}'; cx
check "check.cheat_allow lets the developer allow one" '[ $rc -eq 0 ]' "$out"
setcheck '{"cheat_guard":false}'; clean; put src/app.py 'import sys\nsys.exit(0)\n'; cx
check "check.cheat_guard false turns the stage off" '[ $rc -eq 0 ]' "$out"
setcheck '{}'
clean; put src/app.py 'class Money:\n    def __eq__(self, other):\n        return True\n'; cx
check "an __eq__ that is always true is green..." '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "reason(s) for a reviewer"' "$out"
check "...with the reason in the marker" 'grep -q "^review=cheat signature eq-always-true at src/app.py:2" .factory/verified/C-01'
check "the marker holds a digest of the task's files, for factory-land" 'grep -qx "files=$(factory-check fingerprint C-01)" .factory/verified/C-01'
out="$(factory-risk C-01)"; rc=$?
check "...and factory-risk sends it to a reviewer" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "RISK C-01: cheat signature eq-always-true"' "$out"
clean; put src/app.py 'class Money:\n    def __eq__(self, other):\n        """Same amount, same currency."""\n        return (self.amount, self.currency) == (other.amount, other.currency)\n'; cx
check "an honest __eq__ is no reason" '[ $rc -eq 0 ] && ! grep -q "^review=" .factory/verified/C-01' "$out"
out="$(factory-risk C-01)"; rc=$?
check "...and factory-risk finds nothing" '[ $rc -eq 0 ]' "$out"
clean; put src/app.js 'Object.defineProperty(expect, "toBe", { value: () => true })\n'; cx
check "patching the test framework goes to a reviewer" '[ $rc -eq 0 ] && grep -q "^review=cheat signature framework-patch" .factory/verified/C-01' "$out"
clean

echo "=== 3.3: HEAD's version of a changed test, run on the new code"
Z="$WORK/frozen"; rm -rf "$Z"; mkdir -p "$Z/.factory" "$Z/src" "$Z/tests"; cd "$Z" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
: > .factory/active; printf '.factory/\n' > .gitignore
printf '1\n' > src/value.txt; printf '1\n' > tests/test_value.py
git add -A; git commit -qm base
P="$Z"
jq -n '{min_tests:1, commands:{build:"true", lint:"true", test:"grep -qxF \"$(cat src/value.txt)\" tests/test_value.py && echo \"1 passed\""}}' > .factory/config.json
mktask in-progress F-01 "" "true" src/value.txt tests/test_value.py
setfm tasks/in-progress/F-01.md modifies_tests true
git add -f tasks; git commit -qm "approve F-01"
printf '2\n' > src/value.txt; printf '2\n' > tests/test_value.py
out="$(factory-check F-01)"; rc=$?
check "a task that rewrote a test to match new code is green..." '[ $rc -eq 0 ]' "$out"
check "...but HEAD's test, run on that code, fails and a reviewer is asked" 'printf "%s" "$out" | grep -q "HEAD.s version of tests/test_value.py fails" && grep -q "^review=frozen suite: " .factory/verified/F-01' "$out"
out="$(factory-risk F-01)"; rc=$?
check "...factory-risk names it" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "RISK F-01: frozen suite"' "$out"
check "...and the main tree is as the task left it" 'grep -qx "isolated=no" .factory/verified/F-01 && [ "$(cat tests/test_value.py)" = 2 ] && [ -z "$(git worktree list | sed 1d)" ]'
printf '1\n' > src/value.txt; printf '1\n2\n' > tests/test_value.py
out="$(factory-check F-01)"; rc=$?
check "a test that only gained a case still passes in HEAD's form: no reason" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "still passes against the new code" && ! grep -q "^review=" .factory/verified/F-01' "$out"
git checkout -q tests/test_value.py
out="$(factory-check F-01)"; rc=$?
check "no test changed: nothing extra runs" '[ $rc -eq 0 ] && ! printf "%s" "$out" | grep -q "frozen"' "$out"
printf '2\n' > src/value.txt; printf '2\n' > tests/test_value.py
jq '.check = {frozen_suite:false}' .factory/config.json > c.tmp && mv c.tmp .factory/config.json
out="$(factory-check F-01)"; rc=$?
check "check.frozen_suite false turns it off" '[ $rc -eq 0 ] && ! printf "%s" "$out" | grep -q "frozen"' "$out"
git checkout -q src/value.txt tests/test_value.py

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
