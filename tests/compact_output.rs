//! Token-efficient output contract: compact JSON, opt-in rules, multi-ID show,
//! lean history, trimmed text rows and label add/remove.

use serde_json::{json, Value};
use std::{fs, process::Command, process::Output};
use tasks_cli::store::create_project_db;
use tempfile::TempDir;
use uuid::Uuid;

struct Fixture {
    root: TempDir,
    id: Uuid,
}

impl Fixture {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        create_project_db(root.path(), &id).unwrap();
        fs::write(root.path().join("body.md"), "body text").unwrap();
        fs::write(root.path().join("rules.md"), "RULE-ONE: verify").unwrap();
        Self { root, id }
    }

    fn raw(&self, format: &str, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_tasks"))
            .args([
                "--data-root",
                self.root.path().to_str().unwrap(),
                "--project",
                &self.id.to_string(),
                "--format",
                format,
            ])
            .args(args)
            .output()
            .unwrap()
    }

    fn text(&self, args: &[&str]) -> String {
        let output = self.raw("text", args);
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }

    fn json_stdout(&self, args: &[&str]) -> String {
        let output = self.raw("json", args);
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }

    fn json(&self, args: &[&str]) -> Value {
        serde_json::from_str::<Value>(&self.json_stdout(args)).unwrap()["data"].clone()
    }

    fn body(&self) -> String {
        self.root
            .path()
            .join("body.md")
            .to_str()
            .unwrap()
            .to_string()
    }

    fn create(&self, title: &str, extra: &[&str]) -> u64 {
        let body = self.body();
        let mut args = vec!["create", "--title", title, "--body-file", body.as_str()];
        args.extend_from_slice(extra);
        self.json(&args)["id"].as_u64().unwrap()
    }

    fn set_rules(&self) {
        let rules = self.root.path().join("rules.md");
        self.json(&[
            "rules",
            "set",
            "--body-file",
            rules.to_str().unwrap(),
            "--expect-version",
            "1",
        ]);
    }
}

#[test]
fn json_output_is_one_compact_line() {
    let f = Fixture::new();
    f.create("alpha", &["--status", "todo"]);
    let stdout = f.json_stdout(&["list", "--open"]);
    assert_eq!(stdout.trim_end().lines().count(), 1, "{stdout}");
    assert!(!stdout.contains(": "), "no pretty-print spacing: {stdout}");
}

#[test]
fn show_omits_rules_and_duplicate_deps_unless_requested() {
    let f = Fixture::new();
    f.set_rules();
    let dep = f.create("dependency", &[]);
    let task = f.create("main", &["--deps", &format!("T-{dep}")]);
    let id = format!("T-{task}");

    let plain = f.json(&["show", &id]);
    assert_eq!(plain["command"], "show");
    assert!(plain.get("rules").is_none(), "{plain}");
    assert!(plain.get("rule_version").is_none(), "{plain}");
    assert!(plain.get("deps").is_none(), "{plain}");
    assert_eq!(plain["dependency_summaries"][0]["id"], dep);
    assert_eq!(plain["title"], "main");

    let with_rules = f.json(&["show", &id, "--rules"]);
    assert_eq!(with_rules["rules"], "RULE-ONE: verify");
    assert_eq!(with_rules["rule_version"], 2);

    let text = f.text(&["show", &id]);
    assert!(!text.contains("RULE-ONE"), "{text}");
    assert!(!text.contains("rules("), "{text}");
    assert!(!text.contains("dependencies:"), "{text}");
    assert!(!text.contains("project_id:"), "{text}");
    assert!(
        !text.contains("labels:"),
        "empty labels line omitted: {text}"
    );
    assert!(text.contains(&format!("depends_on: T-{dep:03}")), "{text}");

    let text = f.text(&["show", &id, "--rules"]);
    assert!(text.contains("rules(v2):\nRULE-ONE: verify"), "{text}");
}

