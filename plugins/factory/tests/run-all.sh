#!/usr/bin/env bash
# The factory's own test suite. Nothing here touches a real project: every
# suite builds its sandboxes under one temporary directory and removes it.
#
#   bash ~/.claude/hooks/tests/run-all.sh          run everything
#   bash ~/.claude/hooks/tests/run-all.sh 3        run one suite
#   FACTORY_KEEP=1 bash .../run-all.sh             keep the sandboxes to look at
#
# What each suite covers:
#   1  ids, change open/sync/close, per-task commit, claim, done-guard, stop gate
#   2  risk routing, lessons, attempts-safe parsing, retro sections, gate isolation
#   3  event log, dashboard, question inbox, status line, end-of-run message
#   4  duplicate-gate skip, task lint, ready set
#   5  change-level acceptance, commit bisect, the version/upgrade check
#   6  the fast lane: factory-check, plan, start/land/block, /factory:fast scheduling
#   7  hard bans, autonomy consent, deny merge, STOP
#   8  delivery: per-change branch, publisher state machine against a fake gh,
#      classes, breakers, quota line
#   9  the retrospective: due marker, validator, ledger, evaluate
#  10  the outer loop: factory-next gates, worktree launch, launchd plist, modifies_tests
#  11  3.1: the unpushed breaker, the upgrade commits its config, unclassified gate results
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HERE/../bin:$PATH"
export FACTORY_NO_NOTIFY=1
. "$HERE/../hooks/factory-compat.sh"

want="${1:-all}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/factory-selftest.XXXXXX")"
export FACTORY_TEST_DIR="$WORK"
cleanup() { [ "${FACTORY_KEEP:-0}" = "1" ] || rm -rf "$WORK"; }
trap cleanup EXIT

version="$(cat "$HERE/../hooks/factory-version.txt" 2>/dev/null || echo unknown)"
echo "factory ${version}"
echo "sandbox ${WORK}"
echo

total_pass=0; total_fail=0; failed_suites=""
for n in 1 2 3 4 5 6 7 8 9 10 11; do
  case "$want" in all|"$n") ;; *) continue ;; esac
  [ -f "$HERE/suite${n}.sh" ] || continue
  echo "--- suite ${n} ---"
  out="$(bash "$HERE/suite${n}.sh" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | grep -E '^FAIL' 
  line="$(printf '%s\n' "$out" | grep -E '^passed=' | tail -1)"
  p="$(printf '%s' "$line" | sed -n 's/.*passed=\([0-9]*\).*/\1/p')"
  f="$(printf '%s' "$line" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"
  total_pass=$(( total_pass + ${p:-0} ))
  total_fail=$(( total_fail + ${f:-0} ))
  [ "$rc" -eq 0 ] || failed_suites="${failed_suites} ${n}"
  echo "suite ${n}: ${line:-no result}"
  echo
done

echo "TOTAL passed=${total_pass} failed=${total_fail}"
if [ -n "${failed_suites}" ]; then
  echo "suites with failures:${failed_suites}"
  exit 1
fi
exit 0
