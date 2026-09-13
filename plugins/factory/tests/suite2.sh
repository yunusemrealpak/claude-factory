#!/usr/bin/env bash
# Sandbox tests: risk check, lessons, attempts-safe parser, retro sections,
# template gate isolation. Never touches a real project.
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
BASE="$(cd "$(dirname "$0")" && pwd)"
EXTRACT="$BASE/extract.py"
# Sandboxes are built under here, never beside the suite itself.
WORK="${FACTORY_TEST_DIR:-$(mktemp -d)}"
# Inside a Claude Code session the plugin's bin/ is on PATH; the toolkit is
# called by name, so the suites run under the same condition.
export PATH="$(cd "$(dirname "$0")/../bin" && pwd):$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

mktask() {  # <dir> <column> <id> <module> [files...]
  local d="$1" col="$2" id="$3" mod="$4"; shift 4
  mkdir -p "$d/tasks/$col"
  {
    echo "---"; echo "id: $id"; echo "title: t $id"; echo "module: $mod"
    echo "depends_on: []"; echo "acceptance: bash gates/verify.sh $id"
    echo "needs_human: false"; echo "retries: 0"; echo "---"; echo
    echo "## Files touched"
    for f in "$@"; do echo "- \`$f\`"; done
    echo; echo "## Attempts"
  } > "$d/tasks/$col/$id.md"
}

echo "=== risk"
R="$WORK/risk"; rm -rf "$R"; mkdir -p "$R/.factory"; cd "$R" || exit 1
jq -n '{risk_paths: ["*/auth/*", "*.sql", "db/migrations/*", "*payment*"]}' > .factory/config.json
mktask "$R" in-progress C2-01 m src/Auth/Login.cs src/x.cs
out="$(bash $H/factory-risk.sh C2-01)"; rc=$?
check "auth path matches case-insensitively" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "src/Auth/Login.cs matches \"\*/auth/\*\""' "$out"
check "non-risky file not listed" '! printf "%s" "$out" | grep -q "src/x.cs matches"' "$out"
mktask "$R" in-progress C2-02 m app/db/migrations/0001_init.py
out="$(bash $H/factory-risk.sh C2-02)"; rc=$?
check "bare pattern matches at any depth" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "0001_init.py"' "$out"
mktask "$R" in-progress C2-03 m src/orders/Order.cs README.md
out="$(bash $H/factory-risk.sh C2-03)"; rc=$?
check "harmless task passes" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^RISK none for C2-03: 2 file"' "$out"
mktask "$R" in-progress C2-04 m
out="$(bash $H/factory-risk.sh C2-04)"; rc=$?
check "empty list is sent to review" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "lists no files"' "$out"
jq -n '{}' > .factory/config.json
out="$(bash $H/factory-risk.sh C2-01)"; rc=$?
check "no risk_paths configured: pass, and says so" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "no risk_paths"' "$out"
out="$(bash $H/factory-risk.sh NOPE 2>&1)"; rc=$?
check "unknown task: usage error" '[ $rc -eq 2 ]' "$out"

echo "=== lessons"
LS="$WORK/lessons"; rm -rf "$LS"; mkdir -p "$LS/.factory/failures"; cd "$LS" || exit 1
mktask "$LS" done C2-03 orders src/a.cs
printf 'sig text\n' > .factory/failures/sig-abcdef123456.txt
out="$(bash $H/factory-lesson.sh add orders C2-03,sig-abcdef123456 "Run dotnet test with --filter Category!=Integration unless the db is up." 2>&1)"; rc=$?
check "lesson with real evidence is added" '[ $rc -eq 0 ] && grep -q "^- Run dotnet test .* \[evidence: C2-03, sig-abcdef123456; added: 20[0-9-]*T[0-9:]*Z\]$" .factory/lessons/orders.md' "$out $(cat .factory/lessons/orders.md 2>/dev/null)"
out="$(bash $H/factory-lesson.sh add orders C9-99 "x" 2>&1)"; rc=$?
check "evidence task that does not exist is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "no task file"' "$out"
out="$(bash $H/factory-lesson.sh add orders sig-000000000000 "x" 2>&1)"; rc=$?
check "evidence signature that does not exist is refused" '[ $rc -ne 0 ]' "$out"
out="$(bash $H/factory-lesson.sh add orders "" "x" 2>&1)"; rc=$?
check "no evidence is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "needs evidence"' "$out"
long="$(printf '%0201d' 0)"
out="$(bash $H/factory-lesson.sh add orders C2-03 "$long" 2>&1)"; rc=$?
check "over 200 characters is refused" '[ $rc -ne 0 ]' "$out"
out="$(bash $H/factory-lesson.sh add orders C2-03 "two
lines" 2>&1)"; rc=$?
check "multi-line lesson is refused" '[ $rc -ne 0 ]' "$out"
out="$(bash $H/factory-lesson.sh add orders C2-03 "Run dotnet test with --filter Category!=Integration unless the db is up." 2>&1)"; rc=$?
check "duplicate lesson is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "already"' "$out"
out="$(bash $H/factory-lesson.sh add "bad/module" C2-03 "x" 2>&1)"; rc=$?
check "module with a slash is refused" '[ $rc -ne 0 ]' "$out"
for i in $(seq 2 15); do bash $H/factory-lesson.sh add orders C2-03 "lesson number $i" >/dev/null 2>&1; done
out="$(bash $H/factory-lesson.sh add orders C2-03 "one too many" 2>&1)"; rc=$?
check "sixteenth lesson is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "15 lessons"' "$out"
out="$(bash $H/factory-lesson.sh remove orders 2)"
check "remove takes out the right one" 'printf "%s" "$out" | grep -q "lesson number 2 \[" && ! grep -q "lesson number 2 \[" .factory/lessons/orders.md && [ "$(grep -c "^- " .factory/lessons/orders.md)" -eq 14 ]' "$out"
check "list numbers lessons" 'bash $H/factory-lesson.sh list orders | grep -q "^ 1 - Run dotnet test"'

