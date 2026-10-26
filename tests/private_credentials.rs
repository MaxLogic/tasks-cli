#![cfg(feature = "remote")]
use tasks_cli::remote::credentials::{generate_key, load_key};

fn client_key_error(path: &std::path::Path) -> tasks_cli::AppError {
    use tasks_cli::remote::{client::RemoteClient, config::Profile};
    let profile = Profile::Remote {
        server_url: "https://localhost:8443".into(),
        server_id: uuid::Uuid::new_v4(),
        credential_id: uuid::Uuid::new_v4(),
        credential_file: path.to_path_buf(),
        private_ca: None,
        connect_timeout_seconds: 3,
        request_timeout_seconds: 15,
    };
    let error = RemoteClient::new(&profile).err().expect("key refused");
    assert_eq!(error.code(), "remote_credential");
    assert_eq!(error.exit_code(), 5);
    let json: serde_json::Value = serde_json::from_str(&error.json()).unwrap();
    assert_eq!(json["error"]["code"], "remote_credential");
    error
}

#[test]
fn client_distinguishes_missing_invalid_encoding_and_oversized_keys() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("keys");
    generate_key(&directory).unwrap();
    let missing = client_key_error(&directory.join("missing.pem")).to_string();
    let mut failures = Vec::new();
    if !missing.contains("missing") || !missing.contains("credential_file") {
        failures.push(format!("missing: {missing}"));
    }
    let path = directory.join("signing-key.pem");
    for (bytes, cause) in [
        (vec![0xff, 0xfe], "UTF-8"),
        (b"PRIVATE_SENTINEL_MUST_NOT_APPEAR".to_vec(), "PKCS#8"),
        (vec![b'x'; 16385], "16 KiB"),
    ] {
        std::fs::write(&path, bytes).unwrap();
        let message = client_key_error(&path).to_string();
        if !message.contains(cause) || !message.contains("restore") {
            failures.push(format!("{cause}: {message}"));
        }
        assert!(!message.contains("PRIVATE_SENTINEL"), "{message}");
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[cfg(windows)]
#[test]
fn windows_sixteen_key_loads_can_overlap_a_protected_reader() {
    use std::{fs::OpenOptions, os::windows::fs::OpenOptionsExt, sync::Barrier};
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("keys");
    let public = generate_key(&directory).unwrap();
    let path = directory.join("signing-key.pem");
    // Keep a real reader open throughout all loads. No scheduler timing or
    // retries can hide an exclusive-open regression.
    let reader = OpenOptions::new()
        .read(true)
        .share_mode(1)
        .open(&path)
        .unwrap();
    tasks_cli::private_fs::validate_file(&reader).unwrap();
    let barrier = Barrier::new(16);
    std::thread::scope(|scope| {
        let workers: Vec<_> = (0..16)
            .map(|_| {
                let (barrier, path) = (&barrier, &path);
                scope.spawn(move || {
                    barrier.wait();
                    load_key(path).map(|key| key.verifying_key().to_bytes())
                })
            })
            .collect();
        // Join every worker before asserting, also on failure.
        let results: Vec<_> = workers.into_iter().map(|w| w.join().unwrap()).collect();
        let failures: Vec<_> = results.iter().filter_map(|r| r.as_ref().err()).collect();
        assert!(
            failures.is_empty(),
            "{} of 16 key loads failed: {failures:?}",
            failures.len()
        );
        for result in results {
            assert_eq!(result.unwrap(), public);
        }
    });
}

#[cfg(windows)]
#[test]
fn windows_client_reports_locked_key_without_retrying_or_blame_on_encoding() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("keys");
    generate_key(&directory).unwrap();
    let path = directory.join("signing-key.pem");
    let _exclusive = tasks_cli::private_fs::open_file(&path).unwrap();
    let error = client_key_error(&path);
    let message = error.to_string();
    assert!(message.contains("locked"), "{message}");
    assert!(message.contains("retry"), "{message}");
    assert!(!message.contains("encoding"), "{message}");
}

#[cfg(windows)]
#[test]
fn windows_key_and_parent_directory_reparse_points_are_refused() {
    use std::os::windows::fs::{symlink_dir, symlink_file};
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("keys");
    generate_key(&directory).unwrap();
    let key_link = directory.join("key-link.pem");
    symlink_file(directory.join("signing-key.pem"), &key_link).unwrap();
    let key_result = load_key(&key_link);
    std::fs::remove_file(&key_link).unwrap();
    assert!(key_result
        .err()
        .unwrap()
        .to_string()
        .contains("permissions are insecure"));
    let directory_link = root.path().join("keys-link");
    symlink_dir(&directory, &directory_link).unwrap();
    let directory_result = load_key(&directory_link.join("signing-key.pem"));
    std::fs::remove_dir(&directory_link).unwrap();
    assert!(directory_result
        .err()
        .unwrap()
        .to_string()
        .contains("permissions are insecure"));
}

