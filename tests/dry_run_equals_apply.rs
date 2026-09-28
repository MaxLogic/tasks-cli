//! Preview must run every data check apply runs before its transaction. Each
//! test here violates one apply-side check and asserts that the dry run
//! reports it in the all-problems format, and that a passing dry run is not
//! followed by an apply failure for a data reason.

use serde_json::Value;
use std::fs;
use std::path::Path;
use std::process::{Command, Output};

fn write(path: &Path, contents: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("parent directory");
    }
    fs::write(path, contents).expect("fixture file");
}

fn string_arg(value: impl AsRef<Path>) -> String {
    value.as_ref().to_string_lossy().to_string()
}

fn run(args: &[String]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_tasks"))
        .args(args)
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .output()
        .expect("tasks executable")
}

fn candidates(report_dir: &Path) -> Vec<Value> {
    let text = fs::read_to_string(report_dir.join("run.jsonl")).expect("run.jsonl");
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).expect("candidate JSON"))
        .collect()
}

fn problem<'a>(candidate: &'a Value, needle: &str) -> &'a Value {
    candidate["problems"]
        .as_array()
        .expect("problems")
        .iter()
        .find(|problem| problem["message"].as_str().unwrap_or("").contains(needle))
        .unwrap_or_else(|| {
            panic!(
                "no problem containing {needle:?} in {}",
                candidate["problems"]
            )
        })
}

fn messages(value: &Value) -> String {
    value
        .as_array()
        .expect("array")
        .iter()
        .map(|item| item["message"].as_str().expect("message").to_string())
        .collect::<Vec<_>>()
        .join("\n")
}

fn bulk_dry_run(
    corpus: &Path,
    map: &Path,
    report_dir: &Path,
    data_root: &Path,
    schema: &str,
) -> Output {
    run(&[
        string_arg("--data-root"),
        string_arg(data_root),
        string_arg("bulk-import"),
        string_arg("--scan-root"),
        string_arg(corpus),
        string_arg("--map-file"),
        string_arg(map),
        string_arg("--report-dir"),
        string_arg(report_dir),
        string_arg("--source-schema"),
        string_arg(schema),
    ])
}

#[test]
fn dry_run_reports_oversized_title_and_body() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    let long_title = "t".repeat(501);
    let long_body = "b".repeat(1_048_600);
    write(
        &corpus.join("over").join("TASKS.md"),
        &format!("## Done\n### T-1 {long_title}\nshort\n### T-2 Beta\n{long_body}\n"),
    );
    let map = root.join("map.json");
    write(&map, "{\"sections\":{\"Done\":\"done\"}}");
    let report_dir = root.join("reports");
    let data_root = root.join("data");

    let output = bulk_dry_run(&corpus, &map, &report_dir, &data_root, "canonical");
    assert_eq!(
        output.status.code(),
        Some(2),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    assert_eq!(items.len(), 1);
    let candidate = &items[0];
    assert_eq!(candidate["bucket"], "unrecognized", "{candidate:#}");
    let title = problem(candidate, "501 characters");
    assert_eq!(title["task_id"], 1);
    assert_eq!(title["line"], 2);
    assert_eq!(title["file"], "over/TASKS.md");
    assert!(title["message"].as_str().unwrap().contains("500"));
    let body = problem(candidate, "1048600 bytes");
    assert_eq!(body["task_id"], 2);
    assert!(body["message"].as_str().unwrap().contains("1048576"));
    assert!(
        candidate["problems"].as_array().unwrap().len() >= 2,
        "both size problems must be reported in one run: {candidate:#}"
    );
    assert!(
        !data_root.exists(),
        "a dry run must not create the data root"
    );
}

