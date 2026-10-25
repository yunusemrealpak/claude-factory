#!/usr/bin/env bash
# Sandbox tests: opt-in depth, the check side (3.6) - check.security (gitleaks
# and semgrep on what a task adds, the whole-tree scans of a run) and
# check.mutation (the run's diff, after a green full check), and the mechanism
# counts in metrics.jsonl. The tools are stand-ins on a PATH shim: what is
# tested is how the factory reads them, not the tools. Never touches a real
# project.
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
skip() { echo "SKIP $1"; }

# --- stand-in tools, on a PATH of their own ----------------------------------
SHIM="$WORK/s17-shim"; rm -rf "$SHIM"; mkdir -p "$SHIM"
cat > "$SHIM/gitleaks" <<'SH'
#!/usr/bin/env bash
# a stand-in: "AKIA" anywhere under --source is a leak (exit 1)
src=""
while [ $# -gt 0 ]; do [ "$1" = "--source" ] && src="$2"; shift; done
[ -d "$src" ] || { echo "no source dir: $src"; exit 2; }
if grep -rq "AKIA" "$src"; then echo "Finding: AKIA... (redacted)"; echo "leaks found: 1"; exit 1; fi
echo "no leaks found"; exit 0
SH
cat > "$SHIM/semgrep" <<'SH'
#!/usr/bin/env bash
# a stand-in: eval( in a named file is a finding (exit 1 under --error)
hit=0
for a in "$@"; do [ -f "$a" ] && grep -q "eval(" "$a" && hit=$((hit + 1)); done
[ "$hit" -gt 0 ] && { echo "Ran 1 rule on $# files: $hit blocking findings"; exit 1; }
echo "Ran 1 rule: 0 findings"; exit 0
SH
chmod +x "$SHIM/gitleaks" "$SHIM/semgrep"

newproj() {  # <name> -> P, cd P: a git project whose full check runs core/*.t
  P="$WORK/s17-$1"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
  git init -q -b main; git config user.email t@example.invalid; git config user.name t
  mkdir -p .factory core/tests src tasks/backlog tasks/in-progress tasks/done tasks/blocked
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
  printf 'KEY = "AKIA-already-in-head"\n' > src/old.py
  cat > .factory/config.json <<'JSON'
{ "gate_mode": "full", "min_tests": 1, "retry_limit": 2, "risk_builtin": false,
  "commands": { "build": "true", "test": "bash runner.sh core", "arch": "", "lint": "true" },
  "check": { "test_files": "\\.t$", "untracked_guard": false } }
JSON
  printf '.factory/\n' > .gitignore
  git add -A; git commit -qm base
}
mktask() {  # <column> <id> <files...>
  local col="$1" id="$2"; shift 2
  { echo "---"; echo "id: $id"; echo "title: task $id"; echo "module: core"; echo "depends_on: []"
    echo "acceptance: bash runner.sh core"; echo "needs_human: false"; echo "review: on-red"; echo "retries: 0"
    echo "untested_ok: true"; echo "owner:"; echo "stage: queued"; echo "stage_since:"; echo "---"; echo
    echo "## Goal"; echo "Do the thing."; echo; echo "## Acceptance criteria"; echo "- [ ] it works"; echo
    echo "## Files touched"; for f in "$@"; do echo "- $f"; done; echo; echo "## Attempts"; } > "tasks/$col/$id.md"
}
setsec() {  # <json for check.security, or null>
  jq --argjson s "$1" 'if $s == null then del(.check.security) else .check.security = $s end' .factory/config.json \
    > "$WORK/s17.cfg" && mv "$WORK/s17.cfg" .factory/config.json
}
cx() { out="$(factory-check C1-01)"; rc=$?; }

echo "=== check.security: off unless asked for"
newproj sec
mktask in-progress C1-01 src/app.py
git add -A; git commit -qm "approve C1-01"
printf 'def run():\n    return 1\n' > src/app.py
PATH="$SHIM:$PATH" cx
check "no check.security: no scan stage, even with the tools installed" '[ $rc -eq 0 ] && ! printf "%s" "$out" | grep -qE "^  (secrets|semgrep) "' "$out"

echo "=== a tool that is not installed is a note"
setsec '{}'
if command -v gitleaks >/dev/null 2>&1 || command -v semgrep >/dev/null 2>&1; then
  skip "gitleaks or semgrep is really installed here: the missing-tool case cannot be staged"
else
  cx
  check "gitleaks missing: skipped with a note, still green" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "secrets  skipped (gitleaks is not installed)"' "$out"
  check "semgrep missing: skipped with a note" 'printf "%s" "$out" | grep -q "semgrep  skipped (semgrep is not installed)"' "$out"
fi

echo "=== gitleaks: a secret this task adds is red"
export PATH="$SHIM:$PATH"
cx
check "nothing secret added: green, the scan says so" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "secrets  PASS (gitleaks: nothing in what 1 file(s) add)"' "$out"
check "...and semgrep without rules is a note" 'printf "%s" "$out" | grep -q "semgrep_config does not say which rules"' "$out"
printf 'def run():\n    key = "AKIAABCDEFGHIJKLMNOP"\n    return key\n' > src/app.py
cx
check "a secret in what the task adds is red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "secrets  FAIL (gitleaks found a secret in what this task adds)"' "$out"
check "...and the red says what to do" 'printf "%s" "$out" | grep -q "A secret in a commit is never fine"' "$out"
printf 'def run():\n    return 1\n' > src/app.py
printf 'KEY = "AKIA-already-in-head"\nOTHER = 2\n' > src/old.py
mktask in-progress C1-01 src/app.py src/old.py
git add tasks; git commit -qm "approve C1-01 again"
cx
check "a secret already in HEAD is not this task's: only added lines are scanned" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "secrets  PASS"' "$out"
git checkout -q -- src/old.py
mktask in-progress C1-01 src/app.py
git add tasks; git commit -qm "approve C1-01, one file"
check "each scan is an event" '[ "$(jq -c "select(.kind==\"scan\" and .tool==\"gitleaks\") | .outcome" .factory/events.jsonl | sort | uniq -c | wc -l | tr -d " ")" = 2 ]' "$(cat .factory/events.jsonl 2>/dev/null)"

echo "=== semgrep: a finding is a reviewer's, or red when asked"
setsec '{"semgrep_config": "rules.yml"}'
printf 'def run(x):\n    return eval(x)\n' > src/app.py
cx
check "a finding: green, with a reason for a reviewer" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "semgrep  1 finding(s) for a reviewer"' "$out"
check "...in the marker, where factory-risk reads it" 'grep -q "^review=semgrep: 1 finding(s) in what this task adds" .factory/verified/C1-01'
out="$(factory-risk C1-01)"; rc=$?
check "...and factory-risk sends the task to a reviewer" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "RISK C1-01: semgrep: 1 finding"' "$out"
setsec '{"semgrep_config": "rules.yml", "semgrep_red": true}'
cx
check "semgrep_red: true makes a finding red" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "semgrep  FAIL (1 finding(s) in what this task adds)"' "$out"
printf 'def run(x):\n    return x\n' > src/app.py
cx
check "no finding: green" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "semgrep  PASS (nothing new against HEAD)"' "$out"
setsec '{"semgrep_config": "rules.yml", "gitleaks": false, "semgrep": false}'
cx
check "a tool set to false is not run" '[ $rc -eq 0 ] && ! printf "%s" "$out" | grep -qE "^  (secrets|semgrep) "' "$out"

# --- a landed run, for factory-finish ------------------------------------------
landed() {  # <name>: a project whose run landed C1-01 (src/calc.py) on top of its base
  newproj "$1"
  base="$(git rev-parse HEAD)"
  printf 'def add(a, b):\n    return a + b\n\ndef sub(a, b):\n    return a - b\n' > src/calc.py
  mktask done C1-01 src/calc.py
  git add -A; git commit -qm "C1-01: calc" -m "Factory-Task: C1-01"
  started=$(( $(date +%s) - 60 ))
  printf '{"head": "%s", "started": %s, "tasks": ["C1-01"]}\n' "$base" "$started" > .factory/run-start.json
  cat > mutool.sh <<'SH'
[ -f "$1" ] && echo "diff read: $(grep -c '^+' "$1") added line(s)"
echo "MISSED   src/calc.py:2:5: replace + with - in add"
echo "MISSED   src/other.py:9:1: replace foo with bar"
echo "MISSED   calc.py:5:5: replace sub -> int with 0"
echo "CAUGHT   src/calc.py:5:5: replace - with + in sub"
exit 2
SH
}
setmut() { jq --argjson m "$1" '.check.mutation = $m' .factory/config.json > "$WORK/s17.cfg" && mv "$WORK/s17.cfg" .factory/config.json; }

echo "=== check.mutation: survivors in changed code, after a green full check"
landed mut
setmut '{"command": "bash mutool.sh {diff}"}'
jq -cn --argjson e "$(date +%s)" '{ts:"x", epoch:$e, kind:"budget", level:"warn", task:"C1-01"}' >> .factory/events.jsonl
jq -cn --argjson e 1000 '{ts:"x", epoch:$e, kind:"scan", tool:"gitleaks", outcome:"found"}' >> .factory/events.jsonl
out="$(factory-finish --tasks C1-01 --json)"
check "the full check is green: a survivor does not make it red" '[ "$(printf "%s" "$out" | jq -r .full_check)" = green ] && [ "$(printf "%s" "$out" | jq -r .mutation.status)" = survived ]' "$out"
check "...only survivors in files the run changed count (a sub-project's relative path too)" '[ "$(printf "%s" "$out" | jq .mutation.survived)" = 2 ] && [ "$(printf "%s" "$out" | jq .mutation.killed)" = 1 ]' "$out"
check "...it is something to look at" 'printf "%s" "$out" | jq -e "[.attention[] | select(.id==\"mutation\" and (.concern | test(\"2 mutant\\\\(s\\\\) survived\")))] | length == 1" >/dev/null' "$out"
check "...written where the auditor reads it" 'grep -q "MISSED src/calc.py:2:5" .factory/mutation/last.txt && grep -q "MISSED calc.py:5:5" .factory/mutation/last.txt && grep -q "survived elsewhere: 1" .factory/mutation/last.txt && ! grep -q "^MISSED src/other.py" .factory/mutation/last.txt' "$(cat .factory/mutation/last.txt 2>/dev/null)"
check "...the tool was given the run's diff" 'grep -q "diff read: [1-9]" .factory/mutation/*.log' "$(cat .factory/mutation/*.log 2>/dev/null)"
check "the run's metrics count each mechanism, this run's events only" 'tail -1 .factory/metrics.jsonl | jq -e ".mechanisms.mutation.survived == 1 and .mechanisms.budget.warn == 1 and (.mechanisms.scan == null)" >/dev/null' "$(tail -1 .factory/metrics.jsonl)"
out="$(factory-finish --tasks C1-01)"
check "the one line says it" 'printf "%s" "$out" | grep -q "2 mutant(s) survived"' "$out"

echo "=== check.mutation: never on a red tree, never red itself"
landed mutred
setmut '{"command": "bash mutool.sh {diff}"}'
printf 'exit 1\n' > core/tests/broken.t; git add -A; git commit -qm "broken" -m "Factory-Task: C1-01"
out="$(factory-finish --tasks C1-01 --json)"
check "a red full check: mutation skipped, and says why" '[ "$(printf "%s" "$out" | jq -r .full_check)" = red ] && [ "$(printf "%s" "$out" | jq -r .mutation.status)" = skipped ] && printf "%s" "$out" | jq -r .mutation.why | grep -q "full check is red"' "$out"
landed mutfail
setmut '{"command": "echo boom; exit 3"}'
out="$(factory-finish --tasks C1-01 --json)"
check "a tool that fails and reports nothing: a note, not red, nothing to look at" '[ "$(printf "%s" "$out" | jq -r .full_check)" = green ] && [ "$(printf "%s" "$out" | jq -r .mutation.status)" = failed ] && ! printf "%s" "$out" | jq -e ".attention[] | select(.id==\"mutation\")" >/dev/null' "$out"
printf 'echo started\nsleep 90\necho never\n' > slow.sh
setmut '{"command": "bash slow.sh", "timeout_min": 0.05}'
t0=$(date +%s)
out="$(factory-finish --tasks C1-01 --json)"
t1=$(date +%s)
check "a tool that outlives timeout_min: timeout, not red" '[ "$(printf "%s" "$out" | jq -r .mutation.status)" = timeout ] && [ "$(printf "%s" "$out" | jq -r .full_check)" = green ]' "$out"
check "...and the finish does not wait for it" '[ $((t1 - t0)) -lt 75 ] && grep -q "timed out after" .factory/mutation/last.txt && ! grep -q never .factory/mutation/*.log' "took $((t1 - t0))s"

echo "=== check.security.full: the run's whole-tree scans"
landed scans
printf 'echo "1 high severity vulnerability"; exit 1\n' > audit.sh
setsec '{"gitleaks": false, "semgrep": false, "full": ["bash audit.sh", "echo all clear"]}'
out="$(factory-finish --tasks C1-01 --json)"
check "a scan that exits non-zero is something to look at, not red" '[ "$(printf "%s" "$out" | jq -r .full_check)" = green ] && printf "%s" "$out" | jq -e "[.attention[] | select(.id==\"scan\" and (.concern | test(\"bash audit.sh exited 1\")))] | length == 1" >/dev/null' "$out"
check "...each report kept for the auditor" 'grep -q "1 high severity" .factory/scans/1.txt && grep -q "^exit 0" .factory/scans/2.txt' "$(ls .factory/scans 2>/dev/null)"
check "...and counted" 'tail -1 .factory/metrics.jsonl | jq -e ".mechanisms.scan.found == 1 and .mechanisms.scan.clean == 1" >/dev/null' "$(tail -1 .factory/metrics.jsonl)"
out="$(factory-finish --tasks C1-01 --no-full --json)"
check "no full check, no scans" '[ "$(printf "%s" "$out" | jq ".scans | length")" = 0 ]' "$out"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
