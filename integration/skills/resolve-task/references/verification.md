# Verification tiers

Use the cheapest gate that can falsify the current change, then widen at
deliberate checkpoints. This keeps feedback fast without weakening final proof.

For a full run, record the task, batch, and final commands before implementation.
Map each task ID to its focused commands and name the task IDs after which batch
gates run. Do not put a batch/Final command in every task entry; if a task really
needs one, record its task-specific cadence exception. A broad command outside
the schedule needs an escalation reason such as a shared runner, storage,
lifecycle, security, or public-contract change.

## Establish the acceptance path

Before broad certification, identify the command or public entry point that
acceptance actually exercises, including executable, build/platform, options,
dependencies, fixtures, and cache mode. Confirm a focused end-to-end result on
that path. A compatibility API or diagnostic probe may explain behavior, but
its proof does not certify a different production route. Record intentional
route differences before investing in full-suite or compiler proof.

For persistence, migration or legacy-compatibility work, also identify the
materially different representations reached by the supported production
writers and options. In the existing acceptance checklist, classify each as
tested, explicitly refused, or unverified. Use a focused fixture for each
distinct storage path before broad certification; do not infer coverage from
logical schema or test count alone. Limit this to variants that change the
implementation path, not every combination of inputs. Scope completion claims
to that evidence.

## Task tier

Run for every task after its frozen source/proof inputs have passed focused
review and before an authorized commit. Before review, use only the cheap
stabilization subset: exact tests, owning fixture, compile/type-check, and
diff/resource hygiene.

1. The exact RED/GREEN test target.
2. The owning fixture, package, or module suite.
3. Compile/type-check the changed production surface.
4. Lint/static analysis limited to touched files or rules when supported.
5. Validate touched UI resources, schemas, migrations, or generated contracts.
6. Satisfy the task's reconciled `Proof` requirements. Execute literal commands
   or record an approved, input-matched coverage mapping; never list a command
   as executed merely because another run covers its requirement.
7. Check diff, encoding, and staged scope.
8. Repeat affected checks after the last code change.

Project-wide analysis is normally a batch/Final command. Scheduling it at task
tier requires a concrete cadence exception, such as a task that changes the
analyzer, build graph, shared runtime, or public contract. Run review first so
review-driven source fixes do not waste an expensive analysis pass.

For low-risk documentation/configuration tasks, use the strongest meaningful
text/schema/build check and state why behavioral TDD does not apply.

## Batch tier

Run after about 3–4 related tasks, before moving across a dependency boundary,
or immediately after changes to shared infrastructure:

- broad/full product tests;
- production/Release build;
- project-level static-analysis delta;
- grouped UI/resource/schema validation;
- integration or smoke tests across the changed workflow.

Shorten the interval when commits touch shared lifecycle, persistence, public
APIs, build infrastructure, or security boundaries. Lengthen it for isolated
leaf changes only when repository policy allows.

Do not classify fixture registration, manifest entries, or a new test file as
shared infrastructure by itself. Escalate when runner selection, common helper
behavior, process/resource ownership, or a production boundary changes.

If a batch gate finds a regression in an earlier completed task, create a new
defect task referencing the originating task. Do not rewrite history silently.

## Batch and final gates report every failure

A runner that stops at the first failing unit hides the rest: `cargo test`
stops at the first failing test binary, and that hid a second failure for a
whole batch. Run batch and final gates so that one failure does not stop the
others, and list every failure in the gate record:

- use the runner's keep-going mode (`cargo test --no-fail-fast`, `go test`
  without `-failfast`, `pytest` without `-x`, `make -k`, `ctest` without
  `--stop-on-failure`);
- in a gate script, run every command, capture each exit code and log, and
  print one result line per command. Do not chain gate commands with `&&`;
- the gate's exit code is nonzero when any command failed.

Fail-fast remains right for the task tier, where the first failure is the one
being worked on.

## Environment gaps

A batch gate whose only failures come from a missing environment prerequisite
(network share, elevation, device, credentials, licensed tool) is recorded as
`pass_with_environment_gap`, never as a plain `pass` and never as an
unexplained `fail`:

```json
{"status": "pass_with_environment_gap", "exit_code": 101,
 "environment_gaps": [{"prerequisite": "SMB fixture share (TEST_UNC_ROOT)",
                       "failed": ["scan-accounting network-and-remote-consent"]}]}
```

Keep the native exit code. Name each prerequisite and the exact checks it
failed, and confirm from the output that each of those checks failed for that
reason and no other. Every other check must pass. Carry the gap into the final
report.

The status exists only for batch gates. A task whose own proof needs the
missing prerequisite is blocked, not complete. A final gate needs a plain pass:
provide the prerequisite, or report the affected criteria as unproven.

## Final tier

Run once the requested scope is otherwise complete and every selected
SQLite task lifecycle transition has been applied:

1. Materialize one clean exact candidate or `HEAD`.
2. Initialize the exact dependency/submodule revisions without junction or
   live-worktree leakage.
