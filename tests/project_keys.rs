//! Project keys in task IDs (`DAK-12`): assignment, uniqueness, parsing,
//! output, cross-project enrichment, migration and bulk import. Every test
//! uses its own temporary data root and real subprocesses.

mod support;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use tasks_cli::store::{data_root_project_path, Store};

struct Env {
    temp: tempfile::TempDir,
}

impl Env {
    fn new() -> Self {
        Self {
            temp: tempfile::tempdir().expect("temp"),
        }
    }

    fn data(&self) -> PathBuf {
        self.temp.path().join("data")
    }

    fn root(&self, name: &str) -> PathBuf {
        let root = self.temp.path().join(name);
        fs::create_dir_all(&root).expect("root");
        root
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = support::process::command(env!("CARGO_BIN_EXE_tasks"));
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000);
        }
        command
            .arg("--data-root")
            .arg(self.data())
            .args(args)
            .env_remove("TASKS_WINDOWS_EXE")
            .env_remove("TASKS_PROJECT");
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command(args).output().expect("tasks")
    }

    fn run_stdin(&self, args: &[&str], stdin: &str) -> Output {
        use std::io::Write;
        let mut child = self
            .command(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("tasks");
        child
            .stdin
            .take()
            .expect("stdin")
            .write_all(stdin.as_bytes())
            .expect("write stdin");
        child.wait_with_output().expect("tasks output")
    }

    /// JSON `data` of a successful command.
    fn json(&self, args: &[&str]) -> Value {
        let mut all = vec!["--format", "json"];
        all.extend_from_slice(args);
        let output = self.run(&all);
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice::<Value>(&output.stdout).expect("JSON")["data"].clone()
    }

    fn text(&self, args: &[&str]) -> String {
        let output = self.run(args);
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).expect("UTF-8")
    }

    /// `init --key`, returning the project UUID.
    fn init(&self, name: &str, key: &str) -> String {
        let root = self.root(name);
        self.json(&["init", "--root", s(&root), "--key", key])["project_id"]
            .as_str()
            .expect("project id")
            .to_string()
    }

    fn create(&self, project: &str, title: &str, extra: &[&str]) -> Value {
        let mut args = vec![
            "--project",
            project,
            "create",
            "--title",
            title,
            "--body-file",
            "-",
            "--status",
            "todo",
        ];
        args.extend_from_slice(extra);
        let mut all = vec!["--format", "json"];
        all.extend_from_slice(&args);
        let output = self.run_stdin(&all, "body\n");
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice::<Value>(&output.stdout).expect("JSON")["data"].clone()
    }

    fn project_dirs(&self) -> usize {
        fs::read_dir(self.data().join("projects"))
            .map(|entries| entries.count())
            .unwrap_or(0)
    }

    fn bindings(&self) -> usize {
        tasks_cli::registry::list_bindings(&self.data())
            .map(|registry| registry.bindings.len())
            .unwrap_or(0)
    }
}

/// Every file under `root` with its bytes.
fn data_files(root: &Path) -> std::collections::BTreeMap<PathBuf, Vec<u8>> {
    let mut files = std::collections::BTreeMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                stack.push(path);
            } else {
                files.insert(path.clone(), fs::read(&path).unwrap());
            }
        }
    }
    files
}

