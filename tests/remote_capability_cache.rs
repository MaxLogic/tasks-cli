#![cfg(feature = "server")]
mod support;

use serde_json::Value;
use std::{path::Path, process::Output};
use support::remote_fixture::{ok, run, Fixture};
use tasks_cli::remote::config::{self, Profile};

fn configure(root: &Path) -> Output {
    let Profile::Remote {
        server_url,
        server_id,
        credential_id,
        credential_file,
        private_ca,
        ..
    } = config::load(root).unwrap()
    else {
        unreachable!()
    };
    run(
        root,
        &[
            "remote",
            "configure",
            "--server-url",
            &server_url,
            "--server-id",
            &server_id.to_string(),
            "--credential-id",
            &credential_id.to_string(),
            "--credential-file",
            credential_file.to_str().unwrap(),
            "--private-ca",
            private_ca.as_ref().unwrap().to_str().unwrap(),
        ],
    )
}

fn error(output: Output, exit: i32, code: &str) {
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(exit), "{stderr}");
    let value: Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(value["error"]["code"], code, "{stderr}");
}

fn create(f: &Fixture, project: &str) {
    let body = f.body("cache concurrency fixture");
    ok(run(
        &f.clients[0],
        &[
            "--project",
            project,
            "create",
            "--title",
            "fixture",
            "--body-file",
            body.to_str().unwrap(),
        ],
    ));
}

#[test]
fn unusable_cache_never_changes_live_success_or_original_errors() {
    let f = Fixture::new();
    let project = f.project().to_string();
    create(&f, &project);
    let cache = f.clients[0].join("client/capabilities.json");
    std::fs::remove_file(&cache).unwrap();
    // A directory at the cache path deterministically refuses open/publication
    // and invalidation on both platforms, without interfering with credentials.
    std::fs::create_dir(&cache).unwrap();
    let viewer = run(&f.clients[0], &["viewer", "info"]);
    let configured = configure(&f.clients[0]);
    let conflict = run(
        &f.clients[0],
        &[
            "--project",
            &project,
            "update",
            "1",
            "--expect-version",
            "2",
            "--title",
            "stale",
        ],
    );
    let missing = run(&f.clients[0], &["--project", &project, "show", "999"]);
    // Collect all outcomes before asserting, so the RED observes all paths.
    let outcomes = [
        viewer.status.code(),
        configured.status.code(),
        conflict.status.code(),
        missing.status.code(),
    ];
    assert_eq!(outcomes, [Some(0), Some(0), Some(4), Some(3)]);
    ok(viewer);
    ok(configured);
    error(conflict, 4, "version_conflict");
    error(missing, 3, "not_found");
    std::fs::remove_dir(&cache).unwrap();
}

#[test]
fn oversized_discovery_misses_and_configure_always_probes_live() {
    let f = Fixture::new();
    let cache = f.clients[0].join("client/capabilities.json");
    // Valid JSON followed by whitespace still exceeds the bounded record size.
    let mut bytes = std::fs::read(&cache).unwrap();
    bytes.resize(65537, b' ');
    std::fs::write(&cache, bytes).unwrap();
    let before = f.gateway.requests();
    ok(run(&f.clients[0], &["viewer", "info"]));
    assert_eq!(f.gateway.requests() - before, 2);
    let before = f.gateway.requests();
    ok(run(&f.clients[0], &["viewer", "info"]));
    assert_eq!(f.gateway.requests() - before, 1);
    let before = f.gateway.requests();
    ok(configure(&f.clients[0]));
    assert_eq!(
        f.gateway.requests() - before,
        1,
        "explicit configure must contact the live server even with valid discovery"
    );
}

