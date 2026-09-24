#!/usr/bin/env bash
# Sandbox tests: the fast lane - factory-check (units, reach, guards, the
# per-task census, no-progress, the full check), factory-plan, factory-start,
# factory-land, factory-block, factory-finish, the /factory:fast workflow's
# scheduling, and the claim/telemetry fixes it relies on.
#
# The project in the sandbox is written in no language at all: its "toolchain"
# is a handful of shell scripts, its tests are *.t files, and everything the
# check knows about it comes from .factory/config.json. That is the point - the
# check must work for any project whose config says how to build and test it.
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
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
grep -rn BUILD_ERROR core api ui tools && { echo "error: build broke"; exit 1; }; exit 0
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
check "the marker says it came from the fast check" 'grep -q "^check=fast" .factory/verified/T-01 && grep -q "^tree=" .factory/verified/T-01 && grep -q "^tests=6" .factory/verified/T-01' "$(cat .factory/verified/T-01 2>/dev/null)"
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
printf 'exit 0\n' > core/tests/main.t
out="$(factory-check T-01)"; rc=$?
check "green again clears the no-progress flag" '[ $rc -eq 0 ] && [ ! -f .factory/no-progress/T-01 ] && [ -f .factory/failures/resolved/T-01.log ]' "$out"
printf 'value BUILD_ERROR\n' > core/src/main.src
out="$(factory-check T-01)"; rc=$?
check "a build failure is red and quoted" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "build    FAIL" && printf "%s" "$out" | grep -q "error: build broke"' "$out"
printf 'value\n' > core/src/main.src

echo "=== guards"
printf 'helper v2\n' > tools/gen.src
mktask in-progress T-02 "" "bash tools-note.sh" tools/gen.src
printf 'echo ok\n' > tools-note.sh
out="$(factory-check T-02)"; rc=$?
check "a change no test exercises is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "no test exercised this change"' "$out"
setfm tasks/in-progress/T-02.md untested_ok true
out="$(factory-check T-02)"; rc=$?
check "untested_ok written in the task waives it" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "waived by untested_ok"' "$out"
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

echo "=== the census is judged per task, against HEAD"
rm -f api/tests/main.t
mktask in-progress T-05 "" "bash runner.sh api" api/src/main.src api/tests/main.t
out="$(factory-check T-05)"; rc=$?
check "a task that deletes a tracked test file is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "this task deletes test file(s): api/tests/main.t"' "$out"
setfm tasks/in-progress/T-05.md allow_test_removal true
out="$(factory-check T-05)"; rc=$?
check "allow_test_removal written in the task waives it" '! printf "%s" "$out" | grep -q "census"' "$out"
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

echo "=== acceptance is executed, not reported"
printf 'echo "acceptance ran"; exit 1\n' > accept-red.sh
mktask in-progress T-09 "" "bash accept-red.sh" ui/src/main.src
out="$(factory-check T-09)"; rc=$?
check "a failing acceptance command is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "accept   FAIL (exit 1)"' "$out"

