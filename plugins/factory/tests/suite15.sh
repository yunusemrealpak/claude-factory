#!/usr/bin/env bash
# Sandbox tests: the unattended run. factory-allow writes the permission rules
# a run started with --permission-prompts none needs, as a union that keeps
# the developer's own; factory-next schtasks writes the Windows Task Scheduler
# wrapper and prints the line that registers it, installing nothing. A fake
# `claude` stands in for the CLI, so nothing here starts a real run.
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
. "$H/factory-compat.sh"
PLUGIN="$(cd "$H/.." && pwd)"
WORK="${FACTORY_TEST_DIR:-$(mktemp -d)}"
export PATH="${PLUGIN}/bin:$PATH"
export FACTORY_NO_NOTIFY=1
pass=0; fail=0; skip=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }
skipped() { skip=$((skip+1)); echo "SKIP $1"; }

al() { FACTORY_ROOT="$P" python3 "$H/factory-allow.py" "$@" 2>&1; }
has() { jq -e --arg r "$1" '.permissions.allow | index($r) != null' .claude/settings.json >/dev/null 2>&1; }
proj() { P="$WORK/s15-$1"; rm -rf "$P"; mkdir -p "$P/.factory"; cd "$P" || exit 1; : > .factory/active; }

echo "=== factory-allow: the rules"
proj empty
out="$(al --list)"
check "the loop workflow is allowed" 'printf "%s\n" "$out" | grep -qxF "Workflow(factory:loop)"' "$out"
check "the commands a run calls, bare and with arguments" 'printf "%s\n" "$out" | grep -qxF "Bash(factory-settle)" && printf "%s\n" "$out" | grep -qxF "Bash(factory-settle *)" && printf "%s\n" "$out" | grep -qxF "Bash(factory-retro-apply *)" && printf "%s\n" "$out" | grep -qxF "Bash(factory-review-submit *)"' "$out"
check "read-only git, nothing that writes" 'printf "%s\n" "$out" | grep -qxF "Bash(git diff *)" && printf "%s\n" "$out" | grep -qxF "Bash(git log *)" && ! printf "%s\n" "$out" | grep -qE "^Bash\(git (push|commit|reset|checkout|restore)"' "$out"
check "a subcommand a run calls in one form is allowed only in that form" 'printf "%s\n" "$out" | grep -qxF "Bash(factory-lesson list *)" && ! printf "%s\n" "$out" | grep -qxF "Bash(factory-lesson *)" && ! printf "%s\n" "$out" | grep -qxF "Bash(factory-change *)"' "$out"
check "nothing that changes the permissions themselves" '! printf "%s\n" "$out" | grep -qE "^Bash\(factory-(allow|deny|upgrade|next|autonomy)"' "$out"
check "no rule is listed twice" '[ "$(printf "%s\n" "$out" | sort | uniq -d | wc -l | tr -d " ")" = 0 ]' "$out"

echo "=== factory-allow: report, apply, apply again"
out="$(al)"; rc=$?
check "an empty project lacks them all, and says how to add them" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^ALLOW [0-9][0-9]* rule(s) missing from .claude/settings.json" && printf "%s" "$out" | grep -qF "factory-allow --apply"' "$out"
check "reporting writes nothing" '[ ! -e .claude/settings.json ]'
out="$(al --apply)"; rc=$?
n="$(al --list | wc -l | tr -d ' ')"
check "apply writes every rule" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^ALLOW APPLIED: $n rule(s) added" && [ "$(jq ".permissions.allow | length" .claude/settings.json)" = "$n" ]' "$out"
out="$(al)"; rc=$?
check "then the report is clean" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^ALLOW OK"' "$out"
cp .claude/settings.json "$WORK/s15-before.json"
out="$(al --apply)"; rc=$?
check "a second apply adds nothing and leaves the file as it was" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^ALLOW APPLIED: 0 rule(s)" && cmp -s .claude/settings.json "$WORK/s15-before.json"' "$out"

