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

A project may contain `.tasks.json` with exactly one field,
`{"project_id":"<canonical-lowercase-uuid>"}`. For routed commands, resolution
precedence is explicit `--project`, `TASKS_PROJECT`, the nearest `.tasks.json`
from the current or delegated route directory, then the longest registry
ancestor binding. The identity file is portable project configuration and never
contains a database path. Reject an invalid nearer identity instead of skipping
it. A valid identity selects only an existing database; it never initializes a
project implicitly. `bind` and `bulk-import` do not consume directory identity
as an implicit creation argument. `init` creates or verifies the exact root
identity as part of explicit project setup. Require an ordinary, non-link file no
larger than 4 KiB so identity lookup stays bounded and cannot redirect to an
unrelated configuration file. `init` creates this file at the exact root when
it is absent. It accepts an existing
matching identity and refuses malformed or conflicting content without
overwriting it. When `--project` is omitted, a valid identity already at the
exact root supplies the UUID for this explicit initialization operation.

`tasks init --root <absolute-path>` creates a project, binding and portable
identity. `tasks bind
--root <absolute-path> --project <uuid>` associates another worktree with an
existing project. Neither requires Git nor modifies the project directory.
Initialization of an already bound root reports its existing identity, without
creating another database. Bind refuses to reassign an existing binding.

Commands accept global `--project <uuid>`; otherwise inspect directory identity,
then canonicalize the current directory and choose the longest ancestor binding
by path components, never string prefix. Windows matching is case-insensitive
and resolves existing links; Linux matching is case-sensitive and resolves
existing links.
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
access. Support `TASKS_PROJECT` as an explicit default so routine WSL commands
can remain short. When neither it nor `--project` is present, the Linux
delegating CLI translates its current directory with `wslpath -w` and passes
that Windows path as hidden `--route-root` context to `tasks.exe`; the Windows
child resolves the nearest `.tasks.json`, then the closest registered ancestor.
If `TASKS_PROJECT` is present, the
delegating CLI forwards it as an explicit project argument so the Windows child
does not depend on cross-OS environment propagation. An explicit `--project`
takes precedence over `TASKS_PROJECT`, and both take precedence over directory
identity and registry routing. An unknown translated directory fails without creating a database or
backlog. Explicit flags override environment values. These `TASKS_PROJECT` and
hidden `--route-root` routing defaults apply only to routed project commands.
Native and delegated `init`/`bind` never consume them and follow their own
root-binding and project-creation contract; `bulk-import` also takes no injected
routing default and follows its own multi-project contract. Reject delegation on
non-WSL Linux or from Windows, and do
not forward the delegation option to the child. Failure to start the configured
executable must fail, never fall back to a local store.

Use `std::process::Command`, never a shell command string. Preserve stdin,
stdout, stderr and child exit code. Convert filesystem-valued arguments (`--root`,
`--data-root`, `--body-file` except `-`, `--map-file`, `--file`, `--out`,
`--scan-root`, `--report-dir`, `--quarantine-dir`) with
`wslpath -w` as argument arrays; leave task text, IDs and search strings untouched.
Stop option processing at `--`; consume option values as values even when they
resemble flags. Only actual delegation options are removed from the child argv.
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
On Linux inspect the owning mount in `/proc/self/mountinfo`, including custom
DrvFs mountpoints and canonicalized existing ancestors of new paths. Reject
identifiable remote paths and document that redirected/cloud storage
cannot be reliably detected by path syntax alone.

## CLI and output contract

Normalize accepted project UUID spellings to lowercase hyphenated form before
resolving database paths or storing bindings.

Global options: `--data-root`, `--project`, `--format text|json` (default text).
No interactive prompts or color in v1. UTF-8 output. Stdout contains results only;
stderr contains concise errors. JSON is one object with `schema_version: 1`,
`project_id` (null before selection), and command-specific data; errors contain
`error.code`, `error.message`, and optional structured conflict details. Text and
JSON have the same semantics. No timestamps or banners added merely for display.

