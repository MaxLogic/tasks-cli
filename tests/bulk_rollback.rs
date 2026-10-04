#![cfg(feature = "test-hooks")]

mod support;
use std::fs;
use std::process::Stdio;
use std::time::{Duration, Instant};
use tasks_cli::bulk::{self, BulkOptions};
use tasks_cli::model::{SourceSchema, TaskStatus};
use tasks_cli::store::{create_project_db_with_key, Store};
use uuid::Uuid;

/// Writes a --key-map giving the workspace root the key WS.
fn key_map(temp: &std::path::Path, root: &std::path::Path) -> std::path::PathBuf {
    let path = temp.join("keys.json");
    fs::write(
        &path,
        serde_json::json!({ root.to_str().unwrap(): "WS" }).to_string(),
    )
    .unwrap();
    path
}

#[test]
fn failed_bulk_import_preserves_a_project_created_by_another_process() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("workspace");
    fs::create_dir(&root).unwrap();
    fs::write(
        root.join("TASKS.md"),
        "## ready\n### T-1 Imported\nBody:\nbody\n",
    )
    .unwrap();
    let map = temp.path().join("map.json");
    fs::write(&map, "{\"sections\":{\"ready\":\"ready\"}}").unwrap();
    let data = temp.path().join("data");
    let preview = bulk::run(BulkOptions {
        data_root: data.clone(),
        scan_root: root.clone(),
        map_file: map.clone(),
        report_dir: temp.path().join("preview"),
        excludes: vec![],
        apply: false,
        quarantine_dir: None,
        delete_quarantined: false,
        allow_partial: false,
        source_schema: SourceSchema::Canonical,
        key_map: Some(key_map(temp.path(), &root)),
    })
    .unwrap();
    assert_eq!(preview.failed, 0);
    let project = preview.candidates[0].project_id.clone();
    let ready = temp.path().join("ready");
    let release = temp.path().join("release");
    let mut child = support::process::command(env!("CARGO_BIN_EXE_tasks"))
        .arg("--data-root")
        .arg(&data)
        .arg("bulk-import")
        .arg("--scan-root")
        .arg(&root)
        .arg("--map-file")
        .arg(&map)
        .arg("--report-dir")
        .arg(temp.path().join("apply"))
        .arg("--key-map")
        .arg(key_map(temp.path(), &root))
        .arg("--apply")
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .env("TASKS_TEST_BULK_READY", &ready)
        .env("TASKS_TEST_BULK_RELEASE", &release)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let started = Instant::now();
    while !ready.exists() {
        if started.elapsed() > Duration::from_secs(10) || child.try_wait().unwrap().is_some() {
            let _ = child.kill();
            let output = child.wait_with_output().unwrap();
            panic!("bulk import did not reach interleaving point: {output:?}");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let init = support::process::command(env!("CARGO_BIN_EXE_tasks"))
        .arg("--data-root")
        .arg(&data)
        .arg("--project")
        .arg(&project)
        .arg("init")
        .arg("--root")
        .arg(&root)
        .arg("--key")
        .arg("WS")
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .output()
        .unwrap();
    assert!(init.status.success(), "{init:?}");
    let mut other = Store::open_rw(&data, &project).unwrap();
    other
        .create_task(
            "Another worker's committed task",
            "keep this",
            TaskStatus::Ready,
            vec![],
        )
        .unwrap();
    drop(other);
    fs::write(release, "go").unwrap();
    let result = child.wait_with_output().unwrap();
    assert!(
        !result.status.success(),
        "import into occupied project must fail"
    );
    let mut retained = Store::open_readonly(&data, &project)
        .expect("failed import deleted the other process's committed database");
    assert_eq!(
        retained.show_task("T-1").unwrap().title,
        "Another worker's committed task"
    );
    let registry = tasks_cli::registry::list_bindings(&data).unwrap();
    assert_eq!(
        registry.bindings.len(),
        1,
        "failed import removed another process's binding"
    );
    assert_eq!(registry.bindings[0].project_id, project);
}

#[test]
fn verification_failure_on_a_preexisting_database_reports_retained_mutation() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("workspace");
    fs::create_dir(&root).unwrap();
    fs::write(
        root.join("TASKS.md"),
        "## ready\n### T-1 Imported\nBody:\nbody\n",
    )
    .unwrap();
    let map = temp.path().join("map.json");
    fs::write(&map, "{\"sections\":{\"ready\":\"ready\"}}").unwrap();
    let data = temp.path().join("data");
    let preview = bulk::run(BulkOptions {
        data_root: data.clone(),
        scan_root: root.clone(),
        map_file: map.clone(),
        report_dir: temp.path().join("preview"),
        excludes: vec![],
        apply: false,
        quarantine_dir: None,
        delete_quarantined: false,
        allow_partial: false,
        source_schema: SourceSchema::Canonical,
        key_map: Some(key_map(temp.path(), &root)),
    })
    .unwrap();
    let project = Uuid::parse_str(&preview.candidates[0].project_id).unwrap();
    create_project_db_with_key(&data, &project, Some("WS")).unwrap();

    let report_dir = temp.path().join("apply");
    let output = support::process::command(env!("CARGO_BIN_EXE_tasks"))
        .args([
            "--data-root",
            data.to_str().unwrap(),
            "bulk-import",
            "--scan-root",
            root.to_str().unwrap(),
            "--map-file",
            map.to_str().unwrap(),
            "--report-dir",
            report_dir.to_str().unwrap(),
            "--key-map",
            key_map(temp.path(), &root).to_str().unwrap(),
            "--apply",
        ])
        .env("TASKS_TEST_BULK_FAIL_VERIFY", "1")
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2), "{output:?}");
    let lines = fs::read_to_string(report_dir.join("run.jsonl")).unwrap();
    let candidate: serde_json::Value = serde_json::from_str(lines.lines().next().unwrap()).unwrap();
    assert_eq!(candidate["applied"], true, "{candidate:#?}");
    assert_eq!(candidate["verified"], false, "{candidate:#?}");
    assert_eq!(candidate["rolled_back"], false, "{candidate:#?}");
    let mut retained = Store::open_readonly(&data, &project.to_string()).unwrap();
    assert_eq!(retained.show_task("T-1").unwrap().title, "Imported");
}

