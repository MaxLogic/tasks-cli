# tasks-cli

A shared task backlog for coding agents and the architect who coordinates them.

`tasks` keeps one SQLite task list per project. The database lives outside the
working tree and is keyed by a project UUID, so switching branches, adding a
worktree or re-cloning the repository leaves the backlog untouched. Every write
states the task version it read, and a stale write fails instead of
overwriting someone else's change.

The CLI stores and queries work. It does not call an LLM or run task bodies.
The agent workflow around it lives in the bundled [skills](integration/README.md).

## Why use it

- **One backlog across sessions, branches and worktrees.** A small `.tasks.json`
  in the project root selects the backlog from any nested directory.
- **No silent overwrites.** Updates carry `--expect-version`; a conflict exits
  with code 4 and the caller decides what to do. There is no automatic retry.
- **Cheap reads for agents.** `list` and `search` return bounded summary rows.
  `show` returns complete text only for the tasks you ask for.
- **A full audit trail.** History is append-only. Each event keeps the task
  snapshot, the changed fields and the available context about who made the change.
- **Implementation separate from acceptance.** `to-verify` marks work waiting for
  a verification gate; the `needs-human` label marks decisions for the user.
- **Local first.** A local CLI needs no account, server or runtime beyond the
  executable. An optional self-hosted HTTPS server provides shared access
  across machines.
- **A Windows viewer** for reading and editing tasks, with keyboard navigation,
  conflict handling, saved drafts and screen-reader support.

Coordination is the architect's job: it assigns bounded tasks to workers. The
tool has no built-in assignee or task lease.

## Install

The CLI runs on Windows x64 and Linux x64; the viewer runs on Windows 11 x64.
macOS has not been built or tested. Portable packages contain everything needed
at runtime, including SQLite and, for the viewer, its Flutter runtime and a
matching CLI.

See [installation](installation.md) for checksum verification, PATH setup,
building from source and a first-run example.

## Quick tour

```text
tasks init --root "D:\Work\Project" --key APP
cd "D:\Work\Project"
tasks create --title "Write release notes" --body-file notes.md --status todo
tasks list
```

```text
APP-001	P2	todo	v1	Write release notes
has_more: false
```

`show` prints the full text and whatever the task is waiting on:

```text
$ tasks show APP-2
id: APP-002
status: draft
priority: P2
version: 1
depends_on: APP-001	todo	v2	Write release notes
title:
Tag the release
body:
Ship it.
```

The project key (2-6 letters or digits, starting with a letter) is chosen at
`init` and can be changed later with `tasks project-key --set NEW`. Input accepts
`APP-1`, `app-001`, a bare `1` and the legacy `T-1` form for the same task.

For an isolated trial with an architect supervising two worktrees, follow
[the architect walkthrough](integration/architect-workflow.md).

## Everyday commands

```text
tasks list [--open] [--needs-human] [--label perf] [--limit 20] [--after CURSOR]
tasks search "release notes" [--ranked] [--prefix]
tasks show APP-12 APP-13 --rules
tasks create --title "Fix login" --body-file task.md --status todo --priority P1 --labels security
tasks update APP-12 --expect-version 3 --status in-progress --add-label needs-human
tasks history APP-12 [--event 42]
tasks unlocks --limit 20
tasks rules show
tasks rules set --body-file RULES.md --expect-version 1
tasks attachment add APP-12 --expect-version 4 --file run.log
tasks attachment get APP-12 A1 --out saved.log
tasks enrich --file response.txt
```

Global options (`--data-root`, `--project`, `--format`, `--windows-exe`) work
before or after the subcommand. Bodies are read from a file, or from standard
input with `-`. Pages hold 1 to 100 rows; pass the `next_after` cursor from one
page unchanged to `--after` for the next.

### Statuses and picking work

Statuses are `draft`, `todo`, `in-progress`, `to-verify`, `blocked`, `done` and
`cancelled`. Priority runs from P0 (most urgent) to P3; the default is P2.

