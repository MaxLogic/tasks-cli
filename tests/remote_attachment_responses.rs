#![cfg(feature = "server")]
mod support;

use serde_json::{json, Value};
use std::{
    fs,
    io::{Read, Write},
    net::TcpListener,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread::{self, JoinHandle},
    time::Duration,
};
use support::{
    https::{Reply, TlsFixture, FIXTURE_IO_TIMEOUT},
    remote_fixture::{ok, run},
};
use tasks_cli::remote::config::{self, Profile};
use uuid::Uuid;

// Deliberately untrusted HTTP peer behind the normal TLS fixture. Production
// parsing, signed client requests, CLI errors and filesystem publication all run.
struct DownloadPeer {
    body: Arc<Mutex<Vec<u8>>>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
    gateway: TlsFixture,
}
impl DownloadPeer {
    fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        listener.set_nonblocking(true).unwrap();
        let body = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let (response, done) = (body.clone(), stop.clone());
        let worker = thread::spawn(move || {
            while !done.load(Ordering::SeqCst) {
                let (mut stream, _) = match listener.accept() {
                    Ok(connection) => connection,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                        continue;
                    }
                    Err(error) => panic!("download peer accept: {error}"),
                };
                // Windows may inherit the listener's nonblocking mode.
                stream.set_nonblocking(false).unwrap();
                stream.set_read_timeout(Some(FIXTURE_IO_TIMEOUT)).unwrap();
                stream.set_write_timeout(Some(FIXTURE_IO_TIMEOUT)).unwrap();
                let mut head = Vec::new();
                while !head.ends_with(b"\r\n\r\n") {
                    assert!(head.len() < 16 * 1024);
                    let mut byte = [0];
                    stream.read_exact(&mut byte).unwrap();
                    head.push(byte[0]);
                }
                let head = String::from_utf8(head).unwrap();
                assert!(head.starts_with("GET /v1/projects/"), "{head}");
                assert!(head.contains("/tasks/1/attachments/1?context=1&task_ref="));
                let body = response.lock().unwrap();
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                )
                .unwrap();
                stream.write_all(&body).unwrap();
            }
        });
        Self {
            body,
            stop,
            worker: Some(worker),
            gateway: TlsFixture::new("localhost", false, Reply::Proxy(address)),
        }
    }
}
impl Drop for DownloadPeer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let result = self.worker.take().unwrap().join();
        if !thread::panicking() {
            result.unwrap();
        }
    }
}

fn frame(metadata: &Value) -> Vec<u8> {
    // Literal raw envelope framing, independent of the production frame writer.
    let bytes = b"trusted attachment bytes";
    let hash = tasks_cli::markdown::sha256(bytes);
    let mut envelope = b"TASKATT1".to_vec();
    envelope.extend([1, 0, 0, 0]);
    envelope.extend((bytes.len() as u64).to_le_bytes());
    for part in hash.as_bytes().chunks(2) {
        envelope.push(u8::from_str_radix(std::str::from_utf8(part).unwrap(), 16).unwrap());
    }
    envelope.extend(bytes);
    let json = serde_json::to_vec(metadata).unwrap();
    let mut frame = b"TASKDN01".to_vec();
    frame.extend((json.len() as u32).to_le_bytes());
    frame.extend(json);
    frame.extend(envelope);
    frame
}

fn files(root: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    fn visit(root: &Path, path: &Path, result: &mut Vec<(PathBuf, Vec<u8>)>) {
        if !path.exists() {
            return;
        }
        for entry in fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                visit(root, &path, result);
            } else {
                result.push((
                    path.strip_prefix(root).unwrap().to_owned(),
                    fs::read(path).unwrap(),
                ));
            }
        }
    }
    let mut result = Vec::new();
    visit(root, root, &mut result);
    result.sort();
    result
}

