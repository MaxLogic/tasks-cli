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
fn unknown_ids_inside_existing_annotations_do_not_hide_outside_unknowns() {
    let (_root, store) = fixture();
    store
        .conn
        .execute("UPDATE tasks SET title='See T999' WHERE id=1", [])
        .unwrap();
    let protected = enrich::enrich(&store.conn, "T1 (See T999)").unwrap();
    assert_eq!(protected.text, "T1 (See T999)");
    assert_eq!(protected.replacements, 0);
    assert!(protected.unknown_ids.is_empty(), "{protected:?}");
    let input = "T1 (See T999) and T999";
    let result = enrich::enrich(&store.conn, input).unwrap();
    assert_eq!(result.text, input);
    assert_eq!(result.replacements, 0);
    assert_eq!(result.unknown_ids, vec![999]);
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

#[test]
fn reserved_prefixes_are_never_task_references() {
    let (_root, store) = fixture();
    let context = enrich::EnrichContext {
        own_key: store.project_key.as_deref(),
        own_project: Some(&store.project_id),
        data_root: Some(&store.data_root),
    };
    let input = "See UTF-8, SHA-256 and ISO-8601 plus T1.";
    let result = enrich::enrich_with(&store.conn, input, context).unwrap();
    assert_eq!(
        result.text,
        "See UTF-8, SHA-256 and ISO-8601 plus T1 (Repair cache Ω)."
    );
    assert_eq!(result.replacements, 1);
    assert!(result.unknown_refs.is_empty(), "{:?}", result.unknown_refs);
    assert!(result.unknown_ids.is_empty(), "{:?}", result.unknown_ids);

    // Reserved-only text must not touch the data-root key scan/cache.
    let cache = store.data_root.join("project-keys.json");
    assert!(!cache.exists(), "no scan should have happened yet");
    let reserved_only = "UTF-8, SHA-256, ISO-8601, IEEE-754, CVE-2024, RFC-822, AES-256, RSA-2048, CRC-32, CWE-79, ECMA-262, CP-1252, X86-64.";
    let result2 = enrich::enrich_with(&store.conn, reserved_only, context).unwrap();
    assert_eq!(result2.text, reserved_only);
    assert_eq!(result2.replacements, 0);
    assert!(
        result2.unknown_refs.is_empty(),
        "{:?}",
        result2.unknown_refs
    );
    assert!(
        !cache.exists(),
        "reserved-only text must not trigger a data-root scan"
    );
}

#[test]
fn enriches_slash_separated_task_references_without_rewriting_paths() {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch("CREATE TABLE tasks(id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
        .unwrap();
    for (id, title) in [(226, "NativeWind"), (227, "Zustand"), (228, "Mobile API")] {
        conn.execute("INSERT INTO tasks(id, title) VALUES (?1, ?2)", (id, title))
            .unwrap();
    }
    let input = "3. **Architecture drift (T-226/T-227/T-228):** spec.md and AGENTS.md say NativeWind, Zustand, and mobile plus API only. The code uses StyleSheet with brand tokens, module-level stores, and also ships a Tauri desktop app. Should the docs change to match the code, or the code to match the docs?";
    let result = enrich::enrich(&conn, input).unwrap();
    assert_eq!(result.replacements, 3);
    assert_eq!(result.unknown_ids, Vec::<u64>::new());
    assert_eq!(
        result.text,
        input.replace(
            "T-226/T-227/T-228",
            "T-226 (NativeWind)/T-227 (Zustand)/T-228 (Mobile API)"
        )
    );

    let paths = "https://example.test/T-226/T-227 C:\\work\\T-228 /T-226/T-227 T-226/file";
    let unchanged = enrich::enrich(&conn, paths).unwrap();
    assert_eq!(unchanged.text, paths);
    assert_eq!(unchanged.replacements, 0);
}
