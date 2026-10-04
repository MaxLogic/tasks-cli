#![cfg(feature = "server")]
mod support;
use axum::http::{HeaderValue, Method, Uri};
use ed25519_dalek::SigningKey;
use tasks_cli::server::signatures::SigningIdentity;
use tasks_cli::server::{OwnedServer, Registration, ServiceError};
use uuid::Uuid;

fn signed_fixture() -> (tempfile::TempDir, OwnedServer, SigningIdentity) {
    let root = tempfile::tempdir().unwrap();
    let server = OwnedServer::initialize(root.path()).unwrap();
    let credential = server.register(&registration()).unwrap();
    let signer = SigningIdentity {
        credential_id: credential,
        server_id: server.server_id(),
        key: SigningKey::from_bytes(&[7; 32]),
    };
    (root, server, signer)
}

#[test]
fn empty_get_signature_matches_an_independently_written_rfc_base() {
    use base64::{engine::general_purpose::STANDARD, Engine};
    use ed25519_dalek::Signer;
    let signer = SigningIdentity {
        server_id: "11111111-1111-4111-8111-111111111111".parse().unwrap(),
        credential_id: "22222222-2222-4222-8222-222222222222".parse().unwrap(),
        key: SigningKey::from_bytes(&[7; 32]),
    };
    let headers = signer
        .sign(
            &Method::GET,
            &"/v1/info".parse().unwrap(),
            b"",
            None,
            1000,
            &[0; 32],
        )
        .unwrap();
    let base=concat!(
        "\"@method\": GET\n",
        "\"@path\": /v1/info\n",
        "\"@query\": ?\n",
        "\"content-type\": application/json\n",
        "\"content-digest\": sha-256=:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=:\n",
        "\"x-tasks-server-id\": 11111111-1111-4111-8111-111111111111\n",
        "\"@signature-params\": (\"@method\" \"@path\" \"@query\" \"content-type\" \"content-digest\" \"x-tasks-server-id\");created=1000;expires=1120;nonce=\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\";alg=\"ed25519\";keyid=\"22222222-2222-4222-8222-222222222222\""
    );
    let expected = format!(
        "tasks=:{}:",
        STANDARD.encode(signer.key.sign(base.as_bytes()).to_bytes())
    );
    assert_eq!(headers["signature"].to_str().unwrap(), expected);
}

