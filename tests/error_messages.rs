//! One test per error class: every message must name what failed, what was
//! found, and what to do next.

use serde_json::Value;
use std::fs;
use std::path::Path;
use std::process::{Command, Output};
use tasks_cli::store::{create_project_db, data_root_project_path};
use uuid::Uuid;

fn run(args: &[&str], cwd: Option<&Path>) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_tasks"));
    command.args(args);
    if let Some(dir) = cwd {
        command.current_dir(dir);
    }
    command.output().expect("CLI")
}

fn error_message(output: &Output) -> String {
    let value: serde_json::Value =
        serde_json::from_slice(&output.stderr).expect("structured JSON error");
    value["error"]["message"]
        .as_str()
        .expect("error message")
        .to_string()
}

fn error_code(output: &Output) -> String {
    let value: serde_json::Value =
        serde_json::from_slice(&output.stderr).expect("structured JSON error");
    value["error"]["code"]
        .as_str()
        .expect("error code")
        .to_string()
}

#[test]
fn io_errors_name_the_operation_and_the_path() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(temp.path(), &project).expect("database");
    let missing = temp.path().join("missing-body.md");
    let project_text = project.to_string();
    let output = run(
        &[
            "--format=json",
            "--data-root",
            temp.path().to_str().expect("UTF-8 root"),
            "--project",
            &project_text,
            "create",
            "--title",
            "A task",
            "--body-file",
            missing.to_str().expect("UTF-8 path"),
        ],
        None,
    );
    assert_eq!(output.status.code(), Some(6));
    assert_eq!(error_code(&output), "io");
    let message = error_message(&output);
    assert!(message.contains("cannot read"), "{message}");
    assert!(
        message.contains(missing.to_str().expect("UTF-8 path")),
        "{message}"
    );
}

#[test]
fn missing_project_names_the_database_and_the_recovery_action() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    let db_path = data_root_project_path(temp.path(), &project.to_string());
    let project_text = project.to_string();
    let output = run(
        &[
            "--format=json",
            "--data-root",
            temp.path().to_str().expect("UTF-8 root"),
            "--project",
            &project_text,
            "list",
        ],
        None,
    );
    assert_eq!(output.status.code(), Some(3));
    assert_eq!(error_code(&output), "not_found");
    let message = error_message(&output);
    assert!(message.contains(&project_text), "{message}");
    assert!(
        message.contains(&db_path.display().to_string()),
        "{message}"
    );
    assert!(message.contains("tasks init --root"), "{message}");
}

#[test]
fn schema_errors_name_the_database_the_found_version_and_the_required_one() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(temp.path(), &project).expect("database");
    let db_path = data_root_project_path(temp.path(), &project.to_string());
    let conn = rusqlite::Connection::open(&db_path).expect("open database");
    conn.pragma_update(None, "user_version", 7i32)
        .expect("set schema version");
    drop(conn);
    let project_text = project.to_string();
    let output = run(
        &[
            "--format=json",
            "--data-root",
            temp.path().to_str().expect("UTF-8 root"),
            "--project",
            &project_text,
            "list",
        ],
        None,
    );
    assert_eq!(output.status.code(), Some(6));
    assert_eq!(error_code(&output), "database");
    let message = error_message(&output);
    assert!(
        message.contains(&db_path.display().to_string()),
        "{message}"
    );
    assert!(message.contains("schema version 7"), "{message}");
    assert!(
        message.contains("newer than this build supports (5)"),
        "{message}"
    );
    assert!(message.contains("upgrade tasks-cli"), "{message}");

    let conn = rusqlite::Connection::open(&db_path).expect("reopen database");
    conn.pragma_update(None, "user_version", 0i32)
        .expect("set older schema version");
    drop(conn);
    let output = run(
        &[
            "--format=json",
            "--data-root",
            temp.path().to_str().expect("UTF-8 root"),
            "--project",
            &project_text,
            "list",
        ],
        None,
    );
    assert_eq!(output.status.code(), Some(6));
    assert_eq!(error_code(&output), "database");
    let message = error_message(&output);
    assert!(
        message.contains(&db_path.display().to_string()),
        "{message}"
    );
    assert!(message.contains("schema version 0"), "{message}");
    assert!(message.contains("requires 5"), "{message}");
    assert!(message.contains("tasks migrate --project"), "{message}");
}

