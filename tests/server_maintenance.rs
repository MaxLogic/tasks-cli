#![cfg(feature = "server")]

use rusqlite::{params, Connection};
use serde_json::json;
use std::{fs, path::Path};
use tasks_cli::{
    model::TaskStatus,
    server::{
        maintenance,
        receipts::{execute, ReceiptIdentity},
        OwnedServer, Registration,
    },
    store::{create_project_db_with_key, data_root_project_path, Store},
};
use uuid::Uuid;

fn project(root: &Path, key: &str) -> Uuid {
    let id = Uuid::new_v4();
    create_project_db_with_key(root, &id, Some(key)).unwrap();
    let receipt = ReceiptIdentity {
        request_id: Uuid::new_v4(),
        actor_id: "fixture-actor".into(),
        installation_id: Uuid::new_v4(),
        route: "POST /v1/tasks".into(),
    };
    execute(
        Store::open_rw(root, &id.to_string()).unwrap(),
        &receipt,
        b"fixture",
        |store| {
            let (task_id, version, event_id) =
                store.create_task("kept title", "kept body", TaskStatus::Ready, vec![])?;
            Ok(json!({"task_id":task_id,"version":version,"event_id":event_id}))
        },
    )
    .unwrap();
    id
}

fn row_snapshot(path: &Path) -> (String, i64, String, String, i64, i64) {
    let conn = Connection::open(path).unwrap();
    conn.query_row(
        "SELECT p.project_id,p.next_task_number,t.body,e.snapshot_json,
                (SELECT count(*) FROM metadata_events),
                (SELECT count(*) FROM mutation_receipts)
         FROM project p JOIN tasks t ON t.id=1 JOIN events e ON e.task_id=1
         ORDER BY e.event_id DESC LIMIT 1",
        [],
        |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
            ))
        },
    )
    .unwrap()
}

#[test]
fn admin_migrate_upgrades_all_schema8_projects_and_preserves_verified_backups() {
    let base = tempfile::tempdir().unwrap();
    let root = base.path().join("server");
    let server = OwnedServer::initialize(&root).unwrap();
    let ids = [project(&root, "ONE"), project(&root, "TWO")];
    let before = ids.map(|id| row_snapshot(&data_root_project_path(&root, &id.to_string())));
    for id in ids {
        let conn = Connection::open(data_root_project_path(&root, &id.to_string())).unwrap();
        conn.execute_batch(
            "DROP TABLE task_attachments; DROP TABLE attachment_blobs; PRAGMA user_version=8;",
        )
        .unwrap();
    }
    drop(server);
    let migrate = || {
        let result = super_command()
            .args(["--data-root", root.to_str().unwrap(), "admin", "migrate"])
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        serde_json::from_slice::<serde_json::Value>(&result.stdout).unwrap()
    };
    let first = migrate();
    assert_eq!(first["projects"].as_array().unwrap().len(), 2);
    for (index, id) in ids.into_iter().enumerate() {
        let db = data_root_project_path(&root, &id.to_string());
        let conn = Connection::open(&db).unwrap();
        assert_eq!(
            conn.pragma_query_value(None, "user_version", |r| r.get::<_, i32>(0))
                .unwrap(),
            9
        );
        assert_eq!(row_snapshot(&db), before[index]);
        let entry = first["projects"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["project_id"] == id.to_string())
            .unwrap();
        assert_eq!(entry["from_version"], 8);
        assert_eq!(entry["to_version"], 9);
        let backup = Path::new(entry["backup_path"].as_str().unwrap());
        assert_eq!(row_snapshot(backup), before[index]);
        let old = Connection::open(backup).unwrap();
        assert_eq!(
            old.pragma_query_value(None, "user_version", |r| r.get::<_, i32>(0))
                .unwrap(),
            8
        );
        assert_eq!(
            old.query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
    }
    let second = migrate();
    assert!(second["projects"]
        .as_array()
        .unwrap()
        .iter()
        .all(|p| p["from_version"] == 9 && p["to_version"] == 9 && p["backup_path"].is_null()));
    let catalog = Connection::open(root.join("server.sqlite")).unwrap();
    assert_eq!(
        catalog
            .pragma_query_value(None, "user_version", |r| r.get::<_, i32>(0))
            .unwrap(),
        2
    );
    let server = OwnedServer::open(&root).unwrap();
    let out = base.path().join("backup");
    maintenance::backup(&server, &out).unwrap();
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(out.join("manifest.json")).unwrap()).unwrap();
    for item in manifest["files"].as_array().unwrap().iter().skip(1) {
        assert!(item["counts"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c[0] == "attachment_blobs"));
        assert!(item["counts"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c[0] == "task_attachments"));
    }
}

fn super_command() -> std::process::Command {
    let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_tasks-server"));
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000);
    }
    cmd
}

