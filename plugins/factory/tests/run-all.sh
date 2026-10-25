#!/usr/bin/env bash
# The factory's own test suite. Nothing here touches a real project: every
# suite builds its sandboxes under one temporary directory and removes it.
#
#   bash ~/.claude/hooks/tests/run-all.sh          run everything
#   bash ~/.claude/hooks/tests/run-all.sh 3        run one suite
#   FACTORY_KEEP=1 bash .../run-all.sh             keep the sandboxes to look at
#
# What each suite covers:
#   1  ids, change open/sync/close, per-task commit, done-guard
#   2  risk routing, lessons, attempts-safe parsing, retro sections, gate isolation
#   3  event log, sweep and run.lock in the brief, dashboard, question inbox, status line
#   4  task lint, the ready set (factory-plan --ready)
#   5  change-level acceptance, commit bisect, the version/upgrade check
#   6  factory-check, plan, start/land/block, finish
#   7  hard bans, autonomy consent, deny merge, STOP
#   8  delivery: per-change branch, publisher state machine against a fake gh,
#      classes, breakers, quota line
#   9  the retrospective: due marker, validator, ledger, evaluate
#  10  the outer loop: factory-next gates, worktree launch, launchd plist, modifies_tests
#  11  3.1: the unpushed breaker, the upgrade commits its config, unclassified gate results
#  12  shadow mode: the pre-3.3 gate template and the engine, verdict for verdict
#  13  the one loop: the workflow's schedule (loop-cases.mjs), preflight, settle,
#      review-submit, deliver
#  14  the plan and what a run is judged by: factory-lint --plan, built-in review
#      triggers, criteria files, must-haves, the preflight's start check
#  15  unattended permissions and scheduling: factory-allow, factory-next schtasks
#  16  escalation: factory-notify, question deadlines, defaults and expiry
#  17  3.6: security scans (gitleaks, semgrep, full scans) and mutation testing
#  18  3.6: EARS concerns, area leases in the plan, the cheat monitor
#  19  3.6: lessons (category, retire_when, the overlap check, update, check),
#      rules through factory-retro-apply, the retro digest's view of both
#  20  3.6: the spec ledger: delta seed and validate, merge on close (all or nothing), drift
#  21  3.6: untrusted input framed, a checkout per builder and its integration
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
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21; do
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
