#![cfg(feature = "server")]
mod support;
use serde_json::{json, Value};
use std::sync::atomic::Ordering;
use support::remote_fixture::{command, ok, run, Fixture};
use tasks_cli::remote::pending::PendingStore;

#[test]
fn intermediary_json_error_after_commit_keeps_the_original_recovery_request() {
    let f = Fixture::new();
    let project = f.project();
    let id = project.to_string();
    let body = f.body("exact");
    f.substitute_write.store(true, Ordering::SeqCst);
    let response = run(
        &f.clients[0],
        &[
            "--project",
            &id,
            "create",
            "--title",
            "once",
            "--body-file",
            body.to_str().unwrap(),
        ],
    );
    assert_eq!(response.status.code(), Some(5));
    let error: Value = serde_json::from_slice(&response.stderr).unwrap();
    assert_eq!(error["error"]["code"], "unknown_write_outcome");
    let receipt = error["error"]["request_id"].as_str().unwrap();
    assert_eq!(
        PendingStore::new(&f.clients[0])
            .unwrap()
            .list()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        ok(run(&f.clients[0], &["remote", "reconcile", receipt]))["data"]["id"],
        1
    );
}

#[test]
fn two_clients_share_state_versions_errors_and_registered_attribution() {
    let f = Fixture::new();
    let project = f.project();
    let id = project.to_string();
    let workspace = f.root.path().join("workspace");
    let repeated = ok(run(
        &f.clients[0],
        &[
            "init",
            "--root",
            workspace.to_str().unwrap(),
            "--key",
            "FIX",
        ],
    ));
    assert_eq!(repeated["project_id"], id);
    // Registry routing remains authoritative after an identity file is lost.
    std::fs::remove_file(workspace.join(".tasks.json")).unwrap();
    let registry_only = ok(run(
        &f.clients[0],
        &[
            "init",
            "--root",
            workspace.to_str().unwrap(),
            "--key",
            "FIX",
        ],
    ));
    assert_eq!(registry_only["project_id"], id);
    let body = f.body("complete ĂŽÂ©\r\nbody");
    let created = ok(run(
        &f.clients[0],
        &[
            "--project",
            &id,
            "create",
            "--title",
            "first",
            "--body-file",
            body.to_str().unwrap(),
            "--status",
            "todo",
        ],
    ));
    assert_eq!(created["data"]["display_id"], "FIX-001");
    let shown = ok(run(&f.clients[1], &["--project", &id, "show", "FIX-001"]));
    assert_eq!(shown["data"]["body"], "complete ĂŽÂ©\r\nbody");
    let routed = ok(
        command(&f.clients[1], &["--project", &id, "show", "FIX-001"])
            .env("TASKS_WINDOWS_EXE", "deliberately-missing-backend.exe")
            .output()
            .unwrap(),
    );
    assert_eq!(routed["data"]["id"], 1);
    let local = f.root.path().join("unconfigured-local");
    std::fs::create_dir(&local).unwrap();
    let before = f.gateway.requests();
    assert_eq!(
        run(&local, &["--project", &id, "show", "FIX-001"])
            .status
            .code(),
        Some(3)
    );
    assert_eq!(f.gateway.requests(), before);
    ok(run(
        &f.clients[1],
        &[
            "--project",
            &id,
            "update",
            "FIX-001",
            "--expect-version",
            "1",
            "--title",
            "changed",
        ],
    ));
    let stale = run(
        &f.clients[0],
        &[
            "--project",
            &id,
            "update",
            "FIX-001",
            "--expect-version",
            "1",
            "--title",
            "stale",
        ],
    );
    assert_eq!(stale.status.code(), Some(4));
    assert_eq!(
        serde_json::from_slice::<Value>(&stale.stderr).unwrap()["error"]["conflict"],
        json!({"expected":1,"current":2})
    );
    let history = ok(run(
        &f.clients[0],
        &["--project", &id, "history", "FIX-001", "--event", "2"],
    ));
    assert_eq!(
        history["data"]["items"][0]["attribution"]["actor_authority"],
        "credential"
    );
    assert!(PendingStore::new(&f.clients[0])
        .unwrap()
        .list()
        .unwrap()
        .is_empty());
    assert!(PendingStore::new(&f.clients[1])
        .unwrap()
        .list()
        .unwrap()
        .is_empty());
}

