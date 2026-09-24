# Tasks Viewer specification

Status: Ready for implementation. All implementation and runtime verification below are planned, not completed.

Date: 2026-09-21

## 1. Context and authority

Build a local Flutter/Dart Windows x64 application for reviewing the existing shared tasks-cli backlogs. The primary user uses NVDA. Project discovery, searching, comparison, keyboard navigation and safe editing must work without sight or a mouse.

This document is the viewer's functional and implementation contract. [design.md](design.md) defines presentation, focus and interaction. [../spec.md](../spec.md) remains authoritative for storage ownership, task invariants, migrations, backups and existing CLI behavior. Additive commands specified here are new work; do not pretend they already exist. If source changes after this specification, reconcile the affected contract before implementation.

The new viewer command group deliberately adds timestamp fields, exact initial query counts and offset navigation. These are scoped extensions to the root spec's minimal list/search output and no-count-per-page rule. Legacy list/search/show output remains unchanged. This document does not authorize changing storage ownership or migration rules.

The requested deliverables for this authoring task are these documents and [goal.md](goal.md). Executing the goal later authorizes implementation. Do not start implementation merely because these files exist.

### Verified repository baseline

- `src/cli.rs`: `list`, `search`, `show`, `update`, `history`, `rules show`, `enrich` and `enrich-clipboard` exist. Global options include `--data-root`, `--project` and `--format json`.
- `src/registry.rs`: `registry.json` contains root-to-project UUID bindings. Multiple roots can identify one project. The Windows default data root is `%LOCALAPPDATA%\MaxLogic\tasks-cli`. There is no project-list CLI command.
- `src/model.rs`: six statuses are `draft`, `todo`, `in-progress`, `blocked`, `done`, `cancelled`; priorities are `P0` through `P3`. Details include dependencies, labels, rules and version. Existing summary/detail JSON omits task timestamps.
- `src/store.rs`: tasks have `created_ms` and `updated_ms`. The project table has no project-start timestamp. Events are append-only and writes use optimistic versions.
- `src/output.rs` and `src/error.rs`: success JSON uses a versioned envelope; errors have machine-readable codes and exit statuses. Preserve existing output contracts.
- `src/enrich.rs`: reference enrichment is existing Rust behavior. Reuse it instead of reimplementing reference parsing in Dart.

## 2. Scope and decisions

Required: discover registered projects; show project statistics; filter, search and sort both collections; virtualize both lists; select and read complete task details; edit existing tasks; mark a task done with Ctrl+D; inspect dependencies, history and project rules; enrich clipboard text in the selected project's context with its button or Ctrl+E; remember navigation preferences; use the full ultrawide monitor with maximized startup; start with Windows by default with a Settings opt-out; bundle ElevenLabs Bella static announcement audio; provide a portable Windows release and reproducible tests.

Excluded: creating/deleting tasks or projects, bulk edits, import/migration UI, rule editing, cloud services, accounts, synchronization, Linux/macOS viewer builds, automatic updates and automatic AI execution. The Rust CLI still requires native Windows and Linux verification when changed.

| Decision | Required implementation | Reason |
| --- | --- | --- |
| Storage access | Flutter invokes the Windows `tasks.exe`; Dart never opens task SQLite files or edits the registry | One implementation of validation, transactions and Windows ownership |
| Process boundary | Short-lived processes using argument arrays and UTF-8 JSON, no shell | Safe text handling and existing architecture |
| Queries | Add `tasks viewer ...` commands in the same Cargo package | Existing list/search cannot express the combined query contract |
| UI | Flutter SDK controls plus a reusable virtual list; separate read view and explicit Edit mode | Predictable reading and deliberate saves |
| State | Concrete services/controllers with `ChangeNotifier`, immutable DTOs, injected process/settings interfaces | Testable without a new state framework |
| Project start | Earliest stored task creation time, explicitly labelled as inferred | Do not invent a missing historical project creation date |
| Progress | Completed non-cancelled tasks divided by all non-cancelled tasks | Cancelling work must not count as completing it |

## 3. Runtime and component boundaries

Create the Flutter project inside `viewer/`, preserving these documents. Use the stable Flutter SDK available at implementation start, record the exact Flutter/Dart versions, commit `pubspec.lock`, and pin the tested toolchain in `viewer/README.md`. Use Windows 11 x64 as the required runtime. Ship all Flutter release bundle files and the matching `tasks.exe` together. No SDK should be required on the user's machine.

Proposed paths:

| Path | Responsibility |
| --- | --- |
| `viewer/lib/main.dart`, `app.dart` | Startup and root navigation |
| `viewer/lib/data/cli_client.dart` | Process lifecycle, protocol validation, typed errors |
| `viewer/lib/data/models.dart` | DTO parsing, no widgets |
| `viewer/lib/data/settings_store.dart` | Versioned atomic settings and draft persistence |
| `viewer/lib/platform/` | Monitor/window state, per-user startup registration, single-instance activation and local audio playback |
| `viewer/lib/controllers/announcement_controller.dart` | Static Bella clips versus dynamic NVDA announcements; cancellation and deduplication |
| `viewer/assets/announcements/` | Generated Bella MP3 files and provenance manifest, bundled for offline use |
| `viewer/lib/controllers/` | Project query, task query, detail editor and clipboard state |
| `viewer/lib/ui/` | Screens, forms, dialogs, accessible virtual list |
| `viewer/test/`, `viewer/integration_test/` | Unit/widget tests and real Windows integration |
| `viewer/tool/` | Reproducible verification, fixtures and packaging scripts |
| `src/viewer.rs`, `tests/viewer_api.rs` | Additive Rust query/update contract and subprocess tests |

Resolve the CLI in this order: explicit viewer `--tasks-exe` absolute path, saved absolute path, bundled `tasks.exe` beside the viewer executable. Do not silently select an unrelated PATH version. Require the protocol probe below before querying. Settings provide Browse and Test connection actions. If the CLI is missing/incompatible, show a persistent setup error and disable data actions, while keeping Settings and Help usable.

Support viewer launch arguments `--data-root <absolute path>`, `--tasks-exe <absolute path>`, `--settings-root <absolute path>`, `--startup` and test-only `--test-mode`. Path arguments override saved settings. Automated test harnesses must supply all three paths and `--test-mode`. Default settings live under `%LOCALAPPDATA%\MaxLogic\tasks-viewer`, separate from the task store. Never initialize a task store when it is missing. Show "No task store found" with its resolved path.

### 3.1 Full-monitor window and Windows startup