echo "=== the full check runs the project's own gate commands"
out="$(factory-plan --json --start)"
check "a planned run records where it started" 'jq -e ".test_files == 3 and (.files | length) == 3 and (.tasks | length) > 0" .factory/run-start.json >/dev/null' "$(cat .factory/run-start.json 2>/dev/null)"
: > .factory/tool.log
out="$(factory-check --full)"; rc=$?
check "the full check runs build, test and lint" '[ $rc -eq 0 ] && [ "$(tools_log)" = "build,runner .,lint," ] && printf "%s" "$out" | grep -q "test     PASS (6 test(s))"' "$(tools_log) / $out"
check "its verdict is recorded" 'grep -q "^verdict=green" .factory/full-check && grep -q "^tests=6" .factory/full-check'
jq '.commands.test = "echo no tests found"' .factory/config.json > c && mv c .factory/config.json
out="$(factory-check --full)"; rc=$?
check "a suite that ran zero tests is never a green full check" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "reported 0 test(s)"' "$out"
jq '.commands.test = "echo done"' .factory/config.json > c && mv c .factory/config.json
out="$(factory-check --full)"; rc=$?
check "an unrecognised count passes but says so" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "count not recognised - set check.count"' "$out"
jq '.commands.test = "echo done; echo \"ran=7\"" | .check.count = "ran=(\\d+)"' .factory/config.json > c && mv c .factory/config.json
out="$(factory-check --full)"
check "check.count teaches it any runner's summary" 'printf "%s" "$out" | grep -q "test     PASS (7 test(s))"' "$out"
jq '.commands.test = "bash runner.sh ." | del(.check.count)' .factory/config.json > c && mv c .factory/config.json
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
check "plan carries the fast-lane config" '[ "$(jq -c "[.workers, .effort.build, .effort.escalate]" <<< "$j")" = "[3,\"high\",\"xhigh\"]" ]' "$j"
check "a task left in progress is named" 'jq -e ".warnings | map(select(test(\"in-progress: R\"))) | length == 1" <<< "$j" >/dev/null' "$j"
mktask backlog K "L" "x" a; mktask backlog L "K" "x" a
j="$(factory-plan --json)"; rc=$?
check "a dependency cycle stops the plan" '[ $rc -eq 1 ] && jq -e ".ok == false and (.problems[0] | test(\"cycle\"))" <<< "$j" >/dev/null' "$j"

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
out="$(factory-land C2-01)"; rc=$?
check "land refuses without a green check" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "LAND REFUSED" && [ -f tasks/in-progress/C2-01.md ]' "$out"
printf 'y\n' > src/x.txt; touch .factory/verified/C2-01
out="$(factory-land C2-01)"; rc=$?
check "land moves to done and commits exactly the task" '[ $rc -eq 0 ] && [ -f tasks/done/C2-01.md ] && printf "%s" "$out" | grep -q "^LANDED C2-01 [0-9a-f]" && git log -1 --format=%B | grep -q "Factory-Task: C2-01"' "$out"
check "land records the move and the commit in the event log" 'jq -e "select(.kind==\"commit\" and .task==\"C2-01\")" .factory/events.jsonl >/dev/null && jq -e "select(.kind==\"move\" and .to==\"done\")" .factory/events.jsonl >/dev/null'
mktask backlog C2-02 "" "bash run.sh" src/x.txt
sed -i.bak 's/^title: .*/title: <placeholder>/; s/^acceptance: .*/acceptance: <command>/' tasks/backlog/C2-02.md; rm -f tasks/backlog/C2-02.md.bak
out="$(factory-start C2-02)"; rc=$?
check "start refuses a task that does not lint" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "does not lint" && [ -f tasks/backlog/C2-02.md ]' "$out"
mktask backlog C2-03 "" "bash run.sh" src/x.txt; touch .factory/verified/C2-03
out="$(factory-block C2-03 "needs the payment provider decided")"
check "block moves the task with its reason and drops its marker" '[ -f tasks/blocked/C2-03.md ] && grep -q "needs the payment provider decided" tasks/blocked/C2-03.md && [ ! -f .factory/verified/C2-03 ]' "$out"


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
check "finish puts what a builder left open first" 'jq -e ".attention == [{\"id\":\"F-01\",\"concern\":\"the id /start returns is never accepted by /next\"}]" <<< "$out" >/dev/null' "$out"
check "finish reads where each task is and which commit carries it" 'jq -e "[.board[] | .lane] == [\"done\",\"blocked\",\"backlog\"] and .board[0].commit != null and .board[1].reason == \"2026-01-01T00:00:00Z: needs the provider decided\"" <<< "$out" >/dev/null' "$out"
check "with nothing new to judge the full check is skipped, and says so" 'jq -e ".full_check == \"skipped\"" <<< "$out" >/dev/null' "$out"
check "the report is written for the developer too" 'grep -q "## Needs your attention" .factory/last-run.md && grep -q "| F-02 | blocked |" .factory/last-run.md'

echo "=== the workflow's scheduling (JavaScriptCore)"
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
if [ -x "$JSC" ]; then
  harness() {  # <scenario js defining agent()> -> prints result JSON and call order
    { cat <<'JS'
var logs=[]; function log(m){logs.push(m)} function phase(p){}
var args={workers:2}; var calls=[]; var prompts={};
JS
      printf '%s\n' "$1"
      echo "async function __main(){"
      sed '1,/^}$/d' "${PLUGIN}/workflows/fast.js"
      echo "}"
      echo "__main().then(function(r){ print(JSON.stringify(r)); print('CALLS '+calls.join(',')); print('FINISH '+prompts.finish) }, function(e){ print('ERROR '+e) });"
    } > "$WORK/wf.js"
    "$JSC" "$WORK/wf.js"
  }
  base='function reply(o){return Promise.resolve(o)}
