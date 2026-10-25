#!/usr/bin/env bash
# Factory quality gate. Usage: bash gates/verify.sh <task-id>
# Runs build, tests, architecture tests and lint. On full success it writes
# .factory/verified/<task-id>, which is the only thing that lets a task enter
# the done column (enforced by the factory-done-guard PreToolUse hook).
#
# Beyond running the stages, the gate defends against the three ways a run can
# look green without being green:
#   - a suite that executed zero tests            -> count_tests
#   - a suite that got greener by losing tests    -> guard_test_census
#   - an acceptance criterion the agent can write -> guard_acceptance
# and against the way a red run burns budget without moving:
#   - the identical failure, twice                -> failure signature history
# Optionally ("gate_isolation": true) it checks the task in a clean worktree
# holding HEAD plus the task's own files, instead of the shared tree -> isolate
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: bash gates/verify.sh <task-id>" >&2
  exit 2
fi
TASK_ID="$1"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# A marker describes the last green run of this task. The moment a new run
# starts it describes nothing: if this run goes red, a marker left over from an
# earlier green one would still let the task into done. It is written again at
# the end, and only on green.
rm -f "${ROOT}/.factory/verified/${TASK_ID}"

# Everything the stages and the guards print accumulates here. On a red run it
# becomes the failure signature; nothing else reads it.
RUN_LOG="$(mktemp "${TMPDIR:-/tmp}/factory-gate-run-XXXXXX")"
# Set only when the gate runs isolated (see isolate below). Whatever happens,
# the throwaway worktree goes when the gate exits.
WT_PARENT=""
cleanup() {
  rm -f "${RUN_LOG}"
  if [ -n "${WT_PARENT}" ]; then
    git -C "${ROOT}" worktree remove --force "${WT_PARENT}/tree" >/dev/null 2>&1
    rm -rf "${WT_PARENT}"
    git -C "${ROOT}" worktree prune >/dev/null 2>&1
  fi
}
trap cleanup EXIT

CONFIG="${ROOT}/.factory/config.json"
GATE_MODE="$(jq -r '.gate_mode // "full"' "${CONFIG}" 2>/dev/null || echo full)"
ISOLATE="$(jq -r '.gate_isolation // false' "${CONFIG}" 2>/dev/null || echo false)"

# The tree the stages and the census look at: the working tree itself, or the
# isolated worktree when gate_isolation is on.
WORK="${ROOT}"

read_cmd() { jq -r --arg k "$1" '.commands[$k] // ""' "${CONFIG}" 2>/dev/null; }

BUILD_CMD="$(read_cmd build)"
TEST_CMD="$(read_cmd test)"
ARCH_CMD="$(read_cmd arch)"
LINT_CMD="$(read_cmd lint)"

FAILED=0
RAN=0

MIN_TESTS="$(jq -r '.min_tests // 1' "${CONFIG}" 2>/dev/null)"
case "${MIN_TESTS}" in ''|*[!0-9]*) MIN_TESTS=1 ;; esac
TEST_COUNT=""
CENSUS_FILES=0
CENSUS_SKIPS=0

# The task file. The guards read declared exemptions from its frontmatter.
TASK_FILE="$(ls "${ROOT}"/tasks/*/"${TASK_ID}".md 2>/dev/null | head -1)"

task_field() {
  [ -n "${TASK_FILE}" ] && [ -f "${TASK_FILE}" ] || return 0
  awk 'NR==1 && /^---[[:space:]]*$/ {inside=1; next}
       inside && /^---[[:space:]]*$/ {exit}
       inside {print}' "${TASK_FILE}" \
    | sed -n "s/^$1:[[:space:]]*//p" | head -1
}

say_fail() {  # print, and keep it in the run log so it reaches the signature
  echo "$*" >&2
  echo "$*" >> "${RUN_LOG}"
}

# ---------------------------------------------------------------------------
# Failure signature and no-progress detection.
#
# retry_limit counts attempts, and attempts are the wrong thing to count: two
# runs that fail on the identical error are not two attempts at a problem, they
# are the same attempt made twice, and the budget spent on the second bought
# nothing. So the gate fingerprints each red run by its normalised error lines
# and remembers the fingerprints per task. A fingerprint seen before on this
# task - the run before it, or any run before that, which is how an A-B-A-B
# oscillation gets caught too - means the loop is not converging: the task needs
# a human or a different approach, not another identical retry.
#
# Normalisation strips what legitimately varies between two runs of the same
# failure: absolute paths, hashes, timestamps and all bare numbers. Losing line
# numbers is deliberate - the same error moved down three lines is the same
# error.
# ---------------------------------------------------------------------------
FAIL_DIR="${ROOT}/.factory/failures"

