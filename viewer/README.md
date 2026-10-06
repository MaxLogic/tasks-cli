# Tasks Viewer

A Windows desktop front end for the `tasks` CLI. It reads one shared SQLite
backlog per project through the CLI's `viewer` command group. Local stores and
configured remote profiles use the same interface; the viewer never opens a
task database itself.

The project owner tested the viewer with NVDA and confirmed screen-reader use
on 2026-10-06. Keyboard navigation, full-text reading and editing are part of
the application workflow. See [verification-report.md](verification-report.md)
for the owner report and dated automated checks.

The viewer talks to the store only through `tasks.exe`. Reads use the CLI's
`viewer projects`, `viewer tasks`, `viewer show` and `viewer info` commands.
Writes use `viewer update` with an expected version; project archive dates use
`viewer archive` and `viewer archive --unarchive`. Nothing in the viewer creates,
migrates or repairs a task store.
The CLI keeps project statistics and archive dates in `viewer-cache.sqlite3`
under the selected task data root. Preserve this file when moving the store.

## Requirements

- Windows 11 x64.
- No Flutter/Dart SDK on the user's machine. The packaged bundle in
  `target/viewer-release/` contains the release engine and the matching CLI.
- NVDA is the tested screen reader. Flutter semantics are exposed through the
  native Windows accessibility bridge; the viewer also supports keyboard use.

## Bundle layout

`pwsh -NoProfile -File viewer/tool/package.ps1` writes:

| Path | Contents |
| --- | --- |
| `tasks_viewer.exe` | Flutter release executable |
| `tasks.exe` | Matching CLI build for the same commit |
| `data/` | Engine, ICU data, Flutter assets, bundled announcement clips |
| `bundle-metadata.json` | Source commit, dirty flag, executable and asset hashes |
| `SHA256SUMS.txt` | SHA-256 of every packaged file |

Copy the whole directory. The bundle is portable: it never writes next to
itself except through the Windows startup shortcut described below.

## Launching and configuration

Run `tasks_viewer.exe`. Optional arguments override saved settings for that
launch:

| Argument | Meaning |
| --- | --- |
| `--data-root <absolute path>` | Task store root that holds `registry.json` and `projects/` |
| `--tasks-exe <absolute path>` | CLI executable to use |
| `--settings-root <absolute path>` | Directory for `viewer-settings.json` and `recovery-drafts.json` |
| `--startup` | Auto-start launch; honours a saved `start_with_windows: false` and exits before opening a window |
| `--test-mode` | Test harness only: disables startup registration and window-manager probing |

The CLI is resolved in this order: `--tasks-exe`, the saved absolute path,
then `tasks.exe` beside the viewer executable. A different `tasks.exe` on
`PATH` is never selected silently. The viewer probes `viewer info` before
querying; if the executable is missing or incompatible it shows a persistent
setup error, disables data actions, and keeps Settings and Hotkey help usable.

Settings default to `%LOCALAPPDATA%\MaxLogic\tasks-viewer`, separate from the
task store. Test harnesses pass all three paths plus `--test-mode`.

Settings pane:

- CLI path with Browse and Test connection.
- Data root with Browse.
- Theme (Follow Windows, light, dark, high contrast light, high contrast dark)
  and text size (100 %, 125 %, 150 %, 175 %, 200 %).
- Pane widths for Projects, Tasks and Details, plus Reset layout.
- Start with Windows.
- Announcement mode and Bella volume, with Test voice.

Changes apply when Settings is saved. Cancel leaves the stored document
untouched.

## Window and Windows startup

Every normal launch opens maximized on the last-used monitor when it is still
connected, otherwise the primary monitor; the client area fills the working
area without covering the taskbar. Restore, Minimize and Maximize stay
available, and a saved restored size is clamped back onto a connected monitor
after a resolution or topology change.

