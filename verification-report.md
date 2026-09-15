# tasks-cli verification report

Date: 2026-09-15
Scope: current source tree, Windows x64 release binary, and Ubuntu 22.04 WSL x64 release binary.

## 1. Summary

The release-blocking and correctness findings from the review were fixed or independently verified against the current implementation. The importer now preserves metadata-like body prefixes, sectionless tasks are unmapped, delegated init/bind do not inherit unrelated project context, legacy migration rejects cycles safely, limits are validated, diagnostics and read-only paths work on old schemas, and the required Windows/WSL routing and race evidence is present.

The release judgment is **Ready with minor fixes**. The remaining qualification is repository hygiene: this environment was instructed not to use Git, so no initial commit was created. Cargo.lock exists and was used by every locked build/test command, project.zip is ignored, and the stray control-character directory was removed. A few low-priority maintainability and preview-polish items remain explicitly listed below.

## 2. Findings and implementation status

| Finding | Status | Relevant implementation and evidence |
| --- | --- | --- |
| H1. Metadata-like lines lost from imported task bodies | Fixed | src/markdown.rs uses an ordered metadata block, treats Body: as a hard boundary, records consumed metadata, and preserves non-matching prefix lines. Regression tests are in tests/import_contract.rs; executable smoke evidence is in target/evidence/assessment-import-exe-windows-2. |
| M1. Delegated init inherited TASKS_PROJECT | Fixed | src/interop.rs injects project context only for routed project commands, not init or bind. target/evidence/assessment-wsl-fixes-3/summary.txt proves two delegated init roots receive two projects while explicit routing and TASKS_PROJECT precedence work for routed commands. |
| M2. Tasks outside a section defaulted to backlog | Fixed | src/markdown.rs represents this as the explicit <no section> pseudo-section and blocks apply unless mapped. Covered by tests/import_contract.rs and the executable smoke summary. |
| M3. Unversioned repository and stray files | Partially fixed | The stray control-character directory is gone and /project.zip is in .gitignore. No commit was made because Git operations are outside this execution scope; the lockfile is present but not committed. |
| M4. Missing delegated race and broken-interop evidence | Fixed | target/evidence/assessment-wsl-fixes-3/summary.txt records closest-ancestor routing, explicit-project precedence, unknown-directory no-creation, broken interop with no Linux fallback, and a corrected native-Windows versus delegated-Windows optimistic-update race. |
| M5. Exponential/unterminated dependency cycle walk | Fixed | Live and legacy cycle checks use recursive UNION, and v0 migration validates legacy dependencies before commit. Covered by tests/migrations.rs; the legacy cyclic fixture rolls back. |
| L1. Global options failed after a subcommand | Fixed | src/cli.rs marks the common options global. tests/interop.rs covers tasks list --format json. |
| L2. Reads were read-write and doctor rejected old schemas | Fixed | Rules preview, export, and import preview use read-only opening; diagnostics use a schema-tolerant read-only opener and report old/new schema state. Covered by tests/reads.rs and tests/migrations.rs. |
| L3. Failed migration left an unusable retry backup | Fixed | Migration reuses and validates an existing pre-upgrade backup rather than failing with an opaque destination-exists error. Covered by tests/migrations.rs. |
| L4. Limits were silently clamped | Fixed | List, search, and history reject values outside 1..=100. Covered by tests/reads.rs. |
| L5. Help went to stderr | Fixed | Help/version output is written to stdout in src/main.rs. |
| L6. Error classification and input error shape | Fixed for reviewed paths | Validation/file-input errors use the documented usage class; schema/open failures use the database class; the stable JSON envelope and conflict details remain covered by subprocess tests. |
| L7. Dead code and nominal module boundaries | Partially fixed | The backup wrapper is now used by the command path. A broad split of store.rs, removal of the unused alternate renderer, and a dedicated migrations directory were not undertaken because they do not improve the release proof enough to justify a broad refactor. |
| L8. Noisy previews for BOM/summary content | Partially fixed | Import accounting and explicit unknown/unmapped reporting are enforced, and metadata handling is documented. BOM and project-specific summary conventions remain visible as source content/unknown content rather than being guessed away. |
| L9. Readers had no busy timeout | Fixed | Read-only open configures a bounded SQLite busy timeout. |
| L10. Lock contention mapping was Windows-specific | Fixed | OS error 32/33 are treated as lock contention only on Windows; Unix tests cover the distinction. |
| Priority 2. Backup validation/publication | Fixed and verified | Online backup output is validated for integrity, foreign keys, schema version, and project UUID, then published with no-overwrite race protection. Concurrent backup tests pass. |
| Priority 2. Test-only failure hooks | Fixed and verified | Failure injection is behind the test-hooks feature/helper and is not enabled by the normal release binary. |
| Priority 2. Dependency replacement/no-op semantics | Fixed and verified | Replacement is set-semantic, ordering-independent, mutually exclusive with clear, and no-op updates create no version/event. |
| Priority 2. Text/JSON and delegation path syntax | Fixed and verified | Routing identity, dependency summaries, bounded reads, JSON errors, and both --flag value and --flag=value delegation forms are covered by tests/probes. |
| Priority 3. Toolchain pin | Fixed | rust-toolchain.toml pins the project toolchain. |
| Priority 3. Documentation | Fixed for current behavior | README.md, spec.md, AGENTS.md, and this report describe the importer contract, routing, storage ownership, build/use/recovery commands, and verification scope. |

