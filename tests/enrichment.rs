use rusqlite::Connection;
use tasks_cli::enrich;
use tasks_cli::store::{create_project_db, Store};
use uuid::Uuid;
fn fixture() -> (tempfile::TempDir, Store) {
    let root = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    create_project_db(root.path(), &id).unwrap();
    let mut store = Store::open_rw(root.path(), &id.to_string()).unwrap();
    store
        .create_task(
            "Repair cache Ω",
            "body must not be loaded into the output",
            tasks_cli::model::TaskStatus::Ready,
            vec![],
        )
        .unwrap();
    store
        .create_task(
            "Review security",
            "private body",
            tasks_cli::model::TaskStatus::Done,
            vec![],
        )
        .unwrap();
    (root, store)
}
#[test]
fn enriches_references_preserving_text_and_unknown_ids() {
    let (_root, store) = fixture();
    let input="Ω T001, T-1 and T0002.\r\nAgain T001; unknown T999. AT001 T001suffix T0 T99999999999999999999999999";
    let result = enrich::enrich(&store.conn, input).unwrap();
    assert_eq!(result.text,"Ω T001 (Repair cache Ω), T-1 (Repair cache Ω) and T0002 (Review security).\r\nAgain T001 (Repair cache Ω); unknown T999. AT001 T001suffix T0 T99999999999999999999999999");
    assert_eq!(result.replacements, 4);
    assert_eq!(result.unknown_ids, vec![999]);
    assert!(!result.text.contains("private body"));
    assert_eq!(
        enrich::enrich(&store.conn, &result.text).unwrap().text,
        result.text
    );
    let version: i64 = store
        .conn
        .query_row("SELECT sum(version) FROM tasks", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 2);
}
#[test]
fn handles_large_documents_with_bounded_batches_and_no_database_scan_for_plain_text() {
    let (_root, store) = fixture();
    let input = "ordinary paragraph Ω\r\n".repeat(20000) + "T001";
    let result = enrich::enrich(&store.conn, &input).unwrap();
    assert!(result.text.ends_with("T001 (Repair cache Ω)"));
    assert_eq!(result.replacements, 1);
    let conn = Connection::open_in_memory().unwrap();
    assert_eq!(
        enrich::enrich(&conn, "No task references.").unwrap().text,
        "No task references."
    );
    assert!(enrich::enrich(&conn, &"x".repeat(enrich::MAX_INPUT_BYTES + 1)).is_err());
}
#[test]
fn does_not_rewrite_obvious_urls_or_read_titles_from_inserted_text() {
    let (_root, store) = fixture();
    store
        .conn
        .execute("UPDATE tasks SET title='See T002' WHERE id=1", [])
        .unwrap();
    let result = enrich::enrich(
        &store.conn,
        "https://example.test/T001 [T001](https://example.test/T001) T001",
    )
    .unwrap();
    assert_eq!(
        result.text,
        "https://example.test/T001 [T001 (See T002)](https://example.test/T001) T001 (See T002)"
    );
}

#[test]
fn refuses_excessive_title_expansion_without_partial_output() {
    let (_root, store) = fixture();
    store
        .conn
        .execute("UPDATE tasks SET title=?1 WHERE id=1", ["x".repeat(1024)])
        .unwrap();
    assert!(enrich::enrich(&store.conn, &"T001 ".repeat(70000)).is_err());
}
