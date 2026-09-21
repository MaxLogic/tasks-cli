# Deployment record: 2026-09-21

## Executables

- Windows: `F:\CliTools\tasks.exe`
  - SHA-256: `f7ec1aab97f19caaead8f93054f056f28e71052e3eb36fefed16a4f022612983`
- Ubuntu/WSL: `/home/pawel/.local/bin/tasks`
  - SHA-256: `67a782fab0092781b4c83fb991cf5ffa5377bf61b79d20cfbf50f79d4dda0688`
- Both report `tasks 0.1.0`.

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