Start maximized on every normal launch, including auto-start. Select the last-used monitor if connected, otherwise the primary monitor. Get its current working area and DPI; use the whole available client area without covering the taskbar. The user's display reported 3440x1440 physical pixels during authoring; never hard-code that as a logical size. Pane proportions and responsive behavior are defined in design.md. Preserve ordinary Restore/Minimize/Maximize controls, and clamp saved restored bounds to a connected monitor after resolution/topology changes.

`start_with_windows` defaults true. On the first normal packaged-release launch, create one application-owned shortcut named `MaxLogic Tasks Viewer.lnk` in the current user's Windows Startup known folder. Target the absolute installed viewer executable with `--startup`, its explicit data/settings/CLI paths, and the executable directory as working directory. Use the Windows shortcut API through a maintained Windows-capable package or small platform bridge; paths/arguments are separate properties, never a shell-composed command. Startup-folder shortcuts are a supported [Windows sign-in startup mechanism](https://support.microsoft.com/en-us/windows/experience/startup-boot/configure-startup-applications-in-windows).

The Settings checkbox "Start with Windows" is enabled initially and can be disabled. Apply only when Settings is saved. Disable removes only this app's owned shortcut; subsequent launches must not recreate it while false. Record registration success/failure independently of desired state and show errors with Retry. Detect an existing shortcut with an unrelated target and report a conflict instead of overwriting it. If Windows startup policy/Task Manager disables this app, show the effective disabled state and instructions; never re-enable it automatically or edit undocumented StartupApproved state. A moved portable bundle is re-registered only after the user launches it at the new location; never promise a deleted path will still launch.

Use one normal instance per Windows user and settings root. A second launch activates the existing window rather than creating another editor. `--startup` must honor a saved false preference and exit before opening a window if stale registration invokes it. Debug/test builds and any launch with proposed `--test-mode` must never create/remove real startup registrations. The harness supplies that flag; startup tests use an injected temporary Startup directory and process-activation adapter. Real sign-in verification occurs in a disposable Windows test account and must not sign out the user's active session. Startup registration is implementation work, not a machine change performed while editing this specification.

The manual packaged-release sign-in test is distinct from automated registration tests: run without `--test-mode` only inside the disposable Windows account, use explicit synthetic data/settings paths and allow its real application-owned Startup shortcut. After verification remove only that test account's run-owned shortcut and fixture artifacts. Do not run this manual procedure under the user's normal account. Injected-directory tests alone cannot pass the real sign-in gate.

### 3.2 CLI process transport

Use `Process.start` with `runInShell: false`. Close stdin after writing requests, drain stdout/stderr concurrently, and decode UTF-8 strictly. Never interpolate text into cmd.exe/PowerShell. All operations after project selection pass its UUID explicitly; never route by the viewer's working directory.

At most two read processes and one mutation/clipboard process may be active. Coalesce rapid queries with a 250 ms debounce; Enter submits immediately. Associate each result with a generation and project UUID. Discard stale responses without changing selection or speaking obsolete results. Kill only viewer-owned superseded reads. Do not cancel writes automatically. After 10 seconds show "Still saving; outcome not yet known" for a running write. On abnormal exit, reconcile as specified in section 7 rather than replaying it. Read timeout is 30 seconds, followed by an explicit Retry action. Stop initiating background work while minimized.

## 4. Additive CLI protocol

### 4.1 Common rules

Add a `viewer` command group. Invoke with `--format json`. Existing commands retain their formats and behavior. Use the existing success envelope with `schema_version: 1`, `project_id` and `data`; new payload tags are `viewer_info`, `viewer_projects`, `viewer_tasks`, `viewer_show` and `viewer_update`. Add `protocol_version: 1` inside each new payload. Do not confuse this protocol number with SQLite's schema version.

Commands:

```text
tasks --format json viewer info
tasks --data-root <root> --format json viewer projects --request-file -
tasks --data-root <root> --project <uuid> --format json viewer tasks --request-file -
tasks --data-root <root> --project <uuid> --format json viewer show T-007
tasks --data-root <root> --project <uuid> --format json viewer update --request-file -
```

`-` means UTF-8 JSON on stdin; ordinary file paths are also supported for reproductions. Request size limit is 8 MiB, checked before parsing. Reject unknown fields, duplicate JSON keys, malformed JSON, unsupported enum values, negative offsets and out-of-range limits with exit 2. Missing optional fields take the documented defaults; explicit null is accepted only where stated. Read and parse requests before opening a transaction. `viewer info` must not access/create a store; return `protocol_version`, supported operations and the model limits from section 7. Reject a protocol version other than 1 in the client. Unknown additive response fields may be ignored; missing/wrong-type required fields are errors.

Use a duplicate-key-rejecting deserialization visitor at every object level. Use presence-aware fields to distinguish absent from null; plain `Option<T>` alone is insufficient. Tests must distinguish omitted body, null body and duplicate body keys. All new commands require JSON format; invoking them in text mode returns a usage error. `viewer info` returns the six editable-field limits, canonical statuses/priorities and the operation names defined here.

Collection read successes return `items`, `total_count`, `offset`, `limit`, `has_more` and `next_offset` (null at the end). Defaults: offset 0, limit 100; allowed limit 1..200. `total_count` is the exact filtered count, not the loaded count. Empty results have zero items and a null next offset. Compute the task count only for a null snapshot and bind it into that token; subsequent valid-token pages return that same count without recounting. Snapshot validation, initial count and rows must use one read transaction. Limit/offset must be applied in SQL for task rows; never retrieve task bodies to filter or sort them in Dart or Rust. Fetch labels/dependency counts for only the selected page in batched queries.

`viewer show T-ID` returns all existing TaskDetail fields plus `created_ms` and `updated_ms` in one read transaction. Use this command for viewer details, post-save reconciliation and dependency navigation. Keep the original `show` command unchanged. In the rest of this document, viewer detail re-reads mean this new command.

Use allowlisted SQL fragments for sort keys and parameter binding for values. Return full titles in JSON. Never silently shorten title/body content. Existing error envelope and exit codes remain authoritative. Add `stale_snapshot` with exit 4 for query invalidation; distinguish it from `version_conflict` by code. Errors must not contain task bodies or clipboard text in logs.

### 4.2 Project enumeration and statistics

Project request fields:

```json
{"query":"","state":"all","sort":"name","direction":"asc","offset":0,"limit":100,"snapshot":null}
```

