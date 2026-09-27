# Tasks Viewer verification report

## 2026-09-27: verification no longer rebuilds the installed CLI

`F:\CliTools\tasks.exe` links to `target\release\tasks.exe`. Before this change,
every `verify-windows.ps1` run rebuilt that file three times, once as a
test-hooks build. Now its plain, test-hooks and restore builds, and those of
`measure.ps1`, go to `target\verify-cli`. `real_cli_editor_test.dart` and
`real_cli_clipboard_test.dart` receive that build through
`--dart-define=TASKS_VIEWER_TEST_CLI=<path>`. Without the define they still
fall back to `target\release`. Two related fixes:

- Dot-sourcing `package.ps1` rebound `$CliExecutable` to package.ps1's
  default, so G10 bundled `target\release\tasks.exe` instead of the verify
  build. This went unnoticed while both paths were the same file. Verify now
  captures the value before the dot-source.
- `package.ps1` now refuses to replace a bundle that a running process was
  started from. It used to delete part of the folder, then fail on the locked
  DLL, leaving the running viewer without its `data\` folder.

`verify-windows.ps1` ran on `9bbd937` with these edits uncommitted and passed
**12/12 gates**:

- G05: 547 passed, with 1 documented skip closed by G06 (3 passed).
- G08: 5 passed.
- G11: 70 UIA nodes.
- G10: the bundled `tasks.exe` matched the verify build (`e6ba248e…`).
- The installed `target\release\tasks.exe` kept its SHA-256
  (`0b96f3ea…`) and timestamp across all four runs below.
- Evidence: `viewer/target/evidence/viewer/2026-09-27-103917-verify-windows/`.

Three earlier runs from the same day are kept:

- `2026-09-27-102610-verify-windows`: G10 failed because the running viewer
  locked its DLL. That failure led to the new `package.ps1` guard.
- `2026-09-27-103136-verify-windows`: G00–G11 passed, but the run reported the
  bundle/verify-CLI hash mismatch that exposed the rebinding bug.
- `2026-09-27-103510-verify-windows`: G11 failed with a `FLUTTERVIEW`-only
  UIA snapshot, the known intermittent exposure. The next run passed G11.

Pester passes 65/65, and PSScriptAnalyzer reports no findings for the three
scripts. `measure.ps1` was not run, because it is a long benchmark. Afterwards,
`target\viewer-release` was repackaged with the installed CLI and the viewer
was restarted.

## 2026-09-26: UI polish, Ctrl+V list search and lean CLI output

Covers `7dfbbd1`, `a1985d4` and `dc98db6`: list layout and spacing, Clear
filters in the empty state, the table project summary, the type scale,
Ctrl+V into the list search, acceptance of the lean CLI history shape, and
committed layout goldens. `33534a5` formats three test files and fixes a
`verify-windows.ps1` bug. The script read its fixture-cleanup roots only after
packaging, so a failure in an earlier gate left the throwaway store in place.

`verify-windows.ps1` ran at `33534a5`. The tree was dirty only with the
uncommitted AGENTS.md, deployment record and report text. It passed **12/12
gates**:

- G05: 547 passed, with 1 documented skip that G06 closes (3 passed).
- G08: all 5 real-store end-to-end cases passed.
- G11: found 70 native UIA nodes; the project region and Settings were exposed.
- Probed `data/app.so`: `fcd0149b9d57bbe92fb4679c38d35e261dc1781a4c5b01a5a54b6c9a2da91eb4`.
- Evidence: `viewer/target/evidence/viewer/2026-09-26-111817-verify-windows/`.

Two earlier runs failed and are kept:

- `2026-09-26-111120-verify-windows` failed G03 on the three unformatted
  files. That failure exposed the cleanup bug.
- `2026-09-26-111255-verify-windows` passed G00–G10 but failed G11 after 45 s.
  The UIA snapshot held only `FLUTTERVIEW`, the same intermittent exposure
  recorded on 2026-09-23. The unchanged bundle passed G11 on the next run.
  The cause is still unexplained.

The layout goldens use the Segoe UI files installed on this machine. They ran
in G05; they skip only on hosts that lack those fonts. As before, the window
workflows (V08) and NVDA speech walkthroughs (V10) remain manual.

## 2026-09-23: packaged release UI Automation gate

`viewer/tool/verify-windows.ps1` now runs G11 by default after G10 packaging. It seeds a
fresh synthetic store with the bundled CLI, launches that exact packaged
`tasks_viewer.exe` with isolated settings, and reads the external Windows UIA
tree without keyboard or pointer input. It checks the Projects region, the
Search projects Edit, the Sort button, and the seeded project row. The gate
also compares the probed `tasks_viewer.exe`, `tasks.exe` and `data/app.so`
SHA-256 values with the packaged and built candidate.

The final run at source HEAD `4da96d4` with the gate edits still uncommitted
(`source_dirty: true`) passed **12/12 gates**. G05 reported 481 passed and one
documented skip, closed by G06 (3 passed); G08 passed all 5 real-store cases.
G11 found 62 UIA nodes and passed all four native exposure checks. The probed
`data/app.so` hash was `0c6aea2ed14773ea98052c937e13eb31ad6d110993ff3cdc6926d61aec362ae0`.
Evidence: `viewer/target/evidence/viewer/2026-09-23-release-uia-gate-2/`
(`12-release-uia.txt`, `verify-summary.json`, `verify-summary.md`).

The first complete run at
`viewer/target/evidence/viewer/2026-09-23-release-uia-gate/` failed G11:
its UIA snapshot contained only the window and `FLUTTERVIEW` pane. The gate
did not turn that into a pass. A later focused probe on the same packaged
release exposed the full tree. G11 now uses its own pristine fixture; the
complete rerun passed. The first failure remains evidence of intermittent
UIA exposure, not a proven explanation of its cause. This automated check
does not complete V08's window workflows or V10's NVDA speech walkthroughs.

## Earlier headless baseline

Candidate: **`823094a`** - `fix(viewer): discover migrated task store on startup`,
branch `main`, tree clean at every measurement recorded here. Nothing was pushed, no live backlog was
migrated or modified, no installed executable was replaced, and no real Startup entry or clipboard
was touched. One post-gate read-only catalog probe opened the standard task store and returned its 51
projects. Every test fixture was synthetic, disposable and rooted outside the repository.

This is the headless verification the user asked for: *"test the GUI in headless mode please. do not
steal my mouse and keyboard"*. No command below delivers keyboard or pointer input to the desktop,
holds a foreground lease, invokes a UI Automation element, drives a screen reader or reads the real
clipboard. Keys and pointer events exist only inside the Flutter test binding, so the desktop stays
usable while the gates run. Rows that need a live session are marked unavailable and are never
claimed as passing.

## Result summary

| Area | Result |
| --- | --- |
| `viewer/tool/verify-windows.ps1` headless gate run | **passed, 11/11 gates** at `823094a`, `source_dirty: false` |
| Flutter gates | format **passed**, analyze **passed**, full suite **481 passed / 1 documented skip**, test-hooks suite **3 passed**, headless end-to-end **5 passed** |
| Default migrated store | bundled CLI read-only probe returned **51/51 projects** from `%LOCALAPPDATA%\MaxLogic\tasks-cli`; `start-viewer.lnk` targets the refreshed bundle |
| Rust gates, Windows x64 | fmt, clippy `--all-targets`, test (**214 passed**, 35 targets), release build - all exit 0 |
| Rust gates, native Ubuntu/WSL x64 | the same four commands in `target/linux` (**218 passed**, 35 targets) - all exit 0 |
| Real two-binary WSL delegation smoke | **passed** - delegated `viewer projects/tasks/update` exit 0, native Linux refuses the Windows root |
| Section 10 performance (`measure.ps1`) | 8 measured rows passed (7 with wide margin, M06 with 0.7 %) and 3 rows unavailable |
| V01..V13 | V01-V07 and V11 covered; V09 measured with 3 unavailable rows; **V08, V10, V12, V13 unavailable** |
| Release acceptance | **incomplete** - the required manual rows above are unavailable, so spec section 11 acceptance cannot be declared |

## 1. Source identity and evidence roots

All paths are relative to `F:\projects\MaxLogic\tasks-cli`.

| Purpose | Evidence root |
| --- | --- |
| Final headless gate run (G00-G10) | `viewer/target/evidence/viewer/2026-09-23-default-discovery-a11y/` |
| Previous headless gate run | `viewer/target/evidence/viewer/2026-09-22-headless-verify-6-caretfix/` |
| Windows Rust gates | `target/evidence/init-default-20260922/windows.log` |
| Linux Rust gates (final) | `target/evidence/init-default-20260922/linux.log` |
| Linux Rust gates, delegation-switch first failure | `viewer/target/evidence/viewer/2026-09-22-rust-gates-linux/` (`FINDING.md`) |
| Two-binary WSL delegation smoke | `viewer/target/evidence/viewer/2026-09-22-wsl-delegation/` |
| Delegated request-file first failure | `viewer/target/evidence/viewer/2026-09-22-wsl-delegation-request-file-failure/` (`FINDING.md`) |
| Section 10 acceptance measurements | `viewer/target/evidence/viewer/2026-09-22-measure-acceptance-clean/` |
| Section 10 earlier run (M06 failed) | `viewer/target/evidence/viewer/2026-09-22-measure-acceptance/` |
| M06 follow-up profile | `viewer/target/evidence/viewer/2026-09-22-m06-profile/` |
| Bella generation and integrity | `target/evidence/viewer/2026-09-21-bella-generation/` |
| Live NVDA walkthroughs (pre-directive) | `viewer/target/evidence/viewer/2026-09-22-slice4-nvda/`, `...-slice5-nvda/`, `...-slice6-nvda/`, `target/evidence/viewer/2026-09-21-nvda-walkthrough-a/` |

`viewer/target/` and `target/` are gitignored generated trees; the logs are machine-local evidence and
are not part of the shipped source. Everything committed for this milestone is source, tests,
scripts, assets and documentation.

## 2. Toolchains and machine

| Item | Value |
| --- | --- |
| Flutter | 3.44.1 stable, framework `924134a44c`, engine `39b1f70437` |
| Dart | 3.12.1 (DevTools 2.57.0) |
| Rust | rustc 1.98.1 (`48a229cea`), cargo 1.98.1 (`797e8a9bc`) |
| Windows | Windows 11 Home 10.0.26200 build 26200, x64 |
| CPU / RAM | AMD Ryzen 9 5950X (16 cores / 32 logical), 127.9 GiB |
| Performance power plan | "Najwyzsza wydajnosc" (High performance), GUID `f6c1b926-...` |
| Linux | Ubuntu 22.04.5 LTS under WSL2, kernel 6.18.33.2-microsoft-standard-WSL2, x86_64 |
| PowerShell | 7.6.6, Pester 5.8.0, PSScriptAnalyzer 1.25.0 |
| NVDA (pre-directive walkthroughs only) | 2026.2, `2026.2.0.57664` |

The display used by both performance runs and the earlier NVDA sessions was a single 3440x1440
monitor at system DPI 96 (100 % scaling), Polish keyboard layout `0415`.

## 3. Commands, counts and artifacts

### 3.1 Final headless gate run

`pwsh -NoProfile -File viewer/tool/verify-windows.ps1 -EvidenceRoot viewer/target/evidence/viewer/2026-09-23-default-discovery-a11y`

Generated 2026-09-23T12:35:14Z at `823094a` with `source_dirty: false`.

| Id | Gate | Status | Detail |
| --- | --- | --- | --- |
| G00 | toolchains | passed | Flutter/Dart/Rust/machine recorded |
| G01 | release CLI build | passed | first build of `tasks.exe`, sha256 `053819e3...2460` |
| G02 | throwaway fixture seed | passed | alpha 28 tasks (27 open), beta 4 tasks |
| G03 | dart format | passed | `lib test integration_test` unchanged |
| G04 | flutter analyze | passed | `--fatal-infos` clean |
| G05 | flutter test (full suite) | passed | 481 passed, 1 skipped (the documented acknowledgement-loss case) |
| G06 | test-hooks CLI closes the skip | passed | 3 passed, 0 skipped |
| G07 | shipped CLI restored | passed | rebuilt plain release CLI sha256 `aa7b96a5...36fe` |
| G08 | viewer end-to-end (headless, real store) | passed | 5 passed, 0 skipped, own freshly seeded store |
| G09 | Windows release build | passed | `tasks_viewer.exe` sha256 `b56b1608...190c` |
| G10 | portable release bundle | passed | 40 files, 20 clips, 39 hash entries re-verified, launch test passed |

The windowed integration gate (`-IncludeWindowedIntegration`) was deliberately not requested, and the
harness says so in every summary rather than silently skipping it.

### 3.2 Rust gates

Both platforms ran `cargo fmt --check`, `cargo clippy --locked --all-targets`, `cargo test --locked`
and `cargo build --release --locked`, with separate target directories, and all four commands exited 0
on each.

| Platform | Tests | Targets | Release artifact |
| --- | ---: | ---: | --- |
| Windows x64 | 214 passed, 0 failed, 0 ignored | 35 | deployed `F:\CliTools\tasks.exe`, 6 019 584 bytes, sha256 `92793db00a29e723f26d221a6a7e6e29a282c10542b71395b027f81c94a3b3d2` |
| Ubuntu/WSL x64 | 218 passed, 0 failed, 0 ignored | 35 | deployed `/home/pawel/.local/bin/tasks`, 7 789 488 bytes, sha256 `607d1841e23ba93c2713466606dfcf1973b77a468d4e80e36f195976dcd2848c` |

Linux ran with `CARGO_TARGET_DIR=target/linux` and with `TASKS_WINDOWS_EXE` cleared so the suite
exercises the native Linux CLI; the switch was set to `/mnt/f/CliTools/tasks.exe` in the login shell
before the run cleared it, which is recorded in `00-host.txt` of that run.
Both gate sets ran at `8b1dabd`, the identity-in-init candidate, with the Windows run recording 214
tests and the native Ubuntu/WSL run recording 218. The current `823094a` changes only viewer Dart UI
and tests after those Rust gates, so the Rust evidence remains applicable.

### 3.3 Real two-binary WSL delegation

A synthetic Windows-owned root inside the evidence directory was driven through the Linux wrapper
with the real Windows executable: `create` exit 0, `viewer projects` exit 0 (project present with
statistics), `viewer tasks` exit 0 (`total_count=1`), `viewer update` exit 0 (version 1 -> 2), and a
Windows-native `show` afterwards read back title `Delegated viewer update` at version 2. Native Linux
refused the Windows root twice with `invalid_path` and exit 2, a missing `--windows-exe` failed with
`interop` and exit 6 with no fallback, and `linux_owned_exists=no` confirms no Linux process created
or opened a store on that root. The run records `source_commit=a15a809`, `source_dirty=0`.

Cleanup was verified afterwards: the live registry still holds exactly its 51 pre-existing bindings,
and no synthetic probe root (`/tmp/tasks-probe-manual`, the probe project directory) remains.

### 3.4 Flutter command set

The gate run covers the spec command list from `viewer/`: `flutter pub get`,
`dart format --output=none --set-exit-if-changed lib test integration_test`,
`flutter analyze --fatal-infos`, `flutter test --reporter expanded` and
`flutter build windows --release`.

### 3.5 Standard-store discovery proof

After G10, the packaged `tasks.exe` ran one read-only `viewer projects` request against
`%LOCALAPPDATA%\MaxLogic\tasks-cli`. It exited 0 with protocol version 1 and returned all 51 projects
reported by the registry. The root shortcut still targets
`target\viewer-release\tasks_viewer.exe`. The command, request and result are retained in
`12-default-live-registry-probe.txt`. This probe did not start the viewer, save settings or mutate
the task store.

## 4. Failures, aborted runs and reruns

Every failure below is retained in its own evidence directory and was followed by a fix or an
explicit rerun. No passing run reuses a failed run's counts.

| # | Run | What happened | Resolution |
| --- | --- | --- | --- |
| 1 | `2026-09-22-112757-verify-windows` | aborted at start: `-EvidenceRoot` binding error (empty `Gates` collection) | harness parameter fixed |
| 2 | `2026-09-22-112809-verify-windows` | `dart format` reported unformatted files (exit 1) after G02 | files formatted; log kept |
| 3 | `2026-09-22-112856-verify-windows` | full Flutter suite failed after G04 | failing widget test fixed; log kept |
| 4 | `2026-09-22-headless-verify` (first full run, `5af13de`, dirty) | G08 end-to-end failed one case: "the editor never left edit mode after Save" (45 s timeout) | G08 now seeds its own pristine store instead of reusing the shared fixture store; the case passed in every later run |
| 5 | `2026-09-22-headless-verify-2` and `-3` | both passed all 10 gates but ran with `source_dirty: true` (documentation still in flight) | rerun on a clean tree |
| 6 | `2026-09-22-headless-verify-4-clean` and `-5-clean` | clean-tree passes at `380093c` and `b56f883` | superseded by later commits |
| 7 | `2026-09-22-rust-gates-linux` | `cargo test --locked` exit 101 on source `18dcd9f`: `backup_race` asserted `[0, 2]` and saw `[2, 2]` because the login shell exported `TASKS_WINDOWS_EXE` and both children delegated to Windows, which correctly refused the `\\wsl.localhost\...` root | rerun with the interop switch cleared (`...-linux-2`, then `-linux-3` for `a15a809`); cause documented in that directory's `FINDING.md` |
| 8 | `2026-09-22-wsl-delegation-request-file-failure` | delegated viewer commands exited 6: `--request-file` was missing from the wrapper's translated path options | fixed in `a15a809` with two focused tests (RED 2 failed -> GREEN 4 passed); delegation rerun passes (`...-wsl-delegation/`) |
| 9 | `2026-09-22-measure-smoke` | the first smoke attempt aborted on a harness bug (`limit` must be between 1 and 200; got 1000); a second, deliberately short 2-iteration smoke run is retained with two rows marked failed, because a p95 over n=2 is not a percentile | fixed; the 30-iteration acceptance runs are the ones this report relies on |
| 10 | `2026-09-22-measure-acceptance` | 30-iteration run at `380093c` with M06 p95 **10115.4 ms** (max 11 243.1 ms) against a 10 000 ms target | rerun `-clean` at `b56f883` passed at 9928.2 ms p95; both runs are retained - see section 6 |
| 11 | `2026-09-22-headless-verify-6-caretfix` | clean-tree rerun at `719ba66` after the guard-Cancel caret fix; two new Windows-variant widget tests landed with it | passed 11/11 and became the run this report quotes |
| 12 | `2026-09-23-headless-verify-8-semantic-audit` | clean-tree rerun at `f8ba86a`; the rendered semantics audit and task-scope labels landed after the previous headless candidate | passed 11/11; superseded by the default-discovery run |
| 13 | `2026-09-23-default-discovery-a11y` | clean-tree rerun at `823094a`; default store discovery, first setup, named dialog routes and empty row-navigation cleanup landed after the previous candidate | passed 11/11; this is the current run quoted above |

## 5. Required test matrix

Status is the project-level truth, not just what one harness covered. "Unavailable" means a required
live or human gate that this run cannot perform by direction.

| Id | Status | Evidence |
| --- | --- | --- |
| V01 | passed | `tests/viewer_api.rs` protocol cases in the Windows and Linux gate sets: JSON-only commands, malformed/oversized/unreadable requests, duplicate keys at every level, unknown fields and wrong types, enum/offset/limit bounds, missing executable and nonzero exits - 24 tests in that file |
| V02 | passed | the same gate sets: two bindings of one UUID listed once with statistics, missing roots, corrupt databases, empty registries, state filters, literal and case-sensitive queries, both sort directions with UUID tie-breaks, stable snapshots; the viewer catalog slice over the seeded store ran in G08 |
| V03 | passed | the same gate sets: combined filters, literal `%_`/quotes, Unicode, body-only matches, numeric IDs, all sorts with ties, limit/offset/end boundaries, event-bound snapshots; G08 also ran the literal `%_` search and priority order against a real store |
| V04 | passed | G05 editor/validation/rollback suites, G06 acknowledgement loss against the real CLI, G08 save plus second-process read-back; the live NVDA walkthrough C steps 1-3 add real-clipboard-free ground truth for one version-checked commit and one conflict refusal |
| V05 | passed | G05 draft and navigation suites: Save/Discard/Cancel per leaving action, restart restore, corrupt settings, write failures, store identity |
| V06 | passed | G05 clipboard suites over the fake clipboard (known/unknown/repeated IDs, collisions, already-enriched text, no text, Unicode and newlines, limits, contention, preview never writes); walkthrough D steps D0-D2r were run live before the headless-only direction using synthetic text only |
| V07 | passed | G05 widget, semantics and accessibility suites: control names/roles/state, named route scopes, unnamed-field detection, focus order and modal focus return, disabled reasons, loading announcements, text scaling, contrast themes and the rendered-tree audit |
| V08 | unavailable | G08 proves discover/filter/sort/read/edit/refresh headlessly over a real store, but the packaged-candidate window flows and any UI Automation step need a live desktop, which this directive forbids |
| V09 | passed with 3 unavailable rows | `viewer/tool/measure.ps1` acceptance run: fixtures, percentiles and raw samples recorded; M09-M11 (frame time, peak working set, NVDA on/off) unavailable - section 6 |
| V10 | unavailable | walkthroughs B and C ran live under NVDA on 2026-09-22 with speech logs and CLI ground truth, and walkthrough D reached D0-D2r live; walkthrough A never ran beyond the blocked attempt, walkthroughs E and F have not run. Walkthrough C's step-4a caret defect is fixed in `719ba66` with a RED/GREEN Windows-variant widget test, but that step still needs a live re-run. This row needs every walkthrough, so it stays unavailable - section 7 |
| V11 | passed | G05 hotkey suites: F1/F2/F3 focus targets, remembered-list Ctrl+F, scoped access keys, modal isolation, key-repeat suppression, Ctrl+D and Ctrl+E routing, the permanently visible Hotkey help button/F10 with focus return |
| V12 | unavailable | startup registration and single-instance classification pass in G05 and the packaged launch test covers the no-window opt-out path, but a real sign-in proof in a disposable Windows account and the changed/missing-monitor checks need a live session. High-DPI change testing is skipped at the user's request. |
| V13 | unavailable | generation, manifest/hash integrity, packaged clips, offline verification and package rejection are proven. On 2026-09-24 the user confirmed hearing Bella speak the Test voice clip in the running viewer. Full clip listening and other playback-behavior checks remain open - section 7. |

## 6. Section 10 performance and correctness evidence

`pwsh -NoProfile -File viewer/tool/measure.ps1` seeded deterministic release fixtures (recorded seed
`20260922`) with the release CLI and timed 30 runs after one discarded warm-up. Raw samples, host
details and fixture digests: `viewer/target/evidence/viewer/2026-09-22-measure-acceptance-clean/`
(`03-measurements.json`, `measure-summary.json`, `measure-summary.md`).

The two `source_commit` values differ: the accepted `-clean` run measured the `b56f883` build, the
earlier failing run a dirty `380093c` tree. The current candidate `823094a` adds viewer startup
discovery, first setup and accessibility checks after those measurements; none of those touches the
native Windows CLI rows measured here, but these numbers are not a re-measurement of `823094a`.

| Id | Row | Target p95 | p50 | p95 | max | Status |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| M08 | cold start: first usable project list (100 projects) | 6000 ms | 781.4 | 781.4 | 781.4 | passed |
| M01 | first task page (100 000-task project) | 500 ms | 381.1 | 462.3 | 487.5 | passed |
| M02 | task detail, 2 KiB body | 300 ms | 23.2 | 40.6 | 42.4 | passed |
| M03 | task detail, 1 MiB body | 1000 ms | 24.4 | 46.0 | 64.2 | passed |
| M04 | save acknowledgement, uncontended | 750 ms | 31.3 | 54.7 | 62.0 | passed |
| M05 | project first page with statistics (100 projects) | 5000 ms | 1309.0 | 1415.6 | 1426.6 | passed |
| M06 | project first page with statistics (1000 empty projects) | 10 000 ms | 8223.5 | 9928.2 | 9960.6 | passed |
| M07 | literal `%_` body search (100 000 tasks) | 2000 ms | 1306.4 | 1409.3 | 1442.5 | passed |

Unavailable rows, recorded with their reasons rather than silently dropped: M09 (60-second scroll
frame time) needs a windowed profile session, M10 (release peak working set) needs the launched
viewer process on a live desktop, and M11 (frame/memory with NVDA enabled and disabled) needs a live
NVDA session.

### M06 is the row to watch, and it is not robustly under target

M06 passed by 72 ms (0.7 %) in the accepted run, and an earlier 30-iteration run at `380093c`
(`source_dirty: true`, harness still in flight) **failed** it at 10 115.4 ms p95 (max 11 243.1 ms) -
`viewer/target/evidence/viewer/2026-09-22-measure-acceptance/`. Run-to-run spread alone is enough to
flip the row, and the cost is dominated by opening each project database to check its schema
version.

Follow-up profile: `viewer/target/evidence/viewer/2026-09-22-m06-profile/probe.py` opens every
`TASKS.sqlite` in the retained 1000-empty-project fixture once with an ordinary read-only handle and
once with `immutable=1`, running `PRAGMA user_version` on each, twice per mode.

| Mode | Pass 1 | Pass 2 | Per project |
| --- | ---: | ---: | ---: |
| plain `mode=ro` | 8654.1 ms | 9004.6 ms | ~8.8 ms |
| `immutable=1` | 210.8 ms | 195.3 ms | ~0.2 ms |

Both modes returned the same value for every database (`user_version = 4`), so the gap is handle
setup, not a different answer: roughly **43x cheaper** when SQLite is told the file cannot change.
`src/viewer.rs::sample_project_inner` performs exactly this open-and-check once per project on the
catalog read path; `src/store.rs::Store::open_readonly` does the same for single-project viewer
commands.

This is a lead, not a fix: `immutable=1` is only sound for a quiescent file, and applying it to a
live store would let the reader ignore a non-empty WAL and return stale data, which the durability
rules forbid. The safe candidates worth measuring next are reading `user_version` straight from the
SQLite header, sharing one connection across the catalog read, or bounding the per-project schema
check to the first page. Nothing was changed for this milestone, so M06 keeps its thin margin; a
future change must re-measure before claiming an improvement. The probe is read-only and ran against
a temporary fixture root, never a live store.

## 7. Announcements, startup and the manual rows

### Bella announcements

Assets are real ElevenLabs output, not synthetic tones: 20 licensed clips for voice `Bella -
Professional, Bright, Warm` (`hpp4J3VqNfWAUOO0d1Us`), model `eleven_multilingual_v2`, format
`mp3_44100_128`, stability 0.5, similarity boost 0.75, style 0, speaker boost on. The catalog,
manifest, per-clip text/config hashes and durations are committed under `viewer/assets/announcements/`
and `viewer/assets/announcements/manifest.json`. Generation and integrity evidence is in
`target/evidence/viewer/2026-09-21-bella-generation/`: the first attempt failed before any API write
(kept), generation produced 20 clips, an idempotent rerun reused all 20 without re-billing, and a
speech-to-text round trip matched 20/20 transcripts. No API key, task text or private data is in any
committed file, and `package.ps1` scans the bundle for credentials before it will ship it.

On 2026-09-24 the user confirmed hearing Bella speak the Test voice clip in the running viewer.
This confirms that clip's audible playback. Offline playback, the other clips and the
playback-behavior cases remain open, so V13 stays unavailable.

### Windows startup and sign-in

Verified: the launch/configuration surface in `viewer/README.md`, startup registration and
single-instance classification in the G05 suite, and the packaged release's no-window
`--startup` opt-out and argument handling in the G10 launch test
(`viewer/target/evidence/viewer/2026-09-23-default-discovery-a11y/11-package.txt`). The launch test
runs from a temporary root whose path contains spaces and non-ASCII characters.

Not verified: a real sign-in/sign-out in a disposable Windows account, the "Start with Windows"
shortcut pointing at an installed bundle, a moved bundle, a policy-disabled startup entry, and
monitor changes including a disconnected monitor. High-DPI change testing is skipped at the user's
request. Deliberately, no real Startup entry was
created, changed or removed by any run.

### Live NVDA walkthroughs

The live walkthroughs that ran did so before the headless-only direction, on release builds, with a
real NVDA instance, speech logs recorded by line offset and CLI ground truth:

- **B (read complete content)**: slice-4 session, including the 1 MiB body focus investigation and
  its fix, exact copy of stored CRLF text, dependency follow/back and history snapshot equality -
  `viewer/target/evidence/viewer/2026-09-22-slice4-nvda/` and the slice-4 section of the repository
  `verification-report.md`.
- **C (edit, conflict, recovery)**: 5 steps PASS, 1 PARTIAL - the PARTIAL is step 4a's caret
  restore, fixed headlessly in `719ba66` with a live re-run still pending -
  `viewer/target/evidence/viewer/2026-09-22-slice5-nvda/walkthrough-c-summary.md`.
- **D (clipboard and failure states)**: D0, D1 and the D2 rerun PASS live; D3-D5 were proven with
  headless widget and subprocess harnesses instead and carry no NVDA speech -
  `viewer/target/evidence/viewer/2026-09-22-slice6-nvda/walkthrough-d-summary.md`.
- **A (project/task discovery)**: not executed. The attempt opened NVDA's own menu and could not
  reach the Speech Viewer; the smallest external action to unblock it is written down in
  `target/evidence/viewer/2026-09-21-nvda-walkthrough-a/README.md`.
- **E (layout and Windows behaviour)** and **F (startup and Bella playback)**: not run, by direction.

### Defects

- **Defect B - the caret lost after a guard Cancel - fixed in `719ba66`.** In the live walkthrough C
  step 4a, after Alt+F4 and Cancel, focus returned to the Title field but the next keystroke replaced
  the whole value. Root cause, established with a reproduction rather than guessed:
  `EditableText.selectAllOnFocus` defaults to true on desktop, so Flutter itself selects the whole
  value when the field regains focus, and the widget harness had never seen it because `FLUTTER_TEST`
  forces `TargetPlatform.android`, where the default is false. The fix in
  `viewer/lib/ui/editor_form.dart` remembers each text field's selection on focus loss and restores
  it in a post-frame callback when the same text regains focus; two tests pinned to the Windows
  platform variant cover the close guard and the form guard. RED before the fix (the observed
  selection was the whole title, `0..12`) and GREEN after it are retained in
  `.../2026-09-22-defect-b-caret/`. Honest caveat: a live NVDA re-run of walkthrough C step 4a is
  still required before that step can be called PASS - the harness has no Windows text-input
  connection, so a platform echo arriving after the restore frame cannot be reproduced headlessly -
  which is why V10 stays unavailable. The two other findings from that step (the project-switch
  Cancel dead end and the conflict wording) were fixed earlier with widget tests.
- **Harness-only findings from the slice-4 session** (a swallowed first chord after idle, and a
  `partial` verdict file whose retry hit the same state) are recorded there as harness behaviour, not
  as app defects.

### Smallest external action to close each unavailable gate

Everything this repository can prove headlessly is already proven; each remaining acceptance row
needs one step from outside the agent's authority. The standing "headless only, do not steal the
mouse and keyboard" directive forbids the agent from taking any of them, so they are listed as
options rather than queued work.

| Gate | Smallest external action | What it closes |
| --- | --- | --- |
| V08 | Authorize one bounded live windowed session of the packaged candidate (window flows plus UI Automation), with synthetic-only clipboard text placed by the tester | packaged launch, cross virtual boundary, second-writer conflict, clipboard preview/enrichment, restart-with-draft and unavailable-store recovery |
| V09 rows M09-M11 | Authorize the bounded windowed profiling run, with NVDA running for M11 | 60-second scroll frame time, release peak working set, frame/memory with NVDA on and off |
| V10 | Run NVDA with the Speech Viewer open in a bounded live session, or perform the remaining walkthroughs by hand: A (its `NVDA+N`, `T`, `S` unblock note is in `target/evidence/viewer/2026-09-21-nvda-walkthrough-a/README.md`), C step 4a against the caret fix, E and F | every design.md walkthrough with speech evidence and real text editing |
| V12 | Create or authorize a disposable local Windows account and one bounded monitor change at the current display scale | real sign-in launch, default-on registration across sign-out/in, changed/missing monitor checks; high-DPI changes are skipped |
| V13 | One human listening pass over the remaining bundled clips, with the packaged offline playback | remaining clip content, volume and announcement modes, rapid-event cancellation and playback-failure fallback; Bella's Test voice was heard |

V01-V07, V11 and the catalog rows of V09 pass headlessly, and the portable bundle re-verifies against
the current candidate, so these rows are the complete distance between it and release acceptance.

## 8. Limitations

- The verification is single-machine: Windows 11 Home x64 plus Ubuntu 22.04 in WSL2, no other Linux
  distribution, no bare-metal Linux and no ARM target.
- `tasks.exe` hashes are **not reproducible across rebuilds of identical source**. In the current run
  itself, the first build hashed `053819e3...` and the G07 rebuild of the same source hashed
  `aa7b96a5...`; other builds recorded in this report hashed `f0f92831...`, `7617ea6a...`,
  `93abd32a...`, `42514649...`, `1d11efde...` and `7132f27d...`. Treat a hash as identifying one
  build, not one source revision, and re-hash rather than comparing against an older number. The
  viewer stub `tasks_viewer.exe` did stay stable at `b56b1608...` across every build of this
  milestone; the Dart UI it loads lives in `data/app.so`, whose current sealed hash is
  `06dbac3b...`.
- V08, V10, V12 and V13 need a live desktop, a disposable Windows account or a human listener; until
  they run, release acceptance is incomplete no matter how green the automated gates are.
- M09-M11 (frame time under scroll, peak working set, NVDA on/off) need a windowed profile session;
  the viewer's memory and raster behaviour is therefore unmeasured.
- High-DPI change tests are skipped at the user's request. No verification run changed the system
  display scale or DPI.
- Performance numbers describe this host and these fixtures, not a promise for arbitrary backlogs.
- Clipboard coverage is the fake clipboard in the automated suites plus synthetic text in the earlier
  live walkthroughs; the automated clipboard tests never touched the real clipboard.
- The packaged bundle is built from `823094a`, the current viewer candidate. Its
  `target/viewer-release/bundle-metadata.json` records `source_commit 823094a`, `source_dirty false`,
  cli `aa7b96a5...36fe` and viewer `b56b1608...`; the section 10 timings came from the earlier `b56f883`
  build.

## 9. Reproducing this run

From `viewer/`: `flutter pub get`, `dart format --output=none --set-exit-if-changed lib test integration_test`,
`flutter analyze --fatal-infos`, `flutter test --reporter expanded`, `flutter build windows --release`.
From the repository root: `pwsh -NoProfile -File viewer/tool/verify-windows.ps1`,
`pwsh -NoProfile -File viewer/tool/measure.ps1`, `pwsh -NoProfile -File viewer/tool/package.ps1`.
Every script allocates its own temporary data and settings roots, retains logs under
`viewer/target/evidence/viewer/<run-id>/`, and fails closed when its prerequisites are missing. None of
them needs a live desktop, and `-IncludeWindowedIntegration` is the only switch that would open a
window.
