#![cfg(feature = "server")]
use axum::http::Method;
use ed25519_dalek::SigningKey;
use tasks_cli::remote::https::{ClientError, ClientOptions, HttpsClient};
use tasks_cli::server::signatures::SigningIdentity;
use uuid::Uuid;

fn identity() -> SigningIdentity {
    SigningIdentity {
        credential_id: Uuid::new_v4(),
        server_id: Uuid::new_v4(),
        key: SigningKey::from_bytes(&[5; 32]),
    }
}

#[test]
fn configuration_rejects_http_credentials_fragments_and_invalid_timeouts() {
    for url in [
        "http://127.0.0.1",
        "https://user:secret@localhost",
        "https://localhost/path",
        "https://localhost?token=secret",
        "https://localhost#fragment",
    ] {
        assert!(
            matches!(
                HttpsClient::new(url, ClientOptions::default(), identity()),
                Err(ClientError::Configuration(_))
            ),
            "{url}"
        );
    }
    assert!(HttpsClient::new(
        "https://localhost",
        ClientOptions {
            request_timeout: std::time::Duration::ZERO,
            ..Default::default()
        },
        identity()
    )
    .is_err());
}

#[test]
fn trusted_ca_accepts_valid_host_and_rejects_untrusted_wrong_host_and_expired_certificates() {
    let valid = TlsFixture::new("localhost", false, Reply::Ok);
    let client = HttpsClient::new(&valid.url(), valid.options(), identity()).unwrap();
    let response = client.send(Method::GET, "/v1/info", b"", None).unwrap();
    assert_eq!(response.status, 200);
    assert_eq!(response.body, b"{\"fixture\":true}");
    assert!(matches!(
        HttpsClient::new(&valid.url(), ClientOptions::default(), identity())
            .unwrap()
            .send(Method::GET, "/v1/info", b"", None),
        Err(ClientError::Transport)
    ));
    assert_eq!(valid.requests(), 1);
    let wrong = TlsFixture::new("other.invalid", false, Reply::Ok);
    assert!(matches!(
        HttpsClient::new(&wrong.url(), wrong.options(), identity())
            .unwrap()
            .send(Method::GET, "/v1/info", b"", None),
        Err(ClientError::Transport)
    ));
    assert_eq!(wrong.requests(), 0);
    let expired = TlsFixture::new("localhost", true, Reply::Ok);
    assert!(matches!(
        HttpsClient::new(&expired.url(), expired.options(), identity())
            .unwrap()
            .send(Method::GET, "/v1/info", b"", None),
        Err(ClientError::Transport)
    ));
    assert_eq!(expired.requests(), 0);
}

#[test]
fn redirects_never_forward_signatures_and_responses_are_bounded() {
    let target = TlsFixture::new("localhost", false, Reply::Ok);
    let redirect = TlsFixture::new("localhost", false, Reply::Redirect(target.url()));
    let response = HttpsClient::new(&redirect.url(), redirect.options(), identity())
        .unwrap()
        .send(Method::GET, "/v1/info", b"", None);
    assert!(matches!(response, Err(ClientError::Redirect)));
    assert_eq!(target.requests(), 0);
    let large = TlsFixture::new("localhost", false, Reply::Large);
    assert!(matches!(
        HttpsClient::new(&large.url(), large.options(), identity())
            .unwrap()
            .send(Method::GET, "/v1/info", b"", None),
        Err(ClientError::ResponseLimit)
    ));
    let streamed = TlsFixture::new("localhost", false, Reply::LargeStream);
    assert!(matches!(
        HttpsClient::new(&streamed.url(), streamed.options(), identity())
            .unwrap()
            .send(Method::GET, "/v1/info", b"", None),
        Err(ClientError::ResponseLimit)
    ));
}

#[test]
fn request_timeout_does_not_resend_an_admitted_write() {
    let fixture = TlsFixture::new("localhost", false, Reply::Stall);
    let mut options = fixture.options();
    options.request_timeout = std::time::Duration::from_millis(500);
    let client = HttpsClient::new(&fixture.url(), options, identity()).unwrap();
    let started = std::time::Instant::now();
    assert!(matches!(
        client.send(Method::POST, "/v1/projects", b"{}", Some(Uuid::new_v4())),
        Err(ClientError::Transport)
    ));
    assert!(started.elapsed() < std::time::Duration::from_millis(1500));
    assert_eq!(fixture.requests(), 1);
}

#[test]
fn signed_https_round_trip_preserves_encoded_components_and_registered_destination() {
    use tasks_cli::server::{OwnedServer, Registration};
    let root = tempfile::tempdir().unwrap();
    let server = OwnedServer::initialize(root.path()).unwrap();
    let mut signer = identity();
    signer.server_id = server.server_id();
    signer.credential_id = server
        .register(&Registration {
            public_key: signer.key.verifying_key().to_bytes(),
            actor_id: "owner".into(),
            actor_name: "Owner".into(),
            installation_id: Uuid::new_v4(),
            installation_name: "fixture".into(),
        })
        .unwrap();
    let fixture = TlsFixture::new("localhost", false, Reply::Authenticate(server));
    let client = HttpsClient::new(&fixture.url(), fixture.options(), signer).unwrap();
    let receipt = Uuid::new_v4();
    let response = client
        .send(
            Method::POST,
            "/v1/projects/abc/tasks?encoded=%2F&empty=",
            b"exact private body",
            Some(receipt),
        )
        .unwrap();
    assert_eq!(response.status, 200);
    assert_eq!(fixture.requests(), 1);
    assert!(matches!(
        client.send(Method::GET, "/v1/../other", b"", None),
        Err(ClientError::Configuration(_))
    ));
}

