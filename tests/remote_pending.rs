#![cfg(feature = "remote")]
use tasks_cli::remote::pending::{PendingStore, PendingWrite};
use uuid::Uuid;

#[test]
fn private_pending_requests_survive_reload_and_refuse_identity_changes() {
    let root = tempfile::tempdir().unwrap();
    let store = PendingStore::new(root.path()).unwrap();
    let request = PendingWrite::new(
        Uuid::new_v4(),
        Uuid::new_v4(),
        "POST",
        "/v1/projects",
        serde_json::json!({"project_id":Uuid::new_v4(),"name":"exact"}),
    )
    .unwrap();
    store.save(&request).unwrap();
    assert!(store.save(&request).is_err());
    let loaded = store.load(request.request_id).unwrap();
    assert_eq!(loaded.bytes().unwrap(), request.bytes().unwrap());
    assert!(loaded
        .check_destination(Uuid::new_v4(), request.credential_id)
        .is_err());
    assert!(loaded
        .check_destination(request.server_id, Uuid::new_v4())
        .is_err());
    assert_eq!(store.list().unwrap(), vec![request.request_id]);
    store.remove(request.request_id).unwrap();
    assert!(store.list().unwrap().is_empty());
}

#[test]
fn malformed_or_oversized_pending_requests_never_become_arbitrary_signed_calls() {
    for (method, target) in [
        ("GET", "/v1/info"),
        ("POST", "https://other.invalid/v1/projects"),
        ("DELETE", "/v1/projects"),
        ("POST", "/v1/projects?private=query"),
    ] {
        assert!(PendingWrite::new(
            Uuid::new_v4(),
            Uuid::new_v4(),
            method,
            target,
            serde_json::json!({})
        )
        .is_err());
    }
    assert!(PendingWrite::new(
        Uuid::new_v4(),
        Uuid::new_v4(),
        "POST",
        "/v1/projects",
        serde_json::json!({"name":"x".repeat(8*1024*1024)})
    )
    .is_err());
}
