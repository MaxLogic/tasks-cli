mod support;
use rusqlite::Connection;
use tasks_cli::model::TaskStatus;
use tasks_cli::store::{create_project_db, Store};
use uuid::Uuid;

#[test]
fn concurrent_backups_publish_at_most_one_destination() {
    let root = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).expect("database");
    let mut store = Store::open_rw(root.path(), &project.to_string()).expect("open");
    store
        .create_task("backup task", "body", TaskStatus::Ready, Vec::new())
        .expect("task");
    drop(store);

    let binary = env!("CARGO_BIN_EXE_tasks");
    let project_text = project.to_string();
    let root_text = root.path().to_str().expect("UTF-8 root");
    let out = root.path().join("same.sqlite");
    let out_text = out.to_str().expect("UTF-8 backup");
    let args = [
        "--data-root",
        root_text,
        "--project",
        project_text.as_str(),
        "backup",
        "--out",
        out_text,
    ];
    let first = support::process::command(binary)
        .args(args)
        .spawn()
        .expect("first backup");
    let second = support::process::command(binary)
        .args(args)
        .spawn()
        .expect("second backup");
    let first = first.wait_with_output().expect("first status");
    let second = second.wait_with_output().expect("second status");
    let mut statuses = [
        first.status.code().expect("first code"),
        second.status.code().expect("second code"),
    ];
    statuses.sort_unstable();
    assert_eq!(statuses, [0, 2]);

    let conn = Connection::open_with_flags(out, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .expect("published backup");
    assert_eq!(
        conn.query_row("PRAGMA quick_check", [], |row| row.get::<_, String>(0))
            .expect("quick check"),
        "ok"
    );
    assert_eq!(
        conn.query_row("SELECT COUNT(*) FROM tasks", [], |row| row.get::<_, i64>(0))
            .expect("task count"),
        1
    );
}

#[test]
fn existing_destination_sidecars_are_preserved_and_block_backup_publication() {
    let root = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).expect("database");
    let mut store = Store::open_rw(root.path(), &project.to_string()).expect("open");
    store
        .create_task("backup task", "body", TaskStatus::Ready, Vec::new())
        .expect("task");
    let out = root.path().join("protected.sqlite");
    let wal = std::path::PathBuf::from(format!("{}-wal", out.display()));
    let shm = std::path::PathBuf::from(format!("{}-shm", out.display()));
    std::fs::write(&wal, b"existing wal").expect("wal");
    std::fs::write(&shm, b"existing shm").expect("shm");
    let error = store
        .backup(&out)
        .expect_err("sidecars must block publication");
    assert!(error.to_string().contains("sidecar"), "{error}");
    assert_eq!(std::fs::read(&wal).expect("wal bytes"), b"existing wal");
    assert_eq!(std::fs::read(&shm).expect("shm bytes"), b"existing shm");
    assert!(
        !out.exists(),
        "backup destination was published beside owned sidecars"
    );
}

#[cfg(feature = "test-hooks")]
#[test]
fn incomplete_backup_steps_are_bounded_and_publish_nothing() {
    for step in ["busy", "locked", "more"] {
        let root = tempfile::tempdir().unwrap();
        let project = Uuid::new_v4();
        create_project_db(root.path(), &project).unwrap();
        let out = root.path().join("bounded.sqlite");
        let log = root.path().join("steps.log");
        let output = support::process::command(env!("CARGO_BIN_EXE_tasks"))
            .args([
                "--data-root",
                root.path().to_str().unwrap(),
                "--project",
                &project.to_string(),
                "--format",
                "json",
                "backup",
                "--out",
                out.to_str().unwrap(),
            ])
            .env("TASKS_TEST_BACKUP_STEP", step)
            .env("TASKS_TEST_BACKUP_STEP_LOG", &log)
            .output()
            .unwrap();
        assert_eq!(
            output.status.code(),
            Some(5),
            "{step}: {}",
            String::from_utf8_lossy(&output.stdout)
        );
        assert!(String::from_utf8_lossy(&output.stderr).contains("lock_timeout"));
        assert!(!out.exists());
        assert_eq!(std::fs::read_to_string(log).unwrap().lines().count(), 3);
        assert!(!std::fs::read_dir(root.path()).unwrap().any(|e| e
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains("tasks-cli-tmp")));
    }
}

