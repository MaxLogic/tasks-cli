# Remote CLI setup and recovery

Remote access is implemented. The maintained Windows and native WSL clients
were installed for the QNAP authority on 2026-10-06; see
[the deployment record](deployment-2026-10-06.md). For another installation,
configure its own profile and credentials. Profile setup does not migrate data.
The default build includes the HTTPS client; `--features server` also builds the
server. `--no-default-features` is a local-only binary and refuses any existing
profile instead of treating it as an unconfigured local root.

## Configure once per installation

Use a remote-capable `tasks` executable in these commands. Supply a fresh absolute
personal directory and an explicit client data root. The private key is generated
locally; stdout contains only the public registration document.

```text
tasks --data-root <client-root> remote keygen --directory <private-key-directory>
```

Save the public JSON as an enrollment file and register it through stopped-service
server administration, as described in [server-core.md](server-core.md). The
operator confirms the actor and installation labels, and returns the credential
UUID and existing server UUID. Configure one final LAN or public HTTPS origin:

```text
tasks --data-root <client-root> remote configure --server-url https://<hostname>:<port> --server-id <server-uuid> --credential-id <credential-uuid> --credential-file <absolute-private-key-directory>/signing-key.pem
```

Use `--private-ca <absolute-PEM-path>` only for an operator-supplied private CA.
Do not disable certificate validation. The command authenticates `/v1/info`,
checks its identity/capabilities and writes `<client-root>/client.toml` atomically.
Existing project bindings and `.tasks.json` still select UUIDs. Remote `init`
creates a server project and a local routing binding; `bind` confirms a server
project and adds local routing only. Neither opens a leftover local task DB.

Ordinary commands keep their arguments and JSON/text output. OS machine/account
and available harness/session context are collected automatically. The server
replaces actor/installation identity from the enrolled credential. Optional
[harness hooks](context-hooks.md) add supplied invocation context without
per-call metadata flags.

Profiles are selected before WSL delegation. Each native installation should
have its own protected key and native private directories. An absent profile
uses the existing local behavior. Invalid files, dangling links and incompatible
profiles fail closed. `remote local` explicitly selects local behavior, after
all pending writes are resolved. Switching profiles is configuration, not data
migration or permission to operate two writable authorities for one UUID.

## Outages and unknown outcomes

Remote reads fail with a service error; they never fall back to local SQLite.
Writes first confirm the server is online. Before dispatch, the CLI persists the
request UUID, original payload/version, route, server and credential in a private
pending file. There are no automatic retries and no offline write queue.

```text
tasks --data-root <client-root> remote pending
tasks --data-root <client-root> remote reconcile <request-uuid>
```

Reconciliation uses the original request and a fresh signature. It does not
rebase the version or invent a new request. The server replays the original
committed response, including terminal refusals. Another write stays blocked
until pending evidence is resolved. Reconfiguration cannot change the pending
server or credential identity. The same server may be reached by either enrolled
HTTPS route. A revoked/lost credential with unresolved evidence needs operator
recovery before changing credentials; preserve that evidence.

The HTTPS gateway is trusted. Confirmed replies carry a marker matching request
UUID, route, canonical payload SHA-256 and status. Generic intermediary errors,
including a JSON 503 after commit, retain the pending request. This marker is
not a separate end-to-end server signature. Windows pending publication uses
`MoveFileExW` with write-through through `atomicwrites`; Unix syncs the containing
directory. Tests establish these mechanisms and response-loss recovery, not a
physical power-loss experiment. Completed-file deletion has best-effort directory
sync: a stale receipt resurrected after a crash can safely replay the same result.

## Complete exports and bounded reads

Remote export streams a complete SQLite snapshot and verifies its terminal UUID,
byte count, task count and SHA-256. It publishes only after that verification,
refuses existing destinations, and removes temporary files after interruption.
On Windows, pinned canonical directory handles and an exclusively held source
prevent pathname replacement during publication. Unix requires an owned export
directory and trusted root/current-user ancestors; writable non-sticky ancestors
are refused. Cleanup after publication is best effort, so a complete published
file is reported as successful even if removal of its temporary name fails.

Ordinary replies are bounded at 16 MiB. Split oversized reads or use export;
complete bodies are never silently truncated. Title enrichment batches at most
500 references per API request and retains the local text/URL rules.

Import, bulk-import, backup, migration and doctor require server-local
administration; the remote CLI refuses them before opening local SQLite/input.
Remote viewer operations and retained receipt recovery are described in
[remote-viewer.md](remote-viewer.md). NAS deployment and LAN/public routes have
dated proof in [deployment-2026-10-05.md](deployment-2026-10-05.md); production
cutover is recorded separately. A new deployment still needs its own TLS,
network-isolation, recovery and installation checks.

Dependency notes: the selected TOML parser is `toml 0.9.12+spec-1.1.0`
(MIT/Apache-2.0, declared Rust 1.76), and the Windows publication wrapper is
`atomicwrites 0.4.4` (MIT). Cargo.lock pins the selected transitive dependencies.
The wrapper's platform source and native API behavior were inspected; tests use
fresh protected synthetic roots. See
[MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)
and [atomicwrites source](https://docs.rs/crate/atomicwrites/0.4.4/source/src/lib.rs).
