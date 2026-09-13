#!/usr/bin/env bash
# Sandbox tests for factory-commit / factory-change / factory-claim / done-guard
# claim / stop-gate close / ids. Never touches a real project.
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
BASE="$(cd "$(dirname "$0")" && pwd)"
EXTRACT="$BASE/extract.py"
# Sandboxes are built under here, never beside the suite itself.
WORK="${FACTORY_TEST_DIR:-$(mktemp -d)}"
# Inside a Claude Code session the plugin's bin/ is on PATH; the toolkit is
# called by name, so the suites run under the same condition.
export PATH="$(cd "$(dirname "$0")/../bin" && pwd):$PATH"
P="$WORK/proj"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

task() {  # <column> <id> <title> <depends> [files-touched...]
  local col="$1" id="$2" title="$3" deps="$4"; shift 4
  mkdir -p "$P/tasks/$col"
  {
    echo "---"; echo "id: $id"; echo "title: $title"; echo "module: m"
    echo "depends_on: [$deps]"; echo "acceptance: bash gates/verify.sh $id"
    echo "needs_human: false"; echo "review: on-red"; echo "retries: 0"
    echo "owner:"; echo "stage: queued"; echo "stage_since:"; echo "---"
    echo; echo "## Goal"; echo "g"; echo
    echo "## Files touched"
    for f in "$@"; do echo "- \`$f\`"; done
    echo; echo "## Acceptance criteria"; echo "- [ ] x"
  } > "$P/tasks/$col/$id.md"
}

rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
mkdir -p src .factory/verified tasks/backlog tasks/in-progress tasks/done tasks/blocked tasks/proposed
touch .factory/active
printf 'a\n' > src/a.txt; printf 'old\n' > src/old.txt; printf 'u\n' > user.txt
printf '# decisions\n' > decisions.md
git add -A; git commit -qm base
BASE_SHA="$(git rev-parse HEAD)"

echo "=== ids"
task done T-001 "first run task" ""
check "next-prefix is C2 after a first run" '[ "$(bash $H/factory-ids.sh next-prefix)" = C2 ]'
task backlog C2-01 "add thing" "T-001" src/a.txt src/new.txt src/old.txt
task backlog C2-02 "second thing" "C2-01" src/b.txt
check "next-prefix is C3 with C2 tasks" '[ "$(bash $H/factory-ids.sh next-prefix)" = C3 ]'
mkdir -p .factory/changes/C4-gone
check "next-prefix skips an archived change with no task files" '[ "$(bash $H/factory-ids.sh next-prefix)" = C5 ]'
rmdir .factory/changes/C4-gone
touch .factory/verified/C2-02
out="$(bash $H/factory-ids.sh check)"; rc=$?
check "stale marker on a backlog task blocks" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "STALE-MARKER C2-02"' "$out"
rm -f .factory/verified/C2-02
bash $H/factory-ids.sh check >/dev/null; check "clean board passes check" '[ $? -eq 0 ]'

echo "=== change open"
out="$(printf 'Export invoices as CSV.\nSecond line.\n' | bash $H/factory-change.sh open C2 invoice-export feature - 2>&1)"
check "open prints OPENED" 'printf "%s" "$out" | grep -q "^OPENED C2-invoice-export: 2 task(s)"' "$out"
G=.factory/changes/C2-invoice-export/goal.md
check "goal.md lists the change's tasks" 'grep -qx "tasks: \[C2-01, C2-02\]" $G' "$(cat $G 2>/dev/null)"
check "goal.md extends C1" 'grep -qx "extends: \[C1\]" $G'
check "goal.md records base commit" 'grep -qx "base_commit: $BASE_SHA" $G'
check "goal.md records branch" 'grep -qx "branch: main" $G'
check "goal.md keeps the goal text" 'grep -qx "Second line." $G'
check "summary.md written at open" '[ -s .factory/changes/C2-invoice-export/summary.md ]'
out="$(printf 'x' | bash $H/factory-change.sh open C2 again feature - 2>&1)"; rc=$?
check "reopening an id is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "never reused"' "$out"
out="$(printf 'x' | bash $H/factory-change.sh open C3 Bad_Slug feature - 2>&1)"; rc=$?
check "bad slug refused" '[ $rc -ne 0 ]' "$out"
out="$(printf 'x' | bash $H/factory-change.sh open C3 ok-slug hotfix - 2>&1)"; rc=$?
check "bad type refused" '[ $rc -ne 0 ]' "$out"
out="$(printf 'x' | bash $H/factory-change.sh open C3 ok-slug feature - 2>&1)"; rc=$?
check "change with no tasks refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "no task belongs"' "$out"
printf 'spec body\n' > spec.md
task backlog C3-01 "c3 task" "" src/c.txt
out="$(bash $H/factory-change.sh open C3 from-file bugfix spec.md 2>&1)"
check "goal from a file is copied with its source" 'grep -q "^Source: spec.md" .factory/changes/C3-from-file/goal.md && grep -qx "spec body" .factory/changes/C3-from-file/goal.md' "$out"

