# SQLite task skills

These three product-owned skills are deployed together so their sibling links
resolve to one workflow. `task-ledger` owns access and identity; `create-task`
owns task formulation; `resolve-task` owns implementation and proof. The example
UUID is illustrative and must not be used for setup.

Install/evaluate the sibling directories together. The Rust CLI discovers the
nearest `.tasks.json`; no skill reads SQLite directly or maintains Markdown task
state.

## Explicit project setup

Setup is a separate authorized operation. For an existing project, obtain and
verify its UUID from the existing tasks registry/CLI output. For a genuinely new
project, run authorized
`tasks init --root <absolute-project-root> --key KEY` and retain the
returned project UUID. Do not generate a UUID independently.

The command creates root `.tasks.json` with only
`{"project_id":"<returned-project-uuid>"}`, using lowercase canonical UUID
text. Commit it as project configuration.
The schema is [project-identity.schema.json](project-identity.schema.json).
The file contains identity only, never machine-specific database paths.
Review its changes like other project configuration. A copied UUID selects that
same backlog; forking a repository does not implicitly create a new project.

Git worktrees inherit the tracked identity. From any nested directory run:

```text
tasks --format json list --limit 30
```

The CLI validates the nearest identity and does not need a registry binding for
each worktree. An invalid nearer identity stops routing instead of falling back
to an outer project. Missing identity uses the existing registry binding only
for backward compatibility; migrated projects keep `.tasks.json` as their
portable identity.

For WSL Windows-owned storage, pass `--windows-exe /mnt/c/.../tasks.exe` or set
`TASKS_WINDOWS_EXE`. Keep data ownership
and path conversion in the existing Rust CLI. A Linux-owned synthetic store is
valid for native Linux tests; never point Linux SQLite directly at the shared
Windows database.

## Verification

```text
python -B -m unittest discover -s integration/tests -v
```

`TASKS_TEST_EXE` may select the real binary under test. The default is the
repository's native release binary (`tasks.exe` on Windows and `tasks` on
Linux). Set `CARGO_TARGET_DIR` when the checkout uses a separate Cargo target
tree, such as `target/linux` for WSL verification. Tests initialize only an
explicit unique temporary data root, commit an identity fixture, create a real
detached Git worktree, read the same project from nested paths, and reject
unsafe identity. They clean only their unique temporary directory and remove
the test worktree through Git. They do not use the user's default store.

See [evaluation.md](evaluation.md) for provenance, strengths retained and the
limits of the workflow evaluation.

For a first run, see [installation](../installation.md) and the
[architect-led worktree example](architect-workflow.md). The architect owns
assignment and lifecycle transitions; workers return changes and evidence.
The three skills express that workflow through the CLI. CLI operation does not
require installing the skills or an MCP server.