#[test]
fn invalid_registration_errors_do_not_echo_supplied_values() {
    let root = tempfile::tempdir().unwrap();
    drop(OwnedServer::initialize(root.path()).unwrap());
    let input = root.path().join("bad.json");
    std::fs::write(&input, br#"{"public_key":"PRIVATE_VALUE_MUST_NOT_APPEAR"}"#).unwrap();
    let result = support::process::command(env!("CARGO_BIN_EXE_tasks-server"))
        .args([
            "--data-root",
            root.path().to_str().unwrap(),
            "admin",
            "register",
            "--registration-file",
            input.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(5));
    assert!(!String::from_utf8_lossy(&result.stderr).contains("PRIVATE_VALUE_MUST_NOT_APPEAR"));
    assert!(result.stdout.is_empty());
}

#[test]
fn signatures_bind_exact_encoded_path_query_body_and_registered_identity() {
    let (_root, server, signer) = signed_fixture();
    let uri: Uri = "/v1/projects/abc/tasks?a=%2F&b=2".parse().unwrap();
    let receipt = Uuid::new_v4();
    let headers = signer
        .sign(
            &Method::POST,
            &uri,
            b"exact body",
            Some(receipt),
            1000,
            &[8; 32],
        )
        .unwrap();
    let authenticated = server
        .authenticate(&Method::POST, &uri, &headers, 1000)
        .unwrap();
    authenticated.check_body(b"exact body").unwrap();
    assert!(authenticated.check_body(b"changed body").is_err());
    let mut context = tasks_cli::model::Attribution {
        actor_id: Some("forged".into()),
        actor_name: Some("forged".into()),
        machine_id: Some(Uuid::new_v4()),
        registered_machine_name: Some("forged".into()),
        ..Default::default()
    };
    authenticated.apply_identity(&mut context);
    assert_eq!(context.actor_id.as_deref(), Some("owner"));
    assert_eq!(
        context.machine_id,
        Some(authenticated.registration.installation_id)
    );
    assert_eq!(context.request_id, receipt);
    assert_eq!(
        context.actor_authority,
        tasks_cli::model::AttributionSource::Credential
    );
    assert!(server
        .authenticate(&Method::POST, &uri, &headers, 1000)
        .is_err());
}

#[test]
fn tampered_metadata_and_invalid_signatures_cannot_consume_replay_capacity() {
    let (root, server, signer) = signed_fixture();
    let uri: Uri = "/v1/info?encoded=%2F".parse().unwrap();
    let headers = signer
        .sign(&Method::GET, &uri, b"", None, 1000, &[1; 32])
        .unwrap();
    for fault in [
        "method",
        "path",
        "query",
        "type",
        "digest",
        "server",
        "signature",
        "duplicate",
        "algorithm",
        "components",
        "extra-signature",
        "duplicate-param",
        "compression",
    ] {
        let mut bad = headers.clone();
        let method = if fault == "method" {
            Method::HEAD
        } else {
            Method::GET
        };
        let target = match fault {
            "path" => "/other?encoded=%2F",
            "query" => "/v1/info?encoded=/",
            _ => "/v1/info?encoded=%2F",
        }
        .parse()
        .unwrap();
        match fault {
            "type" => {
                bad.insert("content-type", HeaderValue::from_static("text/plain"));
            }
            "digest" => {
                bad.insert(
                    "content-digest",
                    HeaderValue::from_static(
                        "sha-256=:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=:",
                    ),
                );
            }
            "server" => {
                bad.insert(
                    "x-tasks-server-id",
                    Uuid::new_v4().to_string().parse().unwrap(),
                );
            }
            "signature" => {
                bad.insert("signature", HeaderValue::from_static("tasks=:AA==:"));
            }
            "duplicate" => {
                bad.append("content-type", HeaderValue::from_static("application/json"));
            }
            "algorithm" | "components" | "extra-signature" | "duplicate-param" => {
                let value = bad["signature-input"].to_str().unwrap().to_owned();
                let value = match fault {
                    "algorithm" => value.replace("ed25519", "rsa-pss-sha512"),
                    "components" => value.replace("\"@query\" ", ""),
                    "extra-signature" => format!("{value}, other=(\"@method\")"),
                    _ => format!("{value};created=1000"),
                };
                bad.insert("signature-input", value.parse().unwrap());
            }
            "compression" => {
                bad.insert("content-encoding", HeaderValue::from_static("gzip"));
            }
            _ => {}
        }
        assert!(
            server.authenticate(&method, &target, &bad, 1000).is_err(),
            "{fault}"
        );
    }
    let connection = rusqlite::Connection::open(root.path().join("server.sqlite")).unwrap();
    let count: i64 = connection
        .query_row("SELECT count(*) FROM replay_nonces", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 0);
    server
        .authenticate(&Method::GET, &uri, &headers, 1000)
        .unwrap();
}

#[test]
fn clock_window_revocation_and_fresh_signatures_preserve_reconciliation_identity() {
    let (_root, server, signer) = signed_fixture();
    let uri: Uri = "/v1/projects/example/tasks".parse().unwrap();
    let receipt = Uuid::new_v4();
    for (created, accepted) in [(1030, true), (1031, false), (850, true), (849, false)] {
        let nonce = [(created % 256) as u8; 32];
        let headers = signer
            .sign(&Method::POST, &uri, b"{}", Some(receipt), created, &nonce)
            .unwrap();
        assert_eq!(
            server
                .authenticate(&Method::POST, &uri, &headers, 1000)
                .is_ok(),
            accepted,
            "{created}"
        );
    }
    for nonce in [[17; 32], [18; 32]] {
        let headers = signer
            .sign(&Method::POST, &uri, b"{}", Some(receipt), 1000, &nonce)
            .unwrap();
        let auth = server
            .authenticate(&Method::POST, &uri, &headers, 1000)
            .unwrap();
        assert_eq!(auth.idempotency_key, Some(receipt));
    }
    server.revoke(signer.credential_id).unwrap();
    let headers = signer
        .sign(&Method::POST, &uri, b"{}", Some(receipt), 1000, &[19; 32])
        .unwrap();
    assert!(matches!(
        server.authenticate(&Method::POST, &uri, &headers, 1000),
        Err(ServiceError::Unauthorized(_))
    ));
}

struct HttpFixture {
    root: tempfile::TempDir,
    address: std::net::SocketAddr,
    signer: SigningIdentity,
    state: tasks_cli::server::transport::ServiceState,
    stop: Option<tokio::sync::oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl HttpFixture {
    fn new() -> Self {
        Self::with_log_file(None)
    }
    fn with_log_file(log: Option<std::fs::File>) -> Self {
        let (root, server, signer) = signed_fixture();
        let mut state = tasks_cli::server::transport::ServiceState::new(server);
        if let Some(file) = log {
            state = state.with_log_file(file);
        }
        let app = state.router();
        let (send, receive) = std::sync::mpsc::channel();
        let (stop, stopped) = tokio::sync::oneshot::channel();
        let thread = std::thread::spawn(move || {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .max_blocking_threads(8)
                .enable_all()
                .build()
                .unwrap()
                .block_on(async {
                    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
                    send.send(listener.local_addr().unwrap()).unwrap();
                    axum::serve(listener, app)
                        .with_graceful_shutdown(async {
                            let _ = stopped.await;
                        })
                        .await
                        .unwrap();
                });
        });
        Self {
            root,
            address: receive
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap(),
            signer,
            state,
            stop: Some(stop),
            thread: Some(thread),
        }
    }
    fn headers(
        &self,
        method: &Method,
        target: &str,
        body: &[u8],
        nonce: u8,
    ) -> axum::http::HeaderMap {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let uri: Uri = target.parse().unwrap();
        let key = tasks_cli::server::signatures::is_mutation(method, &uri).then(Uuid::new_v4);
        self.signer
            .sign(method, &uri, body, key, now, &[nonce; 32])
            .unwrap()
    }
    fn connect(
        &self,
        method: &Method,
        target: &str,
        headers: &axum::http::HeaderMap,
        length: usize,
    ) -> std::net::TcpStream {
        use std::io::Write;
        let mut stream = std::net::TcpStream::connect(self.address).unwrap();
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(8)))
            .unwrap();
        write!(stream,"{method} {target} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: {length}\r\n").unwrap();
        for (name, value) in headers {
            write!(stream, "{name}: {}\r\n", value.to_str().unwrap()).unwrap();
        }
        write!(stream, "\r\n").unwrap();
        stream
    }
    fn response(mut stream: std::net::TcpStream) -> String {
        use std::io::Read;
        let mut bytes = String::new();
        stream.read_to_string(&mut bytes).unwrap();
        bytes
    }
}

#[test]
fn request_logs_include_registered_actor_and_refusals_without_private_request_content() {
    use std::io::Write;
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("requests.jsonl");
    let fixture = HttpFixture::with_log_file(Some(std::fs::File::create(&path).unwrap()));
    let project = Uuid::new_v4();
    let target = format!("/v1/projects/{project}/tasks?session_title=PRIVATE_QUERY");
    let body = b"PRIVATE_BODY_AND_PROMPT";
    let mut headers = fixture.headers(&Method::POST, &target, body, 125);
    headers.insert("authorization", "Bearer PRIVATE_TOKEN".parse().unwrap());
    headers.insert("x-forwarded-user", "PRIVATE_FORGED_ACTOR".parse().unwrap());
    let mut stream = fixture.connect(&Method::POST, &target, &headers, body.len());
    stream.write_all(body).unwrap();
    assert!(HttpFixture::response(stream).starts_with("HTTP/1.1 400"));
    assert!(HttpFixture::response(fixture.connect(
        &Method::GET,
        "/v1/info",
        &Default::default(),
        0
    ))
    .starts_with("HTTP/1.1 401"));
    drop(fixture);
    let text = std::fs::read_to_string(path).unwrap();
    assert!(!text.contains("PRIVATE_"));
    assert!(!text.contains("signature") && !text.contains("content-digest"));
    let lines = text
        .lines()
        .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(lines.len(), 2);
    for line in &lines {
        assert_eq!(line.as_object().unwrap().len(), 6);
        assert!(Uuid::parse_str(line["request_id"].as_str().unwrap()).is_ok());
        assert!(line["duration_ms"].is_u64());
    }
    assert_eq!(lines[0]["actor_id"], "owner");
    assert_eq!(lines[0]["project_id"], project.to_string());
    assert_eq!(lines[0]["operation"], "task_create");
    assert_eq!(lines[0]["outcome"], "http_400");
    assert!(lines[1]["actor_id"].is_null());
    assert_eq!(lines[1]["outcome"], "http_401");
}
impl Drop for HttpFixture {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
    }
}

