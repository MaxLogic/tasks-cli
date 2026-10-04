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

## Security group, 2026-10-04

TSK-023 transport implementation now includes strict synchronous HTTPS/private CA,
OS-random Ed25519 PKCS#8 key generation/private loading, a TLS gateway fixture
reaching the actual Rust listener, and fixed metadata request logs. Client profile
routing, enrollment export and pending receipt reconciliation remain TSK-025.
Task routes still return 404 and info remains `ready: false` until TSK-024.
TSK-023 awaits the scheduled batch; NAS routing/isolation remains TSK-027.
Admitted task-write shutdown proof is scheduled with TSK-024's dispatch.

The same protected-file helper closes the Windows hook ACL gap in TSK-022.
Isolated real harness/shell/model-switch acceptance and Windows ancestry selection
remain open. Desktop and installed application interaction are deferred while
the user works. This group changes no installed command, harness setting, NAS
configuration or live project authority.

### Exact focused proof

Six owning test targets (`attribution`, `attribution_detection`, `history`,
`private_credentials`, `remote_https`, `server_transport`) pass: 38 on Windows,
37 on native Linux, zero failures/ignored/filtered. Windows has one extra ACL
hook regression. The platform credential target selects three real filesystem
cases each. HTTPS selects six cases: configuration, certificate trust/date/name,
redirect/declared and streamed limits, exact encoded signed requests, actual
gateway/private-listener forwarding, and timed-out admitted write sent once.
Transport now includes a request-log privacy/refusal regression (13 cases total).
The existing attribution/detection/history checks stay green.

Full logs under `target/evidence/server-refactor/`:
`security-group-windows-final.log`, `security-group-linux-final.log`,
`security-group-windows-clippy-final.log`, `security-group-linux-clippy.log`,
`security-group-windows-release.log`, `security-group-linux-release.log`,
`security-group-fmt.log`. Focused clippy covers the library, two binaries and
four security/detection targets, without warnings. Both `tasks` and `tasks-server`
release candidates build in separate target directories. Broad checkpoints
remain scheduled after slices 1-5 and after 6-7.

Observed RED: missing credential/HTTPS/log APIs and a shared Windows hook ACL
incorrectly accepted (`private-credentials-red.log`, `remote-https-red.log`,
`request-logs-red.log`, `private-context-red.log`). The initial Windows credential
run exposed the ACL dependency's null-DACL panic; conversion now refuses null
ACLs before that accessor. Source review also avoids its incorrect generic
security setter and unused account-name lookup. Direct safe handle APIs are used;
no unsafe Rust or permission-setting subprocess was added.

The first TLS fixture inherited nonblocking sockets on Windows. The retained
`remote-https-socket-diagnosis.log` records error 10035/WouldBlock; accepted
sockets now explicitly select bounded blocking I/O. This was a fixture defect,
not evidence of relaxed TLS. The first concurrent hook run exposed publication
before directory ACL protection; Windows now publishes only a protected empty
directory. Passing original fixtures provide regression proof for both fixes.
Earlier native runs are retained with `-first` names, not mixed with final counts.

Coordinator security review checked permissions before reading/writing secrets,
opened-object validation, bounded inputs/replies, private-value error suppression,
encoded-target signing, no redirects/retries, and registration-only actor logs.
Independent agent review remains unavailable through the priority-only tier.
No existing Cargo package version was removed or upgraded. New dependencies:
reqwest 0.12.28 (MIT/Apache-2.0, Rust 1.64), windows-permissions 0.2.4 (MIT,
no declared MSRV) and rustix 1.1.4 (Apache-2.0 with LLVM exception/Apache-2.0/MIT),
with rcgen 0.14.10 and rustls 0.23.45 as synthetic TLS proof dependencies. The
installed Rust toolchains build and execute them natively on both platforms.

## Atomic receipt core, 2026-10-04 (TSK-024, partial milestone)

Project schema 8 adds append-only mutation receipts. Existing task, rules and
key methods use a savepoint when the service owns their transaction; ordinary
local commands retain their immediate transaction. Deduplication precedes entity
version checks and retains terminal validation/conflict responses. Receipt
insertion failure rolls back tasks, history, rules and the ID counter together.
A multi-step refused operation rolls back its earlier steps and keeps only the
refusal receipt. Busy/storage failures are not made durable refusals.

Schema 7 upgrades require explicit migration and a verified pre-upgrade backup.
Schema validation checks receipt table and trigger definitions, including a
same-name trigger whose append-only protection was weakened. Legacy task/history
bytes survive the upgrade. No live database or installed binary was changed.

Eight owning targets (`server_api`, `attribution`, `history`, `migrations`,
`recovery`, `states`, `error_messages`, `project_keys`) select 61 tests on each
platform: all pass, zero failed/ignored/filtered. RED for missing receipt APIs is
retained in `receipts-api-red.log`; earlier fixture/compiler failures are retained
separately. The schema-error fixture previously hard-coded future/current schema
7/6; it now derives both numbers from the actual schema constant. Its subprocess
and project-key subprocesses use hidden Windows creation flags.

Proof: `target/evidence/server-refactor/receipts-windows-verified.log`,
`receipts-linux-verified.log`, and `receipts-{windows,linux}-clippy.log`.
Focused Clippy succeeds on both platforms with one inherited test-only
`field_reassign_with_default` warning in `tests/attribution.rs`. Format and diff
checks pass. API routes, catalog recovery and HTTP acceptance still belong to
the active TSK-024; this receipt milestone does not close that task.
Both release candidates (`tasks`, `tasks-server`) build in the isolated Windows
and Linux target directories; logs are `receipts-{windows,linux}-release.log`.
