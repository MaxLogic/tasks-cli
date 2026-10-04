mod support;
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

const MAP_TEMPLATE: &str = r#"{"sections":{"In Progress":"in-progress","Blocked":"blocked","Done":"done","Next - Today":"ready","Next - This Week":"ready","Next - Later":"backlog","Next _EN_ Today":"ready","Next _EN_ This Week":"ready","Next _EN_ Later":"backlog","Ongoing":"in-progress"},"section_patterns":[{"pattern":"^\\d{4}-\\d{2}-\\d{2}","status":"done"}]}"#;

fn write(path: &Path, contents: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("parent directory");
    }
    fs::write(path, contents).expect("fixture file");
}

fn write_map(path: &Path) {
    write(path, &MAP_TEMPLATE.replace("_EN_", "\u{2013}"));
}

fn string_arg(path: &Path) -> String {
    path.to_str().expect("UTF-8 path").to_string()
}

fn run(args: &[&str]) -> std::process::Output {
    let mut args = args.iter().map(|arg| arg.to_string()).collect::<Vec<_>>();
    // Apply runs need a key per new project. These tests are about other
    // behavior, so give every ledger directory under the scan root a key
    // unless the test passes its own --key-map; tests/project_keys.rs covers
    // missing and conflicting keys.
    if args.iter().any(|arg| arg == "--apply") && !args.iter().any(|arg| arg == "--key-map") {
        if let Some(position) = args.iter().position(|arg| arg == "--scan-root") {
            let scan_root = Path::new(&args[position + 1]).to_path_buf();
            let key_map = scan_root
                .parent()
                .unwrap_or(&scan_root)
                .join(format!("generated-keys-{}.json", std::process::id()));
            write_generated_key_map(&scan_root, &key_map);
            args.push("--key-map".to_string());
            args.push(string_arg(&key_map));
        }
    }
    support::process::command(env!("CARGO_BIN_EXE_tasks"))
        .args(&args)
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .output()
        .expect("tasks executable")
}

/// Maps every directory holding a ledger below `scan_root` to a distinct key.
fn write_generated_key_map(scan_root: &Path, key_map: &Path) {
    fn walk(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        let mut has_ledger = false;
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if kind.is_dir() {
                walk(&path, out);
            } else if matches!(
                path.file_name().and_then(|name| name.to_str()),
                Some("TASKS.md" | "TASKS.ARCHIVE.md")
            ) {
                has_ledger = true;
            }
        }
        if has_ledger {
            out.push(dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf()));
        }
    }
    let mut dirs = Vec::new();
    walk(scan_root, &mut dirs);
    let mut map = serde_json::Map::new();
    for (index, dir) in dirs.iter().enumerate() {
        map.insert(string_arg(dir), Value::String(format!("K{index}")));
    }
    write(key_map, &Value::Object(map).to_string());
}

fn candidates(report_dir: &Path) -> Vec<Value> {
    let text = fs::read_to_string(report_dir.join("run.jsonl")).expect("run.jsonl");
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).expect("candidate JSON"))
        .collect()
}

fn candidate<'a>(items: &'a [Value], relative: &str) -> &'a Value {
    items
        .iter()
        .find(|item| item["relative_directory"] == relative)
        .unwrap_or_else(|| panic!("candidate {relative} is missing: {items:#?}"))
}

fn section_status(candidate: &Value, relative_file: &str, heading: &str) -> Value {
    let files = candidate["files"].as_array().expect("files");
    let file = files
        .iter()
        .find(|file| file["relative_path"] == relative_file)
        .unwrap_or_else(|| panic!("file {relative_file} is missing"));
    let sections = file["preview"]["sections"].as_array().expect("sections");
    sections
        .iter()
        .find(|section| section["heading"] == heading)
        .unwrap_or_else(|| panic!("section {heading} is missing in {relative_file}"))["status"]
        .clone()
}

fn snapshot(root: &Path, skip: &Path) -> BTreeMap<String, (u64, String)> {
    let mut files = BTreeMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(&dir).expect("read_dir") {
            let entry = entry.expect("entry");
            let path = entry.path();
            let file_type = entry.file_type().expect("file type");
            if file_type.is_symlink() || path == skip {
                continue;
            }
            if file_type.is_dir() {
                stack.push(path);
                continue;
            }
            let bytes = fs::read(&path).expect("snapshot read");
            let relative = path
                .strip_prefix(root)
                .expect("relative path")
                .to_string_lossy()
                .replace('\\', "/");
            files.insert(
                relative,
                (bytes.len() as u64, tasks_cli::markdown::sha256(&bytes)),
            );
        }
    }
    files
}

fn make_directory_link(target: &Path, link: &Path) -> bool {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link).is_ok()
    }
    #[cfg(windows)]
    {
        let output = support::process::command("cmd")
            .args(["/c", "mklink", "/J"])
            .arg(link)
            .arg(target)
            .output()
            .expect("mklink");
        output.status.success()
    }
}

fn fixture_corpus(corpus: &Path) {
    write(
        &corpus.join("alpha").join("TASKS.md"),
        "## Summary\nprose only, no task headings in this section\n## Ongoing\n### T-1 Alpha\nbody one\n\n## Next - Today\n### T-2 Beta\nbody two\n## Next \u{2013} This Week\n### T-3 Gamma\nbody three\n",
    );
    write(
        &corpus.join("alpha").join("TASKS.ARCHIVE.md"),
        "## Done\n### T-4 Delta\nfinished\n## 2026-01-02 release\n### T-5 Epsilon\narchived\n",
    );
    write(
        &corpus.join("alpha").join("AGENTS.md"),
        "# guide\nRead TASKS.md before working.\nno reference here\nThen update TASKS.md.\n",
    );
    write(
        &corpus.join("beta").join("TASKS.md"),
        "## Next - Later\n### T-1 Zeta\nlater\n",
    );
    write(
        &corpus.join("bom").join("TASKS.md"),
        "\u{feff}## In Progress\n### T-1 Eta\nbom body\n",
    );
    write(
        &corpus.join("nested").join("TASKS.md"),
        "## Next - Today\n### T-1 Theta\ntop level\n",
    );
    write(
        &corpus.join("nested").join("backend").join("TASKS.md"),
        "## Next - Today\n### T-1 Iota\nbackend\n",
    );
    write(
        &corpus
            .join("nested")
            .join("frontend")
            .join("TASKS.ARCHIVE.md"),
        "## Done\n### T-1 Kappa\nfront end\n",
    );
    write(
        &corpus.join("--maxTdb").join("TASKS.md"),
        "## Next - Today\n### T-1 Lambda\nflag shaped directory\n",
    );
    write(
        &corpus.join("mystery").join("TASKS.md"),
        "## Weird\n### T-1 Mu\nunmapped\n",
    );
}