sha_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print substr($1,1,12)}'
  else
    sha256sum | awk '{print substr($1,1,12)}'
  fi
}

failure_signature() {
  local sig work_real root_real
  # Tools print either the path as given or its physical form (/private/var/...
  # on macOS); both have to collapse to the same <root>.
  work_real="$(cd "${WORK}" 2>/dev/null && pwd -P)"
  root_real="$(cd "${ROOT}" 2>/dev/null && pwd -P)"
  sig="$(grep -aiE '(^|[^a-z])(error|fail(ed|ure|s)?|exception|panic|assert|violation|missing)([^a-z]|$)' "${RUN_LOG}" 2>/dev/null \
    | sed -E \
        -e "s#${work_real:-${WORK}}#<root>#g" \
        -e "s#${WORK}#<root>#g" \
        -e "s#${root_real:-${ROOT}}#<root>#g" \
        -e "s#${ROOT}#<root>#g" \
        -e 's#/(private/)?(tmp|var/folders)/[^ :"]*#<tmp>#g' \
        -e 's/[0-9a-f]{7,40}/<sha>/g' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.]+Z?/<ts>/g' \
        -e 's/[0-9]+/<n>/g' \
        -e 's/[[:space:]]+/ /g' \
        -e 's/^ //; s/ $//' \
    | sort -u)"
  # Some runners fail without printing any word we recognise as an error.
  # Falling back to the tail of the log keeps those fingerprintable instead of
  # collapsing every one of them onto the same empty signature.
  if [ -z "${sig}" ]; then
    sig="$(tail -40 "${RUN_LOG}" | sed -E 's/[0-9]+/<n>/g; s/[[:space:]]+/ /g' | sort -u)"
  fi
  printf '%s\n' "${sig}"
}

record_failure() {
  local sig sha hist attempt repeat=0
  mkdir -p "${FAIL_DIR}"
  sig="$(failure_signature)"
  sha="$(printf '%s' "${sig}" | sha_of)"
  hist="${FAIL_DIR}/${TASK_ID}.log"

  # One file per distinct signature, shared across tasks on purpose: when the
  # same signature turns up under several task ids it is the harness that is
  # broken, not the task. /factory:retro clusters on exactly that.
  [ -s "${FAIL_DIR}/sig-${sha}.txt" ] || printf '%s\n' "${sig}" > "${FAIL_DIR}/sig-${sha}.txt"

  if [ -f "${hist}" ] && grep -q " ${sha} " "${hist}"; then
    repeat=1
  fi
  # Redirecting from a missing file fails in the shell before wc ever runs, so
  # a 2>/dev/null on wc would not have caught it.
  if [ -f "${hist}" ]; then
    attempt=$(( $(wc -l < "${hist}") + 1 ))
  else
    attempt=1
  fi
  printf '%s %s attempt=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${sha}" "${attempt}" >> "${hist}"

  if [ "${repeat}" -eq 1 ]; then
    mkdir -p "${ROOT}/.factory/no-progress"
    {
      echo "signature=${sha}"
      echo "attempt=${attempt}"
      echo "detail=.factory/failures/sig-${sha}.txt"
    } > "${ROOT}/.factory/no-progress/${TASK_ID}"
    echo "GATE RESULT: RED for ${TASK_ID} - NO PROGRESS" >&2
    echo "GATE: this exact failure (${sha}) already happened on this task; attempt ${attempt} changed nothing." >&2
    echo "GATE: retrying an identical failure buys nothing. Block the task and change the approach, or" >&2
    echo "GATE: escalate it. Signature: .factory/failures/sig-${sha}.txt" >&2
  else
    echo "GATE RESULT: RED for ${TASK_ID} (signature ${sha}, attempt ${attempt})" >&2
  fi
}

fail_red() {
  record_failure
  exit 1
}

