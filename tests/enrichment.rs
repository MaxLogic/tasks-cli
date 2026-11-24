#[path = "support/enrich_base.rs"]
mod enrich_base;
#[path = "support/process.rs"]
#[allow(dead_code)]
mod process;

use rusqlite::Connection;
use tasks_cli::enrich;
use tasks_cli::store::{create_project_db, Store};
use uuid::Uuid;
fn fixture() -> (tempfile::TempDir, Store) {
    let root = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4();
    create_project_db(root.path(), &id).unwrap();
    let mut store = Store::open_rw(root.path(), &id.to_string()).unwrap();
    store
        .create_task(
            "Repair cache Ω",
            "body must not be loaded into the output",
            tasks_cli::model::TaskStatus::Ready,
            vec![],
        )
        .unwrap();
    store
        .create_task(
            "Review security",
            "private body",
            tasks_cli::model::TaskStatus::Done,
            vec![],
        )
        .unwrap();
    (root, store)
}
#[test]
fn enriches_references_preserving_text_and_unknown_ids() {
    let (_root, store) = fixture();
    let input="Ω T001, T-1 and T0002.\r\nAgain T001; unknown T999. AT001 T001suffix T0 T99999999999999999999999999";
    let result = enrich::enrich(&store.conn, input).unwrap();
    assert_eq!(result.text,"Ω T001 (Repair cache Ω), T-1 (Repair cache Ω) and T0002 (Review security).\r\nAgain T001 (Repair cache Ω); unknown T999. AT001 T001suffix T0 T99999999999999999999999999");
    assert_eq!(result.replacements, 4);
    assert_eq!(result.unknown_ids, vec![999]);
    assert!(!result.text.contains("private body"));
    assert_eq!(
        enrich::enrich(&store.conn, &result.text).unwrap().text,
        result.text
    );
    let version: i64 = store
        .conn
        .query_row("SELECT sum(version) FROM tasks", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 2);
}
#[test]
fn handles_large_documents_with_bounded_batches_and_no_database_scan_for_plain_text() {
    let (_root, store) = fixture();
    let input = "ordinary paragraph Ω\r\n".repeat(20000) + "T001";
    let result = enrich::enrich(&store.conn, &input).unwrap();
    assert!(result.text.ends_with("T001 (Repair cache Ω)"));
    assert_eq!(result.replacements, 1);
    let conn = Connection::open_in_memory().unwrap();
    assert_eq!(
        enrich::enrich(&conn, "No task references.").unwrap().text,
        "No task references."
    );
    assert!(enrich::enrich(&conn, &"x".repeat(enrich::MAX_INPUT_BYTES + 1)).is_err());
}
#[test]
fn does_not_rewrite_obvious_urls_or_read_titles_from_inserted_text() {
    let (_root, store) = fixture();
    store
        .conn
        .execute("UPDATE tasks SET title='See T002' WHERE id=1", [])
        .unwrap();
    let result = enrich::enrich(
        &store.conn,
        "https://example.test/T001 [T001](https://example.test/T001) T001",
    )
    .unwrap();
    assert_eq!(
        result.text,
        "https://example.test/T001 [T001 (See T002)](https://example.test/T001) T001 (See T002)"
    );
}

#[test]
fn unknown_ids_inside_existing_annotations_do_not_hide_outside_unknowns() {
    let (_root, store) = fixture();
    store
        .conn
        .execute("UPDATE tasks SET title='See T999' WHERE id=1", [])
        .unwrap();
    let protected = enrich::enrich(&store.conn, "T1 (See T999)").unwrap();
    assert_eq!(protected.text, "T1 (See T999)");
    assert_eq!(protected.replacements, 0);
    assert!(protected.unknown_ids.is_empty(), "{protected:?}");
    let input = "T1 (See T999) and T999";
    let result = enrich::enrich(&store.conn, input).unwrap();
    assert_eq!(result.text, input);
    assert_eq!(result.replacements, 0);
    assert_eq!(result.unknown_ids, vec![999]);
}

#[test]
fn refuses_excessive_title_expansion_without_partial_output() {
    let (_root, store) = fixture();
    store
        .conn
        .execute("UPDATE tasks SET title=?1 WHERE id=1", ["x".repeat(1024)])
        .unwrap();
    assert!(enrich::enrich(&store.conn, &"T001 ".repeat(70000)).is_err());
}

#[test]
fn reserved_prefixes_are_never_task_references() {
    let (_root, store) = fixture();
    let context = enrich::EnrichContext {
        own_key: store.project_key.as_deref(),
        own_project: Some(&store.project_id),
        data_root: Some(&store.data_root),
    };
    let input = "See UTF-8, SHA-256 and ISO-8601 plus T1.";
    let result = enrich::enrich_with(&store.conn, input, context).unwrap();
    assert_eq!(
        result.text,
        "See UTF-8, SHA-256 and ISO-8601 plus T1 (Repair cache Ω)."
    );
    assert_eq!(result.replacements, 1);
    assert!(result.unknown_refs.is_empty(), "{:?}", result.unknown_refs);
    assert!(result.unknown_ids.is_empty(), "{:?}", result.unknown_ids);

    // Reserved-only text must not touch the data-root key scan/cache.
    let cache = store.data_root.join("project-keys.json");
    assert!(!cache.exists(), "no scan should have happened yet");
    let reserved_only = "UTF-8, SHA-256, ISO-8601, IEEE-754, CVE-2024, RFC-822, AES-256, RSA-2048, CRC-32, CWE-79, ECMA-262, CP-1252, X86-64.";
    let result2 = enrich::enrich_with(&store.conn, reserved_only, context).unwrap();
    assert_eq!(result2.text, reserved_only);
    assert_eq!(result2.replacements, 0);
    assert!(
        result2.unknown_refs.is_empty(),
        "{:?}",
        result2.unknown_refs
    );
    assert!(
        !cache.exists(),
        "reserved-only text must not trigger a data-root scan"
    );
}

#[test]
fn enriches_slash_separated_task_references_without_rewriting_paths() {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch("CREATE TABLE tasks(id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
        .unwrap();
    for (id, title) in [(226, "NativeWind"), (227, "Zustand"), (228, "Mobile API")] {
        conn.execute("INSERT INTO tasks(id, title) VALUES (?1, ?2)", (id, title))
            .unwrap();
    }
    let input = "3. **Architecture drift (T-226/T-227/T-228):** spec.md and AGENTS.md say NativeWind, Zustand, and mobile plus API only. The code uses StyleSheet with brand tokens, module-level stores, and also ships a Tauri desktop app. Should the docs change to match the code, or the code to match the docs?";
    let result = enrich::enrich(&conn, input).unwrap();
    assert_eq!(result.replacements, 3);
    assert_eq!(result.unknown_ids, Vec::<u64>::new());
    assert_eq!(
        result.text,
        input.replace(
            "T-226/T-227/T-228",
            "T-226 (NativeWind)/T-227 (Zustand)/T-228 (Mobile API)"
        )
    );

    let paths = "https://example.test/T-226/T-227 C:\\work\\T-228 /T-226/T-227 T-226/file";
    let unchanged = enrich::enrich(&conn, paths).unwrap();
    assert_eq!(unchanged.text, paths);
    assert_eq!(unchanged.replacements, 0);
}

// ---------------------------------------------------------------------------
// TSK-078: list continuation. Fake resolver tables (own key AUTH; EXT is a
// known project, ZZ an unknown one).
// ---------------------------------------------------------------------------

type Table = &'static [(u64, &'static str)];
type Slot = Option<String>;

/// Titles of the current project; several contain references on purpose.
const LOCAL: Table = &[
    (1, "Cache Ω"),
    (2, "Second"),
    (3, "Voir T4"),
    (4, "Fourth"),
    (5, "Nested (T2)"),
    (6, "Voir AUTH-1, 2"),
    (7, "SSO (redirect"),
    (8, "x)/T-3 (y"),
    (20, "Twenty"),
    (40, "Forty"),
    (60, "Sixty"),
    (100, "Hundred"),
    (2024, "Year"),
];
/// Titles without references: every output must be stable on a second pass.
const PLAIN: Table = &[
    (1, "Cache Ω"),
    (2, "Second"),
    (3, "Third"),
    (4, "Fourth"),
    (5, "Fifth (a)"),
    (6, "Sixth (b"),
    (7, "SSO (redirect"),
    (8, "Eighth)"),
    (20, "Twenty"),
    (40, "Forty"),
    (60, "Sixty"),
    (100, "Hundred"),
    (2024, "Year"),
];
const EXT: Table = &[(1, "Ext one"), (2, "Voir T3")];
const EXT_PLAIN: Table = &[(1, "Ext one"), (2, "Ext two")];