#[test]
fn tls_gateway_forwards_signatures_to_the_actual_private_rust_listener() {
    use tasks_cli::server::{transport::ServiceState, OwnedServer, Registration};
    let root = tempfile::tempdir().unwrap();
    let server = OwnedServer::initialize(root.path()).unwrap();
    let mut signer = identity();
    signer.server_id = server.server_id();
    signer.credential_id = server
        .register(&Registration {
            public_key: signer.key.verifying_key().to_bytes(),
            actor_id: "owner".into(),
            actor_name: "Owner".into(),
            installation_id: Uuid::new_v4(),
            installation_name: "fixture".into(),
        })
        .unwrap();
    let backend = HttpBackend::new(ServiceState::new(server));
    let gateway = TlsFixture::new("localhost", false, Reply::Proxy(backend.address));
    let client = HttpsClient::new(&gateway.url(), gateway.options(), signer).unwrap();
    let info = client.send(Method::GET, "/v1/info", b"", None).unwrap();
    assert_eq!(info.status, 200);
    let value: serde_json::Value = serde_json::from_slice(&info.body).unwrap();
    assert_eq!(value["ready"], true);
    let target = format!("/v1/projects/{}/tasks?encoded=%2F", Uuid::new_v4());
    let write = client
        .send(
            Method::POST,
            &target,
            b"private exact payload",
            Some(Uuid::new_v4()),
        )
        .unwrap();
    // The signature and body passed verification; application dispatch refuses
    // unsupported query parameters. 401 would expose forwarding damage.
    assert_eq!(write.status, 400);

    // A legitimate SQLite wait may exceed the gateway fixture's old three-second
    // read timeout. It must reach the client under the production five-second
    // busy bound rather than being converted into a lost transport response.
    let path = root.path().join("server.sqlite");
    let (ready, locked) = std::sync::mpsc::channel();
    let lock = std::thread::spawn(move || {
        let connection = rusqlite::Connection::open(path).unwrap();
        connection.execute_batch("BEGIN IMMEDIATE").unwrap();
        ready.send(()).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(3300));
        connection.execute_batch("ROLLBACK").unwrap();
    });
    locked
        .recv_timeout(std::time::Duration::from_secs(1))
        .unwrap();
    let waited = client.send(Method::GET, "/v1/info", b"", None);
    lock.join().unwrap();
    assert_eq!(waited.unwrap().status, 200);
}

#[test]
fn complete_large_export_streams_through_tls_without_a_whole_response_buffer() {
    use sha2::{Digest, Sha256};
    use std::io::Write;
    use tasks_cli::{
        model::TaskStatus,
        remote::https::RemoteExportResponse,
        server::{api, transport::ServiceState, OwnedServer, Registration},
        store::Store,
    };
    let root = tempfile::tempdir().unwrap();
    let server = OwnedServer::initialize(root.path()).unwrap();
    let mut signer = identity();
    signer.server_id = server.server_id();
    signer.credential_id = server
        .register(&Registration {
            public_key: signer.key.verifying_key().to_bytes(),
            actor_id: "owner".into(),
            actor_name: "Owner".into(),
            installation_id: Uuid::new_v4(),
            installation_name: "fixture".into(),
        })
        .unwrap();
    let project = Uuid::new_v4();
    let uri = "/v1/projects".parse().unwrap();
    let bytes =
        serde_json::to_vec(&serde_json::json!({"project_id":project,"name":"export fixture"}))
            .unwrap();
    let headers = signer
        .sign_now(&Method::POST, &uri, &bytes, Some(Uuid::new_v4()))
        .unwrap();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let auth = server
        .authenticate(&Method::POST, &uri, &headers, now)
        .unwrap();
    assert_eq!(
        api::handle(&server, &auth, &Method::POST, &uri, &bytes)
            .unwrap()
            .status,
        200
    );
    let mut store = Store::open_rw(root.path(), &project.to_string()).unwrap();
    store.rules_set("exact rules Ω\r\n", 1).unwrap();
    for index in 0..20 {
        store
            .create_task(
                &format!("large {index}"),
                &"x".repeat(1024 * 1024),
                TaskStatus::Ready,
                vec![],
            )
            .unwrap();
    }
    struct Probe {
        digest: Sha256,
        bytes: u64,
        largest_write: usize,
    }
    impl Write for Probe {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.digest.update(bytes);
            self.bytes += bytes.len() as u64;
            self.largest_write = self.largest_write.max(bytes.len());
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut expected = Probe {
        digest: Sha256::new(),
        bytes: 0,
        largest_write: 0,
    };
    assert_eq!(store.write_markdown(&mut expected).unwrap(), 20);
    drop(store);
    let backend = HttpBackend::new(ServiceState::new(server));
    let gateway = TlsFixture::new("localhost", false, Reply::Proxy(backend.address));
    let client = HttpsClient::new(&gateway.url(), gateway.options(), signer).unwrap();
    let mut received = Probe {
        digest: Sha256::new(),
        bytes: 0,
        largest_write: 0,
    };
    let RemoteExportResponse::Complete(summary) = client.export(project, &mut received).unwrap()
    else {
        panic!("export refused")
    };
    assert_eq!(summary.task_count, 20);
    assert_eq!(received.bytes, expected.bytes);
    assert!(received.bytes > 16 * 1024 * 1024);
    assert!(received.largest_write <= tasks_cli::remote::export::CHUNK_BYTES);
    assert_eq!(received.digest.finalize(), expected.digest.finalize());
    assert_eq!(gateway.requests(), 1);
}

mod support;
use support::https::{HttpBackend, Reply, TlsFixture};
