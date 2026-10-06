# Ownership, claiming and planning fields

Proposal dated 2026-10-06. None of the new fields or commands below is
implemented or an accepted extension to `spec.md`.

The preferred workflow has one architect selecting work, dispatching bounded
assignments and recording lifecycle transitions. Workers return patches and
proof. That already addresses duplicate assignment within one coordinated team.
Adding features should reduce a demonstrated coordination cost, not reproduce
every field in a general project-management system.

## Recommendation

| Feature | Recommendation now | Reason to reconsider |
| --- | --- | --- |
| Dedicated assignee | Defer; put the worker and owned paths in the architect's brief | Repeated need to query ownership, recover abandoned work or coordinate several architects |
| Atomic claim | Defer while the architect dispatches all work | Workers or independent coordinators need to select from the same queue |
| Expiring lease | Defer | Long-running unattended workers need detectable ownership loss and a safe recovery protocol |
| Goals and milestones | Use explicit task-body sections and grouping labels | Users need hierarchy queries, milestone reports or goal-specific acceptance |
| Structured acceptance criteria | Keep Markdown checklists in bodies | Users need stable criterion IDs, independent evidence records or machine-readable gate queries |

For grouping, labels such as `goal:parser-refresh` and `milestone:v1` are already
valid. They are conventions without referential integrity. Bodies can separate
Outcome, Scope, Acceptance criteria and Proof. Neither a checked box nor a task
status demonstrates that a test actually passed.

## Smallest ownership extension, if needed

Add nullable `assignee` text to tasks and expose `update --assignee NAME`,
`update --clear-assignee` and `list --assignee NAME`. Bound and validate the name;
do not build an account directory. A stable worker name supplied by the architect
is more useful than guessing ownership from the latest writer's session.

Include the field in show/list JSON, new history snapshots, import/export,
server request types and the viewer. Changes use the existing expected-version
transaction. Preserve old snapshots unchanged; missing assignee means unassigned.
Use the next schema version with the existing verified-backup migration process.

Assignment is descriptive, not authorization: recording an owner does not
prevent another agent from editing source or operating the CLI. Authenticated
mutation attribution identifies the writer and remains separate from assignment.

## Atomic claiming, if independent selection becomes necessary

Build claiming on explicit assignment, not on a second lock file. A proposed
`claim ID --expect-version N --assignee NAME` would, in one write transaction:

1. Check the observed version and that the task is unassigned and `todo`.
2. Recheck the existing readiness predicate, including prerequisites and
   `needs-human`, within that transaction.
3. Set assignee and `in-progress`, increment the version, append history and,
   for remote operation, commit the request receipt.

Two callers racing for one task must yield one success and one refusal. There
is no automatic conflict retry. Start with claiming a specific observed ID;
`claim-next` adds queue policy and should wait for an actual use case.

The architect can explicitly release or reassign abandoned work with another
version-checked operation and a recorded reason. Finish, cancellation and
release must have a defined policy for retaining or clearing ownership.
Self-reported names are not credential enforcement. If ownership must restrict
mutations, specify that authorization policy separately for the server and local
CLI before implementation.

## Why leases are expensive here

An expiry does not stop the original worker editing files. Reassigning its task
while it is still running can create the duplicate work a lease was meant to
prevent. Paused model sessions, machine sleep and network outages also make
heartbeats unreliable indications of whether work has stopped.

If needed later, use authority-issued claim tokens with monotonically increasing
generations, an explicit expiry and version-checked renewal/release. The server
clock owns remote expiry. After expiry, classify the claim as stale; require the
architect to confirm shutdown before reassignment. Reject stale generations on
task result writes. That fences ledger updates, not arbitrary Git or filesystem
writes. Source-worktree ownership still needs its own policy.

Do not add a lease daemon now. Explicit architect recovery is simpler for the
current supervised workflow.

## Goals and milestones without another dependency system

Start with grouping labels and a parent task whose body defines the intended
outcome and review criteria. Use dependencies only when they represent real
execution or completion prerequisites; do not turn membership into a dependency.

If grouping stops being sufficient, add a small milestone record with a stable
ID, name and optional target date, plus optional task membership. Specify query
and deletion behavior before adding it. An all-done membership count is a report,
not automatic proof of a goal's outcome. Defer a separate goals hierarchy until
milestones cannot express real work.

## Structured acceptance criteria, if tools must query them

Add child records with stable per-task IDs, criterion text and optional evidence
references. Criterion changes must check and increment the parent task version
and commit their snapshots with history. The architect accepts evidence; a worker
cannot turn an arbitrary checkbox into independent verification.

Define whether criterion edits invalidate prior acceptance, how old Markdown
tasks remain valid, and how criteria round-trip through import/export. Preserve
bodies rather than heuristically extracting their checklists during migration.
Only introduce a completion gate on structured criteria after its semantics and
legacy behavior are explicitly accepted.

## Proof required before adding any of these

Exercise backed-up schema migration and preservation, stale writes, concurrent
claim attempts, readiness changes during claiming, old snapshot reads, complete
import/export and local/remote agreement. Remote cases must include a lost reply
and reconciliation of the original request. A lease would additionally need stale
generation and clock-boundary cases. The viewer must expose the new fields through
keyboard and screen-reader interaction.

First make the existing product easy to install and try. Add ownership only when
outside use or our own handoffs demonstrate the query/recovery need. The next
artifact would be an accepted spec extension before implementation.
