# Project identity files

Routing starts at the current directory (or the translated WSL route directory)
and walks ancestors until the first `.tasks.json`. Git roots do not stop the
walk. A monorepo can give each subproject its own UUID, with the root identity
serving directories without a nearer identity. Invalid or dangling nearer
identities fail closed. Explicit `--project` and `TASKS_PROJECT` retain precedence.

An identity contains only `{"project_id":"<canonical-lowercase-uuid>"}` and is
at most 4096 bytes. It can be a regular file or a file symlink to a regular
file. Relative links into `.private/` are supported. For a subproject at
`sub/app`, its `.tasks.json` can link to
`../../.private/sub/app/.tasks.json`, using the repository's single root overlay.
Ordinary excluded copies remain supported.

File symlink chains are supported. If the immediate target is missing, the error
says `points to missing <target>`. If it is an existing link whose final target
is missing, the error names that intermediate link and says
`which is a link to a missing target`. Both cases stop ancestor discovery.

`init --root <subdirectory> --key KEY` creates an exact-root identity without
changing its parent's identity. An existing matching link and its target are
preserved. Conflicting, invalid and dangling identities are refused; initialization
never replaces a link or creates a missing target through it.

## Target validation and Windows reparse points

The reader checks the target's type and size before opening, then validates
metadata from the opened handle. It reads at most 4097 bytes from that same
handle and rejects a result over 4096 bytes, so concurrent growth cannot produce
an unbounded allocation. On Unix the open is nonblocking so a concurrent FIFO
replacement cannot hang the open before handle validation.

Observed on Windows with Rust 1.98.1 and real NTFS links:
`symlink_metadata()` reports a file symlink as `is_symlink() == true`,
`is_symlink_file() == true`, with attributes `0x420`.
`metadata()` follows it and reports a regular file, `is_symlink() == false`,
with attributes `0x20`. A directory junction is also `is_symlink() == true`
under `symlink_metadata()`, with attributes `0x410`, but
`is_symlink_file() == false`. Following the junction with `metadata()` reports
a directory with attributes `0x10`.

Consequently `is_symlink()` alone cannot admit Windows identity links safely.
Only file symlinks are eligible for following; directory symlinks and junctions
are rejected. Other reparse points are rejected by the reparse attribute check,
and the followed/opened target must be a regular file without that attribute.
Windows junctions target directories, so a junction to an identity file is not
a supported file-link mechanism. These exceptions apply only to project identity
reads; credential, export, private-directory and remote-config link rules remain
unchanged.