Plain `list` shows runnable work: `todo` and `in-progress` tasks whose
prerequisites are `done` or `to-verify`, excluding `needs-human`, ordered by
priority and then ID. `--open` shows every unfinished task. `--status` bypasses
readiness. `unlocks` ranks open prerequisites by how much work finishing them
would release.

Marking a task `done` requires every prerequisite to be `done` or `cancelled`,
so a group that is waiting in `to-verify` gets completed in dependency order.

### Search

Plain `search` matches literal substrings in titles and bodies. `--ranked` uses
SQLite FTS5 word search, weights title matches above body matches and treats the
query as literal terms rather than FTS operators. `--prefix` matches word
beginnings. Matching is lexical: no typo correction, synonyms or embeddings.

### History

`history --format json` lists events with their `resulting_version` and
`changed_fields`. `--event ID` returns that event's complete task snapshot.
Reading an old snapshot does not restore it.

### Attachments

Tasks can carry files of any type. Adding or detaching an attachment checks the
task version and records an audit event; detached bytes remain in history.
`attachment get` verifies size and SHA-256 and writes a local file, then prints
its path. It never prints file contents to the terminal. Files can also come
from the clipboard (`attachment clipboard`, then `add --clipboard`).

Limits: 20 MiB per compressed file, 32 attachments or 50 MiB per task, and
1 GiB of unique stored bytes per project.

### Enrich references

`tasks enrich` turns `APP-001` into `APP-001 (Task title)` in plain text, which
helps when reading agent output. References to other projects under the same
data root resolve read-only by their key. Unknown IDs stay unchanged and are
reported on stderr. `enrich-clipboard` does the same to clipboard text.

## Version checks and exit codes

```text
$ tasks update APP-1 --expect-version 1 --status done
version conflict: expected 1, current 2
$ echo $?
4
```

Read the task again, decide what the other change means for yours, then retry
with the current version.

| Code | Meaning |
| --- | --- |
| 0 | Success, including an empty list |
| 2 | Usage or validation error |
| 3 | Project or task not found |
| 4 | Version conflict or another conflict |
| 5 | Lock timeout, busy database or remote service failure |
| 6 | I/O, database or schema failure |

Errors go to stderr and name a recovery action. A mutation is printed only
after it commits, so if stdout breaks after `create`, the task exists; check
before repeating the command. Limits are 1 MiB per body, 500 characters per
title and 256 KiB of shared rules, with no partial writes.

## JSON output

`--format json` wraps every result in a versioned envelope on one line. The
payload sits under `data`; errors and exit codes behave as in text mode.

```json
{
  "schema_version": 1,
  "project_id": "3a785d75-2e1c-4351-80e3-8ba9e7fab992",
  "data": {
    "command": "show",
    "id": 2,
    "display_id": "APP-002",
    "status": "draft",
    "priority": "P2",
    "version": 1,
    "title": "Tag the release",
    "body": "Ship it.\n",
    "labels": [],
    "dependency_summaries": [
      { "id": 1, "status": "todo", "version": 2, "title": "Write release notes" }
    ]
  }
}
```

## Project selection and storage

You rarely pass `--project`. The CLI resolves the project in this order:
explicit `--project`, `TASKS_PROJECT`, the nearest `.tasks.json` found by walking
up from the current directory, then the longest registered ancestor path. An
unknown directory fails rather than creating a second backlog.

A `.tasks.json` holds only the project UUID, so it travels with Git worktrees.
Monorepos can give each subproject its own file with
`tasks init --root <subdirectory> --key KEY`. The file may be a symlink, for
example into a private overlay. See [project identity files](docs/project-identities.md)
for the validation rules.

```text
tasks bind --root "D:\Work\Project\subdir" --project UUID
tasks --project UUID doctor
```

Data lives under `%LOCALAPPDATA%\MaxLogic\tasks-cli` on Windows and under
`$XDG_DATA_HOME/MaxLogic/tasks-cli` (or `~/.local/share/MaxLogic/tasks-cli`) on
Linux. Each project database is `projects/<UUID>/TASKS.sqlite`. `--data-root`
selects an isolated root, which is what the tests use.

## Windows and WSL

Windows and native Linux keep separate storage, and one live database is never
opened from both. To use the Windows backlog from WSL, delegate to the Windows
executable:

