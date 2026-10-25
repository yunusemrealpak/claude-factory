#!/usr/bin/env bash
# Sandbox tests: opt-in depth (3.6) - the EARS form of acceptance criteria
# (plan.ears), a task's area in the run plan (fast.area_lease), and the cheat
# monitor (review.monitor): factory-monitor-submit's filter and what a verdict
# does, and factory-settle's MONITOR hint. Never touches a real project.
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

mktask() {  # <column> <id> <deps> <covers> [extra frontmatter line] [criterion...]
  local col="$1" id="$2" deps="$3" covers="$4" extra="${5:-}"
  shift 4; [ $# -gt 0 ] && shift
  mkdir -p "$P/tasks/$col"
  {
    echo "---"; echo "id: $id"; echo "title: task $id"; echo "module: core"
    echo "depends_on: [$deps]"; echo "covers: [$covers]"; echo "acceptance: bash runner.sh core"
    echo "needs_human: false"; echo "review: on-red"; echo "retries: 0"
    [ -n "$extra" ] && echo "$extra"
    echo "owner:"; echo "stage: queued"; echo "stage_since:"; echo "---"
    echo; echo "## Goal"; echo "Do the thing."; echo
    echo "## Acceptance criteria"
    if [ $# -gt 0 ]; then for c in "$@"; do echo "- [ ] $c"; done; else echo "- [ ] The core shall work."; fi
    echo
    echo "## Files touched"; echo "- core/src/$id.src"; echo
    echo "## Attempts"
  } > "$P/tasks/$col/$id.md"
}
newproj() {  # <name> -> P, cd P: a git project whose full check runs core/*.t
  P="$WORK/s18-$1"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
  git init -q -b main; git config user.email t@example.invalid; git config user.name t
  mkdir -p .factory/changes core/src core/tests tasks/backlog tasks/in-progress tasks/done tasks/blocked
  : > .factory/active
  printf 'exit 0\n' > core/tests/base.t
  cat > runner.sh <<'SH'
n=0; bad=0
for t in $(find "$1" -name '*.t' | sort); do
  n=$((n + 1)); bash "$t" || { bad=$((bad + 1)); echo "FAILED $t"; }
done
[ "$bad" -gt 0 ] && { echo "$((n - bad)) passed, $bad failed"; exit 1; }
echo "$n passed"
SH
  cat > .factory/config.json <<'JSON'
{ "gate_mode": "full", "min_tests": 1, "retry_limit": 2,
  "commands": { "build": "true", "test": "bash runner.sh core", "arch": "", "lint": "true" },
  "check": { "unit_test": "bash runner.sh {path}", "test_files": "\\.t$",
             "units": [ {"name": "core", "path": "core", "deps": []} ] },
  "risk_builtin": false, "fast": { "workers": 2 } }
JSON
  printf '.factory/\n' > .gitignore
}
reqs() {  # <change> <FR ids...>
  local c="$1"; shift
  { echo "# $c requirements"; echo; for r in "$@"; do echo "- $r: requirement $r"; done; } > ".factory/changes/$c.requirements.md"
}
setcfg() {  # <jq filter>
  jq "$1" .factory/config.json > "$WORK/cfg18" && mv "$WORK/cfg18" .factory/config.json
}

echo "=== EARS (plan.ears): a criterion in another form is a concern, never a FAIL"
newproj ears
reqs C2 FR-001 FR-002 FR-003 FR-004
mktask backlog C2-01 "" FR-001 "" "The parser shall reject an empty file." "When a user logs in, the system shall record the time."
mktask backlog C2-02 "" FR-002 "" "While offline, the app shall queue writes." "If the token is expired, then the API shall return 401."
mktask backlog C2-03 "" FR-003 "" "Where dark mode is on, the page shall use the dark palette." "AC2: the CLI SHALL print its usage."
mktask backlog C2-04 "" FR-004 "" "Rejects an empty file" "If the token is expired, the API shall return 401."
out="$(factory-lint --plan C2)"; rc=$?
check "plan.ears off (the default): no EARS concern" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^PLAN C2: PASS" && ! printf "%s" "$out" | grep -q "EARS"' "$out"
setcfg '.plan = {"ears": true}'
out="$(factory-lint --plan C2)"; rc=$?
check "on: each criterion out of form is a CONCERN - four tasks, past small_change, still no FAIL" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^PLAN C2: CONCERNS"' "$out"
check "...an unshaped criterion is named" 'printf "%s" "$out" | grep -q "^CONCERN C2: C2-04: a criterion not in EARS form .*: Rejects an empty file$"' "$out"
check "...an If without then is named" 'printf "%s" "$out" | grep -q "C2-04: a criterion not in EARS form .*If the token is expired, the API"' "$out"
check "...the five EARS shapes, any case, after a label, are not" '[ "$(printf "%s" "$out" | grep -c "not in EARS form")" = 2 ]' "$out"
out="$(factory-lint --plan C2 --json)"
check "--json carries them as concerns, not fails" '[ "$(printf "%s" "$out" | jq "[.changes[0].concerns[] | select(test(\"EARS\"))] | length")" = 2 ] && [ "$(printf "%s" "$out" | jq ".changes[0].fail | length")" = 0 ]' "$out"

echo "=== area: in the run plan, and the lease flag"
newproj area
reqs C2 FR-001 FR-002 FR-003
mktask backlog C2-01 "" FR-001 "area: db"
mktask backlog C2-02 "" FR-002 'area: "DB"'
mktask backlog C2-03 "" FR-003
git add -A; git commit -qm area
out="$(factory-preflight --json --change C2)"; rc=$?; rm -f .factory/run.lock
check "each task carries its area, lower-cased and unquoted" '[ $rc -eq 0 ] && [ "$(printf "%s" "$out" | jq -r "[.tasks[] | .area // \"-\"] | join(\",\")")" = "db,db,-" ]' "$out"
check "...a task with no area has no area key" 'printf "%s" "$out" | jq -e ".tasks[2] | has(\"area\") | not" >/dev/null' "$out"
check "...and the lease is off unless asked" 'printf "%s" "$out" | jq -e ".area_lease == false and .monitor == false" >/dev/null' "$out"
setcfg '.fast.area_lease = true | .review = {"monitor": true}'
out="$(factory-preflight --json --change C2)"; rc=$?; rm -f .factory/run.lock
check "fast.area_lease and review.monitor reach the plan" '[ $rc -eq 0 ] && printf "%s" "$out" | jq -e ".area_lease == true and .monitor == true" >/dev/null' "$out"

# A green task in progress, its marker written by hand, with a change in its file.
greentask() {  # <id> [review= line] [review mode, committed: HEAD's copy decides]
  mktask in-progress "$1" "" FR-001
  if [ -n "${3:-}" ]; then
    sed "s/^review: on-red\$/review: $3/" "tasks/in-progress/$1.md" > "$WORK/t18" && mv "$WORK/t18" "tasks/in-progress/$1.md"
  fi
  printf 'def eq(a, b):\n    return a == b\n' > "core/src/$1.src"
  git add -A; git commit -qm "base $1"
  printf 'def eq(a, b):\n    return True\n# shortcut\n' > "core/src/$1.src"
  mkdir -p .factory/verified
  { echo "tests=1"; echo "isolated=0"; echo "check=fast"; [ -n "${2:-}" ] && echo "review=$2"; } > ".factory/verified/$1"
}
submit() {  # <id> <json>
  printf '%s' "$2" | factory-monitor-submit "$1"
}

echo "=== factory-monitor-submit: evidence that cannot point at the diff counts for nothing"
newproj mon
setcfg '.review = {"monitor": true}'
greentask C2-01 "cheat signature always-true at core/src/C2-01.src:2 - returns True"
out="$(submit C2-01 '{"verdict":"cheat","evidence":[{"file":"core/src/C2-01.src","line":2,"quote":"return 42","why":"made up"},{"file":"core/src/other.src","line":1,"quote":"return True","why":"wrong file"}]}')"; rc=$?
check "a cheat whose evidence is all dropped is recorded as clear" '[ $rc -eq 0 ] && printf "%s" "$out" | tail -1 | grep -q "^MONITOR CLEAR C2-01 (a cheat verdict with no evidence"' "$out"
check "...a quote that is not an added line is dropped" 'printf "%s" "$out" | grep -q "dropped .*the quote is not in the lines this task added"' "$out"
check "...a file outside the diff is dropped" 'printf "%s" "$out" | grep -q "dropped .*core/src/other.src is not in this task.s diff"' "$out"
check "...the record says what was asked and what stood" 'jq -e ".asked == \"cheat\" and .outcome == \"clear\" and (.dropped | length) == 2 and (.evidence | length) == 0" .factory/monitor/C2-01.json >/dev/null' "$(cat .factory/monitor/C2-01.json 2>/dev/null)"
check "...the task is untouched" '[ -f tasks/in-progress/C2-01.md ] && grep -q "return True" core/src/C2-01.src'
out="$(submit C2-01 '{"verdict":"clear","evidence":[]}')"; rc=$?
check "a clear verdict: MONITOR CLEAR, the task stays for the reviewer" '[ $rc -eq 0 ] && [ "$(printf "%s" "$out" | tail -1)" = "MONITOR CLEAR C2-01" ] && [ -f tasks/in-progress/C2-01.md ]' "$out"
check "...each verdict is an event" '[ "$(grep -c "\"kind\": \"monitor\"" .factory/events.jsonl)" = 2 ] && tail -1 .factory/events.jsonl | jq -e ".task == \"C2-01\" and .outcome == \"clear\" and (.epoch | type) == \"number\" and (.ts | test(\"Z$\"))" >/dev/null' "$(cat .factory/events.jsonl 2>/dev/null)"
out="$(submit C2-01 'not json')"; rc=$?
check "input that is not JSON is refused" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^MONITOR REFUSED C2-01: the verdict is not JSON"' "$out"
out="$(submit C2-01 '{"verdict":"maybe"}')"; rc=$?
check "a verdict other than cheat or clear is refused" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^MONITOR REFUSED C2-01: \"verdict\" must be"' "$out"
out="$(submit C2-01 '{"verdict":"cheat","evidence":[{"file":"core/src/C2-01.src","line":2,"quote":"return True","why":"eq ignores both operands"}]}')"; rc=$?
check "a cheat with evidence in an added line: blocked and asked" '[ $rc -eq 0 ] && [ "$(printf "%s" "$out" | tail -1)" = "MONITOR CHEAT C2-01: blocked and asked" ]' "$out"
check "...the task is in tasks/blocked, the reason is the evidence" '[ -f tasks/blocked/C2-01.md ] && [ ! -f tasks/in-progress/C2-01.md ] && grep -q "cheat monitor found the checks passed without the work: core/src/C2-01.src:2 eq ignores both operands" tasks/blocked/C2-01.md' "$(cat tasks/blocked/C2-01.md 2>/dev/null | tail -5)"
check "...the developer is asked" 'grep -rqs "cheat monitor says C2-01" .factory/questions/' "$(ls .factory/questions 2>/dev/null)"
check "...and the event says cheat" 'tail -n 3 .factory/events.jsonl | grep "\"kind\": \"monitor\"" | tail -1 | jq -e ".outcome == \"cheat\" and .evidence == 1" >/dev/null' "$(tail -3 .factory/events.jsonl)"
out="$(submit C2-01 '{"verdict":"clear","evidence":[]}')"; rc=$?
check "a task no longer in progress is refused" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^MONITOR REFUSED C2-01: no tasks/in-progress/C2-01.md"' "$out"
greentask C2-02
rm -f .factory/verified/C2-02
out="$(submit C2-02 '{"verdict":"clear","evidence":[]}')"; rc=$?
check "a task with no green check is refused" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^MONITOR REFUSED C2-02: no green check"' "$out"

echo "=== factory-settle: the MONITOR hint"
newproj settle
greentask C2-01 "cheat signature always-true at core/src/C2-01.src:2 - returns True" always
out="$(factory-settle C2-01 done)"; rc=$?
check "review.monitor off: a cheat-type reason gives no hint" '[ $rc -eq 0 ] && [ "$(printf "%s" "$out" | tail -1)" = "SETTLED C2-01 REVIEW" ] && ! printf "%s" "$out" | grep -q "^MONITOR"' "$out"
setcfg '.review = {"monitor": true}'
out="$(factory-settle C2-01 done)"; rc=$?
check "on: the hint names the reason, and settle says REVIEW MONITOR" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^MONITOR C2-01: cheat signature always-true at core/src/C2-01.src:2 - returns True$" && [ "$(printf "%s" "$out" | tail -1)" = "SETTLED C2-01 REVIEW MONITOR" ]' "$out"
greentask C2-02 "frozen suite: the suite did not change while the code did"
out="$(factory-settle C2-02 done)"; rc=$?
check "...a frozen suite is put to the monitor before landing, too" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^MONITOR C2-02: frozen suite: " && [ "$(printf "%s" "$out" | tail -1)" = "SETTLED C2-02 REVIEW MONITOR" ] && [ -f tasks/in-progress/C2-02.md ]' "$out"
greentask C2-03 "risk path core/src/C2-03.src matches auth" always
out="$(factory-settle C2-03 done)"; rc=$?
check "...a reason that is not cheat-type gives no hint" '[ $rc -eq 0 ] && [ "$(printf "%s" "$out" | tail -1)" = "SETTLED C2-03 REVIEW" ] && ! printf "%s" "$out" | grep -q "^MONITOR"' "$out"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