#[test]
fn untrusted_download_context_and_identities_never_publish_get_view_or_save() {
    let root = tempfile::tempdir().unwrap();
    let client = root.path().join("client");
    let keys = client.join("client");
    fs::create_dir(&client).unwrap();
    ok(run(
        &client,
        &["remote", "keygen", "--directory", keys.to_str().unwrap()],
    ));
    let peer = DownloadPeer::new();
    let project = Uuid::new_v4();
    config::save(
        &client,
        &Profile::Remote {
            server_url: peer.gateway.url(),
            server_id: Uuid::new_v4(),
            credential_id: Uuid::new_v4(),
            credential_file: keys.join("signing-key.pem"),
            private_ca: peer.gateway.options().private_ca,
            connect_timeout_seconds: 3,
            request_timeout_seconds: 15,
        },
    )
    .unwrap();
    let good = json!({
        "format": 1, "project_id": project, "task_id": 1,
        "attachment": {"id":1,"display_id":"A1","name":"download.txt",
            "kind":"file","media_type":"text/plain","original_size":24,
            "stored_size":76,"sha256":tasks_cli::markdown::sha256(b"trusted attachment bytes"),"added_ms":1},
        "context":{"id_key":"FIX","detached_ms":null}
    });
    let mut cases = Vec::new();
    let mut missing = good.clone();
    missing.as_object_mut().unwrap().remove("context");
    cases.push(("missing context", missing));
    for (label, context) in [
        ("null context", Value::Null),
        ("scalar context", json!("FIX")),
        ("invalid key type", json!({"id_key":7,"detached_ms":null})),
        (
            "invalid detached type",
            json!({"id_key":"FIX","detached_ms":"yesterday"}),
        ),
        (
            "noncanonical key",
            json!({"id_key":"fix","detached_ms":null}),
        ),
        ("foreign key", json!({"id_key":"OTHER","detached_ms":null})),
    ] {
        let mut bad = good.clone();
        bad["context"] = context;
        cases.push((label, bad));
    }
    for (label, field, value) in [
        ("foreign project", "project_id", json!(Uuid::new_v4())),
        ("foreign task", "task_id", json!(2)),
    ] {
        let mut bad = good.clone();
        bad[field] = value;
        cases.push((label, bad));
    }
    let mut bad = good.clone();
    bad["attachment"]["id"] = json!(2);
    cases.push(("foreign attachment", bad));

    let mut refusals = 0;
    for mode in ["get", "view", "save"] {
        let output_root = root.path().join(mode);
        fs::create_dir(&output_root).unwrap();
        let destination = if mode == "view" {
            client.join(format!("cache/attachments/{project}/A1/download.txt"))
        } else {
            output_root.join("saved.txt")
        };
        let project = project.to_string();
        let mut args = vec![
            "--project",
            &project,
            "attachment",
            "get",
            if mode == "get" { "1" } else { "FIX-001" },
            "A1",
        ];
        if mode != "view" {
            args.extend(["--out", destination.to_str().unwrap()]);
        }
        // A valid control proves every mode reaches publication through this peer.
        *peer.body.lock().unwrap() = frame(&good);
        ok(run(&client, &args));
        assert_eq!(fs::read(&destination).unwrap(), b"trusted attachment bytes");
        fs::remove_file(&destination).unwrap();
        for (label, metadata) in &cases {
            // Numeric references intentionally do not constrain the project key.
            if mode == "get" && *label == "foreign key" {
                continue;
            }
            for state in ["absent", "existing", "overwrite"] {
                if state != "absent" {
                    fs::write(&destination, b"keep existing destination").unwrap();
                }
                let before_out = files(&output_root);
                let before_cache = files(&client.join("cache"));
                let mut args = args.clone();
                if state == "overwrite" {
                    args.push("--overwrite");
                }
                *peer.body.lock().unwrap() = frame(metadata);
                let result = run(&client, &args);
                assert_eq!(
                    result.status.code(),
                    Some(6),
                    "{mode}/{label}/{state}: stdout={} stderr={}",
                    String::from_utf8_lossy(&result.stdout),
                    String::from_utf8_lossy(&result.stderr)
                );
                let error: Value = serde_json::from_slice(&result.stderr).unwrap();
                assert_eq!(
                    error["error"]["code"], "attachment_integrity",
                    "{mode}/{label}/{state}: {error}"
                );
                assert_eq!(files(&output_root), before_out, "{mode}/{label}/{state}");
                assert_eq!(
                    files(&client.join("cache")),
                    before_cache,
                    "{mode}/{label}/{state}"
                );
                if state == "absent" {
                    assert!(!destination.exists());
                } else {
                    assert_eq!(
                        fs::read(&destination).unwrap(),
                        b"keep existing destination"
                    );
                    fs::remove_file(&destination).unwrap();
                }
                refusals += 1;
            }
        }
    }
    eprintln!("adversarial download matrix: {refusals} refusals; 3 valid publication controls");
}
