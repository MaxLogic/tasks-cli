# tasks-cli verification report

Date: 2026-09-16
Candidate: main after numbered maintenance commits and the follow-up recovery-test fix
Scope: Windows x64 release binary and Ubuntu 22.04 WSL x64 release binary.

## Summary

The seven requested maintenance items are implemented in separate commits. Migration now creates a new validated pre-upgrade backup for every actual migration attempt, reports its path, and does not reuse or delete older backups. Import BOM handling, readable text previews, routing documentation, dead-code removal, and batched list/search dependency reads are complete.

All current-binary checks below are measured from the candidate after the item commits. No prior trial counts are reused. No live TASKS.md file or live task backlog was modified.

One first-run failure occurred and is recorded rather than smoothed over: the first parallel WSL test run of the correction batch failed on the recovery test's fixed ten-second readiness wait. It was rerun to pass, and follow-up fix 1 removes the cause. The gate numbers below are the post-fix first-run results.

## Numbered commits

| Item | Commit | Result |
| --- | --- | --- |
| 1 | 46806e1 | Fresh unique migration backups, output path, sidecar cleanup, and migration regression coverage |
| 2 | Final report commit | Current measured gate counts, hashes, ledger trials, and WSL smoke evidence |
| 3 | 37689bd | Dead code removal; Clippy verified |
| 4 | c1f79f7 | BOM structural parsing, has_bom report field, and parity/apply coverage |
| 5 | 9be3434 | Readable line-oriented import text preview |
| 6 | 0047be0 | Routing, migration-backup, and BOM documentation |
| 7 | 7826d53 | One parameterized dependency query for each list/search page |
| Formatting | 7396607 | Mechanical rustfmt changes recorded separately |

Follow-up fixes, each in its own commit:

| Fix | Commit | Result |
| --- | --- | --- |
| 1 | d5ea677 | Precommit readiness wait polls while the writer process is alive, fails fast if it exits before the marker appears, and is capped at five minutes; cold throwaway-target proof |
| 2 | Report correction commit | Records the failed first parallel WSL test run and the rerun, and the removal of the leaked extension-less WSL binary |

## Verification commands and exact results

### Windows

Executed in F:\projects\MaxLogic\tasks-cli:

    cargo fmt --check
    cargo clippy --locked --all-targets --all-features -- -D warnings
    cargo test --locked
    cargo test --locked -- --test-threads=1
    cargo build --release --locked

The command statuses were fmt=0, clippy=0, test=0, serial=0, build=0.

For both cargo test commands, the captured output contained 15 running-test lines and 16 test-result lines. The result totals were 63 passed, 0 failed, and 0 ignored. This is 15 unit tests and 48 nonzero integration tests; the additional result line is the zero-test doctest target.

The five gates were re-run unchanged after follow-up fix 1, and the first and only post-fix run passed with the same statuses (fmt=0, clippy=0, test=0, serial=0, build=0) and totals (63 passed, 0 failed in both test modes). The Windows run was incremental: cargo clean was not run because the default target directory also contains the retained evidence tree. Retained evidence lives under target/evidence/, so a cargo clean in the default Windows target directory would destroy it; that is the reason the Windows gates run incrementally. The release build was already up to date and reproduced the recorded artifact hash.

Evidence (post-fix re-run):

- target/evidence/item-1-gates-windows/fmt.log
- target/evidence/item-1-gates-windows/clippy.log
- target/evidence/item-1-gates-windows/test.log
- target/evidence/item-1-gates-windows/serial.log
- target/evidence/item-1-gates-windows/build.log
- target/evidence/item-1-gates-windows/status.txt
- target/evidence/item-1-gates-windows/artifact.txt
- target/evidence/item-1-gates-windows/run.ps1

Correction-batch evidence: target/evidence/item-2-windows-gates/.

### Ubuntu/WSL

Executed inside Ubuntu 22.04 WSL with CARGO_TARGET_DIR=target/linux:

    cd /mnt/f/projects/MaxLogic/tasks-cli
    export CARGO_TARGET_DIR=target/linux
    cargo fmt --check
    cargo clippy --locked --all-targets --all-features -- -D warnings
    cargo test --locked
    cargo test --locked -- --test-threads=1
    cargo build --release --locked

