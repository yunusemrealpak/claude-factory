#!/usr/bin/env bash
# Sandbox tests: change-level acceptance, the commit bisect, and the version
# check that tells an old project it is behind.
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
BASE="$(cd "$(dirname "$0")" && pwd)"
EXTRACT="$BASE/extract.py"
# Sandboxes are built under here, never beside the suite itself.
WORK="${FACTORY_TEST_DIR:-$(mktemp -d)}"
# Inside a Claude Code session the plugin's bin/ is on PATH; the toolkit is
# called by name, so the suites run under the same condition.
export PATH="$(cd "$(dirname "$0")/../bin" && pwd):$PATH"
export FACTORY_NO_NOTIFY=1
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

mktask() {  # <dir> <column> <id>
  local d="$1" col="$2" id="$3"
  mkdir -p "$d/tasks/$col"
  {
    echo "---"; echo "id: $id"; echo "title: t $id"; echo "module: m"
    echo "depends_on: []"; echo "acceptance: bash gates/verify.sh $id"
    echo "needs_human: false"; echo "review: on-red"; echo "retries: 0"
    echo "owner:"; echo "stage: queued"; echo "stage_since:"; echo "---"; echo
    echo "## Goal"; echo g; echo
    echo "## Acceptance criteria"; echo "- [ ] works"; echo
    echo "## Files touched"; echo "- \`src/a.txt\`"; echo; echo "## Attempts"
  } > "$d/tasks/$col/$id.md"
}

echo "=== change acceptance"
A="$WORK/accept"; rm -rf "$A"; mkdir -p "$A/.factory" "$A/src"; cd "$A" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
: > .factory/active
mktask "$A" done C2-01
mktask "$A" backlog C2-02
echo base > src/a.txt; git add -A; git commit -qm base
printf 'Kasa akışı.\n' | bash "$H/factory-change.sh" open C2 kasa feature - "test -f src/wired.txt" > "$WORK/acc.out" 2>&1
check "open records the acceptance command" 'grep -q "^acceptance: test -f src/wired.txt" .factory/changes/C2-kasa/goal.md' "$(cat "$WORK/acc.out")"
check "open says the change needs it to close" 'grep -q "It closes only after" "$WORK/acc.out"' "$(cat "$WORK/acc.out")"
mktask "$A" backlog C3-01
out="$(printf 'x\n' | bash "$H/factory-change.sh" open C3 bad feature - "run <the tests>" 2>&1)"; rc=$?
rm -f tasks/backlog/C3-01.md
check "a placeholder acceptance command is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "placeholder"' "$out"

out="$(bash "$H/factory-change.sh" sync C2)"
check "with a task still open the change is open" 'printf "%s" "$out" | grep -q "^open C2-kasa done=1/2"' "$out"
mv tasks/backlog/C2-02.md tasks/done/
out="$(bash "$H/factory-change.sh" sync C2)"
check "all tasks done but acceptance never run: unverified, not closed" 'printf "%s" "$out" | grep -q "^unverified C2-kasa done=2/2" && [ ! -f .factory/changes/C2-kasa/closed ]' "$out"
check "the summary says what it is waiting for" 'grep -q "## Waiting on its acceptance" .factory/changes/C2-kasa/summary.md && grep -q "never run" .factory/changes/C2-kasa/summary.md'
check "list agrees it is unverified" 'bash "$H/factory-change.sh" list | grep -q "^unverified C2-kasa"'
out="$(bash "$H/factory-accept.sh" C2 --show 2>&1)"; rc=$?
check "--show reports it was never run" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^ACCEPT NEVER-RUN C2"' "$out"

