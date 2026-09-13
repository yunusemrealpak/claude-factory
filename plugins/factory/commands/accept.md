---
description: Run a change's own acceptance command and record the verdict - a change does not close until it is green
argument-hint: "[change id, e.g. C2]"
disable-model-invocation: true
allowed-tools: Read, Grep, Bash(factory-accept *), Bash(factory-change list), Bash(factory-change sync *), Bash(cat *), Bash(jq *)
---

Run the acceptance command of change `$ARGUMENTS` and record the verdict.

1. With no argument, list the changes
   (`factory-change list`) and take the one marked
   `unverified`. If more than one is, ask me which.

2. Run it:

   ```bash
   factory-accept <change-id>
   ```

3. Report:
   - `ACCEPT GREEN` - close the change:
     `factory-change sync <change-id>`, then tell me it
     is closed and where its summary and local ref are.
   - `ACCEPT RED` - quote the failing output. Every task in this change passed
     its own gate, so this is a seam between them: what they add up to does not
     do what the change asked for. Say what you think the seam is, in two or
     three sentences. Then stop - leave the change open, do not open a task, do
     not touch the acceptance command. What to do about it is my call. If I want
     the commit that broke it, `/factory:bisect` searches the task commits.
   - `ACCEPT NONE` - this change closes on its tasks alone; nothing to do.

Never edit the command in `goal.md` to make it pass. It is the thing I approved
the change against.
