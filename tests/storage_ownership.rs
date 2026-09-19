#[cfg(unix)]
#[test]
fn same_os_project_directory_links_are_validated_at_the_resolved_database_target() {
    use std::fs;
    use std::os::unix::fs::symlink;
    use tasks_cli::store::{create_project_db, Store};
    use tempfile::tempdir;
    use uuid::Uuid;

    let root = tempdir().expect("temporary root");
    let project = Uuid::new_v4();
    let owned = root.path().join("owned");
    let project_dir = root.path().join("projects").join(project.to_string());
    fs::create_dir_all(&owned).expect("owned project root");
    fs::create_dir_all(project_dir.parent().expect("projects parent")).expect("projects root");
    symlink(&owned, &project_dir).expect("same-os project directory link");

    create_project_db(root.path(), &project).expect("create through local project link");
    let actual = owned.join("TASKS.sqlite");
    assert!(
        actual.is_file(),
        "database was not created under resolved root"
    );
    Store::open_rw(root.path(), &project.to_string()).expect("open through local link");
}

#[cfg(target_os = "linux")]
#[test]
fn linux_rejects_db_and_project_links_into_windows_mounts_before_sqlite_open() {
    use std::fs;
    use std::os::unix::fs::symlink;
    use tasks_cli::store::Store;
    use tempfile::tempdir;
    use uuid::Uuid;

    let mount = std::path::Path::new("/mnt/c");
    if !mount.is_dir() {
        return;
    }
    let root = tempdir().expect("temporary root");
    let project = Uuid::new_v4();
    let project_dir = root.path().join("projects").join(project.to_string());
    fs::create_dir_all(&project_dir).expect("project directory");
    let db_link = project_dir.join("TASKS.sqlite");
    symlink(mount, &db_link).expect("database link");
    let error = match Store::open_readonly(root.path(), &project.to_string()) {
        Ok(_) => panic!("database link into /mnt/c was opened"),
        Err(error) => error,
    };
    assert_eq!(error.code(), "invalid_path", "{error}");
    assert!(
        error.to_string().contains("Windows") || error.to_string().contains("WSL"),
        "{error}"
    );

    fs::remove_file(&db_link).expect("remove database link");
    fs::remove_dir(&project_dir).expect("remove project directory");
    symlink(mount, &project_dir).expect("project directory link");
    let error = match Store::open_readonly(root.path(), &project.to_string()) {
        Ok(_) => panic!("project directory link into /mnt/c was opened"),
        Err(error) => error,
    };
    assert_eq!(error.code(), "invalid_path", "{error}");
    assert!(
        error.to_string().contains("Windows") || error.to_string().contains("WSL"),
        "{error}"
    );
}

#[test]
fn rejected_cross_os_target_is_refused_before_database_creation() {
    use std::path::PathBuf;
    use tasks_cli::store::create_project_db;
    use uuid::Uuid;

    let project = Uuid::new_v4();
    let invalid = if cfg!(windows) {
        PathBuf::from(format!(r"\\server\share\tasks-cli-{project}"))
    } else {
        PathBuf::from(format!("/mnt/c/tasks-cli-{project}"))
    };
    let error = match create_project_db(&invalid, &project) {
        Ok(_) => panic!("cross-os target was accepted"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("remote") || error.to_string().contains("WSL"));
}