echo "=== factory-allow: the developer's file stays theirs"
proj kept
mkdir -p .claude
printf '%s\n' '{"model":"opus","permissions":{"allow":["Bash(make *)","Read(src/**)"],"deny":["Bash(rm -rf *)"],"defaultMode":"default"},"env":{"X":"1"}}' > .claude/settings.json
out="$(al --apply)"; rc=$?
check "the developer's allow rules stay first, in their order" '[ $rc -eq 0 ] && [ "$(jq -r ".permissions.allow[0]" .claude/settings.json)" = "Bash(make *)" ] && [ "$(jq -r ".permissions.allow[1]" .claude/settings.json)" = "Read(src/**)" ]' "$out"
check "deny, the other permission keys and the rest of the file are untouched" '[ "$(jq -c ".permissions.deny" .claude/settings.json)" = "[\"Bash(rm -rf *)\"]" ] && [ "$(jq -r ".permissions.defaultMode" .claude/settings.json)" = default ] && [ "$(jq -r ".model" .claude/settings.json)" = opus ] && [ "$(jq -r ".env.X" .claude/settings.json)" = 1 ]' "$(cat .claude/settings.json)"
check "and the rules are added after them" 'has "Workflow(factory:loop)" && has "Bash(factory-finish *)"' "$(cat .claude/settings.json)"
proj partial
mkdir -p .claude
printf '%s\n' '{"permissions":{"allow":["Workflow(factory:loop)","Bash(factory-settle *)"]}}' > .claude/settings.json
out="$(al --apply)"
check "a rule already there is not added again" '[ "$(jq "[.permissions.allow[] | select(. == \"Bash(factory-settle *)\")] | length" .claude/settings.json)" = 1 ] && printf "%s" "$out" | grep -q "^ALLOW APPLIED: $((n - 2)) rule(s)"' "$out"
proj bom
mkdir -p .claude
printf '\357\273\277{"permissions":{"allow":["Bash(make)"]}}\n' > .claude/settings.json
out="$(al --apply)"; rc=$?
check "a file saved with a BOM is read, not refused" '[ $rc -eq 0 ] && has "Bash(make)" && has "Workflow(factory:loop)"' "$out"

echo "=== factory-allow: the project's own commands"
proj cmds
cat > .factory/config.json <<'JSON'
{"commands":{"build":"cd app && npm run build","test":"pytest {path} -q","arch":"","lint":"bash -c 'ruff {files}'"},
 "check":{"format":"ruff format --check","unit_test":"","units":[{"name":"api","test":"bash scripts/test-api.sh"},{"name":"web","test":"npm --prefix web test"}]}}
JSON
out="$(al --list)"
check "a command is allowed bare and with arguments" 'printf "%s\n" "$out" | grep -qxF "Bash(ruff format --check)" && printf "%s\n" "$out" | grep -qxF "Bash(ruff format --check *)" && printf "%s\n" "$out" | grep -qxF "Bash(npm --prefix web test *)"' "$out"
check "a placeholder, and whatever follows it, is a wildcard" 'printf "%s\n" "$out" | grep -qxF "Bash(pytest *)" && ! printf "%s\n" "$out" | grep -qF "{path}"' "$out"
check "a compound command is one rule per part" 'printf "%s\n" "$out" | grep -qxF "Bash(cd app)" && printf "%s\n" "$out" | grep -qxF "Bash(npm run build)" && ! printf "%s\n" "$out" | grep -qF "&&"' "$out"
check "a command run through a shell gets no wildcard" 'printf "%s\n" "$out" | grep -qxF "Bash(bash scripts/test-api.sh)" && ! printf "%s\n" "$out" | grep -qxF "Bash(bash scripts/test-api.sh *)" && ! printf "%s\n" "$out" | grep -q "^Bash(bash -c"' "$out"
out="$(al)"
check "...and the report names the one it left to the developer" 'printf "%s" "$out" | grep -q "^ALLOW NOTE: .*bash -c .ruff {files}."' "$out"

