# Server backup and synthetic cutover

Use a stopped service for administration of an existing authority. Backup and import claim server.lock; a running service or another administrator must release it first. Restore verifies a backup and publishes a new authority without opening the existing data root. Use an absolute, new destination on a local disk. Backup and restore refuse existing destinations. Backup destinations must be outside the source server data root.

    tasks-server --data-root <server-root> admin backup --out <new-backup-directory>
    tasks-server --data-root <server-root> admin restore --backup <verified-backup-directory> --out <new-server-root>
    tasks-server --data-root <new-server-root> admin info

Backup uses SQLite online backup for server.sqlite and every projects/<uuid>/TASKS.sqlite, including unpublished project receipt stores. Its private manifest records SHA-256, byte length, schema, identity and row counts. Full SQLite integrity and foreign-key checks run before publication. Publication renames a new private staging directory only after all databases and the manifest are durable. The original authority remains untouched. Keep the backup directory private: it contains credentials, nonce history, receipts, attribution and task bodies.

Restore verifies the manifest, every database hash, schema, identity, count, integrity and foreign keys before copying to a private staging directory. It checks the staged copy again, then publishes a new directory. A mismatched or damaged backup is refused. The restored server retains the same server UUID, public credentials, revocations and replay nonces. Do not run the original and restored authorities as simultaneous writers.

To adopt an existing schema-8 project copy, stop the server and use:

    tasks-server --data-root <server-root> admin import-project --database <source-TASKS.sqlite> --name <display-name>

Import takes an online SQLite snapshot of the source, so a source in WAL mode is complete. It validates integrity, foreign keys, UUID, schema and project key, then publishes the catalog row. A catalog UUID, existing project directory (including an unpublished receipt stub), or used key blocks adoption. The source is not modified. An older project needs an explicit migration on a separate copy before import. A failed import removes only its newly created project directory; if the process crashes before catalog publication, an unpublished directory may remain and blocks reuse until an operator inspects it.

For rehearsal, use only synthetic or copied project databases. Compare selected task IDs, versions, body text, dependency rows, import rows, event IDs and snapshots, attribution and receipt IDs between the source copy and imported/restored copy. Confirm both a catalogued project and an unpublished receipt store appear in the backup manifest. Keep local snapshots read-only for rollback.

At real cutover, stop all local writers, take the final verified local project backups, import copies, take and verify a complete server backup, then configure remote clients. Before server writes, rollback may restore the old client profile. After server writes, quiesce the server and take its current verified backup before choosing an authority; reverting directly to an older local snapshot would lose those writes. Never keep the same project UUID writable in local and remote stores.

Container packaging, QNAP runtime checks, Caddy/Cloudflare TLS routes, LAN backend isolation and NAS smoke proof remain separate deployment gates in spec.md.