#[test]
fn dry_run_classifies_the_fixture_corpus_and_writes_only_inside_the_report_dir() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    fs::create_dir_all(&corpus).expect("corpus");
    fixture_corpus(&corpus);
    let outside = root.join("outside");
    write(
        &outside.join("TASKS.md"),
        "## Next - Today\n### T-1 Outside\nmust not be scanned\n",
    );
    assert!(
        make_directory_link(&outside, &corpus.join("linked-outside")),
        "could not create the out-of-root directory link"
    );
    let map = root.join("map.json");
    write_map(&map);
    let report_dir = root.join("reports");
    let data_root = root.join("data");
    let quarantine = root.join("quarantine");

    let before = snapshot(root, &report_dir);
    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--exclude",
        "beta/**",
        "--quarantine-dir",
        &string_arg(&quarantine),
    ]);
    assert_eq!(
        output.status.code(),
        Some(2),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("1 candidate(s) were not migrated"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let after = snapshot(root, &report_dir);
    assert_eq!(
        before, after,
        "dry run changed bytes outside the report dir"
    );
    assert!(!data_root.exists(), "dry run created the data root");
    assert!(
        !quarantine.exists(),
        "dry run created the quarantine directory"
    );

    let items = candidates(&report_dir);
    let names = items
        .iter()
        .map(|item| {
            item["relative_directory"]
                .as_str()
                .unwrap_or_default()
                .to_string()
        })
        .collect::<Vec<_>>();
    assert_eq!(
        names,
        vec![
            "--maxTdb",
            "alpha",
            "beta",
            "bom",
            "mystery",
            "nested",
            "nested/backend",
            "nested/frontend"
        ],
        "{items:#?}"
    );
    for item in &items {
        assert!(
            !item["directory"]
                .as_str()
                .unwrap_or_default()
                .contains("outside"),
            "the out-of-root link target was scanned: {item}"
        );
    }
    assert_eq!(candidate(&items, "alpha")["bucket"], "recognized");
    assert_eq!(candidate(&items, "beta")["bucket"], "excluded");
    assert_eq!(
        candidate(&items, "bom")["bucket"],
        "recognized-with-warnings"
    );
    assert_eq!(candidate(&items, "mystery")["bucket"], "unrecognized");
    assert_eq!(candidate(&items, "--maxTdb")["bucket"], "recognized");
    assert_eq!(candidate(&items, "nested/backend")["bucket"], "recognized");
    assert_eq!(candidate(&items, "nested/frontend")["bucket"], "recognized");

    let alpha = candidate(&items, "alpha");
    assert_eq!(alpha["task_count"], 5);
    assert_eq!(
        section_status(alpha, "alpha/TASKS.md", "Next - Today"),
        "todo"
    );
    assert_eq!(
        section_status(alpha, "alpha/TASKS.md", "Next \u{2013} This Week"),
        "todo"
    );
    assert_eq!(
        section_status(alpha, "alpha/TASKS.md", "Ongoing"),
        "in-progress"
    );
    let summary_section = alpha["files"]
        .as_array()
        .expect("files")
        .iter()
        .find(|file| file["relative_path"] == "alpha/TASKS.md")
        .expect("alpha ledger")["preview"]["sections"]
        .as_array()
        .expect("sections")
        .iter()
        .find(|section| section["heading"] == "Summary")
        .expect("Summary section")
        .clone();
    assert_eq!(summary_section["status"], Value::Null);
    assert_eq!(summary_section["contains_tasks"], false);
    assert_eq!(
        section_status(alpha, "alpha/TASKS.ARCHIVE.md", "2026-01-02 release"),
        "done"
    );
    assert_eq!(
        section_status(alpha, "alpha/TASKS.ARCHIVE.md", "Done"),
        "done"
    );

    let bom = candidate(&items, "bom");
    assert_eq!(bom["files"][0]["has_bom"], true);
    assert!(
        bom["warnings"][0]
            .as_str()
            .unwrap_or_default()
            .contains("BOM"),
        "{bom}"
    );

    let nested = candidate(&items, "nested");
    let backend = candidate(&items, "nested/backend");
    let frontend = candidate(&items, "nested/frontend");
    assert_ne!(nested["project_id"], backend["project_id"]);
    assert_ne!(nested["project_id"], frontend["project_id"]);
    assert_ne!(backend["project_id"], frontend["project_id"]);
    assert_eq!(nested["task_count"], 1);
    let ids = items
        .iter()
        .map(|item| item["project_id"].as_str().unwrap_or_default().to_string())
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(ids.len(), items.len(), "project UUIDs are not distinct");

    let mystery = candidate(&items, "mystery");
    let reason = mystery["reason"].as_str().expect("reason");
    assert!(reason.contains("mystery/TASKS.md"), "{reason}");
    assert!(reason.contains("'Weird'"), "{reason}");
    assert!(reason.contains("no status mapping"), "{reason}");

    let quarantine_records = alpha["quarantine"].as_array().expect("quarantine");
    assert_eq!(quarantine_records.len(), 2);
    for record in quarantine_records {
        assert_eq!(record["status"], "planned");
        assert!(
            record["destination"]
                .as_str()
                .unwrap_or_default()
                .starts_with(&string_arg(&quarantine)),
            "{record}"
        );
    }
    assert_eq!(alpha["applied"], false);
    assert_eq!(alpha["verified"], false);

    let references = alpha["ledger_references"].as_array().expect("references");
    let agents = references
        .iter()
        .find(|reference| reference["relative_path"] == "AGENTS.md")
        .expect("AGENTS.md reference");
    assert_eq!(agents["lines"], serde_json::json!([2, 4]));

    let excluded_paths = fs::read_to_string(report_dir.join("summary.md")).expect("summary");
    assert!(
        excluded_paths.contains("[link] linked-outside"),
        "{excluded_paths}"
    );
    assert!(
        excluded_paths.contains("[file] beta/TASKS.md"),
        "{excluded_paths}"
    );
    let unrecognized =
        fs::read_to_string(report_dir.join("unrecognized.md")).expect("unrecognized");
    assert!(unrecognized.contains("mystery/TASKS.md"), "{unrecognized}");
    assert!(unrecognized.contains("'Weird'"), "{unrecognized}");
    assert!(
        unrecognized.contains("expected a literal sections entry"),
        "{unrecognized}"
    );
    assert!(unrecognized.contains("beta/TASKS.md"), "{unrecognized}");
}

#[test]
fn dash_spellings_dated_archives_and_prose_sections_resolve() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("one").join("TASKS.md"),
        "## Notes\nprose without tasks\n## Ongoing\n### T-1 A\nbody\n## Next - Today\n### T-2 B\nbody\n## Next \u{2013} Later\n### T-3 C\nbody\n",
    );
    write(
        &corpus.join("one").join("TASKS.ARCHIVE.md"),
        "## 2025-12-31 wrap up\n### T-4 D\nbody\n",
    );
    let map = root.join("map.json");
    write_map(&map);
    let report_dir = root.join("reports");
    let output = run(&[
        "--data-root",
        &string_arg(&root.join("data")),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
    ]);
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    let one = candidate(&items, "one");
    assert_eq!(one["bucket"], "recognized");
    assert_eq!(one["task_count"], 4);
    assert_eq!(
        section_status(one, "one/TASKS.md", "Ongoing"),
        "in-progress"
    );
    assert_eq!(section_status(one, "one/TASKS.md", "Next - Today"), "todo");
    assert_eq!(
        section_status(one, "one/TASKS.md", "Next \u{2013} Later"),
        "draft"
    );
    assert_eq!(section_status(one, "one/TASKS.md", "Notes"), Value::Null);
    assert_eq!(
        section_status(one, "one/TASKS.ARCHIVE.md", "2025-12-31 wrap up"),
        "done"
    );
}

