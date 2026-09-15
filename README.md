# tasks-cli

`tasks-cli` is a synchronous Rust command-line client for one SQLite backlog per
project UUID. It has no daemon, server, ORM, or network dependency. Windows and
native Linux own separate storage roots. WSL access to a Windows backlog is
delegated to the Windows executable; the Linux process never opens that SQLite
file.

## Build and install

Rust stable, Cargo, and a C compiler suitable for the bundled SQLite build are
required.

```text
cargo fmt --check
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo test --locked
cargo test --locked -- --test-threads=1
cargo build --release --locked
```

The release executable is `target/release/tasks.exe` on Windows and
`target/release/tasks` on Linux. Copy the executable to a directory on
`PATH`, or invoke it by its absolute path. Do not replace an executable that is
currently in use.

## Storage and routing

Windows stores data below `%LOCALAPPDATA%\MaxLogic\tasks-cli`; native Linux
stores it below `$XDG_DATA_HOME/MaxLogic/tasks-cli` or
`$HOME/.local/share/MaxLogic/tasks-cli`. Pass `--data-root PATH` in tests or
when an isolated root is needed. The registry is `registry.json`; each project
database is `projects/<UUID>/TASKS.sqlite`.

Create and bind a project from a workspace:

```text
tasks --data-root "D:\Task Data" init --root "D:\Work\Project"
tasks --data-root "D:\Task Data" bind --root "D:\Work\Project\subdir" --project UUID
tasks --data-root "D:\Task Data" --project UUID doctor
```

Without `--project`, the Windows registry selects the longest registered
ancestor of the current directory. `TASKS_PROJECT` is the environment default;
an explicit flag wins over it. An unknown directory fails and does not create a
database.

## Daily use

```text
tasks list [--status backlog] [--after 20] [--limit 20]
tasks search "release notes"
tasks show T-12
tasks create --title "Write release notes" --body-file notes.md
tasks update T-12 --expect-version 1 --status ready
tasks update T-12 --expect-version 2 --clear-deps
tasks history T-12
tasks rules show
tasks rules set --body-file RULES.md --expect-version 1
```

`list` and `search` return bounded summary rows without bodies. `show` returns
the complete title/body, direct dependency IDs, version, and shared rules. A
write must supply the expected version; a stale version returns exit code 4.
IDs are rendered as `T-001` and accept both `T-1` and `T-001`.

Use `--format json` for the versioned output envelope. The command-specific
payload is under `data`; errors go to stderr and preserve the documented exit
codes.

The global options `--data-root`, `--project`, `--format`, and
`--windows-exe` may appear before or after the subcommand. Page limits must be
between 1 and 100.

## Import and export

```text
tasks --project UUID import --file TASKS.md
tasks --format json --project UUID import --file TASKS.md --map-file sections.json
tasks --project UUID import --file TASKS.md --map-file sections.json --apply --expect-sha256 HASH_FROM_PREVIEW
tasks --project UUID export --out TASKS-export.md
```

Import is preview-only unless `--apply` is present. Apply requires an empty
task/rules store and the exact SHA-256 returned by preview. It re-reads the
source immediately before mutation, validates exact status sections or an
explicit map, preserves the original source bytes and SHA-256, and commits
tasks, dependencies, rules, events, and provenance together. Repeating an
identical import is a no-op. Unknown source ranges, duplicate IDs, invalid
mapping values, and changed source content block apply without partial data.
Export is deterministic and human-readable, but the SQLite backup is the exact
recovery authority. It includes a snapshot warning, project UUID, rules,
versions, dependency IDs, and complete bodies.

The importer recognizes the exporter metadata block in this order:
`Status:`, `Version:`, `Depends on:`, `Body:`. An optional leading `Title:` is
accepted only as part of that block. For compatibility, the older ordered
`Status:`, `Depends on:`, `Body:` form and an exact standalone `Body:` marker
are also accepted. `Body:` ends metadata and everything after it is body text.
A body line beginning with a metadata label is therefore preserved unless an
ordered metadata form is present.
Tasks before the first level-two section are reported as `<no section>` and
block apply; a map may explicitly assign that pseudo-section when such input
is intentional.

## Backup and recovery

```text
tasks --project UUID backup --out "D:\Backups\project.sqlite"
tasks --project UUID doctor
```

Backup uses SQLite's online backup API, validates `quick_check`, writes an
exclusively created temporary file beside the destination, checks foreign-key
integrity, schema version, and project UUID, and refuses to overwrite an
existing destination. Backup/data roots must be owned by the current OS; native
Linux rejects /mnt/<drive> and UNC/remote roots rather than opening a
Windows-owned SQLite file. To recover, validate a backup in a new isolated data
root, then recreate the registry entry with init/bind; there is no in-place
destructive restore command.

## WSL delegation

Point Linux `tasks` at the Windows executable:

```bash
tasks --windows-exe /mnt/c/Tools/tasks.exe --project UUID show T-12
TASKS_WINDOWS_EXE=/mnt/c/Tools/tasks.exe tasks list
```

The Linux wrapper converts filesystem-valued arguments with `wslpath -w`,
preserves stdin/stdout/stderr and the child exit code, and does not fall back to
native Linux storage if the Windows executable cannot start. With neither an
explicit project nor `TASKS_PROJECT`, it translates the current directory and
lets the Windows registry resolve the closest registered ancestor. An unknown
directory fails without creating a Linux or Windows backlog. Native Linux
commands without delegation use Linux-owned storage only.

## Tests and known limits

The integration targets cover routing/init contention, selective reads,
transactional mutations, Markdown preservation, migration/backup recovery,
history/dependency/output contracts, and WSL interop. They use real temporary
SQLite stores and subprocesses for contention, exit codes, stdin, backup
recovery, and crash rollback. Live project TASKS.md files are not modified by
the test suite.

Known v1 limits are deliberate: no hard-delete command, no automatic migration
of a live project, no automatic backup retention policy, and no full-fidelity
authority claim for Markdown export. Native Linux and Windows databases must
not be opened concurrently across the OS boundary; use WSL delegation for the
shared Windows backlog.
