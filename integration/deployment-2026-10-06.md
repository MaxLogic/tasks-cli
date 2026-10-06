# Production cutover and installation, 2026-10-06

## Current authority

The user explicitly authorized copying all local SQLite databases to QNAP and
installing the new CLIs. All **55 projects**, **6,297 tasks** and **9,694 original
history events** now belong to the NAS authority at
`/share/Container/tasks-server/data`. UUIDs, project keys, rules, task IDs,
versions, full bodies, dependencies, labels, imports and original event rows
were preserved. Two archived projects (CNR and INIA) retain their original
archive timestamps; their unavailable original authors were not invented.

Server UUID: `8748aad8-d5cd-4c00-881b-842938eee52b`. Container and image remain
`qnap-tasks-server` and the reviewed October 4 image; Docker 27 and the existing
LAN/Cloudflare routes are unchanged. `https://tasks.maxlogic.app` serves this
one authority over both routes, with Ed25519 installation signatures and strict
TLS hostname/certificate validation. This replaces the October 5 empty-store state.

## Installed clients

- Windows: `F:\CliTools\tasks.exe` remains the symlink to this repository's
  `target/release/tasks.exe`, rebuilt with `cargo build --release --locked`.
  SHA-256: `9e8da0e1777acea01785df62c3e1c42c99ac10bfdee33eb6a3b08b4ee88bb29e`.
- Native WSL: `~/.local/bin/tasks` remains the symlink to
  `~/.local/share/tasks-cli/target/release/tasks`, rebuilt natively with
  `CARGO_TARGET_DIR=/home/pawel/.local/share/tasks-cli/target`.
  SHA-256: `834136558aa81719165810eaacb9caca5c1866f8c1bbd8752a41a3a4648be8c8`.
- Default Windows root `C:\Users\pawel\AppData\Local\MaxLogic\tasks-cli`
  and native WSL root `~/.local/share/MaxLogic/tasks-cli` now have remote profiles.
  The existing Windows key and a new independent native Linux key are enrolled.
  No private key was sent to the NAS. Native WSL has 55 converted routing bindings
  and no local project SQLite store; it uses HTTPS before Windows delegation.
- Viewer: `target/viewer-release` now contains the matching installed Windows CLI.
  Settings, theme, filters and startup preference were preserved. The previous
  viewer closed gracefully. The four packaged headless launch cases passed.
  Normal viewer launch requests focus, so it is ready to reopen when the user's
  workstation is available; no foreground or NVDA acceptance was attempted.

Ordinary `tasks list`, `show`, `history`, `rules` and viewer requests now use the
server without connection flags. Machine/account/harness/session context remains
automatic. The real cutover note mutation recorded credential-authoritative pawel,
pawel3, Codex and its session UUID; unavailable model/name/executable fields remain
null. Global harness hooks/settings were not changed.

## Preservation and proof

The Windows snapshot helper held the registry lock and writer reservations on
all 55 source DBs. Old CLI online backups were compared against the locked sources;
only separate copies migrated from schema 6 to 8. Legacy rows were hashed completely,
including binary import records. The two archive conversions add metadata and its
new sequence only; original task/history rows and sequences remain identical.

Copies were converted to standalone DELETE-journal snapshots before mounting them
read-only for NAS import. An earlier import failed before adding any project because
a WAL-mode copy needed writable sidecars. The newly enrolled Linux identity was
verified against a stopped catalog snapshot and reused, without duplicate enrollment.
Earlier failed attempts and backups are retained separately.

NAS admin commands used the pinned reviewed image ID, stopped service and new
private destinations. The complete snapshot of 56 imported databases was downloaded
outside the NAS and checked for every byte hash, integrity/FK, full legacy rows,
metadata/receipts/sequences, catalog names and existing credential/nonce/admin rows.
The server started only after these comparisons passed.

Original local project directories now deny current-user data/append/attribute
writes. All 55 rejected OS write access and zero-row SQLite writes; current source
contents also matched after writer release, using closed private copies including
any WAL files. Sealed WAL directories cannot create SQLite read sidecars. The
Windows profile/client directory ACLs were tightened to owner/SYSTEM/Administrators
because remote configuration correctly refused the legacy broad inherited ACLs.

Installed Windows and native WSL each read all 55 projects. WSL also resolved TSK,
PFM and DAK from normal workspaces, with an intentionally unusable delegation path.
Windows trusted LAN and forced public Cloudflare TLS returned 53 active plus 2 archived
available projects. The opaque public CONNECT proxy changed no DNS or TLS trust and
was stopped afterwards. Windows cutover-note update and native Linux unchanged-rules
write both committed under their distinct enrolled installations. No pending writes.

Final backup includes 6,297 tasks, 9,695 events (the added cutover note) and both mutation
receipts. All 56 hashes, integrity/FK and both enrolled receipt identities passed.
Rust/Cargo sources still match the previously accepted Windows/Linux candidate;
this run rebuilt and checked the installed binaries, without claiming a full suite rerun.
Independent code review found no remaining must-fix after safeguards were corrected.

Evidence: `target/evidence/cutover-20261006-57ad52c0b52c44c6b0ae16ba08b249c6/`:
`comparison.json`, `locked-source-comparison.json`, `retired-local-store.json`,
`installed-smoke.json`, `installed-linux-smoke.json`, `native-linux-mutation.json`,
`windows-mutation-attribution.json`, `final-backup-integrity.json`, install logs,
`viewer-package/` and the final `review-findings.md`. Raw task data stays outside Git.

## Backups and recovery

Private workstation root:
`C:\Users\pawel\AppData\Local\MaxLogic\tasks-cli-cutover-20261006-57ad52c0b52c44c6b0ae16ba08b249c6-final`.
It retains original online backups, migrated copies, registry/cache, original project
ACLs (`local-projects-acl.txt`), old Windows/viewer binaries/settings, import and final
server snapshots. Old native WSL CLI is also retained as
`~/.local/share/tasks-cli/tasks-pre-cutover-20261006`.

Cutover NAS backup (deleted later on 2026-10-06 after a fresh daily archive was
verified):
`/share/Container/tasks-server/backups/cutover-final-20261006-2fc1fa50ef924b84b23571cce16ab7ef`.
Off-NAS copy: the workstation root's `final-server-snapshot/`; its manifest verifies
all 56 standalone databases, including catalog, public credentials, nonces and receipts.
The off-NAS backup and local originals remain retained. Published daily archives
now replace the named NAS cutover directory; see qnap-daily-backups.md.

After remote mutations, recovery starts by stopping writers and taking a current
verified server backup. Restore it to a new private NAS directory, verify identity,
hashes and integrity, then choose one writable authority. Do not simply select the
old local store: it omits remote history. Remove the local write seal only during an
explicit recovery that first stops the remote authority. Restore saved project ACLs
relative to the original store root, and retain an owner-only client directory.

Later on 2026-10-06, the user authorized and received daily 02:00 NAS snapshots,
timestamped TGZ archives and seven-calendar-day retention. The first archive was
verified before removing the named cutover directory. See qnap-daily-backups.md.
TSK-027 remains to-verify behind TSK-026's packaged NVDA gate. Renewal, full NAS reboot
and an offsite-machine run remain unobserved. No push was performed.