#[test]
fn unmapped_task_section_lands_in_unrecognized_without_touching_the_store() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("mystery").join("TASKS.md"),
        "## Weird\n### T-1 Mu\nunmapped\n",
    );
    let map = root.join("map.json");
    write_map(&map);
    let report_dir = root.join("reports");
    let data_root = root.join("data");
    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--apply",
    ]);
    assert_eq!(
        output.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !data_root.exists(),
        "an unrecognized candidate must not create a project or a store"
    );
    let items = candidates(&report_dir);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["bucket"], "unrecognized");
    assert_eq!(items[0]["applied"], false);
    assert_eq!(items[0]["verified"], false);
}

#[test]
fn nested_ledgers_produce_three_projects_without_merging() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("tree").join("TASKS.md"),
        "## ready\n### T-10 Top\ntop body\n",
    );
    write(
        &corpus.join("tree").join("backend").join("TASKS.md"),
        "## ready\n### T-20 Backend\nbackend body\n",
    );
    write(
        &corpus.join("tree").join("frontend").join("TASKS.md"),
        "## ready\n### T-30 Frontend\nfrontend body\n",
    );
    let map = root.join("map.json");
    write(&map, "{}");
    let report_dir = root.join("reports");
    let output = run(&[
        "--data-root",
        &string_arg(&root.join("data")),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
    ]);
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    assert_eq!(items.len(), 3, "{items:#?}");
    let top = candidate(&items, "tree");
    let backend = candidate(&items, "tree/backend");
    let frontend = candidate(&items, "tree/frontend");
    assert_eq!(top["task_count"], 1);
    assert_eq!(backend["task_count"], 1);
    assert_eq!(frontend["task_count"], 1);
    assert_ne!(top["project_id"], backend["project_id"]);
    assert_ne!(top["project_id"], frontend["project_id"]);
}

#[test]
fn flag_named_directory_is_scanned_as_a_path() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("--maxTdb").join("TASKS.md"),
        "## ready\n### T-1 Flag\nflag shaped\n",
    );
    let map = root.join("map.json");
    write(&map, "{}");
    let report_dir = root.join("reports");
    let output = run(&[
        "--data-root",
        &string_arg(&root.join("data")),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
    ]);
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["relative_directory"], "--maxTdb");
    assert_eq!(items[0]["bucket"], "recognized");
    assert_eq!(items[0]["task_count"], 1);
}

#[test]
fn symlink_outside_the_scan_root_is_ignored() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("inside").join("TASKS.md"),
        "## ready\n### T-1 Inside\ninside\n",
    );
    let outside = root.join("outside");
    write(
        &outside.join("TASKS.md"),
        "## ready\n### T-2 Outside\noutside\n",
    );
    assert!(
        make_directory_link(&outside, &corpus.join("escape")),
        "could not create the out-of-root directory link"
    );
    let map = root.join("map.json");
    write(&map, "{}");
    let report_dir = root.join("reports");
    let output = run(&[
        "--data-root",
        &string_arg(&root.join("data")),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
    ]);
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    assert_eq!(items.len(), 1, "{items:#?}");
    assert_eq!(items[0]["relative_directory"], "inside");
    let summary = fs::read_to_string(report_dir.join("summary.md")).expect("summary");
    assert!(summary.contains("[link] escape"), "{summary}");
}

