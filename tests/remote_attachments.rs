#![cfg(all(feature = "server", feature = "test-hooks"))]
mod support;
use serde_json::{json, Value};
use std::{fs, sync::atomic::Ordering};
use support::remote_fixture::{ok, run, Fixture};
use tasks_cli::remote::pending::{PendingStore, PendingWrite};
use uuid::Uuid;

fn task(f: &Fixture, project: Uuid) {
    ok(run(
        &f.clients[0],
        &[
            "--project",
            &project.to_string(),
            "create",
            "--title",
            "Attachment target",
            "--body-file",
            f.body("body").to_str().unwrap(),
        ],
    ));
}

fn attachment_recovery_after_lost_response(detach: bool) {
    let f = Fixture::new();
    let project_id = f.project();
    let project = project_id.to_string();
    task(&f, project_id);
    task(&f, project_id);
    let source = f.body("recovery attachment");
    let add = [
        "--project",
        &project,
        "attachment",
        "add",
        "FIX-002",
        "--expect-version",
        "1",
        "--file",
        source.to_str().unwrap(),
    ];
    if detach {
        ok(run(&f.clients[0], &add));
    }
    let receipt = Uuid::new_v4().to_string();
    let detach_args = [
        "--project",
        &project,
        "attachment",
        "detach",
        "FIX-002",
        "A1",
        "--expect-version",
        "2",
    ];
    let mut args = if detach {
        detach_args.to_vec()
    } else {
        add.to_vec()
    };
    args.extend(["--request-id", &receipt]);
    f.drop_write.store(true, Ordering::SeqCst);
    let lost = run(&f.clients[0], &args);
    assert_eq!(lost.status.code(), Some(5));
    let error: Value = serde_json::from_slice(&lost.stderr).unwrap();
    assert_eq!(error["error"]["code"], "unknown_write_outcome");
    assert!(
        error["error"]["message"]
            .as_str()
            .unwrap()
            .contains("[stage=transport:"),
        "lost reply must identify the failed stage: {error}"
    );
    let operation = if detach {
        "attachment_detach"
    } else {
        "attachment_add"
    };
    let expected = json!({
        "schema_version":1,"project_id":null,"id_key":null,
        "data":{"command":"viewer_recovery","protocol_version":1,"items":[{
            "request_id":receipt,"project_id":project,"operation":operation,
            "task_id":2,"archived":null,"outcome_known":false
        }]}
    });
    assert_eq!(ok(run(&f.clients[0], &["viewer", "recovery"])), expected);
    let path = f.clients[0].join(format!("client/pending/{receipt}.json"));
    let mut stored: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(stored["task_id"], 2);
    // The reviewed format whitelist stays unchanged: binary v2, JSON detach v1.
    assert_eq!(stored["format_version"], if detach { 1 } else { 2 });
    // Legacy records lack the identity field. Recovery still associates them
    // using the validated numeric route, without changing the replay payload.
    stored.as_object_mut().unwrap().remove("task_id");
    fs::write(&path, serde_json::to_vec(&stored).unwrap()).unwrap();
    assert_eq!(ok(run(&f.clients[0], &["viewer", "recovery"])), expected);
    let replay = ok(run(&f.clients[0], &["viewer", "reconcile", &receipt]));
    assert_eq!(replay["data"]["command"], operation);
    assert_eq!(replay["data"]["id"], 2);
    assert_eq!(replay["data"]["display_id"], "FIX-002");
    assert_eq!(replay["data"]["version"], if detach { 3 } else { 2 });
    assert_eq!(
        ok(run(&f.clients[0], &["viewer", "reconcile", &receipt])),
        replay
    );
    let mut confirmed = expected;
    confirmed["data"]["items"][0]["outcome_known"] = json!(true);
    assert_eq!(ok(run(&f.clients[0], &["viewer", "recovery"])), confirmed);
    ok(run(&f.clients[0], &["viewer", "acknowledge", &receipt]));
    assert!(!path.exists());
    assert!(!path.with_extension("body").exists());
    assert_eq!(
        ok(run(&f.clients[0], &["viewer", "recovery"]))["data"]["items"],
        json!([])
    );
    let history = ok(run(&f.clients[1], &["--project", &project, "history", "2"]));
    assert_eq!(
        history["data"]["items"].as_array().unwrap().len(),
        if detach { 3 } else { 2 }
    );
}

#[test]
fn attachment_recovery_add_reports_task_identity_and_reconciles_legacy_record() {
    attachment_recovery_after_lost_response(false);
}

#[test]
fn attachment_recovery_detach_reports_task_identity_and_reconciles_legacy_record() {
    attachment_recovery_after_lost_response(true);
}