#[cfg(windows)]
#[test]
fn windows_empty_and_denied_key_dacls_are_refused() {
    use windows_permissions::constants::{SeObjectType::SE_FILE_OBJECT, SecurityInformation};
    use windows_permissions::{wrappers, LocalBox, SecurityDescriptor};
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("keys");
    generate_key(&directory).unwrap();
    let path = directory.join("signing-key.pem");
    // The owner retains implicit WRITE_DAC, so restore the original DACL
    // before assertions and teardown even when read access is denied.
    let original =
        wrappers::GetNamedSecurityInfo(path.as_os_str(), SE_FILE_OBJECT, SecurityInformation::Dacl)
            .unwrap();
    for sddl in ["D:P", "D:P(D;;FR;;;WD)"] {
        let opened = std::fs::File::open(&path).unwrap();
        let descriptor: LocalBox<SecurityDescriptor> = sddl.parse().unwrap();
        wrappers::SetNamedSecurityInfo(
            path.as_os_str(),
            SE_FILE_OBJECT,
            SecurityInformation::Dacl | SecurityInformation::ProtectedDacl,
            None,
            None,
            descriptor.dacl(),
            None,
        )
        .unwrap();
        let validation = tasks_cli::private_fs::validate_file(&opened);
        drop(opened);
        let error = std::panic::catch_unwind(|| client_key_error(&path));
        wrappers::SetNamedSecurityInfo(
            path.as_os_str(),
            SE_FILE_OBJECT,
            SecurityInformation::Dacl | SecurityInformation::ProtectedDacl,
            None,
            None,
            original.dacl(),
            None,
        )
        .unwrap();
        let message = error.unwrap().to_string();
        assert!(validation
            .err()
            .unwrap()
            .to_string()
            .contains("permissions are insecure"));
        assert!(message.contains("denied"), "{sddl}: {message}");
        assert!(message.contains("owner-only"), "{message}");
    }
}

#[test]
fn generated_key_is_private_pkcs8_and_cannot_be_overwritten() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("keys");
    let public = generate_key(&directory).unwrap();
    let path = directory.join("signing-key.pem");
    let key = load_key(&path).unwrap();
    assert_eq!(key.verifying_key().to_bytes(), public);
    assert!(std::fs::read_to_string(&path)
        .unwrap()
        .starts_with("-----BEGIN PRIVATE KEY-----"));
    assert!(generate_key(&directory).is_err());
    assert_eq!(load_key(&path).unwrap().verifying_key().to_bytes(), public);
    tasks_cli::private_fs::validate_file(&std::fs::File::open(&path).unwrap()).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}

#[test]
fn missing_malformed_and_oversized_keys_are_refused_without_echoing_content() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("keys");
    assert!(load_key(&directory.join("missing")).is_err());
    generate_key(&directory).unwrap();
    let path = directory.join("signing-key.pem");
    std::fs::write(&path, b"PRIVATE_SENTINEL_MUST_NOT_APPEAR").unwrap();
    let message = load_key(&path).err().unwrap().to_string();
    assert!(!message.contains("PRIVATE_SENTINEL"));
    assert!(message.contains("PKCS"));
    std::fs::write(&path, vec![b'x'; 16385]).unwrap();
    assert!(load_key(&path).err().unwrap().to_string().contains("limit"));
}

#[cfg(unix)]
#[test]
fn unix_shared_modes_symlinks_and_hard_links_are_refused() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("keys");
    generate_key(&directory).unwrap();
    let path = directory.join("signing-key.pem");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
    assert!(load_key(&path).is_err());
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    symlink(&path, root.path().join("link")).unwrap();
    assert!(load_key(&root.path().join("link")).is_err());
    std::fs::hard_link(&path, root.path().join("hard")).unwrap();
    assert!(load_key(&path).is_err());
}

#[cfg(windows)]
#[test]
fn windows_extra_grant_and_null_dacl_are_refused() {
    use windows_permissions::constants::{SeObjectType::SE_FILE_OBJECT, SecurityInformation};
    use windows_permissions::{wrappers, LocalBox, SecurityDescriptor};
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("keys");
    generate_key(&directory).unwrap();
    let path = directory.join("signing-key.pem");
    let descriptor: LocalBox<SecurityDescriptor> = "D:P(A;;FA;;;WD)".parse().unwrap();
    wrappers::SetNamedSecurityInfo(
        path.as_os_str(),
        SE_FILE_OBJECT,
        SecurityInformation::Dacl | SecurityInformation::ProtectedDacl,
        None,
        None,
        descriptor.dacl(),
        None,
    )
    .unwrap();
    assert!(load_key(&path).is_err());
    let message = client_key_error(&path).to_string();
    assert!(message.contains("permissions are insecure"), "{message}");
    assert!(message.contains("owner-only"), "{message}");
    wrappers::SetNamedSecurityInfo(
        path.as_os_str(),
        SE_FILE_OBJECT,
        SecurityInformation::Dacl | SecurityInformation::ProtectedDacl,
        None,
        None,
        None,
        None,
    )
    .unwrap();
    assert!(load_key(&path).is_err());
}
