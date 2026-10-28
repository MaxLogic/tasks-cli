# Try tasks-cli

Extract the whole archive. The executable uses bundled SQLite; no Rust SDK,
server or model API key is needed for local use.

On Windows x64, copy `tasks.exe` to a directory on your user PATH. Open a new
terminal and run `tasks --version`. On Linux x64, copy `tasks` to
`$HOME/.local/bin/tasks`, run `chmod +x "$HOME/.local/bin/tasks"`, and ensure
that directory is on PATH. Inspect an existing symlink before replacing it.
The Linux binary is built on Ubuntu 22.04 and requires glibc 2.35 or newer.

Choose an existing project directory, create `notes.md` with a task's scope
and acceptance criteria, and run:

```text
tasks init --root <absolute-project-directory> --key APP
cd <absolute-project-directory>
tasks create --title "Write release notes" --body-file notes.md --status todo
tasks list
tasks show APP-1
```

Replace the bracketed path. The default store is outside the checkout.
Commit the project identity `.tasks.json`, but keep databases and backups
outside Git. A project identity alone does not transfer a local backlog to
another machine.

For a disposable store and two workers supervised by one architect, follow
https://github.com/MaxLogic/tasks-cli/blob/main/integration/architect-workflow.md.
Every command there names a temporary data root.

In WSL, keep native Linux storage on the Linux filesystem. To access a
Windows-owned local store, set `TASKS_WINDOWS_EXE` to your Windows `tasks.exe`
path and let the Linux CLI delegate. Never open the same live SQLite database
from native Windows and native Linux processes.

Installation, backups and remote setup:
https://github.com/MaxLogic/tasks-cli/blob/main/installation.md.
The MIT license and dependency notices are included in this archive.
