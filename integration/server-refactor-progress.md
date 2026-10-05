# Server refactor progress

## Scope and gates

Approved contract: spec.md, Rust server and automatic attribution extension.
Ledger: TSK-021 through TSK-027, corresponding to implementation slices 1-7.
Focused proof per slice; broad Windows/native Linux gate after TSK-025, final
after TSK-027. Candidate workstation installs and live project migrations require
their separate authorization; NAS deployment was authorized on 2026-10-05.

LAN HTTPS is owned by the user's other thread. Reuse its Caddy gateway; QTS
keeps NAS administration. Stale Audiobookshelf rule removal was verified by SSH
on 2026-10-03. Docker stays at the current version. Actual NAS deployment,
strict LAN/public TLS and physical backend isolation passed on 2026-10-05;
see the dated deployment record below.

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

## Shared API, 2026-10-04 (TSK-024)

Typed catalog/project creation, list/search/unlocks/show/history/rules/key reads
and task/rules/key mutations now share Store validation, versions and history.
Authenticated identity replaces client actor/machine claims. Server schema 2
adds the catalog through explicit backed-up migration; project schema remains 8.
Creation commits its event/receipt before publishing a catalog binding. A replay
repairs interrupted publication without creating another project or history event.
Valid-UUID terminal creation refusals retain receipts without publishing a project.

Normal replies have a 16 MiB serialization cap and retain operation admission
while response buffers live. Show/history preflight source bytes in their read
snapshot. History lookahead queries existence without loading the next snapshot.
Complete exports stream one SQLite snapshot in bounded NDJSON frames, with byte
count and SHA-256 verification. Queued frames retain admission after producer exit.
Client atomic export publication belongs to TSK-025, not this milestone.

Focused proof: 68 owning tests per platform across server_api (19), transport
(13), HTTPS (7), attribution (8), history (2), project_keys (17), markdown (2).
Library tests add 58 Windows / 59 Linux; all pass, zero failed/ignored/filtered.
The TLS export proof transfers over 20 MiB through an actual gateway/listener,
compares complete bytes/checksum/count and bounds consumer writes to 16 KiB.
HTTP tests cover disconnect/lost acknowledgement, admitted-write shutdown,
oversized bodies, exact-once receipts, competing creates and catalog recovery.

Logs: `target/evidence/server-refactor/api-final-{windows,linux}-tests.log`,
`api-final-{windows,linux}-clippy.log`, `api-final-{windows,linux}-release.log`.
Both isolated release candidates build; focused Clippy is clean. Original RED
and unsuccessful fixture runs remain separately named. The existing history
fixture now suppresses Windows consoles and inherited delegation. Missing help
on the context-hook harness option was exposed by library tests and corrected.

A controlled 3.3-second SQLite lock reproduces the test gateway's old 3-second
upstream timeout (`proxy-wait-red.log`). Aligning that fixture with the client's
15-second request bound passes the same probe (`proxy-wait-green.log`); production
timeouts were not changed. The regression is retained in the gateway test.

Independent reviews used installed Codex CLI, GPT-6 Sol/high, default service
tier, supplied-source read-only snapshots with tools/hooks disabled. Initial
findings (response memory/refusal receipts), follow-up findings (queued permit
ownership/lookahead), and final no-blocker result are retained in
`api-review-{supplied,fixed,final}-findings.md` with measured run/usage records.
An earlier shell-based review read no code because of policy refusals; its zero
process exit is not claimed as review evidence. Final review's source snapshot
precedes only the test-gateway timeout regression, documentation and formatting.
Broad checkpoints remain after slices 1-5 and 6-7. No installation, live data
migration, desktop operation or NAS deployment occurred.

## Remote CLI and first broad checkpoint, 2026-10-04 (TSK-025)

Default builds now include strict HTTPS profiles, local enrollment/configuration,
automatic attribution, remote routing before WSL delegation, complete export
publication and explicit original-request reconciliation. Ordinary reads/writes,
errors, version conflicts, routing and batched enrichment retain their contracts.
Maintenance operations refuse remote execution without opening local SQLite.
Setup/recovery is documented in integration/remote-cli.md.

