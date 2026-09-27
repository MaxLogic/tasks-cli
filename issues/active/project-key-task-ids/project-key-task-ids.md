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

- `init --root PATH [--key KEY]`:
  - With `--key`: use it; if another project owns it, exit 2 naming that
    project and a free suggestion. Nothing is created.
  - Without `--key`: propose one from the root folder name (capitals of a
    CamelCase name, `DelphiAiKit` -> `DAK`; otherwise the first letters of the
    words or the first 3-4 letters), then extend it until it is free. Print the
    chosen key in the result.
- Existing projects: `project-key` prints the key; `project-key --suggest`
  prints a free proposal; `project-key --set KEY` sets or changes it under the
  same uniqueness rule and registry lock. Projects without a key keep working
  with `T-N`; setting one is explicit.
- Changing a key does not rewrite task bodies. Old `OLDKEY-N` mentions stay as
  written and no longer resolve.
- `bulk-import --apply` assigns proposed keys the same way and lists them in its
  report.

## Schema and compatibility

Additive: a project-metadata key field plus a migration that leaves it unset
for existing databases. Older binaries refuse the new schema as they do today.
WSL delegation needs no change beyond passing the new flags through.

## Skills

task-ledger, create-task and resolve-task: write new references as `KEY-N`,
accept `T-N` in old text, never rewrite old notes just to change IDs.

## Proof

- Temporary data roots only. Key derivation cases (`DelphiAiKit`,
  `tasks-cli`, `SkillSync`, collisions, a folder name with no letters).
- Uniqueness: explicit conflicting `--key` refused with nothing written; two
  concurrent `init`s get different keys.
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