fn s(path: &Path) -> &str {
    path.to_str().expect("UTF-8 path")
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

#[test]
fn init_requires_a_valid_key_and_creates_nothing_without_one() {
    let env = Env::new();
    let root = env.root("app");
    for (args, needle) in [
        (vec!["init", "--root", s(&root)], "--key"),
        (vec!["init", "--root", s(&root), "--key", "A"], "2-6"),
        (vec!["init", "--root", s(&root), "--key", "ABCDEFG"], "2-6"),
        (vec!["init", "--root", s(&root), "--key", "1AB"], "letter"),
        (vec!["init", "--root", s(&root), "--key", "T"], "reserved"),
        (vec!["init", "--root", s(&root), "--key", "t"], "reserved"),
        (vec!["init", "--root", s(&root), "--key", "A-B"], "letters"),
    ] {
        let output = env.run(&args);
        assert_eq!(
            output.status.code(),
            Some(2),
            "{args:?}: {}",
            stderr(&output)
        );
        assert!(
            stderr(&output).contains(needle),
            "{args:?}: {}",
            stderr(&output)
        );
    }
    assert!(
        !env.data().exists(),
        "a refused init must not create the data root"
    );
    assert!(!root.join(".tasks.json").exists());

    // Case folding: the key is stored uppercase.
    let data = env.json(&["init", "--root", s(&root), "--key", "dak"]);
    assert_eq!(data["project_key"], "DAK");
    let project = data["project_id"].as_str().unwrap();
    assert_eq!(
        Store::open_readonly(&env.data(), project)
            .unwrap()
            .project_key
            .as_deref(),
        Some("DAK")
    );
    assert_eq!(
        env.json(&["--project", project, "project-key"])["project_key"],
        "DAK"
    );
    assert!(env
        .text(&["--project", project, "project-key"])
        .contains("project_key: DAK"));
}

#[test]
fn reserved_keys_are_refused_as_project_keys() {
    let env = Env::new();
    let root = env.root("app");
    for key in ["utf", "UTF", "SHA", "iso", "IEEE", "cve", "X86"] {
        let output = env.run(&["init", "--root", s(&root), "--key", key]);
        assert_eq!(output.status.code(), Some(2), "{key}: {}", stderr(&output));
        let message = stderr(&output);
        assert!(message.contains("reserved"), "{key}: {message}");
        assert!(
            message
                .to_ascii_uppercase()
                .contains(&key.to_ascii_uppercase()),
            "{key}: {message}"
        );
    }
    assert!(
        !env.data().exists(),
        "a refused init must not create the data root"
    );

    // A non-reserved key is unaffected; project-key --set also refuses.
    let project = env.init("app", "DAK");
    let set = env.run(&["--project", &project, "project-key", "--set", "SHA"]);
    assert_eq!(set.status.code(), Some(2), "{}", stderr(&set));
    assert!(stderr(&set).contains("reserved"), "{}", stderr(&set));
    assert_eq!(
        env.json(&["--project", &project, "project-key"])["project_key"],
        "DAK"
    );
}

#[test]
fn a_taken_key_is_refused_with_nothing_written_and_names_the_owner() {
    let env = Env::new();
    let owner = env.init("owner-app", "DAK");
    assert!(
        env.data().join("project-keys.json").is_file(),
        "the first committed init writes the key cache"
    );
    let other = env.root("other-app");
    let before = data_files(&env.data());
    let output = env.run(&["init", "--root", s(&other), "--key", "dak"]);
    assert!(
        before == data_files(&env.data()),
        "a refused init leaves the data root byte-identical"
    );
    assert_eq!(output.status.code(), Some(2), "{}", stderr(&output));
    let message = stderr(&output);
    assert!(message.contains("DAK"), "{message}");
    assert!(message.contains(&owner), "{message}");
    assert!(message.contains("owner-app"), "{message}");
    assert_eq!(env.project_dirs(), 1, "no second project directory");
    assert_eq!(env.bindings(), 1, "no second binding");
    assert!(!other.join(".tasks.json").exists());

    // Re-initializing the owner's root with its own key is accepted; with a
    // different key it is refused without changing the stored key.
    let again = env.json(&["init", "--root", s(&env.root("owner-app")), "--key", "DAK"]);
    assert_eq!(again["project_id"], owner.as_str());
    let changed = env.run(&["init", "--root", s(&env.root("owner-app")), "--key", "DS"]);
    assert_eq!(changed.status.code(), Some(2), "{}", stderr(&changed));
    assert!(
        stderr(&changed).contains("project-key --set"),
        "{}",
        stderr(&changed)
    );
    assert_eq!(
        env.json(&["--project", &owner, "project-key"])["project_key"],
        "DAK"
    );
}

#[test]
fn concurrent_inits_with_one_key_have_exactly_one_winner() {
    for round in 0..3 {
        let env = Env::new();
        let first = env.root("first");
        let second = env.root("second");
        let spawn = |root: &Path| {
            env.command(&["init", "--root", s(root), "--key", "DUP"])
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .expect("init")
        };
        let a = spawn(&first);
        let b = spawn(&second);
        let a = a.wait_with_output().expect("a");
        let b = b.wait_with_output().expect("b");
        let codes = [a.status.code(), b.status.code()];
        assert_eq!(
            codes.iter().filter(|code| **code == Some(0)).count(),
            1,
            "round {round}: {codes:?}\n{}\n{}",
            stderr(&a),
            stderr(&b)
        );
        assert!(codes.contains(&Some(2)), "round {round}: {codes:?}");
        assert_eq!(env.project_dirs(), 1, "round {round}");
        assert_eq!(env.bindings(), 1, "round {round}");
        let keyed = tasks_cli::keys::scan(&env.data(), true).unwrap();
        assert_eq!(keyed.len(), 1);
        assert_eq!(keyed[0].key.as_deref(), Some("DUP"));
    }
}

#[test]
fn ids_parse_in_every_accepted_form_and_foreign_keys_exit_3() {
    let env = Env::new();
    let dak = env.init("DelphiAiKit", "DAK");
    let ds = env.init("DelphiSemantics", "DS");
    env.create(&dak, "first", &[]);
    env.create(&ds, "semantics one", &[]);
    for form in ["DAK-1", "dak-001", "T-1", "t-1", "1", "001"] {
        let shown = env.json(&["--project", &dak, "show", form]);
        assert_eq!(shown["id"], 1, "{form}");
        assert_eq!(shown["display_id"], "DAK-001", "{form}");
    }
    // Another project's key: exit 3, naming that project and its root.
    let foreign = env.run(&["--project", &dak, "show", "DS-1"]);
    assert_eq!(foreign.status.code(), Some(3), "{}", stderr(&foreign));
    let message = stderr(&foreign);
    assert!(message.contains("DS-001"), "{message}");
    assert!(message.contains(&ds), "{message}");
    assert!(message.contains("DelphiSemantics"), "{message}");
    // A key no project has is also not found.
    let unknown = env.run(&["--project", &dak, "show", "ZZ-1"]);
    assert_eq!(unknown.status.code(), Some(3), "{}", stderr(&unknown));
    assert!(
        stderr(&unknown).contains("no project"),
        "{}",
        stderr(&unknown)
    );
    // Dependencies stay within one project.
    let dep = env.run_stdin(
        &[
            "--project",
            &dak,
            "create",
            "--title",
            "x",
            "--body-file",
            "-",
            "--deps",
            "DS-1",
        ],
        "b\n",
    );
    assert_eq!(dep.status.code(), Some(3), "{}", stderr(&dep));
    assert_eq!(env.project_dirs(), 2);
    let second = env.create(&dak, "second", &["--deps", "dak-1"]);
    assert_eq!(second["display_id"], "DAK-002");
    let update = env.json(&[
        "--project",
        &dak,
        "update",
        "DAK-2",
        "--expect-version",
        "1",
        "--deps",
        "T-1",
    ]);
    assert_eq!(update["display_id"], "DAK-002");
    let history = env.json(&["--project", &dak, "history", "2"]);
    assert_eq!(history["display_id"], "DAK-002");
    // Malformed input is still a usage error.
    let bad = env.run(&["--project", &dak, "show", "DAK-x"]);
    assert_eq!(bad.status.code(), Some(2), "{}", stderr(&bad));
}

#[test]
fn output_shows_keyed_ids_and_unkeyed_projects_keep_t_ids() {
    let env = Env::new();
    let dak = env.init("app", "DAK");
    env.create(&dak, "base", &[]);
    env.create(&dak, "dependent", &["--deps", "DAK-1"]);

    let list = env.text(&["--project", &dak, "list", "--open"]);
    assert!(list.contains("DAK-001\tP2\ttodo\tv1\tbase"), "{list}");
    assert!(
        list.contains("DAK-002\tP2\ttodo\tv1\tdependent\t[DAK-001]"),
        "{list}"
    );
    assert!(!list.contains("T-00"), "{list}");
    let json = env.json(&["--project", &dak, "list", "--open"]);
    assert_eq!(json["items"][1]["id"], 2);
    assert_eq!(json["items"][1]["display_id"], "DAK-002");
    assert_eq!(json["items"][1]["deps"], serde_json::json!([1]));

    let show = env.text(&["--project", &dak, "show", "DAK-2"]);
    assert!(show.starts_with("id: DAK-002\n"), "{show}");
    assert!(
        show.contains("depends_on: DAK-001\ttodo\tv1\tbase"),
        "{show}"
    );
    let show = env.json(&["--project", &dak, "show", "DAK-2"]);
    assert_eq!(show["dependency_summaries"][0]["display_id"], "DAK-001");

    let unlocks = env.text(&["--project", &dak, "unlocks"]);
    assert!(unlocks.starts_with("DAK-001\t"), "{unlocks}");
    let search = env.json(&["--project", &dak, "search", "dependent"]);
    assert_eq!(search["items"][0]["display_id"], "DAK-002");
    let ranked = env.json(&["--project", &dak, "search", "dependent", "--ranked"]);
    assert_eq!(ranked["items"][0]["display_id"], "DAK-002");
    let created = env.run_stdin(
        &[
            "--project",
            &dak,
            "create",
            "--title",
            "third",
            "--body-file",
            "-",
        ],
        "b\n",
    );
    assert!(
        String::from_utf8_lossy(&created.stdout).starts_with("id: DAK-003\n"),
        "{}",
        String::from_utf8_lossy(&created.stdout)
    );
    let missing = env.run(&["--project", &dak, "show", "DAK-99"]);
    assert_eq!(missing.status.code(), Some(3));
    assert!(stderr(&missing).contains("DAK-099"), "{}", stderr(&missing));

    // The completion guard names prerequisites with the key.
    let guard = env.run(&[
        "--format",
        "json",
        "--project",
        &dak,
        "update",
        "DAK-2",
        "--expect-version",
        "1",
        "--status",
        "done",
    ]);
    assert_eq!(guard.status.code(), Some(2));
    let error: Value = serde_json::from_slice(&guard.stderr).unwrap();
    assert!(
        error["error"]["message"]
            .as_str()
            .unwrap()
            .contains("DAK-001 (todo)"),
        "{error}"
    );
    assert_eq!(
        error["error"]["open_prerequisites"]["prerequisites"][0]["display_id"],
        "DAK-001"
    );

    let out = env.temp.path().join("export.md");
    env.text(&["--project", &dak, "export", "--out", s(&out)]);
    let exported = fs::read_to_string(&out).unwrap();
    assert!(exported.contains("### DAK-002 dependent\n"), "{exported}");
    assert!(exported.contains("Depends on: DAK-001\n"), "{exported}");
    assert!(!exported.contains("### T-"), "{exported}");

    // A project without a key (library-created, as after migration) keeps T-N.
    let plain = uuid::Uuid::new_v4();
    tasks_cli::store::create_project_db(&env.data(), &plain).unwrap();
    let plain = plain.to_string();
    env.create(&plain, "legacy", &[]);
    let list = env.text(&["--project", &plain, "list", "--open"]);
    assert!(list.starts_with("T-001\tP2\ttodo\tv1\tlegacy"), "{list}");
    assert_eq!(
        env.json(&["--project", &plain, "show", "T-1"])["display_id"],
        "T-001"
    );
    let key = env.json(&["--project", &plain, "project-key"]);
    assert_eq!(key["project_key"], Value::Null);
    assert!(env
        .text(&["--project", &plain, "project-key"])
        .contains("project_key: none"));
    let out = env.temp.path().join("plain.md");
    env.text(&["--project", &plain, "export", "--out", s(&out)]);
    assert!(fs::read_to_string(&out)
        .unwrap()
        .contains("### T-001 legacy\n"));
}

#[test]
fn enrich_resolves_keys_across_projects_and_project_key_set_guards_uniqueness() {
    let env = Env::new();
    let dak = env.init("dak", "DAK");
    let ds = env.init("ds", "DS");
    env.create(&dak, "Kit task", &[]);
    env.create(&ds, "Semantics task", &[]);
    let input = "See DAK-1, DS-1, T-1, UTF-8, ZZ-4 and DAK-9.\n";
    let output = env.run_stdin(&["--project", &ds, "enrich"], input);
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "See DAK-1 (Kit task), DS-1 (Semantics task), T-1 (Semantics task), UTF-8, ZZ-4 and DAK-9.\n"
    );
    assert!(stderr(&output).contains("DAK-9"), "{}", stderr(&output));
    assert!(!stderr(&output).contains("ZZ"), "{}", stderr(&output));
    let json = env.run_stdin(&["--format", "json", "--project", &ds, "enrich"], input);
    let data = &serde_json::from_slice::<Value>(&json.stdout).unwrap()["data"];
    assert_eq!(data["replacements"], 3);
    assert_eq!(data["unknown_ids"], serde_json::json!([]));
    assert_eq!(data["unknown_refs"], serde_json::json!(["DAK-9"]));

    // project-key --set to a taken key exits 2 and changes nothing.
    let taken = env.run(&["--project", &ds, "project-key", "--set", "dak"]);
    assert_eq!(taken.status.code(), Some(2), "{}", stderr(&taken));
    assert!(stderr(&taken).contains(&dak), "{}", stderr(&taken));
    assert_eq!(
        env.json(&["--project", &ds, "project-key"])["project_key"],
        "DS"
    );
    let bad = env.run(&["--project", &ds, "project-key", "--set", "9X"]);
    assert_eq!(bad.status.code(), Some(2));

    // Changing a key: old mentions stay as written and no longer resolve.
    let set = env.json(&["--project", &ds, "project-key", "--set", "sem"]);
    assert_eq!(set["project_key"], "SEM");
    assert_eq!(set["previous_key"], "DS");
    assert_eq!(
        env.json(&["--project", &ds, "show", "SEM-1"])["title"],
        "Semantics task"
    );
    let old = env.run(&["--project", &ds, "show", "DS-1"]);
    assert_eq!(old.status.code(), Some(3));
    let output = env.run_stdin(&["--project", &dak, "enrich"], "DS-1 and SEM-1\n");
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "DS-1 and SEM-1 (Semantics task)\n"
    );
    // The body was not rewritten.
    assert_eq!(env.json(&["--project", &ds, "show", "SEM-1"])["version"], 1);
    // Setting the same key again is a no-op success.
    let same = env.json(&["--project", &ds, "project-key", "--set", "SEM"]);
    assert_eq!(same["previous_key"], "SEM");
}

