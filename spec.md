# Spec: shared local task backlog CLI

Status: implementation contract and verification basis, updated 2026-09-15.
The behavioral requirements below remain normative; implementation and
performance results are recorded separately in verification-report.md.

## Context and goals

Large TASKS.md files encourage unnecessary context loading and contend during
concurrent edits. Prior local measurements using the o200k_base tokenizer proxy
were 62,428 tokens for PFM and 54,062 for DelphiAiKit; median task bodies were
approximately 484 and 403 tokens. These are content measurements, not billing or
proven session savings. Prompt caching does not remove context occupancy.

Provide a local `tasks` executable that discovers one project backlog, lists
compact summaries, retrieves complete selected tasks, performs conflict-aware
updates, and retains recoverable history. A project has one backlog across all
branches and explicitly registered worktrees. Preserve Markdown descriptions,
acceptance criteria, proof notes and external references without interpretation.

Non-goals: network service, multi-machine sync, GUI, LLM calls, embeddings, arbitrary
SQL commands, agents with enforced filesystem isolation, Git branch task versions,
automatic code execution from task content, and automatic live-project migration.
The executable does not need an interpreter or separately installed SQLite at
runtime. Building bundled SQLite may require native build tools.

## Language and dependencies

Choose Rust: one Cargo package named `tasks-cli`, binary `tasks`, synchronous
execution. Rust has locally maintained engineering/testing skills, typed errors,
and a direct SQLite library. Go would also be suitable but adds a new guidance
ecosystem; Delphi fits Windows but makes the required native Linux target less direct.
This is a maintenance choice, not a claim that Rust queries outperform Go/Delphi.

Use `clap` derive for arguments, `rusqlite` with bundled SQLite and backup support,
`serde`/`serde_json` for contracts, a small typed error enum, and `tempfile` for
tests/owned temporary artifacts. UUID generation and SHA-256 for project/import
identity may use focused crates. Do not add an ORM, Tokio, SQLx, DI container or
workspace crates. Verify current versions/features/MSRV before selecting them;
pin the verified stable toolchain and commit Cargo.lock during implementation.

