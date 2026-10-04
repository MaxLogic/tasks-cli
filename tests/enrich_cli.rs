mod support;
use std::{io::Write, process::Stdio};
use tasks_cli::store::{create_project_db, Store};
use uuid::Uuid;
#[test]
fn enrich_cli_preserves_stdin_file_and_json_contracts() {
    let root = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    create_project_db(root.path(), &id).unwrap();
    let mut store = Store::open_rw(root.path(), &id.to_string()).unwrap();
    store
        .create_task(
            "Cache Ω",
            "body",
            tasks_cli::model::TaskStatus::Ready,
            vec![],
        )
        .unwrap();
    drop(store);
    let run = |args: &[&str], input: &[u8]| {
        let mut child = support::process::command(env!("CARGO_BIN_EXE_tasks"))
            .args([
                "--data-root",
                root.path().to_str().unwrap(),
                "--project",
                &id.to_string(),
            ])
            .args(args)
            .env_remove("TASKS_WINDOWS_EXE")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        child.wait_with_output().unwrap()
    };
    let input = "Start T001\r\nT-1; T999";
    let output = run(&["enrich"], input.as_bytes());
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        "Start T001 (Cache Ω)\r\nT-1 (Cache Ω); T999"
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("T-999"));
    let file = root.path().join("input.txt");
    std::fs::write(&file, input).unwrap();
    let output = run(
        &[
            "enrich",
            "--file",
            file.to_str().unwrap(),
            "--format",
            "json",
        ],
        b"",
    );
    assert!(output.status.success());
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(json["data"]["replacements"], 2);
    assert_eq!(json["data"]["unknown_ids"], serde_json::json!([999]));
    assert_eq!(std::fs::read_to_string(file).unwrap(), input);
    assert_eq!(run(&["enrich"], &[255]).status.code(), Some(2));
}
