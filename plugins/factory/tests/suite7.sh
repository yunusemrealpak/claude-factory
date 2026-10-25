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
# A soft hit refuses the one call and does not halt the run (exit 5).
soft()  { local out rc; out="$(hb "$1" "$2")"; rc=$?; [ "$rc" -eq 5 ] && [ "$out" = "$3" ]; }

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
check "push inside an argument" 'clean bash "git log --grep=\"push the button\""'
check "git log --oneline"     'clean bash "git log --oneline -5"'
check "gh pr view"            'clean bash "gh pr view 3"'
check "gh api read"           'clean bash "gh api repos/a/b"'
check "write src file"        'clean path "$P/lib/main.dart"'
check "echo to a log"         'clean bash "echo hi > out.log"'

echo "=== matcher: one spelling per file (Windows, case, dot segments)"
hbr() {  # <root> <kind> <text>
  printf '%s' "$3" | bash "$H/factory-hardblock.sh" check "$1" "$2"
}
hitr() { local out rc; out="$(hbr "$1" "$2" "$3")"; rc=$?; [ "$rc" -eq 3 ] && [ "$out" = "$4" ]; }
Q="'"
check "C:\\ path inside root"          'hitr "C:\\proj" path "C:\\proj\\gates\\verify.sh" gates-dir'
check "drive and folder in other case" 'hitr "C:\\proj" path "c:/PROJ/.factory/config.json" factory-config'
check "/c/ spelling in a command"      'hitr "C:\\proj" bash "echo x > /c/proj/.factory/STOP" stop-switch'
check "backslashes in a command"       'hitr "C:\\proj" bash "echo K=1 > C:\\proj\\.env" env-file'
check "an MSYS root, a Windows path"   'hitr "/c/proj" path "C:\\proj\\gates\\x.sh" gates-dir'
check "dir/../ inside the root"        'hit path "$P/src/../gates/verify.sh" gates-dir'
check "../ from a subfolder"           'hit bash "cd src && echo x > ../gates/verify.sh" gates-dir'
check "letter case of a folder"        'hit path "$P/GATES/run.sh" gates-dir'
check "letter case of a command"       'hit bash "GIT push origin main" git-push'
check "a nested gates/ is not the root one" 'clean path "$P/src/gates/x.ts"'

echo "=== matcher: git that rewrites the shared tree"
for c in "git checkout -- src/a.txt" "git stash" "git stash pop" "git restore src" "git reset --hard" "git add -A" \
         "git commit -m x" "git clean -fd" "git -C sub checkout main" "git switch -c x" "git apply x.patch" \
         "git cherry-pick abc" "git worktree add ../x" "git config core.hooksPath /dev/null" "git update-ref HEAD x"; do
  check "refused: $c" 'hit bash "$c" git-tree-write'
done
check "git -c on the command line"     'hit bash "git -c core.hooksPath=/dev/null log" git-inline-config'
check "GIT_CONFIG_* in the env"        'hit bash "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath git log" git-env-config'
for c in "git status" "git log --oneline -5" "git diff --stat" "git show HEAD:src/a.txt" "git rev-parse HEAD" \
         "git blame src/a.txt" "git log -c" "git diff HEAD -- src" "git ls-files"; do
  check "read-only: $c" 'clean bash "$c"'
done

echo "=== matcher: the factory's own state"
check "cd into .factory"               'hit bash "cd .factory && echo x > config.json" protected-cd'
check "cd into gates"                  'hit bash "cd gates; ls" protected-cd'
check "cd into src is fine"            'clean bash "cd src && ls"'
check "an agent answers a question"    'hit bash "factory-ask answer Q1 yes" ask-answer'
check "an agent asks one"              'clean bash "factory-ask ask T-1 \"which one?\""'
check "touch a verified marker"        'hit bash "touch .factory/verified/T-1" factory-verified'
check "write a verified marker"        'hit bash "echo ok > .factory/verified/T-1" factory-verified'
check "write tool: verified marker"    'hit path "$P/.factory/verified/T-1" factory-verified'
check "removing a marker is allowed"   'clean bash "rm -f .factory/verified/T-1"'
check "run-start.json"                 'hit bash "echo {} > .factory/run-start.json" factory-run-start'
check "no-progress"                    'hit bash "rm .factory/no-progress/T-1" factory-no-progress'
check "failures"                       'hit path "$P/.factory/failures/T-1.txt" factory-failures'
check "questions"                      'hit path "$P/.factory/questions/Q1.md" factory-questions'
check "lessons"                        'hit bash "echo rule >> .factory/lessons/core.md" factory-lessons'
check "rules"                          'hit path "$P/.factory/rules/pnpm-only.rule" factory-rules'
check "removing a rule"                'hit bash "rm .factory/rules/pnpm-only.rule" factory-rules'
check "the event log"                  'hit bash "echo {} >> .factory/events.jsonl" factory-events'
check "publisher state"                'hit path "$P/.factory/publish/C1.json" factory-publish-state'
check "the active switch"              'hit bash "rm .factory/active" factory-active'
check "a git hook"                     'hit path "$P/.git/hooks/pre-commit" git-dir'
check "git config file"                'hit bash "echo x >> .git/config" git-dir'
check "reading .git is fine"           'clean bash "cat .git/HEAD"'

