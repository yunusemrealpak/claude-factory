#!/usr/bin/env bash
# Shadow mode: the gate template every project had until 3.3
# (hooks/legacy/verify-3.1.sh) and the engine that replaces it (factory-check,
# what the gates/verify.sh shim runs), on the same fixtures. Each scenario is
# built twice from one template, so neither gate sees what the other wrote, and
# the two verdicts (GREEN or RED) are compared.
#
# A difference is a failure unless EXPLAINED names it and says why the engine
# is right. A name in EXPLAINED whose scenario no longer differs is a failure
# too: the list says what is true now, not what once was.
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

# scenario -> why the engine's verdict differs from the old gate's, and why
# that is the right one.
declare -A EXPLAINED=(
  [full-without-lint]="full mode: a task check requires a test command; a missing build or lint command is red in the full check (factory-check --full), which the fast lane runs last. A project in full mode under the old gate has both, or none of its tasks was ever green"
  [acceptance-red]="the engine runs the task's acceptance command; the old gate left it to the implementer, who could report it green"
  [cheat-exit-zero]="3.3: cheat signatures - a sys.exit(0) in product code is red"
  [undeclared-dependency]="3.2: a dependency manifest the approved task file does not declare is red"
  [test-config]="3.3: a change to how the tests run ([pytest] in tox.ini) is red"
)

S="$WORK/shadow"; rm -rf "$S"; mkdir -p "$S"
T="$S/template"; mkdir -p "$T"; cd "$T" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
mkdir -p .factory gates src tests tasks/in-progress
: > .factory/active
printf '.factory/*\n!.factory/active\n' > .gitignore
cp "$H/legacy/verify-3.1.sh" gates/verify.sh
printf 'ok\n' > src/app.txt; printf 'fine\n' > src/other.txt
printf 'def test_a():\n    assert True\n' > tests/test_app.py
printf '[tox]\nenvlist = py\n\n[pytest]\naddopts = -q\n' > tox.ini
printf '{"name":"s","version":"1.0.0"}\n' > package.json
cat > tasks/in-progress/S-01.md <<'EOF'
---
id: S-01
title: the shadow task
module: core
depends_on: []
acceptance: bash gates/verify.sh S-01
needs_human: false
review: on-red
retries: 0
owner:
stage: queued
stage_since:
---

## Goal
Change the app.

## Files touched
- src/app.txt
- tests/test_app.py
- src/run.py
- package.json
- tox.ini
EOF
config() { jq -n --arg m "${1:-full}" --argjson c "${2:-}" --argjson x "${3:-{\}}" \
  '{gate_mode:$m, min_tests:1, commands:$c} + $x' > .factory/config.json; }
CMDS='{"build":"grep -q ok src/app.txt && ! grep -q broken src/other.txt","test":"echo 3 passed","lint":"true"}'
config full "$CMDS"
git add -A; git commit -qm base
# The old gate's census baseline, as its first green run records it.
bash gates/verify.sh S-01 >/dev/null 2>&1 || { echo "the template does not pass the old gate"; exit 1; }
rm -rf .factory/verified .factory/failures .factory/no-progress .factory/logs

