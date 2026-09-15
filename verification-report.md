# tasks-cli verification report

Date: 2026-09-15
Candidate: main after numbered maintenance commits
Scope: Windows x64 release binary and Ubuntu 22.04 WSL x64 release binary.

## Summary

The seven requested maintenance items are implemented in separate commits. Migration now creates a new validated pre-upgrade backup for every actual migration attempt, reports its path, and does not reuse or delete older backups. Import BOM handling, readable text previews, routing documentation, dead-code removal, and batched list/search dependency reads are complete.

All current-binary checks below are measured from the candidate after the item commits. No prior trial counts are reused. No live TASKS.md file or live task backlog was modified.

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

Evidence:

- target/evidence/item-2-windows-gates/fmt.log
- target/evidence/item-2-windows-gates/clippy.log
- target/evidence/item-2-windows-gates/test.log
- target/evidence/item-2-windows-gates/serial.log
- target/evidence/item-2-windows-gates/build.log
- target/evidence/item-2-windows-gates/status.txt

### Ubuntu/WSL

Executed inside Ubuntu 22.04 WSL with CARGO_TARGET_DIR=target/linux:

    cd /mnt/f/projects/MaxLogic/tasks-cli
    export CARGO_TARGET_DIR=target/linux
    cargo fmt --check
    cargo clippy --locked --all-targets --all-features -- -D warnings
    cargo test --locked
    cargo test --locked -- --test-threads=1
    cargo build --release --locked

The command statuses were fmt=0, clippy=0, test=0, serial=0, build=0.

For both cargo test commands, the captured output contained 15 running-test lines and 16 test-result lines. The result totals were 65 passed, 0 failed, and 0 ignored. This is 16 unit tests and 49 nonzero integration tests; the additional result line is the zero-test doctest target.

Evidence:

- target/evidence/item-2-wsl-gates/fmt.log
- target/evidence/item-2-wsl-gates/clippy.log
- target/evidence/item-2-wsl-gates/test.log
- target/evidence/item-2-wsl-gates/serial.log
- target/evidence/item-2-wsl-gates/build.log
- target/evidence/item-2-wsl-gates/status.txt
- target/evidence/item-2-gate-summary.txt

## Release artifacts

- Windows target/release/tasks.exe
  - Size: 2,998,784 bytes
  - SHA-256: 04B4E0A4DE1DE03F6F090273425EB9F1286EB9566B57492D6CE044E8A75F9B16
- Linux x64 target/linux/release/tasks
  - Size: 3,976,472 bytes
  - SHA-256: ECCF95D8464F97E15949981523A8A1F1255E08EF7D4DA5EE2CF512713183F4D5

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

    project_one=7d444545-9f60-478a-af5b-6908eb135fca
    project_two=becb8aaa-45ac-4886-80b0-36e7e325b76d
    init_one_status=0
    init_two_status=0
    projects_after_init=2
    closest_project=7d444545-9f60-478a-af5b-6908eb135fca
    precedence_project=7d444545-9f60-478a-af5b-6908eb135fca
    route_two_project=becb8aaa-45ac-4886-80b0-36e7e325b76d
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

- target/evidence/item-2-wsl-smoke/summary.txt
- target/evidence/item-2-wsl-smoke/artifact-sha256.txt
- target/evidence/item-2-wsl-smoke/smoke.sh
- target/evidence/item-2-wsl-smoke/race.sh

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

Ready with minor fixes. The requested maintenance changes and current-binary platform evidence are complete; no push was performed.
