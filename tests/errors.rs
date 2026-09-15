use serde_json::Value;
use std::process::Command;
use tasks_cli::model::{TaskStatus, TaskUpdate};
use tasks_cli::store::{create_project_db, data_root_project_path, Store};
use uuid::Uuid;

fn parse_error(output: std::process::Output) -> Value {
    assert!(!output.status.success());
    serde_json::from_slice(&output.stderr).expect("structured JSON error")
}

#[test]
fn clap_usage_errors_use_the_json_error_envelope() {
    let output = Command::new(env!("CARGO_BIN_EXE_tasks"))
        .args(["--format=json", "not-a-command"])
        .output()
        .expect("CLI");
    assert_eq!(output.status.code(), Some(2));
    let value = parse_error(output);
    assert_eq!(value["schema_version"], 1);
    assert_eq!(value["error"]["code"], "usage");
    assert!(value["error"]["message"].as_str().is_some());
}

#[test]
fn conflicts_have_stable_json_fields_and_exit_code() {
    let root = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).expect("database");
    let mut store = Store::open_rw(root.path(), &project.to_string()).expect("open");
    store
        .create_task("title", "body", TaskStatus::Ready, Vec::new())
        .expect("task");
    store
        .update_task(
            1,
            1,
            TaskUpdate {
                title: Some("changed".to_string()),
                ..TaskUpdate::default()
            },
        )
        .expect("first update");
    drop(store);

    let project_text = project.to_string();
    let root_text = root.path().to_str().expect("UTF-8 root");
    let output = Command::new(env!("CARGO_BIN_EXE_tasks"))
        .args([
            "--format",
            "json",
            "--data-root",
            root_text,
            "--project",
            project_text.as_str(),
            "update",
            "T-1",
            "--expect-version",
            "1",
            "--title",
            "second",
        ])
        .output()
        .expect("CLI");
    assert_eq!(output.status.code(), Some(4));
    let value = parse_error(output);
    assert_eq!(value["error"]["code"], "version_conflict");
    assert_eq!(value["error"]["conflict"]["expected"], 1);
    assert_eq!(value["error"]["conflict"]["current"], 2);
}

#[test]
fn missing_project_is_not_found_and_corrupt_database_is_database_error() {
    let root = tempfile::tempdir().expect("temporary directory");
    let missing = Uuid::new_v4().to_string();
    let root_text = root.path().to_str().expect("UTF-8 root");
    let missing_output = Command::new(env!("CARGO_BIN_EXE_tasks"))
        .args([
            "--format=json",
            "--data-root",
            root_text,
            "--project",
            &missing,
            "show",
            "T-1",
        ])
        .output()
        .expect("missing project CLI");
    assert_eq!(missing_output.status.code(), Some(3));
    assert_eq!(parse_error(missing_output)["error"]["code"], "not_found");

    let corrupt_project = Uuid::new_v4();
    let corrupt_path = data_root_project_path(root.path(), &corrupt_project.to_string());
    std::fs::create_dir_all(corrupt_path.parent().expect("project directory"))
        .expect("project directory");
    std::fs::write(&corrupt_path, b"not sqlite").expect("corrupt database");
    let corrupt_text = corrupt_project.to_string();
    let corrupt_output = Command::new(env!("CARGO_BIN_EXE_tasks"))
        .args([
            "--format=json",
            "--data-root",
            root_text,
            "--project",
            corrupt_text.as_str(),
            "show",
            "T-1",
        ])
        .output()
        .expect("corrupt database CLI");
    assert_eq!(corrupt_output.status.code(), Some(6));
    assert_eq!(parse_error(corrupt_output)["error"]["code"], "database");
}
