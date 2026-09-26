# tasks-cli verification report

## Token-efficient output, skills 1.1/4.1/6.2 and install — 2026-09-26

`e60aaab` makes JSON compact and omits rules from `show` unless `--rules` is
passed. It adds multi-ID `show` (1–100 IDs, exit 3 if any is missing),
`--add-label`/`--remove-label`, and `changed_fields` in history, and replaces
`snapshot_json` with a nested `snapshot`. The data schema is unchanged. The
skills that describe these commands were committed in `5048280`, `60a9599`
and `b8a9240`, and both binaries were installed at `b8a9240`
(`integration/deployment-20260926.md`).

### Proof

- Windows gates on the implementation tree: fmt, clippy, test and release
  build all exit 0, with **228 passed, 0 failed**
  (`target/evidence/cli-impl/cli-impl-win-status.txt`, `cli-impl-win-test.log`).
- Ubuntu/WSL gates with the Linux-owned target `~/.cache/tasks-cli-impl-target`:
  all exit 0, with **232 passed, 0 failed**
  (`target/evidence/cli-impl/linux-status.txt`, `linux-test.log`). The first
  attempt used a target on `/mnt/f` and failed in libc's build script; its logs
  are kept as `first-attempt-linux-*`.
- Real two-binary delegation (Linux `tasks` → Windows `tasks.exe`) on a
  temporary store covered init, rules, create, multi-ID show in text and JSON,
  label add, a stale write (exit 4), a missing ID (exit 3), history JSON,
  `history --event` and text list. Every check passed
  (`target/evidence/cli-impl/delegation/summary.txt`).
- Output size (UTF-8 bytes, same fixture): `list --open` JSON 5442 → 2973,
  `show` JSON 1766 → 553.
- Installed binaries: before the install, every command the updated skills
  document was run against a temporary data root with
  `target/release/tasks.exe`. On WSL, `tasks --version` reports
  `b8a9240ba6e7`, and `tasks show --help` lists `<IDS>...` and `--rules`
  through the installed symlink.

### Limits

- Before schema 2, history events did not store the previous status. The
  first update after such an event can therefore list `status` in
  `changed_fields` even when the status did not change.
- Other JSON consumers that read `deps` from `show`, rules from `show`, or
  `snapshot_json` from history must be updated. The viewer accepts both the
  old and the new history shapes (`a1985d4`).

## Viewer slice 4: projects, tasks, details and history under NVDA — 2026-09-22

Slice 4 of `viewer/` adds the real project and task lists, the details pane with
its Details, Dependencies, History and Project rules tabs, and the read paths
behind them. Verification ran against the release build of the slice-4 working
tree, in `--test-mode` with a synthetic fixture root and the real `tasks.exe`.
Nothing was pushed, no live backlog was opened and no installed executable was
replaced. Evidence is under
`viewer/target/evidence/viewer/2026-09-22-slice4-nvda/` (`drive/` for harness
logs and UIA dumps, `nvda/` for speech logs).

### Proof

- **The 1 MiB body no longer freezes the reader.** `delta-reading` T-001 holds
  1 046 247 stored characters with 24 870 CRLF pairs. Focusing it in a profile
  build stalled the next frame for **278.1 s** (`drive/focus-probe-6.log`,
  03:27:24.740 → 03:32:02.837) and 285.5 s in the confirming run
  (`drive/focus-probe-before-crfix.log`); NVDA logged repeated 10 s
  freeze-recovery cycles over the same period
  (`nvda/nvda-walkthrough-before-nvdaoff.log`). The isolated paragraph probe
  puts the cost on U+000D: 64 KiB of CRLF paragraph text lays out in 448 ms
  against 18 ms with LF, and the whole 1 021 377-character LF form in 321 ms
  (`drive/paragraph-probe.log`). `ViewerBodyText` now lays out the LF form and
  keeps the stored text as the source of truth for offsets and for anything
  leaving the app, after which the same focus path completes a frame in
  **0.48 s** (`drive/focus-probe-profile.log`, 04:06:54.867 → 04:06:55.351).
  The stall was never NVDA's: with NVDA stopped the small-body frame still
  completed and the 1 MiB frame still did not (`drive/Z-nvdaoff.log`,
  `drive/Z-nvdaoff2.log`).