echo "=== factory-allow: a file it cannot read"
proj broken
mkdir -p .claude
printf '{"permissions": {"allow": [}\n' > .claude/settings.json
cp .claude/settings.json "$WORK/s15-broken.json"
out="$(al --apply)"; rc=$?
check "invalid JSON is refused and left as it is" '[ $rc -eq 2 ] && printf "%s" "$out" | grep -q "^ALLOW ERROR: .claude/settings.json cannot be read" && cmp -s .claude/settings.json "$WORK/s15-broken.json"' "$out"
printf '{"permissions":{"allow":"Bash(make)"}}\n' > .claude/settings.json
out="$(al --apply)"; rc=$?
check "so is an allow that is not a list" '[ $rc -eq 2 ] && [ "$(jq -r ".permissions.allow" .claude/settings.json)" = "Bash(make)" ]' "$out"
out="$(cd "$WORK" && python3 - "$H/factory-allow.py" "$P" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("factory_allow", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
gap = m.missing(root=sys.argv[2])
print(type(gap).__name__, len(gap) == len(m.wanted(root=sys.argv[2])))
PY
)"
check "missing() never raises: an unreadable file lacks every rule (what preflight imports)" '[ "$out" = "list True" ]' "$out"

echo "=== factory-next schtasks"
FC="$WORK/s15-fakeclaude"; rm -rf "$FC"; mkdir -p "$FC"
printf '#!/usr/bin/env bash\necho "args: $*" >> "%s/log"\n' "$FC" > "$FC/claude"; chmod +x "$FC/claude"
proj "night run"
out="$(FACTORY_ROOT="$P" FACTORY_CLAUDE="$FC/claude" python3 "$H/factory-next.py" schtasks --hour 5 --timeout-min 45 2>&1)"; rc=$?
W=.factory/schedule/next.ps1
check "the wrapper is written under .factory/schedule/" '[ $rc -eq 0 ] && [ -f "$W" ] && printf "%s" "$out" | grep -q "^SCHTASKS WROTE .factory/schedule/next.ps1"' "$out"
check "every placeholder is filled" '! grep -q "__[A-Z]*__" "$W"' "$(grep -n "__" "$W")"
check "with this machine's paths and the timeout asked for" 'grep -q "^\$TimeoutMin = 45" "$W" && grep -q "^\$Claude = .*s15-fakeclaude.claude.\$" "$W" && grep -q "^\$Script = .*factory-next\.py.\$" "$W" && grep -q "^\$Root = .*s15-night run.\$" "$W"' "$(grep -n "^\\$" "$W")"
check "the register line is printed, at the hour asked for" 'printf "%s" "$out" | grep -qF "schtasks /Create /TN \"Factory\\next-s15-night-run\" /SC DAILY /ST 05:00 /TR \"powershell.exe -NoProfile -ExecutionPolicy Bypass -File" && printf "%s" "$out" | grep -qF "next.ps1\\\"\" /F"' "$out"
check "and the line that removes it" 'printf "%s" "$out" | grep -qF "schtasks /Delete /TN \"Factory\\next-s15-night-run\" /F"' "$out"
check "the wrapper honours STOP, takes a lock and kills the tree on timeout" 'grep -qF ".factory\\STOP" "$W" && grep -qF "next-schtasks.lock" "$W" && grep -qF "taskkill.exe /T /F" "$W"' ""
out="$(FACTORY_ROOT="$P" FACTORY_CLAUDE="$FC/claude" python3 "$H/factory-next.py" schtasks 2>&1)"
check "by default: 03:00 and a four-hour timeout" 'printf "%s" "$out" | grep -qF "/ST 03:00" && grep -q "^\$TimeoutMin = 240" "$W"' "$out"
proj noclaude
out="$(FACTORY_ROOT="$P" FACTORY_CLAUDE="$WORK/no-such-dir/claude" python3 "$H/factory-next.py" schtasks 2>&1)"; rc=$?
check "no claude to point at: refused, nothing written" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^SCHTASKS REFUSED: no claude executable" && [ ! -e .factory/schedule ]' "$out"
out="$(FACTORY_ROOT="$P" FACTORY_CLAUDE="s15-no-such-claude" python3 "$H/factory-next.py" schtasks 2>&1)"; rc=$?
check "...also when the name is not on PATH" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^SCHTASKS REFUSED"' "$out"