#[test]
fn dry_run_reports_oversized_shared_rules() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    let prose = "r".repeat(300_000);
    write(
        &corpus.join("rules").join("TASKS.md"),
        &format!("## Notes\n{prose}\n## Done\n### T-1 Alpha\nbody\n"),
    );
    let map = root.join("map.json");
    write(&map, "{\"sections\":{\"Done\":\"done\"}}");
    let report_dir = root.join("reports");
    let data_root = root.join("data");

    let output = bulk_dry_run(&corpus, &map, &report_dir, &data_root, "canonical");
    assert_eq!(output.status.code(), Some(2), "{output:#?}");
    let items = candidates(&report_dir);
    let candidate = &items[0];
    assert_eq!(candidate["bucket"], "unrecognized");
    let rules = problem(candidate, "300000 bytes");
    assert!(rules["message"].as_str().unwrap().contains("262144"));
    assert_eq!(rules["file"], "rules/TASKS.md");
}

#[test]
fn dry_run_reports_cycles() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("deps").join("TASKS.md"),
        "## In Progress\n### T-1 Alpha\nDeps: T-2\n### T-2 Beta\nDeps: T-3\n### T-3 Gamma\nDeps: T-2\n",
    );
    let map = root.join("map.json");
    write(&map, "{\"sections\":{\"In Progress\":\"in-progress\"}}");
    let report_dir = root.join("reports");
    let data_root = root.join("data");

    let output = bulk_dry_run(&corpus, &map, &report_dir, &data_root, "create-task");
    assert_eq!(output.status.code(), Some(2), "{output:#?}");
    let items = candidates(&report_dir);
    let candidate = &items[0];
    assert_eq!(candidate["bucket"], "unrecognized");
    let cycle = problem(candidate, "dependency cycle");
    assert_eq!(cycle["group"], serde_json::json!([2, 3]));
    assert!(cycle["message"].as_str().unwrap().contains("T-003"));
    assert_eq!(
        candidate["problems"].as_array().unwrap().len(),
        1,
        "the cycle is the only problem: {candidate:#}"
    );
}

#[test]
fn dry_run_reports_canonical_dependency_duplicates_unknowns_self_links_and_cycles() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("canonical").join("TASKS.md"),
        "## in-progress\n\
         ### T-1 Alpha\nStatus: ready\nDepends on: T-2, T-2\nBody:\nbody one\n\
         ### T-2 Beta\nStatus: ready\nDepends on: T-9\nBody:\nbody two\n\
         ### T-3 Gamma\nStatus: ready\nDepends on: T-3\nBody:\nbody three\n\
         ### T-4 Delta\nStatus: ready\nDepends on: T-5\nBody:\nbody four\n\
         ### T-5 Epsilon\nStatus: ready\nDepends on: T-4\nBody:\nbody five\n",
    );
    let map = root.join("map.json");
    write(&map, "{\"sections\":{}}");
    let report_dir = root.join("reports");
    let data_root = root.join("data");

    let output = bulk_dry_run(&corpus, &map, &report_dir, &data_root, "canonical");
    assert_eq!(output.status.code(), Some(2), "{output:#?}");
    let items = candidates(&report_dir);
    let candidate = &items[0];
    assert_eq!(candidate["bucket"], "unrecognized", "{candidate:#}");
    let duplicate = problem(candidate, "more than once");
    assert_eq!(duplicate["task_id"], 1);
    assert_eq!(duplicate["file"], "canonical/TASKS.md");
    assert!(duplicate["line"].is_number());
    let unknown = problem(candidate, "in neither the import set");
    assert_eq!(unknown["task_id"], 2);
    assert!(unknown["message"].as_str().unwrap().contains("T-009"));
    let self_link = problem(candidate, "lists itself");
    assert_eq!(self_link["task_id"], 3);
    let cycle = problem(candidate, "dependency cycle");
    assert_eq!(cycle["group"], serde_json::json!([4, 5]));
    assert_eq!(
        candidate["problems"].as_array().unwrap().len(),
        4,
        "all four dependency problems must be reported in one run: {candidate:#}"
    );
}

