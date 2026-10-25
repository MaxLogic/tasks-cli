mod support;

use serde_json::Value;
use std::fs;
use std::path::Path;
use std::process::Output;
use tasks_cli::registry::write_project_identity;
use tasks_cli::store::create_project_db;
use uuid::Uuid;

fn identity(project: Uuid) -> String {
    format!("{{\"project_id\":\"{project}\"}}\n")
}

fn run(data: &Path, cwd: &Path, args: &[&str]) -> Output {
    support::process::command(env!("CARGO_BIN_EXE_tasks"))
        .args(["--format=json", "--data-root"])
        .arg(data)
        .args(args)
        .current_dir(cwd)
        .env_remove("TASKS_PROJECT")
        .env_remove("TASKS_WINDOWS_EXE")
        .output()
        .expect("tasks process")
}

fn selected(output: Output) -> String {
    assert!(output.status.success(), "{output:?}");
    let json: Value = serde_json::from_slice(&output.stdout).expect("JSON output");
    json["project_id"].as_str().expect("project UUID").into()
}

fn file_link(target: &Path, link: &Path) -> bool {
    #[cfg(unix)]
    let result = std::os::unix::fs::symlink(target, link);
    #[cfg(windows)]
    let result = {
        // The Windows reparse buffer needs native separators in relative targets.
        let target: std::path::PathBuf = target.components().collect();
        std::os::windows::fs::symlink_file(target, link)
    };
    match result {
        Ok(()) => {
            #[cfg(windows)]
            {
                use std::os::windows::fs::{FileTypeExt, MetadataExt};
                let entry = fs::symlink_metadata(link).unwrap();
                if let Ok(followed) = fs::metadata(link) {
                    eprintln!("file link: symlink_metadata is_symlink={} is_symlink_file={} attributes={:#x}; metadata is_file={} is_symlink={} attributes={:#x}", entry.is_symlink(), entry.file_type().is_symlink_file(), entry.file_attributes(), followed.is_file(), followed.is_symlink(), followed.file_attributes());
                }
            }
            true
        }
        #[cfg(windows)]
        Err(error) => {
            eprintln!(
                "SKIP symlink test: cannot create {} -> {}: {error}",
                link.display(),
                target.display()
            );
            false
        }
        #[cfg(not(windows))]
        Err(error) => panic!("create {} -> {}: {error}", link.display(), target.display()),
    }
}

#[test]
fn relative_and_private_identity_links_route_from_root_and_descendants() {
    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().join("data");
    let project = Uuid::new_v4();
    create_project_db(&data, &project).unwrap();
    for relative in ["identity.json", ".private/.tasks.json"] {
        let root = temp.path().join(if relative.starts_with('.') {
            "overlay"
        } else {
            "relative"
        });
        fs::create_dir_all(root.join(".private")).unwrap();
        fs::create_dir_all(root.join("src/deep")).unwrap();
        fs::write(root.join(relative), identity(project)).unwrap();
        if !file_link(Path::new(relative), &root.join(".tasks.json")) {
            return;
        }
        for cwd in [&root, &root.join("src/deep")] {
            assert_eq!(selected(run(&data, cwd, &["list"])), project.to_string());
        }
    }
}

#[test]
fn dangling_identity_link_fails_closed_for_routing_and_init_without_write_through() {
    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().join("data");
    let parent = temp.path().join("parent");
    let child = parent.join("child");
    fs::create_dir_all(&child).unwrap();
    let project = Uuid::new_v4();
    create_project_db(&data, &project).unwrap();
    fs::write(parent.join(".tasks.json"), identity(project)).unwrap();
    let link = child.join(".tasks.json");
    let target = child.join("missing.json");
    if !file_link(Path::new("missing.json"), &link) {
        return;
    }
    for output in [
        run(&data, &child, &["list"]),
        run(
            &data,
            &child,
            &["init", "--root", child.to_str().unwrap(), "--key", "CH"],
        ),
    ] {
        assert_eq!(output.status.code(), Some(2), "{output:?}");
        let error = String::from_utf8_lossy(&output.stderr);
        assert!(
            error.contains("project identity link") && error.contains("points to missing"),
            "{error}"
        );
        assert!(
            error.contains(".tasks.json") && error.contains("missing.json"),
            "{error}"
        );
    }
    let error = write_project_identity(&child, &project)
        .unwrap_err()
        .to_string();
    assert!(error.contains("points to missing"), "{error}");
    assert!(fs::symlink_metadata(&link).unwrap().is_symlink());
    assert!(!target.exists());
    assert_eq!(
        fs::read_to_string(parent.join(".tasks.json")).unwrap(),
        identity(project)
    );
}

