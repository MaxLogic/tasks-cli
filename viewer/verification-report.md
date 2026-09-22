# Tasks Viewer verification report

Candidate: **`a15a809`** - `interop: translate viewer request-file paths when delegating from WSL`,
branch `main`, tree clean at every measurement recorded here. Nothing was pushed, no live backlog was
migrated or opened, no installed executable was replaced, and no real Startup entry, task store or
clipboard was touched. Every fixture was synthetic, disposable and rooted outside the repository.

This is the headless verification the user asked for: *"test the GUI in headless mode please. do not
steal my mouse and keyboard"*. No command below delivers keyboard or pointer input to the desktop,
holds a foreground lease, invokes a UI Automation element, drives a screen reader or reads the real
clipboard. Keys and pointer events exist only inside the Flutter test binding, so the desktop stays
usable while the gates run. Rows that need a live session are marked unavailable and are never
claimed as passing.

## Result summary

| Area | Result |
| --- | --- |
| `viewer/tool/verify-windows.ps1` headless gate run | **passed, 11/11 gates** at `a15a809`, `source_dirty: false` |
| Flutter gates | format **passed**, analyze **passed**, full suite **466 passed / 1 documented skip**, test-hooks suite **3 passed**, headless end-to-end **5 passed** |
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
| Final headless gate run (G00-G10) | `viewer/target/evidence/viewer/2026-09-22-final-headless-verify/` |
| Windows Rust gates | `target/evidence/viewer/2026-09-22-rust-gates-windows-2/` |
| Linux Rust gates (final) | `viewer/target/evidence/viewer/2026-09-22-rust-gates-linux-3/` |
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

`pwsh -NoProfile -File viewer/tool/verify-windows.ps1 -EvidenceRoot viewer/target/evidence/viewer/2026-09-22-final-headless-verify`

Generated 2026-09-22T10:55:10Z at `a15a809` with `source_dirty: false`.

| Id | Gate | Status | Detail |
| --- | --- | --- | --- |
| G00 | toolchains | passed | Flutter/Dart/Rust/machine recorded |
| G01 | release CLI build | passed | `tasks.exe` sha256 `f0f92831...04e9` (already up to date; the binary is the one the Windows gate set left) |
| G02 | throwaway fixture seed | passed | alpha 28 tasks (27 open), beta 4 tasks |
| G03 | dart format | passed | `lib test integration_test` unchanged |
| G04 | flutter analyze | passed | `--fatal-infos` clean |
| G05 | flutter test (full suite) | passed | 466 passed, 1 skipped (the documented acknowledgement-loss case) |
| G06 | test-hooks CLI closes the skip | passed | 3 passed, 0 skipped |
| G07 | shipped CLI restored | passed | rebuilt plain release CLI sha256 `7617ea6a...7a27f` |
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
| Windows x64 | 214 passed, 0 failed, 0 ignored | 35 | `target/release/tasks.exe`, 6 022 144 bytes, sha256 `f0f92831f018ada161979df85a768dc1c2892b569585d2272ae528c9a0da04e9` |
| Ubuntu/WSL x64 | 218 passed, 0 failed, 0 ignored | 35 | `target/linux/release/tasks`, 7 791 856 bytes, sha256 `5c170b0bfa7a3be7046457fa8ffeb2945119de2382bbdc9bc1935f62cea91446` |

Linux ran with `CARGO_TARGET_DIR=target/linux` and with `TASKS_WINDOWS_EXE` cleared so the suite
exercises the native Linux CLI; the switch was set to `/mnt/f/CliTools/tasks.exe` in the login shell
before the run cleared it, which is recorded in `00-host.txt` of that run.

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
| V07 | passed | G05 widget, semantics and accessibility suites: control names/roles/state, focus order and modal focus return, disabled reasons, loading announcements, text scaling and contrast themes |
| V08 | unavailable | G08 proves discover/filter/sort/read/edit/refresh headlessly over a real store, but the packaged-candidate window flows and any UI Automation step need a live desktop, which this directive forbids |
| V09 | passed with 3 unavailable rows | `viewer/tool/measure.ps1` acceptance run: fixtures, percentiles and raw samples recorded; M09-M11 (frame time, peak working set, NVDA on/off) unavailable - section 6 |
| V10 | unavailable | walkthroughs B and C ran live under NVDA on 2026-09-22 with speech logs and CLI ground truth, and walkthrough D reached D0-D2r live; walkthrough A never ran beyond the blocked attempt, walkthroughs E and F have not run. This row needs every walkthrough, so it stays unavailable - section 7 |
| V11 | passed | G05 hotkey suites: F1/F2/F3 focus targets, remembered-list Ctrl+F, scoped access keys, modal isolation, key-repeat suppression, Ctrl+D and Ctrl+E routing, the permanently visible Hotkey help button/F10 with focus return |
| V12 | unavailable | startup registration and single-instance classification pass in G05 and the packaged launch test covers the no-window opt-out path, but a real sign-in proof in a disposable Windows account and the changed/missing-monitor and live-DPI checks need a live session |
| V13 | unavailable | generation, manifest/hash integrity, packaged clips, offline verification and package rejection are proven; audible listening and the real-listening checks need a human - section 7 |

## 6. Section 10 performance and correctness evidence

`pwsh -NoProfile -File viewer/tool/measure.ps1` seeded deterministic release fixtures (recorded seed
`20260922`) with the release CLI and timed 30 runs after one discarded warm-up. Raw samples, host
details and fixture digests: `viewer/target/evidence/viewer/2026-09-22-measure-acceptance-clean/`
(`03-measurements.json`, `measure-summary.json`, `measure-summary.md`).

