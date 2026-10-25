mod support;
use tasks_cli::attachment::{
    db::{self, PreparedItem},
    envelope, Limits,
};
use tasks_cli::model::TaskStatus;
use tasks_cli::model::TaskUpdate;
use tasks_cli::store::{create_project_db, Store};
use uuid::Uuid;

fn fixture() -> (tempfile::TempDir, Store) {
    let root = tempfile::tempdir().unwrap();
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).unwrap();
    let store = Store::open_rw(root.path(), &project.to_string()).unwrap();
    (root, store)
}

#[test]
fn schema_nine_installs_attachment_objects() {
    let (_root, store) = fixture();
    let version: u32 = store
        .conn
        .pragma_query_value(None, "user_version", |r| r.get(0))
        .unwrap();
    assert_eq!(version, 9);
    let count: u32 = store.conn.query_row("SELECT count(*) FROM sqlite_schema WHERE name IN ('attachment_blobs','task_attachments','attachment_blobs_no_replace','task_attachments_no_replace')", [], |r| r.get(0)).unwrap();
    assert_eq!(count, 4);
}

#[test]
fn new_task_snapshot_has_empty_attachment_references() {
    let (_root, mut store) = fixture();
    store
        .create_task("task", "body", TaskStatus::Ready, vec![])
        .unwrap();
    let snapshot: String = store
        .conn
        .query_row(
            "SELECT snapshot_json FROM events WHERE task_id=1",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let snapshot: serde_json::Value = serde_json::from_str(&snapshot).unwrap();
    assert_eq!(snapshot["attachments"], serde_json::json!([]));
}

fn item(name: &str, bytes: &[u8]) -> PreparedItem {
    PreparedItem {
        name: name.into(),
        envelope: envelope::encode(bytes, name, &Limits::PRODUCTION).unwrap(),
    }
}
fn task(store: &mut Store) -> u64 {
    store
        .create_task("task", "body", TaskStatus::Ready, vec![])
        .unwrap()
        .0
}
fn state(store: &Store) -> (u64, u64, u64, u64, u64) {
    store.conn.query_row("SELECT (SELECT count(*) FROM attachment_blobs),(SELECT count(*) FROM task_attachments),(SELECT count(*) FROM events),(SELECT coalesce(sum(version),0) FROM tasks),(SELECT coalesce(sum(stored_size),0) FROM attachment_blobs)",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).unwrap()
}

#[test]
fn attach_detach_dedup_history_and_reads_are_atomic() {
    let (_root, mut store) = fixture();
    let a = task(&mut store);
    let b = task(&mut store);
    let context = tasks_cli::attribution::current();
    store.set_attribution(&context).unwrap();
    let add = store
        .attach(
            a,
            1,
            vec![item("a.txt", b"hello"), item("b.txt", b"hello")],
            &Limits::PRODUCTION,
        )
        .unwrap();
    assert_eq!((add.version, add.attachments.len()), (2, 2));
    assert!(!add.attachments[0].deduplicated);
    assert!(add.attachments[1].deduplicated);
    assert_eq!(state(&store), (1, 2, 3, 3, 57));
    let (snap, attribution): (String, String) = store
        .conn
        .query_row(
            "SELECT snapshot_json,attribution_json FROM events WHERE event_id=?1",
            [add.event_id.unwrap()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    let snap: serde_json::Value = serde_json::from_str(&snap).unwrap();
    assert_eq!(snap["attachments"].as_array().unwrap().len(), 2);
    assert_eq!(snap["attachments"][0]["id"], 1);
    assert!(snap["attachments"][0].get("envelope").is_none());
    assert!(snap["attachments"][0].get("stored_size").is_none());
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&attribution).unwrap(),
        serde_json::to_value(context).unwrap()
    );
    for (format, command) in [
        ("text", vec!["show", "1"]),
        ("text", vec!["list"]),
        ("json", vec!["show", "1"]),
        ("json", vec!["list"]),
    ] {
        let output = support::process::command(env!("CARGO_BIN_EXE_tasks"))
            .args([
                "--data-root",
                store.data_root.to_str().unwrap(),
                "--project",
                &store.project_id.to_string(),
                "--format",
                format,
            ])
            .args(&command)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert!(!stdout.contains("TASKATT1"));
        if format == "text" {
            if command[0] == "show" {
                assert!(stdout
                    .contains("attachment: A1\ttext\ttext/plain; charset=utf-8\t5 bytes\ta.txt\n"));
                assert!(stdout.contains("attachments: tasks attachment get T-001 [A1 ...] writes local files and prints their paths"));
            } else {
                assert!(stdout.contains("\tattachments=2\n"));
            }
        } else {
            let value: serde_json::Value = serde_json::from_str(&stdout).unwrap();
            if command[0] == "show" {
                assert_eq!(value["data"]["attachments"].as_array().unwrap().len(), 2);
            } else {
                assert_eq!(value["data"]["items"][0]["attachment_count"], 2);
            }
        }
    }
    let detail = store.show_task("1").unwrap();
    assert_eq!(detail.attachments.len(), 2);
    assert_eq!(
        store.list_tasks(None, None, 20).unwrap().items[0].attachment_count,
        2
    );
    assert_eq!(
        store.search_tasks("task", None, 20).unwrap().items[0].attachment_count,
        2
    );
    assert_eq!(
        store
            .search_ranked("task", false, None, 0, 20)
            .unwrap()
            .items[0]
            .attachment_count,
        2
    );
    let page = store.list_attachments(a, false, None, 1).unwrap();
    assert!(page.has_more);
    assert_eq!(page.next_after, Some(1));
    assert_eq!(
        store
            .list_attachments(a, false, page.next_after, 1)
            .unwrap()
            .items[0]
            .attachment
            .id,
        2
    );
    let detached = store.detach(a, 2, &[1, 1]).unwrap();
    assert_eq!((detached.version, detached.detached), (3, vec![1]));
    let before = state(&store);
    let noop = store.detach(a, 3, &[1]).unwrap();
    assert_eq!(noop.event_id, None);
    assert_eq!(noop.version, 3);
    assert_eq!(state(&store), before);
    assert_eq!(store.detach(b, 1, &[2]).unwrap_err().exit_code(), 3);
    assert_eq!(state(&store), before);
    let (record, bytes) = store.read_envelope(a, 1).unwrap();
    assert!(record.detached_ms.is_some());
    let mut decoded = Vec::new();
    envelope::decode_to(&bytes, "a.txt", &mut decoded, &Limits::PRODUCTION).unwrap();
    assert_eq!(decoded, b"hello");
    store
        .attach(b, 1, vec![item("again.txt", b"hello")], &Limits::PRODUCTION)
        .unwrap();
    assert_eq!(
        store.attachment_usage().unwrap(),
        tasks_cli::model::AttachmentUsage {
            attachment_blobs: 1,
            attachment_stored_bytes: 57,
            attachment_quota_bytes: 1024 * 1024 * 1024
        }
    );
    let history = store.history(a, None, 100, None).unwrap().0;
    assert_eq!(
        history.items[1].changed_fields.as_ref().unwrap(),
        &["attachments"]
    );
    assert_eq!(
        history.items[2].changed_fields.as_ref().unwrap(),
        &["attachments"]
    );
    store
        .update_task(
            a,
            3,
            TaskUpdate {
                title: Some("changed".into()),
                ..TaskUpdate::default()
            },
        )
        .unwrap();
    let last: String = store
        .conn
        .query_row(
            "SELECT snapshot_json FROM events WHERE task_id=?1 ORDER BY event_id DESC LIMIT 1",
            [a],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&last).unwrap()["attachments"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn stale_versions_and_all_quota_refusals_write_nothing() {
    let (_root, mut store) = fixture();
    let id = task(&mut store);
    let before = state(&store);
    let error = store
        .attach(id, 99, vec![item("a", b"hi")], &Limits::PRODUCTION)
        .unwrap_err();
    assert_eq!(error.exit_code(), 4);
    assert_eq!(state(&store), before);
    assert_eq!(store.detach(id, 99, &[1]).unwrap_err().exit_code(), 4);
    assert_eq!(state(&store), before);
    for limits in [
        Limits {
            task_count: 0,
            ..Limits::PRODUCTION
        },
        Limits {
            task_stored_bytes: 53,
            ..Limits::PRODUCTION
        },
        Limits {
            project_stored_bytes: 53,
            ..Limits::PRODUCTION
        },
    ] {
        let error = store
            .attach(id, 1, vec![item("a", b"hi")], &limits)
            .unwrap_err();
        assert_eq!(error.exit_code(), 2);
        assert_eq!(state(&store), before);
        assert!(matches!(
            error.code(),
            "task_attachment_limit" | "project_attachment_quota"
        ));
    }
    let limits = Limits {
        project_stored_bytes: 54,
        ..Limits::PRODUCTION
    };
    store
        .attach(id, 1, vec![item("a", b"hi")], &limits)
        .unwrap();
    store.detach(id, 2, &[1]).unwrap();
    let before = state(&store);
    assert_eq!(
        store
            .attach(id, 3, vec![item("new", b"ho")], &limits)
            .unwrap_err()
            .code(),
        "project_attachment_quota"
    );
    assert_eq!(state(&store), before);
    assert!(
        store
            .attach(id, 3, vec![item("same", b"hi")], &limits)
            .unwrap()
            .attachments[0]
            .deduplicated
    );
}

#[test]
fn header_preflight_refuses_batches_without_decoding_or_writing() {
    let (_root, mut store) = fixture();
    let id = task(&mut store);
    let before = state(&store);
    let error = db::preflight(
        std::iter::repeat_n(&b"not even an envelope"[..], 33),
        &Limits::PRODUCTION,
    )
    .unwrap_err();
    assert_eq!(error.code(), "attachment_batch_too_large");
    // Raw envelopes deliberately contain no declared payload: a decode would fail integrity.
    let mut header = b"TASKATT1\x01\x00\x00\x00".to_vec();
    header.extend_from_slice(&(256u64 * 1024 * 1024).to_le_bytes());
    header.extend_from_slice(&[0u8; 32]);
    assert_eq!(
        db::preflight(
            [header.as_slice(), header.as_slice(), header.as_slice()],
            &Limits::PRODUCTION
        )
        .unwrap_err()
        .code(),
        "attachment_batch_too_large"
    );
    let items = (0..33).map(|_| item("a", b"hi")).collect();
    assert_eq!(
        store
            .attach(id, 1, items, &Limits::PRODUCTION)
            .unwrap_err()
            .code(),
        "attachment_batch_too_large"
    );
    assert_eq!(state(&store), before);
}

fn raw(name: &str, bytes: &[u8]) -> PreparedItem {
    let mut envelope = b"TASKATT1\x01\x00\x00\x00".to_vec();
    envelope.extend_from_slice(&(bytes.len() as u64).to_le_bytes());
    use sha2::{Digest, Sha256};
    envelope.extend_from_slice(&Sha256::digest(bytes));
    envelope.extend_from_slice(bytes);
    PreparedItem {
        name: name.into(),
        envelope: envelope::validate(envelope, name, &Limits::PRODUCTION).unwrap(),
    }
}

#[test]
fn alternate_encodings_count_the_persisted_blob_for_each_row() {
    let (_root, mut store) = fixture();
    let a = task(&mut store);
    let b = task(&mut store);
    let bytes = vec![b'x'; 20 * 1024 * 1024];
    let raw_size = (bytes.len() + 52) as u64;
    store
        .attach(
            a,
            1,
            vec![raw("raw.txt", &bytes), raw("raw2.txt", &bytes)],
            &Limits::PRODUCTION,
        )
        .unwrap();
    let before = state(&store);
    let compressed = item("small.txt", &bytes);
    assert_eq!(compressed.envelope.codec(), envelope::Codec::Xz);
    assert_eq!(
        store
            .attach(a, 2, vec![compressed], &Limits::PRODUCTION)
            .unwrap_err()
            .code(),
        "task_attachment_limit"
    );
    assert_eq!(state(&store), before);
    let added = store
        .attach(b, 1, vec![item("other.txt", &bytes)], &Limits::PRODUCTION)
        .unwrap();
    assert!(added.attachments[0].deduplicated);
    assert_eq!(added.attachments[0].attachment.stored_size, raw_size);
    assert_eq!(
        store.attachment_usage().unwrap().attachment_stored_bytes,
        raw_size
    );
    let (_root, mut reverse) = fixture();
    let a = task(&mut reverse);
    let first = reverse
        .attach(a, 1, vec![item("small.txt", &bytes)], &Limits::PRODUCTION)
        .unwrap();
    let small_size = first.attachments[0].attachment.stored_size;
    let second = reverse
        .attach(a, 2, vec![raw("raw.txt", &bytes)], &Limits::PRODUCTION)
        .unwrap();
    assert_eq!(second.attachments[0].attachment.stored_size, small_size);
    assert!(second.attachments[0].deduplicated);
    assert_eq!(
        reverse.attachment_usage().unwrap().attachment_stored_bytes,
        small_size
    );
}

#[test]
fn direct_sql_cannot_mutate_replace_or_ignore_attachment_identity() {
    let (_root, mut store) = fixture();
    let id = task(&mut store);
    store
        .attach(id, 1, vec![item("name.txt", b"hi")], &Limits::PRODUCTION)
        .unwrap();
    let original = store.read_envelope(id, 1).unwrap().1;
    let before = state(&store);
    let delete_error = store
        .conn
        .execute_batch("DELETE FROM attachment_blobs")
        .unwrap_err();
    assert!(
        delete_error
            .to_string()
            .contains("attachment content is retained"),
        "{delete_error}"
    );
    assert_eq!(state(&store), before);
    for sql in [
        "UPDATE attachment_blobs SET envelope=zeroblob(stored_size)",
        "DELETE FROM task_attachments",
        "UPDATE task_attachments SET name='rename'",
        "UPDATE task_attachments SET attachment_id=9",
    ] {
        assert!(store.conn.execute_batch(sql).is_err(), "{sql}");
        assert_eq!(state(&store), before);
    }
    for prefix in ["INSERT OR REPLACE", "REPLACE", "INSERT OR IGNORE"] {
        for select in ["blob_id,content_sha256,original_size,codec,stored_size,created_ms,envelope", "blob_id+100,content_sha256,original_size,codec,stored_size,created_ms,envelope", "blob_id,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',original_size,codec,stored_size,created_ms,envelope"] {
            let sql=format!("{prefix} INTO attachment_blobs SELECT {select} FROM attachment_blobs");assert!(store.conn.execute_batch(&sql).is_err(),"{sql}");
        }
        let sql = format!("{prefix} INTO task_attachments SELECT * FROM task_attachments");
        assert!(store.conn.execute_batch(&sql).is_err(), "{sql}");
        assert_eq!(state(&store), before);
        assert_eq!(store.read_envelope(id, 1).unwrap().1, original);
    }
    store.detach(id, 2, &[1]).unwrap();
    assert!(store
        .conn
        .execute_batch(
            "UPDATE task_attachments SET detached_event_id=added_event_id,detached_ms=123"
        )
        .is_err());
    assert!(store
        .conn
        .execute_batch("UPDATE task_attachments SET detached_event_id=NULL,detached_ms=NULL")
        .is_err());
}

// Subprocess fixture: every invocation is bound to an explicit synthetic data root.
#[cfg(feature = "test-hooks")]
#[test]
fn attachment_child_process() {
    let Some(root) = std::env::var_os("TASKS_ATTACHMENT_CHILD_DATA_ROOT") else {
        return;
    };
    let project = std::env::var("TASKS_ATTACHMENT_CHILD_PROJECT").unwrap();
    if let Ok(case) = std::env::var("TASKS_ATTACHMENT_CHILD_PREFLIGHT") {
        let mut header = b"TASKATT1\x01\x00\x00\x00".to_vec();
        header.extend_from_slice(&(256u64 * 1024 * 1024).to_le_bytes());
        header.extend_from_slice(&[0u8; 32]);
        let inputs = if case == "count" {
            (0..33).map(|_| ("a".into(), vec![])).collect()
        } else if case == "valid" {
            vec![("a".into(), item("a", b"hi").envelope.into_bytes())]
        } else {
            (0..3).map(|_| ("a".into(), header.clone())).collect()
        };
        let result = db::prepare_items(inputs, &Limits::PRODUCTION);
        if case == "valid" {
            assert_eq!(result.unwrap().len(), 1);
        } else {
            assert_eq!(result.unwrap_err().code(), "attachment_batch_too_large");
        }
        return;
    }
    let mut store = Store::open_rw(std::path::Path::new(&root), &project).unwrap();
    let id = std::env::var("TASKS_ATTACHMENT_CHILD_TASK")
        .unwrap()
        .parse()
        .unwrap();
    let version = std::env::var("TASKS_ATTACHMENT_CHILD_VERSION")
        .unwrap()
        .parse()
        .unwrap();
    let size: usize = std::env::var("TASKS_ATTACHMENT_CHILD_SIZE")
        .unwrap()
        .parse()
        .unwrap();
    let seed: u8 = std::env::var("TASKS_ATTACHMENT_CHILD_SEED")
        .unwrap()
        .parse()
        .unwrap();
    let result = if std::env::var_os("TASKS_ATTACHMENT_CHILD_DETACH").is_some() {
        store.detach(id, version, &[1]).map(|_| ())
    } else {
        store
            .attach(
                id,
                version,
                vec![raw("child.bin", &vec![seed; size])],
                &Limits::PRODUCTION,
            )
            .map(|_| ())
    };
    if let Err(error) = result {
        eprintln!("{}: {error}", error.code());
        std::process::exit(error.exit_code());
    }
}

#[cfg(feature = "test-hooks")]
fn child(store: &Store, id: u64, version: u64, size: usize, seed: u8) -> std::process::Command {
    let mut cmd = support::process::command(std::env::current_exe().unwrap());
    cmd.args(["--exact", "attachment_child_process", "--nocapture"])
        .env("TASKS_ATTACHMENT_CHILD_DATA_ROOT", &store.data_root)
        .env(
            "TASKS_ATTACHMENT_CHILD_PROJECT",
            store.project_id.to_string(),
        )
        .env("TASKS_ATTACHMENT_CHILD_TASK", id.to_string())
        .env("TASKS_ATTACHMENT_CHILD_VERSION", version.to_string())
        .env("TASKS_ATTACHMENT_CHILD_SIZE", size.to_string())
        .env("TASKS_ATTACHMENT_CHILD_SEED", seed.to_string())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    cmd
}

#[cfg(feature = "test-hooks")]
#[test]
fn precommit_failure_rolls_back_blobs_references_events_and_version() {
    let (_root, mut store) = fixture();
    let id = task(&mut store);
    let before = state(&store);
    let output = child(&store, id, 1, 8, 1)
        .env("TASKS_PRECOMMIT_FAIL", "1")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("injected precommit failure"));
    assert_eq!(state(&store), before);
    store
        .attach(id, 1, vec![item("a", b"hi")], &Limits::PRODUCTION)
        .unwrap();
    let before = state(&store);
    let output = child(&store, id, 2, 8, 1)
        .env("TASKS_ATTACHMENT_CHILD_DETACH", "1")
        .env("TASKS_PRECOMMIT_FAIL", "1")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(state(&store), before);
    assert!(
        store.list_attachments(id, false, None, 100).unwrap().items[0]
            .detached_ms
            .is_none()
    );
}

#[cfg(feature = "test-hooks")]
fn competing(
    store: &Store,
    first_task: u64,
    second_task: u64,
    version: u64,
    size: usize,
    quota: Option<u64>,
    marker: &std::path::Path,
) -> [std::process::Output; 2] {
    let before = state(store);
    let mut a = child(store, first_task, version, size, 1);
    let mut b = child(store, second_task, version, size, 2);
    a.env("TASKS_HOLD_PRECOMMIT_MS", "400")
        .env("TASKS_PRECOMMIT_READY_FILE", marker);
    if let Some(quota) = quota {
        a.env("TASKS_TEST_PROJECT_ATTACHMENT_QUOTA", quota.to_string());
        b.env("TASKS_TEST_PROJECT_ATTACHMENT_QUOTA", quota.to_string());
    }
    let mut first = a.spawn().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !marker.exists() {
        if let Some(status) = first.try_wait().unwrap() {
            panic!("first child exited before barrier: {status}");
        }
        assert!(
            std::time::Instant::now() < deadline,
            "precommit barrier deadline"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert_eq!(
        state(store),
        before,
        "uncommitted blobs, rows, event and version must be invisible to readers"
    );
    let second = b.spawn().unwrap();
    [
        first.wait_with_output().unwrap(),
        second.wait_with_output().unwrap(),
    ]
}

#[cfg(feature = "test-hooks")]
#[test]
fn competing_attaches_serialize_ids_and_project_quota() {
    for quota in [None, Some(60)] {
        let (root, mut store) = fixture();
        let a = task(&mut store);
        let b = task(&mut store);
        let outputs = competing(&store, a, b, 1, 8, quota, &root.path().join("ready"));
        let codes = outputs
            .iter()
            .map(|o| o.status.code().unwrap())
            .collect::<Vec<_>>();
        if quota.is_none() {
            assert_eq!(codes, vec![0, 0]);
            assert_eq!(state(&store).0, 2);
            assert_eq!(state(&store).1, 2);
            let ids: Vec<(u64, u64)> = store
                .conn
                .prepare(
                    "SELECT attachment_id,blob_id FROM task_attachments ORDER BY attachment_id",
                )
                .unwrap()
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap();
            assert_eq!(ids, vec![(1, 1), (2, 2)]);
        } else {
            assert_eq!(codes, vec![0, 2]);
            assert!(
                String::from_utf8_lossy(&outputs[1].stderr).contains("project_attachment_quota")
            );
            assert_eq!(state(&store).0, 1);
            assert_eq!(state(&store).4, 60);
        }
    }
}

#[cfg(feature = "test-hooks")]
#[test]
fn competing_attaches_obey_task_count_and_byte_limits() {
    for byte_limit in [false, true] {
        let (root, mut store) = fixture();
        let id = task(&mut store);
        let size = if byte_limit {
            store
                .attach(
                    id,
                    1,
                    vec![
                        raw("a", &vec![3; 20 * 1024 * 1024]),
                        raw("b", &vec![4; 20 * 1024 * 1024]),
                    ],
                    &Limits::PRODUCTION,
                )
                .unwrap();
            6 * 1024 * 1024
        } else {
            store
                .attach(
                    id,
                    1,
                    (0..31).map(|_| item("a", b"hi")).collect(),
                    &Limits::PRODUCTION,
                )
                .unwrap();
            8
        };
        let outputs = competing(&store, id, id, 2, size, None, &root.path().join("ready"));
        assert_eq!(outputs[0].status.code(), Some(0));
        assert_eq!(
            outputs[1].status.code(),
            Some(4),
            "{}",
            String::from_utf8_lossy(&outputs[1].stderr)
        );
        assert!(String::from_utf8_lossy(&outputs[1].stderr).contains("version_conflict"));
        let retained = store.list_attachments(id, false, None, 100).unwrap().items;
        assert!(retained.len() <= 32);
        assert!(
            retained
                .iter()
                .map(|a| a.attachment.stored_size)
                .sum::<u64>()
                <= 50 * 1024 * 1024
        );
        assert_eq!(store.show_task(&id.to_string()).unwrap().version, 3);
    }
}

#[test]
fn pre_nine_snapshots_do_not_report_attachment_changes_until_comparable() {
    let (_root, mut store) = fixture();
    let id = task(&mut store);
    store.conn.execute("UPDATE events SET snapshot_json=json_remove(snapshot_json,'$.attachments') WHERE task_id=?1",[id]).unwrap();
    store
        .attach(id, 1, vec![item("a", b"hi")], &Limits::PRODUCTION)
        .unwrap();
    store.detach(id, 2, &[1]).unwrap();
    let history = store.history(id, None, 100, None).unwrap().0;
    assert!(!history.items[1]
        .changed_fields
        .as_ref()
        .unwrap()
        .iter()
        .any(|f| f == "attachments"));
    assert_eq!(
        history.items[2].changed_fields.as_ref().unwrap(),
        &["attachments"]
    );
}

#[test]
fn import_and_viewer_update_snapshots_contain_empty_references() {
    let (root, mut store) = fixture();
    let parsed = tasks_cli::markdown::parse(
        "source.md",
        b"## todo\n### T-1 imported\nBody:\nhello\n".to_vec(),
        None,
    )
    .unwrap();
    let hash = parsed.source_hash.clone();
    store.import_apply(parsed, Some(&hash)).unwrap();
    let request = root.path().join("update.json");
    std::fs::write(
        &request,
        r#"{"id":1,"expect_version":1,"changes":{"title":"viewer changed"}}"#,
    )
    .unwrap();
    let output = support::process::command(env!("CARGO_BIN_EXE_tasks"))
        .args([
            "--data-root",
            root.path().to_str().unwrap(),
            "--project",
            &store.project_id.to_string(),
            "--format",
            "json",
            "viewer",
            "update",
            "--request-file",
            request.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let snapshots: Vec<String> = store
        .conn
        .prepare("SELECT snapshot_json FROM events WHERE task_id=1 ORDER BY event_id")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(snapshots.len(), 2);
    for snapshot in snapshots {
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&snapshot).unwrap()["attachments"],
            serde_json::json!([])
        );
    }
}

#[test]
#[ignore = "release-only retained performance probe"]
fn measure_20_mib_attach() {
    let payload = vec![77u8; 20 * 1024 * 1024];
    for sample in 0..3 {
        let (_root, mut store) = fixture();
        let id = task(&mut store);
        store
            .conn
            .pragma_update(None, "wal_autocheckpoint", 0)
            .unwrap();
        let wal = std::path::PathBuf::from(format!("{}-wal", store.db_path.display()));
        let prepared = raw("large.bin", &payload);
        let before = std::fs::metadata(&wal).map_or(0, |m| m.len());
        let start = std::time::Instant::now();
        store
            .attach(id, 1, vec![prepared], &Limits::PRODUCTION)
            .unwrap();
        let elapsed = start.elapsed();
        let after = std::fs::metadata(&wal).unwrap().len();
        println!("ATTACH_MEASURE sample={sample} original_bytes={} stored_bytes={} attach_ms={:.3} wal_growth_bytes={}",payload.len(),store.attachment_usage().unwrap().attachment_stored_bytes,elapsed.as_secs_f64()*1000.0,after-before);
        assert_eq!(
            store.read_envelope(id, 1).unwrap().1.len(),
            payload.len() + 52
        );
    }
}

#[cfg(feature = "test-hooks")]
#[test]
fn refused_batches_never_reach_the_decode_callsite() {
    let (root, mut store) = fixture();
    let id = task(&mut store);
    let before = state(&store);
    for case in ["count", "originals", "valid"] {
        let log = root.path().join(format!("decode-{case}.log"));
        let output = child(&store, id, 1, 1, 1)
            .env("TASKS_ATTACHMENT_CHILD_PREFLIGHT", case)
            .env("TASKS_TEST_DECODE_LOG", &log)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        if case == "valid" {
            assert_eq!(std::fs::read_to_string(&log).unwrap().lines().count(), 1);
        } else {
            assert!(!log.exists(), "decode callsite was reached for {case}");
        }
        assert_eq!(state(&store), before);
    }
}

#[test]
fn store_rechecks_production_original_byte_budget_before_sql_writes() {
    use sha2::{Digest, Sha256};
    use std::io::Write;
    let (_root, mut store) = fixture();
    let id = task(&mut store);
    let before = state(&store);
    let size = 180u64 * 1024 * 1024;
    // A small-dictionary real xz stream avoids retaining the 180 MiB original.
    let mut encoder = liblzma::write::XzEncoder::new(Vec::new(), 0);
    let mut hash = Sha256::new();
    let chunk = [0u8; 64 * 1024];
    for _ in 0..size / chunk.len() as u64 {
        encoder.write_all(&chunk).unwrap();
        hash.update(chunk);
    }
    let payload = encoder.finish().unwrap();
    let mut bytes = b"TASKATT1\x01\x01\x00\x00".to_vec();
    bytes.extend_from_slice(&size.to_le_bytes());
    bytes.extend_from_slice(&hash.finalize());
    bytes.extend_from_slice(&payload);
    let items = (0..3)
        .map(|_| PreparedItem {
            name: "large.txt".into(),
            envelope: envelope::validate(bytes.clone(), "large.txt", &Limits::PRODUCTION).unwrap(),
        })
        .collect();
    let error = store.attach(id, 1, items, &Limits::PRODUCTION).unwrap_err();
    assert_eq!(error.code(), "attachment_batch_too_large");
    assert_eq!(state(&store), before);
}

#[test]
fn attachment_savepoints_obey_the_callers_outer_transaction() {
    let (_root, mut store) = fixture();
    let id = task(&mut store);
    let before = state(&store);
    let observer = Store::open_readonly(&store.data_root, &store.project_id.to_string()).unwrap();
    let prepared = item("a.txt", b"hi");
    store.conn.execute_batch("BEGIN IMMEDIATE").unwrap();
    store
        .attach(id, 1, vec![prepared], &Limits::PRODUCTION)
        .unwrap();
    assert_eq!(
        state(&observer),
        before,
        "savepoint release must not publish a blob or event"
    );
    store.detach(id, 2, &[1]).unwrap();
    assert_eq!(state(&observer), before);
    store.conn.execute_batch("ROLLBACK").unwrap();
    assert_eq!(state(&store), before);
    let prepared = item("b.txt", b"new");
    store.conn.execute_batch("BEGIN IMMEDIATE").unwrap();
    let result = store
        .attach(id, 1, vec![prepared], &Limits::PRODUCTION)
        .unwrap();
    assert_eq!(result.attachments[0].attachment.id, 1);
    assert_eq!(state(&observer), before);
    store.conn.execute_batch("COMMIT").unwrap();
    assert_eq!(state(&observer), (1, 1, 2, 2, 55));
}
