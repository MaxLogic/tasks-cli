# QNAP server deployment, 2026-10-05

## Authorization and authority

The user accepted nullable Windows caller/harness executable fields and
authorized QNAP deployment with Cloudflare Tunnel and LAN DNS for
`https://tasks.maxlogic.app`, using the updated NAS playbook. TSK-022 and
TSK-025 were completed in dependency order. The Windows attribution decision
is committed as `d92e6d7`; it adds no unsafe exception or Rust source change.

The permanent server UUID is `8748aad8-d5cd-4c00-881b-842938eee52b`.
It serves an empty project catalog, with one enrolled workstation installation.
Its NAS-local authority is `/share/Container/tasks-server/data` (10001:10001,
mode 700). The container is `qnap-tasks-server`; its image ID is
`sha256:cd294eb7a7765b0e4fa23f8fef65f5af6b6f4e554a6d5a009b71a30cc162f91f`.
Archive SHA-256:
`86b39202dfb9fadf0585b58489189ca0baaf99643bbaa8f75d4f5bdf6424b7ea`.

The existing NAS runtime is x86_64, QTS 5.2.10/20260731, Container Station
3.1.2.1742 and Docker 27.1.2-qnap8. Docker was retained. No live local project
store or installed workstation CLI/viewer executable was replaced or migrated.

## Routes and authentication

LAN CoreDNS returns `10.77.77.13` A, TTL 300, with empty NOERROR AAAA/SVCB/HTTPS
answers. HAProxy on NAS 443 sends tasks SNI to existing Caddy 8443. Caddy's
trusted Let's Encrypt certificate expires 2027-01-03 07:25:16 UTC. Public DNS
has a proxied CNAME into the existing tunnel; ingress points at
`http://qnap-tasks-server:8080`. The backend has no published host port and
uses the internal `qnap-tasks` network, 172.29.24.0/22.

Ed25519 installation signatures, body digest, server identity, timestamp,
nonce and mutation UUID are verified by Rust on both routes. Anonymous API
requests receive 401. No interactive Cloudflare Access policy is needed for
the API. Existing Audiobookshelf, QTS and protected-directory routes remain
working. Recreating the connector requires reattaching `qnap-tasks`; its
restart retains the attachment. Caddy's existing DNS-only token was retained;
the temporary tunnel-write setup token was revoked after final verification.

## Workstation access

The once-configured alternate remote profile is
`C:\Users\pawel\AppData\Local\MaxLogic\tasks-cli\remote-qnap`.
Its private installation key remains locally protected at
`C:\Users\pawel\AppData\Local\MaxLogic\tasks-cli\client\keys\qnap-nas-20261005`.
Only public enrollment data was uploaded. Use the verified remote-capable
candidate until a separate global install/cutover is authorized:

```powershell
$tasksCandidate = 'F:\projects\MaxLogic\tasks-cli\target\server-candidate\release\tasks.exe'
$qnapProfile = 'C:\Users\pawel\AppData\Local\MaxLogic\tasks-cli\remote-qnap'
'{}' | & $tasksCandidate --data-root $qnapProfile --format json viewer projects --request-file -
```

Candidate CLI SHA-256 is
`3aaeddc887385e9ba95f8e95af2b87c01412b48f8f058ff673c86f41202fd8a6`.
Additional machines need distinct private keys and public enrollment; ordinary
writes then sign automatically. The installed schema-6 CLI still handles the
existing local ledgers.

## Actual NAS acceptance

`target/evidence/nas-deploy-20261005/deployment-proof.json` records 16 distinct
passing checks. The raw append-only acceptance file contains successful repeat
runs; the final manifest counts each named case once.

- Two enrolled installation keys, signed LAN/public HTTPS and the same authority UUID.
- Exact cross-route task body and history attribution; stale versions rejected.
- Simultaneous LAN/public edits: exactly one commit and one conflict.
- Nonce replay rejected across routes, including after NAS restart.
- A private relay dropped a committed public reply. The CLI retained its request
  UUID, reconciled through LAN after server restart, and recovered exactly one
  task/event with its original body. The relay was removed and the original
  tunnel route restored.
- Revoked verification key rejected through both routes; the other key survives.
- Actual CLI refused invalid production TLS identity.
- Offline NAS backup/restore preserved identical database hashes, identity,
  revocation, row counts, SQLite integrity and foreign keys.
- Non-root/read-only server, internal network and empty host port bindings.
- Pi UDP/TCP DNS and trusted HTTPS; routed direct origin timed out. Its temporary
  route was removed. NAS HTTP8080 belongs to existing QTS `fcgi-pm`; its HTML404
  for `/v1/info` is not the tasks API's JSON401.
- Permanent empty authority and enrolled profile pass both routes after restart.
- Audiobookshelf trusted LAN/public routes and authenticated API retain seven
  libraries/five providers; QTS's exact TLS fingerprint is unchanged. All six
  public directory paths still require Access login. Five deployed assets match
  local hashes and contain no private credential values; the index has 41 entries.
- Temporary Cloudflare setup token revoked; existing renewal credentials retained.

Mutations used the separate synthetic `proof-data` authority, not permanent
`data`. Its verified backup/restored copies remain private. The permanent
authority has an initial verified snapshot at
`/share/Container/tasks-server/backups/initial-authority-661a85f5e798`.
This setup does not add a scheduled backup or retention job.

Failed fixture invocations, Python 3.10 hashing compatibility, NAS RAM `/tmp`
archive exhaustion, private-parent upload permissions, and validator cleanup
quoting are retained in first-failure logs. Corrected proof passes; these
failures are not counted as passing cases. The helper's final cleanup and
fail-fast corrections received syntax/self-review; the already-successful
routing pipeline was not reapplied just to exercise its updated cleanup.

Independent operational/security review (GPT-6 Sol/high, default tier,
84.06 seconds) found no confirmed deployment must-fix. Its optimization note
was addressed by explicit refusal before helper execution under -O/-OO or
PYTHONOPTIMIZE; 10 subprocess safeguard cases pass. Follow-up review found no
confirmed must-fix; its results are retained. Connector recreation notes include
both private networks and route verification. Before any real project cutover,
select backup cadence/retention and a verified off-NAS
recovery destination. These are separate from the tested initial empty store.
Review packets/results: review-brief.md, review-findings.md, review-run.json,
helper-guard-proof.json and followup-review-findings.md in the evidence root.

Limits: public CLI traffic was forced through a verified Cloudflare IP from
this workstation without changing global DNS; no offsite-machine trial was
performed. Certificate renewal and full NAS reboot remain unobserved.
Packaged viewer/NVDA acceptance remains TSK-026. TSK-027's deployment criteria
pass, but its TSK-026 prerequisite keeps it nonterminal. No local schema-8
upgrade, real project migration or global harness-hook install was performed.

## Operations and rollback

Use [the NAS runbook](../../qnap-nas-maintenance/docs/tasks-server-deployment.md)
for routing inputs, connector recreation, isolated preparation/probes and exact
private rollback paths. Stop only the tasks server for offline admin commands.
Restore verified snapshots to new private destinations; choose authority
explicitly before switching mounts. Preserve later writes before data rollback.
The NAS workspace had no commits and all its previous files were untracked;
existing operational files were updated without absorbing that unrelated
workspace into a new initial commit.
