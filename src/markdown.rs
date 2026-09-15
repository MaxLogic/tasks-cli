use crate::error::AppError;
use crate::model::{
    parse_task_id, ImportSectionPreview, ImportTaskPreview, SourceRange, TaskStatus,
};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::Path;

const NO_SECTION: &str = "<no section>";

#[derive(Debug, Clone)]
pub struct ParsedTask {
    pub id: u64,
    pub title: String,
    pub body: String,
    pub status: TaskStatus,
    pub deps: Vec<u64>,
}

#[derive(Debug, Clone)]
pub struct ParsedImport {
    pub source_name: String,
    pub source: Vec<u8>,
    pub source_hash: String,
    pub has_bom: bool,
    pub tasks: Vec<ParsedTask>,
    pub task_previews: Vec<ImportTaskPreview>,
    pub sections: Vec<ImportSectionPreview>,
    pub rules: String,
    pub duplicate_ids: Vec<u64>,
    pub unmapped_sections: Vec<String>,
    pub ambiguous_sections: Vec<String>,
    pub unassigned_ranges: Vec<SourceRange>,
    pub has_unknown_content: bool,
}

#[derive(Debug, Clone)]
struct Line<'a> {
    start: usize,
    end: usize,
    raw: &'a str,
    text: &'a str,
}