## 3. Tests added or retained

- Import metadata-prefix preservation for Title:, Status:, Depends on:, Version:, and Body:.
- Export/import round-trip preservation for metadata-like body prefixes.
- Sectionless tasks reported as unmapped and rejected during apply.
- Strict page-limit validation.
- Doctor reporting for an actual v0 schema without migrating it.
- Cyclic legacy dependency migration rollback.
- Delegated init/bind argument-context regression.
- Global option parsing after a subcommand.
- Unix lock-error classification.
- Existing durable coverage retained for SQLite transactions, same-version single-winner updates, unique concurrent IDs, failed-write rollback, killed writers/WAL recovery, dependency cycles, bounded pagination, body omission in list, complete show text, malformed import atomicity, concurrent backups, newer schemas, CRLF/Unicode, literal search metacharacters, history event ownership, and structured subprocess errors.

Windows test result: 14 unit tests and 51 integration tests passed; 0 failed and 0 ignored.
Ubuntu/WSL test result: 15 unit tests and 52 integration tests passed; 0 failed and 0 ignored.
The test harness reported no selected doctests and no zero-test selection was used.

## 4. Verification actually executed

### Windows gates

Executed in F:\projects\MaxLogic\tasks-cli:

    cargo fmt --check
    cargo clippy --locked --all-targets --all-features -- -D warnings
    cargo test --locked
    cargo test --locked -- --test-threads=1
    cargo build --release --locked

All passed. Combined status is recorded in target/evidence/assessment-windows-gates.log as:

    STATUS fmt=0 clippy=0 test=0 serial=0 build=0

The test-hooks helper was also built with:

    cargo build --release --locked --features test-hooks --bin tasks-test-fixture

### Ubuntu/WSL gates

Executed inside Ubuntu 22.04 WSL with a separate target directory:

    cd /mnt/f/projects/MaxLogic/tasks-cli
    export CARGO_TARGET_DIR=target/linux
    cargo fmt --check
    cargo clippy --locked --all-targets --all-features -- -D warnings
    cargo test --locked
    cargo test --locked -- --test-threads=1
    cargo build --release --locked

All passed. The test-hooks helper was also built with:

    CARGO_TARGET_DIR=target/linux cargo build --release --locked --features test-hooks --bin tasks-test-fixture

### Release artifacts

- Windows: target/release/tasks.exe
  - Size: 2,980,864 bytes
  - SHA-256: F43A465077235EAF936F9DAC6792ABA653FE8926EFA57DD4D2B406798139B3BD
- Linux x64: target/linux/release/tasks
  - Size: 3,976,472 bytes
  - SHA-256: ECCF95D8464F97E15949981523A8A1F1255E08EF7D4DA5EE2CF512713183F4D5

