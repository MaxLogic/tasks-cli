# tasks-cli

A backlog that lives next to your project instead of inside it.

`tasks` keeps one SQLite task list per project, stored outside the working tree
and keyed by a project UUID. Switch branches, add a worktree, or wipe and
re-clone, and the backlog stays exactly where it was. Reads are bounded, so
`list` and `search` hand back summary rows without dragging every task body
along with them. Writes carry a version check, so two agents working the same
backlog cannot silently overwrite each other.

It is one synchronous executable. No daemon, no server, no ORM, no network. One
connection per command, then it exits. Multi-query reads use a single WAL
snapshot, so concurrent changes cannot mix task versions, rules and dependencies
in one response. Export renders after releasing that snapshot and publishes
without overwriting a competing file.

The bundled engine is SQLite 3.53.2 through rusqlite 0.40.2. This is the engine
in the current crate, not a claim to bundle the latest upstream SQLite patch.

## Sixty-second tour

```text
tasks init --root "D:\Work\Project"
tasks create --title "Write release notes" --body-file notes.md
tasks list
```

That gives you a project, a task, and a backlog you can read at a glance:

```text
project_id: 3a785d75-2e1c-4351-80e3-8ba9e7fab992
T-001	draft	v1	Write release notes	[]	labels=[]
has_more: false
```

`show` is where the full text lives, along with whatever the task is waiting on:

```text
$ tasks show T-2
id: T-002
status: draft
version: 1
labels:
dependencies: 1
depends_on: T-001	todo	v2	Write release notes
title:
Tag the release
body:
Ship it.
```

IDs render as `T-001` and accept either spelling on input, so `T-1` and `T-001`
reach the same task.

## Finding the right project

You rarely pass `--project`. From any directory inside a registered workspace,
the registry picks the longest registered ancestor and routes there. An
unregistered directory fails loudly instead of quietly creating a second
backlog.

```text
tasks init --root "D:\Work\Project"
tasks bind --root "D:\Work\Project\subdir" --project UUID
tasks --project UUID doctor
```

`TASKS_PROJECT` sets a default and an explicit `--project` beats it. That
variable and the hidden `--route-root` option are routing context for routed
project commands only. `init` and `bind` ignore both, native or delegated, and
follow their own binding contract instead.

Data lives under `%LOCALAPPDATA%\MaxLogic\tasks-cli` on Windows and under
`$XDG_DATA_HOME/MaxLogic/tasks-cli` or `$HOME/.local/share/MaxLogic/tasks-cli`
on Linux. The registry is `registry.json`, and each database is
`projects/<UUID>/TASKS.sqlite`. Pass `--data-root PATH` when you want an
isolated root, which is what the tests do.

## Everyday commands

```text
tasks list [--status draft] [--after 20] [--limit 20]
tasks search "release notes"
tasks show T-12
tasks create --title "Write release notes" --body-file notes.md
tasks update T-12 --expect-version 1 --status todo
tasks update T-12 --expect-version 2 --clear-deps
tasks history T-12
tasks rules show
tasks rules set --body-file RULES.md --expect-version 1
```

An agent can retrieve a previous task revision without loading the whole history:

```text
tasks history T-12 --format json
tasks history T-12 --event 42 --format json
```

The first command lists event IDs and `resulting_version`. Select the event for
the desired task version; the second returns its complete `snapshot_json`.
Event IDs and task version numbers are different. Reading an old snapshot does
not restore it or change the current task.

Statuses are `draft`, `todo`, `in-progress`, `blocked`, `done`, and
`cancelled`. Bodies come from a file, and `-` reads standard input. Page limits
run from 1 to 100, and `--after` continues from the cursor the previous page
reported. `rules` holds the shared text that every `show` returns beside the
task, which makes it the natural home for conventions that apply to the whole
backlog.

The global options `--data-root`, `--project`, `--format`, and `--windows-exe`
work before or after the subcommand, whichever reads better.

## Labels and ranked search

```text
tasks create --title "Review cache" --body-file task.md --labels performance,security
tasks update T-12 --expect-version 2 --labels performance,needs-human
tasks update T-12 --expect-version 3 --clear-labels
tasks list --label performance
tasks list --status blocked --label needs-human
tasks search "cache latency" --ranked --label performance --format json
tasks search "cach lat" --ranked --prefix --limit 20 --offset 20
```