/// Builds a schema-5 database: a current one without the key column.
fn schema_five(data: &Path) -> String {
    let project = uuid::Uuid::new_v4();
    tasks_cli::store::create_project_db(data, &project).unwrap();
    let mut store = Store::open_rw(data, &project.to_string()).unwrap();
    store
        .create_task(
            "old task",
            "mentions DAK-9",
            tasks_cli::model::TaskStatus::Ready,
            vec![],
        )
        .unwrap();
    drop(store);
    let conn =
        rusqlite::Connection::open(data_root_project_path(data, &project.to_string())).unwrap();
    conn.execute_batch("ALTER TABLE project DROP COLUMN project_key; DROP TABLE mutation_receipts; DROP TABLE metadata_events; ALTER TABLE events DROP COLUMN attribution_json; PRAGMA user_version = 5;")
        .unwrap();
    drop(conn);
    project.to_string()
}

#[test]
fn migration_adds_an_unset_key_and_the_project_keeps_working_with_t_ids() {
    let env = Env::new();
    fs::create_dir_all(env.data()).unwrap();
    let project = schema_five(&env.data());
    let refused = env.run(&["--project", &project, "list", "--open"]);
    assert_eq!(
        refused.status.code(),
        Some(6),
        "schema 5 must require migrate"
    );
    let migrated = env.json(&["--project", &project, "migrate"]);
    assert_eq!(migrated["from_version"], 5);
    assert_eq!(migrated["to_version"], 8);
    assert!(migrated["backup_path"].as_str().is_some());
    assert_eq!(
        env.json(&["--project", &project, "project-key"])["project_key"],
        Value::Null
    );
    let list = env.text(&["--project", &project, "list"]);
    assert!(list.starts_with("T-001\t"), "{list}");
    env.json(&["--project", &project, "project-key", "--set", "OLD"]);
    let list = env.text(&["--project", &project, "list"]);
    assert!(list.starts_with("OLD-001\t"), "{list}");
    assert_eq!(
        env.json(&["--project", &project, "show", "T-1"])["body"],
        "mentions DAK-9"
    );
    // Running migrate again is a no-op.
    let again = env.json(&["--project", &project, "migrate"]);
    assert_eq!(again["backup_path"], Value::Null);
}

