use serde_json::Value;
use std::process::{Command, Stdio};
use tasks_cli::registry;
use tasks_cli::store::create_project_db;
use uuid::Uuid;

#[test]
fn repeated_init_reuses_identity_and_does_not_create_orphans() {
    let data = tempfile::tempdir().expect("data root");
    let project_root = tempfile::tempdir().expect("project root");
    let first = registry::init_root(data.path(), project_root.path(), None).expect("first init");
    let second = registry::init_root(data.path(), project_root.path(), None).expect("second init");
    assert_eq!(first.project_id, second.project_id);
    let project_dirs = std::fs::read_dir(data.path().join("projects"))
        .expect("projects")
        .filter_map(Result::ok)
        .filter(|entry| entry.path().is_dir())
        .count();
    assert_eq!(project_dirs, 1);
    let registry = registry::list_bindings(data.path()).expect("registry");
    assert_eq!(registry.bindings.len(), 1);
    assert_eq!(
        registry.bindings[0].project_id,
        first.project_id.to_string()
    );
}

#[test]
fn concurrent_init_processes_publish_one_binding_and_one_database() {
    let data = tempfile::tempdir().expect("data root");
    let project_root = tempfile::tempdir().expect("project root");
    let binary = env!("CARGO_BIN_EXE_tasks");
    let data_text = data.path().to_str().expect("UTF-8 data root");
    let root_text = project_root.path().to_str().expect("UTF-8 project root");
    let args = [
        "--format=json",
        "--data-root",
        data_text,
        "init",
        "--root",
        root_text,
    ];
    let first = Command::new(binary)
        .args(args)
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("first init");
    let second = Command::new(binary)
        .args(args)
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("second init");
    let first = first.wait_with_output().expect("first status");
    let second = second.wait_with_output().expect("second status");
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    assert!(
        second.status.success(),
        "{}",
        String::from_utf8_lossy(&second.stderr)
    );
    let first: Value = serde_json::from_slice(&first.stdout).expect("first JSON");
    let second: Value = serde_json::from_slice(&second.stdout).expect("second JSON");
    assert_eq!(first["project_id"], second["project_id"]);
    assert_eq!(
        std::fs::read_dir(data.path().join("projects"))
            .expect("projects")
            .filter_map(Result::ok)
            .filter(|entry| entry.path().is_dir())
            .count(),
        1
    );
    assert_eq!(
        registry::list_bindings(data.path())
            .expect("registry")
            .bindings
            .len(),
        1
    );
}

#[test]
fn stale_binding_does_not_block_a_new_valid_binding() {
    let data = tempfile::tempdir().expect("data root");
    let old_root = tempfile::tempdir().expect("old root");
    let old = registry::init_root(data.path(), old_root.path(), None).expect("old init");
    let old_path = old_root.path().to_path_buf();
    drop(old_root);
    assert!(!old_path.exists());

    let replacement = tempfile::tempdir().expect("replacement root");
    let replacement_id = Uuid::new_v4();
    create_project_db(data.path(), &replacement_id).expect("replacement database");
    registry::bind_root(
        data.path(),
        replacement.path(),
        Some(replacement_id.to_string()),
    )
    .expect("replacement bind");
    let resolved = registry::resolve_project(data.path(), None, Some(replacement.path()))
        .expect("replacement route");
    assert_eq!(resolved, replacement_id.to_string());
    assert_ne!(resolved, old.project_id.to_string());
}
