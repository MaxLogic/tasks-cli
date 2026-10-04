mod support;
use rusqlite::Connection;
use std::fs;
use tasks_cli::{
    markdown,
    model::TaskStatus,
    store::{create_project_db, data_root_project_path, Store},
};
use tempfile::TempDir;
use uuid::Uuid;

fn v1_fixture() -> (TempDir, Uuid) {
    let root = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    let path = data_root_project_path(root.path(), &id.to_string());
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(include_str!("fixtures/schema-v1.sql"))
        .unwrap();
    conn.execute(
        "INSERT INTO project VALUES (?1, 'rules Ω', 8, 42)",
        [id.to_string()],
    )
    .unwrap();
    conn.execute_batch(r#"INSERT INTO tasks VALUES (7, 'old', 'body Ω', 'backlog', 3, 11, 12), (9, 'next', 'other', 'ready', 5, 13, 14);
        INSERT INTO dependencies VALUES (9, 7);
        INSERT INTO events VALUES (17,7,'task','updated',3,12,' { "status" : "backlog", "version" : 3 } ');
        INSERT INTO imports VALUES ('hash','ledger.md',X'000A0DFF',' { "status" : "ready" } ',15);"#).unwrap();
    (root, id)
}

#[test]
fn genuine_v1_migration_preserves_records_and_legacy_history_bytes() {
    let (root, id) = v1_fixture();
    let path = data_root_project_path(root.path(), &id.to_string());
    let prior_backup = path.with_file_name("TASKS.v1-pre-migrate-old.sqlite");
    fs::write(&prior_backup, b"previous backup must survive").unwrap();
    assert!(Store::open_readonly(root.path(), &id.to_string()).is_err());
    let mut store = Store::open_for_migration(root.path(), &id.to_string()).unwrap();
    let (from, to, backup) = store.migrate().unwrap();
    assert_eq!((from, to), (1, 8));
    let backup = backup.unwrap();
    assert_ne!(backup, prior_backup);
    assert_eq!(
        fs::read(prior_backup).unwrap(),
        b"previous backup must survive"
    );
    let old =
        Connection::open_with_flags(backup, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(
        old.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        old.query_row("PRAGMA quick_check", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    for (table, columns, order) in [
        (
            "project",
            "project_id,rules_markdown,rules_version,next_task_number",
            "project_id",
        ),
        ("tasks", "id,title,body,version,created_ms,updated_ms", "id"),
        ("dependencies", "*", "task_id"),
        (
            "events",
            "event_id,task_id,entity_type,operation,resulting_version,created_ms,snapshot_json",
            "event_id",
        ),
        ("imports", "*", "input_sha256"),
    ] {
        let query = format!("SELECT {columns} FROM {table} ORDER BY {order}");
        let read = |conn: &Connection| {
            let mut stmt = conn.prepare(&query).unwrap();
            let width = stmt.column_count();
            stmt.query_map([], |r| {
                (0..width)
                    .map(|i| r.get::<_, rusqlite::types::Value>(i))
                    .collect::<Result<Vec<_>, _>>()
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
        };
        assert_eq!(read(&store.conn), read(&old), "{table} preserved");
    }
    assert_eq!(store.show_task("T-7").unwrap().status.to_string(), "draft");
    assert_eq!(store.show_task("T-9").unwrap().status.to_string(), "todo");
    assert_eq!(store.doctor().unwrap().2, 8);
    assert!(store
        .conn
        .execute("UPDATE tasks SET status='backlog' WHERE id=7", [])
        .is_err());
    let created = store
        .create_task("new", "body", TaskStatus::Backlog, vec![])
        .unwrap();
    assert_eq!(created.0, 42);
    let event: i64 = store
        .conn
        .query_row("SELECT MAX(event_id) FROM events", [], |r| r.get(0))
        .unwrap();
    assert_eq!(event, 18);
    assert_eq!(store.migrate().unwrap(), (8, 8, None));
}

#[test]
fn failed_v1_rebuild_rolls_back_and_restores_foreign_keys() {
    let (root, id) = v1_fixture();
    let path = data_root_project_path(root.path(), &id.to_string());
    let raw = Connection::open(path).unwrap();
    // This valid SQLite file passes the backup checks, then fails schema
    // validation after rebuilding tasks. The transaction must restore tasks.
    raw.execute_batch("ALTER TABLE events RENAME COLUMN operation TO unsupported_operation;")
        .unwrap();
    drop(raw);
    let mut store = Store::open_for_migration(root.path(), &id.to_string()).unwrap();
    assert!(store.migrate().is_err());
    assert_eq!(
        store
            .conn
            .pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        store
            .conn
            .pragma_query_value(None, "foreign_keys", |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        store
            .conn
            .query_row("SELECT status FROM tasks WHERE id=7", [], |r| r
                .get::<_, String>(0))
            .unwrap(),
        "backlog"
    );
    assert_eq!(
        store
            .conn
            .query_row("SELECT COUNT(*) FROM dependencies", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        store
            .conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name='tasks_v2'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
        0
    );
}

#[test]
fn future_schema_refusal_preserves_database() {
    let (root, id) = v1_fixture();
    let path = data_root_project_path(root.path(), &id.to_string());
    let conn = Connection::open(&path).unwrap();
    conn.pragma_update(None, "user_version", 99).unwrap();
    drop(conn);
    let before = fs::read(&path).unwrap();
    assert!(Store::open_for_migration(root.path(), &id.to_string()).is_err());
    assert_eq!(fs::read(path).unwrap(), before);
}

#[test]
fn canonical_states_work_in_cli_output_filters_and_exports() {
    let root = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    create_project_db(root.path(), &id).unwrap();
    let body = root.path().join("body.md");
    fs::write(&body, "body").unwrap();
    for (index, state) in [
        "draft",
        "todo",
        "in-progress",
        "blocked",
        "done",
        "cancelled",
    ]
    .iter()
    .enumerate()
    {
        let mut command = support::process::command(env!("CARGO_BIN_EXE_tasks"));
        command.args([
            "--data-root",
            root.path().to_str().unwrap(),
            "--project",
            &id.to_string(),
            "--format",
            "json",
            "create",
            "--title",
            state,
            "--body-file",
            body.to_str().unwrap(),
        ]);
        if index != 0 {
            command.args(["--status", state]);
        }
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let result: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(result["data"]["status"], *state);
    }
    let mut store = Store::open_rw(root.path(), &id.to_string()).unwrap();
    let export = root.path().join("export.md");
    assert_eq!(store.export_markdown(&export).unwrap(), 6);
    let text = fs::read_to_string(&export).unwrap();
    assert!(text.contains("## draft\n"));
    assert!(text.contains("## todo\n"));
    assert!(!text.contains("Status: backlog"));
    let parsed = markdown::parse("export.md", text.into_bytes(), None).unwrap();
    assert_eq!(parsed.tasks.len(), 6);
    let output = support::process::command(env!("CARGO_BIN_EXE_tasks"))
        .args([
            "--data-root",
            root.path().to_str().unwrap(),
            "--project",
            &id.to_string(),
            "--format",
            "json",
            "list",
            "--status",
            "todo",
        ])
        .output()
        .unwrap();
    assert!(output.status.success());
    let result: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(result["data"]["items"][0]["status"], "todo");
}

#[test]
fn legacy_ledger_and_map_aliases_import_as_canonical_states() {
    let parsed = markdown::parse(
        "old.md",
        b"## backlog\n### T-1 One\nBody:\nbody\n## ready\n### T-2 Two\nBody:\nbody\n".to_vec(),
        None,
    )
    .unwrap();
    assert_eq!(parsed.tasks[0].status.to_string(), "draft");
    assert_eq!(parsed.tasks[1].status.to_string(), "todo");
    let root = tempfile::tempdir().unwrap();
    let map = root.path().join("map.json");
    fs::write(
        &map,
        r#"{"sections":{"Old":"backlog","New":"todo"},"default_status":"ready"}"#,
    )
    .unwrap();
    let parsed = markdown::parse(
        "mapped.md",
        b"## Old\n### T-1 One\nbody\n## New\n### T-2 Two\nbody\n## Unknown\n### T-3 Three\nbody\n"
            .to_vec(),
        Some(&map),
    )
    .unwrap();
    assert_eq!(
        parsed
            .tasks
            .iter()
            .map(|t| t.status.to_string())
            .collect::<Vec<_>>(),
        ["draft", "todo", "todo"]
    );
}
