# Server authentication candidate

This is the TSK-023 authentication/storage milestone. It is not a deployable
task backend. `/v1/info` returns `ready: false`; task API, HTTPS client, private
key storage, proxy fixtures and deployment proof remain open. Keep it on a
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

## Remaining TSK-023 acceptance

Implement the strict synchronous HTTPS client and synthetic proxy TLS fixtures
(trusted/private CA, wrong hostname, expired/untrusted certificates), owner-only
private key setup/validation on both platforms, configured proxy preservation
proof and safe request logging. Complete real service shutdown/write proof after
shared task dispatch. Actual NAS route and isolation proof waits for the other
thread's gateway and the later deployment rehearsal. No TLS verification bypass
or unauthenticated health/admin HTTP endpoint is provided.
