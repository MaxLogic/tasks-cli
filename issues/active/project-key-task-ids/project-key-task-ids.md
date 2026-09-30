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

## Implementation decisions

Recorded during implementation, 2026-09-27. spec.md "Project keys" is the
contract; these are the choices the issue left open.

- Display IDs keep the three-digit padding: `DAK-007`, like `T-007`.
- JSON adds `display_id` next to each numeric `id` (and `task_display_id` in
  `open_prerequisites`); `deps` arrays stay numeric. List `next_after`
  cursors keep the `P2:T-123` form.
- A `KEY-N` whose key no project has exits 3 as well, saying so.
- `enrich` leaves a `KEY-N` with an unknown key unchanged and unreported
  (`UTF-8`, `ISO-8601`); JSON gains `unknown_refs` for all unknown references.
- Import accepts `### KEY-N` and `Depends on: KEY-N` only for the target
  key; a `### OTHER-N` heading is a blocking problem, and the create-task
  `Deps:` grammar stays `T-N`. Import problem messages keep the ledger's
  `T-N` wording.
- `--key-map` is a JSON object from project root (absolute or relative to
  `--scan-root`) to key. Only projects the run would create need an entry.
- Re-running `init` on a bound root must repeat its existing key; it never
  changes one.
- Opening every project database costs about 6 ms each on Windows, so a
  fingerprint-validated cache `<data-root>/project-keys.json` backs reference
  lookups (evidence: target/evidence/project-keys/perf/).
- Key cache: kept for every key lookup, including the uniqueness checks in init, project-key --set and bulk apply (user decision 2026-09-28). The same cache is intended to later hold per-project stats for the viewer's project list.
- List cursors keep the P2:T-123 form (user decision 2026-09-28).
- `T` followed only by digits (`T12`) is never a key: it would read like the
  legacy `T12` spelling. The parser and the schema CHECK both refuse it.
- A `### KEY-N` heading is reported as another project's task only when a
  project in the data root owns that key; `### ISO-8601 dates` stays text.
- Recovery drafts keep the `T-N` identity and are matched by project and
  numeric ID, so a key (or a key change) never orphans them.
- Reserved keys (user decision 2026-09-29): `enrich` never treats a fixed
  list of standard-name prefixes as a task-ID key, so `UTF-8`, `SHA-256` or
  `ISO-8601` in prose no longer triggers a data-root scan. The list covers
  encodings, standards bodies, hashes, ciphers and vulnerability IDs (for
  example UTF, UCS, ISO, IEC, IEEE, RFC, SHA, AES, RSA, CRC, CVE, CWE, ECMA,
  CP, X86). Project-key validation refuses the same keys, so no project can
  own a key that enrich ignores; none of the keys in `project-keys.csv`
  collides with the list.
- Project-list statistics cache (user decision 2026-09-30, TSK-006): keep two
  caches. Per-project statistics stay in the viewer's
  `<data-root>/viewer-cache.sqlite3`; keys stay in `project-keys.json`; both
  use one shared staleness/fingerprint rule. This supersedes the 2026-09-28
  idea of storing statistics in the key cache. Measure the project list first
  (53 and 500 projects, warm and cold cache) and fix only what the
  measurements show is slow. Archive dates stay in the viewer's persistent
  settings.

## Follow-ups from review

Recorded during the implementation review, 2026-09-28; not part of this change.

- Read-only opens leave an empty `-wal`/`-shm` behind, which raises every
  later read-only open on Windows from about 1 ms to 6.5 ms; `show` also pays
  it (14.7 vs 20.3 ms). This predates the slice. A fix must not break the
  guarantee that a bulk-import dry run leaves the data root byte-identical,
  because a read-write close can checkpoint.
  Resolved 2026-09-28. Cause: a read-only SQLite connection creates the
  sidecars but may not run the close-time checkpoint that removes them. A read
  now opens read-write with `PRAGMA query_only` when the WAL is absent or
  empty (nothing to checkpoint), and read-only when it holds frames. Measured
  with release builds (target/evidence/cache-wal/perf/NOTES.txt): Windows
  show 43.3 -> 35.9 ms and list 42.9 -> 36.6 ms (interleaved A/B medians, loaded
  machine); with the key cache, init at 500 projects 4214 -> 155 ms (1220 ms
  when no cache file exists yet) and project-key --set 4404 -> 125 ms; native
  Linux show and list unchanged within about 0.3 ms (interleaved A/B, 4.0-4.5
  ms). No sidecars remain after reads; the first read of a database with an
  older binary's empty leftovers removes them.
- The enrich key-shaped regex matches UTF-8, SHA-256 and similar words, which
  triggers a scan on ordinary prose (cheap with the cache).
- The editor keeps the old key until the task is reloaded after a key change.
- The default `flutter test` real-CLI cases and the verify-windows.ps1
  ALPHA-001 fixtures need the installed build.
- Viewer project list: cache per-project stats so the list renders without recomputing them (user direction 2026-09-28; not yet designed).
