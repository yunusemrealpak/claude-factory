#!/usr/bin/env bash
# Sandbox tests: the fast lane - factory-check (import graph, bundling, guards,
# no-progress), factory-plan, factory-start, factory-land, factory-block, the
# /factory:fast workflow's scheduling, and the claim/telemetry fixes it relies
# on. Never touches a real project, and needs no Dart or Flutter SDK: the
# toolchain is stubbed through the "check" block of the config.
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

# --- a Dart package whose toolchain is three stub scripts --------------------
P="$WORK/fast"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
mkdir -p .factory/verified lib/src test/helpers android stub tasks/backlog tasks/in-progress tasks/done tasks/blocked
: > .factory/active
printf 'name: app\nenvironment:\n  sdk: ^3.0.0\n' > pubspec.yaml
printf "int a() => 1;\n" > lib/a.dart
printf "import 'package:app/a.dart';\nint b() => a() + 1;\n" > lib/b.dart
printf "int c() => 3;\n" > lib/c.dart
printf "int lonely() => 4;\n" > lib/lonely.dart
printf "part 'p.g.dart';\nint p() => pg();\n" > lib/p.dart
printf "part of 'p.dart';\nint pg() => 5;\n" > lib/p.g.dart
printf "import 'package:app/b.dart';\nvoid main() {}\n" > test/a_test.dart
printf "import '../lib/c.dart';\nvoid main() {}\n" > test/c_test.dart
printf "import 'package:app/a.dart';\nint h() => 0;\n" > test/helpers/h.dart
printf "import 'helpers/h.dart';\nvoid main() {}\n" > test/h_test.dart
printf "import 'package:app/p.dart';\nvoid main() {}\n" > test/p_test.dart
# Stubs: record their arguments; the test stub fails when a test file says FAILME
# and prints the reporter's last line the way dart/flutter test does.
cat > stub/format.sh <<'SH'
echo "$@" > .factory/stub-format.args
SH
cat > stub/analyze.sh <<'SH'
echo "$@" > .factory/stub-analyze.args
grep -l ANALYZE_ERROR "$@" 2>/dev/null | sed 's/^/error - /' | grep . && exit 3
echo "No issues found!"
SH
cat > stub/test.sh <<'SH'
echo "$@" > .factory/stub-test.args
files=""
for a in "$@"; do
  case "$a" in
    *bundle_*.dart) cp "$a" .factory/stub-bundle.dart; files="$files $(sed -n "s/^import '\(.*\)' as t[0-9]*;$/\1/p" "$a" | sed 's#^\.\./\.\./##')" ;;
    *.dart) files="$files $a" ;;
  esac
done
n=0; failed=0
for f in $files; do n=$((n + 2)); grep -q FAILME "$f" 2>/dev/null && failed=$((failed + 1)); done
if [ "$failed" -gt 0 ]; then
  echo "00:01 +$n -$failed: widget renders [E]"
  echo "  Expected: <1>"
  echo "    Actual: <2>"
  echo "00:01 +$n -$failed: Some tests failed."
  exit 1
fi
echo "00:01 +$n: All tests passed!"
SH
cat > .factory/config.json <<'JSON'
{ "min_tests": 1,
  "check": { "format": "bash stub/format.sh {files}", "analyze": "bash stub/analyze.sh {files}",
             "test": "bash stub/test.sh {tests}", "full_test": "bash stub/test.sh {tests}",
             "full_analyze": "bash stub/analyze.sh lib", "full_format": "true", "bundle": true },
  "fast": { "workers": 3 } }
JSON
printf '.factory/\n.dart_tool/\n' > .gitignore
git add -A; git commit -qm base

echo "=== import graph"
out="$(factory-check affected lib/a.dart)"
check "a change reaches tests through imports and through test helpers" '[ "$(printf "%s" "$out" | tr "\n" " ")" = "test/a_test.dart test/h_test.dart" ]' "$out"
out="$(factory-check affected lib/c.dart)"
check "a relative import is resolved" '[ "$out" = "test/c_test.dart" ]' "$out"
out="$(factory-check affected lib/p.g.dart)"
check "a part file reaches the tests of its library" '[ "$out" = "test/p_test.dart" ]' "$out"
out="$(factory-check affected pubspec.yaml)"
check "pubspec reaches every test" 'printf "%s" "$out" | grep -q "^ALL pubspec.yaml"' "$out"
out="$(factory-check affected assets/data.json)"
check "an asset reaches every test" 'printf "%s" "$out" | grep -q "^ALL "' "$out"
out="$(factory-check affected android/app/Main.kt)"
check "platform code reaches no Dart test" '[ -z "$out" ]' "$out"
out="$(factory-check affected lib/lonely.dart)"
check "a file nothing imports reaches no test" '[ -z "$out" ]' "$out"