#[test]
fn corrupt_registry_names_the_file_and_the_recovery_action() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let data = temp.path().join("data");
    fs::create_dir_all(&data).expect("data root");
    let registry = data.join("registry.json");
    fs::write(&registry, b"{ this is not json").expect("corrupt registry");
    let cwd = temp.path().join("cwd");
    fs::create_dir_all(&cwd).expect("working directory");
    let output = run(
        &[
            "--format=json",
            "--data-root",
            data.to_str().expect("UTF-8 data root"),
            "list",
        ],
        Some(&cwd),
    );
    assert_eq!(output.status.code(), Some(6));
    assert_eq!(error_code(&output), "registry");
    let message = error_message(&output);
    assert!(
        message.contains(registry.to_str().expect("UTF-8 registry")),
        "{message}"
    );
    assert!(message.contains("not valid JSON"), "{message}");
    assert!(message.contains("tasks init"), "{message}");
}

#[test]
fn invalid_scan_root_names_the_flag_the_path_and_the_expectation() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let file = temp.path().join("not-a-directory");
    fs::write(&file, b"x").expect("file");
    let output = run(
        &[
            "--format=json",
            "--data-root",
            temp.path().join("data").to_str().expect("UTF-8 root"),
            "bulk-import",
            "--scan-root",
            file.to_str().expect("UTF-8 file"),
            "--map-file",
            temp.path().join("map.json").to_str().expect("UTF-8 map"),
            "--report-dir",
            temp.path().join("report").to_str().expect("UTF-8 report"),
        ],
        None,
    );
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(error_code(&output), "invalid_path");
    let message = error_message(&output);
    assert!(message.contains("--scan-root"), "{message}");
    assert!(
        message.contains(file.to_str().expect("UTF-8 file")),
        "{message}"
    );
    assert!(message.contains("not a directory"), "{message}");
}

#[test]
fn usage_errors_name_the_argument_and_the_fix() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let output = run(
        &[
            "--format=json",
            "--data-root",
            temp.path().join("data").to_str().expect("UTF-8 root"),
            "bulk-import",
            "--scan-root",
            temp.path().to_str().expect("UTF-8 temp"),
            "--map-file",
            temp.path().join("map.json").to_str().expect("UTF-8 map"),
            "--report-dir",
            temp.path().join("report").to_str().expect("UTF-8 report"),
            "--delete-quarantined",
        ],
        None,
    );
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(error_code(&output), "usage");
    let message = error_message(&output);
    assert!(message.contains("--delete-quarantined"), "{message}");
    assert!(message.contains("--apply"), "{message}");

    let project = Uuid::new_v4();
    create_project_db(temp.path(), &project).expect("database");
    let file_a = temp.path().join("a.md");
    let file_b = temp.path().join("b.md");
    let project_text = project.to_string();
    let output = run(
        &[
            "--format=json",
            "--data-root",
            temp.path().to_str().expect("UTF-8 root"),
            "--project",
            &project_text,
            "import",
            "--file",
            file_a.to_str().expect("UTF-8 path"),
            "--file",
            file_b.to_str().expect("UTF-8 path"),
            "--expect-sha256",
            "00",
        ],
        None,
    );
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(error_code(&output), "usage");
    let message = error_message(&output);
    assert!(message.contains("2 --file source(s)"), "{message}");
    assert!(message.contains("1 --expect-sha256 value(s)"), "{message}");
    assert!(message.contains("same order"), "{message}");
}