Actual CLI/TLS fixtures use two protected installations and test response loss,
an intermediary JSON503 after commit, poisoned local DB/outage, repeated init
including registry-only routing, complete/interrupted exports and original-version
replay after another installation changes the task. Unmarked/nonterminal replies
retain private evidence. Terminal replies bind UUID/route/digest/status. Missing-
project writes retain negative receipts, so later creation cannot execute a replay.
Windows pending files use native write-through publication via atomicwrites;
Unix uses directory fsync. Physical power-loss proof is not claimed.

Independent source reviews used GPT-6 Sol/high/default with installed hidden
Codex CLI and disabled tools/hooks. Initial receipt/profile/deletion findings,
then registry/publication findings, then negative-receipt/sticky-ancestor/Windows
durability findings were fixed. Final bounded review reports no confirmed remaining
must-fix issue in those fixes: remote-cli-review-terminal-findings.md (69.266s).
Review logs/results and every first-failure proof remain under target/evidence/
server-refactor. Compilation errors and characterization tests are distinguished
from runtime RED; no claim that every added test began with a runtime RED.

First broad checkpoint: Windows 348 tests, native WSL/Linux 353 tests, all pass;
49 test target results per platform, zero failed/ignored/filtered. fmt, all-target
server Clippy, isolated release builds of both binaries, default-client and
local-only feature checks pass. Two inherited test-only Clippy warnings remain
(items_after_test_module and field_reassign_with_default). Logs are
checkpoint1-verified-windows-{fmt,clippy,tests,release,local-feature,default-feature}.log
and checkpoint1-linux-{fmt,clippy,tests,release,local-feature,default-feature}.log.
Candidate Windows/Cargo hashes: checkpoint1-candidate-hashes.json. Linux SHA256:
tasks 92402cff079c0ae0fef9b535091dd76456faf3d481b4c736a2a96e0490071783;
server 2fabd862f3d238a53bcd9587850a707d82cbb97f60364a60e05f27a94e51025c.

The original broad Windows run failed five tests: three migration fixtures pinned
schema6, and two deterministic export tests no longer matched the streamed SQL.
Their historical-field comparisons now explicitly exclude added nullable columns;
the export test checks its interleave actually fired. Revised broad gates pass;
checkpoint1-windows-tests.log and the first focused fixture failure are preserved.
All Rust test subprocess constructors now use a common hidden Windows launcher.
No desktop/clipboard verification, installed binary change, live DB migration or
NAS deployment occurred. Viewer remote flows and Docker/cutover remain the next
slices; actual harness acceptance remains separate under TSK-022.

## Remote viewer milestone, 2026-10-04 (TSK-026)

The existing CLI JSON protocol now provides a remote project catalog, task
pages/details/history, viewer updates and shared archival metadata. Client root
bindings stay local; server filesystem paths are not returned. Snapshot tokens
bind the server query and client bindings. Per-project availability errors do
not discard healthy projects. Catalog size and raw response sources are bounded
before serialization. History renders typed nullable attribution.

The viewer preassigns mutation UUIDs. Private request evidence and confirmation
markers remain until the frontend validates the response and acknowledges it.
Confirmation binds server and credential identity. Explicit reconciliation
replays the original payload/version; later edits cannot prove an earlier save
by matching text. Unknown outcomes preserve drafts and inhibit new writes.
Reconciliation outages preserve pending state. Timed-out original CLI processes
are not killed; checks wait for their exit, then distinguish a saved receipt
from a preflight failure without sending another write. Known refusal, failed
launch, lost cleanup output and failed detail refresh have separate recovery
paths. See integration/remote-viewer.md.

Focused Rust proof: 49 tests on each platform across remote_cli, remote_pending,
remote_viewer (5), server_maintenance and viewer_api. Logs:
viewer-maintenance-reviewed-{windows,linux}.log under target/evidence/server-refactor.
Flutter owning proof includes 17 remote cases in the final broad suite. Observed
runtime RED/GREEN covers lost editor pending state on reconciliation outage and
the still-running preflight case. Initial test compilation mistakes are retained
and are not runtime RED. Logs: viewer-reconcile-outage-red-selected.log,
viewer-reconcile-outage-green.log, viewer-preflight-timeout-red.log and
viewer-preflight-timeout-green.log.

Independent source reviews used hidden installed Codex CLI, GPT-6 Sol/high/default,
with tools/hooks disabled and supplied frozen sources. Five initial viewer and
maintenance findings were fixed. Final reviews report no confirmed remaining
must-fix defect; the suggested terminal-reconciliation refusal regression was
added. Review briefs/events/findings/run records remain under the same evidence
directory. Reviews are not executable proof.