| Command | Required behavior |
| --- | --- |
| `init --root PATH` | Create project, binding and exact root identity; accept a matching identity unchanged and refuse malformed or conflicting files without overwriting them |
| `bind --root PATH --project UUID` | Validate database/schema/embedded UUID, then register another root without duplicating tasks |
| `list [--open | --needs-human] [--status STATUS] [--label LABEL] [--after CURSOR] [--limit N]` | Default runnable todo/in-progress; priority then ID; default 20, max 100 |
| `unlocks [--offset N] [--limit N]` | Open prerequisites ranked by immediately runnable then direct open dependents |
| `enrich [--file PATH]` | Enrich UTF-8 text task references; stdin by default, exact text to stdout |
| `enrich-clipboard` | Enrich clipboard text and replace it after checking the original still matches |
| `show T-N` | Full task, version, project rules and direct dependency summaries |
| `search TEXT [--label LABEL] [--after N] [--limit N]` | Literal case-insensitive ASCII substring search of title/body; numeric ID cursor, same page limits |
| `create --title TEXT --body-file PATH` | Optional `--status`, default draft; `--priority P0..P3`, default P2; allocate next ID atomically |
| `update T-N --expect-version N ...` | At least one of title, body-file, status, priority, labels or full dependency replacement |
| `history T-N [--after N] [--limit N]` | Metadata only by default; `--event N` returns complete selected event |
| `rules show` / `rules set --body-file PATH --expect-version N` | Retrieve/update shared project Markdown rules |
| `import --file PATH... [--apply --expect-sha256 HASH]... [--map-file PATH] [--source-schema NAME]` | Preview by default; one apply can commit several sources into the same empty project |
| `bulk-import --scan-root PATH --map-file FILE --report-dir DIR [--exclude GLOB]... [--apply] [--allow-partial] [--quarantine-dir DIR] [--delete-quarantined] [--source-schema NAME]` | Dry-run corpus migration: scan, group, classify and preview Markdown ledgers; only `--apply` initializes projects, imports and verifies; apply is all-or-nothing unless `--allow-partial` is passed; only `--quarantine-dir` moves sources |
| `export --out PATH` | Deterministic readable Markdown snapshot; refuse existing destination |
| `backup --out PATH` | Consistent SQLite backup; refuse existing destination |
| `migrate` | Explicit schema upgrade, with verified pre-upgrade backup |
| `doctor` | Database path/UUID/schema/SQLite version, quick_check and foreign_key_check |

Define `update --deps T-1,T-2` as complete replacement; `--clear-deps` means empty,
and omission preserves dependencies. They are mutually exclusive. The same
optional dependency flags apply to create. Status values: draft, todo,
in-progress, blocked, done, cancelled. All explicit status transitions are allowed;
done/cancelled are terminal. Default lists additionally require readiness. No hard-delete command in v1.

Schema 2 stores and emits canonical `draft` and `todo` names. Explicit migration
from schema 1 changes `backlog` to `draft` and `ready` to `todo` atomically after
a validated fresh backup. It preserves task IDs, versions, timestamps, rules,
dependencies, import provenance and existing event snapshot bytes. Schema 0
upgrades through schema 1 in the same transaction. Older Markdown headings,
metadata and section maps may still use `backlog`/`ready` as import aliases;
new CLI values, output and exports use the canonical names.

Schema 3 adds `task_labels(task_id,label)` with a composite primary key, task
foreign key and `(label,task_id)` index, plus external-content FTS5 `tasks_fts`
on title/body using unicode61 and prefix indexes for lengths 2 and 3. Insert,
delete and changed-title/body triggers keep the index in the task transaction.
Migration rebuilds the index from existing content without rewriting events.
Upgrades from schemas 0, 1 and 2 remain explicit, backed up and atomic.

Create/update accept `--labels LABEL,...`; update omission preserves the set,
`--labels` replaces it and mutually exclusive `--clear-labels` empties it.
Normalize by trimming, ASCII lowercasing, sorting and deduplicating; allow at
most 32 labels of 1–64 ASCII letters, digits or `-_.:`. Labels appear in show,
summary rows, history snapshots, import previews and optional canonical metadata.
Exact normalized `--label` filtering is available for list and both search modes.
No reserved-label behavior is enforced by the CLI.

