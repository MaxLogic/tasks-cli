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