`state`: `all`, `has-open`, `has-blocked`, `complete`, `empty`, `unavailable`, `active`, `archived`. `complete` means non-cancelled total > 0 and open = 0; an all-cancelled project is not complete. `unavailable` means the project database is missing or could not be read. Only `archived` includes archived projects; every other state, including `all`, excludes them. `active` and `all` both include every non-archived project independently of database availability. `query` is a trimmed literal substring over display name, UUID and every bound root. Matching is ASCII case-insensitive; non-ASCII characters match exactly. `%`, `_`, quotes and backslashes are literal. Empty query matches all. State and text filters combine with AND.

Enumerate unique UUIDs from existing registry bindings only; do not scan disks, infer projects from folder names, or rewrite the registry. Include missing roots and inaccessible project databases. Sort roots by ASCII case-insensitive text, then exact text. Display name is the final path component of the first root in that order, falling back to the UUID. Duplicate names remain separate rows and show their path. The project details panel lists all bound roots and the UUID.

For each UUID, return `project_id`, `name`, `roots`, `availability` (`available`, `missing`, `error`), nullable `error` (`code`, `message`), `sampled_at_ms`, nullable `archived_at_ms`, and nullable `stats`. Store project statistics and archive dates in a SQLite metadata file under the selected data root. Compare database identity, size and modification time plus WAL/journal fingerprints on refresh; reuse unchanged statistics without opening that project database. Retry missing/error databases on each refresh. When a changed database is read, inspect one DB at a time, closing it before opening another. Reuse storage validation and read-only opening rules, but set the project-statistics read connection's SQLite busy timeout to zero. A locked DB becomes an error row immediately; retain existing write/legacy-command timeouts. An unavailable database produces its own error row; malformed registry data fails the command. Never represent unavailable statistics as zero. A valid empty registry produces an empty result.

`viewer archive` records the current archive time for the selected project; `viewer archive --unarchive` clears it. Archive state is user metadata, so the metadata SQLite file is persistent data rather than a disposable cache. A project's last task write strictly later than its archive time automatically clears the archive date on catalog refresh. An equal timestamp keeps it archived. Archive changes invalidate project page snapshots.

Aggregate within each DB using SQL, without loading tasks. The registry is read once. Project statistics across databases are independently sampled, not one globally atomic snapshot. Sorting/filtering the compact aggregate records in Rust is permitted because there is no cross-project database. Return only the requested page. This is an explicit exception for project metadata, not permission to load task collections. Return a snapshot token derived from the query and a deterministic hash of all catalog records, excluding sample times and variable error prose but including identity, availability, error code and statistics. Recompute on subsequent page requests and reject a non-null mismatching token with `stale_snapshot`. Apply the same bounded refresh behavior as task pages. This detects changed ordering without claiming globally simultaneous statistics.

| Field | Exact meaning |
| --- | --- |
| `total` | All stored tasks including cancelled |
| `open` | Status in draft, todo, in-progress, blocked |
| `blocked` | Explicit status blocked; dependency waiting alone does not count |
| `done` / `cancelled` | Counts of those exact statuses |
| `started_ms` | MIN(tasks.created_ms), null for no tasks; UI label "Started (first recorded task)" |
| `last_write_ms` | MAX(tasks.updated_ms), null for no tasks; excludes rules and viewer settings |
| `progress_percent` | null when total-cancelled = 0; otherwise 100*done/(total-cancelled), rounded to one decimal for display only |

Sort keys: `name`, `open`, `total`, `blocked`, `started`, `last-write`, `progress`. Direction is `asc` or `desc`; tie-break always project UUID ascending. Compare progress using the unrounded ratio. Null values sort last in both directions. Default is name ascending; the UI defaults counts and dates to descending when their sort key is selected and offers one button to reverse direction. Non-archived unavailable projects match `all`, `active` and `unavailable`. Archived unavailable projects match only `archived`. Project counts do not change when task filters change. Example: 10 total, 2 cancelled, 4 done yields 4 open and 50.0% progress. Zero tasks or only cancelled tasks display "Not applicable", not 100%.

### 4.3 Combined task query

Task request fields:

```json
{"query":"","scope":"open","statuses":[],"priorities":[],"labels":[],"readiness":"any","sort":"priority","direction":"asc","offset":0,"limit":100,"snapshot":null}
```

- Scope is `open` or `all`, default open. Explicit statuses further intersect that scope. Choosing a terminal status in the UI changes scope to all and announces the change; the API itself never silently changes scope.
- Statuses and priorities select any of their selected values. Different filter groups combine with AND. Labels require every selected label, normalized by `src/labels.rs`. Empty arrays mean no restriction. "Needs human" toggles the `needs-human` label.
- Readiness is `any`, `runnable`, `waiting`. Runnable follows the existing store selection predicate exactly; waiting means open tasks with at least one nonterminal dependency. Readiness is separate from explicit blocked status. Tests must call the shared predicate/query construction rather than introduce a second definition.
- Query is a trimmed literal substring of title/body, or a complete task ID match for input parsed as `T-<digits>`. Case handling matches project search. Empty text matches all. Escape SQL LIKE wildcards; do not expose an FTS query language. Task search includes full body content without returning bodies in pages.
- Sort keys: `id` (numeric), `priority` (P0..P3), `status` (draft, todo, in-progress, blocked, done, cancelled), `title` (ASCII case-insensitive then exact), `created`, `updated`. Every sort ends with numeric task ID ascending as tie-break. Default priority ascending. Nulls, if encountered in corrupt data, produce an actionable data error rather than guessed dates.

Use explicit SQL expressions: `id`; priority `priority` (the P0..P3 CHECK constraint keeps lexical and priority order identical and permits its index); status `CASE` mapping the specified sequence to 0..5; title `lower(title), title COLLATE BINARY`; `created_ms`; `updated_ms`. Apply requested direction to all primary sort components, then ID ascending, except ID-only sorting which uses the requested direction once. Never order status by its raw text. Test both directions with ties and non-ASCII titles.

Each task item returns `id`, `title`, `status`, `priority`, `version`, `labels`, `dependency_count`, `waiting_dependency_count`, `created_ms`, `updated_ms`. Do not embed bodies, rules or history snapshots in list responses. Display canonical IDs using at least three digits, for example T-007 and T-12000.

Return a `snapshot` token from the task read transaction. It binds project UUID, database identity, current maximum event ID, initial total count, and all query/sort parameters excluding offset/limit. Use an opaque deterministic encoding with a validated format; it is not a security credential. Validate a non-null token against the transaction's first read snapshot before selecting any rows. On mismatch return `stale_snapshot`, with no items. This prevents combining offsets across intervening writes. Same-timestamp writes must invalidate it; timestamps alone are insufficient. Use an event-backed generation and platform file identity so replacing the database invalidates old pages. Pure rule writes may conservatively invalidate pages.

