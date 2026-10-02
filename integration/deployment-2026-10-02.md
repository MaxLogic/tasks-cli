# Viewer install and open-task verification, 2026-10-01 to 2026-10-02

The user authorized the viewer install, agent-driven NVDA Speech Viewer and
console verification, and a bounded root-cause investigation of TSK-017.
The source input was `88b42cafeab75026f6403ed9b7e8300effa25a79` on `main`,
plus the related viewer fixes committed with this record. Unrelated untracked
work was preserved. The viewer bundle owns a copy of the CLI; the installed
Windows and WSL CLI symlinks were not replaced.

## Changes and focused proof

- TSK-008: the Flutter tester starts with a windowless console. Detach it and
  attach to the hidden console-owning verification host. An `inheritStdio`
  control child reports the host's console HWND; the production launcher child
  reports zero. Required proof fails instead of skipping. The first full gate
  passed 12/12 with `console_window_proof: passed`.
- TSK-018: the pending write disables Mark done and loses its focus before a
  real CLI refusal arrives. Restore the initiating header button after it is
  enabled, guarded by the same project/task and clean editor. Delayed tests
  cover keyboard, pointer, header/list Ctrl+D, context menu and a dirty editor:
  six passed. The initial delayed-header test failed before the fix.
- TSK-019: the matching Flutter Windows bridge transfers labels but omits
  `Semantics.hint`. Put the prerequisite hint in the action's accessible name,
  with its visible copy excluded from semantics. Header and menu semantics
  checks failed before the fix; their owning suites passed 68 tests before
  four additional initiator cases were added.
- TSK-020: G06 exposed a fixture defect. Its injected 500 ms acknowledgement
  deadline also covered setup reads; `fetchTaskDetail` timed out before any
  update. A test-only client now scopes that deadline to the update, and
  closing its stdin waits for the existing pre-commit marker. An 800 ms read
  response delay proves the old fixture fails and the new fixture passes.
  Three real-CLI tests passed, with one committed update and successful
  reconciliation. Production timeouts and launch behavior are unchanged.

Focused RED/GREEN logs, source hashes, leases, screenshots and incremental
NVDA captures live under `target/evidence/open-tasks-20261001-145502/`.
`final-candidate-inputs.json` records the final source/proof file hashes.
Only newly generated Speech Viewer text was captured, using a bounded read
of its validated RichEdit HWND and PID. Real settings and task data were not
used by native verification.

## Gate history

- `viewer/target/evidence/viewer/2026-10-01-open-tasks/`: all 12 gates passed;
  585 full-suite tests passed, one documented test-hooks skip, three hook cases
  passed, five headless end-to-end cases passed, and 70 native provider nodes.
  Pester `viewer/tool/tests` also passed 77/77. This run preceded the native
  accessibility fixes.
- `viewer/target/evidence/viewer/2026-10-01-open-tasks-final/`: G00-G05 passed;
  G06 failed with two passed and one failed acknowledgement-loss case. The
  original failed log remains intact. Later gates were not run. TSK-020 was
  created and corrected from this evidence.
- `viewer/target/evidence/viewer/2026-10-02-open-tasks-final/`: all 12 gates
  passed. Formatting and analysis passed; the full suite passed 589 cases
  with one documented hook skip, closed by three passing G06 cases. Five
  headless end-to-end cases passed. Packaging validated 40 files and 20 clips;
  G11 exposed 70 native provider nodes. `console_window_proof` is `passed`.

## Installed bundle and remaining native acceptance

`target/viewer-release/` was rebuilt and packaged by the final gate. Its hashes:

- `tasks_viewer.exe`: `b56b160878db840e5bff4926b3242cf3473440d16bd58237619438e6a91d190c`
- `data/app.so`: `448d6dcfafd4c861b162998897365c9f58dd3c235e3f6700f4efffb0303c470b`
- bundled `tasks.exe`: `12a36c623088831f9c5aa3994d5dc1aa23d698f2ed022840263a4a7258b5b749`

The bundle metadata records base HEAD plus a dirty source tree. The tracked
code/test diff and `final-candidate-inputs.json` identify that tested candidate;
the base HEAD alone does not identify the new Flutter payload.

The isolated new viewer's native MSAA button name is
`Mark done. Needs ALPHA-009 done first`, recorded in
`nvda-final-native-action-names.json`. This confirms the native name, not NVDA
speech. NVDA restarted between sessions and Speech Viewer is now closed;
reopening it was requested. Attempts to reopen its menu did not produce a
readable Speech Viewer. All foreground input was leased and guarded; an
attempt interrupted by a foreground change was discarded. No unrelated
NVDA dialog or other application was operated.

TSK-008 and TSK-020 are done. TSK-018/019 remain to-verify, TSK-007 remains
blocked on the final live speech/focus pass, and TSK-009's issue directories
remain in place. They will close in dependency order after native acceptance.
The full V10 walkthrough and physical monitor/sign-in/audio cases were not
claimed by the automated gate.

The synthetic viewer (PID 199524) was stopped after its executable path was
checked. The normal installed viewer was restarted with no fixture arguments,
requested minimized to preserve the user's current work, and confirmed running
as PID 256856 from the bundle path with title `Tasks Viewer` and HWND 45483454.
Real settings and task data were preserved. Restart logs are in the run root.

## TSK-017: cause remains unresolved

The original bare-FLUTTERVIEW failure did not recur. Five original-path
packaged probes exposed 70 nodes without retry. Two probes delaying the first
external accessibility query by 20 seconds also passed with 70 nodes. This
does not confirm the hypothesis that an early Dart semantics update was
discarded before the native accessibility bridge existed: NVDA itself may
have queried the windows sooner. No speculative production or timeout change
was made for this defect. The existing narrow retry remains a mitigation.

The matching Flutter engine (`c416acfeb8126e097f758c664aaa3da929e27da0`) sources
and the detailed investigation are retained under the run's `upstream/` and
`tsk-017-investigation.md`. TSK-017 remains blocked, as requested when the
cause cannot be established now.

To resume diagnosis, retain the next failing process while it is still alive:
PID, Win32 child HWND, provider snapshots, elapsed time, exact launch mode,
screenshot and window responsiveness. Compare a fresh MSAA retrieval with
raw `WM_GETOBJECT` and capture bridge activation/update timing. The current
timeout snapshot cannot distinguish an unpopulated bridge, a stalled UI
thread or a cached fallback, and the probe normally kills the process.

## User acceptance and archival, 2026-10-02

The user confirmed: "NVDA is playing fin. you can close those tickets."
TSK-018, TSK-019 and TSK-007 were closed on that confirmation, with the
previous automated and native evidence retained. This does not claim another
agent-observed Speech Viewer or keyboard walkthrough. TSK-009 was then closed:
both complete issue directories moved to `issues/closed/`, review follow-ups
were annotated, and source references in repository files and tasks were updated.
The archived CSV has the same Git blob as before the move. No implementation
tests were rerun for this archival. Evidence is under
`target/evidence/closure-server-design-20261002/`.

The subsequent TSK-017 log review found no recorded recurrence after the
2026-09-30 bare-FLUTTERVIEW failure. Both later completed G11 checks returned
70 nodes with `Retried: false`; the seven October 1 investigation probes also
returned 70 nodes without retry. The intervening failed G06 run did not execute
G11. The ordinary viewer does not continuously log its native provider tree,
so this finding covers saved verification evidence, not every interactive use.
TSK-017 remains blocked pending a captured recurrence; no speculative fix was made.
