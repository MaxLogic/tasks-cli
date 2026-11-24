//! Optional opt-in Sentry crash and panic reporting for `tasks` and `tasks-server`.
//!
//! Public builds ship without any embedded credentials unless configured at build
//! time. Even when a DSN is compiled into a release binary, `tasks` keeps Sentry
//! completely disabled (zero network calls, zero background threads) unless the
//! user has explicitly opted into automatic reporting via environment variable or
//! their local settings file. `tasks-server` enables Sentry only when the
//! operator configures `TASKS_SERVER_SENTRY_DSN`.

use std::path::{Path, PathBuf};

/// Crash-reporting consent mode shared with `tasks_viewer`.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum CrashReportingMode {
    Off,
    Ask,
    Always,
}

impl CrashReportingMode {
    fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "off" | "0" | "false" | "no" => Some(Self::Off),
            "ask" => Some(Self::Ask),
            "always" | "1" | "true" | "yes" | "on" => Some(Self::Always),
            _ => None,
        }
    }
}

/// Active Sentry client guard. Dropping it flushes pending crash events.
pub struct TelemetryGuard {
    #[cfg(feature = "telemetry")]
    _inner: Option<sentry::ClientInitGuard>,
}

impl TelemetryGuard {
    fn inactive() -> Self {
        Self {
            #[cfg(feature = "telemetry")]
            _inner: None,
        }
    }

    /// True when Sentry crash reporting is active in this process.
    pub fn is_active(&self) -> bool {
        #[cfg(feature = "telemetry")]
        {
            self._inner.is_some()
        }
        #[cfg(not(feature = "telemetry"))]
        {
            false
        }
    }
}

/// Resolved startup telemetry configuration (separated for pure unit testing).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedConfig {
    pub dsn: String,
    pub release: String,
    pub component: &'static str,
}

