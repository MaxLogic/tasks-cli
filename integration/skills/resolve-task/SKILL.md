---
name: resolve-task
description: "Resolve explicitly selected engineering tasks from a shared SQLite backlog. Use for named task IDs, selected backlog items, or a requested task sweep. Apply acceptance-driven implementation, focused TDD, risk-based verification, exact-candidate proof, and versioned lifecycle transitions."
metadata:
  author: Pawel Piotrowski
  version: "6.3.2"
  adapted-from: "D:/Pawel/Prompts/skills/resolve-task (5.2.0)"
---

# Resolve Task

Read [task-ledger](../task-ledger/SKILL.md) for identity, queries and mutations,
and [create-task](../create-task/SKILL.md) when formulating or changing task
intent. The coordinator owns every shared-ledger transition. SQLite owns durable
intent/status; session notes own proof and current execution, never another
editable backlog. This skill does not use the Markdown-ledger Python
helpers or their coupled state-transition/close helpers.

## Start and selection

Use focused mode for one low/medium-risk task; full mode for multiple tasks,
backlog sweeps or high-risk changes. Read repository guidance, rules, relevant
specs and nearest tests. Resolve identity before any access. Fetch bounded rows
(text output), then selected bodies, versions and prerequisites in one
multi-ID `show`; add `--rules` once per session. IDs may be written `KEY-N`,
`T-N` or `N`; cite them as `KEY-N` in new notes and commit messages and leave
old `T-N` text unchanged. Explicit IDs include necessary
prerequisites; semantic selections include matching work plus prerequisites;
"all open" requires `list --open` with every page, including blocked/human work.
Normal runnable list alone cannot establish that a sweep is complete.

Preserve settled decisions. Re-plan only for a demonstrated contradiction,
infeasibility or material risk outside the approved outcome. Respect human gates
and dependencies; do not remove needs-human merely to make work runnable.
Use priority and unlock counts to order otherwise ready work.

Inspect the live dirty tree. Preserve unrelated changes and never revert an
ambiguous patch. Use the current checkout unless a prepared isolated workspace
is authorized; do not create a worktree automatically. In a prepared worktree,
verify tracked identity plus required untracked/ignored local guidance. Never
initialize another task store for that worktree.

Establish a focused baseline. In full mode, record the task/batch/final schedule,
candidate paths, selected IDs and dependency order, risk/reviewer specialty and
production-versus-proof-only limits before implementation. Use existing session
continuity if available; no new state schema or mandatory helper is introduced
by this copy. Without recoverable session proof, use the same checklist directly
and rerun evidence that cannot be recovered. Never invent a command or result.

Name every non-functional acceptance gate (performance ratio, latency, memory,
size, packaging) at planning time, with the assumption each rests on. Once the
seam it depends on exists, usually after the first slice, measure that
assumption with the cheapest end-to-end probe instead of waiting for the Final
tier. A probe that predicts failure for a cause outside the authorized scope is
the demonstrated infeasibility that justifies re-planning: record a needs-human
decision task with the measurement immediately and continue independent work.
See [verification](references/verification.md).

## Task loop

1. Read current task/version and deps. Coordinator transitions ready work to
   `in-progress` with the observed `--expect-version` (no extra `show` for a
   status-only change); exit 4 means stale, so re-read and reconcile.
2. Extract acceptance from Outcome, Proof, rules/specs and notes. Each outcome
   needs observable proof. Split independently provable work before coding;
   retain a reason when a large change is indivisible.
3. Add meaningful failing proof for behavior slices, implement GREEN, and run
   cheap stabilization. Report TDD as yes, mutation, partial, or no with reason.
   Reversible prose edits need relevant validation, not artificial RED tests.
4. Self-check risk, then request independent review when justified. Review after
   GREEN before broad task gates. Each confirmed must-fix is a separate
   RED/GREEN slice returned to its owner, followed by affected proof/re-review.
5. Freeze the source and proof inputs; record real candidate identity, hashes
   where used, literal commands, exit codes, test counts and proof references.
   Run the task tier on those inputs. Zero selected tests do not prove behavior.
6. Coordinator checks acceptance and review, then transitions to `to-verify`
   while a required batch or delivery-dependent gate remains, `done` after
   applicable task proof otherwise, with the last observed version. The write
   output is the committed result; do not issue a read-back `show`. A stale
   version (exit 4) is re-read and reconciled, never
   overwritten with an automatic retry. Keep concise proof pointers in Notes.
7. Inspect the exact owned patch, clean owned temporary artifacts safely, and
   continue only with dependency-ready work. Archive only when requested.

Necessary discovered prerequisites join the active run; semantic matches and
new tasks under "all open" join it too. Record unrelated independent follow-up
without expanding explicit-ID scope. A proof task finding missing production
behavior creates and resolves a defect prerequisite before rerunning proof.

## Verification and review

Read [verification](references/verification.md) for task/batch/final gates,
evidence reuse, environment gaps and exact-candidate completion. Read
[reviews](references/reviews.md) for medium/high-risk changes and independent
review packets. The repository can require stronger checks.

In parallel work, give each worker UUID/task/version, relevant rules/body,
owned files, allowed actions, proof and stopping condition. Workers return proof
and patches, never ledger writes. Avoid overlapping source edits and shared
build outputs. Coordinator integrates and owns broad gates. Reconcile partial
patches and worker liveness on resume; do not assume an old worker still runs.

On first failure diagnose and make one focused correction. On a second recurrence
stop patching and recheck hypothesis, contract/environment and inputs. Use
systematic debugging for unexplained/flaky failures. On a third cycle without
new evidence, coordinator records `blocked` plus concrete cause, last evidence
and smallest unblock action. Retry external blockers only on new evidence,
explicit request or a scheduled requirement; continue independent work.

## Delivery

After each reviewed slice with all applicable pre-commit proof passing, use
`git-operations` to stage exact owned paths, inspect the staged patch and create
a local commit without asking for approval. Required task and batch gates
normally precede that commit. Only when a gate intrinsically requires a
committed or pushed candidate may a reviewed, locally proven slice be committed
before that gate. Keep affected tasks `to-verify` and run the post-delivery gate
before marking them `done`. A failed pre-commit gate, missing tool or environment
gap does not qualify for this exception. Respect an explicit user prohibition
on commits and preserve unrelated work. Do not stage junction-linked skills or
unrelated generated content.
This commit rule grants no push or deployment authority; follow the repository's
separate rules for those actions.

Before final proof, reconcile every selected task and ledger transition, stop
or account for active workers, and materialize one exact delivery candidate.
Run required final gates against that candidate. Do not combine results from a
clean live tree and a different staged tree. A failure or required environment
gap leaves affected acceptance unproven. Report closed criteria, remaining
blockers/risks, native results and evidence limits; task counts or artifact counts
are not acceptance. No selected task stays `in-progress` without active work.
