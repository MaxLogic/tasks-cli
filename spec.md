# Spec: shared local task backlog CLI

Status: implementation contract and verification basis, updated 2026-09-15.
The behavioral requirements below remain normative; implementation and
performance results are recorded separately in verification-report.md.

The [Rust server and automatic attribution extension](#rust-server-and-automatic-attribution)
was specified on 2026-10-02 from the user's accepted direction. Its behavior is
planned, not installed or verified. It supersedes the local-only restrictions
for explicitly configured remote profiles; existing local behavior remains normative.

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

Non-goals: offline synchronization, LLM calls, embeddings, arbitrary
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
identity may use focused crates. Do not add an ORM, SQLx, DI container or workspace
crates. Keep Tokio out of the local CLI and SQLite layer. The server extension permits its named HTTP/TLS
dependencies and Tokio for the server transport; synchronous database work and
the local CLI do not gain an async runtime. Verify versions/features/MSRV before selecting them;
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
`--scan-root`, `--report-dir`, `--quarantine-dir`, `--key-map`) with
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
stderr contains concise errors. JSON is one compact single-line object (no
pretty-printing) with `schema_version: 1`, `project_id` (null before selection),
and command-specific data; errors contain `error.code`, `error.message`, and
optional structured conflict details. Text and JSON have the same semantics. No
timestamps or banners added merely for display. Text output prints a
`project_id:` line only where the project is the result (`init`, `bind`,
`doctor`); JSON always carries it in the envelope. Text is the default for
reading; use JSON when parsing fields or cursors. Every command and option has a
one-line `--help` description.

| Command | Required behavior |
| --- | --- |
| `init --root PATH --key KEY` | Create project with its key, binding and exact root identity; accept a matching identity unchanged and refuse malformed or conflicting files without overwriting them |
| `project-key [--set KEY]` | Print the project key; `--set` assigns or changes it under the uniqueness rule |
| `bind --root PATH --project UUID` | Validate database/schema/embedded UUID, then register another root without duplicating tasks |
| `list [--open | --needs-human] [--status STATUS] [--label LABEL] [--after CURSOR] [--limit N]` | Default runnable todo/in-progress (prerequisites done or to-verify); priority then ID; default 20, max 100 |
| `unlocks [--offset N] [--limit N]` | Open prerequisites ranked by immediately runnable then direct open dependents |
| `enrich [--file PATH]` | Enrich UTF-8 text task references; stdin by default, exact text to stdout |
| `enrich-clipboard` | Enrich clipboard text and replace it after checking the original still matches |
| `show ID... [--rules]` | Full task(s), version and direct dependency summaries; shared rules only with `--rules`, printed once |
| `search TEXT [--label LABEL] [--after N] [--limit N]` | Literal case-insensitive ASCII substring search of title/body; numeric ID cursor, same page limits |
| `create --title TEXT --body-file PATH` | Optional `--status`, default draft; `--priority P0..P3`, default P2; allocate next ID atomically |
| `update ID --expect-version N ...` | At least one of title, body-file, status, priority, labels (replace, clear, add or remove) or full dependency replacement |
| `history ID [--after N] [--limit N]` | Metadata and changed field names by default; `--event N` returns complete selected event |
| `project-history [--after N] [--limit N]` | Bounded project creation, key and import audit events with mutation context |
| `rules show` / `rules set --body-file PATH --expect-version N` | Retrieve/update shared project Markdown rules |
| `import --file PATH... [--apply --expect-sha256 HASH]... [--map-file PATH] [--source-schema NAME]` | Preview by default; one apply can commit several sources into the same empty project |
| `bulk-import --scan-root PATH --map-file FILE --report-dir DIR [--exclude GLOB]... [--apply] [--allow-partial] [--quarantine-dir DIR] [--delete-quarantined] [--source-schema NAME] [--key-map FILE]` | Dry-run corpus migration: scan, group, classify and preview Markdown ledgers; only `--apply` initializes projects, imports and verifies; apply is all-or-nothing unless `--allow-partial` is passed; only `--quarantine-dir` moves sources |
| `export --out PATH` | Deterministic readable Markdown snapshot; refuse existing destination |
| `backup --out PATH` | Consistent SQLite backup; refuse existing destination |
| `migrate` | Explicit schema upgrade, with verified pre-upgrade backup |
| `doctor` | Database path/UUID/schema/SQLite version, quick_check and foreign_key_check |

Define `update --deps T-1,T-2` as complete replacement; `--clear-deps` means empty,
and omission preserves dependencies. They are mutually exclusive. The same
optional dependency flags apply to create. Status values: draft, todo,
in-progress, to-verify, blocked, done, cancelled; done/cancelled are terminal and
the others nonterminal. `to-verify` means implemented and focused-tested, waiting
for a scheduled batch gate. Every explicit status transition is allowed except
one completion guard: `update --status` moving a task to done fails with exit 2
(validation) and writes nothing while any prerequisite in the dependency set the
update would commit is nonterminal (draft, todo, in-progress, to-verify or
blocked); the message names each such prerequisite and its status. Done and
cancelled prerequisites never block. The guard applies only to the transition
into done (an already-done task can still be edited), not to create, import or
other transitions, and a later change to a prerequisite never reopens a done
task. Default lists additionally require readiness. No hard-delete command in v1.

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
Update also accepts `--add-label LABEL,...` and `--remove-label LABEL,...`,
together or alone, which merge into or subtract from the current set inside the
version-checked transaction (removal first, so a label in both is kept); they
conflict with `--labels`/`--clear-labels`. Removing an absent label is a no-op.
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

Schema 5 adds `to-verify` to the task status CHECK constraint. SQLite cannot
alter a CHECK in place, so explicit `migrate` rebuilds `tasks` after the verified
pre-upgrade backup, in one transaction with foreign keys disabled: drop the FTS
triggers, copy every column into a new table with the widened constraint and a
fresh-schema column order (priority last), swap it in, and recreate the three
task indexes and FTS triggers. Task IDs are unchanged, so the external-content
FTS index stays valid without a rebuild. Dependencies, labels, events, imports,
rules, versions and timestamps are untouched; validation and foreign_key_check
run before COMMIT and any failure rolls back to schema 4. Upgrades from schemas
0–3 pass through the same steps. Schema-4 binaries refuse schema 5 through the
existing newer-schema check.

Schema 6 adds the nullable project key (`project.project_key`, CHECK: 2-6
uppercase ASCII letters/digits starting with a letter, not `T<digits>`). Explicit backed-up
`migrate` adds the column and leaves it unset, so migrated projects keep
working with `T-N` until a person assigns a key; schemas 0-4 pass through the
earlier steps. Schema-5 binaries refuse schema 6 through the newer-schema check.

