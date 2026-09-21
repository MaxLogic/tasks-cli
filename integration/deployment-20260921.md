# Deployment record: 2026-09-21

## Executables

- Windows: `F:\CliTools\tasks.exe`
  - SHA-256: `f7acde2349697d97c560208da729a2ce93909167f8545c9659077a670d7a89d9`
- Ubuntu/WSL: `/home/pawel/.local/bin/tasks`
  - SHA-256: `4e71b0b7d71517e8365b2351fae151249eb4d9789de105ceab7408d34b385125`
- Both report `tasks 0.1.0 (commit 6e55a3a92a8f)` and were rebuilt from
  implementation commit `6e55a3a`.

`/home/pawel/.profile` exports
`TASKS_WINDOWS_EXE=/mnt/f/CliTools/tasks.exe`. This makes ordinary WSL commands
against projects under `/mnt/f/projects` delegate to the Windows binary instead
of opening the Windows-owned SQLite files from native Linux.

## Data

The 51 live databases and registry are physically stored under
`F:\projects\.tasks-cli-data`. The ordinary Windows path
`%LOCALAPPDATA%\MaxLogic\tasks-cli` is a directory junction to that location.
The prior empty store is preserved at
`%LOCALAPPDATA%\MaxLogic\tasks-cli.pre-migration-20260921`.

## Skills

The `task-ledger`, `create-task`, and `resolve-task` entries for Codex, Claude,
and Copilot are direct links to `F:\projects\MaxLogic\tasks-cli\integration\skills`
on Windows and `/mnt/f/projects/MaxLogic/tasks-cli/integration/skills` on WSL.
The six replaced Markdown skill links are retained outside active skill discovery
under each agent's `skill-link-backups/20260921` directory.

To roll back link selection, first verify the dated entry is still a link to
`D:\Pawel\Prompts\skills` (or `/mnt/d/Pawel/Prompts/skills`), move the current
product link aside, and rename the dated link to its original name. Do not
recursively delete through any skill link.
