#![cfg(feature = "server")]
mod support;

use serde_json::Value;
use std::{
    fs,
    net::{SocketAddr, TcpListener, TcpStream},
    path::{Path, PathBuf},
    process::{Child, Stdio},
    time::{Duration, Instant},
};
use support::{
    https::{Reply, TlsFixture, FIXTURE_IO_TIMEOUT},
    remote_fixture::{ok, run},
};

struct Server(Child);
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        self.0.wait().unwrap();
    }
}

fn server_binary() -> PathBuf {
    // An explicit local historical binary verifies compatibility without
    // contacting any deployed service or changing the Cargo-selected client.
    std::env::var_os("TASKS_TEST_SERVER_EXE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_BIN_EXE_tasks-server")))
}

fn admin(root: &Path, args: &[&str]) -> Value {
    ok(support::process::command(server_binary())
        .args(["--data-root", root.to_str().unwrap(), "admin"])
        .args(args)
        .output()
        .unwrap())
}

fn round_trip(omit_empty_get_length: bool) {
    let root = tempfile::tempdir().unwrap();
    let server_root = root.path().join("server");
    let client = root.path().join("client");
    let keys = client.join("client");
    fs::create_dir(&client).unwrap();
    let init = admin(&server_root, &["init"]);
    let enrollment = ok(run(
        &client,
        &["remote", "keygen", "--directory", keys.to_str().unwrap()],
    ));
    let registration = root.path().join("registration.json");
    fs::write(&registration, serde_json::to_vec(&enrollment).unwrap()).unwrap();
    let registered = admin(
        &server_root,
        &[
            "register",
            "--registration-file",
            registration.to_str().unwrap(),
        ],
    );
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address: SocketAddr = listener.local_addr().unwrap();
    drop(listener);
    let mut server = Server(
        support::process::command(server_binary())
            .args([
                "--data-root",
                server_root.to_str().unwrap(),
                "serve",
                "--listen",
                &address.to_string(),
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::from(
                fs::File::create(root.path().join("server.log")).unwrap(),
            ))
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + FIXTURE_IO_TIMEOUT;
    loop {
        assert!(
            server.0.try_wait().unwrap().is_none(),
            "server exited before readiness"
        );
        if TcpStream::connect_timeout(&address, Duration::from_millis(100)).is_ok() {
            break;
        }
        assert!(Instant::now() < deadline, "server readiness deadline");
        std::thread::sleep(Duration::from_millis(10));
    }
    let gateway = TlsFixture::new(
        "localhost",
        false,
        if omit_empty_get_length {
            Reply::ProxyWithoutEmptyGetLength(address)
        } else {
            Reply::Proxy(address)
        },
    );
    ok(run(
        &client,
        &[
            "remote",
            "configure",
            "--server-url",
            &gateway.url(),
            "--server-id",
            init["server_id"].as_str().unwrap(),
            "--credential-id",
            registered["credential_id"].as_str().unwrap(),
            "--credential-file",
            keys.join("signing-key.pem").to_str().unwrap(),
            "--private-ca",
            gateway.options().private_ca.unwrap().to_str().unwrap(),
        ],
    ));
    let workspace = root.path().join("workspace");
    fs::create_dir(&workspace).unwrap();
    let project = ok(run(
        &client,
        &[
            "init",
            "--root",
            workspace.to_str().unwrap(),
            "--key",
            "FIX",
        ],
    ));
    let project = project["project_id"].as_str().unwrap();
    let bytes = b"PK\x03\x04signed binary round trip";
    let source = root.path().join("source.zip");
    fs::write(&source, bytes).unwrap();
    let body = root.path().join("body.txt");
    fs::write(&body, "synthetic task").unwrap();
    let call = |args: &[&str]| {
        let mut selected = vec!["--project", project];
        selected.extend_from_slice(args);
        ok(run(&client, &selected))
    };
    call(&[
        "create",
        "--title",
        "Synthetic attachment",
        "--body-file",
        body.to_str().unwrap(),
    ]);
    assert_eq!(
        call(&[
            "attachment",
            "add",
            "FIX-001",
            "--expect-version",
            "1",
            "--file",
            source.to_str().unwrap()
        ])["data"]["version"],
        2
    );
    let list = call(&["attachment", "list", "FIX-001"]);
    assert_eq!(list["data"]["items"].as_array().unwrap().len(), 1);
    // Viewer View uses the cached path; Save as supplies --out. Exercise both
    // CLI contracts, including exact bytes and the structured path response.
    for out in [None, Some(root.path().join("saved.zip"))] {
        let mut args = vec!["attachment", "get", "FIX-001", "A1"];
        if let Some(path) = &out {
            args.extend(["--out", path.to_str().unwrap()]);
        }
        let downloaded = call(&args);
        assert_eq!(downloaded["data"]["command"], "attachment_get");
        let path = downloaded["data"]["items"][0]["path"].as_str().unwrap();
        assert_eq!(fs::read(path).unwrap(), bytes);
        if let Some(out) = out {
            assert_eq!(fs::read(out).unwrap(), bytes);
        }
    }
    assert_eq!(
        call(&[
            "attachment",
            "detach",
            "FIX-001",
            "A1",
            "--expect-version",
            "2"
        ])["data"]["version"],
        3
    );
    assert!(call(&["attachment", "list", "FIX-001"])["data"]["items"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn real_binaries_attach_list_get_detach() {
    round_trip(false);
}

#[test]
fn real_binaries_get_survives_gateway_omitting_empty_content_length() {
    round_trip(true);
}
