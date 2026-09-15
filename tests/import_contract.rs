use std::fs;
use tasks_cli::markdown;
use tasks_cli::model::TaskStatus;
use tasks_cli::store::{create_project_db, Store};
use tempfile::TempDir;
use uuid::Uuid;

fn store() -> (TempDir, Store) {
    let root = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).expect("database");
    let store = Store::open_rw(root.path(), &project.to_string()).expect("open");
    (root, store)
}

#[test]
fn rules_before_and_after_tasks_keep_source_order_and_crlf() {
    let source =
        b"## Rules\r\nbefore \xCE\xA9\r\n## ready\r\n### T-1 One\r\none\r\n## Rules\r\nafter\r\n"
            .to_vec();
    let parsed = markdown::parse("rules.md", source, None).expect("parse");
    assert_eq!(parsed.tasks.len(), 1);
    assert_eq!(parsed.tasks[0].status, TaskStatus::Ready);
    assert_eq!(parsed.rules, "before Ω\r\nafter");
    assert_eq!(parsed.task_previews[0].title, "One");
    assert_eq!(parsed.sections[1].status, Some(TaskStatus::Ready));
    assert_eq!(parsed.source_hash.len(), 64);
    assert!(parsed.unassigned_ranges.is_empty());
}

#[test]
fn unknown_section_content_after_last_task_is_reported_and_cannot_apply() {
    let source = b"## backlog\n### T-1 One\nbody\n# Notes\nunassigned shared text\n".to_vec();
    let parsed = markdown::parse("unknown.md", source, None).expect("parse");
    assert!(parsed.has_unknown_content);
    assert_eq!(parsed.unassigned_ranges.len(), 1);
    let (_root, mut store) = store();
    let hash = parsed.source_hash.clone();
    assert!(store.import_apply(parsed, Some(&hash)).is_err());
    assert_eq!(
        store.list_tasks(None, None, 20).expect("list").items.len(),
        0
    );
}

#[test]
fn fenced_fake_headings_and_unknown_content_between_tasks_are_not_lost() {
    let source = b"## backlog\n### T-1 One\n\x60\x60\x60\n### T-99 fake\n\x60\x60\x60\n~~~\n### T-98 fake\n~~~\n# Notes\nbetween tasks\n## ready\n### T-2 Two\nbody\n".to_vec();
    let parsed = markdown::parse("fences.md", source, None).expect("parse");
    assert_eq!(
        parsed.tasks.iter().map(|task| task.id).collect::<Vec<_>>(),
        vec![1, 2]
    );
    assert!(parsed
        .unassigned_ranges
        .iter()
        .any(|range| range.preview.contains("between tasks")));
}

