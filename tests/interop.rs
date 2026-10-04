mod support;
use clap::Parser;
use std::fs;
use std::io::Write;
use std::process::Stdio;
use tasks_cli::cli::Cli;
use uuid::Uuid;

#[test]
fn explicit_project_and_windows_exe_are_parsed_without_shell_expansion() {
    let id = Uuid::new_v4().to_string();
    let cli = Cli::try_parse_from([
        "tasks",
        "--project",
        &id,
        "--windows-exe",
        "C:\\Program Files\\tasks.exe",
        "show",
        "T-1",
    ])
    .expect("parse");
    assert_eq!(cli.project.as_deref(), Some(id.as_str()));
    assert_eq!(
        cli.windows_exe.as_deref().unwrap().to_string_lossy(),
        "C:\\Program Files\\tasks.exe"
    );
}

#[test]
fn global_format_option_is_accepted_after_a_subcommand() {
    let cli = Cli::try_parse_from(["tasks", "list", "--format", "json"]).expect("parse");
    assert_eq!(cli.format, tasks_cli::cli::OutputFormat::Json);
}

#[test]
fn subprocess_preserves_stdin_body_and_nonzero_exit_codes() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let root = temp.path().join("workspace with spaces");
    fs::create_dir_all(&root).expect("root");
    let data = temp.path().join("data");
    let binary = env!("CARGO_BIN_EXE_tasks");
    let init = support::process::command(binary)
        .args([
            "--data-root",
            data.to_str().unwrap(),
            "init",
            "--root",
            root.to_str().unwrap(),
            "--key",
            "IO",
        ])
        .output()
        .expect("init");
    assert!(init.status.success());
    let init_json = String::from_utf8_lossy(&init.stdout);
    let project = init_json
        .split("project_id: ")
        .nth(1)
        .and_then(|v| v.lines().next())
        .unwrap()
        .trim()
        .to_string();
    let mut child = support::process::command(binary)
        .args([
            "--data-root",
            data.to_str().unwrap(),
            "--project",
            &project,
            "create",
            "--title",
            "stdin",
            "--body-file",
            "-",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("create");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"stdin body\r\n")
        .expect("stdin");
    assert!(child
        .wait_with_output()
        .expect("create result")
        .status
        .success());
    let bad = support::process::command(binary)
        .args([
            "--data-root",
            data.to_str().unwrap(),
            "--project",
            &project,
            "show",
            "T-999",
        ])
        .output()
        .expect("missing show");
    assert_eq!(bad.status.code(), Some(3));
}
