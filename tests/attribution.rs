use serde_json::Value;
use tasks_cli::model::{Attribution, AttributionSource, TaskStatus, TaskUpdate};
use tasks_cli::store::{create_project_db, Store};
use tempfile::TempDir;
use uuid::Uuid;

fn fixture() -> (TempDir, Uuid, Store) {
    let root = tempfile::tempdir().expect("isolated attribution root");
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).expect("create project");
    let store = Store::open_rw(root.path(), &project.to_string()).expect("open store");
    (root, project, store)
}

#[test]
fn task_and_rules_mutations_persist_versioned_context_in_history() {
    let (_root, _project, mut store) = fixture();
    store
        .create_task("audit", "body", TaskStatus::Ready, vec![])
        .unwrap();
    store
        .update_task(
            1,
            1,
            TaskUpdate {
                title: Some("renamed".into()),
                ..Default::default()
            },
        )
        .unwrap();
    store.rules_set("project rules", 1).unwrap();
    let contexts = store
        .conn
        .prepare("SELECT attribution_json FROM events ORDER BY event_id")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(contexts.len(), 3);
    for context in contexts {
        let value: Value = serde_json::from_str(&context).unwrap();
        assert_eq!(value["schema_version"], 1);
        assert!(Uuid::parse_str(value["request_id"].as_str().unwrap()).is_ok());
    }
    let history = serde_json::to_value(store.history(1, None, 10, None).unwrap().0.items).unwrap();
    assert_eq!(history[0]["attribution"]["schema_version"], 1);
}

#[test]
fn project_creation_and_key_changes_have_separate_append_only_metadata_history() {
    let (_root, _project, mut store) = fixture();
    store.set_project_key("AUD").unwrap();
    store.set_project_key("AUD").unwrap();
    let entries = store
        .conn
        .prepare("SELECT operation, attribution_json FROM metadata_events ORDER BY event_id")
        .unwrap()
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(
        entries.iter().map(|x| x.0.as_str()).collect::<Vec<_>>(),
        ["create", "set-key"]
    );
    assert!(entries.iter().all(
        |(_, context)| serde_json::from_str::<Value>(context).unwrap()["schema_version"] == 1
    ));
    assert!(store
        .conn
        .execute("DELETE FROM metadata_events", [])
        .is_err());
    assert_eq!(
        store
            .conn
            .query_row("SELECT COUNT(*) FROM events", [], |r| r.get::<_, u64>(0))
            .unwrap(),
        0
    );
}

#[test]
fn unchanged_rules_leave_version_and_audit_unchanged() {
    let (_root, _project, mut store) = fixture();
    assert_eq!(store.rules_set("", 1).unwrap(), 1);
    assert_eq!(
        store
            .conn
            .query_row("SELECT COUNT(*) FROM events", [], |r| r.get::<_, u64>(0))
            .unwrap(),
        0
    );
}

#[test]
fn empty_import_persists_provenance_once() {
    let (_root, _project, mut store) = fixture();
    let parsed =
        tasks_cli::markdown::parse("empty.md", b"# Task Backlog\n".to_vec(), None).unwrap();
    let hash = parsed.source_hash.clone();
    store.import_apply(parsed.clone(), Some(&hash)).unwrap();
    store.import_apply(parsed, Some(&hash)).unwrap();
    let imports: u64 = store
        .conn
        .query_row(
            "SELECT COUNT(*) FROM metadata_events WHERE operation='import'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        imports, 1,
        "even a zero-task import persists provenance once"
    );
}