#[test]
fn internal_http_requires_authentication_and_consumes_nonce_before_body_failure() {
    let fixture = HttpFixture::new();
    let unsigned =
        HttpFixture::response(fixture.connect(&Method::GET, "/v1/info", &Default::default(), 0));
    assert!(unsigned.starts_with("HTTP/1.1 401"));
    let headers = fixture.headers(&Method::GET, "/v1/info", b"", 81);
    let valid = HttpFixture::response(fixture.connect(&Method::GET, "/v1/info", &headers, 0));
    assert!(valid.starts_with("HTTP/1.1 200"), "{valid}");
    assert!(valid.contains(&fixture.signer.server_id.to_string()));
    assert!(valid.contains("\"ready\":true"));
    let replay = HttpFixture::response(fixture.connect(&Method::GET, "/v1/info", &headers, 0));
    assert!(replay.starts_with("HTTP/1.1 401"));
    let headers = fixture.headers(&Method::GET, "/v1/info", b"good", 82);
    let mut stream = fixture.connect(&Method::GET, "/v1/info", &headers, 4);
    std::io::Write::write_all(&mut stream, b"evil").unwrap();
    let mismatch = HttpFixture::response(stream);
    assert!(mismatch.starts_with("HTTP/1.1 401"));
    let consumed = HttpFixture::response(fixture.connect(&Method::GET, "/v1/info", &headers, 0));
    assert!(consumed.starts_with("HTTP/1.1 401"));
    let unknown = HttpFixture::response(fixture.connect(
        &Method::GET,
        "/v1/projects/unknown",
        &Default::default(),
        0,
    ));
    assert!(unknown.starts_with("HTTP/1.1 401"));
    let oversized_headers = fixture.headers(&Method::GET, "/v1/info", b"", 83);
    let oversized = HttpFixture::response(fixture.connect(
        &Method::GET,
        "/v1/info",
        &oversized_headers,
        tasks_cli::server::transport::MAX_BODY_BYTES + 1,
    ));
    // to_bytes bounds streamed bytes; a declared oversized body is rejected
    // before waiting for them by the transport's Content-Length precheck.
    assert!(oversized.starts_with("HTTP/1.1 413"), "{oversized}");
}

