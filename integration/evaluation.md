# Skill evaluation and deployment readiness

Scope: product-owned SQLite task skills and direct CLI project identity. The
shared access skill is `task-ledger`.

## Provenance and retained behavior

Sources read through installed junctions on 2026-09-19:

- `C:/Users/pawel/.codex/skills/create-task` resolves to
  `D:/Pawel/Prompts/skills/create-task`, source version 3.5.0.
- `C:/Users/pawel/.codex/skills/resolve-task` resolves to
  `D:/Pawel/Prompts/skills/resolve-task`, source version 5.2.0.

Source provenance remains in the product skill frontmatter. The adaptations preserve task
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

`python -B -m unittest discover -s integration/tests -v` exercises the tasks
binary directly against a real temporary Git repository/worktree, with an
explicit unique temporary store. The current six-case suite covers
caller-relative body paths, direct nearest-ancestor identity, invalid nearer
identity refusal, explicit override, and byte-for-byte unchanged store files
after an unknown identity. It passed against the native Windows release binary
and the native Ubuntu/WSL release binary selected through `CARGO_TARGET_DIR`;
`TASKS_TEST_EXE` remains available for an exact candidate path. Selection
details are also covered by the Rust implementation tests.

The skill creator's `quick_validate.py` passed for all three skill directories.
A relative Markdown link check found no unresolved links. Entrypoints contain
71 lines (create-task), 109 lines (resolve-task), and 99 lines (task-ledger).
These are recorded observations, not size requirements or quality scores.

These deterministic checks prove the helper behavior on the tested platform.
They do not measure skill discovery, autonomous execution quality, or model
improvement. Workflow agent grading and human review remain separate evidence;
no model-quality gain is claimed from static validation or helper tests.

The sixth identity regression also preserves a literal `--project` search term
after `--`; direct CLI parsing keeps the end-of-options marker separate from
routing overrides, and subprocess decoding is explicit UTF-8. Six Windows and
six Ubuntu/WSL identity tests pass.

Three bounded model exercises covered worktree identity and conflicts,
exhaustive open-task selection, and unknown-identity refusal. The candidate
answer satisfied all 14 rubric assertions. The comparison baseline lacked
direct identity discovery, paginated open selection, and SQLite versioned-write
semantics, but its run accidentally exposed expected outputs while loading the
fixture. Treat that baseline as contaminated: it supports a qualitative gap
assessment, not a blind score or a measured model-quality gain. Both exercises
used independent workers; no production backlog was mutated.

Final candidate: all six identity tests passed on Windows and native Ubuntu/WSL
against the new release binaries, using separate OS-owned temporary stores.
The executable workflow probe additionally checked priority/readiness, decision
queue, paginated open selection, unlock counts, history, version-conflict refusal
and enrichment. This is CLI workflow proof, not an autonomous-agent comparison.

On 2026-09-21 the three skills were deployed as direct product-repository links
for Codex, Claude and Copilot on Windows and Ubuntu/WSL. The previous
`create-task` and `resolve-task` links were retained under dated rollback names.