#[test]
fn schema_six_migration_preserves_legacy_snapshots_without_inventing_authors() {
    let (root, project, mut store) = fixture();
    store
        .create_task("legacy Ω", "exact\r\nbody", TaskStatus::Ready, vec![])
        .unwrap();
    let snapshot: String = store
        .conn
        .query_row("SELECT snapshot_json FROM events", [], |row| row.get(0))
        .unwrap();
    // Removing only the additive version-seven objects restores the version-six
    // representation, including an existing history snapshot and task version.
    store.conn.execute_batch("DROP TABLE metadata_events; ALTER TABLE events DROP COLUMN attribution_json; PRAGMA user_version=6;").unwrap();
    drop(store);
    let mut migration = Store::open_for_migration(root.path(), &project.to_string()).unwrap();
    let (from, to, backup) = migration.migrate().unwrap();
    assert_eq!((from, to), (6, 7));
    let backup = rusqlite::Connection::open(backup.unwrap()).unwrap();
    assert_eq!(
        backup
            .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .unwrap(),
        6
    );
    assert_eq!(
        backup
            .query_row("SELECT snapshot_json FROM events", [], |row| row
                .get::<_, String>(0))
            .unwrap(),
        snapshot
    );
    drop(migration);
    let mut store = Store::open_rw(root.path(), &project.to_string()).unwrap();
    let old = store.history(1, None, 10, Some(1)).unwrap().1.unwrap();
    assert!(old.attribution.is_none());
    assert_eq!(old.snapshot_json.unwrap(), snapshot);
    assert!(store.metadata_history(None, 10).unwrap().items.is_empty());
    store
        .update_task(
            1,
            1,
            TaskUpdate {
                title: Some("new".into()),
                ..Default::default()
            },
        )
        .unwrap();
    assert!(store.history(1, None, 10, None).unwrap().0.items[1]
        .attribution
        .is_some());
}

