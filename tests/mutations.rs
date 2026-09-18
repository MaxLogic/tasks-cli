use std::fs;
use std::process::Command;
use tasks_cli::model::{TaskStatus, TaskUpdate};
use tasks_cli::store::{create_project_db, Store};
use tempfile::TempDir;
use uuid::Uuid;

fn setup() -> (TempDir, Uuid, std::path::PathBuf) {
    let temp = tempfile::tempdir().expect("temporary directory");
    let id = Uuid::new_v4();
    create_project_db(temp.path(), &id).expect("database");
    let work = temp.path().join("work");
    fs::create_dir_all(&work).expect("work");
    (temp, id, work)
}

fn cli(temp: &TempDir, id: &Uuid, work: &std::path::Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_tasks"));
    command
        .arg("--data-root")
        .arg(temp.path())
        .arg("--project")
        .arg(id.to_string())
        .current_dir(work);
    command
}

#[test]
fn same_version_subprocess_updates_have_exactly_one_winner() {
    let (temp, id, work) = setup();
    let mut store = Store::open_rw(temp.path(), &id.to_string()).expect("open");
    store
        .create_task("initial", "body", TaskStatus::Backlog, Vec::new())
        .expect("create");
    let mut first = cli(&temp, &id, &work);
    first.args([
        "update",
        "T-001",
        "--expect-version",
        "1",
        "--title",
        "winner-a",
    ]);
    let mut second = cli(&temp, &id, &work);
    second.args([
        "update",
        "T-001",
        "--expect-version",
        "1",
        "--title",
        "winner-b",
    ]);
    let child_a = first.spawn().expect("first update");
    let child_b = second.spawn().expect("second update");
    let result_a = child_a.wait_with_output().expect("first result");
    let result_b = child_b.wait_with_output().expect("second result");
    let mut codes = vec![
        result_a.status.code().unwrap_or(6),
        result_b.status.code().unwrap_or(6),
    ];
    codes.sort_unstable();
    assert_eq!(codes, vec![0, 4]);
    let mut check = Store::open_rw(temp.path(), &id.to_string()).expect("reopen");
    let detail = check.show_task("T-001").expect("show");
    assert_eq!(detail.version, 2);
    assert!(detail.title == "winner-a" || detail.title == "winner-b");
    let events: i64 = check
        .conn
        .query_row("SELECT COUNT(*) FROM events WHERE task_id = 1", [], |r| {
            r.get(0)
        })
        .expect("events");
    assert_eq!(events, 2);
}

#[test]
fn concurrent_subprocess_creates_receive_unique_ids() {
    let (temp, id, work) = setup();
    let body = temp.path().join("body.md");
    fs::write(&body, "body").expect("body");
    let mut children = Vec::new();
    for index in 0..8 {
        let mut command = cli(&temp, &id, &work);
        command.args([
            "create",
            "--title",
            &format!("task-{index}"),
            "--body-file",
            body.to_str().unwrap(),
        ]);
        children.push(command.spawn().expect("create child"));
    }
    for child in children {
        assert_eq!(
            child
                .wait_with_output()
                .expect("create result")
                .status
                .code(),
            Some(0)
        );
    }
    let mut store = Store::open_rw(temp.path(), &id.to_string()).expect("open");
    let page = store.list_tasks(Some("draft"), None, 100).expect("list");
    let ids = page
        .items
        .iter()
        .map(|item| item.id)
        .collect::<std::collections::HashSet<_>>();
    assert_eq!(ids.len(), 8);
    assert_eq!(ids.iter().min(), Some(&1));
    assert_eq!(ids.iter().max(), Some(&8));
}

#[test]
fn failed_write_leaves_task_and_history_unchanged() {
    let (temp, id, work) = setup();
    let mut store = Store::open_rw(temp.path(), &id.to_string()).expect("open");
    store
        .create_task("initial", "body", TaskStatus::Backlog, Vec::new())
        .expect("create");
    store
        .conn
        .execute(
            "CREATE TRIGGER fail_event_insert BEFORE INSERT ON events
             BEGIN SELECT RAISE(ABORT, 'test event failure'); END",
            [],
        )
        .expect("failure trigger");
    let mut command = cli(&temp, &id, &work);
    command.args([
        "update",
        "T-001",
        "--expect-version",
        "1",
        "--title",
        "must-not-commit",
    ]);
    assert_eq!(
        command.output().expect("failed update").status.code(),
        Some(6)
    );
    let detail = store.show_task("T-001").expect("show");
    assert_eq!(detail.title, "initial");
    assert_eq!(detail.version, 1);
    let events: i64 = store
        .conn
        .query_row("SELECT COUNT(*) FROM events", [], |r| r.get(0))
        .expect("events");
    assert_eq!(events, 1);
}

#[test]
fn dependency_cycles_fail_without_changing_edges() {
    let (temp, id, _work) = setup();
    let mut store = Store::open_rw(temp.path(), &id.to_string()).expect("open");
    store
        .create_task("one", "", TaskStatus::Backlog, Vec::new())
        .expect("one");
    store
        .create_task("two", "", TaskStatus::Backlog, vec![1])
        .expect("two");
    let error = store
        .update_task(
            1,
            1,
            TaskUpdate {
                deps: Some(vec![2]),
                ..TaskUpdate::default()
            },
        )
        .expect_err("cycle");
    assert!(error.to_string().contains("cycle"));
    assert_eq!(
        store.show_task("T-001").expect("show").deps,
        Vec::<u64>::new()
    );
}