#[test]
fn committed_response_loss_retains_one_request_and_reconciliation_never_rebases() {
    let f = Fixture::new();
    let project = f.project();
    let id = project.to_string();
    let body = f.body("exact");
    f.drop_write.store(true, Ordering::SeqCst);
    let unknown = run(
        &f.clients[0],
        &[
            "--project",
            &id,
            "create",
            "--title",
            "once",
            "--body-file",
            body.to_str().unwrap(),
        ],
    );
    assert_eq!(unknown.status.code(), Some(5));
    let error: Value = serde_json::from_slice(&unknown.stderr).unwrap();
    assert_eq!(error["error"]["code"], "unknown_write_outcome");
    let receipt = error["error"]["request_id"].as_str().unwrap();
    let blocked = run(
        &f.clients[0],
        &[
            "--project",
            &id,
            "create",
            "--title",
            "second",
            "--body-file",
            body.to_str().unwrap(),
        ],
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&blocked.stderr).unwrap()["error"]["code"],
        "pending_write"
    );
    let recovered = ok(run(&f.clients[0], &["remote", "reconcile", receipt]));
    assert_eq!(recovered["data"]["id"], 1);
    let database =
        tasks_cli::store::Store::open_readonly(&f.root.path().join("server"), &id).unwrap();
    assert_eq!(
        database
            .conn
            .query_row("SELECT count(*) FROM tasks", [], |row| row.get::<_, u64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        database
            .conn
            .query_row(
                "SELECT count(*) FROM events WHERE entity_type='task'",
                [],
                |row| row.get::<_, u64>(0)
            )
            .unwrap(),
        1
    );
    assert!(PendingStore::new(&f.clients[0])
        .unwrap()
        .list()
        .unwrap()
        .is_empty());
    drop(database);
    f.drop_write.store(true, Ordering::SeqCst);
    let lost = run(
        &f.clients[0],
        &[
            "--project",
            &id,
            "update",
            "FIX-001",
            "--expect-version",
            "1",
            "--title",
            "original update",
        ],
    );
    let lost: Value = serde_json::from_slice(&lost.stderr).unwrap();
    let request = lost["error"]["request_id"].as_str().unwrap();
    ok(run(
        &f.clients[1],
        &[
            "--project",
            &id,
            "update",
            "FIX-001",
            "--expect-version",
            "2",
            "--title",
            "later external update",
        ],
    ));
    let replay = ok(run(&f.clients[0], &["remote", "reconcile", request]));
    assert_eq!(replay["data"]["version"], 2);
    let current = ok(run(&f.clients[0], &["--project", &id, "show", "FIX-001"]));
    assert_eq!(current["data"]["version"], 3);
    assert_eq!(current["data"]["title"], "later external update");
}

#[test]
fn outage_and_unsupported_maintenance_never_open_poisoned_local_sqlite() {
    let f = Fixture::new();
    let project = f.project();
    let id = project.to_string();
    let poison = f.clients[0].join("projects").join(&id);
    std::fs::create_dir_all(&poison).unwrap();
    let path = poison.join("TASKS.sqlite");
    std::fs::write(&path, b"poisoned leftover; never SQLite").unwrap();
    let unsupported = run(
        &f.clients[0],
        &[
            "--project",
            &id,
            "import",
            "--file",
            "missing-do-not-open.md",
        ],
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&unsupported.stderr).unwrap()["error"]["code"],
        "unsupported_remote_operation"
    );
    let mut profile = tasks_cli::remote::config::load(&f.clients[0]).unwrap();
    let tasks_cli::remote::config::Profile::Remote { server_url, .. } = &mut profile else {
        panic!()
    };
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    *server_url = format!("https://localhost:{port}");
    tasks_cli::remote::config::save(&f.clients[0], &profile).unwrap();
    let unavailable = run(&f.clients[0], &["--project", &id, "show", "FIX-001"]);
    assert_eq!(unavailable.status.code(), Some(5));
    assert_eq!(
        serde_json::from_slice::<Value>(&unavailable.stderr).unwrap()["error"]["code"],
        "service_unavailable"
    );
    assert_eq!(
        std::fs::read(path).unwrap(),
        b"poisoned leftover; never SQLite"
    );
    assert_eq!(std::fs::read_dir(poison).unwrap().count(), 1);
}