#[cfg(feature = "test-hooks")]
#[test]
fn single_step_backup_with_concurrent_writer_preserves_decodable_blob() {
    use tasks_cli::attachment::{db::PreparedItem, envelope, Limits};
    let root = tempfile::tempdir().unwrap();
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).unwrap();
    let mut store = Store::open_rw(root.path(), &project.to_string()).unwrap();
    let id = store
        .create_task("backup", "body", TaskStatus::Ready, vec![])
        .unwrap()
        .0;
    let original = vec![7u8; 1024 * 1024];
    let prepared = PreparedItem {
        name: "content.bin".into(),
        envelope: envelope::encode(original.as_slice(), "content.bin", &Limits::PRODUCTION)
            .unwrap(),
    };
    store
        .attach(id, 1, vec![prepared], &Limits::PRODUCTION)
        .unwrap();
    let marker = root.path().join("writer-ready");
    let steps = root.path().join("backup-steps");
    let out = root.path().join("online.sqlite");
    let mut writer = support::process::command(env!("CARGO_BIN_EXE_tasks-test-writer"))
        .args([
            "--data-root",
            root.path().to_str().unwrap(),
            "--project",
            &project.to_string(),
            "--id",
            "T-1",
            "--expect-version",
            "2",
            "--title",
            "concurrent",
        ])
        .env("TASKS_PRECOMMIT_READY_FILE", &marker)
        .env("TASKS_HOLD_PRECOMMIT_MS", "800")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !marker.exists() {
        if let Some(status) = writer.try_wait().unwrap() {
            panic!("writer exited before precommit: {status}");
        }
        if std::time::Instant::now() > deadline {
            writer.kill().unwrap();
            writer.wait().unwrap();
            panic!("writer barrier deadline");
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let backup = support::process::command(env!("CARGO_BIN_EXE_tasks"))
        .args([
            "--data-root",
            root.path().to_str().unwrap(),
            "--project",
            &project.to_string(),
            "backup",
            "--out",
            out.to_str().unwrap(),
        ])
        .env("TASKS_TEST_BACKUP_STEP_LOG", &steps)
        .output()
        .unwrap();
    let writer = writer.wait_with_output().unwrap();
    assert!(
        writer.status.success(),
        "{}",
        String::from_utf8_lossy(&writer.stderr)
    );
    assert!(
        backup.status.success(),
        "{}",
        String::from_utf8_lossy(&backup.stderr)
    );
    assert_eq!(std::fs::read_to_string(steps).unwrap().lines().count(), 1);
    let backup =
        Connection::open_with_flags(out, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(
        backup
            .query_row("PRAGMA quick_check", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    let bytes: Vec<u8> = backup
        .query_row(
            "SELECT envelope FROM attachment_blobs WHERE blob_id=1",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let mut decoded = Vec::new();
    envelope::decode_to(&bytes, "content.bin", &mut decoded, &Limits::PRODUCTION).unwrap();
    assert_eq!(decoded, original);
    assert_eq!(
        backup
            .query_row("SELECT count(*) FROM task_attachments", [], |r| r
                .get::<_, u64>(0))
            .unwrap(),
        1
    );
}

#[cfg(feature = "test-hooks")]
#[test]
fn backup_retry_preserves_competing_file_at_removed_temp_path() {
    use std::{
        fs,
        path::PathBuf,
        process::Stdio,
        time::{Duration, Instant},
    };
    use tasks_cli::store::data_root_project_path;

    for migration in [false, true] {
        let root = tempfile::tempdir().unwrap();
        let project = Uuid::new_v4();
        create_project_db(root.path(), &project).unwrap();
        let db = data_root_project_path(root.path(), &project.to_string());
        if migration {
            Connection::open(&db).unwrap().execute_batch(
                "DROP TABLE task_attachments; DROP TABLE attachment_blobs; PRAGMA user_version=8;"
            ).unwrap();
        }
        let out = root.path().join("collision.sqlite");
        let ready = root.path().join("retry-ready");
        let resume = root.path().join("retry-resume");
        let steps = root.path().join("steps.log");
        let mut command = support::process::command(env!("CARGO_BIN_EXE_tasks"));
        command.args([
            "--data-root",
            root.path().to_str().unwrap(),
            "--project",
            &project.to_string(),
            "--format",
            "json",
        ]);
        if migration {
            command.arg("migrate");
        } else {
            command.args(["backup", "--out", out.to_str().unwrap()]);
        }
        let start = Instant::now();
        let mut child = command
            .env("TASKS_TEST_BACKUP_STEP", "busy")
            .env("TASKS_TEST_BACKUP_STEP_LOG", &steps)
            .env("TASKS_TEST_BACKUP_RETRY_READY", &ready)
            .env("TASKS_TEST_BACKUP_RETRY_RESUME", &resume)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let deadline = start + Duration::from_secs(10);
        let temp = loop {
            if let Ok(path) = fs::read_to_string(&ready) {
                if !path.is_empty() {
                    break PathBuf::from(path);
                }
            }
            if let Some(status) = child.try_wait().unwrap() {
                panic!("backup exited before retry barrier: {status}");
            }
            if Instant::now() >= deadline {
                child.kill().unwrap();
                child.wait().unwrap();
                panic!("backup retry barrier deadline");
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        assert!(
            !temp.exists(),
            "completed attempt must release its pathname"
        );
        let sentinel = b"competing file must survive the retry";
        let sidecar = PathBuf::from(format!("{}-wal", temp.display()));
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .unwrap();
        fs::write(&temp, sentinel).unwrap();
        fs::write(&sidecar, b"competing sidecar").unwrap();
        fs::write(&resume, b"resume").unwrap();
        while child.try_wait().unwrap().is_none() {
            if Instant::now() >= deadline {
                child.kill().unwrap();
                child.wait().unwrap();
                panic!("backup exceeded bounded retry deadline");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let output = child.wait_with_output().unwrap();
        assert_eq!(
            fs::read(&temp).ok().as_deref(),
            Some(sentinel.as_slice()),
            "migration={migration}: competing file was deleted or modified"
        );
        assert_eq!(fs::read(&sidecar).unwrap(), b"competing sidecar");
        assert_eq!(
            output.status.code(),
            Some(5),
            "migration={migration}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(String::from_utf8_lossy(&output.stderr).contains("lock_timeout"));
        assert_eq!(fs::read_to_string(&steps).unwrap().lines().count(), 3);
        assert!(!out.exists());
        assert!(!fs::read_dir(db.parent().unwrap()).unwrap().any(|entry| {
            let name = entry.unwrap().file_name();
            let name = name.to_string_lossy();
            name.starts_with("TASKS.") && name.contains("pre-migrate-")
        }));
        let mut leftovers: Vec<_> = fs::read_dir(temp.parent().unwrap())
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| {
                path.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .contains("tasks-cli-tmp")
            })
            .collect();
        leftovers.sort();
        let mut competing = vec![temp, sidecar];
        competing.sort();
        assert_eq!(leftovers, competing, "only the competing files may remain");
        if migration {
            assert_eq!(
                Connection::open(&db)
                    .unwrap()
                    .query_row("PRAGMA user_version", [], |row| row.get::<_, i32>(0))
                    .unwrap(),
                8
            );
        }
    }
}
