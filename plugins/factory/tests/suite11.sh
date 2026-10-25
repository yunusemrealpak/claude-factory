#!/usr/bin/env bash
# Sandbox tests: release 3.1 - commits that never left the machine stop the
# factory (the unpushed breaker), an upgrade commits its own config change so the
# retrospective is not locked out, and an unclassified gate result keeps a hint.
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
. "$H/factory-compat.sh"
PLUGIN="$(cd "$H/.." && pwd)"
WORK="${FACTORY_TEST_DIR:-$(mktemp -d)}"
export PATH="${PLUGIN}/bin:$PATH"
export FACTORY_NO_NOTIFY=1
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

REMOTE="$WORK/s11-remote.git"; rm -rf "$REMOTE"; git init -q --bare -b main "$REMOTE"
P="$WORK/s11-proj"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
git init -q -b main .; git config user.email dev@example.com; git config user.name dev
git remote add origin "$REMOTE"
mkdir -p tasks/backlog tasks/in-progress tasks/done .factory/inflight
: > .factory/active; printf '.factory/\n' > .gitignore
echo '{"verify":"gates/verify.sh","delivery":{"base":"main","max_unpushed":3}}' > .factory/config.json
printf -- '---\nid: C1-01\ntitle: t\nmodule: core\ndepends_on: []\nacceptance: true\nneeds_human: false\nreview: on-red\nretries: 0\nowner:\nstage: backlog\nstage_since:\n---\n\n## Files touched\n\n## Attempts\n' > tasks/backlog/C1-01.md
echo base > a.txt; git add -A; git commit -qm base; git push -q origin main
export FACTORY_ROOT="$P"
U="$H/factory-unpushed.sh"

echo "=== the unpushed breaker"
out="$(bash "$U")"
check "nothing ahead counts 0" '[ "$out" = "0" ]' "$out"
for i in 1 2; do echo "$i" >> a.txt; git commit -qam "c$i"; done
out="$(bash "$U")"
check "two local commits count 2" '[ "$out" = "2" ]' "$out"
check "below the limit the check passes" 'bash "$U" check >/dev/null'
echo 3 >> a.txt; git commit -qam c3
out="$(bash "$U" check)"; rc=$?
check "at the limit the check refuses and says how to leave" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "UNPUSHED LIMIT: 3 commit" && printf "%s" "$out" | grep -q "auto devam et"' "$out"
out="$(cd "$P" && bash "$H/factory-start.sh" C1-01 2>&1)"; rc=$?
check "factory-start refuses to take a task" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "START REFUSED for C1-01: UNPUSHED LIMIT"' "$out"
check "the task stayed in the backlog" '[ -f tasks/backlog/C1-01.md ] && [ ! -f tasks/in-progress/C1-01.md ]'
bash "$H/factory-dash.sh" >/dev/null 2>&1
check "the status line carries the count" 'grep -q "^unpushed=3$" .factory/statusline.txt' "$(cat .factory/statusline.txt 2>/dev/null)"
jq '.delivery.max_unpushed = 0' .factory/config.json > c && mv c .factory/config.json
check "a limit of 0 turns the check off" 'bash "$U" check >/dev/null'
git push -q origin main
out="$(bash "$U")"
check "after a push the count is 0 again" '[ "$out" = "0" ]' "$out"
rm -rf "$WORK/s11-noremote"; mkdir -p "$WORK/s11-noremote"; (cd "$WORK/s11-noremote" && git init -q -b main . && git config user.email d@e.x && git config user.name d && echo x > f && git add -A && git commit -qm x)
out="$(FACTORY_ROOT="$WORK/s11-noremote" bash "$U")"
check "no remote ref counts 0" '[ "$out" = "0" ]' "$out"

echo "=== an unclassified gate result keeps its tail"
LOG="$P/.factory/events.jsonl"; : > "$LOG"
post() { jq -cn --arg c "$P" --arg cmd "$1" --arg e "$2" '{cwd:$c, hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:$cmd}, tool_response:{stdout:"", stderr:$e}}' | bash "$H/factory-event.sh"; }
post "factory-check C1-01" "something nobody expected happened"
check "unknown stays unknown, with a hint" 'jq -e "select(.kind==\"gate\" and .verdict==\"unknown\" and (.hint|test(\"nobody expected\")))" "$LOG" >/dev/null' "$(cat "$LOG")"
post "factory-check C1-01" "CHECK: no task file for C1-01 under tasks/"
check "a refused check is classified, not unknown" 'jq -e "select(.kind==\"gate\" and .verdict==\"refused\")" "$LOG" >/dev/null' "$(cat "$LOG")"