Primary API references, checked for this design:
- [rusqlite](https://docs.rs/rusqlite/latest/rusqlite/)
- [clap derive](https://docs.rs/clap/latest/clap/_derive/_tutorial/)
- [SQLite WAL](https://sqlite.org/wal.html)
- [SQLite online backup](https://sqlite.org/backup.html)

## Storage discovery and ownership

One database per project UUID, not per branch or directory basename:
`<data-root>/projects/<uuid>/TASKS.sqlite`. Windows default data root is
`%LOCALAPPDATA%/MaxLogic/tasks-cli`; an explicit absolute `--data-root` overrides
it and is required in tests. Linux default is `$XDG_DATA_HOME/MaxLogic/tasks-cli`
when XDG_DATA_HOME is absolute, otherwise `$HOME/.local/share/MaxLogic/tasks-cli`.
Store bindings in `<data-root>/registry.json` with a
format version and an array of canonical workspace roots and project UUIDs.

`tasks init --root <absolute-path>` creates a project and binding. `tasks bind
--root <absolute-path> --project <uuid>` associates another worktree with an
existing project. Neither requires Git nor modifies the project directory.
Initialization of an already bound root reports its existing identity, without
creating another database. Bind refuses to reassign an existing binding.

Commands accept global `--project <uuid>`; otherwise canonicalize the current
directory and choose the longest ancestor binding by path components, never
string prefix. Windows matching is case-insensitive and resolves existing links;
Linux matching is case-sensitive and resolves existing links.
Unknown roots fail with guidance, never create a database implicitly. Project
renames/moves require a new explicit binding. Print the selected project UUID in
results so incorrect routing is visible. Do not infer identity from Git remotes.

Registry modifications use one bounded exclusive file lock and atomic replacement
with a same-directory temporary file. Reads see either complete old or new JSON.
Use a proven cross-platform locking API/crate if std on the pinned toolchain is
insufficient. Never rewrite registry files for ordinary reads. Create/validate a
database before publishing its registry binding; interrupted init may leave an
unbound UUID directory, which must not be deleted automatically.

V1 runtime acceptance targets: Windows x64 (`x86_64-pc-windows-msvc`) and Linux x64
(`x86_64-unknown-linux-gnu`, tested on Ubuntu in WSL). Produce `tasks.exe` and
`tasks`; neither platform is optional. Build and test each on its native OS using
the same source and lockfile. Keep Cargo target directories separate when a
checkout is shared. Document the tested Ubuntu/glibc baseline; do not claim every
Linux distribution is supported from one successful build.

Each database has one OS owner. Native Linux accesses Linux-owned databases
directly. Native Linux processes must not open a Windows-owned database through
`/mnt/c`, `/mnt/f` or another mounted Windows filesystem. Do not mix SQLite VFS/OS
ownership, copy the backlog between OSes, or create a second backlog silently.

For convenient shared-backlog access, the Linux CLI supports explicit WSL
delegation: `tasks --windows-exe /mnt/c/path/tasks.exe --project UUID show T-323`.
The `--windows-exe` option, or its persistent environment equivalent
`TASKS_WINDOWS_EXE`, selects the Windows backend before local registry/database
access. Require an explicit project UUID for delegated project commands; support
`TASKS_PROJECT` as its default so routine WSL commands can remain short. When
neither is present, the Linux delegating CLI translates its current directory
with `wslpath -w` and passes that Windows path as hidden `--route-root` context
to `tasks.exe`; the Windows registry resolves the closest registered ancestor
using the normal longest-ancestor rule. If `TASKS_PROJECT` is present, the
delegating CLI forwards it as an explicit project argument so the Windows child
does not depend on cross-OS environment propagation. An explicit `--project`
takes precedence over `TASKS_PROJECT`, and both take precedence over directory
routing. An unknown translated directory fails without creating a database or
backlog. Explicit flags override environment values. These `TASKS_PROJECT` and
hidden `--route-root` routing defaults apply only to routed project commands.
Native and delegated `init`/`bind` never consume them; those commands follow
their own root-binding and project-creation contract. Reject delegation on
non-WSL Linux or from Windows, and do
not forward the delegation option to the child. Failure to start the configured
executable must fail, never fall back to a local store.

Use `std::process::Command`, never a shell command string. Preserve stdin,
stdout, stderr and child exit code. Convert filesystem-valued arguments (`--root`,
`--data-root`, `--body-file` except `-`, `--map-file`, `--file`, `--out`) with
`wslpath -w` as argument arrays; leave task text, IDs and search strings untouched.
Resolve relative paths in the Linux caller's cwd before conversion, including
not-yet-created output paths. For delegated data-root/root bindings, require
Windows-local paths; Linux UNC locations are not valid Windows database roots.
Input/output documents may use Windows-accessible converted paths; report access
errors without copying files behind the user's back. An omitted --data-root uses
the Windows child's default, not the Linux default. An explicit --data-root is
the caller-specified backend root after conversion. Delegated commands operate on
the Windows registry and the same UUID/database as native Windows commands.

Store
live databases on local disks, not UNC/network shares or cloud-synced folders.
Reject identifiable remote paths and document that redirected/cloud storage
cannot be reliably detected by path syntax alone.

## CLI and output contract

Global options: `--data-root`, `--project`, `--format text|json` (default text).
No interactive prompts or color in v1. UTF-8 output. Stdout contains results only;
stderr contains concise errors. JSON is one object with `schema_version: 1`,
`project_id` (null before selection), and command-specific data; errors contain
`error.code`, `error.message`, and optional structured conflict details. Text and
JSON have the same semantics. No timestamps or banners added merely for display.

| Command | Required behavior |
| --- | --- |
| `init --root PATH` | Create project and return UUID/database path; existing binding is a no-op |
| `bind --root PATH --project UUID` | Register another root without duplicating tasks |
| `list [--status STATUS] [--after N] [--limit N]` | Default nonterminal tasks; numeric ID order; default 20, max 100 |
| `show T-N` | Full task, version, project rules and direct dependency summaries |
| `search TEXT [--after N] [--limit N]` | Literal case-insensitive ASCII substring search of title/body; same paging as list |
| `create --title TEXT --body-file PATH` | Optional `--status`, default backlog; allocate next ID atomically |
| `update T-N --expect-version N ...` | At least one of title, body-file, status or full dependency replacement |
| `history T-N [--after N] [--limit N]` | Metadata only by default; `--event N` returns complete selected event |
| `rules show` / `rules set --body-file PATH --expect-version N` | Retrieve/update shared project Markdown rules |
| `import --file PATH [--apply --expect-sha256 HASH]` | Preview by default; explicit apply imports validated content atomically |
| `export --out PATH` | Deterministic readable Markdown snapshot; refuse existing destination |
| `backup --out PATH` | Consistent SQLite backup; refuse existing destination |
| `migrate` | Explicit schema upgrade, with verified pre-upgrade backup |
| `doctor` | Database path/UUID/schema/SQLite version, quick_check and foreign_key_check |

Define `update --deps T-1,T-2` as complete replacement; `--clear-deps` means empty,
and omission preserves dependencies. They are mutually exclusive. The same
optional dependency flags apply to create. Status values: backlog, ready,
in-progress, blocked, done, cancelled. All explicit status transitions are allowed;
done/cancelled are terminal for default lists. No hard-delete command in v1.

List/search rows contain only ID, status, version, title (display bounded to 120
Unicode characters), and dependency IDs. Include `has_more` and `next_after`; read
limit+1 rows, do not COUNT(*) on each request. `--after` is the numeric ID from the
last result. Pagination is a fresh snapshot per call, not a persistent snapshot;
concurrent edits can change later pages. History pages similarly use event IDs.
`show` never silently truncates body text. History full snapshots and export are
explicit bulk access, not default context. Dependency cycles and self-links fail.

`rules` contains shared verification/workflow requirements needed to interpret
tasks; do not make agents infer them from an obsolete TASKS.md. `show` includes
these rules, with version, by default. Repeated output should be deterministic
for unchanged data. Writes return only ID, status, new version and event ID.
Support `--body-file -` for UTF-8 stdin; never launch an editor or interpolate text
through a shell. Preserve input body whitespace/newlines. Reject invalid UTF-8,
empty titles and oversized input with no mutation (body limit 1 MiB; title 500
Unicode characters; shared rules 256 KiB). No secret redaction or telemetry.

Exit codes: 0 success (including empty lists), 2 usage/validation, 3 project/task
not found, 4 version conflict, 5 lock timeout/busy, 6 I/O/database/schema failure.
Errors name recovery actions; no stack traces unless explicitly requested later.
Mutations are committed before output. If stdout breaks after commit, do not roll
back or retry; a caller must inspect state before repeating a create operation.

## Data model and atomic changes

Use versioned SQL migrations, `PRAGMA user_version`, and explicit column lists.
Initialize metadata with database project UUID and check it against routing on
every open. Reads use existing-only read-only connections and do not migrate,
initialize or perform access-time writes. Unknown newer schemas fail closed.

Minimum tables:
- `project`: singleton UUID, rules Markdown, rules version, next task number.
- `tasks`: numeric primary key, title, body Markdown, constrained status, positive
  version, created/updated UTC timestamps stored consistently as integer millis.
  Render IDs as `T-<number>` with at least three digits; accept T-1 and T-001 as
  the same ID. Never reuse IDs; imports advance the counter past the maximum.
- `dependencies`: task_id, depends_on_id; composite primary key and foreign keys.
- `events`: monotonic event_id, optional task_id, entity type task/rules,
  operation, resulting entity version, timestamp, complete resulting snapshot JSON.
  Each create/update/rules change has exactly one event in its transaction.
- `imports`: input SHA-256 unique, source name, original source bytes, report JSON,
  import timestamp. Preserve the original source for recovery/provenance.

Add index `(status, id)` on tasks, reverse dependency index, and `(task_id,event_id)`
on events. Parameterize every value. Use a fixed whitelist for SQL choices, never
insert user-provided identifiers/order clauses. Substring search may scan bodies
in v1, but filters/projections/limits stay in SQL. Define ASCII case folding
explicitly; Unicode case-insensitive search and FTS are deferred until needed.

Writer connections use foreign_keys=ON, WAL, synchronous=FULL and a 5-second busy
timeout. Configure journal mode at initialization/migration, not on every read.
Keep default automatic checkpointing; no VACUUM/checkpoint or full integrity scan
per command. Readers may require SQLite sidecar access; do not promise zero
filesystem activity or use immutable=1 for a live WAL database.

Read/validate external files before `BEGIN IMMEDIATE`. Inside a short transaction,
read current version, reject mismatches, validate references/cycles, update via
`WHERE id=? AND version=?`, require exactly one affected row, increment version,
append history, then commit. A no-op update returns unchanged version with no event.
Do not print, sleep, invoke tools or wait for stdin inside a transaction. Conflict
returns expected/current version and leaves task/history unchanged. Busy waits
must be bounded; never add an unbounded retry loop. Different-task edits can both
succeed sequentially. Concurrent creates allocate distinct IDs in the transaction.

No task completion gate is inferred from Markdown. Shared rules and agents decide
whether proof suffices; the CLI enforces storage consistency, not engineering truth.

## Module boundaries

`main.rs` translates CLI errors to exit codes. `cli.rs` owns clap definitions;
`output.rs` renders typed results. `registry.rs` resolves paths/identity.
`store.rs` owns connections, queries and atomic operations; `migrations/` holds SQL.
`model.rs` contains task/status/result types. `markdown.rs` owns import/export.
`backup.rs` wraps the SQLite backup API. `interop.rs` validates and delegates WSL
calls before store discovery. Keep delegation separate from storage operations.
Use one library so integration tests can
exercise real operations. Split store.rs by responsibility only when it becomes
difficult to maintain; do not create a trait/layer for each query.

Data flow: parse arguments -> resolve project -> read bounded external input ->
validate -> perform one store operation -> close transaction -> render result.

## Migration, export and recovery

Initial importer supports the existing `### T-N ...` task layout with surrounding
`##` status sections. Use Markdown-aware heading recognition (including fenced
code handling), not a broad regex that mistakes code examples for task boundaries.
Preserve each task's content and capture original bytes. A leading UTF-8 BOM at
byte 0 is structural input: preview reports `has_bom: true`, while the original
bytes and source SHA-256 remain unchanged. Preview reports IDs,
titles, section/status mappings, duplicate IDs, ambiguous content and every
unassigned non-whitespace range. Provide an explicit mapping file option
`--map-file PATH` for section-to-status choices; do not guess ambiguous statuses.
The map is UTF-8 JSON `{"sections":{"In Progress":"in-progress","Next - Today":"ready"}}`;
keys are exact level-two heading text, values are the six supported statuses.
Every section containing tasks needs an explicit mapping, except exact headings
equal to a canonical status. Preview may suggest mappings but apply never accepts
an unconfirmed suggestion. Unknown keys/values and conflicting mappings fail.
Store shared non-task rules in project rules in source order, retain original
sections in import provenance, and expose the proposed rules in the preview.
Do not infer dependencies from arbitrary T-N mentions; keep prose references.

The canonical export metadata block is ordered `Status:`, `Version:`,
`Depends on:`, `Body:`; an optional `Title:` may precede it for compatible
inputs. The importer consumes metadata only when that ordered block is present.
For compatibility it also accepts the older ordered `Status:`, `Depends on:`,
`Body:` form and an exact standalone `Body:` marker. `Body:` is a hard
boundary and all following source text belongs to the task body. A
metadata-like first body line is preserved when it is not an ordered metadata
form, and preview lists the consumed metadata fields. A task before the first
`##` heading is reported under the pseudo-section `<no section>` and blocks
apply unless that exact pseudo-section is explicitly mapped.

`import --source-schema canonical` (the default) keeps that metadata contract
unchanged. `--source-schema create-task` additionally recognizes the
create-task ledger block: within a task block, the first line whose text begins
at column zero with `Deps:` (fenced code excluded) is parsed with the same
comma-separated `T-` ID syntax and the `-`/`none` empty forms; extracted IDs are
recorded as task dependencies and listed per task in the preview (each task
preview carries `deps`, and `consumed_metadata` gains `Deps`). Extraction is
additive: the `Deps:` line and every other source byte stay in the stored body
unchanged, nothing is consumed, and non-task prerequisite text remains
descriptive. The default schema, preview semantics and export round-trip are
unchanged.

Each actual schema migration creates and validates a fresh pre-upgrade backup
named `TASKS.v<from>-pre-migrate-<unix-millis>-<pid>-<counter>.sqlite`; older
pre-migration backups are retained, and migrate output reports the new path.
If the database is already current, no backup is created and the reported path
is null. Apply only to a project with no tasks and no nonempty rules. Validate every byte
range is assigned to a task, shared rules or documented structural markup; unknown
content blocks apply. Re-read/check the expected source hash before applying.
The whole import, initial events, rules and provenance commit together. A repeated
identical import reports already imported without mutation. Duplicate IDs or
partial parsing roll everything back. Never edit/remove the source TASKS.md.
Importer compatibility with actual PFM/DelphiAiKit copies is an acceptance gate,
not permission to switch those projects to SQLite.

Export contains a snapshot warning, project UUID, shared rules, all tasks ordered
by ID, status, version, dependency IDs and complete bodies. It is human-readable,
not a live authority or full-fidelity database backup. No generated-at timestamp
in deterministic export content. Exact native recovery uses database backups.

Use SQLite online backup, not copying only TASKS.sqlite while WAL is active.
Write an exclusively created temporary backup next to the requested destination,
validate integrity/foreign keys/project UUID, then publish without overwriting.
On failure retain actionable diagnostics and never claim a usable backup. Do not
hold a write transaction while backing up. Schema upgrades require a successful
backup before an atomic migration and must recheck schema under the migration
lock. Test upgrade failure rollback. Automatic backup retention/deletion is deferred.

V1 recovery procedure: stop task clients, preserve the whole damaged store directory
for diagnosis, validate a backup at a new isolated data root, then explicitly bind
the restored UUID there. No in-place destructive restore command. Back up registry
bindings separately or recreate them with bind after restoring the UUID directory.

## Performance and output targets

Targets, not measurements: on the development Windows SSD, release binary,
10,000 tasks averaging 2 KiB body and 50,000 events, run 5 warmups + 50 measured
fresh-process invocations. Record toolchain, SQLite version, hardware, fixture
sizes, exit codes and p50/p95 end-to-end timings. Report first-run timing separately.
Aim for p95 <=100 ms for show/list, <=250 ms for substring search and <=150 ms for
an uncontended update. Contention tests verify bounded completion, not these limits.
Repeat the matrix on native Linux with a Linux-owned temporary store. Measure
WSL-to-Windows delegation separately, including process/interop startup, and report
its overhead rather than applying native timing targets to it. These are diagnostic
targets, not timing assertions in normal CI.

List default output <=6 KiB for fixture titles/dependencies; one typical show
should include only that task, shared rules and direct dependency summaries.
Measure output bytes; only claim token counts when a named tokenizer was used.
Record peak process memory for show/list; investigate >64 MiB. Export/backup may
scale with data size, but stream where practical. Never read all bodies/history
for list. Use EXPLAIN QUERY PLAN to verify ID/status/history access paths; do not
add FTS/caching or change durability merely to meet targets. Bound dependency
count to 100 per task; reject oversized replacement rather than truncate it.

## Verification and implementation slices

Task tier: focused tests for the current slice with real isolated databases;
record meaningful RED/GREEN and selected counts. Batch tier: one cargo test run
after transactional commands (slice 3). Final tier after slice 6: fmt, clippy,
full tests, release build and one performance matrix on each platform. Two broad
test gates per platform total,
expected low cost for temporary-local tests; performance gate is separate and
measured. Review storage/import/backup invariants after focused GREEN and before
final broad checks. No full unrelated project builds required.

Use tests with independently asserted database rows/output, not only round trips.
Cover Unicode, CRLF, quoted paths, missing data root, wrong UUID, newer schema,
invalid status, no-op updates, version conflicts, dependencies, bounded paging,
stderr/exit behavior, import ambiguity and backup restoration. Real subprocess
races must prove exactly one winner for same-version edits and unique create IDs.
Use explicit synchronization, not sleeps, for deterministic contention tests.
Inject a test-only precommit failure at the library boundary to prove rollback;
also terminate a child holding an uncommitted transaction and reopen/verify state.

1. **Scaffold and project routing.** Outcome: Cargo package, pinned toolchain,
   registry/init/bind work across two roots with one UUID; unknown roots fail.
   Proof: `cargo test --test routing` passes routing, lock and interrupted-init
   cases using explicit temporary roots. `tasks --help` documents stable syntax.
2. **Schema and selective reads.** Outcome: migrations, rules/show/list/search,
   typed output and exit codes. Proof: `cargo test --test reads` verifies fixtures,
   no implicit database creation/migration, paging and no task-body leakage in list.
3. **Transactional writes and history.** Outcome: create/update/rules and dependency
   checks obey atomic/version semantics. Proof: `cargo test --test mutations`
   verifies row/event invariants, concurrent processes, timeout and crash rollback.
4. **Markdown import/export.** Outcome: preview/apply and deterministic export
   preserve task content and shared rules. Proof: `cargo test --test markdown`
   rejects duplicate/ambiguous/fenced-heading cases and checks independent expected
   content. Locally trial copies of PFM/DelphiAiKit ledgers; keep private contents
   outside committed fixtures and report counts/hash/content coverage.
5. **Backup and migration recovery.** Outcome: consistent backups during writes,
   explicit schema upgrade and documented recovery. Proof: `cargo test --test
   recovery` reopens backups and verifies committed task/event pairs, failure
   rollback, no overwrite and newer-schema rejection.
6. **Dual-platform packaging and WSL access.** Outcome: native Windows and Linux
   release executables, explicit delegation, command examples and repeatable
   benchmark harness. Proof: build/test Windows natively and Linux inside Ubuntu;
   exercise native Linux CRUD/backup on a Linux-owned temporary store. Run
   `cargo test --test interop` for argument/path/error contracts. Then exercise
   real Linux-to-Windows delegation with spaces, Unicode, stdin bodies, relative
   output paths and nonzero exit codes. Write a task via Linux delegation and read
   its identical UUID/version from Windows; race a Windows update against a
   delegated update to prove one winner for the same expected version. Verify no
   Linux database was created. Test unset/broken interop with no fallback. Record
   the native/delegated performance matrix and full-ledger versus selective output.

The named integration targets and additional regression targets are implemented
in this repository. Their current counts, exact commands, artifacts and
remaining platform limits are recorded in verification-report.md; this report
does not weaken any contract when a platform check is unavailable.

## Risks, review disposition and handoff

Local challenge pass resolved: basename-based identity replaced with UUID and
explicit binding; mixed Windows/WSL database access excluded; historical Markdown
ambiguity blocks import; rules are returned with tasks; backup uses SQLite API;
concurrent updates require versions. No live migration is included in this work.

Deferred: additional Linux distributions/architectures, network sync, claims/leases for agent task
ownership, Unicode search folding, automatic backup retention, hard deletion and
import into a nonempty backlog. Version checks prevent lost updates but do not
prevent two agents doing duplicate engineering work; task claiming is a later
workflow decision. The verified v1 implementation is limited to the documented
Windows x64 and Ubuntu/WSL Linux x64 scope; current evidence and remaining
platform limitations are recorded in verification-report.md.

Execution prerequisites: verify the selected Rust/MSVC build toolchain, dependency
features and bundled SQLite version; use a supported SQLite patch release with
applicable WAL fixes. Collect real migration samples as private test inputs only.

Canonical artifact: `spec.md`. Implementation and verification state belongs in
verification-report.md, not in this behavioral contract. Build:
`cargo build --release --locked`; tests: `cargo test --locked`.
Do not recreate the full backlog in AGENTS.md, a second spec, or CLI help text.
