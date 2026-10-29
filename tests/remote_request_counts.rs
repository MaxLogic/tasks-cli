#![cfg(feature = "server")]
mod support;

use std::time::Instant;
use support::remote_fixture::{ok, run, Fixture};

fn measured_run(root: &std::path::Path, args: &[&str]) -> std::process::Output {
    if let Some(binary) = std::env::var_os("TSK062_MEASURE_BINARY") {
        support::process::command(binary)
            .args(["--data-root", root.to_str().unwrap(), "--format", "json"])
            .args(args)
            .env_remove("TASKS_WINDOWS_EXE")
            .env_remove("TASKS_PROJECT")
            .env("TASKS_CLIENT_DIR", root.join("client"))
            .output()
            .unwrap()
    } else {
        run(root, args)
    }
}
use tasks_cli::remote::{
    config::{self, Profile},
    pending::PendingStore,
};

#[test]
fn leftover_capability_cache_is_ignored_and_never_replaced() {
    let f = Fixture::new();
    let cache = f.clients[0].join("client/capabilities.json");
    assert!(!cache.exists(), "configure must not publish discovery");
    let bytes = b"{deliberately stale and malformed discovery}";
    std::fs::write(&cache, bytes).unwrap();
    let before = f.gateway.requests();
    ok(run(&f.clients[0], &["viewer", "info"]));
    assert_eq!(f.gateway.requests() - before, 1);
    assert_eq!(std::fs::read(&cache).unwrap(), bytes);
    let project = f.project().to_string();
    assert_eq!(
        run(&f.clients[0], &["--project", &project, "show", "999"])
            .status
            .code(),
        Some(3)
    );
    assert_eq!(std::fs::read(&cache).unwrap(), bytes);
}

#[test]
fn keyed_detach_still_validates_the_key_before_sending_a_numeric_mutation() {
    let f = Fixture::new();
    let project = f.project().to_string();
    let body = f.body("keyed detach");
    ok(run(
        &f.clients[0],
        &[
            "--project",
            &project,
            "create",
            "--title",
            "keyed",
            "--body-file",
            body.to_str().unwrap(),
        ],
    ));
    ok(run(
        &f.clients[0],
        &[
            "--project",
            &project,
            "attachment",
            "add",
            "1",
            "--expect-version",
            "1",
            "--file",
            body.to_str().unwrap(),
        ],
    ));
    let before = f.gateway.requests();
    let wrong = run(
        &f.clients[0],
        &[
            "--project",
            &project,
            "attachment",
            "detach",
            "OTHER-001",
            "A1",
            "--expect-version",
            "2",
        ],
    );
    assert_eq!(wrong.status.code(), Some(3));
    assert_eq!(f.gateway.requests() - before, 1);
    assert!(PendingStore::new(&f.clients[0])
        .unwrap()
        .list()
        .unwrap()
        .is_empty());
    // Key validation remains a safety request before the mutation.
    let before = f.gateway.requests();
    let detached = ok(run(
        &f.clients[0],
        &[
            "--project",
            &project,
            "attachment",
            "detach",
            "FIX-001",
            "A1",
            "--expect-version",
            "2",
        ],
    ));
    assert_eq!(detached["data"]["version"], 3);
    assert_eq!(f.gateway.requests() - before, 2);
}

