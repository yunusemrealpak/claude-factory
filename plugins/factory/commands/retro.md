---
description: Retrospective on the factory itself - cluster recorded failures into mechanisms and propose minimal harness changes for approval
argument-hint: [project dir, defaults to cwd]
---

# Factory retrospective

The factory records every red gate, every stalled task and every retry. This
command reads that record and asks one question: **what should change in the
harness so these failures stop happening?**

Not what should change in the code. The harness - the agent prompts, the gate,
the task template, the config, the project CLAUDE.md. A task that failed is a
task; the same failure across three tasks is a defect in the machine that
produced them.

## Why this is worth a command

An agent's harness can be improved from its own execution traces without
touching the model: cluster failures by root mechanism, propose one minimal
edit per mechanism, keep only what survives a check. Published results for that
loop are large - held-out pass rates going from 40.5% to 61.9%, 23.8% to 38.1%,
42.9% to 57.1% across three model families. The expensive part of that loop is
the evidence, and the factory has been collecting it all along.

## Step 1 - Collect

```bash
factory-retro $ARGUMENTS
```

Read the digest. Do not read the raw logs it summarises unless a specific
cluster needs a line you cannot get from the digest - the whole point of the
collector is that you do not have to.

If a previous retrospective exists, read the most recent one now, before
forming any opinion. A proposal that was already made and rejected must not
come back as if it were new, and one that was applied needs its effect checked
rather than its text repeated.

## Step 2 - Cluster by mechanism, not by text

Identical signatures are already grouped for you: the gate hashes each red run's
normalised error lines, so `2 red run(s) | 1 task(s)` means the same wall twice.
Your work is the level above that - grouping distinct signatures that share a
cause.

Two signatures belong to one mechanism when the same harness change would have
prevented both. `error CS0246: type or namespace not found` in three different
modules is one mechanism (the implementer is not being told where contracts
live), not three failures.

Rank mechanisms by **breadth first, then cost**: a signature spanning several
tasks is the harness failing repeatedly; a signature that hit one task five
times is one hard task. Breadth is the stronger signal that something in the
machine is wrong.

Say plainly when the evidence is thin. A digest with four red runs in it does
not support five proposals, and inventing them is worse than reporting that the
run was clean. **Zero proposals is a valid and useful outcome.**

## Step 3 - Propose

At most five proposals. Each one is tied to exactly one mechanism, and each one
names the smallest surface that fixes it:

| surface | file |
| --- | --- |
| what an agent is told | `this plugin's `agents/`` |
| what the gate refuses | `<project>/gates/verify.sh` |
| how tasks are written | `/factory:init` |
| how the loop routes | `/factory:run` |
| limits, commands, isolation, risk paths | `<project>/.factory/config.json` |
| project-specific rules | `<project>/CLAUDE.md` |
| what one module's tasks must know | `<project>/.factory/lessons/<module>.md` - Step 3b, not here |

Rules for a proposal:

- **One mechanism, one surface.** A proposal that edits three files is three
  proposals, or it is not understood yet.
- **Minimal.** The change is the smallest one that addresses the diagnosed
  cause. Rewrites are not proposals, they are new designs.
- **Falsifiable.** State a number from this digest that should move, and by
  roughly how much. The next retrospective checks it. "Should improve quality"
  is not a proposal; "the 23% retry rate should fall below 15%, and
  `GATE build: FAIL` should stop being the top signature" is.
- **Evidence attached.** Name the signature hashes and task ids it came from.
  A proposal with no trace behind it is an opinion, and opinions do not belong
  in a retrospective built on records.

Two things are explicitly out of scope. Do not propose raising `workers` or
`max_concurrent_agents`: those are set where they are for the machine's sake,
not by accident. Do not propose new instructions for an agent prompt that
already says the thing - check first, and if the rule exists but is not being
followed, that is a different diagnosis with a different fix.

**Red runs naming another task's files.** When the digest's "Red runs naming
files outside the task's own list" section shows paths that are `also listed
by` another task, the gate was most likely judging one task by another's
half-written work. The proposal for that mechanism is `"gate_isolation": true`
in the config - plus `isolation_links` for what the stack needs to build
without reinstalling (`node_modules`, a `.venv`). A path `listed by no task` is
different: usually the task broke a file it did not list, which is an
implementer finding, not an isolation one.

## Step 3b - Lessons

Separately from the harness proposals, propose at most five **lessons**. A
lesson is a project fact an implementer would have needed before starting:
"`dotnet test` needs `--filter Category!=Integration` unless the compose
database is up", "new handlers are registered in `Modules/<X>/Registration.cs`".
Its material is the digest's "Red tasks that went green" section - the
`resolved by` lines - and signatures that span several tasks.

- **Evidence or nothing.** Name the task ids and `sig-<hash>` it came from. The
  script that writes lessons refuses evidence that is not on disk.
- **A rule for the next task, not a story about the last one.** Imperative, one
  line, at most 200 characters. "C2-03 failed because..." is history, not a
  lesson.
- **Scoped.** Name the module it applies to - the `module` of the tasks it came
  from - or `general` only when it truly holds across the repo. A lesson is
  read by every task of its module; each one costs all of them attention.
- **Not already said.** Check the "Lessons in force" section, the project
  `CLAUDE.md` and the agent prompts first.
- **Lessons that did not work.** A lesson in force whose evidence signature
  still has red runs since it was added did not do its job: propose rewording
  or retiring it, not a second lesson next to it.

## Step 4 - Write it down, change nothing

Write the report to `<project>/.factory/retro/<YYYY-MM-DD>.md`:

```markdown
# Retrospective <date>

Evidence: <n> red runs across <n> tasks, <n> distinct signatures, retry rate <n>%.

## Mechanism 1 - <one line name>
Signatures: <hashes>  Tasks: <ids>
What actually happens: <two or three sentences, from the evidence>

### Proposal
Surface: <file>
Change: <the specific edit>
Expected: <the number that should move, and where it stands now>

## Mechanism 2 - ...

## Lesson proposals
- L1 [module: <module>] <the lesson, one line> - evidence: <task ids, sig-hashes>
- L2 ...

## Checked from the previous retrospective
- <proposal from last time>: <did the number move? by how much?>
```

Then show me the mechanisms, proposals and lesson proposals in the terminal,
compactly, and stop.

**Apply nothing.** Not the small ones, not the obvious ones. Harness edits that
an agent writes into its own instruction files without a human reading them make
things worse - measured, in one study, at roughly 3% lower success for 20% more
cost. The value here is in the diagnosis; the approval is what makes it safe. I
will tell you which proposals to apply.

## Step 5 - Only after I approve

Apply exactly the proposals I named, as written in the report - if I change
one, apply my version.

Each approved lesson goes in with the script, one call per lesson, its text
verbatim:

```bash
factory-lesson add <module> <evidence> "<lesson>"
```

`<evidence>` is comma-separated without spaces, e.g. `C2-03,sig-4f1a9c0e2b7d`.
If the script refuses - evidence not on disk, text too long, module file full -
show me its message and wait: a full file means I pick a lesson to retire
(`factory-lesson list <module>`, then `remove <module> <number>`), never you.
Never write to `.factory/lessons/` any other way.
