# Self-improvement review: accessibility verification boundary

Date: 2026-09-23
Originating project: `F:\projects\MaxLogic\tasks-cli`
Original objective: Fix the Tasks Viewer Settings accessibility defect and improve the test that had missed it, while skipping Windows DPI changes.
Trigger and timing: Manual review after the user challenged whether the UX skill required the full screen-reader test.
Review outcome: Approved, applied, and verified within the focused scenario

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

Status: Applied and verified
Target: `D:\Pawel\Prompts\skills\ux-design\SKILL.md`, `reference/platform-and-accessibility.md`, and `evals/evals.json`
Baseline: canonical skill repository revision `006717cdf0f22a19d3217a9b9794335352e08be2`; skill version 1.1.0
Cause addressed: Existing guidance named the relevant evidence types but did not make the reported assistive technology's exact-candidate rerun an acceptance requirement.

```diff
 For implemented work, exercise the relevant primary task, keyboard/focus path,
 navigation and return, and failure/recovery path with suitable platform tools.
+When a user reports an accessibility failure, prefer repeatable automation and
+require evidence that crosses the boundary where it failed. For app-side
+semantics defects, require sensitive framework tests and an exact-candidate
+platform accessibility-API test. Use the reported assistive technology for
+technology-specific behavior or an unresolved mismatch. That run may be
+automated in an isolated session; manual control is not inherently required.
```

Add the following supporting requirements to the platform reference:

1. Inspect names, roles, values, states, actions, relationships, dialog or route
   names, feedback, traversal, initial focus, modal containment, and restoration.
2. Add a deliberately defective negative-control fixture proving that each
   custom audit detects the failure it claims to guard against.
3. Inspect UI Automation names, control types, patterns, state, order, and focus
   events on the exact Windows candidate.
4. Reproduce and rerun the affected task with the reported screen reader when
   the claim depends on its speech, browse/caret behavior, announcement timing,
   custom interaction, or an unresolved mismatch. Prefer unattended execution
   in an isolated Windows test session.

Add an eval case based on a Windows Flutter Settings dialog whose old green test
checks only labelled tap targets and basic actions. The expected answer must keep
UI Automation in scope while excluding only DPI changes. It must distinguish an
app-side platform-contract defect from behavior that specifically requires NVDA.

Expected benefit: Future work will not confuse a stronger widget test with proof that a user-reported NVDA failure is fixed.
Downside or counterexample: The rule should not require every assistive technology for an unrelated visual correction or when no specific technology reported the defect; those cases still use a scoped matrix.
Dependencies: None.
Verification scenario: In a fresh-context eval, ask an agent to fix the described Settings defect while prohibiting DPI changes. It should require the negative control and exact-candidate UI Automation inspection, require real NVDA only for NVDA-specific behavior or an unresolved mismatch, and prefer unattended execution in an isolated test session.
Checks already run: Version 1.2.0 passed `quick_validate.py`, invocation-policy validation across 76 skills, JSON parsing with five unique eval IDs and seven expectations in eval 5, and `git diff --check`. In the final fresh-context comparison, both the 1.2.0 candidate and 1.1.0 baseline selected sensitive Flutter semantics plus exact-candidate UI Automation as sufficient for the diagnosed app-side defect, while reserving real NVDA for NVDA-specific behavior or an unresolved mismatch. The candidate met all seven expectations; the tie establishes focused non-regression, not added value.
Checks not yet run: The Tasks Viewer still has no automated exact-release UI Automation gate. No real NVDA run was performed. These product checks are separate from verification of the skill revision.

User decision: P1 approved on 2026-09-23. In the same message, the user preferred an automated test over manually controlling their NVDA session; that clarification is incorporated above.
Implementation and verification: Applied to skill version 1.2.0 in canonical skill-repository commit `b0d79e0`. The deployed skill is linked to that canonical source. Focused validation passed with the limits above.
