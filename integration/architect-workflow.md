# One architect, two workers, one backlog

The architect owns task selection, assignment and lifecycle writes. Workers
implement bounded assignments and return changes, proof and unresolved points.
They can read the shared backlog, but do not independently claim the next task
or mark their assignment done. This convention prevents duplicate assignments;
the CLI's version checks protect edits. Neither is a filesystem lock on source.

This example uses two Git worktrees and a fresh local store. Run both workers
on the same OS. The directory names below are examples: choose a new absolute
directory on a local disk, such as `C:/tasks-demo-unique` on Windows or
`/tmp/tasks-demo-unique` on Linux. Never reuse your live task data root.

Use `<demo>/store` as the explicit data root on **every** command. Unset
`TASKS_PROJECT` and `TASKS_WINDOWS_EXE` in the demo terminals so they cannot
route the fixture to another project or OS. Create `<demo>/repo` first.
The fixture has no remote profile and sends no requests to a server.

## Architect: prepare the project and assignments

From `<demo>/repo`:

```text
git init
tasks --data-root <demo>/store init --root <demo>/repo --key DEMO
git add .tasks.json
git commit -m "Initialize demo task identity"
git worktree add -b demo-worker-a <demo>/worker-a
git worktree add -b demo-worker-b <demo>/worker-b
```

Use your normal local Git identity for the commit. Only `.tasks.json` is needed
in Git for backlog routing; both worktrees inherit it. No per-worktree `bind`
is needed.

Create two UTF-8 body files outside the checkout:

- `<demo>/parser.md`: implement a parser change; state the accepted inputs,
  owned source paths and required regression proof.
- `<demo>/caller.md`: update its caller after the parser is implemented; state
  owned paths and the integration checks the architect will run.

```text
tasks --data-root <demo>/store create --title "Update parser" --body-file <demo>/parser.md --status todo
tasks --data-root <demo>/store create --title "Update caller" --body-file <demo>/caller.md --status todo --deps DEMO-1
tasks --data-root <demo>/store show DEMO-1 DEMO-2 --rules
tasks --data-root <demo>/store update DEMO-1 --expect-version 1 --status in-progress
```

The architect assigns DEMO-001 to worker A, including the observed version,
worktree, owned paths and acceptance criteria. Worker B waits: DEMO-002 depends
on DEMO-001. There are no source changes or tests implicit in these commands.

## Workers: read their assignment

Worker A runs from `<demo>/worker-a`; worker B runs from `<demo>/worker-b`:

```text
tasks --data-root <demo>/store show DEMO-1 DEMO-2
tasks --data-root <demo>/store list
```

Both see the same project UUID in JSON (`--format json`) and the same task
versions. The second task is initially absent from the runnable list.
Workers return their patch and evidence to the architect; they do not write
an alternative task ledger inside their worktree.

## Architect: handle a result based on an old version

Worker A's brief was based on version 2. While A works, the architect clarifies
the title:

```text
tasks --data-root <demo>/store update DEMO-1 --expect-version 2 --title "Update parser and preserve errors"
```

This creates version 3. A returns its implementation and focused proof referring
to version 2. Applying its proposed transition with that old version fails:

```text
tasks --data-root <demo>/store update DEMO-1 --expect-version 2 --status to-verify
```

Expected exit code: 4. Stderr reports `expected 2, current 3`; the refused write
does not change the task or add a history event. The architect reads the task
again, checks whether A's work satisfies the clarified scope, and requests more
work if it does not. After accepting the focused result:

```text
tasks --data-root <demo>/store show DEMO-1
tasks --data-root <demo>/store update DEMO-1 --expect-version 3 --status to-verify
tasks --data-root <demo>/store list
```

DEMO-002 is now runnable because `to-verify` permits dependent work to start.
The architect assigns it to B, records `in-progress` at its observed version,
and later records `to-verify` only after checking B's focused proof. These
commands illustrate the accepted result; they do not constitute proof themselves.

## Architect: run the verification gate and close in order

```text
tasks --data-root <demo>/store update DEMO-2 --expect-version 1 --status in-progress
tasks --data-root <demo>/store update DEMO-2 --expect-version 2 --status to-verify
tasks --data-root <demo>/store list --status to-verify
tasks --data-root <demo>/store update DEMO-2 --expect-version 3 --status done
```

The last command fails with exit 2: DEMO-001 is still `to-verify`. Readiness to
start and acceptance as done are different rules. After the architect has run
the required integrated verification against the combined candidate, close the
prerequisite first:

```text
tasks --data-root <demo>/store update DEMO-1 --expect-version 4 --status done
tasks --data-root <demo>/store update DEMO-2 --expect-version 3 --status done
tasks --data-root <demo>/store history DEMO-1
tasks --data-root <demo>/store list --open
```

The open list is empty. A cancelled prerequisite still withholds default
readiness, although the explicit completion guard accepts cancelled prerequisites.
The architect must review that distinction before accepting a dependent task.

Leave the fixture for inspection or remove only its own worktrees and directory.
Do not point cleanup at the source repository or a real task store.
