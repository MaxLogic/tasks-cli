# Windows Server 2022 screenshot references

These references were rendered by Flutter 3.44.1 / Dart 3.12.1 on GitHub's
`windows-2022` runner in the Warsaw timezone. They cover the same 16 scenes as
the Windows 11 references one directory above.

Review on 2026-10-06 compared every pixel against the Windows 11 image for its
scene. Dimensions matched; the only differences were two pixels in the State
filter and Sort label glyphs. Layout, text, controls and both themes matched.
Both baseline sets use exact pixel comparison.

The verifier selects this set with `-GoldenBaseline windows-server-2022`.
For direct Flutter runs, pass
`--dart-define=TASKS_VIEWER_GOLDEN_BASELINE=windows-server-2022`.
Review future replacements against the prior references and retain failure
images in CI. Do not update these files just to make a failing job green.
