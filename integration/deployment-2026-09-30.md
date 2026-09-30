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
- ~~G10 packaging (and downstream G11/G12) needs a rerun once
  `target\viewer-release` is unlocked~~ - resolved below (2026-09-30 retry):
  the lock cleared on its own once the holding terminal session was closed.

## Retry: viewer gate rerun, lock cleared (2026-09-30, later same day)

The user reported closing the terminal that had likely held the directory
handle ("I think I closed the terminal holding the handle. try again.").

**Lock check**: `Rename-Item` round-trip on `target\viewer-release` (rename to
a temp name, then back) succeeded immediately - the directory was no longer
locked.

**`pwsh -NoProfile -File viewer/tool/verify-windows.ps1`** was run once more
(no `-IncludeWindowedIntegration`, so G12 is out of scope by design). Result:
**FAILED - 1 problem(s)**, this time only at the external UI Automation gate,
after every gate through packaging passed:

| Gate | Result |
| --- | --- |
| G00 toolchains | passed |
| G01 release CLI build | passed |
| G02 throwaway fixture seed | passed |
| G03 dart format | passed |
| G04 flutter analyze | passed |
| G05 flutter test (full suite) | passed |
| G06 test-hooks CLI closes the skip | passed |
| G07 shipped CLI restored | passed |
| G08 viewer end-to-end (headless, real store) | passed |
| G09 Windows release build | passed |
| G10 portable release bundle (packaging) | **passed** - lock gone, bundle written to `target\viewer-release`; launch cases `startup-opt-out`, `argument-error`, `cli-version`, `cli-viewer-info` all `ok` from a path with spaces and non-ASCII characters |
| G11 packaged release UI Automation | **failed** - `verify-release-uia.ps1` timed out after 45s: no project row exposed "alpha" with the expected open/total counts in its UIA name; last snapshot had 62 nodes, none matching. `app.so` sha256 `3b06a90a2ee1845804c79474f63b27f0359843176863e8af2ee8e4fde211613a`, viewer exe sha256 `b56b160878db840e5bff4926b3242cf3473440d16bd58237619438e6a91d190c`, CLI sha256 `3051b0247d602c41ceccb763f7a7228c14228675fab9e1d547afb23da0f381f8` |

