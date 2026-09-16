use std::fs;
use std::process::Command;
use tasks_cli::markdown;
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

fn run(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_tasks"))
        .args(args)
        .output()
        .expect("tasks executable")
}

#[test]
fn several_sources_commit_once_with_separate_provenance_and_rules() {
    let source_a = b"## Rules\nrule A\n## backlog\n### T-1 Alpha\nbody a\n".to_vec();
    let source_b = b"## Rules\nrule B\n## ready\n### T-2 Beta\nbody b\n".to_vec();
    let (_root, mut store) = store();
    let a = markdown::parse("a.md", source_a.clone(), None).expect("a");
    let b = markdown::parse("b.md", source_b.clone(), None).expect("b");
    let hash_a = a.source_hash.clone();
    let hash_b = b.source_hash.clone();
    let (reports, already) = store
        .import_apply_many(vec![a, b], &[hash_a.clone(), hash_b.clone()])
        .expect("multi apply");
    assert!(!already);
    assert_eq!(reports.len(), 2);
    assert_eq!(reports[0].source_sha256, hash_a);
    assert_eq!(reports[1].source_sha256, hash_b);
    assert_eq!(reports[0].task_count, 1);
    assert_eq!(reports[1].task_count, 1);
    assert_eq!(
        store.project_rules().expect("rules").body,
        "rule A\n\nrule B"
    );
    assert_eq!(
        store.list_tasks(None, None, 20).expect("list").items.len(),
        2
    );

    let mut stmt = store
        .conn
        .prepare(
            "SELECT input_sha256, source_name, original_source FROM imports ORDER BY source_name",
        )
        .expect("prepare");
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Vec<u8>>(2)?,
            ))
        })
        .expect("query")
        .collect::<Result<Vec<_>, _>>()
        .expect("rows");
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].1, "a.md");
    assert_eq!(rows[0].0, hash_a);
    assert_eq!(rows[0].2, source_a);
    assert_eq!(rows[1].1, "b.md");
    assert_eq!(rows[1].0, hash_b);
    assert_eq!(rows[1].2, source_b);
}

#[test]
fn cross_source_duplicates_fail_and_the_empty_store_check_runs_once() {
    let (_root, mut store) = store();
    let first =
        markdown::parse("a.md", b"## backlog\n### T-1 A\nbody\n".to_vec(), None).expect("first");
    let duplicate = markdown::parse("b.md", b"## backlog\n### T-1 B\nbody\n".to_vec(), None)
        .expect("duplicate");
    let hashes = vec![first.source_hash.clone(), duplicate.source_hash.clone()];
    assert!(store
        .import_apply_many(vec![first, duplicate], &hashes)
        .is_err());
    assert_eq!(
        store.list_tasks(None, None, 20).expect("list").items.len(),
        0
    );

    let a = markdown::parse("a.md", b"## backlog\n### T-1 A\nbody\n".to_vec(), None).expect("a");
    let b = markdown::parse("b.md", b"## ready\n### T-2 B\nbody\n".to_vec(), None).expect("b");
    let hashes = vec![a.source_hash.clone(), b.source_hash.clone()];
    store
        .import_apply_many(vec![a, b], &hashes)
        .expect("first apply");

    let late =
        markdown::parse("c.md", b"## backlog\n### T-9 C\nbody\n".to_vec(), None).expect("late");
    let hash = late.source_hash.clone();
    let error = store
        .import_apply_many(vec![late.clone()], &[String::new()])
        .expect_err("hash mismatch");
    assert_eq!(error.exit_code(), 2);
    let error = store
        .import_apply_many(vec![late], &[hash])
        .expect_err("empty store precondition");
    assert!(
        error.to_string().contains("requires an empty store"),
        "{error}"
    );
    assert_eq!(
        store.list_tasks(None, None, 20).expect("list").items.len(),
        2
    );
}