#[test]
fn show_accepts_several_ids_and_prints_rules_once() {
    let f = Fixture::new();
    f.set_rules();
    let first = f.create("first", &[]);
    let second = f.create("second", &[]);
    let (a, b) = (format!("T-{first}"), format!("T-{second}"));

    let many = f.json(&["show", &b, &a, "--rules"]);
    assert_eq!(many["command"], "show_many");
    let titles: Vec<&str> = many["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["title"].as_str().unwrap())
        .collect();
    assert_eq!(titles, ["second", "first"], "requested order is kept");
    assert!(many["items"][0].get("rules").is_none());
    assert_eq!(many["rules"], "RULE-ONE: verify");
    assert_eq!(many["rule_version"], 2);

    let no_rules = f.json(&["show", &a, &b]);
    assert!(no_rules.get("rules").is_none(), "{no_rules}");

    let text = f.text(&["show", &a, &b, "--rules"]);
    assert_eq!(text.matches("RULE-ONE").count(), 1, "{text}");
    assert!(text.contains("id: T-001") && text.contains("id: T-002"));

    let missing = f.raw("text", &["show", &a, "T-99", "T-98"]);
    assert_eq!(missing.status.code(), Some(3));
    assert!(missing.stdout.is_empty(), "no partial output");
    let message = String::from_utf8_lossy(&missing.stderr);
    assert!(
        message.contains("T-099") && message.contains("T-098"),
        "{message}"
    );
}

#[test]
fn history_is_lean_and_reports_changed_fields() {
    let f = Fixture::new();
    let id = f.create("task", &["--status", "todo"]);
    let task = format!("T-{id}");
    let updated = f.json(&[
        "update",
        &task,
        "--expect-version",
        "1",
        "--status",
        "done",
        "--labels",
        "x",
    ]);
    assert_eq!(updated["version"], 2);

    let history = f.json(&["history", &task]);
    let items = history["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    for item in items {
        assert!(item.get("task_id").is_none(), "{item}");
        assert!(item.get("entity_type").is_none(), "{item}");
        assert!(item.get("snapshot_json").is_none(), "{item}");
        assert!(item.get("snapshot").is_none(), "{item}");
    }
    assert!(
        items[0].get("changed_fields").is_none(),
        "create has no predecessor"
    );
    assert_eq!(items[1]["changed_fields"], json!(["status", "labels"]));

    let event = items[1]["event_id"].as_u64().unwrap().to_string();
    let selected = f.json(&["history", &task, "--event", &event]);
    let snapshot = &selected["items"][0]["snapshot"];
    assert!(snapshot.is_object(), "{selected}");
    assert_eq!(snapshot["status"], "done");
    assert_eq!(
        selected["items"][0]["changed_fields"],
        json!(["status", "labels"])
    );

    let text = f.text(&["history", &task]);
    assert!(text.contains("changed=status,labels"), "{text}");
}

#[test]
fn summary_rows_omit_empty_dependency_and_label_columns() {
    let f = Fixture::new();
    let plain = f.create("plain", &["--status", "todo"]);
    f.create(
        "tagged",
        &[
            "--status",
            "todo",
            "--labels",
            "a,b",
            "--deps",
            &format!("T-{plain}"),
        ],
    );
    let text = f.text(&["list", "--open"]);
    assert!(!text.contains("project_id:"), "{text}");
    assert!(!text.contains("[]"), "{text}");
    let tagged = text.lines().find(|line| line.contains("tagged")).unwrap();
    assert!(tagged.ends_with("\t[T-001]\tlabels=[a,b]"), "{tagged}");
    let plain_line = text.lines().find(|line| line.contains("plain")).unwrap();
    assert!(plain_line.ends_with("\tplain"), "{plain_line}");

    let doctor = f.text(&["doctor"]);
    assert_eq!(doctor.matches("project_id:").count(), 1, "{doctor}");
}

#[test]
fn update_adds_and_removes_labels_without_replacing_the_set() {
    let f = Fixture::new();
    let id = f.create("task", &["--labels", "keep,old"]);
    let task = format!("T-{id}");
    f.json(&[
        "update",
        &task,
        "--expect-version",
        "1",
        "--add-label",
        "New,extra",
        "--remove-label",
        "old",
    ]);
    assert_eq!(
        f.json(&["show", &task])["labels"],
        json!(["extra", "keep", "new"])
    );

    let noop = f.json(&[
        "update",
        &task,
        "--expect-version",
        "2",
        "--remove-label",
        "absent",
    ]);
    assert_eq!(noop["version"], 2);
    assert_eq!(noop["event_id"], Value::Null);

    let conflict = f.raw(
        "json",
        &[
            "update",
            &task,
            "--expect-version",
            "2",
            "--labels",
            "a",
            "--add-label",
            "b",
        ],
    );
    assert_eq!(conflict.status.code(), Some(2));
}

#[test]
fn history_tolerates_legacy_non_json_snapshots() {
    let f = Fixture::new();
    let id = f.create("task", &[]);
    let store = tasks_cli::store::Store::open_rw(f.root.path(), &f.id.to_string()).unwrap();
    store
        .conn
        .execute(
            "INSERT INTO events(task_id,entity_type,operation,resulting_version,created_ms,snapshot_json)
             VALUES (?1,'task','update',1,0,'legacy text')",
            [id as i64],
        )
        .unwrap();
    drop(store);
    let task = format!("T-{id}");
    let history = f.json(&["history", &task]);
    let legacy = &history["items"][1];
    assert!(legacy.get("changed_fields").is_none(), "{history}");
    let event = legacy["event_id"].as_u64().unwrap().to_string();
    let selected = f.json(&["history", &task, "--event", &event]);
    assert_eq!(selected["items"][0]["snapshot"], "legacy text");
}