Labels are trimmed, lowercased, sorted and deduplicated. Each task may have up to
32 labels, each 1–64 ASCII letters, digits or `-_.:` characters. `--labels` replaces
the complete set; omission preserves it. Label changes use the same version check
and history transaction as other task edits. `needs-human` is a workflow convention,
not a special state. Use `draft` for ideas needing brainstorming.

Plain `search` already supports literal title/body substrings. `--ranked` adds
SQLite FTS5 word search: all query terms must match; title matches receive more
weight than body matches. `--prefix` matches word beginnings. Query text is quoted
as literal terms, not interpreted as FTS operators. Ranked queries are limited to
64 whitespace-separated terms and 4096 UTF-8 bytes. This is lexical retrieval,
without typo correction, synonyms or embeddings.

Ranked results use `next_offset` and `--offset`, not the ID-based `--after` cursor.
Both search modes return bounded summaries and may include done/cancelled tasks.
Ordinary `list` excludes done/cancelled but still includes draft and blocked tasks.
Every page is internally consistent; changes between requests can move ranked
results, so restart pagination after relevant edits.

Existing databases require explicit `tasks migrate`: schema 3 adds labels and
builds the search index after a validated backup. Schema 1 states become
`draft`/`todo`; existing history snapshots remain unchanged. New databases start
at schema 3. No live project is migrated automatically.

## Every write says what it expects

There is no manual lock to take and no automatic conflict retry. You tell the tool which version you
read, and it refuses the write if the world moved:

```text
$ tasks update T-1 --expect-version 1 --status done
version conflict: expected 1, current 2
$ echo $?
4
```

Read the task again, decide what the other writer's change means for yours, then
send the write with the current version. The tool will not guess on your behalf.

Exit codes are stable and worth scripting against:

| Code | Meaning |
| --- | --- |
| 0 | Success, including an empty list |
| 2 | Usage or validation error |
| 3 | Project or task not found |
| 4 | Version conflict |
| 5 | Lock timeout or busy database |
| 6 | I/O, database, or schema failure |

Errors name a recovery action and go to stderr. Mutations commit before anything
is printed, so a broken stdout after a `create` means the task exists. Inspect
the state before repeating that command.

Input limits are enforced with no partial write: 1 MiB per body, 500 Unicode
characters per title, 256 KiB of shared rules. Invalid UTF-8 and empty titles
are rejected outright.

## JSON for the callers that need it

`--format json` wraps every command in a versioned envelope. The payload sits
under `data`, errors still go to stderr, and the exit codes above still hold.

```json
{
  "schema_version": 1,
  "project_id": "3a785d75-2e1c-4351-80e3-8ba9e7fab992",
  "data": {
    "command": "show",
    "id": 2,
    "status": "draft",
    "version": 1,
    "title": "Tag the release",
    "body": "Ship it.\n",
    "deps": [1],
    "labels": [],
    "dependency_summaries": [
      { "id": 1, "status": "todo", "version": 2, "title": "Write release notes" }
    ],
    "rule_version": 1,
    "rules": ""
  }
}
```

## Bringing a Markdown backlog across

```text
tasks --project UUID import --file TASKS.md
tasks --format json --project UUID import --file TASKS.md --map-file sections.json
tasks --project UUID import --file TASKS.md --map-file sections.json --apply --expect-sha256 HASH_FROM_PREVIEW
tasks --project UUID export --out TASKS-export.md
```

Import previews by default. Look at what it found, then apply with the exact
SHA-256 the preview printed. Reading the source from `-` previews fine but
cannot be applied, since apply has to re-read the file. Apply requires an empty task and rules store,
re-reads the source immediately before mutating, insists on exact status
sections or an explicit map, keeps the original bytes and hash as provenance,
and commits tasks, dependencies, rules, events, and provenance together. Run the
same import twice and the second run does nothing. Unknown source ranges,
duplicate IDs, invalid mapping values, and a source that changed between preview
and apply each stop the apply with no partial data left behind.

The importer reads the exporter's metadata block in this order: `Status:`,
`Version:`, `Depends on:`, `Body:`, with an optional leading `Title:` accepted
only as part of that block. The older ordered `Status:`, `Depends on:`, `Body:`
form and an exact standalone `Body:` marker still work. `Body:` ends the
metadata and everything after it is body text, which is how a paragraph that
happens to begin with `Version:` survives the trip intact. A leading UTF-8 BOM
counts as structural input: preview and JSON report `has_bom: true` while the
original bytes and source SHA-256 stay unchanged. Tasks sitting before the first
level-two section are reported as `<no section>` and block the apply until a map
assigns them somewhere on purpose.

