use serde_json::{json, Value};
use std::process::{Command, Output};
use tasks_cli::store::create_project_db;
use uuid::Uuid;

struct Fixture {
    temp: tempfile::TempDir,
    id: Uuid,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        create_project_db(temp.path(), &id).unwrap();
        std::fs::write(temp.path().join("body.md"), "ordinary body").unwrap();
        Self { temp, id }
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_tasks"))
            .args(["--format", "json", "--data-root"])
            .arg(self.temp.path())
            .arg("--project")
            .arg(self.id.to_string())
            .args(args)
            .current_dir(self.temp.path())
            .env_remove("TASKS_PROJECT")
            .env_remove("TASKS_WINDOWS_EXE")
            .output()
            .unwrap()
    }

    fn ok(&self, args: &[&str]) -> Value {
        let output = self.run(args);
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["data"].clone()
    }

    fn create(&self, title: &str, body: &str, labels: &str) -> Value {
        std::fs::write(self.temp.path().join("body.md"), body).unwrap();
        self.ok(&[
            "create",
            "--title",
            title,
            "--body-file",
            "body.md",
            "--labels",
            labels,
        ])
    }
}

#[test]
fn labels_are_normalized_filterable_and_versioned_with_full_history() {
    let f = Fixture::new();
    let created = f.create(
        "review",
        "initial content",
        "Security, needs-human,security",
    );
    let first_event = created["event_id"].as_u64().unwrap().to_string();
    assert_eq!(
        f.ok(&["show", "T-1"])["labels"],
        json!(["needs-human", "security"])
    );
    assert_eq!(
        f.ok(&["list", "--open", "--label", "SECURITY"])["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    f.ok(&[
        "update",
        "T-1",
        "--expect-version",
        "1",
        "--labels",
        "performance",
    ]);
    assert_eq!(
        f.run(&["update", "T-1", "--expect-version", "1", "--clear-labels"])
            .status
            .code(),
        Some(4)
    );
    let old = f.ok(&["history", "T-1", "--event", &first_event]);
    let snapshot = old["items"][0]["snapshot"].clone();
    assert_eq!(snapshot["labels"], json!(["needs-human", "security"]));
    assert_eq!(snapshot["body"], "initial content");
    assert!(f.ok(&["list", "--open", "--label", "security"])["items"]
        .as_array()
        .unwrap()
        .is_empty());
    let unchanged = f.ok(&[
        "update",
        "T-1",
        "--expect-version",
        "2",
        "--labels",
        "PERFORMANCE,performance",
    ]);
    assert_eq!(unchanged["version"], 2);
    assert!(unchanged["event_id"].is_null());
    f.ok(&["update", "T-1", "--expect-version", "2", "--clear-labels"]);
    assert_eq!(f.ok(&["show", "T-1"])["labels"], json!([]));
}

#[test]
fn ranked_word_and_prefix_search_rank_titles_and_paginate_without_id_skips() {
    let f = Fixture::new();
    f.create("background notes", "cache latency", "performance");
    f.create("cache latency", "ordinary body", "performance");
    f.create("cache only", "unrelated body", "security");
    let page = f.ok(&["search", "cache latency", "--ranked", "--limit", "1"]);
    assert_eq!(
        page["items"][0]["id"], 2,
        "title match should rank ahead of body-only match"
    );
    assert_eq!(page["next_offset"], 1);
    let next = f.ok(&[
        "search",
        "cache latency",
        "--ranked",
        "--limit",
        "1",
        "--offset",
        "1",
    ]);
    assert_eq!(next["items"][0]["id"], 1);
    assert_eq!(next["has_more"], false);
    assert!(next["next_offset"].is_null());
    let prefix = f.ok(&[
        "search",
        "cach lat",
        "--ranked",
        "--prefix",
        "--label",
        "performance",
    ]);
    assert_eq!(prefix["items"].as_array().unwrap().len(), 2);
    assert!(prefix["items"][0].get("body").is_none());
    assert_eq!(prefix["items"][0]["labels"], json!(["performance"]));
    assert_eq!(
        f.run(&["search", "cache", "--ranked", "--after", "1"])
            .status
            .code(),
        Some(2)
    );
}

#[test]
fn literal_search_remains_available_and_full_text_tracks_atomic_updates() {
    let f = Fixture::new();
    f.create("literal 100%_needle", "oldtoken", "security");
    assert_eq!(
        f.ok(&["search", "%_needle"])["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        f.ok(&["search", "oldtoken", "--ranked"])["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    std::fs::write(f.temp.path().join("new.md"), "newtoken").unwrap();
    assert_eq!(
        f.run(&[
            "update",
            "T-1",
            "--expect-version",
            "99",
            "--body-file",
            "new.md"
        ])
        .status
        .code(),
        Some(4)
    );
    assert!(f.ok(&["search", "newtoken", "--ranked"])["items"]
        .as_array()
        .unwrap()
        .is_empty());
    f.ok(&[
        "update",
        "T-1",
        "--expect-version",
        "1",
        "--body-file",
        "new.md",
    ]);
    assert!(f.ok(&["search", "oldtoken", "--ranked"])["items"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(
        f.ok(&["search", "newtoken", "--ranked", "--label", "security"])["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(
        f.ok(&["search", "newtoken", "--ranked", "--label", "performance"])["items"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(f.ok(&["search", "\" OR *", "--ranked"])["items"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn labels_survive_markdown_export_import_without_consuming_body_text() {
    let source = Fixture::new();
    source.create(
        "export me",
        "Labels: keep this prose\nnext line",
        "security,performance",
    );
    source.ok(&["export", "--out", "export.md"]);
    let target = Fixture::new();
    std::fs::copy(
        source.temp.path().join("export.md"),
        target.temp.path().join("import.md"),
    )
    .unwrap();
    let preview = target.ok(&["import", "--file", "import.md"]);
    let hash = preview["report"]["source_sha256"].as_str().unwrap();
    target.ok(&[
        "import",
        "--file",
        "import.md",
        "--apply",
        "--expect-sha256",
        hash,
    ]);
    let task = target.ok(&["show", "T-1"]);
    assert_eq!(task["labels"], json!(["performance", "security"]));
    assert!(task["body"]
        .as_str()
        .unwrap()
        .starts_with("Labels: keep this prose\nnext line"));
    assert_eq!(
        target.ok(&["search", "export", "--ranked"])["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn invalid_labels_and_empty_ranked_queries_fail_without_writes() {
    let f = Fixture::new();
    assert_eq!(
        f.run(&[
            "create",
            "--title",
            "bad",
            "--body-file",
            "body.md",
            "--labels",
            "contains spaces"
        ])
        .status
        .code(),
        Some(2)
    );
    assert!(f.ok(&["list"])["items"].as_array().unwrap().is_empty());
    assert_eq!(f.run(&["search", "   ", "--ranked"]).status.code(), Some(2));
}