# ---------------------------------------------------------------------------
# Guard 1: an acceptance criterion the agent can satisfy by writing prose.
#
# The agent appends to decisions.md and edits its own task file as part of the
# protocol. An acceptance command whose only evidence is one of those files is
# not a criterion, it is a formality the agent grants itself. Real evidence
# means a build, a test runner, a query - something the agent cannot assert.
# ---------------------------------------------------------------------------
guard_acceptance() {
  local acc
  # A needs_human task is outside the automated loop: no agent is ever
  # dispatched to satisfy it, so there is nobody here to grant themselves a pass.
  [ "$(task_field needs_human)" = "true" ] && return 0
  acc="$(task_field acceptance)"
  [ -n "${acc}" ] || return 0

  echo "${acc}" | grep -qE 'decisions\.md|tasks/[^ ]*\.md' || return 0
  echo "${acc}" | grep -qE '(dotnet|npm|pnpm|yarn|npx|node|flutter|melos|dart|pytest|python3?|go test|cargo|mvn|gradle|gradlew|make|bash gates/|jest|vitest|rspec|phpunit|curl|psql|docker)' && return 0

  say_fail "GATE acceptance: FAIL - self-certifying acceptance criterion."
  say_fail "GATE acceptance: ${acc}"
  say_fail "GATE acceptance: its only evidence is a file the agent writes itself, so it proves nothing."
  say_fail "GATE acceptance: replace it with a command that runs the code, or mark the task needs_human: true."
  FAILED=1
}

# ---------------------------------------------------------------------------
# Guard 2: a suite that got greener by losing tests.
#
# Deleting the failing test and skipping the failing test both turn a red run
# green, and both are documented behaviours of coding agents under a pass/fail
# reward, not hypotheticals. Neither is visible to the stages: after the edit
# the suite really does pass. So the gate keeps a census - how many test files
# exist, how many suppression markers they carry - refreshes it on every green
# run, and refuses a run that lost test files or gained suppressions.
#
# A task that legitimately removes tests declares allow_test_removal: true in
# its own frontmatter. That is the point - not to forbid it, but to make it a
# decision somebody wrote down.
# ---------------------------------------------------------------------------
BASELINE="${ROOT}/.factory/baseline.json"

SKIP_RE='\[Ignore\(|\(Skip[[:space:]]*=|\.skip\(|(^|[^a-zA-Z])xit\(|(^|[^a-zA-Z])xdescribe\(|@Ignore([^a-zA-Z]|$)|@pytest\.mark\.skip|@unittest\.skip|(^|[^a-zA-Z])t\.Skip\(|#\[ignore\]|skip:[[:space:]]*true|Assert\.Inconclusive'

census_test_files() {
  find "${WORK}" \
    \( -name node_modules -o -name bin -o -name obj -o -name .git -o -name build \
       -o -name .dart_tool -o -name Pods -o -name vendor -o -name target \
       -o -name dist -o -name .next -o -name .factory \) -prune -o \
    -type f \( -name '*Tests.cs' -o -name '*Test.cs' -o -name '*_test.go' \
       -o -name 'test_*.py' -o -name '*_test.py' -o -name '*_test.dart' \
       -o -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.test.js' -o -name '*.test.jsx' \
       -o -name '*.spec.ts' -o -name '*.spec.tsx' -o -name '*.spec.js' -o -name '*_spec.rb' \
       -o -name '*Test.java' -o -name '*Tests.java' -o -name '*_test.rs' \) -print 2>/dev/null
}

guard_test_census() {
  local files n_files n_skips prev_files prev_skips allow bad=0
  files="$(census_test_files)"
  n_files="$(printf '%s\n' "${files}" | grep -c .)"
  n_skips=0
  if [ "${n_files}" -gt 0 ]; then
    n_skips="$(printf '%s\n' "${files}" | tr '\n' '\0' \
      | xargs -0 grep -ohE "${SKIP_RE}" 2>/dev/null | grep -c .)"
  fi
  CENSUS_FILES="${n_files}"
  CENSUS_SKIPS="${n_skips}"

  if [ ! -f "${BASELINE}" ]; then
    echo "GATE census: ${n_files} test file(s), ${n_skips} suppression(s) - first run, recording baseline"
    return 0
  fi

  prev_files="$(jq -r '.test_files // 0' "${BASELINE}" 2>/dev/null)"
  prev_skips="$(jq -r '.skipped // 0' "${BASELINE}" 2>/dev/null)"
  case "${prev_files}" in ''|*[!0-9]*) prev_files=0 ;; esac
  case "${prev_skips}" in ''|*[!0-9]*) prev_skips=0 ;; esac

  allow="$(task_field allow_test_removal)"
  if [ "${allow}" = "true" ]; then
    echo "GATE census: ${n_files} file(s) / ${n_skips} suppression(s) vs baseline ${prev_files}/${prev_skips} - waived by allow_test_removal"
    return 0
  fi

  if [ "${n_files}" -lt "${prev_files}" ]; then
    say_fail "GATE census: FAIL - test files went from ${prev_files} to ${n_files}."
    say_fail "GATE census: a suite does not get greener by losing tests. Restore them; if removing them"
    say_fail "GATE census: is this task's job, put allow_test_removal: true in its frontmatter."
    FAILED=1; bad=1
  fi
  if [ "${n_skips}" -gt "${prev_skips}" ]; then
    say_fail "GATE census: FAIL - test suppressions went from ${prev_skips} to ${n_skips}."
    say_fail "GATE census: skipping the failing test is not fixing it. Remove the skip and make it pass;"
    say_fail "GATE census: if the skip is this task's job, put allow_test_removal: true in its frontmatter."
    FAILED=1; bad=1
  fi
  [ "${bad}" -eq 0 ] && echo "GATE census: PASS (${n_files} test file(s), ${n_skips} suppression(s); baseline ${prev_files}/${prev_skips})"
  return 0
}

