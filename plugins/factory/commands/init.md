---
description: Bootstrap the factory in this project - detect or decide the stack, scaffold tasks/ and gates/, split the spec into dependency-ordered tasks, then ask for approval
argument-hint: [spec path or one-line goal]
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, AskUserQuestion
---

Bootstrap the factory in the current project. Argument (optional): $ARGUMENTS

Work through the steps in order. Do not skip step 5: `/factory:run` must not run
without my explicit approval.

---

## Step 0 - Is the factory already here?

Check for `.factory/config.json` and for any task file under `tasks/`.

**Neither exists** - this is the first run in this project. Carry on with Step 1
exactly as written.

**Either exists** - the factory was set up here before, and this run adds one
more piece of work to it: a feature, a bugfix, a migration. Switch to
**incremental mode**. Everything earlier runs produced stays exactly as it is -
finished tasks, their verified markers, their failure history, the tuned config,
the gate - and the new work is added next to it without touching any of it.

Incremental mode changes the steps below like this:

- **Step 1** - skip stack detection; the stack and the commands are already in
  `.factory/config.json`. If the new work plainly needs a stage the config lacks
  (a web app added to a backend-only repo, say), tell me and ask. Do not edit
  the config yourself. The same goes for keys added to the factory after that
  config was written: if `risk_paths` is missing, propose a list for this repo
  (see Step 2) and ask whether to add it - without it no green task is routed
  to a reviewer by what it touched. Likewise a missing `check` block: propose
  one from the project's structure (Step 2) and ask - without it every
  `/factory:fast` check runs the whole suite.
- **Step 2** - create only directories that are missing, plus `tasks/proposed/`.
  Never write `.factory/config.json`, `gates/verify.sh`, `decisions.md` or
  `.factory/active` in this mode: each already exists and may have been adjusted
  by hand since the first run.
- **Step 3** - skip; the protocol section is already in `CLAUDE.md`.
- **Step 4, the spec** - the spec for this run is the command argument and only
  the argument. A path means read that file; a sentence means that sentence is
  the goal. With no argument, stop and ask me what this run is for. `specs/` is
  read for context - the product it describes, the decisions it settles - and
  never split into tasks again: an earlier run already split it, and splitting
  it twice produces duplicate tasks for work that is already done.
- **Step 4, ids** - this run is one *change* - a feature, a bugfix, a
  migration - and every task in it carries the change's prefix. Get the prefix
  with `factory-ids next-prefix` (it prints `C2` on the
  first increment, then `C3`, and so on) and number from 01: `C2-01`, `C2-02`.
  The first run's tasks (`P0-..`, `T-..`) are change C1. A prefix per change
  makes a collision impossible by construction, and it is how the commits, the
  change archive and its summary tell which change a task belongs to.
- **Step 4, dependencies** - `depends_on` may name tasks from earlier changes.
  A finished one counts as satisfied; an unfinished one makes this task wait for
  it, which is right when the new work genuinely builds on it.
- **Step 4, location** - write the new task files to `tasks/proposed/`, not
  `tasks/backlog/`. The lead dispatches from the backlog, and a factory that is
  already running would pick up tasks I have not approved. Nothing reads
  `tasks/proposed/` except this command.
- **Before Step 5** - run `factory-ids check`. It must
  exit 0. A non-zero exit names each collision; rename the offending new task
  and run the check again.
- **Step 5** - show only the new tasks, then one line for the rest of the board:
  `existing, untouched: backlog=N in-progress=N blocked=N done=N`. When I
  approve, move the new files from `tasks/proposed/` to `tasks/backlog/`. That
  move is the approval; until it happens, no run can see them. Then open the
  change exactly as Step 5 describes.

---

## Step 1 - Detect the mode

Inspect the working directory: `ls -la`, then look for `*.sln`, `*.csproj`,
`pubspec.yaml`, `package.json`, `go.mod`, `Cargo.toml`, `pom.xml`,
`build.gradle*`, `requirements.txt`, `pyproject.toml`, `Package.swift`,
`*.xcodeproj`, and for a `specs/` directory.

### Mode A - existing project

Identify language and build system, then pick the real verify commands. Reference
sets (adapt to what the repo actually uses, do not assume):