- **Copy hands over the store's own characters.** With the body focused,
  Ctrl+C after a Find-in-body match copied exactly the 31-character marker at
  stored index 1 046 201 (sha256 `1D6A3D9C…`), and Ctrl+A then Ctrl+C copied
  all 1 046 247 characters including 24 870 CRLF (sha256 `E1D10C56…`), equal
  to the stored body (`drive/B29-b1-summary.json`,
  `drive/B27-whole-body-result.json`). Two earlier runs whose verdicts read
  `fail` had in fact copied exactly CRLF, two characters
  (`drive/B19-copy-result.json`, `drive/B22-copy-result.json`); the harness
  predicate expected the marker. They show the same stored characters and are
  retained as such.
- **A refused row jump is announced.** Typing 99999 into Go to row and pressing
  Enter in the four-task delta-reading list speaks
  `Enter a row number from 1 to 4. Nothing moved.` as an alert
  (`drive/R2-announce.speech.txt`), matching the `a refused row reaches the
  engine announce channel` widget test.
- **Dependencies, driven from a fresh instance.** Alt+2 moves focus to the
  Dependencies tab (node name `Dependencies\nAlt+2`) and the pane reads
  `Dependencies of T-003` (`drive/N31-alt2.uia.json`); Alt+L then Down move to
  `T-001 … Waiting for this dependency` and `T-002 … Waiting for this
  dependency` (`N32`, `N33`); Alt+O opens the dependency, so the details header
  becomes `Follow up with the vendor` / `ID T-002` with
  `Dependencies of T-002. No dependencies` (`N44`,
  `N45-names-after-alt-o.txt`); Alt+Left returns to `ID T-003` with both
  dependency rows (`N46`, `N47-names-after-back.txt`).
- **History reads, and the snapshot matches the CLI byte for byte.** Alt+3
  moves focus to the History tab (`History\nAlt+3`), Alt+V focuses
  `Event 2, create, version 1, 22 September 2026, 00:48`, Enter opens the event
  and Alt+E focuses `Event snapshot (Alt+E)` (`drive/O34`…`O37`). The focused
  value is 167 characters with sha256 `b215d8dd…`, identical to the
  `snapshot_json` returned by `tasks history T-002 --event 2`
  (`O38-cli-event2.json`, `O39-snapshot-value.txt`,
  `O40-snapshot-focus.speech.txt`). Alt+E with no event selected alerts
  `Select a history event before reading its snapshot.`
- **History paging crosses the 100-event boundary.** `taskHistoryPageSize` is
  100 (`viewer/lib/controllers/detail_controller.dart:24`, spec section 183),
  so the original fixture's 31-event T-001 could never show the button. One
  additive project, `epsilon-history` (`a680d42a-6a44-4c3e-b2a4-ab9ee2b1b592`,
  131 events on T-001, `drive/H10-history-fixture.json`), was added to the same
  temporary fixture root; the four original projects are unchanged. The first
  page reports `100 events loaded` with a `Load more events` button
  (`P21-footer.uia.json`, `P22-button.uia.json`); invoking it moves focus to
  `No more events` and the footer to `131 events loaded`
  (`P23-loadmore-invoke.log`, `P24`, `P25`); NVDA reads
  `Event 1, create, version 1 … row 1 of 131 … selected`
  (`P27-history-131.speech.txt`).
- **Gates and artifact.** `flutter analyze` reports `No issues found!` and
  `flutter test` ends `All tests passed!` with **241 passed / 0 failed**
  (`final-analyze.log`, `final-test.log`). The release build
  (`drive/CF-release-build.log`, 04:19) postdates the last source edit (04:14)
  and the gates postdate the build: `tasks_viewer.exe` sha256 `B56B1608…`,
  `data/app.so` sha256 `762E805F…` (6 112 144 bytes). The profiling hooks used
  during the investigation are not in the shipped source.
- **Body focus announces the whole body, report-only.** Putting focus on the
  1 MiB body makes NVDA speak its full text as one utterance; the speech log
  for that focus is 1 046 315 bytes (`drive/CF-b1-body-focus.speech.txt`).
  Design.md section 10 forbids suppressing a text editor's native semantics to
  reduce speech, and the body must stay focusable, selectable and copyable, so
  this is recorded rather than changed.

### Superseded and bounded findings

