# Server authentication candidate

This is the TSK-023 authentication/storage milestone. It is not a deployable
task backend. `/v1/info` returns `ready: false`; task API, remote CLI profile
routing and deployment proof remain open. Keep it on a
synthetic local data root. No installed binary, live backlog, harness settings
or NAS configuration was changed.

## Candidate build and administration

```powershell
cargo build --release --locked --features server --bin tasks --bin tasks-server --target-dir target/server-candidate
target/server-candidate/release/tasks-server.exe --data-root <fresh-local-fixture> admin init
target/server-candidate/release/tasks-server.exe --data-root <fixture> admin info
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
replay nonces live in the separate server database. It uses FULL durability and
five-second SQLite busy handling. Opening validates the schema, audit trigger
bodies and integrity. Fresh initialization creates a new UUID; reopening
retains it. A replacement registration receives a new credential UUID.

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
but application receipts are not implemented yet.

Authentication replaces actor/installation identity from the server registration;
reported session/harness data remains client context. Eight operation permits
bound HTTP work, with a one-second admission wait and 8 MiB body limit. A blocking
worker retains its permit even if the request is cancelled. Body reads have a
15-second limit. New writes are refused during shutdown; the process has a
30-second graceful deadline and SQLite recovery owns outcomes after forced exit.
Admitted task writes still need acceptance once task dispatch exists.

## HTTPS client and private files

The synchronous client accepts an HTTPS origin, optional private CA PEM bundle
and positive connect/request timeouts (three/15 seconds by default). TLS checks
hostname, date and trust with TLS 1.2 or newer. Every request gets a fresh signature;
redirects are refused and automatic request retries are disabled. Exact encoded
path/query bytes are checked against the transmitted URL before signing. Bodies
and responses are bounded at 8 MiB, including responses without Content-Length.
Errors contain fixed diagnostic categories, never raw URLs, headers or bodies.
Remote CLI profile selection and pending mutation receipt handling are TSK-025.

Explicit key generation produces an OS-random Ed25519 key in PKCS#8 PEM and
returns only its public key. Existing keys are never overwritten. Load requires
a protected parent and a secure opened file; missing, malformed, oversized and
insecure files are refused. Unix requires owner identity and exact 0700/0600
permissions; linked files are refused. Windows uses protected ACLs restricted
to the filesystem owner, SYSTEM and Administrators, with reparse points refused.
Use a trusted personal data root, never a shared writable directory. Key setup
is a library building block until the explicit remote CLI configuration slice.

Per-session hook files share this protection. Windows protects an empty unique
directory before publishing its name, so simultaneous hooks cannot encounter a
directory whose ACL is still being set. Existing insecure directories are refused;
the helper does not silently change their permissions or trust their contents.
No production unsafe Rust or permission-setting subprocess is introduced.

The server emits one JSON log line per request to stderr, with exactly request ID,
registered actor ID (null before authentication), valid project UUID, fixed
operation name, duration and outcome. Query text, bodies, headers, keys, titles,
environment and executable arguments are excluded. A cancelled handler records
`cancelled`, not a claimed mutation result. Persistent receipts will own mutation
outcome recovery. Log I/O errors are reported locally without changing committed
application outcomes.

## Deployment and dependent proof

Synthetic TLS gateway proof reaches the actual authenticated private Rust HTTP
listener and preserves signed metadata/body. This does not certify the NAS Caddy
or Cloudflare route. Actual NAS TLS/network isolation waits for the user's gateway
thread and TSK-027. Admitted task-write shutdown/recovery proof belongs with shared
task dispatch in TSK-024; no task route is advertised as ready today.