#[test]
fn dry_run_reports_cross_file_duplicate_ids() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("dup").join("TASKS.md"),
        "## Done\n### T-1 Alpha\nbody\n",
    );
    write(
        &corpus.join("dup").join("TASKS.ARCHIVE.md"),
        "## Done\n### T-1 Alpha again\narchived\n",
    );
    let map = root.join("map.json");
    write(&map, "{\"sections\":{\"Done\":\"done\"}}");
    let report_dir = root.join("reports");
    let data_root = root.join("data");

    let output = bulk_dry_run(&corpus, &map, &report_dir, &data_root, "canonical");
    assert_eq!(output.status.code(), Some(2), "{output:#?}");
    let items = candidates(&report_dir);
    let candidate = &items[0];
    assert_eq!(candidate["bucket"], "unrecognized");
    let duplicate = problem(candidate, "also defined in");
    assert!(duplicate["message"].as_str().unwrap().contains("T-001"));
}

#[test]
fn single_file_import_preview_reports_a_non_empty_store_and_rules() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let data_root = root.join("data");
    let ledger = root.join("ledger.md");
    write(&ledger, "## done\n### T-1 Alpha\nbody\n");
    let body_file = root.join("body.md");
    write(&body_file, "existing body\n");

    let init = |name: &str| -> String {
        let project_root = root.join(name);
        fs::create_dir_all(&project_root).expect("project directory");
        let output = run(&[
            string_arg("--data-root"),
            string_arg(&data_root),
            string_arg("--format"),
            string_arg("json"),
            string_arg("init"),
            string_arg("--root"),
            string_arg(&project_root),
            string_arg("--key"),
            string_arg(if name == "project-tasks" { "PT" } else { "PR" }),
        ]);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let envelope: Value = serde_json::from_slice(&output.stdout).expect("init JSON");
        envelope["data"]["project_id"]
            .as_str()
            .expect("project id")
            .to_string()
    };
    let import_preview = |project: &str| -> Output {
        run(&[
            string_arg("--data-root"),
            string_arg(&data_root),
            string_arg("--project"),
            string_arg(project),
            string_arg("--format"),
            string_arg("json"),
            string_arg("import"),
            string_arg("--file"),
            string_arg(&ledger),
        ])
    };

    let project = init("project-tasks");
    let preview = import_preview(&project);
    assert_eq!(
        preview.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&preview.stderr)
    );
    let envelope: Value = serde_json::from_slice(&preview.stdout).expect("preview JSON");
    assert!(
        envelope["data"]["problems"].as_array().unwrap().is_empty(),
        "a fresh project has no store precondition problems: {envelope:#}"
    );

    let create = run(&[
        string_arg("--data-root"),
        string_arg(&data_root),
        string_arg("--project"),
        string_arg(&project),
        string_arg("create"),
        string_arg("--title"),
        string_arg("Existing task"),
        string_arg("--body-file"),
        string_arg(&body_file),
    ]);
    assert!(
        create.status.success(),
        "{}",
        String::from_utf8_lossy(&create.stderr)
    );
    let preview = import_preview(&project);
    let envelope: Value = serde_json::from_slice(&preview.stdout).expect("preview JSON");
    let text = messages(&envelope["data"]["problems"]);
    assert!(text.contains("already has 1 task(s)"), "{text}");
    assert!(text.contains(&project), "{text}");

    let rules_project = init("project-rules");
    let rules_file = root.join("rules.md");
    write(&rules_file, "existing shared rules\n");
    let rules_set = run(&[
        string_arg("--data-root"),
        string_arg(&data_root),
        string_arg("--project"),
        string_arg(&rules_project),
        string_arg("rules"),
        string_arg("set"),
        string_arg("--body-file"),
        string_arg(&rules_file),
        string_arg("--expect-version"),
        string_arg("1"),
    ]);
    assert!(
        rules_set.status.success(),
        "{}",
        String::from_utf8_lossy(&rules_set.stderr)
    );
    let preview = import_preview(&rules_project);
    let envelope: Value = serde_json::from_slice(&preview.stdout).expect("preview JSON");
    let text = messages(&envelope["data"]["problems"]);
    assert!(text.contains("already has rules"), "{text}");
    assert!(text.contains(&rules_project), "{text}");
}