fn resolve_with(requests: &enrich::TitleRequests, local: Table) -> enrich::TitleResolution {
    let mut resolution = enrich::TitleResolution::default();
    for (slot, ids) in requests {
        let table = match slot.as_deref() {
            None => local,
            Some("EXT") => {
                resolution.known_keys.insert("EXT".into());
                if local.as_ptr() == PLAIN.as_ptr() {
                    EXT_PLAIN
                } else {
                    EXT
                }
            }
            Some(_) => continue,
        };
        for id in ids {
            if let Some((_, title)) = table.iter().find(|(known, _)| known == id) {
                resolution
                    .titles
                    .insert((slot.clone(), *id), (*title).to_string());
            }
        }
    }
    resolution
}

struct Run {
    result: Result<enrich::EnrichedText, tasks_cli::error::AppError>,
    calls: usize,
    requests: Vec<enrich::TitleRequests>,
}

impl Run {
    fn ok(self) -> enrich::EnrichedText {
        self.result.expect("enrichment succeeds")
    }
    /// Every requested `(slot, id)`.
    fn requested(&self) -> std::collections::BTreeSet<(Slot, u64)> {
        self.requests
            .iter()
            .flat_map(|map| {
                map.iter()
                    .flat_map(|(slot, ids)| ids.iter().map(move |id| (slot.clone(), *id)))
            })
            .collect()
    }
}

fn run_with(input: &str, local: Table) -> Run {
    let mut calls = 0;
    let mut requests = Vec::new();
    let result = enrich::enrich_using(input, Some("AUTH"), |map| {
        calls += 1;
        requests.push(map.clone());
        Ok(resolve_with(map, local))
    });
    Run {
        result,
        calls,
        requests,
    }
}

fn run(input: &str) -> Run {
    run_with(input, LOCAL)
}

/// One pass gives `expected`; a second pass changes nothing.
fn assert_stable(input: &str, expected: &str, local: Table) {
    let first = run_with(input, local).ok();
    assert_eq!(first.text, expected, "first pass of {input:?}");
    let second = run_with(&first.text, local).ok();
    assert_eq!(second.text, first.text, "second pass of {input:?}");
    assert_eq!(second.replacements, 0, "second pass of {input:?}");
}

fn base_run(input: &str, local: Table) -> (enrich::EnrichedText, enrich::TitleRequests) {
    let mut seen = enrich::TitleRequests::new();
    let result = enrich_base::enrich_using(input, Some("AUTH"), |map| {
        seen = map.clone();
        Ok(resolve_with(map, local))
    })
    .unwrap();
    (result, seen)
}

#[test]
fn binding_examples_from_the_task() {
    let (_root, store) = fixture();
    for (id, title) in [
        (16, "Sixteenth"),
        (400, "Last"),
        (438, "Login timeout"),
        (439, "Token refresh"),
        (440, "SSO redirect"),
        (441, "Audit log"),
        (443, "MFA reset"),
        (444, "Session cap"),
    ] {
        add_task(&store, id, title);
    }
    let context = enrich::EnrichContext {
        own_key: Some("AUTH"),
        ..Default::default()
    };
    let enrich_text = |input: &str| enrich::enrich_with(&store.conn, input, context).unwrap();
    let first = enrich_text("AUTH-438–441, 443.");
    assert_eq!(
        first.text,
        "AUTH-438 (Login timeout), AUTH-439 (Token refresh), AUTH-440 (SSO redirect), AUTH-441 (Audit log), AUTH-443 (MFA reset)."
    );
    assert_eq!(first.replacements, 5);
    assert!(first.unknown_refs.is_empty());
    let result = enrich_text("AUTH-443 and 444");
    assert_eq!(
        result.text,
        "AUTH-443 (MFA reset) and AUTH-444 (Session cap)"
    );
    assert_eq!(result.replacements, 2);
    let result = enrich_text("Fixed AUTH-443, 3 tests added");
    assert_eq!(result.text, "Fixed AUTH-443 (MFA reset), 3 tests added");
    assert_eq!(result.replacements, 1);
    let result = enrich_text("AUTH-1–400");
    assert_eq!(result.text, "AUTH-1 (Repair cache Ω)–AUTH-400 (Last)");
    assert_eq!(result.replacements, 2);
    let result = enrich_text("UTF-8, 16");
    assert_eq!(result.text, "UTF-8, 16");
    assert_eq!(result.replacements, 0);
    assert!(result.unknown_ids.is_empty() && result.unknown_refs.is_empty());
    let again = enrich_text(&first.text);
    assert_eq!(again.text, first.text);
    assert_eq!(again.replacements, 0);
    let result = enrich_text("AUTH-441–438");
    assert_eq!(result.text, "AUTH-441 (Audit log)–438");
    assert_eq!(result.replacements, 1);
    // Invalid list numbers end the list.
    let result = enrich_text("AUTH-443, 0, 444");
    assert_eq!(result.text, "AUTH-443 (MFA reset), 0, 444");
    let result = enrich_text("AUTH-443, 9223372036854775808, 444");
    assert_eq!(
        result.text,
        "AUTH-443 (MFA reset), 9223372036854775808, 444"
    );
    // Legacy spellings keep the anchor's prefix as written.
    let result = enrich_text("T-1, 2 and T1, 2.");
    assert_eq!(
        result.text,
        "T-1 (Repair cache Ω), T-2 (Review security) and T1 (Repair cache Ω), T2 (Review security)."
    );
    // The reviewer's re-enrichment case: titles with references and lists.
    add_task(&store, 6, "See T-4 (draft), 2");
    add_task(&store, 3, "Voir T4");
    let twice = enrich_text("T-6, 3.");
    assert_eq!(twice.text, "T-6 (See T-4 (draft), 2), T-3 (Voir T4).");
    let again = enrich_text(&twice.text);
    assert_eq!(again.text, twice.text);
    assert_eq!(again.replacements, 0);
}

#[test]
fn list_ranges_expand_with_fixed_spelling_and_boundaries() {
    // The 50/51 boundary: 50 IDs expand, 51 annotate only their ends.
    let fifty = run("AUTH-1–50 x.");
    assert_eq!(fifty.requested().len(), 50);
    let text = fifty.ok().text;
    assert!(text.starts_with("AUTH-1 (Cache Ω), AUTH-2 (Second), AUTH-3 (Voir T4), AUTH-4 (Fourth), AUTH-5 (Nested (T2)), AUTH-6 (Voir AUTH-1, 2), AUTH-7 (SSO (redirect), AUTH-8 (x)/T-3 (y), AUTH-9, AUTH-10, "));
    assert!(text.ends_with(", AUTH-49, AUTH-50 x."));
    assert!(text.contains(", AUTH-20 (Twenty), ") && text.contains(", AUTH-40 (Forty), "));
    let fifty_one = run("AUTH-1–51 x.");
    assert_eq!(
        fifty_one.requested(),
        [(None, 1), (None, 51)].into_iter().collect()
    );
    let result = fifty_one.ok();
    assert_eq!(result.text, "AUTH-1 (Cache Ω)–51 x.");
    assert_eq!(result.unknown_ids, [51]);
    // Padded spelling: the first and last keep their digits.
    let padded = run_with("AUTH-001-004.", PLAIN).ok();
    assert_eq!(
        padded.text,
        "AUTH-001 (Cache Ω), AUTH-2 (Second), AUTH-3 (Third), AUTH-004 (Fourth)."
    );
    assert_eq!(padded.replacements, 4);
    // A wholly unknown short range stays unchanged and is reported.
    let unknown = run("AUTH-9–11 x").ok();
    assert_eq!(unknown.text, "AUTH-9–11 x");
    assert_eq!(unknown.unknown_ids, [9, 10, 11]);
    assert_eq!(unknown.unknown_refs, ["AUTH-9", "AUTH-10", "AUTH-11"]);
}

