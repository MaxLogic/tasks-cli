# QNAP tasks-server deployment and recovery

The reviewed server is deployed on the QNAP as of 2026-10-05 at
`https://tasks.maxlogic.app`. LAN DNS selects NAS 443; public DNS selects the
existing Cloudflare Tunnel. Both routes enforce server-side request signing.
The permanent authority received 55 project backlogs on 2026-10-06. See
[the production cutover](deployment-2026-10-06.md),
[the initial deployment record](deployment-2026-10-05.md) and
[NAS operations](../../qnap-nas-maintenance/docs/tasks-server-deployment.md).

The local Docker driver below remains an isolated rehearsal. Actual NAS proof
is separately recorded under `target/evidence/nas-deploy-20261005/`.

## Inputs and boundaries

The server image is built for `linux/amd64` from the repository [multistage
Dockerfile](../Dockerfile). Record its digest and the NAS CPU, QTS, Container
Station and Docker versions again immediately before deployment. The last
observed NAS Docker version in the spec is `27.1.2-qnap8`; use the installed
binary at `/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker`. Do not
assume that a local Docker 29 result proves the NAS 27 network behavior.

Use [server-compose.yml](server-compose.yml) with these explicit variables:

| Variable | Value to supply |
| --- | --- |
| `TASKS_SERVER_IMAGE` | Verified `linux/amd64` image tag or immutable digest. |
| `TASKS_DATA_DIRECTORY` | Private NAS-local directory holding the initialized server store. No network filesystem. |
| `TASKS_UID`, `TASKS_GID` | NAS identity that owns that directory, default `10001:10001`. |
| `TASKS_GATEWAY_NETWORK` | Private Docker network shared with the existing trusted Caddy gateway and tunnel connector. |

The Compose service has no `ports:` entry. Its HTTP listener is reachable by
Docker DNS as `tasks-server:8080` only from attached containers. It has a
read-only root filesystem, limited `/tmp`, dropped capabilities, no privilege
gain, bounded processes and memory, and a 35 second graceful stop. Keep the
backend off the NAS LAN interface. Neither server container nor image receives
TLS private keys, tunnel credentials, client signing keys, or a Docker socket.
The server verifies Ed25519 request signatures, the signed body digest, server
identity, timestamp/nonce and mutation UUID after trusted proxy forwarding.

The existing QTS admin proxy remains under its current owner. Do not repurpose
its routes or certificates. Configure the existing Caddy gateway for the LAN
hostname with a matching certificate trusted by each client. Connect Caddy and
the existing `cloudflared` connector to the private tasks network. The public
hostname terminates HTTPS at the existing Cloudflare edge and enters through
that connector. Both paths forward the method, original path and query, signed
headers, body bytes and response bytes without request rewriting or signing on
behalf of a client. Restrict the public tunnel route to the intended hostname.
Neither proxy needs a client private key. Keep proxy TLS key material and tunnel
credentials under their existing owners.

## Offline initialization and enrollment

Create the NAS-local data directory with restrictive permissions, owned by the
configured UID/GID. With the service stopped, run `tasks-server --data-root
/data admin init` in a one-off container mounting only that directory at
`/data`. Confirm the returned server UUID and save it in private operator
records. The server must be initialized and clients registered before `serve`
takes the ownership lock. Run every admin command only while the service is
stopped.

For each fresh client installation, use a remote-capable CLI and an explicit
private data root:

```text
tasks --data-root <new-client-root> remote keygen --directory <new-private-key-directory>
```

Save stdout as a public enrollment JSON file. Mount that single file read-only
into an offline one-off server container, then run:

```text
tasks-server --data-root /data admin register --registration-file /enrollment.json
```

Return its credential UUID and server UUID to the client owner. Never copy the
private `signing-key.pem` to the NAS, image, gateway or connector. Configure
each installation using its final HTTPS origin and a matching trusted CA:

```text
tasks --data-root <client-root> remote configure --server-url https://<lan-or-public-host> --server-id <server-uuid> --credential-id <credential-uuid> --credential-file <key-directory>/signing-key.pem --private-ca <trusted-ca.pem>
```

