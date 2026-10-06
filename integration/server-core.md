# Server API and administration

The server implements authenticated task operations, catalog recovery and
atomic request receipts. `/v1/info` advertises `ready: true` for the typed API.
Remote CLI routing and QNAP deployment are implemented; see
[the production cutover](deployment-2026-10-06.md). Use synthetic roots for
verification. Administration of a live authority requires its writers to stop.

## Isolated build and administration

```powershell
cargo build --release --locked --features server --bin tasks --bin tasks-server --target-dir target/server-candidate
target/server-candidate/release/tasks-server.exe --data-root <fresh-local-fixture> admin init
target/server-candidate/release/tasks-server.exe --data-root <fixture> admin info
target/server-candidate/release/tasks-server.exe --data-root <fixture> admin migrate
target/server-candidate/release/tasks-server.exe --data-root <fixture> admin register --registration-file <public-enrollment.json>
target/server-candidate/release/tasks-server.exe --data-root <fixture> admin revoke <credential-uuid>
target/server-candidate/release/tasks-server.exe --data-root <fixture> serve --listen 127.0.0.1:8080
```

For Linux, use `CARGO_TARGET_DIR=$HOME/.local/share/tasks-cli/target/server-candidate`
and the Linux-owned root. Initialization is explicit and never overwrites an
existing `server.sqlite`. Administration and serving both hold `server.lock`;
stop the service before changing registrations. The public registration JSON
contains `public_key` (32-byte array), `actor_id`, `actor_name`, `installation_id`
(UUID) and `installation_name`. Do not put a private key in this file.

Server identity, public registrations, revocations, append-only admin audit and
replay nonces and project catalog live in the separate schema-2 server database. It uses FULL durability and
five-second SQLite busy handling. Opening validates the schema, audit trigger
bodies and integrity. Fresh initialization creates a new UUID; reopening
retains it. A replacement registration receives a new credential UUID.
The stopped-service `admin migrate` command upgrades schema 1 explicitly,
preserving a verified SQLite pre-upgrade backup, identity, credentials, audit
and replay nonces. Serving does not migrate implicitly.

## Authentication and resource ownership

The shared signing/verifying library implements the specified Ed25519 profile.
All internal HTTP routes require the signature, body digest and destination UUID.
Encoded path/query bytes remain encoded; an absent query signs `?`. Only the
specified components/parameters, one signature and SHA-256 digest are accepted.
Duplicate security headers, extra signatures and compression are rejected.
Clock checks allow only the specified 120-second lifetime and 30-second skew.

The server verifies registration/signature before atomically consuming a nonce.
Nonce consumption precedes bounded body reading; body refusal does not restore
the nonce. Restart preserves replay protection. Per-credential/global capacity
is 4096/65536 live entries; unexpired entries are never evicted. Invalid signatures
cannot consume replay capacity. Fresh signatures may reuse an idempotency UUID,
and the project receipt returns the original committed success or terminal
refusal. A different actor, installation, route or canonical payload under that
request UUID returns a conflict without dispatching the mutation.

Authentication replaces actor/installation identity from the server registration;
reported session/harness data remains client context. Eight operation permits
bound HTTP work, with a one-second admission wait and 8 MiB body limit. A blocking
worker retains its permit even if the request is cancelled. Response buffers retain
that permit until their final owner releases them. Body reads have a
15-second limit. New writes are refused during shutdown; the process has a
30-second graceful deadline and SQLite recovery owns outcomes after forced exit.
Synthetic HTTP proof covers admitted-write completion during shutdown and
response loss/reconciliation after a service restart.

## Shared operations and project ownership

The typed `/v1` routes cover catalog/project creation, list/search/unlocks,
show-many, history/rules/key reads, task/rules/key mutations and Markdown export.
Store validation, optimistic version checks and history are shared with local
commands. Queries accept only their tagged request type, never SQL or commands.
The response carries the existing stdout JSON envelope and its text rendering.
Ordinary replies are capped at 16 MiB. Show-many and project history preflight a
4 MiB source-text budget in the same read snapshot before loading bodies or
metadata JSON; oversized reads return 413 with an actionable smaller-page hint.
No successful response silently truncates text.