The two `source_commit` values differ: the accepted `-clean` run measured the `b56f883` build, the
earlier failing run a dirty `380093c` tree. The final candidate `a15a809` adds only the WSL
delegation path translation in `src/interop.rs`, which cannot change these native Windows rows, but
these numbers are not a re-measurement of `a15a809`.

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

What is **not** verified: a human listening check of the clips, and audible playback on a device.
That is the V13 gap, and it is why V13 stays unavailable.

### Windows startup and sign-in

Verified: the launch/configuration surface in `viewer/README.md`, startup registration and
single-instance classification in the G05 suite, and the packaged release's no-window
`--startup` opt-out and argument handling in the G10 launch test
(`viewer/target/evidence/viewer/2026-09-22-final-headless-verify/11-package.txt`). The launch test
runs from a temporary root whose path contains spaces and non-ASCII characters.

Not verified: a real sign-in/sign-out in a disposable Windows account, the "Start with Windows"
shortcut pointing at an installed bundle, a moved bundle, a policy-disabled startup entry, and
monitor/DPI changes including a disconnected monitor. Deliberately, no real Startup entry was
created, changed or removed by any run.

### Live NVDA walkthroughs

The live walkthroughs that ran did so before the headless-only direction, on release builds, with a
real NVDA instance, speech logs recorded by line offset and CLI ground truth:

- **B (read complete content)**: slice-4 session, including the 1 MiB body focus investigation and
  its fix, exact copy of stored CRLF text, dependency follow/back and history snapshot equality -
  `viewer/target/evidence/viewer/2026-09-22-slice4-nvda/` and the slice-4 section of the repository
  `verification-report.md`.
- **C (edit, conflict, recovery)**: 5 steps PASS, 1 PARTIAL -
  `viewer/target/evidence/viewer/2026-09-22-slice5-nvda/walkthrough-c-summary.md`.
- **D (clipboard and failure states)**: D0, D1 and the D2 rerun PASS live; D3-D5 were proven with
  headless widget and subprocess harnesses instead and carry no NVDA speech -
  `viewer/target/evidence/viewer/2026-09-22-slice6-nvda/walkthrough-d-summary.md`.
- **A (project/task discovery)**: not executed. The attempt opened NVDA's own menu and could not
  reach the Speech Viewer; the smallest external action to unblock it is written down in
  `target/evidence/viewer/2026-09-21-nvda-walkthrough-a/README.md`.
- **E (layout and Windows behaviour)** and **F (startup and Bella playback)**: not run, by direction.

### Open defects

- **Defect B - caret not restored after a guard Cancel.** Walkthrough C step 4a is PARTIAL: switching
  projects and closing both honour Save/Discard/Cancel, but Cancel does not put the caret back where
  it was. The two other findings from that step (the project-switch Cancel dead end and the conflict
  wording) were fixed after the run with widget tests; the caret restore was not, and it has had no
  live NVDA re-run. Evidence: `.../2026-09-22-slice5-nvda/walkthrough-c-summary.md`.
- **Harness-only findings from the slice-4 session** (a swallowed first chord after idle, and a
  `partial` verdict file whose retry hit the same state) are recorded there as harness behaviour, not
  as app defects.

## 8. Limitations

- The verification is single-machine: Windows 11 Home x64 plus Ubuntu 22.04 in WSL2, no other Linux
  distribution, no bare-metal Linux and no ARM target.
- `tasks.exe` hashes are **not reproducible across rebuilds of identical source**. In the final run
  itself, the CLI built before the test-hooks build hashed `f0f92831...` and the rebuild after it
  hashed `7617ea6a...`; across earlier runs the same commit produced `93abd32a...`, `42514649...`,
  `1d11efde...` and `7132f27d...`. Treat a hash as identifying one build, not one source revision,
  and re-hash rather than comparing against an older number. The viewer executable did stay stable
  across the slice-5..7 builds (`b56b1608...`).
- V08, V10, V12 and V13 need a live desktop, a disposable Windows account or a human listener; until
  they run, release acceptance is incomplete no matter how green the automated gates are.
- M09-M11 (frame time under scroll, peak working set, NVDA on/off) need a windowed profile session;
  the viewer's memory and raster behaviour is therefore unmeasured.
- Performance numbers describe this host and these fixtures, not a promise for arbitrary backlogs.
- Clipboard coverage is the fake clipboard in the automated suites plus synthetic text in the earlier
  live walkthroughs; the automated clipboard tests never touched the real clipboard.
- The packaged bundle is built from `a15a809`, the commit every Rust, Flutter and packaging gate in
  this report ran against, so `target/viewer-release/bundle-metadata.json` records
  `source_commit a15a809` and `source_dirty false`; the section 10 timings came from the earlier
  `b56f883` build.

## 9. Reproducing this run

From `viewer/`: `flutter pub get`, `dart format --output=none --set-exit-if-changed lib test integration_test`,
`flutter analyze --fatal-infos`, `flutter test --reporter expanded`, `flutter build windows --release`.
From the repository root: `pwsh -NoProfile -File viewer/tool/verify-windows.ps1`,
`pwsh -NoProfile -File viewer/tool/measure.ps1`, `pwsh -NoProfile -File viewer/tool/package.ps1`.
Every script allocates its own temporary data and settings roots, retains logs under
`viewer/target/evidence/viewer/<run-id>/`, and fails closed when its prerequisites are missing. None of
them needs a live desktop, and `-IncludeWindowedIntegration` is the only switch that would open a
window.