#[test]
fn validation_errors_name_the_file_the_line_and_the_task() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(temp.path(), &project).expect("database");
    let ledger = temp.path().join("TASKS.md");
    fs::write(&ledger, "## backlog\n### T-001\nbody\n").expect("ledger");
    let project_text = project.to_string();
    let preview = run(
        &[
            "--format=json",
            "--data-root",
            temp.path().to_str().expect("UTF-8 root"),
            "--project",
            &project_text,
            "import",
            "--file",
            ledger.to_str().expect("UTF-8 ledger"),
        ],
        None,
    );
    assert_eq!(
        preview.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&preview.stderr)
    );
    let preview_json: Value = serde_json::from_slice(&preview.stdout).expect("preview JSON");
    let problems = preview_json["data"]["problems"]
        .as_array()
        .expect("structured preview problems");
    assert!(!problems.is_empty(), "{preview_json}");
    let title_problem = problems
        .iter()
        .find(|problem| {
            problem["message"]
                .as_str()
                .unwrap_or("")
                .contains("has no title")
        })
        .expect("empty-title diagnostic");
    assert_eq!(title_problem["file"].as_str(), ledger.to_str());
    assert_eq!(title_problem["line"].as_u64(), Some(2));
    assert_eq!(title_problem["task_id"].as_u64(), Some(1));
    assert_eq!(
        title_problem["fix"].as_str(),
        Some("write a non-empty title for T-001")
    );
    let preview_messages = problems
        .iter()
        .map(|problem| problem["message"].as_str().expect("problem message"))
        .collect::<Vec<_>>();

    let source_hash = tasks_cli::markdown::sha256(&fs::read(&ledger).expect("ledger bytes"));
    let apply = run(
        &[
            "--format=json",
            "--data-root",
            temp.path().to_str().expect("UTF-8 root"),
            "--project",
            &project_text,
            "import",
            "--file",
            ledger.to_str().expect("UTF-8 ledger"),
            "--apply",
            "--expect-sha256",
            &source_hash,
        ],
        None,
    );
    assert_eq!(apply.status.code(), Some(2));
    assert_eq!(error_code(&apply), "validation");
    let apply_message = error_message(&apply);
    for message in preview_messages {
        assert!(apply_message.contains(message), "{apply_message}");
    }

    let mut store = tasks_cli::store::Store::open_readonly(temp.path(), &project_text)
        .expect("database remains readable");
    assert!(store
        .list_tasks(None, None, 20)
        .expect("list tasks")
        .items
        .is_empty());
    let provenance_count: i64 = store
        .conn
        .query_row("SELECT COUNT(*) FROM imports", [], |row| row.get(0))
        .expect("provenance count");
    assert_eq!(provenance_count, 0);
}

#[test]
fn version_conflicts_name_the_expected_and_current_versions() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(temp.path(), &project).expect("database");
    let body = temp.path().join("body.md");
    fs::write(&body, "body").expect("body file");
    let project_text = project.to_string();
    let root_text = temp.path().to_str().expect("UTF-8 root");
    let body_text = body.to_str().expect("UTF-8 body");
    let created = run(
        &[
            "--format=json",
            "--data-root",
            root_text,
            "--project",
            &project_text,
            "create",
            "--title",
            "first",
            "--body-file",
            body_text,
        ],
        None,
    );
    assert!(
        created.status.success(),
        "{}",
        String::from_utf8_lossy(&created.stderr)
    );
    let updated = run(
        &[
            "--format=json",
            "--data-root",
            root_text,
            "--project",
            &project_text,
            "update",
            "T-1",
            "--expect-version",
            "1",
            "--title",
            "second",
        ],
        None,
    );
    assert!(
        updated.status.success(),
        "{}",
        String::from_utf8_lossy(&updated.stderr)
    );
    let conflict = run(
        &[
            "--format=json",
            "--data-root",
            root_text,
            "--project",
            &project_text,
            "update",
            "T-1",
            "--expect-version",
            "1",
            "--title",
            "third",
        ],
        None,
    );
    assert_eq!(conflict.status.code(), Some(4));
    assert_eq!(error_code(&conflict), "version_conflict");
    let message = error_message(&conflict);
    assert!(message.contains("expected 1"), "{message}");
    assert!(message.contains("current 2"), "{message}");
    assert!(message.contains("re-read the task"), "{message}");
}

#[test]
fn interop_errors_name_the_backend_setting() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let backend = temp.path().join("tasks.exe");
    let backend_text = backend.to_str().expect("UTF-8 backend");
    let output = run(
        &[
            "--format=json",
            "--data-root",
            temp.path().to_str().expect("UTF-8 root"),
            "--windows-exe",
            backend_text,
            "list",
        ],
        None,
    );
    assert_eq!(output.status.code(), Some(6));
    assert_eq!(error_code(&output), "interop");
    let message = error_message(&output);
    assert!(message.contains("Windows backend"), "{message}");
    assert!(message.contains("--windows-exe"), "{message}");
}
