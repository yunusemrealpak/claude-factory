---
description: Build the approved task list - one deterministic preflight, then the factory loop workflow (a fresh builder per task, a check and a settle per task, one full check at the end)
argument-hint: "[change id, e.g. C2]"
disable-model-invocation: true
allowed-tools: Bash(factory-preflight), Bash(factory-preflight *), Workflow(factory:loop), Read
---

Run the factory in this project. Argument (optional, a change id such as `C2`):
$ARGUMENTS

You make two calls: one Bash call, then one Workflow call. Everything else
belongs to the loop and its scripts - do not read the board, the task files or
the code, do not move a task, and do not fix anything yourself. What happens to
each task is decided on disk by the factory's scripts, not in this session.

1. **Preflight.** From the project root run

   ```bash
   factory-preflight --json
   ```

   adding `--change <id>` only when the argument is a change id (`C` and
   digits). It prints one JSON object on one line: the plan. Before it prints,
   it has already settled the board - answered questions back to the backlog,
   needs-human and unlintable tasks blocked with a question in the inbox, the
   approvals committed.
   - `"ok": false`: print each of its `problems`, and its `notes`, as one line
     each, and stop. Do not work around a problem: each one is mine to settle
     (`.factory/STOP`, uncommitted work above autonomy level local, an id
     collision, a breaker, an approval that changed).
   - `"ok": true` with an empty `tasks` and an empty `owed`: say there is
     nothing to build, print `held` as `id: reason` lines, and stop.
2. **Loop.** Call the Workflow tool with `name: "factory:loop"` and `args` set
   to that JSON object, exactly as printed - parse it and pass the object, with
   nothing edited, shortened or re-ordered. If the tool says there is no such
   workflow, use the one this plugin ships named `loop`. Then wait: no Monitor,
   no polling, no narration while it runs - every wake-up of this session
   re-reads its whole context.
3. **Report.** When the workflow returns, print at most ten lines: its `line`;
   its `halted` and `audit` when present; the plan's `notes` and `warnings`; and
   the report path, `.factory/last-run.md`. Nothing more - the report has the
   details, the dashboard (`open .factory/dashboard.html`) the live state.

Questions the run raises go to the inbox (`factory-ask list`), not to this
session; answer them with `factory-ask answer <Qn> "<answer>"`, and the next
`/factory:run` picks the task up with the answer in its file. A run that
halted - the quota, `.factory/STOP`, the infrastructure - is continued by
typing `/factory:run` again: it keeps the base the first one had.

If this session has no Workflow tool (a Claude Code too old for workflows), say
so and stop: the loop needs it.