- The whole-script run `drive/release-9-fresh.ps1` recorded verdict `partial`
  with nine failing steps (`drive/O1-fresh-result.json`). All nine are one
  harness wedge: the first details-scope chord after an idle period is
  swallowed, and the batch's own retry hits the same state. Re-driven one chord
  at a time after a mouse wake inside the details region, the identical steps
  pass (`drive/N31`…`N47`, `drive/O34`…`O40`). The run is retained and is not
  reported as an app defect.
- `drive/C1-gaps-result.json` carries verdict `partial`. Its details-scope
  steps were sent while focus was still in the tasks list, so they failed on
  scope, and its `betaWork` row count of 5 is a grep artifact: the pattern also
  matches the project search placeholder, while the list itself reported
  `4 matching tasks` (`drive/F6-rows.uia.json`). The filter, Hide-filters and
  T-003 detail observations in that file stand.
- Intermittent drops of synthetic keyboard chords (logged by NVDA, never
  reaching the viewer) are a harness finding: a real mouse click on a text
  field restores delivery (`drive/B29-b1-summary.json`). Root cause was
  not established.

## Init defaults and agent-guidance cutover — 2026-09-22

`tasks init --root <project>` now creates `.tasks.json` when absent, accepts an
existing matching identity byte-for-byte without rewriting it, and refuses
malformed or conflicting identities before initialization. The redundant
`--write-identity` option was removed.

- Windows passed formatting, Clippy with all targets/features and warnings
  denied, the complete Rust suite (**214 passed**), three feature-enabled bulk
  rollback tests, six identity integration tests and the release build.
- Native Ubuntu/WSL passed the corresponding gates in a separate Linux target
  directory: **218 passed**, plus the three rollback tests, six identity
  integration tests and the release build.
- The first Linux integration invocation used a fresh target directory before
  building its release executable. That ordering failure is retained in
  `target/evidence/init-default-20260922/linux-first-ordering-failure.log`; the
  exact release rerun passed. Final Windows and Linux logs are in
  `target/evidence/init-default-20260922/`.
- Operative project guidance now invokes the installed `task-ledger`,
  `create-task`, and `resolve-task` skills explicitly. It no longer describes
  the CLI using the ambiguous bare word `tasks` or advertises legacy Markdown
  ledgers as project structure.

## Migration and initial deployment — 2026-09-21

Direct nearest-ancestor `.tasks.json` routing, identity creation by `init`, and
build-identified `tasks --version` output are implemented. Routing precedence
is explicit `--project`, `TASKS_PROJECT`, the nearest identity file, then the
longest registry binding. Invalid nearer identities fail closed. The task-ledger,
create-task and resolve-task skills use the CLI directly.

### Product proof

- Windows passed `cargo fmt --check`, Clippy with all targets/features and
  warnings denied, `cargo test --locked --no-fail-fast` (**189 passed**), the
  three feature-enabled bulk rollback tests, release build, and six direct CLI
  identity integration tests.
- Native Ubuntu/WSL passed the corresponding gates in a separate Linux target
  directory: **193 passed**, zero failed or ignored, plus the three rollback
  tests and six identity integration tests. The release candidates report
  `tasks 0.1.0 (commit <12-hex-source-commit>)`.
- The final precedence regression exercises `--project > TASKS_PROJECT >
  .tasks.json > registry` on both platforms. Full logs are under
  `target/evidence/final-20260921/`.
- The first Linux integration invocation accidentally selected the Windows
  executable and failed on Linux `/tmp` paths. That log is retained; the test
  default was corrected to select the native executable and the rerun passed.
- During the identity/version feature verification, the first Linux full-suite
  invocation again inherited the deployed `TASKS_WINDOWS_EXE`. Its safety
  rejections are retained in
  `target/evidence/linux-feature-first-failure-20260921.log`; the native rerun
  explicitly unset delegation and passed in
  `target/evidence/linux-feature-verification-20260921.log`. Windows evidence is
  `target/evidence/windows-feature-verification-20260921.log`.

### Live migration and deployment

- A strict rehearsal over `F:\projects` selected 51 reviewed project roots,
  5,597 tasks, zero unrecognized candidates, and one preserved UTF-8 BOM
  warning. The canonical manifest and exclusions are under `migration/`.
