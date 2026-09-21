//! Acceptance tests for the additive `tasks viewer` protocol
//! (`viewer/spec.md` sections 4, 7 and 11, slice 2).
//!
//! Every test runs the real `tasks` binary against an explicit unique
//! temporary data root; nothing here touches the real default store.

use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use tasks_cli::model::{Priority, TaskStatus};
use tasks_cli::registry;
use tasks_cli::store::{create_project_db, data_root_project_path, Store};
use tempfile::TempDir;
use uuid::Uuid;

const EXIT_USAGE: i32 = 2;
const EXIT_NOT_FOUND: i32 = 3;
const EXIT_CONFLICT_OR_STALE: i32 = 4;
const EXIT_IO_OR_DATABASE: i32 = 6;
const MAX_REQUEST_BYTES: usize = 8 * 1024 * 1024;

struct Run {
    code: i32,
    stdout: String,
    stderr: String,
}

impl Run {
    fn ok(&self) -> Value {
        assert_eq!(
            self.code, 0,
            "expected success, got exit {}: {}",
            self.code, self.stderr
        );
        serde_json::from_str(&self.stdout)
            .unwrap_or_else(|error| panic!("stdout is not JSON ({error}): {}", self.stdout))
    }

    fn data(&self) -> Value {
        self.ok()["data"].clone()
    }

    fn fails(&self, exit: i32, code: &str) -> Value {
        assert_eq!(
            self.code, exit,
            "expected exit {exit}, got {}: {}",
            self.code, self.stderr
        );
        assert!(
            self.stdout.trim().is_empty(),
            "a failed viewer command must not print a success document: {}",
            self.stdout
        );
        let value: Value = serde_json::from_str(&self.stderr).unwrap_or_else(|error| {
            panic!("stderr is not an error envelope ({error}): {}", self.stderr)
        });
        assert_eq!(value["schema_version"], 1);
        let error = &value["error"];
        assert_eq!(error["code"], code, "stderr: {}", self.stderr);
        assert!(
            error["message"]
                .as_str()
                .is_some_and(|text| !text.is_empty()),
            "error messages must be actionable: {}",
            self.stderr
        );
        error.clone()
    }

    fn fails_with_message(&self, exit: i32, code: &str, needle: &str) -> Value {
        let error = self.fails(exit, code);
        let message = error["message"].as_str().unwrap_or_default();
        assert!(
            message.contains(needle),
            "expected '{needle}' inside '{message}'"
        );
        error
    }
}

fn spawn(args: &[String], stdin: Option<&[u8]>) -> Run {
    let mut command = Command::new(env!("CARGO_BIN_EXE_tasks"));
    command.args(args);
    let output: Output = match stdin {
        None => command.output().unwrap(),
        Some(bytes) => {
            command
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());
            let mut child = command.spawn().unwrap();
            child.stdin.as_mut().unwrap().write_all(bytes).unwrap();
            drop(child.stdin.take());
            child.wait_with_output().unwrap()
        }
    };
    Run {
        code: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}

/// Global arguments for a JSON viewer call, before the command tail.
fn viewer_args(data_root: &Path, project: Option<&str>, tail: &[&str]) -> Vec<String> {
    let mut args = vec![
        "--data-root".to_string(),
        data_root.display().to_string(),
        "--format".to_string(),
        "json".to_string(),
    ];
    if let Some(project) = project {
        args.push("--project".to_string());
        args.push(project.to_string());
    }
    args.extend(tail.iter().map(|arg| arg.to_string()));
    args
}

