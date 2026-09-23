# Self-improvement review: accessibility verification boundary

Date: 2026-09-23
Originating project: `F:\projects\MaxLogic\tasks-cli`
Original objective: Fix the Tasks Viewer Settings accessibility defect and improve the test that had missed it, while skipping Windows DPI changes.
Trigger and timing: Manual review after the user challenged whether the UX skill required the full screen-reader test.
Review outcome: Proposal ready

## Evidence and diagnosis

The existing `ux-design` skill says that an automated accessibility scan cannot
prove accessible task completion, requires implemented work to exercise the
keyboard and focus path with suitable platform tools, and says unavailable
assistive-technology verification must be reported. Its Windows reference also
lists UI Automation and NVDA or Narrator as candidate checks and distinguishes
automated scans, accessibility-tree snapshots, and assistive-technology
walkthroughs.

That guidance was partly successful: the implementation report did not claim an
NVDA run had occurred. It was not decisive enough at the acceptance boundary.
The reference calls the checks "candidate manual checks" and says not all must
be run for a one-control correction. That allowed a user-reported screen-reader
defect to be treated as complete after improving only headless semantics tests.
The user's exclusion applied to changing DPI, not to UI Automation or NVDA.

| Evidence | Reference and excerpt | What it establishes |
| --- | --- | --- |
| Current canonical skill | `D:\Pawel\Prompts\skills\ux-design\SKILL.md:90-97`, version 1.1.0 | The principle and honest-reporting rule already existed. |
| Current platform reference | `ux-design/reference/platform-and-accessibility.md:8-22,68-70` | UI Automation and NVDA were listed, but only as candidate checks. |
| Current session | The audit had checked tap targets and basic actions but missed unnamed text fields and unnamed route scopes. | A green custom audit was not sensitive to the reported failure class. |
| Current session | The user excluded changing Windows DPI and then asked why the full accessibility test was not required. | Other live accessibility evidence remained in scope. |
| Skill repository history | Experimental commit `f85604e`; restored by `006717c` pending approval. | A concrete candidate diff was inspected and structurally validated, but is not live. |

History scope and coverage: Current-session evidence and the canonical skill were sufficient; no session-history search was needed.
Prior decisions checked: No related review existed in the originating project's `.agents/reviews/` directory.

## P1: Require layered proof for a reported assistive-technology defect

Status: Proposed, awaiting approval
Target: `D:\Pawel\Prompts\skills\ux-design\SKILL.md`, `reference/platform-and-accessibility.md`, and `evals/evals.json`
Baseline: canonical skill repository revision `006717cdf0f22a19d3217a9b9794335352e08be2`; skill version 1.1.0
Cause addressed: Existing guidance named the relevant evidence types but did not make the reported assistive technology's exact-candidate rerun an acceptance requirement.

```diff
 For implemented work, exercise the relevant primary task, keyboard/focus path,
 navigation and return, and failure/recovery path with suitable platform tools.
+When a user reports an assistive-technology failure, require reproduction and
+an exact-candidate rerun with that technology before calling the defect fixed.
+Treat source checks, lints, rendered semantics, and platform accessibility-tree
+inspection as distinct evidence layers, not substitutes for that rerun.
+If the live layer is unavailable or excluded, report the defect as not yet
+confirmed fixed. Excluding one check, such as DPI changes, excludes only that
+check unless the user says otherwise.
```

Add the following supporting requirements to the platform reference:

1. Inspect names, roles, values, states, actions, relationships, dialog or route
   names, feedback, traversal, initial focus, modal containment, and restoration.
2. Add a deliberately defective negative-control fixture proving that each
   custom audit detects the failure it claims to guard against.
3. Inspect UI Automation names, control types, patterns, state, order, and focus
   events on the exact Windows candidate.
4. Reproduce and rerun the affected task with the reported screen reader,
   checking discovery, announcements, operation, errors, recovery, and focus.

Add an eval case based on a Windows Flutter Settings dialog whose old green test
checks only labelled tap targets and basic actions. The expected answer must keep
UI Automation and NVDA in scope while excluding only DPI changes.

Expected benefit: Future work will not confuse a stronger widget test with proof that a user-reported NVDA failure is fixed.
Downside or counterexample: The rule should not require every assistive technology for an unrelated visual correction or when no specific technology reported the defect; those cases still use a scoped matrix.
Dependencies: None.
Verification scenario: In a fresh-context eval, ask an agent to fix the described Settings defect while prohibiting DPI changes. It should require the negative control, exact-candidate UI Automation inspection, and NVDA walkthrough, and should keep the issue unconfirmed if the live run is unavailable.
Checks already run: Candidate version 1.2.0 passed `quick_validate.py`, invocation-policy validation across 76 skills, JSON parsing with five unique eval IDs, and `git diff --check`. The candidate was then reverted because live skill edits require prior approval.
Checks not yet run: Fresh-context old-versus-new eval and live application UI Automation/NVDA verification. Structural validation does not establish behavioral improvement.

User decision: Awaiting approval as of 2026-09-23.
Implementation and verification: Not applied. Candidate commits `f85604e` and `006717c` preserve the proposed and reverted diffs in local skill-repository history.
