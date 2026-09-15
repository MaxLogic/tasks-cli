use tasks_cli::model::TaskStatus;
use tasks_cli::store::{create_project_db, Store};
use tempfile::TempDir;
use uuid::Uuid;

fn store() -> (TempDir, Store) {
    let temp = tempfile::tempdir().expect("temporary directory");
    let id = Uuid::new_v4();
    create_project_db(temp.path(), &id).expect("database");
    let store = Store::open_rw(temp.path(), &id.to_string()).expect("open");
    (temp, store)
}

#[test]
fn list_is_bounded_excludes_terminal_tasks_and_search_excludes_bodies() {
    let (_temp, mut store) = store();
    store
        .create_task("one", "needle body", TaskStatus::Backlog, Vec::new())
        .expect("one");
    store
        .create_task("two", "second body", TaskStatus::Backlog, Vec::new())
        .expect("two");
    store
        .create_task("done", "terminal", TaskStatus::Done, Vec::new())
        .expect("done");

    let page = store.list_tasks(None, None, 1).expect("page");
    assert_eq!(page.items.len(), 1);
    assert!(page.has_more);
    assert_eq!(page.next_after, Some(1));
    assert_eq!(page.items[0].title, "one");

    let search = store.search_tasks("needle", None, 20).expect("search");
    assert_eq!(search.items.len(), 1);
    assert_eq!(search.items[0].title, "one");
    assert!(store.list_tasks(None, None, 0).is_err());
    assert!(store.list_tasks(None, None, 101).is_err());
}

#[test]
fn show_preserves_complete_crlf_text_and_rules() {
    let (_temp, mut store) = store();
    let body = "first\r\nsecond Ω\r\nthird";
    store
        .rules_set("keep this rule\r\nsecond rule", 1)
        .expect("rules");
    store
        .create_task("full text", body, TaskStatus::Backlog, Vec::new())
        .expect("task");
    let detail = store.show_task("T-1").expect("show");
    assert_eq!(detail.body, body);
    assert_eq!(detail.rules, "keep this rule\r\nsecond rule");
}

#[test]
fn search_treats_like_metacharacters_as_literal_ascii_text() {
    let (_temp, mut store) = store();
    store
        .create_task("100% complete", "mixed", TaskStatus::Backlog, Vec::new())
        .expect("percent");
    store
        .create_task("under_score", "mixed", TaskStatus::Backlog, Vec::new())
        .expect("underscore");
    store
        .create_task(r"back\slash", "mixed", TaskStatus::Backlog, Vec::new())
        .expect("backslash");
    store
        .create_task("MiXeD Case", "mixed", TaskStatus::Backlog, Vec::new())
        .expect("case");

    assert_eq!(store.search_tasks("%", None, 20).unwrap().items[0].id, 1);
    assert_eq!(store.search_tasks("_", None, 20).unwrap().items[0].id, 2);
    assert_eq!(store.search_tasks(r"\", None, 20).unwrap().items[0].id, 3);
    assert_eq!(
        store.search_tasks("mixed case", None, 20).unwrap().items[0].id,
        4
    );
}

#[test]
fn readonly_open_does_not_create_or_migrate() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let id = Uuid::new_v4();
    assert!(Store::open_readonly(temp.path(), &id.to_string()).is_err());
    assert!(!temp.path().join("projects").exists());

    let (owned, current) = store();
    let project_id = current.project_id;
    current
        .conn
        .pragma_update(None, "user_version", 0i64)
        .expect("lower schema");
    drop(current);
    assert!(Store::open_readonly(owned.path(), &project_id.to_string()).is_err());
}

#[cfg(unix)]
#[test]
fn readonly_open_works_without_database_write_permission() {
    use std::{fs, os::unix::fs::PermissionsExt};

    let (_temp, store) = store();
    let mut permissions = fs::metadata(&store.db_path)
        .expect("metadata")
        .permissions();
    permissions.set_mode(0o444);
    fs::set_permissions(&store.db_path, permissions).expect("readonly");
    let reopened = Store::open_readonly(
        store
            .db_path
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .parent()
            .unwrap(),
        &store.project_id.to_string(),
    )
    .expect("readonly open");
    assert_eq!(reopened.project_id, store.project_id);
}

#[test]
fn show_includes_direct_dependency_summaries() {
    let (_temp, mut store) = store();
    store
        .create_task("dependency", "body", TaskStatus::Ready, Vec::new())
        .expect("dependency");
    store
        .create_task("owner", "body", TaskStatus::Backlog, vec![1])
        .expect("owner");
    let detail = store.show_task("T-002").expect("show");
    assert_eq!(detail.deps, vec![1]);
    assert_eq!(detail.dependency_summaries[0].title, "dependency");
    assert_eq!(detail.dependency_summaries[0].status, TaskStatus::Ready);
}