The five gates started with cargo clean. The recorded statuses were clean=0, fmt=0, clippy=0, test=0, serial=0, build=0; the test=0 is the rerun result described next, not the first parallel run.

The first parallel test run of this batch did not pass. newer_schema_fails_safely_and_killed_precommit_writer_rolls_back failed because its fixed ten-second readiness wait expired while the nested cargo run --features test-hooks invocation was still compiling the test-hooks binaries (target/evidence/item-2-correction-wsl-gates/test-parallel-initial.log). The test was rerun and passed (target/evidence/item-2-correction-wsl-gates/test-rerun-status.txt), and follow-up fix 1 (d5ea677) removed the cause: the wait now polls while the writer process is alive, fails immediately if it exits before the marker appears, and is capped at five minutes.

The full gate run was repeated against the fixed candidate; its first and only post-fix run passed with clean=0, fmt=0, clippy=0, test=0, serial=0, build=0. The recovery test passed in the parallel mode in 12.11s, which the old fixed wait could not have survived.

The earlier WSL run used the shared default target directory and was repeated here with CARGO_TARGET_DIR=target/linux in the same shell.

For both cargo test commands, the captured output contained 15 running-test lines and 16 test-result lines. The result totals were 65 passed, 0 failed, and 0 ignored. This is 16 unit tests and 49 nonzero integration tests; the additional result line is the zero-test doctest target.

Evidence (post-fix re-run):

- target/evidence/item-1-gates-wsl/fmt.log
- target/evidence/item-1-gates-wsl/clippy.log
- target/evidence/item-1-gates-wsl/test.log
- target/evidence/item-1-gates-wsl/serial.log
- target/evidence/item-1-gates-wsl/build.log
- target/evidence/item-1-gates-wsl/status.txt
- target/evidence/item-1-gates-wsl/artifact.txt
- target/evidence/item-1-gates-wsl/invocation-note.txt
- target/evidence/item-1-gates-wsl.sh

Failed first run and rerun: target/evidence/item-2-correction-wsl-gates/test-parallel-initial.log, test-rerun-status.txt, test-rerun-results.txt.

### Recovery readiness proof (throwaway cold target)

The fix was proven once against a fresh throwaway target directory outside target/ and target/linux/, on the same filesystem as the gate targets:

    cargo clean
    cargo test --locked --test recovery

Result: clean=0, test=0; 4 passed, 0 failed; the test file finished in 34.60s with a cold nested compile. The throwaway target directory (467 MB) was deleted after the run.

Evidence:

- target/evidence/item-1-recovery-cold-build/cold-recovery.log
- target/evidence/item-1-recovery-cold-build/status.txt
- target/evidence/item-1-recovery-cold-build/run-meta.txt
- target/evidence/item-1-recovery-cold-build/run.sh
- target/evidence/item-1-recovery-cold-build/cleanup-throwaway.sh

## Release artifacts

- Windows target/release/tasks.exe
  - Size: 2,998,784 bytes
  - SHA-256: 04B4E0A4DE1DE03F6F090273425EB9F1286EB9566B57492D6CE044E8A75F9B16
- Linux x64 target/linux/release/tasks
  - Size: 3,992,160 bytes
  - SHA-256: A7593D59A328A3B003B7F1E20DBCA2984D878AC48D2DD396C0CA9C68F8988F36
- The WSL-built leftovers in the shared Windows target directories from the earlier unscoped WSL run were removed. The first pass deleted target/release/deps/tasks-42c0fe6702b2e502, target/debug/tasks, and target/debug/deps/tasks-9b4c447236f414f1 (target/release/tasks was already absent); a follow-up sweep removed the remaining 72 extension-less Linux ELF files under target/debug and target/release (606,224,144 bytes) plus 1,348 extension-carrying Linux objects (1,342 .o and 6 .so, 103,867,552 bytes). Inventory, removal script, post-removal checks, and summary: target/evidence/cleanup-unscoped-wsl-leak/. The recorded artifacts above are unchanged by these cleanups.

## Current-binary PFM and DelphiAiKit trials

