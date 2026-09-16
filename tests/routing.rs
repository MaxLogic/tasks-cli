use std::fs;
use tasks_cli::registry::{bind_root, resolve_project};
use tasks_cli::store::{create_project_db, data_root_project_path};
use tempfile::TempDir;
use uuid::Uuid;

fn setup() -> (TempDir, Uuid) {
    let temp = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(temp.path(), &project).expect("database");
    (temp, project)
}

#[test]
fn longest_registered_ancestor_and_explicit_precedence() {
    let (temp, parent_project) = setup();
    let parent = temp.path().join("workspace");
    let child = parent.join("nested");
    let unrelated = temp.path().join("unrelated");
    fs::create_dir_all(&child).expect("child");
    fs::create_dir_all(&unrelated).expect("unrelated");
    let child_project = Uuid::new_v4();
    create_project_db(temp.path(), &child_project).expect("child database");
    bind_root(temp.path(), &parent, Some(parent_project.to_string())).expect("parent binding");
    bind_root(temp.path(), &child, Some(child_project.to_string())).expect("child binding");

    assert_eq!(
        resolve_project(temp.path(), None, Some(&child)).expect("child route"),
        child_project.to_string()
    );
    assert_eq!(
        resolve_project(temp.path(), Some(&parent_project.to_string()), Some(&child))
            .expect("explicit route"),
        parent_project.to_string()
    );
    assert!(resolve_project(temp.path(), None, Some(&unrelated)).is_err());
    assert!(!data_root_project_path(temp.path(), &Uuid::new_v4().to_string()).exists());
}

#[test]
fn unknown_cli_directory_fails_without_creating_a_backlog() {
    let (temp, _) = setup();
    let unknown = temp.path().join("unknown");
    fs::create_dir_all(&unknown).expect("unknown directory");
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_tasks"))
        .args(["--data-root", temp.path().to_str().unwrap(), "list"])
        .current_dir(&unknown)
        .output()
        .expect("tasks executable");
    assert_eq!(output.status.code(), Some(3));
    assert!(!temp.path().join("projects").join("unknown").exists());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("no project is bound"), "{stderr}");
    assert!(stderr.contains("registry"), "{stderr}");
    assert!(stderr.contains("tasks init --root"), "{stderr}");
}
