use std::process::Command;
use tasks_cli::model::Attribution;
use tasks_cli::store::{create_project_db, Store};
use uuid::Uuid;

fn mutation(viewer: bool) -> Attribution {
    let root = tempfile::tempdir().unwrap();
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).unwrap();
    let body = root.path().join("body.md");
    std::fs::write(&body, "audit body").unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_tasks"));
    command
        .args([
            "--data-root",
            root.path().to_str().unwrap(),
            "--project",
            &project.to_string(),
            "create",
            "--title",
            "automatic",
            "--body-file",
            body.to_str().unwrap(),
        ])
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_CONTEXT_FILE")
        .env("TASKS_CLIENT_DIR", root.path().join("client"))
        .env("CODEX_THREAD_ID", "codex-conversation")
        .env("CODEX_SESSION_ID", "codex-execution")
        .env("CODEX_VERSION", "test-version")
        .env("CODEX_MODEL", "never-trust-global-model")
        .env("COMPUTERNAME", "forged-host")
        .env("HOSTNAME", "forged-host");
    if viewer {
        command.env("TASKS_INVOKER", "viewer");
    } else {
        command.env_remove("TASKS_INVOKER");
    }
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let mut store = Store::open_readonly(root.path(), &project.to_string()).unwrap();
    store
        .history(1, None, 10, None)
        .unwrap()
        .0
        .items
        .remove(0)
        .attribution
        .unwrap()
}

fn context_mutation(
    root: &std::path::Path,
    project: Uuid,
    session: &str,
    agent: Option<&str>,
) -> Attribution {
    let body = root.join("hook-body.md");
    std::fs::write(&body, "body").unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_tasks"));
    command
        .args([
            "--data-root",
            root.to_str().unwrap(),
            "--project",
            &project.to_string(),
            "create",
            "--title",
            "hooked",
            "--body-file",
            body.to_str().unwrap(),
        ])
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_CONTEXT_FILE")
        .env_remove("TASKS_INVOKER")
        .env_remove("TASKS_DELEGATED")
        .env_remove("TASKS_EXECUTION_ID")
        .env_remove("AGENT_HARNESS")
        .env("TASKS_CLIENT_DIR", root.join("client"))
        .env("CODEX_THREAD_ID", session)
        .env_remove("CODEX_SESSION_ID");
    if let Some(agent) = agent {
        command.env("TASKS_AGENT_ID", agent);
    } else {
        command.env_remove("TASKS_AGENT_ID");
    }
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let store = Store::open_readonly(root, &project.to_string()).unwrap();
    let json: String = store
        .conn
        .query_row(
            "SELECT attribution_json FROM events ORDER BY event_id DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    serde_json::from_str(&json).unwrap()
}

#[test]
fn concurrent_session_and_agent_hooks_keep_context_separate_and_refresh_model() {
    let root = tempfile::tempdir().unwrap();
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).unwrap();
    let client = root.path().join("client");
    std::thread::scope(|scope| {
        for (session, name) in [("session-a", "Alpha"), ("session-b", "Beta")] {
            let client = &client;
            scope.spawn(move || {
                tasks_cli::attribution::write_hook(client, "codex", &serde_json::to_vec(&serde_json::json!({"session_id":session,"session_title":name,"model":"ambiguous-root"})).unwrap()).unwrap();
            });
        }
    });
    let a = context_mutation(root.path(), project, "session-a", None);
    let b = context_mutation(root.path(), project, "session-b", None);
    assert_eq!(a.session_name.as_deref(), Some("Alpha"));
    assert_eq!(b.session_name.as_deref(), Some("Beta"));
    assert!(a.model.is_none() && b.model.is_none());
    tasks_cli::attribution::write_hook(
        &client,
        "codex",
        br#"{"session_id":"session-a","model":"changed-root"}"#,
    )
    .unwrap();
    assert_eq!(
        context_mutation(root.path(), project, "session-a", None)
            .session_name
            .as_deref(),
        Some("Alpha")
    );
    for model in ["agent-model-1", "agent-model-2"] {
        tasks_cli::attribution::write_hook(
            &client,
            "codex",
            &serde_json::to_vec(
                &serde_json::json!({"session_id":"session-a","agent_id":"worker","model":model}),
            )
            .unwrap(),
        )
        .unwrap();
        let agent = context_mutation(root.path(), project, "session-a", Some("worker"));
        assert_eq!(agent.model.as_deref(), Some(model));
        assert_eq!(agent.agent_id.as_deref(), Some("worker"));
    }
    let parent = context_mutation(root.path(), project, "session-a", None);
    assert_eq!(parent.session_name.as_deref(), Some("Alpha"));
    assert!(parent.model.is_none());
}

