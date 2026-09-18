# tasks-cli

Build and maintain a local Rust CLI for one shared SQLite task backlog per
project, independent of Git branches and worktrees. `spec.md` is the
implementation contract. The repository includes the implementation and its
platform-specific verification evidence; keep that evidence honest and current.

Both native Windows x64 and Linux x64 builds are required. Test Linux inside
Ubuntu/WSL with a Linux-owned temporary database. For the shared Windows backlog,
the Linux CLI delegates to tasks.exe as specified in spec.md; never open the same
live SQLite database from Windows and native Linux processes. Verify delegation
with the real two binaries, not just argument mocks.

## Start here

- Read the relevant spec sections and implement its slices in order. Resolve
  contradictions explicitly; do not silently simplify away data preservation,
  concurrency checks, backups or acceptance criteria.
- Use the project-local `rust-engineering` skill for Rust implementation and
  `rust-testing` for substantial test design. Both are linked under
  `.agents/skills/` and `.claude/skills/`; their sources live in
  `D:/Pawel/Prompts/skills/_rust/`. Do not edit or delete through those links.
- This task authorizes scaffolding and synthetic-data verification. It does not
  authorize switching PFM, DelphiAiKit or other live projects to the new store.
  Migration trials use copies. Never modify their TASKS.md files during tests.

## Architecture and performance

- Start with one Cargo package, a thin binary and a small library. Use synchronous
  Rust, concrete types, explicit parameterized SQL and one connection per command.
  No async runtime, ORM, daemon, connection pool, plugin framework or generic
  repository traits without a measured requirement.
- Keep parsing/rendering outside database transactions. Bound list results in SQL;
  do not load every task/body/history entry and filter in Rust. Preserve complete
  text in `show`; expose pagination rather than silently dropping results.
- Use `Result` and actionable typed errors. No production `unwrap`, unsafe code,
  shell-composed SQL, user-controlled SQL fragments or automatically retried
  optimistic-conflict writes.
- SQLite atomicity, version checks and append-only history belong in the same
  transaction. Report mutation success only after commit. Follow the spec's
  Windows/WSL ownership boundary and backup procedure exactly.
- Measure release binaries including process startup. Distinguish proposed
  performance targets from observed results. Do not weaken durability to pass a
  benchmark or add caches before profiling demonstrates a need.

## Verification and context

- Locate files before reading bodies. Search `src/`, `tests/` or the exact docs
  section. Exclude `target/`, linked skills and generated evidence by default;
  include hidden guidance when discovering applicable instructions.
- Add meaningful failing tests for each behavior slice, then implement and verify
  GREEN. Use real temporary SQLite databases and subprocesses for persistence,
  contention, exit codes and crash behavior. Zero selected tests are not proof.
- Once Cargo files exist: `cargo fmt --check`, `cargo clippy --locked --all-targets`,
  `cargo test --locked`, `cargo build --release --locked`. Establish and commit
  Cargo.lock as part of implementation; do not use `--locked` before it exists.
- Run the build/test gates on both Windows and Linux, with separate Cargo target
  directories. A Windows build or Linux cross-compile alone is not Linux runtime
  proof. Record native and delegated performance separately.
- Run focused tests while editing. Run broad checks at the spec's batch/final
  boundaries, not after every small edit. Retain full logs under ignored
  `target/evidence/`; report status, counts, relevant failures and exact log paths.
- Tests must receive an explicit unique temporary data root. Never use the real
  default task store, recursively clean a repository, or kill unrelated workers.
- Preserve unrelated changes. Do not push, migrate a live backlog or replace an
  in-use executable without authorization.
- After completing and verifying each task or milestone, create a local Git
  commit for that related batch. Stage only its owned changes, inspect the staged
  diff, and keep unrelated work separate. Commit authority does not authorize push.
- If Git is initialized, ignore only generated `target/` and local skill-link
  directories `.agents/skills/`, `.claude/skills/`. Do not blanket-ignore `.agents`.
  User task databases, backups and exports live outside this source repository.
