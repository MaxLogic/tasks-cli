//! Best-effort invocation context. No transcript, arguments or environment dump.
use crate::model::{Attribution, AttributionSource};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{mpsc, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_CONTEXT_BYTES: u64 = 16_384;
const CONTEXT_MAX_AGE_MS: i64 = 600_000;
static INVOCATION: OnceLock<Attribution> = OnceLock::new();

pub fn current() -> Attribution {
    INVOCATION.get().cloned().unwrap_or_default()
}

pub fn initialize(viewer: bool) {
    INVOCATION.get_or_init(|| {
        if cfg!(windows) && std::env::var("TASKS_DELEGATED").as_deref() == Ok("1") {
            if let Ok(json) = std::env::var("TASKS_ORIGIN_CONTEXT") {
                if json.len() <= MAX_CONTEXT_BYTES as usize {
                    if let Ok(mut context) = serde_json::from_str::<Attribution>(&json) {
                        if context.validated_json().is_ok() {
                            // Delegated observations are local, never authenticated identities.
                            context.actor_authority = AttributionSource::LocalUnverified;
                            for source in context.context_source.values_mut() {
                                if *source == AttributionSource::Credential {
                                    *source = AttributionSource::Environment;
                                }
                            }
                            return context;
                        }
                    }
                }
            }
        }
        let (send, receive) = mpsc::sync_channel(1);
        let deadline = Instant::now() + Duration::from_millis(100);
        // Bound even inaccessible profile files or slow OS identity APIs.
        let worker = std::thread::Builder::new()
            .name("tasks-context".into())
            .spawn(move || {
                let _ = send.send(collect(viewer, deadline));
            });
        if worker.is_err() {
            return Attribution::default();
        }
        receive
            .recv_timeout(Duration::from_millis(100))
            .unwrap_or_default()
    });
}

fn env(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty() && value.len() <= 1024)
}

pub fn client_dir() -> Option<PathBuf> {
    if let Some(root) = std::env::var_os("TASKS_CLIENT_DIR") {
        return Some(root.into());
    }
    if cfg!(windows) {
        std::env::var_os("LOCALAPPDATA")
            .map(|root| PathBuf::from(root).join("MaxLogic/tasks-cli/client"))
    } else {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|root| PathBuf::from(root).join(".config")))
            .map(|root| root.join("tasks-cli/client"))
    }
}

fn source(context: &mut Attribution, field: &str, origin: AttributionSource, present: bool) {
    if present {
        context.context_source.insert(field.into(), origin);
    }
}

