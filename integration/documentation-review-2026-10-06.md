# Documentation review, 2026-10-06

Scope: README, installation and workflow guides, root/viewer specifications,
viewer design, remote CLI/viewer/server guides, and the introductions to dated
verification and migration records. Existing untracked research and unrelated
files were preserved. Dated deployment logs retain their original observations.

## Changes

- Explained shared worktree identity, bounded reads, version-checked edits,
  history, optional remote access and architect-led coordination in the README.
- Reconciled project schema 8, server catalog schema 2, seven statuses,
  `needs-human` filtering and required initialization keys with source.
- Distinguished readiness (`done` or `to-verify` prerequisites) from the
  explicit done-transition guard (`done` or `cancelled` prerequisites).
- Clarified that strict bulk-import preflight is separate from independently
  committed project imports; there is no cross-project transaction.
- Replaced stale candidate/future descriptions in current remote guides with
  links to the dated deployment and cutover records.
- Corrected viewer open statistics and announcement/recovery descriptions.
  Recorded the owner's NVDA confirmation, retaining historical test evidence.
- Added the MIT license and Cargo license metadata, source installation
  instructions, public archive recommendations and a two-worktree walkthrough.
- Documented proposals for ownership, claiming, leases and planning fields.
  They remain proposals; the task model and schema were not changed.

macOS has not been built or tested because the maintainer has no machine for it.
No public release, installer or download URL is claimed.

## Verification

The disposable walkthrough ran against both installed native binaries reporting
`tasks 0.1.0 (commit 1d6196a0fbfb)`. There are no Rust source, test or lockfile
differences between that embedded commit and the pre-edit HEAD `15e5c82`.
The only Cargo change in this documentation batch is the MIT license field.

Each platform run executed 38 subprocess commands, including Git setup. Fresh
explicit data roots prevented access to the real backlog. A native SQLite read
confirmed schema 8. Two actual Git worktrees selected the same UUID and versions.
The probes verified runnable selection, stale-write exit 4 without a history
event, dependent readiness after to-verify, completion refusal with exit 2,
ordered closure, and the cancelled-prerequisite distinction. No engineering
implementation or product regression suite is claimed by this fixture.

Evidence root:
`target/evidence/docs-review-8b5450e45a5e4f55a13e161c7dacde11/`.

- Windows: `windows/commands.json`, `windows/summary.json`.
- Native Linux: `linux-commands.json`, `linux-summary.json`; original fixture
  under `/tmp/tasks-docs-review-8b5450e45a5e4f55a13e161c7dacde11`.
- Documentation links and added-prose punctuation: `document-check.json`.
- `cargo metadata --no-deps --locked --format-version 1` reports `license: MIT`;
  Cargo.lock is unchanged. `git diff --check` passes.

The fixtures are retained for inspection. No installed executable, server,
live task store, harness configuration or task lifecycle record was changed.