#[test]
fn historical_inputs_are_stable_and_paths_equal_base() {
    for (input, expected) in [
        ("T1-2AUTH-4", "T1 (Cache Ω)-2AUTH-4"),
        ("T1-2/T3", "T1-2/T3 (Voir T4)"),
        ("T1/T99, 3.", "T1 (Cache Ω)/T99, 3."),
        ("T1/T3", "T1 (Cache Ω)/T3 (Voir T4)"),
        ("T1-2.json/child.txt", "T1-2.json/child.txt"),
        ("T1-2-3.json/child.txt", "T1-2-3.json/child.txt"),
        ("T1–2.json/child.txt", "T1 (Cache Ω)–2.json/child.txt"),
        ("T-1-2.json/child.txt", "T-1 (Cache Ω)-2.json/child.txt"),
        ("AUTH-1, 2-3.json/x", "AUTH-1 (Cache Ω), 2-3.json/x"),
        ("AUTH-1, 441–438", "AUTH-1 (Cache Ω), 441–438"),
        ("AUTH-2024-11-24", "AUTH-2024 (Year)-11-24"),
        ("AUTH-1, 3–5–7", "AUTH-1 (Cache Ω), 3–5–7"),
        ("AUTH-1–3.json", "AUTH-1 (Cache Ω)–3.json"),
        ("AUTH-1, 2– 3.json", "AUTH-1 (Cache Ω), 2– 3.json"),
        // A range end followed by another dash would start a new range once
        // written out, so the list fails as a whole.
        ("AUTH-1–3 – 100", "AUTH-1 (Cache Ω)–3 – 100"),
        ("AUTH-1 – 3 – 100", "AUTH-1 (Cache Ω) – 3 – 100"),
        (
            "AUTH-1, 2 – 100",
            "AUTH-1 (Cache Ω), AUTH-2 (Second) – AUTH-100 (Hundred)",
        ),
    ] {
        assert_stable(input, expected, LOCAL);
    }
    assert_eq!(run("T1/T99, 3.").ok().unknown_ids, [99]);
    assert_stable(
        "AUTH-1–3 fixed",
        "AUTH-1 (Cache Ω), AUTH-2 (Second), AUTH-3 (Voir T4) fixed",
        LOCAL,
    );
    // Path-like inputs keep the exact base output.
    for input in [
        "T1-2.json/child.txt",
        "T1-2-3.json/child.txt",
        "T1–2.json/child.txt",
        "T-1-2.json/child.txt",
        "T1-2AUTH-4",
        "T1-2/T3",
    ] {
        assert_eq!(
            run(input).ok().text,
            base_run(input, LOCAL).0.text,
            "{input:?}"
        );
    }
    // Invalid keys are never requested; base asks for them.
    let invalid = run("T1-2.json/child.txt");
    assert_eq!(invalid.calls, 0);
    assert!(base_run("T1-2.json/child.txt", LOCAL)
        .1
        .contains_key(&Some("T1".to_string())));
}

#[test]
fn a_list_never_continues_past_a_parenthetical() {
    let (_root, store) = fixture();
    add_task(&store, 3, "SSO (redirect");
    add_task(&store, 4, "Audit log");
    let context = enrich::EnrichContext {
        own_key: Some("AUTH"),
        ..Default::default()
    };
    let input = "AUTH-001 (Repair cache Ω), 3 (SSO (redirect), 4.";
    let result = enrich::enrich_with(&store.conn, input, context).unwrap();
    assert_eq!(result.text, input);
    assert_eq!(result.replacements, 0);
    let bare = enrich::enrich_with(&store.conn, "AUTH-001, 3, 4.", context).unwrap();
    assert_eq!(
        bare.text,
        "AUTH-001 (Repair cache Ω), AUTH-3 (SSO (redirect), AUTH-4 (Audit log)."
    );
    let again = enrich::enrich_with(&store.conn, &bare.text, context).unwrap();
    assert_eq!(again.text, bare.text);
    assert_eq!(again.replacements, 0);
}

#[test]
fn ignored_and_protected_references_do_not_inflate_lookups() {
    // `T-1 (aside), N–M.` x201: one call, only the anchor, no limit error.
    let input: String = (0..201)
        .map(|i| format!("T-1 (aside), {}–{}.\n", i * 50 + 2, i * 50 + 51))
        .collect();
    let probe = run(&input);
    assert_eq!(probe.calls, 1);
    assert_eq!(probe.requested(), [(None, 1)].into_iter().collect());
    assert_eq!(probe.ok().replacements, 201);
    // `/T-N (aside)` x20,001: nothing qualifies, so no lookup at all.
    let input: String = (1..=20_001)
        .map(|n| format!("/T-{n} (aside)\r\n"))
        .collect();
    let probe = run(&input);
    assert_eq!(probe.calls, 0);
    assert_eq!(probe.ok().text, input);
    // Protect-only references count toward the 10,000 limit.
    let input: String = (1..=10_001)
        .map(|n| format!("x)/T-{n} (aside)\n"))
        .collect();
    assert!(matches!(
        run(&input).result,
        Err(tasks_cli::error::AppError::Validation(message)) if message.contains("10000 distinct")
    ));
    // 10,001 anchors followed by parentheticals: bare numbers are not requested.
    let mut input: String = (10..10_011)
        .map(|n| format!("T1 (aside), {n}.\n"))
        .collect();
    input.push_str("T3 (Voir T4), 5.");
    let probe = run(&input);
    assert_eq!(probe.calls, 1);
    assert_eq!(
        probe.requested(),
        [(None, 1), (None, 3), (None, 4)].into_iter().collect()
    );
    let result = probe.ok();
    assert!(result.text.ends_with("\nT3 (Voir T4), 5."));
    assert_eq!(result.replacements, 10_001);
}

#[test]
fn every_list_is_read_in_one_snapshot_with_one_lookup() {
    thread_local! {
        static SELECTS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
        static WRITER: std::cell::RefCell<Option<Connection>> = const { std::cell::RefCell::new(None) };
    }
    fn trace(event: rusqlite::trace::TraceEvent<'_>) {
        let rusqlite::trace::TraceEvent::Stmt(_, sql) = event else {
            return;
        };
        if !sql.contains("SELECT id,title") {
            return;
        }
        let seen = SELECTS.with(|count| {
            count.set(count.get() + 1);
            count.get()
        });
        if seen == 2 {
            WRITER.with(|writer| {
                let writer = writer.borrow();
                let writer = writer.as_ref().expect("writer connection");
                writer
                    .execute_batch("UPDATE tasks SET title = 'new-' || id")
                    .unwrap();
            });
        }
    }
    let (root, store) = fixture();
    for id in 3..=600u64 {
        add_task(&store, id, &format!("old-{id}"));
    }
    store
        .conn
        .execute("UPDATE tasks SET title = 'old-' || id", [])
        .unwrap();
    let reader = Store::open_readonly(root.path(), &store.project_id.to_string()).unwrap();
    WRITER.with(|writer| *writer.borrow_mut() = Some(Connection::open(&store.db_path).unwrap()));
    reader.conn.trace_v2(
        rusqlite::trace::TraceEventCodes::SQLITE_TRACE_STMT,
        Some(trace),
    );
    let input = std::iter::once("T-1".to_string())
        .chain((2..=600).map(|n| n.to_string()))
        .collect::<Vec<_>>()
        .join(", ");
    let result =
        enrich::enrich_with(&reader.conn, &input, enrich::EnrichContext::default()).unwrap();
    WRITER.with(|writer| writer.borrow_mut().take());
    // A second lookup would run two more SELECTs.
    assert_eq!(
        SELECTS.with(|count| count.get()),
        2,
        "one lookup reads two batches: 500 and 100 IDs"
    );
    let committed: String = Connection::open(&store.db_path)
        .unwrap()
        .query_row("SELECT title FROM tasks WHERE id = 600", [], |r| r.get(0))
        .unwrap();
    assert_eq!(committed, "new-600", "the concurrent write committed");
    assert_eq!(result.replacements, 600);
    for n in 1..=600 {
        assert!(result.text.contains(&format!("T-{n} (old-{n})")), "{n}");
    }
    assert!(!result.text.contains("new-"));
}

