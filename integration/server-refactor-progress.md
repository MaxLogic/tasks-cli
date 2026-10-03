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

## TSK-022: context collection milestone

OS account/host, exported harness/session IDs, per-session silent hook records,
viewer origin and typed WSL delegation are implemented. Collection has a 100 ms
deadline; stale, mismatched, oversized and ambiguous model contexts remain null.
One-time setup prints a preview, without changing harness settings. Integration
instructions and remaining manual acceptance are in `integration/context-hooks.md`.

Five detection cases and the eight attribution/two history cases pass on both
Windows and native Linux (15 per platform). Logs under
`target/evidence/server-refactor/`: `detection-windows-final.log`,
`detection-linux-final.log`, `detection-red.log`, `detection-title-red.log`.
The initial collection and dropped-title regressions have observed RED/GREEN.
Focused library clippy and format checks passed. A real candidate Linux binary
delegated a mutation to the candidate Windows binary against a synthetic
Windows-owned fixture; history retained Linux origin and both session IDs.
Proof: `detection-real-delegation.json`. The unique fixture was retained after
automatic approval review rejected the command containing recursive cleanup.

Remaining: real isolated Codex/Claude adapters and model-switch acceptance,
Windows private context ACLs, and Windows executable ancestry. The latter needs
the user's choice between unavailable fields and a narrow native-wrapper
exception to the no-unsafe rule. This milestone does not close TSK-022 or claim
those manual/security checks passed. No global executable or profile was replaced.

## TSK-023: authentication/storage milestone

The `server` feature now builds `tasks-server`. Explicit admin initialization,
public registration/revocation and append-only OS-actor audit share the service's
lifetime data-root lock. Schema validation checks real definitions and integrity,
including audit trigger bodies. Persistent UUID/public registrations/replay state
remain separate from project databases. The Ed25519 RFC 9421 profile validates
exact signed components, digest, destination UUID, timestamps, nonce and current
credential; authoritative actor/installation fields replace client claims.

Authenticated private HTTP exposes only info (`ready: false`), with eight
operation permits, one-second admission, bounded bodies and shutdown handling.
See `integration/server-core.md`. This milestone does not close TSK-023: strict
HTTPS client/proxy TLS fixtures, private key permissions, request logging and
remaining shutdown/application acceptance still need implementation/proof.

### Proof and review

Twelve transport cases cover identity/restart, lifetime lock and real admin process
exclusion, public credential revocation/audit, immutable audit protection/schema
damage refusal, signed metadata/body tampering, spoofed identity replacement,
clock boundaries, replay persistence and both capacity ceilings, fresh-signature
identity, authenticated info, body rejection, operation capacity and shutdown
admission, an independently written signature base, and private-value error
suppression. Alongside attribution/detection/history this selects 27 cases.
Logs under `target/evidence/server-refactor/`: `server-core-windows-final.log`,
`server-core-linux-final.log`, owning clippy/release logs. Exact native results
are 27 passed, zero failed/ignored on each platform. Format and focused library/
server-binary clippy pass without warnings on Windows and Linux. Release `tasks`
and `tasks-server` candidates build on both platforms, using the separate target
directories above. No installed release binary was replaced. Broad batch/final
gates remain pending as scheduled.

Observed RED/GREEN: missing ownership/signature APIs, declared oversize body
waiting for bytes instead of early rejection, and missing audit trigger accepted
on reopen. Logs: `server-transport-red.log`, `server-signatures-red.log`,
`server-body-limit-red-selected.log`, `server-schema-red.log`. One misnamed exact
filter selected zero tests (`server-body-limit-red.log`); it is not proof.
First Linux attempt lacked Cargo on PATH; retained in
`server-core-linux-path-failure.log`, corrected by loading the Linux Cargo env.

Coordinator review checked strict verification before nonce consumption, body
check before route dispatch, same-transaction revocation/capacity admission,
inclusive expiry/skew boundaries, registration-derived identity, secret-free
admin error messages, and permit lifetime across cancelled blocking work.
Independent review is unavailable through the exposed priority-only agent tier.

Dependencies locked and source-checked: Axum 0.8.9 (MIT, Rust 1.80), Tokio 1.53.1
(MIT, Rust 1.71), ed25519-dalek 2.2.0 (BSD-3-Clause, Rust 1.81), sfv 0.14.0
(MIT/Apache-2.0, Rust 1.77), base64 0.22.1 and rand_core 0.6.4. The runtime is confined to
the opt-in server feature; normal local CLI builds remain synchronous. Installed
Rust 1.98.1 satisfies the selected package requirements.