echo "=== commit"
# the task's work, plus the developer's own staged edit that must stay out
printf 'task edit\n' >> src/a.txt; printf 'new\n' > src/new.txt; rm src/old.txt
printf 'dev edit\n' >> user.txt; git add user.txt
printf -- '- C2-01: did the thing - because\n' >> decisions.md
out="$(bash $H/factory-commit.sh C2-01 2>&1)"; rc=$?
check "commit refused while the task is not in done" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "move it to done"' "$out"
mv tasks/backlog/C2-01.md tasks/done/C2-01.md
# another in-flight task lists src/a.txt too
task in-progress C2-02 "second thing" "C2-01" src/a.txt src/b.txt
rm -f tasks/backlog/C2-02.md
out="$(bash $H/factory-commit.sh C2-01 2>&1)"; rc=$?
check "commit succeeds" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^COMMIT [0-9a-f]* C2-01 (C2)"' "$out"
check "shared file reported" 'printf "%s" "$out" | grep -q "COMMIT SHARED:.*src/a.txt(also-C2-02)"' "$out"
files="$(git show --name-status --format= HEAD | sort | tr '\t' ' ' | tr '\n' ';')"
check "commit holds exactly the task's files" '[ "$files" = "A src/new.txt;A tasks/done/C2-01.md;D src/old.txt;M decisions.md;M src/a.txt;" ]' "$files"
check "developer's staged edit is still staged, uncommitted" '[ "$(git diff --cached --name-only)" = user.txt ]' "$(git diff --cached --name-only)"
tr="$(git log -1 --format=%B | git interpret-trailers --parse | tr '\n' ';')"
check "trailers present" '[ "$tr" = "Factory-Task: C2-01;Factory-Change: C2;" ]' "$tr"
check "subject is id: title" '[ "$(git log -1 --format=%s)" = "C2-01: add thing" ]'
out="$(bash $H/factory-commit.sh C2-01 2>&1)"; rc=$?
check "second commit of the same task is a no-op" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "COMMIT SKIPPED"' "$out"

task done C9-01 "no files" ""
out="$(bash $H/factory-commit.sh C9-01 2>&1)"; rc=$?
check "task without Files touched refused" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "no usable"' "$out"
task done C9-02 "bad paths" "" ../escape.txt .factory/verified/x /abs/path
out="$(bash $H/factory-commit.sh C9-02 2>&1)"; rc=$?
check "outside / internal paths are not committed" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "outside-project" && printf "%s" "$out" | grep -q "factory-or-git-internal"' "$out"
rm -f tasks/done/C9-01.md tasks/done/C9-02.md

touch "$(git rev-parse --git-path MERGE_HEAD)"
task done C9-03 "merge state" "" src/a.txt
out="$(bash $H/factory-commit.sh C9-03 2>&1)"; rc=$?
check "refused in the middle of a merge" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "MERGE_HEAD"' "$out"
rm -f "$(git rev-parse --git-path MERGE_HEAD)" tasks/done/C9-03.md

echo "=== change sync"
out="$(bash $H/factory-change.sh sync C2)"
check "half-done change stays open" 'printf "%s" "$out" | grep -q "^open C2-invoice-export done=1/2"' "$out"
S=.factory/changes/C2-invoice-export/summary.md
c1="$(git log -1 --format=%h)"
check "summary shows the task commit" 'grep -q "| C2-01 | add thing | done | 0 | - | $c1 |" $S' "$(grep C2-01 $S)"
check "summary shows the decision" 'grep -qx -- "- C2-01: did the thing - because" $S'
check "no ref while open" '! git rev-parse -q --verify refs/factory/C2-invoice-export >/dev/null'