#[test]
fn apply_quarantines_sources_and_the_manifest_hashes_match() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    let ledger = corpus.join("alpha").join("TASKS.md");
    write(&ledger, "## ready\n### T-1 Alpha\nbody one\n");
    let archive = corpus.join("alpha").join("TASKS.ARCHIVE.md");
    write(&archive, "## done\n### T-2 Beta\nbody two\n");
    let ledger_bytes = fs::read(&ledger).expect("ledger bytes");
    let archive_bytes = fs::read(&archive).expect("archive bytes");
    let ledger_original = ledger
        .canonicalize()
        .expect("ledger canonical")
        .display()
        .to_string();
    let archive_original = archive
        .canonicalize()
        .expect("archive canonical")
        .display()
        .to_string();
    let map = root.join("map.json");
    write(&map, "{}");
    let report_dir = root.join("reports");
    let data_root = root.join("data");
    let quarantine = root.join("quarantine");
    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--apply",
        "--quarantine-dir",
        &string_arg(&quarantine),
    ]);
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !ledger.exists() && !archive.exists(),
        "verified sources must be moved into the quarantine directory"
    );
    let items = candidates(&report_dir);
    let alpha = candidate(&items, "alpha");
    assert_eq!(alpha["applied"], true);
    assert_eq!(alpha["verified"], true);
    assert_eq!(alpha["quarantined"], true);
    let project_id = alpha["project_id"]
        .as_str()
        .expect("project id")
        .to_string();

    let moved_ledger = quarantine.join("alpha").join("TASKS.md");
    let moved_archive = quarantine.join("alpha").join("TASKS.ARCHIVE.md");
    assert_eq!(fs::read(&moved_ledger).expect("moved ledger"), ledger_bytes);
    assert_eq!(
        fs::read(&moved_archive).expect("moved archive"),
        archive_bytes
    );

    let mut originals = BTreeMap::new();
    originals.insert(ledger_original, ledger_bytes.clone());
    originals.insert(archive_original, archive_bytes.clone());
    let manifest: Value = serde_json::from_slice(
        &fs::read(report_dir.join("quarantine-manifest.json")).expect("manifest bytes"),
    )
    .expect("manifest JSON");
    assert_eq!(manifest["format_version"], 1);
    let entries = manifest["entries"].as_array().expect("entries");
    assert_eq!(entries.len(), 2);
    for entry in entries {
        let original = entry["original_path"].as_str().expect("original path");
        let expected = originals
            .get(original)
            .unwrap_or_else(|| panic!("unexpected original path {original}"));
        assert_eq!(entry["sha256"], tasks_cli::markdown::sha256(expected));
        assert_eq!(entry["size"], expected.len() as u64);
        assert_eq!(entry["deleted"], false);
        assert_eq!(entry["project_id"], project_id);
        let destination = entry["destination"].as_str().expect("destination");
        assert_eq!(
            &fs::read(destination).expect("destination bytes"),
            expected,
            "quarantined copy does not match the original"
        );
    }

    let parsed = tasks_cli::markdown::parse("TASKS.md", ledger_bytes, None).expect("parse");
    let mut store = tasks_cli::store::Store::open_readonly(&data_root, &project_id).expect("store");
    for task in &parsed.tasks {
        let detail = store
            .show_task(&format!("T-{:03}", task.id))
            .expect("show task");
        assert_eq!(detail.title, task.title);
        assert_eq!(detail.body.as_bytes(), task.body.as_bytes());
    }
}

#[test]
fn report_directory_collisions_are_rejected_before_bulk_apply() {
    let temp = tempfile::tempdir().expect("temp");
    let corpus = temp.path().join("corpus");
    let source = corpus.join("alpha").join("TASKS.md");
    write(&source, "## ready\n### T-1 Alpha\nbody\n");
    let map = temp.path().join("map.json");
    write(&map, "{}");
    let report_dir = temp.path().join("reports");
    fs::create_dir_all(report_dir.join("summary.md")).expect("summary collision");
    let data_root = temp.path().join("data");
    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--apply",
    ]);
    assert_eq!(output.status.code(), Some(2), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("summary.md"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(source.exists(), "report collision moved the source");
    assert!(
        !data_root.exists(),
        "report collision created the data root"
    );
}

#[test]
fn existing_quarantine_manifest_is_preserved_and_blocks_apply() {
    let temp = tempfile::tempdir().expect("temp");
    let corpus = temp.path().join("corpus");
    let source = corpus.join("alpha").join("TASKS.md");
    write(&source, "## ready\n### T-1 Alpha\nbody\n");
    let map = temp.path().join("map.json");
    write(&map, "{}");
    let report_dir = temp.path().join("reports");
    fs::create_dir_all(&report_dir).expect("report dir");
    let manifest = report_dir.join("quarantine-manifest.json");
    let original = br#"{"audit":"keep me"}"#;
    fs::write(&manifest, original).expect("existing manifest");
    let data_root = temp.path().join("data");
    let quarantine = temp.path().join("quarantine");
    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--apply",
        "--quarantine-dir",
        &string_arg(&quarantine),
    ]);
    assert_eq!(output.status.code(), Some(2), "{output:?}");
    assert!(source.exists(), "manifest collision moved the source");
    assert!(
        !data_root.exists(),
        "manifest collision created the data root"
    );
    assert_eq!(fs::read(&manifest).expect("manifest bytes"), original);
}

#[test]
fn delete_quarantined_requires_apply_and_removes_the_copies() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    let ledger = corpus.join("alpha").join("TASKS.md");
    write(&ledger, "## ready\n### T-1 Alpha\nbody one\n");
    let map = root.join("map.json");
    write(&map, "{}");
    let report_dir = root.join("reports");
    let data_root = root.join("data");
    let quarantine = root.join("quarantine");

    let refusal = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--delete-quarantined",
        "--quarantine-dir",
        &string_arg(&quarantine),
    ]);
    assert_eq!(refusal.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&refusal.stderr).contains("--delete-quarantined requires --apply"),
        "{}",
        String::from_utf8_lossy(&refusal.stderr)
    );
    let refusal = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--apply",
        "--delete-quarantined",
    ]);
    assert_eq!(refusal.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&refusal.stderr)
            .contains("--delete-quarantined requires --quarantine-dir"),
        "{}",
        String::from_utf8_lossy(&refusal.stderr)
    );
    assert!(
        ledger.exists(),
        "a refused run must not move or delete anything"
    );
    assert!(!report_dir.exists(), "a refused run must not write reports");

    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--apply",
        "--quarantine-dir",
        &string_arg(&quarantine),
        "--delete-quarantined",
    ]);
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!ledger.exists(), "the source is moved before it is deleted");
    assert!(
        !quarantine.join("alpha").join("TASKS.md").exists(),
        "the quarantined copy is deleted afterwards"
    );
    let items = candidates(&report_dir);
    let alpha = candidate(&items, "alpha");
    assert_eq!(alpha["verified"], true);
    assert_eq!(alpha["quarantine"][0]["status"], "deleted");
    let manifest: Value = serde_json::from_slice(
        &fs::read(report_dir.join("quarantine-manifest.json")).expect("manifest bytes"),
    )
    .expect("manifest JSON");
    assert_eq!(manifest["delete_quarantined"], true);
    assert_eq!(manifest["entries"][0]["deleted"], true);
}

#[test]
fn bom_file_is_preserved_in_provenance() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    let ledger = corpus.join("bom").join("TASKS.md");
    write(&ledger, "\u{feff}## ready\n### T-1 Eta\nbom body\n");
    let original = fs::read(&ledger).expect("original bytes");
    assert_eq!(original[0..3], [0xef, 0xbb, 0xbf]);
    let map = root.join("map.json");
    write(&map, "{}");
    let report_dir = root.join("reports");
    let data_root = root.join("data");
    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--apply",
    ]);
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    let bom = candidate(&items, "bom");
    assert_eq!(bom["bucket"], "recognized-with-warnings");
    assert_eq!(bom["files"][0]["has_bom"], true);
    let project_id = bom["project_id"].as_str().expect("project id").to_string();
    let mut store = tasks_cli::store::Store::open_readonly(&data_root, &project_id).expect("store");
    let stored: Vec<u8> = store
        .conn
        .query_row("SELECT original_source FROM imports", [], |row| row.get(0))
        .expect("stored source");
    assert_eq!(stored, original, "provenance must keep the BOM bytes");
    assert_eq!(
        store.show_task("T-1").expect("task").title,
        "Eta",
        "the BOM must not leak into the title"
    );
}