- The matching strict apply imported and verified all 51 projects with zero
  failures. No Markdown ledger was moved, deleted, or quarantined. Evidence is
  under `target/evidence/migration-20260921-{final-dry,live-apply}/`.
- Every project received a one-field `.tasks.json`. A post-apply `doctor` loop
  resolved all 51 identities to the expected UUID and schema 4 database.
- Live databases reside at `F:\projects\.tasks-cli-data`, inside the user's
  existing iDrive-backed project tree. The normal Windows data-root path is a
  junction to that directory. The previous empty default store remains at the
  dated rollback path.
- Windows `tasks.exe` is installed in `F:\CliTools`; the native Linux binary is
  in `/home/pawel/.local/bin`. WSL login shells set `TASKS_WINDOWS_EXE` to the
  Windows binary, and a real delegated `doctor` call from ActiveAppView resolved
  the Windows-owned database successfully.
- Product skill links for Codex, Claude and Copilot on Windows and WSL resolve
  directly to `integration/skills`. Previous Markdown-skill links remain in
  dated backup directories outside active skill discovery. The three skills pass `quick_validate.py`; the candidate
  model exercise met all 14 rubric assertions, while the comparison baseline is
  documented as contaminated and is not a blind score.

## Current verification: selection, enrichment and development skills — 2026-09-19

Schema 4 adds P0–P3 priority (default P2), runnable default listings, explicit
open/human queues, priority cursors and direct unlock impact. Enrichment annotates
every known reference, preserves unknown references and original whitespace,
and supports stdin, files and the desktop clipboard. Development skill copies
use tracked project identity across worktrees; installed skills remain unchanged.
No live backlog was migrated and no executable was deployed.

### Proof and limits

- Windows and native Ubuntu/WSL passed `cargo fmt --check`,
  `cargo clippy --locked --all-targets`, `cargo test --locked` and
  `cargo build --release --locked`: **167 Windows / 169 Linux tests**, no
  failures or ignored tests. The feature-enabled bulk rollback test passed
  separately on both platforms. Six identity-wrapper tests passed on each OS.
- Final logs are under `target/evidence/final-20260919/`: platform-prefixed
  `*-fmt.log`, `*-clippy.log`, `*-test.log`, `*-build.log`, `*-bulk.log`
  and `*-identity.log`. Linux used a separate target directory and Linux-owned
  temporary stores. Initial failures from stale schema/default-list assertions
  and a missing fixture priority column were corrected; `windows-initial.log`
  preserves those failures.
- Selection RED/GREEN is retained under `target/evidence/selection-20260919/`.
  Enrichment core, CLI and output-limit RED/GREEN logs are under
  `target/evidence/enrich-20260919/`. Additional migration and clipboard tests
  were added after implementation; no independent RED is claimed for them.
  `identity-red.log` and `identity-green.log` reproduce and fix literal option
  text being mistaken for a routing override by the development helper.
- The exact release Windows clipboard round trip passed, including Unicode,
  repeated references and an unchanged second pass. The original clipboard
  formats were restored (`clipboard-release.log`). Replacement produces plain
  text and its changed-input check is best effort, not atomic compare-and-swap.
  Native Wayland/X11 desktop clipboard behavior remains unverified.
- PSScriptAnalyzer recorded one `PSAvoidUsingWriteHost` warning for deliberate
  exact-byte `Console.Write` output; see `powershell-analysis.json`.
- Real native and delegated release probes verified readiness, priority paging,
  human selection, unlock counts, historical snapshots, optimistic conflict
  refusal, and stdin/file enrichment. Delegation used the actual Linux and
  Windows binaries, with only Windows opening the Windows-owned store.
- Development skills passed static validation and executable helper checks.
  Autonomous baseline/candidate skill evaluation remains uncompleted because
  workers hit workspace-credit/thread limits. These checks do not establish
  model-quality improvement or justify live skill deployment; see
  [development evaluation](integration/evaluation.md).

### Release smoke measurements

The fixture contains only **three tasks**; these are startup/workflow smoke
measurements, not large-backlog performance claims. Each operation used six
warmups and twenty fresh-process samples, with nearest-rank p95 and no concurrent
build. Large enrichment contained 20,000 references. Harness, samples and release
hashes are in `workflow-proof.py` and `perf-{windows,linux,delegated}.json` in the
final evidence directory.

