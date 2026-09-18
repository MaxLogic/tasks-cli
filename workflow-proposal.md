# Proposed AI task workflow

Status: states, labels and ranked word/prefix search are implemented. Other
sections remain recommendations. No live skills or task ledgers have been switched. `spec.md` remains the current implementation contract.

## Keep the SQLite CLI

For this workflow, SQLite is a better authority than a Markdown ledger. Agents
cannot accidentally load the whole backlog with a file read; the CLI gives them
bounded summaries and explicit full-task access. Tasks survive worktree removal,
and transactional writes, version checks and history protect the shared backlog.
The loss of Git-native task diffs is a small cost when TASKS.md was usually not
tracked anyway. Done/cancelled tasks already disappear from ordinary listings.

The costs are maintaining binaries/schema migrations, backing up the database,
and making project selection reliable. Version checks prevent overwritten edits,
but cannot prevent two agents independently doing the same engineering work.
Keep the coordinator responsible for selecting work and changing task state.

The external-tool review does not justify replacing this implementation.
[Beads](https://github.com/gastownhall/beads) offers dependency-driven ready work,
[Backlog.md](https://github.com/MrLesk/Backlog.md) emphasizes acceptance criteria,
and [td](https://github.com/marcus/td) provides useful structured handoffs. Borrow
those ideas without adding another task authority or a mandatory service. The
research reports are retained under `target/evidence/tool-landscape-20260918/`.

## States, labels and priority

The approved six states are implemented. Explicit schema migration replaces
`backlog`/`ready` with `draft`/`todo` while preserving existing history.

| State | Meaning |
| --- | --- |
| `draft` | Placeholder or idea that still needs brainstorming or definition |
| `todo` | Defined work, subject to dependency readiness |
| `in-progress` | Work the coordinator has started |
| `blocked` | Work cannot currently proceed for a non-dependency reason |
| `done` | Completed and verified |
| `cancelled` | Intentionally abandoned |

Use ordinary normalized labels such as `performance`, `security`, and `ui`.
Reserve `needs-human` for a decision or input requested from the user. It may
appear on a blocked task or a draft: brainstorming and waiting for a decision
are independent properties. A draft without that label can be developed by an
agent. Record the actual question in the task body. Do not infer a human decision
from the label's age or silently remove it on a status change.

Keep priority separate: P0 urgent, P1 high, P2 normal (default), P3 low. Labels
are enough for the requested grouping; defer a second hierarchy of categories.
Include labels and priority in version checks, history, import/export and JSON.

## Queries

Proposed examples, not currently supported commands:

```text
tasks list
tasks list --label performance
tasks list --status draft
tasks list --needs-human
tasks list --open
tasks list --status done
tasks unlocks
```

Default `list` should return `todo` and `in-progress` tasks whose prerequisites
are all done, excluding `needs-human`. Order by priority and then stable task ID.
Keep bounded results and pagination in SQL. `--open` explicitly includes every
nonterminal state; `--needs-human` explicitly includes nonterminal drafts and
blocked tasks awaiting input. Label filtering should combine with either scope.

A cancelled prerequisite should not silently count as completed. The coordinator
must remove the dependency with an explanation or explicitly decide that its
requirement has been met. Dependency blockage is calculated from the graph;
avoid requiring agents to maintain a second, manually synchronized blocked flag.

`unlocks` should report open prerequisites, their direct open dependent count,
and how many tasks would actually become runnable if each prerequisite finished.
Sort by that immediately runnable count, then direct dependent count and priority.
Count each dependent once. A task with another unmet prerequisite, a manual
block, a draft state or a pending human decision is not immediately unlocked.
Defer transitive graph scoring until it helps a real selection decision.

## Worktrees and subagents

Use a small tracked `.tasks.json` containing only `{"project_id":"<UUID>"}`.
The UUID is project identity, not a credential or database path. Git worktrees
inherit the same file, while database locations remain machine-local.
AGENTS.md should point to the shared task skill and identity file, rather than
duplicate the UUID. A general `.env` is a poor fit because it is often untracked,
may contain secrets, and requires separate loading rules.

Initially the shared skill can read this file and pass `--project` explicitly;
automatic CLI discovery is a separate feature. An unknown UUID must fail with
setup instructions rather than create another backlog. On a new machine, restore
or initialize that identity deliberately, then bind roots as needed. Current
CLI users must continue using explicit `--project` or `bind`; it does not yet
read `.tasks.json` or discover Git worktree membership.

The coordinator supplies project UUID, task ID/version, relevant rules, bounded
scope and acceptance criteria in each subagent brief. Subagents return changes,
proof, uncertainties and remaining work. The coordinator reconciles the result
and performs version-checked task transitions. No claims/lease subsystem is
needed for this model. WSL workers use the Windows backend for a Windows backlog.

## Skills and handoffs

Use “Task Ledger” as a possible system name, keep the short `tasks` command,
and put backend mechanics in a shared `task-ledger` skill. Naming is a proposal.
`create-task` retains task formulation and ledger-edit ownership; `resolve-task`
retains execution, acceptance checks and verification. Both reference the shared
skill for project selection, rules, queries, writes and version-conflict handling.

Keep session handoffs in the existing session-state workflow: completed work,
remaining work, decisions, uncertainties and links to proof. Link to task IDs;
do not duplicate editable task records. Deploy the skill changes only in the
agreed quiet window after CLI readiness and copied-ledger migration trials.

## Revisions and search

Revision history already exists: task creation records the initial full snapshot;
every subsequent actual mutation appends the resulting full snapshot in the same
transaction as the change. Earlier snapshots remain intact. No-op updates add
no event. `history T-N --event N` retrieves a selected revision. A second revision
table would duplicate this. A future restore command should make a new
version-checked update and event, preserving later history.

Labels and SQLite FTS5 ranked word/prefix search are now implemented, with an
index updated transactionally. Plain `search` preserves literal substring
matching for identifiers and exact fragments. Priority queries remain proposed. FTS5 supports
ranking and tokenization, but is not semantic similarity or general typo
correction. See the [SQLite FTS5 documentation](https://www.sqlite.org/fts5.html).

Use task labels and a small, explicit synonym list if queries like “speed” should
find “performance.” Add typo tolerance only after recording missed queries.
Defer embeddings, model downloads, a vector store and index-version coordination
until lexical search demonstrably fails useful retrieval cases. Search results
should remain bounded summaries with explicit access to the full task.
