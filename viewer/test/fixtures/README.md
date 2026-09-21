# Viewer test fixtures

## `viewer-projects-real.json`

Captured from the real CLI, not hand-written. Provenance:

- `tasks.exe` built from commit `363d0c1` (debug profile), the slice-2 CLI that
  implements `viewer projects`.
- Command:
  `tasks.exe --data-root <fixture>\data --format json viewer projects --request-file <request>`
  with `{"query":"","state":"all","sort":"name","direction":"asc","offset":0,"limit":100,"snapshot":null}`.
- Synthetic fixture store, built by `tasks.exe init`/`bind`/`create` in a
  temporary directory outside this repository. It contains one project with two
  bound roots, one project with a single task, one project whose database file
  is not a SQLite database, one project whose database file is absent, and one
  project with no tasks.
- The only edit after capture is a textual substitution of the absolute
  temporary fixture root for `C:\viewer-fixture`, so the committed fixture
  carries no machine-specific path. Field names, values, counts, ordering and
  the snapshot token are byte-identical to the CLI response.
- The captured response, the request documents, the raw logs and the build
  script for the fixture live under
  `target/evidence/viewer/2026-09-21-slice3/` (ignored by Git).

`RealCatalogFixtureTest` decodes this file with the production DTOs, so the
viewer's parsing is checked against real CLI output rather than a hand-written
approximation.