#[test]
fn verification_failure_leaves_the_sources_in_place() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    let ledger = corpus.join("broken").join("TASKS.md");
    write(&ledger, "## ready\n### T-1 Alpha\nbody one\n");
    let map = root.join("map.json");
    write(&map, "{}");
    let report_dir = root.join("reports");
    let data_root = root.join("data");
    let quarantine = root.join("quarantine");
    let seed_project = seed_data_root(&data_root);
    let before = snapshot(&data_root, &report_dir);
    let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let output = support::process::command("cargo")
        .args([
            "run",
            "--quiet",
            "--locked",
            "--features",
            "test-hooks",
            "--bin",
            "tasks",
            "--",
            "--data-root",
        ])
        .arg(string_arg(&data_root))
        .args(["bulk-import", "--scan-root"])
        .arg(string_arg(&corpus))
        .args(["--map-file"])
        .arg(string_arg(&map))
        .args(["--report-dir"])
        .arg(string_arg(&report_dir))
        .args(["--apply", "--quarantine-dir"])
        .arg(string_arg(&quarantine))
        .arg("--key-map")
        .arg({
            let key_map = root.join("keys.json");
            write_generated_key_map(&corpus, &key_map);
            string_arg(&key_map)
        })
        .current_dir(&manifest_dir)
        .env("TASKS_TEST_BULK_FAIL_VERIFY", "1")
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .output()
        .expect("nested cargo run");
    assert_eq!(
        output.status.code(),
        Some(2),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("1 candidate(s) were not migrated"),
        "{stderr}"
    );
    assert!(
        ledger.exists(),
        "a failed verification must leave the source in place"
    );
    assert!(
        !quarantine.exists(),
        "nothing may be quarantined for a project that failed verification"
    );
    assert!(
        data_root.exists(),
        "the seeded data root must still exist after the rollback"
    );
    assert_eq!(
        snapshot(&data_root, &report_dir),
        before,
        "a rolled-back candidate must leave the registry and projects directory byte-identical"
    );
    let items = candidates(&report_dir);
    let broken = candidate(&items, "broken");
    assert_eq!(broken["applied"], true);
    assert_eq!(broken["verified"], false);
    assert_eq!(broken["rolled_back"], true);
    let broken_id = broken["project_id"].as_str().expect("project id");
    assert!(
        !data_root.join("projects").join(broken_id).exists(),
        "the rolled-back project directory must be gone"
    );
    let registry: Value =
        serde_json::from_slice(&fs::read(data_root.join("registry.json")).expect("registry"))
            .expect("registry JSON");
    let bindings = registry["bindings"].as_array().expect("bindings");
    assert!(
        bindings.iter().all(|binding| !binding["project_id"]
            .as_str()
            .unwrap_or_default()
            .eq_ignore_ascii_case(broken_id)),
        "the rolled-back binding must be gone: {registry}"
    );
    assert!(
        bindings.iter().any(|binding| binding["project_id"]
            .as_str()
            .unwrap_or_default()
            .eq_ignore_ascii_case(&seed_project)),
        "the pre-existing binding must remain: {registry}"
    );
    assert!(
        broken["verification_error"]
            .as_str()
            .unwrap_or_default()
            .contains("forced verification failure"),
        "{broken}"
    );
    let unrecognized =
        fs::read_to_string(report_dir.join("unrecognized.md")).expect("unrecognized");
    assert!(
        unrecognized.contains("verification failed"),
        "{unrecognized}"
    );
}

#[test]
fn create_task_strict_deps_block_every_real_corpus_form_with_the_fix_text() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("a-backticked-id").join("TASKS.md"),
        "## Next - Today\n### T-1 Alpha\nOutcome:\n- ok\nDeps: `T-27`\nbody one\n",
    );
    write(
        &corpus.join("a-backticked-id").join("TASKS.ARCHIVE.md"),
        "## Done\n### T-27 Watcher\nbody\n",
    );
    write(
        &corpus.join("b-project-name").join("TASKS.md"),
        "## Next - Today\n### T-1 Alpha\nDeps: `T-27`, MaxLogicFoundation `T-33`\nbody\n",
    );
    write(
        &corpus.join("b-project-name").join("TASKS.ARCHIVE.md"),
        "## Done\n### T-27 Watcher\nbody\n### T-33 Other project task\nbody\n",
    );
    write(
        &corpus.join("c-semicolon-prose").join("TASKS.md"),
        "## Next - Today\n### T-1 Alpha\nDeps: T-163; defect found during T-164 final review\nbody\n",
    );
    write(
        &corpus.join("c-semicolon-prose").join("TASKS.ARCHIVE.md"),
        "## Done\n### T-163 Watcher\nbody\n### T-164 Reviewer\nbody\n",
    );
    write(
        &corpus.join("d-range-prose").join("TASKS.md"),
        "## Next - Today\n### T-1 Alpha\nDeps: T-2 through T-13, plus any owner-specific fix task created by T-13\nbody\n",
    );
    write(
        &corpus.join("d-range-prose").join("TASKS.ARCHIVE.md"),
        "## Done\n### T-2 Spanner\nbody\n### T-13 Fixes\nbody\n",
    );
    write(
        &corpus.join("e-prose-only").join("TASKS.md"),
        "## Next - Today\n### T-1 Alpha\nDeps: existing source-context mapping\nbody\n",
    );
    write(
        &corpus.join("f-trailing-comma").join("TASKS.md"),
        "## Next - Today\n### T-1 Alpha\nDeps: T-2,\nbody\n",
    );
    write(
        &corpus.join("f-trailing-comma").join("TASKS.ARCHIVE.md"),
        "## Done\n### T-2 Beta\nbody\n",
    );
    write(
        &corpus.join("g-second-line").join("TASKS.md"),
        "## Next - Today\n### T-1 Alpha\nDeps: T-2\nDeps: T-3\nbody\n",
    );
    write(
        &corpus.join("g-second-line").join("TASKS.ARCHIVE.md"),
        "## Done\n### T-2 Beta\nbody\n### T-3 Gamma\nbody\n",
    );
    let map = root.join("map.json");
    write_map(&map);
    let report_dir = root.join("reports");
    let data_root = root.join("data");

    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--source-schema",
        "create-task",
    ]);
    assert_eq!(
        output.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    assert_eq!(items.len(), 7, "{items:#?}");
    let expectations = [
        ("a-backticked-id", "`T-27`", serde_json::json!([27]), 5usize),
        (
            "b-project-name",
            "`T-27`, MaxLogicFoundation `T-33`",
            serde_json::json!([27]),
            3,
        ),
        (
            "c-semicolon-prose",
            "T-163; defect found during T-164 final review",
            serde_json::json!([163]),
            3,
        ),
        (
            "d-range-prose",
            "T-2 through T-13, plus any owner-specific fix task created by T-13",
            serde_json::json!([]),
            3,
        ),
        (
            "e-prose-only",
            "existing source-context mapping",
            serde_json::json!([]),
            3,
        ),
        ("f-trailing-comma", "T-2,", serde_json::json!([2]), 3),
        ("g-second-line", "T-3", serde_json::json!([3]), 4),
    ];
    for (directory, value, keepable, line) in expectations {
        let item = candidate(&items, directory);
        assert_eq!(item["bucket"], "unrecognized", "{item:#?}");
        assert_eq!(item["problem_counts"]["nonconforming_deps"], 1, "{item:#?}");
        let problems = item["problems"].as_array().expect("problems");
        let problem = problems
            .iter()
            .find(|problem| problem["kind"] == "nonconforming-deps")
            .unwrap_or_else(|| panic!("nonconforming problem in {item:#?}"));
        assert_eq!(problem["value"], value, "{problem:#?}");
        assert_eq!(problem["keepable_ids"], keepable, "{problem:#?}");
        let message = problem["message"].as_str().expect("message");
        assert!(message.contains(&format!("line {line}")), "{message}");
        assert!(
            message.contains(
                "keep only these IDs in Deps and move the rest of the original text to Notes"
            ),
            "{message}"
        );
    }
    let summary = fs::read_to_string(report_dir.join("summary.md")).expect("summary");
    assert!(
        summary.contains("1 problem(s): 1 nonconforming Deps"),
        "{summary}"
    );
    let unrecognized =
        fs::read_to_string(report_dir.join("unrecognized.md")).expect("unrecognized");
    assert!(
        unrecognized.contains("keep only these IDs in Deps"),
        "{unrecognized}"
    );
}