#[test]
fn complete_export_publishes_once_and_interrupted_export_publishes_nothing() {
    let f = Fixture::new();
    let project = f.project();
    let id = project.to_string();
    let body = f.body(&"x".repeat(64 * 1024));
    ok(run(
        &f.clients[0],
        &[
            "--project",
            &id,
            "create",
            "--title",
            "export",
            "--body-file",
            body.to_str().unwrap(),
        ],
    ));
    let out = f.root.path().join("complete.md");
    ok(run(
        &f.clients[0],
        &["--project", &id, "export", "--out", out.to_str().unwrap()],
    ));
    let expected = std::fs::read(&out).unwrap();
    assert!(expected.len() > 64 * 1024);
    assert_eq!(
        run(
            &f.clients[0],
            &["--project", &id, "export", "--out", out.to_str().unwrap()]
        )
        .status
        .code(),
        Some(2)
    );
    assert_eq!(std::fs::read(&out).unwrap(), expected);
    let interrupted = f.root.path().join("interrupted.md");
    f.truncate_export.store(true, Ordering::SeqCst);
    assert_eq!(
        run(
            &f.clients[0],
            &[
                "--project",
                &id,
                "export",
                "--out",
                interrupted.to_str().unwrap()
            ]
        )
        .status
        .code(),
        Some(5)
    );
    assert!(!interrupted.exists());
    assert!(!std::fs::read_dir(f.root.path()).unwrap().any(|entry| entry
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with(".tasks-export-")));
}

#[cfg(unix)]
#[test]
fn export_refuses_a_directory_where_another_user_can_replace_entries() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    let id = f.project().to_string();
    let directory = f.root.path().join("shared-export");
    std::fs::create_dir(&directory).unwrap();
    std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o777)).unwrap();
    let out = directory.join("result.md");
    assert!(!run(
        &f.clients[0],
        &["--project", &id, "export", "--out", out.to_str().unwrap()]
    )
    .status
    .success());
    assert!(!out.exists());
}

#[test]
fn enrichment_uses_batched_remote_titles_and_preserves_local_text_rules() {
    let f = Fixture::new();
    let project = f.project();
    let id = project.to_string();
    let body = f.body("private body");
    ok(run(
        &f.clients[0],
        &[
            "--project",
            &id,
            "create",
            "--title",
            "Title ĂŽÂ©",
            "--body-file",
            body.to_str().unwrap(),
        ],
    ));
    let foreign_workspace = f.root.path().join("foreign");
    std::fs::create_dir(&foreign_workspace).unwrap();
    let foreign = ok(run(
        &f.clients[0],
        &[
            "init",
            "--root",
            foreign_workspace.to_str().unwrap(),
            "--key",
            "OTH",
        ],
    ));
    ok(run(
        &f.clients[0],
        &[
            "--project",
            foreign["project_id"].as_str().unwrap(),
            "create",
            "--title",
            "Foreign",
            "--body-file",
            body.to_str().unwrap(),
        ],
    ));
    let input = f.root.path().join("text.txt");
    std::fs::write(
        &input,
        "FIX-001 T-1 FIX-999 OTH-001 OTH-999 UTF-8 https://example.test/FIX-001\r\n",
    )
    .unwrap();
    let before = f.gateway.requests();
    let result = ok(run(
        &f.clients[1],
        &[
            "--project",
            &id,
            "enrich",
            "--file",
            input.to_str().unwrap(),
        ],
    ));
    assert_eq!(
        result["data"]["text"],
        "FIX-001 (Title ĂŽÂ©) T-1 (Title ĂŽÂ©) FIX-999 OTH-001 (Foreign) OTH-999 UTF-8 https://example.test/FIX-001\r\n"
    );
    assert_eq!(
        result["data"]["unknown_refs"],
        json!(["FIX-999", "OTH-999"])
    );
    assert!(f.gateway.requests() - before <= 2);
}
