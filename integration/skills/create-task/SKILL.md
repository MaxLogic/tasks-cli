---
name: create-task
description: "Add, split, reword, reprioritize, block, complete, or otherwise maintain durable tasks in a shared SQLite backlog. Use for requested task management and independent follow-up or prerequisite work. During resolve-task, own formulation while the coordinator applies ledger edits. Do not invoke merely because a backlog exists."
metadata:
  author: Pawel Piotrowski
  version: "4.2.0"
  adapted-from: "D:/Pawel/Prompts/skills/create-task (3.5.0)"
---

# Create Task

Read [task-ledger](../task-ledger/SKILL.md) for identity, bounded reads,
versioned writes, field semantics, and coordinator ownership. Load project rules
once per session (`rules show` or `show --rules`) and relevant repository/spec
guidance before editing. Never bootstrap or migrate
to make a helper work. SQLite owns lifecycle and task IDs; do not run the old
Python Markdown ledger helpers or update an exported TASKS.md.

Record work when requested, required by repository policy, or when an independent
follow-up/prerequisite must survive the session. A self-contained change being
completed now does not need invented bookkeeping. Search existing intent,
including completed tasks, and show likely matches (several IDs in one `show`)
before creating a duplicate.
Update the task that already owns the outcome.

## Formulation

Make each task understandable and reviewable on its own. Prefer narrow vertical
slices that deliver observable behavior through every required layer. Split
different outcomes, dependencies, proof, or risks; keep one coherent transaction
together when splitting would weaken validity or rollback. For a migration that
cannot remain green in vertical slices, use expand, migrate, contract with real
dependency edges. An unsettled material design goes through the repository's
design workflow, not an arbitrary spec fragment to reduce context.

Write an imperative title and a body with required fields:

```text
Outcome:
- <observable condition>
Proof:
- Run: <exact executable command>
  Expect: <exit code, output, result, or measured condition>
```

Proof names targeted checks only: the exact new or changed tests, the owning
fixture or module, and a compile of the changed surface. Never write "full suite
passes", "all tests green", a full build or project-wide analysis into a task's
Proof or Outcome. Those run once per group of tasks at the batch and final gates
that resolve-task schedules. A task that genuinely needs a broad run (it changes
the test runner, build graph, shared runtime or public contract) states that as
`Cadence exception: <command> because <reason>`.

Include only useful optional fields: Touches, Parent, Verify, Review, Expected
gate cost, Risk, Production changes (`allowed` or `proof-only`), and Notes.
Manual proof must be named honestly. Use ordinary, specific prose; preserve
user terminology, commands and exact quotations. Keep durable approved
decisions, blockers and concise source/proof pointers in Notes. Replace stale
notes rather than appending a session transcript or raw logs.

Set priority P0-P3, default P2, and existing-vocabulary labels through structured
CLI fields. Use dependencies only for same-project IDs that truly must complete
first. Do not place reasons, ranges or external project IDs into dependency
arguments. Write task references in bodies and notes as `KEY-N` (for example
`DAK-212`, or another project's `DS-640`); keep existing `T-N` text as
written. A parent groups work and is not automatically a dependency.
Let SQLite assign IDs. Pass bodies with `--body-file -` and a heredoc. Use
`show` for content you rewrite, then `update --expect-version`; a status-only
change can use the listed version. The write output reports the committed
version, so skip a verifying `show`. Never silently retry conflicts.

Resolve-task chooses batch and final cadence for the selected run. A proof-only
task that finds missing behavior creates a defect
prerequisite; it does not quietly absorb a redesign. Completion requires actual
acceptance/proof, not a progress label. Archived Markdown is migration input or
an export, not live authority; do not archive merely because work is complete.

## Discovered work

Record clear follow-up without asking the user to choose an ID or restate the
goal. During resolution, necessary prerequisites join before their dependents;
matching semantic work joins the current selection; under "all open tasks", new
open work joins too. Unrelated follow-up remains outside an explicit-ID or
semantic run. Update the active plan once and continue. Pause only when the
discovery materially changes the goal, architecture, external effects, or risk.
