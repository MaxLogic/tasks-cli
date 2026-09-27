# Project keys in task IDs (`DAK-123`)

Status: approved for implementation, 2026-09-27. Do after `to-verify`
(`issues/active/grouped-verification-queue`).

## Problem

Every project numbers tasks `T-1, T-2, ...`. A note in a DelphiSemantics task
that says "see T-212" does not say which project T-212 belongs to, and linked
work across projects (DAK/DS) is referenced by prose. A short project key in
the ID identifies project and task in one token: `DAK-212`, `DS-640`.

## Behavior

- Each project has one key: 2-6 characters, uppercase ASCII letters and digits,
  starting with a letter. Input is case-insensitive and stored uppercase. `T` is
  reserved for the legacy form.
- Keys are unique within a data root. The key lives in the project database
  (so backups carry it). Uniqueness is checked against every project database
  under `<data-root>/projects/`, while holding the registry lock, so two
  concurrent `init`s cannot claim the same key.
- Output shows `KEY-N` everywhere a task ID appears: text and JSON output,
  `list`/`show`/`history`/`unlocks`, dependency summaries, Markdown export and
  the viewer. JSON keeps the numeric `id` and adds the display ID.
- Input accepts `KEY-N` with this project's key, `T-N` and bare `N`, forever.
  Old notes, commit messages and TODO comments use `T-N`.
- A `KEY-N` with another project's key fails with exit 3 and names that
  project and its root. Dependencies stay same-project.
- `enrich` resolves `KEY-N` for any project in the data root (read-only), so
  a DS note mentioning `DAK-212` gets its title. `T-N` keeps resolving against
  the current project.
- Import accepts both `### T-N` and `### KEY-N` headings for the target project.

## Assigning keys

Keys are always chosen by a person; the CLI never invents one.

- `init --root PATH --key KEY`: `--key` is required. A missing, malformed or
  taken key exits 2 and creates nothing; a taken key names the owning project.
- `project-key` prints the current key; `project-key --set KEY` sets or changes
  it under the same uniqueness rule and registry lock.
- Changing a key does not rewrite task bodies. Old `OLDKEY-N` mentions stay as
  written and no longer resolve.
- `bulk-import --apply` requires a key for every project it creates, from a
  `--key-map FILE` (root to key). The dry-run report lists roots still lacking
  one; apply refuses until all are mapped.
- Projects without a key (migrated databases before assignment) keep working
  with `T-N`.

## Migrating existing projects

The maintainer reviewed keys for all registered projects in
[project-keys.csv](project-keys.csv), next to this issue (columns `key`,
`project_name`, `project_path`, `project_id`; migrate by `project_id`). After the release is installed:
back up each database, run `migrate`, then `project-key --set KEY --project
UUID` for each row. Check first that every key is valid and unique; stop on the
first failure and report it. Projects whose root no longer exists are keyed by
UUID the same way.

## Schema and compatibility

Additive: a project-metadata key field plus a migration that leaves it unset
for existing databases. Older binaries refuse the new schema as they do today.
WSL delegation needs no change beyond passing the new flags through.

## Skills

task-ledger, create-task and resolve-task: write new references as `KEY-N`,
accept `T-N` in old text, never rewrite old notes just to change IDs.

## Proof

- Temporary data roots only. Key validation: length, leading digit, reserved
  `T`, case folding; `init` without `--key` exits 2 and creates nothing.
- Uniqueness: explicit conflicting `--key` refused with nothing written; two
  concurrent `init`s with the same key: exactly one succeeds.
- Parsing: `KEY-N`, `key-n`, `T-N`, `N` accepted; foreign key exits 3.
- Output: text, JSON and export show `KEY-N`; projects without a key still
  show `T-N`.
- `enrich` across two projects; `project-key --set` to a taken key exits 2.
- Migration of an existing database; viewer displays keyed IDs.
- Windows and Linux gates per AGENTS.md; delegated `init --key` with the real
  binaries.

## Out of scope

Cross-project dependencies, cross-project `show`/`update`, renumbering tasks,
rewriting existing notes.