printf 'b\n' > src/b.txt; printf -- '- C2-02: second - reason\n' >> decisions.md
mv tasks/in-progress/C2-02.md tasks/done/C2-02.md
printf 'x\ntests=7\ntest_files=2\nskipped=0\n' > .factory/verified/C2-02
mkdir -p .factory/failures/resolved; printf 'ts abc attempt=1\n' > .factory/failures/resolved/C2-02.log
bash $H/factory-commit.sh C2-02 >/dev/null 2>&1
c2="$(git log -1 --format=%h)"
# an unrelated commit after the change finished must not move its ref
printf 'later\n' > later.txt; git add later.txt; git commit -qm unrelated
out="$(bash $H/factory-change.sh sync)"
check "finished change closes now" 'printf "%s" "$out" | grep -q "^CLOSED-NOW C2-invoice-export done=2/2 ref=refs/factory/C2-invoice-export"' "$out"
check "ref points at the change's last commit, not HEAD" '[ "$(git rev-parse --short refs/factory/C2-invoice-export)" = "$c2" ]' "ref=$(git rev-parse --short refs/factory/C2-invoice-export) want=$c2"
check "summary row carries tests and red runs" 'grep -q "| C2-02 | second thing | done | 1 | 7 | $c2 |" $S' "$(grep C2-02 $S)"
check "summary status closed" 'grep -q "status | \*\*closed\*\*" $S'
check "summary tells how to get back" 'grep -q "git switch --detach refs/factory/C2-invoice-export" $S'
out="$(bash $H/factory-change.sh sync)"
check "second sync reports closed, not closed-now" 'printf "%s" "$out" | grep -q "^closed C2-invoice-export"' "$out"
check "C3 still open in list" 'bash $H/factory-change.sh list | grep -q "^open C3-from-file done=0/1 type=bugfix"'
check "refs/factory is not pushed by --tags/--follow-tags (namespace check)" '[ -z "$(git for-each-ref refs/tags refs/heads | grep factory)" ]'

echo "=== claim via done-guard"
hook() {  # <session> <command>
  jq -n --arg s "$1" --arg c "$2" --arg cwd "$P" \
    '{session_id: $s, cwd: $cwd, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}' \
    | bash $H/factory-done-guard.sh
}
rm -f .factory/run-owner .factory/run-owner.pending
out="$(hook s1 'bash ~/.claude/hooks/factory-claim.sh')"
check "unowned claim is staged, not denied" '[ -z "$out" ] && [ "$(cat .factory/run-owner.pending)" = s1 ] && [ ! -e .factory/run-owner ]' "$out"
out="$(bash $H/factory-claim.sh)"; rc=$?
check "claim script promotes the pending id" '[ $rc -eq 0 ] && [ "$(cat .factory/run-owner)" = s1 ] && [ ! -e .factory/run-owner.pending ]' "$out"
out="$(bash $H/factory-claim.sh)"; rc=$?
check "claim script without a pending claim fails loudly" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "CLAIM FAILED"' "$out"
out="$(hook s2 'bash ~/.claude/hooks/factory-claim.sh')"
check "second session is denied" 'printf "%s" "$out" | jq -e ".hookSpecificOutput.permissionDecision==\"deny\"" >/dev/null && [ ! -e .factory/run-owner.pending ]' "$out"
out="$(hook s2 'bash ~/.claude/hooks/factory-claim.sh --take-over')"
check "take-over is staged" '[ -z "$out" ] && [ "$(cat .factory/run-owner.pending)" = s2 ]' "$out"
rm -f .factory/run-owner.pending
out="$(hook s1 'bash ~/.claude/hooks/factory-claim.sh')"
check "owner re-claiming itself is fine" '[ -z "$out" ] && [ "$(cat .factory/run-owner.pending)" = s1 ]' "$out"
rm -f .factory/run-owner.pending
for cmd in 'cat ~/.claude/hooks/factory-claim.sh' 'grep -n take-over ~/.claude/hooks/factory-claim.sh' 'vim factory-claim.sh' 'echo bash factory-claim.sh'; do
  out="$(hook s3 "$cmd")"
  check "not a claim: $cmd" '[ -z "$out" ] && [ ! -e .factory/run-owner.pending ]' "$out"
done
out="$(hook s3 'cd sub; bash /x/factory-claim.sh --take-over')"
check "claim after a separator is recognised" '[ -z "$out" ] && [ "$(cat .factory/run-owner.pending 2>/dev/null)" = s3 ]' "$out"
rm -f .factory/run-owner.pending
out="$(jq -n --arg cwd "$P" '{cwd: $cwd, tool_name: "Bash", tool_input: {command: "bash ~/.claude/hooks/factory-claim.sh"}}' | bash $H/factory-done-guard.sh)"
check "no session id is denied" 'printf "%s" "$out" | grep -q "no session id"' "$out"

echo "=== done-guard regressions"
task in-progress C3-01 "c3 task" "" src/c.txt; rm -f tasks/backlog/C3-01.md
out="$(hook s1 "mv tasks/in-progress/C3-01.md tasks/$(printf done)/C3-01.md")"
check "move without marker denied" 'printf "%s" "$out" | grep -q "no verification marker"' "$out"
touch .factory/verified/C3-01
out="$(hook s1 "mv tasks/in-progress/C3-01.md tasks/$(printf done)/C3-01.md")"
check "move with marker allowed" '[ -z "$out" ]' "$out"