#[test]
fn identity_link_chain_routes_and_dangling_chain_fails_closed() {
    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().join("data");
    let parent = temp.path().join("parent");
    let project = Uuid::new_v4();
    create_project_db(&data, &project).unwrap();
    fs::create_dir_all(&parent).unwrap();
    fs::write(parent.join(".tasks.json"), identity(Uuid::new_v4())).unwrap();
    for absolute in [false, true] {
        let root = parent.join(if absolute { "absolute" } else { "relative" });
        fs::create_dir_all(root.join(".private")).unwrap();
        let target = root.join(".private/.tasks.json");
        let intermediate = root.join(".private/link.json");
        let link = root.join(".tasks.json");
        fs::write(&target, identity(project)).unwrap();
        // .tasks.json -> .private/link.json -> .tasks.json (relative to .private)
        let final_target = if absolute {
            target.as_path()
        } else {
            Path::new(".tasks.json")
        };
        let first_target = if absolute {
            intermediate.as_path()
        } else {
            Path::new(".private/link.json")
        };
        if !file_link(final_target, &intermediate) || !file_link(first_target, &link) {
            return;
        }
        assert_eq!(selected(run(&data, &root, &["list"])), project.to_string());
        fs::remove_file(&target).unwrap();
        let output = run(&data, &root, &["list"]);
        assert_eq!(output.status.code(), Some(2), "{output:?}");
        let error: Value = serde_json::from_slice(&output.stderr).expect("JSON error");
        let message = error["error"]["message"].as_str().unwrap();
        assert!(message.contains("link to a missing target"), "{message}");
        let resolved = link.parent().unwrap().join(fs::read_link(&link).unwrap());
        assert!(
            message.contains(&resolved.display().to_string()),
            "{message}"
        );
        assert!(message.contains(&link.display().to_string()), "{message}");
        let error = write_project_identity(&root, &project)
            .unwrap_err()
            .to_string();
        assert!(error.contains("link to a missing target"), "{error}");
        assert!(!target.exists());
        assert!(fs::symlink_metadata(&link).unwrap().is_symlink());
        assert!(fs::symlink_metadata(&intermediate).unwrap().is_symlink());
    }
}

#[test]
fn linked_identity_targets_keep_regular_file_validation() {
    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().join("data");
    let root = temp.path().join("root");
    fs::create_dir_all(&root).unwrap();
    let target = root.join("target.json");
    let link = root.join(".tasks.json");
    fs::write(&target, "{}").unwrap();
    if !file_link(Path::new("target.json"), &link) {
        return;
    }
    for (content, expected) in [
        ("x".repeat(4097), "limited to 4096 bytes"),
        ("{}".into(), "not a valid project identity"),
        ("{\"project_id\":\"not-a-uuid\"}".into(), "is not a UUID"),
        (
            "{\"project_id\":\"AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA\"}".into(),
            "canonical lowercase",
        ),
        (
            format!("{{\"project_id\":\"{}\",\"extra\":true}}", Uuid::new_v4()),
            "not a valid project identity",
        ),
    ] {
        fs::write(&target, &content).unwrap();
        let linked = run(&data, &root, &["list"]);
        assert_eq!(linked.status.code(), Some(2), "{linked:?}");
        let error = String::from_utf8_lossy(&linked.stderr);
        assert!(
            error.contains(expected) && error.contains(".tasks.json"),
            "{error}"
        );
        fs::remove_file(&link).unwrap();
        fs::write(&link, &content).unwrap();
        let regular = run(&data, &root, &["list"]);
        assert_eq!(regular.status.code(), linked.status.code());
        assert_eq!(regular.stderr, linked.stderr);
        fs::remove_file(&link).unwrap();
        assert!(file_link(Path::new("target.json"), &link));
    }
}

#[test]
fn directory_identity_and_directory_link_are_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().join("data");
    let root = temp.path().join("root");
    fs::create_dir_all(root.join(".tasks.json")).unwrap();
    let direct = run(&data, &root, &["list"]);
    assert_eq!(direct.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&direct.stderr).contains("must be an ordinary file"));
    fs::remove_dir(root.join(".tasks.json")).unwrap();
    fs::create_dir(root.join("directory")).unwrap();
    #[cfg(unix)]
    assert!(file_link(Path::new("directory"), &root.join(".tasks.json")));
    #[cfg(windows)]
    if let Err(error) = std::os::windows::fs::symlink_dir("directory", root.join(".tasks.json")) {
        eprintln!("SKIP directory symlink test: {error}");
        return;
    }
    let linked = run(&data, &root, &["list"]);
    assert_eq!(linked.status.code(), Some(2), "{linked:?}");
    assert!(String::from_utf8_lossy(&linked.stderr).contains("must be an ordinary file"));
}

#[test]
fn init_and_write_preserve_matching_identity_link_and_refuse_conflicts() {
    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().join("data");
    let root = temp.path().join("root");
    fs::create_dir_all(root.join(".private")).unwrap();
    let project = Uuid::new_v4();
    let content = format!("{{\r\n  \"project_id\": \"{project}\"\r\n}}\r\n");
    let target = root.join(".private/.tasks.json");
    let link = root.join(".tasks.json");
    fs::write(&target, &content).unwrap();
    if !file_link(Path::new(".private/.tasks.json"), &link) {
        return;
    }
    write_project_identity(&root, &project).expect("matching link");
    assert_eq!(
        selected(run(
            &data,
            &root,
            &["init", "--root", root.to_str().unwrap(), "--key", "LK"]
        )),
        project.to_string()
    );
    let other = Uuid::new_v4();
    assert!(write_project_identity(&root, &other)
        .unwrap_err()
        .to_string()
        .contains("refusing to overwrite"));
    let refused = run(
        &data,
        &root,
        &[
            "--project",
            &other.to_string(),
            "init",
            "--root",
            root.to_str().unwrap(),
            "--key",
            "LK",
        ],
    );
    assert_eq!(refused.status.code(), Some(2), "{refused:?}");
    assert!(fs::symlink_metadata(&link).unwrap().is_symlink());
    assert_eq!(
        fs::read_link(&link).unwrap(),
        Path::new(".private/.tasks.json")
    );
    assert_eq!(fs::read_to_string(&target).unwrap(), content);
    assert!(!data.join("projects").join(other.to_string()).exists());
}

