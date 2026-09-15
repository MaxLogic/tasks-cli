use std::fs;
use tasks_cli::markdown;
use tasks_cli::model::TaskStatus;
use tasks_cli::store::{create_project_db, Store};
use tempfile::TempDir;
use uuid::Uuid;

fn store() -> (TempDir, Store) {
    let temp = tempfile::tempdir().expect("temporary directory");
    let id = Uuid::new_v4();
    create_project_db(temp.path(), &id).expect("database");
    let path = temp.path().to_path_buf();
    (temp, Store::open_rw(&path, &id.to_string()).expect("open"))
}

#[test]
fn crlf_import_preserves_text_forward_dependencies_and_rules() {
    let (temp, mut store) = store();
    let source = b"# Backlog\r\n\r\n## Rules\r\nshared rule\r\n\r\n## backlog\r\n### T-001 Alpha\r\nStatus: backlog\r\nDepends on: T-002\r\nBody:\r\nfirst\r\nsecond \xCE\xA9\r\n\r\n## ready\r\n### T-002 Beta\r\nBody:\r\nsecond body\r\n".to_vec();
    let parsed = markdown::parse("fixture.md", source, None).expect("parse");
    assert_eq!(parsed.tasks.len(), 2);
    assert_eq!(parsed.tasks[0].body, "first\r\nsecond Ω");
    assert_eq!(parsed.tasks[0].deps, vec![2]);
    assert_eq!(parsed.rules, "shared rule");
    assert!(!parsed.has_unknown_content);
    let source_hash = parsed.source_hash.clone();
    let (report, already) = store
        .import_apply(parsed, Some(&source_hash))
        .expect("apply");
    assert!(!already);
    assert_eq!(report.task_count, 2);
    assert_eq!(store.show_task("T-001").expect("show").deps, vec![2]);
    assert_eq!(
        store.show_task("T-002").expect("show").status,
        TaskStatus::Ready
    );
    assert_eq!(store.project_rules().expect("rules").body, "shared rule");
    let source_again = b"# Backlog\n\n## backlog\n### T-001 Alpha\nBody:\nfirst\n## backlog\n### T-001 Duplicate\nBody:\nsecond\n".to_vec();
    let bad = markdown::parse("bad.md", source_again, None).expect("parse bad");
    let bad_hash = bad.source_hash.clone();
    assert!(store.import_apply(bad, Some(&bad_hash)).is_err());
    assert_eq!(
        store
            .conn
            .query_row("SELECT COUNT(*) FROM tasks", [], |r| r.get::<_, i64>(0))
            .expect("count"),
        2
    );
    let export = temp.path().join("export.md");
    store.export_markdown(&export).expect("export");
    let first = fs::read(&export).expect("first export");
    let export2 = temp.path().join("export2.md");
    store.export_markdown(&export2).expect("second export");
    assert_eq!(first, fs::read(export2).expect("second bytes"));
}

#[test]
fn mapped_sections_are_explicit_and_malformed_content_is_rejected_without_changes() {
    let (temp, mut store) = store();
    let map = temp.path().join("map.json");
    fs::write(&map, r#"{"sections":{"Doing":"in-progress"}}"#).expect("map");
    let source = b"## Doing\n### T-7 Mapped\nBody:\ntext\n".to_vec();
    let parsed = markdown::parse("mapped.md", source, Some(&map)).expect("mapped parse");
    assert_eq!(parsed.tasks[0].status, TaskStatus::InProgress);
    let source_hash = parsed.source_hash.clone();
    store
        .import_apply(parsed, Some(&source_hash))
        .expect("mapped apply");
    assert_eq!(
        store.show_task("T-7").expect("show").status,
        TaskStatus::InProgress
    );
}
