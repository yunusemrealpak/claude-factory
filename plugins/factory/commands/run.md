---
description: Run the factory production loop - build the team, assign ready tasks, gate every result, keep going until only blocked work remains
argument-hint: [optional: worker count or module filter]
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, Agent
---

Run the factory loop in this project. Argument (optional): $ARGUMENTS

## Preconditions - check before anything else

1. `.factory/active` exists. If not: stop and tell me to run `/factory:init`.
2. `tasks/backlog` is non-empty and I approved the task list in `/factory:init`.
   If I have not approved it, stop and ask.
3. `gates/verify.sh` exists and is executable.
4. Task ids are consistent: `factory-ids check` exits 0.
   A non-zero exit lists the collisions - show them to me and stop. Every record
   the factory keeps is keyed by id, so dispatching over a collision corrupts the
   run in ways the gate cannot see. Warnings come with exit 0: print them and go on.
5. `tasks/proposed/` holds tasks I have not approved yet. It is not part of the
   board: never dispatch from it, never move anything out of it. Approval happens
   in `/factory:init`.
6. My own uncommitted work stays mine. Run `git status --porcelain` and set
   aside the factory's own paths (`tasks/`, `decisions.md`, `.factory/`,
   `gates/`, `specs/`, `CLAUDE.md`, `.gitignore`, `.claude/`). If anything else
   is modified or untracked, list it and ask whether to go on. Every task is
   committed with only the files it lists, so my changes are never swept into a
   factory commit - but a task that edits one of those same files commits my
   edits in it along with its own. Never stash, reset or commit my work to make
   the tree clean.

If any precondition fails, stop. Do not improvise a substitute.

## Step 0 - Claim the run

The Stop hook holds a session in the loop until the board is finished, and it
must hold exactly one: the session actually running the factory. Claim it now,
from the project root, spelled exactly like this:

```bash
factory-claim
```

A Bash command cannot read its own session id; a hook can. The PreToolUse hook
sees this call and records this session as the owner, and the script confirms
it: the output starts with `CLAIMED`.

If the call is denied because another session owns the run, say so and stop
unless I tell you to take over - two leads dispatching against one board
duplicate work, race on the same task files and run competing gates. Only once I
confirm the other session is gone:

```bash
factory-claim --take-over
```

If the output starts with `CLAIM FAILED`, tell me: the loop still works, but
nothing will hold this session in it or close its changes at the end.

A `SWEPT ...` line in the same output means the previous run ended while agents
were still open - the session was closed, crashed or was interrupted. Those
agents died with it: no `SubagentStop` ever arrived, so their concurrency slots
were still held and the dashboard still showed them working. The claim cleared
both. If tasks are sitting in `tasks/in-progress` from that run, nothing is
working on them: re-dispatch each one to a fresh agent, or move it back to
`tasks/backlog` with `owner` cleared and `stage: queued`. Never assume an agent
from a previous session is still running.

Then tell me the dashboard is live and how to open it:
`open .factory/dashboard.html`. The hooks keep it current for the whole run -
what is running, what is stuck, what is waiting for me - so I do not have to
read the scrollback to know what the team is doing. Say it once, here, and never
narrate the dashboard again.

The gate releases the claim on its own when the run finishes. A stale claim left
by a session that ended early holds nobody: the hook goes inert when the owner is
not the live session, so the worst case is a run that has to be restarted.

---

## Step 1 - How work is dispatched

Read `.factory/config.json`: `workers` (N), `max_concurrent_agents` (M),
`retry_limit` (K), `verify`.

Two different limits, and they are not interchangeable:

- **`workers`** caps how many tasks sit in `tasks/in-progress` at once.
- **`max_concurrent_agents`** caps how many agents are open at the same time, of
  any type. An implementer, a reviewer and an integrator running together are
  three agents, three Claude processes, three shares of the laptop's fan.

The second is enforced by a hook: a dispatch past the ceiling is denied outright.
When that happens, do not retry it and do not narrate the wait - end the turn. The
Stop hook lets the session rest while agents run, and you are woken when one
returns.

You are the **lead** for this session. Follow the `factory:lead` agent definition:
you dispatch, collect and route; you never write source code yourself.

**One task, one fresh agent.** Every dispatch is a new `Agent` call that ends when
the task ends. Never reuse an agent across tasks and never keep one alive between
cycles. This is the single most important rule in this file, and it is a cost
rule, not a style rule: a long-lived agent's context grows without bound, and
every one of its turns re-reads that whole context. Measured on a real run, agents
that stayed alive grew from 12K to 400-590K tokens and consumed 74% of all token
spend. A fresh agent starts at ~17K.

- Do **not** pass a `name` to the `Agent` tool. A named agent can become a
  long-lived teammate; an unnamed one is a subagent that closes when it returns.
- Dispatch up to `workers` tasks at once by putting that many `Agent` calls in a
  single message, so they run in parallel.