out="$(bash "$H/factory-accept.sh" C2 2>&1)"; rc=$?
check "a failing acceptance command is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^ACCEPT RED C2"' "$out"
check "the verdict is recorded with the task-set signature" 'grep -q "^verdict=red" .factory/changes/C2-kasa/acceptance && grep -qE "^sig=[0-9a-f]{40}$" .factory/changes/C2-kasa/acceptance'
check "the output is kept in acceptance.log" '[ -s .factory/changes/C2-kasa/acceptance.log ]'
check "red keeps the change open" 'bash "$H/factory-change.sh" sync C2 | grep -q "^unverified" && [ ! -f .factory/changes/C2-kasa/closed ]'
check "the summary shows the red verdict" 'grep -q "RED" .factory/changes/C2-kasa/summary.md'
check "red is not a nudge to rewrite the command" 'printf "%s" "$out" | grep -q "do not edit the acceptance command"' "$out"

touch src/wired.txt
out="$(bash "$H/factory-accept.sh" C2 2>&1)"; rc=$?
check "a passing acceptance command is green" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^ACCEPT GREEN C2"' "$out"
out="$(bash "$H/factory-change.sh" sync C2)"
check "green closes the change" 'printf "%s" "$out" | grep -q "^CLOSED-NOW C2-kasa" && [ -f .factory/changes/C2-kasa/closed ]' "$out"

# A task added after the verdict makes that verdict stale.
mktask "$A" backlog C2-03
out="$(bash "$H/factory-change.sh" sync C2)"
check "a new task reopens the change" 'printf "%s" "$out" | grep -q "^open C2-kasa done=2/3"' "$out"
mv tasks/backlog/C2-03.md tasks/done/
out="$(bash "$H/factory-change.sh" sync C2)"
check "the old green verdict does not cover the new task" 'printf "%s" "$out" | grep -q "^unverified"' "$out"
check "--show calls that stale" 'bash "$H/factory-accept.sh" C2 --show 2>&1 | grep -q "ACCEPT stale"'
bash "$H/factory-accept.sh" C2 >/dev/null 2>&1
check "running it again against the new task set closes it" 'bash "$H/factory-change.sh" sync C2 | grep -qE "^(closed|CLOSED-NOW) C2-kasa"'

# A change with no acceptance command behaves as it always did.
N="$WORK/accept-none"; rm -rf "$N"; mkdir -p "$N/.factory"; cd "$N" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
: > .factory/active; mktask "$N" done C2-01; git add -A; git commit -qm base
printf 'g\n' | bash "$H/factory-change.sh" open C2 plain chore - >/dev/null 2>&1
check "no acceptance command: the change still closes on its tasks" 'bash "$H/factory-change.sh" sync C2 | grep -qE "^(closed|CLOSED-NOW) C2-plain" && [ -f .factory/changes/C2-plain/closed ]'
check "accept says there is nothing to run" 'bash "$H/factory-accept.sh" C2 | grep -q "^ACCEPT NONE C2"'

echo "=== the run does not end on an unrun acceptance"
cd "$A" || exit 1
mktask "$A" backlog C2-04
mv tasks/backlog/C2-04.md tasks/done/
rm -f .factory/changes/C2-kasa/closed .factory/changes/C2-kasa/acceptance
printf 's1' > .factory/run-owner
stop_in() { jq -cn --arg c "$A" '{cwd:$c, session_id:"s1", hook_event_name:"Stop", stop_hook_active:false}'; }
out="$(stop_in | bash "$H/factory-stop-gate.sh")"
check "an acceptance that never ran holds the session" 'printf "%s" "$out" | jq -e ".decision==\"block\"" >/dev/null && printf "%s" "$out" | jq -r ".reason" | grep -q "factory-accept"' "$out"
check "the claim is not released while it is held" '[ -s .factory/run-owner ]'
rm -f src/wired.txt
bash "$H/factory-accept.sh" C2 >/dev/null 2>&1
out="$(stop_in | bash "$H/factory-stop-gate.sh")"
check "a red verdict is reported, not looped on" '! printf "%s" "$out" | jq -e ".decision" >/dev/null 2>&1 && printf "%s" "$out" | jq -r ".systemMessage" | grep -q "Waiting on a change acceptance"' "$out"
check "the claim is released once it has been run" '[ ! -s .factory/run-owner ]'