fn line_text(raw: &str, start: usize) -> &str {
    let text = raw.trim_end_matches('\n').trim_end_matches('\r');
    if start == 0 {
        text.strip_prefix('\u{feff}').unwrap_or(text)
    } else {
        text
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Assignment {
    Structural,
    Task(usize),
    Rules,
    Unknown,
}

#[derive(Clone, Copy, Debug)]
struct Fence {
    marker: char,
    length: usize,
}

fn lines_with_offsets(input: &str) -> Vec<Line<'_>> {
    let mut result = Vec::new();
    let mut start = 0;
    for (offset, ch) in input.char_indices() {
        if ch == '\n' {
            let end = offset + 1;
            let raw = &input[start..end];
            result.push(Line {
                start,
                end,
                raw,
                text: line_text(raw, start),
            });
            start = end;
        }
    }
    if start < input.len() {
        let raw = &input[start..];
        result.push(Line {
            start,
            end: input.len(),
            raw,
            text: line_text(raw, start),
        });
    }
    result
}

fn leading_columns(value: &str) -> usize {
    let mut columns = 0;
    for ch in value.chars() {
        match ch {
            ' ' => columns += 1,
            '\t' => columns += 4,
            _ => break,
        }
    }
    columns
}

fn structural_text(value: &str) -> Option<&str> {
    if leading_columns(value) >= 4 {
        None
    } else {
        Some(value.trim())
    }
}

fn fence_candidate(value: &str) -> Option<(char, usize)> {
    let value = structural_text(value)?;
    let marker = value.chars().next()?;
    if marker != '`' && marker != '~' {
        return None;
    }
    let length = value.chars().take_while(|ch| *ch == marker).count();
    (length >= 3).then_some((marker, length))
}

fn update_fence(state: &mut Option<Fence>, line: &str) {
    let Some((marker, length)) = fence_candidate(line) else {
        return;
    };
    match state {
        Some(fence) if fence.marker == marker && length >= fence.length => {
            let trimmed = structural_text(line).unwrap_or_default();
            let after = trimmed.chars().skip(length).collect::<String>();
            if after.trim().is_empty() {
                *state = None;
            }
        }
        Some(_) => {}
        None => *state = Some(Fence { marker, length }),
    }
}

fn parse_task_heading(text: &str) -> Option<(u64, String)> {
    let text = structural_text(text)?;
    let rest = text.strip_prefix("### ")?.trim();
    let mut pieces = rest.splitn(2, char::is_whitespace);
    let id = parse_task_id(pieces.next()?).ok()?;
    let title = pieces.next().unwrap_or_default().trim().to_string();
    Some((id, title))
}

fn canonical_status(section: &str) -> Option<TaskStatus> {
    match section {
        "backlog" => Some(TaskStatus::Backlog),
        "ready" => Some(TaskStatus::Ready),
        "in-progress" => Some(TaskStatus::InProgress),
        "blocked" => Some(TaskStatus::Blocked),
        "done" => Some(TaskStatus::Done),
        "cancelled" => Some(TaskStatus::Cancelled),
        _ => None,
    }
}

fn status_for_section(section: &str, mappings: &HashMap<String, TaskStatus>) -> Option<TaskStatus> {
    mappings
        .get(section)
        .cloned()
        .or_else(|| canonical_status(section))
}

fn parse_mapping_status(value: &str) -> Option<TaskStatus> {
    match value {
        "backlog" => Some(TaskStatus::Backlog),
        "ready" => Some(TaskStatus::Ready),
        "in-progress" => Some(TaskStatus::InProgress),
        "blocked" => Some(TaskStatus::Blocked),
        "done" => Some(TaskStatus::Done),
        "cancelled" => Some(TaskStatus::Cancelled),
        _ => None,
    }
}

fn load_mapping(path: Option<&Path>) -> Result<HashMap<String, TaskStatus>, AppError> {
    let Some(path) = path else {
        return Ok(HashMap::new());
    };
    let value: Value = serde_json::from_slice(&std::fs::read(path)?)?;
    let object = value
        .as_object()
        .ok_or_else(|| AppError::Validation("map file must contain a JSON object".to_string()))?;
    let mappings = if let Some(sections) = object.get("sections") {
        if object.keys().any(|key| key != "sections") {
            return Err(AppError::Validation(
                "map file cannot mix sections with other top-level keys".to_string(),
            ));
        }
        sections
    } else {
        &value
    };
    let mapping_object = mappings
        .as_object()
        .ok_or_else(|| AppError::Validation("map file sections must be an object".to_string()))?;
    let mut output = HashMap::new();
    for (name, status) in mapping_object {
        let status = status
            .as_str()
            .and_then(parse_mapping_status)
            .ok_or_else(|| {
                AppError::Validation(format!(
                    "map for section '{name}' must be one of backlog, ready, in-progress, blocked, done, cancelled"
                ))
            })?;
        if canonical_status(name).is_some_and(|canonical| canonical != status) {
            return Err(AppError::Validation(format!(
                "mapping for canonical section '{name}' conflicts with its status"
            )));
        }
        if output.insert(name.clone(), status).is_some() {
            return Err(AppError::Validation(format!(
                "conflicting mapping for section '{name}'"
            )));
        }
    }
    Ok(output)
}

fn parse_dependencies(value: &str) -> Result<Vec<u64>, AppError> {
    let value = value.trim();
    if value.is_empty() || value == "-" || value.eq_ignore_ascii_case("none") {
        return Ok(Vec::new());
    }
    let mut deps = value
        .split(',')
        .map(|raw| parse_task_id(raw.trim()).map_err(AppError::Validation))
        .collect::<Result<Vec<_>, _>>()?;
    deps.sort_unstable();
    Ok(deps)
}

struct MetadataBlock {
    title: Option<String>,
    status: Option<TaskStatus>,
    deps: Vec<u64>,
    body_start: usize,
    consumed: Vec<String>,
}

fn metadata_value<'a>(line: &Line<'a>, prefix: &str) -> Option<&'a str> {
    line.text.trim().strip_prefix(prefix).map(str::trim)
}

