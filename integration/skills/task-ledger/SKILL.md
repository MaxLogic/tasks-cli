---
name: task-ledger
description: "Access a project's shared SQLite task backlog with the MaxLogic tasks-cli executable. Use for project identity, selected task queries, versioned mutations, dependency readiness, and task history. Pair with create-task for formulation or resolve-task for execution. Do not bootstrap, migrate, or edit a Markdown ledger implicitly."
metadata:
  author: Pawel Piotrowski
  version: "1.1.0"
---

# Task Ledger

SQLite is the durable authority for task IDs, bodies, status, priority, labels,
dependencies, rules, and history. Markdown exports are snapshots, never an
editable second ledger. In this skill, `tasks` means the MaxLogic tasks-cli
executable, not a generic task facility. The sibling skills handle formulation
and execution.

## Identity before access

Each project root has a `.tasks.json` containing only a canonical UUID
`project_id`. The CLI discovers the nearest identity from the working directory,
including an inherited file in a Git worktree. It never skips an invalid nearer
identity to find a usable outer one. Run commands from the project tree:

```text
tasks list --limit 30
```

An explicit `--project` or `TASKS_PROJECT` overrides directory discovery. The
registry remains a compatibility fallback when no identity file exists. Missing,
malformed, or unknown identity stops the SQLite workflow. Report the specific
failure and necessary explicit setup; do not guess from a folder name, mint a
UUID, create another backlog, or edit a Markdown export.

For synthetic tests pass `--data-root <unique-temp-root>`. For WSL with a
Windows-owned store, use `--windows-exe <path>` or `TASKS_WINDOWS_EXE` so the
Linux CLI delegates discovery and database access to Windows. Do not open Windows SQLite files
with native Linux SQLite or propagate a Linux data root into a Windows store.
Both worktrees use the same UUID even though their paths differ. A project UUID
does not grant permission to migrate, deploy, or access unrelated projects.

## Task IDs and project keys

Each project has a short key chosen by a person (`DAK`), and the CLI shows task
IDs as `KEY-N` (`DAK-012`); a project without a key still shows `T-N`. Write
new references as `KEY-N` so notes, commits and other projects' tasks name
the project too. Input accepts `KEY-N` with this project's key, `T-N` and a
bare number, forever, so old text keeps working; never rewrite old notes only
to change their IDs. A `KEY-N` of another project exits 3 and names that
project: run the command there, since dependencies stay within one project.
`enrich` resolves another project's `KEY-N` read-only. `project-key` prints
the key. `init --key` and `project-key --set` need the key from the user; never
invent or change one yourself.

## Read only the needed records

The table omits the `tasks` prefix. Browse with the default text output; add
`--format json` (one compact line) only when parsing fields or following
cursors. Inspect live `tasks --help` and command help if the installed binary
differs from this contract. Do not invent a fallback that broadens writes.

| Need | Command |
| --- | --- |
| Normal ready queue | `list --limit 30` |
| Every open state, including blocked/human work | `list --open --limit 30` |
| Human-gated work | `list --needs-human --limit 30` |
| One explicit lifecycle | `list --status blocked --limit 30` |
| Group awaiting its batch gate | `list --status to-verify --limit 30` |
| Label slice | `list --label storage --limit 30` |
| Complete task/version/dependencies | `show T-012` |
| Several selected tasks in one read | `show T-012 T-014 T-020` |
| Find intent before creation | `search "shutdown" --ranked --limit 20` |
| Prefix-aware ranked retrieval | `search "shut" --ranked --prefix --limit 20` |
| Completion impact | `unlocks --limit 20` |
| Bounded history metadata | `history T-012 --limit 20` |
| Exact event body | `history T-012 --event 42` |
| Current project guidance, once per session | `rules show` or `show T-012 --rules` |

Follow returned cursors until the requested selection is complete. List uses
the returned `next_after` string (for example `P2:T-123`) as `--after`; plain
search/history use numeric cursors. Ranked search and unlocks use offsets.
Do not substitute a single bounded page for "all open tasks". Search
finds candidates, then `show` retrieves only selected bodies and prerequisites.
Default list is runnable `todo`/`in-progress` work excluding needs-human tasks;
it is not the full backlog. Statuses: draft, todo, in-progress, to-verify,
blocked, done, cancelled. `to-verify` means implemented and focused-tested,
waiting for a scheduled batch gate; it is nonterminal and hidden from default
list (`--open` and `--status to-verify` show it). A `to-verify` prerequisite
counts as satisfied for default list and `unlocks` only. Distinguish direct dependents from dependents that
become immediately runnable after completion; `unlocks` is scheduling evidence,
not permission to close a prerequisite. Lower P number means higher priority;
P0 through P3 are supported and P2 is the default. Priority never bypasses deps.

## Mutations and ownership

The coordinator alone writes task transitions. Pass the version you last
observed (list row or `show`) as `--expect-version`; a status or label change
needs no fresh `show`, because a stale version fails with exit 4 and writes
nothing. Re-read `show` before edits derived from body or field content. On
conflict, re-read and reconcile the changed intent with the user selection;
never automatically retry the same write or force an overwrite. Write output is
printed after commit (ID, status, new version, event ID); report it without a
verifying `show`. SQLite allocates IDs. `update --status done` fails with exit 2
and writes nothing while any prerequisite is not done or cancelled; move a
verified group to done in dependency order instead of retrying.

```text
create --title "Fix shutdown ordering" --body-file <body.md> --priority P2 --labels lifecycle
update T-012 --expect-version <observed-version> --status in-progress
update T-012 --expect-version <observed-version> --body-file <body.md> --deps T-003,T-009
update T-012 --expect-version <observed-version> --add-label needs-human
```

`--body-file -` reads the body from stdin, so a heredoc avoids a temporary file:

```text
tasks create --title "Fix shutdown ordering" --body-file - <<'EOF'
Outcome:
- ...
EOF
```

The `needs-human` label is the human gate. Preserve it unless the underlying
decision is resolved and removing it is authorized. Use `--add-label` and
`--remove-label` for single labels; `--labels` replaces the whole set. Treat
labels, priority, status, and dependencies as structured fields, not duplicate
body status lines. Dependency IDs belong to this project (`KEY-N`, `T-N` or
`N`), must exist, and must stay acyclic. Keep prerequisites without IDs in task notes. Read project rules
once per session before formulation/execution (plain `show` omits them) and use
versioned `rules set` only when authorized.

Give a worker the project UUID, task ID, observed version, complete selected
body, relevant rules, prerequisites, owned paths, allowed actions, exact proof,
and stopping condition. Workers return patches and evidence; they never mutate
the shared ledger or claim tasks by moving lifecycle themselves. The coordinator
rechecks version and acceptance before recording their result.
