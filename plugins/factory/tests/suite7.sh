#!/usr/bin/env bash
# Sandbox tests: release 2.7 - the hard bans (hard-blocks.txt, the shell matcher,
# the PreToolUse guard for subagents, the STOP switch), the autonomy consent
# (factory-consent, factory-autonomy) and the permissions.deny merge.
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

P="$WORK/s7"; rm -rf "$P"; mkdir -p "$P/.factory" "$P/gates"
cd "$P" || exit 1
git init -q . 2>/dev/null
git config user.email dev@example.com
touch .factory/active
echo '{"verify":"gates/verify.sh"}' > .factory/config.json
export FACTORY_ROOT="$P"

hb() {  # <kind> <text> -> rule name on stdout, exit code
  printf '%s' "$2" | bash "$H/factory-hardblock.sh" check "$P" "$1"
}
hit()   { local out rc; out="$(hb "$1" "$2")"; rc=$?; [ "$rc" -eq 3 ] && [ "$out" = "$3" ]; }
clean() { hb "$1" "$2" >/dev/null; [ $? -eq 0 ]; }

echo "=== matcher: one case per rule"
check "git push"              'hit bash "git push origin main" git-push'
check "git -C x push"         'hit bash "git -C sub push" git-push'
check "git push after &&"     'hit bash "make && git push" git-push'
check "git push, multi-line"  'hit bash "$(printf "echo a\ngit push\n")" git-push'
check "git push --force"      'hit bash "git push --force" git-push'
check "git rebase --force"    'hit bash "git rebase --force x" git-force'
check "git tag"               'hit bash "git tag v1" git-tag'
check "git --no-verify"       'hit bash "git commit --no-verify -m x" git-no-verify'
check "git remote set-url"    'hit bash "git remote set-url origin x" git-remote-set-url'
check "gh pr merge"           'hit bash "gh pr merge 3" gh-pr-merge'
check "gh release"            'hit bash "gh release create v1" gh-release'
check "gh api -X"             'hit bash "gh api repos/a/b -X POST" gh-api-write'
check "fastlane"              'hit bash "bundle exec fastlane beta" store-deploy'
check "xcrun altool"          'hit bash "xcrun altool --upload-app" store-deploy'
check "redirect to .env"      'hit bash "echo K=1 > .env" env-file'
check "tee to .env.local"     'hit bash "echo K=1 | tee .env.local" env-file'
check "cp to key.p8"          'hit bash "cp a keys/AuthKey.p8" apple-key'
check "mv to jks"             'hit bash "mv a release.jks" android-keystore'
check "rm gates/verify"       'hit bash "rm gates/verify.sh" gates-dir'
check "sed -i verify.sh"      'hit bash "sed -i s/a/b/ tools/verify.sh" verify-script'
check "redirect baseline"     'hit bash "echo {} > .factory/baseline.json" census-baseline'
check "redirect config"       'hit bash "echo {} >> .factory/config.json" factory-config'
check "redirect autonomy"     'hit bash "echo {} > .factory/autonomy.json" autonomy-consent'
check "tee autonomy-off"      'hit bash "echo x | tee .factory/autonomy-off" autonomy-consent'
check "rm STOP"               'hit bash "rm .factory/STOP" stop-switch'
check "absolute path inside root" 'hit bash "echo x > $P/.factory/autonomy.json" autonomy-consent'
check "write tool: .env"      'hit path "$P/.env.production" env-file'
check "write tool: gates"     'hit path "$P/gates/verify.sh" gates-dir'
check "write tool: autonomy"  'hit path "$P/.factory/autonomy.json" autonomy-consent'
check "write tool: STOP"      'hit path "$P/.factory/STOP" stop-switch'

echo "=== matcher: clean commands"
check "git status"            'clean bash "git status"'
check "git commit message"    'clean bash "git commit -m \"push the button\""'
check "git log --oneline"     'clean bash "git log --oneline -5"'
check "gh pr view"            'clean bash "gh pr view 3"'
check "gh api read"           'clean bash "gh api repos/a/b"'
check "write src file"        'clean path "$P/lib/main.dart"'
check "echo to a log"         'clean bash "echo hi > out.log"'

echo "=== matcher: unreadable rules fail closed"
printf 'x' | FACTORY_HARD_BLOCKS=/nonexistent bash "$H/factory-hardblock.sh" check "$P" bash >/dev/null 2>&1
check "missing rule file exits 4" '[ $? -eq 4 ]'

echo "=== guard: subagents are judged, the main session is not"
guard() { jq -cn --arg cwd "$P" --arg a "$1" --arg t "$2" --arg c "$3" \
  '{cwd:$cwd, tool_name:$t, tool_input:(if $t=="Bash" then {command:$c} else {file_path:$c} end)} + (if $a=="" then {} else {agent_id:$a} end)' \
  | bash "$H/factory-done-guard.sh"; }
rm -f .factory/STOP
out="$(guard agent-1 Bash "git push origin main")"
check "subagent git push is denied" 'printf "%s" "$out" | jq -e ".hookSpecificOutput.permissionDecision == \"deny\"" >/dev/null' "$out"
check "...and STOP is written"      '[ -f .factory/STOP ]'
check "...and an event is logged"   'grep -q hard_block .factory/events.jsonl'
rm -f .factory/STOP
out="$(guard "" Bash "git push origin main")"
check "main session git push passes the guard" '[ -z "$out" ]' "$out"
out="$(guard agent-1 Write "$P/gates/verify.sh")"
check "subagent write to gates is denied" 'printf "%s" "$out" | grep -q deny' "$out"
rm -f .factory/STOP
out="$(guard "" Write "$P/gates/verify.sh")"
check "main session writes gates freely" '[ -z "$out" ]' "$out"
out="$(guard agent-1 Bash "git status")"
check "subagent clean command passes" '[ -z "$out" ] && [ ! -f .factory/STOP ]' "$out"

