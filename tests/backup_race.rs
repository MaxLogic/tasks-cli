use rusqlite::Connection;
use std::process::Command;
use tasks_cli::model::TaskStatus;
use tasks_cli::store::{create_project_db, Store};
use uuid::Uuid;

#[test]
fn concurrent_backups_publish_at_most_one_destination() {
    let root = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).expect("database");
    let mut store = Store::open_rw(root.path(), &project.to_string()).expect("open");
    store
        .create_task("backup task", "body", TaskStatus::Ready, Vec::new())
        .expect("task");
    drop(store);

    let binary = env!("CARGO_BIN_EXE_tasks");
    let project_text = project.to_string();
    let root_text = root.path().to_str().expect("UTF-8 root");
    let out = root.path().join("same.sqlite");
    let out_text = out.to_str().expect("UTF-8 backup");
    let args = [
        "--data-root",
        root_text,
        "--project",
        project_text.as_str(),
        "backup",
        "--out",
        out_text,
    ];
    let first = Command::new(binary)
        .args(args)
        .spawn()
        .expect("first backup");
    let second = Command::new(binary)
        .args(args)
        .spawn()
        .expect("second backup");
    let first = first.wait_with_output().expect("first status");
    let second = second.wait_with_output().expect("second status");
    let mut statuses = [
        first.status.code().expect("first code"),
        second.status.code().expect("second code"),
    ];
    statuses.sort_unstable();
    assert_eq!(statuses, [0, 2]);

    let conn = Connection::open_with_flags(out, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .expect("published backup");
    assert_eq!(
        conn.query_row("PRAGMA quick_check", [], |row| row.get::<_, String>(0))
            .expect("quick check"),
        "ok"
    );
    assert_eq!(
        conn.query_row("SELECT COUNT(*) FROM tasks", [], |row| row.get::<_, i64>(0))
            .expect("task count"),
        1
    );
}
