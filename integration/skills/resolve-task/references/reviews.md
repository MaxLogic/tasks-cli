# Risk-based reviews

Use independent review where a second perspective is likely to change the
outcome. More reviewers are not automatically more confidence.

## Selection

- Low-risk localized task: self-review.
- Medium-risk task: one reviewer when behavior crosses a boundary.
- High-risk task: one specialty reviewer per task plus broader final review.
- Large multi-task goal: architecture review before implementation only when an
  unresolved design risk can change the plan. Use two final reviewers only for
  broad/high-risk work, with named non-overlapping scopes; size alone is not a
  reason to reopen a settled design.

Good specialty scopes include concurrency/lifetime, persistence, security,
compatibility, performance harnesses, and live UX/accessibility.

One task reviewer is the default cap. Add a second only when the run state names
the distinct risk it covers and why the first reviewer cannot cover it. Pure
test ports, test deletions, documentation, and mechanical registrations usually
need self-review plus the next batch gate, not a reviewer per file.

## Timing

Ask for architecture/acceptance feedback before coding when it could change the
design. Ask for implementation review after GREEN and cheap stabilization, but
before the task-tier gate. Give the reviewer the RED/GREEN result and available
focused-check evidence. Run independent reviews in parallel only when they are
read-only and genuinely independent.

Record review duration and verdict. If review time materially exceeds the
implementation/proof time for two consecutive tasks, consolidate review at the
next shared-risk boundary unless a specific unresolved risk justifies it.

## Risk checklist: review before the reviewer

Independent review after "done" doubles the work when it keeps finding the same
defect classes. In one run every high-risk lane needed a second round, and ten
reviews found the same eight classes. Move those checks in front of the report.
This section applies to medium and high-risk tasks. A low-risk task keeps plain
self-review.

1. **The author self-checks.** Before reporting a medium or high-risk task, the
   author (worker or orchestrator) checks the change against the project risk
   checklist and states the result per item: checked and clean, checked and
   fixed, or not applicable with the reason. "Reviewed, looks fine" is not a
   result.
2. **The orchestrator maintains the checklist.** Keep it in the common worker
   brief, or in `STATE.md` working notes when there are no workers. Start from
   the list below, delete items that cannot occur in this project, and append
   the class of every confirmed review finding as one line that names the
   pattern, not the instance. A finding that repeats an existing class means
   the self-check is being skipped: tighten the brief instead of adding a line.
3. **Starter checklist.**
   - Success reported after a failed flush, sync, commit or journal write.
   - An untrusted layer (frontend, client, caller-supplied flag) acting as the
     authorization or safety boundary.
   - Identity decided by path or name text where object identity is required
     (file ID, inode, handle, primary key, content hash).
   - An unbounded reply, query, queue, buffer or loop over external input.
   - A check made before taking a lock, lease or transaction and not repeated
     under it.
   - A swallowed error: discarded result, empty catch, default value in place
     of a failure.
   - A test that passes for the wrong reason: accepts any error, asserts a
     constant, greps source text by layout, or never runs the asserted path.
   - A hard-coded count of tests, assertions, rows or cases that another change
     will legitimately alter.

## Reviewer packet

Provide:

- task outcome and acceptance checklist;
- exact candidate revision/diff;
- relevant design constraints;
- RED/GREEN and available proof summary, and the author's checklist result;
- the fixed questions below plus any task-specific question;
- required verdict: `PASS` or `REVISE` with blocking findings.

Fixed questions, answered one by one:

1. Does any must-fix exist? Answer "Must-fix: none" or list them first, each
   with file, line, the failing scenario and the expected behavior. Do not
   leave it to be inferred from the prose.
2. Which checklist items did you verify in the code, and which could you not
   verify from the packet?
3. Can each new test fail? Name a test that would still pass with the fix
   removed.
4. Which acceptance criterion has no direct proof?
5. What did the change make worse outside its task (contracts, limits,
   recovery, other callers)?

Should-fix and notes come after the must-fix answer and do not block.

## After the review

Validate reviewer findings against the code before changing it. Send confirmed
findings back to the worker that wrote the change while its context is intact;
a fresh worker pays the whole reading cost again. Each must-fix is its own
RED/GREEN slice: show it failing, fix it, show it passing. Rerun affected proof
and request re-review of the fix diff only. Close the task, and record its
review verdict, after the fix round, never between report and review. Append
each confirmed class to the checklist. Three review-fix cycles without new
evidence indicate a blocker, not a mandate to keep patching.