echo "=== the task check"
mktask in-progress T-01 "" "dart test test/a_test.dart" lib/a.dart test/a_test.dart
printf "int a() => 2;\n" > lib/a.dart
out="$(factory-check T-01)"; rc=$?
check "green on a clean change" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "CHECK RESULT: GREEN for T-01"' "$out"
check "the marker says it came from the fast check" 'grep -q "^check=fast" .factory/verified/T-01 && grep -q "^tree=" .factory/verified/T-01'
check "only the touched Dart files are formatted" '[ "$(cat .factory/stub-format.args)" = "lib/a.dart test/a_test.dart" ]' "$(cat .factory/stub-format.args)"
check "analysis covers the touched files and what imports them" 'for f in lib/a.dart lib/b.dart test/helpers/h.dart test/a_test.dart test/h_test.dart; do grep -q "$f" .factory/stub-analyze.args || exit 1; done' "$(cat .factory/stub-analyze.args)"
check "the selected tests run bundled into one entrypoint" 'grep -q "bundle_T-01\|bundle_T_01" .factory/stub-test.args && grep -q "a_test.dart" .factory/stub-bundle.dart && grep -q "h_test.dart" .factory/stub-bundle.dart && ! grep -q "c_test.dart" .factory/stub-bundle.dart' "$(cat .factory/stub-test.args)"
check "the bundle is removed after the run" '[ -z "$(ls .dart_tool/factory/ 2>/dev/null)" ]'
check "an acceptance that only reruns selected tests is not run twice" 'printf "%s" "$out" | grep -q "accept   PASS (covered by the selected tests)"' "$out"
check "the summary stays short" '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" -le 10 ]' "$out"
check "stage is stamped verifying" 'grep -q "^stage: verifying" tasks/in-progress/T-01.md'
check "the census baseline is written on green" 'jq -e ".test_files == 4" .factory/baseline.json >/dev/null' "$(cat .factory/baseline.json)"

echo "=== red, then the same red again"
printf "import 'package:app/b.dart';\nvoid main() {} // FAILME\n" > test/a_test.dart
out="$(factory-check T-01)"; rc=$?
check "a failing test is red with an excerpt" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "Expected: <1>" && printf "%s" "$out" | grep -q "CHECK RESULT: RED for T-01 (signature"' "$out"
check "a red check leaves no marker" '[ ! -f .factory/verified/T-01 ]'
check "the full output goes to a log, not the agent" 'printf "%s" "$out" | grep -q "full log: .factory/logs/T-01."' "$out"
out="$(factory-check T-01)"; rc=$?
check "the identical failure twice is NO PROGRESS" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "NO PROGRESS" && [ -f .factory/no-progress/T-01 ]' "$out"
printf "import 'package:app/b.dart';\nvoid main() {}\n" > test/a_test.dart
out="$(factory-check T-01)"; rc=$?
check "green again clears the no-progress flag" '[ $rc -eq 0 ] && [ ! -f .factory/no-progress/T-01 ] && [ -f .factory/failures/resolved/T-01.log ]' "$out"

echo "=== guards"
printf "int lonely() => 44;\n" > lib/lonely.dart
mktask in-progress T-02 "" "bash stub/noop.sh" lib/lonely.dart
printf 'echo ok\n' > stub/noop.sh
out="$(factory-check T-02)"; rc=$?
check "a Dart change no test reaches is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "no test exercised this change"' "$out"
sed -i.bak 's/^needs_human: false/needs_human: false\nuntested_ok: true/' tasks/in-progress/T-02.md && rm -f tasks/in-progress/T-02.md.bak
out="$(factory-check T-02)"; rc=$?
check "untested_ok written in the task waives it" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "waived by untested_ok"' "$out"
git checkout -q lib/lonely.dart
mktask in-progress T-03 "" "grep -q done decisions.md" lib/c.dart
out="$(factory-check T-03)"; rc=$?
check "a self-certifying acceptance is red before anything runs" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "self-certifying"' "$out"
mktask in-progress T-04 "" "bash stub/noop.sh"
out="$(factory-check T-04)"; rc=$?
check "an empty Files touched list is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "lists nothing under"' "$out"
jq -n '{test_files: 9, skipped: 0}' > .factory/baseline.json
mktask in-progress T-05 "" "bash stub/noop.sh" lib/c.dart
out="$(factory-check T-05)"; rc=$?
check "a shrunken test census is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "test files went from 9 to 4"' "$out"
jq -n '{test_files: 4, skipped: 0}' > .factory/baseline.json
printf "int c() => 33; // ANALYZE_ERROR\n" > lib/c.dart
out="$(factory-check T-05)"; rc=$?
check "an analyzer finding is red and quoted" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "analyze  FAIL" && printf "%s" "$out" | grep -q "error - lib/c.dart"' "$out"
git checkout -q lib/c.dart