#[test]
fn stale_wrong_and_oversized_hook_records_do_not_relabel_an_invocation() {
    use tasks_cli::attribution::{context_path, write_hook, HookContext};
    let root = tempfile::tempdir().unwrap();
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).unwrap();
    let client = root.path().join("client");
    let path = write_hook(
        &client,
        "codex",
        br#"{"session_id":"current","session_title":"valid"}"#,
    )
    .unwrap();
    let original: HookContext = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    for fault in ["stale", "wrong-session", "wrong-harness", "oversized"] {
        let mut record = original.clone();
        match fault {
            "stale" => record.recorded_ms = 0,
            "wrong-session" => record.session_id = "other".into(),
            "wrong-harness" => record.harness = "claude-code".into(),
            _ => record.session_name = Some("x".repeat(16_384)),
        }
        std::fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
        let context = context_mutation(root.path(), project, "current", None);
        assert!(context.session_name.is_none(), "{fault}");
        assert!(context.model.is_none());
    }
    assert_ne!(context_path(&client, "codex", "../current", None), path);
}

#[test]
fn hook_command_is_silent_and_claude_env_publication_is_append_only() {
    use std::io::Write;
    use std::process::Stdio;
    let root = tempfile::tempdir().unwrap();
    let client = root.path().join("client with quote '");
    let env_file = root.path().join("claude-env.sh");
    std::fs::write(&env_file, "export PREVIOUS='keep'\n").unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_tasks"));
    command
        .args([
            "context-hook",
            "--harness",
            "claude-code",
            "--client-dir",
            client.to_str().unwrap(),
        ])
        .env("CLAUDE_ENV_FILE", &env_file)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().unwrap();
    child.stdin.take().unwrap().write_all(br#"{"hook_event_name":"SessionStart","session_id":"claude-session","model":"model","transcript_path":"never-read","prompt":"never-store"}"#).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    assert!(output.stdout.is_empty() && output.stderr.is_empty());
    let exports = std::fs::read_to_string(&env_file).unwrap();
    assert!(exports.starts_with("export PREVIOUS='keep'\n"));
    assert!(exports.contains("CLAUDE_CODE_SESSION_ID='claude-session'"));
    let context = std::fs::read_to_string(tasks_cli::attribution::context_path(
        &client,
        "claude-code",
        "claude-session",
        None,
    ))
    .unwrap();
    assert!(!context.contains("never-read") && !context.contains("never-store"));
    let before = std::fs::read_dir(&client).unwrap().count();
    let preview = Command::new(env!("CARGO_BIN_EXE_tasks"))
        .args(["context-setup", "--harness", "codex"])
        .env("TASKS_CLIENT_DIR", &client)
        .output()
        .unwrap();
    assert!(preview.status.success());
    assert_eq!(std::fs::read_dir(&client).unwrap().count(), before);
    assert!(
        serde_json::from_slice::<serde_json::Value>(&preview.stdout).unwrap()["preview_only"]
            .as_bool()
            .unwrap()
    );
}

#[test]
fn ordinary_mutation_collects_os_account_machine_and_codex_session() {
    let context = mutation(false);
    assert!(context.machine_name.is_some());
    assert_ne!(context.machine_name.as_deref(), Some("forged-host"));
    assert!(context.actor_name.is_some());
    assert_eq!(context.harness, "codex");
    assert_eq!(context.session_id.as_deref(), Some("codex-conversation"));
    assert_eq!(context.harness_version.as_deref(), Some("test-version"));
    assert!(context.model.is_none());
}

#[test]
fn viewer_origin_clears_inherited_ai_session_and_model() {
    let context = mutation(true);
    assert_eq!(context.harness, "viewer");
    assert!(context.session_id.is_none());
    assert!(context.model.is_none());
    assert!(context.harness_version.is_none());
}

#[cfg(windows)]
#[test]
fn windows_hook_context_with_a_shared_acl_is_ignored() {
    use windows_permissions::constants::{SeObjectType::SE_FILE_OBJECT, SecurityInformation};
    use windows_permissions::{wrappers, LocalBox, SecurityDescriptor};
    let root = tempfile::tempdir().unwrap();
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).unwrap();
    let client = root.path().join("client");
    let path = tasks_cli::attribution::write_hook(
        &client,
        "codex",
        br#"{"session_id":"private-session","session_title":"PRIVATE_TITLE"}"#,
    )
    .unwrap();
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
    let context = context_mutation(root.path(), project, "private-session", None);
    assert!(context.session_name.is_none());
}
