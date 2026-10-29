#![cfg(feature = "server")]

use std::sync::{Arc, Barrier};
use tasks_cli::server::{OwnedServer, Registration, ServiceError};
use uuid::Uuid;

#[test]
fn concurrent_nonce_admission_releases_transactions_and_observes_revocation() {
    let root = tempfile::tempdir().unwrap();
    let server = Arc::new(OwnedServer::initialize(root.path()).unwrap());
    let registration = Registration {
        public_key: ed25519_dalek::SigningKey::from_bytes(&[73; 32])
            .verifying_key()
            .to_bytes(),
        actor_id: "fixture".into(),
        actor_name: "Fixture".into(),
        installation_id: Uuid::new_v4(),
        installation_name: "Fixture".into(),
    };
    let credential = server.register(&registration).unwrap();
    let barrier = Arc::new(Barrier::new(8));
    let workers: Vec<_> = (0..8)
        .map(|worker| {
            let server = Arc::clone(&server);
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                barrier.wait();
                let admitted = match server.consume_nonce(credential, "shared", 1120, 1000) {
                    Ok(()) => true,
                    Err(ServiceError::Unauthorized(_)) => false,
                    other => panic!("unexpected admission result: {other:?}"),
                };
                for nonce in 0..16 {
                    server
                        .consume_nonce(credential, &format!("{worker}-{nonce}"), 1120, 1000)
                        .unwrap();
                }
                admitted
            })
        })
        .collect();
    let admitted = workers
        .into_iter()
        .map(|worker| usize::from(worker.join().unwrap()))
        .sum::<usize>();
    assert_eq!(admitted, 1);

    let connection = rusqlite::Connection::open(root.path().join("server.sqlite")).unwrap();
    let count: i64 = connection
        .query_row("SELECT count(*) FROM replay_nonces", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 129);
    let busy: i64 = connection
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get(0))
        .unwrap();
    assert_eq!(
        busy, 0,
        "admissions must not retain a transaction or snapshot"
    );

    // A retained writer must see revocation committed on another connection.
    server.revoke(credential).unwrap();
    assert!(matches!(
        server.consume_nonce(credential, "revoked", 1120, 1000),
        Err(ServiceError::Unauthorized(_))
    ));
    let replacement = server.register(&registration).unwrap();
    server
        .consume_nonce(replacement, "replacement", 1120, 1000)
        .unwrap();
    drop(connection);
    drop(server);
    let recovered = OwnedServer::open(root.path()).unwrap();
    assert!(matches!(
        recovered.consume_nonce(replacement, "replacement", 1120, 1000),
        Err(ServiceError::Unauthorized(_))
    ));
}