3. Run the full suite with the repository's required zero-failure policy.
4. Run all required production builds and validators.
5. Run full static analysis and compare with the recorded baseline.
6. Run non-functional acceptance: performance, security, accessibility,
   packaging, migration, or live UI proof as applicable.
7. Run final independent review when full mode/high risk requires it.

Every final claim must come from this same candidate. If one command cannot run
in the isolated environment, fix the environment or report the gate unproven.

## When a final bundle fails

Classify the failure before rerunning. A product or test defect returns to the
task loop. When the failures share an environmental cause (host load, shared
ports, address pools, timing under parallel workers), different failing files
are one recurring failure, not new ones. A full bundle is too expensive a tool
for finding the next member of that class: one run spent nine 70-minute bundles
and twenty review rounds moving a few test files per attempt.

1. Rerun only the failing step under the same load (same worker count and
   background services) until it passes twice in a row. Collect every failing
   unit, not just the first set.
2. Fix the class once: adjust worker bounds, isolation, or the shared resource.
   Quarantining units one bundle at a time is a last resort.
3. Then run one full bundle on the frozen candidate.

This applies only to a diagnosed environmental cause. A failure that reproduces
solo or has no explanation is a defect; use systematic debugging.

A delta that changes only test scheduling or comments (no assertion, timeout,
bound, fixture, or production byte) is verified by the orchestrator's exact
diff inspection, recorded in the existing review entry. It does not need a new
independent review round or a byte-reconstruction script. A changed timeout or
bound can hide a product regression and keeps its review. Classify test runners
and rosters as proof inputs, not source inputs, unless they ship in the
product, so such a delta leaves `source_input_hash` and source-only analysis
valid.

## Gate reuse and invalidation

Before an expensive rerun, use the existing gate record to answer:

1. Which consumed input, tool version, or option changed?
2. Which concrete unresolved risk requires this command?
3. Does an explicit task, scheduled batch, or final requirement require a fresh
   run despite unchanged inputs?

If none applies and the retained proof is verifiable, reuse it. If proof is
missing or input identity is uncertain, rerun the smallest affected gate.
Record the reason in the existing command entry; do not create another ledger.

For successive test-only batches, rebuild the affected test target and run the
changed tests and owning fixture. Keep touched-test analysis where required;
reuse production builds and source-only analysis whose inputs are unchanged.
Changes to a shared helper or runner can justify broader checks. Run the broad
suite at its scheduled checkpoint; test edits still invalidate older suite
proof and never exempt the final retained suite.

Reuse a passing broad gate only when its relevant input fingerprint is
unchanged. Record separate fingerprints when useful:

- `source_input_hash`: production source, manifests/build configuration,
  generated resources, dependency revisions, and analyzer/compiler inputs;
- `proof_input_hash`: source inputs plus tests, harness code, and data/schema
  fixtures consumed by the proof.

A task-ledger, changelog, review-note, or test-only edit does not invalidate a
source-only analyzer result when its source inputs, tool version, and options
are unchanged. It does invalidate evidence that consumes the edited test or
fixture. Updating a task status after its focused gate does not invalidate that
gate unless the command consumes the ledger. The database transition changes durable state; capture the final ledger versions with the delivery candidate, so complete ledger maintenance before the Final tier.
Record `reused_from` and the matching fingerprint; uncertainty invalidates
reuse.

## Baseline failures

Record exact baseline command, failure identity, and revision before changes.
An unchanged baseline failure may permit focused work only when the user or
repository policy allows it and the current slice remains independently
provable. A requested zero-failure final gate still blocks completion.

Repeated flaky failures are defects. After the second recurrence, invoke
systematic debugging instead of normalizing retries as a passing gate.

## Evidence record

Keep three things separate in the existing owning record:

- **Requirements:** the prospectively agreed task/batch/final schedule.
- **Executions:** literal commands actually run, native exit codes, durations,
  candidate identities, input fingerprints and direct proof references.
- **Coverage:** which required cases each execution or unchanged reusable
  component satisfies, and why options, environment and review stage match.

One combined run may satisfy several requirements. A requirement may use fresh
and retained components with separate current fingerprints; each must include
all shared inputs it consumes. Case identities and direct proof matter, not
matching totals or file names. Never manufacture command entries to appease a
validator. See [proof-coverage.md](proof-coverage.md) for the
optional backwards-compatible structured representation.

An explicitly permitted inherited compiler/typed-lint diagnostic qualification
retains the native nonzero exit code and its individual-diagnostic evidence.
It is not a passing compiler run and cannot certify a zero-diagnostic Final
gate. Old qualified task history can remain while a later fresh Final gate
proves zero diagnostics. Tests, missing tooling, crashes and bad configuration
cannot use the inherited-diagnostic exception.

For each gate retain:

```text
candidate revision/hash
command
exit code
pass/fail/skip
duration seconds
test counts or key metrics
scheduled checkpoint or escalation reason
reused-from gate ID, if applicable
artifact summary path (if needed)
```

Keep raw logs only for failures or when the user requests a full audit trail.
