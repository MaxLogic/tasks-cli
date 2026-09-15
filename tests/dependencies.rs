use tasks_cli::model::{TaskStatus, TaskUpdate};
use tasks_cli::store::{create_project_db, Store};
use tempfile::TempDir;
use uuid::Uuid;

fn store() -> (TempDir, Store) {
    let root = tempfile::tempdir().expect("temporary directory");
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).expect("database");
    let store = Store::open_rw(root.path(), &project.to_string()).expect("open");
    (root, store)
}

#[test]
fn dependency_replacement_is_order_insensitive_and_noop_has_no_event() {
    let (_root, mut store) = store();
    store
        .create_task("one", "", TaskStatus::Ready, Vec::new())
        .expect("one");
    store
        .create_task("two", "", TaskStatus::Ready, Vec::new())
        .expect("two");
    let (_, version, event) = store
        .create_task("owner", "", TaskStatus::Backlog, vec![2, 1])
        .expect("owner");
    assert_eq!(version, 1);
    assert!(event.is_some_and(|value| value > 0));

    let before = store.history(3, None, 20, None).expect("history").0;
    let result = store
        .update_task(
            3,
            1,
            TaskUpdate {
                deps: Some(vec![1, 2]),
                ..TaskUpdate::default()
            },
        )
        .expect("semantic noop");
    assert_eq!(result.2, 1);
    assert!(result.3.is_none());
    let after = store.history(3, None, 20, None).expect("history").0;
    assert_eq!(before.items.len(), after.items.len());
}

#[test]
fn clear_deps_is_mutually_exclusive_and_has_no_zero_event() {
    let (_root, mut store) = store();
    store
        .create_task("dependency", "", TaskStatus::Ready, Vec::new())
        .expect("dependency");
    store
        .create_task("owner", "", TaskStatus::Backlog, vec![1])
        .expect("owner");
    assert!(store
        .update_task(
            2,
            1,
            TaskUpdate {
                deps: Some(vec![1]),
                clear_deps: true,
                ..TaskUpdate::default()
            },
        )
        .is_err());

    let changed = store
        .update_task(
            2,
            1,
            TaskUpdate {
                clear_deps: true,
                ..TaskUpdate::default()
            },
        )
        .expect("clear deps");
    assert_eq!(changed.2, 2);
    assert!(changed.3.is_some_and(|value| value > 0));
    let unchanged = store
        .update_task(
            2,
            2,
            TaskUpdate {
                clear_deps: true,
                ..TaskUpdate::default()
            },
        )
        .expect("repeated clear");
    assert_eq!(unchanged.2, 2);
    assert!(unchanged.3.is_none());
}
