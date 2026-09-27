# Deployment record: CLI and skills update 2026-09-26

Install of the token-efficiency CLI changes (`e60aaab`) and the updated
`task-ledger` 1.1.0, `create-task` 4.1.0 and `resolve-task` 6.2.0 skills.
Both binaries report `tasks 0.1.0 (commit b8a9240ba6e7)`.

## Executables

The installed paths are now symlinks to release builds instead of copies.

- Windows: `F:\CliTools\tasks.exe` → `..\projects\MaxLogic\tasks-cli\target\release\tasks.exe`
  - SHA-256 at install: `2b81b99b6d7620cc38c6568be60ebf44d4e9f19ac502e8d81d36c770b58e1962`.
    Later `verify-windows.ps1` runs rebuilt the same source through the
    symlink at later commits that do not touch the CLI, so the hash and the
    `--version` commit change with each rebuild. Since 2026-09-27 that script
    builds into `target/verify-cli` and no longer touches the installed binary.
  - Previous copy (`92793db00a29e723f26d221a6a7e6e29a282c10542b71395b027f81c94a3b3d2`,
    commit `8b1dabd`) was kept as `F:\CliTools\tasks.exe.pre-20260926` and
    deleted on request on 2026-09-27.
- Ubuntu/WSL: `/home/pawel/.local/bin/tasks` → `/home/pawel/.local/share/tasks-cli/target/release/tasks`
  - SHA-256: `dcdede23034a2cd4280caa0bf81e7ca93bb5cc06d607a02e1bbcc42b1ae34ae6`
  - Previous copy (`607d1841e23ba93c2713466606dfcf1973b77a468d4e80e36f195976dcd2848c`,
    commit `8b1dabd`) was kept as `/home/pawel/.local/bin/tasks.pre-20260926`
    and deleted on request on 2026-09-27.

The backups are gone, so rolling back means checking out an older commit and
rebuilding into the linked target directory.

## Viewer

`target\viewer-release\` was repackaged with the new `tasks.exe`
(`bundle-metadata.json`: source `b8a9240`, not dirty, launch test passed) and
restarted.

## Verification

- Every command the updated skills document (`show` with several IDs,
  `show --rules`, `--add-label`, `--body-file -` heredoc, stale-version exit 4,
  `history` with `changed=`) was run against a temporary data root.
- WSL `tasks show --help` lists `<IDS>...` and `--rules`. A WSL command run
  under `/mnt/f/projects` delegated to the Windows binary (its error message
  named the Windows registry path).
- No live backlog was read or modified.

## Behavior changes for other JSON readers

JSON output is compact. `show` omits rules unless `--rules` is passed and no
longer contains `deps`. `history --event` returns a nested `snapshot` instead of
`snapshot_json`. The data schema is unchanged; no migration was run.