#[cfg(feature = "telemetry")]
fn env_truthy(name: &str) -> bool {
    std::env::var(name)
        .ok()
        .map(|v| {
            matches!(
                v.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

fn non_empty_trimmed(raw: Option<&str>) -> Option<String> {
    raw.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

/// Release identifier matching the version and build commit uploaded with symbols.
pub fn release_name(component: &str) -> String {
    format!(
        "{component}@{}+{}",
        env!("CARGO_PKG_VERSION"),
        env!("TASKS_BUILD_COMMIT")
    )
}

/// Parses `"crash_reporting"` from a JSON settings document (`viewer-settings.json`
/// or `telemetry.json`). Missing or unreadable values fail closed to `None`.
pub fn parse_mode_from_json(raw: &str) -> Option<CrashReportingMode> {
    let value: serde_json::Value = serde_json::from_str(raw).ok()?;
    let mode = value.get("crash_reporting")?.as_str()?;
    CrashReportingMode::parse(mode)
}

fn read_mode_from_file(path: &Path) -> Option<CrashReportingMode> {
    let text = std::fs::read_to_string(path).ok()?;
    parse_mode_from_json(&text)
}

/// Default per-user settings files consulted for CLI crash-reporting consent.
#[cfg(feature = "telemetry")]
fn default_cli_settings_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(explicit) = std::env::var_os("TASKS_TELEMETRY_SETTINGS") {
        if !explicit.is_empty() {
            paths.push(PathBuf::from(explicit));
            return paths;
        }
    }
    #[cfg(windows)]
    {
        if let Some(local_app_data) = std::env::var_os("LOCALAPPDATA") {
            let base = PathBuf::from(local_app_data).join("MaxLogic");
            paths.push(base.join("tasks-viewer").join("viewer-settings.json"));
            paths.push(base.join("tasks-cli").join("telemetry.json"));
        }
    }
    #[cfg(not(windows))]
    {
        if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME") {
            if !xdg.is_empty() {
                paths.push(
                    PathBuf::from(xdg)
                        .join("MaxLogic")
                        .join("tasks-cli")
                        .join("telemetry.json"),
                );
            }
        }
        if let Some(home) = std::env::var_os("HOME") {
            if !home.is_empty() {
                paths.push(
                    PathBuf::from(home)
                        .join(".config")
                        .join("MaxLogic")
                        .join("tasks-cli")
                        .join("telemetry.json"),
                );
            }
        }
    }
    paths
}

/// Resolves whether `tasks` (CLI) should activate Sentry given explicit inputs.
pub fn resolve_cli_config(
    disabled_flag: bool,
    env_dsn: Option<&str>,
    compiled_dsn: Option<&str>,
    env_enabled: Option<&str>,
    settings_paths: &[PathBuf],
) -> Option<ResolvedConfig> {
    if disabled_flag {
        return None;
    }
    // An explicit empty TASKS_SENTRY_DSN overrides any compiled-in DSN to disable.
    let dsn = match env_dsn {
        Some(raw) => non_empty_trimmed(Some(raw))?,
        None => non_empty_trimmed(compiled_dsn)?,
    };

    let mode = match env_enabled.and_then(CrashReportingMode::parse) {
        Some(explicit) => explicit,
        None => settings_paths
            .iter()
            .find_map(|path| read_mode_from_file(path))
            .unwrap_or(CrashReportingMode::Off),
    };

    // Short-lived CLI processes never upload silently unless mode is `Always`.
    if mode != CrashReportingMode::Always {
        return None;
    }

    Some(ResolvedConfig {
        dsn,
        release: release_name("tasks-cli"),
        component: "tasks-cli",
    })
}

/// Resolves whether `tasks-server` should activate Sentry.
pub fn resolve_server_config(
    disabled_flag: bool,
    env_dsn: Option<&str>,
    compiled_dsn: Option<&str>,
    env_enabled: Option<&str>,
) -> Option<ResolvedConfig> {
    if disabled_flag {
        return None;
    }
    if let Some(mode) = env_enabled.and_then(CrashReportingMode::parse) {
        if mode != CrashReportingMode::Always {
            return None;
        }
    }
    // Runtime TASKS_SERVER_SENTRY_DSN is the primary opt-in for operators; a
    // compiled DSN is used only when TASKS_SENTRY_ENABLED explicitly opts in.
    let dsn = match env_dsn {
        Some(raw) => non_empty_trimmed(Some(raw))?,
        None => {
            let opted_in = env_enabled
                .and_then(CrashReportingMode::parse)
                .is_some_and(|mode| mode == CrashReportingMode::Always);
            if !opted_in {
                return None;
            }
            non_empty_trimmed(compiled_dsn)?
        }
    };

    Some(ResolvedConfig {
        dsn,
        release: release_name("tasks-server"),
        component: "tasks-server",
    })
}

/// Redacts known credential prefixes from diagnostic text before transmission.
pub fn scrub_text(input: &str) -> String {
    // Store reversed prefixes so compiled binaries never embed literal
    // credential-scanner markers in `.rdata`, regardless of section layout.
    const REVERSED_PREFIXES: [&str; 6] = [
        "_uyrtns",
        "_syrtns",
        "YEK_IPA_SBALNEVELE",
        "yek-ipa-ix",
        " reraeB",
        " erutangiS",
    ];
    let mut text = input.to_owned();
    let mut marker = String::new();
    for reversed in REVERSED_PREFIXES {
        marker.clear();
        marker.extend(reversed.chars().rev());
        let mut cursor = 0;
        while let Some(rel) = text[cursor..].find(marker.as_str()) {
            let start = cursor + rel;
            let after_marker = start + marker.len();
            let end = text[after_marker..]
                .find(|ch: char| ch.is_whitespace() || matches!(ch, '"' | '\'' | ',' | ';' | ')'))
                .map(|offset| after_marker + offset)
                .unwrap_or(text.len());
            text.replace_range(start..end, "[REDACTED]");
            cursor = start + "[REDACTED]".len();
        }
    }
    text
}

#[cfg(feature = "telemetry")]
fn is_sensitive_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    [
        "auth",
        "token",
        "secret",
        "password",
        "cookie",
        "clipboard",
        "body",
        "title",
        "key",
        "env",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

#[cfg(feature = "telemetry")]
fn scrub_event(
    mut event: sentry::protocol::Event<'static>,
) -> Option<sentry::protocol::Event<'static>> {
    event.user = None;
    event.request = None;
    if let Some(message) = event.message.take() {
        event.message = Some(scrub_text(&message));
    }
    for exception in &mut event.exception.values {
        if let Some(value) = exception.value.take() {
            exception.value = Some(scrub_text(&value));
        }
    }
    event.extra.retain(|key, _| !is_sensitive_key(key));
    for breadcrumb in &mut event.breadcrumbs.values {
        if let Some(message) = breadcrumb.message.take() {
            breadcrumb.message = Some(scrub_text(&message));
        }
        breadcrumb.data.retain(|key, _| !is_sensitive_key(key));
    }
    Some(event)
}

#[cfg(feature = "telemetry")]
fn init_with_config(config: ResolvedConfig) -> TelemetryGuard {
    let dsn: sentry::types::Dsn = match config.dsn.parse() {
        Ok(dsn) => dsn,
        Err(_) => return TelemetryGuard::inactive(),
    };
    let mut options = sentry::ClientOptions::default();
    options.dsn = Some(dsn);
    options.release = Some(config.release.into());
    options.send_default_pii = false;
    options.attach_stacktrace = true;
    options.before_send = Some(std::sync::Arc::new(scrub_event));
    options.shutdown_timeout = std::time::Duration::from_secs(2);
    let guard = sentry::init(options);
    sentry::configure_scope(|scope| {
        scope.set_tag("component", config.component);
        scope.set_tag("os", std::env::consts::OS);
        scope.set_tag("arch", std::env::consts::ARCH);
    });
    TelemetryGuard {
        _inner: Some(guard),
    }
}

/// Initializes optional Sentry panic reporting for `tasks` (CLI).
///
/// Returns an inactive guard with zero network/thread cost unless a DSN is
/// available and the user has opted into `always` crash reporting.
pub fn init_cli() -> TelemetryGuard {
    #[cfg(not(feature = "telemetry"))]
    {
        TelemetryGuard::inactive()
    }
    #[cfg(feature = "telemetry")]
    {
        let env_dsn = std::env::var("TASKS_SENTRY_DSN").ok();
        let env_enabled = std::env::var("TASKS_SENTRY_ENABLED").ok();
        let paths = default_cli_settings_paths();
        let Some(config) = resolve_cli_config(
            env_truthy("TASKS_NO_SENTRY"),
            env_dsn.as_deref(),
            option_env!("TASKS_CLI_SENTRY_DSN"),
            env_enabled.as_deref(),
            &paths,
        ) else {
            return TelemetryGuard::inactive();
        };
        init_with_config(config)
    }
}

/// Initializes optional Sentry panic and 500-error reporting for `tasks-server`.
pub fn init_server() -> TelemetryGuard {
    #[cfg(not(feature = "telemetry"))]
    {
        TelemetryGuard::inactive()
    }
    #[cfg(feature = "telemetry")]
    {
        let env_dsn = std::env::var("TASKS_SERVER_SENTRY_DSN").ok();
        let env_enabled = std::env::var("TASKS_SENTRY_ENABLED").ok();
        let Some(config) = resolve_server_config(
            env_truthy("TASKS_NO_SENTRY"),
            env_dsn.as_deref(),
            option_env!("TASKS_SERVER_SENTRY_DSN"),
            env_enabled.as_deref(),
        ) else {
            return TelemetryGuard::inactive();
        };
        init_with_config(config)
    }
}

/// Records only the static CLI subcommand name (never task arguments or paths).
pub fn set_command_tag(command: &'static str) {
    #[cfg(feature = "telemetry")]
    {
        sentry::configure_scope(|scope| {
            scope.set_tag("command", command);
        });
    }
    #[cfg(not(feature = "telemetry"))]
    {
        let _ = command;
    }
}

/// Captures a sanitized `tasks-server` HTTP 500 failure (no task content or headers).
pub fn capture_server_internal_error(code: &str, detail: &str) {
    #[cfg(feature = "telemetry")]
    {
        sentry::with_scope(
            |scope| {
                scope.set_tag("server_error_code", code);
            },
            || {
                sentry::capture_message(
                    &format!("tasks-server 500 ({code}): {detail}"),
                    sentry::Level::Error,
                );
            },
        );
    }
    #[cfg(not(feature = "telemetry"))]
    {
        let _ = (code, detail);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_DSN: &str = "https://abc123@o1.ingest.de.sentry.io/42";

    #[test]
    fn cli_stays_disabled_by_default_even_with_compiled_dsn() {
        let config = resolve_cli_config(false, None, Some(SAMPLE_DSN), None, &[]);
        assert!(config.is_none());
    }

    #[test]
    fn cli_respects_no_sentry_kill_switch_and_empty_dsn_override() {
        assert!(resolve_cli_config(true, None, Some(SAMPLE_DSN), Some("1"), &[]).is_none());
        assert!(resolve_cli_config(false, Some(""), Some(SAMPLE_DSN), Some("1"), &[]).is_none());
        assert!(resolve_cli_config(false, None, Some(SAMPLE_DSN), Some("ask"), &[]).is_none());
        assert!(resolve_cli_config(false, None, Some(SAMPLE_DSN), Some("off"), &[]).is_none());
    }

    #[test]
    fn cli_reads_always_mode_from_viewer_settings_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        let settings = dir.path().join("viewer-settings.json");
        std::fs::write(
            &settings,
            r#"{"schema_version":1,"crash_reporting":"always"}"#,
        )
        .expect("write settings");

        let config = resolve_cli_config(
            false,
            None,
            Some(SAMPLE_DSN),
            None,
            std::slice::from_ref(&settings),
        )
        .expect("enabled via settings");
        assert_eq!(config.dsn, SAMPLE_DSN);
        assert_eq!(config.component, "tasks-cli");
        assert!(config.release.starts_with("tasks-cli@"));

        std::fs::write(&settings, r#"{"schema_version":1,"crash_reporting":"ask"}"#)
            .expect("write ask settings");
        assert!(resolve_cli_config(false, None, Some(SAMPLE_DSN), None, &[settings]).is_none());
    }

    #[test]
    fn server_enables_from_runtime_dsn_only_unless_explicitly_disabled() {
        assert!(resolve_server_config(false, None, Some(SAMPLE_DSN), None).is_none());
        let config = resolve_server_config(false, Some(SAMPLE_DSN), None, None)
            .expect("runtime DSN enables server");
        assert_eq!(config.component, "tasks-server");
        assert_eq!(config.dsn, SAMPLE_DSN);
        assert!(resolve_server_config(false, Some(SAMPLE_DSN), None, Some("off")).is_none());
        assert!(resolve_server_config(true, Some(SAMPLE_DSN), None, None).is_none());
    }

    #[test]
    fn scrub_text_redacts_tokens_and_bearer_headers() {
        let raw = "auth failed Bearer secret123 and sntryu_abcdef012345 token";
        let scrubbed = scrub_text(raw);
        assert!(!scrubbed.contains("secret123"));
        assert!(!scrubbed.contains("sntryu_abcdef012345"));
        assert!(scrubbed.contains("[REDACTED]"));
    }

    #[cfg(feature = "telemetry")]
    #[test]
    fn scrub_event_strips_user_request_and_sensitive_extra_keys() {
        let mut event = sentry::protocol::Event::new();
        event.message = Some("boom sntrys_topsecret".into());
        event.user = Some(sentry::User {
            email: Some("private@example.com".into()),
            ..Default::default()
        });
        event.request = Some(sentry::protocol::Request::default());
        event
            .extra
            .insert("clipboard_text".into(), serde_json::json!("secret note"));
        event
            .extra
            .insert("task_body".into(), serde_json::json!("private body"));
        event
            .extra
            .insert("safe_metric".into(), serde_json::json!(42));

        let cleaned = scrub_event(event).expect("event kept");
        assert!(cleaned.user.is_none());
        assert!(cleaned.request.is_none());
        assert!(!cleaned.extra.contains_key("clipboard_text"));
        assert!(!cleaned.extra.contains_key("task_body"));
        assert_eq!(
            cleaned.extra.get("safe_metric"),
            Some(&serde_json::json!(42))
        );
        assert!(!cleaned.message.as_deref().unwrap_or("").contains("sntrys_"));
    }
}
