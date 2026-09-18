use rusqlite::Connection;
use tasks_cli::store::{data_root_project_path, Store};
use uuid::Uuid;

#[test]
fn schema_two_migration_indexes_existing_content_and_preserves_history() {
    let root = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    let path = data_root_project_path(root.path(), &id.to_string());
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch(include_str!("fixtures/schema-v2.sql"))
        .unwrap();
    conn.execute(
        "INSERT INTO project VALUES(?1,'rules',1,8)",
        [id.to_string()],
    )
    .unwrap();
    conn.execute_batch("INSERT INTO tasks VALUES(7,'cache migration','existing body','todo',2,1,2); INSERT INTO events VALUES(1,7,'task','update',2,2,'original snapshot');").unwrap();
    drop(conn);
    let mut store = Store::open_for_migration(root.path(), &id.to_string()).unwrap();
    let (from, to, backup) = store.migrate().unwrap();
    assert_eq!((from, to), (2, 3));
    let old = Connection::open(backup.unwrap()).unwrap();
    assert_eq!(
        old.pragma_query_value(None, "user_version", |r| r.get::<_, i32>(0))
            .unwrap(),
        2
    );
    assert_eq!(
        old.query_row(
            "SELECT count(*) FROM sqlite_master WHERE name='task_labels'",
            [],
            |r| r.get::<_, i32>(0)
        )
        .unwrap(),
        0
    );
    assert_eq!(
        store
            .search_ranked("cache", false, None, 0, 20)
            .unwrap()
            .items[0]
            .id,
        7
    );
    assert!(store.show_task("T-7").unwrap().labels.is_empty());
    assert_eq!(
        store
            .history(7, None, 20, Some(1))
            .unwrap()
            .1
            .unwrap()
            .snapshot_json
            .as_deref(),
        Some("original snapshot")
    );
    let result = store
        .update_task(
            7,
            2,
            tasks_cli::model::TaskUpdate {
                labels: Some(vec!["performance".into()]),
                ..Default::default()
            },
        )
        .unwrap();
    assert_eq!(result.2, 3);
    assert_eq!(
        store
            .search_ranked("cache", false, Some("performance"), 0, 20)
            .unwrap()
            .items
            .len(),
        1
    );
    assert_eq!(store.migrate().unwrap(), (3, 3, None));
}
