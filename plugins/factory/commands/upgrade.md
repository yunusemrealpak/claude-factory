---
description: Bring this project's factory files up to the current harness - config, directories, gitignore, task sections, and a report on the gate
disable-model-invocation: true
allowed-tools: Read, Grep, Bash(factory-upgrade), Bash(factory-upgrade --apply), Bash(factory-version), Bash(jq *), Bash(grep *)
---

Check whether this project is still running what the current factory writes, and
bring it up to date.

The hooks, commands and agents live in `~/.claude` and are shared, so those are
always current. What is not current is everything `/factory:init` wrote **into**
this project: `gates/verify.sh`, `.factory/config.json`, the task file layout,
`.gitignore`. A project set up by an older factory keeps running the older gate,
and nothing about that is visible from the board.

1. Report first, change nothing:

   ```bash
   factory-upgrade
   ```

   Show me its output as it is. `UPGRADE NONE` means the project is current -
   say so in one line and stop.

2. If there are gaps, say what each one costs me before touching anything:
   - a missing config key means the feature that reads it is inert here
     (`gate_isolation` without `isolate` in the gate, `risk_paths` with no
     patterns means no green task is ever reviewed)
   - a missing `.factory/` directory means that record is not kept - no
     questions inbox, no lessons, no change archive
   - a task file with no `## Files touched` cannot be committed by
     `factory-commit`: the commit takes exactly those paths
   - a gate missing a guard is the serious one. Name what each absent guard
     would have caught, in one line each.

3. Ask me before applying. On my yes:

   ```bash
   factory-upgrade --apply
   ```

   This only adds: missing config keys at their defaults (an existing value is
   never overwritten), missing directories, missing gitignore lines, missing
   task sections. It never rewrites the gate, a config value, or a task body.

3b. **The `check` block.** If `.factory/config.json` has none, `/factory:fast`
   judges every task by running the whole suite. Read the project's structure -
   the packages, projects or modules its own build tool declares - and propose
   a `check` block as `/factory:init` Step 2 describes it: `units` with their
   paths, dependencies and test commands, a `format` command, and a `count`
   regex if the runner's summary needs one. Show it, and write it only on my
   yes. Never guess a dependency the project does not declare.

4. **The gate is not touched by `--apply`.** If the report says
   `STILL BEHIND - gates/verify.sh is missing: ...`, tell me that the fix is to
   run `/factory:init` in this project: it reads the existing gate, reports
   which protections it lacks, and merges in only the missing parts once I
   approve - keeping everything project-specific the file already does. Do not
   edit `gates/verify.sh` yourself in this command.

5. Finish with the version line: what the project was on, what the harness is
   now (`factory-version`), and whether the stamp was
   updated. The stamp only moves when the gate is current too.