# A suite that runs zero tests exits 0 and looks exactly like a suite that
# passed. That is the one failure the stages cannot see and the reason a task
# can come back green with nothing actually verified. Read the runner's own
# summary and treat "nothing ran" as red.
count_tests() {
  local out="$1" n
  # A runner whose summary none of the patterns below know is described in the
  # config ("check.count", a regex) and counted by the factory's own tool.
  if [ -n "$(jq -r '.check.count // ""' "${CONFIG}" 2>/dev/null)" ] && command -v factory-check >/dev/null 2>&1; then
    n="$(factory-check count "${out}" 2>/dev/null)"
    case "${n}" in ''|*[!0-9]*) ;; *) TEST_COUNT="${n}"; return 0 ;; esac
  fi
  # Explicit zero-test signatures. Unambiguous across runners.
  if grep -qiE 'no test files|no tests ran|no tests found|no tests were found|found 0 tests|ran 0 tests|Tests:[[:space:]]+0 total|Total tests:[[:space:]]*0' "${out}"; then
    TEST_COUNT=0
    return 0
  fi
  # Positive counts, most specific runner format first. The first pattern that
  # matches wins; summing ACROSS patterns would double-count a line like
  # "Tests: 12 passed, 12 total". Summing WITHIN one pattern is correct, because
  # a monorepo prints one summary per package. Extended regex (-E) throughout:
  # BSD sed on macOS has no \b, and basic regex has no alternation.
  local pats='s/.*Tests:[[:space:]]*([0-9]+)[[:space:]]*passed.*/\1/p
s/.*[Pp]assed:[[:space:]]*([0-9]+).*/\1/p
s/.*Total tests:[[:space:]]*([0-9]+).*/\1/p
s/^\+([0-9]+):.*/\1/p
s/^([0-9]+)[[:space:]]+passed.*/\1/p
s/.*[^0-9]([0-9]+)[[:space:]]+passed.*/\1/p'
  while IFS= read -r pat; do
    [ -z "${pat}" ] && continue
    n="$(sed -E -n "${pat}" "${out}" | awk '{s+=$1} END {print s+0}')"
    if [ -n "${n}" ] && [ "${n}" -gt 0 ] 2>/dev/null; then
      TEST_COUNT="${n}"
      return 0
    fi
  done <<< "${pats}"
  TEST_COUNT=""   # unrecognised runner output: say so rather than guess
}

