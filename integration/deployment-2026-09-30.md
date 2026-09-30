# Deployment record: install current CLI, viewer gate check 2026-09-30

Install authorized by the user on 2026-09-30 ("update it to the newest
version"), covering the working tree at commit `1d27666`
(`1d276661517495dfc40d89b105251f3bcb6d8bc6`, `main`) - no new source commits
landed since the previous deployment (`deployment-2026-09-28.md`). Both
binaries report `tasks 0.1.0 (commit 1d2766615174)`.

## Executables

- Windows: `F:\CliTools\tasks.exe` -> `..\projects\MaxLogic\tasks-cli\target\release\tasks.exe`
  (symlink confirmed unchanged), built with `cargo build --release --locked`
  in the default target dir. Finished in 21.04s.
  SHA-256 `4892fd03c4cc5b1ba4d057111b8663f92ae082278ad5d49f6bf6ed753af30c33`,
  identical for the symlink target and the installed path.
- Ubuntu/WSL: `~/.local/bin/tasks` -> `~/.local/share/tasks-cli/target/release/tasks`
  (symlink confirmed unchanged), built with
  `CARGO_TARGET_DIR=~/.local/share/tasks-cli/target cargo build --release --locked`
  from `/mnt/f/projects/MaxLogic/tasks-cli` (script file, `~/.profile` sourced
  for `cargo` and `TASKS_WINDOWS_EXE` on PATH/env). Build was already
  up to date for this commit (`Finished ... in 0.11s`, no recompile needed).
  SHA-256 `c5314a5a2fdc8baf927fd520bbdff06760bda12eb6303be1a45c77b143c57118`,
  identical for the installed path and the target-dir build output.

## Verification reads

- Windows: `F:\CliTools\tasks.exe --version` -> `tasks 0.1.0 (commit 1d2766615174)`;
  SHA-256 of `F:\CliTools\tasks.exe` equals SHA-256 of
  `target\release\tasks.exe` (both `4892fd03...`); read-only
  `tasks list --limit 1` from this repo exits 0 (`has_more: false`).
- WSL: `~/.local/bin/tasks --version` -> `tasks 0.1.0 (commit 1d2766615174)`;
  installed-path and target-dir hashes equal (`c5314a5a...`); delegated
  read-only `tasks list --limit 1` from `/mnt/f/projects/MaxLogic/tasks-cli`,
  with `TASKS_WINDOWS_EXE=/mnt/f/CliTools/tasks.exe` from `~/.profile`,
  exits 0 (`has_more: false`), confirming delegation to the Windows binary
  with the two real executables (no argument mock).

No tasks.exe process was running before or during either build.

## Viewer gate

Preconditions checked before the run: no `flutter_tester`, `dart` or
`tasks_viewer` process running; `target\viewer-release` present but empty
(0 files) - consistent with the architect's just-prior check.

`pwsh -NoProfile -File viewer/tool/verify-windows.ps1` was run once. Result:
**FAILED - 1 problem(s)**, at the packaging step (portable release bundle,
gate `G10`), after every preceding gate passed:

| Gate | Result |
| --- | --- |
| G00 toolchains | passed |
| G01 release CLI build | passed |
| G02 throwaway fixture seed | passed |
| G03 dart format | passed |
| G04 flutter analyze | passed |
| G05 flutter test (full suite) | passed - 584 passed, 2 skipped (documented: G06 closes one; the console-window `CREATE_NO_WINDOW` case is unproven pending TSK-008, decision 2026-09-29) |
| G06 test-hooks CLI closes the skip | passed - 3 passed |
| G07 shipped CLI restored | passed |
| G08 viewer end-to-end (headless, real store) | passed - 5 passed |
| G09 Windows release build | passed |
| G10 portable release bundle (packaging) | **failed**: `The process cannot access the file 'F:\projects\MaxLogic\tasks-cli\target\viewer-release' because it is being used by another process.` |

G11 (packaged release UI Automation) and G12 (windowed integration) did not
run as a result. Evidence root:
`viewer/target/evidence/viewer/2026-09-30-173414-verify-windows/`
(`verify-summary.md`, `verify-summary.json`, per-gate logs `00`-`10`).

### Lock investigation

`Rename-Item` on `target\viewer-release` failed twice (before and after a
retry) with the same "used by another process" error, so the lock was not a
transient scan. No `flutter_tester`, `dart`, `tasks_viewer`, `explorer`
(other than the normal per-desktop instances) or `OneDrive` process held an
obvious handle. This machine has a large number of concurrent `pwsh`/`cmd`/
`bash`/`conhost` sessions (over 100 processes from unrelated work), and the
most likely cause is one of those having its current working directory set
inside `target\viewer-release`, which holds a directory handle open on
Windows. Per instruction, nothing was killed to test this. No corrective
action was taken beyond the investigation above.

## Viewer status

Not repackaged and not relaunched: packaging failed at G10 before producing
a bundle, so `target\viewer-release` remains empty and there is nothing new
to launch. The viewer was not touched otherwise (no running instance existed
before or after this session).

## Outstanding

- Console-window proof (`CREATE_NO_WINDOW`) remains unproven pending TSK-008,
  as recorded by G05 and carried into this run's summary
  (`console_window_proof: unproven ... pending TSK-008`).
- G10 packaging (and downstream G11/G12) needs a rerun once
  `target\viewer-release` is unlocked; identify and close the holding
  process (or its owning session) rather than force-deleting the directory.