fn collect(viewer: bool, deadline: Instant) -> Attribution {
    let mut context = Attribution {
        machine_name: whoami::hostname().ok(),
        actor_id: whoami::account().ok(),
        actor_name: whoami::username().ok(),
        actor_authority: AttributionSource::LocalUnverified,
        origin_platform: Some(std::env::consts::OS.into()),
        ..Default::default()
    };
    let has_host = context.machine_name.is_some();
    let has_actor = context.actor_id.is_some();
    let has_name = context.actor_name.is_some();
    source(
        &mut context,
        "machine_name",
        AttributionSource::Os,
        has_host,
    );
    source(&mut context, "actor_id", AttributionSource::Os, has_actor);
    source(&mut context, "actor_name", AttributionSource::Os, has_name);
    source(&mut context, "origin_platform", AttributionSource::Os, true);
    let ancestors = ancestors(deadline);
    let profile_root = client_dir();
    if let Some(root) = &profile_root {
        if let Some(id) = read_private_json::<Installation>(root, &root.join("installation.json")) {
            if id.schema_version == 1 && !id.machine_id.is_nil() {
                context.machine_id = Some(id.machine_id);
                source(
                    &mut context,
                    "machine_id",
                    AttributionSource::LocalUnverified,
                    true,
                );
            }
        }
    }
    context.caller_executable = ancestors.first().cloned();
    source(
        &mut context,
        "caller_executable",
        AttributionSource::Os,
        !ancestors.is_empty(),
    );
    let detected = ancestors.iter().find_map(|name| {
        match name.to_ascii_lowercase().trim_end_matches(".exe") {
            "codex" => Some(("codex", name.clone())),
            "claude" => Some(("claude-code", name.clone())),
            "tasks_viewer" | "tasks-viewer" => Some(("viewer", name.clone())),
            _ => None,
        }
    });
    if let Some((_, name)) = &detected {
        context.harness_executable = Some(name.clone());
        source(
            &mut context,
            "harness_executable",
            AttributionSource::Os,
            true,
        );
    }
    let direct_viewer = viewer
        || env("TASKS_INVOKER").as_deref() == Some("viewer")
        || detected
            .as_ref()
            .is_some_and(|(harness, _)| *harness == "viewer");
    if direct_viewer {
        context.harness = "viewer".into();
        let origin = if viewer || detected.as_ref().is_some_and(|(name, _)| *name == "viewer") {
            AttributionSource::Os
        } else {
            AttributionSource::Environment
        };
        source(&mut context, "harness", origin, true);
        return context;
    }
    let native = detected.as_ref().map(|(harness, _)| *harness);
    if native.is_some() {
        source(&mut context, "harness", AttributionSource::Os, true);
    }
    let claude =
        native == Some("claude-code") || env("AGENT_HARNESS").as_deref() == Some("claude-code");
    if !claude
        && (native == Some("codex")
            || env("CODEX_THREAD_ID").is_some()
            || env("CODEX_SESSION_ID").is_some())
    {
        context.harness = "codex".into();
        context.session_id = env("CODEX_THREAD_ID").or_else(|| env("CODEX_SESSION_ID"));
        context.harness_session_id =
            env("CODEX_SESSION_ID").filter(|id| Some(id) != context.session_id.as_ref());
        context.harness_version = env("CODEX_VERSION");
    } else if claude || env("CLAUDE_CODE_SESSION_ID").is_some() {
        context.harness = "claude-code".into();
        context.session_id = env("CLAUDE_CODE_SESSION_ID").or_else(|| env("AGENT_SESSION_ID"));
        context.harness_version = env("CLAUDE_CODE_VERSION");
    } else if ancestors.first().is_some_and(|name| {
        matches!(
            name.as_str(),
            "bash" | "zsh" | "fish" | "cmd.exe" | "pwsh.exe" | "powershell.exe"
        )
    }) {
        context.harness = "manual".into();
        source(&mut context, "harness", AttributionSource::Os, true);
    }
    let has_session = context.session_id.is_some();
    let has_execution = context.harness_session_id.is_some();
    let has_version = context.harness_version.is_some();
    source(
        &mut context,
        "session_id",
        AttributionSource::Environment,
        has_session,
    );
    source(
        &mut context,
        "harness_session_id",
        AttributionSource::Environment,
        has_execution,
    );
    source(
        &mut context,
        "harness_version",
        AttributionSource::Environment,
        has_version,
    );
    if has_session {
        source(
            &mut context,
            "harness",
            AttributionSource::Environment,
            true,
        );
    }
    if let Some(root) = profile_root {
        if let Some(session) = context.session_id.as_deref() {
            let pointer = env("TASKS_CONTEXT_FILE").map(PathBuf::from);
            let agent = env("TASKS_AGENT_ID");
            let path = pointer.clone().unwrap_or_else(|| {
                context_path(&root, &context.harness, session, agent.as_deref())
            });
            if let Some(hook) = read_private_json::<HookContext>(&root, &path) {
                let now = now_ms();
                if hook.schema_version == 1
                    && hook.harness == context.harness
                    && hook.session_id == session
                    && hook.recorded_ms <= now + 30_000
                    && hook.recorded_ms >= now - CONTEXT_MAX_AGE_MS
                    && hook.agent_id == agent
                {
                    context.session_name = hook.session_name;
                    let has_name = context.session_name.is_some();
                    source(
                        &mut context,
                        "session_name",
                        AttributionSource::Hook,
                        has_name,
                    );
                    // A shared session file cannot distinguish root and concurrent agents.
                    // Require an invocation identity carried by the configured adapter.
                    if agent.is_some()
                        || (pointer.is_some()
                            && env("TASKS_EXECUTION_ID") == hook.execution_id
                            && hook.execution_id.is_some())
                    {
                        context.model = hook.model;
                        context.agent_id = hook.agent_id;
                        let has_model = context.model.is_some();
                        let has_agent = context.agent_id.is_some();
                        source(&mut context, "model", AttributionSource::Hook, has_model);
                        source(&mut context, "agent_id", AttributionSource::Hook, has_agent);
                    }
                }
            }
        }
    }
    context
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Installation {
    pub schema_version: u32,
    pub machine_id: uuid::Uuid,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HookContext {
    pub schema_version: u32,
    pub harness: String,
    pub session_id: String,
    pub session_name: Option<String>,
    pub model: Option<String>,
    pub agent_id: Option<String>,
    pub execution_id: Option<String>,
    pub recorded_ms: i64,
}

pub fn context_path(root: &Path, harness: &str, session: &str, agent: Option<&str>) -> PathBuf {
    let identity = serde_json::json!([harness, session, agent]).to_string();
    root.join("contexts")
        .join(format!("{:x}.json", Sha256::digest(identity.as_bytes())))
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|time| time.as_millis() as i64)
        .unwrap_or(0)
}

fn read_private_json<T: serde::de::DeserializeOwned>(root: &Path, path: &Path) -> Option<T> {
    let root = crate::storage::validate_storage_root(root)
        .ok()?
        .canonicalize()
        .ok()?;
    if !path.canonicalize().ok()?.starts_with(&root) {
        return None;
    }
    let file = crate::private_fs::open_file(path).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > MAX_CONTEXT_BYTES {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_CONTEXT_BYTES + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() > MAX_CONTEXT_BYTES as usize {
        return None;
    }
    serde_json::from_slice(&bytes).ok()
}

#[cfg(target_os = "linux")]
fn ancestors(deadline: Instant) -> Vec<String> {
    fn stat(pid: u32) -> Option<(u32, u64)> {
        let text = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let (_, fields) = text.rsplit_once(") ")?;
        let values = fields.split_whitespace().collect::<Vec<_>>();
        Some((values.get(1)?.parse().ok()?, values.get(19)?.parse().ok()?))
    }
    let mut names = Vec::new();
    let mut pid = std::process::id();
    let Some((mut parent, mut started)) = stat(pid) else {
        return names;
    };
    for _ in 0..8 {
        if Instant::now() >= deadline || parent == 0 || parent == pid {
            break;
        }
        let Some((next, parent_started)) = stat(parent) else {
            break;
        };
        if parent_started > started {
            break;
        }
        let name = fs::read_link(format!("/proc/{parent}/exe"))
            .ok()
            .and_then(|path| {
                path.file_name()
                    .map(|name| name.to_string_lossy().into_owned())
            });
        if stat(parent) != Some((next, parent_started)) {
            break;
        }
        let Some(name) = name else {
            break;
        };
        names.push(name);
        pid = parent;
        parent = next;
        started = parent_started;
    }
    names
}

#[cfg(not(target_os = "linux"))]
fn ancestors(_deadline: Instant) -> Vec<String> {
    // No safe selective Windows parent/start-time API has been established.
    // Full process snapshots and WMI fallback are forbidden by the contract.
    Vec::new()
}

/// Silent hook ingestion. Ignores unneeded fields including prompt/tool content.
pub fn write_hook(root: &Path, harness: &str, input: &[u8]) -> Result<PathBuf, crate::AppError> {
    if !matches!(harness, "codex" | "claude-code") || input.len() > MAX_CONTEXT_BYTES as usize {
        return Err(crate::AppError::Validation(
            "unsupported or oversized hook input".into(),
        ));
    }
    let value: BTreeMap<String, serde_json::Value> = serde_json::from_slice(input)?;
    let field = |name: &str| {
        value
            .get(name)
            .and_then(|value| value.as_str())
            .filter(|value| !value.trim().is_empty() && value.len() <= 1024)
            .map(str::to_owned)
    };
    let session_id = field("session_id")
        .ok_or_else(|| crate::AppError::Validation("hook has no session_id".into()))?;
    let mut context = HookContext {
        schema_version: 1,
        harness: harness.into(),
        session_id,
        session_name: field("session_title"),
        model: field("model"),
        agent_id: field("agent_id"),
        execution_id: field("execution_id"),
        recorded_ms: now_ms(),
    };
    let root = crate::storage::validate_storage_root(root)?;
    let directory = root.join("contexts");
    fs::create_dir_all(&root)?;
    crate::private_fs::create_dir(&directory)?;
    let path = context_path(
        &root,
        harness,
        &context.session_id,
        context.agent_id.as_deref(),
    );
    if context.session_name.is_none() {
        if let Some(previous) = read_private_json::<HookContext>(&root, &path) {
            if previous.harness == context.harness
                && previous.session_id == context.session_id
                && previous.agent_id == context.agent_id
            {
                context.session_name = previous.session_name;
            }
        }
    }
    let temporary = directory.join(format!("{}.tmp", uuid::Uuid::new_v4()));
    let mut file = crate::private_fs::create_file(&temporary)?;
    let result = (|| -> Result<(), crate::AppError> {
        file.write_all(&serde_json::to_vec(&context)?)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, &path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map(|_| path)
}

/// Claude documents this file as Bash exports, not a universal shell channel.
pub fn publish_claude_environment(input: &[u8], context: &Path) -> Result<(), crate::AppError> {
    let value: serde_json::Value = serde_json::from_slice(input)?;
    if value["hook_event_name"] != "SessionStart" {
        return Ok(());
    }
    let Some(path) = std::env::var_os("CLAUDE_ENV_FILE") else {
        return Ok(());
    };
    let Some(session) = value["session_id"]
        .as_str()
        .filter(|id| !id.trim().is_empty() && id.len() <= 1024)
    else {
        return Ok(());
    };
    fn quote(value: &str) -> String {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
    let mut file = OpenOptions::new().append(true).open(path)?;
    writeln!(file, "export AGENT_HARNESS='claude-code'\nexport CLAUDE_CODE_SESSION_ID={}\nexport TASKS_CONTEXT_FILE={}", quote(session), quote(&context.to_string_lossy()))?;
    Ok(())
}

pub fn setup_preview(harness: &str) -> serde_json::Value {
    let command = format!("tasks context-hook --harness {harness}");
    serde_json::json!({
        "preview_only": true,
        "harness": harness,
        "hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command": command, "timeout": 5}]}],
            "PreToolUse": [{"matcher": "Bash|PowerShell", "hooks": [{"type": "command", "command": command, "timeout": 5}]}],
            "SubagentStart": [{"hooks": [{"type": "command", "command": command, "timeout": 5}]}]
        }
    })
}
