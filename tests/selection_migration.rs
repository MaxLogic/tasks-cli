use rusqlite::{types::Value, Connection};
use tasks_cli::store::{data_root_project_path, Store};
use uuid::Uuid;

fn fixture(root: &std::path::Path, id: &Uuid) {
    let path = data_root_project_path(root, &id.to_string());
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(include_str!("fixtures/schema-v2.sql"))
        .unwrap();
    conn.execute_batch(include_str!("fixtures/schema-v3-additions.sql"))
        .unwrap();
    conn.execute(
        "INSERT INTO project VALUES(?1,'rules Ω',7,12)",
        [id.to_string()],
    )
    .unwrap();
    conn.execute_batch("INSERT INTO tasks VALUES(7,'cache','body Ω','todo',3,1,2),(9,'dependent','other','todo',4,5,6);
        INSERT INTO dependencies VALUES(9,7);
        INSERT INTO task_labels VALUES(7,'needs-human');
        INSERT INTO events VALUES(17,7,'task','update',3,2,' untouched snapshot ');
        INSERT INTO imports VALUES('sha','old.md',X'000A0DFF','original report',9);").unwrap();
}
fn values(conn: &Connection, sql: &str) -> Vec<Vec<Value>> {
    let mut statement = conn.prepare(sql).unwrap();
    let width = statement.column_count();
    statement
        .query_map([], |r| (0..width).map(|i| r.get(i)).collect())
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

#[test]
fn schema_three_upgrade_preserves_all_records_and_verified_backup() {
    let root = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    fixture(root.path(), &id);
    let mut store = Store::open_for_migration(root.path(), &id.to_string()).unwrap();
    let (from, to, backup) = store.migrate().unwrap();
    assert_eq!((from, to), (3, 6));
    let old =
        Connection::open_with_flags(backup.unwrap(), rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    assert_eq!(
        values(&old, "PRAGMA user_version"),
        vec![vec![Value::Integer(3)]]
    );
    assert_eq!(
        values(&old, "PRAGMA quick_check"),
        vec![vec![Value::Text("ok".into())]]
    );
    for (table, columns, order) in [
        (
            "project",
            "project_id,rules_markdown,rules_version,next_task_number",
            "project_id",
        ),
        (
            "tasks",
            "id,title,body,status,version,created_ms,updated_ms",
            "id",
        ),
        ("dependencies", "*", "task_id"),
        ("task_labels", "*", "task_id"),
        ("events", "*", "event_id"),
        ("imports", "*", "input_sha256"),
    ] {
        let sql = format!("SELECT {columns} FROM {table} ORDER BY {order}");
        assert_eq!(values(&store.conn, &sql), values(&old, &sql), "{table}");
    }
    assert_eq!(store.show_task("T-7").unwrap().priority.to_string(), "P2");
    assert_eq!(
        store
            .search_ranked("cache", false, None, 0, 20)
            .unwrap()
            .items[0]
            .id,
        7
    );
    assert!(store
        .conn
        .execute("UPDATE tasks SET priority='P4' WHERE id=7", [])
        .is_err());
    assert_eq!(store.migrate().unwrap(), (6, 6, None));
}

#[test]
fn failed_schema_three_upgrade_rolls_back_column_and_keeps_backup() {
    let root = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    fixture(root.path(), &id);
    let mut store = Store::open_for_migration(root.path(), &id.to_string()).unwrap();
    // Fail validation after the ALTER and indexes, exercising transaction rollback.
    store
        .conn
        .execute_batch("ALTER TABLE events RENAME COLUMN operation TO invalid_operation")
        .unwrap();
    assert!(store.migrate().is_err());
    assert_eq!(
        values(&store.conn, "PRAGMA user_version"),
        vec![vec![Value::Integer(3)]]
    );
    assert!(store.conn.prepare("SELECT priority FROM tasks").is_err());
    assert_eq!(
        values(&store.conn, "SELECT snapshot_json FROM events"),
        vec![vec![Value::Text(" untouched snapshot ".into())]]
    );
    assert_eq!(
        values(&store.conn, "PRAGMA foreign_keys"),
        vec![vec![Value::Integer(1)]]
    );
    let backups = std::fs::read_dir(store.db_path.parent().unwrap())
        .unwrap()
        .filter_map(Result::ok)
        .filter(|f| {
            f.file_name()
                .to_string_lossy()
                .starts_with("TASKS.v3-pre-migrate-")
        })
        .count();
    assert_eq!(backups, 1);
}