run_stage() {
  local name="$1" cmd="$2"
  if [ -z "${cmd}" ]; then
    if [ "${GATE_MODE}" = "full" ] && [ "${name}" != "arch" ]; then
      say_fail "GATE ${name}: MISSING (gate_mode=full requires it)"
      FAILED=1
    else
      echo "GATE ${name}: skipped (not configured yet, gate_mode=${GATE_MODE})"
    fi
    return
  fi
  echo "GATE ${name}: ${cmd}"

  # Every stage is teed: the run stays visible while its output is kept for the
  # failure signature, and for the test stage also for the zero-test check.
  local out_file ok=0
  out_file="$(mktemp "${TMPDIR:-/tmp}/factory-stage-XXXXXX")"
  if bash -c "${cmd}" 2>&1 | tee "${out_file}"; then ok=1; fi
  { echo "### stage ${name}"; cat "${out_file}"; } >> "${RUN_LOG}"

  if [ "${ok}" -ne 1 ]; then
    say_fail "GATE ${name}: FAIL"
    FAILED=1
    rm -f "${out_file}"
    return
  fi

  if [ "${name}" != "test" ]; then
    echo "GATE ${name}: PASS"
    RAN=$((RAN + 1))
    rm -f "${out_file}"
    return
  fi

  count_tests "${out_file}"
  rm -f "${out_file}"

  if [ -z "${TEST_COUNT}" ]; then
    echo "GATE ${name}: PASS (test count not recognised in this runner's output; zero-test check skipped)"
    RAN=$((RAN + 1))
  elif [ "${TEST_COUNT}" -lt "${MIN_TESTS}" ]; then
    say_fail "GATE ${name}: FAIL - the suite reported ${TEST_COUNT} test(s), minimum is ${MIN_TESTS}."
    say_fail "GATE ${name}: a suite that runs nothing exits 0 and proves nothing. Add real tests, or fix the filter/scope that excluded them."
    FAILED=1
  else
    echo "GATE ${name}: PASS (${TEST_COUNT} test(s) ran)"
    RAN=$((RAN + 1))
  fi
}

# ---------------------------------------------------------------------------
# Isolation - "gate_isolation": true in .factory/config.json. Off by default.
#
# The factory runs several tasks in one working tree. Checked there, a task is
# judged together with whatever the others have half-written at that moment: it
# can go red on a neighbour's unfinished file, and it can go green by leaning on
# a neighbour's code that its own commit will not contain. Isolated, the gate
# checks HEAD out into a throwaway worktree, copies in only the files the task
# lists under "## Files touched", and runs everything there - exactly what the
# task's commit will hold. A file missing from the list becomes a red build
# here instead of a commit that does not compile.
#
# The price is a cold tree: no build cache, no installed dependencies, none of
# the untracked files the build may expect. "isolation_links" names files or
# directories to symlink in from the main tree instead, e.g. ["node_modules"].
# Link only what the build reads, never what it writes (bin/, obj/, build/):
# two trees writing one output directory corrupt each other.
# ---------------------------------------------------------------------------
task_files_touched() {
  [ -n "${TASK_FILE}" ] && [ -f "${TASK_FILE}" ] || return 0
  sed -n '/^##[[:space:]]*Files touched[[:space:]]*$/,/^#/p' "${TASK_FILE}" \
    | sed -n 's/^[[:space:]]*[-*][[:space:]][[:space:]]*//p' \
    | tr -d '`' | sed 's/[[:space:]].*//; s#^\./##' | grep -v '^$' | sort -u
}

