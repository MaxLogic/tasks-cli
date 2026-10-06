# Build and publish a release

`.github/workflows/release.yml` tests native Windows x64 and Ubuntu 22.04 x64
CLI builds and builds the Windows viewer. A push to `main`, a pull request or
a manual run produces workflow artifacts. A `v*` tag additionally publishes
a GitHub Release after all three build jobs pass. Only the publishing job has
permission to write repository content.

For each release:

1. Update the Cargo version and `release/notes.md`. Review the installation
   guide, platform baselines and pinned Rust/Flutter versions.
2. Commit the candidate and let its `main` workflow pass. Inspect CLI tests,
   viewer verification and packaged smoke checks in the workflow logs.
3. Tag that commit `v<version>` and push the tag. Publication creates a draft,
   uploads all archives and checksum files, then publishes the complete release.
4. Download the public assets, check `SHA256SUMS.txt`, and try the extracted
   archives with temporary storage. Record additional clean-machine or live
   screen-reader checks separately from hosted automation.

The tag must match `Cargo.toml`. Published versions are immutable inputs for
users: fixes get a new version and tag. A failed publishing job may leave a
draft release. Inspect it with `gh release view <tag>`; repair the failed step
and upload the missing assets before publishing. Do not replace public assets
or move an existing release tag.

The archive tool uses Python 3.13's standard library. It includes MIT and Rust
dependency notices, checks the embedded commit, exercises a synthetic task
through a stale update and verification handoff, then repeats the CLI check
after extraction. Linux archives preserve executable permissions. The viewer
archive also includes Flutter notices, audio provenance, the full runtime and
its matching CLI. `viewer/tool/package.ps1` checks clip hashes and runs packaged
startup/argument checks; `verify-windows.ps1` adds real-store widget and UIA checks.
CI does not prove audible playback or NVDA speech on a user's machine.

For local packaging, build into an isolated target, set `TASKS_BUILD_COMMIT`
to the source commit, and invoke `release/package.py --help`. Do not replace
the maintainer's installed default release target or viewer bundle. Pass
`-PackageOutputRoot <repository>/target/public-viewer` to the viewer verifier
when preparing a separate distributable.

macOS builds remain unverified and are not included. The server has source
build and container instructions; it is not part of these portable downloads.
