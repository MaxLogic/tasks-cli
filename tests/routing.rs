use serde_json::Value;
use std::fs;
use std::process::Command;
use tasks_cli::registry::{bind_root, resolve_project};
use tasks_cli::store::{create_project_db, data_root_project_path};
use tempfile::TempDir;
use uuid::Uuid;

fn write_identity(root: &std::path::Path, project: Uuid) {
    fs::write(
        root.join(".tasks.json"),
        format!(r#"{{"project_id":"{project}"}}"#),
    )
    .expect("identity");
}

fn routed_project(
    data_root: &std::path::Path,
    current_dir: &std::path::Path,
    explicit_project: Option<&str>,
    environment_project: Option<&str>,
) -> String {
    let mut command = Command::new(env!("CARGO_BIN_EXE_tasks"));
    command
        .args([
            "--format",
            "json",
            "--data-root",
            data_root.to_str().expect("UTF-8 data root"),
        ])
        .env_remove("TASKS_PROJECT")
        .current_dir(current_dir);
    if let Some(project) = explicit_project {
        command.args(["--project", project]);
    }
    command.arg("list");
    if let Some(project) = environment_project {
        command.env("TASKS_PROJECT", project);
    }
    let output = command.output().expect("tasks executable");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let envelope: Value = serde_json::from_slice(&output.stdout).expect("JSON output");
    envelope["project_id"]
        .as_str()
        .expect("selected project")
        .to_owned()
}

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

#[test]
fn nearest_project_identity_routes_an_unbound_worktree() {
    let (temp, project) = setup();
    let worktree = temp.path().join("unbound-worktree");
    let nested = worktree.join("src/deep");
    fs::create_dir_all(&nested).expect("worktree");
    write_identity(&worktree, project);

    assert_eq!(
        resolve_project(temp.path(), None, Some(&nested)).expect("identity route"),
        project.to_string()
    );
}

#[test]
fn routing_precedence_is_explicit_then_environment_then_identity_then_registry() {
    let data = tempfile::tempdir().expect("data root");
    let workspace = tempfile::tempdir().expect("workspace");
    let nested = workspace.path().join("src/deep");
    fs::create_dir_all(&nested).expect("nested directory");

    let registry_project = Uuid::new_v4();
    let identity_project = Uuid::new_v4();
    let environment_project = Uuid::new_v4();
    let explicit_project = Uuid::new_v4();
    for project in [
        registry_project,
        identity_project,
        environment_project,
        explicit_project,
    ] {
        create_project_db(data.path(), &project).expect("project database");
    }
    bind_root(
        data.path(),
        workspace.path(),
        Some(registry_project.to_string()),
    )
    .expect("registry binding");
    write_identity(workspace.path(), identity_project);

    assert_eq!(
        routed_project(
            data.path(),
            &nested,
            Some(&explicit_project.to_string()),
            Some(&environment_project.to_string()),
        ),
        explicit_project.to_string()
    );
    assert_eq!(
        routed_project(
            data.path(),
            &nested,
            None,
            Some(&environment_project.to_string()),
        ),
        environment_project.to_string()
    );
    assert_eq!(
        routed_project(data.path(), &nested, None, None),
        identity_project.to_string()
    );

    fs::remove_file(workspace.path().join(".tasks.json")).expect("remove identity");
    assert_eq!(
        routed_project(data.path(), &nested, None, None),
        registry_project.to_string()
    );
}

#[test]
fn explicit_project_wins_and_invalid_nearest_identity_fails_closed() {
    let (temp, project) = setup();
    let root = temp.path().join("workspace");
    let nested = root.join("nested/deep");
    fs::create_dir_all(&nested).expect("workspace");
    fs::write(root.join(".tasks.json"), r#"{"project_id":"invalid"}"#)
        .expect("invalid outer identity");
    fs::write(nested.parent().unwrap().join(".tasks.json"), "{}")
        .expect("invalid nearest identity");

    let error = resolve_project(temp.path(), None, Some(&nested)).expect_err("invalid identity");
    assert!(error.to_string().contains(".tasks.json"), "{error}");
    assert_eq!(error.exit_code(), 2);

    fs::write(
        nested.parent().unwrap().join(".tasks.json"),
        vec![b'x'; 4097],
    )
    .expect("oversized identity");
    let error = resolve_project(temp.path(), None, Some(&nested)).expect_err("oversized identity");
    assert!(
        error.to_string().contains("limited to 4096 bytes"),
        "{error}"
    );

    assert_eq!(
        resolve_project(temp.path(), Some(&project.to_string()), Some(&nested))
            .expect("explicit project"),
        project.to_string()
    );
}

#[test]
fn version_flag_identifies_the_binary() {
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_tasks"))
        .arg("--version")
        .output()
        .expect("tasks executable");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8(output.stdout).expect("UTF-8 version"),
        format!("tasks {}\n", env!("CARGO_PKG_VERSION"))
    );
}
