use std::fs;
use std::process::Command;
use tasks_cli::model::TaskStatus;
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

fn init_project(work: &std::path::Path) -> String {
    let root = work.join("project");
    fs::create_dir_all(&root).expect("project root");
    let init = run(&[
        "--data-root",
        work.to_str().expect("UTF-8 work root"),
        "init",
        "--root",
        root.to_str().expect("UTF-8 project root"),
    ]);
    assert!(
        init.status.success(),
        "{}",
        String::from_utf8_lossy(&init.stderr)
    );
    text_of(&init)
        .lines()
        .find_map(|line| line.strip_prefix("project_id: ").map(str::to_string))
        .expect("project id")
}

#[test]
fn section_patterns_and_default_status_reach_the_store_through_the_cli() {
    let work = tempfile::tempdir().expect("work");
    let project = init_project(work.path());
    let ledger = work.path().join("project").join("TASKS.md");
    fs::write(
        &ledger,
        "## Ongoing\n### T-1 Alpha\nbody one\n## 2026-01-02 release\n### T-2 Beta\nbody two\n## Mystery\n### T-3 Gamma\nbody three\n",
    )
    .expect("ledger");
    let map = work.path().join("map.json");
    fs::write(
        &map,
        r#"{"sections":{"Ongoing":"in-progress"},"section_patterns":[{"pattern":"^\\d{4}-\\d{2}-\\d{2}","status":"done"}],"default_status":"backlog"}"#,
    )
    .expect("map");

    let preview = run(&[
        "--data-root",
        work.path().to_str().expect("data root"),
        "--project",
        &project,
        "import",
        "--file",
        ledger.to_str().expect("ledger path"),
        "--map-file",
        map.to_str().expect("map path"),
    ]);
    let preview_text = text_of(&preview);
    assert!(preview.status.success(), "{preview_text}");
    assert!(
        preview_text.contains("section: Ongoing status=in-progress contains_tasks=true"),
        "{preview_text}"
    );
    assert!(
        preview_text.contains("section: 2026-01-02 release status=done contains_tasks=true"),
        "{preview_text}"
    );
    assert!(
        preview_text.contains("section: Mystery status=draft contains_tasks=true"),
        "{preview_text}"
    );
    let hash = preview_text
        .lines()
        .find_map(|line| line.strip_prefix("source_sha256: "))
        .expect("source hash")
        .to_string();

    let apply = run(&[
        "--data-root",
        work.path().to_str().expect("data root"),
        "--project",
        &project,
        "import",
        "--file",
        ledger.to_str().expect("ledger path"),
        "--map-file",
        map.to_str().expect("map path"),
        "--apply",
        "--expect-sha256",
        &hash,
    ]);
    assert!(
        apply.status.success(),
        "{}",
        String::from_utf8_lossy(&apply.stderr)
    );
    let mut store = Store::open_readonly(work.path(), &project).expect("store");
    assert_eq!(
        store.show_task("T-1").expect("T-1").status,
        TaskStatus::InProgress
    );
    assert_eq!(
        store.show_task("T-2").expect("T-2").status,
        TaskStatus::Done
    );
    assert_eq!(
        store.show_task("T-3").expect("T-3").status,
        TaskStatus::Backlog
    );
}

#[test]
fn invalid_regex_in_the_map_fails_at_load_with_exit_2() {
    let work = tempfile::tempdir().expect("work");
    let project = init_project(work.path());
    let ledger = work.path().join("project").join("TASKS.md");
    fs::write(&ledger, "## backlog\n### T-1 Alpha\nbody\n").expect("ledger");
    let map = work.path().join("bad-regex.json");
    fs::write(
        &map,
        r#"{"section_patterns":[{"pattern":"(","status":"done"}]}"#,
    )
    .expect("map");

    let output = run(&[
        "--format=json",
        "--data-root",
        work.path().to_str().expect("data root"),
        "--project",
        &project,
        "import",
        "--file",
        ledger.to_str().expect("ledger path"),
        "--map-file",
        map.to_str().expect("map path"),
    ]);
    assert_eq!(output.status.code(), Some(2));
    let error = serde_json::from_slice::<serde_json::Value>(&output.stderr).expect("JSON error");
    assert_eq!(error["error"]["code"], "validation");
    assert!(
        error["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("not a valid regex")),
        "{error}"
    );
    let mut store = Store::open_readonly(work.path(), &project).expect("store");
    assert!(store
        .list_tasks(None, None, 20)
        .expect("list")
        .items
        .is_empty());
}
