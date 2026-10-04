#![cfg(feature = "remote")]
use tasks_cli::remote::config::{load, Profile};

#[test]
fn absent_profile_is_local_and_invalid_profiles_fail_closed() {
    let root = tempfile::tempdir().unwrap();
    assert!(matches!(load(root.path()).unwrap(), Profile::Local));
    for contents in [
        "",
        "backend='unknown'",
        "backend='local'\nserver_url='https://localhost'",
        "backend='remote'",
        "backend='local'\nbackend='local'",
    ] {
        std::fs::write(root.path().join("client.toml"), contents).unwrap();
        assert!(load(root.path()).is_err(), "{contents}");
    }
}

#[cfg(unix)]
#[test]
fn dangling_profile_is_invalid_instead_of_selecting_local_sqlite() {
    let root = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(
        root.path().join("missing-profile"),
        root.path().join("client.toml"),
    )
    .unwrap();
    assert!(load(root.path()).is_err());
}

#[test]
fn remote_profile_checks_destination_identity_paths_and_timeouts() {
    let root = tempfile::tempdir().unwrap();
    let credential = root.path().join("key.pem");
    let base = format!("backend='remote'\nserver_url='https://localhost:8443'\nserver_id='{}'\ncredential_id='{}'\ncredential_file={}\n", uuid::Uuid::new_v4(), uuid::Uuid::new_v4(), serde_json::to_string(&credential.to_string_lossy()).unwrap());
    std::fs::write(root.path().join("client.toml"), &base).unwrap();
    assert!(matches!(load(root.path()).unwrap(), Profile::Remote { .. }));
    for contents in [
        base.replace("https://", "http://"),
        format!("{base}request_timeout_seconds=0\n"),
        base.replace(
            &serde_json::to_string(&credential.to_string_lossy()).unwrap(),
            "'relative.pem'",
        ),
        format!("{base}unrecognized=true\n"),
    ] {
        std::fs::write(root.path().join("client.toml"), contents).unwrap();
        assert!(load(root.path()).is_err());
    }
}