#[test]
fn binary_upload_lost_response_reconciles_exact_sidecar_and_detaches() {
    let f = Fixture::new();
    // Advertisement must be backed by accepted add/get/detach requests below.
    let client = remote(&f, 0);
    let info = client.info().unwrap();
    assert!(info["capabilities"]
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v == "attachments-v1"));
    let viewer = client
        .read(http::Method::GET, "/v1/viewer/info", b"")
        .unwrap();
    for operation in ["attachment-add", "attachment-get", "attachment-detach"] {
        assert!(viewer["output"]["data"]["operations"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v == operation));
    }
    let project = f.project();
    task(&f, project);
    let source = f.root.path().join("source.zip");
    fs::write(&source, b"PK\x03\x04original bytes").unwrap();
    f.drop_write.store(true, Ordering::SeqCst);
    let result = run(
        &f.clients[0],
        &[
            "--project",
            &project.to_string(),
            "attachment",
            "add",
            "1",
            "--expect-version",
            "1",
            "--file",
            source.to_str().unwrap(),
        ],
    );
    assert_eq!(
        result.status.code(),
        Some(5),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let pending = PendingStore::new(&f.clients[0]).unwrap();
    let ids = pending.list().unwrap();
    assert_eq!(ids.len(), 1);
    let path = f.clients[0].join(format!("client/pending/{}.body", ids[0]));
    assert!(path.exists());
    let record: Value = serde_json::from_slice(
        &fs::read(f.clients[0].join(format!("client/pending/{}.json", ids[0]))).unwrap(),
    )
    .unwrap();
    assert_eq!(record["format_version"], 2);
    let recovery = ok(run(&f.clients[0], &["viewer", "recovery"]));
    assert_eq!(recovery["data"]["items"][0]["operation"], "attachment_add");
    fs::write(&source, b"changed after unknown outcome").unwrap();
    let exact = fs::read(&path).unwrap();
    fs::write(&path, b"tampered").unwrap();
    let refused = run(&f.clients[0], &["remote", "reconcile", &ids[0].to_string()]);
    assert_eq!(refused.status.code(), Some(5));
    assert!(String::from_utf8_lossy(&refused.stderr).contains("pending_request"));
    fs::write(&path, &exact).unwrap();
    let replay = ok(run(
        &f.clients[0],
        &["remote", "reconcile", &ids[0].to_string()],
    ));
    assert_eq!(replay["data"]["version"], 2);
    assert!(!path.exists());
    let listed = ok(run(
        &f.clients[1],
        &["--project", &project.to_string(), "attachment", "list", "1"],
    ));
    assert_eq!(listed["data"]["items"].as_array().unwrap().len(), 1);
    let original = tasks_cli::remote::attachment::get(&remote(&f, 1), project, 1, 1).unwrap();
    assert_eq!(original.bytes, b"PK\x03\x04original bytes");
    let history = ok(run(
        &f.clients[1],
        &["--project", &project.to_string(), "history", "1"],
    ));
    assert_eq!(history["data"]["items"].as_array().unwrap().len(), 2);
    let detached = ok(run(
        &f.clients[1],
        &[
            "--project",
            &project.to_string(),
            "attachment",
            "detach",
            "1",
            "A1",
            "--expect-version",
            "2",
        ],
    ));
    assert_eq!(detached["data"]["version"], 3);
}

#[test]
fn pending_v2_refuses_tampered_body_before_replay() {
    let root = tempfile::tempdir().unwrap();
    let store = PendingStore::new(root.path()).unwrap();
    let id = Uuid::new_v4();
    let body = b"exact binary body";
    let record = json!({"format_version":2,"request_id":id,"server_id":Uuid::new_v4(),"credential_id":Uuid::new_v4(),"method":"POST","target":format!("/v1/projects/{}/tasks/1/attachments",Uuid::new_v4()),"payload":{},"body":{"content_type":"application/octet-stream","sha256":tasks_cli::markdown::sha256(body),"len":body.len()}});
    let parsed: PendingWrite = serde_json::from_value(record.clone()).unwrap();
    store.save_binary(&parsed, body).unwrap();
    assert_eq!(store.load(id).unwrap().format_version, 2);
    fs::write(
        root.path().join(format!("client/pending/{id}.body")),
        b"tampered body!!!!",
    )
    .unwrap();
    let error = store.load(id).unwrap_err();
    assert_eq!(error.exit_code(), 5);
    assert!(root
        .path()
        .join(format!("client/pending/{id}.json"))
        .exists());
}

#[test]
fn pending_save_retires_an_orphan_even_when_id_is_reused() {
    let root = tempfile::tempdir().unwrap();
    let store = PendingStore::new(root.path()).unwrap();
    let bytes = b"exact upload body";
    let request = PendingWrite::binary(
        Uuid::new_v4(),
        Uuid::new_v4(),
        &format!("/v1/projects/{}/tasks/1/attachments", Uuid::new_v4()),
        bytes,
    )
    .unwrap();
    let body = root
        .path()
        .join(format!("client/pending/{}.body", request.request_id));
    use std::io::Write;
    let mut sidecar = tasks_cli::private_fs::create_file(&body).unwrap();
    sidecar.write_all(bytes).unwrap();
    drop(sidecar);
    assert!(store.list().unwrap().is_empty());
    let mut next = PendingWrite::new(
        request.server_id,
        request.credential_id,
        "POST",
        "/v1/projects",
        json!({}),
    )
    .unwrap();
    next.request_id = request.request_id;
    store.save(&next).unwrap();
    assert!(!body.exists());
    store.load(next.request_id).unwrap();
}

fn remote(f: &Fixture, index: usize) -> tasks_cli::remote::client::RemoteClient {
    tasks_cli::remote::client::RemoteClient::new(
        &tasks_cli::remote::config::load(&f.clients[index]).unwrap(),
    )
    .unwrap()
}

