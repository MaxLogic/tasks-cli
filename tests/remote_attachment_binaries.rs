#![cfg(feature = "server")]
mod support;

use serde_json::Value;
use std::{
    fs,
    net::{SocketAddr, TcpListener, TcpStream},
    path::{Path, PathBuf},
    process::{Child, Output, Stdio},
    time::{Duration, Instant},
};
use support::{
    https::{Reply, TlsFixture, FIXTURE_IO_TIMEOUT},
    remote_fixture::ok,
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

fn admin(binary: &Path, root: &Path, args: &[&str]) -> Value {
    ok(support::process::command(binary)
        .args(["--data-root", root.to_str().unwrap(), "admin"])
        .args(args)
        .output()
        .unwrap())
}

fn run(binary: &Path, root: &Path, args: &[&str]) -> Output {
    support::process::command(binary)
        .args(["--data-root", root.to_str().unwrap(), "--format", "json"])
        .args(args)
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .env_remove("TASKS_DELEGATED")
        .env_remove("TASKS_ORIGIN_CONTEXT")
        .env("TASKS_CLIENT_DIR", root.join("client"))
        .output()
        .unwrap()
}

fn round_trip(
    server_exe: &Path,
    client_exe: &Path,
    omit_empty_get_length: bool,
    refuse_new_operations: bool,
) {
    let root = support::temp::TempDir::new();
    let server_root = root.path().join("server");
    let client = root.path().join("client");
    let keys = client.join("client");
    fs::create_dir(&client).unwrap();
    let init = admin(server_exe, &server_root, &["init"]);
    let enrollment = ok(run(
        client_exe,
        &client,
        &["remote", "keygen", "--directory", keys.to_str().unwrap()],
    ));
    let registration = root.path().join("registration.json");
    fs::write(&registration, serde_json::to_vec(&enrollment).unwrap()).unwrap();
    let registered = admin(
        server_exe,
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
        support::process::command(server_exe)
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
        client_exe,
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
        client_exe,
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
    let raw = |args: &[&str]| {
        let mut selected = vec!["--project", project];
        selected.extend_from_slice(args);
        run(client_exe, &client, &selected)
    };
    let call = |args: &[&str]| ok(raw(args));
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
    if refuse_new_operations {
        let history = call(&["history", "FIX-001"]);
        let task = call(&["show", "FIX-001"]);
        let refusal = |args: &[&str]| {
            let output = raw(args);
            let error: Value = serde_json::from_slice(&output.stderr).unwrap();
            assert_eq!(output.status.code(), Some(2), "{error}");
            assert_eq!(error["error"]["code"], "validation", "{error}");
            eprintln!("old server refused {args:?}: {error}");
        };
        for out in [None, Some(root.path().join("saved.zip"))] {
            let destination = out.clone().unwrap_or_else(|| {
                client.join(format!("cache/attachments/{project}/A1/source.zip"))
            });
            for overwrite in [false, true] {
                if overwrite {
                    fs::create_dir_all(destination.parent().unwrap()).unwrap();
                    fs::write(&destination, b"preserve original file").unwrap();
                }
                let mut args = vec!["attachment", "get", "FIX-001", "A1"];
                if let Some(out) = &out {
                    args.extend(["--out", out.to_str().unwrap()]);
                }
                if overwrite {
                    args.push("--overwrite");
                }
                refusal(&args);
                if overwrite {
                    assert_eq!(fs::read(&destination).unwrap(), b"preserve original file");
                    fs::remove_file(&destination).unwrap();
                } else {
                    assert!(!destination.exists());
                }
            }
        }
        for reference in ["FIX-001", "OTHER-001"] {
            refusal(&[
                "attachment",
                "detach",
                reference,
                "A1",
                "--expect-version",
                "2",
            ]);
            assert_eq!(call(&["attachment", "list", "FIX-001"]), list);
            assert_eq!(call(&["history", "FIX-001"]), history);
            assert_eq!(call(&["show", "FIX-001"]), task);
        }
        eprintln!("new client / old server: get refuses without publication or replacement; keyed detach refuses without task, history or attachment mutation");
        return;
    }
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
    eprintln!(
        "client={} server={}: list, cached get, Save as and keyed detach passed",
        client_exe.display(),
        server_exe.display()
    );
}

#[test]
fn real_binaries_attach_list_get_detach() {
    round_trip(
        &server_binary(),
        Path::new(env!("CARGO_BIN_EXE_tasks")),
        false,
        false,
    );
}

#[test]
fn real_binaries_get_survives_gateway_omitting_empty_content_length() {
    round_trip(
        &server_binary(),
        Path::new(env!("CARGO_BIN_EXE_tasks")),
        true,
        false,
    );
}

// The retained rollout script exports/builds 393d8f3 outside the worktree and
// supplies these paths. Ordinary suites do not depend on historical builds.
#[test]
#[ignore = "requires TASKS_PROTOCOL2_BASE_CLIENT built from 393d8f3"]
fn protocol2_rollout_old_client_new_server() {
    let old =
        PathBuf::from(std::env::var_os("TASKS_PROTOCOL2_BASE_CLIENT").expect("base client path"));
    round_trip(
        Path::new(env!("CARGO_BIN_EXE_tasks-server")),
        &old,
        false,
        false,
    );
}

#[test]
#[ignore = "requires TASKS_PROTOCOL2_BASE_SERVER built from 393d8f3"]
fn protocol2_rollout_new_client_old_server_refuses_without_side_effects() {
    let old =
        PathBuf::from(std::env::var_os("TASKS_PROTOCOL2_BASE_SERVER").expect("base server path"));
    round_trip(&old, Path::new(env!("CARGO_BIN_EXE_tasks")), false, true);
}
