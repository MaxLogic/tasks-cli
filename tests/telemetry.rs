mod support;

use support::process::command;
use support::temp::TempDir;

#[test]
fn cli_runs_cleanly_across_telemetry_consent_modes_without_network() {
    let root = TempDir::new();
    let data_root = root.path().join("data");
    let settings_file = root.path().join("viewer-settings.json");

    // 1. Default / opt-out modes must succeed without touching any network.
    for mode in ["off", "ask"] {
        std::fs::write(
            &settings_file,
            format!(r#"{{"schema_version":1,"crash_reporting":"{mode}"}}"#),
        )
        .expect("write settings");
        let output = command(env!("CARGO_BIN_EXE_tasks"))
            .args(["--data-root"])
            .arg(&data_root)
            .args(["--format", "json", "viewer", "info"])
            .env_remove("TASKS_WINDOWS_EXE")
            .env_remove("TASKS_PROJECT")
            .env_remove("TASKS_SENTRY_ENABLED")
            .env("TASKS_TELEMETRY_SETTINGS", &settings_file)
            .env("TASKS_SENTRY_DSN", "https://deadbeef@127.0.0.1:1/42")
            .output()
            .expect("run tasks viewer info");
        assert!(
            output.status.success(),
            "mode={mode} stderr={}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    // 2. Kill switch overrides opt-in and always exits cleanly.
    std::fs::write(
        &settings_file,
        r#"{"schema_version":1,"crash_reporting":"always"}"#,
    )
    .expect("write always settings");
    let output = command(env!("CARGO_BIN_EXE_tasks"))
        .args(["--data-root"])
        .arg(&data_root)
        .args(["--format", "json", "viewer", "info"])
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .env("TASKS_TELEMETRY_SETTINGS", &settings_file)
        .env("TASKS_NO_SENTRY", "1")
        .env("TASKS_SENTRY_DSN", "https://deadbeef@127.0.0.1:1/42")
        .output()
        .expect("run tasks with TASKS_NO_SENTRY=1");
    assert!(
        output.status.success(),
        "kill-switch stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );

    // 3. Invalid DSN fails closed cleanly even when opted into always.
    let output = command(env!("CARGO_BIN_EXE_tasks"))
        .args(["--data-root"])
        .arg(&data_root)
        .args(["--format", "json", "viewer", "info"])
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .env_remove("TASKS_NO_SENTRY")
        .env("TASKS_TELEMETRY_SETTINGS", &settings_file)
        .env("TASKS_SENTRY_DSN", "not-a-valid-dsn")
        .output()
        .expect("run tasks with invalid DSN");
    assert!(
        output.status.success(),
        "invalid-dsn stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn server_internal_error_hook_is_safe_when_inactive() {
    tasks_cli::telemetry::capture_server_internal_error(
        "internal_error",
        "Bearer secret_token should never panic when inactive",
    );
}
