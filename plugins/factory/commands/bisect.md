---
description: Find which task's commit broke a command, by binary-searching the factory's per-task commits
argument-hint: "[optional: the command to test, defaults to the config's test command]"
disable-model-invocation: true
allowed-tools: Read, Grep, Bash(factory-bisect *), Bash(factory-bisect), Bash(git show *), Bash(git log *), Bash(jq *)
---

Find the first task commit where a command fails. Argument (optional): the
command. With no argument it uses `commands.test` from `.factory/config.json`.

The factory records one commit per task, each carrying a `Factory-Task` trailer.
That is what makes this answerable exactly rather than by reading diffs.

1. Run it:

   ```bash
   factory-bisect "$ARGUMENTS"
   ```

   It tests each candidate in a detached worktree built from that commit - the
   working tree is never touched, no branch or ref moves, and uncommitted work
   is deliberately not part of any run. The command runs about log2(N)+2 times;
   that is the whole cost, so say up front roughly how long that will take if
   the suite is slow.

2. Read the result out, do not paraphrase it:
   - `FIRST BAD <sha> task <id>` - name the task, its title, and the task file.
     Then show what that commit changed (`git show <sha>`) and say in one or two
     sentences what in it plausibly causes the failure.
   - `BISECT CLEAN` - it passes at HEAD, so the failure is in the working tree,
     not in history. Check uncommitted changes.
   - `BISECT INCONCLUSIVE` - either the breakage predates the range (widen it
     with `--max`), or it is in a commit with no `Factory-Task` trailer: work
     committed by hand, a merge, a dependency bump.

3. Stop there. Finding it is this command's whole job: do not fix the task, do
   not revert the commit, do not open a task for it. Tell me what you found and
   what the two obvious options are (fix forward, or `git revert <sha>` which
   undoes exactly that one task).

A first bad commit is where to look, not proof of what is wrong: a commit can be
the first to expose a fault an earlier task left behind. Say so if the diff does
not obviously explain the failure.