| Stack | build | test | lint |
| --- | --- | --- | --- |
| .NET | `dotnet build -warnaserror` | `dotnet test` | `dotnet format --verify-no-changes` |
| Flutter | `flutter analyze` (an APK build belongs in CI, not in every gate run) | `flutter test` | `dart format --set-exit-if-changed .` |
| Node/TS | `npm run build` | `npm test` | `npm run lint` |
| Go | `go build ./...` | `go test ./...` | `golangci-lint run` |
| Python | `python -m compileall -q .` | `pytest` | `ruff check .` |
| Rust | `cargo build` | `cargo test` | `cargo clippy -- -D warnings` |

Prefer commands that already exist in the repo (npm scripts, Makefile targets, CI
workflow steps). Read the CI file if there is one and reuse its commands verbatim.
Set `gate_mode` to `full`.

### Mode B - greenfield (empty directory, or no recognisable project)

1. Read `specs/` first. Every decision already written there is settled; do not
   re-ask it.
2. For whatever is still undecided, ask me in ONE `AskUserQuestion` call, at most
   four questions, combining where needed:
   - language + framework
   - database / persistence
   - architecture template (e.g. layered, hexagonal/clean, vertical slice, modular
     monolith, microservices)
   - repository / solution name
   Assume nothing on these. If I answer with something you cannot map to a
   concrete toolchain, ask again rather than guessing.
3. Put a **Phase 0 - Foundation** package at the very front of the backlog. One
   task per item, each with a runnable acceptance command:
   - `P0-01` git repo + directory skeleton + `.gitignore`
     - acceptance: `git rev-parse --is-inside-work-tree` prints `true`
   - `P0-02` solution / project structure created
     - acceptance: the build command exits 0 with zero errors
   - `P0-03` shared core (domain primitives, error type, DI/composition root)
     - acceptance: build exits 0 and the core project is referenced by the app
   - `P0-04` test infrastructure + one sample test
     - acceptance: the test command runs and reports 1 passing test
   - `P0-05` architecture boundary tests (dependency rules of the chosen template)
     - acceptance: the boundary test suite passes, and fails when a rule is
       violated on purpose
   - `P0-06` lint + format configuration
     - acceptance: the lint command exits 0
   - `P0-07` CI file running build + test + lint
     - acceptance: the CI file parses and its steps run locally
   - `P0-08` fill `gates/verify.sh` with the real commands and flip the gate to
     full
     - acceptance: `bash gates/verify.sh P0-08` exits 0 and
       `.factory/config.json` has `"gate_mode": "full"`
   Set `gate_mode` to `staged` at init time.
4. Every product task generated from the spec gets `depends_on` entries pointing
   at the Phase 0 tasks it needs. No product task may be assignable before the
   ground it stands on exists.

---

## Step 2 - Scaffold

Create, without clobbering anything that already exists:

```
.factory/active
.factory/config.json
.factory/verified/.gitkeep
tasks/backlog/  tasks/in-progress/  tasks/done/  tasks/blocked/
gates/verify.sh
decisions.md
```

`.factory/config.json` (read the harness version first -
`cat factory-version` - and write that exact string as
`factory_version`; it is how a later session knows this project was set up by an
older factory and offers `/factory:upgrade`):

```json
{
  "factory_version": "<the contents of factory-version>",
  "verify": "gates/verify.sh",
  "workers": 2,
  "max_concurrent_agents": 3,
  "retry_limit": 2,
  "min_tests": 1,
  "gate_mode": "staged",
  "agent_stale_after_min": 45,
  "gate_isolation": false,
  "isolation_links": [],
  "risk_paths": [
    "*/auth/*", "*authentication*", "*authorization*", "*identity*",
    "*permission*", "*tenant*", "*payment*", "*billing*",
    "*/migrations/*", "*.sql", "*secret*", "*crypto*", "*/.github/workflows/*"
  ],
  "stack": "<detected or chosen stack>",
  "commands": {
    "build": "<build command or empty string>",
    "test": "<test command or empty string>",
    "arch": "<architecture test command or empty string>",
    "lint": "<lint command or empty string>"
  }
}
```

