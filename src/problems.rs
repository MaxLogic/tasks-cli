//! Cross-file import problem analysis.
//!
//! A preview never stops at the first problem: every nonconforming Deps line,
//! every unknown or self-referencing dependency, every unmapped task-bearing
//! section, every unassigned content range, every duplicate ID and every
//! dependency cycle group of the whole import set is collected in one pass.

use crate::markdown::ParsedImport;
use crate::model::{
    ImportProblem, BODY_MAX_BYTES, MAX_DEPENDENCIES, PROBLEM_CYCLE, PROBLEM_NONCONFORMING_DEPS,
    PROBLEM_OTHER, PROBLEM_UNKNOWN_DEPENDENCY, RULES_MAX_BYTES, TITLE_MAX_CHARS,
};
use std::collections::{HashMap, HashSet, VecDeque};

/// Analyze one import set: a single-file import, or one bulk candidate with all
/// of its ledger files.
pub fn analyze(sources: &[&ParsedImport]) -> Vec<ImportProblem> {
    let mut problems = Vec::new();
    for parsed in sources {
        problems.extend(parsed.parse_problems.iter().cloned());
    }
    for parsed in sources {
        problems.extend(
            parsed
                .deps_problems
                .iter()
                .filter(|problem| problem.kind == PROBLEM_NONCONFORMING_DEPS)
                .cloned(),
        );
    }
    for parsed in sources {
        problems.extend(
            parsed
                .deps_problems
                .iter()
                .filter(|problem| {
                    problem.kind == PROBLEM_UNKNOWN_DEPENDENCY
                        || problem.kind == crate::model::PROBLEM_SELF_DEPENDENCY
                })
                .cloned(),
        );
    }
    for parsed in sources {
        problems.extend(
            parsed
                .deps_problems
                .iter()
                .filter(|problem| problem.kind == PROBLEM_OTHER)
                .cloned(),
        );
    }
    for parsed in sources {
        problems.extend(other_problems(parsed));
    }
    for parsed in sources {
        problems.extend(task_limit_problems(parsed));
    }
    for parsed in sources {
        problems.extend(size_problems(parsed));
    }
    problems.extend(rules_size_problems(sources));
    problems.extend(unresolved_dependency_problems(sources));
    problems.extend(cross_file_duplicate_problems(sources));
    problems.extend(duplicate_source_hash_problems(sources));
    problems.extend(cycle_problems(sources));
    problems
}

/// Dependencies carried in `task.deps` that resolve to no task of the import
/// set, and self-references. The create-task resolver strips both before they
/// reach a task's deps, so this covers the canonical metadata form; import
/// apply rejects the same set through its dependency-existence and cycle
/// checks.
fn unresolved_dependency_problems(sources: &[&ParsedImport]) -> Vec<ImportProblem> {
    let known: HashSet<u64> = sources
        .iter()
        .flat_map(|parsed| parsed.tasks.iter().map(|task| task.id))
        .collect();
    let mut problems = Vec::new();
    for parsed in sources {
        let name = &parsed.source_name;
        for task in &parsed.tasks {
            let id = format!("T-{:03}", task.id);
            for dep in &task.deps {
                if *dep == task.id {
                    problems.push(ImportProblem {
                        kind: crate::model::PROBLEM_SELF_DEPENDENCY.to_string(),
                        message: format!(
                            "{id} at {name}:{} lists itself in its dependency list; fix: remove {id} from the list",
                            task.heading_line
                        ),
                        file: Some(name.clone()),
                        line: Some(task.heading_line),
                        task_id: Some(task.id),
                        value: None,
                        keepable_ids: Vec::new(),
                        group: Vec::new(),
                        fix: Some(format!("remove {id} from the dependency list")),
                    });
                } else if !known.contains(dep) {
                    problems.push(ImportProblem {
                        kind: PROBLEM_UNKNOWN_DEPENDENCY.to_string(),
                        message: format!(
                            "{id} at {name}:{} depends on T-{dep:03}, which is in neither the import set nor the project; fix: remove T-{dep:03} from the dependency list or add that task to the ledger",
                            task.heading_line
                        ),
                        file: Some(name.clone()),
                        line: Some(task.heading_line),
                        task_id: Some(task.id),
                        value: None,
                        keepable_ids: Vec::new(),
                        group: Vec::new(),
                        fix: Some(format!(
                            "remove T-{dep:03} from the dependency list; no such task exists"
                        )),
                    });
                }
            }
        }
    }
    problems
}

