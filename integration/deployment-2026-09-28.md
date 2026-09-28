# Deployment record: to-verify, project keys and key cache 2026-09-28

Install authorized by the user on 2026-09-28. It covers three CLI commits:

- `e56cf62` feat(status): add to-verify status with completion guard
- `72e7525` feat(keys): add project keys to task IDs (DAK-212)
- `b40cc54` perf(store): cache every key lookup and leave no -wal/-shm after reads

Both binaries report `tasks 0.1.0 (commit b40cc547edce)`. The data schema is
now version 6; stores on older versions must be migrated (see "Live migration").

## Executables

- Windows: `F:\CliTools\tasks.exe` → `..\projects\MaxLogic\tasks-cli\target\release\tasks.exe`,
  built with `cargo build --release --locked` (log
  `target/evidence/deploy-2026-09-28/win-build.log`).
  SHA-256 `38a028f55d0b0cd08d4b56cd203635c13e7e162c17a4992c3403e9492faaeb5b`.
- Ubuntu/WSL: `/home/pawel/.local/bin/tasks` → `/home/pawel/.local/share/tasks-cli/target/release/tasks`,
  built with that `CARGO_TARGET_DIR` (log `target/evidence/deploy-2026-09-28/wsl-build.log`).
  SHA-256 `b4bb016d9fec8190e289ee062aba6d82d2cc9ef2db37faab86c06ccddf718d74`.
  `TASKS_WINDOWS_EXE=/mnt/f/CliTools/tasks.exe`; a `tasks doctor` under
  `/mnt/f/projects/MaxLogic/tasks-cli` delegated to Windows (its error named the
  Windows registry path).

No tasks.exe process was running during the build. The viewer
(`target\viewer-release\tasks_viewer.exe`) was stopped first.

## Skills

Applied with `git apply --check`, then `git apply`, both exit 0, in this order:

1. `target/evidence/to-verify/skills-after-install.patch`: `resolve-task/SKILL.md`,
   `resolve-task/references/verification.md`, `task-ledger/SKILL.md`
   (the `to-verify` status and the `update --status done` prerequisite guard).
2. `target/evidence/project-keys/skills-after-install.patch`: `create-task/SKILL.md`,
   `resolve-task/SKILL.md`, `task-ledger/SKILL.md` (`KEY-N` task IDs, `project-key`,
   cross-project exit 3).

`b40cc54` needs no skill text: the key cache (`<data-root>/project-keys.json`)
and the read-connection change are internal and change no command, output or
exit code the skills describe.

## Viewer

`pwsh -NoProfile -File viewer/tool/package.ps1` exit 0: 40 files, bundled
`tasks.exe` SHA-256 equal to the Windows build above, launch cases passed
(log `target/evidence/deploy-2026-09-28/viewer-package.log`).
`tasks_viewer.exe` SHA-256 `b56b160878db840e5bff4926b3242cf3473440d16bd58237619438e6a91d190c`.

## Verification

`flutter test test/integration/real_cli_clipboard_test.dart test/integration/real_cli_editor_test.dart`
against `target\release\tasks.exe` (the installed build), exit 0: 4 passed,
1 skipped. The skipped case, "a lost save acknowledgement is reconciled against
the commit", needs a `--features test-hooks` build, which the installed binary
is not. Log `target/evidence/deploy-2026-09-28/viewer-real-cli.log`.


## Viewer restart

After the migration, the viewer was started from `target\viewer-release` with
that folder as its working directory, the same as `start-viewer.lnk`. It has no
console window. The process is running and its "Tasks Viewer" window is visible.

## Live migration

Result: all 53 projects migrated from schema 4 to 6 and keyed. No registered
project is outside the CSV, so none is left without a key.

### Checks before migration

`issues/active/project-key-task-ids/project-keys.csv` has 53 rows. Every key is
2-6 characters, `[A-Z][A-Z0-9]*`, not `T` plus digits, and unique. Every
`project_id` is unique, bound in `registry.json` at the CSV path, and has
`projects/<UUID>/TASKS.sqlite`. The registry and data root hold the same 53
projects. `doctor` reported schema 4 for all 53.

### Backups

