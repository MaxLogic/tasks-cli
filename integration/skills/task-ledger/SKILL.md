---
name: task-ledger
description: "Access a project's shared SQLite task backlog with tasks CLI. Use for project identity, selected task queries, versioned mutations, dependency readiness, and task history. Pair with create-task for formulation or resolve-task for execution. Do not bootstrap, migrate, or edit a Markdown ledger implicitly."
metadata:
  author: Pawel Piotrowski
  version: "0.1.0-dev"
---

# Task Ledger

SQLite is the durable authority for task IDs, bodies, status, priority, labels,
dependencies, rules, and history. Markdown exports are snapshots, never an
editable second ledger. This development skill requires `tasks`, Python 3,
Git, and the sibling development skills when formulation or execution is needed.

## Identity before access

For Git projects read the Git root's tracked `.tasks.json`, containing only a
canonical UUID `project_id`. Outside Git (including SVN), use the nearest ancestor
`.tasks.json` as the project boundary; never skip an invalid nearer identity to
find a valid outer one. Use the bundled wrapper for each command:

```text
python -B <task-ledger>/scripts/task_project.py --cwd <working-directory> -- <command>
```

The wrapper finds the Git root from nested directories, validates the file,
checks the selected project through read-only `rules show`, and always passes
`--project <uuid> --format json`. It never initializes or binds a worktree.
Missing, malformed, untracked, or unknown identity stops access. Report the
specific failure and necessary explicit setup; do not guess from a folder name,
silently fall back to CWD binding, mint a UUID, or create another backlog.

For synthetic tests pass wrapper `--data-root <unique-temp-root>`. For WSL with
a Windows-owned store, use the Linux CLI's existing Windows delegation and
wrapper `--windows-exe <path>` where needed. Do not open Windows SQLite files
with native Linux SQLite or propagate a Linux data root into a Windows store.
Both worktrees use the same UUID even though their paths differ. A project UUID
does not grant permission to migrate, deploy, or access unrelated projects.

## Read only the needed records

All commands below follow the wrapper's `--` separator. Inspect live `tasks
--help` and command help if the installed binary differs from this development
contract. Do not invent a fallback that broadens writes.

| Need | Command |
| --- | --- |
| Normal ready queue | `list --limit 30` |
| Every open state, including blocked/human work | `list --open --limit 30` |
| Human-gated work | `list --needs-human --limit 30` |
| One explicit lifecycle | `list --status blocked --limit 30` |
| Label slice | `list --label storage --limit 30` |
| Complete task/version/dependencies | `show T-012` |
| Find intent before creation | `search "shutdown" --ranked --limit 20` |
| Prefix-aware ranked retrieval | `search "shut" --ranked --prefix --limit 20` |
| Completion impact | `unlocks --limit 20` |
| Bounded history metadata | `history T-012 --limit 20` |
| Exact event body | `history T-012 --event 42` |
| Current project guidance | `rules show` |

Follow returned cursors until the requested selection is complete. List uses
the returned `next_after` string (for example `P2:T-123`) as `--after`; plain
search/history use numeric cursors. Ranked search and unlocks use offsets.
Do not substitute a single bounded page for "all open tasks". Search
finds candidates, then `show` retrieves only selected bodies and prerequisites.
Default list is runnable `todo`/`in-progress` work excluding needs-human tasks;
it is not the full backlog. Distinguish direct dependents from dependents that
become immediately runnable after completion; `unlocks` is scheduling evidence,
not permission to close a prerequisite. Lower P number means higher priority;
P0 through P3 are supported and P2 is the default. Priority never bypasses deps.

## Mutations and ownership

The coordinator alone writes task transitions. Read `show` immediately before
an update and pass its current `--expect-version`. On conflict, re-read and
reconcile the changed intent with the user selection; never automatically retry
the same write or force an overwrite. Report success only from committed CLI
success, then verify the returned version/selected record. SQLite allocates IDs.

```text
create --title "Fix shutdown ordering" --body-file <body.md> --priority P2 --labels lifecycle
update T-012 --expect-version <observed-version> --status in-progress
update T-012 --expect-version <observed-version> --body-file <body.md> --deps T-003,T-009
```

The `needs-human` label is the human gate. Preserve it unless the underlying
decision is resolved and removing it is authorized. Use the installed command's
exact clear-field options. Treat
labels, priority, status, and dependencies as structured fields, not duplicate
body status lines. Dependency IDs belong to this project, must exist, and must
stay acyclic. Keep prerequisites without IDs in task notes. Read project rules
before formulation/execution and use versioned `rules set` only when authorized.

Give a worker the project UUID, task ID, observed version, complete selected
body, relevant rules, prerequisites, owned paths, allowed actions, exact proof,
and stopping condition. Workers return patches and evidence; they never mutate
the shared ledger or claim tasks by moving lifecycle themselves. The coordinator
rechecks version and acceptance before recording their result.