`search TEXT --ranked [--prefix] [--label LABEL] [--offset N] [--limit N]`
uses FTS5 BM25, title weight 10/body weight 1, then numeric ID to break ties.
Query input is 1–64 whitespace-separated terms and at most 4096 UTF-8 bytes;
each term is quoted with embedded quotes escaped, joined with AND. Prefix mode
adds a suffix wildcard outside each quoted term; raw FTS operators are never
accepted. Punctuation follows unicode61 tokenization. No fuzzy/semantic service
or new dependency is required. Ranked JSON has command `search_ranked`,
`items`, `has_more`, `next_offset`. The default/max limits remain 20/100;
read limit+1 in SQL. `--after` conflicts with `--ranked`; `--prefix` and
`--offset` require `--ranked`. Offset must fit SQLite's signed integer range.
Search includes terminal states. Pages may shift after concurrent edits;
no cross-command snapshot is promised.

Schema 4 adds task `priority`, constrained to P0, P1, P2 or P3 (default P2),
with priority/ID and status/priority/ID indexes. It participates in the same
optimistic version check, no-op detection, event snapshot, import and export as
other task fields. Old snapshots are unchanged. Explicit backed-up migration
from schemas 0–3 supplies P2 without changing task versions or other records.

Default list selects only todo/in-progress tasks without `needs-human`, and all
prerequisites must be done. Cancelled prerequisites remain unsatisfied. `--open`
selects every nonterminal task. `--needs-human` selects nonterminal tasks with
that label. These flags conflict; explicit `--status` bypasses default readiness,
while `--needs-human` still restricts to its nonterminal decision queue. Optional
`--label` intersects the selected scope. No query changes task state.

List order is priority then numeric ID. JSON `next_after` is a string such as
`P2:T-123`; pass it unchanged to `--after`. Numeric list cursors are no longer
accepted. Search/history keep their original cursor types. Priority changes
between requests may move tasks; only a single request is snapshot-consistent.
The older library `list_tasks` wrappers retain ID-paged open semantics; CLI
selection uses `select_tasks`.

`unlocks` returns bounded summary rows with `direct_open_dependents` and
`immediately_runnable`. Include only nonterminal prerequisites and nonterminal
dependents. A dependent is immediately runnable when todo/in-progress, without
needs-human, and every other prerequisite is done. Count distinct dependency
edges enforced by the composite key. Order by immediately runnable descending,
direct count descending, priority then ID. Use `next_offset`/`--offset`, limits
20/default and 100/max. This is direct impact, not transitive scoring or an
authorization to close the prerequisite.

Enrichment recognizes standalone uppercase T001 and T-001 spellings, preserving
the original ID text. Append ` (current task title)` after every known reference,
including terminal tasks, without inserting task bodies. Unknown IDs are left
unchanged and reported on stderr (and `unknown_ids` in JSON). Invalid/out-of-range
numbers remain untouched. Exact existing annotations are skipped, including IDs
inside that annotation; arbitrary pre-existing prose is not deduplicated. Obvious
URL/path components are skipped, but this is a plain-text transform, not a
Markdown/code parser. Code blocks and link labels may therefore be enriched.
Read requested ID/title pairs in batches under one read snapshot; release it
before rendering. Limit input to 16 MiB, distinct valid IDs to 10,000 and output
to 64 MiB; fail instead of truncating. Preserve Unicode, line endings and trailing
newlines; `--file` never overwrites the input. Text output adds no banner. JSON
uses command `enrich` with text, replacements, unknown_ids and clipboard.

Clipboard support uses Windows PowerShell STA/System.Windows.Forms on Windows
and WSL; native Linux uses wl-clipboard for Wayland or xclip for X11. Missing
helpers/display/non-text input fail clearly. Use static command scripts and
stdin data, never interpolate task text into shell code. Before replacing, check
that clipboard text still equals the input; this is best-effort conflict detection,
not atomic compare-and-swap. No-op enrichment does not rewrite the clipboard.
Successful replacement publishes plain text, replacing other clipboard formats.
WSL delegation runs this command wholly through tasks.exe for Windows-owned stores.

