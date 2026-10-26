//! Local attachment contract: real commands, synthetic stores, no live clipboard.
mod support;
use serde_json::{json, Value};
use std::{
    fs,
    io::Write,
    path::Path,
    process::{Command, Output, Stdio},
};
use tasks_cli::{
    attachment::{db::PreparedItem, envelope, Limits},
    model::TaskStatus,
    store::{create_project_db, Store},
};
use tempfile::TempDir;
use uuid::Uuid;

struct Fixture {
    root: TempDir,
    project: String,
}
impl Fixture {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        create_project_db(root.path(), &id).unwrap();
        let mut store = Store::open_rw(root.path(), &id.to_string()).unwrap();
        store
            .create_task("attachments", "body", TaskStatus::Ready, vec![])
            .unwrap();
        Self {
            root,
            project: id.to_string(),
        }
    }
    fn store(&self) -> Store {
        Store::open_rw(self.root.path(), &self.project).unwrap()
    }
    fn cmd(&self, args: &[&str]) -> Command {
        let mut cmd = support::process::command(env!("CARGO_BIN_EXE_tasks"));
        cmd.env_remove("TASKS_WINDOWS_EXE")
            .env_remove("TASKS_PROJECT")
            .args([
                "--data-root",
                self.root.path().to_str().unwrap(),
                "--project",
                &self.project,
                "--format",
                "json",
            ])
            .args(args);
        cmd
    }
    fn run(&self, args: &[&str], input: Option<&[u8]>) -> Output {
        let mut cmd = self.cmd(args);
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = cmd.spawn().unwrap();
        if let Some(input) = input {
            child.stdin.take().unwrap().write_all(input).unwrap();
        } else {
            drop(child.stdin.take());
        }
        child.wait_with_output().unwrap()
    }
    fn seed(&self, names: &[&str]) {
        let mut store = self.store();
        let items = names
            .iter()
            .map(|name| PreparedItem {
                name: (*name).into(),
                envelope: envelope::encode(name.as_bytes(), name, &Limits::PRODUCTION).unwrap(),
            })
            .collect();
        store.attach(1, 1, items, &Limits::PRODUCTION).unwrap();
    }
    fn path(&self, name: &str) -> String {
        self.root.path().join(name).to_str().unwrap().into()
    }
}
fn ok(output: Output) -> Value {
    assert!(
        output.status.success(),
        "exit {:?}: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!String::from_utf8_lossy(&output.stdout).contains("TASKATT1"));
    serde_json::from_slice::<Value>(&output.stdout).unwrap()["data"].clone()
}
fn error(output: Output, exit: i32, code: &str) -> String {
    assert_eq!(
        output.status.code(),
        Some(exit),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stdout.is_empty());
    let value: Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(value["error"]["code"], code, "{value}");
    value["error"]["message"].as_str().unwrap().into()
}
fn no_temps(root: &Path) {
    for e in fs::read_dir(root).unwrap() {
        let e = e.unwrap();
        assert!(!e.file_name().to_string_lossy().contains(".tasks-tmp-"));
        if e.file_type().unwrap().is_dir() {
            no_temps(&e.path());
        }
    }
}

#[test]
fn add_file_batch_stdin_metadata_and_detach() {
    let f = Fixture::new();
    let source = f.path("source.txt");
    fs::write(&source, b"hello").unwrap();
    let other = f.path("other.json");
    fs::write(&other, b"{}").unwrap();
    let add = ok(f.run(
        &[
            "attachment",
            "add",
            "T-1",
            "--expect-version",
            "1",
            "--file",
            &source,
            "--file",
            &other,
        ],
        None,
    ));
    assert_eq!(add["command"], "attachment_add");
    assert_eq!(add["version"], 2);
    assert_eq!(add["attachments"][0]["name"], "source.txt");
    assert_eq!(add["attachments"][1]["media_type"], "application/json");
    let add = ok(f.run(
        &[
            "attachment",
            "add",
            "1",
            "--expect-version",
            "2",
            "--file",
            "-",
            "--name",
            "stdin.txt",
        ],
        Some(b"hello"),
    ));
    assert_eq!(add["attachments"][0]["deduplicated"], true);
    let shown = ok(f.run(&["show", "1"], None));
    assert_eq!(shown["attachments"].as_array().unwrap().len(), 3);
    for (args, needle) in [
        (
            vec!["show", "1"],
            "attachment: A1\ttext\ttext/plain; charset=utf-8\t5 bytes\tsource.txt",
        ),
        (vec!["list"], "attachments=3"),
        (vec!["search", "attachments"], "attachments=3"),
    ] {
        let output = f.cmd(&args).args(["--format", "text"]).output().unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stdout).contains(needle));
        assert!(!String::from_utf8_lossy(&output.stdout).contains("TASKATT1"));
    }
    let page = ok(f.run(&["attachment", "list", "1", "--limit", "1"], None));
    assert_eq!(page["next_after"], "A1");
    assert_eq!(page["has_more"], true);
    let page = ok(f.run(&["attachment", "list", "1", "--after", "a1"], None));
    assert_eq!(page["items"].as_array().unwrap().len(), 2);
    let detached = ok(f.run(
        &[
            "attachment",
            "detach",
            "1",
            "a1",
            "2",
            "--expect-version",
            "3",
        ],
        None,
    ));
    assert_eq!(detached["detached"], json!([1, 2]));
    assert_eq!(detached["version"], 4);
    let noop = ok(f.run(
        &["attachment", "detach", "1", "A1", "--expect-version", "4"],
        None,
    ));
    assert!(noop["event_id"].is_null());
    let all = ok(f.run(&["attachment", "list", "1", "--all"], None));
    assert!(all["items"][0]["detached_ms"].is_number());
    assert_eq!(
        ok(f.run(&["attachment", "get", "1"], None))["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        ok(f.run(&["attachment", "get", "1", "A1"], None))["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn get_cache_explicit_file_directory_reuse_overwrite_and_text() {
    let f = Fixture::new();
    f.seed(&["one.txt", "two.txt"]);
    let get = ok(f.run(&["attachment", "get", "1"], None));
    for (i, name) in ["one.txt", "two.txt"].iter().enumerate() {
        let expected = f
            .root
            .path()
            .join("cache/attachments")
            .join(&f.project)
            .join(format!("A{}", i + 1))
            .join(name);
        // The CLI resolves the cache root. Windows temp paths can use an 8.3
        // alias (RUNNER~1 on CI), so compare the actual file, not its spelling.
        let actual = Path::new(get["items"][i]["path"].as_str().unwrap());
        assert!(same_file::is_same_file(actual, &expected).unwrap());
        assert_eq!(fs::read(&expected).unwrap(), name.as_bytes());
    }
    let first = get["items"][0]["path"].as_str().unwrap();
    let before = fs::metadata(first).unwrap().modified().unwrap();
    let reused = ok(f.run(&["attachment", "get", "1"], None));
    assert_eq!(reused["items"][0]["reused"], true);
    assert_eq!(fs::metadata(first).unwrap().modified().unwrap(), before);
    fs::write(first, b"damaged cache").unwrap();
    assert_eq!(
        ok(f.run(&["attachment", "get", "1"], None))["items"][0]["reused"],
        false
    );
    let dest = f.path("export.bin");
    ok(f.run(&["attachment", "get", "1", "A1", "--out", &dest], None));
    assert_eq!(
        ok(f.run(&["attachment", "get", "1", "A1", "--out", &dest], None))["items"][0]["reused"],
        true
    );
    fs::write(&dest, b"keep").unwrap();
    error(
        f.run(&["attachment", "get", "1", "A1", "--out", &dest], None),
        2,
        "destination_exists",
    );
    assert_eq!(fs::read(&dest).unwrap(), b"keep");
    ok(f.run(
        &[
            "attachment",
            "get",
            "1",
            "A1",
            "--out",
            &dest,
            "--overwrite",
        ],
        None,
    ));
    assert_eq!(fs::read(&dest).unwrap(), b"one.txt");
    let dir = f.path("directory");
    fs::create_dir(&dir).unwrap();
    ok(f.run(&["attachment", "get", "1", "--out", &dir], None));
    let text = f
        .cmd(&[
            "attachment",
            "get",
            "1",
            "A1",
            "--out",
            &dir,
            "--format",
            "text",
        ])
        .output()
        .unwrap();
    assert!(text.status.success());
    let printed = String::from_utf8(text.stdout).unwrap();
    assert!(printed.ends_with('\n'));
    assert_eq!(printed.lines().count(), 1);
    assert!(same_file::is_same_file(printed.trim_end(), Path::new(&dir).join("one.txt")).unwrap());
    no_temps(f.root.path());
}

#[test]
fn collisions_preflight_all_destinations_and_platform_case_rules() {
    for names in [
        ["same.txt", "same.txt"],
        ["a:b.txt", "a_b.txt"],
        ["k.txt", "K.txt"],
        ["K.txt", "K.txt"],
    ] {
        let f = Fixture::new();
        f.seed(&names);
        let dir = f.path("out");
        fs::create_dir(&dir).unwrap();
        let collision = names[0] == "same.txt"
            || names[0] == "a:b.txt"
            || (cfg!(windows) && names[0] == "k.txt");
        for overwrite in [false, true] {
            let mut args = vec!["attachment", "get", "1", "--out", &dir];
            if overwrite {
                args.push("--overwrite");
            }
            let output = f.run(&args, None);
            if collision {
                let message = error(output, 2, "destination_collision");
                assert!(message.contains("A1") && message.contains("A2"));
                assert_eq!(fs::read_dir(&dir).unwrap().count(), 0);
            } else {
                ok(output);
                assert_eq!(
                    fs::read(Path::new(&dir).join(names[0])).unwrap(),
                    names[0].as_bytes()
                );
                assert_eq!(
                    fs::read(Path::new(&dir).join(names[1])).unwrap(),
                    names[1].as_bytes()
                );
            }
        }
        no_temps(f.root.path());
    }
    let f = Fixture::new();
    f.seed(&["first.txt", "second.txt"]);
    let dir = f.path("out");
    fs::create_dir(&dir).unwrap();
    fs::write(Path::new(&dir).join("second.txt"), b"keep").unwrap();
    error(
        f.run(&["attachment", "get", "1", "--out", &dir], None),
        2,
        "destination_exists",
    );
    assert!(!Path::new(&dir).join("first.txt").exists());
    no_temps(f.root.path());
}

#[test]
fn overwrite_refuses_aliasing_destinations() {
    let f = Fixture::new();
    f.seed(&["first.txt", "second.txt"]);
    let dir = f.path("out");
    fs::create_dir(&dir).unwrap();
    let a = Path::new(&dir).join("first.txt");
    let b = Path::new(&dir).join("second.txt");
    fs::write(&a, b"keep").unwrap();
    fs::hard_link(&a, &b).unwrap();
    error(
        f.run(
            &["attachment", "get", "1", "--out", &dir, "--overwrite"],
            None,
        ),
        2,
        "destination_collision",
    );
    assert_eq!(fs::read(&a).unwrap(), b"keep");
    assert_eq!(fs::read(&b).unwrap(), b"keep");
    no_temps(f.root.path());
}

#[test]
fn maximum_ascii_and_multibyte_safe_names_publish_without_shortening_final_names() {
    let f = Fixture::new();
    let ascii = format!("{}.txt", "a".repeat(251));
    let multibyte = format!("{}.json", "é".repeat(125));
    assert_eq!(ascii.len(), 255);
    assert_eq!(multibyte.len(), 255);
    f.seed(&[&ascii, &multibyte]);
    for explicit in [false, true] {
        let directory = f.path("long-name-exports");
        fs::create_dir_all(&directory).unwrap();
        let mut args = vec!["attachment", "get", "1"];
        if explicit {
            args.extend(["--out", &directory]);
        }
        let get = ok(f.run(&args, None));
        for (item, name) in get["items"]
            .as_array()
            .unwrap()
            .iter()
            .zip([&ascii, &multibyte])
        {
            let path = Path::new(item["path"].as_str().unwrap());
            assert_eq!(path.file_name().unwrap(), name.as_str());
            assert_eq!(fs::read(path).unwrap(), name.as_bytes());
        }
    }
    no_temps(f.root.path());
}

#[test]
fn errors_name_missing_ids_and_enforce_usage_conflicts_and_io() {
    let f = Fixture::new();
    f.seed(&["one.txt"]);
    let mut store = f.store();
    store
        .create_task("second", "", TaskStatus::Ready, vec![])
        .unwrap();
    drop(store);
    let message = error(
        f.run(&["attachment", "get", "2", "A1", "A99"], None),
        3,
        "not_found",
    );
    assert!(message.contains("A1") && message.contains("A99"));
    error(f.run(&["attachment", "list", "999"], None), 3, "not_found");
    error(
        f.run(
            &["attachment", "detach", "1", "A1", "--expect-version", "1"],
            None,
        ),
        4,
        "version_conflict",
    );
    for args in [
        vec!["attachment", "get", "1", "--out", "-"],
        vec![
            "attachment",
            "add",
            "1",
            "--expect-version",
            "2",
            "--file",
            "-",
        ],
        vec![
            "attachment",
            "detach",
            "1",
            "A1",
            "--expect-version",
            "2",
            "--request-id",
            "01234567-89ab-4cde-8fab-0123456789ab",
        ],
    ] {
        error(f.run(&args, None), 2, "usage");
    }
    error(
        f.run(
            &[
                "attachment",
                "add",
                "1",
                "--expect-version",
                "2",
                "--file",
                "-",
                "--name",
                "a/b",
            ],
            Some(b"x"),
        ),
        2,
        "validation",
    );
    error(
        f.run(
            &[
                "attachment",
                "add",
                "1",
                "--expect-version",
                "2",
                "--file",
                &f.path("missing"),
            ],
            None,
        ),
        6,
        "io",
    );
    error(
        f.run(
            &["attachment", "get", "1", "--out", &f.path("missing/child")],
            None,
        ),
        6,
        "io",
    );
}

#[test]
fn get_enforces_its_selection_limit_and_detach_deduplicates_repeated_ids() {
    let f = Fixture::new();
    f.seed(&["one.txt"]);
    let mut args = vec!["attachment", "get", "1"];
    args.extend(std::iter::repeat_n("A1", 33));
    error(f.run(&args, None), 2, "usage");
    let mut args = vec!["attachment", "detach", "1"];
    args.extend(std::iter::repeat_n("A1", 33));
    args.extend(["--expect-version", "2"]);
    let detached = ok(f.run(&args, None));
    assert_eq!(detached["detached"], json!([1]));
    assert_eq!(detached["version"], 3);
}

#[test]
fn partial_get_reports_prior_publications_when_a_later_blob_is_corrupt() {
    let f = Fixture::new();
    f.seed(&["good.txt", "broken.txt"]);
    let store = f.store();
    let trigger: String = store
        .conn
        .query_row(
            "SELECT sql FROM sqlite_schema WHERE name='attachment_blobs_no_update'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    store.conn.execute_batch("DROP TRIGGER attachment_blobs_no_update; UPDATE attachment_blobs SET envelope=zeroblob(length(envelope)) WHERE blob_id=(SELECT blob_id FROM task_attachments WHERE attachment_id=2)").unwrap();
    store.conn.execute_batch(&trigger).unwrap();
    drop(store);
    let out = f.path("partial");
    fs::create_dir(&out).unwrap();
    let message = error(
        f.run(&["attachment", "get", "1", "--out", &out], None),
        6,
        "attachment_integrity",
    );
    assert!(
        message.contains("already published:") && message.contains("good.txt"),
        "{message}"
    );
    assert_eq!(
        fs::read(Path::new(&out).join("good.txt")).unwrap(),
        b"good.txt"
    );
    assert!(!Path::new(&out).join("broken.txt").exists());
    no_temps(f.root.path());
}

#[test]
fn corruption_is_never_published_even_when_cache_matches() {
    let f = Fixture::new();
    f.seed(&["one.txt"]);
    let get = ok(f.run(&["attachment", "get", "1"], None));
    let cache = get["items"][0]["path"].as_str().unwrap();
    let store = f.store();
    store.conn.execute_batch("DROP TRIGGER attachment_blobs_no_update; UPDATE attachment_blobs SET envelope=zeroblob(length(envelope));").unwrap();
    // Restore the trigger definition so schema admission succeeds and tests the read integrity boundary.
    let reference = rusqlite::Connection::open_in_memory().unwrap();
    tasks_cli::attachment::db::create_schema(&reference).unwrap();
    let sql: String = reference
        .query_row(
            "SELECT sql FROM sqlite_schema WHERE name='attachment_blobs_no_update'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    store.conn.execute_batch(&sql).unwrap();
    drop(store);
    let out = f.path("must-not-exist");
    let message = error(
        f.run(&["attachment", "get", "1", "--out", &out], None),
        6,
        "attachment_integrity",
    );
    assert!(message.contains("verified backup"));
    assert!(!Path::new(&out).exists());
    error(
        f.run(&["attachment", "get", "1"], None),
        6,
        "attachment_integrity",
    );
    assert_eq!(fs::read(cache).unwrap(), b"one.txt");
    no_temps(f.root.path());
}

#[test]
fn count_and_sparse_size_preflight_happen_before_encoding() {
    let f = Fixture::new();
    let log = f.path("encode.log");
    let mut args = vec!["attachment", "add", "1", "--expect-version", "1"];
    for _ in 0..33 {
        args.extend(["--file", "does-not-exist"]);
    }
    let out = f
        .cmd(&args)
        .env("TASKS_TEST_ENCODE_LOG", &log)
        .output()
        .unwrap();
    error(out, 2, "attachment_batch_too_large");
    let large = f.path("large.bin");
    fs::File::create(&large)
        .unwrap()
        .set_len(268_435_457)
        .unwrap();
    error(
        f.cmd(&[
            "attachment",
            "add",
            "1",
            "--expect-version",
            "1",
            "--file",
            &large,
        ])
        .env("TASKS_TEST_ENCODE_LOG", &log)
        .output()
        .unwrap(),
        2,
        "attachment_original_too_large",
    );
    fs::File::create(&large)
        .unwrap()
        .set_len(200 * 1024 * 1024)
        .unwrap();
    error(
        f.cmd(&[
            "attachment",
            "add",
            "1",
            "--expect-version",
            "1",
            "--file",
            &large,
            "--file",
            &large,
            "--file",
            &large,
        ])
        .env("TASKS_TEST_ENCODE_LOG", &log)
        .output()
        .unwrap(),
        2,
        "attachment_batch_too_large",
    );
    assert!(!Path::new(&log).exists() || fs::read(&log).unwrap().is_empty());
    assert_eq!(ok(f.run(&["show", "1"], None))["version"], 1);
}

#[test]
fn payload_task_count_and_stored_byte_limits_refuse_without_partial_attach() {
    // Recognized PNG bytes stay raw, so this probes L1 without compression work.
    let f = Fixture::new();
    let source = f.path("oversize.png");
    let mut file = fs::File::create(&source).unwrap();
    file.write_all(b"\x89PNG\r\n\x1a\n").unwrap();
    file.set_len(20 * 1024 * 1024 + 1).unwrap();
    drop(file);
    error(
        f.run(
            &[
                "attachment",
                "add",
                "1",
                "--expect-version",
                "1",
                "--file",
                &source,
            ],
            None,
        ),
        2,
        "attachment_too_large",
    );
    assert_eq!(ok(f.run(&["show", "1"], None))["attachments"], json!([]));

    let f = Fixture::new();
    f.seed(&["tiny.txt"; 32]);
    let source = f.path("extra.txt");
    fs::write(&source, b"extra").unwrap();
    error(
        f.run(
            &[
                "attachment",
                "add",
                "1",
                "--expect-version",
                "2",
                "--file",
                &source,
            ],
            None,
        ),
        2,
        "task_attachment_limit",
    );
    assert_eq!(ok(f.run(&["show", "1"], None))["version"], 2);

    let f = Fixture::new();
    let source = f.path("large.png");
    let mut file = fs::File::create(&source).unwrap();
    file.write_all(b"\x89PNG\r\n\x1a\n").unwrap();
    file.set_len(18 * 1024 * 1024).unwrap();
    drop(file);
    // Dedup still counts each retained reference against task stored bytes (L4).
    error(
        f.run(
            &[
                "attachment",
                "add",
                "1",
                "--expect-version",
                "1",
                "--file",
                &source,
                "--file",
                &source,
                "--file",
                &source,
            ],
            None,
        ),
        2,
        "task_attachment_limit",
    );
    assert_eq!(ok(f.run(&["show", "1"], None))["version"], 1);
}

#[cfg(feature = "test-hooks")]
#[test]
fn project_quota_and_lock_timeout_have_their_documented_exit_codes() {
    let f = Fixture::new();
    let source = f.path("quota.txt");
    fs::write(&source, b"quota").unwrap();
    error(
        f.cmd(&[
            "attachment",
            "add",
            "1",
            "--expect-version",
            "1",
            "--file",
            &source,
        ])
        .env("TASKS_TEST_PROJECT_ATTACHMENT_QUOTA", "1")
        .output()
        .unwrap(),
        2,
        "project_attachment_quota",
    );
    let store = f.store();
    store.conn.execute_batch("BEGIN IMMEDIATE").unwrap();
    error(
        f.run(
            &[
                "attachment",
                "add",
                "1",
                "--expect-version",
                "1",
                "--file",
                &source,
            ],
            None,
        ),
        5,
        "lock_timeout",
    );
    store.conn.execute_batch("ROLLBACK").unwrap();
    assert_eq!(ok(f.run(&["show", "1"], None))["version"], 1);
}

#[test]
fn text_add_detach_and_name_override_follow_the_contract() {
    let f = Fixture::new();
    let source = f.path("source");
    fs::write(&source, b"hello").unwrap();
    let add = f
        .cmd(&[
            "attachment",
            "add",
            "1",
            "--expect-version",
            "1",
            "--file",
            &source,
            "--name",
            "named.txt",
            "--format",
            "text",
        ])
        .output()
        .unwrap();
    assert!(
        add.status.success(),
        "{}",
        String::from_utf8_lossy(&add.stderr)
    );
    let text = String::from_utf8(add.stdout).unwrap();
    assert!(
        text.starts_with("id: T-001\nstatus: todo\nversion: 2\nevent_id: "),
        "{text}"
    );
    assert!(
        text.ends_with("attached: A1\ttext\ttext/plain; charset=utf-8\t5 bytes\tnamed.txt\n"),
        "{text}"
    );
    let detach = f
        .cmd(&[
            "attachment",
            "detach",
            "1",
            "A1",
            "--expect-version",
            "2",
            "--format",
            "text",
        ])
        .output()
        .unwrap();
    assert!(detach.status.success());
    assert!(String::from_utf8(detach.stdout)
        .unwrap()
        .ends_with("detached: A1\n"));
    let detach = f
        .cmd(&[
            "attachment",
            "detach",
            "1",
            "A1",
            "--expect-version",
            "3",
            "--format",
            "text",
        ])
        .output()
        .unwrap();
    assert!(detach.status.success());
    assert!(String::from_utf8(detach.stdout)
        .unwrap()
        .ends_with("event_id: null\n"));
}

#[cfg(unix)]
#[test]
fn non_regular_fifo_sources_are_refused_without_waiting_for_a_writer() {
    let f = Fixture::new();
    let fifo = f.path("pipe");
    assert!(support::process::command("mkfifo")
        .arg(&fifo)
        .status()
        .unwrap()
        .success());
    let mut child = f
        .cmd(&[
            "attachment",
            "add",
            "1",
            "--expect-version",
            "1",
            "--file",
            &fifo,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while child.try_wait().unwrap().is_none() {
        if std::time::Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("non-regular attachment input blocked waiting for a FIFO writer");
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    error(child.wait_with_output().unwrap(), 6, "io");
}

#[cfg(feature = "test-hooks")]
#[test]
fn clipboard_errors_are_mapped_without_opening_a_store() {
    let f = Fixture::new();
    let dir = f.path("broken-clipboard");
    fs::create_dir(&dir).unwrap();
    fs::write(Path::new(&dir).join("files.json"), b"invalid JSON").unwrap();
    error(
        f.cmd(&["attachment", "clipboard"])
            .env("TASKS_TEST_CLIPBOARD_FIXTURE", &dir)
            .output()
            .unwrap(),
        6,
        "interop",
    );
    fs::write(
        Path::new(&dir).join("files.json"),
        serde_json::to_vec(&json!({"count":33,"files":[]})).unwrap(),
    )
    .unwrap();
    error(
        f.cmd(&["attachment", "clipboard"])
            .env("TASKS_TEST_CLIPBOARD_FIXTURE", &dir)
            .output()
            .unwrap(),
        2,
        "attachment_batch_too_large",
    );
}

#[cfg(feature = "test-hooks")]
#[test]
fn clipboard_fixture_inspection_token_match_mismatch_and_empty() {
    let f = Fixture::new();
    let dir = f.path("clipboard");
    fs::create_dir(&dir).unwrap();
    let source = f.path("clip.txt");
    fs::write(&source, b"clip").unwrap();
    fs::write(
        Path::new(&dir).join("files.json"),
        serde_json::to_vec(&json!([source])).unwrap(),
    )
    .unwrap();
    let inspect = ok(f
        .cmd(&["attachment", "clipboard"])
        .env("TASKS_TEST_CLIPBOARD_FIXTURE", &dir)
        .output()
        .unwrap());
    assert_eq!(inspect["items"][0]["source"], "file");
    assert_eq!(inspect["items"][0]["name"], "clip.txt");
    error(
        f.cmd(&[
            "attachment",
            "add",
            "1",
            "--expect-version",
            "1",
            "--clipboard",
            "--clipboard-token",
            &"0".repeat(64),
        ])
        .env("TASKS_TEST_CLIPBOARD_FIXTURE", &dir)
        .output()
        .unwrap(),
        4,
        "clipboard_changed",
    );
    ok(f.cmd(&[
        "attachment",
        "add",
        "1",
        "--expect-version",
        "1",
        "--clipboard",
        "--clipboard-token",
        inspect["token"].as_str().unwrap(),
    ])
    .env("TASKS_TEST_CLIPBOARD_FIXTURE", &dir)
    .output()
    .unwrap());
    fs::remove_file(Path::new(&dir).join("files.json")).unwrap();
    error(
        f.cmd(&["attachment", "clipboard"])
            .env("TASKS_TEST_CLIPBOARD_FIXTURE", &dir)
            .output()
            .unwrap(),
        2,
        "clipboard_empty",
    );
    fs::write(
        Path::new(&dir).join("image.png"),
        b"\x89PNG\r\n\x1a\nsynthetic",
    )
    .unwrap();
    let image = ok(f
        .cmd(&[
            "attachment",
            "add",
            "1",
            "--expect-version",
            "2",
            "--clipboard",
        ])
        .env("TASKS_TEST_CLIPBOARD_FIXTURE", &dir)
        .output()
        .unwrap());
    assert_eq!(image["attachments"][0]["kind"], "image");
    let name = image["attachments"][0]["name"].as_str().unwrap();
    assert!(name.starts_with("clipboard-") && name.ends_with("Z.png"));
}

#[cfg(feature = "test-hooks")]
#[test]
fn replaced_staging_path_is_detected_after_publication() {
    for mode in ["no-replace", "overwrite", "cache"] {
        let f = Fixture::new();
        f.seed(&["one.txt"]);
        let out = if mode == "cache" {
            f.root
                .path()
                .join("cache/attachments")
                .join(&f.project)
                .join("A1/one.txt")
        } else {
            f.root.path().join("final.txt")
        };
        let ready = f.path("ready");
        let release = f.path("release");
        let mut cmd = f.cmd(&["attachment", "get", "1", "A1"]);
        if mode != "cache" {
            cmd.args(["--out", out.to_str().unwrap()]);
        }
        if mode == "overwrite" {
            fs::write(&out, b"existing destination").unwrap();
            cmd.arg("--overwrite");
        }
        let child = cmd
            .env("TASKS_TEST_PUBLISH_READY", &ready)
            .env("TASKS_TEST_PUBLISH_RELEASE", &release)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        wait_for_publication(&ready);
        let temp = staging_path(out.parent().unwrap());
        let moved = f.root.path().join("moved-stage");
        fs::rename(&temp, &moved).unwrap();
        fs::write(&temp, b"bad.txt").unwrap();
        fs::write(&release, b"release").unwrap();
        let message = error(child.wait_with_output().unwrap(), 6, "attachment_integrity");
        assert!(
            message.contains("final.txt") || message.contains("one.txt"),
            "{message}"
        );
        assert_eq!(fs::read(&out).unwrap(), b"bad.txt");
        assert_eq!(fs::read(&moved).unwrap(), b"one.txt");
        // Unix no-clobber links leave the source entry; it is somebody else's.
        #[cfg(unix)]
        if mode == "no-replace" {
            assert!(
                temp.exists(),
                "replacement source must be preserved after link publication"
            );
        }
        if temp.exists() {
            assert_eq!(fs::read(&temp).unwrap(), b"bad.txt");
            assert!(message.contains("leftover"), "{message}");
        }
    }
}

#[cfg(feature = "test-hooks")]
#[test]
fn replaced_staging_path_is_preserved_on_failed_publication() {
    let f = Fixture::new();
    f.seed(&["one.txt"]);
    let out = f.path("final.txt");
    let ready = f.path("ready");
    let release = f.path("release");
    let child = f
        .cmd(&["attachment", "get", "1", "A1", "--out", &out])
        .env("TASKS_TEST_PUBLISH_READY", &ready)
        .env("TASKS_TEST_PUBLISH_RELEASE", &release)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    wait_for_publication(&ready);
    let temp = staging_path(f.root.path());
    let moved = f.root.path().join("moved-stage");
    fs::rename(&temp, &moved).unwrap();
    fs::write(&temp, b"replacement owned by another writer").unwrap();
    fs::write(&out, b"competing destination").unwrap();
    fs::write(&release, b"release").unwrap();
    let message = error(child.wait_with_output().unwrap(), 2, "destination_exists");
    assert_eq!(
        fs::read(&temp).unwrap(),
        b"replacement owned by another writer"
    );
    assert!(
        message.contains("leftover")
            && message.contains(temp.file_name().unwrap().to_str().unwrap()),
        "{message}"
    );
    assert_eq!(fs::read(&moved).unwrap(), b"one.txt");
    assert_eq!(fs::read(&out).unwrap(), b"competing destination");
}

#[cfg(feature = "test-hooks")]
fn wait_for_publication(ready: &str) {
    let start = std::time::Instant::now();
    while !Path::new(ready).exists() {
        assert!(
            start.elapsed() < std::time::Duration::from_secs(8),
            "publisher did not reach barrier"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}

#[cfg(feature = "test-hooks")]
fn staging_path(dir: &Path) -> std::path::PathBuf {
    let paths: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with(".tasks-tmp-")
        })
        .collect();
    assert_eq!(paths.len(), 1);
    paths[0].clone()
}

#[cfg(feature = "test-hooks")]
#[test]
fn competing_publishers_do_not_clobber_and_identical_content_is_reused() {
    for identical in [false, true] {
        let f = Fixture::new();
        f.seed(if identical {
            &["same.txt", "same.txt"]
        } else {
            &["one.txt", "two.txt"]
        });
        let out = f.path("race.txt");
        let mut children = Vec::new();
        let release = f.path("release");
        let ready: Vec<_> = ["ready1", "ready2"].map(|name| f.path(name)).into();
        for (id, ready) in ["A1", "A2"].into_iter().zip(&ready) {
            children.push(
                f.cmd(&["attachment", "get", "1", id, "--out", &out])
                    .env("TASKS_TEST_PUBLISH_READY", ready)
                    .env("TASKS_TEST_PUBLISH_RELEASE", &release)
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .spawn()
                    .unwrap(),
            );
        }
        for ready in &ready {
            wait_for_publication(ready);
        }
        fs::write(&release, b"release").unwrap();
        let outputs: Vec<_> = children
            .into_iter()
            .map(|c| c.wait_with_output().unwrap())
            .collect();
        if identical {
            let values: Vec<_> = outputs.into_iter().map(ok).collect();
            assert_eq!(
                values
                    .iter()
                    .filter(|v| v["items"][0]["reused"] == true)
                    .count(),
                1
            );
        } else {
            let mut winner = None;
            for output in outputs {
                if output.status.success() {
                    assert!(winner.is_none());
                    winner = Some(ok(output));
                } else {
                    error(output, 2, "destination_exists");
                }
            }
            let winner = winner.unwrap();
            let name = winner["items"][0]["attachment"]["name"].as_str().unwrap();
            assert_eq!(fs::read(&out).unwrap(), name.as_bytes());
        }
        no_temps(f.root.path());
    }
}