A release provider characterization sampled five runs each at 50 and 500 empty
synthetic projects. Replacing repeated Store validation/connections with one
read transaction per project reduced the 500-project samples from 5.47-6.53s to
1.06-1.62s; 50-project samples changed from 507-590ms to 86-104ms. Complete
provider outputs were compared, excluding sample time. These are separate
equivalent fixtures and provider-only timings, not full CLI/TLS p95 certification.
Logs/source: viewer-provider-{baseline,candidate}.log and measure-viewer-provider.rs.

### Final background gates

- Rust: Windows 359 tests and native WSL/Linux 364 tests pass, 51 target results
  each, zero failures/ignored/filtered. Format, all-target server Clippy, isolated
  release builds and default/local-only feature checks pass on both platforms.
  Three inherited test-only Clippy warnings remain; no new production warning.
  Logs: checkpoint2-final-verified-windows-*.log and checkpoint2-final-linux-*.log.
- Flutter: analysis has no issues; 612 tests pass with a fresh seeded headless
  E2E fixture and an isolated schema-8 test-hooks CLI. The one explicit skip is
  the console-window case in a console-free runner; it separately passes with
  a hidden console. Final focused transport, real CLI/recovery and remote cases
  also pass (59).
  The first lost-response check expected a kill request, contrary to the spec's
  prohibition on cancelling writes. The revised test forwards any actual kill,
  expects none, observes the response deadline before commit, and verifies one
  persisted update after reconciliation. Removing the launcher's read delay
  exposed a production race: reconciliation read the old WAL version before
  its writer exited. The client now waits for its own local writer and reserves
  that slot before asynchronous process launch. Detail reads recheck a queued
  writer before launch; failed launches release their reservation. Read waiting
  remains cancellable and shares one timeout budget across queued writers and
  response draining. Six focused regressions cover these cases. The original
  failures are retained, including
  the RED test's failed teardown while its writer was still alive; the fixture
  now awaits its owned writer before cleanup.
  Logs: viewer-final-analyze.log,
  checkpoint2-flutter-final-seeded-tests.log, viewer-hidden-console-proof-fixed.log,
  viewer-test-hooks-recovery.log, viewer-local-reconcile-race-{red,green}.log,
  viewer-final-wait-focused-fixed.log and viewer-local-cancel-red.log. An initial
  widget test mixed fake timer advancement with a real Stopwatch; its budget
  test failure is retained but is not behavior RED. The corrected real-timer
  case passes. Final local-race reviews found reservation, cancellation and
  budget gaps, all fixed and regression-covered; final findings are in
  local-race-review-findings.md, earlier findings in *-first/second/third-findings.md.
- Windows viewer release builds. The isolated portable bundle at
  target/viewer-server-final passes all four headless launch cases, plus clip,
  credential and hash checks. The first packaging invocation supplied a relative
  settings root and failed startup argument validation; rerunning with absolute
  fixture paths passed without source changes. The final bundle includes the
  local writer fix. Evidence: package-final/package-summary.json,
  viewer-final-release.log and viewer-package-final.log. Earlier packaging
  failure/pass evidence remains under package-reviewed/ and package-accepted/.

No installed CLI/viewer or user harness setting was changed. No live project was
migrated and no NAS service was changed. Real packaged viewer/NVDA spoken-outage/focus/retry proof remains
pending until the workstation is available. TSK-026 remains to-verify.

## Container and recovery milestone, 2026-10-04 (TSK-027)

Server administration now supports verified backup, restore to a new authority,
and adoption of schema-8 project copies. Online SQLite snapshots include the
catalog and all project directories, including unpublished receipt stores.
Private manifests record identity, schema, counts, size and SHA-256. Integrity,
foreign keys and staged copy hashes are checked before durable publication.
Outputs refuse overwrite; parent sync order is tested. Sources and imported
history, counters, attribution, receipts and authentication state are preserved.
Existing-authority administration requires the running service to stop. Restore
publishes a separate destination without opening the existing authority.

The linux/amd64 image runs as UID/GID 10001. Compose uses a private external
gateway network, no published ports, a read-only root, dropped capabilities,
no privilege gain, bounded resources and rotated logs. TLS and signing private
keys, tunnel credentials and Docker sockets stay outside the image/container.