#[test]
fn create_task_id_only_deps_create_edges_and_unknown_ids_block() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("good").join("TASKS.md"),
        "## Next - Today\n### T-1 Alpha\nDeps: T-2, T-3\nbody one\n",
    );
    write(
        &corpus.join("good").join("TASKS.ARCHIVE.md"),
        "## Done\n### T-2 Beta\nbody two\n### T-3 Gamma\nbody three\n",
    );
    write(
        &corpus.join("unknown").join("TASKS.md"),
        "## Next - Today\n### T-1 Alpha\nDeps: T-2, T-99\nbody\n",
    );
    write(
        &corpus.join("unknown").join("TASKS.ARCHIVE.md"),
        "## Done\n### T-2 Beta\nbody two\n",
    );
    let map = root.join("map.json");
    write_map(&map);
    let report_dir = root.join("reports");
    let data_root = root.join("data");

    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--source-schema",
        "create-task",
        "--apply",
        "--allow-partial",
    ]);
    assert_eq!(
        output.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    let good = candidate(&items, "good");
    assert_eq!(good["bucket"], "recognized", "{good:#?}");
    assert_eq!(good["applied"], true, "{good:#?}");
    assert_eq!(good["verified"], true, "{good:#?}");
    let project_id = good["project_id"].as_str().expect("project id");
    let mut store = tasks_cli::store::Store::open_readonly(&data_root, project_id).expect("store");
    assert_eq!(store.show_task("T-1").expect("T-1").deps, vec![2, 3]);

    let unknown = candidate(&items, "unknown");
    assert_eq!(unknown["bucket"], "unrecognized", "{unknown:#?}");
    assert_eq!(unknown["applied"], false, "{unknown:#?}");
    assert_eq!(unknown["problem_counts"]["unknown_ids"], 1, "{unknown:#?}");
    let problems = unknown["problems"].as_array().expect("problems");
    let problem = problems
        .iter()
        .find(|problem| problem["kind"] == "unknown-dependency")
        .unwrap_or_else(|| panic!("unknown-dependency problem in {unknown:#?}"));
    let message = problem["message"].as_str().expect("message");
    assert!(
        message.contains("remove T-099 from Deps; no such task exists"),
        "{message}"
    );
    assert!(message.contains("line 3"), "{message}");
}

#[test]
fn create_task_reports_every_cycle_group_in_one_run() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("cycles").join("TASKS.md"),
        "## In Progress\n### T-1 Alpha\nDeps: T-2\n### T-2 Beta\nDeps: T-1\n### T-8 Eta\nDeps: T-9\n### T-9 Theta\nDeps: T-8\n",
    );
    write(
        &corpus.join("cycles").join("TASKS.ARCHIVE.md"),
        "## Done\n### T-20 Done task\nbody\n",
    );
    write(
        &corpus.join("unknown-and-cycle").join("TASKS.md"),
        "## In Progress\n### T-1 Alpha\nDeps: T-99\n### T-2 Beta\nDeps: T-3\n### T-3 Gamma\nDeps: T-2\n",
    );
    let map = root.join("map.json");
    write_map(&map);
    let report_dir = root.join("reports");
    let data_root = root.join("data");

    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--source-schema",
        "create-task",
    ]);
    assert_eq!(
        output.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    let cycles = candidate(&items, "cycles");
    assert_eq!(cycles["bucket"], "unrecognized", "{cycles:#?}");
    assert_eq!(cycles["problem_counts"]["cycle_groups"], 2, "{cycles:#?}");
    let problems = cycles["problems"].as_array().expect("problems");
    let groups = problems
        .iter()
        .filter(|problem| problem["kind"] == "cycle")
        .map(|problem| problem["group"].clone())
        .collect::<Vec<_>>();
    assert!(
        groups.contains(&serde_json::json!([1, 2])) && groups.contains(&serde_json::json!([8, 9])),
        "{problems:#?}"
    );
    let first = problems
        .iter()
        .find(|problem| problem["kind"] == "cycle")
        .expect("cycle problem");
    let message = first["message"].as_str().expect("message");
    assert!(message.contains("cycles/TASKS.md:"), "{message}");
    assert!(message.contains("Deps: T-"), "{message}");
    assert!(message.contains("cycle group of 2 task(s)"), "{message}");

    let mixed = candidate(&items, "unknown-and-cycle");
    assert_eq!(mixed["problem_counts"]["unknown_ids"], 1, "{mixed:#?}");
    assert_eq!(mixed["problem_counts"]["cycle_groups"], 1, "{mixed:#?}");
    let summary = fs::read_to_string(report_dir.join("summary.md")).expect("summary");
    assert!(
        summary
            .contains("2 problem(s): 0 nonconforming Deps, 0 unknown IDs, 2 cycle groups, 0 other"),
        "{summary}"
    );
}

