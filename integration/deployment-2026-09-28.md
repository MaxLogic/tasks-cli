# Deployment record: to-verify, project keys and key cache 2026-09-28

Install authorized by the user on 2026-09-28. It covers three CLI commits:

- `e56cf62` feat(status): add to-verify status with completion guard
- `72e7525` feat(keys): add project keys to task IDs (DAK-212)
- `b40cc54` perf(store): cache every key lookup and leave no -wal/-shm after reads

Both binaries report `tasks 0.1.0 (commit b40cc547edce)`. The data schema is
now version 6; stores on older versions must be migrated (see "Live migration").

## Executables

- Windows: `F:\CliTools\tasks.exe` → `..\projects\MaxLogic\tasks-cli\target\release\tasks.exe`,
  built with `cargo build --release --locked` (log
  `target/evidence/deploy-2026-09-28/win-build.log`).
  SHA-256 `38a028f55d0b0cd08d4b56cd203635c13e7e162c17a4992c3403e9492faaeb5b`.
- Ubuntu/WSL: `/home/pawel/.local/bin/tasks` → `/home/pawel/.local/share/tasks-cli/target/release/tasks`,
  built with that `CARGO_TARGET_DIR` (log `target/evidence/deploy-2026-09-28/wsl-build.log`).
  SHA-256 `b4bb016d9fec8190e289ee062aba6d82d2cc9ef2db37faab86c06ccddf718d74`.
  `TASKS_WINDOWS_EXE=/mnt/f/CliTools/tasks.exe`; a `tasks doctor` under
  `/mnt/f/projects/MaxLogic/tasks-cli` delegated to Windows (its error named the
  Windows registry path).

No tasks.exe process was running during the build. The viewer
(`target\viewer-release\tasks_viewer.exe`) was stopped first.

## Skills

Applied with `git apply --check`, then `git apply`, both exit 0, in this order:

1. `target/evidence/to-verify/skills-after-install.patch`: `resolve-task/SKILL.md`,
   `resolve-task/references/verification.md`, `task-ledger/SKILL.md`
   (the `to-verify` status and the `update --status done` prerequisite guard).
2. `target/evidence/project-keys/skills-after-install.patch`: `create-task/SKILL.md`,
   `resolve-task/SKILL.md`, `task-ledger/SKILL.md` (`KEY-N` task IDs, `project-key`,
   cross-project exit 3).

`b40cc54` needs no skill text: the key cache (`<data-root>/project-keys.json`)
and the read-connection change are internal and change no command, output or
exit code the skills describe.

## Viewer

`pwsh -NoProfile -File viewer/tool/package.ps1` exit 0: 40 files, bundled
`tasks.exe` SHA-256 equal to the Windows build above, launch cases passed
(log `target/evidence/deploy-2026-09-28/viewer-package.log`).
`tasks_viewer.exe` SHA-256 `b56b160878db840e5bff4926b3242cf3473440d16bd58237619438e6a91d190c`.

## Verification

`flutter test test/integration/real_cli_clipboard_test.dart test/integration/real_cli_editor_test.dart`
against `target\release\tasks.exe` (the installed build), exit 0: 4 passed,
1 skipped. The skipped case, "a lost save acknowledgement is reconciled against
the commit", needs a `--features test-hooks` build, which the installed binary
is not. Log `target/evidence/deploy-2026-09-28/viewer-real-cli.log`.

The viewer was not restarted. Every live store is still on schema 4, and this
build refuses to read them until they are migrated.

## Live migration: stopped before any store changed

Pre-checks passed. `issues/active/project-key-task-ids/project-keys.csv` has 53
rows. Every key is 2-6 characters, `[A-Z][A-Z0-9]*`, not `T` plus digits, and
unique. Every `project_id` is unique, bound in `registry.json` at the CSV path,
and has `projects/<UUID>/TASKS.sqlite`. The registry and data root contain the
same 53 projects, so no registered project is missing from the CSV. `doctor`
reports schema 4 for all 53.

The first project stopped the run: ACV `973b97c0-d88d-4e46-9f84-885c5a84a559`.
`tasks backup --out ...` exits 6 with "has schema version 4; this build requires 6.
Run tasks migrate". The installed `backup` command cannot copy a store older than
schema 6. The only pre-upgrade backup for an old store is the one `migrate` makes
itself (spec.md, `TASKS.v<from>-pre-migrate-*.sqlite`). No migrate or
project-key command ran, and no store changed. Log
`target/evidence/deploy-2026-09-28/migration.log`.

Until the stores are migrated, the installed CLI refuses every live project.

### Second attempt, same day

The user chose a full copy plus `migrate`'s own backup. No tasks.exe or viewer
process was running. The whole data root (`projects\`, `registry.json`,
`registry.lock`, `project-keys.csv`, `viewer-cache.sqlite3`) was copied to
`%LOCALAPPDATA%\MaxLogic\tasks-cli-backups\pre-keys-20260928-full\`. Source and
copy match: 110 files, 63,840,773 bytes, and SHA-256 equal for every file,
including the 53 `TASKS.sqlite`. The hashes are in
`target/evidence/deploy-2026-09-28/full-copy-sha256.csv`.

The harness permission check then refused to run the migration script, so
`migrate` and `project-key --set` did not run on any project. All 53 stores
are still on schema 4 and have no key.
