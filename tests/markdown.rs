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

#[test]
fn attachment_export_is_metadata_only_and_imports_tasks_with_one_warning() {
    use tasks_cli::attachment::{db::PreparedItem, envelope, Limits};
    let (_root, mut source) = store();
    source
        .create_task(
            "task",
            "body\n<!-- fake marker -->",
            TaskStatus::Ready,
            vec![],
        )
        .unwrap();
    let item = PreparedItem {
        name: "log (copy).txt".into(),
        envelope: envelope::encode(&b"hello"[..], "log (copy).txt", &Limits::PRODUCTION).unwrap(),
    };
    source
        .attach(1, 1, vec![item], &Limits::PRODUCTION)
        .unwrap();
    let (text, count) = source.markdown_snapshot().unwrap();
    assert_eq!(count, 1);
    assert!(text.contains("> Snapshot export omits attachment bytes; 1 attachment(s) on 1 task(s) are listed as metadata."));
    assert!(text.contains("<!-- tasks-cli:canonical-v1:attachments count=1 -->\n- A1 log (copy).txt (text/plain; charset=utf-8, 5 bytes, sha256 "));
    assert!(!text.contains("TASKATT1"));
    let parsed = markdown::parse("export.md", text.clone().into_bytes(), None).unwrap();
    assert!(
        parsed.parse_problems.is_empty(),
        "{:?}",
        parsed.parse_problems
    );
    assert!(!parsed.has_unknown_content);
    assert_eq!(parsed.warnings(),vec!["1 attachment reference(s) on 1 task(s) were not imported; Markdown exports omit attachment bytes"]);
    let (_root, mut target) = store();
    let hash = parsed.source_hash.clone();
    target.import_apply(parsed, Some(&hash)).unwrap();
    let old = source.show_task("1").unwrap();
    let new = target.show_task("1").unwrap();
    assert_eq!(
        (new.title, new.body, new.status, new.deps),
        (old.title, old.body, old.status, old.deps)
    );
    assert!(new.attachments.is_empty());
    for malformed in [
        text.replace("attachments count=1", "attachments count=2"),
        text.replace("end-attachments", "end-bogus"),
        text.replace("sha256 2cf24dba", "sha256 NOTHEX!!"),
        text.replace("- A1 log (copy).txt", "- A0 log (copy).txt"),
    ] {
        let parsed = markdown::parse("malformed.md", malformed.into_bytes(), None).unwrap();
        assert!(!parsed.parse_problems.is_empty());
        let (_root, mut target) = store();
        let hash = parsed.source_hash.clone();
        assert!(target.import_apply(parsed, Some(&hash)).is_err());
    }
    let without = text
        .lines()
        .filter(|line| !line.contains("Snapshot export omits attachment bytes"))
        .collect::<Vec<_>>()
        .join("\n");
    let begin = without
        .find("<!-- tasks-cli:canonical-v1:attachments")
        .unwrap();
    let end = without[begin..]
        .find("<!-- tasks-cli:canonical-v1:end-attachments -->")
        .unwrap()
        + begin
        + "<!-- tasks-cli:canonical-v1:end-attachments -->".len();
    let old = format!("{}{}", &without[..begin], &without[end..]);
    let parsed = markdown::parse("old.md", old.into_bytes(), None).unwrap();
    assert!(parsed.warnings().is_empty());
    assert!(parsed.parse_problems.is_empty());
}