#[test]
fn apply_rejects_the_same_oversized_fixture_the_preview_reported() {
    use tasks_cli::markdown;
    use tasks_cli::model::SourceSchema;
    use tasks_cli::store::{create_project_db, Store};
    use uuid::Uuid;

    let long_title = "t".repeat(501);
    let text = format!("## Done\n### T-1 {long_title}\nbody\n");
    let parsed = markdown::parse_with_schema(
        "over.md".to_string(),
        text.into_bytes(),
        None,
        SourceSchema::Canonical,
    )
    .expect("parse");
    let mut sources = vec![parsed];
    markdown::resolve_create_task_deps_across(&mut sources);
    let refs = sources.iter().collect::<Vec<_>>();
    let problems = tasks_cli::problems::analyze(&refs);
    let preview_message = problems
        .iter()
        .find(|problem| problem.message.contains("501 characters"))
        .expect("the preview reports the oversized title")
        .message
        .clone();

    let root = tempfile::tempdir().expect("temp");
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).expect("database");
    let mut store = Store::open_rw(root.path(), &project.to_string()).expect("open");
    let hash = sources[0].source_hash.clone();
    let error = store
        .import_apply(sources.remove(0), Some(&hash))
        .expect_err("apply rejects the same fixture");
    assert!(
        error.to_string().contains(&preview_message),
        "apply error {error} must carry the preview message {preview_message:?}"
    );
}

#[test]
fn a_corpus_that_passes_the_dry_run_applies_and_verifies() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    let ledger = corpus.join("alpha").join("TASKS.md");
    write(
        &ledger,
        "## In Progress\n### T-1 Alpha\nbody one\n\n## Done\n### T-2 Beta\ndone two\n",
    );
    let original = fs::read(&ledger).expect("original bytes");
    let map = root.join("map.json");
    write(
        &map,
        "{\"sections\":{\"Done\":\"done\",\"In Progress\":\"in-progress\"}}",
    );
    let report_dir = root.join("reports");
    let data_root = root.join("data");
    let quarantine = root.join("quarantine");

    let output = bulk_dry_run(&corpus, &map, &report_dir, &data_root, "canonical");
    assert_eq!(output.status.code(), Some(0), "{output:#?}");
    let items = candidates(&report_dir);
    assert_eq!(items[0]["bucket"], "recognized");
    assert_eq!(items[0]["applied"], false);
    assert_eq!(
        items[0]["problems"].as_array().unwrap().len(),
        0,
        "{:#}",
        items[0]
    );

    let output = run(&[
        string_arg("--data-root"),
        string_arg(&data_root),
        string_arg("bulk-import"),
        string_arg("--scan-root"),
        string_arg(&corpus),
        string_arg("--map-file"),
        string_arg(&map),
        string_arg("--report-dir"),
        string_arg(&report_dir),
        string_arg("--apply"),
        string_arg("--quarantine-dir"),
        string_arg(&quarantine),
        string_arg("--key-map"),
        {
            let key_map = root.join("keys.json");
            write(&key_map, "{\"alpha\":\"ALPHA\"}");
            string_arg(&key_map)
        },
    ]);
    assert_eq!(
        output.status.code(),
        Some(0),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    assert_eq!(items[0]["applied"], true, "{:#}", items[0]);
    assert_eq!(items[0]["verified"], true, "{:#}", items[0]);
    assert!(!ledger.exists(), "the verified source was quarantined");
    let manifest: Value = serde_json::from_slice(
        &fs::read(report_dir.join("quarantine-manifest.json")).expect("manifest"),
    )
    .expect("manifest JSON");
    let entry = &manifest["entries"][0];
    assert_eq!(
        entry["sha256"],
        tasks_cli::markdown::sha256(&original),
        "the manifest must carry the original bytes hash"
    );
    assert_eq!(entry["size"], original.len() as u64);
}