#[test]
fn monorepo_nearest_identity_routes_and_invalid_nearer_identity_fails_closed() {
    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().join("data");
    let root = temp.path().join("repo");
    let app = root.join("sub/app");
    fs::create_dir_all(app.join("src")).unwrap();
    fs::create_dir_all(root.join("sub/other")).unwrap();
    // Discovery is independent of Git boundaries, including a nested repository.
    fs::create_dir(root.join(".git")).unwrap();
    fs::create_dir(app.join(".git")).unwrap();
    let a = Uuid::new_v4();
    let b = Uuid::new_v4();
    for project in [a, b] {
        create_project_db(&data, &project).unwrap();
    }
    fs::write(root.join(".tasks.json"), identity(a)).unwrap();
    fs::write(app.join(".tasks.json"), identity(b)).unwrap();
    for (cwd, expected) in [
        (&root, a),
        (&root.join("sub/other"), a),
        (&app, b),
        (&app.join("src"), b),
    ] {
        assert_eq!(selected(run(&data, cwd, &["list"])), expected.to_string());
    }
    fs::write(app.join(".tasks.json"), "{}").unwrap();
    let output = run(&data, &app.join("src"), &["list"]);
    assert_eq!(output.status.code(), Some(2), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stderr).contains("not a valid project identity"));
}

#[test]
fn init_subproject_preserves_parent_and_supports_nested_overlay_identity() {
    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().join("data");
    let root = temp.path().join("repo");
    let app = root.join("sub/app");
    fs::create_dir_all(app.join("src")).unwrap();
    let a = Uuid::new_v4();
    fs::write(root.join(".tasks.json"), identity(a)).unwrap();
    let b = selected(run(
        &data,
        &root,
        &["init", "--root", app.to_str().unwrap(), "--key", "SUB"],
    ));
    assert_ne!(b, a.to_string());
    assert_eq!(
        fs::read_to_string(root.join(".tasks.json")).unwrap(),
        identity(a)
    );
    assert_eq!(selected(run(&data, &app.join("src"), &["list"])), b);
    let overlay = root.join(".private/sub/app");
    fs::create_dir_all(&overlay).unwrap();
    fs::rename(app.join(".tasks.json"), overlay.join(".tasks.json")).unwrap();
    if !file_link(
        Path::new("../../.private/sub/app/.tasks.json"),
        &app.join(".tasks.json"),
    ) {
        return;
    }
    for cwd in [&app, &app.join("src")] {
        assert_eq!(selected(run(&data, cwd, &["list"])), b);
    }
}

#[cfg(unix)]
#[test]
fn identity_link_to_a_special_file_is_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().join("data");
    let root = temp.path().join("root");
    fs::create_dir_all(&root).unwrap();
    assert!(file_link(Path::new("/dev/null"), &root.join(".tasks.json")));
    let output = run(&data, &root, &["list"]);
    assert_eq!(output.status.code(), Some(2), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stderr).contains("must be an ordinary file"));
}

#[cfg(windows)]
#[test]
fn windows_junction_identity_is_a_directory_reparse_point_and_is_rejected() {
    use std::os::windows::fs::{FileTypeExt, MetadataExt};
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    let target = temp.path().join("directory");
    fs::create_dir_all(&root).unwrap();
    fs::create_dir(&target).unwrap();
    let link = root.join(".tasks.json");
    let output = support::process::command("cmd.exe")
        .args(["/c", "mklink", "/J"])
        .arg(&link)
        .arg(&target)
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let entry = fs::symlink_metadata(&link).unwrap();
    let followed = fs::metadata(&link).unwrap();
    let routed = run(&temp.path().join("data"), &root, &["list"]);
    fs::remove_dir(&link).expect("remove owned junction itself");
    eprintln!("junction: symlink_metadata is_symlink={} is_dir={} attributes={:#x}; metadata is_symlink={} is_dir={} attributes={:#x}", entry.is_symlink(), entry.is_dir(), entry.file_attributes(), followed.is_symlink(), followed.is_dir(), followed.file_attributes());
    // Rust treats junctions as symlinks, but not as file symlinks.
    assert!(!entry.file_type().is_symlink_file());
    assert_ne!(entry.file_attributes() & 0x400, 0);
    assert!(followed.is_dir());
    assert_eq!(routed.status.code(), Some(2), "{routed:?}");
}