| Operation | Windows p95 ms | Linux p95 ms | Delegated p95 ms |
| --- | ---: | ---: | ---: |
| list | 26.3 | 71.6 | 131.4 |
| unlocks | 35.4 | 62.9 | 130.8 |
| enrich-large | 53.5 | 79.2 | 131.8 |

## Previous checkpoint: states, labels and ranked search — 2026-09-18

The approved states are `draft`, `todo`, `in-progress`, `blocked`, `done`, and
`cancelled`. State migration was committed as `3e71089`. The subsequent labels
and search milestone adds schema 3, normalized labels in task snapshots and
Markdown round trips, exact label filtering, and opt-in FTS5 ranked word/prefix
search. Plain substring search remains compatible. History already supported
retrieving a complete earlier snapshot by event ID; README now shows the query.
No live project migration, installed-skill change, executable deployment or push
was performed. AGENTS.md requires a local commit after each verified milestone.

### Proof and platform gates

- State RED: four behavioral failures and one pass; state GREEN: five passes.
  Logs: `target/evidence/states-20260918/red-windows-2.log`,
  `green-windows-1.log`, `focused-windows.log`, `focused-linux.log`.
- Labels/search CLI RED: four failures from unavailable label/search options,
  one validation test already passing. GREEN: all five passed. Engine RED:
  seven failures against the temporary no-op implementation; GREEN: seven
  passed. Logs under `target/evidence/search-labels-20260918/`: `red.log`,
  `fts-red.log`, `fts-green.log`, `focused-green.log`.
- Supplemental schema-2 migration coverage verifies index rebuild over existing
  content, unchanged history, an independently readable schema-2 backup and
  subsequent version-checked label edits. This extra test was added after the
  main RED/GREEN cycle; it is not claimed as a separate RED/GREEN reproduction.
- Final `cargo fmt --check`, `cargo clippy --locked --all-targets`,
  `cargo test --locked`, and `cargo build --release --locked` passed on native
  Windows and Ubuntu/WSL. Linux used `CARGO_TARGET_DIR=target/linux` and
  Linux-owned temporary databases. Totals: **155 Windows / 157 Linux**, zero
  failures or ignored tests. Feature-enabled `bulk_rollback` passed separately
  on both platforms (one additional test each).
- Full logs: `target/evidence/search-labels-20260918/{windows,linux}-fmt.log`,
  `*-clippy.log`, `*-test-final.log`, `*-bulk-rollback.log`, `*-build.log`.
  Counts and release hashes: `gates-summary.json` in that directory.
- Initial wider runs exposed a legacy fixture setup error introduced during this
  change and an old `backlog` output assertion in `section_map`. Both were
  corrected; original logs remain as `windows-test-1.log`, `windows-test.log`
  and `linux-test.log`. The first Linux gate-script launch also had CRLF shell
  line endings; no checks ran in that launch. The corrected LF script completed
  the recorded final gates. No passing wrapper exit was used as proof of tests.

### Release measurements

Measurements use 10,000 tasks and 50,000 seeded events, plus one label mutation.
Each sample is a new release process: one first run, five additional warmups,
then 50 measured samples; p95 is nearest rank. Output is captured. Modes run
sequentially after builds finish. Linux native stores use `/tmp`; delegated
stores use unique Windows TEMP directories and only the Windows binary opens
SQLite. The harness and complete samples are retained under
`target/evidence/search-labels-20260918/measure.py` and `perf-*.json`.

| Operation | Windows p95 ms | Linux p95 ms | Delegated p95 ms |
| --- | ---: | ---: | ---: |
| list | 43.2 | 83.3 | 153.2 |
| show | 45.3 | 142.8 | 142.9 |
| search-hit | 34.0 | 92.9 | 147.5 |
| search-miss | 139.8 | 153.9 | 271.3 |
| ranked-hit | 149.7 | 151.7 | 297.3 |
| ranked-miss | 52.8 | 63.2 | 197.2 |
| ranked-prefix-label | 224.7 | 132.6 | 280.5 |
| export | 529.5 | 401.0 | 549.5 |
| update | 71.1 | 175.3 | 217.2 |

All measured calls exited 0. These are fixture observations, not upper bounds for
arbitrary backlogs. Ranking is not uniformly faster than substring search: common
terms require scoring many matches. Native Linux show and update exceeded the
spec's diagnostic p95 targets of 100/150 ms; this is recorded rather than hidden
by a retry. No durability setting was weakened. Every measured operation's p95
was below 550 ms, including full export and delegated process startup. Memory
was not remeasured in this milestone.

