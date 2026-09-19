use rusqlite::Connection;
use std::{
    fs,
    path::PathBuf,
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

fn migration_backups(root: &TempDir, project_id: &Uuid) -> Vec<PathBuf> {
    let project_dir = root.path().join("projects").join(project_id.to_string());
    let mut backups = fs::read_dir(project_dir)
        .expect("project directory")
        .map(|entry| entry.expect("directory entry").path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| {
                    name.starts_with("TASKS.v0-pre-migrate-") && name.ends_with(".sqlite")
                })
        })
        .collect::<Vec<_>>();
    backups.sort();
    backups
}

#[test]
fn genuine_v0_schema_migrates_and_preserves_data() {
    let (root, project_id, _db_path) = legacy_fixture("ready");
    let mut store = Store::open_for_migration(root.path(), &project_id.to_string()).expect("open");
    let (from, to, backup_path) = store.migrate().expect("migrate");
    assert_eq!((from, to), (0, 4));
    let backup = backup_path.expect("backup path");
    assert!(backup.is_file());

    let reopened = Store::open_readonly(root.path(), &project_id.to_string()).expect("reopen");
    let mut reopened = reopened;
    let page = reopened.list_tasks(None, None, 20).expect("list");
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].id, 7);
    assert_eq!(page.items[0].title, "old title");
    let detail = reopened.show_task("T-7").expect("show");
    assert_eq!(detail.body, "old body Ω");
    assert_eq!(detail.version, 1);

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
fn every_migration_attempt_backups_the_current_live_database() {
    let (root, project_id, db_path) = legacy_fixture("ready");
    let mut first = Store::open_for_migration(root.path(), &project_id.to_string()).expect("open");
    let (_, _, first_backup) = first.migrate().expect("first migrate");
    let first_backup = first_backup.expect("first backup");
    drop(first);

    let conn = Connection::open(&db_path).expect("current database");
    conn.execute(
        "INSERT INTO tasks(id, title, body, status, version, created_ms, updated_ms) VALUES (8, 'new title', 'new body', 'draft', 1, 0, 0)",
        [],
    )
    .expect("new live task");
    conn.execute_batch("DROP TRIGGER tasks_fts_insert; DROP TRIGGER tasks_fts_update; DROP TRIGGER tasks_fts_delete; DROP TABLE tasks_fts; DROP TABLE task_labels;").unwrap();
    conn.pragma_update(None, "user_version", 0i64)
        .expect("reset version for reproduction");
    drop(conn);

    let mut second =
        Store::open_for_migration(root.path(), &project_id.to_string()).expect("reopen");
    let (_, _, second_backup) = second.migrate().expect("second migrate");
    let second_backup = second_backup.expect("second backup");
    assert_ne!(first_backup, second_backup);
    assert_eq!(migration_backups(&root, &project_id).len(), 2);
    let mut current = Store::open_rw(root.path(), &project_id.to_string()).expect("current");
    let published = root.path().join("published.sqlite");
    current.backup(&published).expect("published backup");
    for path in [&first_backup, &second_backup, &published] {
        assert!(
            !PathBuf::from(format!("{}-wal", path.display())).exists(),
            "unexpected WAL sidecar for {}",
            path.display()
        );
        assert!(
            !PathBuf::from(format!("{}-shm", path.display())).exists(),
            "unexpected SHM sidecar for {}",
            path.display()
        );
    }
    let second_conn =
        Connection::open_with_flags(&second_backup, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .expect("second backup");
    assert_eq!(
        second_conn
            .query_row("SELECT COUNT(*) FROM tasks", [], |row| row.get::<_, i64>(0))
            .expect("second backup count"),
        2
    );
    drop(second_conn);
}

#[test]
fn migrate_output_reports_backup_path_in_text_and_json() {
    for format in ["text", "json"] {
        let (root, project_id, _) = legacy_fixture("ready");
        let project_text = project_id.to_string();
        let output = Command::new(env!("CARGO_BIN_EXE_tasks"))
            .args([
                "--data-root",
                root.path().to_str().expect("UTF-8 root"),
                "--project",
                project_text.as_str(),
                "--format",
                format,
                "migrate",
            ])
            .output()
            .expect("migrate command");
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let stdout = String::from_utf8(output.stdout).expect("UTF-8 output");
        if format == "text" {
            assert!(stdout.contains("backup_path: "));
            assert!(stdout.contains("pre-migrate-"));
        } else {
            let value: serde_json::Value = serde_json::from_str(&stdout).expect("JSON output");
            assert!(value["data"]["backup_path"].as_str().is_some());
        }
    }
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
    assert_eq!(migration_backups(&root, &project_id).len(), 1);

    assert_eq!(migration_backups(&root, &project_id).len(), 1);
    let mut retry = Store::open_for_migration(root.path(), &project_id.to_string()).expect("retry");
    let retry_error = retry
        .migrate()
        .expect_err("invalid legacy data remains invalid");
    assert!(!retry_error.to_string().contains("destination exists"));
    assert_eq!(migration_backups(&root, &project_id).len(), 2);
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
fn valid_unconstrained_legacy_dependencies_are_rebuilt_with_constraints() {
    let (root, project_id, db_path) = legacy_fixture("backlog");
    let conn = Connection::open(&db_path).expect("legacy database");
    conn.execute_batch(
        "CREATE TABLE dependencies(task_id INTEGER NOT NULL, depends_on_id INTEGER NOT NULL);
         INSERT INTO tasks(id, title, body, status) VALUES (8, 'second', 'body', 'backlog');
         INSERT INTO dependencies(task_id, depends_on_id) VALUES (8, 7);
         PRAGMA user_version = 0;",
    )
    .expect("legacy dependencies");
    drop(conn);

    let mut store = Store::open_for_migration(root.path(), &project_id.to_string()).expect("open");
    store.migrate().expect("migrate");
    drop(store);
    let conn = Connection::open(&db_path).expect("migrated database");
    assert_eq!(
        conn.query_row(
            "SELECT COUNT(*) FROM pragma_foreign_key_list('dependencies')",
            [],
            |row| row.get::<_, i64>(0)
        )
        .expect("foreign keys"),
        2
    );
    assert!(conn
        .execute(
            "INSERT INTO dependencies(task_id, depends_on_id) VALUES (8, 7)",
            [],
        )
        .is_err());
    assert!(conn
        .execute(
            "INSERT INTO dependencies(task_id, depends_on_id) VALUES (8, 99)",
            [],
        )
        .is_err());
}

#[test]
fn invalid_legacy_dependency_endpoints_and_duplicates_roll_back_the_original_table() {
    for (label, rows, expected, expected_rows) in [
        (
            "duplicate",
            "INSERT INTO dependencies(task_id, depends_on_id) VALUES (8, 7), (8, 7);",
            "duplicate edge",
            2,
        ),
        (
            "source",
            "INSERT INTO dependencies(task_id, depends_on_id) VALUES (99, 7);",
            "source T-099",
            1,
        ),
        (
            "destination",
            "INSERT INTO dependencies(task_id, depends_on_id) VALUES (7, 99);",
            "references T-099",
            1,
        ),
    ] {
        let (root, project_id, db_path) = legacy_fixture("backlog");
        let conn = Connection::open(&db_path).expect("legacy database");
        conn.execute_batch(&format!(
            "CREATE TABLE dependencies(task_id INTEGER NOT NULL, depends_on_id INTEGER NOT NULL);
             INSERT INTO tasks(id, title, body, status) VALUES (8, 'second', 'body', 'backlog');
             {rows}
             PRAGMA user_version = 0;"
        ))
        .expect("invalid legacy dependencies");
        drop(conn);

        let mut store =
            Store::open_for_migration(root.path(), &project_id.to_string()).expect("open");
        let error = store.migrate().expect_err(label);
        assert!(error.to_string().contains(expected), "{label}: {error}");
        drop(store);
        let conn = Connection::open(&db_path).expect("reopen legacy database");
        assert_eq!(
            conn.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
                .expect("version"),
            0,
            "{label} migration changed schema version"
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM dependencies", [], |row| {
                row.get::<_, i64>(0)
            })
            .expect("dependency rows"),
            expected_rows,
            "{label} migration changed original dependency rows"
        );
    }
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
