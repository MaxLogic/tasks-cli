use rusqlite::Connection;
use std::fs;
use std::thread;
use std::time::{Duration, Instant};
use tasks_cli::model::TaskStatus;
use tasks_cli::store::{create_project_db, Store};
use tempfile::TempDir;
use uuid::Uuid;

fn setup() -> (TempDir, Uuid, std::path::PathBuf) {
    let temp = tempfile::tempdir().expect("temporary directory");
    let id = Uuid::new_v4();
    create_project_db(temp.path(), &id).expect("database");
    let work = temp.path().join("work");
    fs::create_dir_all(&work).expect("work");
    (temp, id, work)
}

#[test]
fn backup_is_consistent_and_refuses_overwrite() {
    let (temp, id, _work) = setup();
    let mut store = Store::open_rw(temp.path(), &id.to_string()).expect("open");
    store
        .create_task("one", "body", TaskStatus::Backlog, Vec::new())
        .expect("task");
    let backup = temp.path().join("backup.sqlite");
    let bytes = store.backup(&backup).expect("backup");
    assert!(bytes > 0);
    assert!(store.backup(&backup).is_err());
    let check = Connection::open(&backup).expect("backup open");
    assert_eq!(
        check
            .query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))
            .expect("integrity"),
        "ok"
    );
    assert_eq!(
        check
            .query_row("SELECT COUNT(*) FROM tasks", [], |r| r.get::<_, i64>(0))
            .expect("tasks"),
        1
    );
    assert_eq!(
        check
            .query_row("SELECT COUNT(*) FROM events", [], |r| r.get::<_, i64>(0))
            .expect("events"),
        1
    );
}

#[test]
fn newer_schema_fails_safely_and_killed_precommit_writer_rolls_back() {
    let (temp, id, _work) = setup();
    let mut store = Store::open_rw(temp.path(), &id.to_string()).expect("open");
    store
        .create_task("one", "body", TaskStatus::Backlog, Vec::new())
        .expect("task");
    let db = temp
        .path()
        .join("projects")
        .join(id.to_string())
        .join("TASKS.sqlite");
    let conn = Connection::open(&db).expect("raw db");
    conn.pragma_update(None, "user_version", 99i64)
        .expect("newer schema");
    assert!(Store::open_readonly(temp.path(), &id.to_string()).is_err());
    drop(conn);
    let conn = Connection::open(&db).expect("reset schema");
    conn.pragma_update(
        None,
        "user_version",
        tasks_cli::store::CURRENT_SCHEMA_VERSION,
    )
    .expect("restore schema");
    drop(conn);
    let marker = temp.path().join("precommit.ready");
    let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let mut child = std::process::Command::new("cargo")
        .args([
            "run",
            "--quiet",
            "--locked",
            "--features",
            "test-hooks",
            "--bin",
            "tasks-test-writer",
            "--",
            "--data-root",
            temp.path().to_str().unwrap(),
            "--project",
            &id.to_string(),
            "--id",
            "T-001",
            "--expect-version",
            "1",
            "--title",
            "killed",
        ])
        .current_dir(manifest)
        .env("TASKS_PRECOMMIT_READY_FILE", &marker)
        .env("TASKS_HOLD_PRECOMMIT_MS", "30000")
        .spawn()
        .expect("writer");
    let ready_deadline = Instant::now() + Duration::from_secs(300);
    loop {
        if marker.exists() {
            break;
        }
        if let Some(status) = child.try_wait().expect("writer status") {
            panic!("writer exited before creating the readiness marker: {status}");
        }
        if Instant::now() >= ready_deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("writer did not create the readiness marker within 300 seconds");
        }
        thread::sleep(Duration::from_millis(20));
    }
    child.kill().expect("kill writer");
    let _ = child.wait().expect("wait writer");
    let mut reopened = Store::open_rw(temp.path(), &id.to_string()).expect("reopen");
    assert_eq!(reopened.show_task("T-001").expect("show").title, "one");
    assert_eq!(
        reopened
            .conn
            .query_row("SELECT COUNT(*) FROM events", [], |r| r.get::<_, i64>(0))
            .expect("events"),
        1
    );
}

#[test]
fn backups_during_subprocess_writes_contain_committed_pairs() {
    let (temp, id, work) = setup();
    let body = temp.path().join("body.md");
    fs::write(&body, "body").expect("body");
    let mut writer = std::process::Command::new(env!("CARGO_BIN_EXE_tasks"))
        .args([
            "--data-root",
            temp.path().to_str().unwrap(),
            "--project",
            &id.to_string(),
            "create",
            "--title",
            "writer",
            "--body-file",
            body.to_str().unwrap(),
        ])
        .current_dir(&work)
        .spawn()
        .expect("writer");
    let mut observed = 0;
    for index in 0..5 {
        let mut store = Store::open_rw(temp.path(), &id.to_string()).expect("open");
        let backup = temp.path().join(format!("during-{index}.sqlite"));
        if store.backup(&backup).is_ok() {
            let check = Connection::open(backup).expect("backup open");
            let tasks: i64 = check
                .query_row("SELECT COUNT(*) FROM tasks", [], |r| r.get(0))
                .expect("tasks");
            let events: i64 = check
                .query_row("SELECT COUNT(*) FROM events", [], |r| r.get(0))
                .expect("events");
            assert!(events >= tasks);
            observed += 1;
        }
    }
    assert!(writer.wait().expect("writer result").success());
    assert!(observed > 0);
}

#[test]
fn explicit_migration_keeps_a_verified_pre_upgrade_backup() {
    let (temp, id, _work) = setup();
    let db = temp
        .path()
        .join("projects")
        .join(id.to_string())
        .join("TASKS.sqlite");
    let raw = Connection::open(&db).expect("raw db");
    raw.execute_batch("DROP TRIGGER tasks_fts_insert; DROP TRIGGER tasks_fts_update; DROP TRIGGER tasks_fts_delete; DROP TABLE tasks_fts; DROP TABLE task_labels;").unwrap();
    raw.pragma_update(None, "user_version", 0i64)
        .expect("old schema");
    drop(raw);
    let mut store = Store::open_for_migration(temp.path(), &id.to_string()).expect("old open");
    let (from, to, backup_path) = store.migrate().expect("migrate");
    assert_eq!((from, to), (0, 4));
    let backup_path = backup_path.expect("backup path");
    assert!(backup_path.is_file());
    assert!(backup_path
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.contains("v0-pre-migrate-")));
    assert_eq!(store.doctor().expect("doctor").2, 4);
}
