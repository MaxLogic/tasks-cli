#![cfg(feature = "server")]
use tasks_cli::remote::credentials::{generate_key, load_key};

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
