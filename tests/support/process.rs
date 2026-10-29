//! Synthetic subprocesses must not steal foreground focus on Windows.
pub fn command(program: impl AsRef<std::ffi::OsStr>) -> std::process::Command {
    #[allow(unused_mut)]
    let mut command = std::process::Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    command
}

/// Build hook-only helpers without replacing Cargo's outer test executables.
pub fn test_hooks_command(binary: &str) -> std::process::Command {
    let target = std::path::Path::new(env!("CARGO_BIN_EXE_tasks"))
        .parent()
        .expect("outer binary directory")
        .join("nested-test-hooks");
    let mut command = command(env!("CARGO"));
    command
        .args(["run", "--quiet", "--locked", "--target-dir"])
        .arg(target)
        .args(["--features", "test-hooks", "--bin", binary, "--"])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT");
    command
}