#[test]
fn unknown_list_items_are_reported_in_struct_and_json() {
    let (root, store) = fixture();
    add_task(&store, 4, "Audit log");
    let input = "T-1, 2–4, 006. T-8–10. ZZ-1–4.";
    let result = enrich::enrich(&store.conn, input).unwrap();
    assert_eq!(
        result.text,
        "T-1 (Repair cache Ω), T-2 (Review security), T-3, T-4 (Audit log), 006. T-8–10. ZZ-1–4."
    );
    assert_eq!(result.replacements, 3);
    assert_eq!(result.unknown_ids, [3, 6, 8, 9, 10]);
    assert_eq!(result.unknown_refs, ["T-3", "T-6", "T-8", "T-9", "T-10"]);
    let input_file = root.path().join("input.txt");
    std::fs::write(&input_file, input).unwrap();
    let output = process::command(env!("CARGO_BIN_EXE_tasks"))
        .arg("--data-root")
        .arg(root.path())
        .arg("--project")
        .arg(store.project_id.to_string())
        .args(["--format", "json", "enrich", "--file"])
        .arg(input_file)
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        json["data"]["unknown_refs"],
        serde_json::json!(result.unknown_refs)
    );
}

#[test]
fn resolves_foreign_lists_in_their_own_project_read_only() {
    let (root, store) = fixture();
    let id = Uuid::new_v4();
    tasks_cli::store::create_project_db_with_key(root.path(), &id, Some("AUTH")).unwrap();
    let foreign = Store::open_rw(root.path(), &id.to_string()).unwrap();
    add_task(&foreign, 1, "Remote login");
    add_task(&foreign, 2, "Remote audit");
    let before: i64 = foreign
        .conn
        .query_row("PRAGMA data_version", [], |r| r.get(0))
        .unwrap();
    let result = enrich::enrich_with(
        &store.conn,
        "AUTH-1 and 2, 3. T-1 and 2.",
        enrich::EnrichContext {
            own_project: Some(&store.project_id),
            data_root: Some(root.path()),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(
        result.text,
        "AUTH-1 (Remote login) and AUTH-2 (Remote audit), 3. T-1 (Repair cache Ω) and T-2 (Review security)."
    );
    assert_eq!(result.replacements, 4);
    assert_eq!(result.unknown_refs, ["AUTH-3"]);
    assert!(result.unknown_ids.is_empty());
    let after: i64 = foreign
        .conn
        .query_row("PRAGMA data_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(before, after);
}

#[test]
fn range_interiors_count_toward_the_distinct_id_limit() {
    let input: String = (0..201)
        .map(|i| format!("T-{}–{}. ", i * 50 + 1, i * 50 + 50))
        .collect();
    let result = enrich::enrich_using(&input, None, |_| Ok(Default::default()));
    assert!(matches!(
        result,
        Err(tasks_cli::error::AppError::Validation(message)) if message.contains("10000 distinct")
    ));
}

#[test]
fn expanded_ranges_cannot_exceed_the_output_limit() {
    let (_root, store) = fixture();
    let title = "x".repeat(500);
    for id in 3..=50 {
        add_task(&store, id, &title);
    }
    let result = enrich::enrich(&store.conn, &"T-1–50. ".repeat(3000));
    assert!(matches!(
        result,
        Err(tasks_cli::error::AppError::Validation(message)) if message.contains("64 MiB")
    ));
}

// ---------------------------------------------------------------------------
// Generators. The structured model below renders each segment from its typed
// description; it never calls the production lexer.
// ---------------------------------------------------------------------------

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Kind {
    Own,
    Ext,
    Zz,
}

fn slot_of(kind: Kind) -> Slot {
    match kind {
        Kind::Own => None,
        Kind::Ext => Some("EXT".into()),
        Kind::Zz => Some("ZZ".into()),
    }
}

fn title_of(kind: Kind, id: u64) -> Option<&'static str> {
    let table = match kind {
        Kind::Own => LOCAL,
        Kind::Ext => EXT,
        Kind::Zz => return None,
    };
    table
        .iter()
        .find(|(known, _)| *known == id)
        .map(|(_, t)| *t)
}

fn reportable(kind: Kind) -> bool {
    kind != Kind::Zz
}

struct AnchorSpec {
    text: &'static str,
    /// The key spelling before the digits: what a written list number gets.
    prefix: &'static str,
    kind: Kind,
    id: u64,
    /// `T5` and `T005` read as the invalid KEY-N key when a `-digit` follows.
    legacy: bool,
}

const ANCHORS: [AnchorSpec; 6] = [
    AnchorSpec {
        text: "T5",
        prefix: "T",
        kind: Kind::Own,
        id: 5,
        legacy: true,
    },
    AnchorSpec {
        text: "T-5",
        prefix: "T-",
        kind: Kind::Own,
        id: 5,
        legacy: false,
    },
    AnchorSpec {
        text: "T005",
        prefix: "T",
        kind: Kind::Own,
        id: 5,
        legacy: true,
    },
    AnchorSpec {
        text: "AUTH-5",
        prefix: "AUTH-",
        kind: Kind::Own,
        id: 5,
        legacy: false,
    },
    AnchorSpec {
        text: "EXT-2",
        prefix: "EXT-",
        kind: Kind::Ext,
        id: 2,
        legacy: false,
    },
    AnchorSpec {
        text: "ZZ-3",
        prefix: "ZZ-",
        kind: Kind::Zz,
        id: 3,
        legacy: false,
    },
];
const SEPS: [&str; 8] = [",", ", ", ", and ", " and ", "-", "–", " – ", "— "];
const TAILS: [&str; 22] = [
    "", ".", ")", ";", " (", ",", " tests", ".json/x", "x", "-3", "/T3", " + 4", " /file", " \\x",
    " #x", " =", " * 2", " & 3", " \"q\"", " 4", " 'q'", " -",
];
const JOINERS: [&str; 4] = ["\n", "\r\n", ". ", "; "];
const NUMBERS: [u64; 16] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 20, 40, 50, 51, 60, 100, 400];
const PATHS: [&str; 7] = [
    "a/T-3",
    "T-3/x",
    "#T3",
    "=T3",
    "C:\\T3",
    "https://x/T-3/T-1",
    "/T-1",
];
// (spelling, kind, id)
const CHAIN_REFS: [(&str, Kind, u64); 7] = [
    ("T-1", Kind::Own, 1),
    ("AUTH-2", Kind::Own, 2),
    ("T3", Kind::Own, 3),
    ("T4", Kind::Own, 4),
    ("T-9", Kind::Own, 9),
    ("EXT-1", Kind::Ext, 1),
    ("ZZ-3", Kind::Zz, 3),
];

fn sep_index_is_hyphen(sep: usize) -> bool {
    SEPS[sep] == "-"
}

fn sep_is_dash(sep: usize) -> bool {
    SEPS[sep].chars().any(|c| matches!(c, '-' | '–' | '—'))
}

#[derive(Clone, Debug)]
enum Seg {
    List {
        anchor: usize,
        elems: Vec<(usize, u64)>,
        tail: usize,
    },
    Chain {
        members: Vec<usize>,
        prefix: usize,
        suffix: usize,
    },
    Pre {
        id: u64,
        exact: bool,
    },
    Protect {
        exact: bool,
    },
    Path(usize),
    /// Fresh text with parentheticals after list numbers and invalid numbers.
    Fresh(usize),
}

#[derive(Default)]
struct SegOut {
    input: String,
    expected: String,
    requests: std::collections::BTreeSet<(Slot, u64)>,
    unknown: std::collections::BTreeSet<(Slot, u64)>,
    replacements: usize,
}

impl SegOut {
    fn plain(input: &str) -> Self {
        Self {
            input: input.into(),
            expected: input.into(),
            ..Default::default()
        }
    }
    fn request(&mut self, kind: Kind, id: u64) {
        self.requests.insert((slot_of(kind), id));
    }
    fn report_if_unknown(&mut self, kind: Kind, id: u64) {
        if title_of(kind, id).is_none() && reportable(kind) {
            self.unknown.insert((slot_of(kind), id));
        }
    }
    /// ` (title)` of a known task; counts the annotation.
    fn annotation(&mut self, kind: Kind, id: u64) -> String {
        let Some(title) = title_of(kind, id) else {
            return String::new();
        };
        self.replacements += 1;
        format!(" ({title})")
    }
}

fn is_word(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

fn model_is_line_break(c: char) -> bool {
    "\n\r\u{b}\u{c}\u{85}\u{2028}\u{2029}".contains(c)
}

/// The boundary check on the text after a list's last element, written over
/// a character vector (the production code works on string slices).
fn model_end_ok(rest: &str, range_end: bool, unspaced_range_end: bool) -> bool {
    let chars: Vec<char> = rest.chars().collect();
    let mut i = 0;
    while i < chars.len() && ",.;:!?)]}".contains(chars[i]) {
        i += 1;
    }
    let closed = i > 0;
    if i < chars.len() && !chars[i].is_whitespace() {
        return false;
    }
    if range_end && !closed {
        let dash = chars[i..]
            .iter()
            .find(|c| !(c.is_whitespace() && !model_is_line_break(**c)));
        if dash.is_some_and(|c| "-–—".contains(*c)) {
            return false;
        }
    }
    if closed || i == chars.len() {
        return true;
    }
    while i < chars.len() && chars[i].is_whitespace() && !model_is_line_break(chars[i]) {
        i += 1;
    }
    if i == chars.len() {
        return true;
    }
    let c = chars[i];
    // An unspaced range end may also be followed by whitespace and a word.
    if unspaced_range_end && is_word(c) {
        return true;
    }
    if model_is_line_break(c) || c == '(' || c == ',' || "-–—".contains(c) {
        return true;
    }
    let word: String = chars[i..].iter().take(3).collect();
    word == "and"
        && chars
            .get(i + 3)
            .is_some_and(|c| c.is_whitespace() && !model_is_line_break(*c))
}

struct Parsed {
    sep: usize,
    num: u64,
    start: usize,
    end: usize,
    range_end: bool,
    spaced: bool,
}

fn model_list(anchor: &AnchorSpec, elems: &[(usize, u64)], tail: usize, following: &str) -> SegOut {
    let tail_text = TAILS[tail];
    let mut raw = anchor.text.to_string();
    let anchor_len = raw.len();
    let mut all: Vec<(usize, u64, usize, usize)> = Vec::new();
    for &(sep, num) in elems {
        raw.push_str(SEPS[sep]);
        let start = raw.len();
        raw.push_str(&num.to_string());
        all.push((sep, num, start, raw.len()));
    }
    let typed_end = raw.len();
    raw.push_str(tail_text);
    let mut out = SegOut::plain(&raw);
    let kind = anchor.kind;
    let after_anchor = format!("{}{}", &raw[anchor_len..], following);
    // No candidate: a word character or (for T5/T005) `-digit` follows.
    if after_anchor.chars().next().is_some_and(is_word) {
        return out;
    }
    // `T5-7` is the KEY-N form with key `T5` when the digits end at a word
    // boundary; `T5-7x` stays the legacy `T5`.
    if anchor.legacy {
        if let Some(digits) = after_anchor.strip_prefix('-') {
            let rest = digits.trim_start_matches(|c: char| c.is_ascii_digit());
            if rest.len() < digits.len() && !rest.chars().next().is_some_and(is_word) {
                // The invalid form still joins a slash chain: `T5-7/T3`.
                if elems.len() == 1 && sep_index_is_hyphen(elems[0].0) && tail_text == "/T3" {
                    let ann = out.annotation(Kind::Own, 3);
                    out.expected = format!("{}/T3{ann}", &raw[..typed_end]);
                    out.request(Kind::Own, 3);
                    out.report_if_unknown(Kind::Own, 3);
                }
                return out;
            }
        }
    }
    // `ANCHOR/T3`: a slash chain of two, no list.
    if elems.is_empty() && tail_text == "/T3" {
        let first = out.annotation(kind, anchor.id);
        let second = out.annotation(Kind::Own, 3);
        out.expected = format!("{}{first}/T3{second}", anchor.text);
        out.request(kind, anchor.id);
        out.request(Kind::Own, 3);
        out.report_if_unknown(kind, anchor.id);
        out.report_if_unknown(Kind::Own, 3);
        return out;
    }
    // The tail `-3` is one more `SEP NUM`.
    if tail_text == "-3" {
        all.push((4, 3, typed_end + 1, typed_end + 2));
    }
    let mut kept: Vec<Parsed> = Vec::new();
    let mut previous = anchor.id;
    let mut previous_range_end = false;
    for &(sep, num, start, end) in &all {
        let next = format!("{}{}", &raw[end..], following);
        if next.chars().next().is_some_and(is_word) {
            break;
        }
        let dash = sep_is_dash(sep);
        if dash && (previous_range_end || num <= previous) {
            break;
        }
        kept.push(Parsed {
            sep,
            num,
            start,
            end,
            range_end: dash,
            spaced: SEPS[sep].contains(' '),
        });
        previous = num;
        previous_range_end = dash;
    }
    while let Some(last) = kept.last() {
        let rest = format!("{}{}", &raw[last.end..], following);
        if model_end_ok(&rest, last.range_end, last.range_end && !last.spaced) {
            break;
        }
        let cut = kept.iter().rposition(|e| e.spaced).unwrap_or(0);
        kept.truncate(cut);
    }
    // Pieces: the anchor, then the kept elements; a range end joins the
    // piece before it.
    let mut units: Vec<Vec<(String, String, u64)>> =
        vec![vec![(String::new(), anchor.text.to_string(), anchor.id)]];
    for element in &kept {
        let piece = (
            SEPS[element.sep].to_string(),
            raw[element.start..element.end].to_string(),
            element.num,
        );
        match (element.range_end, units.last_mut()) {
            (true, Some(unit)) => unit.push(piece),
            _ => units.push(vec![piece]),
        }
    }
    let prefix = anchor.prefix;
    let mut text = String::new();
    out.requests.clear();
    for (index, unit) in units.iter().enumerate() {
        // Only the anchor is already a full reference.
        let bare = index > 0;
        let (first_sep, first_digits, a) = (&unit[0].0, &unit[0].1, unit[0].2);
        let known = |id: u64| title_of(kind, id).is_some();
        let full = |digits: &str, id: u64| {
            if bare && known(id) {
                format!("{prefix}{digits}")
            } else {
                digits.to_string()
            }
        };
        match unit.get(1) {
            None => {
                out.request(kind, a);
                out.report_if_unknown(kind, a);
                let ann = out.annotation(kind, a);
                text.push_str(&format!("{first_sep}{}{ann}", full(first_digits, a)));
            }
            Some((last_sep, last_digits, b)) => {
                let b = *b;
                let last_full = |digits: &str, id: u64| {
                    if known(id) {
                        format!("{prefix}{digits}")
                    } else {
                        digits.to_string()
                    }
                };
                if b - a < 50 {
                    for id in a..=b {
                        out.request(kind, id);
                        out.report_if_unknown(kind, id);
                    }
                    if (a..=b).any(known) {
                        // Inside an expanded range every element is a full reference.
                        let first_full = if bare {
                            format!("{prefix}{first_digits}")
                        } else {
                            first_digits.to_string()
                        };
                        text.push_str(&format!("{first_sep}{first_full}"));
                        let ann = out.annotation(kind, a);
                        text.push_str(&ann);
                        for id in a + 1..b {
                            let ann = out.annotation(kind, id);
                            text.push_str(&format!(", {prefix}{id}{ann}"));
                        }
                        let ann = out.annotation(kind, b);
                        text.push_str(&format!(", {prefix}{last_digits}{ann}"));
                    } else {
                        text.push_str(&format!("{first_sep}{first_digits}{last_sep}{last_digits}"));
                    }
                } else {
                    for id in [a, b] {
                        out.request(kind, id);
                        out.report_if_unknown(kind, id);
                    }
                    let ann_a = out.annotation(kind, a);
                    let ann_b = out.annotation(kind, b);
                    text.push_str(&format!(
                        "{first_sep}{}{ann_a}{last_sep}{}{ann_b}",
                        full(first_digits, a),
                        last_full(last_digits, b)
                    ));
                }
            }
        }
    }
    let used = kept.last().map_or(anchor_len, |e| e.end);
    text.push_str(&raw[used..]);
    out.expected = text;
    out
}

fn model_segment(seg: &Seg, following: &str) -> SegOut {
    match seg {
        Seg::List {
            anchor,
            elems,
            tail,
        } => model_list(&ANCHORS[*anchor], elems, *tail, following),
        Seg::Chain {
            members,
            prefix,
            suffix,
        } => {
            let prefix_text = ["", "https://x/", "a/"][*prefix];
            let suffix_text = ["", "/file"][*suffix];
            let spelled: Vec<&str> = members.iter().map(|m| CHAIN_REFS[*m].0).collect();
            let input = format!("{prefix_text}{}{suffix_text}", spelled.join("/"));
            let mut out = SegOut::plain(&input);
            if *prefix == 0 && *suffix == 0 {
                let mut parts = Vec::new();
                for &m in members {
                    let (spelling, kind, id) = CHAIN_REFS[m];
                    out.request(kind, id);
                    out.report_if_unknown(kind, id);
                    let ann = out.annotation(kind, id);
                    parts.push(format!("{spelling}{ann}"));
                }
                out.expected = parts.join("/");
            }
            out
        }
        Seg::Pre { id, exact } => {
            let title = title_of(Kind::Own, *id).expect("known");
            let mut out = SegOut::plain("");
            out.request(Kind::Own, *id);
            if *exact {
                if title.chars().any(|c| c.is_ascii_digit()) {
                    // `Voir T4` holds T4, `Nested (T2)` holds T2.
                    out.request(Kind::Own, if title.contains("T4") { 4 } else { 2 });
                }
                out.input = format!("T{id} ({title})");
                out.expected = out.input.clone();
            } else {
                out.request(Kind::Own, 4);
                out.input = format!("T{id} (Other T4)");
                out.expected = format!("T{id} ({title}) (Other T4 (Fourth))");
                out.replacements = 2;
            }
            out
        }
        Seg::Protect { exact } => {
            let mut out = SegOut::plain("");
            out.request(Kind::Own, 3);
            out.request(Kind::Own, 4);
            if *exact {
                out.input = "x)/T-3 (Voir T4)".into();
                out.expected = out.input.clone();
            } else {
                out.input = "x)/T-3 (Other T4)".into();
                out.expected = "x)/T-3 (Other T4 (Fourth))".into();
                out.replacements = 1;
            }
            out
        }
        Seg::Path(i) => SegOut::plain(PATHS[*i]),
        Seg::Fresh(i) => {
            let (input, expected, requested, replacements) = FRESH[*i];
            let mut out = SegOut::plain(input);
            out.expected = expected.into();
            out.replacements = replacements;
            for id in requested {
                out.request(Kind::Own, *id);
            }
            out
        }
    }
}

// (input, expected, requested IDs, replacements). A list never continues past
// a parenthetical, so numbers after one stay bare; references inside any
// parenthetical are annotated as in base.
const FRESH: [(&str, &str, &[u64], usize); 5] = [
    (
        "T-1 (see notes), 3 (T-4 fix)",
        "T-1 (Cache Ω) (see notes), 3 (T-4 (Fourth) fix)",
        &[1, 4],
        2,
    ),
    (
        "T-1 (aside), 0 (T-4).",
        "T-1 (Cache Ω) (aside), 0 (T-4 (Fourth)).",
        &[1, 4],
        2,
    ),
    ("T-1, 0, 2", "T-1 (Cache Ω), 0, 2", &[1], 1),
    (
        "T-1 (x), 2 (y) and 3 (T-4 z) (T-2)",
        "T-1 (Cache Ω) (x), 2 (y) and 3 (T-4 (Fourth) z) (T-2 (Second))",
        &[1, 2, 4],
        3,
    ),
    (
        "T-1 (see T-4)",
        "T-1 (Cache Ω) (see T-4 (Fourth))",
        &[1, 4],
        2,
    ),
];

fn raw_of(seg: &Seg) -> String {
    model_segment(seg, "\n").input
}

fn random_segment(rng: &mut Rng) -> Seg {
    match rng.below(20) {
        0..=9 => {
            let count = rng.below(5);
            Seg::List {
                anchor: rng.below(ANCHORS.len()),
                elems: (0..count)
                    .map(|_| (rng.below(SEPS.len()), NUMBERS[rng.below(NUMBERS.len())]))
                    .collect(),
                tail: rng.below(TAILS.len()),
            }
        }
        10..=12 => Seg::Chain {
            members: (0..2 + rng.below(2))
                .map(|_| rng.below(CHAIN_REFS.len()))
                .collect(),
            prefix: rng.below(3),
            suffix: rng.below(2),
        },
        13..=14 => Seg::Pre {
            id: [1, 3, 5][rng.below(3)],
            exact: rng.below(2) == 0,
        },
        15..=16 => Seg::Protect {
            exact: rng.below(2) == 0,
        },
        17 => Seg::Fresh(rng.below(FRESH.len())),
        _ => Seg::Path(rng.below(PATHS.len())),
    }
}

/// Runs one document built from typed segments and checks all four outputs.
fn check_document(segments: &[Seg], joiners: &[usize], context: &str) {
    let raws: Vec<String> = segments.iter().map(raw_of).collect();
    let mut input = String::new();
    let mut expected = String::new();
    let mut requests = std::collections::BTreeSet::new();
    let mut unknown = std::collections::BTreeSet::new();
    let mut replacements = 0;
    for (i, seg) in segments.iter().enumerate() {
        let mut following = String::new();
        for k in i + 1..segments.len() {
            following.push_str(JOINERS[joiners[k - 1]]);
            following.push_str(&raws[k]);
        }
        let out = model_segment(seg, &following);
        assert_eq!(out.input, raws[i], "{context}");
        input.push_str(&out.input);
        expected.push_str(&out.expected);
        if i + 1 < segments.len() {
            input.push_str(JOINERS[joiners[i]]);
            expected.push_str(JOINERS[joiners[i]]);
        }
        requests.extend(out.requests);
        unknown.extend(out.unknown);
        replacements += out.replacements;
    }
    let probe = run(&input);
    let calls = probe.calls;
    let seen = probe.requested();
    let result = probe.ok();
    assert_eq!(result.text, expected, "{context}: text of {input:?}");
    assert_eq!(result.replacements, replacements, "{context}: {input:?}");
    assert_eq!(seen, requests, "{context}: requests of {input:?}");
    assert_eq!(calls, usize::from(!requests.is_empty()), "{context}");
    let unknown_ids: Vec<u64> = unknown
        .iter()
        .filter(|(slot, _)| slot.is_none())
        .map(|(_, id)| *id)
        .collect();
    let unknown_refs: Vec<String> = unknown
        .iter()
        .map(|(slot, id)| format!("{}-{id}", slot.as_deref().unwrap_or("AUTH")))
        .collect();
    assert_eq!(result.unknown_ids, unknown_ids, "{context}: {input:?}");
    assert_eq!(result.unknown_refs, unknown_refs, "{context}: {input:?}");
    {
        let second = run(&result.text).ok();
        assert_eq!(
            second.text, result.text,
            "{context}: second pass of {input:?}"
        );
        assert_eq!(second.replacements, 0, "{context}: {input:?}");
        assert!(
            second
                .unknown_refs
                .iter()
                .all(|r| result.unknown_refs.contains(r)),
            "{context}: second-pass unknowns of {input:?}"
        );
    }
}

#[test]
fn structured_model_places_titles_requests_and_reports() {
    // Exhaustive: anchor x separator x element form x tail.
    let mut cases = 0;
    for (anchor, spec) in ANCHORS.iter().enumerate() {
        for sep in 0..SEPS.len() {
            for delta in [2u64, 4, 49, 50, 99] {
                for tail in 0..TAILS.len() {
                    let segment = Seg::List {
                        anchor,
                        elems: vec![(sep, spec.id + delta)],
                        tail,
                    };
                    check_document(&[segment], &[0], "exhaustive");
                    cases += 1;
                }
            }
        }
    }
    assert_eq!(cases, 6 * 8 * 5 * TAILS.len());
    // Seeded documents of 1-8 segments.
    const SEED: u64 = 0x5453_4b30_3738;
    let mut rng = Rng(SEED);
    for case in 0..4096 {
        let count = 1 + rng.below(8);
        let segments: Vec<Seg> = (0..count).map(|_| random_segment(&mut rng)).collect();
        let joiners: Vec<usize> = (0..count).map(|_| rng.below(JOINERS.len())).collect();
        check_document(
            &segments,
            &joiners,
            &format!("seed {SEED:#x} case {case} {segments:?}"),
        );
        cases += 1;
    }
    eprintln!("model cases {cases}, second pass checked for every case");
}

const SOUP: &[&str] = &[
    "T1",
    "T-2",
    "T3",
    "T5",
    "AUTH-4",
    "AUTH-1",
    "EXT-1",
    "ZZ-3",
    "UTF-8",
    "T1-2",
    "1",
    "2",
    "3",
    "5",
    "006",
    "9",
    "8",
    "7",
    "6",
    "10",
    "11",
    "12",
    "50",
    "51",
    "400",
    ",",
    ", ",
    " and ",
    ", and ",
    "–",
    " — ",
    "-",
    " - ",
    " ",
    ".",
    "; ",
    "(",
    ")",
    "/",
    "\\",
    ".json/",
    "\n",
    "\r\n",
    "Ω",
    "see",
    "#",
    "=",
    "+",
    "*",
    "&",
    "\"",
    "'",
    " + ",
    " / ",
    " \\ ",
    " # ",
    " = ",
    " * ",
    " - ",
    " & ",
    " \"",
    " (Cache Ω)",
    " (Second)",
    " (Third)",
    " (Voir T4)",
    " (Nested (T2))",
];

fn soup(rng: &mut Rng) -> String {
    (0..1 + rng.below(16))
        .map(|_| SOUP[rng.below(SOUP.len())])
        .collect()
}

#[test]
fn free_mix_property_never_fails_calls_once_and_is_stable() {
    const SEED: u64 = 0x5453_4b30_3739;
    let mut rng = Rng(SEED);
    let mut cases = 0;
    for case in 0..4096 {
        let input = soup(&mut rng);
        let context = format!("seed {SEED:#x} case {case} {input:?}");
        for local in [LOCAL, PLAIN, HARD] {
            let probe = run_with(&input, local);
            assert!(probe.calls <= 1, "{context}");
            let first = probe.ok();
            let second = run_with(&first.text, local).ok();
            assert_eq!(second.text, first.text, "{context}: second pass");
            assert_eq!(second.replacements, 0, "{context}: second pass");
        }
        // Without titles nothing is written.
        let mut calls = 0;
        let bare = enrich::enrich_using(&input, Some("AUTH"), |_| {
            calls += 1;
            Ok(Default::default())
        })
        .unwrap();
        assert!(calls <= 1, "{context}");
        assert_eq!(bare.text, input, "{context}");
        assert_eq!(bare.replacements, 0, "{context}");
        cases += 1;
    }
    eprintln!("free mix: {cases} cases x 3 title tables");
    assert_eq!(cases, 4096);
}

const BASE_FRAGMENTS: &[&str] = &[
    "T1",
    "T-2",
    "T3",
    "AUTH-4",
    "AUTH-5",
    "EXT-1",
    "EXT-2",
    "ZZ-3",
    "UTF-8",
    "SHA-256",
    "T1-2",
    "T12-3",
    "T99",
    "T-100",
    "/",
    "https://x/",
    "#",
    "=",
    "\\",
    "a/",
    "/file",
    ".json/",
    " ",
    ", ",
    " and ",
    "-",
    "–",
    ". ",
    "\n",
    "\r\n",
    "(",
    ")",
    ")/",
    "x",
    "Ω",
    "see",
    " (Cache Ω)",
    " (Second)",
    " (Voir T4)",
    " (Other T4)",
    " (Nested (T2))",
    " (Fourth)",
];

#[test]
fn base_differential_on_inputs_without_bare_numbers() {
    const SEED: u64 = 0x5453_4b30_373a;
    let mut rng = Rng(SEED);
    let (mut compared, mut protect_shaped) = (0, 0);
    for case in 0..4096 {
        let input: String = (0..1 + rng.below(14))
            .map(|_| BASE_FRAGMENTS[rng.below(BASE_FRAGMENTS.len())])
            .collect();
        let context = format!("seed {SEED:#x} case {case} {input:?}");
        let probe = run(&input);
        let new_requests = probe.requests.first().cloned().unwrap_or_default();
        let new = probe.ok();
        // Base is not idempotent on `)/` shapes; the new code must be.
        let second = run(&new.text).ok();
        assert_eq!(second.text, new.text, "{context}: second pass");
        assert_eq!(second.replacements, 0, "{context}: second pass");
        if input.contains(")/") {
            // Accepted difference: protect-only references (base defect).
            protect_shaped += 1;
            continue;
        }
        let (base, base_requests) = base_run(&input, LOCAL);
        assert_eq!(new.text, base.text, "{context}");
        assert_eq!(new.replacements, base.replacements, "{context}");
        assert_eq!(new.unknown_ids, base.unknown_ids, "{context}");
        assert_eq!(new.unknown_refs, base.unknown_refs, "{context}");
        // Accepted difference: slots failing `parse_project_key` are not requested.
        let expected_requests: enrich::TitleRequests = base_requests
            .into_iter()
            .filter(|(slot, _)| {
                slot.as_deref()
                    .is_none_or(|key| tasks_cli::model::parse_project_key(key).is_ok())
            })
            .collect();
        assert_eq!(new_requests, expected_requests, "{context}");
        compared += 1;
    }
    eprintln!("base differential: compared {compared}, protect-shaped excluded {protect_shaped}");
    assert!(compared > 2000, "{compared} compared");
}

fn add_task(store: &Store, id: u64, title: &str) {
    store
        .conn
        .execute(
            "INSERT INTO tasks (id, title, body, status, version, created_ms, updated_ms)
             VALUES (?1, ?2, '', 'todo', 1, 0, 0)",
            (id, title),
        )
        .unwrap();
}

/// Titles that broke re-enrichment of the bare-number output (review r3):
/// nested, unbalanced, early-closing and multiline titles that hold references.
const HARD: Table = &[
    (1, "Cache Ω"),
    (3, "Voir T4"),
    (4, "Fourth"),
    (6, "See T-4 (draft), 2"),
    (7, "SSO (redirect"),
    (8, "x)/T-3 (y"),
    (9, "Line one\nT-4 tail"),
    (10, "early ) close T-4"),
    (11, "A (b"),
    (12, "nested ((T-4)), 3"),
];

#[test]
fn full_references_make_re_enrichment_safe_for_hard_titles() {
    assert_stable("T-6, 3.", "T-6 (See T-4 (draft), 2), T-3 (Voir T4).", HARD);
    assert_stable(
        "AUTH-6, 7 and 8.",
        "AUTH-6 (See T-4 (draft), 2), AUTH-7 (SSO (redirect) and AUTH-8 (x)/T-3 (y).",
        HARD,
    );
    assert_stable(
        "AUTH-1, 9, 10.",
        "AUTH-1 (Cache Ω), AUTH-9 (Line one\nT-4 tail), AUTH-10 (early ) close T-4).",
        HARD,
    );
    assert_stable(
        "T1, 11, 12",
        "T1 (Cache Ω), T11 (A (b), T12 (nested ((T-4)), 3)",
        HARD,
    );
    assert_stable(
        "T-1, 3–8, 12.",
        "T-1 (Cache Ω), T-3 (Voir T4), T-4 (Fourth), T-5, T-6 (See T-4 (draft), 2), T-7 (SSO (redirect), T-8 (x)/T-3 (y), T-12 (nested ((T-4)), 3).",
        HARD,
    );
    // Every title of the table, alone and in lists, is stable.
    for (id, _) in HARD {
        for input in [
            format!("T-{id}"),
            format!("AUTH-1, {id}."),
            format!("AUTH-{id}–{}.", id + 1),
            format!("T{id} and {}", id + 2),
        ] {
            let first = run_with(&input, HARD).ok();
            let second = run_with(&first.text, HARD).ok();
            assert_eq!(second.text, first.text, "{input:?}");
            assert_eq!(second.replacements, 0, "{input:?}");
        }
    }
}

#[test]
fn invalid_list_numbers_end_the_list_without_hiding_references() {
    for (input, expected) in [
        ("T-1, 0, 2", "T-1 (Cache Ω), 0, 2"),
        (
            "T-1, 9223372036854775808, 2",
            "T-1 (Cache Ω), 9223372036854775808, 2",
        ),
        (
            "T-1 (aside), 0 (T-4).",
            "T-1 (Cache Ω) (aside), 0 (T-4 (Fourth)).",
        ),
        (
            "T-1 (aside), 9223372036854775808 (T-4)",
            "T-1 (Cache Ω) (aside), 9223372036854775808 (T-4 (Fourth))",
        ),
    ] {
        assert_stable(input, expected, LOCAL);
    }
}

#[test]
fn written_list_numbers_keep_digits_and_unknown_ones_stay_bare() {
    assert_stable(
        "T005, 3 and 0004.",
        "T005 (Nested (T2)), T3 (Voir T4) and T0004 (Fourth).",
        LOCAL,
    );
    assert_stable(
        "AUTH-001, 99, 3 and 0098",
        "AUTH-001 (Cache Ω), 99, AUTH-3 (Voir T4) and 0098",
        LOCAL,
    );
    let result = run("AUTH-001, 99, 3 and 0098").ok();
    assert_eq!(result.unknown_ids, [98, 99]);
    assert_eq!(result.unknown_refs, ["AUTH-98", "AUTH-99"]);
    // Inside an expanded range every element is a full reference, including
    // unknown ends; unknown numbers outside one stay as written.
    assert_stable("AUTH-19–21.", "AUTH-19, AUTH-20 (Twenty), AUTH-21.", LOCAL);
    assert_stable(
        "AUTH-1, 19–21, 99.",
        "AUTH-1 (Cache Ω), AUTH-19, AUTH-20 (Twenty), AUTH-21, 99.",
        LOCAL,
    );
    assert_eq!(run("AUTH-19–21.").ok().unknown_ids, [19, 21]);
    assert_stable("AUTH-9–60 x", "AUTH-9–AUTH-60 (Sixty) x", LOCAL);
    assert_stable("AUTH-9–11 x", "AUTH-9–11 x", LOCAL);
    assert_stable(
        "AUTH-1–3 and 20–22.",
        "AUTH-1 (Cache Ω), AUTH-2 (Second), AUTH-3 (Voir T4) and AUTH-20 (Twenty), AUTH-21, AUTH-22.",
        LOCAL,
    );
}

#[test]
fn compact_repeated_ids_fail_the_output_limit_early_and_stay_correct_below_it() {
    fn titles(map: &enrich::TitleRequests) -> enrich::TitleResolution {
        let mut resolution = enrich::TitleResolution::default();
        for (slot, ids) in map {
            for id in ids {
                let title = if *id == 1 { "One" } else { "Two" };
                resolution
                    .titles
                    .insert((slot.clone(), *id), title.to_string());
            }
        }
        resolution
    }
    // 16 MiB of `,2`: two distinct IDs, about 8 million occurrences. The output
    // would be five times larger than the 64 MiB limit.
    let huge = format!("T-1{}.", ",2".repeat((enrich::MAX_INPUT_BYTES - 4) / 2));
    assert!(huge.len() <= enrich::MAX_INPUT_BYTES);
    let mut calls = 0;
    let result = enrich::enrich_using(&huge, None, |map| {
        calls += 1;
        assert_eq!(map.values().map(Vec::len).sum::<usize>(), 2);
        Ok(titles(map))
    });
    assert!(matches!(
        result,
        Err(tasks_cli::error::AppError::Validation(message)) if message.contains("64 MiB")
    ));
    assert_eq!(calls, 1);
    // Below the limit every occurrence is a full reference.
    let input = format!("T-1{}.", ",2".repeat(1_000_000));
    let result = enrich::enrich_using(&input, None, |map| Ok(titles(map))).unwrap();
    assert_eq!(result.replacements, 1_000_001);
    assert_eq!(result.text.len(), 9 + 1_000_000 * 10 + 1);
    assert!(result.text.starts_with("T-1 (One),T-2 (Two),T-2 (Two),"));
    assert!(result.text.ends_with(",T-2 (Two)."));
    let again = enrich::enrich_using(&result.text, None, |map| Ok(titles(map))).unwrap();
    assert_eq!(again.replacements, 0);
    assert_eq!(again.text, result.text);
}

#[test]
fn output_limit_uses_the_exact_emitted_size() {
    // Every spaced range drops its separator, so a long gap makes the input
    // far larger than the part of the output that depends on it.
    const LIMIT: usize = 64 * 1024 * 1024;
    let resolve = |map: &enrich::TitleRequests, tail_title: usize| {
        let mut resolution = enrich::TitleResolution::default();
        for (slot, ids) in map {
            for id in ids {
                let title = if *id == 51 {
                    "z".repeat(tail_title)
                } else {
                    "x".repeat(400)
                };
                resolution.titles.insert((slot.clone(), *id), title);
            }
        }
        resolution
    };
    let input = |ranges: usize, gap: usize| {
        format!(
            "{}T-1{}–3.\nT-51",
            "T-1–50.\n".repeat(ranges),
            " ".repeat(gap)
        )
    };
    let size = |ranges: usize, tail_title: usize| {
        let text = input(ranges, 1);
        enrich::enrich_using(&text, None, |map| Ok(resolve(map, tail_title)))
            .unwrap()
            .text
            .len()
    };
    let one = size(1, 1);
    let block = size(2, 1) - one;
    let ranges = 1 + (LIMIT - 1 - one) / block;
    let tail_title = 1 + LIMIT - size(ranges, 1);
    assert_eq!(size(ranges, tail_title), LIMIT);
    let long = input(ranges, 8 * 1024 * 1024);
    assert!(long.len() > LIMIT / 8 && long.len() <= enrich::MAX_INPUT_BYTES);
    let exact = enrich::enrich_using(&long, None, |map| Ok(resolve(map, tail_title))).unwrap();
    assert_eq!(exact.text.len(), LIMIT);
    let over = enrich::enrich_using(&long, None, |map| Ok(resolve(map, tail_title + 1)));
    assert!(matches!(
        over,
        Err(tasks_cli::error::AppError::Validation(message)) if message.contains("64 MiB")
    ));
}

#[test]
fn an_unspaced_range_end_is_followed_only_by_a_word_or_a_normal_boundary() {
    for tail in [
        " + 4", " /file", " \\x", " #x", " = 1", " * 2", " & 3", " \"q\"", " 'q'", " -",
    ] {
        let input = format!("T-1–3{tail}");
        let out = run(&input).ok();
        assert!(
            out.text.starts_with("T-1 (Cache Ω)–3"),
            "{input:?} -> {:?}",
            out.text
        );
    }
    // A word still qualifies, like the normal boundaries do.
    assert!(run("T-1–3 tests")
        .ok()
        .text
        .starts_with("T-1 (Cache Ω), T-2 (Second)"));
    // A word is Unicode `\w`, listed here independently of the code: letters,
    // combining marks, decimal digits, connector punctuation and join controls
    // start a word; other numbers (superscripts, fractions), symbols and
    // spacing punctuation do not.
    for (tail, expands) in [
        (" é", true),
        (" Ωmega", true),
        (" \u{0301}x", true),    // combining acute accent (Mn)
        (" \u{200D}x", true),    // zero-width joiner (Join_Control)
        (" \u{203F}name", true), // undertie (Pc)
        (" _x", true),
        (" \u{0663}", true), // Arabic-Indic digit three (Nd)
        (" ²", false),       // superscript two (No)
        (" ½", false),       // vulgar fraction one half (No)
        (" €", false),       // euro sign (Sc)
        (" «q»", false),     // guillemet (Pi)
    ] {
        let input = format!("T-1–3{tail}");
        let expected = if expands {
            "T-1 (Cache Ω), T-2 (Second)"
        } else {
            "T-1 (Cache Ω)–3"
        };
        let first = run(&input).ok();
        assert!(
            first.text.starts_with(expected),
            "{input:?} -> {:?}",
            first.text
        );
        let second = run(&first.text).ok();
        assert_eq!(second.text, first.text, "second pass of {input:?}");
        assert_eq!(second.replacements, 0, "second pass of {input:?}");
    }
}
