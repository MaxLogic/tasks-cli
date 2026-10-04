#![cfg(feature = "server")]
use serde_json::json;
use tasks_cli::{
    model::{TaskStatus, TaskUpdate},
    server::receipts::{execute, ReceiptIdentity},
    store::{create_project_db, Store},
};
use uuid::Uuid;

fn fixture() -> (tempfile::TempDir, Uuid, ReceiptIdentity) {
    let root = tempfile::tempdir().unwrap();
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).unwrap();
    let identity = ReceiptIdentity {
        request_id: Uuid::new_v4(),
        actor_id: "owner".into(),
        installation_id: Uuid::new_v4(),
        route: "POST /tasks".into(),
    };
    (root, project, identity)
}
fn store(root: &std::path::Path, project: Uuid) -> Store {
    Store::open_rw(root, &project.to_string()).unwrap()
}
#[test]
fn receipt_and_mutation_commit_once_and_replay_precedes_version_check() {
    let (root, project, key) = fixture();
    let result = execute(
        store(root.path(), project),
        &key,
        b"canonical-create",
        |store| {
            let (id, version, event) =
                store.create_task("first", "body", TaskStatus::Ready, vec![])?;
            Ok(json!({"id":id,"version":version,"event_id":event}))
        },
    )
    .unwrap();
    assert_eq!(result.status, 200);
    let replay = execute(
        store(root.path(), project),
        &key,
        b"canonical-create",
        |_| panic!("replay must not dispatch"),
    )
    .unwrap();
    assert_eq!(replay, result);
    let mut update = key.clone();
    update.request_id = Uuid::new_v4();
    update.route = "PATCH /tasks/1".into();
    let result = execute(
        store(root.path(), project),
        &update,
        b"version-1",
        |store| {
            let (_, _, version, event) = store.update_task(
                1,
                1,
                TaskUpdate {
                    title: Some("updated".into()),
                    ..Default::default()
                },
            )?;
            Ok(json!({"version":version,"event_id":event}))
        },
    )
    .unwrap();
    let replay = execute(store(root.path(), project), &update, b"version-1", |_| {
        panic!("stale version must not be checked")
    })
    .unwrap();
    assert_eq!(replay, result);
    let db = store(root.path(), project);
    assert_eq!(
        db.conn
            .query_row(
                "SELECT count(*) FROM events WHERE entity_type='task'",
                [],
                |r| r.get::<_, u64>(0)
            )
            .unwrap(),
        2
    );
    assert_eq!(
        db.conn
            .query_row("SELECT count(*) FROM mutation_receipts", [], |r| r
                .get::<_, u64>(0))
            .unwrap(),
        2
    );
    assert!(db
        .conn
        .execute("DELETE FROM mutation_receipts", [])
        .is_err());
    assert!(db
        .conn
        .execute("UPDATE mutation_receipts SET status=400", [])
        .is_err());
}
#[test]
fn receipt_scope_and_payload_conflicts_never_dispatch_or_mutate() {
    let (root, project, key) = fixture();
    execute(store(root.path(), project), &key, b"first", |_| {
        Ok(json!({"saved":true}))
    })
    .unwrap();
    for fault in ["body", "actor", "installation", "route"] {
        let mut other = key.clone();
        match fault {
            "actor" => other.actor_id = "other".into(),
            "installation" => other.installation_id = Uuid::new_v4(),
            "route" => other.route = "PUT /rules".into(),
            _ => (),
        }
        let result = execute(
            store(root.path(), project),
            &other,
            if fault == "body" {
                b"second".as_slice()
            } else {
                b"first".as_slice()
            },
            |_| panic!("conflicting key must not dispatch"),
        )
        .unwrap();
        assert_eq!(result.status, 409);
        assert_eq!(result.body["error"]["code"], "idempotency_conflict");
    }
}
#[test]
fn terminal_completion_refusal_is_retained_after_the_prerequisite_changes() {
    let (root, project, key) = fixture();
    let mut db = store(root.path(), project);
    db.create_task("parent", "", TaskStatus::Ready, vec![])
        .unwrap();
    db.create_task("child", "", TaskStatus::Ready, vec![1])
        .unwrap();
    drop(db);
    let refusal = execute(
        store(root.path(), project),
        &key,
        b"finish-child",
        |store| {
            store.update_task(
                2,
                1,
                TaskUpdate {
                    status: Some(TaskStatus::Done),
                    ..Default::default()
                },
            )?;
            Ok(json!({}))
        },
    )
    .unwrap();
    assert_eq!(refusal.status, 400);
    let mut db = store(root.path(), project);
    db.update_task(
        1,
        1,
        TaskUpdate {
            status: Some(TaskStatus::Done),
            ..Default::default()
        },
    )
    .unwrap();
    drop(db);
    assert_eq!(
        execute(
            store(root.path(), project),
            &key,
            b"finish-child",
            |_| panic!("refusal cannot become a success")
        )
        .unwrap(),
        refusal
    );
    assert_eq!(
        store(root.path(), project).show_task("2").unwrap().version,
        1
    );
}
#[test]
fn failed_receipt_insert_rolls_back_counter_task_history_and_rules() {
    let (root, project, key) = fixture();
    let db = store(root.path(), project);
    db.conn.execute_batch("CREATE TRIGGER receipt_fault BEFORE INSERT ON mutation_receipts BEGIN SELECT RAISE(ABORT,'synthetic receipt failure'); END;").unwrap();
    drop(db);
    let result = execute(store(root.path(), project), &key, b"first", |store| {
        store.create_task("must roll back", "", TaskStatus::Ready, vec![])?;
        store.rules_set("must roll back", 1)?;
        Ok(json!({"ok":true}))
    });
    assert!(result.is_err());
    let db = store(root.path(), project);
    assert_eq!(
        db.conn
            .query_row("SELECT count(*) FROM tasks", [], |r| r.get::<_, u64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        db.conn
            .query_row("SELECT count(*) FROM events", [], |r| r.get::<_, u64>(0))
            .unwrap(),
        0
    );
    assert_eq!(db.project_rules().unwrap().version, 1);
    assert_eq!(
        db.conn
            .query_row("SELECT next_task_number FROM project", [], |r| r
                .get::<_, u64>(0))
            .unwrap(),
        1
    );
}
#[test]
fn competing_versioned_writes_have_one_success_and_one_persisted_conflict() {
    let (root, project, key) = fixture();
    store(root.path(), project)
        .create_task("original", "", TaskStatus::Ready, vec![])
        .unwrap();
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
    let results = std::thread::scope(|scope| {
        let handles = (0..2)
            .map(|index| {
                let barrier = barrier.clone();
                let mut key = key.clone();
                key.request_id = Uuid::new_v4();
                let root = root.path();
                scope.spawn(move || {
                    let db = store(root, project);
                    barrier.wait();
                    execute(db, &key, b"update", |store| {
                        let result = store.update_task(
                            1,
                            1,
                            TaskUpdate {
                                title: Some(format!("writer-{index}")),
                                ..Default::default()
                            },
                        )?;
                        Ok(json!({"version":result.2}))
                    })
                    .unwrap()
                })
            })
            .collect::<Vec<_>>();
        handles
            .into_iter()
            .map(|h| h.join().unwrap().status)
            .collect::<Vec<_>>()
    });
    assert_eq!(results.iter().filter(|&&s| s == 200).count(), 1);
    assert_eq!(results.iter().filter(|&&s| s == 409).count(), 1);
    assert_eq!(
        store(root.path(), project).show_task("1").unwrap().version,
        2
    );
}

#[test]
fn terminal_refusal_rolls_back_earlier_steps_but_keeps_receipt() {
    let (root, project, key) = fixture();
    let response = execute(store(root.path(), project), &key, b"refused", |store| {
        store.create_task("rollback", "", TaskStatus::Ready, vec![])?;
        Err(tasks_cli::AppError::validation("synthetic refusal"))
    })
    .unwrap();
    assert_eq!(response.status, 400);
    let db = store(root.path(), project);
    assert_eq!(
        db.conn
            .query_row("SELECT count(*) FROM tasks", [], |r| r.get::<_, u64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        db.conn
            .query_row("SELECT count(*) FROM mutation_receipts", [], |r| r
                .get::<_, u64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn schema_seven_upgrade_preserves_history_and_backups_and_rejects_weakened_receipts() {
    let (root, project, _) = fixture();
    let mut db = store(root.path(), project);
    db.create_task("legacy", "exact\r\nΩ", TaskStatus::Ready, vec![])
        .unwrap();
    let before: String = db
        .conn
        .query_row("SELECT snapshot_json FROM events", [], |r| r.get(0))
        .unwrap();
    db.conn
        .execute_batch("DROP TABLE mutation_receipts; PRAGMA user_version=7;")
        .unwrap();
    drop(db);
    assert!(Store::open_rw(root.path(), &project.to_string()).is_err());
    let mut db = Store::open_for_migration(root.path(), &project.to_string()).unwrap();
    let (from, to, backup) = db.migrate().unwrap();
    assert_eq!((from, to), (7, 8));
    let backup = rusqlite::Connection::open(backup.unwrap()).unwrap();
    assert_eq!(
        backup
            .pragma_query_value(None, "user_version", |r| r.get::<_, u64>(0))
            .unwrap(),
        7
    );
    assert_eq!(
        db.conn
            .query_row("SELECT snapshot_json FROM events", [], |r| r
                .get::<_, String>(0))
            .unwrap(),
        before
    );
    db.conn.execute_batch("DROP TRIGGER mutation_receipts_no_delete; CREATE TRIGGER mutation_receipts_no_delete BEFORE DELETE ON mutation_receipts BEGIN SELECT 1; END;").unwrap();
    drop(db);
    assert!(Store::open_rw(root.path(), &project.to_string()).is_err());
}