Use the safe [`file-id` crate API](https://docs.rs/file-id/latest/file_id/) for Windows volume/file ID and Linux device/inode identity; pin the selected release in Cargo.lock. Do not add unsafe application code. Check identity before opening and after the read transaction; discard results on change. Test same-path replacement with equal file length/timestamps. Follow existing storage locks for repository-owned replacement. Arbitrary external in-place corruption is a database error, not a supported concurrent mutation. Expire tokens after application restart rather than persisting pages across sessions.

On invalidation, retain the displayed list as stale, clear cached subsequent pages and reload from offset zero once. Preserve a selected task's detail/draft by ID. If invalidation repeats during that refresh, show "Tasks are changing. Refresh to load the latest list"; do not loop forever or move keyboard focus. No claim of a frozen multi-process snapshot is permitted.

## 5. Collections and refresh

The exact layouts and keyboard contract are in design.md. Both lists must be virtual even for small datasets. Use `ListView.builder` or a sliver builder with stable UUID/task-ID keys and correct item indexes. A giant `Column`, eager `DataTable` or one widget per database task is not acceptable.

Use 100-row pages, prefetch the next page when within 20 rows of its boundary, and retain at most five task pages plus the selected task detail/draft. Evict least recently used pages that do not contain the focused row. Keep at most five project pages; project aggregates can be recomputed by the CLI. Do not retain every visited row widget or FocusNode. Builder count represents total filtered rows; unloaded positions are placeholders with a loading label, never invented task IDs. Announce the actual row only after it is materialized.

Arrow keys, Page Up/Down and Home/End operate on logical row indexes across pages. End requests the page containing the last result directly; it must not fetch all intervening pages. Fetch then scroll then focus the target keyed row. While loading, keep focus on the list and announce "Loading row N" only if it takes more than 500 ms. A stale snapshot cancels the pending jump.

Selecting a task loads `show` asynchronously. Selecting a project loads its task query and project summary. Late detail results for an old selection are ignored. Debounce detail loads for arrow navigation by 150 ms; Enter loads immediately. Selection does not move keyboard focus to details. Preserve each project's filters, sort and last selected task separately. After a save, refresh task and project statistics, select the saved ID if still present, otherwise show "Saved task no longer matches these filters" while retaining its detail until the user selects another task.

F5 refreshes the current workspace, and a Refresh button is always available. When the app regains focus, refresh if the last successful read is older than 30 seconds. No periodic background polling. Refresh never replaces dirty fields. Keep last confirmed data visible with "Refreshing" or "Refresh failed" status; show its sample time. A failed first load is an error view with Retry, not an empty list.

Persist query settings, sort, selected UUID/ID, theme, text size and pane widths, but not cached task bodies. Search text is local private preference data. Settings writes use a temporary file in the same directory followed by atomic replacement. A corrupt settings file is preserved with a timestamped name and replaced by defaults with a visible warning. Changing data root resets project selection and cached rows after the dirty-draft guard.

## 6. Task reading

Show the full title, ID, canonical status, priority, labels, timestamps and version. Render body Markdown as selectable plain source text in v1; preserve all whitespace and content, allow keyboard selection and copy, and provide Find in body. Do not execute embedded HTML or open URLs automatically. Full text must be available to NVDA line/word/character navigation, including a 1 MiB body. Do not merge an entire body into a single unstructured announcement.

Dependencies show ID, title, status and whether they prevent readiness, using `dependency_summaries`. Activating one opens its detail in the same project with Back restoring the previous ID, filter and focus, using the dirty-draft guard. Show all dependencies via a virtual list if necessary. Do not discard dependencies merely because their status is terminal.

Provide separate Details, Dependencies, History and Project rules tabs. Rules are read-only and include `rule_version`. History uses the existing paginated `history` command, 100 events per page; load a full snapshot only when an event is selected using `--event`. Show event ID, operation, resulting version and time, plus complete selectable snapshot text. History and rules must not be loaded for every row.

## 7. Editing and concurrency

Edit button or F4 enters edit mode for the selected task. F1 focuses Projects, F2 focuses Tasks, and F3 focuses the description/body directly, including its draft editor. Ctrl+F focuses the text filter of the focused list, or the last focused list when outside both. design.md section 9 is the authoritative complete shortcut/access-key map. Editable fields are title, body, status, priority, labels and dependencies. ID, timestamps, version, history and rules are read-only. Use labelled SDK text fields and enum selectors. No autosave to the task store. Save/Ctrl+S applies all changed fields in one transaction; Cancel leaves the store unchanged. Save is disabled for a clean form or an in-flight write.

### Mark done

Ctrl+D and the Mark done button set the selected task's status to `done` through one `viewer update` using the displayed version. Enable only when Tasks/Task details has focus, a task is selected and no write is in flight; suppress auto-repeated key-down events. Disable for an already-done task; a repeated invocation creates no event. A cancelled task can be explicitly changed to done subject to the existing store rules. Do not force completion past validation or a version conflict.

In a dirty editor, Ctrl+D first opens "Mark task done with unsaved changes?" with Save changes and mark done (Alt+S), Discard changes and mark done (Alt+D), Cancel (Alt+C/Escape, default). Save includes the draft's other changed fields and `status: done` in one version-checked update. Discard sends only `status: done` but retains the draft until completion is confirmed, so a failed/conflicting update does not destroy it. An unconfirmed operation uses the same conflict/reconciliation rules as Save. On success clear the corresponding draft, update stats, play "Task marked done", and apply the existing saved-task-no-longer-matches behavior. In the list, retain focus at the same logical index, selecting the next surviving row or previous at the end; the done task's read view remains until another task is selected. No extra confirmation is required for a clean selected task.

### Shared validation, updates and recovery

Validate in both Dart and Rust. The store is authoritative:

- Title: existing nonempty title validation and at most 500 Unicode scalar values, not UTF-16 code units.
- Body: at most 1,048,576 UTF-8 bytes, including newlines. Preserve exact entered content.
- Labels: at most 32; each 1..64 ASCII characters in letters/digits/`-_.:`. Trim, lowercase, sort and deduplicate using the existing normalization.
- Dependencies: at most 1000 distinct same-project IDs. Accept comma-separated T-IDs in the editor, allow empty to clear. Reject unknown IDs, self-dependencies and cycles using the existing store validation. Explain errors and keep all draft values.
- Preserve all existing status-transition and dependency readiness rules. Never relax a store rejection to make the UI save succeed. Display its actionable message.

New `viewer update` request:

```json
{"id":7,"expect_version":3,"changes":{"title":"Review parser","body":"Full text\n","status":"todo","priority":"P1","labels":["needs-human"],"deps":[2,4]}}
```

`id` and `expect_version` are positive integers. Changes permit only the six editable fields; absent means unchanged, empty arrays clear collections, null is invalid. Reject empty changes. Dispatch through the existing `TaskUpdate`/store update transaction, including no-op behavior and history semantics. Do not issue one CLI update per field. Return the existing update result fields with the new payload tag; re-read `show` after confirmed success. The stdin contract prevents Windows command-length failures for large dependency/label payloads. A saved form can produce a no-op after normalization; report "No changes needed" when the store does not create an event.

On conflict, retain base version/base fields, the draft and the freshly read current record. Open an accessible conflict dialog listing changed fields with Base, Mine and Current values. Default action is "Return to editor". "Reload current and discard draft" requires explicit choice. "Review against current" rebases the form only after the user chooses Mine or Current for each conflicting field; treat body, labels and dependencies as whole fields, without an automatic text merge. Retain user's nonconflicting changes and current values for fields they did not change. Require a separate Save with the newly read version. Another intervening write produces another conflict, never a force save.

If a write process exits without a valid success/error response, mark the outcome unknown and disable Save until a `show` reconciliation succeeds. If the record equals all intended normalized values, report "Current task matches your changes; save acknowledgement was lost". If it remains at the base version, return to unsaved state with explicit Retry. Otherwise enter the conflict workflow. Do not infer failure from timeout or resend a mutation automatically. Reconciliation itself must not mutate the store.

Switching task/project, closing the window, changing the store or leaving edit mode with dirty fields prompts Save, Discard, Cancel. Cancel is default and restores initiating focus. Save continues navigation only after confirmed save/reconciliation and successful refresh. Discard affects the draft only. While a save is running, closing offers "Keep waiting" by default; never claim it cancels an atomic store write.

Persist one recovery draft per open editor under the settings root, keyed by data-root identity, project UUID and task ID. Include base version/base fields and draft fields. Write after 500 ms idle and immediately before an intentional close/navigation guard. Treat local drafts as private task content; no telemetry or body logging. On restart offer Restore draft or Discard, default Restore, then compare current version before saving. Delete only that draft after confirmed save/discard. If draft persistence fails, show a persistent warning and permit Copy draft so the user can preserve it. Do not promise recovery of keystrokes not yet persisted when a process crashes.

## 8. Clipboard actions

The selected project's toolbar has "Enrich clipboard" and "Preview enrichment" buttons. Ctrl+E while the Projects list has focus invokes the exact same command handler as Enrich clipboard. Ignore key repeat and disable duplicate invocation while processing. One selection scopes both actions to its UUID. Project selection is captured when the action starts; later selection changes do not retarget it. Disable buttons for no selection or unavailable store and expose the reason.

"Enrich clipboard" calls existing `enrich-clipboard` with explicit root/project and JSON output. Preserve its input limits, unknown-ID behavior, idempotence and best-effort text-equality check before replacement. That check is not atomic clipboard compare-and-swap; do not promise stronger race protection. Replacement publishes plain text and may replace other clipboard formats. Never duplicate the read-transform-write logic in Dart. On success expose replacement count and unknown-ID count in the persistent status; Bella mode plays "Clipboard enriched" while NVDA-only mode announces the counts. If unknown IDs need attention, use one dynamic NVDA announcement of that outcome instead of also playing the generic clip. No replacements means "Clipboard unchanged". Do not display or log the entire clipboard on direct action.

"Preview enrichment" reads plain clipboard text once using the Flutter clipboard API, then sends it to existing `enrich --file -`. Show original and enriched selectable text in a dialog with replacement and unknown-ID counts. This action does not write the clipboard. Provide Close only; the direct action is the deliberate clipboard-writing route. Support the existing 16 MiB/10,000 distinct-reference limits, Unicode and line endings. A non-text clipboard shows "Clipboard contains no text" without changing it. A failed write never reports success. Announce processing after 500 ms, and final outcome once; no repeated speech for every ID.

## 9. Accessibility requirements

NVDA is a release gate, not a future enhancement. Follow design.md's role, name, state and keyboard requirements. Flutter semantics are necessary but do not establish NVDA compatibility by themselves. SDK controls already provide many semantics; add missing information without duplicating announcements. Builder-based lists instantiate children on demand; implement selection and focus across unbuilt rows explicitly. See the [Flutter assistive-technology guidance](https://docs.flutter.dev/ui/accessibility/assistive-technologies), [ListView.builder API](https://api.flutter.dev/flutter/widgets/ListView/ListView.builder.html), and [accessibility testing guidance](https://docs.flutter.dev/ui/accessibility/accessibility-testing).

The early accessibility slice must prove a virtual list, labelled edit field, enum control, modal dialog and live status message with the actual Windows build and NVDA. If a framework control fails, fix or replace it within Flutter using a tested accessible implementation. A native Windows bridge is allowed only for a demonstrated missing platform capability, kept small and covered by tests. Do not defer core navigation until the end or silently drop virtual lists.

Required engineering thresholds are product targets, not a legal conformance claim: ordinary text contrast at least 4.5:1; focus/control indicators at least 3:1 against adjacent colors; 2 logical-pixel visible focus outline; controls at least 32 logical pixels high. Follow Windows contrast themes and text scaling. Test 100%, 150%, 200% display scaling and 200% in-app text size. No clipping of controls or loss of operations at 800x600 logical pixels. Reduce to one pane when necessary. Never reserve NVDA's Insert/Caps Lock commands or require Menu/Right Ctrl remapping.

### 9.1 ElevenLabs Bella static announcements

Generate the application's fixed spoken feedback with ElevenLabs using the Bella voice, then bundle the resulting clips. This is development-time generation; runtime playback is local and works offline. NVDA continues to provide control names, focus, row text, editable content and dynamic errors. Do not synthesize private task bodies, titles, paths, IDs, versions or clipboard text through ElevenLabs. No ElevenLabs key goes into Dart, application settings, assets or release bundles.

Create `viewer/tool/generate-announcements.ps1`, a fixed-text catalog and `viewer/assets/announcements/manifest.json`. The generator reads `ELEVENLABS_API_KEY` only from the authorized generation environment, resolves Bella through the account's [List voices API](https://elevenlabs.io/docs/api-reference/voices/search), and stores the selected voice ID/name/category in the manifest. Reuse a manifest-pinned ID on later generations and verify it still identifies the intended voice. Do not use a guessed historic ID or silently substitute a different voice. If Bella is missing or the account has multiple indistinguishable Bella candidates, generation remains pending until access/identity is resolved; unrelated implementation can continue.

Call the official [Create speech API](https://elevenlabs.io/docs/api-reference/text-to-speech/convert) for each fixed phrase. Use `eleven_multilingual_v2` and `mp3_44100_128`, stability 0.5, similarity boost 0.75, style 0, speaker boost true. Verify account support before the batch; record the exact configuration. Generate only missing/changed entries, never during normal builds/tests. The initial phrase batch is in scope when the implementation goal is executed using available authorized credentials; do not automatically purchase credits or start repeated paid batches. Preserve successful clips and report the precise missing credential/voice/quota prerequisite.

Required catalog (file ID -> exact spoken text):

| ID | Text |
| --- | --- |
| `saving` | Saving |
| `task_saved` | Task saved |
| `task_done` | Task marked done |
| `no_changes` | No changes needed |
| `clipboard_enriched` | Clipboard enriched |
| `clipboard_unchanged` | Clipboard unchanged |
| `preview_ready` | Preview ready |
| `reference_copied` | Task reference copied |
| `project_id_copied` | Project ID copied |
| `settings_saved` | Settings saved |
| `loading` | Loading |
| `refreshing` | Refreshing |
| `refreshed` | Refreshed |
| `no_matching_projects` | No projects match these filters |
| `no_matching_tasks` | No tasks match these filters |
| `no_tasks` | This project has no tasks |
| `no_clipboard_text` | Clipboard contains no text |
| `draft_restored` | Draft restored |
| `draft_discarded` | Draft discarded |
| `voice_test` | This is Bella. Spoken announcements are enabled. |

Every additional fixed app feedback utterance must be catalogued and generated before release; control labels/body text read by NVDA are not app feedback clips. Manifest entries include ID, exact text, voice ID, model/settings, generation date, file name, duration and SHA-256. Listen to every generated file, reject incorrect/truncated speech, and record real generation provenance. Do not label another synthesizer's output Bella. Preserve the generator's text/config hash to avoid unnecessary regeneration. Ship committed reusable assets; packaging validates every referenced file/hash and contains no API key.

Settings "Announcements" has Bella (default), NVDA only, and Off. Off disables only application-initiated clips/live messages; it never disables semantic controls or the user's screen reader. Bella volume defaults to 70%, adjustable 0..100 in 10% steps; Test voice plays the fixed preview. Store preferences locally. Missing/corrupt clip or playback failure falls back to an NVDA live announcement and a persistent audio warning without blocking the operation; release verification must still reject a missing required clip.

Use one announcement controller and one audio player. The persistent Status control is focusable/readable on demand in every mode. For a static event in Bella mode its updated text is explicitly non-live: play one matching clip, with the full dynamic outcome remaining readable in Status. For dynamic error/validation/conflict details, audio fallback and NVDA-only outcomes, use exactly one live announcement channel and skip the equivalent clip. Never combine an explicit announcement call and a live-region update for the same event. Off keeps all status updates non-live. Never splice IDs/counts into prerecorded phrases. In NVDA-only mode announce the full status including its task ID/version/count. Coalesce obsolete progress: play loading/saving only after 500 ms and stop it when the final result arrives. Queue at most one pending final clip, replacing stale feedback with the latest relevant event. Never overlap two app clips.

Do not delay a save, focus restoration or keyboard input to finish audio. Defer routine clips until focus changes settle for 300 ms; new input cancels pending clips and stops current app speech. Keep the full result text accessible after cancellation. The app must not stop/mute NVDA. Test with NVDA running to identify interference; no duplicate outcome announcements or unreadable focus feedback may be accepted. Allow immediate switch to NVDA-only or Off through Settings. Unsolicited startup clips are not required.

## 10. Performance and correctness evidence

All numbers here are acceptance targets, not current measurements. Use a local SSD, Windows 11 x64, at least 4 logical CPUs and 16 GiB RAM; record exact CPU, RAM, storage, OS, power mode, toolchain, NVDA version and commit. Run release binaries, including CLI process startup in timings.

Fixtures use an explicit unique temporary root outside the repository and live store. Provide a deterministic fixture generator with a recorded seed: 100 projects with 1000 tasks each, plus one separate project with 100,000 tasks; all six statuses, four priorities, labels, acyclic dependencies, repeated sort values and Unicode. Most bodies are 2 KiB; include one 1 MiB body and 1000 dependencies. A separate 1000-project empty-store fixture tests project virtualization. Never create fixtures through the real default root.

Targets over 30 runs after one warm-up: p95 first task page <=500 ms; detail <=300 ms for ordinary bodies and <=1 s for maximum body; save acknowledgement <=750 ms uncontended; project first page with statistics <=5 s for the 100-project fixture, <=10 s for 1000 empty projects. Literal body searches on 100,000 tasks may take <=2 s p95. Record cold start separately, target first usable project list <=6 s on the 100-project fixture. Do not weaken SQLite durability to achieve these values.

For a scripted 60-second scroll in the 100,000-task project, target p95 UI/raster frame time <=16.7 ms and no application-caused main-thread stall >100 ms. Measure profile-build Flutter frame data and separately release process working set, excluding the NVDA process. Viewer peak working set target <=350 MiB. Retained row widgets/FocusNodes must scale with viewport/cache, not total_count; returning from row 100,000 must not retain all visited pages. Measure with NVDA both enabled and disabled and report each; performance success does not excuse inaccessible semantics.

## 11. Validation strategy

### Scheduling and fixtures

Use focused tests for each slice with a meaningful failing test before behavioral implementation. Preserve first-failure evidence. Run one Flutter project-wide batch after slice 4; run final Flutter, native Rust and release gates after slice 7. An early Windows build for NVDA proof is also required. Repeat broad gates only for changed inputs or unresolved failures. Existing Rust gates are project-wide and WSL gates are expensive; do not repeat them after every document/widget edit.

All process, integration and performance tests receive unique `--data-root` and `--settings-root`; child CLI calls must inherit the fixture root explicitly. A test must fail closed if configuration is absent. Never mutate live backlogs, project identity files, clipboard contents from an unattended user session, or running installed executables. Automated clipboard tests run in a controlled test desktop; manual clipboard tests use synthetic text deliberately placed by the tester. Clean only exact run-owned roots after verifying their resolved boundaries.

### Required test matrix

| ID | Tests and expected proof |
| --- | --- |
| V01 | Protocol: version mismatch, missing executable, Unicode paths, malformed/oversized JSON, duplicate keys, invalid enum, both output streams, nonzero exit, timeout; actionable errors and no phantom success |
| V02 | Projects: two bindings one UUID, same names different UUIDs, missing roots/DB, corrupt registry, one corrupt DB among healthy ones, empty and cancelled-only projects; correct counts/nulls and exact filter/sort order |
| V03 | Tasks: combined filters, literal `%_` and quotes, Unicode, body-only match, numeric IDs, all sorts/ties, empty/end/limit boundaries, End at row 100,000, intervening same-ms writes and DB replacement; no duplicate or skipped rows within a valid snapshot |
| V04 | Editor: every field, clearing arrays/body, max lengths and multibyte boundaries, invalid status/dependency/cycle, no-op, atomic rollback, version conflict, late detail response, save acknowledgement loss; real DB/history proves exactly the permitted write |
| V05 | Draft/navigation: Save/Discard/Cancel for each leaving action, crash/restart restore, corrupt settings, disk write failure, changed store identity; no silent draft loss or save to wrong project |
| V06 | Clipboard: known/unknown/repeated IDs, project collision, already enriched text, no text, Unicode/newlines, input limits, clipboard contention/change; preview never writes and direct action follows Rust protections |
| V07 | Widgets/semantics: every control name/role/state, focus order, cross-page navigation, selection retention, disabled reasons, modal focus return, stale errors, loading announcements, text scaling and contrast themes |
| V08 | Windows end-to-end: launch packaged candidate, discover/filter/sort, cross virtual boundary, edit/reopen, conflict against a second real CLI writer, preview/enrich synthetic clipboard, restart with draft, unavailable store recovery |
| V09 | Performance: section 10 fixtures, percentile/raw samples, frame/memory evidence, retained page/node bounds |
| V10 | Manual NVDA: every walkthrough in design.md, speech evidence and actual text editing; automated semantics or UI Automation alone cannot pass this row |
| V11 | Hotkeys/help: F1/F2/F3 exact focus targets, remembered-list Ctrl+F, all scoped access keys, AltGr/text-editing preservation, modal isolation, key-repeat suppression, Ctrl+D atomic/draft/conflict paths, Ctrl+E project-only routing, permanently visible Hotkey help button/F10, registry-generated searchable help and focus return |
| V12 | Window/startup: full 3440x1440 monitor at actual DPI, maximized manual/sign-in launch, changed/missing monitor, default-on registration, disable persists, foreign shortcut preserved, moved bundle, second-instance activation, policy-disabled startup and registration failure; real sign-in proof in a disposable Windows account |
| V13 | Bella: real ElevenLabs voice/config provenance and listening checks, manifest coverage/hash integrity, offline packaged playback, volume/modes, no secret or task content in generation, no duplicate app/NVDA outcome, rapid-event cancellation, playback failure fallback and missing-asset package rejection |

### Commands and evidence

Create the named tests/scripts below as implementation deliverables. They do not exist yet. Run from repository root unless a directory is stated. The harness scripts allocate fixture roots, retain logs under `target/evidence/viewer/<run-id>/`, fail if any required test is absent/skipped, and report actual selected/passed/failed counts. PowerShell scripts must be checked with the installed PSScriptAnalyzer; use Pester for nontrivial fixture/packaging safety logic.

From `viewer/`:

```text
flutter pub get
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze --fatal-infos
flutter test --reporter expanded
flutter build windows --release
```

From repository root, proposed orchestration:

```text
pwsh -NoProfile -File viewer/tool/verify-windows.ps1
pwsh -NoProfile -File viewer/tool/measure.ps1
pwsh -NoProfile -File viewer/tool/package.ps1
```

`verify-windows.ps1` builds the matching CLI, runs `flutter test integration_test/viewer_test.dart -d windows` from viewer with fixture paths supplied through `--dart-define` values, then exercises the packaged release through a Windows UI Automation harness. It must distinguish Flutter test-build evidence from packaged-release evidence. Exit nonzero on any missing integration prerequisite. `measure.ps1` implements section 10; `package.ps1` puts the full runner bundle and matching CLI in `target/viewer-release/`, writes hashes and checks launch from a path containing spaces and non-ASCII characters.

For Rust changes, required commands are `cargo fmt --check`, `cargo clippy --locked --all-targets`, `cargo test --locked`, `cargo build --release --locked` on Windows and native Ubuntu/WSL. Use separate Cargo targets. Run Linux tests against Linux-owned temporary data roots; use actual Windows/Linux binaries for delegation checks against a synthetic Windows-owned root. Follow existing repository verification procedures for WSL path translation and evidence capture. Do not treat a cross-compile as Linux runtime proof.

Create `viewer/verification-report.md` at implementation time with source commit, toolchains, commands, counts, failures/reruns, artifact SHA-256 hashes, V01..V13 results, manual NVDA observations, performance raw-log paths, real audio generation/listening evidence, startup verification and limitations. Mark each item planned/passed/failed/unavailable truthfully. An unavailable required manual test, startup proof or Bella asset-generation prerequisite means release acceptance is incomplete. Record no task bodies, clipboard contents or private live project data in shareable evidence.

## 12. Implementation slices

### Slice 1: Windows accessibility foundation

Deps: none. Touches Flutter scaffold, reusable virtual list, controls and focus tests.

Outcome: a synthetic 10,000-row prototype supports keyboard and NVDA selection beyond row 100, labelled text editing, an enum selector, modal restoration and a spoken status. Establish F1/F2/F3, the scoped command registry and visible Hotkey help button, full-monitor maximization, test-root injection and a fakeable announcement interface. This slice decides whether the chosen Flutter controls meet the actual Windows accessibility requirement before building the full UI. Real Bella asset generation belongs to slice 7; prototype audio is explicitly a test double.

Proof: from viewer run `flutter test test/accessibility_foundation_test.dart`; expect nonzero selected tests and all pass. Build and run Windows prototype with NVDA; execute design.md walkthrough A on synthetic data and record role/name/position, focus and speech evidence. A failed prototype must be corrected before collection UI implementation continues.

### Slice 2: Rust viewer query and update boundary

Deps: baseline contract in section 1; can proceed independently of slice 1. Touches `src/viewer.rs`, CLI dispatch, store queries and `tests/viewer_api.rs`.

Outcome: section 4 queries and section 7 atomic update endpoint pass V01..V04 API cases without changing legacy command behavior. New commands reuse ownership and read-only rules; no migration runs on read.

Proof: from root run `cargo test --locked --test viewer_api`; expect all named project/query/edit/conflict tests execute and pass against isolated stores, including malformed requests and real writer conflicts. Inspect SQL plans for page/aggregate queries and retain them. Record focused GREEN before broader certification.

### Slice 3: Data client and project browser

Deps: slices 1 and 2. Touches DTO/client, settings and project controller/UI.

Outcome: connection/setup, projects, all project stats/filter/sort states, paging and partial project failure work through the real CLI; V01, V02 and relevant V07 pass.

Proof: from viewer run `flutter test test/data test/projects`; expect client fault tests and project semantics tests pass. Use a synthetic multi-project store to verify UUID routing and stats against CLI JSON, including duplicate bindings and unavailable databases.

### Slice 4: Task browser and read views

Deps: slice 3. Touches task controller, detail/dependency/history/rules views.

Outcome: all combined task filters, sort orders, virtual jumps, stale query handling, complete body reading and back navigation work; V03 and read-only V07/V08 pass.

Proof: from viewer run `flutter test test/tasks test/details`; expect full-body and cross-page tests pass. Run NVDA walkthroughs A/B against real fixture data. Then run the single intermediate Flutter-wide batch defined in section 11.

### Slice 5: Editor, conflicts and recovery

Deps: slice 4. Touches edit controller/form, conflict dialog and local draft storage.

Outcome: all six fields and the Ctrl+D Mark done path save atomically with version checks; every leaving action preserves or deliberately discards the draft; V04/V05 and mutation cases in V11 pass.

Proof: from viewer run `flutter test test/editor test/recovery`; expect validation, navigation and conflict tests pass. Run real CLI second-writer and acknowledgement-loss integration cases with persisted history assertions. Execute NVDA walkthrough C before proceeding.

### Slice 6: Clipboard integration

Deps: slice 3 and shared dialogs from slice 1. Touches clipboard controller/preview and project toolbar.

Outcome: project-scoped direct enrichment by button/Ctrl+E and preview are usable and accurate; V06 and clipboard shortcut cases in V11 pass with existing Rust semantics.

Proof: from viewer run `flutter test test/clipboard`; expect scope capture, no-write preview and errors pass. Execute synthetic-text NVDA walkthrough D and controlled-desktop clipboard integration. Confirm no task mutation/event is caused by enrichment.

### Slice 7: Complete release workflow

Deps: slices 4, 5 and 6. Touches platform startup integration, real Bella asset generator/playback, integration harness, packaging, performance fixes, README and verification report.

Outcome: packaged application works without Flutter installed, supports the complete design.md workflow and satisfies V01..V13 and section 10. Implement default Windows startup/opt-out, single-instance activation, real generated Bella assets and offline playback. README documents launch/configuration, Hotkey help, startup behavior, announcement settings, draft location, statistics definitions and recovery. Performance fixes preserve all store and accessibility invariants. Keep platform integration, asset generation and performance fixes in separate coherent commits within this delivery slice.

Proof: use the final commands and evidence in section 11 once against the final source candidate. Exercise packaged-release startup, synthetic store edits and NVDA walkthroughs. Record every unmet target as failure; neither an executable file nor passing widget tests alone establishes completion.

Focused proof for slice 7: run `flutter test test/platform test/announcements test/hotkeys` from viewer and expect positive test counts/all pass with injected startup/audio services. From root run proposed `pwsh -NoProfile -File viewer/tool/generate-announcements.ps1 -VerifyOnly` to validate the catalog and bundled assets without network calls, then its explicit `-Generate` mode only in the authorized generation environment for missing clips. VerifyOnly must fail until every required real clip/provenance exists. Actual startup and playback proof are walkthrough F; test doubles do not satisfy it.

## 13. Risks, prerequisites and handoff

| Prerequisite/risk | Owner and completion check | Dependent work |
| --- | --- | --- |
| Flutter Windows build tools and Windows SDK | Implementer records `flutter doctor -v` and successful x64 build; install missing tools only within existing machine authority | Slices 1, 3..7 |
| Actual NVDA interactive session | Implementer/tester records NVDA version, speech and completed walkthroughs; inability to access it is a pending runtime gate | Slice 1 and final acceptance |
| ElevenLabs generation access and Bella identity | Implementer uses authorized API credential/account with Bella available, resolves exact voice identity and records generated/listened-to clips; never substitute another voice or claim clips exist before generation | Slice 7 / V13 |
| Disposable Windows startup test account | Implementer/tester verifies enable/disable across actual sign-in without signing out the user's account | Slice 7 / V12 |
| Cross-platform Rust checks | Implementer uses Ubuntu/WSL, Linux-owned fixture root and two real binaries | Slice 2 certification/final gate |
| Expensive project aggregation | Measure representative catalog; optimize aggregate SQL if targets fail, without adding a daemon or bypassing storage ownership | Slices 3, 7 |
| Project start provenance | UI always labels first recorded task; historical project creation is unavailable and excluded | Project statistics |
| NVDA consumes plain F4 in its default desktop layout (report current object) | Implementer records the key-delivery probe (F4 absent from the Flutter trace, F3 and Shift/Ctrl+F4 arriving, F4 also consumed in File Explorer) and reaches the editor through the Edit button during the walkthrough; an alternative in-app binding stays a slice-7 decision | Slice 5 walkthrough C, slice 7 |

Review: the author performed a bounded consistency review and a separate read-only contract reviewer checked the repository boundary. Corrections adopted: scoped timestamp/count extensions, count reuse within query tokens, explicit platform file identity, immediate locked-project error rows, presence-aware JSON parsing, explicit SQL sort expressions, catalog-page invalidation and honest clipboard race limits. No material review finding remains deferred. No implementation tests were run for this documentation change.

Execution handoff: canonical artifact is `viewer/spec.md`; readiness is Ready for implementation, with runtime prerequisites above. Build/test commands and proof schedule are in section 11; work packages are in [Implementation slices](#12-implementation-slices). Use project-local rust-engineering/rust-testing for Rust work, UX/accessibility guidance for Flutter controls and scoped Git operations for the required local milestone commits. No live backlog migration, push, publication or replacement of an in-use executable is authorized. Deferred features are exactly the exclusions in section 2.
