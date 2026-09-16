//! Cross-file import problem analysis.
//!
//! A preview never stops at the first problem: every nonconforming Deps line,
//! every unknown or self-referencing dependency, every unmapped task-bearing
//! section, every unassigned content range and every duplicate ID of the
//! whole import set is collected in one pass.

use crate::markdown::ParsedImport;
use crate::model::{ImportProblem, PROBLEM_NONCONFORMING_DEPS, PROBLEM_UNKNOWN_DEPENDENCY};
use std::collections::HashMap;

/// Analyze one import set: a single-file import, or one bulk candidate with all
/// of its ledger files.
pub fn analyze(sources: &[&ParsedImport]) -> Vec<ImportProblem> {
    let mut problems = Vec::new();
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
        problems.extend(other_problems(parsed));
    }
    problems.extend(cross_file_duplicate_problems(sources));
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

fn line_number(bytes: &[u8], offset: usize) -> usize {
    bytes
        .iter()
        .take(offset.min(bytes.len()))
        .filter(|byte| **byte == b'\n')
        .count()
        + 1
}