echo "=== commit parser ignores attempt bullets under a sub-heading"
CP="$WORK/cparse"; rm -rf "$CP"; mkdir -p "$CP"; cd "$CP" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
mkdir -p src tasks/done; printf 'a\n' > src/a.txt; git add -A; git commit -qm base
printf 'b\n' >> src/a.txt; printf 'evil\n' > src/notmine.txt
{
  echo "---"; echo "id: C2-01"; echo "title: t"; echo "---"
  echo "## Files touched"; echo "- src/a.txt"
  echo "### Attempt 1 - red"; echo "- src/notmine.txt was what I suspected"
} > tasks/done/C2-01.md
out="$(bash $H/factory-commit.sh C2-01 2>&1)"
check "bullet under ### Attempt is not a path" '! git show --name-only --format= HEAD | grep -q notmine' "$out $(git show --name-only --format= HEAD)"

echo "=== retro sections"
RT="$WORK/retro"; rm -rf "$RT"; mkdir -p "$RT/.factory/failures/resolved" "$RT/.factory/lessons"; cd "$RT" || exit 1
jq -n '{gate_isolation: false}' > .factory/config.json
mktask "$RT" done C2-01 orders src/orders/A.cs
printf 'Resolved by: added the missing DI registration in Startup.cs\n' >> tasks/done/C2-01.md
mktask "$RT" in-progress C2-02 billing src/billing/B.cs
printf '2026-09-10T10:00:00Z aaaaaaaaaaaa attempt=1\n2026-09-10T11:00:00Z bbbbbbbbbbbb attempt=2\n' > .factory/failures/resolved/C2-01.log
printf 'error CS<n>: <root>/src/billing/B.cs(<n>,<n>): unexpected token\n' > .factory/failures/sig-aaaaaaaaaaaa.txt
printf 'error: <root>/src/orders/A.cs missing registration\n' > .factory/failures/sig-bbbbbbbbbbbb.txt
printf '2026-09-12T09:00:00Z bbbbbbbbbbbb attempt=1\n' > .factory/failures/C2-02.log
printf '# Lessons: orders\n\n- Register handlers in Startup.cs. [evidence: C2-01, sig-bbbbbbbbbbbb; added: 2026-09-11T00:00:00Z]\n' > .factory/lessons/orders.md
out="$(bash $H/factory-retro.sh "$RT")"
check "resolved section shows what fixed it" 'printf "%s" "$out" | grep -q "resolved by: added the missing DI registration in Startup.cs"' "$out"
check "foreign-file hint names the other task" 'printf "%s" "$out" | grep -q -- "- C2-01 aaaaaaaaaaaa: src/billing/B.cs (also listed by: C2-02)"' "$(printf "%s" "$out" | sed -n "/outside the task/,/gate_isolation/p")"
check "own file is not a hint" '! printf "%s" "$out" | grep -q -- "- C2-01 bbbbbbbbbbbb: src/orders/A.cs"'
check "lesson recurrence is counted after its date only" 'printf "%s" "$out" | grep -q "sig-bbbbbbbbbbbb: 1 red run(s) since this lesson was added"' "$(printf "%s" "$out" | sed -n "/Lessons in force/,/Decisions/p")"