echo "=== matcher: inline code that writes"
check "python -c writes a marker"      'soft bash "python3 -c \"open(${Q}.factory/verified/T-1${Q},${Q}w${Q}).write(${Q}ok${Q})\"" factory-verified'
check "node -e writes the gate"        'soft bash "node -e \"require(${Q}fs${Q}).writeFileSync(${Q}gates/verify.sh${Q},${Q}exit 0${Q})\"" gates-dir'
check "a python heredoc writes config" 'soft bash "$(printf "python3 - <<EOF\nimport pathlib\npathlib.Path(\".factory/config.json\").write_text(\"{}\")\nEOF\n")" factory-config'
check "python reading config passes"   'clean bash "python3 -c \"print(open(${Q}.factory/config.json${Q}).read())\" 2>/dev/null"'
check "python tests pass"              'clean bash "python3 -m pytest tests/ -q 2>/dev/null"'
check "sed -n reading config passes"   'clean bash "sed -n 1,5p .factory/config.json"'

echo "=== matcher: PowerShell"
check "Set-Content to gates"           'hit powershell "Set-Content -Path gates\\verify.sh -Value x" gates-dir'
check "Out-File to STOP"               'hit powershell "\"x\" | Out-File .factory\\STOP" stop-switch'
check "git push from PowerShell"       'hit powershell "git push origin main" git-push'
check "[IO.File] write to config"      'soft powershell "[IO.File]::WriteAllText(${Q}.factory/config.json${Q}, ${Q}{}${Q})" factory-config'
check "Get-Content is fine"            'clean powershell "Get-Content .factory/config.json"'

echo "=== matcher: the shared cases, in Python and in JavaScript"
# tests/hardblock-cases.txt holds both judges to one answer per command.
wrong=""; n=0
while IFS=$'\t' read -r expect kind root raw; do
  case "${expect}" in ''|'#'*) continue ;; esac
  [ "${root}" = "-" ] && root="$P"
  text="${raw//\{R\}/$root}"; text="${text//\{NL\}/$'\n'}"
  out="$(printf '%s' "${text}" | bash "$H/factory-hardblock.sh" check "${root}" "${kind}" 2>&1)"; rc=$?
  case $rc in 0) got=clean ;; 3) got="hard:${out}" ;; 5) got="soft:${out}" ;; *) got="rc${rc}:${out}" ;; esac
  n=$((n + 1))
  [ "${got}" = "${expect}" ] || wrong="${wrong}
  ${kind} ${text}: expected ${expect}, got ${got}"
done < "$H/../tests/hardblock-cases.txt"
check "every shared case, through factory-hardblock.sh ($n)" '[ "$n" -gt 100 ] && [ -z "$wrong" ]' "$wrong"
if command -v node >/dev/null 2>&1; then
  out="$(node "$H/../tests/hb-cases.mjs" 2>&1)"
  check "every shared case, through register.js" 'printf "%s" "$out" | grep -q "^cases=[0-9]* wrong=0$"' "$out"
else
  echo "SKIP register.js half: no node on PATH"
fi

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
guard2() {  # <cwd> <agent> <tool> <text>
  jq -cn --arg cwd "$1" --arg a "$2" --arg t "$3" --arg c "$4" \
    '{cwd:$cwd, tool_name:$t, tool_input:(if ($t=="Bash" or $t=="PowerShell") then {command:$c} else {file_path:$c} end)} + (if $a=="" then {} else {agent_id:$a} end)' \
    | bash "$H/factory-done-guard.sh"; }
mkdir -p src
out="$(guard2 "$P/src" agent-1 Write "$P/gates/verify.sh")"
check "a subagent that cd'd into src/ is still judged" 'printf "%s" "$out" | grep -q deny' "$out"
rm -f .factory/STOP
out="$(guard2 "$P" agent-1 PowerShell "Set-Content gates/verify.sh x")"
check "subagent PowerShell is judged" 'printf "%s" "$out" | grep -q deny' "$out"
rm -f .factory/STOP
out="$(guard2 "$P" agent-1 MultiEdit "$P/.factory/config.json")"
check "subagent MultiEdit is judged" 'printf "%s" "$out" | grep -q deny' "$out"
rm -f .factory/STOP
check "the guard hook sees PowerShell and MultiEdit" 'jq -e ".hooks.PreToolUse[0].matcher | test(\"PowerShell\") and test(\"MultiEdit\")" "$H/hooks.json" >/dev/null'

echo "=== agents: only tools the factory can judge"
bad_tools=""
for a in "$H"/../agents/*.md; do
  # The lead is the developer's own session's role (/factory:run), not a subagent.
  [ "$(basename "$a")" = lead.md ] && continue
  t="$(sed -n 's/^tools:[[:space:]]*//p' "$a" | head -1 | tr -d '\r')"
  [ -n "$t" ] || { bad_tools="$bad_tools $(basename "$a"):(all)"; continue; }
  for x in $(printf '%s' "$t" | tr ',' ' '); do
    case "$x" in Read|Write|Edit|Bash|Grep|Glob) ;; *) bad_tools="$bad_tools $(basename "$a"):$x" ;; esac
  done