#[test]
fn import_accepts_the_target_key_in_headings_and_rejects_other_keys() {
    let env = Env::new();
    let dak = env.init("app", "DAK");
    let ledger = env.temp.path().join("TASKS.md");
    fs::write(
        &ledger,
        "## todo\n### DAK-1 Keyed\nStatus: todo\nDepends on: T-2\nBody:\nkeyed body\n### T-2 Legacy\nlegacy body\n",
    )
    .unwrap();
    let preview = env.json(&["--project", &dak, "import", "--file", s(&ledger)]);
    assert_eq!(preview["report"]["task_count"], 2, "{preview}");
    assert_eq!(preview["problems"], serde_json::json!([]), "{preview}");
    let hash = preview["report"]["source_sha256"]
        .as_str()
        .unwrap()
        .to_string();
    env.json(&[
        "--project",
        &dak,
        "import",
        "--file",
        s(&ledger),
        "--apply",
        "--expect-sha256",
        &hash,
    ]);
    let shown = env.json(&["--project", &dak, "show", "DAK-1"]);
    assert_eq!(shown["title"], "Keyed");
    assert_eq!(shown["dependency_summaries"][0]["display_id"], "DAK-002");

    // Another project's key is not a task heading here: the content is
    // unassigned and blocks apply.
    let other = env.init("other", "OTH");
    let foreign = env.temp.path().join("FOREIGN.md");
    fs::write(&foreign, "## todo\n### DAK-1 Foreign\nbody\n").unwrap();
    let preview = env.json(&["--project", &other, "import", "--file", s(&foreign)]);
    assert_eq!(preview["report"]["task_count"], 0, "{preview}");
    let problems = preview["problems"].as_array().unwrap();
    assert_eq!(problems.len(), 1, "{preview}");
    let message = problems[0]["message"].as_str().unwrap();
    assert!(message.contains("uses project key DAK"), "{message}");
    assert!(message.contains("targets project key OTH"), "{message}");
    let blocked = env.run(&[
        "--project",
        &other,
        "import",
        "--file",
        s(&foreign),
        "--apply",
        "--expect-sha256",
        preview["report"]["source_sha256"].as_str().unwrap(),
    ]);
    assert_eq!(blocked.status.code(), Some(2), "{}", stderr(&blocked));
}