# One scenario: its setup runs in both copies, then each gate once.
verdict() {  # <rc>
  case "$1" in 0) echo GREEN ;; 1) echo RED ;; *) echo "EXIT$1" ;; esac
}
scenario() {  # <name> <setup function>
  local name="$1" setup="$2" old new d
  for side in old new; do
    d="$S/$name.$side"; rm -rf "$d"; cp -a "$T" "$d"
    ( cd "$d" && "$setup" ) >/dev/null 2>&1
    if [ "$side" = old ]; then
      ( cd "$d" && bash gates/verify.sh S-01 ) > "$d.log" 2>&1; old="$(verdict $?)"
    else
      ( cd "$d" && factory-check S-01 ) > "$d.log" 2>&1; new="$(verdict $?)"
    fi
  done
  local why="${EXPLAINED[$name]:-}"
  if [ "$old" = "$new" ] && [ -z "$why" ]; then
    ok "$name: both $old"
  elif [ "$old" = "$new" ]; then
    bad "$name: both $old, but EXPLAINED says they differ - drop it from the list" "$why"
  elif [ -n "$why" ]; then
    ok "$name: old $old, engine $new - explained: $why"
  else
    bad "$name: old $old, engine $new - an unexplained difference" "$(tail -5 "$S/$name.new.log" | tr '\n' ' ')"
  fi
}
commit_task() { git add -A tasks; git commit -qm "approve the task as it is now"; }
fm() { sed -i.bak "s/^needs_human: false/needs_human: false\\
$1: $2/" tasks/in-progress/S-01.md && rm -f tasks/in-progress/S-01.md.bak; }

echo "=== the verdicts that have to agree"
s_green()        { printf 'ok\nmore\n' > src/app.txt; }
s_build_red()    { printf 'gone\n' > src/app.txt; }
s_test_red()     { config full '{"build":"true","test":"echo 1 failed; exit 1","lint":"true"}'; }
s_zero_tests()   { config full '{"build":"true","test":"echo no tests ran","lint":"true"}'; }
s_below_min()    { config full "$CMDS" '{"min_tests":5}'; }
s_lint_red()     { config full '{"build":"true","test":"echo 3 passed","lint":"exit 1"}'; }
s_no_test_cmd()  { config full '{"build":"true","lint":"true"}'; }
s_count_unread() { config full '{"build":"true","test":"echo all good","lint":"true"}'; }
s_self_cert()    { sed -i.bak 's/^acceptance: .*/acceptance: grep -q S-01 decisions.md/' tasks/in-progress/S-01.md; rm -f tasks/in-progress/S-01.md.bak; commit_task; }
s_test_deleted() { rm tests/test_app.py; }
s_removal_ok()   { rm tests/test_app.py; fm allow_test_removal true; commit_task; }
s_skip_added()   { printf '@pytest.mark.skip\ndef test_b():\n    assert False\n' >> tests/test_app.py; }
s_staged_build() { config staged '{"build":"true"}'; }
s_staged_none()  { config staged '{}'; }
s_neighbour()    { config full "$CMDS" '{"gate_isolation":true}'; printf 'broken\n' > src/other.txt; }
s_unlisted_dep() { config full '{"build":"test -f src/new.txt","test":"echo 3 passed","lint":"true"}' '{"gate_isolation":true}'; printf 'x\n' > src/new.txt; }
scenario green s_green
scenario build-red s_build_red
scenario test-red s_test_red
scenario zero-tests s_zero_tests
scenario below-min-tests s_below_min
scenario lint-red s_lint_red
scenario full-without-test s_no_test_cmd
scenario test-count-unrecognised s_count_unread
scenario self-certifying s_self_cert
scenario test-file-deleted s_test_deleted
scenario test-removal-allowed s_removal_ok
scenario skip-added s_skip_added
scenario staged-build-only s_staged_build
scenario staged-nothing s_staged_none
scenario isolated-neighbour-break s_neighbour
scenario isolated-unlisted-file s_unlisted_dep

echo "=== the verdicts that differ, each for a reason"
s_no_lint()      { config full '{"build":"true","test":"echo 3 passed"}'; }
s_accept_red()   { sed -i.bak 's/^acceptance: .*/acceptance: test -f src\/missing.txt/' tasks/in-progress/S-01.md; rm -f tasks/in-progress/S-01.md.bak; commit_task; }
s_cheat()        { printf 'import sys\n\ndef run():\n    sys.exit(0)\n' > src/run.py; }
s_dependency()   { printf '{"name":"s","version":"1.0.0","dependencies":{"left-pad":"1.3.0"}}\n' > package.json; }
s_test_config()  { printf '[tox]\nenvlist = py\n\n[pytest]\naddopts = -q -k "not slow"\n' > tox.ini; }
scenario full-without-lint s_no_lint
scenario acceptance-red s_accept_red
scenario cheat-exit-zero s_cheat
scenario undeclared-dependency s_dependency
scenario test-config s_test_config

echo "=== every explanation is about a scenario that ran"
for name in "${!EXPLAINED[@]}"; do
  if [ -f "$S/$name.new.log" ]; then ok "EXPLAINED $name ran"; else bad "EXPLAINED names $name, which no scenario runs"; fi
done

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