// Run with --release -- --nocapture for subprocess wall times, including startup.
#[test]
fn remote_commands_send_only_operation_requests() {
    let f = Fixture::new();
    let project = f.project().to_string();
    let body = f.body("request-count fixture");
    let source = f.root.path().join("source.txt");
    std::fs::write(&source, b"attachment fixture").unwrap();
    let query = f.root.path().join("viewer-query.json");
    std::fs::write(&query, br#"{"limit":200,"statuses":["todo"]}"#).unwrap();
    let mut counts = Vec::new();
    let expected_viewer =
        tasks_cli::remote::client::RemoteClient::new(&config::load(&f.clients[0]).unwrap())
            .unwrap()
            .read(http::Method::GET, "/v1/viewer/info", b"")
            .unwrap()["output"]
            .clone();
    let samples = if cfg!(debug_assertions) { 1 } else { 7 };
    for sample in 0..samples {
        // Configure is the sole live info request; ordinary commands never discover.
        let Profile::Remote {
            server_url,
            server_id,
            credential_id,
            credential_file,
            private_ca,
            ..
        } = config::load(&f.clients[0]).unwrap()
        else {
            unreachable!()
        };
        let before_configure = f.gateway.requests();
        ok(run(
            &f.clients[0],
            &[
                "remote",
                "configure",
                "--server-url",
                &server_url,
                "--server-id",
                &server_id.to_string(),
                "--credential-id",
                &credential_id.to_string(),
                "--credential-file",
                credential_file.to_str().unwrap(),
                "--private-ca",
                private_ca.as_ref().unwrap().to_str().unwrap(),
            ],
        ));
        assert_eq!(f.gateway.requests() - before_configure, 1);
        // Old cache contents, including a directory that cannot be replaced,
        // cannot add a request or affect any operation.
        let cache = f.clients[0].join("client/capabilities.json");
        if !cache.exists() {
            std::fs::create_dir(&cache).unwrap();
        }
        let task = (sample + 1).to_string();
        let attachment = format!("A{}", sample + 1);
        let output = f.root.path().join(format!("download-{sample}.txt"));
        let cases = [
            (
                "create",
                vec![
                    "create",
                    "--title",
                    "fixture",
                    "--body-file",
                    body.to_str().unwrap(),
                ],
            ),
            ("list", vec!["list"]),
            ("show", vec!["show", &task]),
            (
                "update",
                vec![
                    "update",
                    &task,
                    "--expect-version",
                    "1",
                    "--title",
                    "changed",
                ],
            ),
            (
                "attachment-add",
                vec![
                    "attachment",
                    "add",
                    &task,
                    "--expect-version",
                    "2",
                    "--file",
                    source.to_str().unwrap(),
                ],
            ),
            ("attachment-list", vec!["attachment", "list", &task]),
            (
                "viewer-tasks-add",
                vec!["viewer", "tasks", "--request-file", query.to_str().unwrap()],
            ),
            ("viewer-show-add", vec!["viewer", "show", &task]),
            (
                "attachment-get",
                vec![
                    "attachment",
                    "get",
                    &task,
                    &attachment,
                    "--out",
                    output.to_str().unwrap(),
                ],
            ),
            (
                "attachment-view",
                vec!["attachment", "get", &task, &attachment],
            ),
            (
                "attachment-detach",
                vec![
                    "attachment",
                    "detach",
                    &task,
                    &attachment,
                    "--expect-version",
                    "3",
                ],
            ),
            (
                "viewer-tasks-detach",
                vec!["viewer", "tasks", "--request-file", query.to_str().unwrap()],
            ),
            ("viewer-show-detach", vec!["viewer", "show", &task]),
            ("viewer-info", vec!["viewer", "info"]),
        ];
        for (name, args) in cases {
            let before = f.gateway.requests();
            let started = Instant::now();
            let args = [vec!["--project", &project], args].concat();
            let value = ok(measured_run(&f.clients[0], &args));
            let elapsed = started.elapsed().as_secs_f64() * 1000.0;
            let count = f.gateway.requests() - before;
            println!(
                "TSK062 sample={sample} command={name} requests={count} elapsed_ms={elapsed:.3}"
            );
            assert_eq!(value["schema_version"], 1);
            if name == "attachment-add" || name == "attachment-detach" {
                assert_eq!(count, 1, "warm attachment write uses one signed request");
                let state = &value["data"]["attachment_state"];
                assert_eq!(state["has_more"], false);
                assert!(state["next_after"].is_null());
                assert!(state["updated_ms"].is_i64());
                let expected_count = usize::from(name == "attachment-add");
                assert_eq!(state["attachment_count"], expected_count);
                assert_eq!(state["items"].as_array().unwrap().len(), expected_count);
                if expected_count == 1 {
                    assert_eq!(state["items"][0]["name"], "source.txt");
                    assert!(state["items"][0]["detached_ms"].is_null());
                }
            }
            if name == "viewer-info" {
                assert_eq!(value, expected_viewer);
            }
            counts.push(count);
        }
        assert_eq!(std::fs::read(&output).unwrap(), b"attachment fixture");
    }
    assert_eq!(
        counts,
        // Single-file get/view retain metadata-before-download. Numeric
        // detach is one request; keyed detach's two are asserted separately.
        [1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 1, 1, 1, 1].repeat(samples)
    );
}