The real two-binary delegation smoke passed label create/show, ranked prefix and
label filtering, selected full history snapshots, Unicode/CRLF stdin, literal
`--out=needle` / `--windows-exe=needle` query arguments and missing-task exit 3.
It used a disposable Windows-owned store, not a live backlog. Full results are
in `perf-delegated.json` under `delegation_smoke`.

Release SHA-256:

- `target/release/tasks.exe`: `fea156efc4cd15e64c095059f9405335e614bb7aa6da49975e89d3fea0ad3b6c`.
- `target/linux/release/tasks`: `22426ac9097f9426c07d62aaa0d9255eb48182e047042aeebe3071b33057d736`.

Remaining scope: priority, actionable-only default lists, unlock queries, automatic
project-file discovery and live skill integration. Current default lists omit
done/cancelled but include draft/blocked; `--label needs-human` selects an ordinary
label. Search includes terminal states. Ranked pages can move across separate
requests if tasks change; each individual request uses a consistent snapshot.

## Earlier reliability checkpoint: 2026-09-18

Candidate: reliability commits 198e6d1, c5dc0c9 and 27912eb. No live task
ledger was migrated and no installed skill was changed. The pre-existing README
rewrite was preserved and updated where necessary.

Implemented:

- rusqlite 0.40.2 / libsqlite3-sys 0.38.2, bundling SQLite 3.53.2, confirmed by
  `doctor` on both release binaries. SQLite upstream lists 3.53.4; this records
  the actual crate bundle, not the newest upstream patch.
- Bulk ownership checks, apply, verification and candidate cleanup share the
  registry lock. A new binding is published after verification. Pre-existing
  databases and their sidecars are preserved. Successful earlier candidates
  remain imported; migration requires stopped workers.
- List/search/show/export use deferred read transactions for one snapshot per
  response. Export renders after commit and publishes without overwriting another
  writer's file. This uses ordinary WAL snapshot isolation.
- Bind validates schema/identity under the registry lock before publication;
  accepted UUID spellings route to the canonical database.
- WSL delegation respects `--` and option-value boundaries. Linux storage checks
  inspect the owning mount, including custom DrvFs mountpoints.
- Documentation reconciles the 1000-dependency limit, content versus formatting
  preservation, and candidate-local cleanup versus cross-project transactions.