done
check "every agent lists its tools, all judgeable" '[ -z "$bad_tools" ]' "$bad_tools"

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

echo "=== 3.3: the tests HEAD has are read-only"
T="$WORK/s7-tests"; rm -rf "$T"; mkdir -p "$T/.factory" "$T/tests/api" "$T/src" "$T/tasks/in-progress" "$T/.github/workflows"
cd "$T" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
: > .factory/active; printf '.factory/\n' > .gitignore
printf 'def test_a(): assert 1\n' > tests/test_old.py; printf 'x\n' > tests/api/test_api.py
printf 'x\n' > conftest.py; printf 'on: push\n' > .github/workflows/ci.yml; printf 'x\n' > src/app.py
printf -- '---\nid: R1\nmodifies_tests: false\n---\n' > tasks/in-progress/R1.md
git add -A; git commit -qm base
ro() { printf '%s' "$2" | HB_CWD="${3:-}" bash "$H/factory-hardblock.sh" check "$T" "$1"; }
out="$(ro path "$T/tests/test_old.py")"; rc=$?
check "an edit of a test HEAD has is refused, and only refused" '[ $rc -eq 6 ] && [ "$out" = "head-tests tests/test_old.py" ]' "$rc $out"
out="$(ro path "$T/tests/test_new.py")"; rc=$?
check "a new test file is the agent's to write" '[ $rc -eq 0 ]' "$rc $out"
out="$(ro bash "echo 'def test_b(): pass' >> tests/test_old.py")"; rc=$?
check "a redirect into a test HEAD has is refused" '[ $rc -eq 6 ]' "$rc $out"
out="$(ro bash "sed -i s/1/0/ test_old.py" "$T/tests")"; rc=$?
check "...from the directory the agent moved to, too" '[ $rc -eq 6 ] && [ "$out" = "head-tests tests/test_old.py" ]' "$rc $out"
out="$(ro bash "cd tests && rm test_old.py")"; rc=$?
check "...and after a cd in the same command" '[ $rc -eq 6 ]' "$rc $out"
out="$(ro bash "python3 -m pytest tests/test_old.py && sed -n 1p tests/test_old.py && cp tests/test_old.py tests/test_new.py")"; rc=$?
check "running, reading and copying a test is not writing it" '[ $rc -eq 0 ]' "$rc $out"
out="$(ro path "$T/conftest.py")"; rc=$?
check "test infrastructure HEAD has is read-only" '[ $rc -eq 6 ] && [ "$out" = "head-tests conftest.py" ]' "$rc $out"
out="$(ro path "$T/.github/workflows/ci.yml")"; rc=$?
check "...a CI workflow too" '[ $rc -eq 6 ]' "$rc $out"
out="$(ro path "$T/tests/api/conftest.py")"; rc=$?
check "...but new infrastructure is not" '[ $rc -eq 0 ]' "$rc $out"
out="$(ro path "$T/src/app.py")"; rc=$?
check "product code is not a test" '[ $rc -eq 0 ]' "$rc $out"
printf -- '---\nid: R1\nmodifies_tests: false\n---\n' > tasks/in-progress/R1.md
sed -i.bak 's/^modifies_tests: .*/modifies_tests: [tests\/api\/*]/' tasks/in-progress/R1.md && rm -f tasks/in-progress/R1.md.bak
out="$(ro path "$T/tests/api/test_api.py")"; rc=$?
check "an exemption a builder writes into its own task file grants nothing" '[ $rc -eq 6 ]' "$rc $out"
git commit -qam "approve R1 for the api tests"
out="$(ro path "$T/tests/api/test_api.py")"; rc=$?
check "an approved modifies_tests list frees exactly its paths" '[ $rc -eq 0 ]' "$rc $out"
out="$(ro path "$T/tests/test_old.py")"; rc=$?
check "...and nothing else" '[ $rc -eq 6 ]' "$rc $out"
out="$(printf '%s' "$T/tests/test_old.py" | bash "$H/factory-hardblock.sh" tests "$T" path)"; rc=$?
check "the tests-only question register.js asks gets the same answer" '[ $rc -eq 6 ]' "$rc $out"
rm -f .factory/STOP
out="$(jq -cn --arg cwd "$T" --arg c "$T/tests/test_old.py" '{cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$c}, agent_id:"a1"}' | bash "$H/factory-done-guard.sh")"
check "the PreToolUse hook refuses the edit and the run goes on" 'printf "%s" "$out" | grep -q "read-only for this task" && [ ! -f .factory/STOP ]' "$out"
out="$(jq -cn --arg cwd "$T" --arg c "$T/tests/test_old.py" '{cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$c}}' | bash "$H/factory-done-guard.sh")"
check "the developer's own session is not judged" '! printf "%s" "$out" | grep -q "read-only"' "$out"
check "the default test-file pattern is factory-check's own" 'grep -q "census_regexes" "$H/factory-check.py" && grep -q "readonly_tests" "$H/factory-hardblock.py"'
cd "$P" || exit 1

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
