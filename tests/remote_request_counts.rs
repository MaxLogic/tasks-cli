#![cfg(feature = "server")]
mod support;

use serde_json::{json, Value};
use std::time::Instant;
use support::remote_fixture::{ok, run, Fixture};

fn measured_run(root: &std::path::Path, args: &[&str]) -> std::process::Output {
    if let Some(binary) = std::env::var_os("TSK061_MEASURE_BINARY") {
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

fn use_gateway(f: &Fixture, gateway: &support::https::TlsFixture) -> Profile {
    let mut profile = config::load(&f.clients[0]).unwrap();
    let Profile::Remote {
        server_url,
        private_ca,
        ..
    } = &mut profile
    else {
        unreachable!()
    };
    *server_url = gateway.url();
    *private_ca = gateway.options().private_ca;
    config::save(&f.clients[0], &profile).unwrap();
    profile
}

#[test]
fn missing_capabilities_refuse_mutations_and_sources_and_filter_viewer_info() {
    use support::https::{Reply, TlsFixture};
    let f = Fixture::new();
    let profile = config::load(&f.clients[0]).unwrap();
    let Profile::Remote { server_id, .. } = profile else {
        unreachable!()
    };
    let project = f.project().to_string();
    let viewer = ok(run(&f.clients[0], &["viewer", "info"]));
    let body = f.body("must not be sent");
    for capabilities in [None, Some(json!([])), Some(json!(["attachments-v1"]))] {
        let mut info = json!({"protocol_version":1,"server_id":server_id,"ready":true});
        if let Some(capabilities) = capabilities {
            info["capabilities"] = capabilities;
        }
        let gateway = TlsFixture::new(
            "localhost",
            false,
            Reply::JsonRoutes(vec![
                ("/v1/info".into(), info),
                ("/v1/viewer/info".into(), json!({"output":viewer,"text":""})),
            ]),
        );
        use_gateway(&f, &gateway);
        let before = gateway.requests();
        let output = run(
            &f.clients[0],
            &[
                "--project",
                &project,
                "create",
                "--title",
                "unsafe",
                "--body-file",
                body.to_str().unwrap(),
            ],
        );
        assert_eq!(output.status.code(), Some(5));
        let error: Value = serde_json::from_slice(&output.stderr).unwrap();
        assert_eq!(error["error"]["code"], "remote_protocol");
        assert_eq!(
            gateway.requests() - before,
            1,
            "no mutation may reach a receipt-less server"
        );
        assert!(PendingStore::new(&f.clients[0])
            .unwrap()
            .list()
            .unwrap()
            .is_empty());
        if info_has_attachments(&f) {
            let before = gateway.requests();
            let output = run(
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
            );
            assert_eq!(output.status.code(), Some(5));
            let error: Value = serde_json::from_slice(&output.stderr).unwrap();
            assert_eq!(error["error"]["code"], "remote_protocol");
            assert_eq!(
                gateway.requests(),
                before,
                "cached attachment support must not bypass the separate receipt gate"
            );
            assert!(PendingStore::new(&f.clients[0])
                .unwrap()
                .list()
                .unwrap()
                .is_empty());
            continue;
        }
        for (index, command) in [
            vec![
                "attachment",
                "add",
                "1",
                "--expect-version",
                "1",
                "--file",
                "deliberately-absent.txt",
            ],
            vec!["attachment", "list", "1"],
            vec!["attachment", "get", "1", "A1"],
            vec!["attachment", "detach", "1", "A1", "--expect-version", "1"],
            vec!["attachment", "clipboard"],
        ]
        .into_iter()
        .enumerate()
        {
            let before = gateway.requests();
            let args = [vec!["--project", &project], command].concat();
            let output = run(&f.clients[0], &args);
            assert_eq!(output.status.code(), Some(5));
            let error: Value = serde_json::from_slice(&output.stderr).unwrap();
            assert_eq!(error["error"]["code"], "remote_capability");
            // The first refusal uses viewer-info's discovery. Every refusal
            // invalidates it, so each later command probes exactly once.
            assert_eq!(gateway.requests() - before, usize::from(index > 0));
        }
    }
}

fn info_has_attachments(f: &Fixture) -> bool {
    let info = ok(run(&f.clients[0], &["viewer", "info"]));
    let operations = info["data"]["operations"].as_array().unwrap();
    let present = operations.iter().any(|v| v == "attachment-add");
    assert_eq!(
        operations
            .iter()
            .filter(|v| v.as_str().unwrap().starts_with("attachment-"))
            .count(),
        if present { 4 } else { 0 }
    );
    present
}

#[test]
fn expired_corrupt_or_future_discovery_is_refreshed_and_errors_invalidate_it() {
    let f = Fixture::new();
    let project = f.project().to_string();
    let cache = f.clients[0].join("client/capabilities.json");
    let original = std::fs::read(&cache).unwrap();
    for timestamp in [0, u64::MAX] {
        let mut record: Value = serde_json::from_slice(&original).unwrap();
        record["checked_at"] = json!({"secs":timestamp,"nanos":0});
        std::fs::write(&cache, serde_json::to_vec(&record).unwrap()).unwrap();
        let before = f.gateway.requests();
        ok(run(&f.clients[0], &["viewer", "info"]));
        assert_eq!(f.gateway.requests() - before, 2);
    }
    std::fs::write(&cache, b"{broken").unwrap();
    let before = f.gateway.requests();
    ok(run(&f.clients[0], &["viewer", "info"]));
    assert_eq!(f.gateway.requests() - before, 2);
    let mut malformed: Value = serde_json::from_slice(&original).unwrap();
    malformed["info"]["protocol_version"] = json!(2);
    std::fs::write(&cache, serde_json::to_vec(&malformed).unwrap()).unwrap();
    let before = f.gateway.requests();
    ok(run(&f.clients[0], &["viewer", "info"]));
    assert_eq!(f.gateway.requests() - before, 2);
    let failure = run(&f.clients[0], &["--project", &project, "show", "999"]);
    assert_eq!(failure.status.code(), Some(3));
    assert!(!cache.exists());
    let before = f.gateway.requests();
    ok(run(&f.clients[0], &["viewer", "info"]));
    assert_eq!(f.gateway.requests() - before, 2);
    let before = f.gateway.requests();
    ok(run(&f.clients[0], &["viewer", "info"]));
    assert_eq!(f.gateway.requests() - before, 1);

    // A cold binary mutation discovers both capabilities with one probe.
    let body = f.body("cold source");
    ok(run(
        &f.clients[0],
        &[
            "--project",
            &project,
            "create",
            "--title",
            "cold",
            "--body-file",
            body.to_str().unwrap(),
        ],
    ));
    std::fs::remove_file(&cache).unwrap();
    let before = f.gateway.requests();
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
    assert_eq!(f.gateway.requests() - before, 2);
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
    // The refusal invalidated discovery. This retry must still perform both
    // discovery and correct-key resolution, then detach the original version.
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
    assert_eq!(f.gateway.requests() - before, 3);
}

// Run with --release -- --nocapture for subprocess wall times, including startup.
#[test]
fn remote_commands_reuse_capabilities_without_redundant_signed_requests() {
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
        // Each sample measures a warm profile; setup is outside the timed region.
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
                "TSK061 sample={sample} command={name} requests={count} elapsed_ms={elapsed:.3}"
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
        [1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 1, 1, 1, 1].repeat(samples)
    );
}