G12 (windowed integration, opt-in) did not run, as expected without
`-IncludeWindowedIntegration`. V01-V13 rows were written to the summary as
usual (most carrying their standing "unavailable"/manual-only status; see the
script's own documentation for what each covers). Evidence root:
`viewer/target/evidence/viewer/2026-09-30-192405-verify-windows/`
(`verify-summary.md`, `verify-summary.json`, per-gate logs `00`-`12`,
including `12-release-uia.txt` with the full failure detail above).

### Viewer status (this retry)

Packaging succeeded, so `target\viewer-release\tasks_viewer.exe` is a fresh
bundle. It was launched visibly (`Start-Process`, normal window, no console
window) per instruction, even though G11 failed:

- PID `23596`, process name `tasks_viewer`, main window title "Tasks Viewer",
  confirmed rendered (non-empty title, valid window handle) about 5s after
  launch.
- Left running for the user to inspect; not stopped by this session.

### Outstanding (updated)

- G11 (packaged release UI Automation) still needs a rerun/fix: the probe's
  45s timeout does not find the expected "alpha" project row with its
  open/total counts in the UIA name. This looks like either a UIA timing
  issue (window not settled within 45s) or a real regression in how the
  project row exposes its accessible name; needs investigation with a longer
  timeout or a UIA tree dump comparison against a known-good build before
  concluding which.
- Console-window proof (`CREATE_NO_WINDOW`) remains unproven pending TSK-008,
  unchanged from the previous entry.

### TSK-015: G11 UIA probe fix (this entry)

Root cause: `verify-windows.ps1` passed the bare project name ("alpha") to
`verify-release-uia.ps1 -ExpectedProjectName`, but the Projects pane row
renders `ProjectItem.displayName` = "name (KEY)" per viewer/spec.md section
11 (the same defect already fixed for the headless e2e fixture in 1d27666).
Fixed by building the expected name from the fixture manifest's `name` and
`project_key` fields. Also hardened the probe's row matcher
(`verify-release-uia.ps1`) with `[WildcardPattern]::Escape` on the project
name so a key containing `[`/`]`/`*`/`?` still matches literally, and added
Pester cases for a keyed row and a bracketed-name row.

- Full gate rerun: `pwsh -NoProfile -File viewer/tool/verify-windows.ps1`,
  exit 0, all 12 gates passed including G11 (packaged release UI Automation).
  Evidence: `viewer/target/evidence/viewer/2026-09-30-193351-verify-windows/`.
- Pester: `Invoke-Pester viewer/tool/tests/verify-release-uia.Tests.ps1`,
  8 passed, 0 failed (includes the new keyed-row and bracketed-name cases).
- Viewer relaunched visibly from the freshly packaged
  `target\viewer-release\tasks_viewer.exe` as PID `282344`; left running.

## "Gate + install" authorization (this entry, 2026-09-30, later same session)

User authorization: verify pid `197828` runs the packaged viewer, stop it,
run `verify-windows.ps1` directly through G11 without changing the script or
skip policy, install on a pass, relaunch the viewer visibly, and record this
entry - all at commit `47ab4f5` (`47ab4f55875727136278f3fa504e189176132978`,
`main`). The Rust final-gate tiers (Windows 274, Linux 278, real delegation)
had already passed at this HEAD; evidence:
`target/evidence/final-gate/2026-09-30-head-47ab4f5/`
(`windows-cargo-fmt.log`, `windows-cargo-clippy.log`, `windows-cargo-test.log`,
`linux-cargo-fmt.log`, `linux-cargo-clippy.log`, `linux-cargo-test.log`,
`windows-verify-cli-build.log`, `linux-verify-cli-build.log`,
`delegation-01`..`05` logs, `viewer-verify-windows*.log/.pid`). Only the
viewer gate remained open, blocked earlier on G05's console-skip policy being
misread by a certifier that launched `pwsh` through
`Start-Process -WindowStyle Hidden` (a hidden console), unlike the passing
direct-Bash runs where `decision-2026-09-29` accepts the skip as unproven.

### Preconditions and viewer gate, attempt 1

Confirmed pid `197828` ran `F:\projects\MaxLogic\tasks-cli\target\viewer-release\tasks_viewer.exe`
(via `CommandLine`), then stopped it (`Stop-Process -Force`); confirmed gone.
Nothing else was touched.

`pwsh -NoProfile -File viewer/tool/verify-windows.ps1` run directly from the
Bash tool (no `Start-Process`, no hidden console). Result: **FAILED - 1
problem(s)**. G00-G10 passed, including G05 (584 passed, 2 skipped - the
acknowledgement-loss case closed by G06, and the console-window
`CREATE_NO_WINDOW` case correctly accepted as unproven, pending TSK-008,
confirming the direct-invocation route avoids the earlier certifier defect).
G11 (packaged release UI Automation) **failed** this time for a different
reason: `verify-release-uia.ps1` timed out after 45s with only one UIA node
(`FLUTTERVIEW`) in the last snapshot - no named Projects region, Search edit,
Sort button or project row. `app.so` sha256
`3b06a90a2ee1845804c79474f63b27f0359843176863e8af2ee8e4fde211613a`, viewer
exe sha256 `b56b160878db840e5bff4926b3242cf3473440d16bd58237619438e6a91d190c`,
CLI sha256 `24d5b096b2f9800f8b2b9324732df9b0d8dd902c48213f46ffdab2673fb5cc1b`.
Evidence: `viewer/target/evidence/viewer/2026-09-30-224326-verify-windows/`.

Per instruction, stopped short of install; relaunched the existing packaged
viewer visibly as PID `279120` and reported the failure for direction.

### Retry, attempt 2 (coordinator-directed)

Coordinator noted no Flutter UI code changed since the last passing G11 run
(`2026-09-30-193351`, 70 UIA nodes) - only `src/viewer.rs` (stats batching)
and tests changed since - and that a tree holding only `FLUTTERVIEW` usually
means the semantics tree never turned on, most consistent with a flaky
startup/timing condition rather than a code regression. Directed: stop PID
`279120` (after checking its path) and rerun the gate once.

Confirmed PID `279120` ran the same packaged `tasks_viewer.exe` path, stopped
it, confirmed gone. Checked machine state before rerun: single monitor
(`DISPLAY6`, primary, 3440x1440, no secondary monitor), no interactive
console session query tool available (`query` not present on this box) but
no lock-screen indication.

`pwsh -NoProfile -File viewer/tool/verify-windows.ps1` run again, unmodified.
Result: **OK - 12 gates**, all passed including G11: 70 native UIA nodes,
project region and Settings exposed, matching the earlier passing run's
profile. Rebuilt artifact hashes: CLI `49026f096558b612853670ee544aac94c14bb73e1fa938f4cd76f7002900b967`
(release-restore build after G06/G07's test-hooks round trip), viewer
`b56b160878db840e5bff4926b3242cf3473440d16bd58237619438e6a91d190c` (unchanged
- no Flutter source changed). Evidence:
`viewer/target/evidence/viewer/2026-09-30-224840-verify-windows/`.

Conclusion: the attempt-1 G11 failure was transient (a timing/startup race
in the external UIA probe against the freshly launched packaged window, not
a code regression - no Flutter or Rust semantics-affecting change occurred
between the two runs, and the second run's node count and exposed controls
match the known-good baseline exactly). No corrective code change was made
or needed; console_window_proof remains `unproven: no interactive console in
this run (decision 2026-09-29, pending TSK-008)` in both attempts' summaries.

### Install (gate passed on retry)

- Windows: `cargo build --release --locked` in the default target dir,
  finished in 18.93s. `F:\CliTools\tasks.exe` symlink target unchanged
  (`..\projects\MaxLogic\tasks-cli\target\release\tasks.exe`). Version
  `tasks 0.1.0 (commit 47ab4f558757)`. SHA-256
  `e29d81b03f876ee0b94e66375cfb0c1318b0b8e27f9a96fe368481c31f47cfc6`, identical
  for the symlink target and the installed path. Read-only
  `tasks list --limit 1` exits 0 (`has_more: false`).
- Ubuntu/WSL: built via a script file (`~/.profile` and `~/.cargo/env`
  sourced for `cargo` and `TASKS_WINDOWS_EXE` on PATH/env) with
  `CARGO_TARGET_DIR=~/.local/share/tasks-cli/target cargo build --release --locked`
  from `/mnt/f/projects/MaxLogic/tasks-cli`, finished in 13.37s.
  `~/.local/bin/tasks` symlink target unchanged
  (`/home/pawel/.local/share/tasks-cli/target/release/tasks`). Version
  `tasks 0.1.0 (commit 47ab4f558757)`. SHA-256
  `da0535f762c1ad7fbfc68bded5c09539c0b750c2de0cc6a35a0a1665792f036f`. Delegated
  read-only `tasks list --limit 1` exits 0 (`has_more: false`), confirming
  delegation to the Windows binary via `TASKS_WINDOWS_EXE=/mnt/f/CliTools/tasks.exe`.

### Viewer status (this entry)

Relaunched visibly (`Start-Process`, normal window, no console window) from
the freshly packaged `target\viewer-release\tasks_viewer.exe`: PID `301440`,
process name `tasks_viewer`, confirmed running from that path. Left running.

### Outstanding (unchanged)

- Console-window proof (`CREATE_NO_WINDOW`) remains unproven pending TSK-008.