List/search rows contain only ID, status, version, title (display bounded to 120
Unicode characters), priority, dependency IDs and normalized labels. Include `has_more` and `next_after`; read
limit+1 rows, do not COUNT(*) on each request. For plain search, `--after` is the numeric ID from the
last result. Pagination is a fresh snapshot per call, not a persistent snapshot;
concurrent edits can change later pages. Each list, search, show and export call
reads its task rows, dependencies and rules within one deferred read transaction.
In WAL mode, writers can commit while that read retains its original snapshot.
Release the read transaction before rendering or publishing an export. History
pages similarly use event IDs.
`show` never silently truncates body text. History full snapshots and export are
explicit bulk access, not default context. Dependency cycles and self-links fail.
Create, update and import enforce the same dependency-list limit: at most 1000
IDs per task.

`rules` contains shared verification/workflow requirements needed to interpret
tasks; do not make agents infer them from an obsolete TASKS.md. `show` includes
these rules, with version, by default. Repeated output should be deterministic
for unchanged data. Writes return only ID, status, new version and event ID.
Support `--body-file -` for UTF-8 stdin; never launch an editor or interpolate text
through a shell. Preserve input body whitespace/newlines. Reject invalid UTF-8,
empty titles and oversized input with no mutation (body limit 1 MiB; title 500
Unicode characters; shared rules 256 KiB; dependency list 1000 IDs per task).
No secret redaction or telemetry.

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
explicitly. Ranked search uses FTS5 unicode61 tokenization and its case folding;
plain substring matching remains ASCII case-insensitive.

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
The map may also cover an open-ended section space with an optional
`default_status` and an optional ordered `section_patterns` list of
`{"pattern": REGEX, "status": STATUS}` objects, written as
`{"sections": {...}, "default_status": "backlog", "section_patterns": [...]}`.
Resolution order for a section heading is: literal `sections` entry, then the
first matching pattern in list order, then an exact canonical status name, then
`default_status`. Patterns are regular expressions tested against the section
heading text (unanchored `is_match` semantics; anchor with `^`/`$` when needed).
An invalid pattern, an unknown status or an unknown key fails at map load with
exit 2. A section that holds tasks and is resolved only by `default_status` is a
section name the map did not anticipate: the status is still assigned, but the
importer records a warning naming the file, the section heading and the assigned
status, and `bulk-import` classifies that candidate `recognized-with-warnings`
instead of `recognized`. A section holding no task headings never needs a
mapping, so prose sections such as `## Summary` do not require entries and stay
silent when `default_status` resolves them. The bare
`{section: status}` form remains valid, and every existing rule and error -
including mappings that conflict with a canonical section's own status - stays
in force. `bulk-import` applies one map to a whole corpus, so a literal entry
that a given file does not contain is ignored there instead of failing (see
Bulk migration); the single-file `import` keeps the strict unknown-section error.
Store shared non-task rules in project rules in source order, retain original
sections in import provenance, and expose the proposed rules in the preview.
Do not infer dependencies from arbitrary T-N mentions; keep prose references.

The canonical export metadata block is ordered `Status:`, `Version:`,
`Depends on:`, optional `Labels:`, optional `Priority:`, `Body:`; an optional `Title:` may precede it for compatible
inputs. The importer consumes metadata only when that ordered block is present.
For compatibility it also accepts the older ordered `Status:`, `Depends on:`,
`Body:` form and an exact standalone `Body:` marker. `Body:` is a hard
boundary and all following source text belongs to the task body. A
metadata-like first body line is preserved when it is not an ordered metadata
form, and preview lists the consumed metadata fields. A task before the first
`##` heading is reported under the pseudo-section `<no section>` and blocks
apply unless that exact pseudo-section is explicitly mapped. `default_status`
and `section_patterns` never resolve `<no section>`; a literal map entry is
required for that pseudo-section.

Canonical exports also contain the exact standalone marker `Task schema: 1` in
their header, before the first section or task and outside fenced or framed
content. The parser recognizes the marker only in that position; matching text
inside a fence, task body, rules body or other protected content is ordinary
content.
The shared rules body and every task body are framed by readable comments of
the form `<!-- tasks-cli:canonical-v1:{body|rules} bytes=N sha256=HEX -->`
and a matching end comment. `N` is the UTF-8 byte length of the raw body and
`HEX` is its SHA-256. A frame is recognized only immediately after `Body:` or
at the start of a `Rules`/`Shared Rules` section. Its end marker must start at
the exact byte offset after the body, with only an optional LF or CRLF
separator, and its length and hash must match. Corrupt, truncated, misplaced,
or mixed framed/unframed content is a blocking problem; the parser does not
fall back to heading discovery inside the advertised frame. Multiple rules
frames are concatenated in source order with one LF separator when needed.
Legacy files without the exact schema marker retain the existing heading and
metadata compatibility behavior.