`start_with_windows` defaults to true. On the first normal packaged-release
launch the viewer creates one application-owned shortcut named
`MaxLogic Tasks Viewer.lnk` in the current user's Startup folder that targets
this executable with `--startup` and the explicit data, settings and CLI
paths. Saving Settings with the checkbox cleared removes only that owned
shortcut and later launches do not recreate it. A shortcut that points
elsewhere is reported as a conflict instead of being overwritten. If Windows
startup policy or Task Manager disables the app, the effective disabled state
and instructions are shown and nothing is re-enabled automatically. Moving
the bundle re-registers it on the next normal launch, which never promises
that a deleted path will still start.

One instance runs per Windows user and settings root; a second launch
activates the existing window instead of starting a second editor.

## Hotkey help

The toolbar keeps a permanent **Hotkey help (F10)** button next to Settings in
every layout, including empty and connection-error states. The dialog is
searchable, groups bindings by Global, Projects, Tasks, Task details, Editor
and Dialogs, and reports which context was active before opening. Its content
is generated from the same command registry the controls use. Closing it
restores focus to the control that opened it, and opening help from another
modal returns focus to that modal.

Global bindings:

| Key | Action |
| --- | --- |
| `F1` | Select the Projects region and focus its selected row |
| `F2` | Select the Tasks region and focus its selected row |
| `F3` | Reveal and focus the task description/body, including the editable draft body |
| `F4` | Edit the selected task |
| `F5` | Refresh the workspace, preserving draft and focus |
| `F6` / `Shift+F6` | Next/previous region: Projects, Tasks, Task details, Status |
| `F10` | Hotkey help |
| `Ctrl+F` | Focus the text filter of the focused Projects/Tasks region, otherwise the last focused list |
| `Ctrl+H` | Find in body (literal text, Next/Previous, match count) |
| `Ctrl+C` | In the task body reader: copy selected text, or the full body when nothing is selected; preserve stored line endings |
| `Ctrl+D` | Mark the selected task done, using the dirty-draft guard when needed |
| `Ctrl+E` | Enrich the clipboard, only while the Projects list itself has focus |
| `Ctrl+V` | While the Projects or Tasks list itself has focus: replace that list's search with the trimmed clipboard text and apply it; focus stays in the list |
| `Ctrl+S` | Save the active editor |
| `Ctrl+,` | Settings |
| `Alt+Left` | Back from a dependency detail or a reduced-layout child pane |
| `Escape` | Close the active popup or dialog; no destructive action on its own |

Plain `Ctrl+E` outside the Projects list, and `Ctrl+V` outside a focused list,
keep the focused control's normal behaviour (a search field pastes as usual). Every other native text-editing key stays with the field, including
AltGr combinations; F1/F2/F3, F4, F5, F6, F10, Ctrl+S, Ctrl+H and Ctrl+, keep
their documented meaning while a text field has focus. Press F10 for the full
scoped list, including the per-region `Alt` access keys.

In the Tasks search field, a number such as `123` searches for that exact ticket
using the selected project's prefix (`T-123` or `KEY-123`). Leading zeros and
surrounding spaces are accepted. Other input searches titles and bodies as before.
The current scope and filters still apply.

## Announcements

- **Bella** plays the bundled static clips for fixed outcomes (loading, no
  matches, draft restored, save acknowledged, clipboard results and so on) at
  the configured volume.
- **NVDA only** leaves those fixed outcomes to NVDA and never plays audio.
- **Off** disables both clip playback and app-generated speech.

Dynamic text such as task titles, counts and error prose is exposed through
the semantic tree, never a generated clip. Off suppresses app-generated live
announcements, not NVDA's ordinary navigation of controls. The clips are
bundled, so playback needs no network access and no credentials. Their
provenance manifest travels with them in
`data/flutter_assets/assets/announcements/manifest.json`; `catalog.json` and
the manifest are verified against the packaged clips at build time.

## Drafts, conflicts and recovery

