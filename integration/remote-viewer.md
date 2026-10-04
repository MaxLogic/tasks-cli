# Viewer through the remote CLI

The viewer uses the same CLI JSON protocol for local and remote profiles. It
does not connect to HTTP itself. Configure the candidate CLI once using
[remote-cli.md](remote-cli.md), then select that executable and the matching
client data root in the viewer. Do not switch a live project to remote storage
until its server copy and cutover have been verified.

The remote catalog includes server projects even when this installation has no
local directory binding. Directory bindings and root searches come from this
client's registry; NAS filesystem paths are not exposed. Task details and
history retain complete text. History displays nullable actor, machine,
harness, session and model attribution; older events remain unattributed.
Viewer edits identify the viewer and clear inherited AI session metadata.
Authenticated server actor and installation fields come from the credential.

## Pending changes

For remote edits and project archival, the viewer assigns a fresh request UUID.
The CLI saves the original payload and version before dispatch. A confirmed
response remains on disk until the viewer validates its project, task and
result, then acknowledges that UUID. Losing process output or a service reply
preserves both the request evidence and the editor draft. A timed-out write
process is left running; the viewer does not automatically resend it.

Use **Check pending change** to reconcile the exact original request after
connectivity returns. The editor retains its draft while the check is pending
or the service is unavailable. A newer task version becomes a conflict; matching
field text alone does not prove that the original save succeeded. After receipt
acknowledgement, a failed detail refresh can be retried without sending another
write. A terminal refusal clears its confirmed receipt and leaves the draft
available for correction. Failed preflight or executable launch does not create
a false pending mutation.

Pending changes survive a viewer restart. The Projects recovery button also
handles archival and ordinary CLI receipts. Diagnostic CLI commands are:

```text
tasks --data-root <client-root> --format json viewer recovery
tasks --data-root <client-root> --format json viewer reconcile <request-uuid>
tasks --data-root <client-root> --format json viewer acknowledge <request-uuid>
```

`acknowledge` requires request-bound confirmation for the same server and
credential. It performs local cleanup and never sends a mutation. Preserve
private pending files if the credential is lost or revoked; this requires
operator recovery. Service failures never fall back to local SQLite.

Project archival is shared metadata. A subsequent task mutation makes that
project active again. Catalog pages bind the server snapshot and client
bindings; stale pages require a fresh query. Catalogs beyond 10,000 projects or
oversized responses fail explicitly rather than silently truncating results.

## Verification boundary

Rust acceptance uses actual CLI processes, HTTPS gateways and separate client
installations. Flutter acceptance uses headless process and widget fixtures.
Portable package verification launches only the startup opt-out and argument
error paths. Spoken outage feedback, stable focus and restored-service recovery
in a real packaged viewer with NVDA remain a workstation availability gate.