function agent(p,o){var l=(o&&o.label)||""; calls.push(l); prompts[l]=p;
 if(l==="plan") return reply({ok:true,tasks:[{id:"A",deps:[]},{id:"B",deps:["A"]},{id:"C",deps:["A"]},{id:"D",deps:["B","C"],review:true}]});
 if(l==="finish") return reply({attention:[{id:"B",concern:"gap"}],board:[{id:"A",lane:"done",commit:"abc"}],full_check:"green"});
 if(/ land$/.test(l)||/ block$/.test(l)) return reply({ok:true,line:"LANDED"});
 if(/ review$/.test(l)) return reply({verdict:"pass",findings:[]});
 if(l==="D") return reply({id:"D",status:"review",summary:"returning review, not landed",concerns:[]});'
  out="$(harness "$base
 return reply({id:l,status:\"landed\",summary:\"ok\",concerns:[]}); }")"
  calls="$(printf '%s\n' "$out" | sed -n 's/^CALLS //p')"
  check "dependents start only after what they need has landed" 'printf "%s" "$calls" | grep -Eq "^plan,A,(B,C|C,B),D,D review,D land,finish$"' "$out"
  check "the plan step records where the run started" 'grep -q "factory-plan --json --start" "$WORK/wf.js"'
  check "a reviewed and landed task no longer says it awaits review" 'printf "%s" "$out" | head -1 | jq -e "(.agent_notes[] | select(.id==\"D\") | .status == \"landed\" and (.summary | startswith(\"reviewed and landed\")))" >/dev/null' "$out"
  check "the result leads with what needs attention and the board from disk" 'printf "%s" "$out" | head -1 | jq -e "(keys_unsorted | .[0:2]) == [\"attention\",\"board\"] and .attention[0].concern == \"gap\"" >/dev/null' "$out"
  check "finish is told every task of the run" 'printf "%s" "$out" | grep -q "^FINISH .*factory-finish --tasks A,B,C,D$"' "$out"
  out="$(harness "$base
 if(l===\"A\") return reply({id:\"A\",status:\"red\",summary:\"x\",concerns:[]});
 if(l===\"A retry\") return reply({id:\"A\",status:\"red\",summary:\"still\",concerns:[]});
 return reply({id:l,status:\"landed\",summary:\"ok\",concerns:[]}); }")"
  check "a task red twice is blocked and its dependents are skipped" 'printf "%s" "$out" | head -1 | jq -e "[.agent_notes[] | .status] == [\"blocked\",\"skipped\",\"skipped\",\"skipped\"]" >/dev/null' "$out"
  check "the red task is retried once, at higher effort" 'printf "%s" "$out" | grep -q "^CALLS plan,A,A retry,A block,finish"' "$out"
  check "nothing landed: finish still reports, without a full check" 'printf "%s" "$out" | grep -q "^FINISH .*--tasks A,B,C,D --no-full"' "$out"
else
  echo "(JavaScriptCore not found - workflow scheduling tests skipped)"
fi

echo "=== fixes the fast lane depends on"
Q="$WORK/fixes"; rm -rf "$Q"; mkdir -p "$Q/.factory"; cd "$Q" || exit 1; : > .factory/active
jq -n --arg cwd "$Q" '{cwd:$cwd, session_id:"S1", tool_name:"Bash", tool_input:{command:"factory-claim"}}' | bash "$H/factory-done-guard.sh" >/dev/null
out="$(bash "$H/factory-claim.sh")"
check "the claim works the way /factory:run spells it" 'printf "%s" "$out" | grep -q "^CLAIMED"' "$out"
echo 99999999999 > .factory/.dash-stamp
jq -cn --arg c "$Q" '{cwd:$c, hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"factory-commit C2-01"}, tool_response:{stdout:"COMMIT 9f3ab12 C2-01 (C2): a", stderr:""}}' | bash "$H/factory-event.sh"
jq -cn --arg c "$Q" '{cwd:$c, hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"bash gates/verify.sh C2-02"}, tool_response:{stdout:"", stderr:"GATE RESULT: GREEN for C2-02"}}' | bash "$H/factory-event.sh"
jq -cn --arg c "$Q" '{cwd:$c, hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"factory-check C2-03"}, tool_response:{stdout:"CHECK RESULT: RED for C2-03", stderr:""}}' | bash "$H/factory-event.sh"
check "bin-style commits are recorded, read from tool_response" 'jq -e "select(.kind==\"commit\" and .sha==\"9f3ab12\")" .factory/events.jsonl >/dev/null' "$(cat .factory/events.jsonl)"
check "a gate verdict printed on stderr is recorded" 'jq -e "select(.kind==\"gate\" and .task==\"C2-02\" and .verdict==\"green\")" .factory/events.jsonl >/dev/null'
check "a factory-check verdict is recorded as a gate run" 'jq -e "select(.kind==\"gate\" and .task==\"C2-03\" and .verdict==\"red\")" .factory/events.jsonl >/dev/null'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
