use rusqlite::{params, Connection};
use tasks_cli::{
    error,
    full_text::{create_index, search},
};

struct Fixture {
    conn: Connection,
    _root: tempfile::TempDir,
}

impl Fixture {
    fn new(index: bool) -> Self {
        let root = tempfile::Builder::new()
            .prefix("tasks-fts-engine-")
            .tempdir()
            .unwrap();
        let conn = Connection::open(root.path().join("tasks.sqlite")).unwrap();
        conn.execute_batch("CREATE TABLE tasks(id INTEGER PRIMARY KEY,title TEXT NOT NULL,body TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'open',version INTEGER NOT NULL DEFAULT 1,priority TEXT NOT NULL DEFAULT 'P2'); CREATE TABLE task_labels(task_id INTEGER NOT NULL,label TEXT NOT NULL,PRIMARY KEY(task_id,label));").unwrap();
        if index {
            create_index(&conn).unwrap();
        }
        Self { conn, _root: root }
    }

    fn add(&self, id: u64, title: &str, body: &str) {
        self.conn
            .execute(
                "INSERT INTO tasks(id,title,body) VALUES(?1,?2,?3)",
                params![id, title, body],
            )
            .unwrap();
    }

    fn ids(&self, text: &str, prefix: bool) -> Vec<u64> {
        search(&self.conn, text, prefix, None, 0, 101)
            .unwrap()
            .into_iter()
            .map(|row| row.id)
            .collect()
    }
}

#[test]
fn title_matches_rank_before_body_matches_and_return_metadata() {
    let f = Fixture::new(true);
    f.add(1, "unrelated", "sqlite");
    f.add(2, "sqlite", "unrelated");
    let rows = search(&f.conn, "sqlite", false, None, 0, 10).unwrap();
    assert_eq!(rows.iter().map(|r| r.id).collect::<Vec<_>>(), vec![2, 1]);
    assert_eq!(
        (&rows[0].status, rows[0].version, &rows[0].title),
        (&"open".to_string(), 1, &"sqlite".to_string())
    );
}

#[test]
fn terms_use_and_and_prefix_is_explicit() {
    let f = Fixture::new(true);
    f.add(1, "database migration", "");
    f.add(2, "database unrelated", "");
    assert_eq!(f.ids("database migration", false), vec![1]);
    assert!(f.ids("data migr", false).is_empty());
    assert_eq!(f.ids("data migr", true), vec![1]);
    assert!(f.ids("absent", false).is_empty());
}

#[test]
fn user_quotes_and_operators_are_literal_terms() {
    let f = Fixture::new(true);
    f.add(1, "alpha OR beta", "");
    f.add(2, "alpha beta", "");
    assert_eq!(f.ids("alpha OR beta", false), vec![1]);
    assert_eq!(f.ids("\"alpha\" OR beta*", false), vec![1]);
    for text in [
        "\"",
        "*",
        "()",
        "title:alpha",
        "alpha'--",
        "NEAR(alpha,beta)",
    ] {
        search(&f.conn, text, false, None, 0, 10).unwrap();
    }
    assert_eq!(
        f.conn
            .query_row("SELECT count(*) FROM tasks", [], |r| r.get::<_, u64>(0))
            .unwrap(),
        2
    );
}

#[test]
fn equal_rank_pages_are_stable_and_labels_are_exact() {
    let f = Fixture::new(true);
    for id in [7, 2, 9, 4] {
        f.add(id, "identical", "");
    }
    f.conn
        .execute(
            "INSERT INTO task_labels VALUES(2,'fix'),(7,'fix'),(4,'fix-more')",
            [],
        )
        .unwrap();
    let ids = |label, offset, limit| {
        search(&f.conn, "identical", false, label, offset, limit)
            .unwrap()
            .into_iter()
            .map(|r| r.id)
            .collect::<Vec<_>>()
    };
    assert_eq!(ids(None, 0, 2), vec![2, 4]);
    assert_eq!(ids(None, 2, 2), vec![7, 9]);
    assert_eq!(ids(Some("fix"), 0, 10), vec![2, 7]);
    assert!(ids(Some("fix' OR 1=1 --"), 0, 10).is_empty());
}

#[test]
fn triggers_follow_updates_deletes_and_rollback() {
    let f = Fixture::new(true);
    f.add(1, "original", "bodyfirst");
    assert_eq!(f.ids("original", false), vec![1]);
    f.conn
        .execute(
            "UPDATE tasks SET title='changed',body='bodysecond',version=2 WHERE id=1",
            [],
        )
        .unwrap();
    assert!(f.ids("original", false).is_empty());
    assert!(f.ids("bodyfirst", false).is_empty());
    assert_eq!(f.ids("bodysecond", false), vec![1]);
    f.conn.execute_batch("BEGIN; UPDATE tasks SET title='rolledback' WHERE id=1; INSERT INTO tasks(id,title,body) VALUES(2,'insertrollback',''); DELETE FROM tasks WHERE id=1; ROLLBACK;").unwrap();
    assert_eq!(f.ids("changed", false), vec![1]);
    assert!(f.ids("rolledback", false).is_empty());
    assert!(f.ids("insertrollback", false).is_empty());
    f.conn.execute("DELETE FROM tasks WHERE id=1", []).unwrap();
    assert!(f.ids("changed", false).is_empty());
}

#[test]
fn rebuild_indexes_existing_tasks_and_ddl_can_roll_back() {
    let f = Fixture::new(false);
    f.add(1, "preexisting", "");
    f.conn.execute_batch("BEGIN").unwrap();
    create_index(&f.conn).unwrap();
    assert_eq!(f.ids("preexisting", false), vec![1]);
    f.conn.execute_batch("ROLLBACK").unwrap();
    assert_eq!(
        f.conn
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE name='tasks_fts'",
                [],
                |r| r.get::<_, u64>(0)
            )
            .unwrap(),
        0
    );
    f.conn.execute_batch("BEGIN").unwrap();
    create_index(&f.conn).unwrap();
    f.conn.execute_batch("COMMIT").unwrap();
    assert_eq!(f.ids("preexisting", false), vec![1]);
}

#[test]
fn invalid_query_bounds_fail_as_validation() {
    let f = Fixture::new(true);
    for query in [
        String::new(),
        " \t\n".to_string(),
        "a".repeat(4097),
        "a ".repeat(65),
        "é".repeat(2049),
    ] {
        assert!(matches!(
            search(&f.conn, &query, false, None, 0, 10),
            Err(error::AppError::Validation(_))
        ));
    }
    assert!(matches!(
        search(&f.conn, "valid", false, None, u64::MAX, 10),
        Err(error::AppError::Validation(_))
    ));
    assert!(search(&f.conn, &"a".repeat(4096), false, None, 0, 10).is_ok());
    assert!(search(&f.conn, &"a ".repeat(64), false, None, 0, 10).is_ok());
}