#[test]
fn unmarked_ledger_without_a_done_section_is_legacy_compatible() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("legacy").join("TASKS.md"),
        "## In Progress\n### T-1 Alpha\nbody one\n",
    );
    write(
        &corpus.join("marked").join("TASKS.md"),
        "Task schema: 1\n\n# Example ledger\n\n## In Progress\n### T-1 Beta\nbody two\n",
    );
    let map = root.join("map.json");
    write_map(&map);
    let report_dir = root.join("reports");
    let data_root = root.join("data");

    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--source-schema",
        "create-task",
    ]);
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    let legacy = candidate(&items, "legacy");
    assert_eq!(legacy["bucket"], "recognized", "{legacy:#?}");
    let legacy_file = &legacy["files"][0];
    assert_eq!(
        legacy_file["schema_class"], "legacy-compatible",
        "{legacy:#?}"
    );
    assert_eq!(legacy_file["has_schema_marker"], false, "{legacy:#?}");
    let marked = candidate(&items, "marked");
    assert_eq!(
        marked["files"][0]["schema_class"], "schema-1",
        "{marked:#?}"
    );
    let summary = fs::read_to_string(report_dir.join("summary.md")).expect("summary");
    assert!(summary.contains("schema=legacy-compatible"), "{summary}");
    assert!(summary.contains("schema=schema-1"), "{summary}");
}

#[test]
fn default_status_resolution_of_a_task_section_is_a_warning() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("endash").join("TASKS.md"),
        "## Next \u{2013} Today\n### T-1 Alpha\nopen work\n",
    );
    write(
        &corpus.join("prose").join("TASKS.md"),
        "## Summary\nprose only, no task headings here\n## backlog\n### T-1 Beta\nbacklog work\n",
    );
    let map = root.join("map.json");
    write(
        &map,
        r#"{"sections":{"Next - Today":"ready","Next - This Week":"ready","Next - Later":"backlog"},"default_status":"done"}"#,
    );
    let report_dir = root.join("reports");
    let data_root = root.join("data");

    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--source-schema",
        "create-task",
    ]);
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    let endash = candidate(&items, "endash");
    assert_eq!(endash["bucket"], "recognized-with-warnings", "{endash:#?}");
    let warnings = endash["warnings"].as_array().expect("warnings");
    assert_eq!(warnings.len(), 1, "{warnings:#?}");
    let warning = warnings[0].as_str().expect("warning text");
    assert!(warning.contains("endash/TASKS.md"), "{warning}");
    assert!(warning.contains("Next \u{2013} Today"), "{warning}");
    assert!(warning.contains("done"), "{warning}");
    let files = endash["files"].as_array().expect("files");
    assert_eq!(files[0]["preview"]["tasks"][0]["status"], "done");
    assert_eq!(files[0]["preview"]["sections"][0]["status"], "done");

    let prose = candidate(&items, "prose");
    assert_eq!(prose["bucket"], "recognized", "{prose:#?}");
    assert!(
        prose["warnings"].as_array().expect("warnings").is_empty(),
        "a section that holds no tasks must not warn: {prose:#?}"
    );
}

#[test]
fn create_task_ledger_markup_is_structural_and_arbitrary_prose_still_blocks() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("markup").join("TASKS.md"),
        "# Project notes\nArchived from TASKS.md.\nTask schema: 1\nNext task ID: T-2\n## backlog\n### T-1 Alpha\nbody one\n",
    );
    write(
        &corpus.join("prose").join("TASKS.md"),
        "## backlog\nsome prose line that is not ledger markup\n### T-1 Beta\nbody two\n",
    );
    let map = root.join("map.json");
    write(&map, "{}");
    let report_dir = root.join("reports");
    let data_root = root.join("data");

    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--source-schema",
        "create-task",
    ]);
    assert_eq!(
        output.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let items = candidates(&report_dir);
    let markup = candidate(&items, "markup");
    assert_eq!(markup["bucket"], "recognized", "{markup:#?}");
    assert!(
        markup["reasons"].as_array().expect("reasons").is_empty(),
        "{markup:#?}"
    );
    let prose = candidate(&items, "prose");
    assert_eq!(prose["bucket"], "unrecognized", "{prose:#?}");
    assert!(
        prose["reason"]
            .as_str()
            .unwrap_or_default()
            .contains("unassigned content"),
        "{prose:#?}"
    );
    assert!(
        prose["reason"]
            .as_str()
            .unwrap_or_default()
            .contains("some prose line that is not ledger markup"),
        "{prose:#?}"
    );
}

