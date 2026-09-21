use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn git_output(manifest_dir: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(manifest_dir)
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn valid_commit(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn watch_git_state(manifest_dir: &Path) {
    for args in [vec!["rev-parse", "--git-path", "HEAD"]] {
        if let Some(path) = git_output(manifest_dir, &args) {
            let path = PathBuf::from(path);
            let path = if path.is_absolute() {
                path
            } else {
                manifest_dir.join(path)
            };
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
    if let Some(reference) = git_output(manifest_dir, &["symbolic-ref", "-q", "HEAD"]) {
        if let Some(path) = git_output(manifest_dir, &["rev-parse", "--git-path", &reference]) {
            let path = PathBuf::from(path);
            let path = if path.is_absolute() {
                path
            } else {
                manifest_dir.join(path)
            };
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
}

fn main() {
    println!("cargo:rerun-if-env-changed=TASKS_BUILD_COMMIT");
    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("manifest dir"));
    watch_git_state(&manifest_dir);

    let explicit = env::var("TASKS_BUILD_COMMIT").ok();
    let commit = explicit.clone().unwrap_or_else(|| {
        git_output(&manifest_dir, &["rev-parse", "--short=12", "HEAD"])
            .unwrap_or_else(|| "unknown".to_string())
    });
    if !valid_commit(&commit) {
        panic!(
            "TASKS_BUILD_COMMIT must be 1-64 ASCII letters, digits, '.', '_' or '-'; got {:?}",
            commit
        );
    }
    let version = env::var("CARGO_PKG_VERSION").expect("package version");
    println!("cargo:rustc-env=TASKS_BUILD_COMMIT={commit}");
    println!("cargo:rustc-env=TASKS_BUILD_VERSION={version} (commit {commit})");
}