Sources: [SQLite isolation](https://www.sqlite.org/isolation.html),
[SQLite release history](https://www.sqlite.org/changes.html),
[rusqlite](https://github.com/rusqlite/rusqlite).

### Final gates

Both Windows x64 and native Linux x64 inside Ubuntu/WSL passed:

```text
cargo fmt --check
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo test --locked
cargo test --locked --features test-hooks --test bulk_rollback --test routing_regressions
cargo build --release --locked
```

Linux used `CARGO_TARGET_DIR=target/linux`; its native databases were unique
Linux-owned temporary stores. Default-suite totals: **137 passed on Windows,
139 passed on Linux**, zero failed/ignored. The additional feature-enabled run
passed the bulk rollback regression (1 test) and routing regressions (5 tests)
on each platform. The default-suite zero-test `bulk_rollback` target is not
counted as proof; the explicit feature-enabled run supplies that proof.

Evidence root: `target/evidence/fix-20260918/`. Final gates:
`windows-final-{fmt,clippy,test,build}.log`,
`linux-final-{fmt,clippy,test,build}.log`,
`routing-interop/final-binding-lock.log`, `linux-final-regressions.log`.
The first strict Windows Clippy attempt rejected the deprecated SQLite trace
callback; the tests were moved to `trace_v2`. Its failure remains in
`windows-clippy-initial.log`. Dependency upgrade compatibility changes retained
fallible unsigned bindings and adopted `MAIN_DB` for the backup API.

### RED/GREEN evidence

| Regression | Observed RED | Evidence below the evidence root |
| --- | --- | --- |
| Bulk rollback ownership | Paused importer deleted a task database committed by another process | `bulk/red.log`, `bulk/green.log`, final feature-enabled runs |
| Invalid bind / UUID spelling | Invalid database was bound; accepted UUID text was not canonicalized | `routing-interop/routing-red.log`, `routing-green.log`, final routing runs |
| Mixed read snapshots / export overwrite | Four new tests failed with mixed data or overwritten output | `snapshots-red.log`, `snapshots-green.log`, final full suites |
| WSL literal argument | `--out=needle` after `--` was translated as a path | `routing-interop/interop-red.log`, `interop-green.log` |
| Custom Windows mount | Old binary treated a custom DrvFs bind mount as a native storage root | `routing-interop/mount-live-red.log`, `mount-live-green.log`; mount parser test in final suites |

The bulk test uses actual CLI subprocesses and a temporary SQLite database with
a deterministic pause before protected apply. The read tests commit through a
second real SQLite connection between reader statements. They demonstrate both
snapshot consistency and that a WAL writer can commit while the reader is active.

The initial custom-mount RED shell harness captured the old not-found response,
then encountered a CRLF shell error. The corrected LF harness rejected that
class of mount with exit 2. It never opened a Windows database from Linux; the
disposable mount was unmounted and removed. This live check preceded the final
bind-lock adjustment; unchanged storage code was included in the final gates.

### Measured command latency

Hardware: AMD Ryzen 9 5950X (16 cores / 32 logical processors).
Toolchain: rustc 1.98.1 (48a229cea 2026-09-01). Fixture: 10,000 tasks, 2080-byte
bodies, 50,000 initial events, no dependency edges. Each command uses a fresh
release process: first invocation recorded separately, five additional warmups,
50 measured samples; p95 is nearest-rank. Setup and output validation are outside
timing. Stdout/stderr capture and process startup are included. No compilation
ran during the final measurement series.

The Linux executable resides on `/mnt/f`; its native database resides in `/tmp`.
Delegated measurements start inside WSL and include Linux CLI, `wslpath` and
Windows process startup. Only Windows executables access the Windows database.
These are candidate timings, not a claimed before/after speedup.

| Command | Windows p50 / p95 ms | Linux p50 / p95 ms | Delegated p50 / p95 ms |
| --- | ---: | ---: | ---: |
| list | 21.6 / 28.0 | 35.2 / 53.0 | 91.3 / 114.4 |
| show | 23.1 / 30.3 | 34.1 / 44.9 | 93.8 / 120.0 |
| search, matching | 24.8 / 31.1 | 34.0 / 41.0 | 91.3 / 122.1 |
| search, no match | 86.3 / 98.8 | 63.8 / 73.2 | 142.9 / 183.6 |
| export | 168.9 / 225.0 | 159.2 / 202.1 | 272.3 / 362.4 |
| update | 34.7 / 46.8 | 63.0 / 79.4 | 93.8 / 117.3 |

All measured subprocesses returned 0. The no-match search scans the fixture;
export writes the 10,000-task fixture and the harness checks its final task is
present. Raw samples, first-run/max timings,
output sizes and artifact hashes are in `performance-final-{windows,linux,delegated}.json`.
Harness: `measure.py`. Requests were below the suggested 1–2 seconds in this
fixture. This is not a hard deadline: lock waits may reach five seconds, and
larger imports/exports scale with input size. Export publication requires
hard-link support in its output filesystem.

The final delegated smoke verified `--out=needle` and `--windows-exe=needle` as
literal search text, Unicode/CRLF stdin body preservation, and propagation of
missing-task exit code 3. See `performance-final-delegated.json`.

### Release artifacts and remaining integration work

- `target/release/tasks.exe`: 5,227,008 bytes; SHA-256 `6bc28fe28d5affdf4f2767fb3c3e5ef4a74782814b7b61d66b6ddf49596cbb85`.
- `target/linux/release/tasks`: 7,038,728 bytes; SHA-256 `a22196401af552e81ec67c5d2984d6547e45369e6d638d7156b4a3fb7bf8bbbc`.

At this earlier checkpoint, labels, priority, draft/decision queues,
runnable-only default listings, unlock ranking, automatic project-file discovery
and shared-skill integration were proposals. Later state/labels/search results
are recorded above. Existing event history already stored full revisions.

No live cutover or skill deployment occurred. These reliability changes were
subsequently committed locally; no push occurred. The historical report below
retains prior evidence, with its original counts and artifact hashes.

<details>
<summary>Historical verification: 2026-09-16</summary>

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

</details>