`risk_paths` decides which green tasks still get a reviewer before they are
committed: after every green gate the lead runs `factory-risk`, which matches
the task's `## Files touched` against these patterns (shell globs,
case-insensitive, `*` crossing directories, a pattern without a leading `/` or
`*` matching at any depth). The list above is a starting point, not a verdict.
Adapt it to the repository: look at its directory and file names, add what
guards security, tenancy, money and data (`*/Policies/*`, `*Guard*`,
`*/Tenancy/*`), and drop what would match half the repo, because every false
match costs a review dispatch. Generated files are never a reason for review:
mark them `linguist-generated=true` in `.gitattributes` if the project does not
already, or list their globs under `risk_exclude` in the config. The final list is part of what I approve in
Step 5.

`fast` is optional and configures `/factory:fast`: `workers` (how many builders at
once, default 4), `effort_build` (default `medium`), `effort_escalate` (the one
retry of a red task, default `xhigh`), `effort_review` (default `high`),
`risk_review` (`after`, the default: a task sent to review only by a risk path
lands first and is reviewed alongside the run; `before`: it waits for the
review), `audit` (default `true`: one auditor reads the run's seams at the end)
and `effort_audit` (default `high`).

`check` is optional too, and it is how `/factory:fast` judges one task without
running the whole project. `factory-check` knows no language, framework or build
tool: everything it runs comes from this block or, where the block is silent,
from `commands`. Write it from what you found in Step 1, and put in it only what
the project's own tools already express:

```json
"check": {
  "format":    "<command that formats files in place; {files} = the files a task touched>",
  "units":     [ { "name": "<unit>", "path": "<dir>", "deps": ["<unit it depends on>"],
                   "test": "<command that runs this unit's tests, from the project root>" } ],
  "unit_test": "<default per-unit test command, with {path} and {name}>",
  "count":     "<regex whose group is the number of tests a run reported>",
  "ignore":    ["<path globs no test can observe>"]
}
```

- **units** are the parts the project is already divided into: the packages of a
  workspace, the projects of a solution, the modules of a build, or feature
  folders with their own test directories. `deps` comes from the project's own
  dependency declarations - never guessed. A task's check runs the tests of the
  units it touched and of every unit that depends on them; a touched file outside
  every unit runs the whole suite. When the list would go stale as units are
  added, make `units` a command that prints it as JSON instead of a literal list.
  A single-unit project needs no `units` at all: every check runs
  `commands.test`. Split only where the suite is big enough to be worth it -
  every unit's test command pays the runner's start-up again, and on a small
  project one suite run is faster than two unit runs.
- **count** only when the test runner's summary does not say "N passed", "passed:
  N" or "Total tests: N". Without a count the zero-test guard cannot see a run
  that executed nothing.
- **build**, **lint**, **arch** may be overridden with narrower commands (`{files}`,
  `{paths}` = the reached units' paths). Leave them out and `commands` is used.
  A lint or format check that walks the whole tree judges every other task's
  unfinished files too: when the project's tool accepts paths, give `lint` a
  `{paths}` or `{files}` form - the full check still runs the whole-tree one
  once, at the end.

Show the `check` block in the approval table in Step 5, as one line per key.

`gate_isolation` stays `false` unless I ask for it. When it is on, the gate
checks each task in a clean worktree holding HEAD plus the task's own files -
see the comment above `isolate` in the gate. `isolation_links` is only read
then: directories or files the build needs but git does not track, to be
symlinked rather than rebuilt - `["node_modules"]` for a Node project, a
`.venv` for Python, an untracked local settings file. Never a build output
directory.

`workers` is how many tasks may sit in `tasks/in-progress` at once.
`max_concurrent_agents` is a separate, harder limit: how many agents may be open
at the same time, of any type - implementers, reviewers and integrators all count
against it. A `factory-agent-limit` PreToolUse hook enforces it by denying the
dispatch, so it does not depend on the lead remembering.

Defaults are 2 and 3. Each concurrent agent is a separate Claude process on the
developer's machine, so raising either heats the laptop as much as it speeds the
run. Raise them only if I ask.

Also write `.claude/settings.json` in the project (merge, do not clobber an
existing one):

```json
{
  "autoCompactWindow": 400000,
  "autoCompactEnabled": true
}
```

`autoCompactWindow` is a token count, not a percentage, and Claude Code caps it at
the model's real context window. 400000 is 40% of a 1M window: the lead compacts
early instead of at ~95%, which keeps its per-turn context - and therefore its
cost - from growing without bound. On a 200K-window session the value is capped
and the default behaviour applies. Keep it project-scoped so other projects are
unaffected.

`gates/verify.sh` - **only when the file does not already exist.** An existing
gate is never overwritten: on a real project it is the file most likely to have
been adapted to the repo - scoped test runs, a dispatcher, extra stages - and
replacing it with the template would silently throw that work away.

When `gates/verify.sh` is already there:

1. Leave it exactly as it is. Write `.factory/config.json` only if it does not
   exist yet - an existing config is never rewritten, for the same reason the
   gate is not.
2. Read it and check which of the gate's five protections it carries. Grep is
   enough: `count_tests`, `guard_test_census`, `guard_acceptance`,
   `record_failure`, and an `rm -f` of `.factory/verified/` for the task before
   the stages run.
3. Report what is missing, in one short list, naming what each absent one would
   have caught:
   - no `count_tests` - a suite that ran zero tests passes as green
   - no `guard_test_census` - deleting or skipping the failing test passes as
     green
   - no `guard_acceptance` - an acceptance criterion the agent satisfies by
     writing a sentence in decisions.md
   - no `record_failure` - the identical failure gets retried until the retry
     limit runs out instead of stopping at the second one
   - no marker removal at the start - a red run leaves the previous green
     marker in place, and the done-guard, which only checks that a marker
     exists, lets the task into done on it

   Also say whether it has an `isolate` function and whether its marker block
   writes a `tree=` line. Neither is a protection:
   - no `isolate` - `"gate_isolation": true` in the config silently does nothing
   - no `tree=` in the marker - the integrator can never tell that its second
     gate run would test the same bytes as the first, so every task pays for
     the full suite twice
4. Then ask whether to add the missing parts, and wait. Do not merge them in
   uninvited. If I say yes, add only the missing functions and their call sites,
   keeping every project-specific thing the file already does.

Write the file below only when there is no gate yet, substituting nothing but
the command values, which come from `.factory/config.json`:

```bash
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
TASK_ID="\$1"

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

read_cmd() { jq -r --arg k "\$1" '.commands[$k] // ""' "${CONFIG}" 2>/dev/null; }

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
    | sed -n "s/^\$1:[[:space:]]*//p" | head -1
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
    shasum -a 256 | awk '{print substr(\$1,1,12)}'
  else
    sha256sum | awk '{print substr(\$1,1,12)}'
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
  local out="\$1" n
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
    n="$(sed -E -n "${pat}" "${out}" | awk '{s+=\$1} END {print s+0}')"
    if [ -n "${n}" ] && [ "${n}" -gt 0 ] 2>/dev/null; then
      TEST_COUNT="${n}"
      return 0
    fi
  done <<< "${pats}"
  TEST_COUNT=""   # unrecognised runner output: say so rather than guess
}

run_stage() {
  local name="\$1" cmd="\$2"
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
```

`chmod +x gates/verify.sh` afterwards.

Add to `.gitignore` if the project has one, so runtime artefacts stay out of
the repo while `.factory/active` and `config.json` remain committed:

```
.factory/verified/
.factory/lead-state.md
.factory/compact-log.md
.factory/failures/
.factory/no-progress/
.factory/baseline.json
.factory/run-owner*
.factory/inflight/
.factory/changes/
.factory/retro/
.factory/lessons/
.factory/events.jsonl
.factory/dashboard.html
.factory/statusline.txt
.factory/questions/
.factory/.dash-stamp
.factory/.cost-sample
.factory/logs/
.factory/locks/
.factory/full-check
.factory/run-start.json
.factory/last-run.md
.factory/parked/
.factory/audit.md
.factory/gate-start/
```

`events.jsonl` is the run's history - every dispatch, gate run, move and commit,
written by hooks at no cost - and `dashboard.html` is the page built from it that
shows what the team is doing right now. `questions/` is what the team is waiting
on the developer for.

`changes/`, `retro/` and `lessons/` are the factory's own record of what it did,
how it went and what it learned. They stay on this machine, like the
`refs/factory/*` refs that point into `changes/`; what reaches the shared
repository is the commits themselves.

`baseline.json` is the test census the gate compares each run against. It is
per-machine state, not a shared fact, so it stays out of the repo - which does
mean deleting it resets the census. That is a speed bump against the default
behaviour, not a lock against an adversary; an agent determined to get around
the gate could also edit `verify.sh`. The value is that removing a test now
takes a deliberate act instead of happening quietly.

---

## Step 3 - Project CLAUDE.md

Append this section to the project's `CLAUDE.md` (create the file if absent, do
not touch unrelated content, do not duplicate the section if it is already there):

```markdown
## Factory Protokolü

Bu projede `.factory/active` dosyası varken factory üretim döngüsü açıktır.

### Görev yaşam döngüsü
`tasks/backlog` -> `tasks/in-progress` -> review (yalnızca kırmızı kapıda,
`review: always` işaretliyse ya da görev `risk_paths` kalıplarına uyan bir
dosyaya dokunduysa) -> entegrasyon kapısı -> `tasks/done` -> commit.
Kapanmayan iş `tasks/blocked` altına düşer. Görev dosyası tek gerçek kaynaktır.

### Commit kuralı
Fabrika tek, paylaşılan çalışma ağacında ve mevcut dalda çalışır. Her görev,
entegrasyon kapısı yeşil dönüp `tasks/done` altına taşındıktan sonra
`factory-commit <task-id>` ile TEK commit olarak
kaydedilir. Commit yalnızca görev dosyasının `## Files touched` listesindeki
dosyaları, görev dosyasını ve `decisions.md` dosyasını içerir; mesajında
`Factory-Task` ve `Factory-Change` trailer'ları bulunur. Fabrika push yapmaz, dal
açmaz, geçmişi yeniden yazmaz, commit hook'larını atlamaz. Commit'i yalnızca
entegratör atar. Paylaşılan ağaçta `git checkout`, `restore`, `stash` ve `reset`
başka bir görevin işini de silebileceği için hiçbir ajan bunları kullanmaz.

### Dersler
`.factory/lessons/<module>.md` ve `.factory/lessons/general.md`, bu projede daha
önce bir görevin hata yaparak öğrendiği kuralları tutar. Implementer işe
başlamadan önce kendi modülünün ve genel dosyanın derslerini okur. Ders yalnızca
`/factory:retro` üzerinden, geliştirici tek tek onayladıktan sonra ve kanıtıyla
birlikte (`factory-lesson`) eklenir. Ajanlar kendiliğinden ders yazmaz.

### Değişiklik arşivi
Her `/factory:init` onayı bir değişiklik açar (C1, C2, ...). İstek
`.factory/changes/<id>-<slug>/goal.md` dosyasında, görevler, commit'ler ve
kararlar `summary.md` dosyasında durur. Son görevi biten değişiklik kapanır ve
yerel `refs/factory/<id>-<slug>` ref'i o değişikliğin son commit'ini gösterir. Bu
ref push edilmez.

### Kapı kuralı
Bir görev `tasks/done` dizinine ancak `bash gates/verify.sh <task-id>` yeşil
dönüp `.factory/verified/<task-id>` işaretini yazdıktan sonra taşınabilir.
PreToolUse hook'u işaret dosyası olmadan yapılan her taşımayı reddeder.
Kapı kırmızıysa: çıktı görev dosyasına eklenir, `retries` artırılır, görev geri
atanır; `retries` limiti aşarsa görev `tasks/blocked` altına taşınır.

### decisions.md zorunluluğu
Her tamamlanan görev `decisions.md` dosyasına TEK satır karar notu bırakır:
`- <task-id>: <alınan karar> - <tek cümlelik gerekçe>`

### Lead kod yazmaz
Takım lideri görev atar, sonuç toplar, yönlendirir. Kaynak kod, test veya
konfigürasyon yazmaz; bunu implementer yapar.

### Compact instructions
Konuşma özetlenirken (compact) şunlar mutlaka korunacak: hangi görevlerin
dispatch edildiği ve hangi aşamada oldukları, son kapı sonuçları (yeşil/kırmızı
ve hangi görev), retries sayaçları, blocked görevlerin sebepleri ve `decisions.md`
dosyasına henüz yazılmamış kararlar. Uzun araç çıktıları, dosya içerikleri ve
tamamlanmış görevlerin ayrıntıları atılabilir. Özetten hemen önce PreCompact
hook'u `.factory/lead-state.md` dosyasına tahtanın diskten yeniden kurulmuş halini
yazar; özet ile bu dosya çelişirse dosya doğrudur.

### Kapsam genişletme yasağı
Ajan yalnızca görev dosyasında yazan işi yapar. Görevde geçmeyen refactor, ek
dosya, bağımlılık yükseltmesi veya "hazır girmişken" iyileştirme yapılmaz.
Mevcut yapı kusurluysa iş yapılmaz, durum lead'e bildirilir.
```

---

## Step 4 - Split the spec into tasks

The spec for this run is the command argument when there is one - a path is a
file to read, a sentence is the goal - and `specs/` otherwise. When both exist,
the argument is what gets split and `specs/` is context. With neither, stop and
ask me for one before generating anything. Incremental mode narrows this
further; see Step 0.

One task = one markdown file in `tasks/backlog/<id>.md` (`tasks/proposed/<id>.md`
in incremental mode) with this frontmatter:

```markdown
---
id: T-014
title: Order module public contract
module: orders
depends_on: [P0-03, P0-04]
acceptance: dotnet test tests/Orders.Contracts.Tests
needs_human: false
review: on-red
retries: 0
owner:
stage: queued
stage_since:
---

## Goal
<what must be true when this is done, in two or three sentences>

## Constraints
<files/modules in scope, files explicitly out of scope>

## Context
<the files a builder reads first and why, the existing code to copy, where new pieces are registered or wired in>

## Acceptance criteria
- [ ] <criterion that the acceptance command actually checks>
- [ ] <criterion>

## Files touched
<filled in by the implementer: one repo-relative path per line, as "- path">

## Attempts
<appended by implementers: one entry per red gate, and a "Resolved by:" line on the first green after a red>
```

Rules:

- Ids: the first run uses `P0-NN` for Phase 0 and `T-NNN` for product tasks,
  and together they form change C1. Every later run uses its change prefix;
  see Step 0.
- `## Context` is what you already found out in Step 1 and while splitting the
  spec, written down so a builder does not have to find it again: the files to
  read first (path, and one clause on why), the existing code whose pattern to
  copy, where new pieces are registered or wired in, and any convention the code
  does not make obvious. At most ten lines, paths rather than prose. Every
  builder starts cold; on a real board, builders without it spent about sixty
  reads per task rediscovering the same code.
- `## Files touched` starts empty. The implementer fills it in, and the commit
  that records the task takes exactly those files, so this list is the line
  between this task's work and everything else in a shared working tree.
- `## Attempts` starts empty too. Every implementer that leaves the gate red
  writes what it tried and what it ruled out there, so a retry starts from the
  last attempt's knowledge instead of from zero; the first green after a red
  adds what finally fixed it, which is what `/factory:retro` turns into lessons.

- Ids are never reused, not even for a task that was deleted. Every record the
  factory keeps is keyed by id - the verified marker the done-guard trusts, the
  failure history, the dependency graph - so a reused id inherits another
  task's past, including its green gate.
- `acceptance` MUST be a single runnable command, not prose, and it MUST run the
  code. A command whose only evidence is `decisions.md` or a task file is one
  the agent satisfies by writing a sentence; the gate rejects those outright.
  If a task genuinely cannot be machine-checked, it is `needs_human: true` work,
  not a task with a soft criterion.
- `owner`, `stage` and `stage_since` start empty / `queued`. The loop fills them:
  they are what /factory:status and the compaction memo read to show who holds
  what,
  and the Stop hook refuses to let the session end while an in-progress task is
  missing either of them.
- Ordering: for every module, its contract/interface task comes first, and every
  other task in that module declares it in `depends_on`. Cross-module tasks depend
  on the other module's contract task, never on its implementation task.
- Greenfield: every product task depends on the Phase 0 tasks that make its
  acceptance command runnable.
- `needs_human: true` for anything needing credentials, a paid account, a store
  submission, a design decision I have not made, or access you do not have.
- `review:` is `on-red` by default: a reviewer runs only when the gate fails. Set
  `review: always` on work the gate cannot judge - security boundaries, tenant
  isolation, authentication, payments, data deletion, and public contracts other
  modules compile against. Be sparing: every `always` costs a dispatch on every
  attempt.
- Graph shape: the longest dependency chain, not the number of workers, bounds
  how fast the board is built - tasks on one chain run one after another.
  Before Step 5, measure it: `factory-plan --proposed` (incremental mode) or
  `factory-plan` prints a `CRITICAL` line and warns when one chain holds more
  than half the tasks. Then shorten it: merge consecutive links that change the
  same part of the code into one task (every link pays a task's fixed cost), and
  move work that has to happen in sequence - a generated artifact, a schema
  migration, a lockfile - into one task after the parallel work instead of
  threading it through every link. Depend on a contract, not on an
  implementation, wherever the contract is enough.
- Task size: one implementer, one gate run. If it needs three unrelated gates,
  split it. The working granularity is one pull request: substantial enough to
  be worth a dispatch, small enough that a red gate does not throw away an hour
  of work.
- `untested_ok: true` only on a task whose change no test can reach -
  scaffolding, an entry point that only wires things together. `factory-check`
  turns a change no test imports red, because a change nothing exercises proves
  nothing; the flag is how the exception is written down, like the next one.
- `allow_test_removal: true` only on a task whose actual job is removing or
  skipping tests - retiring a feature, deleting a dead suite. The gate counts
  test files and suppression markers on every run and turns red when a run has
  fewer tests or more skips than the last green one, because deleting the
  failing test and skipping the failing test are the two cheapest ways to make
  a gate pass without doing the work. The flag is how a legitimate removal says
  so out loud.

---

## Step 5 - Show me and wait

First, check the files you just wrote:

```bash
factory-lint --all
```

Every line that is not `LINT OK` is a task file that would cost a dispatch to
discover: an id that disagrees with its filename, a `depends_on` naming a task
that does not exist, a template placeholder left in the body, an acceptance
command that checks nothing runnable. Fix them and run it again until the only
output is `LINT OK` lines. Do not show me a table built on files that do not
lint.

Head it with the change these tasks form: `Change C2 · <slug> · <type>` (`C1` on
the first run). The slug is a short name of lowercase ASCII words joined by
hyphens, at most 40 characters - `invoice-csv-export`, `login-timeout-fix`. The
type is one of `feature`, `bugfix`, `refactor`, `migration`, `chore`. Both end up
in a folder name and a git ref name, which is why the alphabet is narrow.

Print a table: `id | title | module | depends_on | acceptance | needs_human`,
grouped by phase/module, in dependency order. Then the totals: task count,
Phase 0 count, needs-human count, and the longest dependency chain and widest
level as `factory-plan` measured them. On the first run,
also print the `risk_paths` list you wrote into the config, one line: green
tasks touching these get a reviewer before commit.

Then stop and ask for approval in plain words. Do not start `/factory:run`, do not
dispatch any agents, do not touch source code until I approve. If I want changes,
edit the task files and show the table again. The slug and the type are part of
what I approve; I may change them.

When I approve:

1. Incremental mode only: move the new task files from `tasks/proposed/` to
   `tasks/backlog/`.
2. Open the change. This is what keeps it findable after the run:

   ```bash
   factory-change open <change-id> <slug> <type> <goal-source> "<acceptance command>"
   ```

   `<goal-source>` is the spec file when the argument was a path. When the
   argument was a sentence, it is `-`, with the sentence verbatim on stdin
   through a quoted heredoc so nothing in it gets expanded:

   ```bash
   factory-change open C2 invoice-csv-export feature - <<'GOAL'
   <the argument, verbatim>
   GOAL
   ```

   When the spec is the `specs/` directory, use `-` with one paragraph stating
   the goal and naming the spec files.

   The last argument is optional and is the **change's own acceptance command**:
   one command that proves the whole thing works, not task by task. Propose one
   in the approval table and let me change or drop it. Every task green is not
   the same claim - tasks pass one at a time, and the feature they add up to can
   still be broken at the seams: a screen nothing routes to, a migration that
   runs but leaves the app unable to read its own data. When a change has one,
   it does not close until `factory-accept` has run it green. Leave it out
   for a change whose tasks genuinely are the whole claim - a chore, a rename -
   rather than inventing a command that only re-runs the same tests.

   It writes `.factory/changes/<id>-<slug>/goal.md` - the request, the date, the
   branch and commit it starts from, its tasks, the earlier changes it builds
   on - and a first `summary.md`. It refuses a reused id, a malformed slug or
   type, and a change with no tasks: fix what it names and run it again.
3. Tell me the change is open and that `/factory:run` builds it.