#[test]
fn competing_verification_export_reports_committed_preexisting_db_state() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("workspace");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("TASKS.md"), "## ready\n### T-1 Imported\nbody\n").unwrap();
    let map = temp.path().join("map.json");
    fs::write(&map, "{\"sections\":{\"ready\":\"ready\"}}").unwrap();
    let data = temp.path().join("data");
    let preview = bulk::run(BulkOptions {
        data_root: data.clone(),
        scan_root: root.clone(),
        map_file: map.clone(),
        report_dir: temp.path().join("preview"),
        excludes: vec![],
        apply: false,
        quarantine_dir: None,
        delete_quarantined: false,
        allow_partial: false,
        source_schema: SourceSchema::Canonical,
        key_map: Some(key_map(temp.path(), &root)),
    })
    .unwrap();
    let project = Uuid::parse_str(&preview.candidates[0].project_id).unwrap();
    create_project_db_with_key(&data, &project, Some("WS")).unwrap();

    let report_dir = temp.path().join("apply");
    let ready = temp.path().join("ready-export");
    let release = temp.path().join("release-export");
    let mut child = support::process::command(env!("CARGO_BIN_EXE_tasks"))
        .args([
            "--data-root",
            data.to_str().unwrap(),
            "bulk-import",
            "--scan-root",
            root.to_str().unwrap(),
            "--map-file",
            map.to_str().unwrap(),
            "--report-dir",
            report_dir.to_str().unwrap(),
            "--key-map",
            key_map(temp.path(), &root).to_str().unwrap(),
            "--apply",
        ])
        .env("TASKS_TEST_BULK_READY", &ready)
        .env("TASKS_TEST_BULK_RELEASE", &release)
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let started = Instant::now();
    while !ready.exists() {
        if started.elapsed() > Duration::from_secs(10) || child.try_wait().unwrap().is_some() {
            let _ = child.kill();
            let output = child.wait_with_output().unwrap();
            panic!("bulk import did not reach export race point: {output:?}");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let export = report_dir.join("exports").join("001-root.md");
    fs::write(&export, b"another process's export").unwrap();
    fs::write(&release, b"go").unwrap();
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(2), "{output:?}");
    let lines = fs::read_to_string(report_dir.join("run.jsonl")).unwrap();
    let candidate: serde_json::Value = serde_json::from_str(lines.lines().next().unwrap()).unwrap();
    assert_eq!(candidate["applied"], true, "{candidate:#?}");
    assert_eq!(candidate["verified"], false, "{candidate:#?}");
    assert_eq!(candidate["rolled_back"], false, "{candidate:#?}");
    assert_eq!(fs::read(&export).unwrap(), b"another process's export");
    let mut retained = Store::open_readonly(&data, &project.to_string()).unwrap();
    assert_eq!(retained.list_tasks(None, None, 20).unwrap().items.len(), 1);
}