/// Title and body limits that create, update and import apply all enforce.
/// Import apply runs the same analysis before its transaction, so a preview
/// reporting no problem cannot fail apply for an oversized task.
fn size_problems(parsed: &ParsedImport) -> Vec<ImportProblem> {
    let name = &parsed.source_name;
    let mut problems = Vec::new();
    for task in &parsed.tasks {
        let id = format!("T-{:03}", task.id);
        let title_len = task.title.chars().count();
        if title_len == 0 {
            problems.push(ImportProblem {
                kind: PROBLEM_OTHER.to_string(),
                message: format!(
                    "{id} at {name}:{} has an empty title; give the task a non-empty title.",
                    task.heading_line
                ),
                file: Some(name.clone()),
                line: Some(task.heading_line),
                task_id: Some(task.id),
                value: None,
                keepable_ids: Vec::new(),
                group: Vec::new(),
                fix: Some("give the task a non-empty title".to_string()),
            });
        }
        if title_len > TITLE_MAX_CHARS {
            problems.push(ImportProblem {
                kind: PROBLEM_OTHER.to_string(),
                message: format!(
                    "{id} at {name}:{} has a title of {title_len} characters; the limit is {TITLE_MAX_CHARS}. Shorten the title.",
                    task.heading_line
                ),
                file: Some(name.clone()),
                line: Some(task.heading_line),
                task_id: Some(task.id),
                value: None,
                keepable_ids: Vec::new(),
                group: Vec::new(),
                fix: Some("shorten the title".to_string()),
            });
        }
        if task.body.len() > BODY_MAX_BYTES {
            problems.push(ImportProblem {
                kind: PROBLEM_OTHER.to_string(),
                message: format!(
                    "{id} at {name}:{} has a body of {} bytes; the limit is {BODY_MAX_BYTES}. Trim the body.",
                    task.heading_line,
                    task.body.len()
                ),
                file: Some(name.clone()),
                line: Some(task.heading_line),
                task_id: Some(task.id),
                value: None,
                keepable_ids: Vec::new(),
                group: Vec::new(),
                fix: Some("trim the body".to_string()),
            });
        }
    }
    problems
}