isolate() {
  local listed prefix p link
  if ! git -C "${ROOT}" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    echo "GATE isolation: skipped - there is no commit to build a clean tree from yet"
    return 0
  fi
  listed="$(task_files_touched)"
  if [ -z "${listed}" ]; then
    say_fail "GATE isolation: FAIL - the task lists no files under \"## Files touched\"."
    say_fail "GATE isolation: an isolated gate checks HEAD plus exactly those files; with none it checks HEAD alone and proves nothing."
    FAILED=1
    return 0
  fi
  WT_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/factory-wt-XXXXXX")"
  # Hooks off: a post-checkout hook has no business running for a throwaway tree.
  if ! git -C "${ROOT}" -c core.hooksPath=/dev/null worktree add --detach --quiet "${WT_PARENT}/tree" HEAD >/dev/null 2>&1; then
    say_fail "GATE isolation: FAIL - could not check HEAD out into a worktree."
    FAILED=1
    return 0
  fi
  # The factory may live in a subdirectory of the repository. The path is
  # canonicalised because tools print it that way - macOS hands out a TMPDIR
  # ending in "/", which would otherwise leave a "//" in it.
  prefix="$(git -C "${ROOT}" rev-parse --show-prefix 2>/dev/null)"
  WORK="$(cd "${WT_PARENT}/tree/${prefix%/}" && pwd)"
  while IFS= read -r p; do
    case "${p}" in /*|..|../*|*/../*|.factory/*|.git/*) continue ;; esac
    if [ -d "${ROOT}/${p}" ]; then
      mkdir -p "${WORK}/${p}" && cp -Rp "${ROOT}/${p}/." "${WORK}/${p}/"
    elif [ -e "${ROOT}/${p}" ]; then
      mkdir -p "$(dirname "${WORK}/${p}")" && cp -p "${ROOT}/${p}" "${WORK}/${p}"
    else
      rm -rf "${WORK:?}/${p}"   # listed but gone: the task deleted it
    fi
  done <<< "${listed}"
  while IFS= read -r link; do
    [ -n "${link}" ] || continue
    if [ -e "${ROOT}/${link}" ] && [ ! -e "${WORK}/${link}" ]; then
      mkdir -p "$(dirname "${WORK}/${link}")" && ln -s "${ROOT}/${link}" "${WORK}/${link}"
    fi
  done <<< "$(jq -r '.isolation_links // [] | .[]' "${CONFIG}" 2>/dev/null)"
  echo "GATE isolation: HEAD + $(printf '%s\n' "${listed}" | grep -c .) listed file(s), in a clean worktree"
}

# Guards first. They are static checks that cost nothing, and there is no point
# spending a full build and test run on a task whose acceptance cannot prove
# anything, or whose tree already lost the evidence. Isolation comes before the
# census, so the census counts the tree that is actually being checked.
guard_acceptance
if [ "${ISOLATE}" = "true" ]; then
  isolate
fi
guard_test_census
if [ "${FAILED}" -ne 0 ]; then
  fail_red
fi

cd "${WORK}"
run_stage build "${BUILD_CMD}"
run_stage test  "${TEST_CMD}"
run_stage arch  "${ARCH_CMD}"
run_stage lint  "${LINT_CMD}"

if [ "${GATE_MODE}" = "staged" ] && [ "${RAN}" -eq 0 ]; then
  say_fail "GATE: nothing to run yet, but staged mode needs at least one green stage"
  FAILED=1
fi

if [ "${FAILED}" -ne 0 ]; then
  fail_red
fi

mkdir -p "${ROOT}/.factory/verified"
{
  date -u +"%Y-%m-%dT%H:%M:%SZ"
  [ -n "${TEST_COUNT}" ] && echo "tests=${TEST_COUNT}"
  echo "test_files=${CENSUS_FILES}"
  echo "skipped=${CENSUS_SKIPS}"
  if [ "${WORK}" = "${ROOT}" ]; then echo "isolated=no"; else echo "isolated=yes"; fi
  # HEAD when this run went green. The task's own work is still uncommitted at
  # this point; factory-commit records it on top of this commit once the
  # integrator's gate is green as well.
  echo "commit=$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  # Fingerprint of the product tree this run saw, so the integrator can tell a
  # second gate run that would test different bytes from one that would test
  # the same ones. Factory bookkeeping is excluded from it. The helper comes
  # from the factory plugin and is on PATH inside a Claude Code session; run
  # this gate by hand in a plain terminal and the line reads "unknown", which
  # only means the integrator runs the gate again rather than skipping it.
  if command -v factory-gate-skip >/dev/null 2>&1; then
    echo "tree=$(factory-gate-skip hash "${ROOT}" 2>/dev/null || echo unknown)"
  else
    echo "tree=unknown"
  fi
} > "${ROOT}/.factory/verified/${TASK_ID}"

# Refresh the census baseline. Green is the only state worth measuring the next
# run against.
jq -n --argjson f "${CENSUS_FILES}" --argjson s "${CENSUS_SKIPS}" \
      --arg t "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --arg id "${TASK_ID}" \
   '{test_files: $f, skipped: $s, updated: $t, by: $id}' > "${BASELINE}" 2>/dev/null

# The task is green, so its failure history is history. Keep it for
# /factory:retro but out of the way, and drop any no-progress flag it carried.
if [ -f "${FAIL_DIR}/${TASK_ID}.log" ]; then
  mkdir -p "${FAIL_DIR}/resolved"
  mv "${FAIL_DIR}/${TASK_ID}.log" "${FAIL_DIR}/resolved/${TASK_ID}.log" 2>/dev/null
fi
rm -f "${ROOT}/.factory/no-progress/${TASK_ID}" 2>/dev/null

echo "GATE RESULT: GREEN for ${TASK_ID} (marker written)"
exit 0