echo "=== work in flight belongs to its own task"
printf "import 'package:app/a.dart';\nvoid main() {} // FAILME half-written by another builder\n" > test/other_test.dart
printf "int a() => 3;\n" > lib/a.dart
mktask in-progress T-06 "" "bash stub/noop.sh" lib/a.dart
out="$(factory-check T-06)"; rc=$?
check "another task's half-written test is not this task's red" '[ $rc -eq 0 ] && ! grep -q other_test .factory/stub-bundle.dart' "$out"
rm -f test/other_test.dart; git checkout -q lib/a.dart

echo "=== acceptance is executed, not reported"
printf 'echo "acceptance ran"; exit 1\n' > stub/accept-red.sh
mktask in-progress T-07 "" "bash stub/accept-red.sh" lib/c.dart
out="$(factory-check T-07)"; rc=$?
check "a failing acceptance command is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "accept   FAIL (exit 1)"' "$out"

echo "=== full check"
out="$(factory-check --full)"; rc=$?
check "the full check runs every test" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "FULL CHECK: GREEN" && for f in a_test c_test h_test p_test; do grep -q "$f" .factory/stub-bundle.dart || exit 1; done' "$out"
check "its verdict is recorded" 'grep -q "^verdict=green" .factory/full-check'

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

echo "=== the workflow's scheduling (JavaScriptCore)"
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
if [ -x "$JSC" ]; then
  harness() {  # <scenario js defining agent()> -> prints result JSON and call order
    { cat <<'JS'
var logs=[]; function log(m){logs.push(m)} function phase(p){}
var args={workers:2}; var calls=[];
JS
      printf '%s\n' "$1"
      echo "async function __main(){"
      sed '1,/^}$/d' "${PLUGIN}/workflows/fast.js"
      echo "}"
      echo "__main().then(function(r){ print(JSON.stringify(r)); print('CALLS '+calls.join(',')) }, function(e){ print('ERROR '+e) });"
    } > "$WORK/wf.js"
    "$JSC" "$WORK/wf.js"
  }
  base='function reply(o){return Promise.resolve(o)}
function agent(p,o){var l=(o&&o.label)||""; calls.push(l);
 if(l==="plan") return reply({ok:true,tasks:[{id:"A",deps:[]},{id:"B",deps:["A"]},{id:"C",deps:["A"]},{id:"D",deps:["B","C"],review:true}]});
 if(l==="finish") return reply({full_check:"green"});
 if(/ land$/.test(l)||/ block$/.test(l)) return reply({ok:true,line:"LANDED"});
 if(/ review$/.test(l)) return reply({verdict:"pass",findings:[]});
 if(l==="D") return reply({id:"D",status:"review",summary:"s"});'
  out="$(harness "$base
 return reply({id:l,status:\"landed\",summary:\"ok\"}); }")"
  calls="$(printf '%s\n' "$out" | sed -n 's/^CALLS //p')"
  check "dependents start only after what they need has landed" 'printf "%s" "$calls" | grep -Eq "^plan,A,(B,C|C,B),D,D review,D land,finish$"' "$out"
  check "a review:always task is reviewed, then landed" 'printf "%s" "$out" | head -1 | jq -e "(.landed | map(.id)) == [\"A\",\"B\",\"C\",\"D\"]" >/dev/null' "$out"
  out="$(harness "$base
 if(l===\"A\") return reply({id:\"A\",status:\"red\",summary:\"x\"});
 if(l===\"A retry\") return reply({id:\"A\",status:\"red\",summary:\"still\"});
 return reply({id:l,status:\"landed\",summary:\"ok\"}); }")"
  check "a task red twice is blocked and its dependents are skipped" 'printf "%s" "$out" | head -1 | jq -e "(.blocked | map(.id)) == [\"A\"] and (.skipped | map(.id)) == [\"B\",\"C\",\"D\"]" >/dev/null' "$out"
  check "the red task is retried once, at higher effort" 'printf "%s" "$out" | grep -q "^CALLS plan,A,A retry,A block"' "$out"
  check "nothing landed means no finish step" 'printf "%s" "$out" | head -1 | jq -e ".finish == null" >/dev/null' "$out"
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