Import preserves content and original-source provenance; boundary whitespace
and structural separators may be normalized.

For bulk migration, stop all workers and Markdown writers through apply,
verification and quarantine. A failed candidate cleans up only its newly created
artifacts. Successful candidates remain imported; there is no transaction across
all projects. Existing databases and their sidecars are preserved.

Export is deterministic and pleasant to read, and it carries a snapshot warning,
the project UUID, rules, versions, dependency IDs, and complete bodies. It is
not the recovery authority, though. The SQLite backup is.

## Backups, and the one honest way to restore

```text
tasks --project UUID backup --out "D:\Backups\project.sqlite"
tasks --project UUID doctor
```

Backup uses SQLite's online backup API, writes an exclusively created temporary
file beside the destination, then validates it: `quick_check`, foreign-key
integrity, schema version, and project UUID. It refuses to overwrite an existing
destination.

There is no in-place restore command, on purpose. To recover, validate the
backup in a new isolated data root, then recreate the registry entry with `init`
and `bind`. Nothing destructive reaches a live backlog by accident.

Every real schema migration takes a fresh pre-upgrade backup first, validates it,
and prints its path. The name carries the source version, a millisecond
timestamp, the process ID, and a counter, in the form
`TASKS.v<from>-pre-migrate-<unix-millis>-<pid>-<counter>.sqlite`, so a retried
migration never reuses or overwrites an earlier attempt's backup. Older ones are
kept, and pruning them is your call. A migrate that is already at the current
schema reports no backup path.

## Windows, Linux, and the line between them

Windows and native Linux own separate storage roots, and one live database must
never be opened from both sides. From WSL, point `tasks` at the Windows
executable and let it delegate:

```bash
tasks --windows-exe /mnt/c/Tools/tasks.exe --project UUID show T-12
TASKS_WINDOWS_EXE=/mnt/c/Tools/tasks.exe tasks list
```

The Linux wrapper converts filesystem-valued arguments with `wslpath -w`, passes
stdin, stdout, stderr, and the child exit code straight through, and never falls
back to native Linux storage when the Windows executable cannot start. Writing
to the wrong backlog would be worse than failing. With neither an explicit
project nor `TASKS_PROJECT`, it translates the current directory and lets the
Windows registry resolve the closest registered ancestor; an unknown directory
fails without creating a backlog on either side. Native Linux commands without
delegation use Linux-owned storage only, and a native Linux run rejects
`/mnt/<drive>` and UNC or remote roots rather than open a Windows-owned SQLite
file.

## Building it

The toolchain is pinned in `rust-toolchain.toml` to 1.98.1, so rustup fetches
the right one. You also need a C compiler suitable for the bundled SQLite build.

```text
cargo fmt --check
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo test --locked
cargo test --locked --features test-hooks --test bulk_rollback
cargo build --release --locked
```

The executable lands at `target/release/tasks.exe` on Windows and
`target/release/tasks` on Linux. Copy it to a directory on `PATH` or invoke it
by absolute path, and do not replace an executable that is currently in use.
Build the two platforms into separate Cargo target directories; a Windows build
is not Linux proof.

## Tests

The 2026-09-18 verification ran 155 tests on Windows and 157 on Ubuntu/WSL
with `cargo test --locked`. The separate feature-enabled bulk rollback regression
also passed on both platforms (`cargo test --locked --features test-hooks
--test bulk_rollback`). See [verification-report.md](verification-report.md) for
commands, logs and measured results. Coverage includes routing and init contention,
selective reads, transactional mutations, Markdown preservation, migration and
backup recovery, history, dependencies, output contracts, and WSL interop, using
real temporary SQLite stores and real subprocesses for contention, exit codes,
stdin, backup recovery, and crash rollback. Live project `TASKS.md` files are
never modified by the suite.

## What v1 deliberately does not do

- No hard delete. History is append-only and stays that way.
- No automatic migration of a live project.
- No backup retention policy. Pre-migration backups accumulate until you remove
  them.
- No claim that Markdown export is full fidelity. The SQLite backup is the
  recovery authority.
- No concurrent access to one database from Windows and native Linux. Use WSL
  delegation for a shared Windows backlog.

`spec.md` is the normative contract when you need the exact rule behind any of
this.

States, labels and ranked search are implemented. Priority, actionable-default
listing, unlock queries and shared skill integration remain proposals in
[workflow-proposal.md](workflow-proposal.md).