- The first run stopped at ACV before anything changed. `tasks backup --out`
  exits 6 on a schema-4 store ("this build requires 6. Run tasks migrate"), so
  the standalone backup command cannot back up a store that still needs
  migrating.
- The user then chose a full copy plus `migrate`'s own backup. With no tasks.exe
  or viewer process running, the whole data root was copied to
  `%LOCALAPPDATA%\MaxLogic\tasks-cli-backups\pre-keys-20260928-full\`. That
  covers `projects\` with every `-wal`/`-shm`, `registry.json`, `registry.lock`,
  `project-keys.csv` and `viewer-cache.sqlite3`. Source and copy match: 110
  files, 63,840,773 bytes, and SHA-256 equal per file, including all 53
  `TASKS.sqlite`. Hashes: `target/evidence/deploy-2026-09-28/full-copy-sha256.csv`.
- Each `migrate` also wrote and validated its own pre-upgrade backup, listed in
  the table below. The script checked that each one exists and is not empty.

### Run

The harness permission check refused to let the agent run the migration
script, so the user ran it
(`target/evidence/deploy-2026-09-28/migrate.ps1`, next to `validate.ps1` and
`fullcopy.ps1`). It works through the projects in CSV order and stops at the
first failure. For each project it runs:

1. `migrate --project <UUID>`, then checks that `backup_path` exists and is
   not empty;
2. `project-key --set <KEY>`;
3. `doctor`, which must report schema 6, and `project-key`, which must read the
   key back;
4. `list --limit 3`, with `--open` and then `--status done` as fallbacks when
   the list is empty. It must show `KEY-N` IDs and no `T-N` ID.

Raw results: `target/evidence/deploy-2026-09-28/migration-results.csv`. Command
log: `migration.log`. The failed first run is in
`migration-results.stopped-1.csv`.

Notes on the spot-check column:

- It lists the first three `KEY-N` matches in the output, so a dependency
  column can repeat an ID. INIG shows `INIG-001 INIG-002 INIG-001` because
  INIG-002 depends on INIG-001. `list --status done --limit 3` shows three
  distinct tasks, INIG-001 to INIG-003.
- VSW listed nothing under any of the three filters. Its key was confirmed
  with `project-key`.
- `next_after` paging cursors still print the legacy form (`P2:T-003`) in
  keyed projects.

WSL delegation: `tasks list --limit 2 --project d48b3ab5-...` from
`/mnt/f/projects/MaxLogic/DelphiAiKit` returned DAK-356 and DAK-357, exit 0.
| Key | Project | Schema | Pre-migrate backup (in `projects\<UUID>\`) | Spot-check |
|---|---|---|---|---|
| ACV | ActiveAppView `973b97c0-d88d-4e46-9f84-885c5a84a559` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632436800-277348-0.sqlite` | ACV-048 ACV-049 ACV-050 |
| A11Y | Accessibility-Framework `348fbf67-5320-49b1-b49f-75574ed98dcb` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632467326-250976-0.sqlite` | A11Y-001 A11Y-002 A11Y-003 |
| ABMC | AudioBookMetadataCollector `f8fbc96a-5ac5-49c7-bdbc-822a7018909a` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632467742-11392-0.sqlite` | ABMC-001 ABMC-002 ABMC-003 |
| CNR | CodexNotificationsReceiver `0d8c6517-f086-4d17-bb30-188cafb1b7c4` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632468050-273424-0.sqlite` | CNR-010 |
| DAK | DelphiAiKit `d48b3ab5-a027-4acf-94d7-d8adaf9938db` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632468386-271388-0.sqlite` | DAK-356 DAK-355 DAK-357 |
| DCO | DelphiCompanion `4300fdf3-b658-4371-902a-b8d5ddbc8485` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632468670-78448-0.sqlite` | DCO-014 |
| DS | DelphiSemantics `e56126d2-2e3c-4730-a86e-d3b94f4febbe` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632468947-264900-0.sqlite` | DS-630 DS-632 DS-634 |
| ENC | EncodingFix `0ad305a9-7416-47d4-b5bc-ffbc1d8be3c6` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632469342-261440-0.sqlite` | ENC-001 ENC-002 ENC-003 |
| MLF | MaxLogicFoundation `2adeca08-618b-4f98-8701-2fd567342c27` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632469629-266904-0.sqlite` | MLF-019 MLF-020 MLF-021 |
| CLIP | clipboard-insight-nvda `445cbf4d-85f8-4bf4-b919-fc412acd811c` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632469870-259036-0.sqlite` | CLIP-007 CLIP-008 CLIP-009 |
| KOKO | kokoro-tts-nvda `d20f3c94-8954-43a4-918b-a2578e9510fe` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632470219-269208-0.sqlite` | KOKO-001 KOKO-002 |
| VSW | voice-switcher `1e954363-dada-4ad3-8745-23f9a9dfcd6c` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632470464-262984-0.sqlite` | (no tasks listed) |
| XTTS | xtts-v2-nvda `1c022f7a-f4b0-40db-8236-11c09caa4360` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632470863-277008-0.sqlite` | XTTS-001 XTTS-002 XTTS-003 |
| SBV | SplitByVoices `09ab49cd-93ea-46ec-9237-5285d14b7302` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632471146-119300-0.sqlite` | SBV-001 SBV-002 SBV-003 |
| PSJ | PawelsPersonalShadowJourney `2476549b-ab44-4725-8536-1f29c3c6358f` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632471523-231892-0.sqlite` | PSJ-001 PSJ-002 PSJ-003 |
| RP | RepoPulse `7b70f453-0e10-457b-82a6-8db0184c6144` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632471831-276764-0.sqlite` | RP-057 |
| SV | SecretVault `a12de652-4783-4675-a440-68328c0d25bd` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632472086-213368-0.sqlite` | SV-031 SV-032 SV-033 |
| SKS | SkillSearch `aa294804-9826-4257-ab10-812836ee5572` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632472465-102496-0.sqlite` | SKS-064 |
| SYNC | SkillSync `bfd283a0-3852-47dd-af36-cffa2958c129` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632472717-274668-0.sqlite` | SYNC-005 SYNC-006 SYNC-007 |
| SA | SpeakAloud `01c85e6d-e566-40df-aee3-a9027f6ac512` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632472964-274884-0.sqlite` | SA-127 SA-128 SA-129 |
| TODO | ToDoApp `df8cdbe2-50e9-4ef9-9a54-3dac496aede7` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632473346-277772-0.sqlite` | TODO-167 TODO-168 |
| TS | TreeSize `9f771ecd-f945-4429-93d7-a51226b28c78` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632473651-184256-0.sqlite` | TS-230 TS-198 TS-228 |
| YTD | YoutubeTranscriptionDownloader `e2b7b004-500f-48f7-81c9-45be45d3fec3` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632474066-268052-0.sqlite` | YTD-037 |
| ALAC | alacritty-group `40d8ef66-3378-489f-9a74-0df568d9c360` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632474306-248932-0.sqlite` | ALAC-021 |
| AUTH | betterAuth-VPS `e53eb78e-9f70-49fb-b64b-bc74961c34d8` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632474559-257488-0.sqlite` | AUTH-194 |
| CXV | codex-sessions-viewer `98972be8-de3e-44d8-906e-ddaf7757a234` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632474976-277608-0.sqlite` | CXV-173 CXV-163 CXV-172 |
| EYE | eye-health-training `78ced2fd-0703-43d2-82ba-0dd3fe9962a5` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632475261-259500-0.sqlite` | EYE-062 EYE-187 EYE-188 |
| GAMES | games-small `bcd3db4d-6342-4315-95ed-2b2d507dcf84` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632475594-269672-0.sqlite` | GAMES-068 GAMES-069 |
| CRON | maxCron `30b049fb-f9c5-489d-a471-fa91655428a4` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632475928-88276-0.sqlite` | CRON-102 |
| NEXUS | maxEventNexus `ba0bf55c-07c7-4b38-9924-175cab7f6acf` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632476168-183460-0.sqlite` | NEXUS-1042 |
| PFM | pfm `70f4bba9-b5bc-4e01-a010-7177e4bac0f3` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632476465-258948-0.sqlite` | PFM-296 PFM-182 PFM-186 |
| PROF | profiling `1f000c23-79c6-4599-84b4-0eecca98d621` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632476883-13412-0.sqlite` | PROF-001 PROF-002 PROF-003 |
| RPG | rpg-dice `fe64da70-86da-46e3-a47e-bd721b7e8727` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632477168-11844-0.sqlite` | RPG-009 RPG-016 RPG-018 |
| RPGB | rpg-dice backend `d3454552-1d58-43bb-9943-6240cbc3a0d2` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632477523-277804-0.sqlite` | RPGB-001 RPGB-002 RPGB-003 |
| RPGF | rpg-dice frontend `6fdc2881-316a-4685-8f0e-c5198f48b222` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632477834-101892-0.sqlite` | RPGF-001 RPGF-002 RPGF-003 |
| WWW | www.maxlogic.eu `0084f526-20dc-4359-8185-da1ba929aa9a` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632478224-107320-0.sqlite` | WWW-001 WWW-002 WWW-003 |
| FTP | ftpSmartClient `08fef74d-7bc7-42ad-83a4-ed419c5b25e3` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632478487-257540-0.sqlite` | FTP-015 FTP-017 |
| MDC | mod-dependency-checker `8bec84d8-83a6-47bc-8916-c1459ab60b64` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632478866-277668-0.sqlite` | MDC-001 MDC-002 MDC-003 |
| MXTDB | maxTdb `fb3f3915-69d7-43c9-bad4-0db2a485306b` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632479307-270716-0.sqlite` | MXTDB-088 MXTDB-089 MXTDB-925 |
| TE5 | TE5 `77052e9d-49d8-438f-bbe1-1d997146b850` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632479781-9668-0.sqlite` | TE5-001 TE5-002 TE5-003 |
| DAC | duplicate_account_cleaner `0d95d79e-f454-4d0c-a1fa-be843140e238` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632480084-274064-0.sqlite` | DAC-001 DAC-002 DAC-003 |
| OAC | order_access_cli `502f610c-16da-40c5-a9b9-7f1caf4f9c6b` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632480356-69860-0.sqlite` | OAC-014 |
| TE5B | te5-backend `d680d85d-c0b6-422c-bf37-54f9e0953923` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632480667-105204-0.sqlite` | TE5B-001 TE5B-002 TE5B-003 |
| TE5S | te5stock `9ac76c3f-ee5f-49d7-85e5-c0c5e876bd85` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632480946-246736-0.sqlite` | TE5S-001 TE5S-002 TE5S-003 |
| T5AI | teaccounts_importer_cli `4da0441c-3782-4992-b715-c0d87fbedc04` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632481340-224212-0.sqlite` | T5AI-001 T5AI-002 T5AI-003 |
| FDS | FlexDocServer `791e5575-c7b4-4e53-924e-f69904aa62ef` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632481650-240828-0.sqlite` | FDS-001 FDS-002 FDS-003 |
| FD | Flexdoc `ff1fe730-a3a2-4ab4-8d90-231fd75e6c6a` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632481954-245500-0.sqlite` | FD-001 FD-002 FD-003 |
| MMS | monitor-msgsend `f3182305-04b8-475b-8d35-f80d926bb2c4` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632482351-51340-0.sqlite` | MMS-001 MMS-002 MMS-003 |
| DBML | DeviceBridge_MaxLogic `94aceb9c-9d1c-430b-b769-95e21e27e4c5` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632482654-90348-0.sqlite` | DBML-016 DBML-019 DBML-021 |
| DBSP | DeviceBridge_StatusPro `59888d34-763a-49f5-9060-327309b87da4` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632483103-53600-0.sqlite` | DBSP-016 DBSP-019 DBSP-021 |
| KFZ | Kfzmeister_workCopy `37f1ae5b-5fa4-43b1-8b00-514a6d824220` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632483445-269616-0.sqlite` | KFZ-039 KFZ-066 KFZ-071 |
| INIA | ini2json-tests a-op5.5med `9e5772e9-2c63-4013-8698-245635e0fbad` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632483823-264508-0.sqlite` | INIA-008 INIA-007 INIA-009 |
| INIG | ini2json-tests g-s6-med `154503d2-5835-462b-a18a-7b0a5f5b5336` | 4 -> 6 | `TASKS.v4-pre-migrate-1790632484078-240884-0.sqlite` | INIG-001 INIG-002 INIG-001 |