```bash
TASKS_WINDOWS_EXE=/mnt/f/Tools/tasks.exe tasks list
tasks --windows-exe /mnt/f/Tools/tasks.exe show APP-12
```

The Linux CLI converts path arguments with `wslpath`, passes stdin, stdout,
stderr and the exit code through, and never falls back to Linux storage if the
Windows executable fails to start. A native Linux run refuses `/mnt/<drive>` and
remote data roots.

## Remote server

Remote profiles send signed HTTPS requests to `tasks-server`, which owns the
project databases. Remote writes keep request receipts, so a lost reply can be
reconciled instead of repeated. Remote access needs the server online, and local
maintenance commands (`import`, `bulk-import`, `backup`, `migrate`, `doctor`) are
refused against a remote profile.

- [Remote CLI setup and recovery](integration/remote-cli.md)
- [Server administration](integration/server-core.md)
- [Server backup and recovery](integration/server-cutover.md)

## Importing a Markdown backlog

```text
tasks --project UUID import --file TASKS.md
tasks --project UUID import --file TASKS.md --map-file sections.json --apply --expect-sha256 HASH_FROM_PREVIEW
tasks --project UUID export --out TASKS-export.md
```

Import previews by default. Apply requires the SHA-256 printed by the preview
and an empty project, re-reads the source before writing and commits tasks,
dependencies, rules, history and source provenance in one transaction. Unknown
sections, duplicate IDs or a source that changed since the preview stop the
apply with nothing written. Running the same import twice is a no-op.

Export writes a deterministic Markdown snapshot that the importer reads back.
It is for reading and review. The SQLite backup is the recovery authority.

## Backup, restore and migration

```text
tasks --project UUID backup --out "D:\Backups\project.sqlite"
```

Backup uses SQLite's online backup API, validates the result (integrity,
foreign keys, schema version and project UUID) and never overwrites an
existing file.

There is no in-place restore command. To recover, stop task clients and restore
into an isolated data root:

```text
mkdir D:\Recovery\projects\UUID
copy D:\Backups\project.sqlite D:\Recovery\projects\UUID\TASKS.sqlite
tasks --data-root D:\Recovery --project UUID doctor
tasks --data-root D:\Recovery bind --root D:\RecoveredWorktree --project UUID
```

Do not run `init` here; it creates a new project identity.

Schema upgrades are never implicit. `tasks migrate` takes and validates a fresh
backup first, prints its path and keeps every earlier one. Older binaries refuse
databases newer than they support.

## Building from source

`rust-toolchain.toml` pins the Rust toolchain, so rustup installs the right
version. You also need a C compiler for the bundled SQLite.

```text
cargo fmt --check
cargo clippy --locked --all-targets --features server
cargo test --locked
cargo test --locked --features server
cargo build --release --locked --bin tasks --target-dir target/public-build
```

Add `--features server --bin tasks-server` for a server build. `tasks --version`
prints the package version and the Git commit it was built from. Windows and
Linux each need a native build and test run; a cross-compile is not proof that
the Linux binary works. [Installation](installation.md) covers Linux target
directories, and [release maintenance](release/README.md) covers packaging.

## Verification

Tests use real temporary SQLite databases and real subprocesses for contention,
exit codes, standard input, backup recovery and crash rollback. They never touch
the default task store or live Markdown ledgers.

Recorded results, each tied to its own candidate and environment:

- [CLI verification report](verification-report.md)
- [Server verification](integration/server-refactor-progress.md)
- [Viewer verification](viewer/verification-report.md)

## Deliberately out of scope

- Hard delete. History is append-only.
- Automatic migration of a live project.
- Retention of pre-migration backups. They accumulate until you remove them.
- Full-fidelity Markdown export. Use the SQLite backup for recovery.
- Opening one database from both Windows and native Linux. Use WSL delegation.

[`spec.md`](spec.md) is the normative contract behind all of the above.

## License

The source is licensed under [MIT](LICENSE). Dependencies and bundled audio keep
their own terms; audio provenance is recorded with the viewer assets.
