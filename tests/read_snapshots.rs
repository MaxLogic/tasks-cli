use std::cell::RefCell;
use tasks_cli::model::TaskStatus;
use tasks_cli::store::{create_project_db, Store};
use uuid::Uuid;

// SQLite tracing pauses the reader immediately before its second SELECT.
// The other connection commits in WAL mode, deterministically exercising the
// interleaving without sleeps or a production fault-injection interface.
type Interleave = (&'static str, Box<dyn FnOnce()>);
thread_local! {
    static INTERLEAVE: RefCell<Option<Interleave>> = RefCell::new(None);
}

fn trace(event: rusqlite::trace::TraceEvent<'_>) {
    let rusqlite::trace::TraceEvent::Stmt(_, sql) = event else {
        return;
    };
    let action = INTERLEAVE.with(|slot| {
        let mut slot = slot.borrow_mut();
        if slot
            .as_ref()
            .is_some_and(|(needle, _)| sql.contains(needle))
        {
            slot.take()
        } else {
            None
        }
    });
    if let Some((_, action)) = action {
        action();
    }
}

fn interleave(store: &mut Store, needle: &'static str, action: impl FnOnce() + 'static) {
    INTERLEAVE.with(|slot| *slot.borrow_mut() = Some((needle, Box::new(action))));
    store.conn.trace_v2(
        rusqlite::trace::TraceEventCodes::SQLITE_TRACE_STMT,
        Some(trace),
    );
}

fn fixture() -> (tempfile::TempDir, Store, rusqlite::Connection) {
    let temp = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    create_project_db(temp.path(), &id).unwrap();
    let mut store = Store::open_rw(temp.path(), &id.to_string()).unwrap();
    store
        .create_task("dependency", "body", TaskStatus::Ready, vec![])
        .unwrap();
    store
        .create_task("owner", "body", TaskStatus::Ready, vec![])
        .unwrap();
    let writer = rusqlite::Connection::open(&store.db_path).unwrap();
    let reader = Store::open_readonly(temp.path(), &id.to_string()).unwrap();
    (temp, reader, writer)
}

#[test]
fn list_and_search_keep_task_version_and_dependencies_in_one_snapshot() {
    for search in [false, true] {
        let (_temp, mut reader, writer) = fixture();
        interleave(&mut reader, "SELECT task_id, depends_on_id", move || {
            writer.execute_batch("BEGIN; UPDATE tasks SET version=2 WHERE id=2; INSERT INTO dependencies VALUES(2,1); COMMIT;").unwrap();
        });
        let page = if search {
            reader.search_tasks("owner", None, 20).unwrap()
        } else {
            reader.list_tasks(None, None, 20).unwrap()
        };
        let owner = page.items.iter().find(|task| task.id == 2).unwrap();
        assert_eq!(owner.version, 1);
        assert!(
            owner.deps.is_empty(),
            "old task version mixed with new dependencies"
        );
        assert_eq!(reader.show_task("T-2").unwrap().deps, vec![1]);
    }
}

#[test]
fn show_keeps_task_and_rules_in_one_snapshot() {
    let (_temp, mut reader, writer) = fixture();
    interleave(&mut reader, "SELECT rules_version", move || {
        writer.execute_batch("BEGIN; UPDATE tasks SET version=2 WHERE id=2; UPDATE project SET rules_version=2,rules_markdown='new rules'; COMMIT;").unwrap();
    });
    let task = reader.show_task("T-2").unwrap();
    assert_eq!(task.version, 1);
    assert_eq!(task.rule_version, 1, "old task mixed with new rules");
    assert_eq!(reader.show_task("T-2").unwrap().rule_version, 2);
}

#[test]
fn export_keeps_rules_and_tasks_in_one_snapshot() {
    let (temp, mut reader, writer) = fixture();
    interleave(
        &mut reader,
        "SELECT id,title,body,version,priority",
        move || {
            writer.execute_batch("BEGIN; UPDATE tasks SET title='changed owner' WHERE id=2; UPDATE project SET rules_version=2,rules_markdown='new rules'; COMMIT;").unwrap();
        },
    );
    let out = temp.path().join("export.md");
    reader.export_markdown(&out).unwrap();
    assert!(
        INTERLEAVE.with(|slot| slot.borrow().is_none()),
        "export interleave was not reached"
    );
    let text = std::fs::read_to_string(out).unwrap();
    assert!(
        text.contains("T-002 owner"),
        "old rules mixed with new task title"
    );
    assert!(!text.contains("new rules"));
    assert_eq!(reader.show_task("T-2").unwrap().title, "changed owner");
}

#[test]
fn export_does_not_overwrite_a_file_created_during_its_read() {
    let (temp, mut reader, _writer) = fixture();
    let out = temp.path().join("export.md");
    let competitor = out.clone();
    interleave(
        &mut reader,
        "SELECT id,title,body,version,priority",
        move || {
            std::fs::write(competitor, "other process owns this file").unwrap();
        },
    );
    assert!(reader.export_markdown(&out).is_err());
    assert_eq!(
        std::fs::read_to_string(out).unwrap(),
        "other process owns this file"
    );
}