#[test]
fn cache_is_owner_only_and_insecure_permissions_force_live_discovery() {
    let f = Fixture::new();
    let cache = f.clients[0].join("client/capabilities.json");
    // Validate the actual published object, not just the temp file's mode.
    tasks_cli::private_fs::open_file(&cache).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let meta = std::fs::metadata(&cache).unwrap();
        assert_eq!(meta.mode() & 0o777, 0o600);
        assert_eq!(meta.uid(), rustix::process::geteuid().as_raw());
        std::fs::set_permissions(&cache, std::fs::Permissions::from_mode(0o644)).unwrap();
    }
    #[cfg(windows)]
    {
        use windows_permissions::constants::{SeObjectType::SE_FILE_OBJECT, SecurityInformation};
        use windows_permissions::{wrappers, LocalBox, SecurityDescriptor};
        let original = wrappers::GetNamedSecurityInfo(
            cache.as_os_str(),
            SE_FILE_OBJECT,
            SecurityInformation::Owner | SecurityInformation::Dacl,
        )
        .unwrap();
        let sddl = wrappers::ConvertSecurityDescriptorToStringSecurityDescriptor(
            &original,
            SecurityInformation::Dacl,
        )
        .unwrap()
        .to_string_lossy()
        .into_owned();
        assert!(sddl.starts_with("D:P"), "{sddl}");
        let owner = original.owner().unwrap();
        let acl = original.dacl().unwrap();
        for index in 0..acl.len() {
            let entry = acl.get_ace(index).unwrap();
            let sid = entry.sid().unwrap();
            assert!(
                sid == owner || matches!(sid.to_string().as_str(), "S-1-5-18" | "S-1-5-32-544")
            );
        }
        let insecure: LocalBox<SecurityDescriptor> =
            format!("D:P(A;;FA;;;{owner})(A;;FR;;;WD)").parse().unwrap();
        wrappers::SetNamedSecurityInfo(
            cache.as_os_str(),
            SE_FILE_OBJECT,
            SecurityInformation::Dacl | SecurityInformation::ProtectedDacl,
            None,
            None,
            insecure.dacl(),
            None,
        )
        .unwrap();
    }
    assert!(tasks_cli::private_fs::open_file(&cache).is_err());
    let before = f.gateway.requests();
    ok(run(&f.clients[0], &["viewer", "info"]));
    assert_eq!(f.gateway.requests() - before, 2);
    tasks_cli::private_fs::open_file(&cache).unwrap();
}

#[test]
fn linked_discovery_is_never_reused_or_followed_during_publication() {
    let f = Fixture::new();
    let cache = f.clients[0].join("client/capabilities.json");
    let original = std::fs::read(&cache).unwrap();
    let target = f.clients[0].join("client/symlink-target.json");
    std::fs::rename(&cache, &target).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&target, &cache).unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_file(&target, &cache).unwrap();
    let before = f.gateway.requests();
    let output = run(&f.clients[0], &["viewer", "info"]);
    // Unlink explicitly before assertions/fixture teardown if publication was
    // refused; do not let recursive cleanup encounter a remaining test link.
    if std::fs::symlink_metadata(&cache)
        .unwrap()
        .file_type()
        .is_symlink()
    {
        std::fs::remove_file(&cache).unwrap();
    }
    ok(output);
    assert_eq!(f.gateway.requests() - before, 2);
    assert_eq!(std::fs::read(&target).unwrap(), original);
}

#[cfg(windows)]
#[test]
fn parallel_cli_readers_and_mutations_tolerate_held_cache_and_preserve_errors() {
    use std::{fs::OpenOptions, os::windows::fs::OpenOptionsExt, process::Stdio};
    use support::remote_fixture::command;
    let f = Fixture::new();
    let project = f.project().to_string();
    create(&f, &project);
    let cache = f.clients[0].join("client/capabilities.json");
    let body = f.body("parallel create");
    let cases = [
        (vec!["viewer", "info"], 0, ""),
        (vec!["list"], 0, ""),
        (vec!["show", "1"], 0, ""),
        (
            vec![
                "create",
                "--title",
                "parallel",
                "--body-file",
                body.to_str().unwrap(),
            ],
            0,
            "",
        ),
        (
            vec!["update", "1", "--expect-version", "2", "--title", "stale"],
            4,
            "version_conflict",
        ),
        (vec!["show", "999"], 3, "not_found"),
    ];
    for sharing in [Some(0), Some(1), Some(5), None] {
        ok(run(&f.clients[0], &["viewer", "info"]));
        // Hold across the whole batch. Modes 0/1 also force best-effort
        // publication/invalidation; mode 5 allows deletion but
        // still refuses replacement, so publication stays best-effort.
        let held = sharing.map(|mode| {
            OpenOptions::new()
                .read(true)
                .share_mode(mode)
                .open(&cache)
                .unwrap()
        });
        let children: Vec<_> = cases
            .iter()
            .map(|(args, _, _)| {
                command(
                    &f.clients[0],
                    &[vec!["--project", &project], args.clone()].concat(),
                )
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap()
            })
            .collect();
        // Drain every child before any assertion, including on failure.
        let outputs: Vec<_> = children
            .into_iter()
            .map(|child| child.wait_with_output().unwrap())
            .collect();
        drop(held);
        for ((_, exit, code), output) in cases.iter().zip(outputs) {
            if *exit == 0 {
                ok(output);
            } else {
                error(output, *exit, code);
            }
        }
    }
}