#[test]
fn supplied_context_is_snapshotted_paginated_and_restored_by_backup() {
    let (root, project, mut store) = fixture();
    let mut first = Attribution {
        actor_name: Some("Alice".into()),
        actor_authority: AttributionSource::LocalUnverified,
        machine_name: Some("workstation".into()),
        harness: "codex".into(),
        session_id: Some("session-a".into()),
        ..Default::default()
    };
    store.set_attribution(&first).unwrap();
    store
        .create_task("audit", "complete body", TaskStatus::Ready, vec![])
        .unwrap();
    store.set_project_key("AUD").unwrap();
    first.actor_name = Some("Alice renamed".into());
    first.request_id = Uuid::new_v4();
    store.set_attribution(&first).unwrap();
    store.set_project_key("NEW").unwrap();
    let page = store.metadata_history(None, 2).unwrap();
    assert!(page.has_more);
    assert_eq!(
        page.items[1].attribution.actor_name.as_deref(),
        Some("Alice")
    );
    let next = store.metadata_history(page.next_after, 2).unwrap();
    assert!(!next.has_more);
    assert_eq!(next.items[0].attribution, first);
    assert!(store.metadata_history(None, 101).is_err());
    let backup_path = root.path().join("audit-backup.sqlite");
    store.backup(&backup_path).unwrap();
    let backup = rusqlite::Connection::open(backup_path).unwrap();
    let json: String = backup
        .query_row(
            "SELECT attribution_json FROM events WHERE event_id=1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let saved: Attribution = serde_json::from_str(&json).unwrap();
    assert_eq!(saved.actor_name.as_deref(), Some("Alice"));
    assert_eq!(
        backup
            .query_row("SELECT COUNT(*) FROM metadata_events", [], |row| row
                .get::<_, u64>(0))
            .unwrap(),
        3
    );

    for (command, arg) in [("history", Some("T-1")), ("project-history", None)] {
        for format in ["text", "json"] {
            let mut cli = std::process::Command::new(env!("CARGO_BIN_EXE_tasks"));
            cli.env_remove("TASKS_WINDOWS_EXE")
                .env_remove("TASKS_PROJECT");
            cli.args([
                "--data-root",
                root.path().to_str().unwrap(),
                "--project",
                &project.to_string(),
                "--format",
                format,
                command,
            ]);
            if let Some(arg) = arg {
                cli.arg(arg);
            }
            let output = cli.output().unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            let text = String::from_utf8(output.stdout).unwrap();
            assert!(text.contains("session-a"));
            assert!(text.contains("Alice"));
        }
    }
}

#[test]
fn refused_writes_and_audit_insert_failures_roll_back_the_entire_mutation() {
    let (_root, _project, mut store) = fixture();
    store
        .create_task("first", "body", TaskStatus::Ready, vec![])
        .unwrap();
    assert!(store
        .update_task(
            1,
            99,
            TaskUpdate {
                title: Some("wrong".into()),
                ..Default::default()
            }
        )
        .is_err());
    store
        .update_task(
            1,
            1,
            TaskUpdate {
                title: Some("first".into()),
                ..Default::default()
            },
        )
        .unwrap();
    assert_eq!(
        store
            .conn
            .query_row("SELECT COUNT(*) FROM events", [], |row| row
                .get::<_, u64>(0))
            .unwrap(),
        1
    );
    store.conn.execute_batch("CREATE TRIGGER test_abort BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'test audit failure'); END;").unwrap();
    assert!(store
        .create_task("second", "body", TaskStatus::Ready, vec![])
        .is_err());
    assert!(store
        .update_task(
            1,
            1,
            TaskUpdate {
                title: Some("changed".into()),
                ..Default::default()
            }
        )
        .is_err());
    assert!(store.rules_set("new rules", 1).is_err());
    assert_eq!(
        store
            .conn
            .query_row("SELECT next_task_number FROM project", [], |row| row
                .get::<_, u64>(0))
            .unwrap(),
        2
    );
    assert_eq!(store.rules_show().unwrap().version, 1);
    let task = store
        .show_tasks(&["T-1".into()], false)
        .unwrap()
        .0
        .remove(0);
    assert_eq!(task.version, 1);
    assert_eq!(task.title, "first");
    store.conn.execute_batch("DROP TRIGGER test_abort; CREATE TRIGGER test_abort_metadata BEFORE INSERT ON metadata_events BEGIN SELECT RAISE(ABORT,'test audit failure'); END;").unwrap();
    assert!(store.set_project_key("BAD").is_err());
    assert!(store.project_key.is_none());
    assert!(store
        .conn
        .query_row("SELECT project_key FROM project", [], |row| row
            .get::<_, Option<String>>(0))
        .unwrap()
        .is_none());
    let mut oversized = Attribution::default();
    oversized.session_name = Some("x".repeat(16_384));
    assert!(store.set_attribution(&oversized).is_err());
}

#[test]
fn import_task_rules_and_provenance_share_context_and_rollback_together() {
    let (_root, _project, mut store) = fixture();
    let context = Attribution {
        machine_name: Some("import-host".into()),
        ..Default::default()
    };
    store.set_attribution(&context).unwrap();
    let parsed = tasks_cli::markdown::parse(
        "copy.md",
        b"## Rules\nrule\n## ready\n### T-1 Imported\nbody\n".to_vec(),
        None,
    )
    .unwrap();
    let hash = parsed.source_hash.clone();
    store.conn.execute_batch("CREATE TRIGGER test_abort BEFORE INSERT ON metadata_events BEGIN SELECT RAISE(ABORT,'test audit failure'); END;").unwrap();
    assert!(store.import_apply(parsed.clone(), Some(&hash)).is_err());
    for table in ["tasks", "events", "imports"] {
        let count: u64 = store
            .conn
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 0);
    }
    assert_eq!(store.rules_show().unwrap().body, "");
    store.conn.execute_batch("DROP TRIGGER test_abort").unwrap();
    store.import_apply(parsed, Some(&hash)).unwrap();
    let contexts = store.conn.prepare("SELECT attribution_json FROM events UNION ALL SELECT attribution_json FROM metadata_events WHERE operation='import'").unwrap()
        .query_map([], |row| row.get::<_, String>(0)).unwrap().collect::<Result<Vec<_>, _>>().unwrap();
    assert_eq!(contexts.len(), 3);
    assert!(contexts
        .iter()
        .all(|json| serde_json::from_str::<Attribution>(json).unwrap() == context));
}
