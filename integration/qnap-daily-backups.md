# Daily QNAP task backups

## Schedule and files

The NAS runs a fresh complete snapshot daily at **02:00 local CET/CEST**.
The persistent QNAP crontab is `/etc/config/crontab`; its active copy is
loaded with `/usr/bin/crontab /etc/config/crontab`.

```cron
0 2 * * * /usr/local/bin/python /share/Container/tasks-server/bin/daily-backup.py >> /share/Container/tasks-server/daily-backup.log 2>&1 # tasks-server-daily-snapshot
```

Archives are private files under `/share/Container/tasks-server/backups/`, named
`tasks-snapshot-YYYYMMDDTHHMMSS+ZZZZ.tgz`. Each archive contains `manifest.json`,
`server.sqlite`, and every project database at `projects/<uuid>/TASKS.sqlite`.
This includes archived projects and any unpublished databases required by
mutation receipts. The server identity is
`8748aad8-d5cd-4c00-881b-842938eee52b`.

Retention keeps today and the previous six local calendar dates. Removal runs
only after publishing a verified new archive and applies only to regular files
with this exact filename format. Other backup directories are untouched.
Multiple manual runs on one date can produce multiple archives for that date.

## Operation

Source: [qnap-daily-backup.py](qnap-daily-backup.py). The installed root-owned
script uses the NAS's existing `/usr/local/bin/python` (2.7.18) and standard
library. No Python package or Docker upgrade is required.

The job locks against overlapping runs, inspects the exact server container and
data mount, stops only `qnap-tasks-server`, and runs native `admin backup` using
that server's immutable image. SQLite backup, integrity and foreign-key checks
produce a standalone snapshot and its manifest. The job restarts the server
before compression. The API is briefly unavailable during snapshot creation.

Before publication, the job reads the complete compressed archive and verifies
its gzip footer, exact members, server identity, and each database's SHA-256
and byte count. A new archive is published without replacing an existing file.
Failed backups retain earlier archives and do not perform retention removal.

Docker commands have deadlines. A separate process watches the backup
coordinator and can recover its original server state if the coordinator exits
unexpectedly. It removes only that run's identified admin container, workspace
and partial archive. The next run also handles a stale recovery marker. This
does not guarantee recovery from a simultaneous host/Docker failure; inspect
the logs and server after such an outage.

## Manual backup and recovery

Run as NAS administrator/root through the documented SSH elevation path:

```sh
/usr/local/bin/python /share/Container/tasks-server/bin/daily-backup.py >> /share/Container/tasks-server/daily-backup.log 2>&1
```

Back up these published `.tgz` files with the NAS backup software. They contain
private task data. Do not use an old cutover directory as the recurring backup
source, or copy only the main files from the live WAL databases.

For restoration, unpack a selected archive into a new private directory and
use native `admin restore --backup <unpacked-directory> --out <new-data-root>`.
Restore validates the complete manifest, databases and identity. Select one
writable authority explicitly, preserving the current store before switching;
old local database files omit later remote changes.

For cron rollback, remove only the row marked `tasks-server-daily-snapshot`,
then reload `/etc/config/crontab`. Preserve unrelated and newer entries. Do not
replace the entire crontab with an older saved copy. Remove the installed job
only after confirming no backup or recovery watcher is running.

## Verified installation, 2026-10-06

The persistent and active crontabs both contain the single new row; all 63
previous rows were preserved (64 rows after installation). The NAS timezone
is CET/CEST (`/etc/TZ`: `CET-1CEST-2`), with no overriding cron timezone.

Installed script SHA-256:
`2b4ae70f1cf2c74ecb71b0ab00164198cbbdd53434e81fe385359a5139c58cf6`.
Private installation record and previous crontabs:
`/share/Container/tasks-server/operations/daily-backup-0454f86447e047f4a5ce73b75e62f0bf/`.

The first real run completed successfully. Its log records snapshot creation
at 11:48:52 CEST, server restart at 11:49:03, and archive publication at 11:49:17.
Published file:

`/share/Container/tasks-server/backups/tasks-snapshot-20261006T114852+0200.tgz`

- 26,790,247 bytes; root-owned, mode `0600`.
- 56 databases: 55 project databases and the catalog, plus `manifest.json`.
- SHA-256: `5cb61d95a8609bcf0edf7a9c6408fc887a2398666b5776a07a8283d2949ddd63`.
- Separate post-run verification reread every archived database/hash and gzip
  footer. No partial workspace or recovery marker remained.
- Installed Windows and native WSL clients successfully read the signed remote
  catalog after backup; both reported zero pending requests.

After verification, the user-authorized directory
`backups/cutover-final-20261006-2fc1fa50ef924b84b23571cce16ab7ef/` was deleted.
Its earlier off-NAS copy and local database originals were retained. Other NAS
backup directories were untouched.

Evidence is under ignored
`target/evidence/daily-backup-20261006-0454f86447e047f4a5ce73b75e62f0bf/`:
`installation-output.json`, `first-run.json`, `first-archive-proof.json`,
`old-cutover-deletion.json`, client readbacks and independent source review.
The supplied-source review used GPT-6 Sol/high/default tier, tools disabled;
the final reviewed bytes match the installed script. The scheduled 02:00 run,
full NAS reboot, expiration over seven days and interruption recovery have
not yet been observed. No Rust binary, gateway, Docker version or viewer was changed.