#[test]
fn twenty_mib_upload_downloads_verified_bytes_on_second_client() {
    let f = Fixture::new();
    let project = f.project();
    task(&f, project);
    let mut original = vec![0x96; 20 * 1024 * 1024];
    original[..4].copy_from_slice(b"PK\x03\x04");
    let source = f.root.path().join("max.zip");
    fs::write(&source, &original).unwrap();
    let result = ok(run(
        &f.clients[0],
        &[
            "--project",
            &project.to_string(),
            "attachment",
            "add",
            "FIX-001",
            "--expect-version",
            "1",
            "--file",
            source.to_str().unwrap(),
        ],
    ));
    assert_eq!(
        result["data"]["attachments"][0]["original_size"],
        original.len()
    );
    let download = tasks_cli::remote::attachment::get(&remote(&f, 1), project, 1, 1).unwrap();
    assert_eq!(download.bytes, original);
    assert_eq!(download.metadata.id, 1);
    let output = f.root.path().join("downloaded-client-2.zip");
    let published = ok(run(
        &f.clients[1],
        &[
            "--project",
            &project.to_string(),
            "attachment",
            "get",
            "FIX-001",
            "A1",
            "--out",
            output.to_str().unwrap(),
        ],
    ));
    assert_eq!(published["data"]["command"], "attachment_get");
    assert_eq!(fs::read(&output).unwrap(), original);
    // Corruption remains a download integrity failure at exit 6.
    let db = tasks_cli::store::data_root_project_path(
        &f.root.path().join("server"),
        &project.to_string(),
    );
    let conn = rusqlite::Connection::open(db).unwrap();
    let trigger: String = conn
        .query_row(
            "SELECT sql FROM sqlite_schema WHERE name='attachment_blobs_no_update'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    conn.execute_batch("DROP TRIGGER attachment_blobs_no_update; UPDATE attachment_blobs SET envelope=zeroblob(stored_size);").unwrap();
    conn.execute_batch(&trigger).unwrap();
    let error = tasks_cli::remote::attachment::get(&remote(&f, 1), project, 1, 1)
        .err()
        .unwrap();
    assert_eq!(error.exit_code(), 6);
    assert!(error.json().contains("attachment_integrity"));
    let damaged = f.root.path().join("damaged-download.zip");
    let result = run(
        &f.clients[1],
        &[
            "--project",
            &project.to_string(),
            "attachment",
            "get",
            "1",
            "A1",
            "--out",
            damaged.to_str().unwrap(),
        ],
    );
    assert_eq!(result.status.code(), Some(6));
    assert!(String::from_utf8_lossy(&result.stderr).contains("attachment_integrity"));
    assert!(!damaged.exists());
    assert!(fs::read_dir(f.root.path()).unwrap().all(|e| !e
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with(".tasks-tmp-")));
}

#[test]
fn remote_get_uses_shared_publication_collision_reuse_overwrite_and_detached_rules() {
    let f = Fixture::new();
    let project = f.project();
    task(&f, project);
    let source = f.root.path().join("same.zip");
    fs::write(&source, b"PK\x03\x04first content").unwrap();
    let add = |version: &str| {
        ok(run(
            &f.clients[0],
            &[
                "--project",
                &project.to_string(),
                "attachment",
                "add",
                "1",
                "--expect-version",
                version,
                "--file",
                source.to_str().unwrap(),
            ],
        ))
    };
    add("1");
    fs::write(&source, b"PK\x03\x04different content").unwrap();
    add("2");
    let get = |ids: &[&str], out: Option<&std::path::Path>, overwrite: bool| {
        let project = project.to_string();
        let mut args = vec!["--project", &project, "attachment", "get", "1"];
        args.extend_from_slice(ids);
        if let Some(out) = out {
            args.extend(["--out", out.to_str().unwrap()]);
        }
        if overwrite {
            args.push("--overwrite");
        }
        run(&f.clients[1], &args)
    };
    let dir = f.root.path().join("outputs");
    fs::create_dir(&dir).unwrap();
    let collision = get(&[], Some(&dir), false);
    assert_eq!(collision.status.code(), Some(2));
    assert!(fs::read_dir(&dir).unwrap().next().is_none());
    let out = dir.join("selected.zip");
    fs::write(&out, b"keep existing").unwrap();
    assert_eq!(get(&["A1"], Some(&out), false).status.code(), Some(2));
    assert_eq!(fs::read(&out).unwrap(), b"keep existing");
    assert_eq!(
        get(&["A1", "A999"], Some(&dir), false).status.code(),
        Some(3)
    );
    ok(get(&["a1", "1"], Some(&out), true));
    assert_eq!(fs::read(&out).unwrap(), b"PK\x03\x04first content");
    let reused = ok(get(&["A1"], Some(&out), false));
    assert_eq!(reused["data"]["items"][0]["reused"], true);
    let cached = ok(get(&["A2"], None, false));
    let cached_path = std::path::Path::new(cached["data"]["items"][0]["path"].as_str().unwrap());
    assert_eq!(
        fs::read(cached_path).unwrap(),
        b"PK\x03\x04different content"
    );
    fs::write(cached_path, b"damaged cache").unwrap();
    ok(get(&["A2"], None, false));
    assert_eq!(
        fs::read(cached_path).unwrap(),
        b"PK\x03\x04different content"
    );
    ok(run(
        &f.clients[0],
        &[
            "--project",
            &project.to_string(),
            "attachment",
            "detach",
            "1",
            "A1",
            "--expect-version",
            "3",
        ],
    ));
    ok(get(&["A1"], Some(&out), false));
    let retained = ok(get(&[], Some(&dir), false));
    assert_eq!(retained["data"]["items"].as_array().unwrap().len(), 1);
    assert_eq!(retained["data"]["items"][0]["attachment"]["id"], 2);
    assert_eq!(
        get(&["A1"], Some(std::path::Path::new("-")), false)
            .status
            .code(),
        Some(2)
    );
    assert!(fs::read_dir(&dir).unwrap().all(|e| !e
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with(".tasks-tmp-")));
}

struct Server {
    root: tempfile::TempDir,
    child: std::process::Child,
    signer: tasks_cli::remote::signing::SigningIdentity,
    address: std::net::SocketAddr,
    project: Uuid,
}
impl Server {
    fn new(no_capability: bool) -> Self {
        use tasks_cli::{
            model::TaskStatus,
            server::{OwnedServer, Registration},
            store::{create_project_db_with_key, Store},
        };
        let root = tempfile::tempdir().unwrap();
        let server = OwnedServer::initialize(root.path()).unwrap();
        let key = ed25519_dalek::SigningKey::from_bytes(&[17; 32]);
        let credential = server
            .register(&Registration {
                public_key: key.verifying_key().to_bytes(),
                actor_id: "fixture".into(),
                actor_name: "Fixture".into(),
                installation_id: Uuid::new_v4(),
                installation_name: "test".into(),
            })
            .unwrap();
        let signer = tasks_cli::remote::signing::SigningIdentity {
            server_id: server.server_id(),
            credential_id: credential,
            key,
        };
        let project = Uuid::new_v4();
        create_project_db_with_key(root.path(), &project, Some("BIN")).unwrap();
        let mut store = Store::open_rw(root.path(), &project.to_string()).unwrap();
        store
            .create_task("target", "", TaskStatus::Ready, vec![])
            .unwrap();
        drop(store);
        let conn = rusqlite::Connection::open(root.path().join("server.sqlite")).unwrap();
        conn.execute(
            "INSERT INTO projects(project_id,name) VALUES(?1,'binary fixture')",
            [project.to_string()],
        )
        .unwrap();
        drop(conn);
        drop(server);
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let mut command = support::process::command(env!("CARGO_BIN_EXE_tasks-server"));
        command
            .args([
                "--data-root",
                root.path().to_str().unwrap(),
                "serve",
                "--listen",
                &address.to_string(),
            ])
            .env("TASKS_TEST_DECODE_LOG", root.path().join("decode.log"))
            .env("TASKS_TEST_TRANSFER_LOG", root.path().join("transfer.log"))
            .env_remove("TASKS_TEST_NO_ATTACHMENTS_CAPABILITY")
            .stdout(std::process::Stdio::null())
            .stderr(fs::File::create(root.path().join("requests.log")).unwrap());
        if no_capability {
            command.env("TASKS_TEST_NO_ATTACHMENTS_CAPABILITY", "1");
        }
        let child = command.spawn().unwrap();
        let fixture = Self {
            root,
            child,
            signer,
            address,
            project,
        };
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            if std::net::TcpStream::connect(address).is_ok() {
                break;
            }
            assert!(std::time::Instant::now() < deadline, "server did not start");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        fixture
    }
    fn target(&self) -> String {
        format!("/v1/projects/{}/tasks/1/attachments", self.project)
    }
    fn request(
        &self,
        method: http::Method,
        target: &str,
        body: &[u8],
        kind: &str,
        id: Option<Uuid>,
    ) -> (u16, Vec<u8>) {
        let headers = self
            .signer
            .sign_now_with_content_type(&method, &target.parse().unwrap(), body, id, kind)
            .unwrap();
        let response = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .unwrap()
            .request(method, format!("http://{}{target}", self.address))
            .headers(headers)
            .body(body.to_vec())
            .send()
            .unwrap();
        (
            response.status().as_u16(),
            response.bytes().unwrap().to_vec(),
        )
    }
    fn decodes(&self) -> usize {
        fs::read_to_string(self.root.path().join("decode.log"))
            .unwrap_or_default()
            .lines()
            .count()
    }
    fn receipts(&self) -> usize {
        let conn = rusqlite::Connection::open(tasks_cli::store::data_root_project_path(
            self.root.path(),
            &self.project.to_string(),
        ))
        .unwrap();
        conn.query_row("SELECT count(*) FROM mutation_receipts", [], |r| r.get(0))
            .unwrap()
    }
    fn unchanged(&self) {
        let conn = rusqlite::Connection::open(tasks_cli::store::data_root_project_path(
            self.root.path(),
            &self.project.to_string(),
        ))
        .unwrap();
        assert_eq!(
            conn.query_row("SELECT version FROM tasks WHERE id=1", [], |r| r
                .get::<_, u64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            conn.query_row("SELECT count(*) FROM task_attachments", [], |r| r
                .get::<_, u64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            conn.query_row("SELECT count(*) FROM attachment_blobs", [], |r| r
                .get::<_, u64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            conn.query_row("SELECT count(*) FROM events WHERE task_id=1", [], |r| r
                .get::<_, u64>(0))
                .unwrap(),
            1
        );
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.child.kill().unwrap();
        self.child.wait().unwrap();
    }
}
fn envelope(payload: &[u8], original: u64, hash: &str, codec: u8) -> Vec<u8> {
    let mut bytes = b"TASKATT1".to_vec();
    bytes.extend([1, codec, 0, 0]);
    bytes.extend(original.to_le_bytes());
    for chunk in hash.as_bytes().chunks(2) {
        bytes.push(u8::from_str_radix(std::str::from_utf8(chunk).unwrap(), 16).unwrap());
    }
    bytes.extend(payload);
    bytes
}
fn raw_frame(items: Value, envelopes: &[Vec<u8>]) -> Vec<u8> {
    let metadata=serde_json::to_vec(&json!({"format":1,"task_ref":"BIN-001","expect_version":1,"items":items,"attribution":tasks_cli::model::Attribution::default()})).unwrap();
    let mut bytes = b"TASKUP01".to_vec();
    bytes.extend((metadata.len() as u32).to_le_bytes());
    bytes.extend(metadata);
    for envelope in envelopes {
        bytes.extend(envelope);
    }
    bytes
}
fn item(name: &str, original: u64, hash: &str, stored: usize) -> Value {
    json!({"name":name,"original_size":original,"original_sha256":hash,"stored_size":stored})
}

#[test]
fn signed_content_types_digest_and_early_length_guards() {
    use std::io::{Read, Write};
    let s = Server::new(false);
    assert_eq!(
        s.request(
            http::Method::POST,
            &format!("/v1/projects/{}/query", s.project),
            b"{}",
            "application/octet-stream",
            None
        )
        .0,
        401
    );
    assert_eq!(
        s.request(
            http::Method::POST,
            &s.target(),
            b"{}",
            "application/json",
            Some(Uuid::new_v4())
        )
        .0,
        401
    );
    let headers = s
        .signer
        .sign_now_with_content_type(
            &http::Method::POST,
            &s.target().parse().unwrap(),
            b"original",
            Some(Uuid::new_v4()),
            "application/octet-stream",
        )
        .unwrap();
    let response = reqwest::blocking::Client::new()
        .post(format!("http://{}{}", s.address, s.target()))
        .headers(headers)
        .body("tampered")
        .send()
        .unwrap();
    assert_eq!(response.status().as_u16(), 401);
    for (length, expected) in [(Some(54_525_953), 413), (None, 411)] {
        let mut socket = std::net::TcpStream::connect(s.address).unwrap();
        socket
            .set_read_timeout(Some(support::https::FIXTURE_IO_TIMEOUT))
            .unwrap();
        write!(
            socket,
            "POST {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",
            s.target()
        )
        .unwrap();
        if let Some(length) = length {
            write!(socket, "Content-Length: {length}\r\n").unwrap();
        }
        socket.write_all(b"\r\n").unwrap();
        let mut response = [0; 512];
        let n = socket.read(&mut response).unwrap();
        assert!(
            String::from_utf8_lossy(&response[..n]).starts_with(&format!("HTTP/1.1 {expected}"))
        );
    }
    s.unchanged();
    assert_eq!(s.decodes(), 0);
    assert_eq!(s.receipts(), 0);
}

#[test]
fn header_preflight_refusals_and_replays_decode_nothing() {
    use std::io::Write;
    let s = Server::new(false);
    let hash = tasks_cli::markdown::sha256(b"x");
    let good = envelope(b"x", 1, &hash, 0);
    let mut compressor = liblzma::write::XzEncoder::new(Vec::new(), 0);
    let mut digest = sha2::Sha256::new();
    use sha2::Digest;
    let zeros = vec![0; 1024 * 1024];
    for _ in 0..180 {
        compressor.write_all(&zeros).unwrap();
        digest.update(&zeros);
    }
    let original_hash = format!("{:x}", digest.finalize());
    let xz = envelope(
        &compressor.finish().unwrap(),
        180 * 1024 * 1024,
        &original_hash,
        1,
    );
    let cases = vec![
        (
            raw_frame(
                json!((0..33)
                    .map(|_| item("x", 1, &hash, good.len()))
                    .collect::<Vec<_>>()),
                &vec![good.clone(); 33],
            ),
            413,
        ),
        (
            raw_frame(
                json!([item("overflow", u64::MAX, &hash, good.len())]),
                std::slice::from_ref(&good),
            ),
            413,
        ),
        (
            raw_frame(
                json!([item("mismatch", 2, &hash, good.len())]),
                std::slice::from_ref(&good),
            ),
            400,
        ),
        (
            raw_frame(
                json!([item("mismatch", 1, &"0".repeat(64), good.len())]),
                std::slice::from_ref(&good),
            ),
            400,
        ),
        (
            raw_frame(
                json!([item("too-big", 1, &hash, 20 * 1024 * 1024 + 53)]),
                std::slice::from_ref(&good),
            ),
            413,
        ),
        (
            raw_frame(
                json!([
                    item("good", 1, &hash, good.len()),
                    item("later-bad-header", 1, &hash, good.len())
                ]),
                &[good.clone(), envelope(b"x", 2, &hash, 0)],
            ),
            400,
        ),
        (b"malformed frame".to_vec(), 400),
        (
            raw_frame(
                json!(vec![
                    item(
                        "zeros",
                        180 * 1024 * 1024,
                        &original_hash,
                        xz.len()
                    );
                    3
                ]),
                &vec![xz; 3],
            ),
            413,
        ),
    ];
    for (index, (body, status)) in cases.into_iter().enumerate() {
        let id = Uuid::new_v4();
        let first = s.request(
            http::Method::POST,
            &s.target(),
            &body,
            "application/octet-stream",
            Some(id),
        );
        assert_eq!(first.0, status, "{}", String::from_utf8_lossy(&first.1));
        let response: Value = serde_json::from_slice(&first.1).unwrap();
        assert_eq!(response["receipt"]["request_id"], id.to_string());
        assert_eq!(
            response["receipt"]["payload_sha256"],
            tasks_cli::markdown::sha256(&body)
        );
        assert_eq!(response["receipt"]["status"], status);
        let replay = s.request(
            http::Method::POST,
            &s.target(),
            &body,
            "application/octet-stream",
            Some(id),
        );
        assert_eq!(replay, first);
        assert_eq!(s.decodes(), 0);
        assert_eq!(s.receipts(), index + 1);
        s.unchanged();
    }
}

#[test]
fn decoder_failures_have_terminal_400_receipts_and_success_replay_skips_decode() {
    use std::io::Write;
    let s = Server::new(false);
    let mut compressor = liblzma::write::XzEncoder::new(Vec::new(), 6);
    compressor.write_all(b"longer than declared").unwrap();
    let xz = compressor.finish().unwrap();
    let hash = tasks_cli::markdown::sha256(b"x");
    let bomb = envelope(&xz, 1, &hash, 1);
    let corrupt = envelope(b"not an xz stream", 1, &hash, 1);
    let mut options = liblzma::stream::LzmaOptions::new_preset(0).unwrap();
    options.dict_size(64 * 1024 * 1024);
    let mut filters = liblzma::stream::Filters::new();
    filters.lzma2(&options);
    let stream =
        liblzma::stream::Stream::new_stream_encoder(&filters, liblzma::stream::Check::Crc64)
            .unwrap();
    let mut compressor = liblzma::write::XzEncoder::new_stream(Vec::new(), stream);
    compressor.write_all(b"x").unwrap();
    let memlimit = envelope(&compressor.finish().unwrap(), 1, &hash, 1);
    for (index, bytes) in [bomb, corrupt, memlimit].into_iter().enumerate() {
        let body = raw_frame(json!([item("bad", 1, &hash, bytes.len())]), &[bytes]);
        let id = Uuid::new_v4();
        let first = s.request(
            http::Method::POST,
            &s.target(),
            &body,
            "application/octet-stream",
            Some(id),
        );
        assert_eq!(first.0, 400, "{}", String::from_utf8_lossy(&first.1));
        assert_eq!(s.decodes(), index + 1);
        assert_eq!(
            s.request(
                http::Method::POST,
                &s.target(),
                &body,
                "application/octet-stream",
                Some(id)
            ),
            first
        );
        assert_eq!(s.decodes(), index + 1);
        s.unchanged();
    }
    let bytes = envelope(b"x", 1, &hash, 0);
    let private_name = "confidential-payroll-unique-attachment.txt";
    let body = raw_frame(json!([item(private_name, 1, &hash, bytes.len())]), &[bytes]);
    let id = Uuid::new_v4();
    let first = s.request(
        http::Method::POST,
        &s.target(),
        &body,
        "application/octet-stream",
        Some(id),
    );
    assert_eq!(first.0, 200);
    let logs = fs::read_to_string(s.root.path().join("requests.log")).unwrap();
    let records = logs
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .collect::<Vec<_>>();
    let record = records
        .iter()
        .find(|record| record["request_id"] == id.to_string())
        .unwrap();
    assert_eq!(record["operation"], "attachment_add");
    assert_eq!(record["item_count"], 1);
    assert_eq!(record["stored_bytes"], 53);
    assert_eq!(record["declared_original_bytes"], 1);
    assert!(
        !logs.contains("\"name\"") && !logs.contains("\"sha256\"") && !logs.contains("BIN-001")
    );
    assert!(!logs.contains(private_name));
    assert!(!logs.contains(&s.root.path().display().to_string()));
    assert!(!logs.contains(&hash));
    let count = s.decodes();
    assert_eq!(
        s.request(
            http::Method::POST,
            &s.target(),
            &body,
            "application/octet-stream",
            Some(id)
        ),
        first
    );
    assert_eq!(s.decodes(), count);
    assert_eq!(
        s.request(
            http::Method::POST,
            &s.target(),
            b"different",
            "application/octet-stream",
            Some(id)
        )
        .0,
        409
    );
    assert_eq!(s.decodes(), count);
    let listed = s.request(
        http::Method::POST,
        &format!("/v1/projects/{}/query", s.project),
        &serde_json::to_vec(
            &json!({"operation":"attachments","id":"1","all":false,"after":null,"limit":100}),
        )
        .unwrap(),
        "application/json",
        None,
    );
    assert_eq!(listed.0, 200);
    assert_eq!(s.request(
        http::Method::POST,
        &format!("{}/detach", s.target()),
        &serde_json::to_vec(&json!({"expect_version":2,"attachments":[1],"attribution":tasks_cli::model::Attribution::default()})).unwrap(),
        "application/json", Some(Uuid::new_v4()),
    ).0, 200);
    let logs = fs::read_to_string(s.root.path().join("requests.log")).unwrap();
    let records = logs
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .collect::<Vec<_>>();
    let successful = records
        .iter()
        .filter(|r| r["request_id"] == id.to_string() && r["outcome"] == "http_200")
        .collect::<Vec<_>>();
    assert_eq!(successful.len(), 2);
    for record in successful {
        assert_eq!(record["item_count"], 1);
        assert_eq!(record["stored_bytes"], 53);
        assert_eq!(record["declared_original_bytes"], 1);
    }
    let listed = records
        .iter()
        .find(|r| r["operation"] == "attachment_list")
        .unwrap();
    assert_eq!(listed["item_count"], 1);
    assert_eq!(listed["stored_bytes"], 53);
    assert_eq!(listed["declared_original_bytes"], 1);
    let detached = records
        .iter()
        .find(|r| r["operation"] == "attachment_detach")
        .unwrap();
    assert_eq!(detached["item_count"], 1);
    // Detach transfers identifiers, with no stored or original content bytes.
    assert_eq!(detached["stored_bytes"], 0);
    assert_eq!(detached["declared_original_bytes"], 0);
    assert!(!logs.contains(private_name));
    assert!(!logs.contains(&s.root.path().display().to_string()));
    assert!(!logs.contains(&hash));
}

#[test]
fn third_transfer_gets_capacity_without_mutation() {
    use std::io::Write;
    let s = Server::new(false);
    let mut sockets = Vec::new();
    for _ in 0..2 {
        let mut socket = std::net::TcpStream::connect(s.address).unwrap();
        let headers = s
            .signer
            .sign_now_with_content_type(
                &http::Method::POST,
                &s.target().parse().unwrap(),
                b"xx",
                Some(Uuid::new_v4()),
                "application/octet-stream",
            )
            .unwrap();
        write!(
            socket,
            "POST {} HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nConnection: close\r\n",
            s.target()
        )
        .unwrap();
        for (name, value) in &headers {
            if name != "content-length" {
                write!(socket, "{name}: {}\r\n", value.to_str().unwrap()).unwrap();
            }
        }
        socket.write_all(b"\r\nx").unwrap();
        sockets.push(socket);
    }
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while fs::read_to_string(s.root.path().join("transfer.log"))
        .unwrap_or_default()
        .lines()
        .count()
        != 2
    {
        assert!(std::time::Instant::now() < deadline);
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let response = s.request(
        http::Method::POST,
        &s.target(),
        b"xx",
        "application/octet-stream",
        Some(Uuid::new_v4()),
    );
    assert_eq!(response.0, 503);
    let body: Value = serde_json::from_slice(&response.1).unwrap();
    assert_eq!(body["error"]["code"], "capacity");
    s.unchanged();
    assert_eq!(s.decodes(), 0);
    drop(sockets);
}

fn open_transfer(
    s: &Server,
    method: http::Method,
    target: &str,
    signed_body: &[u8],
    declared: usize,
    initial: &[u8],
) -> std::net::TcpStream {
    use std::io::Write;
    let kind = if method == http::Method::POST {
        "application/octet-stream"
    } else {
        "application/json"
    };
    let headers = s
        .signer
        .sign_now_with_content_type(
            &method,
            &target.parse().unwrap(),
            signed_body,
            (method == http::Method::POST).then(Uuid::new_v4),
            kind,
        )
        .unwrap();
    let mut socket = std::net::TcpStream::connect(s.address).unwrap();
    socket
        .set_read_timeout(Some(support::https::FIXTURE_IO_TIMEOUT))
        .unwrap();
    write!(socket, "{method} {target} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {declared}\r\nConnection: close\r\n").unwrap();
    for (name, value) in &headers {
        if name != "content-length" {
            write!(socket, "{name}: {}\r\n", value.to_str().unwrap()).unwrap();
        }
    }
    socket.write_all(b"\r\n").unwrap();
    socket.write_all(initial).unwrap();
    socket
}

fn read_head(socket: &mut std::net::TcpStream) -> std::io::Result<String> {
    use std::io::Read;
    let mut head = Vec::new();
    while head.len() < 16 * 1024 && !head.ends_with(b"\r\n\r\n") {
        let mut byte = [0];
        if socket.read(&mut byte)? == 0 {
            break;
        }
        head.push(byte[0]);
    }
    Ok(String::from_utf8_lossy(&head).into_owned())
}

#[test]
fn binary_signed_length_tamper_is_401_before_body_or_transfer_admission() {
    let s = Server::new(false);
    for (method, target, declared) in [
        (http::Method::POST, s.target(), 50 * 1024 * 1024),
        (http::Method::GET, format!("{}/1", s.target()), 1024 * 1024),
    ] {
        let mut socket = open_transfer(&s, method, &target, b"x", declared, b"");
        let response = read_head(&mut socket);
        assert!(
            response
                .as_ref()
                .is_ok_and(|head| head.starts_with("HTTP/1.1 401")),
            "length tamper must fail without waiting for any body: {response:?}"
        );
    }
    assert!(!s.root.path().join("transfer.log").exists());
    assert_eq!(s.receipts(), 0);
    s.unchanged();
}

#[test]
fn stalled_download_deadlines_release_capacity_without_clients_closing() {
    let s = Server::new(false);
    let original = vec![0x96; 20 * 1024 * 1024];
    let hash = tasks_cli::markdown::sha256(&original);
    let bytes = envelope(&original, original.len() as u64, &hash, 0);
    let body = raw_frame(
        json!([item("stall.zip", original.len() as u64, &hash, bytes.len())]),
        &[bytes],
    );
    assert_eq!(
        s.request(
            http::Method::POST,
            &s.target(),
            &body,
            "application/octet-stream",
            Some(Uuid::new_v4())
        )
        .0,
        200
    );
    let target = format!("{}/1", s.target());
    let mut stalled = Vec::new();
    for _ in 0..2 {
        let mut socket = open_transfer(&s, http::Method::GET, &target, b"", 0, b"");
        assert!(read_head(&mut socket).unwrap().starts_with("HTTP/1.1 200"));
        stalled.push(socket);
    }
    assert_eq!(
        s.request(http::Method::GET, &target, b"", "application/json", None)
            .0,
        503
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(23);
    loop {
        let logs = fs::read_to_string(s.root.path().join("requests.log")).unwrap();
        if logs.matches("attachment_interrupted").count() >= 2 {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "stalled downloads did not expire"
        );
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    assert_eq!(
        s.request(http::Method::GET, &target, b"", "application/json", None)
            .0,
        200,
        "capacity must recover while both stalled clients keep their sockets open"
    );
    drop(stalled);
}

#[test]
fn stalled_upload_and_slowloris_expire_without_clients_closing() {
    use std::io::Write;
    let s = Server::new(false);
    let stalled = open_transfer(&s, http::Method::POST, &s.target(), b"xx", 2, b"x");
    let full = vec![b'x'; 1024];
    let mut slowloris = open_transfer(&s, http::Method::POST, &s.target(), &full, full.len(), b"x");
    let admitted = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while fs::read_to_string(s.root.path().join("transfer.log"))
        .unwrap_or_default()
        .lines()
        .count()
        < 2
    {
        assert!(std::time::Instant::now() < admitted);
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert_eq!(
        s.request(
            http::Method::POST,
            &s.target(),
            b"xx",
            "application/octet-stream",
            Some(Uuid::new_v4())
        )
        .0,
        503
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(36);
    loop {
        let logs = fs::read_to_string(s.root.path().join("requests.log")).unwrap();
        if logs.matches("http_408").count() >= 2 {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "absolute upload deadlines must defeat slowloris progress"
        );
        let _ = slowloris.write_all(b"x");
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    assert_eq!(s.receipts(), 0);
    s.unchanged();
    let hash = tasks_cli::markdown::sha256(b"x");
    let bytes = envelope(b"x", 1, &hash, 0);
    let body = raw_frame(
        json!([item("after-timeout", 1, &hash, bytes.len())]),
        &[bytes],
    );
    assert_eq!(
        s.request(
            http::Method::POST,
            &s.target(),
            &body,
            "application/octet-stream",
            Some(Uuid::new_v4())
        )
        .0,
        200
    );
    drop((stalled, slowloris));
}

#[test]
fn old_server_refuses_before_reading_source_and_binary_viewer_acknowledge_cleans_sidecars() {
    use ed25519_dalek::pkcs8::EncodePrivateKey;
    let s = Server::new(true);
    let tls = support::https::TlsFixture::new(
        "localhost",
        false,
        support::https::Reply::Proxy(s.address),
    );
    let client_root = s.root.path().join("client-old");
    tasks_cli::private_fs::create_dir(&client_root).unwrap();
    let key_path = client_root.join("key.pem");
    let pem = s.signer.key.to_pkcs8_pem(Default::default()).unwrap();
    use std::io::Write;
    tasks_cli::private_fs::create_file(&key_path)
        .unwrap()
        .write_all(pem.as_bytes())
        .unwrap();
    let profile = tasks_cli::remote::config::Profile::Remote {
        server_url: tls.url(),
        server_id: s.signer.server_id,
        credential_id: s.signer.credential_id,
        credential_file: key_path,
        private_ca: tls.options().private_ca,
        connect_timeout_seconds: 3,
        request_timeout_seconds: 15,
    };
    tasks_cli::remote::config::save(&client_root, &profile).unwrap();
    let response = run(
        &client_root,
        &[
            "--project",
            &s.project.to_string(),
            "attachment",
            "add",
            "1",
            "--expect-version",
            "1",
            "--file",
            "deliberately-absent.zip",
        ],
    );
    assert_eq!(response.status.code(), Some(5));
    assert!(String::from_utf8_lossy(&response.stderr).contains("remote_capability"));
    s.unchanged();
    let f = Fixture::new();
    let project = f.project();
    task(&f, project);
    let source = f.root.path().join("small.zip");
    fs::write(&source, b"original").unwrap();
    let id = Uuid::new_v4();
    f.drop_write.store(true, Ordering::SeqCst);
    let unknown = run(
        &f.clients[0],
        &[
            "--project",
            &project.to_string(),
            "attachment",
            "add",
            "1",
            "--expect-version",
            "1",
            "--file",
            source.to_str().unwrap(),
            "--request-id",
            &id.to_string(),
        ],
    );
    assert_eq!(unknown.status.code(), Some(5));
    let store = PendingStore::new(&f.clients[0]).unwrap();
    assert_eq!(store.list().unwrap(), [id]);
    ok(run(
        &f.clients[0],
        &["viewer", "reconcile", &id.to_string()],
    ));
    assert!(store
        .confirmation(&store.load(id).unwrap())
        .unwrap()
        .is_some());
    ok(run(
        &f.clients[0],
        &["viewer", "acknowledge", &id.to_string()],
    ));
    assert!(store.list().unwrap().is_empty());
    assert!(!f.clients[0]
        .join(format!("client/pending/{id}.body"))
        .exists());
}

#[test]
fn pending_save_retires_only_unpublished_body_sidecars() {
    use std::io::Write;
    let root = tempfile::tempdir().unwrap();
    let store = PendingStore::new(root.path()).unwrap();
    let _lock = store.lock().unwrap();
    let orphan = Uuid::new_v4();
    let path = root.path().join(format!("client/pending/{orphan}.body"));
    tasks_cli::private_fs::create_file(&path)
        .unwrap()
        .write_all(b"never sent")
        .unwrap();
    assert!(store.list().unwrap().is_empty());
    let request = PendingWrite::new(
        Uuid::new_v4(),
        Uuid::new_v4(),
        "POST",
        "/v1/projects",
        json!({"project_id":Uuid::new_v4()}),
    )
    .unwrap();
    store.save(&request).unwrap();
    assert!(!path.exists());
    assert_eq!(store.list().unwrap(), [request.request_id]);
    let upload = format!("/v1/projects/{}/tasks/1/attachments", Uuid::new_v4());
    assert!(PendingWrite::new(Uuid::new_v4(), Uuid::new_v4(), "POST", &upload, json!({})).is_err());
    let mut record = serde_json::to_value(&request).unwrap();
    record["format_version"] = json!(2);
    record["body"] =
        json!({"content_type":"application/octet-stream","sha256":"0".repeat(64),"len":0});
    let invalid: PendingWrite = serde_json::from_value(record).unwrap();
    assert!(store.save(&invalid).is_err());
}
