# Build and publish a release

`.github/workflows/release.yml` tests native Windows x64 and Ubuntu 22.04 x64
CLI builds and builds the Windows viewer. A push to `main`, a pull request or
a manual run produces workflow artifacts. A `v*` tag additionally publishes
a draft GitHub Release after all three build jobs pass. Only the publishing job has
permission to write repository content.

For each release:

1. Update the Cargo version and `release/notes.md`. Review the installation
   guide, platform baselines and pinned Rust/Flutter versions.
2. Commit the candidate and let its `main` workflow pass. Inspect CLI tests,
   viewer verification and packaged smoke checks in the workflow logs.
3. Tag that commit `v<version>` and push the tag. CI creates a draft and uploads
   all archives and checksum files.
4. Download the draft assets with `gh release download v<version>`, check
   `SHA256SUMS.txt`, and try the extracted archives with temporary storage.
   On Windows 11 run `pwsh -NoProfile -File release/verify-viewer.ps1 -BundleRoot
   <extracted-viewer-directory>`. It checks file hashes, opens the exact candidate
   against isolated data and verifies native project and Settings controls.
   Keep its JSON and log with the release evidence.
5. After the candidate checks pass, publish with `gh release edit v<version>
   --draft=false --latest`. Download the public assets and recheck their hashes.
   Record clean-machine and live screen-reader checks separately.

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

The hosted Server 2022 runtime returns a bare `FLUTTERVIEW` object instead of
the viewer's native accessibility tree. On 2026-10-06 the same CI-built bundle
passed on Windows 11 with 70 native nodes and accessible Settings. Hosted runs
therefore pass `-SkipReleaseUia` and record G11 as unavailable. The default
local verifier still requires G11. A successful hosted build alone is not
release acceptance; draft releases await the Windows 11 candidate check.

The screenshot fixtures use installed Segoe UI fonts and local timestamps in
the Warsaw timezone. Windows 11 and Server 2022 have separate reviewed
references because their label-glyph rendering differs by two pixels per
fixture. CI selects the Server 2022 baseline, sets the reference zone and
retains image diffs on failure. Both baselines use exact pixel comparisons.

For local packaging, build into an isolated target, set `TASKS_BUILD_COMMIT`
to the source commit, and invoke `release/package.py --help`. Do not replace
the maintainer's installed default release target or viewer bundle. Pass
`-PackageOutputRoot <repository>/target/public-viewer` to the viewer verifier
when preparing a separate distributable.

macOS builds remain unverified and are not included. The server has source
build and container instructions; it is not part of these portable downloads.
