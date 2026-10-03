# Server refactor progress

## Scope and gates

Approved contract: spec.md, Rust server and automatic attribution extension.
Ledger: TSK-021 through TSK-027, corresponding to implementation slices 1-7.
Focused proof per slice; broad Windows/native Linux gate after TSK-025, final
after TSK-027. Do not install candidates or migrate live stores during this work.

LAN HTTPS is owned by the user's other thread. Reuse its Caddy gateway; QTS
keeps NAS administration. Stale Audiobookshelf rule removal was verified by SSH
on 2026-10-03. Docker stays at the current version. NAS deployment proof remains
pending, including strict TLS and final backend isolation checks.

## TSK-021: persisted mutation attribution

Schema 7 adds nullable attribution to existing task/rules events and separate
append-only metadata history for project creation, key changes and import
provenance. Caller context is validated and serialized before transactions.
Default context reports unknown/unavailable fields until collection is added in
TSK-022. No task versions or task event IDs are consumed by metadata changes.
Identical rules are a no-op after the optimistic version check. JSON/text task
history exposes context; `project-history` provides bounded metadata pages.
Migration preserves legacy snapshots and leaves their authors null. Existing
binaries reject schema 7, so no live backlog has been migrated.

### Proof, 2026-10-03

- Durable RED: initial two tests failed on missing context column and metadata
  table. Two further tests failed on identical rules incrementing their version
  and missing zero-task import provenance. Logs:
  `target/evidence/server-refactor/attribution-red.log` and
  `attribution-import-noop-red.log` in the same directory.
- Four additional characterization cases cover schema-6 migration/verified
  pre-upgrade backup, supplied context and bounded history/CLI rendering/backup,
  version conflicts/no-op writes/audit insert failure rollback, and import
  atomicity. They are not claimed as original RED cases.
- Owning suite: attribution, history, migrations, mutations, import_batch,
  project_keys, states and recovery: 53 tests pass on Windows and native WSL
  Linux, zero failures/ignored tests. Logs:
  `target/evidence/server-refactor/attribution-windows-final.log` and
  `attribution-linux-final.log` in the same directory.
- Windows target: `target/server-candidate`; Linux target:
  `~/.local/share/tasks-cli/target/server-candidate`. Linux tests use unique
  `/tmp/tasks-attribution.*` roots and unset Windows delegation for native proof.
- `cargo fmt --check` and focused `cargo clippy --locked --lib --target-dir
  target/server-candidate` passed. Clippy log:
  `target/evidence/server-refactor/attribution-clippy.log`.
- Initial owning-suite failures were stale fixture schema expectations and
  incomplete simulated downgrades, corrected without weakening preservation
  assertions. The first Linux run inherited Windows delegation; its failure is
  retained in `attribution-linux-green.log`. The native rerun passed.

### Local review

Checked every production history insert: task create/update, rules, batch import
task/rules events, zero-task provenance, project create and key change. Refused
writes/no-op operations do not append; triggered audit failures roll back data,
versions and task counter. Migration and current-schema validation include all
new audit objects; backup uses SQLite's complete online snapshot. SQL paging
limits rows before deserialization and caps metadata pages at 100.

No independent agent review: exposed delegation uses only the priority tier,
which this repository prohibits. This is coordinator review, not independent
certification. Broad server gates remain scheduled after slices 1-5.
