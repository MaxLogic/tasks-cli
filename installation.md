# Install and try tasks-cli

The CLI is a native executable. Local use requires no account, server or model
API key. SQLite is bundled. Rust and a C compiler are build dependencies only.

Download portable archives from [GitHub Releases](https://github.com/MaxLogic/tasks-cli/releases/latest).
Local use starts with extraction; a source build is optional.

## Download and install

Choose the archive for your platform:

| Archive | Contents |
| --- | --- |
| `tasks-cli-<version>-windows-x86_64.zip` | Windows x64 CLI, quickstart, license and dependency notices |
| `tasks-cli-<version>-linux-x86_64.tar.gz` | Linux x64 CLI, built on Ubuntu 22.04 with glibc 2.35 |
| `tasks-viewer-<version>-windows-x86_64.zip` | Windows viewer, matching CLI, Flutter runtime, assets and notices |

Also download `SHA256SUMS.txt`. Before extraction, check the archive's SHA-256
against the manifest. On Windows, use `Get-FileHash <archive> -Algorithm SHA256`
and compare the complete hash with its filename's line. On Linux, run
`sha256sum --ignore-missing --check SHA256SUMS.txt` from the download directory;
confirm it reports `OK` for the archive you downloaded.

On Windows, extract the CLI ZIP and copy `tasks.exe` into a directory on your
user PATH. On Linux, extract the tarball and copy `tasks` into `$HOME/.local/bin`,
which must be on PATH. Inspect any existing symlink before replacing it.
Open a new terminal and run `tasks --version`.

For the viewer, keep the entire extracted directory together and run
`tasks_viewer.exe`. No SDK is needed. If Windows reports a missing Visual C++
runtime DLL, install the [Microsoft x64 Visual C++ Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe).
The viewer enables Start with Windows on its first normal launch; turn it off
in Settings if you only want to try it. Its task database and settings live
outside the extracted directory.

The packages include `QUICKSTART.md`, `release-metadata.json`, dependency notices
and hashes of their individual files. Updates are manual: close any running
viewer, extract the new package and replace your CLI or launch the new viewer
bundle. Back up task data before upgrading. See [the first-run example](#first-run)
or use the isolated architect walkthrough below.

## Supported targets

| Component | Verified target | Other platforms |
| --- | --- | --- |
| CLI | Windows x64; native Linux x64 on Ubuntu in WSL, with separate storage | Other distributions need native verification. No macOS build or test has been run. |
| Viewer | Windows 11 x64, including owner-tested NVDA use | No Linux or macOS viewer build. |
| Server | Linux amd64 container, including a documented QNAP deployment | Other architectures are unverified. |

The Linux download is built natively on Ubuntu 22.04 and requires glibc 2.35
or newer; Alpine/musl is not supported by that binary. macOS is unverified
because the maintainer currently has no machine for it.

## Build the CLI

Install rustup and the native C build tools. On Windows, use the MSVC C++ build
tools and Windows SDK. On Ubuntu, install the distribution's C build toolchain.
The checkout pins Rust in `rust-toolchain.toml`; keep `Cargo.lock` intact.

Clone [the repository](https://github.com/MaxLogic/tasks-cli), then build from
its source directory on Windows:

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

## Release maintenance

The [native release workflow](release/README.md) runs the CLI gates on Windows
and Ubuntu, verifies the Windows viewer, and smoke-tests each archive after
extraction with a temporary store. Successful version tags prepare draft archives
and SHA-256 checksums. The maintainer verifies the downloaded Windows viewer's
native accessibility tree before publishing through GitHub Releases. Workflow artifacts from branch
builds are for evaluation; use Release assets for public downloads.

Hosted tests do not replace a clean-machine trial or live NVDA/audio checks.
Those results must identify the tested release and remain separate from CI
results. Portable archives are the initial distribution format; there is no
installer or automatic updater.