fn request_path(data_root: &Path, name: &str) -> PathBuf {
    let dir = data_root.join("requests");
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn write_request(data_root: &Path, name: &str, document: &str) -> PathBuf {
    let path = request_path(data_root, name);
    fs::write(&path, document).unwrap();
    path
}

fn write_request_bytes(data_root: &Path, name: &str, bytes: &[u8]) -> PathBuf {
    let path = request_path(data_root, name);
    fs::write(&path, bytes).unwrap();
    path
}

/// The registry needs a real directory to bind and a real database to
/// validate, so the binding is created after `create_project_db`.
fn bind_root(data_root: &Path, name: &str, project: &Uuid) -> PathBuf {
    let root = data_root.join("roots").join(name);
    fs::create_dir_all(&root).unwrap();
    registry::bind_root(data_root, &root, Some(project.to_string())).unwrap();
    root
}

fn add_project(data_root: &Path, name: &str) -> (Uuid, PathBuf) {
    let project = Uuid::new_v4();
    create_project_db(data_root, &project).unwrap();
    let root = bind_root(data_root, name, &project);
    (project, root)
}

/// Windows paths are case-insensitive, so two display names that differ only
/// by ASCII case have to live in different parent directories.
fn add_project_nested(data_root: &Path, group: &str, name: &str) -> Uuid {
    let project = Uuid::new_v4();
    create_project_db(data_root, &project).unwrap();
    let root = data_root.join("roots").join(group).join(name);
    fs::create_dir_all(&root).unwrap();
    registry::bind_root(data_root, &root, Some(project.to_string())).unwrap();
    project
}

fn project_db(data_root: &Path, project: &Uuid) -> PathBuf {
    data_root_project_path(data_root, &project.to_string())
}

fn ids(data: &Value) -> Vec<u64> {
    data["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_u64().unwrap())
        .collect()
}

fn project_ids(data: &Value) -> Vec<String> {
    data["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["project_id"].as_str().unwrap().to_string())
        .collect()
}

/// Sort one group of tied records the documented way: project UUID ascending.
fn tied(groups: Vec<Vec<String>>) -> Vec<String> {
    let mut out = Vec::new();
    for mut group in groups {
        group.sort();
        out.extend(group);
    }
    out
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// One project with its own temporary data root and database. The registry is
/// only needed for `viewer projects`, so `tasks`, `show` and `update` tests can
/// use `--project <uuid>` directly.
struct Project {
    data_root: TempDir,
    id: Uuid,
}

impl Project {
    fn new() -> Self {
        let data_root = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        create_project_db(data_root.path(), &id).unwrap();
        Self { data_root, id }
    }

    fn id_text(&self) -> String {
        self.id.to_string()
    }

    fn db_path(&self) -> PathBuf {
        project_db(self.data_root.path(), &self.id)
    }

    fn store(&self) -> Store {
        Store::open_rw(self.data_root.path(), &self.id_text()).unwrap()
    }

    fn conn(&self) -> Connection {
        Connection::open(self.db_path()).unwrap()
    }

    fn run(&self, tail: &[&str]) -> Run {
        let args = viewer_args(self.data_root.path(), Some(&self.id_text()), tail);
        spawn(&args, None)
    }

    fn run_stdin(&self, tail: &[&str], stdin: &[u8]) -> Run {
        let args = viewer_args(self.data_root.path(), Some(&self.id_text()), tail);
        spawn(&args, Some(stdin))
    }

    /// Run a viewer command with a JSON document written to a file.
    fn viewer(&self, command: &str, document: Value) -> Run {
        self.viewer_text(command, &document.to_string())
    }

    fn viewer_text(&self, command: &str, document: &str) -> Run {
        let name = format!("{command}-{}.json", Uuid::new_v4());
        let path = write_request(self.data_root.path(), &name, document);
        self.run(&["viewer", command, "--request-file", path.to_str().unwrap()])
    }

    fn tasks(&self, document: Value) -> Value {
        self.viewer("tasks", document).data()
    }

    fn ids(&self, document: Value) -> Vec<u64> {
        ids(&self.tasks(document))
    }

    fn add(
        &self,
        title: &str,
        status: TaskStatus,
        priority: Priority,
        labels: &[&str],
        deps: Vec<u64>,
    ) -> u64 {
        let labels = labels.iter().map(|label| label.to_string()).collect();
        let mut store = self.store();
        store
            .create_task_with_priority_labels(title, "body", status, deps, labels, priority)
            .unwrap()
            .0
    }

    fn add_body(&self, title: &str, body: &str, status: TaskStatus) -> u64 {
        let mut store = self.store();
        store
            .create_task(title, body, status, Vec::new())
            .unwrap()
            .0
    }

    fn add_plain(&self, title: &str, status: TaskStatus) -> u64 {
        self.add(title, status, Priority::P2, &[], Vec::new())
    }
}

/// `viewer projects` never needs `--project`.
fn projects(data_root: &Path, document: Value) -> Run {
    let name = format!("projects-{}.json", Uuid::new_v4());
    let path = write_request(data_root, &name, &document.to_string());
    let args = viewer_args(
        data_root,
        None,
        &[
            "viewer",
            "projects",
            "--request-file",
            path.to_str().unwrap(),
        ],
    );
    spawn(&args, None)
}

fn inspect(data_root: &Path, project: &Uuid, document: Value) -> Run {
    let name = format!("tasks-{}.json", Uuid::new_v4());
    let path = write_request(data_root, &name, &document.to_string());
    let args = viewer_args(
        data_root,
        Some(&project.to_string()),
        &["viewer", "tasks", "--request-file", path.to_str().unwrap()],
    );
    spawn(&args, None)
}

fn update(data_root: &Path, project: &Uuid, document: Value) -> Run {
    let name = format!("update-{}.json", Uuid::new_v4());
    let path = write_request(data_root, &name, &document.to_string());
    let args = viewer_args(
        data_root,
        Some(&project.to_string()),
        &["viewer", "update", "--request-file", path.to_str().unwrap()],
    );
    spawn(&args, None)
}

/// Decode the documented `v1:` hex encoding to inspect the bound fields.
fn decode_token(token: &str) -> Value {
    let hex = token
        .strip_prefix("v1:")
        .unwrap_or_else(|| panic!("snapshot tokens use the v1 prefix: {token}"));
    let mut bytes = Vec::with_capacity(hex.len() / 2);
    for index in 0..hex.len() / 2 {
        bytes.push(u8::from_str_radix(&hex[index * 2..index * 2 + 2], 16).unwrap());
    }
    serde_json::from_slice(&bytes).unwrap()
}

fn task_version(project: &Project, id: u64) -> u64 {
    project
        .conn()
        .query_row("SELECT version FROM tasks WHERE id=?1", [id], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap() as u64
}

fn task_title(project: &Project, id: u64) -> String {
    project
        .conn()
        .query_row("SELECT title FROM tasks WHERE id=?1", [id], |row| {
            row.get::<_, String>(0)
        })
        .unwrap()
}

fn task_events(project: &Project, id: u64) -> u64 {
    project
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM events WHERE task_id=?1",
            [id],
            |row| row.get::<_, i64>(0),
        )
        .unwrap() as u64
}

fn all_events(project: &Project) -> u64 {
    project
        .conn()
        .query_row("SELECT COUNT(*) FROM events", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap() as u64
}

#[test]
fn viewer_info_reports_the_protocol_without_touching_a_store() {
    let empty = tempfile::tempdir().unwrap();
    let missing = empty.path().join("never-created");

    let args = viewer_args(&missing, None, &["viewer", "info"]);
    let run = spawn(&args, None);
    let envelope = run.ok();
    assert_eq!(envelope["schema_version"], 1);
    assert!(
        envelope["project_id"].is_null(),
        "info has no project context"
    );
    let data = &envelope["data"];
    assert_eq!(data["protocol_version"], 1);
    assert_eq!(
        data["operations"],
        json!(["info", "projects", "tasks", "show", "update"])
    );
    assert_eq!(
        data["statuses"],
        json!([
            "draft",
            "todo",
            "in-progress",
            "blocked",
            "done",
            "cancelled"
        ])
    );
    assert_eq!(data["priorities"], json!(["P0", "P1", "P2", "P3"]));
    assert_eq!(
        data["editable_fields"],
        json!(["title", "body", "status", "priority", "labels", "deps"])
    );
    let limits = &data["editable_field_limits"];
    assert_eq!(limits["title"]["max_chars"], 500);
    assert_eq!(limits["body"]["max_utf8_bytes"], 1_048_576);
    assert_eq!(limits["status"]["values"], data["statuses"]);
    assert_eq!(limits["priority"]["values"], data["priorities"]);
    assert_eq!(limits["labels"]["max_count"], 32);
    assert_eq!(limits["labels"]["item_max_chars"], 64);
    assert_eq!(
        limits["labels"]["item_allowed"],
        "ASCII letters, digits and -_.:"
    );
    assert_eq!(limits["deps"]["max_count"], 1000);

    assert!(
        !missing.exists(),
        "viewer info must not create the data root"
    );
    assert_eq!(fs::read_dir(empty.path()).unwrap().count(), 0);

    // The same command with an explicit project and no data root must also
    // leave the filesystem alone.
    let project_id = Uuid::new_v4().to_string();
    let args = viewer_args(&missing, Some(&project_id), &["viewer", "info"]);
    spawn(&args, None).ok();
    assert!(!missing.exists());
}

#[test]
fn viewer_commands_require_json_format() {
    let empty = tempfile::tempdir().unwrap();
    let missing = empty.path().join("never-created");
    for tail in [
        vec!["viewer", "info"],
        vec!["viewer", "projects", "--request-file", "-"],
        vec!["viewer", "tasks", "--request-file", "-"],
    ] {
        let mut args = vec![
            "--data-root".to_string(),
            missing.display().to_string(),
            "--format".to_string(),
            "text".to_string(),
        ];
        args.extend(tail.iter().map(|arg| arg.to_string()));
        let run = spawn(&args, None);
        assert_eq!(run.code, EXIT_USAGE, "stderr: {}", run.stderr);
        assert!(
            run.stdout.is_empty(),
            "a text-mode usage error must not print a document"
        );
        assert!(
            run.stderr.contains("viewer commands are JSON-only"),
            "stderr: {}",
            run.stderr
        );
    }
    assert!(
        !missing.exists(),
        "the JSON-format check runs before any store access"
    );
}

#[test]
fn malformed_oversized_and_unreadable_requests_are_rejected() {
    let project = Project::new();

    let malformed = write_request(project.data_root.path(), "malformed.json", "{\"scope\":");
    project
        .run(&[
            "viewer",
            "tasks",
            "--request-file",
            malformed.to_str().unwrap(),
        ])
        .fails_with_message(EXIT_USAGE, "usage", "not valid JSON");

    let trailing = write_request(project.data_root.path(), "trailing.json", "{} {}");
    project
        .run(&[
            "viewer",
            "tasks",
            "--request-file",
            trailing.to_str().unwrap(),
        ])
        .fails_with_message(EXIT_USAGE, "usage", "after the JSON document");

    let blank = write_request(project.data_root.path(), "blank.json", "   \n");
    project
        .run(&["viewer", "tasks", "--request-file", blank.to_str().unwrap()])
        .fails_with_message(EXIT_USAGE, "usage", "is empty");

    let array = write_request(project.data_root.path(), "array.json", "[]");
    project
        .run(&["viewer", "tasks", "--request-file", array.to_str().unwrap()])
        .fails_with_message(EXIT_USAGE, "usage", "must be a JSON object");

    // The size check runs before parsing, so the payload never has to be JSON.
    let oversized = vec![b'x'; MAX_REQUEST_BYTES + 1];
    let path = write_request_bytes(project.data_root.path(), "oversized.json", &oversized);
    let error = project
        .run(&["viewer", "tasks", "--request-file", path.to_str().unwrap()])
        .fails_with_message(EXIT_USAGE, "usage", "8388608");
    assert!(
        !error["message"]
            .as_str()
            .unwrap()
            .contains("not valid JSON"),
        "the size limit must win before parsing: {error}"
    );

    // Exactly 8 MiB is still accepted when the document is valid JSON.
    let prefix = "{\"scope\":\"all\",\"query\":\"";
    let suffix = "\"}";
    let filler = "a".repeat(MAX_REQUEST_BYTES - prefix.len() - suffix.len());
    let mut boundary = Vec::with_capacity(MAX_REQUEST_BYTES);
    boundary.extend_from_slice(prefix.as_bytes());
    boundary.extend_from_slice(filler.as_bytes());
    boundary.extend_from_slice(suffix.as_bytes());
    assert_eq!(boundary.len(), MAX_REQUEST_BYTES);
    let path = write_request_bytes(project.data_root.path(), "at-limit.json", &boundary);
    let run = project.run(&["viewer", "tasks", "--request-file", path.to_str().unwrap()]);
    assert_eq!(
        run.code, 0,
        "8 MiB exactly must be accepted: {}",
        run.stderr
    );

    // A missing request file is an IO error, not a usage error.
    let absent = request_path(project.data_root.path(), "absent.json");
    project
        .run(&[
            "viewer",
            "tasks",
            "--request-file",
            absent.to_str().unwrap(),
        ])
        .fails(EXIT_IO_OR_DATABASE, "io");

    // A malformed stdin request is rejected before the store is opened, so a
    // missing data root is left untouched.
    let missing_root = tempfile::tempdir().unwrap().path().join("never-created");
    let args = viewer_args(
        &missing_root,
        Some(&project.id_text()),
        &["viewer", "tasks", "--request-file", "-"],
    );
    spawn(&args, Some(b"{\"scope\":")).fails_with_message(EXIT_USAGE, "usage", "not valid JSON");
    assert!(
        !missing_root.exists(),
        "a rejected request must not touch the store"
    );

    let run = project.run_stdin(
        &["viewer", "tasks", "--request-file", "-"],
        b"{\"scope\":\"all\"}",
    );
    assert_eq!(run.code, 0, "stdin requests are accepted: {}", run.stderr);
}

#[test]
fn duplicate_json_keys_are_rejected_at_every_object_level() {
    let project = Project::new();
    let id = project.add_plain("task", TaskStatus::Ready);

    project
        .viewer_text("tasks", "{\"scope\":\"all\",\"scope\":\"open\"}")
        .fails_with_message(EXIT_USAGE, "usage", "duplicate JSON key 'scope'");

    let name = format!("dup-projects-{}.json", Uuid::new_v4());
    let path = write_request(project.data_root.path(), &name, "{\"limit\":1,\"limit\":2}");
    let args = viewer_args(
        project.data_root.path(),
        None,
        &[
            "viewer",
            "projects",
            "--request-file",
            path.to_str().unwrap(),
        ],
    );
    spawn(&args, None).fails_with_message(EXIT_USAGE, "usage", "duplicate JSON key 'limit'");

    let document = format!(
        "{{\"id\":{id},\"expect_version\":1,\"changes\":{{\"title\":\"a\",\"title\":\"b\"}}}}"
    );
    project.viewer_text("update", &document).fails_with_message(
        EXIT_USAGE,
        "usage",
        "duplicate JSON key 'title'",
    );

    let document =
        format!("{{\"id\":{id},\"expect_version\":1,\"changes\":{{}},\"changes\":{{}}}}");
    project.viewer_text("update", &document).fails_with_message(
        EXIT_USAGE,
        "usage",
        "duplicate JSON key 'changes'",
    );

    assert_eq!(
        task_version(&project, id),
        1,
        "rejected requests must not write"
    );
    assert_eq!(task_events(&project, id), 1);
}

#[test]
fn unknown_fields_and_wrong_types_are_rejected() {
    let project = Project::new();
    let id = project.add_plain("task", TaskStatus::Ready);

    for (document, needle) in [
        (json!({"bogus": 1}), "unknown viewer request field 'bogus'"),
        (
            json!({"offset": "0"}),
            "'offset' must be a whole number, found a string",
        ),
        (
            json!({"labels": "needs-human"}),
            "'labels' must be an array of strings, found a string",
        ),
        (
            json!({"statuses": ["todo", 3]}),
            "'statuses' must be an array of strings, found a number",
        ),
        (
            json!({"sort": []}),
            "'sort' must be a string, found an array",
        ),
    ] {
        project
            .viewer("tasks", document)
            .fails_with_message(EXIT_USAGE, "usage", needle);
    }

    for (document, needle) in [
        (
            json!({"id": id, "expect_version": 1, "changes": {"mystery": 1}}),
            "unknown viewer request field 'mystery'",
        ),
        (
            json!({"id": id, "expect_version": 1}),
            "missing the required field 'changes'",
        ),
        (
            json!({"id": id, "expect_version": 1, "changes": []}),
            "must be a JSON object, found an array",
        ),
        (
            json!({"id": id, "expect_version": 1, "changes": {"deps": ["T-1"]}}),
            "'deps' must be an array of whole numbers, found a string",
        ),
        (
            json!({"id": id, "expect_version": 1, "changes": {"deps": [-1]}}),
            "'deps' items must be whole numbers that are zero or greater",
        ),
    ] {
        project
            .viewer("update", document)
            .fails_with_message(EXIT_USAGE, "usage", needle);
    }

    let empty = tempfile::tempdir().unwrap();
    for (document, needle) in [
        (
            json!({"extra": true}),
            "unknown viewer request field 'extra'",
        ),
        (
            json!({"query": 5}),
            "'query' must be a string, found a number",
        ),
    ] {
        let name = format!("bad-{}.json", Uuid::new_v4());
        let path = write_request(empty.path(), &name, &document.to_string());
        let args = viewer_args(
            empty.path(),
            None,
            &[
                "viewer",
                "projects",
                "--request-file",
                path.to_str().unwrap(),
            ],
        );
        spawn(&args, None).fails_with_message(EXIT_USAGE, "usage", needle);
    }
}

#[test]
fn presence_aware_fields_distinguish_absent_null_and_duplicate() {
    let project = Project::new();
    let id = project.add_plain("task", TaskStatus::Ready);

    // `snapshot` is the one field that documents an explicit null.
    let data = project.tasks(json!({"snapshot": null}));
    assert_eq!(ids(&data), [id]);

    for (document, field) in [
        (json!({"scope": null}), "scope"),
        (json!({"query": null}), "query"),
        (json!({"labels": null}), "labels"),
        (json!({"offset": null}), "offset"),
        (json!({"limit": null}), "limit"),
        (json!({"statuses": null}), "statuses"),
        (json!({"direction": null}), "direction"),
    ] {
        project.viewer("tasks", document).fails_with_message(
            EXIT_USAGE,
            "usage",
            &format!("'{field}' must not be null"),
        );
    }
    project
        .viewer("tasks", json!({"snapshot": 3}))
        .fails_with_message(
            EXIT_USAGE,
            "usage",
            "'snapshot' must be a string or null, found a number",
        );

    // An absent change keeps the field, an explicit null is invalid, and a
    // duplicated key is invalid even when both values are strings.
    update(
        project.data_root.path(),
        &project.id,
        json!({"id": id, "expect_version": 1, "changes": {"priority": "P1"}}),
    )
    .data();
    let shown = project.run(&["viewer", "show", "T-1"]).data();
    assert_eq!(shown["body"], "body");
    assert_eq!(shown["priority"], "P1");

    update(
        project.data_root.path(),
        &project.id,
        json!({"id": id, "expect_version": 2, "changes": {"body": null}}),
    )
    .fails_with_message(EXIT_USAGE, "usage", "'body' must not be null");

    let document = format!(
        "{{\"id\":{id},\"expect_version\":2,\"changes\":{{\"body\":\"a\",\"body\":\"b\"}}}}"
    );
    project.viewer_text("update", &document).fails_with_message(
        EXIT_USAGE,
        "usage",
        "duplicate JSON key 'body'",
    );

    assert_eq!(task_version(&project, id), 2);
    assert_eq!(task_events(&project, id), 2);
}

#[test]
fn enum_offset_and_limit_bounds_are_rejected() {
    let project = Project::new();

    for (document, needle) in [
        (
            json!({"scope": "closed"}),
            "'scope' has the unsupported value 'closed'; supported values are open, all",
        ),
        (
            json!({"sort": "random"}),
            "'sort' has the unsupported value 'random'; supported values are id, priority, status, title, created, updated",
        ),
        (
            json!({"direction": "sideways"}),
            "'direction' has the unsupported value 'sideways'; supported values are asc, desc",
        ),
        (
            json!({"readiness": "later"}),
            "'readiness' has the unsupported value 'later'; supported values are any, runnable, waiting",
        ),
        (
            json!({"statuses": ["finished"]}),
            "supported values are draft, todo, in-progress, blocked, done, cancelled",
        ),
        (
            json!({"priorities": ["P4"]}),
            "'priorities' has the unsupported value 'P4'; supported values are P0, P1, P2, P3",
        ),
        (
            json!({"offset": -1}),
            "'offset' must be a whole number that is zero or greater",
        ),
        (
            json!({"offset": 9223372036854775808u64}),
            "'offset' must fit SQLite's signed integer range",
        ),
        (json!({"limit": 0}), "'limit' must be between 1 and 200; got 0"),
        (
            json!({"limit": 201}),
            "'limit' must be between 1 and 200; got 201",
        ),
        (
            json!({"limit": -3}),
            "'limit' must be a whole number that is zero or greater",
        ),
    ] {
        project
            .viewer("tasks", document)
            .fails_with_message(EXIT_USAGE, "usage", needle);
    }

    for (document, needle) in [
        (
            json!({"state": "open"}),
            "'state' has the unsupported value 'open'; supported values are all, has-open, has-blocked, complete, empty, unavailable",
        ),
        (
            json!({"sort": "uuid"}),
            "'sort' has the unsupported value 'uuid'; supported values are name, open, total, blocked, started, last-write, progress",
        ),
        (
            json!({"offset": -1}),
            "'offset' must be a whole number that is zero or greater",
        ),
        (
            json!({"limit": 201}),
            "'limit' must be between 1 and 200; got 201",
        ),
    ] {
        let name = format!("bad-{}.json", Uuid::new_v4());
        let path = write_request(project.data_root.path(), &name, &document.to_string());
        let args = viewer_args(
            project.data_root.path(),
            None,
            &["viewer", "projects", "--request-file", path.to_str().unwrap()],
        );
        spawn(&args, None).fails_with_message(EXIT_USAGE, "usage", needle);
    }

    // Both boundaries that are allowed.
    assert_eq!(
        project.tasks(json!({"scope": "all", "limit": 1}))["limit"],
        1
    );
    assert_eq!(
        project.tasks(json!({"scope": "all", "limit": 200}))["limit"],
        200
    );
    assert_eq!(
        project.tasks(json!({"scope": "all", "offset": 0}))["offset"],
        0
    );
}

fn canonical_text(path: &Path) -> String {
    fs::canonicalize(path)
        .unwrap()
        .to_string_lossy()
        .into_owned()
}

fn sorted_project_ids(data: &Value) -> Vec<String> {
    let mut ids = project_ids(data);
    ids.sort();
    ids
}

#[test]
fn projects_list_two_bindings_of_one_uuid_once_with_stats() {
    let data_root = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    create_project_db(data_root.path(), &id).unwrap();
    let first = bind_root(data_root.path(), "Alpha", &id);
    let second = bind_root(data_root.path(), "alpha-2", &id);
    let first_text = canonical_text(&first);
    let second_text = canonical_text(&second);
    {
        let mut store = Store::open_rw(data_root.path(), &id.to_string()).unwrap();
        for status in [
            TaskStatus::Done,
            TaskStatus::Cancelled,
            TaskStatus::Blocked,
            TaskStatus::Ready,
        ] {
            store
                .create_task_with_priority_labels(
                    "task",
                    "body",
                    status,
                    vec![],
                    vec![],
                    Priority::P2,
                )
                .unwrap();
        }
    }

    let run = projects(data_root.path(), json!({"state": "all"}));
    let envelope = run.ok();
    assert!(
        envelope["project_id"].is_null(),
        "the project catalog has no project context"
    );
    let data = &envelope["data"];
    assert_eq!(data["protocol_version"], 1);
    assert_eq!(data["total_count"], 1);
    assert_eq!(data["offset"], 0);
    assert_eq!(data["limit"], 100);
    assert_eq!(data["has_more"], false);
    assert!(data["next_offset"].is_null());
    let items = data["items"].as_array().unwrap();
    assert_eq!(items.len(), 1, "one UUID is one row");
    let item = &items[0];
    assert_eq!(item["project_id"], id.to_string());
    assert_eq!(
        item["name"], "Alpha",
        "name comes from the first sorted root"
    );
    assert_eq!(item["roots"], json!([first_text, second_text]));
    assert_eq!(item["availability"], "available");
    assert!(item["error"].is_null());
    assert!(item["sampled_at_ms"].as_i64().unwrap() > 0);
    let stats = &item["stats"];
    assert_eq!(stats["total"], 4);
    assert_eq!(stats["open"], 2, "blocked and todo count as open");
    assert_eq!(stats["blocked"], 1);
    assert_eq!(stats["done"], 1);
    assert_eq!(stats["cancelled"], 1);
    let started = stats["started_ms"].as_i64().unwrap();
    let last_write = stats["last_write_ms"].as_i64().unwrap();
    assert!(started > 0 && last_write >= started);
    assert!((stats["progress_percent"].as_f64().unwrap() - 100.0 / 3.0).abs() < 1e-9);
}

#[test]
fn projects_report_missing_roots_corrupt_databases_and_empty_registries() {
    let data_root = tempfile::tempdir().unwrap();

    let (healthy, _) = add_project(data_root.path(), "healthy");
    {
        let mut store = Store::open_rw(data_root.path(), &healthy.to_string()).unwrap();
        store
            .create_task_with_priority_labels(
                "task",
                "body",
                TaskStatus::Ready,
                vec![],
                vec![],
                Priority::P2,
            )
            .unwrap();
    }

    let (missing, missing_root) = add_project(data_root.path(), "missing");
    let missing_text = canonical_text(&missing_root);
    fs::remove_file(project_db(data_root.path(), &missing)).unwrap();
    fs::remove_dir_all(&missing_root).unwrap();

    let (corrupt, _) = add_project(data_root.path(), "corrupt");
    fs::write(
        project_db(data_root.path(), &corrupt),
        b"this is not a database",
    )
    .unwrap();

    let data = projects(data_root.path(), json!({"state": "all"})).data();
    assert_eq!(data["total_count"], 3);
    let items = data["items"].as_array().unwrap();
    let find = |id: &Uuid| {
        items
            .iter()
            .find(|item| item["project_id"] == id.to_string())
            .unwrap_or_else(|| panic!("project {id} is missing from the catalog"))
    };

    let healthy_item = find(&healthy);
    assert_eq!(healthy_item["availability"], "available");
    assert_eq!(healthy_item["stats"]["total"], 1);
    assert!(healthy_item["error"].is_null());

    let missing_item = find(&missing);
    assert_eq!(missing_item["availability"], "missing");
    assert!(
        missing_item["stats"].is_null(),
        "unavailable statistics are never reported as zero"
    );
    assert!(missing_item["error"].is_null());
    assert_eq!(
        missing_item["roots"],
        json!([missing_text]),
        "a missing root stays listed"
    );

    let corrupt_item = find(&corrupt);
    assert_eq!(corrupt_item["availability"], "error");
    assert!(corrupt_item["stats"].is_null());
    assert_eq!(corrupt_item["error"]["code"], "database");
    assert!(!corrupt_item["error"]["message"]
        .as_str()
        .unwrap()
        .is_empty());

    // Unavailable projects match all/unavailable state filters only.
    let unavailable = projects(data_root.path(), json!({"state": "unavailable"})).data();
    assert_eq!(unavailable["total_count"], 2);
    let mut expected = vec![missing.to_string(), corrupt.to_string()];
    expected.sort();
    assert_eq!(sorted_project_ids(&unavailable), expected);
    let has_open = projects(data_root.path(), json!({"state": "has-open"})).data();
    assert_eq!(sorted_project_ids(&has_open), vec![healthy.to_string()]);

    // A valid empty registry produces an empty result, not an error.
    let empty_root = tempfile::tempdir().unwrap();
    let empty = projects(empty_root.path(), json!({"state": "all"})).data();
    assert_eq!(empty["total_count"], 0);
    assert!(empty["items"].as_array().unwrap().is_empty());
    assert_eq!(empty["has_more"], false);
    assert!(empty["next_offset"].is_null());
    assert!(empty["snapshot"].as_str().unwrap().starts_with("v1:"));
}

#[test]
fn projects_state_filters_follow_the_documented_meaning() {
    let data_root = tempfile::tempdir().unwrap();
    let (empty, _) = add_project(data_root.path(), "empty");
    let (cancelled_only, _) = add_project(data_root.path(), "cancelled-only");
    let (mixed, _) = add_project(data_root.path(), "mixed");
    let (finished, _) = add_project(data_root.path(), "finished");
    let (waiting, _) = add_project(data_root.path(), "waiting");

    {
        let mut store = Store::open_rw(data_root.path(), &cancelled_only.to_string()).unwrap();
        for title in ["one", "two"] {
            store
                .create_task_with_priority_labels(
                    title,
                    "body",
                    TaskStatus::Cancelled,
                    vec![],
                    vec![],
                    Priority::P2,
                )
                .unwrap();
        }
    }
    {
        let mut store = Store::open_rw(data_root.path(), &mixed.to_string()).unwrap();
        for title in ["done 1", "done 2", "done 3", "done 4"] {
            store
                .create_task_with_priority_labels(
                    title,
                    "body",
                    TaskStatus::Done,
                    vec![],
                    vec![],
                    Priority::P2,
                )
                .unwrap();
        }
        for title in ["cancelled 1", "cancelled 2"] {
            store
                .create_task_with_priority_labels(
                    title,
                    "body",
                    TaskStatus::Cancelled,
                    vec![],
                    vec![],
                    Priority::P2,
                )
                .unwrap();
        }
        store
            .create_task_with_priority_labels(
                "blocked",
                "body",
                TaskStatus::Blocked,
                vec![],
                vec![],
                Priority::P2,
            )
            .unwrap();
        for title in ["todo 1", "todo 2"] {
            store
                .create_task_with_priority_labels(
                    title,
                    "body",
                    TaskStatus::Ready,
                    vec![],
                    vec![],
                    Priority::P2,
                )
                .unwrap();
        }
        store
            .create_task_with_priority_labels(
                "draft",
                "body",
                TaskStatus::Backlog,
                vec![],
                vec![],
                Priority::P2,
            )
            .unwrap();
    }
    {
        let mut store = Store::open_rw(data_root.path(), &finished.to_string()).unwrap();
        for title in ["done 1", "done 2", "done 3"] {
            store
                .create_task_with_priority_labels(
                    title,
                    "body",
                    TaskStatus::Done,
                    vec![],
                    vec![],
                    Priority::P2,
                )
                .unwrap();
        }
        store
            .create_task_with_priority_labels(
                "cancelled",
                "body",
                TaskStatus::Cancelled,
                vec![],
                vec![],
                Priority::P2,
            )
            .unwrap();
    }
    {
        let mut store = Store::open_rw(data_root.path(), &waiting.to_string()).unwrap();
        let prerequisite = store
            .create_task_with_priority_labels(
                "prerequisite",
                "body",
                TaskStatus::Ready,
                vec![],
                vec![],
                Priority::P2,
            )
            .unwrap()
            .0;
        store
            .create_task_with_priority_labels(
                "waits",
                "body",
                TaskStatus::InProgress,
                vec![prerequisite],
                vec![],
                Priority::P2,
            )
            .unwrap();
    }

    let all = projects(data_root.path(), json!({"state": "all", "limit": 200})).data();
    assert_eq!(all["total_count"], 5);

    let empty_state = projects(data_root.path(), json!({"state": "empty"})).data();
    assert_eq!(sorted_project_ids(&empty_state), vec![empty.to_string()]);

    let complete = projects(data_root.path(), json!({"state": "complete"})).data();
    assert_eq!(
        sorted_project_ids(&complete),
        vec![finished.to_string()],
        "an all-cancelled project is not complete"
    );

    let has_open = projects(data_root.path(), json!({"state": "has-open"})).data();
    let mut expected = vec![mixed.to_string(), waiting.to_string()];
    expected.sort();
    assert_eq!(sorted_project_ids(&has_open), expected);

    let has_blocked = projects(data_root.path(), json!({"state": "has-blocked"})).data();
    assert_eq!(sorted_project_ids(&has_blocked), vec![mixed.to_string()]);

    let unavailable = projects(data_root.path(), json!({"state": "unavailable"})).data();
    assert_eq!(unavailable["total_count"], 0);

    let items = all["items"].as_array().unwrap();
    let find = |id: &Uuid| {
        items
            .iter()
            .find(|item| item["project_id"] == id.to_string())
            .unwrap()
    };

    let mixed_stats = &find(&mixed)["stats"];
    assert_eq!(mixed_stats["total"], 10);
    assert_eq!(mixed_stats["open"], 4);
    assert_eq!(mixed_stats["blocked"], 1);
    assert_eq!(mixed_stats["done"], 4);
    assert_eq!(mixed_stats["cancelled"], 2);
    assert_eq!(
        mixed_stats["progress_percent"].as_f64().unwrap(),
        50.0,
        "10 total, 2 cancelled and 4 done is exactly 50.0%"
    );

    let empty_stats = &find(&empty)["stats"];
    assert_eq!(empty_stats["total"], 0);
    assert!(empty_stats["started_ms"].is_null());
    assert!(empty_stats["last_write_ms"].is_null());
    assert!(empty_stats["progress_percent"].is_null());

    let cancelled_stats = &find(&cancelled_only)["stats"];
    assert_eq!(cancelled_stats["total"], 2);
    assert_eq!(cancelled_stats["open"], 0);
    assert!(
        cancelled_stats["progress_percent"].is_null(),
        "an all-cancelled project is not 100% progress"
    );

    let waiting_stats = &find(&waiting)["stats"];
    assert_eq!(waiting_stats["open"], 2);
    assert_eq!(
        waiting_stats["blocked"], 0,
        "dependency waiting alone is not an explicit blocked status"
    );
}

#[test]
fn projects_query_matches_literal_characters_and_case() {
    let data_root = tempfile::tempdir().unwrap();
    let (percent, _) = add_project(data_root.path(), "100% Done");
    let (plain, _) = add_project(data_root.path(), "100 Done");
    let upper = add_project_nested(data_root.path(), "case-a", "Alpha");
    let lower = add_project_nested(data_root.path(), "case-b", "alpha");
    let (unicode, _) = add_project(data_root.path(), "Zażółć");
    let (underscore, _) = add_project(data_root.path(), "a_b");
    let (plain_b, _) = add_project(data_root.path(), "axb");
    let (quote, _) = add_project(data_root.path(), "O'Brien");

    let matched = |query: &str| -> Vec<String> {
        sorted_project_ids(
            &projects(data_root.path(), json!({"query": query, "limit": 200})).data(),
        )
    };
    let sorted = |ids: Vec<Uuid>| {
        let mut ids = ids.iter().map(|id| id.to_string()).collect::<Vec<_>>();
        ids.sort();
        ids
    };

    assert_eq!(matched("100%"), sorted(vec![percent]));
    assert_eq!(matched("100"), sorted(vec![percent, plain]));
    assert_eq!(matched("%"), sorted(vec![percent]), "% stays literal");
    assert_eq!(matched("_"), sorted(vec![underscore]), "_ stays literal");
    assert_eq!(matched("a_b"), sorted(vec![underscore]), "_ stays literal");
    assert_eq!(matched("axb"), sorted(vec![plain_b]));
    assert_eq!(matched("ALPHA"), sorted(vec![upper, lower]));
    assert_eq!(matched("zażółć"), sorted(vec![unicode]));
    assert_eq!(
        matched("ZAŻÓŁĆ"),
        Vec::<String>::new(),
        "non-ASCII case is matched exactly"
    );
    assert_eq!(matched("o'brien"), sorted(vec![quote]));
    assert_eq!(matched("  Alpha  "), sorted(vec![upper, lower]));
    let fragment = &plain_b.to_string()[..8];
    assert_eq!(
        matched(fragment),
        sorted(vec![plain_b]),
        "UUID is searchable"
    );
    assert_eq!(matched("").len(), 8);
}

#[test]
fn projects_sort_keys_both_directions_with_uuid_tie_break() {
    let data_root = tempfile::tempdir().unwrap();
    let (b_one, _) = add_project(data_root.path(), "b-one");
    let (a_two, _) = add_project(data_root.path(), "a-two");
    let (c_three, _) = add_project(data_root.path(), "c-three");
    let (d_four, _) = add_project(data_root.path(), "d-four");
    let (e_five, _) = add_project(data_root.path(), "e-five");

    {
        let mut store = Store::open_rw(data_root.path(), &b_one.to_string()).unwrap();
        for status in [TaskStatus::Blocked, TaskStatus::Done, TaskStatus::Ready] {
            store
                .create_task_with_priority_labels(
                    "task",
                    "body",
                    status,
                    vec![],
                    vec![],
                    Priority::P2,
                )
                .unwrap();
        }
    }
    {
        let mut store = Store::open_rw(data_root.path(), &a_two.to_string()).unwrap();
        for title in ["done one", "done two"] {
            store
                .create_task_with_priority_labels(
                    title,
                    "body",
                    TaskStatus::Done,
                    vec![],
                    vec![],
                    Priority::P2,
                )
                .unwrap();
        }
    }
    {
        let mut store = Store::open_rw(data_root.path(), &e_five.to_string()).unwrap();
        store
            .create_task_with_priority_labels(
                "cancelled",
                "body",
                TaskStatus::Cancelled,
                vec![],
                vec![],
                Priority::P2,
            )
            .unwrap();
    }
    let set_times = |id: &Uuid, created: i64, updated: i64| {
        let conn = Connection::open(project_db(data_root.path(), id)).unwrap();
        conn.execute(
            "UPDATE tasks SET created_ms=?1, updated_ms=?2",
            params![created, updated],
        )
        .unwrap();
    };
    set_times(&b_one, 1000, 1500);
    set_times(&a_two, 2000, 2100);
    set_times(&e_five, 500, 600);
    fs::remove_file(project_db(data_root.path(), &c_three)).unwrap();

    let a = a_two.to_string();
    let b = b_one.to_string();
    let c = c_three.to_string();
    let d = d_four.to_string();
    let e = e_five.to_string();
    // c_three has a missing database and d_four is empty, so both report null
    // started/last-write values. Nulls sort last in both directions and their
    // tie-break is the project UUID ascending, so the expected tail depends on
    // the generated identifiers.
    let null_tail = tied(vec![vec![c.clone(), d.clone()]]);
    let leaf = |head: [&String; 3]| -> Vec<String> {
        let mut out: Vec<String> = head.iter().map(|id| (*id).clone()).collect();
        out.extend(null_tail.iter().cloned());
        out
    };
    let cases: Vec<(&str, &str, Vec<String>)> = vec![
        (
            "name",
            "asc",
            vec![a.clone(), b.clone(), c.clone(), d.clone(), e.clone()],
        ),
        (
            "name",
            "desc",
            vec![e.clone(), d.clone(), c.clone(), b.clone(), a.clone()],
        ),
        (
            "open",
            "asc",
            tied(vec![
                vec![a.clone(), d.clone(), e.clone()],
                vec![b.clone()],
                vec![c.clone()],
            ]),
        ),
        (
            "open",
            "desc",
            tied(vec![
                vec![b.clone()],
                vec![a.clone(), d.clone(), e.clone()],
                vec![c.clone()],
            ]),
        ),
        (
            "total",
            "asc",
            vec![d.clone(), e.clone(), a.clone(), b.clone(), c.clone()],
        ),
        (
            "total",
            "desc",
            vec![b.clone(), a.clone(), e.clone(), d.clone(), c.clone()],
        ),
        (
            "blocked",
            "asc",
            tied(vec![
                vec![a.clone(), d.clone(), e.clone()],
                vec![b.clone()],
                vec![c.clone()],
            ]),
        ),
        (
            "blocked",
            "desc",
            tied(vec![
                vec![b.clone()],
                vec![a.clone(), d.clone(), e.clone()],
                vec![c.clone()],
            ]),
        ),
        ("started", "asc", leaf([&e, &b, &a])),
        ("started", "desc", leaf([&a, &b, &e])),
        ("last-write", "asc", leaf([&e, &b, &a])),
        ("last-write", "desc", leaf([&a, &b, &e])),
        (
            "progress",
            "asc",
            tied(vec![
                vec![b.clone()],
                vec![a.clone()],
                vec![c.clone(), d.clone(), e.clone()],
            ]),
        ),
        (
            "progress",
            "desc",
            tied(vec![
                vec![a.clone()],
                vec![b.clone()],
                vec![c.clone(), d.clone(), e.clone()],
            ]),
        ),
    ];
    for (sort, direction, expected) in cases {
        assert_eq!(expected.len(), 5);
        let data = projects(
            data_root.path(),
            json!({"state": "all", "sort": sort, "direction": direction, "limit": 200}),
        )
        .data();
        assert_eq!(data["total_count"], 5, "{sort} {direction}");
        assert_eq!(
            project_ids(&data),
            expected,
            "sort {sort} direction {direction}"
        );
    }
}

#[test]
fn projects_snapshot_is_stable_until_the_catalog_changes() {
    let data_root = tempfile::tempdir().unwrap();
    let (first, _) = add_project(data_root.path(), "first");
    let (second, _) = add_project(data_root.path(), "second");
    let (third, _) = add_project(data_root.path(), "third");
    for id in [&first, &second, &third] {
        let mut store = Store::open_rw(data_root.path(), &id.to_string()).unwrap();
        store
            .create_task_with_priority_labels(
                "task",
                "body",
                TaskStatus::Ready,
                vec![],
                vec![],
                Priority::P2,
            )
            .unwrap();
    }

    let page = projects(data_root.path(), json!({"limit": 1})).data();
    assert_eq!(page["total_count"], 3);
    assert_eq!(page["items"].as_array().unwrap().len(), 1);
    assert_eq!(page["has_more"], true);
    assert_eq!(page["next_offset"], 1);
    let token = page["snapshot"].as_str().unwrap().to_string();
    let decoded = decode_token(&token);
    assert_eq!(decoded["v"], 1);
    assert_eq!(decoded["kind"], "projects");
    assert_eq!(
        decoded["params"],
        json!({"query": "", "state": "all", "sort": "name", "direction": "asc"})
    );
    assert_eq!(decoded["catalog"].as_str().unwrap().len(), 64);

    // Sample times stay out of the digest, so an identical request reuses it.
    let repeat = projects(data_root.path(), json!({"limit": 1})).data();
    assert_eq!(repeat["snapshot"], token);

    // A valid token continues the catalog and keeps the bound count.
    let continued = projects(
        data_root.path(),
        json!({"limit": 1, "offset": 1, "snapshot": token}),
    )
    .data();
    assert_eq!(continued["total_count"], 3);
    assert_eq!(continued["next_offset"], 2);
    assert_eq!(continued["snapshot"], token);
    assert_eq!(continued["items"].as_array().unwrap().len(), 1);

    // The same token with a different query is stale.
    projects(
        data_root.path(),
        json!({"limit": 1, "query": "second", "snapshot": token}),
    )
    .fails_with_message(
        EXIT_CONFLICT_OR_STALE,
        "stale_snapshot",
        "changed since this page",
    );

    // A malformed token is stale as well and reports no items.
    let stale = projects(data_root.path(), json!({"snapshot": "not-a-token"}));
    stale.fails_with_message(EXIT_CONFLICT_OR_STALE, "stale_snapshot", "valid v1 token");
    assert!(stale.stdout.trim().is_empty());

    // A statistics change invalidates the catalog digest.
    {
        let mut store = Store::open_rw(data_root.path(), &third.to_string()).unwrap();
        store
            .create_task_with_priority_labels(
                "extra",
                "body",
                TaskStatus::Ready,
                vec![],
                vec![],
                Priority::P2,
            )
            .unwrap();
    }
    projects(
        data_root.path(),
        json!({"limit": 1, "offset": 1, "snapshot": token}),
    )
    .fails_with_message(
        EXIT_CONFLICT_OR_STALE,
        "stale_snapshot",
        "project catalog or query changed",
    );
}

#[test]
fn task_pages_return_the_documented_fields_without_bodies() {
    let project = Project::new();
    let prerequisite = project.add_plain("prerequisite", TaskStatus::Done);
    let id = project.add(
        "member",
        TaskStatus::InProgress,
        Priority::P0,
        &["Needs-Human", "Beta"],
        vec![prerequisite],
    );

    let data = project.tasks(json!({"scope": "all", "query": "member", "limit": 1}));
    assert_eq!(data["protocol_version"], 1);
    assert_eq!(data["total_count"], 1);
    assert_eq!(data["offset"], 0);
    assert_eq!(data["limit"], 1);
    assert_eq!(data["has_more"], false);
    assert!(data["next_offset"].is_null());
    let items = data["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    let item = &items[0];
    assert_eq!(item["id"], id);
    assert_eq!(item["title"], "member");
    assert_eq!(item["status"], "in-progress");
    assert_eq!(item["priority"], "P0");
    assert_eq!(item["version"], 1);
    assert_eq!(
        item["labels"],
        json!(["beta", "needs-human"]),
        "labels are normalized and sorted"
    );
    assert_eq!(item["dependency_count"], 1);
    assert_eq!(item["waiting_dependency_count"], 0);
    let created = item["created_ms"].as_i64().unwrap();
    let updated = item["updated_ms"].as_i64().unwrap();
    assert!(created > 0 && updated > 0);
    let mut keys = item
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect::<Vec<_>>();
    keys.sort();
    assert_eq!(
        keys,
        [
            "created_ms",
            "dependency_count",
            "id",
            "labels",
            "priority",
            "status",
            "title",
            "updated_ms",
            "version",
            "waiting_dependency_count",
        ],
        "a task page item exposes exactly the documented fields"
    );

    // A waiting dependency is counted, and a terminal dependency is not.
    let waiting = project.add(
        "waits",
        TaskStatus::Ready,
        Priority::P2,
        &[],
        vec![id, prerequisite],
    );
    let data = project.tasks(json!({"scope": "all", "query": "waits"}));
    assert_eq!(ids(&data), [waiting]);
    let item = &data["items"][0];
    assert_eq!(item["dependency_count"], 2);
    assert_eq!(
        item["waiting_dependency_count"], 1,
        "only the non-terminal prerequisite waits"
    );

    // Pages never embed the body, dependency IDs or rules.
    let body = "body text that must not appear in a page";
    let described = project.add_body("described", body, TaskStatus::Ready);
    let data = project.tasks(json!({"scope": "all", "query": "described"}));
    assert_eq!(ids(&data), [described]);
    let serialized = data.to_string();
    assert!(
        !serialized.contains(body),
        "task pages must not embed bodies: {serialized}"
    );
    assert!(data["items"][0].get("deps").is_none());
    assert!(data["items"][0].get("rules").is_none());

    // The end of a page set is an empty success page, not an error.
    let end = project.tasks(json!({"scope": "all", "offset": 4, "limit": 5}));
    assert_eq!(end["total_count"], 4);
    assert!(end["items"].as_array().unwrap().is_empty());
    assert_eq!(end["has_more"], false);
    assert!(end["next_offset"].is_null());
}

#[test]
fn task_filters_combine_scope_status_priority_labels_and_readiness() {
    let project = Project::new();
    let todo = project.add_plain("todo", TaskStatus::Ready);
    let progress = project.add(
        "in progress",
        TaskStatus::InProgress,
        Priority::P1,
        &[],
        vec![],
    );
    let blocked = project.add("blocked", TaskStatus::Blocked, Priority::P0, &[], vec![]);
    let done = project.add_plain("done", TaskStatus::Done);
    let cancelled = project.add_plain("cancelled", TaskStatus::Cancelled);
    let human = project.add(
        "needs human",
        TaskStatus::Ready,
        Priority::P2,
        &["needs-human"],
        vec![],
    );
    let waiting = project.add(
        "waiting",
        TaskStatus::Ready,
        Priority::P2,
        &[],
        vec![blocked],
    );
    let satisfied = project.add(
        "satisfied",
        TaskStatus::Ready,
        Priority::P2,
        &[],
        vec![done],
    );
    let cancelled_dep = project.add(
        "cancelled dependency",
        TaskStatus::Ready,
        Priority::P2,
        &[],
        vec![cancelled],
    );
    let both = project.add(
        "both labels",
        TaskStatus::Ready,
        Priority::P3,
        &["needs-human", "beta"],
        vec![],
    );

    let query = |document: Value| ids(&project.tasks(document));

    assert_eq!(
        query(json!({"sort": "id", "limit": 200})),
        [
            todo,
            progress,
            blocked,
            human,
            waiting,
            satisfied,
            cancelled_dep,
            both
        ],
        "the default scope hides only done and cancelled"
    );
    assert_eq!(
        query(json!({"scope": "all", "sort": "id", "limit": 200})),
        [
            todo,
            progress,
            blocked,
            done,
            cancelled,
            human,
            waiting,
            satisfied,
            cancelled_dep,
            both
        ]
    );
    assert_eq!(
        query(json!({"statuses": ["todo"], "sort": "id", "limit": 200})),
        [todo, human, waiting, satisfied, cancelled_dep, both]
    );
    assert_eq!(
        query(json!({"statuses": ["done"], "sort": "id"})),
        Vec::<u64>::new(),
        "an explicit status still intersects the open scope"
    );
    let mut expected = vec![todo, human, waiting, satisfied, cancelled_dep, both];
    expected.push(cancelled);
    expected.sort();
    assert_eq!(
        query(
            json!({"scope": "all", "statuses": ["todo", "cancelled"], "sort": "id", "limit": 200})
        ),
        expected
    );
    assert_eq!(
        query(json!({"scope": "all", "statuses": ["done"], "sort": "id"})),
        [done]
    );
    assert_eq!(
        query(json!({"scope": "all", "priorities": ["P0", "P1"], "sort": "id"})),
        [progress, blocked]
    );
    assert_eq!(
        query(json!({"scope": "all", "labels": ["needs-human"], "sort": "id"})),
        [human, both]
    );
    assert_eq!(
        query(json!({"scope": "all", "labels": ["needs-human", "beta"], "sort": "id"})),
        [both],
        "labels require every selected label"
    );
    assert_eq!(
        query(json!({"scope": "all", "labels": ["BETA"], "sort": "id"})),
        [both],
        "label filters normalize"
    );

    // Readiness is separate from explicit blocked status: a blocked task is
    // never runnable, and a cancelled dependency neither waits nor satisfies.
    assert_eq!(
        query(json!({"scope": "all", "readiness": "runnable", "sort": "id"})),
        [todo, progress, satisfied]
    );
    assert_eq!(
        query(json!({"scope": "all", "readiness": "waiting", "sort": "id"})),
        [waiting]
    );

    // The runnable set must equal the existing store selection predicate.
    let mut store = project.store();
    let selection = store
        .select_tasks(None, None, 100, None, false, false)
        .unwrap();
    let store_ids = selection
        .items
        .iter()
        .map(|item| item.id)
        .collect::<Vec<_>>();
    assert_eq!(
        store_ids,
        [progress, todo, satisfied],
        "the store default selection orders by priority then id"
    );
    assert_eq!(
        project.tasks(json!({"scope": "all", "readiness": "runnable", "limit": 200}))["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["id"].as_u64().unwrap())
            .collect::<Vec<_>>(),
        store_ids,
        "viewer readiness reuses the store predicate and priority order"
    );

    // Filter groups combine with AND.
    assert_eq!(
        query(json!({
            "scope": "all",
            "statuses": ["todo"],
            "priorities": ["P2"],
            "labels": ["needs-human"],
            "readiness": "any",
            "sort": "id"
        })),
        [human]
    );
    assert_eq!(
        query(json!({"scope": "all", "readiness": "runnable", "query": "sat", "sort": "id"})),
        [satisfied]
    );
    assert_eq!(
        query(json!({"scope": "all", "readiness": "waiting", "query": "todo"})),
        Vec::<u64>::new(),
        "a query that matches no waiting task stays empty"
    );
}

#[test]
fn task_query_matches_literal_characters_ids_and_bodies() {
    let project = Project::new();
    let percent = project.add_plain("50% off", TaskStatus::Ready);
    let percent_plain = project.add_plain("50 off", TaskStatus::Ready);
    let underscore = project.add_plain("a_b", TaskStatus::Ready);
    let quote = project.add_plain("O'Brien notes", TaskStatus::Ready);
    let backslash = project.add_plain("C:\\temp", TaskStatus::Ready);
    let unicode = project.add_plain(
        "Za\u{17c}\u{f3}\u{142}\u{107} g\u{119}\u{15b}l\u{105}",
        TaskStatus::Ready,
    );
    let ascii_upper = project.add_plain("ALPHA release", TaskStatus::Ready);
    let body_only = project.add_body(
        "plain title",
        "buried \u{17c}ubr needle and 42",
        TaskStatus::Ready,
    );
    let numeric = project.add_plain("numeric target", TaskStatus::Ready);

    let query = |text: &str| {
        ids(&project.tasks(json!({"scope": "all", "query": text, "sort": "id", "limit": 200})))
    };

    assert_eq!(query("50%"), [percent], "the wildcard stays literal");
    assert_eq!(query("50"), [percent, percent_plain]);
    assert_eq!(query("%"), [percent]);
    assert_eq!(query("_"), [underscore]);
    assert_eq!(query("a_b"), [underscore]);
    assert_eq!(query("o'brien"), [quote], "ASCII case folds");
    assert_eq!(query("O'Brien"), [quote]);
    assert_eq!(query("\\"), [backslash], "a backslash stays literal");
    assert_eq!(query("za\u{17c}\u{f3}\u{142}\u{107}"), [unicode]);
    assert_eq!(
        query("ZA\u{17b}\u{d3}\u{141}\u{106}"),
        Vec::<u64>::new(),
        "non-ASCII case is matched exactly"
    );
    assert_eq!(query("alpha"), [ascii_upper]);
    assert_eq!(query("  alpha  "), [ascii_upper], "queries are trimmed");
    assert_eq!(
        query("\u{17c}ubr"),
        [body_only],
        "task search reads the body without returning it"
    );
    assert_eq!(query("plain title"), [body_only]);

    // A complete T-<digits> query matches the numeric ID and nothing else.
    let padded = format!("T-{numeric:03}");
    let unpadded = format!("t-{numeric}");
    let over_padded = format!("T-{numeric:04}");
    assert_eq!(query(&padded), [numeric]);
    assert_eq!(query(&unpadded), [numeric]);
    assert_eq!(query(&over_padded), [numeric]);
    assert_eq!(
        query("T-999"),
        Vec::<u64>::new(),
        "an unknown T-ID is an empty page, not an error"
    );
    assert_eq!(query("").len(), 9, "an empty query matches every task");
}

#[test]
fn task_sort_keys_both_directions_with_id_tie_break() {
    let project = Project::new();
    let alpha_lower = project.add("alpha", TaskStatus::Ready, Priority::P2, &[], vec![]);
    let alpha_upper = project.add("ALPHA", TaskStatus::Ready, Priority::P2, &[], vec![]);
    let alpha_mixed = project.add("Alpha", TaskStatus::Ready, Priority::P2, &[], vec![]);
    let zebra = project.add("Zebra", TaskStatus::Ready, Priority::P1, &[], vec![]);
    let zubr = project.add("\u{17c}ubr", TaskStatus::Done, Priority::P1, &[], vec![]);
    let beta = project.add("beta", TaskStatus::Blocked, Priority::P0, &[], vec![]);
    let gamma = project.add("gamma", TaskStatus::Blocked, Priority::P0, &[], vec![]);
    let delta = project.add("delta", TaskStatus::Cancelled, Priority::P3, &[], vec![]);

    let conn = project.conn();
    let set_times = |id: u64, created: i64, updated: i64| {
        conn.execute(
            "UPDATE tasks SET created_ms=?1, updated_ms=?2 WHERE id=?3",
            params![created, updated, id as i64],
        )
        .unwrap();
    };
    for id in [alpha_lower, alpha_upper, alpha_mixed] {
        set_times(id, 1000, 1500);
    }
    for id in [zebra, zubr] {
        set_times(id, 2000, 2500);
    }
    for id in [beta, gamma] {
        set_times(id, 500, 3000);
    }
    set_times(delta, 3000, 500);

    let order = |sort: &str, direction: &str| {
        ids(&project.tasks(json!({
            "scope": "all",
            "sort": sort,
            "direction": direction,
            "limit": 200
        })))
    };
    let cases: Vec<(&str, &str, Vec<u64>)> = vec![
        ("id", "asc", vec![1, 2, 3, 4, 5, 6, 7, 8]),
        ("id", "desc", vec![8, 7, 6, 5, 4, 3, 2, 1]),
        ("priority", "asc", vec![6, 7, 4, 5, 1, 2, 3, 8]),
        ("priority", "desc", vec![8, 1, 2, 3, 4, 5, 6, 7]),
        ("status", "asc", vec![1, 2, 3, 4, 6, 7, 5, 8]),
        ("status", "desc", vec![8, 5, 6, 7, 1, 2, 3, 4]),
        ("title", "asc", vec![2, 3, 1, 6, 8, 7, 4, 5]),
        ("title", "desc", vec![5, 4, 7, 8, 6, 1, 3, 2]),
        ("created", "asc", vec![6, 7, 1, 2, 3, 4, 5, 8]),
        ("created", "desc", vec![8, 4, 5, 1, 2, 3, 6, 7]),
        ("updated", "asc", vec![8, 1, 2, 3, 4, 5, 6, 7]),
        ("updated", "desc", vec![6, 7, 4, 5, 1, 2, 3, 8]),
    ];
    for (sort, direction, expected) in cases {
        assert_eq!(
            order(sort, direction),
            expected,
            "sort {sort} direction {direction}"
        );
    }
}

#[test]
fn task_pages_respect_limit_offset_and_end_boundaries() {
    let project = Project::new();
    for index in 1..=5 {
        project.add_plain(&format!("task {index}"), TaskStatus::Ready);
    }

    let defaults = project.tasks(json!({"scope": "all"}));
    assert_eq!(defaults["total_count"], 5);
    assert_eq!(defaults["offset"], 0);
    assert_eq!(defaults["limit"], 100, "the documented default limit");
    assert_eq!(defaults["has_more"], false);
    assert!(defaults["next_offset"].is_null());
    assert_eq!(ids(&defaults), [1, 2, 3, 4, 5]);

    let first = project.tasks(json!({"scope": "all", "limit": 2}));
    assert_eq!(ids(&first), [1, 2]);
    assert_eq!(first["total_count"], 5);
    assert_eq!(first["has_more"], true);
    assert_eq!(first["next_offset"], 2);
    let token = first["snapshot"].as_str().unwrap().to_string();

    let second = project.tasks(json!({
        "scope": "all",
        "limit": 2,
        "offset": 2,
        "snapshot": token
    }));
    assert_eq!(ids(&second), [3, 4]);
    assert_eq!(second["offset"], 2);
    assert_eq!(second["total_count"], 5);
    assert_eq!(second["has_more"], true);
    assert_eq!(second["next_offset"], 4);

    let last = project.tasks(json!({"scope": "all", "limit": 2, "offset": 4}));
    assert_eq!(ids(&last), [5]);
    assert_eq!(last["has_more"], false);
    assert!(last["next_offset"].is_null());

    let ends_exactly = project.tasks(json!({"scope": "all", "limit": 2, "offset": 3}));
    assert_eq!(ids(&ends_exactly), [4, 5]);
    assert_eq!(ends_exactly["has_more"], false);
    assert!(ends_exactly["next_offset"].is_null());

    for offset in [5, 6, 1_000_000] {
        let beyond = project.tasks(json!({"scope": "all", "limit": 200, "offset": offset}));
        assert!(
            beyond["items"].as_array().unwrap().is_empty(),
            "offset {offset}"
        );
        assert_eq!(beyond["total_count"], 5, "offset {offset} still counts");
        assert_eq!(beyond["has_more"], false);
        assert!(beyond["next_offset"].is_null());
        assert_eq!(beyond["offset"], offset);
    }

    // A page far into a larger list is served by SQL with the same contract.
    let deep = Project::new();
    for index in 1..=250 {
        deep.add_plain(&format!("task {index:03}"), TaskStatus::Ready);
    }
    let page = deep.tasks(json!({"scope": "all", "offset": 200, "limit": 50}));
    assert_eq!(page["total_count"], 250);
    assert_eq!(ids(&page), (201..=250).collect::<Vec<u64>>());
    assert_eq!(page["has_more"], false);
    assert!(page["next_offset"].is_null());
    let single = deep.tasks(json!({"scope": "all", "offset": 249, "limit": 1}));
    assert_eq!(ids(&single), [250]);
    assert!(single["next_offset"].is_null());
    let past_end = deep.tasks(json!({"scope": "all", "offset": 250, "limit": 1}));
    assert_eq!(past_end["total_count"], 250);
    assert!(past_end["items"].as_array().unwrap().is_empty());
    assert!(past_end["next_offset"].is_null());
    assert_eq!(page["limit"], 50);
    assert_eq!(page["offset"], 200);
}

#[test]
fn task_snapshot_binds_events_counts_and_parameters() {
    let project = Project::new();
    for index in 1..=5 {
        project.add_plain(&format!("task {index}"), TaskStatus::Ready);
    }

    let page = project.tasks(json!({"scope": "all", "limit": 2}));
    let token = page["snapshot"].as_str().unwrap().to_string();
    let decoded = decode_token(&token);
    assert_eq!(decoded["v"], 1);
    assert_eq!(decoded["kind"], "tasks");
    assert_eq!(decoded["project"], project.id_text());
    assert_eq!(decoded["count"], 5);
    assert_eq!(
        decoded["params"],
        json!({
            "query": "",
            "scope": "all",
            "statuses": [],
            "priorities": [],
            "labels": [],
            "readiness": "any",
            "sort": "priority",
            "direction": "asc"
        })
    );
    assert!(!decoded["file"].as_str().unwrap().is_empty());
    let max_event: i64 = project
        .conn()
        .query_row("SELECT MAX(event_id) FROM events", [], |row| row.get(0))
        .unwrap();
    assert_eq!(
        decoded["event"], max_event as u64,
        "the token binds the current maximum event ID"
    );

    // A valid token continues the list and keeps the bound count.
    let continued = project.tasks(json!({
        "scope": "all",
        "limit": 2,
        "offset": 2,
        "snapshot": token
    }));
    assert_eq!(continued["snapshot"], token);
    assert_eq!(continued["total_count"], 5);
    assert_eq!(ids(&continued), [3, 4]);

    // The bound count is reused instead of recounted. A row that never entered
    // the event stream changes the table without invalidating the page.
    project
        .conn()
        .execute(
            "INSERT INTO tasks(id, title, body, status, version, created_ms, updated_ms, priority)
             VALUES (99, 'out of band', 'body', 'todo', 1, 1, 1, 'P2')",
            [],
        )
        .unwrap();
    let reused = project.tasks(json!({
        "scope": "all",
        "limit": 2,
        "offset": 2,
        "snapshot": token
    }));
    assert_eq!(
        reused["total_count"], 5,
        "valid-token pages reuse the bound count without recounting"
    );
    assert_eq!(ids(&reused), [3, 4]);
    assert_eq!(reused["has_more"], true);
    assert_eq!(reused["next_offset"], 4);
    let recounted = project.tasks(json!({"scope": "all", "limit": 2}));
    assert_eq!(recounted["total_count"], 6, "a null snapshot recounts");

    // Query and sort parameters are part of the binding.
    for changed in [
        json!({"scope": "all", "limit": 2, "snapshot": token, "sort": "id"}),
        json!({"scope": "all", "limit": 2, "snapshot": token, "query": "task 3"}),
        json!({"scope": "open", "limit": 2, "snapshot": token}),
        json!({"scope": "all", "limit": 2, "snapshot": token, "direction": "desc"}),
    ] {
        project.viewer("tasks", changed).fails_with_message(
            EXIT_CONFLICT_OR_STALE,
            "stale_snapshot",
            "task list changed since this page was requested",
        );
    }
    project
        .viewer("tasks", json!({"scope": "all", "snapshot": "v1:zz"}))
        .fails_with_message(
            EXIT_CONFLICT_OR_STALE,
            "stale_snapshot",
            "not a valid v1 token",
        );
    project
        .viewer("tasks", json!({"scope": "all", "snapshot": "not-a-token"}))
        .fails_with_message(
            EXIT_CONFLICT_OR_STALE,
            "stale_snapshot",
            "not a valid v1 token",
        );

    // A write in the same millisecond still invalidates the page.
    let conn = project.conn();
    let stamp: i64 = conn
        .query_row(
            "SELECT created_ms FROM events ORDER BY event_id DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    conn.execute(
        "INSERT INTO events(task_id, entity_type, operation, resulting_version, created_ms, snapshot_json)
         VALUES (NULL, 'task', 'update', 1, ?1, '{}')",
        params![stamp],
    )
    .unwrap();
    let stamps = conn
        .prepare("SELECT created_ms FROM events ORDER BY event_id DESC LIMIT 2")
        .unwrap()
        .query_map([], |row| row.get::<_, i64>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(stamps.len(), 2);
    assert_eq!(
        stamps[0], stamps[1],
        "the invalidation cannot rely on a changed timestamp"
    );
    project
        .viewer(
            "tasks",
            json!({"scope": "all", "limit": 2, "snapshot": token}),
        )
        .fails_with_message(
            EXIT_CONFLICT_OR_STALE,
            "stale_snapshot",
            "task list changed since this page was requested",
        );
    let fresh = project.tasks(json!({"scope": "all", "limit": 2}));
    assert_eq!(fresh["total_count"], 6);
    assert_ne!(fresh["snapshot"], token);
}
#[test]
fn viewer_show_matches_legacy_detail_and_adds_running_timestamps() {
    let project = Project::new();
    let dependency = project.add_plain("dependency", TaskStatus::Ready);
    let title = "Detail task with \u{fc}n\u{ef}code \u{1f600}";
    let body = "line one\nline two\n\u{1f642}\n";

    let before = now_ms();
    let (id, version, _) = {
        let mut store = project.store();
        store
            .create_task_with_priority_labels(
                title,
                body,
                TaskStatus::Blocked,
                vec![dependency],
                vec!["Needs-Human".to_string(), "Viewer".to_string()],
                Priority::P1,
            )
            .unwrap()
    };
    let after = now_ms();
    let id_text = format!("T-{id:03}");

    let data = project.run(&["viewer", "show", &id_text]).data();
    assert_eq!(data["protocol_version"], 1);

    // Every existing TaskDetail field keeps the legacy `show` value.
    let legacy = spawn(
        &viewer_args(
            project.data_root.path(),
            Some(&project.id_text()),
            &["show", &id_text],
        ),
        None,
    )
    .data();
    assert_eq!(legacy["command"], "show");
    for field in [
        "id",
        "status",
        "priority",
        "version",
        "title",
        "body",
        "deps",
        "labels",
        "dependency_summaries",
        "rule_version",
        "rules",
    ] {
        assert_eq!(
            data[field], legacy[field],
            "viewer show must repeat the legacy detail field '{field}'"
        );
    }
    // The legacy command itself is unchanged: no protocol or timestamp fields.
    assert!(legacy.get("protocol_version").is_none());
    assert!(legacy.get("created_ms").is_none());
    assert!(legacy.get("updated_ms").is_none());

    assert_eq!(data["id"], id);
    assert_eq!(data["title"], title);
    assert_eq!(data["body"], body);
    assert_eq!(data["status"], "blocked");
    assert_eq!(data["priority"], "P1");
    assert_eq!(data["version"], version);
    assert_eq!(data["deps"], json!([dependency]));
    assert_eq!(data["labels"], json!(["needs-human", "viewer"]));
    assert_eq!(
        data["dependency_summaries"],
        json!([{
            "id": dependency,
            "status": "todo",
            "version": 1,
            "title": "dependency"
        }])
    );

    // The timestamps come from the running task store, not from a constant.
    let created = data["created_ms"].as_i64().unwrap();
    let updated = data["updated_ms"].as_i64().unwrap();
    assert_eq!(created, updated, "a fresh task has equal timestamps");
    assert!(
        created >= before && created <= after,
        "created_ms {created} must fall inside the creation window {before}..={after}"
    );
}

#[test]
fn viewer_show_reports_missing_tasks_and_invalid_ids() {
    let project = Project::new();
    project.add_plain("task", TaskStatus::Ready);

    project
        .run(&["viewer", "show", "T-999"])
        .fails_with_message(EXIT_NOT_FOUND, "not_found", "T-999");
    project.run(&["viewer", "show", "007"]).fails_with_message(
        EXIT_USAGE,
        "validation",
        "expected the form T-<digits>",
    );
}

#[test]
fn viewer_update_applies_all_six_fields_and_records_one_event() {
    let project = Project::new();
    let dependency = project.add_plain("dependency", TaskStatus::Ready);
    let target = project.add_plain("target", TaskStatus::Ready);
    let version = task_version(&project, target);
    let events_before = task_events(&project, target);
    let all_before = all_events(&project);

    let data = update(
        project.data_root.path(),
        &project.id,
        json!({
            "id": target,
            "expect_version": version,
            "changes": {
                "title": "Renamed \u{fc}n\u{ef}code target",
                "body": "new body\nsecond line\n",
                "status": "in-progress",
                "priority": "P0",
                "labels": ["Needs-Human", "Viewer", "viewer"],
                "deps": [dependency],
            }
        }),
    )
    .data();
    assert_eq!(data["protocol_version"], 1);
    assert_eq!(data["id"], target);
    assert_eq!(data["status"], "in-progress");
    assert_eq!(data["version"], version + 1);
    let event_id = data["event_id"]
        .as_u64()
        .expect("a permitted change reports its event id");

    // Exactly one additional event row exists, for this task and no other.
    assert_eq!(task_version(&project, target), version + 1);
    assert_eq!(task_events(&project, target), events_before + 1);
    assert_eq!(all_events(&project), all_before + 1);

    // The written event binds the normalized values and resulting version.
    let (operation, resulting_version, snapshot): (String, i64, String) = project
        .conn()
        .query_row(
            "SELECT operation, resulting_version, snapshot_json FROM events WHERE event_id=?1",
            [event_id as i64],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(operation, "update");
    assert_eq!(resulting_version as u64, version + 1);
    let snapshot: Value = serde_json::from_str(&snapshot).unwrap();
    assert_eq!(snapshot["title"], "Renamed \u{fc}n\u{ef}code target");
    assert_eq!(snapshot["body"], "new body\nsecond line\n");
    assert_eq!(snapshot["status"], "in-progress");
    assert_eq!(snapshot["version"], version + 1);
    assert_eq!(snapshot["labels"], json!(["needs-human", "viewer"]));
    assert_eq!(snapshot["deps"], json!([dependency]));

    // Reconciliation through `viewer show` and the task list agrees.
    let id_text = format!("T-{target:03}");
    let shown = project.run(&["viewer", "show", &id_text]).data();
    assert_eq!(shown["title"], "Renamed \u{fc}n\u{ef}code target");
    assert_eq!(shown["body"], "new body\nsecond line\n");
    assert_eq!(shown["status"], "in-progress");
    assert_eq!(shown["priority"], "P0");
    assert_eq!(shown["labels"], json!(["needs-human", "viewer"]));
    assert_eq!(shown["deps"], json!([dependency]));
    assert_eq!(
        project.ids(json!({"scope": "all", "query": "Renamed", "limit": 5})),
        [target]
    );
    let page = inspect(
        project.data_root.path(),
        &project.id,
        json!({"scope": "all", "limit": 5, "query": id_text}),
    )
    .data();
    assert_eq!(ids(&page), [target]);
    assert_eq!(page["items"][0]["dependency_count"], 1);
    assert_eq!(
        page["items"][0]["waiting_dependency_count"], 1,
        "a nonterminal dependency makes the task wait"
    );

    // Empty arrays clear the collections; an empty body is a permitted value.
    let cleared = update(
        project.data_root.path(),
        &project.id,
        json!({
            "id": target,
            "expect_version": version + 1,
            "changes": {"labels": [], "deps": [], "body": ""}
        }),
    )
    .data();
    assert_eq!(cleared["version"], version + 2);
    let shown = project.run(&["viewer", "show", &id_text]).data();
    assert_eq!(shown["labels"], json!([]));
    assert_eq!(shown["deps"], json!([]));
    assert_eq!(shown["body"], "");
    assert_eq!(task_events(&project, target), events_before + 2);
}

#[test]
fn viewer_update_noop_and_version_conflict_write_nothing() {
    let project = Project::new();
    let id = project.add(
        "noop target",
        TaskStatus::Ready,
        Priority::P1,
        &["viewer"],
        Vec::new(),
    );
    let version = task_version(&project, id);
    let events = task_events(&project, id);
    let updated_before: i64 = project
        .conn()
        .query_row("SELECT updated_ms FROM tasks WHERE id=?1", [id], |row| {
            row.get(0)
        })
        .unwrap();

    // A change set that normalizes to the stored values is a reported no-op.
    let noop = update(
        project.data_root.path(),
        &project.id,
        json!({
            "id": id,
            "expect_version": version,
            "changes": {"title": "noop target", "priority": "P1", "labels": ["VIEWER"], "deps": []}
        }),
    )
    .data();
    assert_eq!(noop["protocol_version"], 1);
    assert_eq!(noop["id"], id);
    assert_eq!(noop["status"], "todo");
    assert_eq!(noop["version"], version, "a no-op keeps the version");
    assert!(
        noop["event_id"].is_null(),
        "a no-op reports no event: {noop}"
    );
    assert_eq!(task_version(&project, id), version);
    assert_eq!(task_events(&project, id), events, "a no-op writes no event");
    let updated_after: i64 = project
        .conn()
        .query_row("SELECT updated_ms FROM tasks WHERE id=?1", [id], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(
        updated_after, updated_before,
        "a no-op does not bump updated_ms"
    );

    // A stale expectation is a version conflict, distinct from stale_snapshot.
    let error = update(
        project.data_root.path(),
        &project.id,
        json!({
            "id": id,
            "expect_version": version + 7,
            "changes": {"title": "must not land"}
        }),
    )
    .fails(EXIT_CONFLICT_OR_STALE, "version_conflict");
    assert_eq!(
        error["conflict"],
        json!({"expected": version + 7, "current": version})
    );
    assert_eq!(task_title(&project, id), "noop target");
    assert_eq!(task_version(&project, id), version);
    assert_eq!(task_events(&project, id), events);
}

#[test]
fn viewer_update_validation_errors_write_nothing() {
    let project = Project::new();
    let id = project.add_plain("valid task", TaskStatus::Ready);
    let version = task_version(&project, id);
    let events = task_events(&project, id);
    let all = all_events(&project);

    let long_title = "x".repeat(501);
    let long_body = "y".repeat(1_048_577);
    let many_labels: Vec<String> = (0..33).map(|index| format!("label-{index}")).collect();

    let rejected = vec![
        (
            json!({"id": id, "expect_version": version, "changes": {"title": ""}}),
            EXIT_USAGE,
            "validation",
            "the title is empty",
        ),
        (
            json!({"id": id, "expect_version": version, "changes": {"title": long_title}}),
            EXIT_USAGE,
            "validation",
            "the limit is 500",
        ),
        (
            json!({"id": id, "expect_version": version, "changes": {"body": long_body}}),
            EXIT_USAGE,
            "validation",
            "the limit is 1048576",
        ),
        (
            json!({"id": id, "expect_version": version, "changes": {"labels": ["has space"]}}),
            EXIT_USAGE,
            "validation",
            "labels must contain 1-64 ASCII letters",
        ),
        (
            json!({"id": id, "expect_version": version, "changes": {"labels": many_labels}}),
            EXIT_USAGE,
            "validation",
            "at most 32 labels",
        ),
        (
            json!({"id": id, "expect_version": version, "changes": {"deps": [id]}}),
            EXIT_USAGE,
            "validation",
            "lists itself as a dependency",
        ),
        (
            json!({"id": id, "expect_version": version, "changes": {"deps": [2, 2]}}),
            EXIT_USAGE,
            "validation",
            "listed more than once",
        ),
        (
            json!({"id": id, "expect_version": version, "changes": {"deps": [9999]}}),
            EXIT_USAGE,
            "validation",
            "remove T-9999 from Deps",
        ),
        (
            json!({"id": id, "expect_version": version, "changes": {"deps": [-1]}}),
            EXIT_USAGE,
            "usage",
            "'deps' items must be whole numbers that are zero or greater",
        ),
        (
            json!({"id": id, "expect_version": version, "changes": {}}),
            EXIT_USAGE,
            "usage",
            "the changes object is empty",
        ),
        (
            json!({"id": id, "expect_version": version}),
            EXIT_USAGE,
            "usage",
            "missing the required field 'changes'",
        ),
        (
            json!({"id": id, "expect_version": version, "changes": null}),
            EXIT_USAGE,
            "usage",
            "the viewer request must be a JSON object, found null",
        ),
        (
            json!({"id": id, "changes": {"title": "x"}}),
            EXIT_USAGE,
            "usage",
            "missing the required field 'expect_version'",
        ),
        (
            json!({"expect_version": version, "changes": {"title": "x"}}),
            EXIT_USAGE,
            "usage",
            "missing the required field 'id'",
        ),
        (
            json!({"id": 0, "expect_version": version, "changes": {"title": "x"}}),
            EXIT_USAGE,
            "usage",
            "'id' must be a positive whole number",
        ),
        (
            json!({"id": id, "expect_version": 0, "changes": {"title": "x"}}),
            EXIT_USAGE,
            "usage",
            "'expect_version' must be a positive whole number",
        ),
        (
            json!({"id": id, "expect_version": version, "changes": {"title": "x", "rules": "no"}}),
            EXIT_USAGE,
            "usage",
            "unknown viewer request field 'rules'",
        ),
        (
            json!({"id": id, "expect_version": version, "changes": {"status": "finished"}}),
            EXIT_USAGE,
            "usage",
            "'status' has the unsupported value 'finished'",
        ),
    ];

    for (document, exit, code, needle) in rejected {
        update(project.data_root.path(), &project.id, document)
            .fails_with_message(exit, code, needle);
    }

    assert_eq!(task_title(&project, id), "valid task");
    assert_eq!(task_version(&project, id), version);
    assert_eq!(task_events(&project, id), events);
    assert_eq!(all_events(&project), all);
}