Export uses bounded NDJSON begin/chunk/end frames with 16 KiB data chunks,
project UUID, complete byte count, task count and SHA-256. The server reads one
SQLite snapshot row by row and holds at most two queued frames. Backpressure has
a 15-second wait bound and a five-minute overall stream deadline. Missing or
invalid completion frames fail the client; publication must follow validation.
Responses use `Cache-Control: no-store`.

Project schema 8 retains append-only receipts for the database's lifetime.
Each mutation, history event and receipt commit together. Terminal validation
and version refusals are retained; auth/capacity/lock failures are not. Read
requests create no mutation history. Existing project upgrades remain explicit
and backed up; no project database is migrated by a network request.

Creation holds the registry lock. An unpublished database contains initialized
schema but no creation history until its creation event and receipt commit.
Catalog publication follows that commit. Reconciliation repairs an interrupted
binding from the original creation receipt; competing creates cannot create
another creation event or overwrite its name. UUIDs route operations; task
references and dependency references use the store's current project key.
Creation refusals are retained whenever the request supplies a usable project
UUID, including invalid names and attribution. An absent or malformed UUID has
no project receipt store and returns an immediate protocol refusal.

## HTTPS client and private files

The synchronous client accepts an HTTPS origin, optional private CA PEM bundle
and positive connect/request timeouts (three/15 seconds by default). TLS checks
hostname, date and trust with TLS 1.2 or newer. Every request gets a fresh signature;
redirects are refused and automatic request retries are disabled. Exact encoded
path/query bytes are checked against the transmitted URL before signing. Bodies
are bounded at 8 MiB; ordinary responses at 16 MiB, including replies without
Content-Length. Complete exports use the separately bounded streaming protocol.
Errors contain fixed diagnostic categories, never raw URLs, headers or bodies.
Remote CLI profile selection and pending mutation receipt handling are described
in [remote-cli.md](remote-cli.md).

Explicit key generation produces an OS-random Ed25519 key in PKCS#8 PEM and
returns only its public key. Existing keys are never overwritten. Load requires
a protected parent and a secure opened file; missing, malformed, oversized and
insecure files are refused. Unix requires owner identity and exact 0700/0600
permissions; linked files are refused. Windows uses protected ACLs restricted
to the filesystem owner, SYSTEM and Administrators, with reparse points refused.
Use a trusted personal data root, never a shared writable directory. Key setup
is exposed through the explicit `remote keygen` and `remote configure` commands.

Per-session hook files share this protection. Windows protects an empty unique
directory before publishing its name, so simultaneous hooks cannot encounter a
directory whose ACL is still being set. Existing insecure directories are refused;
the helper does not silently change their permissions or trust their contents.
No production unsafe Rust or permission-setting subprocess is introduced.

The server emits one JSON log line per request to stderr, with exactly request ID,
registered actor ID (null before authentication), valid project UUID, fixed
operation name, duration and outcome. Query text, bodies, headers, keys, titles,
environment and executable arguments are excluded. A cancelled handler records
`cancelled`, not a claimed mutation result. Persistent receipts own mutation
outcome recovery. Log I/O errors are reported locally without changing committed
application outcomes.

## Deployment and dependent proof

Synthetic TLS gateway proof reaches the authenticated private Rust HTTP listener
and preserves signed metadata/body. Actual NAS TLS and network-isolation checks
are recorded in [deployment-2026-10-05.md](deployment-2026-10-05.md), and the
55-project cutover in [deployment-2026-10-06.md](deployment-2026-10-06.md).
Each record establishes its named environment and candidate; local API tests
alone do not establish live routing or physical network isolation.
