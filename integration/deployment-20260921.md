# Deployment record: migration 2026-09-21, binaries updated 2026-09-22

## Executables

- Windows: `F:\CliTools\tasks.exe`
  - SHA-256: `92793db00a29e723f26d221a6a7e6e29a282c10542b71395b027f81c94a3b3d2`
- Ubuntu/WSL: `/home/pawel/.local/bin/tasks`
  - SHA-256: `607d1841e23ba93c2713466606dfcf1973b77a468d4e80e36f195976dcd2848c`
- Both report `tasks 0.1.0 (commit 8b1dabd9b44c)` and were rebuilt from
  implementation commit `8b1dabd`.
- `tasks init --root <project>` creates a missing `.tasks.json`, accepts a
  matching identity without rewriting it, and refuses malformed or conflicting
  identities.

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
