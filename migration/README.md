# 2026-09-21 project migration manifest

`projects-20260921.csv` is the reviewed canonical set for the one-time migration
of task ledgers under `F:\projects`. It contains 51 independent project
identities and 5,597 imported tasks. The corresponding strict dry run completed
with 50 recognized candidates, one recognized candidate with a UTF-8 BOM
warning, and no unrecognized candidates.

The strict rehearsal evidence is retained under
`target/evidence/migration-20260921-final-dry/`. The matching live apply evidence
is under `target/evidence/migration-20260921-live-apply/`: all 51 projects were
applied and verified, with zero failures. The migration used
`sections-20260921.json`, stores live data in `F:\projects\.tasks-cli-data`, and
keeps the Markdown ledgers as read-only migration snapshots. A post-apply
`doctor` run resolved every tracked `.tasks.json` to its expected UUID and schema
4 database.

The scan excluded:

- every `3rdParty`, `lib`, `target`, and `node_modules` subtree;
- DelphiSemantics `.dak` proof trees and `tests/bin` fixtures;
- profiling `testFiles` fixtures;
- `_discarded-or-obselete` projects;
- `pdf-to-md`, whose guidance identifies `TASKS.md` as a historical run artifact;
- maxTdb baseline, benchmark, branch-copy, and test-isolation directories that
  share the authoritative `OEC/TE5/maxTdb` project or contain generated fixtures.

Nested entries in the CSV are independent projects with their own ledger and
identity. The two `rpg-dice` applications and the four nested `OEC/_git/TE5`
tools therefore do not inherit their parent's task identity.