echo "=== bisect"
B="$WORK/bisect"; rm -rf "$B"; mkdir -p "$B/src" "$B/.factory" "$B/tasks/done"; cd "$B" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
printf 'ok\n' > src/a.txt; git add -A; git commit -qm base
for i in 1 2 3 4 5; do
  printf 'line %s\n' "$i" >> src/a.txt
  [ "$i" = 3 ] && printf 'BROKEN\n' >> src/a.txt
  mktask "$B" done "C2-0$i"
  git add -A
  git commit -q -m "C2-0$i: task $i" -m "Factory-Task: C2-0$i
Factory-Change: C2"
done
jq -n '{commands:{test:"! grep -q BROKEN src/a.txt"}, isolation_links:[]}' > .factory/config.json
out="$(bash "$H/factory-bisect.sh" 2>&1)"; rc=$?
check "it finds the first bad task commit" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^FIRST BAD [0-9a-f]* task C2-03"' "$out"
check "it names the task file to read" 'printf "%s" "$out" | grep -q "tasks/done/C2-03.md"' "$out"
check "it offers the single-task revert" 'printf "%s" "$out" | grep -q "git revert"' "$out"
check "it tested a handful of commits, not all of them" '[ "$(printf "%s\n" "$out" | grep -c "^  \[")" -le 4 ]' "$out"
check "the working tree is untouched" '[ -z "$(git status --porcelain -- . ":(exclude).factory/")" ]' "$(git status --porcelain)"
check "no worktree was left behind" '[ "$(git worktree list | wc -l | tr -d " ")" = 1 ]' "$(git worktree list)"
check "HEAD did not move" '[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]'
out="$(bash "$H/factory-bisect.sh" "true" 2>&1)"; rc=$?
check "a command that passes at HEAD reports nothing to bisect" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^BISECT CLEAN"' "$out"
out="$(bash "$H/factory-bisect.sh" "false" 2>&1)"; rc=$?
check "a command that fails everywhere is inconclusive, not a false accusation" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^BISECT INCONCLUSIVE"' "$out"
G="$WORK/bisect-nogit"; rm -rf "$G"; mkdir -p "$G"; cd "$G" || exit 1
out="$(bash "$H/factory-bisect.sh" "true" 2>&1)"; rc=$?
check "outside a repository it refuses" '[ $rc -eq 2 ]' "$out"
cd "$B" || exit 1
git checkout -q --orphan empty 2>/dev/null; git rm -rqf . 2>/dev/null; git commit -qm "no factory commits" --allow-empty
out="$(bash "$H/factory-bisect.sh" "false" 2>&1)"; rc=$?
check "with no Factory-Task commits it says so" '[ $rc -eq 2 ] && printf "%s" "$out" | grep -q "nothing to bisect"' "$out"

echo "=== version check"
V="$WORK/version"; rm -rf "$V"; mkdir -p "$V/.factory" "$V/gates" "$V/tasks/backlog"; cd "$V" || exit 1
: > .factory/active
harness="$(cat "$H/factory-version.txt")"
# an old project: a config from before, a gate from before, a task from before
jq -n '{verify:"gates/verify.sh", workers:2, gate_mode:"staged", commands:{build:"",test:"",arch:"",lint:""}}' > .factory/config.json
printf '#!/usr/bin/env bash\n# old gate\ncount_tests() { :; }\nrecord_failure() { :; }\n' > gates/verify.sh
printf -- '---\nid: C2-01\ntitle: t\n---\n\n## Goal\ng\n' > tasks/backlog/C2-01.md
printf 'node_modules/\n' > .gitignore
out="$(bash "$H/factory-upgrade.sh" 2>&1)"; rc=$?
check "an old project is reported as behind" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "harness is now ${harness}"' "$out"
check "it names the missing config keys" 'printf "%s" "$out" | grep -q "config.json is missing:.*risk_paths"' "$out"
check "it names the missing gate guards" 'printf "%s" "$out" | grep -q "gates/verify.sh is missing:.*guard_acceptance"' "$out"
check "it names the task file with no Files touched" 'printf "%s" "$out" | grep -q "C2-01"' "$out"
check "the report changes nothing" '[ "$(jq -r ".factory_version // \"none\"" .factory/config.json)" = "none" ]'
brief="$(bash "$H/factory-upgrade.sh" --brief 2>&1)"
check "the session brief gets one line about it" 'printf "%s" "$brief" | grep -q "Run /factory-upgrade"' "$brief"

