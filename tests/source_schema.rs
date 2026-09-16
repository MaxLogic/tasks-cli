use std::fs;
use std::process::Command;
use tasks_cli::markdown::{parse, parse_with_schema};
use tasks_cli::model::SourceSchema;
use tasks_cli::store::Store;

fn run(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_tasks"))
        .args(args)
        .output()
        .expect("tasks executable")
}

fn text_of(output: &std::process::Output) -> String {
    String::from_utf8_lossy(&output.stdout).to_string()
}

#[test]
fn create_task_schema_applies_deps_additively_and_round_trips_the_body() {
    let source = "## in-progress\n### T-1 Alpha\nOutcome:\n- ok\nDeps: T-2, T-3\nProof:\n- Run: x\n### T-2 Beta\nDeps: none\nbody two\n### T-3 Gamma\nDeps: -\nbody three\n";
    let canonical = parse("TASKS.md", source.as_bytes().to_vec(), None).expect("canonical parse");
    assert!(canonical.tasks.iter().all(|task| task.deps.is_empty()));
    let parsed = parse_with_schema(
        "TASKS.md",
        source.as_bytes().to_vec(),
        None,
        SourceSchema::CreateTask,
    )
    .expect("create-task parse");
    assert_eq!(parsed.tasks[0].deps, vec![2, 3]);
    assert_eq!(
        parsed.tasks[0].body,
        "Outcome:\n- ok\nDeps: T-2, T-3\nProof:\n- Run: x"
    );
    assert!(parsed.tasks[0].body.contains("Deps: T-2, T-3"));

    let work = tempfile::tempdir().expect("work");
    let root = work.path().join("project");
    fs::create_dir_all(&root).expect("root");
    let ledger = root.join("TASKS.md");
    fs::write(&ledger, source).expect("ledger");

    let init = run(&[
        "--data-root",
        work.path().to_str().unwrap(),
        "init",
        "--root",
        root.to_str().unwrap(),
    ]);
    assert!(
        init.status.success(),
        "{}",
        String::from_utf8_lossy(&init.stderr)
    );
    let project = text_of(&init)
        .lines()
        .find_map(|line| line.strip_prefix("project_id: ").map(str::to_string))
        .expect("project id");

    let preview = run(&[
        "--data-root",
        work.path().to_str().unwrap(),
        "--project",
        &project,
        "import",
        "--file",
        ledger.to_str().unwrap(),
        "--source-schema",
        "create-task",
    ]);
    let preview_text = text_of(&preview);
    assert!(preview.status.success(), "{preview_text}");
    assert!(
        preview_text.contains("deps=[T-002,T-003]"),
        "{preview_text}"
    );
    assert!(preview_text.contains("consumed=[Deps]"), "{preview_text}");
    let hash = preview_text
        .lines()
        .find_map(|line| line.strip_prefix("source_sha256: "))
        .expect("hash")
        .to_string();

    let apply = run(&[
        "--data-root",
        work.path().to_str().unwrap(),
        "--project",
        &project,
        "import",
        "--file",
        ledger.to_str().unwrap(),
        "--source-schema",
        "create-task",
        "--apply",
        "--expect-sha256",
        &hash,
    ]);
    assert!(
        apply.status.success(),
        "{}",
        String::from_utf8_lossy(&apply.stderr)
    );

    let mut store = Store::open_readonly(work.path(), &project).expect("read store");
    let detail = store.show_task("T-1").expect("task");
    assert_eq!(detail.deps, vec![2, 3]);
    assert_eq!(
        detail.body,
        "Outcome:\n- ok\nDeps: T-2, T-3\nProof:\n- Run: x"
    );
    assert_eq!(fs::read_to_string(&ledger).expect("source intact"), source);
}

#[test]
fn create_task_schema_reports_unresolved_deps_instead_of_dropping_them() {
    let source = "## ready\n### T-1 Alpha\nOutcome:\n- ok\nDeps: `T-027`; vendor SDK\nbody\n";
    let work = tempfile::tempdir().expect("work");
    let root = work.path().join("project");
    fs::create_dir_all(&root).expect("root");
    let ledger = root.join("TASKS.md");
    fs::write(&ledger, source).expect("ledger");

    let init = run(&[
        "--data-root",
        work.path().to_str().unwrap(),
        "init",
        "--root",
        root.to_str().unwrap(),
    ]);
    assert!(
        init.status.success(),
        "{}",
        String::from_utf8_lossy(&init.stderr)
    );
    let project = text_of(&init)
        .lines()
        .find_map(|line| line.strip_prefix("project_id: ").map(str::to_string))
        .expect("project id");

    let preview = run(&[
        "--data-root",
        work.path().to_str().unwrap(),
        "--project",
        &project,
        "import",
        "--file",
        ledger.to_str().unwrap(),
        "--source-schema",
        "create-task",
    ]);
    let preview_text = text_of(&preview);
    assert!(preview.status.success(), "{preview_text}");
    assert!(preview_text.contains("deps=[]"), "{preview_text}");
    assert!(
        preview_text.contains("warning: ") && preview_text.contains("T-027"),
        "{preview_text}"
    );
    assert!(preview_text.contains("vendor SDK"), "{preview_text}");
    assert!(preview_text.contains("line 5"), "{preview_text}");
    let hash = preview_text
        .lines()
        .find_map(|line| line.strip_prefix("source_sha256: "))
        .expect("hash")
        .to_string();

    let apply = run(&[
        "--data-root",
        work.path().to_str().unwrap(),
        "--project",
        &project,
        "import",
        "--file",
        ledger.to_str().unwrap(),
        "--source-schema",
        "create-task",
        "--apply",
        "--expect-sha256",
        &hash,
    ]);
    assert!(
        apply.status.success(),
        "{}",
        String::from_utf8_lossy(&apply.stderr)
    );
    let mut store = Store::open_readonly(work.path(), &project).expect("read store");
    let detail = store.show_task("T-1").expect("task");
    assert!(detail.deps.is_empty(), "{:?}", detail.deps);
    assert_eq!(
        detail.body,
        "Outcome:\n- ok\nDeps: `T-027`; vendor SDK\nbody"
    );
    assert_eq!(fs::read_to_string(&ledger).expect("source intact"), source);
}
