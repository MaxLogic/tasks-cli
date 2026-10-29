#![cfg(feature = "server")]
mod support;

use ed25519_dalek::SigningKey;
use http::{Method, Uri};
use std::{
    io::{Read, Write},
    process::Child,
    time::{Duration, Instant},
};
use tasks_cli::server::{signatures::SigningIdentity, OwnedServer, Registration, ServiceError};
use uuid::Uuid;

struct Process(Child);
impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn replay_wal_is_reused_and_committed_nonce_survives_server_kill() {
    let root = tempfile::tempdir().unwrap();
    let server = OwnedServer::initialize(root.path()).unwrap();
    let key = SigningKey::from_bytes(&[41; 32]);
    let credential = server
        .register(&Registration {
            public_key: key.verifying_key().to_bytes(),
            actor_id: "fixture".into(),
            actor_name: "Fixture".into(),
            installation_id: Uuid::new_v4(),
            installation_name: "Fixture".into(),
        })
        .unwrap();
    let signer = SigningIdentity {
        credential_id: credential,
        server_id: server.server_id(),
        key,
    };
    drop(server);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let mut process = Process(
        support::process::command(env!("CARGO_BIN_EXE_tasks-server"))
            .args([
                "--data-root",
                root.path().to_str().unwrap(),
                "serve",
                "--listen",
                &address.to_string(),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::fs::File::create(root.path().join("server.log")).unwrap())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    while std::net::TcpStream::connect(address).is_err() {
        assert!(
            process.0.try_wait().unwrap().is_none(),
            "server startup failed"
        );
        assert!(Instant::now() < deadline, "server startup deadline");
        std::thread::sleep(Duration::from_millis(10));
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let uri: Uri = "/v1/info".parse().unwrap();
    let mut signed = Vec::new();
    let wal = root.path().join("server.sqlite-wal");
    let mut previous_bytes = 0;
    for nonce in [1, 2] {
        let headers = signer
            .sign(&Method::GET, &uri, b"", None, now, &[nonce; 32])
            .unwrap();
        let mut stream = std::net::TcpStream::connect(address).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        write!(stream, "GET /v1/info HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 0\r\n").unwrap();
        for (name, value) in &headers {
            write!(stream, "{name}: {}\r\n", value.to_str().unwrap()).unwrap();
        }
        write!(stream, "\r\n").unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        let bytes = std::fs::metadata(&wal).expect("nonce admission must reuse WAL rather than checkpoint and unlink it on every request").len();
        assert!(
            bytes > previous_bytes,
            "second request should append to the existing WAL"
        );
        previous_bytes = bytes;
        signed.push(headers);
    }
    // A project route reads the catalog through the retained connection, so
    // the checkpoint below also proves that those reads release their snapshot.
    let project_uri: Uri = format!("/v1/projects/{}/tasks/1/attachments/1", Uuid::new_v4())
        .parse()
        .unwrap();
    let headers = signer
        .sign(&Method::GET, &project_uri, b"", None, now, &[4; 32])
        .unwrap();
    let mut stream = std::net::TcpStream::connect(address).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    write!(
        stream,
        "GET {project_uri} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
    )
    .unwrap();
    for (name, value) in &headers {
        write!(stream, "{name}: {}\r\n", value.to_str().unwrap()).unwrap();
    }
    write!(stream, "\r\n").unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    assert!(
        response.starts_with("HTTP/1.1 404"),
        "an admitted request for an unknown project must reach the catalog: {response}"
    );
    // The retained connection must not pin a read snapshot or prevent SQLite's
    // normal checkpointing. Do this before one more admitted nonce, so crash
    // recovery still has to recover a committed record from an uncheckpointed WAL.
    let checkpoint = rusqlite::Connection::open(root.path().join("server.sqlite")).unwrap();
    let busy: i64 = checkpoint
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get(0))
        .unwrap();
    assert_eq!(busy, 0, "idle anchor must not block checkpoints");
    drop(checkpoint);
    let headers = signer
        .sign(&Method::GET, &uri, b"", None, now, &[3; 32])
        .unwrap();
    let mut stream = std::net::TcpStream::connect(address).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    write!(
        stream,
        "GET /v1/info HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 0\r\n"
    )
    .unwrap();
    for (name, value) in &headers {
        write!(stream, "{name}: {}\r\n", value.to_str().unwrap()).unwrap();
    }
    write!(stream, "\r\n").unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    signed.push(headers);
    // Terminate without dropping the server's SQLite connections. Successful
    // admission must remain durable in the WAL, without a shutdown checkpoint.
    process.0.kill().unwrap();
    process.0.wait().unwrap();
    let recovered = OwnedServer::open(root.path()).unwrap();
    for headers in &signed {
        assert!(matches!(
            recovered.authenticate(&Method::GET, &uri, headers, now),
            Err(ServiceError::Unauthorized(_))
        ));
    }
    let db = rusqlite::Connection::open(root.path().join("server.sqlite")).unwrap();
    let count: i64 = db
        .query_row("SELECT count(*) FROM replay_nonces", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 4);
}