`import --source-schema canonical` (the default) keeps that metadata contract
unchanged. `--source-schema create-task` additionally recognizes the
create-task ledger block: every line whose text begins at column zero with
`Deps:` inside a task block (fenced code excluded) is a Deps field, and a second
one in the same task is nonconforming. The value grammar is exactly create-task
3.4.0: the value is trimmed; an empty value, `-` or `none` in any case carries
no dependencies; otherwise it is split on `,` and every trimmed item must match
`^T-\d+$` exactly. Backticks, semicolons, words, ranges and project names do not
match. An ID-only line creates an edge only for IDs present in the same
candidate file set - the file itself for a single `import`, every file of the
project for `bulk-import` - and a self-reference is a problem, never an edge.
Nonconforming lines never create edges and never silently drop text: the line
makes the candidate `unrecognized` and is reported with the file, the line
number, the task ID, the original value verbatim, the IDs a clean line would
keep (standalone items after splitting on `,` and `;` and stripping backticks,
that exist in the candidate's files) and the fix text `keep only these IDs in
Deps and move the rest of the original text to Notes`. A conforming line that
names an ID absent from the candidate's files is equally blocking, reported with
the fix text `remove T-### from Deps; no such task exists`. Extraction stays
additive: the `Deps:` line and other task content remain in the stored body;
non-task prerequisite text stays descriptive. Import may normalize structural
separators and boundary whitespace; exact Markdown formatting is not required.
The original source bytes remain available in import provenance. Each task preview still carries `deps` (the resolved edges), and
`consumed_metadata` still gains `Deps` when the line exists. The default schema,
preview semantics and export round-trip are unchanged.

Every preview reports all of its problems in one run and never stops at the
first: nonconforming `Deps:` lines, unknown IDs, self-references, unmapped
task-bearing sections, unassigned content ranges, duplicate IDs, dependency
lists that exceed 1000 IDs or repeat an entry, and dependency cycle groups. The
report starts with the count line `N problem(s): X
nonconforming Deps, Y unknown IDs, Z cycle groups, W other`, and the same list
is carried as a structured array in `run.jsonl` and as lines in `summary.md` and
`unrecognized.md`. Cycles come from strongly connected components: every group
of two or more tasks reports one concrete cycle, the file and line of each edge
in it with its `Deps:` text, and every task of the group. A candidate holding
any problem is `unrecognized` and is never applied or quarantined; the
single-file `import` command reports all problems the same way and refuses
`--apply` with the same list.

Preview is not a weaker check than apply. It runs every data check apply
performs before its transaction, through the same functions: the dependency
count and duplicate-entry checks, the title, body and combined shared-rules
size limits, dependency existence, self-references, in-file and cross-file
task-ID uniqueness and dependency cycles, plus the store preconditions (an
empty store, empty shared rules, and a source set already recorded in the
project's provenance). Each violation is reported in the all-problems format
with the file, the line and the task where one applies. A source set that
passes a dry run cannot fail `--apply` for a data reason; a set whose sources
were all imported in an earlier run reports that state instead of failing. The
single-file `import` preview reports the same store-state problems, naming the
project UUID and the existing task or rules count.

Create-task ledgers may also carry `Archived from TASKS.md.` and
`Task schema: 1` header lines. Both are recognized as structural markup
alongside `Project:`, `Next task ID:` and `> Snapshot export` lines, so they do
not block apply. That list is exhaustive: any other unassigned non-whitespace
content still blocks apply, which is what catches a ledger schema this tool does
not understand.

A ledger is recognized by its content, never by the marker. Each parsed ledger
file is classified `schema-1` when the exact standalone `Task schema: 1` line
is present,
`legacy-compatible` when there is no marker but every task heading sits under a
section the map or the canonical names resolve, and `unsupported` when a task
heading sits before the first section or under a section nothing resolves. A
missing marker alone never makes a candidate unrecognized, and missing empty
sections do not matter to the class. The class of every file is recorded in
`run.jsonl` and `summary.md`.

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

`import` accepts `--file` more than once, preserving the given order, with
exactly one `--expect-sha256` per file in the same order. The preview reports
each file separately. Apply re-reads and re-hashes every source, checks the
empty-store precondition once, requires IDs to be unique across the whole set
(forward and cross-file dependencies are allowed), and commits all tasks,
dependencies, initial events, rules and provenance rows in one transaction.
Each source records its own bytes and SHA-256 in provenance; shared rules are
concatenated in file order. A repeated identical apply reports already
imported; a set mixing already-imported sources with new ones is refused. An
incoming source set must also contain each SHA-256 at most once, even when two
filenames have identical bytes; preview names both files and apply refuses the
set before opening the write transaction.

Publish the complete export without overwriting an existing or concurrently
created destination. The current same-directory hard-link publication requires
a filesystem supporting hard links; unsupported destinations return an error.
Backup publication refuses an existing destination or destination `-wal`/`-shm`
sidecar and rechecks those sidecars immediately before publication, preserving
any pre-existing sidecar bytes.

Export contains a snapshot warning, project UUID, shared rules, all tasks ordered
by ID, status, version, dependency IDs and complete bodies. It is human-readable,
not a live authority or full-fidelity database backup. No generated-at timestamp
in deterministic export content. Exact native recovery uses database backups.

Use SQLite online backup, not copying only TASKS.sqlite while WAL is active.
Write an exclusively created temporary backup next to the requested destination,
validate integrity/foreign keys/project UUID, then publish without overwriting.
Only temporary sidecars created beside that temporary file are removed.
On failure retain actionable diagnostics and never claim a usable backup. Do not
hold a write transaction while backing up. Schema upgrades require a successful
backup before an atomic migration and must recheck schema under the migration
lock. Test upgrade failure rollback. Automatic backup retention/deletion is deferred.

V1 recovery procedure: stop task clients, preserve the whole damaged store directory
for diagnosis, validate a backup at a new isolated data root, then explicitly bind
the restored UUID there. The restored layout is exactly
`<isolated-root>/projects/<UUID>/TASKS.sqlite`; create that directory and copy the
backup there before running `doctor`, then run `bind --root <worktree> --project
<UUID>` with the isolated `--data-root`. Do not run `init` for this layout because
it creates a new project identity. No in-place destructive restore command. Back up
registry bindings separately or recreate them with bind after restoring the UUID
directory.

## Bulk migration

`tasks bulk-import --scan-root PATH --map-file FILE --report-dir DIR
[--exclude GLOB]... [--apply] [--allow-partial] [--quarantine-dir DIR]
[--delete-quarantined] [--source-schema NAME]` migrates a tree of Markdown ledgers into one project per
ledger directory. Dry run is the default and writes nothing anywhere except the
report directory; apply requires the explicit flag. The whole run refuses to
start when `--report-dir` is not writable.

Stages, in order:
1. Scan `--scan-root` for `TASKS.md` and `TASKS.ARCHIVE.md`. Prune `.git`,
   `target`, `node_modules`, `3rdParty` and every `--exclude` glob. Never follow
   symlinks or reparse points out of the scan root. A discovered path is data,
   never an argument: a directory named `--maxTdb` is handled as a path.
2. Group: one candidate project per directory holding a ledger. A nested ledger
   is its own candidate and is never merged into an ancestor.
3. Classify each candidate into exactly one bucket: recognized,
   recognized-with-warnings, unrecognized, or excluded. Unrecognized means the
   preview cannot assign a status to a section that holds tasks, or the files
   parse with an error; the recorded reason names the file, the section or line,
   and what was expected. A candidate is also unrecognized when a `Deps:` line
   is nonconforming, names an unknown ID or self-reference, or when its
   dependency graph holds a cycle; all of those problems are recorded in one
   pass, never just the first.
4. Preview every recognized candidate through the import preview.
5. Apply, only with `--apply`. Preflight is all-or-nothing by default: the complete
   dry-run validation for every candidate runs first, and when any candidate
   is unrecognized or holds any problem the run writes nothing - no registry
   change, no project directory, no database, no quarantine - exits 2 and
   prints the full problem list. `--allow-partial` applies only the clean
   candidates instead and reports the rest as unmigrated. For each applied
   candidate the run creates or validates the project database, imports all of
   its ledger files in one transaction with the hashes from step 4, then verifies.
   Hold the registry lock from checking artifact ownership through apply,
   verification and cleanup; publish a new root binding only after verification.
   Lock acquisition has a five-second timeout; the protected operation itself
   may take longer for large imports. A failed candidate removes only its newly
   created database, associated sidecars/create lock and empty project directory.
   Never remove sidecars belonging to a pre-existing database. Preserve any
   pre-existing database and binding, and report cleanup failures. If an import
   or verification failure committed rows into a pre-existing database, those
   rows remain and the candidate reports `rolled_back: false`; `rolled_back:
true` means the failed candidate's database mutation and every database artifact
created by this run were actually removed; verification exports and reports are
retained for diagnosis.
   Successful earlier candidates remain imported. There is no cross-project
   crash-atomic rollback. Nothing is deleted recursively, and rollback never
   touches source files.
6. Verify by re-exporting and comparing task count, every ID, title, normalized
   body, extracted dependency and section-to-status assignment against the preview
   and store. Verification failure follows the same candidate-local cleanup as
   apply failure. Its sources are not quarantined; the run reports the failure.
7. Quarantine, only with `--quarantine-dir` and only for verified projects: move
   the sources below the quarantine directory, mirroring their path below the
   scan root. Preflight validates report files, verification-export targets,
   quarantine destinations and the audit-manifest path before any database
   mutation. The manifest is published by a same-directory atomic rename and
   records each file before its move (`planned`), after the move (`moved`), and
   after an optional delete (`deleted`). A later report or delete failure keeps
   prior manifest records and never removes an old audit file. The manifest
   carries the original absolute path, size, SHA-256 and destination.
   `--delete-quarantined` deletes the quarantined copies afterwards and requires
   `--apply`, `--quarantine-dir` and a clean verify for that project; it has no
   form that deletes a source that was never quarantined. Without
   `--quarantine-dir`, nothing is moved or deleted.

Migration is an offline operation: stop all Markdown writers and task workers
before apply, and keep them stopped through verification and quarantine. Do not
edit source ledgers or address an unpublished new project UUID during this window.
This prerequisite avoids adding a second live-source coordination protocol.

A dry run performs stages 1 to 4 and reports exactly what stages 5 to 7 would
do, including the project UUID it would create, the per-section status
assignment, the task count and, when `--quarantine-dir` is given, the quarantine
destination of every file. The project UUID is derived deterministically from
the candidate directory and is reused by apply; an existing registry binding
wins.

Reporting writes `run.jsonl` (one JSON object per candidate), `summary.md` for a
human, and `unrecognized.md` (every unmigrated file with its reason) under
`--report-dir`, plus `quarantine-manifest.json` when quarantine runs. Existing
ordinary report files may be reused only when they are writable; directories,
symlinks, read-only/ACL-denied targets and an existing quarantine manifest are
refused before apply. Per
migrated root the reports list every `AGENTS.md` and `CLAUDE.md` below it that
contains the string `TASKS.md`, with line numbers; the tool reports those files
and never edits them. Each candidate carries its schema class per file, its
count line and its full structured problem list; `unrecognized.md` groups the
messages under the candidate that produced them. Each candidate record also
carries `rolled_back`, true when a failed apply or verification removed
everything this run had created for it. Reports are written even when an
all-or-nothing `--apply` refuses the whole set, so the refusal message can
point at `unrecognized.md`.

Bulk runs apply one map to the whole corpus, so a literal `sections` entry that
a given file does not contain is ignored instead of rejected; the single-file
`import` keeps the strict unknown-section error. Exit codes follow the existing
table: 0 when no candidate is unrecognized and every applied project verified,
where excluded candidates never fail a run; 2 for usage and map errors, including
a completed run that reports unrecognized candidates or failed verifications and
says how many. A refused all-or-nothing apply also exits 2, before any registry,
project, database or quarantine mutation, and still writes the report files
under `--report-dir`. 6 covers I/O and database failure. Rehearsals run against copies of
real ledgers, never the live files, and never create projects in the default
data root.

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
add caches or change durability merely to meet targets. Bound dependency
count to 1000 per task; reject oversized replacement rather than truncate it.

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