fn write_ledger(dir: &Path, text: &str) {
    fs::create_dir_all(dir).unwrap();
    fs::write(dir.join("TASKS.md"), text).unwrap();
}

#[test]
fn bulk_import_requires_a_key_for_every_new_project() {
    let env = Env::new();
    let corpus = env.root("corpus");
    write_ledger(&corpus.join("alpha"), "## todo\n### T-1 Alpha\nbody\n");
    write_ledger(&corpus.join("beta"), "## todo\n### T-1 Beta\nbody\n");
    let map = env.temp.path().join("map.json");
    fs::write(&map, "{}").unwrap();
    let reports = env.temp.path().join("reports");
    let bulk = |extra: &[&str]| {
        let mut args = vec![
            "bulk-import",
            "--scan-root",
            s(&corpus),
            "--map-file",
            s(&map),
            "--report-dir",
            s(&reports),
        ];
        args.extend_from_slice(extra);
        env.run(&args)
    };
    let keys = env.temp.path().join("keys.json");
    fs::write(&keys, r#"{"alpha":"ALP"}"#).unwrap();

    // Dry run: lists the root still lacking a key, writes nothing.
    let dry = bulk(&["--key-map", s(&keys)]);
    assert_eq!(dry.status.code(), Some(0), "{}", stderr(&dry));
    let text = String::from_utf8_lossy(&dry.stdout).to_string();
    assert!(text.contains("key=ALP"), "{text}");
    assert!(
        text.contains("key_problem:") && text.contains("beta"),
        "{text}"
    );
    let summary = fs::read_to_string(reports.join("summary.md")).unwrap();
    assert!(
        summary.contains("roots without a usable key: 1"),
        "{summary}"
    );
    assert_eq!(env.project_dirs(), 0);

    // Apply refuses until every root is mapped; nothing is written.
    let refused = bulk(&["--key-map", s(&keys), "--apply"]);
    assert_eq!(refused.status.code(), Some(2), "{}", stderr(&refused));
    assert!(stderr(&refused).contains("beta"), "{}", stderr(&refused));
    assert_eq!(env.project_dirs(), 0);
    assert_eq!(env.bindings(), 0);
    let no_map = bulk(&["--apply"]);
    assert_eq!(no_map.status.code(), Some(2), "{}", stderr(&no_map));
    assert_eq!(env.project_dirs(), 0);

    // Invalid and duplicate keys fail at map load.
    fs::write(&keys, r#"{"alpha":"1X","beta":"BET"}"#).unwrap();
    assert_eq!(bulk(&["--key-map", s(&keys)]).status.code(), Some(2));
    fs::write(&keys, r#"{"alpha":"SAME","beta":"same"}"#).unwrap();
    let duplicate = bulk(&["--key-map", s(&keys)]);
    assert_eq!(duplicate.status.code(), Some(2));
    assert!(
        stderr(&duplicate).contains("SAME"),
        "{}",
        stderr(&duplicate)
    );

    // A key another project already has is reported and blocks apply.
    let taken = env.init("elsewhere", "BET");
    fs::write(&keys, r#"{"alpha":"ALP","beta":"BET"}"#).unwrap();
    let cache = env.data().join("project-keys.json");
    fs::remove_file(&cache).unwrap();
    let refused = bulk(&["--key-map", s(&keys), "--apply"]);
    assert_eq!(refused.status.code(), Some(2), "{}", stderr(&refused));
    assert!(stderr(&refused).contains(&taken), "{}", stderr(&refused));
    assert_eq!(env.project_dirs(), 1);
    assert!(!cache.exists(), "a refused apply writes no cache");

    // With every root mapped to a free key, apply creates keyed projects
    // and refreshes the key cache after the commit.
    fs::write(&keys, r#"{"alpha":"alp","beta":"BTA"}"#).unwrap();
    let applied = bulk(&["--key-map", s(&keys), "--apply"]);
    assert_eq!(applied.status.code(), Some(0), "{}", stderr(&applied));
    assert!(cache.is_file(), "a committed apply refreshes the cache");
    let mut keyed = tasks_cli::keys::scan(&env.data(), true)
        .unwrap()
        .into_iter()
        .filter_map(|project| project.key)
        .collect::<Vec<_>>();
    keyed.sort();
    assert_eq!(keyed, ["ALP", "BET", "BTA"]);
    let alpha = fs::read_to_string(reports.join("run.jsonl")).unwrap();
    assert!(alpha.contains("\"project_key\":\"ALP\""), "{alpha}");
}

#[test]
fn bulk_import_key_map_refuses_a_reserved_key() {
    let env = Env::new();
    let corpus = env.root("corpus");
    write_ledger(&corpus.join("alpha"), "## todo\n### T-1 Alpha\nbody\n");
    let map = env.temp.path().join("map.json");
    fs::write(&map, "{}").unwrap();
    let reports = env.temp.path().join("reports");
    let keys = env.temp.path().join("keys.json");
    fs::write(&keys, r#"{"alpha":"SHA"}"#).unwrap();
    let output = env.run(&[
        "bulk-import",
        "--scan-root",
        s(&corpus),
        "--map-file",
        s(&map),
        "--report-dir",
        s(&reports),
        "--key-map",
        s(&keys),
        "--apply",
    ]);
    assert_eq!(output.status.code(), Some(2), "{}", stderr(&output));
    assert!(stderr(&output).contains("reserved"), "{}", stderr(&output));
    assert_eq!(env.project_dirs(), 0, "nothing written for a reserved key");
    assert_eq!(env.bindings(), 0);
    assert!(!env.data().join("project-keys.json").exists());
}

/// Bulk-import checks keys through the key cache but never writes it: a dry
/// run over a stale cache still sees a key changed behind the cache's back and
/// leaves every file in the data root byte-identical.
#[test]
fn bulk_dry_run_reads_a_stale_key_cache_without_writing_the_data_root() {
    let env = Env::new();
    let first = env.init("first", "ONE");
    let second = env.init("second", "TWO");
    let cache = env.data().join("project-keys.json");
    env.run_stdin(
        &["--project", &second, "enrich"],
        "ONE-1
",
    );
    assert!(cache.is_file(), "enrich cached both keys");
    let conn = rusqlite::Connection::open(data_root_project_path(&env.data(), &first)).unwrap();
    conn.execute("UPDATE project SET project_key='ALP'", [])
        .unwrap();
    drop(conn);
    let corpus = env.root("corpus");
    write_ledger(
        &corpus.join("alpha"),
        "## todo
### T-1 Alpha
body
",
    );
    let map = env.temp.path().join("map.json");
    fs::write(&map, "{}").unwrap();
    let keys = env.temp.path().join("keys.json");
    fs::write(&keys, r#"{"alpha":"ALP"}"#).unwrap();
    let reports = env.temp.path().join("reports");
    let before = data_files(&env.data());
    let dry = env.run(&[
        "bulk-import",
        "--scan-root",
        s(&corpus),
        "--map-file",
        s(&map),
        "--report-dir",
        s(&reports),
        "--key-map",
        s(&keys),
    ]);
    assert_eq!(dry.status.code(), Some(0), "{}", stderr(&dry));
    let text = String::from_utf8_lossy(&dry.stdout).to_string();
    assert!(
        text.contains("key_problem:") && text.contains("ALP"),
        "the changed key must be seen: {text}"
    );
    assert!(
        before == data_files(&env.data()),
        "a dry run must leave the data root byte-identical"
    );
}

/// The reviewed key list for the live projects (a temp copy; the live stores
/// are never opened) must hold only valid, unique keys.
#[test]
fn the_reviewed_project_key_list_is_valid_and_unique() {
    let source = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("issues/closed/project-key-task-ids/project-keys.csv");
    let temp = tempfile::tempdir().unwrap();
    let copy = temp.path().join("project-keys.csv");
    fs::copy(&source, &copy).unwrap();
    let text = fs::read_to_string(&copy).unwrap();
    let mut lines = text.lines();
    let header = lines.next().unwrap().split(',').collect::<Vec<_>>();
    assert_eq!(
        header,
        ["key", "project_name", "project_path", "project_id"]
    );
    let mut keys = std::collections::HashSet::new();
    let mut ids = std::collections::HashSet::new();
    let mut rows = 0;
    for line in lines.filter(|line| !line.trim().is_empty()) {
        let fields = line.split(',').collect::<Vec<_>>();
        assert_eq!(fields.len(), 4, "{line}");
        let key = tasks_cli::model::parse_project_key(fields[0])
            .unwrap_or_else(|error| panic!("{line}: {error}"));
        assert_eq!(key, fields[0], "keys are written uppercase: {line}");
        assert!(keys.insert(key), "duplicate key: {line}");
        let id = uuid::Uuid::parse_str(fields[3]).unwrap_or_else(|_| panic!("{line}"));
        assert!(ids.insert(id), "duplicate project: {line}");
        rows += 1;
    }
    assert!(rows > 0);
}

#[test]
fn viewer_payloads_carry_the_key_and_display_ids() {
    let env = Env::new();
    let dak = env.init("app", "DAK");
    env.create(&dak, "base", &[]);
    env.create(&dak, "dependent", &["--deps", "DAK-1"]);
    let request = env.temp.path().join("tasks.json");
    fs::write(&request, r#"{"query":"dak-2"}"#).unwrap();
    let tasks = env.json(&[
        "--project",
        &dak,
        "viewer",
        "tasks",
        "--request-file",
        s(&request),
    ]);
    assert_eq!(tasks["project_key"], "DAK");
    assert_eq!(tasks["total_count"], 1, "a KEY-N query is an ID match");
    assert_eq!(tasks["items"][0]["display_id"], "DAK-002");
    let show = env.json(&["--project", &dak, "viewer", "show", "DAK-2"]);
    assert_eq!(show["project_key"], "DAK");
    assert_eq!(show["display_id"], "DAK-002");
    assert_eq!(show["dependency_summaries"][0]["display_id"], "DAK-001");
    let projects_request = env.temp.path().join("projects.json");
    fs::write(&projects_request, "{}").unwrap();
    let projects = env.json(&["viewer", "projects", "--request-file", s(&projects_request)]);
    assert_eq!(projects["items"][0]["project_key"], "DAK");
    fs::write(&projects_request, r#"{"query":"dak"}"#).unwrap();
    let found = env.json(&["viewer", "projects", "--request-file", s(&projects_request)]);
    assert_eq!(found["total_count"], 1, "projects are searchable by key");
    let update = env.temp.path().join("update.json");
    fs::write(&update, r#"{"id":2,"expect_version":1,"changes":{}}"#).unwrap();
    let empty = env.run(&[
        "--format",
        "json",
        "--project",
        &dak,
        "viewer",
        "update",
        "--request-file",
        s(&update),
    ]);
    assert_eq!(empty.status.code(), Some(2), "{}", stderr(&empty));
    assert!(
        stderr(&empty).contains("viewer update DAK-002"),
        "{}",
        stderr(&empty)
    );
}

#[test]
fn the_key_cache_never_hides_a_changed_key_from_lookups_or_uniqueness_checks() {
    let env = Env::new();
    let first = env.init("first", "ONE");
    let second = env.init("second", "TWO");
    env.create(&first, "first task", &[]);
    let cache = env.data().join("project-keys.json");
    assert!(cache.is_file(), "a committed init refreshes the cache");
    // A foreign-key lookup uses and refreshes the derived cache.
    let output = env.run_stdin(
        &["--project", &second, "enrich"],
        "ONE-1
",
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "ONE-1 (first task)
"
    );
    assert!(cache.is_file(), "enrich writes the derived key cache");
    // Change a key behind the CLI's back: the fingerprint changes, so the
    // cached lookup reads the database again instead of trusting the cache.
    let conn = rusqlite::Connection::open(data_root_project_path(&env.data(), &first)).unwrap();
    conn.execute("UPDATE project SET project_key='NEW'", [])
        .unwrap();
    drop(conn);
    let keys = tasks_cli::keys::scan_cached(&env.data()).unwrap();
    let key_of = |id: &str| {
        keys.iter()
            .find(|project| project.project_id.to_string() == id)
            .and_then(|project| project.key.clone())
    };
    assert_eq!(key_of(&first).as_deref(), Some("NEW"));
    assert_eq!(key_of(&second).as_deref(), Some("TWO"));
    let output = env.run_stdin(
        &["--project", &second, "enrich"],
        "NEW-1 ONE-1
",
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "NEW-1 (first task) ONE-1
"
    );
    // The uniqueness check goes through the same cache and sees a key changed
    // behind its back: the fingerprint changed, so the database is read again.
    let conn = rusqlite::Connection::open(data_root_project_path(&env.data(), &second)).unwrap();
    conn.execute("UPDATE project SET project_key='SEC'", [])
        .unwrap();
    drop(conn);
    let taken = env.run(&["init", "--root", s(&env.root("third")), "--key", "sec"]);
    assert_eq!(taken.status.code(), Some(2), "{}", stderr(&taken));
    assert!(stderr(&taken).contains(&second), "{}", stderr(&taken));
    let taken = env.run(&["--project", &first, "project-key", "--set", "sec"]);
    assert_eq!(taken.status.code(), Some(2), "{}", stderr(&taken));
    // The old keys are free again.
    env.json(&["init", "--root", s(&env.root("fourth")), "--key", "ONE"]);
    env.json(&["--project", &first, "project-key", "--set", "TWO"]);
    // A damaged cache is ignored and rebuilt by the next lookup.
    fs::write(&cache, b"not json").unwrap();
    let output = env.run_stdin(
        &["--project", &second, "enrich"],
        "TWO-1
",
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "TWO-1 (first task)
"
    );
    assert!(serde_json::from_slice::<Value>(&fs::read(&cache).unwrap()).is_ok());
}

/// Key-shaped words such as ISO-8601 in a heading are ordinary text unless a
/// project in the data root owns that key (regression: they blocked import).
#[test]
fn key_shaped_headings_of_no_known_project_stay_body_and_rules_text() {
    let env = Env::new();
    let dak = env.init("app", "DAK");
    let ledger = env.temp.path().join("TASKS.md");
    fs::write(
        &ledger,
        "## Rules\n\n### ISO-8601 dates\nUse ISO-8601 everywhere.\n\n## todo\n### DAK-1 Dates\nbody\n### ISO-8601 dates\nstill the body of DAK-1\n### SHA-256 sums\nand this\n",
    )
    .unwrap();
    let preview = env.json(&["--project", &dak, "import", "--file", s(&ledger)]);
    assert_eq!(preview["problems"], serde_json::json!([]), "{preview}");
    assert_eq!(preview["report"]["task_count"], 1, "{preview}");
    assert!(
        preview["report"]["rules"]
            .as_str()
            .unwrap()
            .contains("### ISO-8601 dates"),
        "{preview}"
    );
    let hash = preview["report"]["source_sha256"]
        .as_str()
        .unwrap()
        .to_string();
    env.json(&[
        "--project",
        &dak,
        "import",
        "--file",
        s(&ledger),
        "--apply",
        "--expect-sha256",
        &hash,
    ]);
    let body = env.json(&["--project", &dak, "show", "DAK-1"])["body"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(
        body.contains("### ISO-8601 dates\nstill the body"),
        "{body}"
    );
    assert!(body.contains("### SHA-256 sums"), "{body}");
}

#[test]
fn t_followed_by_digits_is_never_a_key() {
    for key in ["T12", "t1", "T0", "T123456"] {
        assert!(
            tasks_cli::model::parse_project_key(key).is_err(),
            "{key} accepted"
        );
    }
    assert!(tasks_cli::model::parse_project_key("TA1").is_ok());
    let env = Env::new();
    let root = env.root("app");
    let output = env.run(&["init", "--root", s(&root), "--key", "T12"]);
    assert_eq!(output.status.code(), Some(2), "{}", stderr(&output));
    assert!(stderr(&output).contains("reserved"), "{}", stderr(&output));
    // The CHECK refuses it too, even when written behind the CLI's back.
    let project = env.init("other", "OK");
    let conn = rusqlite::Connection::open(data_root_project_path(&env.data(), &project)).unwrap();
    assert!(conn
        .execute("UPDATE project SET project_key='T12'", [])
        .is_err());
}
