//! The nonterminal `to-verify` status: schema 5 migration, readiness in
//! default list and unlocks, the completion guard, listing scopes, the CLI
//! lifecycle and Markdown round trip.

use rusqlite::{types::Value, Connection};
use serde_json::Value as Json;
use std::{fs, process::Command, process::Output};
use tasks_cli::{
    markdown,
    model::{TaskStatus, TaskUpdate},
    store::{create_project_db, data_root_project_path, Store, CURRENT_SCHEMA_VERSION},
};
use tempfile::TempDir;
use uuid::Uuid;

fn new_store() -> (TempDir, Uuid, Store) {
    let root = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    create_project_db(root.path(), &id).unwrap();
    let store = Store::open_rw(root.path(), &id.to_string()).unwrap();
    (root, id, store)
}

fn set_status(store: &mut Store, id: u64, status: TaskStatus) -> Result<u64, String> {
    let version = store.show_task(&format!("T-{id}")).unwrap().version;
    store
        .update_task(
            id,
            version,
            TaskUpdate {
                status: Some(status),
                ..TaskUpdate::default()
            },
        )
        .map(|r| r.2)
        .map_err(|e| e.to_string())
}

fn ids(store: &mut Store, status: Option<&str>, open: bool) -> Vec<u64> {
    store
        .select_tasks(status, None, 100, None, open, false)
        .unwrap()
        .items
        .iter()
        .map(|t| t.id)
        .collect()
}