### Executable and interoperability evidence

- Windows CRUD/import/sectionless smoke: target/evidence/assessment-import-exe-windows-2/summary.txt
- Native Linux-owned storage, CRUD, backup, doctor, /mnt rejection, and UNC rejection: target/evidence/assessment-linux-native-fixes/summary.txt
- WSL delegation, routing precedence, no-fallback failure, and cross-client optimistic conflict: target/evidence/assessment-wsl-fixes-3/summary.txt
- Windows gates: target/evidence/assessment-windows-gates.log

The WSL evidence uses the real shipped Linux wrapper and Windows tasks.exe; it does not open the Windows-owned SQLite file from native Linux. Native Linux tests use a Linux-owned /tmp data root.

### Isolated ledger trials

Read-only copies of PFM and DelphiAiKit TASKS.md were imported into isolated stores. The prior independent comparisons recorded:

- PFM: 133/133 task IDs and bodies matched; shared rules length 2,328 bytes; source SHA-256 8C488BC6C609755F184DA3B1CE67BD7BBB1E21167F410DCA741C276EB0532039.
- DelphiAiKit: 107/107 task IDs and bodies matched; shared rules length 110 bytes; source SHA-256 68CCBE5DF2F38456F378F2C8FD718E853BDD59CC81AC21F8B717F9CDA25939B0.

These were copies only. No live TASKS.md or live backlog was modified or migrated.

### Performance

Each case used five warmups and 50 measured release-binary samples against an operation-owned synthetic fixture. Measurements include process startup and are reported separately for native and delegated paths.

Windows fixture size: 44,294,144 bytes.

| Command | P50 ms | P95 ms | Output bytes |
| --- | ---: | ---: | ---: |
| list --limit 20 | 18.655 | 25.096 | 862 |
| search Performance --limit 20 | 18.033 | 22.794 | 872 |
| show T-00001 | 18.151 | 25.004 | 2,218 |
| update T-00001 | 35.632 | 40.580 | 104 |

Native Linux fixture size: 43,606,016 bytes.

| Command | P50 ms | P95 ms | Output bytes | Peak RSS KiB |
| --- | ---: | ---: | ---: | ---: |
| list --limit 20 | 27.472 | 29.788 | 870 | 5,036 |
| search Performance --limit 20 | 27.940 | 34.657 | 870 | 4,988 |
| show T-00001 | 27.004 | 29.038 | 2,227 | 4,964 |
| update | 42.424 | 45.469 | 103 | 5,140 |

Delegated WSL-to-Windows fixture measurements:

| Command | P50 ms | P95 ms | Output bytes |
| --- | ---: | ---: | ---: |
| list --limit 20 | 65.640 | 74.855 | 864 |
| search Performance --limit 20 | 59.985 | 77.880 | 872 |
| show T-00001 | 59.860 | 80.707 | 2,220 |
| update | 75.091 | 92.824 | 104 |

Performance evidence is retained under target/evidence/assessment-performance-windows/, target/evidence/assessment-performance-linux-2/, and target/evidence/assessment-performance-wsl-2/. These are observed results, not renamed targets.

## 5. Remaining limitations

- No initial Git commit was created in this run, so the lockfile is durable in the working tree but not committed.
- Windows/WSL proof covers Windows x64 and Ubuntu 22.04 WSL x64. Other Linux distributions, native Windows ARM, and other filesystems were not tested.
- WSL delegation is intentionally same-host Windows ownership; native Linux must use its own data root.
- The private ledger trials used isolated read-only copies, not live projects.
- Restore remains an offline recovery workflow rather than an in-place database replacement.
- The broad store.rs module split and alternate-renderer cleanup remain maintainability work, not release correctness blockers.
- Platform-specific behavior on unusual network/cloud-synced filesystems remains outside the evidence matrix.

## 6. Release judgment

**Ready with minor fixes**

The binaries, transaction/migration/import/backup contracts, routing boundary, failure paths, and platform gates have executable evidence. The remaining minor qualification is repository versioning: create and review the initial local commits, including Cargo.lock, before publishing or distributing the release.