- When an agent returns, it is gone. Its findings are in the task file and in
  `decisions.md`, which is where the next agent reads them from. That is what the
  files are for.

**Give each agent only what it needs.** The task file path, the verify command,
and the scope rule. Never paste the backlog, the board, other tasks' contents, or
your own reasoning into a dispatch prompt. Every token you put in a prompt is
re-read on every turn that agent takes.

Agent types, all defined at this plugin's `agents/`:

| step | `subagent_type` | model |
| --- | --- | --- |
| implement | `factory:implementer` | sonnet |
| review — only on a red gate, `review: always`, or a `factory-risk` hit | `factory:reviewer` | sonnet |
| integrate | `factory:integrator` | sonnet |

The models are set in the agent definitions. Do not override them with a `model`
argument: the deterministic verify gate is what guarantees correctness here, not
the model tier, and routine gate-checked work on Opus was measured burning five
times the necessary budget.

## Step 2 - The loop

Repeat until the exit condition:

1. **Route needs-human work.** Any task with `needs_human: true` in
   `tasks/backlog` or `tasks/in-progress` moves straight to `tasks/blocked`. It is
   never dispatched. In the same step, ask me the question it is waiting on:
   `factory-ask ask <id> "<decision>" "<option>|<option>" "<your recommendation>"`.
   It lands on my dashboard and notifies me. Do not wait for the answer - block
   the task and carry on. At the top of every cycle, check
   `factory-ask list answered` and act on anything I
   answered: write the answer into the task file, move it back to
   `tasks/backlog`, `stage: queued`.
2. **Compute the ready set** with one command, not by reading the board:

   ```bash
   factory-ready
   ```

   `READY` lines are dispatchable now, `WAIT` names the dependency that is not
   done yet, `HOLD` is needs-human work, `STALL` is a task the gate has already
   established is not moving. Do not re-derive this by reading task files: it is
   dependency arithmetic, it is on disk, and a mistake here dispatches work whose
   dependency is unfinished.
3. **Lint before dispatching.** For each id you are about to send out:

   ```bash
   factory-lint <id>
   ```

   `LINT OK <id>` and you dispatch. Any other line is a defect in the task file -
   a placeholder left in, an id that disagrees with its filename, a dependency
   that is not on the board, an acceptance command that checks nothing. Fix the
   task file yourself and lint again; that costs seconds, while dispatching it
   costs an agent that works from a broken brief and comes back red.
4. **Dispatch.** Up to N tasks in flight. Move the file
   `tasks/backlog/<id>.md` -> `tasks/in-progress/<id>.md`, write `owner`,
   `stage: implementing` and `stage_since` into its frontmatter, then open a fresh
   `factory:implementer` agent with the path. Use `impl-1` .. `impl-N` as the
   `owner` value to identify the slot; it is a label in the task file, not an
   agent that stays alive.
5. **Implementer returns** -> that agent is finished and gone. Check the gate
   before spending an agent on review: `.factory/verified/<id>` exists when
   `gates/verify.sh` went green.
   - **Gate green, task not marked `review: always`** -> run
     `factory-risk <id>` first.
     - Exit 0 -> skip review, go straight to `factory:integrator`. The gate
       already ran build, tests, architecture rules and lint; a reviewer that
       only re-confirms a green gate is a dispatch spent on nothing.
     - Exit 1 -> the task touched a file matching `risk_paths` in the config.
       Dispatch `factory:reviewer`, say the review is for risk, and pass the
       `RISK` lines so it knows which files to look behind.
   - **Gate green, task marked `review: always`** -> dispatch `factory:reviewer`.
     That mark belongs on work the gate cannot judge: security boundaries, tenant
     isolation, auth, money, data deletion, public contracts.
   - **Gate red** -> dispatch `factory:reviewer` and say the gate is red. Its job
     is then diagnosis: what failed, why, what the fix must be. Findings go in the
     task file, then step 8. Exception: if `.factory/no-progress/<id>` exists,
     skip the reviewer too and go straight to step 8 - the gate has already
     established that this failure is not moving, and a reviewer would be
     diagnosing it for the second time.
6. **Reviewer verdict** (only when a reviewer ran):
   - `pass` -> hand to `integrator`.
   - `fail` -> findings are already in the task file; go to step 8.
7. **Integrator** asks `factory-gate-skip check <id>` whether the tree still
   holds the bytes the gate went green on. If it does not - another task landed
   since, or the first run was isolated - it re-runs `bash gates/verify.sh <id>`
   on the tree as it is now. If it does, that run would test the same bytes
   twice, so it is skipped. Either way the file moves into `tasks/done` only with
   a green marker, and the task is recorded as one commit with
   `factory-commit`. The PreToolUse gate rejects the move when
   `.factory/verified/<id>` is absent - that rejection is the system working, not
   an error to route around. A commit that fails leaves the task in done (its
   gate is green) and goes on the uncommitted list of the final tally; never
   commit it by hand.
