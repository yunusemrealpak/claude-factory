#!/usr/bin/env bash
# Sandbox tests: release 3.0 - the outer loop. factory-next goes only when the
# level is merge, the quota reading is fresh and under the line, no publish is
# in flight and no run is active; it runs in a worktree of its own. A fake
# `claude` stands in for the CLI, so nothing here starts a real run.
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

FC="$WORK/s10-fakeclaude"; rm -rf "$FC"; mkdir -p "$FC"
cat > "$FC/claude" <<'SH'
#!/usr/bin/env bash
{ echo "args: $*"; echo "cwd: $PWD"; echo "root: ${FACTORY_ROOT:-}"; echo "next: ${FACTORY_NEXT:-}"; } >> "$FC_LOG"
exit "${FC_RC:-0}"
SH
chmod +x "$FC/claude"
export FACTORY_CLAUDE="$FC/claude" FC_LOG="$FC/log"
TP="$WORK/s10-transcript.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"auto devam et"}}' > "$TP"
Q="$WORK/s10-quota.json"; export FACTORY_QUOTA_FILE="$Q"
now="$(date +%s)"
mkq() { jq -cn --argjson ts "$1" --argjson u "$2" --argjson l "$3" '{ts:$ts, seven_day:{used_percentage:$u, even_line:$l, resets_at:null}}' > "$Q"; }

newproj() {
  P="$WORK/s10-$1"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
  git init -q -b main .; git config user.email dev@example.com; git config user.name dev
  mkdir -p src tasks/backlog tasks/in-progress tasks/done .factory/inflight .factory/publish
  echo base > src/a.txt; : > .factory/active; printf '.factory/\n' > .gitignore
  echo '{"verify":"gates/verify.sh","autonomy_default":"merge","delivery":{"base":"main","quota_margin":10}}' > .factory/config.json
  printf -- '---\nid: C1-01\ntitle: t\nmodule: core\ndepends_on: []\nacceptance: true\nneeds_human: false\nreview: on-red\nretries: 0\nowner:\nstage: backlog\nstage_since:\n---\n\n## Files touched\n\n## Attempts\n' > tasks/backlog/C1-01.md
  git add -A; git commit -qm base
  export FACTORY_ROOT="$P"
  jq -cn --arg p "auto devam et" --arg cwd "$P" --arg s sess10 --arg tp "$TP" '{prompt:$p,cwd:$cwd,session_id:$s,transcript_path:$tp}' \
    | bash "$H/factory-consent.sh" >/dev/null
  mkq "$now" 20 40
}
nx() { python3 "$H/factory-next.py" "$@" 2>&1; }

