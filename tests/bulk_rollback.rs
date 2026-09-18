#![cfg(feature = "test-hooks")]

use std::fs;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};
use tasks_cli::bulk::{self, BulkOptions};
use tasks_cli::model::{SourceSchema, TaskStatus};
use tasks_cli::store::Store;

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
    })
    .unwrap();
    assert_eq!(preview.failed, 0);
    let project = preview.candidates[0].project_id.clone();
    let ready = temp.path().join("ready");
    let release = temp.path().join("release");
    let mut child = Command::new(env!("CARGO_BIN_EXE_tasks"))
        .arg("--data-root")
        .arg(&data)
        .arg("bulk-import")
        .arg("--scan-root")
        .arg(&root)
        .arg("--map-file")
        .arg(&map)
        .arg("--report-dir")
        .arg(temp.path().join("apply"))
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
    let init = Command::new(env!("CARGO_BIN_EXE_tasks"))
        .arg("--data-root")
        .arg(&data)
        .arg("--project")
        .arg(&project)
        .arg("init")
        .arg("--root")
        .arg(&root)
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