8. **Red gate or failed review**: append the failing output to the task file,
   increment `retries` in its frontmatter, delete `.factory/verified/<id>` if it
   exists, move the file back to `tasks/backlog`, clear `owner` and set
   `stage: queued`, then re-dispatch. The marker has to go: after a failed review
   it still says green, and the done-guard only checks that a marker exists.
   When `retries` > K, move it to `tasks/blocked` with a `## Blocked reason`
   section and stop retrying.

   **First, check `.factory/no-progress/<id>`.** The gate fingerprints every red
   run and writes that marker when a task fails twice on the identical error.
   When it exists, skip the re-dispatch entirely and block the task now, whatever
   `retries` says. Attempts are the wrong budget: two runs that failed on the same
   error are one attempt made twice, and a third will be too. Put the signature
   path from the marker in the `## Blocked reason` section so the next reader can
   see what the wall was.
9. **Health check.** An agent that returns an error, returns nothing usable, or
   reports it could not proceed: re-dispatch its task to a new agent of the same
   type. Never leave a task in `tasks/in-progress` with no live dispatch. A task
   whose agent failed twice goes to `tasks/blocked`.
10. Print one status line per cycle:
   `ready=N in-progress=N done=N blocked=N | dispatched: <ids> | verified: <ids> | failed: <ids>`

## While agents are running

Do not narrate the wait. When every slot is busy and nothing is ready, end the
turn: the Stop hook checks `background_tasks` and lets the session rest while
agents work, and the harness wakes you the moment one returns. A turn that only
says "still waiting, nothing changed" costs a full request and moves nothing.

## Exit condition

Stop only when `tasks/backlog` and `tasks/in-progress` contain nothing but blocked
or needs-human work. The Stop hook enforces this: if you try to end the turn while
actionable tasks remain and no agent is running, it blocks and tells you to keep
going. Do not fight the hook by emptying directories - satisfy it by finishing the
work.

When you do stop, print the final tally, the blocked list with reasons, the
needs-human queue with what you need from me for each item, and the uncommitted
list - tasks in done whose commit failed, with the reason the integrator quoted.

As the run ends, the Stop hook syncs `.factory/changes/`: every change whose last
task reached done is closed, gets its local ref `refs/factory/<id>-<slug>`, and
is named in a message to me. Nothing is pushed.

A change that carries its own acceptance command does not close on its tasks
alone. When the Stop hook says one is waiting, run it:

```bash
factory-accept <change-id>
```

- `ACCEPT GREEN` - the change closes on the next sync. Say so in the tally.
- `ACCEPT RED` - every task passed alone and the change still does not do what
  it asked for, so the fault is in the seams between them. Quote the failing
  output, leave the change open, and tell me. Do not edit the acceptance
  command to make it pass, and do not open a task to "fix the acceptance" -
  what to do about it is my call.

If it is red and I ask you to find where it broke, `/factory:bisect` searches
the task commits for the first one where a command fails.

## Never

- Never write product code as the lead.
- Never reuse an agent across tasks, and never pass a `name` to the `Agent` tool.
- Never paste the backlog or other tasks into a dispatch prompt.
- Never move a task to `tasks/done` without the verification marker.
- Never widen a task beyond its file.
- Never dispatch a reviewer just to confirm a gate that is already green.
- Never push, and never commit, stash, reset, rebase or switch branches as the
  lead. The one git write in the loop is the integrator's `factory-commit`.

---

## Stage protocol - who owns what, and where it is

Every file in `tasks/in-progress` carries three frontmatter fields. They are not
bookkeeping: /factory:status and the compaction memo read them, and the Stop hook
blocks the session while
any of them is missing.

| field | value |
| --- | --- |
| `owner` | the slot label for whoever holds the task right now, e.g. `impl-2`, `reviewer`, `integrator`. A label in the file, not a live agent |
| `stage` | one of `queued`, `implementing`, `verifying`, `review`, `integrating` |
| `stage_since` | UTC ISO-8601 timestamp, rewritten on every stage change |

Transitions, and who writes them:

1. Lead dispatches -> lead sets `owner: impl-N`, `stage: implementing`, `stage_since: now`.
2. Implementer starts running the gate -> it sets `stage: verifying`, `stage_since: now`.
3. Handed to review, when a review is warranted -> lead sets `owner: reviewer`,
   `stage: review`, `stage_since: now`. A task that skips review moves straight
   from `verifying` to `integrating`.
4. Review passes -> lead sets `owner: integrator`, `stage: integrating`, `stage_since: now`.
5. Task reaches `tasks/done` -> the fields stay as they were; the lane is the truth.
6. Task goes back on a red gate -> lead clears `owner`, sets `stage: queued`, and
   increments `retries` before returning the file to `tasks/backlog`.

Get the timestamp with `date -u +"%Y-%m-%dT%H:%M:%SZ"`. Never guess it.

A stage that has not moved in a long time is a stalled dispatch. When /factory:status
shows one, re-dispatch that task to a fresh agent in the same cycle.

---
