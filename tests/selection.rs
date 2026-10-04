mod support;
use serde_json::{json, Value};
use std::fs;
use tasks_cli::{
    model::TaskStatus,
    store::{create_project_db, Store},
};
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
        fs::write(root.path().join("body.md"), "body").unwrap();
        Self { root, id }
    }
    fn run(&self, args: &[&str]) -> Value {
        let output = support::process::command(env!("CARGO_BIN_EXE_tasks"))
            .args([
                "--data-root",
                self.root.path().to_str().unwrap(),
                "--project",
                &self.id.to_string(),
                "--format",
                "json",
            ])
            .args(args)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["data"].clone()
    }
    fn add(&self, status: TaskStatus, deps: Vec<u64>, labels: Vec<String>) -> u64 {
        Store::open_rw(self.root.path(), &self.id.to_string())
            .unwrap()
            .create_task_with_labels("task", "body", status, deps, labels)
            .unwrap()
            .0
    }
}
fn ids(data: &Value) -> Vec<u64> {
    data["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["id"].as_u64().unwrap())
        .collect()
}

#[test]
fn default_selection_requires_done_dependencies_and_excludes_human_work() {
    let f = Fixture::new();
    f.add(TaskStatus::Backlog, vec![], vec![]); // 1
    f.add(TaskStatus::Ready, vec![], vec![]); // 2
    f.add(TaskStatus::InProgress, vec![], vec![]); // 3
    f.add(TaskStatus::Blocked, vec![], vec![]); // 4
    f.add(TaskStatus::Done, vec![], vec![]); // 5
    f.add(TaskStatus::Cancelled, vec![], vec![]); // 6
    f.add(TaskStatus::Ready, vec![5], vec![]); // 7
    f.add(TaskStatus::Ready, vec![6], vec![]); // 8
    f.add(TaskStatus::Ready, vec![2], vec![]); // 9
    f.add(TaskStatus::Ready, vec![], vec!["needs-human".into()]); // 10
    f.add(TaskStatus::Done, vec![], vec!["needs-human".into()]); // 11
    assert_eq!(ids(&f.run(&["list"])), [2, 3, 7]);
    assert_eq!(ids(&f.run(&["list", "--open"])), [1, 2, 3, 4, 7, 8, 9, 10]);
    assert_eq!(ids(&f.run(&["list", "--needs-human"])), [10]);
    assert_eq!(ids(&f.run(&["list", "--status", "todo"])), [2, 7, 8, 9, 10]);
}

#[test]
fn priority_cursor_versions_history_and_markdown_preserve_priority() {
    let f = Fixture::new();
    for priority in ["P3", "P1", "P0", "P1", "P2"] {
        f.run(&[
            "create",
            "--title",
            "task",
            "--body-file",
            f.root.path().join("body.md").to_str().unwrap(),
            "--status",
            "todo",
            "--priority",
            priority,
        ]);
    }
    let page = f.run(&["list", "--limit", "2"]);
    assert_eq!(ids(&page), [3, 2]);
    assert_eq!(page["next_after"], "P1:T-002");
    let page = f.run(&[
        "list",
        "--limit",
        "2",
        "--after",
        page["next_after"].as_str().unwrap(),
    ]);
    assert_eq!(ids(&page), [4, 5]);
    assert_eq!(
        ids(&f.run(&["list", "--after", page["next_after"].as_str().unwrap()])),
        [1]
    );
    assert_eq!(ids(&f.run(&["search", "task", "--after", "3"])), [4, 5]);
    let updated = f.run(&["update", "T-1", "--expect-version", "1", "--priority", "P0"]);
    assert_eq!(updated["version"], 2);
    let unchanged = f.run(&["update", "T-1", "--expect-version", "2", "--priority", "P0"]);
    assert_eq!(unchanged["version"], 2);
    assert_eq!(unchanged["event_id"], Value::Null);
    assert_eq!(f.run(&["show", "T-1"])["priority"], "P0");
    let event = updated["event_id"].as_u64().unwrap().to_string();
    let history = f.run(&["history", "T-1", "--event", &event]);
    let snapshot = history["items"][0]["snapshot"].clone();
    assert_eq!(snapshot["priority"], "P0");
    let export = f.root.path().join("export.md");
    f.run(&["export", "--out", export.to_str().unwrap()]);
    let other = Fixture::new();
    let preview = other.run(&["import", "--file", export.to_str().unwrap()]);
    assert_eq!(preview["report"]["tasks"][0]["priority"], "P0");
    other.run(&[
        "import",
        "--file",
        export.to_str().unwrap(),
        "--apply",
        "--expect-sha256",
        preview["report"]["source_sha256"].as_str().unwrap(),
    ]);
    assert_eq!(other.run(&["show", "T-1"])["priority"], "P0");
}

#[test]
fn cursor_pagination_covers_default_open_needs_human_and_explicit_status_views() {
    // Interleaves todo/in-progress at the same priority so a page boundary
    // falls mid-way through the default view's UNION ALL arms (TSK-014
    // review): the merged, globally priority/id-ordered page must still
    // split and resume correctly across the arm boundary.
    let f = Fixture::new();
    f.add(TaskStatus::Ready, vec![], vec![]); // 1 todo
    f.add(TaskStatus::InProgress, vec![], vec![]); // 2 in-progress
    f.add(TaskStatus::Ready, vec![], vec![]); // 3 todo
    f.add(TaskStatus::InProgress, vec![], vec![]); // 4 in-progress
    f.add(TaskStatus::Backlog, vec![], vec![]); // 5 draft
    f.add(TaskStatus::Blocked, vec![], vec![]); // 6 blocked
    f.add(TaskStatus::Ready, vec![], vec!["needs-human".into()]); // 7 todo, needs-human

    // Default view (RUNNABLE_PREDICATE's two-arm union: todo/in-progress,
    // excluding needs-human): a 2-item page crosses the arm boundary and
    // resumes correctly.
    let page = f.run(&["list", "--limit", "2"]);
    assert_eq!(ids(&page), [1, 2]);
    let next = page["next_after"].as_str().unwrap().to_string();
    assert_eq!(ids(&f.run(&["list", "--after", &next])), [3, 4]);

    // --open (five-arm union over every non-terminal status): a 3-item page
    // crosses two arm boundaries (todo/in-progress -> draft -> blocked) and
    // resumes correctly, including the needs-human task --open still shows.
    let open_page = f.run(&["list", "--open", "--limit", "3"]);
    assert_eq!(ids(&open_page), [1, 2, 3]);
    let open_next = open_page["next_after"].as_str().unwrap().to_string();
    assert_eq!(
        ids(&f.run(&["list", "--open", "--after", &open_next])),
        [4, 5, 6, 7]
    );

    // --needs-human (five-arm union, needs-human-labeled only) with a
    // cursor positioned before the sole match.
    assert_eq!(
        ids(&f.run(&["list", "--needs-human", "--after", &next])),
        [7]
    );

    // Explicit --status (single-arm, readiness bypassed: includes the
    // needs-human task) combined with --after.
    let status_page = f.run(&["list", "--status", "todo", "--limit", "1"]);
    assert_eq!(ids(&status_page), [1]);
    let status_next = status_page["next_after"].as_str().unwrap().to_string();
    assert_eq!(
        ids(&f.run(&["list", "--status", "todo", "--after", &status_next])),
        [3, 7]
    );
}

#[test]
fn unlocks_counts_direct_open_and_immediately_runnable_dependents() {
    let f = Fixture::new();
    f.add(TaskStatus::Backlog, vec![], vec![]); // 1
    f.add(TaskStatus::Blocked, vec![], vec![]); // 2
    f.add(TaskStatus::Done, vec![], vec![]); // 3
    f.add(TaskStatus::Cancelled, vec![], vec![]); // 4
    f.add(TaskStatus::Ready, vec![1, 3], vec![]); // immediate for 1
    f.add(TaskStatus::Ready, vec![1, 2], vec![]); // neither immediate
    f.add(TaskStatus::Ready, vec![2, 4], vec![]); // cancelled is unsatisfied
    f.add(TaskStatus::Backlog, vec![1], vec![]); // direct only
    f.add(TaskStatus::Ready, vec![1], vec!["needs-human".into()]); // direct only
    f.add(TaskStatus::Done, vec![2], vec![]); // excluded
    let result = f.run(&["unlocks", "--limit", "1"]);
    assert_eq!(result["items"][0]["id"], 1);
    assert_eq!(result["items"][0]["direct_open_dependents"], 4);
    assert_eq!(result["items"][0]["immediately_runnable"], 1);
    assert_eq!(result["next_offset"], 1);
    let result = f.run(&["unlocks", "--offset", "1"]);
    assert_eq!(ids(&result), [2]);
    assert_eq!(result["items"][0]["direct_open_dependents"], 2);
    assert_eq!(result["items"][0]["immediately_runnable"], 0);
    assert_eq!(result["has_more"], json!(false));
}