echo "=== STOP halts factory-start"
mkdir -p tasks/backlog tasks/in-progress
printf -- '---\nid: S-1\ntitle: t\nmodule: core\ndepends_on: []\nacceptance: true\nneeds_human: false\nreview: on-red\nretries: 0\nowner:\nstage: queued\nstage_since:\n---\n\n## Goal\nx\n\n## Files touched\n\n## Attempts\n' > tasks/backlog/S-1.md
echo "hard block test" > .factory/STOP
out="$(bash "$H/factory-start.sh" S-1 builder 2>&1)"; rc=$?
check "start is refused while STOP exists" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "HALTED"' "$out"
check "...and the task did not move" '[ -f tasks/backlog/S-1.md ]'
rm -f .factory/STOP

echo "=== consent"
SID="sess-7"
TP="$WORK/s7-transcript.jsonl"
consent() {  # <prompt> [origin]
  jq -cn --arg p "$1" --arg cwd "$P" --arg s "$SID" --arg tp "$TP" --arg o "${2:-}" \
    '{prompt:$p, cwd:$cwd, session_id:$s, transcript_path:$tp} + (if $o=="" then {} else {origin:$o} end)' \
    | bash "$H/factory-consent.sh" >/dev/null
}
say() { jq -cn --arg t "$1" '{type:"user", message:{role:"user", content:$t}}' >> "$TP"; }
reset() { rm -f .factory/autonomy.json .factory/autonomy-off "$TP"; }
level() { bash "$H/factory-autonomy.sh"; }

reset; consent "auto devam et"
check "the plain phrase records consent" '[ -s .factory/autonomy.json ]'
check "...at the default level merge"    '[ "$(jq -r .level .factory/autonomy.json)" = merge ]'
check "...with the hard-block version"   '[ "$(jq -r .hard_blocks_version .factory/autonomy.json)" = "$(bash $H/factory-hardblock.sh version)" ]'
check "...by the git user"               '[ "$(jq -r .consented_by .factory/autonomy.json)" = dev@example.com ]'
check "without a transcript line the level is local" '[ "$(level)" = local ]'
say "auto devam et"
check "with the line in the transcript it is merge" '[ "$(level)" = merge ]'
jq '.hard_blocks_version = "0"' .factory/autonomy.json > a.tmp && mv a.tmp .factory/autonomy.json
check "a hard-block version mismatch is local" '[ "$(level)" = local ]'

for phrase in "yarın auto devam et" "auto devam et lütfen" "\"auto devam et\"" $'merhaba\nauto devam et' "auto devam etme" "do not auto devam et"; do
  reset; consent "$phrase"
  check "not consent: $(printf '%s' "$phrase" | tr '\n' '|')" '[ ! -e .factory/autonomy.json ]'
done
reset; consent "AUTO DEVAM"; check "case-insensitive, without et" '[ -s .factory/autonomy.json ]'
reset; consent "auto devam et" subagent; check "a non-human origin is ignored" '[ ! -e .factory/autonomy.json ]'
reset; consent "auto devam et" composer; check "a composer origin counts" '[ -s .factory/autonomy.json ]'

jq '.autonomy_default = "pr"' .factory/config.json > c.tmp && mv c.tmp .factory/config.json
reset; consent "auto devam et"
check "autonomy_default sets the level" '[ "$(jq -r .level .factory/autonomy.json)" = pr ]'
jq 'del(.autonomy_default)' .factory/config.json > c.tmp && mv c.tmp .factory/config.json

reset; consent "auto devam et"; say "auto devam et"
check "level is merge before off" '[ "$(level)" = merge ]'
consent "auto dur"
check "auto dur writes autonomy-off"  '[ -f .factory/autonomy-off ]'
check "...and the level is local"     '[ "$(level)" = local ]'
consent "auto devam et"
check "a new consent clears the off switch" '[ ! -f .factory/autonomy-off ] && [ "$(level)" = merge ]'
bash "$H/factory-autonomy.sh" off >/dev/null
check "factory-autonomy off returns to local" '[ "$(level)" = local ]'
reset

echo "=== deny merge"
mkdir -p .claude
echo '{"permissions":{"deny":["Bash(rm -rf /)"],"allow":["Bash(ls)"]},"autoCompactEnabled":true}' > .claude/settings.json
bash "$H/factory-deny.sh" >/dev/null; check "report mode exits 1 when rules are missing" '[ $? -eq 1 ]'
bash "$H/factory-deny.sh" --apply >/dev/null
n1="$(jq '.permissions.deny | length' .claude/settings.json)"
check "apply keeps the project's own rule"  'jq -e ".permissions.deny[0] == \"Bash(rm -rf /)\"" .claude/settings.json >/dev/null'
check "apply keeps allow and other keys"    'jq -e ".permissions.allow == [\"Bash(ls)\"] and .autoCompactEnabled" .claude/settings.json >/dev/null'
check "apply adds the git push rule"        'jq -e ".permissions.deny | index(\"Bash(git push *)\")" .claude/settings.json >/dev/null'
bash "$H/factory-deny.sh" --apply >/dev/null
check "a second apply is idempotent"        '[ "$(jq ".permissions.deny | length" .claude/settings.json)" = "$n1" ]'
bash "$H/factory-deny.sh" >/dev/null; check "report is clean afterwards" '[ $? -eq 0 ]'
rm -f .claude/settings.json; bash "$H/factory-deny.sh" --apply >/dev/null
check "apply creates settings.json when absent" '[ -s .claude/settings.json ]'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
