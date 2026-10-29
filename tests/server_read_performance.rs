//! Opt-in release measurement through the real server and signed CLI, using
//! synthetic stores only. No latency assertions on shared development hosts.
#![cfg(feature = "server")]
mod support;

use serde_json::{json, Value};
use std::{io::Write, path::Path, process::Child, time::Instant};
use support::{
    https::{Reply, TlsFixture},
    remote_fixture::{ok, run},
};
use tasks_cli::server::{OwnedServer, Registration};

struct ServerProcess(Child);
impl Drop for ServerProcess {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
#[ignore = "release benchmark: set TASKS_READ_EVIDENCE to a unique evidence directory"]
fn signed_read_phases() {
    let evidence = std::env::var_os("TASKS_READ_EVIDENCE").expect("TASKS_READ_EVIDENCE");
    let evidence = Path::new(&evidence);
    std::fs::create_dir(evidence).unwrap();
    let root = tempfile::tempdir().unwrap();
    let server_root = root.path().join("server");
    let client = root.path().join("client");
    std::fs::create_dir(&client).unwrap();
    let public = ok(run(
        &client,
        &[
            "remote",
            "keygen",
            "--directory",
            client.join("client").to_str().unwrap(),
        ],
    ));
    let server = OwnedServer::initialize(&server_root).unwrap();
    let server_id = server.server_id().to_string();
    let credential = server
        .register(&serde_json::from_value::<Registration>(public).unwrap())
        .unwrap()
        .to_string();
    drop(server);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let server_binary = std::env::var_os("TASKS_READ_SERVER")
        .unwrap_or_else(|| env!("CARGO_BIN_EXE_tasks-server").into());
    let mut command = support::process::command(server_binary);
    command
        .args([
            "--data-root",
            server_root.to_str().unwrap(),
            "serve",
            "--listen",
            &address.to_string(),
        ])
        .stderr(std::fs::File::create(evidence.join("server.jsonl")).unwrap())
        .stdout(std::process::Stdio::null());
    let mut process = ServerProcess(command.spawn().unwrap());
    std::fs::write(evidence.join("server-pid.txt"), process.0.id().to_string()).unwrap();
    let deadline = Instant::now() + std::time::Duration::from_secs(10);
    while std::net::TcpStream::connect(address).is_err() {
        assert!(
            process.0.try_wait().unwrap().is_none(),
            "server exited during startup"
        );
        assert!(Instant::now() < deadline, "server startup deadline");
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let gateway = TlsFixture::new("localhost", false, Reply::Proxy(address));
    ok(run(
        &client,
        &[
            "remote",
            "configure",
            "--server-url",
            &gateway.url(),
            "--server-id",
            &server_id,
            "--credential-id",
            &credential,
            "--credential-file",
            client.join("client/signing-key.pem").to_str().unwrap(),
            "--private-ca",
            gateway.options().private_ca.unwrap().to_str().unwrap(),
        ],
    ));
    let workspace = root.path().join("workspace");
    std::fs::create_dir(&workspace).unwrap();
    let project = ok(run(
        &client,
        &[
            "init",
            "--root",
            workspace.to_str().unwrap(),
            "--key",
            "PERF",
        ],
    ))["project_id"]
        .as_str()
        .unwrap()
        .to_string();
    let body = root.path().join("body.txt");
    std::fs::write(
        &body,
        "Synthetic task body for signed server reads.\n".repeat(48),
    )
    .unwrap();
    for index in 1..=48 {
        ok(run(
            &client,
            &[
                "--project",
                &project,
                "create",
                "--title",
                &format!("Task {index:02}"),
                "--body-file",
                body.to_str().unwrap(),
            ],
        ));
    }
    for task in ["1", "2", "3", "4"] {
        ok(run(
            &client,
            &[
                "--project",
                &project,
                "attachment",
                "add",
                task,
                "--expect-version",
                "1",
                "--file",
                body.to_str().unwrap(),
            ],
        ));
    }
    let mut samples = std::fs::File::create(evidence.join("cli.jsonl")).unwrap();
    for (name, args) in [
        ("show", vec!["show", "48"]),
        ("attachment_empty", vec!["attachment", "list", "48"]),
        ("attachment_present", vec!["attachment", "list", "1"]),
    ] {
        let mut expected: Option<Value> = None;
        for sample in 0..55 {
            let started = Instant::now();
            let result = ok(run(
                &client,
                &[vec!["--project", &project], args.clone()].concat(),
            ));
            let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;
            if let Some(expected) = &expected {
                assert_eq!(&result, expected, "read output changed");
            } else {
                expected = Some(result);
            }
            writeln!(
                samples,
                "{}",
                json!({"case":name,"sample":sample,"warmup":sample<5,"elapsed_ms":elapsed_ms})
            )
            .unwrap();
        }
        std::fs::write(
            evidence.join(format!("{name}.json")),
            serde_json::to_vec_pretty(&expected.unwrap()).unwrap(),
        )
        .unwrap();
    }
    drop(gateway);
    drop(process);
    std::fs::write(evidence.join("fixture.json"), json!({"tasks":48,"attachments":4,"body_bytes":std::fs::metadata(body).unwrap().len(),"project_id":project,"server_id":server_id}).to_string()).unwrap();
}
