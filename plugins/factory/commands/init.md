---
description: Bootstrap the factory in this project - detect or decide the stack, scaffold tasks/ and gates/, split the spec into dependency-ordered tasks, then ask for approval
argument-hint: "[spec path or one-line goal]"
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, AskUserQuestion
---

Bootstrap the factory in the current project. Argument (optional): $ARGUMENTS

Work through the steps in order. Do not skip step 5: nothing builds - not
`/factory:fast`, not `/factory:run` - without my explicit approval.

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
- **Step 3** - skip if `CLAUDE.md` already has the `<!-- factory` pointer; if it still has the old `## Factory Protokolü` section, run `factory-upgrade --apply`, which replaces it.
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
   - `P0-08` set the real commands and flip the gate to full - `needs_human:
     true`: agents cannot write `.factory/config.json`, so I set
     `commands.build`, `test`, `lint` (and `arch`) to what P0-02..P0-07 built,
     and `"gate_mode": "full"`
     - acceptance: `bash gates/verify.sh --full` exits 0 and
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
retry of a red task, default `high`), `effort_review` (default `high`),
`risk_review` (`after`, the default: a task sent to review only by a risk path
lands first and is reviewed alongside the run; `before`: it waits for the
review), `audit` (default `true`: one auditor reads the run's seams at the end)
and `effort_audit` (default `high`). The top-level `retry_limit` (default 2)
is how many attempts a red task gets in total, the first included.

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
  "ignore":    ["<path globs no test can observe>"],
  "claude_md_max_lines": 200,
  "untracked_guard":     true
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
- **claude_md_max_lines** (default 200, `0` turns it off): a CLAUDE.md a task
  touches, or any tracked one at the full check, that is longer is red. Every
  agent loads it on every turn, so its size is a per-token cost of the run.
- **untracked_guard** (default `true`): a file git does not track, inside a unit
  the task touched and not in its `## Files touched`, is red - it would be left
  out of the task's commit (a generated migration, a new file nobody listed).
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

`gate_isolation` stays `false` unless I ask for it. When it is on, every check
runs in a clean worktree: a task's check holds HEAD plus the task's own files
(exactly what its commit will hold - a file missing from its list is a red
build, a neighbour's half-written file is not there), and the full check holds
HEAD. `isolation_links` is only read then: directories or files the build needs but git does not track, to be
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
  "autoCompactEnabled": true
}
```

Then add the hard-ban rules (`permissions.deny`: no push, tag, force, merge,
release, store tooling, no writes to `.env*`, `*.p8`, `*.jks`) with
`factory-deny --apply`. It is a union: the project's own rules stay, a second run
changes nothing. These rules are the second layer of `hooks/hard-blocks.txt`;
the hooks enforce the same list against agents.

Three of those bans are optional, because some developers want the factory (or
their own session) to do that work: store and TestFlight tooling (fastlane,
altool, notarytool, codemagic), git tags, and GitHub releases. **Ask about them
one by one, before the `factory-deny --apply` above**, in my language, with
AskUserQuestion (default: banned). Get the groups and their questions from
`factory-bans questions`. Say what allowing one means: agents of a run and this
session may then do it without a stop, and an autonomy consent given earlier no
longer holds. Then record the answer:

```bash
factory-bans set <the groups I allowed, none if I allowed none>
```

`factory-bans set` writes `hard_blocks.allow` into `.factory/config.json`,
which is why it runs from my session and is banned for agents, and it runs
`factory-deny --apply` itself. On a re-run of init on an existing project, do
not ask again: point to `/factory:bans`.

A long run outlives its context, and the lead carries the run across a
compaction (see "After a compaction" in the lead agent), so auto-compact must
stay on. Do not write `autoCompactWindow`: when to compact is the developer's
own setting (`~/.claude/settings.json` or `/autocompact`), and a project value
would silently override it.

`gates/verify.sh` is the project's gate entry point, and agents may not touch
it. The gate itself is in the plugin: `factory-check`, the same engine
`/factory:fast` uses, so it upgrades with the plugin. Write the entry point
with:

```bash
factory-upgrade --gate
```

- **No gate yet:** it writes the five-line shim that runs `factory-check`
  (`GATE WRITTEN`).
- **A gate an older factory wrote, unchanged:** it puts the shim in its place
  and keeps the old file in `.factory/gate-legacy/verify.sh` (`GATE REPLACED`).
- **A gate of the project's own:** it is left exactly as it is (`GATE KEPT`) -
  on a real project it is the file most likely to have been adapted to the
  repo. Read it and tell me, in one short list, which of these it lacks and
  what each would have caught (grep is enough):
  - no test count (`count_tests`) - a suite that ran zero tests passes as green
  - no census (`guard_test_census`) - deleting or skipping the failing test
    passes as green
  - no acceptance guard (`guard_acceptance`) - an acceptance criterion the
    agent satisfies by writing a sentence in decisions.md
  - no failure history (`record_failure`) - the identical failure gets retried
    until the retry limit runs out instead of stopping at the second one
  - no marker removal at the start (an `rm -f` of `.factory/verified/` for the
    task) - a red run leaves the previous green marker in place, and the
    done-guard lets the task into done on it
  - no `tree=` line in its marker - the integrator cannot skip a second run of
    the same bytes, so every task pays for the full suite twice

  Then offer the way over, and wait: `gates/verify.sh` becomes the shim, and
  what the gate does of its own (a dispatcher, an extra stage, a service it
  starts) moves into `gates/extra.sh`, which every check runs last - with the
  task id, or `--full` for the whole-tree check - and whose failure is red.
  Do not change the gate uninvited.

Either way the gate is `bash gates/verify.sh <task-id>` for the agents, and
`bash gates/verify.sh --full` for the whole tree.

Add to `.gitignore` if the project has one, so runtime artefacts stay out of
the repo while `.factory/active` and `config.json` remain committed:

```
.factory/verified/
.factory/lead-state.md
.factory/lead-state.read.md
.factory/claude-md-protocol.old.md
.factory/gate-legacy/
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
.factory/usage.jsonl
.factory/autonomy.json
.factory/autonomy-off
.factory/autonomy-cap
.factory/publish/
.factory/digest/
.factory/retro-due
.factory/STOP
```

`events.jsonl` is the run's history - every dispatch, gate run, move and commit,
written by hooks at no cost - and `dashboard.html` is the page built from it that
shows what the team is doing right now. `questions/` is what the team is waiting
on the developer for.

`changes/`, `retro/` and `lessons/` are the factory's own record of what it did,
how it went and what it learned. They stay on this machine, like the
`refs/factory/*` refs that point into `changes/`; what reaches the shared
repository is the commits themselves.

`baseline.json` is the test census an older gate (the template before 3.3)
compared each run against; the engine judges each task against HEAD instead, so
nothing per-machine decides what counts as a lost test.

---

## Step 3 - Project CLAUDE.md

Every agent loads `CLAUDE.md` on every turn, so the factory puts only a pointer
there; the rules live in each agent's own instructions and in the hooks. Add
this block to the project's `CLAUDE.md` (create the file if absent, do not touch
unrelated content). If the file already has a block between `<!-- factory`
markers, or an old `## Factory Protokolü` section from an earlier factory,
replace it with this one instead of adding a second:

```markdown
<!-- factory: written by /factory:init, kept current by /factory:upgrade -->
## Factory
While `.factory/active` exists this project is built by the factory plugin: `tasks/` is the board, each task file is the source of truth for its work, and every factory agent follows its own instructions. Hooks enforce the hard blocks (`/factory:bans`); `/factory:fast` builds the approved backlog and `/factory:status` shows the board.
Compact instructions: keep which tasks were dispatched and at which stage, the last check results, retries and blocked reasons; where the summary and `.factory/lead-state.md` disagree, the file is right.
<!-- /factory -->
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
- `dependencies: [name, ...]` on a task that has to add or upgrade a package.
  `factory-check` turns a change to a dependency manifest red unless the approved
  task file names it, so a builder cannot pull in code nobody chose; name the
  packages the spec calls for, and nothing on a task that should need none.
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

Then stop and ask for approval in plain words. Do not start a run, do not
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
3. Tell me the change is open and that `/factory:fast` builds it: one builder per
   task and one deterministic check each, measured at about a third of the cost
   of `/factory:run`, which remains for when I want a lead to steer task by task.
### The one line that approves and hands over

End the board with exactly one line: `Onaylıyorsanız "auto devam et" yazın.` That
single phrase, typed by me and nothing else in the message, approves the board
**and** records my consent to run at the autonomy level (`autonomy_default` in
`.factory/config.json`: `local` commits only, `pr` also pushes a branch and opens
a pull request, `merge` also merges it when its checks are green; default
`merge`). Ask me which level I want once, as part of this step, and write the
answer to `autonomy_default`. A hook records the consent; you never write
`.factory/autonomy.json` yourself, and a phrase with other words in it is not
consent - ask again. `auto dur` (or `/factory:autonomy off`) returns to `local`.
The hard bans (no push by an agent, no writes to `.env*`, keys, `gates/`) hold at
every level.