#[test]
fn http_capacity_is_bounded_and_shutdown_refuses_new_writes() {
    let fixture = HttpFixture::new();
    let mut held = Vec::new();
    for nonce in 90..98 {
        let headers = fixture.headers(&Method::GET, "/v1/info", b"x", nonce);
        held.push(fixture.connect(&Method::GET, "/v1/info", &headers, 1));
    }
    // Observe authentication of all eight without relying on a scheduling sleep.
    let started = std::time::Instant::now();
    loop {
        let connection =
            rusqlite::Connection::open(fixture.root.path().join("server.sqlite")).unwrap();
        let count: i64 = connection
            .query_row("SELECT count(*) FROM replay_nonces", [], |r| r.get(0))
            .unwrap();
        if count == 8 {
            break;
        }
        assert!(started.elapsed() < std::time::Duration::from_secs(5));
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let headers = fixture.headers(&Method::GET, "/v1/info", b"", 98);
    let capacity = HttpFixture::response(fixture.connect(&Method::GET, "/v1/info", &headers, 0));
    assert!(capacity.starts_with("HTTP/1.1 503"));
    assert!(capacity.contains("capacity"));
    drop(held);
    fixture.state.begin_shutdown();
    let headers = fixture.headers(&Method::POST, "/v1/projects", b"{}", 99);
    let response =
        HttpFixture::response(fixture.connect(&Method::POST, "/v1/projects", &headers, 0));
    assert!(response.starts_with("HTTP/1.1 503"));
    assert!(response.contains("shutting_down"));
}

fn registration() -> Registration {
    Registration {
        public_key: SigningKey::from_bytes(&[7; 32]).verifying_key().to_bytes(),
        actor_id: "owner".into(),
        actor_name: "Owner".into(),
        installation_id: Uuid::new_v4(),
        installation_name: "test machine".into(),
    }
}

#[test]
fn server_identity_persists_and_process_ownership_excludes_administration() {
    let root = tempfile::tempdir().unwrap();
    assert!(OwnedServer::open(root.path()).is_err());
    let server = OwnedServer::initialize(root.path()).unwrap();
    let id = server.server_id();
    assert!(matches!(
        OwnedServer::open(root.path()),
        Err(ServiceError::Storage(_))
    ));
    assert!(OwnedServer::initialize(root.path()).is_err());
    drop(server);
    let reopened = OwnedServer::open(root.path()).unwrap();
    assert_eq!(reopened.server_id(), id);
    let other = tempfile::tempdir().unwrap();
    assert_ne!(
        OwnedServer::initialize(other.path()).unwrap().server_id(),
        id
    );
}

#[test]
fn global_replay_capacity_and_real_admin_process_exclusion_are_enforced() {
    let (root, server, signer) = signed_fixture();
    let admin = support::process::command(env!("CARGO_BIN_EXE_tasks-server"))
        .args([
            "--data-root",
            root.path().to_str().unwrap(),
            "admin",
            "info",
        ])
        .output()
        .unwrap();
    assert_eq!(admin.status.code(), Some(5));
    assert!(String::from_utf8_lossy(&admin.stderr).contains("held by another tasks process"));
    let connection = rusqlite::Connection::open(root.path().join("server.sqlite")).unwrap();
    for _ in 0..16 {
        let credential = server.register(&registration()).unwrap();
        connection.execute("WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<4095) INSERT INTO replay_nonces(credential_id,nonce,expires) SELECT ?1,CAST(i AS TEXT),1120 FROM n",[credential.to_string()]).unwrap();
    }
    assert!(matches!(
        server.consume_nonce(signer.credential_id, "new", 1120, 1000),
        Err(ServiceError::Capacity)
    ));
    let uri: Uri = "/v1/info".parse().unwrap();
    let mut headers = signer
        .sign(&Method::GET, &uri, b"", None, 1000, &[6; 32])
        .unwrap();
    headers.insert("signature", HeaderValue::from_static("tasks=:AA==:"));
    assert!(matches!(
        server.authenticate(&Method::GET, &uri, &headers, 1000),
        Err(ServiceError::Unauthorized(_))
    ));
    let count: i64 = connection
        .query_row("SELECT count(*) FROM replay_nonces", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 65536);
}

#[test]
fn opening_damaged_auth_schema_refuses_missing_audit_protection() {
    let root = tempfile::tempdir().unwrap();
    drop(OwnedServer::initialize(root.path()).unwrap());
    let connection = rusqlite::Connection::open(root.path().join("server.sqlite")).unwrap();
    connection
        .execute_batch("DROP TRIGGER admin_events_no_delete")
        .unwrap();
    drop(connection);
    assert!(OwnedServer::open(root.path()).is_err());
}

#[test]
fn credential_revocation_and_append_only_admin_audit_survive_restart() {
    let root = tempfile::tempdir().unwrap();
    let server = OwnedServer::initialize(root.path()).unwrap();
    let registration = registration();
    let credential = server.register(&registration).unwrap();
    assert_eq!(server.credential(credential).unwrap().actor_id, "owner");
    server.revoke(credential).unwrap();
    assert!(matches!(
        server.credential(credential),
        Err(ServiceError::Unauthorized(_))
    ));
    let replacement = server.register(&registration).unwrap();
    assert_ne!(credential, replacement);
    assert_eq!(
        server.credential(replacement).unwrap().installation_id,
        registration.installation_id
    );
    let connection = rusqlite::Connection::open(root.path().join("server.sqlite")).unwrap();
    let count: i64 = connection
        .query_row(
            "SELECT count(*) FROM admin_events WHERE os_actor IS NOT NULL",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 4);
    assert!(connection.execute("DELETE FROM admin_events", []).is_err());
    assert!(connection
        .execute("UPDATE admin_events SET operation='changed'", [])
        .is_err());
    drop(connection);
    drop(server);
    assert!(OwnedServer::open(root.path())
        .unwrap()
        .credential(credential)
        .is_err());
}

#[test]
fn replay_consumption_is_atomic_persistent_and_never_evicts_live_entries() {
    let root = tempfile::tempdir().unwrap();
    let server = OwnedServer::initialize(root.path()).unwrap();
    let credential = server.register(&registration()).unwrap();
    server
        .consume_nonce(credential, "nonce", 1120, 1000)
        .unwrap();
    assert!(matches!(
        server.consume_nonce(credential, "nonce", 1120, 1000),
        Err(ServiceError::Unauthorized(_))
    ));
    drop(server);
    let server = OwnedServer::open(root.path()).unwrap();
    assert!(server
        .consume_nonce(credential, "nonce", 1120, 1000)
        .is_err());
    let connection = rusqlite::Connection::open(root.path().join("server.sqlite")).unwrap();
    connection.execute_batch("BEGIN IMMEDIATE").unwrap();
    let mut statement = connection
        .prepare("INSERT INTO replay_nonces(credential_id,nonce,expires) VALUES (?1,?2,1120)")
        .unwrap();
    for i in 1..4096 {
        statement
            .execute(rusqlite::params![credential.to_string(), format!("n{i}")])
            .unwrap();
    }
    drop(statement);
    connection.execute_batch("COMMIT").unwrap();
    assert!(matches!(
        server.consume_nonce(credential, "over-capacity", 1120, 1000),
        Err(ServiceError::Capacity)
    ));
    assert!(server
        .consume_nonce(credential, "nonce", 1120, 1000)
        .is_err());
    // At the inclusive skew boundary old entries must still be retained.
    assert!(matches!(
        server.consume_nonce(credential, "boundary", 1270, 1150),
        Err(ServiceError::Capacity)
    ));
    server
        .consume_nonce(credential, "after-expiry", 1271, 1151)
        .unwrap();
}
