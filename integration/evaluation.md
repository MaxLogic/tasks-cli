# Development evaluation

Scope: approved development copies and skill-side project identity. No deployment
or live backlog conversion. The shared working name is `task-ledger`.

## Provenance and retained behavior

Sources read through installed junctions on 2026-09-19:

- `C:/Users/pawel/.codex/skills/create-task` resolves to
  `D:/Pawel/Prompts/skills/create-task`, source version 3.5.0.
- `C:/Users/pawel/.codex/skills/resolve-task` resolves to
  `D:/Pawel/Prompts/skills/resolve-task`, source version 5.2.0.

Source metadata remains in the development frontmatter. Copies preserve task
intent deduplication, vertical slices, expand/migrate/contract, observable
Outcome/Proof, proof-only prerequisites, dependency integrity, discovered-work
selection boundaries, focused/full execution, meaningful RED/GREEN, risk-based
review and separate finding fixes, gate tiers/reuse, exact-candidate final proof,
dirty-work preservation, checkpoint authority, recurring failure diagnosis, and
honest environment gaps. The review, verification and proof-coverage references
derive from those source resources, with SQLite authority wording adapted.

Markdown schema, section moves, archival writers, close_tasks.py and the coupled
state validator are deliberately absent. Session continuity can retain proof
through the existing harness workflow, but it is not a second task ledger.
This is a behavioral adaptation, not a drop-in migration of old run-state JSON.

## Evaluation contract

Use `skills/task-ledger/evals/evals.json` for three bounded workflow cases:
worktree identity/delegation/conflict, exhaustive open selection, and unknown
identity refusal. Run the same prompt and fixtures independently with the
candidate and no skill for the new shared skill. Adapted formulation/execution
comparisons should additionally use immutable pre-edit source snapshots.

The delegation brief requested substantial skill adaptation and executable
identity proof; the worker used Astra Medium for substantial skill adaptation. Token usage
and duration were not reported by tooling and are not estimated. Agent exercise results, when run, must identify
their actual model/configuration and preserve outputs and per-assertion evidence.

## Local evidence

`python -B -m unittest discover -s integration/tests -v` exercises the wrapper
against a real tasks binary and real temporary Git repository/worktree, with
an explicit unique temporary store. The initial pre-implementation run failed
the successful identity/worktree path and unknown-identity diagnostic assertion
because the wrapper was absent. The first three-case implemented run passed.
The final five-case Windows run passed (5 tests, 8.028 seconds), including
caller-relative body paths, untracked identity, non-Git nearest-ancestor identity,
invalid nearer identity refusal, and byte-for-byte unchanged store files after
unknown-identity/override/setup refusals. It used the existing
`target/release/tasks.exe`; selection-contract changes are verified separately
by the Rust implementation work, not by this identity-only test.

The skill creator's `quick_validate.py` passed for all three skill directories.
A relative Markdown link check found no unresolved links. Entrypoints contain
71 lines (create-task), 109 lines (resolve-task), and 99 lines (task-ledger).
These are recorded observations, not size requirements or quality scores.

These deterministic checks prove the helper behavior on the tested platform.
They do not measure skill discovery, autonomous execution quality, or model
improvement. Workflow agent grading and human review remain separate evidence;
no model-quality gain is claimed from static validation or helper tests.

Coordinator follow-up: a sixth helper regression reproduced rejection of a literal
`--project` search term after `--`. The wrapper now distinguishes values and the
end-of-options marker from actual routing overrides; text subprocess decoding is
explicit UTF-8. Six Windows helper tests pass. Model-run baseline/candidate grading
could not be completed: both workers ended with a workspace-credit error and further
worker creation was rejected by the thread limit. The development copies are not
presented as evaluated for model quality or ready for live deployment on that basis.

Final candidate: all six identity tests passed on Windows and native Ubuntu/WSL
against the new release binaries, using separate OS-owned temporary stores.
The executable workflow probe additionally checked priority/readiness, decision
queue, paginated open selection, unlock counts, history, version-conflict refusal
and enrichment. This is CLI workflow proof, not an autonomous-agent comparison.