fn values(conn: &Connection, sql: &str) -> Vec<Vec<Value>> {
    let mut statement = conn.prepare(sql).unwrap();
    let width = statement.column_count();
    statement
        .query_map([], |r| (0..width).map(|i| r.get(i)).collect())
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn v4_fixture(root: &std::path::Path, id: &Uuid) {
    let path = data_root_project_path(root, &id.to_string());
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let conn = Connection::open(path).unwrap();
    for sql in [
        include_str!("fixtures/schema-v2.sql"),
        include_str!("fixtures/schema-v3-additions.sql"),
        include_str!("fixtures/schema-v4-additions.sql"),
    ] {
        conn.execute_batch(sql).unwrap();
    }
    conn.execute(
        "INSERT INTO project VALUES(?1,'rules Ω',7,12)",
        [id.to_string()],
    )
    .unwrap();
    conn.execute_batch(
        "INSERT INTO tasks(id,title,body,status,version,created_ms,updated_ms,priority)
           VALUES(7,'cache layer','body Ω','in-progress',3,1,2,'P1'),(9,'dependent','other','todo',4,5,6,'P2');
         INSERT INTO dependencies VALUES(9,7);
         INSERT INTO task_labels VALUES(7,'needs-human');
         INSERT INTO events VALUES(17,7,'task','update',3,2,' untouched snapshot ');
         INSERT INTO imports VALUES('sha','old.md',X'000A0DFF','original report',9);",
    )
    .unwrap();
}

const PRESERVED: [(&str, &str); 6] = [
    ("project", "SELECT * FROM project"),
    (
        "tasks",
        "SELECT id,title,body,status,version,created_ms,updated_ms,priority FROM tasks ORDER BY id",
    ),
    (
        "dependencies",
        "SELECT * FROM dependencies ORDER BY task_id",
    ),
    ("task_labels", "SELECT * FROM task_labels ORDER BY task_id"),
    ("events", "SELECT * FROM events ORDER BY event_id"),
    ("imports", "SELECT * FROM imports ORDER BY input_sha256"),
];

#[test]
fn schema_four_upgrade_rebuilds_status_check_with_verified_backup() {
    assert_eq!(CURRENT_SCHEMA_VERSION, 5);
    let root = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    v4_fixture(root.path(), &id);
    assert!(Store::open_readonly(root.path(), &id.to_string()).is_err());
    let mut store = Store::open_for_migration(root.path(), &id.to_string()).unwrap();
    let (from, to, backup) = store.migrate().unwrap();
    assert_eq!((from, to), (4, 5));
    let backup = backup.unwrap();
    assert!(backup
        .file_name()
        .unwrap()
        .to_string_lossy()
        .starts_with("TASKS.v4-pre-migrate-"));
    let old =
        Connection::open_with_flags(&backup, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(
        values(&old, "PRAGMA user_version"),
        vec![vec![Value::Integer(4)]]
    );
    assert_eq!(
        values(&old, "PRAGMA quick_check"),
        vec![vec![Value::Text("ok".into())]]
    );
    for (table, sql) in PRESERVED {
        assert_eq!(values(&store.conn, sql), values(&old, sql), "{table}");
    }
    drop(old);
    // Indexes, FTS triggers and constraints survive the rebuild.
    for index in [
        "idx_tasks_status_id",
        "idx_tasks_priority_id",
        "idx_tasks_status_priority_id",
    ] {
        assert_eq!(
            values(
                &store.conn,
                &format!(
                    "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='{index}'"
                )
            ),
            vec![vec![Value::Integer(1)]],
            "{index}"
        );
    }
    store
        .conn
        .execute_batch("INSERT INTO tasks_fts(tasks_fts) VALUES('integrity-check')")
        .unwrap();
    assert!(store
        .conn
        .execute("UPDATE tasks SET status='bogus' WHERE id=7", [])
        .is_err());
    assert!(store
        .conn
        .execute("UPDATE tasks SET priority='P4' WHERE id=7", [])
        .is_err());
    drop(store);

    let mut store = Store::open_rw(root.path(), &id.to_string()).unwrap();
    assert_eq!(
        store
            .search_ranked("cache", false, None, 0, 20)
            .unwrap()
            .items[0]
            .id,
        7
    );
    set_status(&mut store, 7, TaskStatus::ToVerify).unwrap();
    assert_eq!(store.show_task("T-7").unwrap().status, TaskStatus::ToVerify);
    // Title edits after the rebuild still reach the FTS index via the triggers.
    let version = store.show_task("T-9").unwrap().version;
    store
        .update_task(
            9,
            version,
            TaskUpdate {
                title: Some("renamed zebra".into()),
                ..TaskUpdate::default()
            },
        )
        .unwrap();
    assert_eq!(
        store
            .search_ranked("zebra", false, None, 0, 20)
            .unwrap()
            .items[0]
            .id,
        9
    );
    store
        .conn
        .execute_batch("INSERT INTO tasks_fts(tasks_fts) VALUES('integrity-check')")
        .unwrap();
    assert_eq!(store.doctor().unwrap().2, 5);
    drop(store);
    let mut again = Store::open_for_migration(root.path(), &id.to_string()).unwrap();
    assert_eq!(again.migrate().unwrap(), (5, 5, None));
}

#[test]
fn failed_schema_four_upgrade_rolls_back_the_rebuild() {
    let root = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    v4_fixture(root.path(), &id);
    let mut store = Store::open_for_migration(root.path(), &id.to_string()).unwrap();
    // Validation fails after the tasks rebuild, so the transaction must roll back.
    store
        .conn
        .execute_batch("ALTER TABLE events RENAME COLUMN operation TO invalid_operation")
        .unwrap();
    assert!(store.migrate().is_err());
    assert_eq!(
        values(&store.conn, "PRAGMA user_version"),
        vec![vec![Value::Integer(4)]]
    );
    assert_eq!(
        values(&store.conn, "PRAGMA foreign_keys"),
        vec![vec![Value::Integer(1)]]
    );
    assert!(store
        .conn
        .execute("UPDATE tasks SET status='to-verify' WHERE id=7", [])
        .is_err());
    assert_eq!(
        values(&store.conn, "SELECT COUNT(*) FROM dependencies"),
        vec![vec![Value::Integer(1)]]
    );
    assert_eq!(
        values(
            &store.conn,
            "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'tasks_fts_%'"
        ),
        vec![vec![Value::Integer(3)]]
    );
}

#[test]
fn to_verify_prerequisite_satisfies_default_list_and_unlocks() {
    let (_root, _id, mut store) = new_store();
    // T-1 prerequisite, T-2 depends on T-1, T-3 depends on T-1 and T-4.
    store
        .create_task("prereq", "", TaskStatus::Ready, vec![])
        .unwrap();
    store
        .create_task("dependent", "", TaskStatus::Ready, vec![1])
        .unwrap();
    store
        .create_task("other prereq", "", TaskStatus::Ready, vec![])
        .unwrap();
    store
        .create_task("both", "", TaskStatus::Ready, vec![1, 3])
        .unwrap();
    assert_eq!(ids(&mut store, None, false), vec![1, 3]);

    set_status(&mut store, 1, TaskStatus::InProgress).unwrap();
    assert_eq!(ids(&mut store, None, false), vec![1, 3]);

    set_status(&mut store, 1, TaskStatus::ToVerify).unwrap();
    // The to-verify task itself is not runnable work; its dependent is.
    assert_eq!(ids(&mut store, None, false), vec![2, 3]);
    let unlocks = store.unlocks(0, 100).unwrap().items;
    // T-1 is satisfied, so only T-3 still unlocks work: T-4 becomes runnable.
    assert_eq!(
        unlocks
            .iter()
            .map(|u| (u.task.id, u.direct_open_dependents, u.immediately_runnable))
            .collect::<Vec<_>>(),
        vec![(3, 1, 1)]
    );

    // Blocked prerequisites and other statuses still do not satisfy readiness.
    set_status(&mut store, 1, TaskStatus::Blocked).unwrap();
    assert_eq!(ids(&mut store, None, false), vec![3]);
    set_status(&mut store, 1, TaskStatus::Cancelled).unwrap();
    assert_eq!(ids(&mut store, None, false), vec![3]);
}

#[test]
fn status_and_open_listing_include_to_verify_tasks() {
    let (_root, _id, mut store) = new_store();
    store
        .create_task("a", "", TaskStatus::Ready, vec![])
        .unwrap();
    store
        .create_task("b", "", TaskStatus::ToVerify, vec![])
        .unwrap();
    store
        .create_task("c", "", TaskStatus::Done, vec![])
        .unwrap();
    store
        .create_task("d", "", TaskStatus::ToVerify, vec![1])
        .unwrap();
    assert_eq!(ids(&mut store, None, false), vec![1]);
    assert_eq!(ids(&mut store, Some("to-verify"), false), vec![2, 4]);
    assert_eq!(ids(&mut store, None, true), vec![1, 2, 4]);
    let library = store.list_tasks(Some("to-verify"), None, 100).unwrap();
    assert_eq!(
        library.items.iter().map(|t| t.id).collect::<Vec<_>>(),
        vec![2, 4]
    );
}

#[test]
fn done_guard_refuses_nonterminal_prerequisites_without_writing() {
    let (_root, _id, mut store) = new_store();
    store
        .create_task("prereq", "", TaskStatus::ToVerify, vec![])
        .unwrap();
    store
        .create_task("second", "", TaskStatus::Ready, vec![])
        .unwrap();
    store
        .create_task("owner", "", TaskStatus::ToVerify, vec![1, 2])
        .unwrap();
    let events = |store: &Store| values(&store.conn, "SELECT COUNT(*) FROM events")[0][0].clone();
    let before = events(&store);
    let error = set_status(&mut store, 3, TaskStatus::Done).unwrap_err();
    assert!(error.contains("T-001 (to-verify)"), "{error}");
    assert!(error.contains("T-002 (todo)"), "{error}");
    assert_eq!(store.show_task("T-3").unwrap().version, 1);
    assert_eq!(store.show_task("T-3").unwrap().status, TaskStatus::ToVerify);
    assert_eq!(events(&store), before);

    // Only the todo prerequisite remains open: still refused.
    set_status(&mut store, 1, TaskStatus::Done).unwrap();
    let error = set_status(&mut store, 3, TaskStatus::Done).unwrap_err();
    assert!(error.contains("T-002 (todo)"), "{error}");
    assert!(!error.contains("T-001"), "{error}");

    // Done and cancelled prerequisites do not block.
    set_status(&mut store, 2, TaskStatus::Cancelled).unwrap();
    set_status(&mut store, 3, TaskStatus::Done).unwrap();
    assert_eq!(store.show_task("T-3").unwrap().status, TaskStatus::Done);

    // The guard applies to the resulting dependency set of the same update.
    store
        .create_task("open", "", TaskStatus::Ready, vec![])
        .unwrap();
    store
        .create_task("switch", "", TaskStatus::InProgress, vec![4])
        .unwrap();
    let refused = store.update_task(
        5,
        1,
        TaskUpdate {
            status: Some(TaskStatus::Done),
            deps: Some(vec![1, 4]),
            ..TaskUpdate::default()
        },
    );
    assert!(refused.is_err());
    let accepted = store
        .update_task(
            5,
            1,
            TaskUpdate {
                status: Some(TaskStatus::Done),
                deps: Some(vec![1, 3]),
                ..TaskUpdate::default()
            },
        )
        .unwrap();
    assert_eq!(accepted.1, TaskStatus::Done);

    // Other transitions stay allowed with open prerequisites.
    store
        .create_task("free", "", TaskStatus::Backlog, vec![4])
        .unwrap();
    for status in [
        TaskStatus::Ready,
        TaskStatus::InProgress,
        TaskStatus::ToVerify,
        TaskStatus::Blocked,
        TaskStatus::Cancelled,
    ] {
        set_status(&mut store, 6, status).unwrap();
    }
}

#[test]
fn markdown_export_and_import_round_trip_to_verify() {
    let (root, _id, mut store) = new_store();
    store
        .create_task("verified later", "body Ω\n", TaskStatus::ToVerify, vec![])
        .unwrap();
    store
        .create_task("next", "", TaskStatus::Ready, vec![1])
        .unwrap();
    let export = root.path().join("export.md");
    store.export_markdown(&export).unwrap();
    let bytes = fs::read(&export).unwrap();
    let text = String::from_utf8(bytes.clone()).unwrap();
    assert!(text.contains("## to-verify\n"), "{text}");
    assert!(text.contains("Status: to-verify\n"), "{text}");

    let parsed = markdown::parse("export.md", bytes, None).unwrap();
    let first = parsed.tasks.iter().find(|t| t.id == 1).unwrap();
    assert_eq!(first.status, TaskStatus::ToVerify);
    let hash = parsed.source_hash.clone();
    let (_second_root, _second_id, mut second) = new_store();
    second.import_apply(parsed, Some(&hash)).unwrap();
    let task = second.show_task("T-1").unwrap();
    assert_eq!(task.status, TaskStatus::ToVerify);
    assert_eq!(task.body, "body Ω\n");
    assert_eq!(second.show_task("T-2").unwrap().deps, vec![1]);

    // Section maps accept the new status value.
    let map = root.path().join("map.json");
    fs::write(&map, r#"{"sections":{"Waiting for gate":"to-verify"}}"#).unwrap();
    let source = b"# Backlog\n\n## Waiting for gate\n### T-001 Alpha\nBody:\ntext\n".to_vec();
    let parsed = markdown::parse("mapped.md", source, Some(&map)).unwrap();
    assert_eq!(parsed.tasks[0].status, TaskStatus::ToVerify);
}

struct Cli {
    root: TempDir,
    id: Uuid,
}

impl Cli {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        create_project_db(root.path(), &id).unwrap();
        fs::write(root.path().join("body.md"), "body").unwrap();
        Self { root, id }
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_tasks"))
            .args([
                "--data-root",
                self.root.path().to_str().unwrap(),
                "--project",
                &self.id.to_string(),
                "--format",
                "json",
            ])
            .args(args)
            .output()
            .unwrap()
    }

    fn ok(&self, args: &[&str]) -> Json {
        let output = self.run(args);
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice::<Json>(&output.stdout).unwrap()["data"].clone()
    }

    fn create(&self, title: &str, deps: &str) -> u64 {
        let body = self.root.path().join("body.md");
        let mut args = vec![
            "create",
            "--title",
            title,
            "--body-file",
            body.to_str().unwrap(),
            "--status",
            "todo",
        ];
        if !deps.is_empty() {
            args.extend(["--deps", deps]);
        }
        self.ok(&args)["id"].as_u64().unwrap()
    }

    fn status(&self, id: u64, version: u64, status: &str) -> Output {
        self.run(&[
            "update",
            &format!("T-{id}"),
            "--expect-version",
            &version.to_string(),
            "--status",
            status,
        ])
    }

    fn move_to(&self, id: u64, version: u64, status: &str) -> u64 {
        let output = self.status(id, version, status);
        assert!(
            output.status.success(),
            "T-{id} -> {status}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let data = serde_json::from_slice::<Json>(&output.stdout).unwrap()["data"].clone();
        assert_eq!(data["status"], status);
        data["version"].as_u64().unwrap()
    }

    fn list(&self, extra: &[&str]) -> Vec<u64> {
        let mut args = vec!["list"];
        args.extend_from_slice(extra);
        self.ok(&args)["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["id"].as_u64().unwrap())
            .collect()
    }
}

#[test]
fn cli_takes_a_dependent_chain_through_to_verify_and_guards_done() {
    let cli = Cli::new();
    let a = cli.create("first", "");
    let b = cli.create("second", "T-1");
    let c = cli.create("third", "T-2");
    assert_eq!(cli.list(&[]), vec![a]);

    let va = cli.move_to(a, 1, "in-progress");
    let va = cli.move_to(a, va, "to-verify");
    // The dependent is runnable while its prerequisite awaits the batch gate.
    assert_eq!(cli.list(&[]), vec![b]);
    let vb = cli.move_to(b, 1, "in-progress");
    let vb = cli.move_to(b, vb, "to-verify");
    assert_eq!(cli.list(&[]), vec![c]);
    let vc = cli.move_to(c, 1, "in-progress");
    let vc = cli.move_to(c, vc, "to-verify");
    assert_eq!(cli.list(&[]), Vec::<u64>::new());
    assert_eq!(cli.list(&["--status", "to-verify"]), vec![a, b, c]);
    assert_eq!(cli.list(&["--open"]), vec![a, b, c]);

    // Guard: completing out of dependency order fails with exit 2, no write.
    let refused = cli.status(c, vc, "done");
    assert_eq!(refused.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&refused.stderr);
    assert!(stderr.contains("T-002 (to-verify)"), "{stderr}");
    let error = serde_json::from_slice::<Json>(&refused.stderr).unwrap()["error"].clone();
    assert_eq!(error["code"], "validation");
    assert_eq!(
        error["open_prerequisites"],
        serde_json::json!({"task": 3, "prerequisites": [{"id": 2, "status": "to-verify"}]})
    );
    assert!(refused.stdout.is_empty());
    let shown = cli.ok(&["show", "T-3"]);
    assert_eq!(shown["version"].as_u64(), Some(vc));
    assert_eq!(shown["status"], "to-verify");

    // Pass: done in dependency order.
    cli.move_to(a, va, "done");
    cli.move_to(b, vb, "done");
    cli.move_to(c, vc, "done");
    assert_eq!(cli.list(&["--open"]), Vec::<u64>::new());
}