An editor draft is written under the settings root and keyed by store
identity, project UUID and task ID. Leaving a dirty editor asks whether to
save, keep the draft or discard it; a crash or restart offers the stored draft
back. Settings and the draft index are written atomically by creating a
temporary file and renaming it into place. A settings file that cannot be
parsed is moved aside as `viewer-settings.corrupt-<timestamp>.json` and the
viewer starts from defaults instead of discarding it silently.

Saving is version-checked. A conflicting write from another process keeps the
typed values, reports the conflict and offers to reload the current task; the
viewer never retries a conflicting write by itself. For a lost local save
acknowledgement, reconciliation waits for the owned writer and re-reads the task.
Remote writes retain their original request receipt; **Check pending change**
reconciles that request rather than creating a replacement write. Drafts survive
service failures and restarts. See [remote recovery](../integration/remote-viewer.md).
A missing data root shows "No task store found" with the
resolved path, and an unavailable or malformed project database produces its
own error row without hiding the healthy projects.

## Statistics shown for a project

Statistics are sampled per project database, one database at a time, and are
independent between projects rather than one global snapshot. Unavailable
statistics are never shown as zero.

| Field | Meaning |
| --- | --- |
| `total` | All stored tasks, including cancelled |
| `open` | draft, todo, in-progress, to-verify and blocked |
| `blocked` | Explicit blocked status; waiting on a dependency alone does not count |
| `done` / `cancelled` | Counts of those exact statuses |
| Started | `MIN(created_ms)`, shown as "Started (first recorded task)" |
| Last write | `MAX(updated_ms)`, excluding rules and viewer settings |
| Progress | `100 * done / (total - cancelled)`; "Not applicable" when no non-cancelled task exists |

## Building and verifying from source

Pinned toolchain: Flutter 3.44.1 stable with Dart 3.12.1 on Windows x64
(`viewer/pubspec.lock` is committed). The Windows host that produced the
current evidence also runs Rust 1.98.1.

The committed screenshot fixtures use Windows Segoe UI fonts and the Warsaw
timezone (`Central European Standard Time`, including its daylight-saving
rules). Windows 11 is the default baseline. CI selects the reviewed Server 2022
references with `-GoldenBaseline windows-server-2022` in the verifier and sets
the zone on its disposable runner. Direct Flutter tests select that baseline
with `--dart-define=TASKS_VIEWER_GOLDEN_BASELINE=windows-server-2022`.
Both sets use exact pixel comparison; failures retain image diffs.

From `viewer/`:

```text
flutter pub get
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze --fatal-infos
flutter test --reporter expanded
flutter build windows --release
```

`test/accessibility/rendered_semantics_audit_test.dart` combines Flutter's
`labeledTapTargetGuideline` with a rendered-tree audit for unnamed or
inoperable controls. It covers the default populated workspace, first-load,
expanded-dropdown, disabled-editor, Settings, Keyboard Help and first-load
error states. These headless checks verify the semantics Flutter produces.
They do not replace the Windows and NVDA walkthroughs required by V10 for
actual speech, focus order and native bridge behavior.

From the repository root:

```text
pwsh -NoProfile -File viewer/tool/verify-windows.ps1
pwsh -NoProfile -File viewer/tool/measure.ps1
pwsh -NoProfile -File viewer/tool/package.ps1
```

`verify-windows.ps1` builds the matching CLI, runs the headless Flutter and
integration suites, then opens the packaged release against a synthetic store
to check its external Windows UI Automation tree. The UIA gate sends no
keyboard or pointer input and fails if the native project region or row is
missing. `-IncludeWindowedIntegration` separately opts into the Flutter
windowed test build. `measure.ps1` seeds deterministic
release fixtures with a recorded seed and times the release CLI round trips.
Each script retains logs under `viewer/target/evidence/viewer/<run-id>/` and
receives explicit temporary data and settings roots; none of them touch a real
backlog. Dated results and environment-specific limitations are recorded in
`viewer/verification-report.md` and integration deployment records. Their counts
and unavailable rows describe the named run, not every later build.
