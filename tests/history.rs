use serde_json::Value;
use std::process::Command;
use tasks_cli::model::TaskStatus;
use tasks_cli::store::{create_project_db, Store};
use tempfile::TempDir;
use uuid::Uuid;

fn fixture() -> (TempDir, Uuid, Store) {
    let root = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).expect("database");
    let store = Store::open_rw(root.path(), &project.to_string()).expect("open");
    (root, project, store)
}

#[test]
fn selected_history_event_must_belong_to_requested_task() {
    let (_root, _project, mut store) = fixture();
    let (_, _, first_event) = store
        .create_task("first", "first body", TaskStatus::Ready, Vec::new())
        .expect("first");
    let (_, _, second_event) = store
        .create_task("second", "second body", TaskStatus::Ready, Vec::new())
        .expect("second");
    let first_event = first_event.expect("first event");
    let second_event = second_event.expect("second event");
    let selected = store
        .history(1, None, 20, Some(first_event))
        .expect("selected event")
        .1
        .expect("event");
    assert_eq!(selected.task_id, Some(1));
    assert!(store.history(1, None, 20, Some(second_event)).is_err());
    assert!(store.history(2, None, 20, Some(first_event)).is_err());
}

#[test]
fn selected_history_text_and_json_include_the_same_snapshot() {
    let (root, project, mut store) = fixture();
    let (_, _, event) = store
        .create_task(
            "complete title",
            "complete body Ω",
            TaskStatus::Ready,
            Vec::new(),
        )
        .expect("task");
    let event = event.expect("event").to_string();
    let project_text = project.to_string();
    let binary = env!("CARGO_BIN_EXE_tasks");
    let common = [
        "--data-root",
        root.path().to_str().expect("UTF-8 root"),
        "--project",
        project_text.as_str(),
        "history",
        "T-1",
        "--event",
        event.as_str(),
    ];
    let text = Command::new(binary)
        .args(["--format", "text"])
        .args(common)
        .output()
        .expect("text history");
    assert!(text.status.success());
    let text = String::from_utf8(text.stdout).expect("text UTF-8");
    assert!(text.contains("complete title"));
    assert!(text.contains("complete body Ω"));

    let json = Command::new(binary)
        .args(["--format", "json"])
        .args(common)
        .output()
        .expect("JSON history");
    assert!(json.status.success());
    let value: Value = serde_json::from_slice(&json.stdout).expect("JSON output");
    let snapshot = &value["data"]["items"][0]["snapshot"];
    assert_eq!(snapshot["title"], "complete title");
    assert_eq!(snapshot["body"], "complete body Ω");
}