#[test]
fn cli_requires_one_hash_per_file_in_order_and_previews_each_file() {
    let work = tempfile::tempdir().expect("work");
    let data_root = work.path().join("data");
    let project_dir = work.path().join("project");
    fs::create_dir_all(&project_dir).expect("project dir");
    let a_path = project_dir.join("a.md");
    let b_path = project_dir.join("b.md");
    let c_path = project_dir.join("c.md");
    fs::write(&a_path, "## backlog\n### T-1 Alpha\nbody a\n").expect("a");
    fs::write(&b_path, "## ready\n### T-2 Beta\nbody b\n").expect("b");
    fs::write(&c_path, "## backlog\n### T-9 Gamma\nbody c\n").expect("c");
    let hash_a = markdown::sha256(&fs::read(&a_path).expect("read a"));
    let hash_b = markdown::sha256(&fs::read(&b_path).expect("read b"));
    let hash_c = markdown::sha256(&fs::read(&c_path).expect("read c"));

    let init = run(&[
        "--data-root",
        data_root.to_str().unwrap(),
        "init",
        "--root",
        project_dir.to_str().unwrap(),
    ]);
    assert!(
        init.status.success(),
        "{}",
        String::from_utf8_lossy(&init.stderr)
    );
    let project = String::from_utf8_lossy(&init.stdout)
        .lines()
        .find_map(|line| line.strip_prefix("project_id: ").map(str::to_string))
        .expect("project id");

    let preview = run(&[
        "--data-root",
        data_root.to_str().unwrap(),
        "--project",
        &project,
        "import",
        "--file",
        a_path.to_str().unwrap(),
        "--file",
        b_path.to_str().unwrap(),
    ]);
    let text = String::from_utf8_lossy(&preview.stdout).to_string();
    assert!(preview.status.success(), "{text}");
    assert!(text.contains("files: 2"), "{text}");
    let position_a = text.find(a_path.to_str().unwrap()).expect("a path");
    let position_b = text.find(b_path.to_str().unwrap()).expect("b path");
    assert!(position_a < position_b, "{text}");
    assert!(!text.contains("applied: true"));

    let reversed = run(&[
        "--data-root",
        data_root.to_str().unwrap(),
        "--project",
        &project,
        "import",
        "--file",
        b_path.to_str().unwrap(),
        "--file",
        a_path.to_str().unwrap(),
    ]);
    let reversed_text = String::from_utf8_lossy(&reversed.stdout).to_string();
    assert!(reversed.status.success(), "{reversed_text}");
    let position_a = reversed_text
        .find(a_path.to_str().unwrap())
        .expect("a path");
    let position_b = reversed_text
        .find(b_path.to_str().unwrap())
        .expect("b path");
    assert!(position_b < position_a, "{reversed_text}");

    let incomplete = run(&[
        "--data-root",
        data_root.to_str().unwrap(),
        "--project",
        &project,
        "import",
        "--file",
        a_path.to_str().unwrap(),
        "--file",
        b_path.to_str().unwrap(),
        "--expect-sha256",
        &hash_a,
    ]);
    assert_eq!(incomplete.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&incomplete.stderr).contains("per --file"));

    let swapped = run(&[
        "--data-root",
        data_root.to_str().unwrap(),
        "--project",
        &project,
        "import",
        "--file",
        a_path.to_str().unwrap(),
        "--file",
        b_path.to_str().unwrap(),
        "--apply",
        "--expect-sha256",
        &hash_b,
        "--expect-sha256",
        &hash_a,
    ]);
    assert_eq!(swapped.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&swapped.stderr);
    assert!(stderr.contains("sha256 mismatch"), "{stderr}");
    assert!(stderr.contains(a_path.to_str().unwrap()), "{stderr}");
    assert!(stderr.contains(&hash_b), "{stderr}");
    assert!(stderr.contains(&hash_a), "{stderr}");
    assert!(stderr.contains("re-run the preview"), "{stderr}");

    let apply = run(&[
        "--data-root",
        data_root.to_str().unwrap(),
        "--project",
        &project,
        "import",
        "--file",
        a_path.to_str().unwrap(),
        "--file",
        b_path.to_str().unwrap(),
        "--apply",
        "--expect-sha256",
        &hash_a,
        "--expect-sha256",
        &hash_b,
    ]);
    assert!(
        apply.status.success(),
        "{}",
        String::from_utf8_lossy(&apply.stderr)
    );
    assert!(String::from_utf8_lossy(&apply.stdout).contains("applied: true"));

    let repeat = run(&[
        "--data-root",
        data_root.to_str().unwrap(),
        "--project",
        &project,
        "import",
        "--file",
        a_path.to_str().unwrap(),
        "--file",
        b_path.to_str().unwrap(),
        "--apply",
        "--expect-sha256",
        &hash_a,
        "--expect-sha256",
        &hash_b,
    ]);
    assert!(
        repeat.status.success(),
        "{}",
        String::from_utf8_lossy(&repeat.stderr)
    );
    assert!(String::from_utf8_lossy(&repeat.stdout).contains("already_imported: true"));

    let mixed = run(&[
        "--data-root",
        data_root.to_str().unwrap(),
        "--project",
        &project,
        "import",
        "--file",
        b_path.to_str().unwrap(),
        "--file",
        c_path.to_str().unwrap(),
        "--apply",
        "--expect-sha256",
        &hash_b,
        "--expect-sha256",
        &hash_c,
    ]);
    assert_eq!(mixed.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&mixed.stderr).contains("already imported"));

    let list = run(&[
        "--data-root",
        data_root.to_str().unwrap(),
        "--project",
        &project,
        "list",
    ]);
    let list_text = String::from_utf8_lossy(&list.stdout).to_string();
    assert!(list_text.contains("T-001"));
    assert!(list_text.contains("T-002"));
    assert!(!list_text.contains("T-009"));
}