echo "=== template gate isolation"
G="$WORK/iso"; rm -rf "$G"; mkdir -p "$G"; cd "$G" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
mkdir -p src gates .factory/verified tasks/in-progress
printf 'base\n' > src/a.txt; printf 'old\n' > src/old.txt
python3 "$EXTRACT" gates/verify.sh >/dev/null
git add -A; git commit -qm base
# a post-checkout hook that must NOT run for the gate's worktree
mkdir -p .git/hooks; printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$G" > .git/hooks/post-checkout; chmod +x .git/hooks/post-checkout
cfg() {  # <isolation> <build> <test> [links-json]
  jq -n --argjson i "$1" --arg b "$2" --arg t "$3" --argjson l "${4:-[]}" \
    '{gate_mode: "full", min_tests: 1, gate_isolation: $i, isolation_links: $l, commands: {build: $b, test: $t, arch: "", lint: "true"}}' > .factory/config.json
}
gate() { bash gates/verify.sh C2-01 > "$WORK/iso.out" 2>&1; }
# the task's own work
printf 'task-edit\n' >> src/a.txt; rm src/old.txt
mktask "$G" in-progress C2-01 m src/a.txt src/old.txt
# a neighbour's half-written, uncommitted file
printf 'BROKEN half written\n' > src/neighbour.txt
BUILD='! grep -rq BROKEN src'
TEST='grep -q task-edit src/a.txt && test ! -e src/old.txt && echo "1 passed"'
cfg false "$BUILD" "$TEST"
gate; rc=$?
check "shared tree: neighbour's file turns the task red" '[ $rc -eq 1 ]' "$(tail -3 "$WORK/iso.out")"
rm -rf .factory/failures .factory/no-progress .factory/baseline.json
cfg true "$BUILD" "$TEST"
gate; rc=$?
check "isolated: same task is green" '[ $rc -eq 0 ] && grep -q "GATE isolation: HEAD + 2 listed file(s)" "$WORK/iso.out"' "$(cat "$WORK/iso.out")"
check "isolated: task edit and deletion both present in the checked tree" 'grep -q "GATE test: PASS" "$WORK/iso.out"'
check "marker says isolated=yes" 'grep -qx "isolated=yes" .factory/verified/C2-01'
check "worktree removed afterwards" '[ "$(git worktree list | wc -l | tr -d " ")" = 1 ]' "$(git worktree list)"
check "post-checkout hook did not run" '[ ! -e "$G/hook-ran" ]'
check "shared tree untouched by the gate" '[ -e src/neighbour.txt ] && grep -q task-edit src/a.txt && [ ! -e src/old.txt ]'

# forgetting a file in the list shows up as red when isolated
mktask "$G" in-progress C2-01 m src/old.txt
gate; rc=$?
check "isolated: file missing from the list makes it red" '[ $rc -eq 1 ] && [ ! -e .factory/verified/C2-01 ]' "$(tail -4 "$WORK/iso.out")"
mktask "$G" in-progress C2-01 m
gate; rc=$?
check "isolated: empty list is refused" '[ $rc -eq 1 ] && grep -q "lists no files" "$WORK/iso.out"' "$(tail -4 "$WORK/iso.out")"
rm -rf .factory/failures .factory/no-progress

# signature paths are normalised to <root>, not the temp dir
mktask "$G" in-progress C2-01 m src/a.txt src/old.txt
cfg true 'echo "error: $(pwd)/src/x.cs is wrong"; false' "$TEST"
gate
sig="$(cat .factory/failures/sig-*.txt 2>/dev/null)"
check "isolated failure signature uses <root>" 'printf "%s" "$sig" | grep -q "<root>/src/x.cs"' "$sig"
rm -rf .factory/failures .factory/no-progress

# isolation_links: an untracked dependency dir is linked in
mkdir -p node_modules; printf 'x\n' > node_modules/dep.txt
cfg true 'test -f node_modules/dep.txt' "$TEST"
gate; rc=$?
check "without the link the cold tree lacks it" '[ $rc -eq 1 ]' "$(tail -3 "$WORK/iso.out")"
rm -rf .factory/failures .factory/no-progress
cfg true 'test -f node_modules/dep.txt' "$TEST" '["node_modules"]'
gate; rc=$?
check "with isolation_links it builds" '[ $rc -eq 0 ]' "$(tail -3 "$WORK/iso.out")"
check "still no stray worktrees" '[ "$(git worktree list | wc -l | tr -d " ")" = 1 ]'

echo "=== isolation with the factory in a subdirectory"
M="$WORK/mono"; rm -rf "$M"; mkdir -p "$M/svc/src" "$M/svc/gates" "$M/svc/.factory/verified"; cd "$M" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
printf 'base\n' > svc/src/a.txt; python3 "$EXTRACT" svc/gates/verify.sh >/dev/null
git add -A; git commit -qm base
cd svc
printf 'task-edit\n' >> src/a.txt
mktask "$M/svc" in-progress C2-01 m src/a.txt
jq -n '{gate_mode: "full", min_tests: 1, gate_isolation: true, commands: {build: "true", test: "grep -q task-edit src/a.txt && echo \"1 passed\"", arch: "", lint: "true"}}' > .factory/config.json
bash gates/verify.sh C2-01 > "$WORK/mono.out" 2>&1; rc=$?
check "subdirectory factory maps into the worktree" '[ $rc -eq 0 ]' "$(tail -5 "$WORK/mono.out")"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
