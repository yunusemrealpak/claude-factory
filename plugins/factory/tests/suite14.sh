#!/usr/bin/env bash
# Sandbox tests: the plan and what a run is judged by (3.5) - the plan check
# (factory-lint --plan), the built-in review triggers (factory-risk), criteria
# files chosen by path (factory-criteria), must-haves (factory-musthaves), and
# the preflight's plan check and start check. Never touches a real project.
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

mktask() {  # <column> <id> <deps> <covers> <acceptance> [body line]
  mkdir -p "$P/tasks/$1"
  {
    echo "---"; echo "id: $2"; echo "title: task $2"; echo "module: core"
    echo "depends_on: [$3]"; echo "covers: [$4]"; echo "acceptance: $5"
    echo "needs_human: false"; echo "review: on-red"; echo "retries: 0"
    echo "owner:"; echo "stage: queued"; echo "stage_since:"; echo "---"
    echo; echo "## Goal"; echo "Do the thing. ${6:-}"; echo
    echo "## Acceptance criteria"; echo "- [ ] it works"; echo
    echo "## Files touched"; echo "- core/src/$2.src"; echo
    echo "## Attempts"
  } > "$P/tasks/$1/$2.md"
}
newproj() {  # <name> -> P, cd P: a git project whose full check runs core/*.t
  P="$WORK/s14-$1"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
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

echo "=== the plan check: a defective plan fails"
newproj plan
reqs C2 FR-001 FR-002 FR-003
printf '\n## Clarifications\n- Q1: which format? CSV\n' >> .factory/changes/C2.requirements.md
mktask backlog C2-01 "" FR-001 "bash runner.sh core"
mktask backlog C2-02 "C2-03" FR-002 "bash runner.sh core"
mktask backlog C2-03 "C2-02" FR-002 "npm run dev"
mktask backlog C2-04 "C2-01" FR-009 "bash runner.sh core" "Which date format? [NEEDS CLARIFICATION: ask the developer]"
mktask backlog C2-05 "" FR-001 "bash runner.sh core || true" 'Remove the `TODO` comments.'
out="$(factory-lint --plan C2)"; rc=$?
check "a defective plan is a FAIL, exit 1" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^PLAN C2: FAIL"' "$out"
check "...a requirement no task builds" 'printf "%s" "$out" | grep -q "FR-003 has no task that builds it"' "$out"
check "...a dependency cycle" 'printf "%s" "$out" | grep -q "a dependency cycle: C2-0[23] -> C2-0[23] -> C2-0[23]"' "$out"
check "...a task covering a requirement the list does not have" 'printf "%s" "$out" | grep -q "C2-04 covers FR-009"' "$out"
check "...an open question left in a task" 'printf "%s" "$out" | grep -q "C2-04 still has \[NEEDS CLARIFICATION\]"' "$out"
check "...an acceptance command that never exits" 'printf "%s" "$out" | grep -q "C2-03: acceptance runs in watch mode"' "$out"
check "...an acceptance command that cannot fail" 'printf "%s" "$out" | grep -q "C2-05: acceptance cannot fail"' "$out"
check "a marker quoted in code is not an open question" '! printf "%s" "$out" | grep -q "C2-05 still has TODO"' "$out"
check "the coverage table names each requirement" 'printf "%s" "$out" | grep -q "^COVERAGE C2 FR-001 -> C2-01, C2-05$" && printf "%s" "$out" | grep -q "^COVERAGE C2 FR-003 -> (none)$"' "$out"
out="$(factory-lint --plan C2 --json)"
check "--json carries the verdict" '[ "$(printf "%s" "$out" | jq -r .verdict)" = FAIL ] && [ "$(printf "%s" "$out" | jq ".changes[0].coverage | length")" = 3 ]' "$out"
git add -A; git commit -qm plan
out="$(factory-preflight --json --change C2)"; rc=$?
check "the preflight does not start a run on a FAIL" '[ $rc -eq 1 ] && printf "%s" "$out" | jq -e ".ok == false and (.problems | map(test(\"plan of C2 fails its check\")) | any)" >/dev/null' "$out"
check "...and writes no run lock" '[ ! -f .factory/run.lock ]'

echo "=== the plan check: a sound plan passes"
newproj good
reqs C3 FR-001 FR-002
mktask backlog C3-01 "" FR-001 "bash runner.sh core"
mktask backlog C3-02 "C3-01" FR-002 "bash runner.sh core"
mktask backlog C3-03 "C3-01" "FR-001, FR-002" "bash runner.sh core"
mktask backlog C3-04 "C3-02, C3-03" FR-002 "bash runner.sh core"
out="$(factory-lint --plan C3)"; rc=$?
check "every requirement covered, no cycle: PASS" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^PLAN C3: PASS (4 task(s), 2 requirement(s))"' "$out"
mktask backlog C3-05 "" "" "bash runner.sh core"
out="$(factory-lint --plan C3)"; rc=$?
check "a task that covers nothing is unrequested work: FAIL" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "C3-05 covers no requirement"' "$out"
rm tasks/backlog/C3-05.md
for i in 1 2 3 4 5 6 7 8 9; do printf -- '- [ ] criterion %s\n' "$i"; done > "$WORK/crit.txt"
awk -v f="$WORK/crit.txt" '/^## Acceptance criteria$/ {print; while ((getline l < f) > 0) print l; skip=1; next} skip && /^- \[ \]/ {next} {skip=0; print}' tasks/backlog/C3-04.md > "$WORK/c.md" && mv "$WORK/c.md" tasks/backlog/C3-04.md
out="$(factory-lint --plan C3)"; rc=$?
check "nine acceptance criteria is past one builder: FAIL" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "C3-04 has 9 acceptance criteria (at most 8)"' "$out"
jq '.plan = {max_criteria: 10}' .factory/config.json > "$WORK/cfg" && mv "$WORK/cfg" .factory/config.json
out="$(factory-lint --plan C3)"; rc=$?
check "plan.max_criteria raises the ceiling" '[ $rc -eq 0 ]' "$out"
printf '\n## Clarifications\n' >> .factory/changes/C3.requirements.md
for i in 1 2 3 4 5 6; do printf -- '- Q%s: question %s? answer\n' "$i" "$i" >> .factory/changes/C3.requirements.md; done
out="$(factory-lint --plan C3)"; rc=$?
check "more than five clarifying questions is a concern, not a FAIL" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^CONCERN C3: 6 clarifying questions" && printf "%s" "$out" | grep -q "^PLAN C3: CONCERNS"' "$out"

echo "=== the plan check: a small change is not held to ceremony"
newproj small
reqs C4 FR-001 FR-002
mktask backlog C4-01 "" FR-001 "bash runner.sh core" "TODO decide the name"
out="$(factory-lint --plan C4)"; rc=$?
check "an uncovered requirement and a marker in a one-task change: CONCERNS" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^CONCERN C4: FR-002 has no task" && printf "%s" "$out" | grep -q "^PLAN C4: CONCERNS"' "$out"
mktask backlog C4-02 "C4-03" FR-002 "bash runner.sh core"
mktask backlog C4-03 "C4-02" FR-002 "bash runner.sh core"
out="$(factory-lint --plan C4)"; rc=$?
check "...but a broken graph fails even a small change" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^FAIL C4: a dependency cycle"' "$out"
rm .factory/changes/C4.requirements.md tasks/backlog/C4-0[23].md
mktask backlog C4-02 "" "" "bash runner.sh core"; mktask backlog C4-03 "" "" "bash runner.sh core"; mktask backlog C4-04 "" "" "bash runner.sh core"
sed -i.bak 's/TODO decide the name//' tasks/backlog/C4-01.md && rm -f tasks/backlog/C4-01.md.bak
out="$(factory-lint --plan C4)"; rc=$?
check "no requirement list on a larger change: a concern, coverage unchecked" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^CONCERN C4: no requirement list"' "$out"

echo "=== built-in review triggers"
newproj risk
mkdir -p .github/workflows gates src/__mocks__ db/migrations src/gates
for f in conftest.py .github/workflows/ci.yml gates/verify.sh src/__mocks__/api.js db/migrations/0001.sql src/gates/logic.py src/app.py src/client.mock.ts; do printf 'x\n' > "$f"; done
git add -A; git commit -qm files
risktask() {  # <id> <files...>
  local id="$1"; shift
  { echo "---"; echo "id: $id"; echo "title: t"; echo "module: core"; echo "depends_on: []"; echo "acceptance: true"
    echo "needs_human: false"; echo "retries: 0"; echo "stage: queued"; echo "---"; echo; echo "## Files touched"
    for f in "$@"; do echo "- $f"; done; echo; echo "## Attempts"; } > "tasks/in-progress/$id.md"
}
jq '.risk_builtin = true' .factory/config.json > "$WORK/cfg" && mv "$WORK/cfg" .factory/config.json
risktask R-01 conftest.py .github/workflows/ci.yml gates/verify.sh src/__mocks__/api.js db/migrations/0001.sql src/client.mock.ts
out="$(factory-risk R-01)"; rc=$?
check "test harness configuration is always reviewed" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "conftest.py is test harness configuration"' "$out"
check "...CI configuration" 'printf "%s" "$out" | grep -q ".github/workflows/ci.yml is CI configuration"' "$out"
check "...the project's gates" 'printf "%s" "$out" | grep -q "gates/verify.sh is one of the project.s gates"' "$out"
check "...test doubles, by folder and by name" 'printf "%s" "$out" | grep -q "src/__mocks__/api.js is a test double" && printf "%s" "$out" | grep -q "src/client.mock.ts is a test double"' "$out"
check "...migrations" 'printf "%s" "$out" | grep -q "db/migrations/0001.sql is a migration"' "$out"
risktask R-02 src/app.py src/gates/logic.py
out="$(factory-risk R-02)"; rc=$?
check "plain code, and a gates/ folder that is not the project's, are not" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^RISK none for R-02"' "$out"
jq '.risk_paths = ["*/migrations/*"]' .factory/config.json > "$WORK/cfg" && mv "$WORK/cfg" .factory/config.json
out="$(factory-risk R-01)"
check "the project's own pattern is named before the built-in reason" 'printf "%s" "$out" | grep -q "db/migrations/0001.sql matches \"\*/migrations/\*\"" && ! printf "%s" "$out" | grep -q "0001.sql is a migration"' "$out"
jq '.risk_builtin = false | del(.risk_paths)' .factory/config.json > "$WORK/cfg" && mv "$WORK/cfg" .factory/config.json
out="$(factory-risk R-01)"; rc=$?
check "risk_builtin false turns the built-in list off" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "only the size was checked"' "$out"

echo "=== a large change is reviewed"
seq 1 450 > src/big.py
risktask R-03 src/big.py
out="$(factory-risk R-03)"; rc=$?
check "an untracked file of 450 lines is past review.max_lines (400)" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "the change is 450 lines (review.max_lines is 400)"' "$out"
git add src/big.py; git commit -qm big
seq 1 300 >> src/app.py
risktask R-04 src/app.py
out="$(factory-risk R-04)"; rc=$?
check "a tracked change under the limit is not" '[ $rc -eq 0 ]' "$out"
seq 1 200 >> src/app.py
out="$(factory-risk R-04)"; rc=$?
check "...and over it, counted against HEAD, is" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "the change is 500 lines"' "$out"
jq '.review = {max_lines: 0}' .factory/config.json > "$WORK/cfg" && mv "$WORK/cfg" .factory/config.json
out="$(factory-risk R-04)"; rc=$?
check "review.max_lines 0 turns it off" '[ $rc -eq 0 ]' "$out"
git checkout -q -- src/app.py

echo "=== criteria files, chosen by the paths a task names"
newproj crit
mkdir -p .factory/criteria
printf -- '---\napplies_to: ["src/api/**"]\n---\n- Every handler reads the tenant from the session.\n' > .factory/criteria/api.md
printf -- '---\nmodules: [db]\n---\n- Migrations are reversible.\n' > .factory/criteria/db.md
printf -- '- Errors are logged once, where they are handled.\n' > .factory/criteria/general.md
{ echo "---"; echo "id: C1-01"; echo "title: an endpoint"; echo "module: core"; echo "depends_on: []"; echo "acceptance: bash runner.sh core"
  echo "needs_human: false"; echo "review: on-red"; echo "retries: 0"; echo "owner:"; echo "stage: queued"; echo "stage_since:"; echo "---"
  echo; echo "## Goal"; echo "An endpoint."; echo; echo "## Acceptance criteria"; echo "- [ ] it answers"; echo
  echo "## Files touched"; echo "- src/api/orders.py"; echo "- core/tests/orders.t"; echo; echo "## Attempts"; } > tasks/backlog/C1-01.md
git add -A; git commit -qm crit
out="$(factory-criteria C1-01 --names)"
check "a glob the task's path matches, and a file with no keys, apply" 'printf "%s" "$out" | grep -qx ".factory/criteria/api.md" && printf "%s" "$out" | grep -qx ".factory/criteria/general.md"' "$out"
check "...a file for another module does not" '! printf "%s" "$out" | grep -q "db.md"' "$out"
out="$(factory-start C1-01 builder)"; rc=$?
check "factory-start prints the criteria that apply, and only those" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "=== criteria for the paths this task names" && printf "%s" "$out" | grep -q "reads the tenant from the session" && ! printf "%s" "$out" | grep -q "Migrations are reversible"' "$out"
rm -rf .factory/criteria
git checkout -q -- tasks 2>/dev/null; git clean -qfd tasks 2>/dev/null
out="$(factory-start C1-01 builder)"
check "no criteria folder, no criteria section" '! printf "%s" "$out" | grep -q "=== criteria"' "$out"

echo "=== must-haves"
newproj must
mkdir -p src
printf 'export const EmptyState = 1\n' > src/empty.tsx; : > src/stub.tsx
printf 'import { EmptyState } from "./empty"\n' > src/routes.tsx
{ echo "---"; echo "id: C2-01"; echo "title: empty state"; echo "module: core"; echo "depends_on: []"; echo "acceptance: true"
  echo "needs_human: false"; echo "retries: 0"; echo "stage: done"; echo "---"; echo; echo "## Must haves"
  echo "- truth: a user with no orders sees the empty state"; echo "- artifact: src/empty.tsx"; echo "- artifact: \`src/missing.tsx\`"
  echo "- artifact: src/stub.tsx"; echo "- link: src/routes.tsx: EmptyState"; echo "- link: src/routes.tsx: OrdersRoute"
  echo; echo "## Files touched"; echo "- src/empty.tsx"; echo; echo "## Attempts"; } > tasks/done/C2-01.md
out="$(factory-musthaves C2)"; rc=$?
check "a missing artifact, an empty one and a missing link are named, exit 1" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "MUST-HAVE MISSING C2-01: artifact src/missing.tsx does not exist" && printf "%s" "$out" | grep -q "artifact src/stub.tsx is empty" && printf "%s" "$out" | grep -q "src/routes.tsx does not contain .OrdersRoute."' "$out"
check "...what is there is not" '! printf "%s" "$out" | grep -q "src/empty.tsx does not" && ! printf "%s" "$out" | grep -q "contain .EmptyState."' "$out"
check "...a truth is listed for the auditor, not checked" 'printf "%s" "$out" | grep -q "^TRUTH C2-01: a user with no orders" && printf "%s" "$out" | grep -q "^MUST-HAVES 5 checked, 3 missing$"' "$out"
git add -A; git commit -qm must
out="$(factory-finish --tasks C2-01 --no-full --json)"
check "factory-finish puts the misses first, as something to look at" '[ "$(printf "%s" "$out" | jq ".must_haves.missing")" = 3 ] && printf "%s" "$out" | jq -e "[.attention[] | select(.concern | test(\"must-have missing\"))] | length == 3" >/dev/null' "$out"
out="$(factory-finish --tasks C2-01 --no-full)"
check "...and its one line counts them" 'printf "%s" "$out" | grep -q "3 must-have(s) missing"' "$out"

echo "=== the start check"
newproj start
reqs C1 FR-001
mktask backlog C1-01 "" FR-001 "bash runner.sh core"
printf 'exit 1\n' > core/tests/broken.t
jq '.check.start_full = "auto"' .factory/config.json > "$WORK/cfg" && mv "$WORK/cfg" .factory/config.json
git add -A; git commit -qm start
out="$(factory-preflight --json)"; rc=$?
check "a red tree at HEAD: the run does not start" '[ $rc -eq 1 ] && printf "%s" "$out" | jq -e ".ok == false and (.problems | map(test(\"full check is red at HEAD before any task\")) | any)" >/dev/null' "$out"
check "...its lock is taken back, the result kept" '[ ! -f .factory/run.lock ] && grep -qx "verdict=red" .factory/start-check'
git rm -q core/tests/broken.t; git commit -qm fix
out="$(factory-preflight --json)"; rc=$?
check "green at HEAD: the run starts, and says it checked" '[ $rc -eq 0 ] && printf "%s" "$out" | jq -e ".notes | map(test(\"start check: the full check is green\")) | any" >/dev/null' "$out"
out="$(factory-preflight --json)"; rc=$?
check "auto: a full check already green at this commit is not run again" '[ $rc -eq 0 ] && printf "%s" "$out" | jq -e ".notes | map(test(\"start check skipped\")) | any" >/dev/null' "$out"
rm -f .factory/run.lock
jq '.check.start_full = "off"' .factory/config.json > "$WORK/cfg" && mv "$WORK/cfg" .factory/config.json
rm -f .factory/start-check
out="$(factory-preflight --json)"; rc=$?
check "off: no start check" '[ $rc -eq 0 ] && [ ! -f .factory/start-check ]' "$out"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