The reviewed local image is tasks-server:reviewed-20261004, image ID
sha256:cd294eb7a7765b0e4fa23f8fef65f5af6b6f4e554a6d5a009b71a30cc162f91f.
Local Docker 29.2.1 rehearsal passed nine named checks: backend network isolation,
two signed HTTPS origins, exact cross-route data/history/attribution, stale-version
refusal without an extra event, nonce replay refusal before/after restart, lost
response recovery with the exact original receipt, revocation on both origins,
TLS hostname mismatch refusal, and verified exact backup/restore. Three mocked
resource-ownership tests pass. All driver-owned containers/networks/volumes were
removed; unrelated resources were untouched. Evidence under
target/evidence/server-refactor: docker-build-reviewed.log,
container-proof-reviewed-fixed/manifest.json and commands.jsonl,
container-ownership-final.log. The first strict TLS run failed because the
synthetic CA lacked AuthorityKeyIdentifier; the corrected fixture retains strict
validation with appropriate key identifiers/usages. Earlier failed logs remain.

An offline deployment candidate is prepared in target/qnap-server-candidate-20261004:
the 85,741,056-byte image archive, Compose configuration, runbooks and hash manifest.
See integration/qnap-server-runbook.md and integration/server-cutover.md.
No NAS access, deployment, installed executable replacement or live migration
occurred. Actual QNAP runtime support, trusted LAN/Cloudflare routing and physical
LAN backend isolation on Docker 27.1.2-qnap8 remain deployment acceptance gates.
The existing NAS Docker version and gateway ownership are retained. TSK-027 stays
to-verify until deployment readiness and the preceding task gates are satisfied.

## Real harness acceptance milestone, 2026-10-04 (TSK-022)

Actual isolated Codex 0.160.0 and Claude Code 2.1.287 sessions used ordinary
candidate CLI writes, then resumed the same session with a different model.
Private previewed adapters generated eight filtered identity records; every
adapter exited 0 with zero stdout/stderr. Task histories matched OS account,
machine, harness and session. Claude supplied its session title but no model;
Codex supplied refreshed model fields but no matching agent/execution identity,
so stored model remained null. Optional unavailable fields were not guessed.
No attribution parameters, hook additionalContext or context variable assignments
were added to ordinary task writes. Direct Bash, Bash-to-native-PowerShell and
native PowerShell paths were exercised as documented in integration/context-hooks.md.

Global harness settings, hooks and trust records were untouched. Codex's
hooks/list verified exact owned IDs/hashes; per-run overrides disabled external
hooks and trusted only owned definitions. Claude used private settings with
user/project sources excluded. Failed initial probes are retained separately;
they do not count as adapter acceptance. Evidence under target/evidence/server-refactor:
codex-context-proof-fixed-manifest.json and claude-context-proof-fixed-manifest.json.

Windows private ACL and Linux bounded ancestry proof already pass. The remaining
TSK-022 decision is whether Windows caller executable fields stay unavailable
under the current no-unsafe/selective-process-access constraints, or a narrowly
scoped native wrapper exception is approved. TSK-022 remains to-verify; TSK-025's
implementation and final gates pass but it cannot become done ahead of that
prerequisite. No model attribution is inferred from a shared concurrent session.

## Accepted Windows decision and actual NAS deployment, 2026-10-05

The user accepted nullable Windows caller/harness executable fields under the
no-unsafe rule. Existing native ACL, Linux ancestry and real harness proof applies;
TSK-022 and then TSK-025 are done. Decision commit: d92e6d7.

The user authorized NAS deployment and tasks.maxlogic.app on the existing
Cloudflare tunnel and LAN DNS. The reviewed image is now running on actual
QNAP Docker27; 16 distinct deployment checks pass with isolated synthetic data,
then a permanent empty authority and one enrolled alternate workstation profile.
Trusted LAN/public signed CLI routes, physical Pi isolation, replay/conflict,
revocation, lost-response restart recovery, exact backup/restore and existing
app/admin route regression are recorded in deployment-2026-10-05.md. The temporary
setup token is revoked and all temporary relay/validator containers are removed.
No installed workstation binary or live project store was replaced/migrated.

TSK-027's actual deployment criteria pass. It remains to-verify while its
TSK-026 prerequisite awaits the packaged NVDA walkthrough. Certificate renewal,
full NAS reboot and offsite machine checks are explicitly unobserved. Evidence:
target/evidence/nas-deploy-20261005/deployment-proof.json and final-regression.json.
