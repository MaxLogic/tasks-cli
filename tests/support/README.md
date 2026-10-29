# Integration test helpers

Use `process::command` for synthetic subprocesses. It prevents console windows
from taking foreground focus on Windows. Give CLI commands an explicit temporary
`--data-root` and remove inherited routing variables when running locally.

Use `temp::TempDir` for server fixture roots. It reports deletion failures as
test failures instead of silently leaving databases behind. Declare the root
after every field owning a file, SQLite connection or server state: Rust drops
fields in declaration order. Stop and join server/proxy workers in `Drop`, and
release retained `ServiceState`/`Arc` owners before removing the root. Killing a
child process also requires waiting for it to exit before fixture cleanup.

Use `process::test_hooks_command(binary)` when a test needs a nested Cargo build
with `test-hooks`. Append only the binary's arguments. This helper selects the
package manifest, removes inherited task routing, and passes an explicit
`--target-dir` beneath the directory containing `CARGO_BIN_EXE_tasks`:
`<outer binary directory>/nested-test-hooks`. It works with custom target roots,
profiles and target triples without depending on the caller's current directory.
All nested hook builds share this cache and Cargo's build lock.

Never let a nested Cargo or rustc invocation write into the outer harness's
binary directory. `CARGO_BIN_EXE_*` identifies a path, not an immutable executable.
A nested build with different features can replace that executable after the
outer test binaries have been compiled, contaminating later subprocess tests.
The bulk-import verification-failure test checks that its nested build preserves
the outer CLI's SHA-256 as well as preserving the source and database fixtures.

Keep feature-dependent output assertions aligned with the outer harness:
ordinary builds omit hook diagnostics, while `test-hooks` builds include them.
The full-suite matrix covers default features, local-only
(`--no-default-features`), `test-hooks`, `server`, and `server,test-hooks`.
Keep each outer target directory exclusive to its gate.
