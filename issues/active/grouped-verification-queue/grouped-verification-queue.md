# Batch verification: a `to-verify` status

Status: approved for implementation, 2026-09-27. Minimal version; replaces the
earlier verification-tracking proposal.

## Problem

Agents run expensive broad suites once per task. In one DelphiAIKit run a
1,216-test suite took 27 minutes and was repeated at intermediate checkpoints.
The causes are instructions, not missing CLI features: task Proof sections
demanding "full suite passes", a skill rule to rerun after shared-infrastructure
changes, and project AGENTS.md cadence rules. Those are fixed separately in the
skills and AGENTS.md files.

What the CLI lacks is a way to mark "implemented and focused-tested, waiting for
the group's broad gate", so the agent can move on and later pick up the whole
group in one query.

## Workflow

1. Implement a task, run its focused tests, set it to `to-verify`.
2. Continue with the next task. It may depend on a `to-verify` task.
3. At the group boundary: `tasks list --status to-verify`, run the broad gate
   once for all of them.
4. Pass: move each to `done` in dependency order, with one Notes line naming the
   gate command, exit code and test count. Fail: move only the affected tasks
   back to `in-progress`.

A single low-risk task with no scheduled batch gate still goes straight to `done`.

## CLI change

- Add status `to-verify`. Statuses become draft, todo, in-progress, to-verify,
  blocked, done, cancelled. It is nonterminal.
- Readiness: a prerequisite in `to-verify` counts as satisfied for the default
  `list` and for `unlocks`. `done` is still required everywhere else.
- Completion guard: `update --status done` fails (exit 2, nothing written) while
  any prerequisite is nonterminal (draft, todo, in-progress, to-verify, blocked).
  Done and cancelled prerequisites do not block. This is the first refused
  transition; all others stay allowed.
- Default `list` does not show `to-verify` tasks (they are not runnable work).
  `--open` and `--status to-verify` do.
- Schema migration: the status CHECK constraint needs a table rebuild through
  the existing `migrate` path, with a verified backup first. Older binaries must
  refuse the new schema as they do today.
- Markdown import/export, the import status map, JSON output, `bulk-import`
  classification and the viewer (display and filter) accept the new status.
- Update spec.md with the status, readiness rule and guard.

No new tables, commands, groups, fingerprints or check tracking.

## Skills (after the CLI ships, not before)

- task-ledger: add the status, the readiness rule and the guard.
- resolve-task: task loop step 6 moves a task to `to-verify` when a batch gate is
  scheduled, `done` otherwise; the batch tier starts from
  `list --status to-verify`.
- create-task: no change beyond the Proof rule already added.

## Proof

- Store tests on temporary databases: migration from the current schema with
  a backup; readiness with a `to-verify` prerequisite; the done guard refusing
  with a `to-verify`/`todo` prerequisite and allowing done/cancelled ones;
  `--status to-verify` and `--open` listing.
- CLI end-to-end: three dependent tasks taken through
  in-progress → to-verify → done, and the guard's exit code.
- Import/export round trip with a `to-verify` task.
- Viewer shows and filters the status.
- Standard gates on Windows and Linux per AGENTS.md; Linux delegation checked
  with the real binaries.

## Out of scope

Recording checks, runs, coverage or input fingerprints in SQLite; cross-project
verification groups; stale-evidence detection. Proof stays in session notes and a
one-line Notes entry. Reconsider only if repeated broad runs persist after this.
