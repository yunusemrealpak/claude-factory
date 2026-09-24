---
description: Run the factory's own test suite - hooks, gate template, dashboard, commit model - in a sandbox
disable-model-invocation: true
allowed-tools: Bash(factory-selftest), Bash(factory-selftest *), Read
---

Run the factory harness against itself:

```bash
factory-selftest
```

This touches no project. Every suite builds its own sandboxes - throwaway git
repositories, task boards and gates - under one temporary directory, and that
directory is removed when the run ends.

What it covers:

| suite | what it proves still works |
| --- | --- |
| 1 | task ids, changes opening/syncing/closing, the per-task commit, the run claim, the done-guard, the Stop gate |
| 2 | risk routing, lessons and their evidence gate, attempt notes, the retrospective's sections, gate isolation |
| 3 | the event log, the dashboard, the question inbox, the status line segment, the end-of-run message |
| 4 | skipping the integrator's duplicate gate run, the task lint, the ready set |
| 5 | change-level acceptance, the commit bisect, the version check that spots a project running an older factory |
| 6 | the fast lane on a project in no language: units and reach, the per-task census, waiting on another task's unlanded work, parking a blocked task's work, the guards and no-progress rule, the full check's zero-test refusal and run census, the graph measure, plan/start/land/block/finish, generated files in risk routing, the `/factory:fast` scheduling - recheck, review after landing, the seam audit, the report from disk - and the classic gate's fingerprint and count fixes |

Report:

1. The version line and the totals (`TOTAL passed=N failed=N`).
2. Every `FAIL` line verbatim, with the suite it came from. A failure names the
   behaviour that broke, not a file - read the suite to find which script it
   exercises before touching anything.
3. If everything passed, say so in one line and stop. Do not summarise the
   suites back to me.

Run this after changing anything under `the plugin's hooks/` or in the gate
template inside `/factory:init`: the suites are the only thing standing between
an edit to a hook and a project whose board silently stops being enforced.

`FACTORY_KEEP=1 factory-selftest` keeps the sandboxes when
a failure needs looking at, and `factory-selftest 3` runs a
single suite.
