use rusqlite::params;
use tasks_cli::markdown;
use tasks_cli::model::{SourceSchema, TaskStatus, TaskUpdate};
use tasks_cli::store::{create_project_db, Store};
use tempfile::TempDir;
use uuid::Uuid;

const LIMIT: usize = 1000;

fn store() -> (TempDir, Store) {
    let root = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).expect("database");
    let store = Store::open_rw(root.path(), &project.to_string()).expect("open");
    (root, store)
}

/// Insert `count` dependency targets directly so create/update tests do not pay
/// one transaction per fixture row.
fn store_with_tasks(count: u64) -> (TempDir, Store) {
    let (root, store) = store();
    let tx = store.conn.unchecked_transaction().expect("transaction");
    for id in 1..=count {
        tx.execute(
            "INSERT INTO tasks(id,title,body,status,version,created_ms,updated_ms)
             VALUES (?1, ?2, '', 'ready', 1, 0, 0)",
            params![id as i64, format!("fixture {id}")],
        )
        .expect("fixture task");
    }
    tx.execute(
        "UPDATE project SET next_task_number = ?1",
        params![count as i64 + 1],
    )
    .expect("next task number");
    tx.commit().expect("commit fixture");
    (root, store)
}

fn ids(count: u64) -> Vec<u64> {
    (1..=count).collect()
}

fn ids_from(start: u64, count: u64) -> Vec<u64> {
    (start..start + count).collect()
}

fn assert_names(message: &str, needles: &[&str]) {
    for needle in needles {
        assert!(
            message.contains(needle),
            "message {message:?} must contain {needle:?}"
        );
    }
}

#[test]
fn create_accepts_1000_dependencies_and_rejects_1001() {
    let (_root, mut store) = store_with_tasks(1002);
    store
        .create_task("large", "", TaskStatus::Backlog, ids(1000))
        .expect("1000 dependencies are accepted");
    let error = store
        .create_task("over-limit", "", TaskStatus::Backlog, ids(1001))
        .expect_err("1001 dependencies are rejected");
    let message = error.to_string();
    assert_names(&message, &["over-limit", "1001", &LIMIT.to_string()]);
}

#[test]
fn update_accepts_1000_dependencies_and_rejects_1001() {
    let (_root, mut store) = store_with_tasks(1002);
    store
        .update_task(
            1,
            1,
            TaskUpdate {
                deps: Some(ids_from(2, 1000)),
                ..TaskUpdate::default()
            },
        )
        .expect("1000 dependencies are accepted");
    let error = store
        .update_task(
            1,
            2,
            TaskUpdate {
                deps: Some(ids_from(2, 1001)),
                ..TaskUpdate::default()
            },
        )
        .expect_err("1001 dependencies are rejected");
    let message = error.to_string();
    assert_names(&message, &["T-001", "1001", &LIMIT.to_string()]);
}

fn ledger_with_dependency_count(count: usize) -> String {
    let mut text = String::from("## in-progress\n");
    for id in 1..=count + 1 {
        text.push_str(&format!("### T-{id} Task {id}\n"));
        if id == 1 {
            let deps = (2..=count + 1)
                .map(|dep| format!("T-{dep}"))
                .collect::<Vec<_>>()
                .join(", ");
            text.push_str(&format!("Deps: {deps}\n"));
        }
    }
    text
}

#[test]
fn import_accepts_1000_dependencies_and_preview_rejects_1001() {
    let parsed = markdown::parse_with_schema(
        "large.md".to_string(),
        ledger_with_dependency_count(LIMIT).into_bytes(),
        None,
        SourceSchema::CreateTask,
    )
    .expect("parse at the limit");
    let mut at_limit = vec![parsed];
    markdown::resolve_create_task_deps_across(&mut at_limit);
    let refs = at_limit.iter().collect::<Vec<_>>();
    let at_limit_problems = tasks_cli::problems::analyze(&refs);
    assert!(
        at_limit_problems.is_empty(),
        "1000 dependencies must not be a problem: {at_limit_problems:#?}"
    );
    let (_limit_root, mut limit_store) = store();
    let hash = at_limit[0].source_hash.clone();
    limit_store
        .import_apply(at_limit.remove(0), Some(&hash))
        .expect("import at the limit");

    let over = markdown::parse_with_schema(
        "over.md".to_string(),
        ledger_with_dependency_count(LIMIT + 1).into_bytes(),
        None,
        SourceSchema::CreateTask,
    )
    .expect("parse over the limit");
    let mut over_set = vec![over];
    markdown::resolve_create_task_deps_across(&mut over_set);
    let refs = over_set.iter().collect::<Vec<_>>();
    let problems = tasks_cli::problems::analyze(&refs);
    let problem = problems
        .iter()
        .find(|problem| problem.message.contains("1001 dependencies"))
        .expect("the dependency-count problem is reported by the preview");
    assert_names(
        &problem.message,
        &["T-001", "over.md", "1001", &LIMIT.to_string()],
    );
    assert_eq!(problem.task_id, Some(1));
    assert!(problem.line.is_some());

    let (_over_root, mut over_store) = store();
    let hash = over_set[0].source_hash.clone();
    let error = over_store
        .import_apply(over_set.remove(0), Some(&hash))
        .expect_err("1001 dependencies are rejected by apply");
    let message = error.to_string();
    assert_names(&message, &["T-001", "over.md", "1001", &LIMIT.to_string()]);
}