Confirm the two installations have distinct credentials, stable UTC clocks,
matching DNS and hostname-valid TLS. Start Compose only after provisioning.
Check signed `/v1/info`, task creation, full-body `show`, history attribution,
version conflict, credential revocation and restart through both routes. Stop
the service before `admin revoke <credential-uuid>`, then restart and show that
the revoked credential is rejected via LAN and public origins. Prove that a
wrong CA or hostname is refused by the actual client. On Docker 27, test from
another physical LAN machine that `tasks-server:8080` has no reachable NAS host
port; save `docker inspect` port bindings and the outside-LAN connection result.
Compose configuration alone cannot establish this last property.

## Local rehearsal

Build the candidate image and a remote-capable Windows release CLI into
isolated locations. Keep the installed `tasks.exe` untouched. Cache
`python:3.13-slim-bookworm` locally; the driver will not pull it. Install
`cryptography>=46` into the Python environment. Then run:

```text
python integration/verify_server_container.py --fixture-root <new-empty-absolute-directory> --image <already-built-local-image> --tasks <absolute-candidate-tasks.exe>
```

The fixture owns a uniquely named volume, private network, server container
and gateway helper. Only the helper has an ephemeral `127.0.0.1` port. Local
Python TLS listeners supply two separate `https://localhost:<port>` origins
with one synthetic CA. A proxy deliberately loses one committed mutation
reply, then the CLI reconciles the original UUID after restart. The driver
keeps `manifest.json`, `commands.jsonl` and a verified backup copy under the
fixture root, and removes only its named Docker resources. A nonzero exit or
incomplete manifest is a failed proof. This is not a NAS smoke run.

## Backup, restore and cutover

Stop the service and all writers for administration. Use the server's online
SQLite backup, even when the service is stopped, to create a new private
destination. Never copy only a live SQLite main file: WAL content and the
catalog, credentials, receipts and project databases must be included.

```text
tasks-server --data-root /data admin backup --out /backups/<new-backup-directory>
tasks-server --data-root /data admin restore --backup /backups/<verified-backup-directory> --out /restores/<new-restored-directory>
tasks-server --data-root /restores/<new-restored-directory> admin info
```

For these one-off commands, mount private NAS directories at `/backups` and
`/restores`. Their parent directories must already exist and be owned by the
admin container's UID/GID. Backup destinations must be outside `/data`; restore
publishes a new directory without overlapping its backup source. Restore does
not open the existing authority identified by `--data-root`.

The backup manifest records server identity, per-database SHA-256, byte length,
schema, identity and table counts. Verify every hash, SQLite integrity and
foreign-key check, and selected exact project UUIDs, keys, task IDs, versions,
full bodies, dependencies, import rows, history event IDs and snapshots. The
restore command verifies before publication and refuses existing destinations.
Keep a private copy of the verified backup outside the container volume and
record which store is authoritative. The backup includes sensitive task and
credential data.

Daily production backups are installed at 02:00 NAS local CET/CEST. Each verified
TGZ contains the catalog, all project databases and manifest. Retention keeps
today and six previous calendar dates under `/share/Container/tasks-server/backups/`.
See [daily backup operations](qnap-daily-backups.md) for the cron row, installed
script, first archive proof, manual execution and restore procedure.

For a real cutover, first stop local writers and take final verified local
backups. Import only copies selected for migration and check exact history and
identity against those copies. Start one remote authority, configure clients,
then confirm both HTTPS routes. Retain old local snapshots read-only. Before
any server write, rollback can restore the prior client profile. After a server
write, stop the server and take its current verified backup before selecting
the authority for recovery; an older local snapshot omits the remote writes.
Never run local and remote writable authorities for the same project UUID.
Actual NAS deployment, physical LAN isolation and DNS/TLS provisioning passed
on 2026-10-05. Migration of all 55 projects and Windows/native WSL installations
passed on 2026-10-06; see deployment-2026-10-06.md. The old local stores remain read-only.
Packaged viewer/NVDA acceptance remains a separate gate.

References: [Docker multistage builds](https://docs.docker.com/build/building/multi-stage/),
[Compose service keys](https://docs.docker.com/reference/compose-file/services/),
[Docker port publishing](https://docs.docker.com/engine/network/port-publishing/).