echo "=== stop-gate close"
stop() { jq -n --arg s "$1" --arg cwd "$P" '{session_id: $s, cwd: $cwd, hook_event_name: "Stop", stop_hook_active: false, background_tasks: []}' | bash $H/factory-stop-gate.sh; }
printf 's1\n' > .factory/run-owner
out="$(stop s1)"
check "unfinished board blocks the owner" 'printf "%s" "$out" | jq -e ".decision==\"block\"" >/dev/null' "$out"
out="$(stop s9)"
check "non-owner is left alone" '[ -z "$out" ]' "$out"
mv tasks/in-progress/C3-01.md tasks/done/C3-01.md
printf 'c\n' > src/c.txt; bash $H/factory-commit.sh C3-01 >/dev/null 2>&1
out="$(stop s1)"
check "finished run prints a systemMessage naming the closed change" 'printf "%s" "$out" | jq -e ".systemMessage|test(\"Closed: C3-from-file\")" >/dev/null' "$out"
check "finished run has no decision field" 'printf "%s" "$out" | jq -e "has(\"decision\")|not" >/dev/null'
check "claim released" '[ ! -e .factory/run-owner ]'
check "C3 ref created" 'git rev-parse -q --verify refs/factory/C3-from-file >/dev/null'
out="$(stop s1)"
check "after release the gate is silent" '[ -z "$out" ]' "$out"

echo "=== brief"
out="$(jq -n --arg cwd "$P" '{session_id: "s1", cwd: $cwd, source: "startup"}' | bash $H/factory-brief.sh | jq -r .hookSpecificOutput.additionalContext)"
check "brief has the changes block" 'printf "%s" "$out" | grep -q "Changes in flight"' "$out"

echo "=== commit outside git"
NG="$WORK/nogit"; rm -rf "$NG"; mkdir -p "$NG/tasks/done" "$NG/.factory"
( cd "$NG" && printf -- '---\nid: C2-01\ntitle: t\n---\n## Files touched\n- a.txt\n' > tasks/done/C2-01.md && bash $H/factory-commit.sh C2-01 ) > "$WORK/nogit.out" 2>&1; rc=$?
check "no repository: skipped, exit 0" '[ $rc -eq 0 ] && grep -q "COMMIT SKIPPED" "$WORK/nogit.out"' "$(cat "$WORK/nogit.out")"

echo "=== list: finished but unsynced"
U="$WORK/unsynced"; rm -rf "$U"; mkdir -p "$U/tasks/done" "$U/.factory/changes/C2-x"
printf -- '---\nchange: C2\nslug: x\ntype: chore\n---\n' > "$U/.factory/changes/C2-x/goal.md"
printf -- '---\nid: C2-01\ntitle: t\n---\n' > "$U/tasks/done/C2-01.md"
out="$(cd "$U" && bash $H/factory-change.sh list)"
check "all done without a sync lists as unsynced" '[ "$out" = "unsynced C2-x done=1/1 type=chore" ]' "$out"
out="$(cd "$U" && bash $H/factory-change.sh sync)"
check "sync closes it" 'printf "%s" "$out" | grep -q "^CLOSED-NOW C2-x done=1/1 ref=$"' "$out"
out="$(cd "$U" && bash $H/factory-change.sh list)"
check "then lists as closed" '[ "$out" = "closed C2-x done=1/1 type=chore" ]' "$out"
check "closed without commits says so in the summary" 'grep -q "none - no commit carries" "$U/.factory/changes/C2-x/summary.md"'

echo "=== template gate: marker invalidation"
GT="$WORK/gate"; rm -rf "$GT"; mkdir -p "$GT/gates" "$GT/.factory/verified" "$GT/tasks/in-progress"
python3 "$EXTRACT" "$GT/gates/verify.sh" >/dev/null
printf -- '---\nid: C2-01\ntitle: t\nacceptance: bash gates/verify.sh C2-01\n---\n' > "$GT/tasks/in-progress/C2-01.md"
cfg() { jq -n --arg t "$1" '{gate_mode: "full", min_tests: 1, commands: {build: "true", test: $t, arch: "", lint: "true"}}' > "$GT/.factory/config.json"; }
cfg "echo '3 passed'"
( cd "$GT" && bash gates/verify.sh C2-01 ) > "$WORK/gate1.out" 2>&1; rc=$?
check "green run writes the marker" '[ $rc -eq 0 ] && [ -f "$GT/.factory/verified/C2-01" ]' "$(tail -3 "$WORK/gate1.out")"
cfg "echo boom; false"
( cd "$GT" && bash gates/verify.sh C2-01 ) > "$WORK/gate2.out" 2>&1; rc=$?
check "red run after a green one removes the old marker" '[ $rc -eq 1 ] && [ ! -e "$GT/.factory/verified/C2-01" ]' "$(tail -3 "$WORK/gate2.out")"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
