# Install and try tasks-cli

The CLI is a native executable. Local use requires no account, server or model
API key. SQLite is bundled. Rust and a C compiler are build dependencies only.

There is no public GitHub release or binary download yet. Obtain a source copy
from the maintainer; this guide does not assume a clone URL exists.

## Supported targets

| Component | Verified target | Other platforms |
| --- | --- | --- |
| CLI | Windows x64; native Linux x64 on Ubuntu in WSL, with separate storage | Other distributions need native verification. No macOS build or test has been run. |
| Viewer | Windows 11 x64, including owner-tested NVDA use | No Linux or macOS viewer build. |
| Server | Linux amd64 container, including a documented QNAP deployment | Other architectures are unverified. |

The original Linux baseline was Ubuntu 22.04 in WSL. Release notes must identify
the actual build/runtime baseline for each future download. macOS is unverified
because the maintainer currently has no machine for it.

## Build the CLI

Install rustup and the native C build tools. On Windows, use the MSVC C++ build
tools and Windows SDK. On Ubuntu, install the distribution's C build toolchain.
The checkout pins Rust in `rust-toolchain.toml`; keep `Cargo.lock` intact.

From the source directory on Windows:

```powershell
cargo build --release --locked --bin tasks --target-dir target/public-build
.\target\public-build\release\tasks.exe --version
```

Copy `tasks.exe` to a directory you own and add that directory to your user
PATH through Windows Environment Variables. Open a new terminal and check
`tasks --version`. Stop users of an existing executable before replacing it.
This build directory avoids replacing the maintainer's installed symlink target.

On native Linux, including Ubuntu in WSL:

```bash
cargo build --release --locked --bin tasks --target-dir "$HOME/.cache/tasks-cli-public-build"
"$HOME/.cache/tasks-cli-public-build/release/tasks" --version
```

Copy the resulting executable to a directory on your PATH, commonly
`$HOME/.local/bin`. If an existing `tasks` there is a symlink, choose a new
destination or inspect its target before replacing it. In WSL, keep both the
Cargo target directory and native task store on the Linux filesystem.

## First run

Choose an existing project directory and a key such as `APP`. Create `notes.md`
inside that directory with the task's scope and acceptance criteria. Then run:

```text
tasks init --root <absolute-project-directory> --key APP
cd <absolute-project-directory>
tasks create --title "Write release notes" --body-file notes.md --status todo
tasks list
tasks show APP-1
```

Replace the bracketed path before running the commands. `init` creates the
project-root `.tasks.json`; commit that identity if the project uses Git.
Do not commit the database. A fresh machine cannot recover a local backlog
from the UUID alone: restore its backup or configure its existing remote server.
Forks must deliberately choose whether to use the original backlog or create
a separate project identity.

For a throwaway trial, use the [architect-led walkthrough](integration/architect-workflow.md).
Every command there supplies an isolated data root.

## Windows storage from WSL

A native Linux process must not open a Windows-owned task database. To use a
Windows local backlog from WSL, delegate to its Windows executable:

```bash
TASKS_WINDOWS_EXE=/mnt/c/Tools/tasks.exe tasks list
```

Replace the path with your installed `tasks.exe`. For a self-hosted remote
backlog, configure each native installation independently instead; the server
owns SQLite. Remote profiles are selected before delegation. See
[remote setup](integration/remote-cli.md).

## Viewer and server

The Windows viewer ships as a whole directory, including its matching CLI,
Flutter runtime, assets and hash manifest. Copy the whole bundle and run
`tasks_viewer.exe`. Select your CLI/data root in Settings. Source packaging and
keyboard controls are described in [viewer/README.md](viewer/README.md).

The server is optional. Add `--features server --bin tasks-server` to a separate
`cargo build --release --locked` invocation with its own target directory and
follow [server administration](integration/server-core.md).
Remote access requires enrollment and an online HTTPS gateway. It does not
provide an offline write queue.

## Proposed public distribution

This is the recommended release approach, not an existing download service:

1. Build and test the same tagged source natively on Windows x64 and Ubuntu x64.
   Use separate targets and temporary stores. Publish the Ubuntu/glibc baseline.
2. Package `tasks.exe` as a Windows ZIP and `tasks` as a Linux tarball. Each
   archive includes a short quickstart, MIT license and dependency notices.
   Publish a SHA-256 manifest and record the embedded source commit.
3. Ship the Windows viewer as a separate ZIP so CLI users have a small download.
   Include its complete runtime and matching CLI. Confirm the bundled audio's
   redistribution terms and include the applicable notices/provenance.
4. Attach archives to a GitHub Release after a repository and release are
   authorized. CI may prepare artifacts first; publication remains an explicit
   step. Use [Release assets](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
   for downloads rather than temporary, access-controlled
   [workflow artifacts](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts).
5. Test the archives on a clean machine: unpack, set PATH, initialize a synthetic
   project and complete the first-run example. Viewer users should need no SDK.

Start with portable archives. Package-manager entries and an installer can follow
when outside users identify installation friction. Do not add an auto-updater,
service or mandatory account to install a local task CLI.