Project keys. Each project has at most one key, always chosen by a person: the
CLI never invents one. Input is case-insensitive and stored uppercase; `T` and
`T` followed only by digits (`T12`) are reserved for the legacy form, as is a
fixed list of standard-name prefixes routinely written as `NAME-number` in
prose (encodings, standards bodies, hashes, ciphers and vulnerability IDs, for
example `UTF`, `ISO`, `IEEE`, `SHA`, `CVE`; the full list is `RESERVED_KEYS` in
src/model.rs) so that `enrich` never mistakes `UTF-8` or `ISO-8601` for a
task-ID key. `init --key` is required: a missing, malformed or
taken key exits 2 and creates nothing (no project directory, binding or
identity file). Re-running `init` on a bound root must name the key the project
already has; init never changes a key. `project-key` prints the key (`none`
when unset); `project-key --set KEY` changes it without rewriting task bodies,
so old `OLDKEY-N` mentions stay as written and no longer resolve. Keys are
unique within a data root: while holding the registry lock, `init`,
`project-key --set` and `bulk-import --apply` check the key against every
project database under `<data-root>/projects/` and refuse a taken key with
exit 2 naming the owning project and its root. The key lives only in the
project database, so backups carry it. Every key lookup, the uniqueness
checks included, goes through `<data-root>/project-keys.json`, which caches
each database's key next to its fingerprint (file identity, size and mtime of
the database and of a non-empty WAL or journal, computed by the shared
`crate::fingerprint` module also used by the viewer's project-statistics
cache; see viewer/spec.md section 4.2), because opening every database costs
milliseconds each on Windows. A database without an entry or whose
fingerprint changed is opened again, a read is cached only when the
fingerprint was the same before and after it, and a damaged cache is ignored.
A file modified within the last 2 seconds is read but not cached, for
filesystems with coarse modification times (the same settle window the
viewer's cache uses). The cache is derived data,
rewritten atomically by the reference lookups (`enrich`, naming the owner of a
foreign `KEY-N`, import's foreign-heading check) and after a committed `init`,
`project-key --set` or bulk apply; a refused `init`, a bulk dry run and a
refused or rolled-back apply leave the data root unchanged.

Task IDs display as `KEY-N` (at least three digits, `DAK-007`) in a keyed
project and `T-N` otherwise, in text output, `list`/`search`/`show`/`history`/
`unlocks`, create/update results, dependency summaries, error messages,
Markdown export and the viewer. JSON keeps each numeric `id` and adds
`display_id` beside it (task rows, show, dependency summaries, create, update,
history, viewer rows, `open_prerequisites` items and `task_display_id`); `deps`
arrays stay numeric. List `next_after` cursors keep the `P2:T-123` form. Input
accepts `KEY-N` with this project's key, `T-N` and bare `N`, forever, in any
case and with or without leading zeros. A `KEY-N` with another key exits 3
naming the project that owns it and its root, or saying that no project has
that key; dependencies stay within one project.

Default list selects only todo/in-progress tasks without `needs-human`, and all
prerequisites must be done or to-verify. A to-verify prerequisite counts as
satisfied only for this readiness and for `unlocks`; completion (the done guard)
and every other rule still require done. Cancelled prerequisites remain
unsatisfied. Default list never shows to-verify tasks themselves, since they are
not runnable work; `--open` and `--status to-verify` do. `--open`
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
`immediately_runnable`. Include only nonterminal prerequisites that are not
to-verify (a to-verify prerequisite already satisfies readiness, so it has
nothing left to unlock) and nonterminal dependents. A dependent is immediately
runnable when todo/in-progress, without needs-human, and every other
prerequisite is done or to-verify. Count distinct dependency
edges enforced by the composite key. Order by immediately runnable descending,
direct count descending, priority then ID. Use `next_offset`/`--offset`, limits
20/default and 100/max. This is direct impact, not transitive scoring or an
authorization to close the prerequisite.

Enrichment recognizes standalone uppercase T001, T-001 and KEY-001 spellings,
preserving the original ID text. `T-N` and this project's `KEY-N` resolve in the
current project; another `KEY-N` resolves read-only in the project under the
same data root that owns that key, found through the key scan above only when
the text names a foreign key. A `KEY-N` whose key no project has (often a word
such as `UTF-8`) is left unchanged and not reported. Append ` (current task title)` after every known reference,
including terminal tasks, without inserting task bodies. Unknown IDs are left
unchanged and reported on stderr (and `unknown_ids` for this project's IDs plus
`unknown_refs` for every unknown reference in JSON). Invalid/out-of-range
numbers remain untouched. Exact existing annotations are skipped, including IDs
inside that annotation; arbitrary pre-existing prose is not deduplicated. Obvious
URL/path components are skipped; slash-separated task references such as
`T-226/T-227` in prose are enriched. This is a plain-text transform, not a
Markdown/code parser. Code blocks and link labels may therefore be enriched.
Read requested ID/title pairs in batches under one read snapshot; release it
before rendering. Limit input to 16 MiB, distinct valid IDs to 10,000 and output
to 64 MiB; fail instead of truncating. Preserve Unicode, line endings and trailing
newlines; `--file` never overwrites the input. Text output adds no banner. JSON
uses command `enrich` with text, replacements, unknown_ids, unknown_refs and
clipboard.

Clipboard support uses Windows PowerShell STA/System.Windows.Forms on Windows
and WSL; native Linux uses wl-clipboard for Wayland or xclip for X11. Missing
helpers/display/non-text input fail clearly. Use static command scripts and
stdin data, never interpolate task text into shell code. Before replacing, check
that clipboard text still equals the input; this is best-effort conflict detection,
not atomic compare-and-swap. No-op enrichment does not rewrite the clipboard.
Successful replacement publishes plain text, replacing other clipboard formats.
WSL delegation runs this command wholly through tasks.exe for Windows-owned stores.

List/search rows contain only ID, status, version, title (display bounded to 120
Unicode characters), priority, dependency IDs and normalized labels. Text rows
are tab-separated `ID, priority, status, vN, title`, followed by `[ID-A,ID-B]`
only when the task has dependencies and `labels=[a,b]` only when it has labels. Include `has_more` and `next_after`; read
limit+1 rows, do not COUNT(*) on each request. For plain search, `--after` is the numeric ID from the
last result. Pagination is a fresh snapshot per call, not a persistent snapshot;
concurrent edits can change later pages. Each list, search, show and export call
reads its task rows, dependencies and rules within one deferred read transaction.
In WAL mode, writers can commit while that read retains its original snapshot.
Release the read transaction before rendering or publishing an export. History
pages similarly use event IDs.
The remote streaming export is an exception: retain its read snapshot while
rendering one row at a time into bounded frames, then release it before the
client publishes the validated complete file. This avoids holding the entire
backlog in server memory while preserving a single consistent snapshot.
`show` never silently truncates body text. It accepts 1–100 task IDs, shown in
request order with repeats collapsed, all read in one snapshot; if any ID is
missing, the whole command fails with exit 3 naming every missing ID and prints
no task. JSON for one ID is command `show` with the task fields at top level:
`priority`, `id`, `status`, `version`, `title`, `body`, `labels`,
`dependency_summaries` (each `id`, `status`, `version`, `title`; the separate
`deps` ID array is not repeated). Several IDs give command `show_many` with
`items` holding those task objects. With `--rules`, `rule_version` and `rules`
appear once at the payload top level; without it they are absent and the rules
are not read. Text prints one block per task (blank line between blocks), omits
an empty `labels:` line and has one `depends_on:` line per dependency; with
`--rules` a single `rules(vN):` block follows the last task. The viewer's
`viewer show` protocol is unchanged and still includes `deps` and rules.

History JSON is command `history` with the task `id`, `items`, `has_more` and
`next_after`. Each item has `event_id`, `operation`, `resulting_version`,
`created_ms` and, when the event has a comparable predecessor task event,
`changed_fields`: the names among title, body, status, priority, labels and deps
(in that order) whose snapshot values differ from the previous task event. A
field counts only when both snapshots contain it; create/migrated events and
legacy non-JSON snapshots have no `changed_fields`. The comparison runs in SQL
so listing never returns snapshot bodies. Items do not repeat `task_id` or
`entity_type` (always this task). `--event N` adds `snapshot`, the stored
snapshot as a nested JSON value (or a string when legacy text is not JSON). Text
history rows are `event_id, vN, operation, created_ms[, changed=a,b]`, with a
`snapshot:` line for `--event`. History full snapshots and export are
explicit bulk access, not default context. Dependency cycles and self-links fail.
Create, update and import enforce the same dependency-list limit: at most 1000
IDs per task.

`rules` contains shared verification/workflow requirements needed to interpret
tasks; do not make agents infer them from an obsolete TASKS.md. `show --rules`
or `rules show` returns them with their version; plain `show` omits them so an
agent reads rules once per session rather than with every task. Repeated output should be deterministic
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
every open. Reads use existing-only connections that cannot write data
(read-only, or `query_only` as below) and do not migrate, initialize or perform
access-time writes. Unknown newer schemas fail closed.

Minimum tables:
- `project`: singleton UUID, rules Markdown, rules version, next task number.
- `tasks`: numeric primary key, title, body Markdown, constrained status, positive
  version, created/updated UTC timestamps stored consistently as integer millis.
  Render IDs as `KEY-<number>` (or `T-<number>` without a key) with at least
  three digits; accept T-1, T-001, KEY-1 and 1 as the same ID. Never reuse IDs;
  imports advance the counter past the maximum. `project` also holds the
  optional project key (schema 6).
- `dependencies`: task_id, depends_on_id; composite primary key and foreign keys.
- `events`: monotonic event_id, optional task_id, entity type task/rules,
  operation, resulting entity version, timestamp, complete resulting snapshot JSON.
  Each create/update/rules change has exactly one event in its transaction.
  Schema 7 adds nullable versioned attribution JSON; legacy authors remain null.
- `metadata_events` (schema 7): independent monotonic event ID, operation,
  timestamp, snapshot and non-null attribution JSON. Project creation, key
  changes and import provenance append within the corresponding transaction.
  Database triggers reject UPDATE and DELETE of this metadata history.
- `mutation_receipts` (schema 8): request UUID, registered actor/installation,
  route, canonical payload SHA-256, HTTP status and original result JSON.
  Mutation/history/receipt writes share one transaction. Triggers reject UPDATE
  and DELETE. Terminal application refusals remain refused on replay; transient
  storage/lock failures are not receipts. See the server API contract below.
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
filesystem activity or use immutable=1 for a live WAL database. A read-only
SQLite connection creates `-wal`/`-shm` but can never remove them, and every
later open pays for the leftovers (about 7 ms per read on Windows). So a
read opens the database read-write with `PRAGMA query_only` when the `-wal`
is absent or empty, and the last connection's close removes the sidecars;
with a non-empty `-wal` the read stays a read-only open. A read does not
checkpoint a WAL that was pending when the read began. Reads may delete empty
`-wal`/`-shm` files left by older binaries: database bytes are unchanged, but
the set of files in the data root can change.

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
`##` status sections. For a target project with a key, `### KEY-N` headings and
`Depends on:` IDs with that key are accepted as well. A `### OTHER-N` heading
whose key belongs to another project in the data root is a blocking problem
rather than silently becoming rules or body text; any other key-shaped heading
(`### ISO-8601 dates`) is ordinary text. The create-task `Deps:`
grammar stays `T-N` only. Use Markdown-aware heading recognition (including fenced
code handling), not a broad regex that mistakes code examples for task boundaries.
Preserve each task's content and capture original bytes. A leading UTF-8 BOM at
byte 0 is structural input: preview reports `has_bom: true`, while the original
bytes and source SHA-256 remain unchanged. Preview reports IDs,
titles, section/status mappings, duplicate IDs, ambiguous content and every
unassigned non-whitespace range. Provide an explicit mapping file option
`--map-file PATH` for section-to-status choices; do not guess ambiguous statuses.
The map is UTF-8 JSON `{"sections":{"In Progress":"in-progress","Next - Today":"ready"}}`;
keys are exact level-two heading text, values are the seven supported statuses.
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
by ID (headings and `Depends on:` in display form), status, version,
dependency IDs and complete bodies. It is human-readable,
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

Every project `--apply` would create needs a key from `--key-map FILE`: one
JSON object mapping a project root (absolute, or relative to `--scan-root`) to
its key. Malformed or duplicate keys fail at load with exit 2. A candidate bound
to an existing project keeps that project's key and needs no entry; entries for
roots that are not candidates are ignored. The dry run reports each
candidate's `project_key` and a `key_problem` for every root still lacking a
key or mapped to a key another project has; `--apply` refuses the whole run
(exit 2, nothing written) until every such problem is fixed, and re-checks
uniqueness under the registry lock before creating each database.

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

`unlocks` budget (separate fixture, TSK-005): dense-edge profile
`perf-100k-dense` (one project, 100000 tasks, 150000 dependency edges
concentrated on open, non-terminal tasks, deterministic from `--seed`).
Proposed target, not yet met: `unlocks --limit 20` p95 <=250 ms on Windows
(same budget as substring search). Observed on the development Windows
machine (release build, 5 warmups + 50 fresh-process runs, `target/perf-cli`):
before the TSK-005 query rewrite, p50 3868 ms / p95 4188 ms (n=50); after
replacing the per-edge correlated `NOT EXISTS` with a single per-task
unsatisfied-prerequisite count (a `WITH unsat AS (...)` CTE joined once per
row instead of a rescan of t's other dependencies per (p,t) edge), p50
1451 ms / p95 1701 ms (n=50) — about 2.5-2.7x faster, but still a miss
against the 250 ms target on this fixture. `EXPLAIN QUERY PLAN` before showed
a full `SCAN d` (150k rows) with two correlated subqueries per row, the
second of which (`other`/`prerequisite`) rescanned each dependent's edges;
after, the rescan is gone and only the cheap `needs-human` label check
remains correlated. The residual cost is dominated by two things unrelated
to the join strategy: opening/reading this 100k-row, ~530 MiB tasks table
(a bare `list --limit 1` on the same fixture already costs about 800 ms
fresh-process, versus about 80 ms for `tasks --help`), and the up to ~450k
still-necessary rowid lookups (`unsat`'s prerequisite lookup, plus `t` and
`p` in the main join) across that large table. Closing the remaining gap
would need a smaller per-row footprint or a materialized/cached readiness
view, which this slice does not add (see AGENTS.md: no caches without
profiling evidence, no durability weakening). Results and ranking are
unchanged: verified byte-for-byte identical output on this fixture between
the old and new query, across all 33847 grouped rows and the top-20 page.
Repeated natively on Linux (WSL2 Ubuntu, Linux-owned `CARGO_TARGET_DIR` and
temp data/roots outside `/mnt`, same fixture profile and seed, same 5
warmups + 50 fresh-process runs): before, p50 1707 ms / p95 3643 ms (n=50,
min 1407 ms, max 4001 ms); after, p50 661 ms / p95 839 ms (n=50, min 555 ms,
max 1523 ms) — about 2.6x faster at p50 and 4.3x at p95, closer to the
proposed 250 ms target than Windows but still a miss. Linux p95 is noisier
than the p50 suggests (WSL2 VM I/O variance); the same query-plan change
applies on both platforms since it is pure SQL with no platform-specific
path.

`list` on stores where few tasks are runnable (TSK-014): a single shared
`select_tasks` query whose default-view status filter was guarded by a bound
parameter (`?1 IS NULL OR t.status NOT IN ('done','cancelled')`) forced
SQLite to fall back to a full `idx_tasks_priority_id` scan regardless of
status selectivity, since the planner cannot resolve a bound-parameter `OR`
branch at prepare time. On `perf-10k-few-runnable` (one project, 10000
tasks, 2048-byte bodies, no dependency edges, 8 intentionally-runnable
tasks placed at the highest ids/priority `P3` so they sort last, the rest
`done`/`cancelled`; `--seed 20260929`), default `list --limit 30` measured
(Windows, `target/perf-cli`, 5 warmups + 50-100 fresh-process runs) p50
70.2 ms / p95 149.6 ms (n=100) -- a miss against the 100 ms budget, isolated
via a `--open` control run (same process/table-open cost, bypasses the
predicate) at p95 94.9 ms, plus a raw `sqlite3` CLI run of the exact query
at 44-60 ms. A first fix replaced the guarded predicate with a literal
`t.status IN ('draft','todo','in-progress','to-verify','blocked')` for the
default view; this picks a status-indexed `SEARCH` and fixed the
few-runnable case, but regressed open-heavy stores: on `perf-100k` (even
6-way status split, ~66666 non-terminal of 100000) default `list --limit 30`
went from ~1-8 ms to 185-360 ms query time (end-to-end ~80 ms to
245-330 ms), because a literal `IN (5 values)` predicate loses the
priority-ordered scan's `LIMIT` early exit (`EXPLAIN QUERY PLAN` shows
`USE TEMP B-TREE FOR ORDER BY`: every matching row must be sorted before
`LIMIT` applies). The fix landed instead: each needed status becomes its
own `SELECT ... WHERE t.status='<literal>' ... ORDER BY t.priority,t.id`
arm over `idx_tasks_status_priority_id` (already the arm's own sort order),
joined with `UNION ALL` and one outer `ORDER BY priority,id LIMIT`; SQLite
recognizes each arm is pre-sorted and merges them (`MERGE (UNION ALL)`)
instead of sorting the union, so the `LIMIT` early exit survives. Which
statuses are unioned is chosen in Rust from `status`/`open`/`needs_human`
(known at call time, not bound parameters): an explicit `--status` stays a
single arm; the default view unions only `todo`/`in-progress` (the two
statuses RUNNABLE_PREDICATE's own `t.status IN (...)` term can ever match);
`--open`/`--needs-human` union all five non-terminal statuses (built from
`TaskStatus::value_variants()` filtered by `!is_terminal()`, not a
hand-maintained literal list). Re-measured on three shapes (Windows
`target/perf-cli` and native Linux/WSL2 Ubuntu, `TASKS_WINDOWS_EXE` unset,
Linux-owned `CARGO_TARGET_DIR`; 5 warmups + 50 fresh-process runs;
default/`--open`/`--needs-human`, `--limit 30`): `perf-10k-few-runnable`
p50 18.1-19.0 ms / p95 22.8-26.9 ms (Windows), p50 7-10 ms / p95 10-13 ms
(Linux); `perf-100k` (even split) p50 17.9-20.2 ms / p95 21.8-24.5 ms
(Windows), p50 9 ms / p95 11-12 ms (Linux); `perf-10k-open-heavy` (new
fixture, ~90% non-terminal, the opposite shape from few-runnable) p50
18.1-20.4 ms / p95 21.3-31.3 ms (Windows), p50 9-11 ms / p95 11-13 ms
(Linux) -- every shape and view now meets the 100 ms p95 budget on both
platforms. `EXPLAIN QUERY PLAN` confirmed `MERGE (UNION ALL)` with no temp
b-tree on all three shapes. Output is unchanged: verified byte-for-byte
identical between the base-commit query and the fixed query across every
shape/view combination above plus `--status` and two-page `--after`
pagination crossing a union-arm boundary. As a side effect (not targeted by
this fix), `perf-100k-dense`'s (TSK-005/TSK-013's dense-edge, 0-runnable
fixture) default `list --limit 30` improved from TSK-013's pre-fix
835-1236 ms (`--limit 1`) to p50 386.0 ms / p95 490.9 ms (Windows, n=10) /
p50 105 ms / p95 150 ms (Linux, n=10) -- still over budget, because that
fixture concentrates 150000 dependency edges on its open tasks specifically
to stress RUNNABLE_PREDICATE's dependency-satisfaction subquery and 0 tasks
are ever runnable, so any query shape must exhaustively evaluate that
subquery for every candidate row; unchanged from TSK-013's "deliberately
extreme ... P3" scoping, not this task's fixture. Evidence:
`target/evidence/tsk-014/`.

List default output <=6 KiB for fixture titles/dependencies; one typical show
should include only that task, shared rules and direct dependency summaries.
Measure output bytes; only claim token counts when a named tokenizer was used.
Record peak process memory for show/list; investigate >64 MiB. Export/backup may
scale with data size, but stream where practical. Never read all bodies/history
for list. Use EXPLAIN QUERY PLAN to verify ID/status/history access paths; do not
add caches or change durability merely to meet targets. Bound dependency
count to 1000 per task; reject oversized replacement rather than truncate it.

`tasks viewer projects` project-list load, before/after sharing the fingerprint
rule between the project-key cache and the viewer's project-statistics cache
(TSK-006; see "Project keys" above and viewer/spec.md section 4.2), and before/
after batching that cache's writes into one transaction per call instead of
one autocommit write per project (same section). Method: release binary
(`target/perf-cli-before` for the pre-TSK-006 code at commit 42d8406,
`target/perf-cli-after` for the candidate), fresh-process `tasks viewer
projects` against 53 and 500 `init`-created projects with one task each, n=20.
Cold cache deletes `viewer-cache.sqlite3` before every one of the n runs,
forcing a full per-project resample every time (a harder case than the real
first-ever run, which this section's other rows already cover via
measure.ps1's M05/M06); warm cache primes once, then reuses it across all n
runs. Proposed targets (not yet asserted in CI; picked from the Windows
numbers below, the platform the viewer ships on): 500-project cold p95
<=2000 ms, warm p95 <=500 ms.

Windows dev SSD -- before: 53 projects cold p50 1181 ms / p95 7980 ms (n=20,
min 1073 ms, max 8200 ms), warm p50 46 ms / p95 71 ms; 500 projects cold p50
20771 ms / p95 25477 ms (n=20, min 13869 ms, max 26332 ms), warm p50 173 ms /
p95 348 ms. After: 53 projects cold p50 227 ms / p95 5437 ms (n=20, min
197 ms, max 6894 ms), warm p50 32 ms / p95 38 ms; 500 projects cold p50
1912 ms / p95 6660 ms (n=20, min 1352 ms, max 9010 ms), warm p50 100 ms /
p95 330 ms. Against the proposed targets: warm passes at both sizes; 500-
project cold p95 (6660 ms) misses the 2000 ms target.

Native Linux (WSL2 Ubuntu, Linux-owned `CARGO_TARGET_DIR`, no antivirus) --
before: 53 projects cold p50 2452 ms / p95 2949 ms (n=20, min 1921 ms, max
3199 ms), warm p50 8 ms / p95 9 ms; 500 projects cold p50 23409 ms / p95
28030 ms (n=20, min 18391 ms, max 28382 ms), warm p50 36 ms / p95 51 ms.
After: 53 projects cold p50 142 ms / p95 176 ms (n=20, min 125 ms, max
2303 ms, one outlier), warm p50 8 ms / p95 9 ms; 500 projects cold p50 478 ms
/ p95 1953 ms (n=20, min 408 ms, max 3048 ms), warm p50 25 ms / p95 42 ms.
Against the proposed targets: every row passes, including 500-project cold
p95 (1953 ms).

Sharing the fingerprint rule alone (no batching) showed no regression at
either platform or size (p50s within noise of the pre-change code). Batching
the cache writes is the change that produced the improvement above: 500
projects cold p50 dropped about 11x on Windows (20771 -> 1912 ms) and about
49x on Linux (23409 -> 478 ms), because `journal_mode=delete,
synchronous=FULL` fsyncs on every autocommit write, and the old code did up
to two per project (stats upsert, archive clear) instead of at most two for
the whole call. An isolated microbenchmark (Linux, Python's `sqlite3`, `journal_mode=DELETE`,
`synchronous=FULL`, 500 autocommit single-row upserts into a fresh copy of
this table vs. the same 500 upserts inside one `BEGIN`/`COMMIT`) measured
15.8 s vs. 0.04 s for the transaction wrapper alone, consistent with the
end-to-end drop. Durability is unchanged: `journal_mode`
and `synchronous` were not touched, and the batch is one transaction (an
interrupted or erroring write leaves the previous cache state, never a
partial batch).

The Windows numbers are noisier and, at 53 projects, non-monotonic across
repeated runs of the unchanged "before" binary (779 / 2200 ms in one run,
1181 / 7980 ms in another, both cold p50/p95, same code, same fixture,
reruns minutes apart): the repeated per-iteration delete-and-recreate of a
small `viewer-cache.sqlite3` file appears to trigger variable antivirus/
filesystem-journal latency on this host, which the cold-cache method here
constructs 20 times per row. The clean, low-variance Linux numbers (no
antivirus) at the same code and fixtures, showing the same directional
improvement with far tighter spread, support attributing the Windows p95
jumpiness to host interference rather than the code change. A later fix kept
the batched archive-clear write's original live re-check (`archived_at_ms <
?`, evaluated at commit time against the current row, not the pre-sampling
snapshot used to decide whether to queue it) so a concurrent `viewer archive`
landing during the call is never clobbered; re-measuring 500 projects cold
after that fix confirmed the improvement held (Windows p50 2710 ms / p95
5467 ms, n=20; Linux p50 503 ms / p95 615 ms, n=20 -- both comfortably inside
or near the proposed targets, Linux with no antivirus/host-noise contribution
at all). Evidence: `target/evidence/tsk-006/` (`windows-cargo-test*.log`,
`linux-cargo-test*.log`, `before-*`/`after-*` sample files,
`linux-perf-v2.txt`, `*-final*`, `microbench-sqlite-upserts.txt`).

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

Deferred: additional Linux distributions/architectures outside the server's QNAP
deployment target, offline sync, claims/leases for agent task
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

## Rust server and automatic attribution

Status: Ready for implementation, 2026-10-03. Deployment prerequisites below
remain pending.
Verification below is planned.
The user selected a Rust server in Docker on a QNAP NAS, online-only remote
operation, HTTPS and authentication. The viewer continues to access tasks
through the CLI. Routine implementation choices below were selected locally.
The user also selected both Cloudflare Tunnel and direct LAN access. The live
infrastructure review confirmed the existing QTS reverse proxy. On 2026-10-03,
the user assigned LAN HTTPS to another thread, which is preparing a separate
Caddy gateway for Docker services. Reuse that gateway and the existing tunnel
for public HTTPS; QTS continues to serve NAS administration.
The user accepted per-installation keys with automatic application-level request
signing, verified by Rust on both routes. This supersedes the token baseline
and earlier mTLS proposal. No attribution or authentication arguments are
required in ordinary CLI calls.

### Verified NAS context and access routes

Read `F:\projects\MaxLogic\qnap-nas-maintenance\` and `F:\projects\LAN\` for
operational guidance. NAS notes identify a TS-473A at `10.77.77.13` with local
name `qnap.home.arpa`. Read-only WSL SSH on 2026-10-02 confirmed hostname
`QNAP-NAS`, `x86_64`, platform `TS-X73A`, QTS `5.2.10` and Container Station
`3.1.2.1742`. Build the server image for `linux/amd64`.
Docker is at `/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker`.
Docker reports `27.1.2-qnap8`. The `cloudflared-audiobookshelf` connector is
running on the `abs-meta` Docker network, shared with `audiobookshelf-1`.
The public `https://audiobooks.maxlogic.app/` and LAN
`http://10.77.77.13:32768/` both returned HTTP 200 from the workstation on
2026-10-02. Dashboard routing was not inspected. No standalone Caddy, nginx or
Traefik container is running. The NAS's App Center catalog, refreshed that day,
offers installed Container Station `3.1.2.1742` for this platform; `3.1.3.1854`
is restricted to QAI-X700/QAI-X90. No supported Docker 28 upgrade is established.
On 2026-10-03 the user decided to retain the current Docker version.

The QTS-native Apache reverse proxy is running with
`/etc/reverseproxy/reverseproxy.conf`. Its persisted rules are in
`/etc/config/reverseproxy/reverseproxy.json`, with generated virtual hosts in
`/etc/reverseproxy/extra/`. Read-only inspection found:

| Existing HTTPS source | Destination | Observation |
|---|---|---|
| `maxlogic.myqnapcloud.com:443` | `https://localhost:2443/` | NAS administration rule; both listeners are active. |

The user deleted the stale Audiobookshelf rule on port 2001. Read-only SSH on
2026-10-03 confirmed only the `main` administration rule remains, with no port
2001 listener or generated virtual host.

The certificate served on port 443 for `maxlogic.myqnapcloud.com` is the
self-signed QNAP certificate, subject CN `QNAP NAS`, with no subject alternative
names. It is valid by date through 2032 but does not meet the CLI's trusted,
matching-hostname requirements. Provision a matching trusted LAN certificate
before deployment readiness. Preserve existing routes when changing certificates;
do not edit QTS-generated Apache files directly.

Required task-service routes:

| Route | TLS endpoint | Origin path |
|---|---|---|
| Direct LAN | Existing Caddy gateway under preparation in the other thread, with matching trusted certificate | Gateway reaches `tasks-server:8080` on its private Docker network. No task backend host port is published. |
| Public hostname | Cloudflare HTTPS edge through the existing tunnel | Connector reaches `tasks-server:8080` by Docker DNS on a dedicated tasks network. |

Add a task-service hostname/rule to the existing tunnel and attach its connector
to the dedicated tasks network. The Rust service joins only that network, not
`abs-meta`. Keep existing Audiobookshelf routes and networks intact. Bind the
task backend only inside Docker; publish no backend port on the NAS.
The gateway network and configuration are documented in
`F:\projects\MaxLogic\qnap-nas-maintenance\docs\docker-https-playbook.md`.
Docker before 28 has a documented same-L2 localhost-publication exposure risk.
Require host firewall protection and proof from a separate LAN machine that
direct backend HTTP is unreachable; absence of a port mapping alone is not
isolation proof. Recheck the final network arrangement, not just the gateway spike.
The database mount is NAS-local, for example `/share/Container/tasks-cli`.

Use per-installation Ed25519 keys with automatic HTTP request signing
verified by Rust, using the RFC 9421 profile below.
Private keys remain client-local; the server stores registered public keys and
maps them to actor/machine identities. Both routes use the same application
authentication and revocation checks. The CLI supplies signatures automatically,
without extra AI arguments. Never reuse the NAS administrator's SSH key.
Client authentication is an accepted design decision. TLS certificates protect
the transport; application keys identify the actor and client installation.
References: [QNAP reverse proxy](https://www.qnap.com/en/how-to/tutorial/article/how-to-use-reverse-proxy-to-improve-secure-remote-connections),
[Cloudflare published applications](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/),
[Docker port publishing](https://docs.docker.com/engine/network/port-publishing/)
and [HTTP Message Signatures](https://www.rfc-editor.org/rfc/rfc9421.html).

### Goals and boundaries

- Multiple machines use one authoritative backlog per project UUID through
  an HTTPS JSON API. All SQLite access for those backlogs occurs on the server.
- Every persisted mutation records actor, machine, harness and available
  session context atomically. Normal CLI calls require no attribution arguments.
- Keep current task semantics, keyed IDs, pagination, version conflicts,
  completion guards, complete descriptions and CLI/viewer output contracts.
- Remote reads and writes require a live connection. No offline queue, cached
  task reads or fallback to a local project database is provided.
- Existing local mode remains available as an explicitly selected backend for
  current installations and synthetic verification. It is never an outage fallback.
- No live backlog migration, NAS deployment, credential installation or harness
  configuration change is authorized by this design document alone. Migration
  preparation and acceptance use copies until the user selects the real cutover.
- Remote filesystem maintenance, remote bulk Markdown migration, OAuth/SSO,
  web UI, task leases and automatic certificate issuance are outside this version.

### Components and ownership

Keep one Cargo package and the existing library. Add `tasks-server` behind a
`server` Cargo feature, plus shared application dispatch, remote transport and
attribution modules. Use Axum/Tokio for internal HTTP and a synchronous HTTPS
client with certificate validation for the CLI, and existing rusqlite storage.
Verify and lock exact compatible dependency versions during implementation.
Do not wrap CLI subprocesses inside the server or duplicate task validation.

SQLite operations remain synchronous on bounded blocking workers. Allow eight
in-flight application operations by default; requests wait at most one second
for a permit and receive an actionable 503 if capacity is unavailable. Keep the
five-second SQLite busy timeout, `synchronous=FULL`, one connection per operation
and existing transaction boundaries. Reject new writes during graceful shutdown;
allow admitted writes to finish before exit, with a 30-second shutdown deadline.
After forced termination, SQLite recovery determines whether a write committed.

Run one server instance for a data root. Hold an exclusive process lock for its
lifetime, reject a second instance, and make server administration respect that
ownership. Store project databases on NAS-local disk mounted into the container
at `/data`, never on SMB/NFS mounts or in the image layer. The QNAP disk is local
to the server even though client machines cannot access its databases directly.
Keep server identity/auth state separately at `/data/server.sqlite` with migrations.

Portable `.tasks.json` remains exactly the project UUID. Client workspace paths
stay client-local; the server catalog contains UUID, project key and readable
project name, never requires `F:\...` paths to exist on another machine.

### HTTPS and authentication

- The Caddy gateway terminates LAN-facing TLS and Cloudflare terminates public-facing TLS,
  using TLS 1.2 or newer. The Rust service listens on HTTP port 8080 on its
  private Docker network, without a published backend port. The gateway and
  tunnel connector must reach it on that network. NAS firewall/isolation proof
  is required as specified above. The gateway manages its LAN certificate inputs;
  Cloudflare manages the public endpoint certificate.
  Missing or invalid TLS/auth configuration prevents deployment readiness.
  Require the same application authentication on both routes and on the
  internal HTTP listener. Ignore unverified proxy identity headers.
- The CLI requires an `https://` URL, checks certificate validity and hostname,
  and permits an explicitly configured private CA file. No insecure bypass.
  Reject cross-origin redirects and never forward credentials to another origin.
- Generate a new Ed25519 key pair from the OS cryptographic random source during
  explicit client setup. Store the private key as PKCS#8 PEM in a client-owned
  file, not arguments, repository files or logs. Require mode
  0600 on Unix and access restricted to the owning user plus system/admin on
  Windows. A missing or insecure key file prevents remote operation. Enrollment
  exports only the public key, installation UUID and observed machine name.
  Register one public key per installation, with a server-generated credential
  UUID, actor ID/name and installation ID/name. The server derives authoritative
  actor/machine IDs from that registration, ignoring client replacements.
  Never transmit or persist the client's private key on the server.
- Provision/revoke credentials through `tasks-server admin` commands executed
  on the server, not through an HTTP admin endpoint. Admin writes use the same
  server process ownership lock; stop the service first. Record the OS actor
  and affected credential identity in append-only admin audit events. A revoked
  credential receives 401 on subsequent requests through either route. Register
  replacement keys under new credential UUIDs, retaining the actor/installation
  history identity. Revocation applies before idempotency receipt lookup.
- Credentials grant read/write access to the owner's server backlogs in this
  initial single-owner service. Separate project permissions are deferred.
- Authenticate before revealing project existence or reading request content
  beyond bounded protocol parsing. Return structured 401 errors without secrets.
  Disable browser CORS access by default. Limit application request bodies to
  8 MiB, matching the existing viewer request ceiling.
- Log request ID, actor ID, project UUID, operation, duration and outcome.
  Exclude authorization/signature headers, private keys, task bodies, prompts, full
  environment dumps, session titles and executable command lines from logs.

#### Signed request profile

- Use RFC 9421 `Signature-Input` and `Signature` header fields with the single
  label `tasks`, algorithm `ed25519` and `keyid` equal to the registered credential
  UUID. Reject additional signatures, duplicate security headers, unknown keys,
  other algorithms and component lists that differ from the specified list.
- Every request signs `@method`, `@path`, `@query`, `content-type`,
  `content-digest` and `x-tasks-server-id`, in that order. Mutation requests also
  sign `idempotency-key`. Require `Content-Type: application/json` on requests,
  including empty GET requests. Use RFC 9530 `Content-Digest` with only `sha-256`,
  calculated over exact transmitted body bytes, including the empty body.
  Request compression and content transformations are unsupported. Reject a
  digest mismatch before any project lookup or mutation.
- Persist a server UUID at server initialization. The operator supplies it to
  client setup from server administration output. Include it in the signed
  `X-Tasks-Server-Id` header and authenticated `/v1/info` response. Reject requests
  addressed to another server UUID. Store the UUID with pending receipts and
  verify it before reconciling after an endpoint change or server restore.
  Backups retain the UUID; fresh server initialization creates a different one.
- Require signed `created`, `expires` and `nonce` parameters. Use Unix UTC seconds,
  with `expires = created + 120`, and a nonce generated from 32 random bytes,
  encoded as unpadded base64url. Accept only when `created <= now + 30` and
  `expires >= now - 30`. Client and server clocks must be synchronized. Report
  actionable clock errors without relaxing verification automatically.
- After verifying the signature and current registration, atomically consume
  `(credential UUID, nonce)` in `/data/server.sqlite` before application dispatch.
  Retain it until `expires + 30 < now`; the replay record survives server restart.
  A repeated nonce receives 401. Allow at most 4096 unexpired nonces per
  credential and 65536 globally; return 503 at capacity and never evict unexpired
  entries to admit another request. Invalid signatures cannot consume capacity.
- Verify signed metadata before reading body content beyond protocol limits.
  Read at most the existing 8 MiB ceiling, check the digest, then dispatch. A
  consumed nonce remains consumed after body failure or application refusal.
  Reconciliation signs a new HTTP request with a fresh nonce/timestamps but
  reuses the exact canonical mutation and idempotency key. Signature headers,
  nonces and freshness timestamps are excluded from mutation receipt identity.
- Caddy and Cloudflare routing must preserve the signed path/query, content bytes
  and application security headers. Do not sign proxy-rewritten scheme/host,
  `Forwarded` or `X-Forwarded-*` fields. HTTPS endpoint validation and the signed
  server UUID provide destination binding. Do not rewrite API paths at a proxy.
  Prove this profile through both actual routes before deployment readiness.

References: [HTTP Message Signatures](https://www.rfc-editor.org/rfc/rfc9421.html)
and [Digest Fields](https://www.rfc-editor.org/rfc/rfc9530.html).

### API and transport contract

Use `/v1` JSON routes and typed shared request/result structures. Requests carry
an attribution object with client-reported context. Reads may carry it for
operational tracing but do not create history or change stored attribution.

| Route | Operations |
|---|---|
| `GET /v1/info` | Authenticated server UUID, protocol capabilities and readiness |
| `GET /v1/projects` | Bounded project catalog and existing viewer statistics |
| `POST /v1/projects` | Explicit project creation, UUID, name and optional user-selected key |
| `POST /v1/projects/{uuid}/query` | Typed list, show-many, search, unlocks, history, rules, project-key and viewer read requests |
| `POST /v1/projects/{uuid}/tasks` | Create task |
| `PATCH /v1/projects/{uuid}/tasks/{id}` | Update task with `expect_version` |
| `PUT /v1/projects/{uuid}/rules` | Change rules with `expect_version` |
| `PUT /v1/projects/{uuid}/key` | User-selected key change, preserving existing collision checks |
| `GET /v1/projects/{uuid}/export` | Existing Markdown export generated on the server and written locally by the client |

Ordinary API responses have a 16 MiB serialized ceiling. Show-many and project
history preflight a 4 MiB source-text budget inside their read snapshot, returning
413 and a smaller-page instruction when exceeded; successful reads remain complete.
Export uses NDJSON `begin`, `chunk`, `end` frames: protocol version 1 and project
UUID, base64 data chunks no larger than 16 KiB, then task count, byte count and
SHA-256. Frames are capped at 32 KiB. The client requires the matching UUID,
complete checksum/count and EOF after the end frame before publishing its file.
The server queues at most two frames, retains admission during the stream,
bounds backpressure waits to 15 seconds and the whole export to five minutes.
All API responses disable caching.

The query body is a tagged enum of supported reads, not arbitrary SQL or command
execution. Viewer `info`, catalog and typed read/write requests map to these
routes and retain current stdout JSON and error payloads. Clipboard enrichment
and file output remain client-local; task/key lookups use the chosen backend.
`bind` writes only client workspace routing and does not create server history.
Remote `import`, `bulk-import`, `backup`, `migrate` and `doctor` return an explicit
unsupported-remote-operation error before touching local databases. Corresponding
maintenance runs under server administration on copied/server-local data.

Keep existing list/search/history limits and cursor semantics. Require a valid
UUID and allow-listed read operation. Unknown projects/tasks return 404, malformed
or invalid operations 400, oversized requests 413, version conflicts 409, and
capacity/lock exhaustion 503. Errors preserve existing application codes and
expected/current versions; CLI maps them to existing exit conventions, with
transport/auth failures using storage/service exit 5 and distinct JSON codes.
Use UUID plus numeric task ID for routing; keyed input is resolved against that
project's current key through existing validation.

Remote task and rules updates still require `--expect-version`. Never retry a
conflict automatically. Before any write, the client generates a request UUID
and includes it in `Idempotency-Key`. Persist its result in the affected project
database in the same transaction as the mutation and history. Same authenticated
actor/machine, route and key with the same canonical request returns the original
result; a different request under that key returns 409 without a mutation. Exclude
volatile request timestamps from the canonical payload. Check deduplication
before checking the entity's now-incremented version. Retain write receipts for
the lifetime of the database in this version.
Terminal application refusals, including validation/version conflicts, also
retain their original result without a task/rules mutation event. Replaying a
refused request must not apply it later after prerequisites change. Auth failures
and transient capacity/lock exhaustion are not persisted as mutation receipts.

Project creation cannot atomically span the server catalog and a new database.
Create the project under the existing registry ownership lock, with its creation
receipt in the project database. Publish the validated catalog binding last.
A retry reconciles the same UUID/receipt and repairs only that incomplete binding;
it never creates a second project. Conflicting identities/keys fail explicitly.

The CLI uses a three-second connection timeout and a 15-second request timeout,
both configurable once per profile. It makes no automatic write retries. Persist
a pending write's key and canonical request before sending, with owner-only
permissions; confirmed responses remove it. If the response is lost, report an
unknown write outcome and the receipt ID, without claiming failure or success.
`tasks remote reconcile <request-id>` resends that exact stored request/key,
returning the committed result or safely executing it once. A definitively refused
write remains refused; reconciliation never rebases its expected version. This
receipt is recovery evidence, not an offline write queue.

### Client configuration and viewer compatibility

Add explicit one-time `tasks remote configure` setup. Store the active backend,
server URL, credential-file path, optional private-CA path and timeout settings
in `<data-root>/client.toml`. Credential secrets stay in a separate protected file.
Each installation selects its LAN or public HTTPS endpoint once. Both reach the
same server and project authority. Automatic endpoint failover is outside this
version; changing the configured endpoint must preserve pending receipt identity
and verify the same server identity before reconciliation.
Default is local when that file is absent. An invalid remote configuration fails
closed. A synthetic `--data-root` without configuration remains local even if
the real user profile is remote. Do not introduce implicit global environment
routing that can turn local test fixtures into server traffic.

Ordinary commands then remain `tasks list`, `tasks show TSK-012` and
`tasks update TSK-012 --expect-version N --status done`. No server or attribution
flags are required per call. Local identity discovery selects the UUID; the
remote server decides whether that project exists. Selecting remote mode must
not open a leftover local `TASKS.sqlite` for reads, writes or readiness checks.
Existing remote setup is not inferred from database files or Git remotes.

For WSL, an explicitly configured remote profile selects native HTTPS access
before Windows-store delegation. A local profile retains current delegation
rules. If a local delegated mutation is attributed, collect its context in the
originating Linux process and carry it through a versioned, hidden delegation
envelope. Windows validates that envelope and preserves its origin; it must not
misidentify the Windows tasks.exe child as the original harness or session.

The viewer keeps CLI subprocess access. Its data root selects the same profile;
`viewer info` probes server capability and its catalog reads server projects.
Preserve the viewer JSON protocol, refusal payloads, superseded-read cancellation
and acknowledgement-loss reconciliation. A viewer write whose CLI response is
lost is reconciled with the pending request receipt before another write is
allowed; reading a matching task version alone does not establish who committed
it. The CLI owns remote receipts, with only the minimal viewer wiring needed to
pass their identity through existing reconciliation. Viewer recovery drafts may
remain local, but remote task state is never presented as current during an outage.

### Automatic mutation attribution

Store a versioned attribution JSON value on each existing history event. Legacy
events have null attribution; migration must not invent their authors. New task,
rules, key, import and project-creation mutations carry context through the shared
application layer into the same database transaction. Add append-only metadata
events where existing project/key changes lack task history; do not manufacture
extra task update events or change task versions solely to add attribution.
No-op operations and refused writes create no task/rules mutation event.

| Field | Collection and authority |
|---|---|
| `actor_id`, `actor_name` | Remote: server credential identity. Local: observed OS account identity/name, explicitly labeled local/unverified. |
| `machine_id` | Remote: registered credential's persistent client installation UUID. Local: installation UUID created during explicit setup. |
| `machine_name` | OS hostname observed at invocation, client-reported; retain the registered name separately when it differs. |
| `harness` | `codex`, `claude-code`, `viewer`, `manual` or `unknown`, with detection source. |
| `harness_version` | Available allow-listed environment/hook value; optional. |
| `session_id`, `session_name` | Exact harness-reported session identifier and optional name; never inferred from the OS login session. |
| `model`, `agent_id` | Optional active model/subagent identity from a matching hook context. |
| `caller_executable`, `harness_executable` | Immediate parent's executable basename and recognized ancestor basename; optional, client-reported. |
| `request_id`, `created_ms` | Invocation UUID and existing server/database UTC event timestamp. |
| `context_source` | Per-field source: OS, environment, hook or unavailable. |

Snapshot names on the event, so later renames do not relabel old changes. History
text/JSON and viewer details expose attribution; compact list/mutation output
does not repeat it. SQLite backups retain attribution JSON and JSON history
includes it; Markdown exports remain descriptions, not full audit recovery artifacts.
Harness/session/model reports are attribution clues, not authenticated proof that
a particular model performed a change.

Detection rules:

1. Recognize a direct viewer invocation first; an inherited Codex environment
   from whoever launched the GUI must not attribute later manual GUI changes to
   that old session. Use `viewer`, with null AI session/model.
2. Prefer a hook context matching the current harness/session. In this session,
   `CODEX_THREAD_ID`, `CODEX_SESSION_ID` and `CODEX_VERSION` are present. Use
   nonempty `CODEX_THREAD_ID` as the Codex conversation ID, falling back to
   `CODEX_SESSION_ID`; do not assume other installations export both. Capture
   both separately when they differ. Environment presence identifies reported
   origin, not a trusted author. Never read API-key environment variables.
3. For Claude Code, ship an optional SessionStart integration that reads hook
   stdin and persists session ID, optional `model` and `session_title`. Publish
   a context-file pointer through `CLAUDE_ENV_FILE` where supported. Supplement
   with silent PreToolUse refreshes for tools that can mutate tasks, so model
   changes do not leave stale attribution. Document and verify Bash and native
   PowerShell behavior on installed versions; no claim of universal inheritance.
4. For Codex, ship an optional silent hook adapter using common hook `session_id`
   and `model` fields. Do not assume an undocumented environment-publication
   feature. Write a context file indexed by harness/session, allowing tasks to
   find it using the already exported session ID. Hook subagents can report a
   parent session ID; retain supplied agent ID separately and never invent one.
   Do not publish subagent model context over a parent session's model record.
5. Context files are per session under a private client configuration directory,
   written atomically. No shared "current session" file. Validate schema, size
   (at most 16 KiB) and matching session before reading. Concurrent sessions
   cannot overwrite each other's context. A hook can publish a private pointer
   via `TASKS_CONTEXT_FILE`; this is setup/inherited environment, not per-call AI
   arguments. Return no additionalContext or routine stdout to the model.
   Store agent/execution contexts separately when the harness exposes a matching
   identity or an inherited pointer. If an invocation cannot distinguish a
   parent session from concurrent agents, leave its model/agent fields null;
   the latest session-wide hook file is not evidence of that invocation's model.
6. Inspect at most eight process ancestors through native Rust platform support,
   bounded to 100 ms in total. Use OS process IDs/start times to detect exited
   or reused parents. Shell wrappers mean the direct parent may be pwsh/bash;
   walk upward for codex/claude/viewer. A generic node/python ancestor is not
   enough to identify a harness. Permissions/timeouts yield unavailable fields
   and never block a valid mutation. No WMI subprocess, full process inventory,
   executable arguments, environment dump or transcript scan per call.
   Accepted Windows behavior (2026-10-05): leave `caller_executable` and
   `harness_executable` null; do not add a native wrapper exception to the
   no-unsafe rule. Linux retains the bounded ancestor walk. Environment and
   matching hook context still supply the Windows harness/session fields.
7. If metadata cannot be obtained, retain null values and `unknown` harness
   when origin is inconclusive. `manual` requires a direct known terminal/GUI
   context, not merely absent session variables. Do not use a global configured
   model as evidence of the current invocation's model. Session names remain
   optional; do not derive names by reading prompt content.

Hook configuration is an explicit one-time integration step. Ship examples and
a previewable setup helper; do not rewrite user harness settings automatically.
Windows/WSL installations may be registered under the same physical machine
name while retaining distinct installation IDs and credentials.

### Docker, migration and recovery

Provide a multistage Dockerfile, a Compose example and a QNAP Container Station
runbook. Run as a configured non-root UID/GID, with a read-only root filesystem,
writable `/data` and a bounded temporary directory. Keep LAN TLS certificate
inputs under gateway management and tunnel credentials in the existing connector.
Provide credential provisioning inputs only to their owning component. Image
contains no secrets or task data.
No privileged mode or Docker socket mount. Set restart policy and graceful-stop
timeout explicitly. Retain the existing Windows x64 and native Linux x64 builds;
build the server image for the verified `linux/amd64` NAS and execute its smoke
proof there. Recheck the recorded NAS and Container Station versions at deployment.

Migration rehearsals preserve project UUIDs/keys, task IDs, counters, versions,
descriptions, dependencies, imports and existing event IDs/snapshots. Use SQLite
online backup or quiesced verified copies, never copy only a live main DB file.
Back up the server catalog/auth database as well as project databases. Keep
machine-local bindings separate. Export evidence of counts, hashes, integrity,
foreign-key checks and selected exact task/history comparisons on copies.

At real cutover, explicitly stop local writers, take final verified backups,
install the server copy and configure clients for remote access. Retain local
snapshots read-only for rollback; do not continue two writable authorities for
one project UUID. Before server writes, rollback can restore the old profile.
After server writes, first quiesce the server and take its verified current
backup; reverting to an older local snapshot would lose those writes. Restore
only with explicit selection of the authoritative data.

### Risks and execution prerequisites

| Item | Required condition / check | Owner | Dependent slices |
|---|---|---|---|
| Signing profile through proxies | Verify the specified signed components, body digest, persistent replay protection and key revocation through both routes. | Implementer/operator | 3 and deployment proof in 7 |
| QNAP architecture/runtime | Recheck verified x86_64 platform/QTS/Container Station; run linux/amd64 image on NAS-local volume. | Operator | 7 |
| TLS identity and routing | Supply LAN/public DNS names, matching trusted LAN certificate and Cloudflare route; verify both paths with strict client hostname checks. Existing QNAP certificate is insufficient. | Operator | 7 and real deployment |
| Backend isolation | Publish no backend port; configure private gateway/tunnel network access and prove backend HTTP unreachable from another LAN machine on the installed Docker version. | Operator | 7 and real deployment |
| Client registration | Create actor/client credentials once with private storage and revocation proof. | Operator | 5 and real deployment |
| Clock synchronization | Keep client/NAS UTC synchronized within the specified signature window; verify clock errors and recovery. | Operator | 7 and real deployment |
| Installed hook support | Verify Codex/Claude Code versions and silent context collection for supported shells; missing fields remain null. | Implementer | 2 |
| Live migration | Explicitly selected projects, backups and a quiesced cutover. | User/operator | Real deployment only |

### Validation strategy

All commands here describe planned proof. Every test supplies a unique temporary
data root and synthetic keys/certificates. No production store, private key,
harness settings or installed global binary is modified for tests. Build release
candidates into `target/server-candidate`, not the installed release target.

Run focused slice proofs first. After slices 1-5 stabilize, perform one local
correctness/security review, then one batch of Windows and native Linux fmt,
clippy and test checks with `--features server`. After slices 6-7, perform one
final batch on the frozen complete candidate with those same checks, release
builds and Docker/two-client proof. Total broad checkpoints: two, project-wide
cost; QNAP runtime proof is a separate deployment prerequisite. Retain logs and
candidate hashes under ignored `target/evidence/`. A passing Windows build or
ARM cross-build is not native Linux/NAS runtime proof.

Final Rust commands: `cargo fmt --check`,
`cargo clippy --locked --all-targets --features server`,
`cargo test --locked --features server`,
`cargo build --release --locked --features server --target-dir target/server-candidate`.
Linux uses its own Linux-owned Cargo target directory and temporary databases.
Schedule the existing viewer broad gate once for the final viewer candidate if
its production sources or bundled CLI change. Do not repeat broad gates per task.

### Implementation slices

The following test targets and modules are proposed additions. The existing
tests and local store behavior must remain compatible.

#### Slice 1: Persist attribution with every mutation

- Touches: src/model.rs, src/store.rs, migrations/, history/output, proposed
  tests/attribution.rs. Reviewer lens: transaction and migration integrity.
- Outcome: versioned nullable legacy attribution, new context on every mutation
  path, metadata events for project/key changes, unchanged no-op/conflict behavior,
  history rendering and complete audit backup recovery.
- Proof: from repo root, `cargo test --locked --test attribution` with an explicit
  unique fixture root supplied by that test harness. Expect nonzero selected
  cases covering migration, task/rules/key/import and rollback, all pass; a
  refused write leaves task, version and event count unchanged.

#### Slice 2: Collect context automatically and integrate hooks

- Deps: slice 1. Touches: proposed attribution module, interop context envelope,
  integration hook examples/setup preview, proposed tests/attribution_detection.rs.
  Reviewer lens: attribution accuracy, privacy and invocation cost.
- Outcome: OS machine/account, bounded caller ancestry, Codex environment and
  concurrent per-session hook context feed writes without per-call arguments;
  viewer/manual, WSL origin and missing/model-changed contexts remain accurate.
- Proof: `cargo test --locked --test attribution_detection`. Expect nonzero
  selected cases including two simultaneous sessions and stale/wrong context,
  all pass. Manual: start isolated Codex and Claude Code sessions with previewed
  adapters and temporary profile roots; issue ordinary task writes, including a
  model switch. Compare resulting history with hook payloads, ensure no metadata
  arguments or hook additionalContext entered the conversation.

#### Slice 3: Establish proxy HTTPS and authenticated server ownership

- Deps: slice 1. Touches: proposed server transport/auth modules, Cargo feature
  and binary, server auth migrations, proxy fixture/config and proposed
  tests/server_transport.rs.
  Reviewer lens: authorization, secret handling and resource ownership.
- Outcome: configured proxy HTTPS route to private Rust HTTP and authenticated
  info, credential
  provisioning/revocation with admin audit, capacity bounds and exclusive data-root
  ownership satisfy the security and operational contracts.
- Proof: `cargo test --locked --features server --test server_transport`. Expect
  nonzero cases covering valid/private-CA TLS, wrong-host/expired/untrusted TLS,
  missing/revoked keys, tampered signed fields/body, wrong server UUID,
  expired/future signatures, duplicate nonces including after restart,
  replay capacity, fresh-signature reconciliation, key-file permissions, actor
  spoofing, operation capacity and second-server exclusion, all pass.

#### Slice 4: Serve shared task operations and recover duplicate requests

- Deps: slices 1 and 3. Touches: proposed application/HTTP modules,
  project receipts/catalog recovery and proposed tests/server_api.rs.
  Reviewer lens: concurrent transaction behavior and crash recovery.
- Outcome: specified API reuses local rules and authenticated identity;
  concurrent version checks and atomic idempotency receipts prevent duplicate
  mutations, explicit creation and crash recovery preserve catalog ownership.
- Proof: `cargo test --locked --features server --test server_api`. Expect nonzero
  cases covering task/rules/key operations, malformed/oversized queries, stale
  writes, conflicting receipt payloads, response loss/replay, competing creates
  and interrupted catalog publication, all pass.

#### Slice 5: Route the CLI through the remote profile

- Deps: slices 2 and 4. Touches: src/cli.rs, src/main.rs, registry/interop, proposed
  remote transport/config module and tests/remote_cli.rs. Reviewer lens: compatibility.
- Outcome: ordinary CLI commands and errors work remotely, explicit setup stores
  private credentials, local and WSL profiles obey routing rules, reconciliation
  recovers unknown write outcomes, outage never opens a local database.
- Proof: `cargo test --locked --features server --test remote_cli`. Expect real
  subprocess cases with two client roots and a temporary TLS server all pass;
  outage leaves a poisoned leftover local database byte-identical; recovered
  response loss creates exactly one task/version increment/event.

#### Slice 6: Preserve viewer flows through the remote CLI

- Deps: slice 5. Touches: src/viewer.rs and owning viewer data/reconciliation
  surfaces only where required; proposed tests/remote_viewer.rs and
  viewer/test/remote/remote_cli_flow_test.dart. Reviewer lens: accessible recovery.
- Outcome: remote catalog, selection, history and writes retain current CLI JSON;
  blocked completion, attribution display, outage feedback and pending-write
  reconciliation work without a direct viewer HTTP client.
- Proof: `cargo test --locked --features server --test remote_viewer` and, from
  viewer/, `flutter test test/remote/remote_cli_flow_test.dart`. Expect nonzero
  selected cases all pass, including response loss and clear outage feedback.
  Manual: isolated packaged viewer/NVDA fixture verifies spoken service failure,
  stable focus and successful retry/reconciliation after server restoration.

#### Slice 7: Package for QNAP and rehearse data cutover

- Deps: slices 3-6. Touches: proposed Dockerfile, compose.yaml, server runbook and
  synthetic migration/container proof helper. Reviewer lens: operational recovery.
- Outcome: non-root container retains all data across restart; TLS/auth secrets
  remain outside image; backup/restore rehearsal preserves exact project history;
  NAS architecture/runtime, both HTTPS routes, proxy TLS provisioning and LAN
  backend isolation checks are explicit. Public and LAN clients reach the same
  server identity and enforce the same credential revocation.
- Proof: proposed `python integration/verify_server_container.py --fixture-root
  <new-empty-absolute-directory>` drives the built candidate with two client
  profiles, synthetic TLS/auth and a NAS-local container volume. Expect nonzero
  named cases, all pass: LAN/public endpoint authentication, direct backend
  isolation, concurrent edits, revoke on both routes, restart, response-loss recovery,
  backup/restore and exact UUID/task/version/event comparisons. Repeat the
  container smoke procedure on the actual NAS before claiming QNAP support.

### Review disposition and handoff

A local architecture/operator challenge pass found and incorporated these defects:
viewer-inherited harness variables could misattribute manual changes; a lost
write acknowledgement could duplicate work; two machines could keep separate
writable copies after cutover; project creation spans catalog and project storage;
and a shared current-session/model file would mix concurrent sessions or agents.
The contracts above address each, including nullable model attribution when the
execution identity cannot be matched. Server transport/auth and application
transactions are separate slices with distinct focused proof. No independent
review or implementation proof is claimed.

Canonical artifact: spec.md, this section. Readiness: Ready for implementation.
The user accepted application-level key authentication on both access routes.
NAS architecture and existing reverse proxy are verified;
dual-route DNS/TLS provisioning, backend isolation and client registration remain
execution prerequisites. Exact crate versions remain
implementation selections. Begin with
the [implementation slices](#implementation-slices), using rust-engineering,
rust-testing and resolve-task when slices have durable task records. Offline
writes, remote bulk import and richer access policies remain excluded. Deployment
and live-project migration require their own concrete rollout authorization.

Primary references checked 2026-10-02: [Axum](https://docs.rs/axum/latest/axum/),
[rustls](https://docs.rs/rustls/latest/rustls/),
[Docker volumes](https://docs.docker.com/engine/storage/volumes/),
[QNAP Container Station](https://www.qnap.com/en/software/container-station),
[Codex hooks](https://developers.openai.com/codex/hooks),
[Claude Code hooks](https://code.claude.com/docs/en/hooks).