echo "=== the wrapper under PowerShell (Windows only)"
PS="$(command -v powershell.exe 2>/dev/null || true)"
if [ -n "$PS" ] && command -v cygpath >/dev/null 2>&1; then
  proj "o'brien"
  FACTORY_ROOT="$P" FACTORY_CLAUDE="$FC/claude" python3 "$H/factory-next.py" schtasks --timeout-min 30 >/dev/null 2>&1
  WW="$(cygpath -w "$P/.factory/schedule/next.ps1")"
  out="$("$PS" -NoProfile -Command "\$e=\$null; [System.Management.Automation.Language.Parser]::ParseFile('$(printf "%s" "$WW" | sed "s/'/''/g")',[ref]\$null,[ref]\$e) | Out-Null; \$e.Count" 2>&1 | tr -d '\r')"
  check "it parses, with an apostrophe in the project's path" '[ "$out" = 0 ]' "$out"
  : > .factory/STOP
  "$PS" -NoProfile -ExecutionPolicy Bypass -File "$WW" >/dev/null 2>&1; rc=$?
  check "STOP set: it exits 0 and starts nothing" '[ $rc -eq 0 ] && grep -q "STOP is set: nothing started" .factory/logs/next-schtasks-*.log && [ ! -e "$FC/log" ]' "$(cat .factory/logs/* 2>/dev/null)"
  rm -f .factory/STOP .factory/logs/*
  mkdir -p .factory/locks; echo 1 > .factory/locks/next-schtasks.lock
  "$PS" -NoProfile -ExecutionPolicy Bypass -File "$WW" >/dev/null 2>&1; rc=$?
  check "a fresh lock: this start is skipped, the lock is not taken" '[ $rc -eq 0 ] && grep -q "still holds the lock: skipped" .factory/logs/next-schtasks-*.log && [ "$(cat .factory/locks/next-schtasks.lock | tr -d "\r ")" = 1 ]' "$(cat .factory/logs/* 2>/dev/null)"
  rm -f .factory/locks/next-schtasks.lock .factory/logs/*
  "$PS" -NoProfile -ExecutionPolicy Bypass -File "$WW" >/dev/null 2>&1; rc=$?
  check "nothing to do: launch's answer and its exit code are logged, the lock is gone" '[ $rc -eq 1 ] && grep -q "NEXT WAIT" .factory/logs/next-schtasks-*.log && grep -q "exit 1$" .factory/logs/next-schtasks-*.log && [ ! -e .factory/locks/next-schtasks.lock ] && [ ! -e "$FC/log" ]' "$(cat .factory/logs/*.log 2>/dev/null)"
else
  skipped "the PowerShell checks (no powershell.exe here)"
fi

echo "=== factory-next launch: unattended means no prompts"
newproj() {
  P="$WORK/s15-$1"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
  git init -q -b main .; git config user.email dev@example.com; git config user.name dev
  mkdir -p src tasks/backlog .factory/publish
  echo base > src/a.txt; : > .factory/active; printf '.factory/\n' > .gitignore
  echo '{"verify":"gates/verify.sh","autonomy_default":"merge","delivery":{"base":"main","quota_margin":10}}' > .factory/config.json
  printf -- '---\nid: C1-01\ntitle: t\nmodule: core\ndepends_on: []\nacceptance: true\nneeds_human: false\nreview: on-red\nretries: 0\nowner:\nstage: backlog\nstage_since:\n---\n\n## Files touched\n\n## Attempts\n' > tasks/backlog/C1-01.md
  git add -A; git commit -qm base
  TP="$WORK/s15-transcript.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"auto devam et"}}' > "$TP"
  jq -cn --arg p "auto devam et" --arg cwd "$P" --arg s sess15 --arg tp "$TP" '{prompt:$p,cwd:$cwd,session_id:$s,transcript_path:$tp}' \
    | FACTORY_ROOT="$P" bash "$H/factory-consent.sh" >/dev/null
  jq -cn --argjson ts "$(date +%s)" '{ts:$ts, seven_day:{used_percentage:20, even_line:40, resets_at:null}}' > "$WORK/s15-quota.json"
}
newproj launch
out="$(FACTORY_ROOT="$P" FACTORY_QUOTA_FILE="$WORK/s15-quota.json" FACTORY_CLAUDE="$FC/claude" python3 "$H/factory-next.py" launch --dry-run 2>&1)"
check "the run is started with --permission-prompts none" 'printf "%s" "$out" | grep -q "^NEXT GO C1" && printf "%s" "$out" | grep -qF -- "--permission-mode auto --permission-prompts none"' "$out"

echo; echo "passed=$pass failed=$fail skipped=$skip"; [ "$fail" -eq 0 ]