/// Create a data root that already holds one init'ed project, so a test can
/// prove that a refused or rolled-back run leaves the registry byte-identical.
fn seed_data_root(data_root: &Path) -> String {
    let seed = data_root.join("seed-project");
    fs::create_dir_all(&seed).expect("seed root");
    let output = run(&[
        "--data-root",
        &string_arg(data_root),
        "init",
        "--root",
        &string_arg(&seed),
        "--key",
        "SEED",
    ]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .find_map(|line| line.strip_prefix("project_id: ").map(str::to_string))
        .expect("seed project id")
}

/// A create-task ledger whose first task lists 1001 existing dependencies:
/// one over MAX_DEPENDENCIES (1000). The count problem must surface in the
/// preview and block apply with the task, file, line, count and limit.
fn write_oversized_dependency_ledger(path: &Path) {
    let mut ledger = String::from("## Next - Today\n### T-1 Alpha\nDeps: ");
    let deps = (2..=1002)
        .map(|id| format!("T-{id}"))
        .collect::<Vec<_>>()
        .join(", ");
    ledger.push_str(&deps);
    ledger.push_str("\nbody one\n");
    for id in 2..=1002 {
        ledger.push_str(&format!("### T-{id} Task {id}\nbody {id}\n"));
    }
    write(path, &ledger);
}

#[test]
fn strict_apply_refuses_the_whole_set_when_one_candidate_has_problems() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("good").join("TASKS.md"),
        "## Next - Today\n### T-1 Alpha\nbody one\n",
    );
    write_oversized_dependency_ledger(&corpus.join("broken").join("TASKS.md"));
    let map = root.join("map.json");
    write_map(&map);
    let report_dir = root.join("reports");
    let data_root = root.join("data");
    let quarantine = root.join("quarantine");
    let seed_project = seed_data_root(&data_root);
    let before = snapshot(&data_root, &report_dir);

    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--source-schema",
        "create-task",
        "--apply",
        "--quarantine-dir",
        &string_arg(&quarantine),
    ]);
    assert_eq!(
        output.status.code(),
        Some(2),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("bulk-import --apply refused"), "{stderr}");
    assert!(stderr.contains("nothing was written"), "{stderr}");
    assert!(stderr.contains("--allow-partial"), "{stderr}");
    assert!(
        stderr.contains("T-001 at broken/TASKS.md:3 has 1001 dependencies; the limit is 1000"),
        "{stderr}"
    );
    assert!(
        stderr.contains("Reduce the list or split the task"),
        "{stderr}"
    );

    assert_eq!(
        snapshot(&data_root, &report_dir),
        before,
        "a refused --apply must leave the registry and projects directory byte-identical"
    );
    assert!(
        !quarantine.exists(),
        "a refused run must not move or delete any source"
    );
    assert!(
        corpus.join("good").join("TASKS.md").exists()
            && corpus.join("broken").join("TASKS.md").exists(),
        "a refused run must leave every source in place"
    );
    let registry = fs::read_to_string(data_root.join("registry.json")).expect("registry");
    assert!(
        registry.contains(&seed_project),
        "the pre-existing binding must remain: {registry}"
    );
    let items = candidates(&report_dir);
    assert_eq!(candidate(&items, "good")["bucket"], "recognized");
    let broken = candidate(&items, "broken");
    assert_eq!(broken["bucket"], "unrecognized", "{broken:#?}");
    assert_eq!(broken["applied"], false, "{broken:#?}");
    assert_eq!(broken["verified"], false, "{broken:#?}");
    assert_eq!(broken["rolled_back"], false, "{broken:#?}");
    let problems = broken["problems"].as_array().expect("problems");
    assert!(
        problems.iter().any(|problem| problem["message"]
            .as_str()
            .unwrap_or_default()
            .contains("1001 dependencies; the limit is 1000")),
        "{broken:#?}"
    );
}

#[test]
fn allow_partial_applies_only_the_clean_candidates() {
    let temp = tempfile::tempdir().expect("temp");
    let root = temp.path();
    let corpus = root.join("corpus");
    write(
        &corpus.join("good").join("TASKS.md"),
        "## Next - Today\n### T-1 Alpha\nbody one\n",
    );
    write_oversized_dependency_ledger(&corpus.join("broken").join("TASKS.md"));
    let map = root.join("map.json");
    write_map(&map);
    let report_dir = root.join("reports");
    let data_root = root.join("data");
    let quarantine = root.join("quarantine");

    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--source-schema",
        "create-task",
        "--apply",
        "--allow-partial",
        "--quarantine-dir",
        &string_arg(&quarantine),
    ]);
    assert_eq!(
        output.status.code(),
        Some(2),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("1 candidate(s) were not migrated"),
        "{stderr}"
    );

    let items = candidates(&report_dir);
    let good = candidate(&items, "good");
    assert_eq!(good["applied"], true, "{good:#?}");
    assert_eq!(good["verified"], true, "{good:#?}");
    assert_eq!(good["rolled_back"], false, "{good:#?}");
    let good_id = good["project_id"].as_str().expect("project id");
    assert!(
        !corpus.join("good").join("TASKS.md").exists(),
        "a verified candidate is quarantined when --quarantine-dir is passed"
    );

    let broken = candidate(&items, "broken");
    assert_eq!(broken["bucket"], "unrecognized", "{broken:#?}");
    assert_eq!(broken["applied"], false, "{broken:#?}");
    let broken_id = broken["project_id"].as_str().expect("project id");
    assert!(
        !data_root.join("projects").join(broken_id).exists(),
        "an unrecognized candidate must get no project directory"
    );
    assert!(
        corpus.join("broken").join("TASKS.md").exists(),
        "an unrecognized candidate keeps its sources"
    );

    let registry: Value =
        serde_json::from_slice(&fs::read(data_root.join("registry.json")).expect("registry"))
            .expect("registry JSON");
    let bindings = registry["bindings"].as_array().expect("bindings");
    assert!(
        bindings.iter().any(|binding| binding["project_id"]
            .as_str()
            .unwrap_or_default()
            .eq_ignore_ascii_case(good_id)),
        "the applied candidate must be bound: {registry}"
    );
    assert!(
        bindings.iter().all(|binding| !binding["project_id"]
            .as_str()
            .unwrap_or_default()
            .eq_ignore_ascii_case(broken_id)),
        "the unrecognized candidate must not be bound: {registry}"
    );

    let mut store = tasks_cli::store::Store::open_readonly(&data_root, good_id).expect("store");
    assert_eq!(store.show_task("T-1").expect("T-1").title, "Alpha");
}

#[test]
fn strict_bulk_apply_rejects_duplicate_source_hashes_before_creating_a_project() {
    let temp = tempfile::tempdir().expect("temp");
    let corpus = temp.path().join("corpus");
    let bytes = "## Rules\nsame rules\n";
    write(&corpus.join("dupe").join("TASKS.md"), bytes);
    write(&corpus.join("dupe").join("TASKS.ARCHIVE.md"), bytes);
    let map = temp.path().join("map.json");
    write(&map, r#"{"sections":{"ready":"ready"}}"#);
    let report_dir = temp.path().join("reports");
    let data_root = temp.path().join("data");
    let output = run(&[
        "--data-root",
        &string_arg(&data_root),
        "bulk-import",
        "--scan-root",
        &string_arg(&corpus),
        "--map-file",
        &string_arg(&map),
        "--report-dir",
        &string_arg(&report_dir),
        "--apply",
    ]);
    assert_eq!(output.status.code(), Some(2), "{output:?}");
    let text = String::from_utf8_lossy(&output.stderr);
    assert!(text.contains("source SHA-256"), "{text}");
    assert!(!data_root.exists(), "strict duplicate refusal created data");
    assert!(corpus.join("dupe").join("TASKS.md").exists());
    assert!(corpus.join("dupe").join("TASKS.ARCHIVE.md").exists());
}