#[test]
fn backup_restores_catalog_credentials_receipts_and_unpublished_store() {
    let base = tempfile::tempdir().unwrap();
    let source = base.path().join("server");
    fs::create_dir(&source).unwrap();
    let server = OwnedServer::initialize(&source).unwrap();
    let credential = server
        .register(&Registration {
            public_key: ed25519_dalek::SigningKey::from_bytes(&[7; 32])
                .verifying_key()
                .to_bytes(),
            actor_id: "owner".into(),
            actor_name: "Owner".into(),
            installation_id: Uuid::new_v4(),
            installation_name: "client".into(),
        })
        .unwrap();
    server.revoke(credential).unwrap();
    let published = project(&source, "PUB");
    let unpublished = project(&source, "STUB");
    {
        let mut store = Store::open_rw(&source, &published.to_string()).unwrap();
        let bytes = tasks_cli::attachment::envelope::encode(
            &b"backup content"[..],
            "kept.txt",
            &tasks_cli::attachment::Limits::PRODUCTION,
        )
        .unwrap();
        store
            .attach(
                1,
                1,
                vec![tasks_cli::attachment::db::PreparedItem {
                    name: "kept.txt".into(),
                    envelope: bytes,
                }],
                &tasks_cli::attachment::Limits::PRODUCTION,
            )
            .unwrap();
    }
    let catalog = Connection::open(source.join("server.sqlite")).unwrap();
    catalog
        .execute(
            "INSERT INTO projects(project_id,name) VALUES (?1,'Published')",
            [published.to_string()],
        )
        .unwrap();
    drop(catalog);
    let source_row = row_snapshot(&data_root_project_path(&source, &unpublished.to_string()));
    let backup = base.path().join("backup");
    let result = maintenance::backup(&server, &backup).unwrap();
    assert_eq!(result.databases, 3);
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(backup.join("manifest.json")).unwrap()).unwrap();
    let evidence = manifest["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["identity"] == published.to_string())
        .unwrap();
    for table in ["attachment_blobs", "task_attachments"] {
        assert!(evidence["counts"]
            .as_array()
            .unwrap()
            .iter()
            .any(|row| row[0] == table && row[1] == 1));
    }
    assert!(backup
        .join("projects")
        .join(unpublished.to_string())
        .is_dir());
    drop(server);
    let restored = base.path().join("restored");
    let result = maintenance::restore(&backup, &restored).unwrap();
    assert_eq!(result.databases, 3);
    let reopened = OwnedServer::open(&restored).unwrap();
    assert_eq!(reopened.server_id(), result.server_id);
    assert!(reopened.credential(credential).is_err());
    assert_eq!(
        row_snapshot(&data_root_project_path(&restored, &unpublished.to_string())),
        source_row
    );
    let conn = Connection::open(restored.join("server.sqlite")).unwrap();
    let revoked: i64 = conn
        .query_row(
            "SELECT revoked FROM credentials WHERE credential_id=?1",
            [credential.to_string()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(revoked, 1);
    let catalog_count: i64 = conn
        .query_row("SELECT count(*) FROM projects", [], |r| r.get(0))
        .unwrap();
    assert_eq!(catalog_count, 1);
}

#[test]
fn import_preserves_events_and_refuses_uuid_or_key_collisions() {
    let base = tempfile::tempdir().unwrap();
    let source = base.path().join("local");
    fs::create_dir(&source).unwrap();
    let id = project(&source, "IMPT");
    let source_db = data_root_project_path(&source, &id.to_string());
    let before = row_snapshot(&source_db);
    let server_root = base.path().join("server");
    fs::create_dir(&server_root).unwrap();
    let server = OwnedServer::initialize(&server_root).unwrap();
    let imported = maintenance::import_project(&server, &source_db, "Imported").unwrap();
    assert_eq!(imported.project_id, id);
    assert_eq!(
        row_snapshot(&data_root_project_path(&server_root, &id.to_string())),
        before
    );
    assert!(maintenance::import_project(&server, &source_db, "Again").is_err());
    let duplicate_root = base.path().join("duplicate");
    fs::create_dir(&duplicate_root).unwrap();
    let duplicate = project(&duplicate_root, "IMPT");
    assert!(maintenance::import_project(
        &server,
        &data_root_project_path(&duplicate_root, &duplicate.to_string()),
        "Duplicate key"
    )
    .is_err());
    assert!(!server_root
        .join("projects")
        .join(duplicate.to_string())
        .exists());
}

#[test]
fn tampered_backup_or_failed_import_never_publishes_destination() {
    let base = tempfile::tempdir().unwrap();
    let server_root = base.path().join("server");
    fs::create_dir(&server_root).unwrap();
    let server = OwnedServer::initialize(&server_root).unwrap();
    let backup = base.path().join("backup");
    maintenance::backup(&server, &backup).unwrap();
    let manifest = backup.join("manifest.json");
    let mut bytes = fs::read(&manifest).unwrap();
    bytes.extend_from_slice(b" ");
    fs::write(&manifest, bytes).unwrap();
    let destination = base.path().join("failed-restore");
    assert!(maintenance::restore(&backup, &destination).is_err());
    assert!(!destination.exists());
    let source = base.path().join("local");
    fs::create_dir(&source).unwrap();
    let id = project(&source, "FAIL");
    let db = data_root_project_path(&source, &id.to_string());
    let conn = Connection::open(&db).unwrap();
    conn.pragma_update(None, "foreign_keys", "OFF").unwrap();
    conn.execute(
        "INSERT INTO dependencies(task_id,depends_on_id) VALUES (?1,?2)",
        params![1, 999],
    )
    .unwrap();
    drop(conn);
    assert!(maintenance::import_project(&server, &db, "Invalid").is_err());
    assert!(!server_root.join("projects").join(id.to_string()).exists());
}
