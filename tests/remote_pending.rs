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

#[test]
fn attachment_pending_identity_is_recorded_and_legacy_files_remain_replayable() {
    for detach in [false, true] {
        let root = tempfile::tempdir().unwrap();
        let store = PendingStore::new(root.path()).unwrap();
        let target = format!(
            "/v1/projects/{}/tasks/7/attachments{}",
            Uuid::new_v4(),
            if detach { "/detach" } else { "" }
        );
        let body = b"exact retained body";
        let request = if detach {
            PendingWrite::new(
                Uuid::new_v4(),
                Uuid::new_v4(),
                "POST",
                &target,
                serde_json::json!({"expect_version":4,"attachments":[3]}),
            )
            .unwrap()
        } else {
            PendingWrite::binary(Uuid::new_v4(), Uuid::new_v4(), &target, body).unwrap()
        };
        if detach {
            store.save(&request).unwrap();
        } else {
            store.save_binary(&request, body).unwrap();
        }
        let path = root
            .path()
            .join(format!("client/pending/{}.json", request.request_id));
        let mut stored: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(stored["task_id"], 7);
        assert_eq!(stored["format_version"], if detach { 1 } else { 2 });
        stored.as_object_mut().unwrap().remove("task_id");
        std::fs::write(&path, serde_json::to_vec(&stored).unwrap()).unwrap();
        let legacy = store.load(request.request_id).unwrap();
        assert_eq!(legacy.bytes().unwrap(), request.bytes().unwrap());
        assert_eq!(
            legacy.payload_sha256().unwrap(),
            request.payload_sha256().unwrap()
        );
        if !detach {
            assert_eq!(store.load_body(&legacy).unwrap(), body);
        }
        for invalid_identity in [
            serde_json::json!(0),
            serde_json::json!(8),
            serde_json::json!("7"),
        ] {
            stored["task_id"] = invalid_identity;
            std::fs::write(&path, serde_json::to_vec(&stored).unwrap()).unwrap();
            assert!(store.load(request.request_id).is_err());
        }
    }
}