#[test]
fn duplicate_ids_and_conflicting_or_invalid_mappings_fail_strictly() {
    let duplicate = b"## backlog\n### T-1 One\none\n### T-1 Again\ntwo\n".to_vec();
    let parsed = markdown::parse("duplicate.md", duplicate, None).expect("parse");
    assert_eq!(parsed.duplicate_ids, vec![1]);
    let (_root, mut store) = store();
    let hash = parsed.source_hash.clone();
    assert!(store.import_apply(parsed, Some(&hash)).is_err());
    assert_eq!(
        store.list_tasks(None, None, 20).expect("list").items.len(),
        0
    );

    let map_root = tempfile::tempdir().expect("mapping directory");
    let invalid = map_root.path().join("invalid.json");
    fs::write(&invalid, r#"{"sections":{"Custom":"not-a-status"}}"#).expect("invalid mapping");
    assert!(markdown::parse(
        "mapped.md",
        b"## Custom\n### T-1 One\nbody\n".to_vec(),
        Some(&invalid)
    )
    .is_err());
    let conflict = map_root.path().join("conflict.json");
    fs::write(&conflict, r#"{"sections":{"ready":"done"}}"#).expect("conflict mapping");
    assert!(markdown::parse(
        "mapped.md",
        b"## ready\n### T-1 One\nbody\n".to_vec(),
        Some(&conflict)
    )
    .is_err());
    let mixed = map_root.path().join("mixed.json");
    fs::write(
        &mixed,
        r#"{"sections":{"Custom":"ready"},"ignored":"backlog"}"#,
    )
    .expect("mixed mapping");
    assert!(markdown::parse(
        "mapped.md",
        b"## Custom\n### T-1 One\nbody\n".to_vec(),
        Some(&mixed)
    )
    .is_err());
}

#[test]
fn repeated_identical_import_is_a_noop() {
    let source = b"## ready\n### T-1 Unicode \xCE\xA9\nbody\r\nline\n".to_vec();
    let first = markdown::parse("same.md", source.clone(), None).expect("first parse");
    let hash = first.source_hash.clone();
    let (_root, mut store) = store();
    let (report, already) = store
        .import_apply(first, Some(&hash))
        .expect("first import");
    assert!(!already);
    assert_eq!(report.task_count, 1);
    let second = markdown::parse("same.md", source, None).expect("second parse");
    let (report, already) = store
        .import_apply(second, Some(&hash))
        .expect("second import");
    assert!(already);
    assert_eq!(report.task_count, 1);
    let detail = store.show_task("T-1").expect("show");
    assert_eq!(detail.title, "Unicode Ω");
    assert_eq!(detail.body, "body\r\nline");
    assert_eq!(
        store
            .history(1, None, 20, None)
            .expect("history")
            .0
            .items
            .len(),
        1
    );
}

#[test]
fn changed_source_hash_rejects_apply_before_any_mutation() {
    let original = markdown::parse(
        "changed.md",
        b"## ready\n### T-1 Original\nbody\n".to_vec(),
        None,
    )
    .expect("original parse");
    let changed = markdown::parse(
        "changed.md",
        b"## ready\n### T-1 Changed\nbody\n".to_vec(),
        None,
    )
    .expect("changed parse");
    let (_root, mut store) = store();
    let expected = changed.source_hash;
    let error = store
        .import_apply(original, Some(&expected))
        .expect_err("changed source must fail");
    assert_eq!(error.code(), "source_hash_mismatch");
    assert_eq!(
        store.list_tasks(None, None, 20).expect("list").items.len(),
        0
    );
}

#[test]
fn body_prefixes_are_preserved_and_only_complete_metadata_is_consumed() {
    let source = b"## ready\n### T-1 Title prefix\nTitle: body text\nrest\n### T-2 Status prefix\nStatus: blocked on vendor\nrest\n### T-3 Depends prefix\nDepends on: T-99 is prose\nrest\n### T-4 Version prefix\nVersion: 2.0 rollout\nrest\n### T-5 Body prefix\nBody: actual body line\nrest\n### T-6 Export metadata\nStatus: ready\nVersion: 3\nDepends on: -\nBody:\ncomplete body\n".to_vec();
    let parsed = markdown::parse("prefixes.md", source, None).expect("parse");
    assert_eq!(parsed.tasks.len(), 6);
    assert_eq!(parsed.tasks[0].body, "Title: body text\nrest");
    assert_eq!(parsed.tasks[1].body, "Status: blocked on vendor\nrest");
    assert_eq!(parsed.tasks[2].body, "Depends on: T-99 is prose\nrest");
    assert_eq!(parsed.tasks[3].body, "Version: 2.0 rollout\nrest");
    assert_eq!(parsed.tasks[4].body, "Body: actual body line\nrest");
    assert_eq!(parsed.tasks[5].body, "complete body");
    assert_eq!(
        parsed.task_previews[5].consumed_metadata,
        vec!["Status", "Version", "Depends on", "Body"]
    );
}

#[test]
fn exported_tasks_round_trip_metadata_like_body_prefixes() {
    let (root, mut store) = store();
    let bodies = [
        "Title: preserved",
        "Status: preserved",
        "Depends on: preserved",
        "Version: preserved",
        "Body: preserved",
    ];
    for (index, body) in bodies.iter().enumerate() {
        store
            .create_task(
                &format!("task {index}"),
                body,
                TaskStatus::Ready,
                Vec::new(),
            )
            .expect("create");
    }
    let output = root.path().join("round-trip.md");
    store.export_markdown(&output).expect("export");
    let parsed = markdown::parse(
        "round-trip.md",
        fs::read(output).expect("export bytes"),
        None,
    )
    .expect("reparse");
    for (task, expected) in parsed.tasks.iter().zip(bodies.iter()) {
        assert_eq!(&task.body, expected);
    }
}

#[test]
fn tasks_without_a_section_are_unmapped_and_cannot_apply() {
    let source = b"# Tasks\n### T-1 No section\nbody\n".to_vec();
    let parsed = markdown::parse("sectionless.md", source, None).expect("parse");
    assert_eq!(parsed.unmapped_sections, vec!["<no section>"]);
    assert_eq!(parsed.task_previews[0].section, "<no section>");
    let hash = parsed.source_hash.clone();
    let (_root, mut store) = store();
    assert!(store.import_apply(parsed, Some(&hash)).is_err());
    assert!(store
        .list_tasks(None, None, 20)
        .expect("list")
        .items
        .is_empty());
}