echo "=== the gate to go"
newproj go
out="$(nx check)"; rc=$?
check "everything holds: GO with the change" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^NEXT GO C1 (1 task"' "$out"
mkq "$now" 55 40
out="$(nx check)"; rc=$?
check "over the quota line waits" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^NEXT WAIT.*QUOTA OVER"' "$out"
mkq "$((now - 7200))" 20 40
out="$(nx check)"; check "a stale reading waits" 'printf "%s" "$out" | grep -q "^NEXT WAIT.*QUOTA STALE"' "$out"
rm -f "$Q"
out="$(nx check)"; check "no reading waits, it never guesses" 'printf "%s" "$out" | grep -q "^NEXT WAIT.*QUOTA NONE"' "$out"
mkq "$now" 20 40
touch .factory/STOP
out="$(nx check)"; check "STOP waits" 'printf "%s" "$out" | grep -q "^NEXT WAIT STOP"' "$out"
rm -f .factory/STOP
bash "$H/factory-autonomy.sh" off >/dev/null
out="$(nx check)"; check "autonomy off waits" 'printf "%s" "$out" | grep -q "^NEXT WAIT autonomy level is local"' "$out"

echo "=== other reasons to wait"
newproj wait
echo '{"change":"C0","state":"pr_open","held":null}' > .factory/publish/C0.json
out="$(nx check)"; check "a publish in flight waits" 'printf "%s" "$out" | grep -q "^NEXT WAIT publish C0 is pr_open"' "$out"
echo '{"change":"C0","state":"done","held":null}' > .factory/publish/C0.json
out="$(nx check)"; check "a finished publish does not" 'printf "%s" "$out" | grep -q "^NEXT GO"' "$out"
touch .factory/inflight/C1-01
out="$(nx check)"; check "an active run waits" 'printf "%s" "$out" | grep -q "^NEXT WAIT a run is active"' "$out"
rm -f .factory/inflight/C1-01
mv tasks/backlog/C1-01.md "$WORK/s10-held.md"
out="$(nx check)"; check "no approved task waits" 'printf "%s" "$out" | grep -q "^NEXT WAIT no approved task"' "$out"
mv "$WORK/s10-held.md" tasks/backlog/C1-01.md

echo "=== launch"
out="$(nx launch --dry-run)"
check "dry run names the command and runs nothing" 'printf "%s" "$out" | grep -q -- "-p /factory:fast --permission-mode auto --strict-mcp-config" && [ ! -s "$FC_LOG" ] && [ ! -d .factory/worktrees ]' "$out"
check "no --bare" '! printf "%s" "$out" | grep -q -- "--bare"' "$out"
: > "$FC_LOG"
out="$(nx launch)"; rc=$?
check "launch runs claude in a new worktree" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^NEXT RAN" && grep -q "^cwd: .*/.factory/worktrees/C1-" "$FC_LOG"' "$out"
check "the worktree is a real git worktree on its own branch" 'git worktree list | grep -q "factory/next-C1-"'
wt="$(ls -d .factory/worktrees/C1-* | head -1)"
check "it carries the tasks and the consent" '[ -f "$wt/tasks/backlog/C1-01.md" ] && [ -f "$wt/.factory/autonomy.json" ] && [ -f "$wt/.factory/active" ]'
check "the main tree is untouched" '[ "$(git symbolic-ref --short HEAD)" = main ] && [ -z "$(git status --porcelain)" ]'
check "the run knows it is unattended" 'grep -q "^next: 1" "$FC_LOG" && grep -q "^root: .*/.factory/worktrees/" "$FC_LOG"'
mkq "$now" 90 40
: > "$FC_LOG"
out="$(nx launch)"; rc=$?
check "launch over the line starts nothing" '[ $rc -eq 1 ] && [ ! -s "$FC_LOG" ]' "$out"

echo "=== launchd"
out="$(nx launchd --hour 4)"
check "the plist is printed, not installed" 'printf "%s" "$out" | grep -q "<integer>4</integer>" && printf "%s" "$out" | grep -q "launch</string>" && [ ! -e "$HOME/Library/LaunchAgents/com.factory.next.s10-wait.plist" ]' "$out"
check "wrapper dispatches" 'cd "$P" && bash -c "factory-next check" | grep -q "^NEXT"'

echo "=== modifies_tests guard"
newproj mt
mkdir -p tests; printf 'it("a", () => { expect(add(1,1)).toBe(2); });\nit("b", () => { expect(1).toBe(1); });\n' > tests/a.test.ts
git add -A; git commit -qm tests
cat > "$WORK/s10-mt.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fc", os.path.join(sys.argv[1], "factory-check.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(sorted(m.changed_assertions(["tests/a.test.ts", "tests/new.test.ts", "src/a.txt"], {}).items()))
PY
printf 'it("a", () => { expect(add(1,1)).toBe(3); });\nit("b", () => { expect(1).toBe(1); });\n' > tests/a.test.ts
printf 'it("n", () => { expect(2).toBe(2); });\n' > tests/new.test.ts
out="$(python3 "$WORK/s10-mt.py" "$H")"
check "a rewritten assertion in an existing test is seen" 'printf "%s" "$out" | grep -q "a.test.ts.*, 1)]"' "$out"
git checkout -q tests/a.test.ts; printf 'it("a", () => { expect(add(1,1)).toBe(2); });\nit("b", () => { expect(1).toBe(1); });\nit("c", () => { expect(3).toBe(3); });\n' > tests/a.test.ts
out="$(python3 "$WORK/s10-mt.py" "$H")"
check "an added test is not a change" '[ "$out" = "[]" ]' "$out"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
