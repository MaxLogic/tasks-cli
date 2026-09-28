//! Read-only commands must not leave empty `-wal`/`-shm` files next to a
//! project database that has no pending WAL: later opens pay for them
//! (issues/active/project-key-task-ids, follow-up i). A database with a
//! pending WAL must keep its bytes and its WAL untouched by the same commands.
//! Every test uses its own temporary data root and real subprocesses.

use rusqlite::config::DbConfig;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use tasks_cli::store::data_root_project_path;

struct Env {
    temp: tempfile::TempDir,
}

impl Env {
    fn new() -> Self {
        Self {
            temp: tempfile::tempdir().expect("temp"),
        }
    }

    fn data(&self) -> PathBuf {
        self.temp.path().join("data")
    }

    fn root(&self, name: &str) -> PathBuf {
        let root = self.temp.path().join(name);
        fs::create_dir_all(&root).expect("root");
        root
    }

    fn run(&self, args: &[&str], stdin: &str) -> Output {
        use std::io::Write;
        let mut child = Command::new(env!("CARGO_BIN_EXE_tasks"))
            .arg("--data-root")
            .arg(self.data())
            .args(args)
            .env_remove("TASKS_WINDOWS_EXE")
            .env_remove("TASKS_PROJECT")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("tasks");
        child
            .stdin
            .take()
            .expect("stdin")
            .write_all(stdin.as_bytes())
            .expect("write stdin");
        let output = child.wait_with_output().expect("tasks output");
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        output
    }

    fn init(&self, name: &str, key: &str) -> String {
        let root = self.root(name);
        let output = self.run(
            &[
                "--format",
                "json",
                "init",
                "--root",
                root.to_str().expect("UTF-8"),
                "--key",
                key,
            ],
            "",
        );
        serde_json::from_slice::<Value>(&output.stdout).expect("JSON")["data"]["project_id"]
            .as_str()
            .expect("project id")
            .to_string()
    }

    fn db(&self, project: &str) -> PathBuf {
        data_root_project_path(&self.data(), project)
    }

    fn write_request(&self, document: &str) -> PathBuf {
        let path = self.temp.path().join("projects-request.json");
        fs::write(&path, document).expect("request");
        path
    }
}

fn sidecar(db: &Path, suffix: &str) -> PathBuf {
    let mut name = db.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

fn sidecars(db: &Path) -> Vec<String> {
    ["-wal", "-shm", "-journal"]
        .into_iter()
        .filter(|suffix| sidecar(db, suffix).exists())
        .map(str::to_string)
        .collect()
}

/// Every read-only command a user or the viewer runs, on a store whose WAL
/// was checkpointed and removed by the last writer.
#[test]
fn read_only_commands_leave_no_sidecars_without_a_pending_wal() {
    let env = Env::new();
    let one = env.init("one", "ONE");
    let two = env.init("two", "TWO");
    env.run(
        &[
            "--project",
            &one,
            "create",
            "--title",
            "first",
            "--body-file",
            "-",
        ],
        "body\n",
    );
    let (db_one, db_two) = (env.db(&one), env.db(&two));
    assert_eq!(sidecars(&db_one), Vec::<String>::new(), "after a write");
    assert_eq!(sidecars(&db_two), Vec::<String>::new(), "after init");

    let request = env.write_request(r#"{"state":"all"}"#);
    let reads: Vec<(Vec<&str>, &str)> = vec![
        (vec!["--project", &one, "show", "ONE-1"], ""),
        (vec!["--project", &one, "list"], ""),
        (vec!["--project", &one, "history", "1"], ""),
        (vec!["--project", &one, "project-key"], ""),
        // A cross-project reference makes enrich scan every project database.
        (vec!["--project", &two, "enrich"], "see ONE-1\n"),
        (
            vec![
                "--format",
                "json",
                "viewer",
                "projects",
                "--request-file",
                request.to_str().expect("UTF-8"),
            ],
            "",
        ),
    ];
    for (args, stdin) in reads {
        env.run(&args, stdin);
        assert_eq!(sidecars(&db_one), Vec::<String>::new(), "after {args:?}");
        assert_eq!(sidecars(&db_two), Vec::<String>::new(), "after {args:?}");
    }
}

/// A pending WAL (frames a writer left without a checkpoint) is not the
/// reader's to checkpoint: the database file and the WAL keep their bytes.
#[test]
fn a_pending_wal_is_neither_checkpointed_nor_removed_by_reads() {
    let env = Env::new();
    let one = env.init("one", "ONE");
    let two = env.init("two", "TWO");
    let db = env.db(&one);
    {
        let conn = rusqlite::Connection::open(&db).expect("writer");
        conn.set_db_config(DbConfig::SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, true)
            .expect("no checkpoint on close");
        conn.execute("UPDATE project SET rules_version = rules_version + 1", [])
            .expect("pending write");
    }
    let wal = sidecar(&db, "-wal");
    assert!(
        fs::metadata(&wal).map(|meta| meta.len()).unwrap_or(0) > 0,
        "fixture needs a pending WAL"
    );
    let before = (fs::read(&db).expect("db"), fs::read(&wal).expect("wal"));
    env.run(&["--project", &one, "project-key"], "");
    env.run(&["--project", &one, "list"], "");
    env.run(&["--project", &two, "enrich"], "see ONE-1\n");
    let after = (fs::read(&db).expect("db"), fs::read(&wal).expect("wal"));
    assert!(before == after, "a read changed the database or its WAL");
}

/// Empty sidecars an older binary's read-only open left behind hold nothing
/// to checkpoint: the next read removes them and keeps the database bytes.
#[test]
fn a_read_removes_empty_sidecars_left_by_older_read_only_opens() {
    let env = Env::new();
    let one = env.init("one", "ONE");
    let db = env.db(&one);
    {
        let conn =
            rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
                .expect("legacy reader");
        conn.query_row("SELECT count(*) FROM tasks", [], |row| row.get::<_, i64>(0))
            .expect("read");
    }
    assert_eq!(fs::metadata(sidecar(&db, "-wal")).expect("-wal").len(), 0);
    assert!(
        sidecar(&db, "-shm").exists(),
        "fixture needs a leftover -shm"
    );
    let before = fs::read(&db).expect("db");
    env.run(&["--project", &one, "list"], "");
    assert_eq!(sidecars(&db), Vec::<String>::new());
    assert!(
        before == fs::read(&db).expect("db"),
        "the read changed the database"
    );
}
