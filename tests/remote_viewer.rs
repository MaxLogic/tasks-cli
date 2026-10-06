#![cfg(feature = "server")]
mod support;
use serde_json::{json, Value};
use std::{io::Write, path::Path, process::Stdio, sync::atomic::Ordering};
use support::remote_fixture::{command, ok, run, Fixture};
use uuid::Uuid;
fn request(root: &Path, args: &[&str], body: Value) -> std::process::Output {
    let mut child = command(root, args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("CODEX_THREAD_ID", "must-not-be-viewer-attribution")
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(&serde_json::to_vec(&body).unwrap())
        .unwrap();
    child.wait_with_output().unwrap()
}
fn create(f: &Fixture, project: &str, title: &str, deps: Option<&str>) -> Value {
    let body = f.body("complete body Ω");
    let mut args = vec![
        "--project",
        project,
        "create",
        "--title",
        title,
        "--body-file",
        body.to_str().unwrap(),
        "--status",
        "todo",
    ];
    if let Some(deps) = deps {
        args.extend(["--deps", deps]);
    }
    ok(run(&f.clients[0], &args))
}
#[test]
fn remote_viewer_catalog_paging_selection_history_and_attribution_keep_json_contracts() {
    let f = Fixture::new();
    let id = f.project().to_string();
    let info = ok(run(&f.clients[1], &["viewer", "info"]));
    assert_eq!(info["data"]["backend"], "remote");
    assert_eq!(info["data"]["receipt_recovery"], true);
    create(&f, &id, "first", None);
    create(&f, &id, "dependent", Some("FIX-001"));
    let catalog = ok(request(
        &f.clients[1],
        &["viewer", "projects", "--request-file", "-"],
        json!({"limit":1,"state":"all"}),
    ));
    assert_eq!(catalog["data"]["items"][0]["project_id"], id);
    assert_eq!(catalog["data"]["items"][0]["roots"], json!([]));
    let bound = ok(request(
        &f.clients[0],
        &["viewer", "projects", "--request-file", "-"],
        json!({"state":"all"}),
    ));
    assert_eq!(
        bound["data"]["items"][0]["roots"][0],
        f.root
            .path()
            .join("workspace")
            .canonicalize()
            .unwrap()
            .to_string_lossy()
            .as_ref()
    );
    let tasks = ok(request(
        &f.clients[1],
        &["--project", &id, "viewer", "tasks", "--request-file", "-"],
        json!({"limit":200,"statuses":["todo"]}),
    ));
    assert_eq!(tasks["data"]["total_count"], 2);
    assert_eq!(tasks["data"]["items"][1]["waiting_dependency_count"], 1);
    let shown = ok(run(
        &f.clients[1],
        &["--project", &id, "viewer", "show", "FIX-001"],
    ));
    assert_eq!(shown["data"]["body"], "complete body Ω");
    assert!(shown["data"]["created_ms"].is_number());
    let receipt = Uuid::new_v4().to_string();
    ok(request(
        &f.clients[1],
        &["--project", &id, "viewer", "update", "--request-file", "-"],
        json!({"id":1,"expect_version":1,"changes":{"title":"viewer change"},"request_id":receipt}),
    ));
    ok(run(&f.clients[1], &["viewer", "acknowledge", &receipt]));
    let history = ok(run(
        &f.clients[0],
        &["--project", &id, "history", "FIX-001", "--event", "3"],
    ));
    assert_eq!(
        history["data"]["items"][0]["attribution"]["harness"],
        "viewer"
    );
    assert!(history["data"]["items"][0]["attribution"]["session_id"].is_null());
}
#[test]
fn receipt_survives_lost_cli_ack_and_replay_precedes_a_later_external_edit() {
    let f = Fixture::new();
    let id = f.project().to_string();
    create(&f, &id, "first", None);
    let receipt = Uuid::new_v4().to_string();
    f.drop_write.store(true, Ordering::SeqCst);
    let lost = request(
        &f.clients[1],
        &["--project", &id, "viewer", "update", "--request-file", "-"],
        json!({"id":1,"expect_version":1,"changes":{"title":"original"},"request_id":receipt}),
    );
    assert_eq!(lost.status.code(), Some(5));
    assert!(
        run(&f.clients[1], &["viewer", "acknowledge", &receipt])
            .status
            .code()
            != Some(0)
    );
    ok(run(
        &f.clients[0],
        &[
            "--project",
            &id,
            "update",
            "FIX-001",
            "--expect-version",
            "2",
            "--title",
            "newer",
        ],
    ));
    let replay = ok(run(&f.clients[1], &["viewer", "reconcile", &receipt]));
    assert_eq!(replay["data"]["version"], 2);
    let recovery = ok(run(&f.clients[1], &["viewer", "recovery"]));
    assert_eq!(recovery["data"]["items"][0]["request_id"], receipt);
    assert_eq!(recovery["data"]["items"][0]["outcome_known"], true);
    ok(run(&f.clients[1], &["viewer", "acknowledge", &receipt]));
    let shown = ok(run(
        &f.clients[1],
        &["--project", &id, "viewer", "show", "1"],
    ));
    assert_eq!(shown["data"]["version"], 3);
    assert_eq!(shown["data"]["title"], "newer");
    // HTTP acknowledgement is known, but loss of the CLI stdout still leaves recovery evidence.
    let next = Uuid::new_v4().to_string();
    ok(request(
        &f.clients[1],
        &["--project", &id, "viewer", "update", "--request-file", "-"],
        json!({"id":1,"expect_version":3,"changes":{"title":"confirmed"},"request_id":next}),
    ));
    let pending = ok(run(&f.clients[1], &["viewer", "recovery"]));
    assert_eq!(pending["data"]["items"][0]["request_id"], next);
    ok(run(&f.clients[1], &["viewer", "acknowledge", &next]));
}
#[test]
fn blocked_completion_remains_refused_after_prerequisite_changes_and_archive_is_shared() {
    let f = Fixture::new();
    let id = f.project().to_string();
    create(&f, &id, "prerequisite", None);
    create(&f, &id, "dependent", Some("1"));
    let receipt = Uuid::new_v4().to_string();
    let refused = request(
        &f.clients[1],
        &["--project", &id, "viewer", "update", "--request-file", "-"],
        json!({"id":2,"expect_version":1,"changes":{"status":"done"},"request_id":receipt}),
    );
    assert_eq!(refused.status.code(), Some(2));
    let error: Value = serde_json::from_slice(&refused.stderr).unwrap();
    assert!(!error["error"]["open_prerequisites"]["prerequisites"]
        .as_array()
        .unwrap()
        .is_empty());
    ok(run(
        &f.clients[0],
        &[
            "--project",
            &id,
            "update",
            "1",
            "--expect-version",
            "1",
            "--status",
            "done",
        ],
    ));
    assert_eq!(
        run(&f.clients[1], &["viewer", "reconcile", &receipt])
            .status
            .code(),
        Some(2)
    );
    ok(run(&f.clients[1], &["viewer", "acknowledge", &receipt]));
    let archived = Uuid::new_v4().to_string();
    ok(run(
        &f.clients[1],
        &[
            "--project",
            &id,
            "viewer",
            "archive",
            "--request-id",
            &archived,
        ],
    ));
    ok(run(&f.clients[1], &["viewer", "acknowledge", &archived]));
    let catalog = ok(request(
        &f.clients[0],
        &["viewer", "projects", "--request-file", "-"],
        json!({"state":"archived"}),
    ));
    assert_eq!(catalog["data"]["total_count"], 1);
    ok(run(
        &f.clients[0],
        &[
            "--project",
            &id,
            "update",
            "2",
            "--expect-version",
            "1",
            "--title",
            "active again",
        ],
    ));
    assert_eq!(
        ok(request(
            &f.clients[1],
            &["viewer", "projects", "--request-file", "-"],
            json!({"state":"archived"})
        ))["data"]["total_count"],
        0
    );
}

#[test]
fn remote_pages_reject_stale_tokens_and_bound_client_roots_are_searchable() {
    let f = Fixture::new();
    let id = f.project().to_string();
    create(&f, &id, "first", None);
    create(&f, &id, "second", None);
    let page = ok(request(
        &f.clients[1],
        &["--project", &id, "viewer", "tasks", "--request-file", "-"],
        json!({"limit":1}),
    ));
    let token = page["data"]["snapshot"].clone();
    assert_eq!(page["data"]["has_more"], true);
    create(&f, &id, "third", None);
    let stale = request(
        &f.clients[1],
        &["--project", &id, "viewer", "tasks", "--request-file", "-"],
        json!({"limit":1,"offset":1,"snapshot":token}),
    );
    assert_ne!(stale.status.code(), Some(0));
    // Bound roots are canonical; a Windows temp path may use an 8.3 alias.
    let root_query = f.root.path().canonicalize().unwrap();
    let local = ok(request(
        &f.clients[0],
        &["viewer", "projects", "--request-file", "-"],
        json!({"query":root_query.to_string_lossy(),"state":"all"}),
    ));
    assert_eq!(local["data"]["total_count"], 1);
    let remote = ok(request(
        &f.clients[1],
        &["viewer", "projects", "--request-file", "-"],
        json!({"query":root_query.to_string_lossy(),"state":"all"}),
    ));
    assert_eq!(remote["data"]["total_count"], 0);
}

#[test]
fn offline_reads_never_fall_back_and_pending_ack_requires_matching_confirmation() {
    let f = Fixture::new();
    let id = f.project().to_string();
    create(&f, &id, "first", None);
    let receipt = Uuid::new_v4().to_string();
    f.drop_write.store(true, Ordering::SeqCst);
    let lost = request(
        &f.clients[1],
        &["--project", &id, "viewer", "update", "--request-file", "-"],
        json!({"id":1,"expect_version":1,"changes":{"title":"saved"},"request_id":receipt}),
    );
    assert_eq!(lost.status.code(), Some(5));
    let store = tasks_cli::remote::pending::PendingStore::new(&f.clients[1]).unwrap();
    let pending = store.load(Uuid::parse_str(&receipt).unwrap()).unwrap();
    assert!(store.confirmation(&pending).unwrap().is_none());
    assert!(
        run(&f.clients[1], &["viewer", "acknowledge", &receipt])
            .status
            .code()
            != Some(0)
    );
    let other = Uuid::new_v4().to_string();
    assert_ne!(
        run(&f.clients[1], &["viewer", "acknowledge", &other])
            .status
            .code(),
        Some(0)
    );
    assert_eq!(store.list().unwrap().len(), 1);
    drop(f.gateway);
    let local = f.clients[1].join("projects").join(&id);
    std::fs::create_dir_all(&local).unwrap();
    std::fs::write(local.join("TASKS.sqlite"), b"poison").unwrap();
    let read = run(&f.clients[1], &["--project", &id, "viewer", "show", "1"]);
    assert_eq!(read.status.code(), Some(5));
    assert_eq!(
        std::fs::read(local.join("TASKS.sqlite")).unwrap(),
        b"poison"
    );
    assert_eq!(store.list().unwrap().len(), 1);
}