echo "=== the upgrade commits its config change"
U2="$WORK/s11-upgrade"; rm -rf "$U2"; mkdir -p "$U2"; cd "$U2" || exit 1
git init -q -b main .; git config user.email dev@example.com; git config user.name dev
mkdir -p .factory gates tasks/backlog; : > .factory/active
printf '.factory/verified/\n' > .gitignore
echo '{"factory_version":"2.5","verify":"gates/verify.sh","workers":2}' > .factory/config.json
git add -A; git commit -qm base
export FACTORY_ROOT="$U2"
out="$(bash "$H/factory-upgrade.sh" --apply 2>&1)"
check "the config got its missing keys" 'jq -e ".delivery.max_unpushed and .fast.workers" .factory/config.json >/dev/null' "$out"
check "and the change is a commit of that file alone" '[ -z "$(git status --porcelain -- .factory/config.json)" ] && git log -1 --format=%B | grep -q "^Factory-Upgrade:"' "$(git log -1 --format=%B)"
check "max_unpushed is written with its default" '[ "$(jq -r .delivery.max_unpushed .factory/config.json)" = "30" ]'
echo '{"factory_version":"2.5","verify":"gates/verify.sh"}' > .factory/config.json
git add -A; git commit -qm back; echo ' ' >> .factory/config.json
out="$(bash "$H/factory-upgrade.sh" --apply 2>&1)"
check "a config with the developer's own uncommitted edit is left uncommitted" '[ -n "$(git status --porcelain -- .factory/config.json)" ]' "$(git status --porcelain)"

echo "=== optional bans: the developer's choice per project"
B2="$WORK/s11-bans"; rm -rf "$B2"; mkdir -p "$B2/.factory" "$B2/.claude"; cd "$B2" || exit 1
git init -q -b main .; : > .factory/active
echo '{"verify":"gates/verify.sh"}' > .factory/config.json
export FACTORY_ROOT="$B2"
hb() { printf '%s' "$2" | bash "$H/factory-hardblock.sh" check "$B2" "$1"; }
out="$(hb bash 'fastlane beta')"; rc=$?
check "store tooling is banned by default" '[ $rc -eq 3 ] && [ "$out" = "store-deploy" ]' "$out"
bash "$H/factory-deny.sh" --apply >/dev/null
check "and its deny rule is in settings.json" 'jq -e ".permissions.deny | index(\"Bash(fastlane *)\")" .claude/settings.json >/dev/null'
bash "$H/factory-bans.sh" allow store-deploy >/dev/null
hb bash 'fastlane beta' >/dev/null; rc=$?
check "an allowed group no longer trips the guard" '[ $rc -eq 0 ]'
check "its deny rules left settings.json" '! jq -e ".permissions.deny | index(\"Bash(fastlane *)\")" .claude/settings.json >/dev/null'
hb bash 'git tag v1' >/dev/null; rc=$?
check "a group not allowed stays banned" '[ $rc -eq 3 ]'
hb bash 'git push origin main' >/dev/null; rc=$?
check "a ban that is not optional stays banned" '[ $rc -eq 3 ]'
bash "$H/factory-deny.sh" --apply >/dev/null
check "a re-run of factory-deny does not put it back" '! jq -e ".permissions.deny | index(\"Bash(fastlane *)\")" .claude/settings.json >/dev/null'
check "the hard-block version carries the allowed set" '[ "$(bash "$H/factory-hardblock.sh" version "$B2")" = "1+store-deploy" ]'
hb bash 'factory-bans allow git-tag' >/dev/null; rc=$?
check "an agent may not change the choice" '[ $rc -eq 3 ]'
bash "$H/factory-bans.sh" forbid store-deploy >/dev/null
hb bash 'fastlane beta' >/dev/null; rc=$?
check "forbid bans it again, rule and deny line" '[ $rc -eq 3 ] && jq -e ".permissions.deny | index(\"Bash(fastlane *)\")" .claude/settings.json >/dev/null'
bash "$H/factory-bans.sh" allow nonsense >/dev/null 2>&1; rc=$?
check "an unknown group is refused" '[ $rc -eq 1 ]'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