out="$(bash "$H/factory-upgrade.sh" --apply 2>&1)"; rc=$?
check "apply adds what it safely can" 'printf "%s" "$out" | grep -q "^UPGRADE APPLIED"' "$out"
check "the missing config keys are there, at their defaults" '[ "$(jq -r ".gate_isolation" .factory/config.json)" = "false" ] && [ "$(jq -r ".risk_paths | length" .factory/config.json)" -gt 5 ]'
check "an existing value is never overwritten" '[ "$(jq -r ".workers" .factory/config.json)" = "2" ] && [ "$(jq -r ".gate_mode" .factory/config.json)" = "staged" ]'
check "the missing directories exist" '[ -d .factory/questions ] && [ -d .factory/lessons ] && [ -d .factory/changes ]'
check "the gitignore learned the new paths" 'grep -q ".factory/events.jsonl" .gitignore && grep -q "node_modules/" .gitignore'
check "the old task file got its sections" 'grep -q "## Files touched" tasks/backlog/C2-01.md && grep -q "## Attempts" tasks/backlog/C2-01.md'
check "apply still refuses to touch the gate" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "STILL BEHIND - gates/verify.sh is missing"' "$out"
check "it points at /factory-init for the gate" 'printf "%s" "$out" | grep -q "factory-init"' "$out"
check "the version stamp does not move while the gate is behind" '[ "$(jq -r ".factory_version" .factory/config.json)" != "${harness}" ]' "$(jq -r .factory_version .factory/config.json)"

# a current project: nothing to say
C="$WORK/current"; rm -rf "$C"; mkdir -p "$C/gates" "$C/tasks/backlog"; cd "$C" || exit 1
mkdir -p .factory/verified .factory/failures .factory/no-progress .factory/changes .factory/lessons .factory/questions .factory/inflight
: > .factory/active
python3 "$EXTRACT" gates/verify.sh >/dev/null
jq -n --arg v "$harness" '{factory_version:$v, verify:"gates/verify.sh", workers:2, max_concurrent_agents:3,
  retry_limit:2, min_tests:1, gate_mode:"staged", gate_isolation:false, isolation_links:[], risk_paths:["*.sql"],
  agent_stale_after_min:45,
  commands:{build:"",test:"",arch:"",lint:""}}' > .factory/config.json
printf '.factory/verified/\n.factory/inflight/\n.factory/events.jsonl\n.factory/dashboard.html\n.factory/statusline.txt\n.factory/questions/\n.factory/run-owner\n.factory/logs/\n.factory/locks/\n.factory/run-start.json\n.factory/last-run.md\n' > .gitignore
printf -- '---\nid: C2-01\n---\n\n## Files touched\n\n## Attempts\n' > tasks/backlog/C2-01.md
out="$(bash "$H/factory-upgrade.sh" 2>&1)"; rc=$?
check "a current project reports nothing to do" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^UPGRADE NONE"' "$out"
check "and says nothing in the session brief" '[ -z "$(bash "$H/factory-upgrade.sh" --brief)" ]'
check "the current gate template carries every guard" '! printf "%s" "$out" | grep -q "gates/verify.sh is missing"' "$out"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