fn metadata_block(
    lines: &[Line<'_>],
    start: usize,
    end: usize,
) -> Result<Option<MetadataBlock>, AppError> {
    let mut cursor = start;
    let mut title = None;
    let mut consumed = Vec::new();

    if cursor < end {
        if let Some(value) = metadata_value(&lines[cursor], "Title:") {
            title = Some(value.to_string());
            consumed.push("Title".to_string());
            cursor += 1;
        }
    }

    if cursor >= end {
        return Ok(None);
    }

    if title.is_none() && lines[cursor].text.trim() == "Body:" {
        return Ok(Some(MetadataBlock {
            title: None,
            status: None,
            deps: Vec::new(),
            body_start: lines[cursor].end,
            consumed: vec!["Body".to_string()],
        }));
    }

    let Some(status_value) = lines
        .get(cursor)
        .and_then(|line| metadata_value(line, "Status:"))
    else {
        return Ok(None);
    };
    if cursor + 1 >= end {
        return Ok(None);
    }
    let (version_value, deps_value, body_index) = if let Some(version_value) = lines
        .get(cursor + 1)
        .and_then(|line| metadata_value(line, "Version:"))
    {
        if cursor + 3 >= end {
            return Ok(None);
        }
        let Some(deps_value) = lines
            .get(cursor + 2)
            .and_then(|line| metadata_value(line, "Depends on:"))
        else {
            return Ok(None);
        };
        if lines.get(cursor + 3).map(|line| line.text.trim()) != Some("Body:") {
            return Ok(None);
        }
        (Some(version_value), deps_value, cursor + 3)
    } else {
        if cursor + 2 >= end {
            return Ok(None);
        }
        let Some(deps_value) = lines
            .get(cursor + 1)
            .and_then(|line| metadata_value(line, "Depends on:"))
        else {
            return Ok(None);
        };
        if lines.get(cursor + 2).map(|line| line.text.trim()) != Some("Body:") {
            return Ok(None);
        }
        (None, deps_value, cursor + 2)
    };

    let status = status_value
        .parse::<TaskStatus>()
        .map_err(AppError::Validation)?;
    if let Some(version_value) = version_value {
        let version = version_value.parse::<u64>().map_err(|_| {
            AppError::Validation(format!("invalid task metadata version '{version_value}'"))
        })?;
        if version == 0 {
            return Err(AppError::Validation(
                "task metadata version must be positive".to_string(),
            ));
        }
    }
    let deps = parse_dependencies(deps_value)?;
    consumed.push("Status".to_string());
    if version_value.is_some() {
        consumed.push("Version".to_string());
    }
    consumed.extend(["Depends on".to_string(), "Body".to_string()]);
    Ok(Some(MetadataBlock {
        title,
        status: Some(status),
        deps,
        body_start: lines[body_index].end,
        consumed,
    }))
}

fn section_end(sections: &[(usize, String)], position: usize, line_count: usize) -> usize {
    sections
        .get(position + 1)
        .map(|(index, _)| *index)
        .unwrap_or(line_count)
}

fn section_for_line(sections: &[(usize, String)], line: usize) -> Option<usize> {
    sections
        .iter()
        .enumerate()
        .rfind(|(_, (index, _))| *index <= line)
        .map(|(position, _)| position)
}

fn append_rule_line(
    rules: &mut String,
    previous: &mut Option<usize>,
    index: usize,
    line: &Line<'_>,
) {
    if previous.is_some_and(|previous| previous + 1 != index)
        && !rules.is_empty()
        && !rules.ends_with('\n')
    {
        rules.push('\n');
    }
    rules.push_str(line.raw);
    *previous = Some(index);
}

fn source_ranges(lines: &[Line<'_>], assignments: &[Assignment]) -> Vec<SourceRange> {
    let mut ranges = Vec::new();
    let mut start: Option<usize> = None;
    for (index, assignment) in assignments.iter().enumerate() {
        let non_whitespace = !lines[index].text.trim().is_empty();
        if *assignment == Assignment::Unknown && non_whitespace {
            if start.is_none() {
                start = Some(index);
            }
        } else if let Some(begin) = start.take() {
            let end = index.saturating_sub(1);
            ranges.push(SourceRange {
                start_byte: lines[begin].start,
                end_byte: lines[end].end,
                preview: lines[begin..=end]
                    .iter()
                    .map(|line| line.raw)
                    .collect::<String>()
                    .trim()
                    .chars()
                    .take(160)
                    .collect(),
            });
        }
    }
    if let Some(begin) = start {
        let end = lines.len().saturating_sub(1);
        ranges.push(SourceRange {
            start_byte: lines[begin].start,
            end_byte: lines[end].end,
            preview: lines[begin..=end]
                .iter()
                .map(|line| line.raw)
                .collect::<String>()
                .trim()
                .chars()
                .take(160)
                .collect(),
        });
    }
    ranges
}

pub fn sha256(source: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(source);
    format!("{:x}", hasher.finalize())
}

pub fn parse(
    source_name: impl Into<String>,
    source: Vec<u8>,
    map_file: Option<&Path>,
) -> Result<ParsedImport, AppError> {
    let text = std::str::from_utf8(&source)
        .map_err(|_| AppError::Validation("import is not valid UTF-8".to_string()))?;
    let source_hash = sha256(&source);
    let has_bom = source.starts_with(&[0xef, 0xbb, 0xbf]);
    let mappings = load_mapping(map_file)?;
    let lines = lines_with_offsets(text);
    let mut fences = None;
    let mut sections: Vec<(usize, String)> = Vec::new();
    let mut task_starts = Vec::new();
    let mut top_level_starts = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        if fences.is_some() {
            update_fence(&mut fences, line.text);
            continue;
        }
        if fence_candidate(line.text).is_some() {
            update_fence(&mut fences, line.text);
            continue;
        }
        let Some(structural) = structural_text(line.text) else {
            continue;
        };
        if let Some(section) = structural.strip_prefix("## ") {
            sections.push((index, section.trim().to_string()));
        }
        if structural.starts_with("# ") {
            top_level_starts.push(index);
        }
        if structural.starts_with("### ") && parse_task_heading(structural).is_some() {
            task_starts.push(index);
        }
    }

    for mapping in mappings.keys() {
        if mapping != NO_SECTION && !sections.iter().any(|(_, section)| section == mapping) {
            return Err(AppError::Validation(format!(
                "map references unknown section '{mapping}'"
            )));
        }
    }

    let mut tasks = Vec::new();
    let mut task_previews = Vec::new();
    let mut seen = HashSet::new();
    let mut duplicate_ids = Vec::new();
    for (position, start_index) in task_starts.iter().enumerate() {
        let next_task = task_starts
            .get(position + 1)
            .copied()
            .unwrap_or(lines.len());
        let next_section = sections
            .iter()
            .filter(|(index, _)| *index > *start_index)
            .map(|(index, _)| *index)
            .min()
            .unwrap_or(lines.len());
        let next_top_level = top_level_starts
            .iter()
            .copied()
            .find(|index| *index > *start_index)
            .unwrap_or(lines.len());
        let end_index = next_task.min(next_section).min(next_top_level);
        let heading = lines[*start_index].text.trim();
        let (id, mut title) = parse_task_heading(heading)
            .ok_or_else(|| AppError::Validation("invalid task heading".to_string()))?;
        if !seen.insert(id) && !duplicate_ids.contains(&id) {
            duplicate_ids.push(id);
        }
        let section = section_for_line(&sections, *start_index)
            .map(|position| sections[position].1.clone())
            .unwrap_or_else(|| NO_SECTION.to_string());
        let mut status = status_for_section(&section, &mappings).unwrap_or(TaskStatus::Backlog);
        let mut deps = Vec::new();
        let mut body_start = lines[*start_index].end;
        let mut consumed_metadata = Vec::new();
        if let Some(metadata) = metadata_block(&lines, *start_index + 1, end_index)? {
            if let Some(metadata_title) = metadata.title {
                title = metadata_title;
            }
            if let Some(metadata_status) = metadata.status {
                status = metadata_status;
            }
            deps = metadata.deps;
            body_start = metadata.body_start;
            consumed_metadata = metadata.consumed;
        }
        let body_end = lines
            .get(end_index.saturating_sub(1))
            .map(|line| line.end)
            .unwrap_or(body_start);
        let body = if body_start <= body_end && body_end <= text.len() {
            text[body_start..body_end]
                .trim_matches(['\r', '\n'])
                .to_string()
        } else {
            String::new()
        };
        if title.is_empty() {
            return Err(AppError::Validation(format!("task T-{id:03} has no title")));
        }
        task_previews.push(ImportTaskPreview {
            id,
            title: title.clone(),
            section: section.clone(),
            status: status.clone(),
            consumed_metadata,
        });
        tasks.push(ParsedTask {
            id,
            title,
            body,
            status,
            deps,
        });
    }

    let mut assignments = vec![Assignment::Unknown; lines.len()];
    for (index, line) in lines.iter().enumerate() {
        if line.text.trim().is_empty() {
            assignments[index] = Assignment::Structural;
        }
    }
    for (index, (section_index, _)) in sections.iter().enumerate() {
        assignments[*section_index] = Assignment::Structural;
        let end = section_end(&sections, index, lines.len());
        let section_has_task = task_starts
            .iter()
            .any(|task| *task > *section_index && *task < end);
        let explicit_rules = matches!(
            sections[index].1.as_str(),
            "Rules" | "Shared Rules" | "rules" | "shared-rules"
        );
        if !section_has_task || explicit_rules {
            for assignment in assignments.iter_mut().take(end).skip(*section_index + 1) {
                if *assignment == Assignment::Unknown {
                    *assignment = Assignment::Rules;
                }
            }
        }
    }
    for (task_index, start) in task_starts.iter().enumerate() {
        let next_task = task_starts
            .get(task_index + 1)
            .copied()
            .unwrap_or(lines.len());
        let next_section = sections
            .iter()
            .filter(|(section, _)| *section > *start)
            .map(|(section, _)| *section)
            .min()
            .unwrap_or(lines.len());
        let next_top_level = top_level_starts
            .iter()
            .copied()
            .find(|section| *section > *start)
            .unwrap_or(lines.len());
        let end = next_task.min(next_section).min(next_top_level);
        for assignment in assignments.iter_mut().take(end).skip(*start) {
            *assignment = Assignment::Task(task_index);
        }
    }
    for (index, line) in lines.iter().enumerate() {
        if assignments[index] != Assignment::Unknown {
            continue;
        }
        let Some(structural) = structural_text(line.text) else {
            continue;
        };
        if structural.starts_with('#')
            || structural.starts_with("Project:")
            || structural.starts_with("Next task ID:")
            || structural.starts_with("> Snapshot export")
        {
            assignments[index] = Assignment::Structural;
        }
    }

    let mut rules = String::new();
    let mut previous_rule_line = None;
    for (index, assignment) in assignments.iter().enumerate() {
        if *assignment == Assignment::Rules {
            append_rule_line(&mut rules, &mut previous_rule_line, index, &lines[index]);
        }
    }
    rules = rules.trim_matches(['\r', '\n']).to_string();
    let unassigned_ranges = source_ranges(&lines, &assignments);
    let has_unknown_content = !unassigned_ranges.is_empty();

    let mut section_previews = Vec::new();
    let mut unmapped_sections = Vec::new();
    for (position, (section_index, heading)) in sections.iter().enumerate() {
        let end = section_end(&sections, position, lines.len());
        let contains_tasks = task_starts
            .iter()
            .any(|task| *task > *section_index && *task < end);
        let status = status_for_section(heading, &mappings);
        if contains_tasks && status.is_none() && !unmapped_sections.contains(heading) {
            unmapped_sections.push(heading.clone());
        }
        section_previews.push(ImportSectionPreview {
            heading: heading.clone(),
            status,
            contains_tasks,
        });
    }
    if task_starts
        .iter()
        .any(|start| section_for_line(&sections, *start).is_none())
    {
        let status = status_for_section(NO_SECTION, &mappings);
        if status.is_none() {
            unmapped_sections.push(NO_SECTION.to_string());
        }
        section_previews.push(ImportSectionPreview {
            heading: NO_SECTION.to_string(),
            status,
            contains_tasks: true,
        });
    }

    Ok(ParsedImport {
        source_name: source_name.into(),
        source,
        source_hash,
        has_bom,
        tasks,
        task_previews,
        sections: section_previews,
        rules,
        duplicate_ids,
        unmapped_sections,
        ambiguous_sections: Vec::new(),
        unassigned_ranges,
        has_unknown_content,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fenced_task_headings_are_not_imported() {
        let input = b"## backlog\n### T-1 Real\nBody:\n```\n### T-99 prose\n```\n~~~\n### T-98 prose\n~~~\n".to_vec();
        let parsed = parse("fenced.md", input, None).unwrap();
        assert_eq!(parsed.tasks.len(), 1);
        assert_eq!(parsed.tasks[0].id, 1);
    }

    #[test]
    fn source_accounting_keeps_rules_after_tasks_and_reports_unknown_text() {
        let input = b"## backlog\n### T-1 Real\nBody:\nbody\n## Rules\nrule\n## ready\nunknown before task\n### T-2 Next\nBody:\nnext\n".to_vec();
        let parsed = parse("accounting.md", input, None).unwrap();
        assert_eq!(parsed.rules, "rule");
        assert_eq!(parsed.unassigned_ranges.len(), 1);
        assert!(parsed.has_unknown_content);
    }
}
