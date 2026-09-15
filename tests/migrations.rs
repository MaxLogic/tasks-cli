use rusqlite::Connection;
use std::{
    fs,
    process::{Command, Stdio},
};
use tasks_cli::store::{data_root_project_path, Store};
use tempfile::TempDir;
use uuid::Uuid;

fn legacy_fixture(status: &str) -> (TempDir, Uuid, std::path::PathBuf) {
    let root = tempfile::tempdir().expect("temporary directory");
    let project_id = Uuid::new_v4();
    let db_path = data_root_project_path(root.path(), &project_id.to_string());
    fs::create_dir_all(db_path.parent().expect("project directory")).expect("project directory");
    let conn = Connection::open(&db_path).expect("legacy database");
    conn.execute_batch(
        "
        CREATE TABLE project(project_id TEXT PRIMARY KEY);
        CREATE TABLE tasks(
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            status TEXT NOT NULL
        );
        ",
    )
    .expect("legacy schema");
    conn.execute(
        "INSERT INTO project(project_id) VALUES (?1)",
        [project_id.to_string()],
    )
    .expect("legacy project");
    conn.execute(
        "INSERT INTO tasks(id, title, body, status) VALUES (7, 'old title', 'old body Ω', ?1)",
        [status],
    )
    .expect("legacy task");
    conn.pragma_update(None, "user_version", 0i64)
        .expect("legacy version");
    drop(conn);
    (root, project_id, db_path)
}

#[test]
fn genuine_v0_schema_migrates_and_preserves_data() {
    let (root, project_id, db_path) = legacy_fixture("ready");
    let mut store = Store::open_for_migration(root.path(), &project_id.to_string()).expect("open");
    assert_eq!(store.migrate().expect("migrate"), (0, 1));

    let reopened = Store::open_readonly(root.path(), &project_id.to_string()).expect("reopen");
    let mut reopened = reopened;
    let page = reopened.list_tasks(None, None, 20).expect("list");
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].id, 7);
    assert_eq!(page.items[0].title, "old title");
    let detail = reopened.show_task("T-7").expect("show");
    assert_eq!(detail.body, "old body Ω");
    assert_eq!(detail.version, 1);

    let backup = db_path.with_extension("v0-pre-migrate.sqlite");
    assert!(backup.is_file());
    let backup_conn =
        Connection::open_with_flags(backup, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .expect("pre-upgrade backup");
    assert_eq!(
        backup_conn
            .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .expect("backup version"),
        0
    );
    assert_eq!(
        backup_conn
            .query_row("SELECT body FROM tasks WHERE id=7", [], |row| row
                .get::<_, String>(0))
            .expect("backup data"),
        "old body Ω"
    );
}

#[test]
fn failed_v0_migration_rolls_back_schema_and_data() {
    let (root, project_id, db_path) = legacy_fixture("not-a-status");
    let mut store = Store::open_for_migration(root.path(), &project_id.to_string()).expect("open");
    assert!(store.migrate().is_err());
    drop(store);

    let conn = Connection::open_with_flags(db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .expect("reopen legacy database");
    assert_eq!(
        conn.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .expect("version"),
        0
    );
    assert_eq!(
        conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('tasks')",
            [],
            |row| { row.get::<_, i64>(0) }
        )
        .expect("task columns"),
        4
    );
    assert_eq!(
        conn.query_row("SELECT body FROM tasks WHERE id=7", [], |row| row
            .get::<_, String>(0))
            .expect("data"),
        "old body Ω"
    );
    assert!(root
        .path()
        .join("projects")
        .join(project_id.to_string())
        .join("TASKS.v0-pre-migrate.sqlite")
        .is_file());

    let mut retry = Store::open_for_migration(root.path(), &project_id.to_string()).expect("retry");
    let retry_error = retry
        .migrate()
        .expect_err("invalid legacy data remains invalid");
    assert!(!retry_error.to_string().contains("destination exists"));
}

#[test]
fn cyclic_legacy_dependencies_fail_without_partial_migration() {
    let (root, project_id, db_path) = legacy_fixture("backlog");
    let conn = Connection::open(&db_path).expect("legacy database");
    conn.execute_batch(
        "CREATE TABLE dependencies(task_id INTEGER NOT NULL, depends_on_id INTEGER NOT NULL);
         INSERT INTO dependencies(task_id, depends_on_id) VALUES (7, 8), (8, 7);
         INSERT INTO tasks(id, title, body, status) VALUES (8, 'second', 'body', 'backlog');
         PRAGMA user_version = 0;",
    )
    .expect("cyclic legacy graph");
    drop(conn);

    let mut store = Store::open_for_migration(root.path(), &project_id.to_string()).expect("open");
    let error = store.migrate().expect_err("cycle");
    assert!(error.to_string().contains("cycle"));
    drop(store);
    let conn = Connection::open_with_flags(db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .expect("reopen");
    assert_eq!(
        conn.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .expect("version"),
        0
    );
}

#[test]
fn doctor_reports_old_schema_without_migrating_it() {
    let (root, project_id, _db_path) = legacy_fixture("ready");
    let mut store =
        Store::open_for_diagnostics(root.path(), &project_id.to_string()).expect("diagnostics");
    let (_, reported_project, schema, _) = store.doctor().expect("doctor");
    assert_eq!(reported_project, project_id.to_string());
    assert_eq!(schema, 0);
}

#[test]
fn concurrent_migrations_serialize_and_both_exit_successfully() {
    let (root, project_id, _db_path) = legacy_fixture("backlog");
    let binary = env!("CARGO_BIN_EXE_tasks");
    let project_text = project_id.to_string();
    let args = [
        "--data-root",
        root.path().to_str().expect("UTF-8 root"),
        "--project",
        project_text.as_str(),
        "migrate",
    ];
    let first = Command::new(binary)
        .args(args)
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("first migration");
    let second = Command::new(binary)
        .args(args)
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("second migration");
    let first = first.wait_with_output().expect("first status");
    let second = second.wait_with_output().expect("second status");
    assert_eq!(
        first.status.code(),
        Some(0),
        "first stderr: {}",
        String::from_utf8_lossy(&first.stderr)
    );
    assert_eq!(
        second.status.code(),
        Some(0),
        "second stderr: {}",
        String::from_utf8_lossy(&second.stderr)
    );

    let store = Store::open_readonly(root.path(), &project_id.to_string()).expect("current db");
    assert_eq!(store.project_id, project_id);
}
