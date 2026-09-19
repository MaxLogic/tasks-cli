# SQLite skill development copies

These files are development candidates, not installed skills. No live backlog
has been migrated and no real repository `.tasks.json` is created by this work.
The example UUID is illustrative and must not be used for setup.

Install/evaluate the three sibling skill directories together to preserve their
relative links. `task-ledger` owns access and identity; `create-task` owns task
formulation; `resolve-task` owns implementation and proof. Python here only
resolves identity and invokes the Rust CLI. It never reads SQLite or maintains
Markdown task state. Older Markdown skill copies remain unchanged.

## Explicit project setup

Setup is a separate authorized operation. For an existing project, obtain and
verify its UUID from the existing tasks registry/CLI output. For a genuinely new
project, run authorized `tasks init --root <absolute-project-root>` and retain
the returned project UUID. Do not generate a UUID independently.

Create root `.tasks.json` with only `{"project_id":"<returned-project-uuid>"}`,
using lowercase canonical UUID text, and commit it as project configuration.
The schema is [project-identity.schema.json](project-identity.schema.json).
The file contains identity only, never machine-specific database paths.
Review its changes like other project configuration. A copied UUID selects that
same backlog; forking a repository does not implicitly create a new project.

Git worktrees inherit the tracked identity. From any nested directory run:

```text
python -B <skill-root>/task-ledger/scripts/task_project.py --cwd <directory> -- list --limit 30
```

The wrapper requires a tracked identity, rejects malformed/unknown projects,
validates through `rules show`, and passes `--project` explicitly. It does not
need a registry path binding for each worktree. Missing identity is a setup
failure, not permission to initialize storage. Direct CLI CWD selection remains
unchanged; this first integration deliberately resolves identity in the skill.
Outside Git, including SVN projects, the nearest ancestor `.tasks.json` defines
the task project boundary. Create/version that file through the project's own
authorized setup workflow. The wrapper stops on an invalid nearer identity,
and never searches past it for a usable outer project. Git projects require
their root identity and cannot fall back to an ancestor outside the repository.

For WSL Windows-owned storage, pass `--windows-exe /mnt/c/.../tasks.exe` to the
wrapper if required by the Linux CLI's delegation setup. Keep data ownership
and path conversion in the existing Rust CLI. A Linux-owned synthetic store is
valid for native Linux tests; never point Linux SQLite directly at the shared
Windows database.

## Verification

```text
python -B -m unittest discover -s integration/tests -v
```

`TASKS_TEST_EXE` may select the real binary under test. The default is the
repository's Windows release binary. Tests initialize only an explicit unique
temporary data root, commit an identity fixture, create a real detached Git
worktree, read the same project from nested paths, and reject unsafe identity.
They clean only their unique temporary directory and remove the test worktree
through Git. They do not use the user's default store.

See [evaluation.md](evaluation.md) for provenance, strengths retained and the
limits of the workflow evaluation.