/// The shared rules of one import set, combined exactly as import apply stores
/// them. Canonical framed rules preserve their byte-exact body; legacy rules
/// retain the historical boundary trimming. Multiple sources are joined with
/// two LF separators in source order.
pub fn combined_rules(sources: &[&ParsedImport]) -> String {
    sources
        .iter()
        .map(|parsed| {
            if parsed.has_canonical_rules_frame {
                parsed.rules.as_str()
            } else {
                parsed.rules.trim_matches(['\r', '\n'])
            }
        })
        .filter(|rules| !rules.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// Shared-rules size limit that create, update, rules set and import apply
/// enforce through the same value.
fn rules_size_problems(sources: &[&ParsedImport]) -> Vec<ImportProblem> {
    let combined = combined_rules(sources);
    if combined.len() <= RULES_MAX_BYTES {
        return Vec::new();
    }
    let names = sources
        .iter()
        .map(|parsed| parsed.source_name.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    let (file, who) = if sources.len() == 1 {
        (Some(names.clone()), names)
    } else {
        (None, format!("import set ({names})"))
    };
    vec![ImportProblem {
        kind: PROBLEM_OTHER.to_string(),
        message: format!(
            "{who}: the shared rules have {} bytes; the limit is {RULES_MAX_BYTES}. Trim the rules.",
            combined.len()
        ),
        file,
        line: None,
        task_id: None,
        value: None,
        keepable_ids: Vec::new(),
        group: Vec::new(),
        fix: Some("trim the rules".to_string()),
    }]
}

/// Dependency-list checks that apply enforces before its transaction: the
/// per-task limit and duplicate entries. The line is the task's `Deps:` line
/// when the source has one, otherwise the task heading.
fn task_limit_problems(parsed: &ParsedImport) -> Vec<ImportProblem> {
    let name = &parsed.source_name;
    let mut problems = Vec::new();
    for task in &parsed.tasks {
        let id = format!("T-{:03}", task.id);
        let line = parsed
            .deps_lines
            .iter()
            .find(|deps| deps.task_id == task.id)
            .map(|deps| deps.line_number)
            .unwrap_or(task.heading_line);
        if task.deps.len() > MAX_DEPENDENCIES {
            problems.push(ImportProblem {
                kind: crate::model::PROBLEM_OTHER.to_string(),
                message: format!(
                    "{id} at {name}:{line} has {} dependencies; the limit is {MAX_DEPENDENCIES}. Reduce the list or split the task.",
                    task.deps.len()
                ),
                file: Some(name.clone()),
                line: Some(line),
                task_id: Some(task.id),
                value: None,
                keepable_ids: Vec::new(),
                group: Vec::new(),
                fix: Some("reduce the list or split the task".to_string()),
            });
        }
        let mut seen = HashSet::new();
        for dependency in &task.deps {
            if !seen.insert(*dependency) {
                problems.push(ImportProblem {
                    kind: crate::model::PROBLEM_OTHER.to_string(),
                    message: format!(
                        "{id} at {name}:{line} lists dependency T-{dependency:03} more than once; remove the duplicate entry."
                    ),
                    file: Some(name.clone()),
                    line: Some(line),
                    task_id: Some(task.id),
                    value: None,
                    keepable_ids: Vec::new(),
                    group: Vec::new(),
                    fix: Some(format!("remove the duplicate T-{dependency:03} entry")),
                });
            }
        }
    }
    problems
}

fn join_ids(ids: &[u64]) -> String {
    ids.iter()
        .map(|id| format!("T-{id:03}"))
        .collect::<Vec<_>>()
        .join(", ")
}

fn other_problems(parsed: &ParsedImport) -> Vec<ImportProblem> {
    let name = &parsed.source_name;
    let mut problems = Vec::new();
    if !parsed.duplicate_ids.is_empty() {
        problems.push(ImportProblem::other(format!(
            "{name}: duplicate task IDs {}",
            join_ids(&parsed.duplicate_ids)
        )));
    }
    for section in &parsed.unmapped_sections {
        problems.push(ImportProblem::other(format!(
            "{name}: section '{section}' holds tasks but has no status mapping; expected a literal sections entry, a matching section_pattern, or default_status in the map file"
        )));
    }
    if !parsed.ambiguous_sections.is_empty() {
        problems.push(ImportProblem::other(format!(
            "{name}: ambiguous sections {}",
            parsed.ambiguous_sections.join(", ")
        )));
    }
    for range in &parsed.unassigned_ranges {
        problems.push(ImportProblem::other(format!(
            "{name}: unassigned content at line {}: {}",
            line_number(&parsed.source, range.start_byte),
            range.preview.trim()
        )));
    }
    if parsed.has_unknown_content && parsed.unassigned_ranges.is_empty() {
        problems.push(ImportProblem::other(format!(
            "{name}: unassigned source content"
        )));
    }
    problems
}

fn cross_file_duplicate_problems(sources: &[&ParsedImport]) -> Vec<ImportProblem> {
    let mut owner: HashMap<u64, &str> = HashMap::new();
    let mut problems = Vec::new();
    for parsed in sources {
        for task in &parsed.tasks {
            match owner.get(&task.id) {
                Some(first) if *first != parsed.source_name.as_str() => {
                    problems.push(ImportProblem::other(format!(
                        "{}: task T-{:03} is also defined in {first}",
                        parsed.source_name, task.id
                    )));
                }
                Some(_) => {}
                None => {
                    owner.insert(task.id, parsed.source_name.as_str());
                }
            }
        }
    }
    problems
}

fn duplicate_source_hash_problems(sources: &[&ParsedImport]) -> Vec<ImportProblem> {
    let mut owner: HashMap<&str, &str> = HashMap::new();
    let mut problems = Vec::new();
    for parsed in sources {
        let hash = parsed.source_hash.as_str();
        if let Some(first) = owner.get(hash) {
            problems.push(ImportProblem::other(format!(
                "{}: source SHA-256 {} is also supplied as {}; importing the same bytes more than once would collide in import provenance",
                parsed.source_name, hash, first
            )));
        } else {
            owner.insert(hash, parsed.source_name.as_str());
        }
    }
    problems
}

fn cycle_problems(sources: &[&ParsedImport]) -> Vec<ImportProblem> {
    let known: HashSet<u64> = sources
        .iter()
        .flat_map(|parsed| parsed.tasks.iter().map(|task| task.id))
        .collect();
    let mut edges: HashMap<u64, Vec<u64>> = HashMap::new();
    let mut locations: HashMap<(u64, u64), (String, usize, String)> = HashMap::new();
    for parsed in sources {
        for edge in &parsed.deps_edges {
            if edge.task_id == edge.dependency || !known.contains(&edge.dependency) {
                continue;
            }
            locations
                .entry((edge.task_id, edge.dependency))
                .or_insert_with(|| (edge.file.clone(), edge.line_number, edge.value.clone()));
        }
        for task in &parsed.tasks {
            for dep in &task.deps {
                if *dep == task.id || !known.contains(dep) {
                    continue;
                }
                let entry = edges.entry(task.id).or_default();
                if !entry.contains(dep) {
                    entry.push(*dep);
                }
            }
        }
    }
    for targets in edges.values_mut() {
        targets.sort_unstable();
    }
    let mut problems = Vec::new();
    for component in strongly_connected_components(&known, &edges) {
        if component.len() < 2 {
            continue;
        }
        let members: HashSet<u64> = component.iter().copied().collect();
        let cycle = cycle_through(component[0], &members, &edges);
        let path = cycle
            .iter()
            .map(|id| format!("T-{id:03}"))
            .collect::<Vec<_>>()
            .join(" -> ");
        let edge_text = cycle
            .windows(2)
            .map(|pair| {
                let (source, target) = (pair[0], pair[1]);
                match locations.get(&(source, target)) {
                    Some((file, line, value)) => format!(
                        "T-{source:03} at {file}:{line} depends on T-{target:03} (Deps: {value})"
                    ),
                    None => format!("T-{source:03} depends on T-{target:03}"),
                }
            })
            .collect::<Vec<_>>()
            .join("; ");
        problems.push(ImportProblem {
            kind: PROBLEM_CYCLE.to_string(),
            message: format!(
                "dependency cycle: {path} ({edge_text}); cycle group of {} task(s): {}",
                component.len(),
                join_ids(&component)
            ),
            file: None,
            line: None,
            task_id: None,
            value: None,
            keepable_ids: Vec::new(),
            group: component.clone(),
            fix: None,
        });
    }
    problems
}

/// Iterative Tarjan: every strongly connected component of the dependency
/// graph, sorted by smallest member.
fn strongly_connected_components(
    nodes: &HashSet<u64>,
    edges: &HashMap<u64, Vec<u64>>,
) -> Vec<Vec<u64>> {
    let mut roots: Vec<u64> = nodes.iter().copied().collect();
    roots.sort_unstable();
    let mut next_index = 0usize;
    let mut indices: HashMap<u64, usize> = HashMap::new();
    let mut low: HashMap<u64, usize> = HashMap::new();
    let mut stack: Vec<u64> = Vec::new();
    let mut on_stack: HashSet<u64> = HashSet::new();
    let mut components = Vec::new();
    for root in roots {
        if indices.contains_key(&root) {
            continue;
        }
        indices.insert(root, next_index);
        low.insert(root, next_index);
        next_index += 1;
        stack.push(root);
        on_stack.insert(root);
        let mut work: Vec<(u64, usize)> = vec![(root, 0)];
        while !work.is_empty() {
            let node = work.last().expect("frame").0;
            let targets = edges.get(&node).map(Vec::as_slice).unwrap_or(&[]);
            let position = work.last().expect("frame").1;
            if position < targets.len() {
                if let Some(frame) = work.last_mut() {
                    frame.1 += 1;
                }
                let target = targets[position];
                if !nodes.contains(&target) {
                    continue;
                }
                match indices.get(&target).copied() {
                    None => {
                        indices.insert(target, next_index);
                        low.insert(target, next_index);
                        next_index += 1;
                        stack.push(target);
                        on_stack.insert(target);
                        work.push((target, 0));
                    }
                    Some(target_index) => {
                        if on_stack.contains(&target) {
                            let node_low = low[&node];
                            if target_index < node_low {
                                low.insert(node, target_index);
                            }
                        }
                    }
                }
            } else {
                work.pop();
                if let Some(parent) = work.last().map(|frame| frame.0) {
                    let node_low = low[&node];
                    if node_low < low[&parent] {
                        low.insert(parent, node_low);
                    }
                }
                if low[&node] == indices[&node] {
                    let mut component = Vec::new();
                    loop {
                        let member = stack.pop().expect("component member");
                        on_stack.remove(&member);
                        component.push(member);
                        if member == node {
                            break;
                        }
                    }
                    component.sort_unstable();
                    components.push(component);
                }
            }
        }
    }
    components
}

/// One concrete cycle through `start` inside its component.
fn cycle_through(start: u64, members: &HashSet<u64>, edges: &HashMap<u64, Vec<u64>>) -> Vec<u64> {
    let mut parents: HashMap<u64, u64> = HashMap::new();
    let mut seen: HashSet<u64> = HashSet::new();
    seen.insert(start);
    let mut queue: VecDeque<u64> = VecDeque::new();
    queue.push_back(start);
    while let Some(node) = queue.pop_front() {
        for target in edges.get(&node).map(Vec::as_slice).unwrap_or(&[]) {
            if !members.contains(target) {
                continue;
            }
            if *target == start {
                let mut path = vec![node];
                while *path.last().expect("path") != start {
                    path.push(parents[path.last().expect("path")]);
                }
                path.reverse();
                path.push(start);
                return path;
            }
            if seen.insert(*target) {
                parents.insert(*target, node);
                queue.push_back(*target);
            }
        }
    }
    vec![start, start]
}

fn line_number(bytes: &[u8], offset: usize) -> usize {
    bytes
        .iter()
        .take(offset.min(bytes.len()))
        .filter(|byte| **byte == b'\n')
        .count()
        + 1
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::SourceSchema;

    fn source(name: &str, text: &str) -> ParsedImport {
        crate::markdown::parse_with_schema(
            name.to_string(),
            text.as_bytes().to_vec(),
            None,
            SourceSchema::CreateTask,
        )
        .expect("parse")
    }

    fn resolved(sources: &mut [ParsedImport]) -> Vec<ImportProblem> {
        crate::markdown::resolve_create_task_deps_across(sources);
        let refs: Vec<&ParsedImport> = sources.iter().collect();
        analyze(&refs)
    }

    #[test]
    fn two_independent_cycles_are_both_reported() {
        let mut sources = vec![
            source(
                "a/TASKS.md",
                "## In Progress\n### T-1 Alpha\nDeps: T-2\n### T-2 Beta\nDeps: T-1\n",
            ),
            source(
                "a/TASKS.ARCHIVE.md",
                "## Done\n### T-8 Eta\nDeps: T-9\n### T-9 Theta\nDeps: T-8\n",
            ),
        ];
        let problems = resolved(&mut sources);
        let cycles: Vec<&ImportProblem> = problems
            .iter()
            .filter(|problem| problem.kind == PROBLEM_CYCLE)
            .collect();
        assert_eq!(cycles.len(), 2, "{problems:#?}");
        assert!(
            cycles.iter().any(|cycle| cycle.message.contains("T-001")),
            "{cycles:#?}"
        );
        let eta = cycles
            .iter()
            .find(|cycle| cycle.message.contains("T-008"))
            .expect("T-008 cycle");
        assert!(eta.message.contains("T-009"), "{eta:#?}");
        assert!(
            cycles
                .iter()
                .all(|cycle| cycle.message.contains("a/TASKS.ARCHIVE.md:")
                    || cycle.message.contains("a/TASKS.md:")),
            "{cycles:#?}"
        );
    }

    #[test]
    fn unknown_ids_do_not_hide_cycles() {
        let mut sources = vec![source(
            "a/TASKS.md",
            "## In Progress\n### T-1 Alpha\nDeps: T-099\n### T-2 Beta\nDeps: T-3\n### T-3 Gamma\nDeps: T-2\n",
        )];
        let problems = resolved(&mut sources);
        assert_eq!(
            problems
                .iter()
                .filter(|problem| problem.kind == PROBLEM_UNKNOWN_DEPENDENCY)
                .count(),
            1,
            "{problems:#?}"
        );
        assert_eq!(
            problems
                .iter()
                .filter(|problem| problem.kind == PROBLEM_CYCLE)
                .count(),
            1,
            "{problems:#?}"
        );
    }

    #[test]
    fn group_lists_every_entangled_task() {
        let mut sources = vec![source(
            "a/TASKS.md",
            "## In Progress\n### T-1 Alpha\nDeps: T-2\n### T-2 Beta\nDeps: T-1, T-3\n### T-3 Gamma\nDeps: T-2\n",
        )];
        let problems = resolved(&mut sources);
        let cycle = problems
            .iter()
            .find(|problem| problem.kind == PROBLEM_CYCLE)
            .expect("cycle");
        assert_eq!(cycle.group, vec![1, 2, 3], "{cycle:#?}");
        assert!(cycle.message.contains("T-003"), "{}", cycle.message);
    }
}