Each live source was copied into an operation-owned evidence directory before reading. The copied TASKS.md was marked read-only. The test used independently parsed expected task headings, titles, bodies, and shared rules, then used the current Windows release binary for init, preview, apply, and per-task show comparisons.

- PFM: 132 tasks, 132/132 title matches, 132/132 body matches, 2,345 shared-rule bytes, source SHA-256 1743BABDD43A5767C86E9931F1FEBC7E84CFEBABEAB5277E220B5E861BD0CEC7.
- DelphiAiKit: 107 tasks, 107/107 title matches, 107/107 body matches, 110 shared-rule bytes, source SHA-256 C795D8E0B8B5A6434583E968924B355770359EB20227ADC9186BC6ED0BB727D4.

The binary used for both trials was SHA-256 04B4E0A4DE1DE03F6F090273425EB9F1286EB9566B57492D6CE044E8A75F9B16.

Evidence:

- target/evidence/item-2-import-trials/summary.txt
- target/evidence/item-2-import-trials/PFM-task-comparison.csv
- target/evidence/item-2-import-trials/DelphiAiKit-task-comparison.csv
- target/evidence/item-2-import-trials/PFM-input/TASKS.md
- target/evidence/item-2-import-trials/DelphiAiKit-input/TASKS.md

## WSL delegation smoke

The real current Linux wrapper and current Windows executable were used. Native Linux used a separate Linux-owned data root. The Windows-owned SQLite database was accessed only by Windows tasks.exe, including delegated calls.

The clean summary records:

    project_one=9b77499b-6fb3-46e5-b611-e7868628fe56
    project_two=25ca0c35-6b95-4c20-966e-a889acf7ec79
    init_one_status=0
    init_two_status=0
    projects_after_init=2
    closest_project=9b77499b-6fb3-46e5-b611-e7868628fe56
    precedence_project=9b77499b-6fb3-46e5-b611-e7868628fe56
    route_two_project=25ca0c35-6b95-4c20-966e-a889acf7ec79
    unknown_status=3
    explicit_unknown_status=0
    broken_interop_status=6
    projects_before_unknown=2
    projects_after_unknown=2
    linux_owned_exists=no
    race_create_status=0
    race_native_status=0
    race_delegated_status=4
    race_history_status=0
    race_show_status=0
    race_history_events=2
    race_show_version=2

The known invalid first race probe used an /mnt path directly with the Windows executable. Its artifacts were removed before the summary was retained; the summary contains only the corrected race result set.

Evidence:

- target/evidence/item-2-correction-wsl-smoke/summary.txt
- target/evidence/item-2-correction-wsl-smoke/artifact-sha256.txt
- target/evidence/item-2-correction-wsl-smoke/smoke.sh
- target/evidence/item-2-correction-wsl-smoke/race.sh

## Implementation coverage

- Fresh migration backups use TASKS.v<from>-pre-migrate-<unix-millis>-<pid>-<counter>.sqlite, are validated before the migration transaction, and older backups remain untouched.
- Backup validation and publication remove temporary and published WAL/SHM sidecars.
- Dead symbols listed in item 3 are removed; backup.rs remains the used SQLite backup wrapper.
- A UTF-8 BOM at byte 0 is structural only; original bytes and source hash are retained, and ImportReport exposes has_bom.
- Text import previews contain one readable line per task, section, and unassigned range; JSON remains structured.
- README.md and spec.md document that TASKS_PROJECT and --route-root affect routed commands only, never init or bind, both natively and through delegation.
- List and search dependency IDs are fetched in one bounded parameterized query per page.

## Remaining limitations

- Performance measurements were not rerun for this maintenance batch; prior candidate metrics are intentionally not repeated here.
- Evidence covers Windows x64 and Ubuntu 22.04 WSL x64. Other distributions, architectures, and unusual network/cloud filesystems remain untested.
- Private ledger checks use isolated read-only copies. Live projects remain unchanged.
- Restore remains an offline recovery workflow rather than an in-place replacement.

## Release judgment

Ready with minor fixes. The requested maintenance changes, the follow-up recovery-test fix, and the current-binary platform evidence are complete; the post-fix gate runs above are first-run passes. No push was performed.
