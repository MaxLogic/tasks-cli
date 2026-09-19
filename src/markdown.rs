use crate::error::AppError;
use crate::model::{
    parse_task_id, ImportProblem, ImportSectionPreview, ImportTaskPreview, Priority, SchemaClass,
    SourceRange, SourceSchema, TaskStatus, PROBLEM_NONCONFORMING_DEPS, PROBLEM_OTHER,
    PROBLEM_SELF_DEPENDENCY, PROBLEM_UNKNOWN_DEPENDENCY,
};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::Path;

const NO_SECTION: &str = "<no section>";
const SCHEMA_MARKER: &str = "Task schema: 1";
const CANONICAL_FRAME_PREFIX: &str = "<!-- tasks-cli:canonical-v1:";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CanonicalFrameKind {
    Body,
    Rules,
}

#[derive(Clone, Debug)]
struct CanonicalFrame {
    kind: CanonicalFrameKind,
    content_start: usize,
    content_end: usize,
    end_line: usize,
}

#[derive(Clone, Debug)]
struct CanonicalFrameHeader {
    kind: CanonicalFrameKind,
    bytes: usize,
    sha256: String,
}

fn canonical_frame_start(value: &str) -> Option<CanonicalFrameHeader> {
    let value = value.trim();
    let inner = value
        .strip_prefix(CANONICAL_FRAME_PREFIX)?
        .strip_suffix("-->")?
        .trim();
    let mut fields = inner.split_whitespace();
    let kind = match fields.next()? {
        "body" => CanonicalFrameKind::Body,
        "rules" => CanonicalFrameKind::Rules,
        _ => return None,
    };
    let bytes = fields.next()?.strip_prefix("bytes=")?.parse().ok()?;
    let sha256 = fields.next()?.strip_prefix("sha256=")?.to_string();
    if fields.next().is_some()
        || sha256.len() != 64
        || !sha256.chars().all(|ch| ch.is_ascii_hexdigit())
    {
        return None;
    }
    Some(CanonicalFrameHeader {
        kind,
        bytes,
        sha256,
    })
}

fn canonical_frame_end(value: &str, kind: CanonicalFrameKind, sha256: &str) -> bool {
    let value = value.trim();
    let name = match kind {
        CanonicalFrameKind::Body => "body",
        CanonicalFrameKind::Rules => "rules",
    };
    value == format!("{CANONICAL_FRAME_PREFIX}end-{name} sha256={sha256} -->")
}

fn framed_block(
    text: &str,
    lines: &[Line<'_>],
    marker_line: usize,
    header: &CanonicalFrameHeader,
) -> Option<CanonicalFrame> {
    let content_start = lines.get(marker_line)?.end;
    let content_end = content_start.checked_add(header.bytes)?;
    if content_end > text.len()
        || !text.is_char_boundary(content_start)
        || !text.is_char_boundary(content_end)
    {
        return None;
    }
    let mut candidates = vec![content_end];
    if text[content_end..].starts_with('\n') {
        candidates.push(content_end + 1);
    }
    if text[content_end..].starts_with("\r\n") {
        candidates.push(content_end + 2);
    }
    for marker_start in candidates {
        if marker_start > text.len() || !text.is_char_boundary(marker_start) {
            continue;
        }
        let Ok(end_line) = lines.binary_search_by_key(&marker_start, |line| line.start) else {
            continue;
        };
        if !canonical_frame_end(lines[end_line].text, header.kind, &header.sha256) {
            continue;
        }
        if sha256(text.as_bytes().get(content_start..content_end)?) != header.sha256 {
            continue;
        }
        return Some(CanonicalFrame {
            kind: header.kind,
            content_start,
            content_end,
            end_line,
        });
    }
    None
}

fn canonical_frame_position_kind(
    lines: &[Line<'_>],
    marker_line: usize,
) -> Option<CanonicalFrameKind> {
    if marker_line
        .checked_sub(1)
        .and_then(|index| lines.get(index))
        .is_some_and(|line| line.text.trim() == "Body:")
    {
        return Some(CanonicalFrameKind::Body);
    }
    let mut index = marker_line;
    while let Some(previous) = index.checked_sub(1) {
        index = previous;
        let value = lines[index].text.trim();
        if value.is_empty() {
            continue;
        }
        if matches!(value, "## Rules" | "## Shared Rules" | "## rules") {
            return Some(CanonicalFrameKind::Rules);
        }
        break;
    }
    None
}

fn protect_untrusted_frame_tail(protected_lines: &mut [bool], marker_line: usize) {
    for protected in protected_lines.iter_mut().skip(marker_line) {
        *protected = true;
    }
}

fn line_is_inside_frame(line: &Line<'_>, frame: &CanonicalFrame) -> bool {
    line.start < frame.content_end && line.end > frame.content_start
}

#[derive(Debug, Clone)]
pub struct ParsedTask {
    pub priority: Priority,
    pub id: u64,
    /// 1-based line of the task heading in the source file.
    pub heading_line: usize,
    pub title: String,
    pub body: String,
    pub status: TaskStatus,
    /// Dependencies declared by the canonical metadata block. The create-task
    /// `Deps:` line is resolution-dependent, so `deps` is recomputed from this
    /// baseline by `resolve_create_task_deps`.
    pub deps: Vec<u64>,
    pub labels: Vec<String>,
    pub metadata_deps: Vec<u64>,
    /// 1-based line of the canonical `Depends on:` line, when the task has one.
    pub metadata_deps_line: Option<usize>,
}

/// A create-task `Deps:` line, kept verbatim so dependency edges can be
/// recomputed against a wider task-ID set: a bulk candidate parses one file at
/// a time but resolves dependencies across every file of the candidate. Every
/// Deps line is kept, not just the first, so a second line in one task can be
/// reported instead of silently ignored.
#[derive(Debug, Clone)]
pub struct DepsLine {
    pub task_id: u64,
    pub line_number: usize,
    pub value: String,
}

/// A dependency edge that was actually recorded from a create-task `Deps:`
/// line, with the location needed to report a cycle.
#[derive(Debug, Clone)]
pub struct DepsEdge {
    pub task_id: u64,
    pub dependency: u64,
    pub file: String,
    pub line_number: usize,
    pub value: String,
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
    pub deps_lines: Vec<DepsLine>,
    pub deps_edges: Vec<DepsEdge>,
    pub deps_problems: Vec<ImportProblem>,
    pub parse_problems: Vec<ImportProblem>,
    pub section_warnings: Vec<String>,
    pub has_schema_marker: bool,
    pub has_canonical_rules_frame: bool,
    pub schema_class: SchemaClass,
}

impl ParsedImport {
    /// Every warning recorded while parsing and resolving this source.
    pub fn warnings(&self) -> Vec<String> {
        self.section_warnings.clone()
    }
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
        "draft" | "backlog" => Some(TaskStatus::Backlog),
        "todo" | "ready" => Some(TaskStatus::Ready),
        "in-progress" => Some(TaskStatus::InProgress),
        "blocked" => Some(TaskStatus::Blocked),
        "done" => Some(TaskStatus::Done),
        "cancelled" => Some(TaskStatus::Cancelled),
        _ => None,
    }
}

fn parse_mapping_status(value: &str) -> Option<TaskStatus> {
    match value {
        "draft" | "backlog" => Some(TaskStatus::Backlog),
        "todo" | "ready" => Some(TaskStatus::Ready),
        "in-progress" => Some(TaskStatus::InProgress),
        "blocked" => Some(TaskStatus::Blocked),
        "done" => Some(TaskStatus::Done),
        "cancelled" => Some(TaskStatus::Cancelled),
        _ => None,
    }
}

#[derive(Debug, Clone, Default)]
pub(crate) struct SectionMap {
    literal: HashMap<String, TaskStatus>,
    patterns: Vec<(regex::Regex, TaskStatus)>,
    default_status: Option<TaskStatus>,
    relaxed_missing_sections: bool,
    /// The map file this map was loaded from, when it came from a file.
    pub(crate) path: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StatusSource {
    Literal,
    Pattern,
    Canonical,
    Default,
}

impl SectionMap {
    /// Bulk runs apply one map to a whole corpus, so a literal section that a
    /// given file does not contain is ignored instead of rejected.
    pub(crate) fn for_corpus(&self) -> SectionMap {
        let mut copy = self.clone();
        copy.relaxed_missing_sections = true;
        copy
    }

    fn resolve(&self, section: &str) -> Option<(TaskStatus, StatusSource)> {
        if let Some(status) = self.literal.get(section) {
            return Some((status.clone(), StatusSource::Literal));
        }
        // Tasks before the first section are deliberately not covered by a
        // pattern or a default.  They are an explicit safety boundary: a
        // caller must map the literal `<no section>` name when it intends to
        // import those tasks.
        if section == NO_SECTION {
            return None;
        }
        if let Some((_, status)) = self
            .patterns
            .iter()
            .find(|(pattern, _)| pattern.is_match(section))
        {
            return Some((status.clone(), StatusSource::Pattern));
        }
        if let Some(status) = canonical_status(section) {
            return Some((status, StatusSource::Canonical));
        }
        self.default_status
            .clone()
            .map(|status| (status, StatusSource::Default))
    }

    fn status_for(&self, section: &str) -> Option<TaskStatus> {
        self.resolve(section).map(|(status, _)| status)
    }
}

fn json_kind(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "an array",
        Value::Object(_) => "an object",
    }
}

fn parse_mapping_status_value(
    map_path: &Path,
    context: &str,
    value: &Value,
) -> Result<TaskStatus, AppError> {
    value
        .as_str()
        .and_then(parse_mapping_status)
        .ok_or_else(|| {
            AppError::Validation(format!(
                "map file {}: {context} must be one of draft, todo, in-progress, blocked, done, cancelled (legacy backlog/ready are also accepted); found {}",
                map_path.display(),
                value
            ))
        })
}

fn insert_literal_mapping(
    map: &mut SectionMap,
    map_path: &Path,
    name: &str,
    status: &Value,
) -> Result<(), AppError> {
    let status = parse_mapping_status_value(map_path, &format!("section '{name}' status"), status)?;
    if canonical_status(name).is_some_and(|canonical| canonical != status) {
        return Err(AppError::Validation(format!(
            "map file {}: mapping for canonical section '{name}' conflicts with its status; remove the mapping or map it to the status the canonical name already has",
            map_path.display()
        )));
    }
    if map.literal.insert(name.to_string(), status).is_some() {
        return Err(AppError::Validation(format!(
            "map file {}: conflicting mapping for section '{name}'",
            map_path.display()
        )));
    }
    Ok(())
}

pub(crate) fn load_section_map(path: &Path) -> Result<SectionMap, AppError> {
    let bytes =
        std::fs::read(path).map_err(|error| AppError::io_path("read map file", path, error))?;
    let value: Value = serde_json::from_slice(&bytes).map_err(|error| {
        AppError::Validation(format!(
            "map file {} is not valid JSON: {error}",
            path.display()
        ))
    })?;
    let object = value.as_object().ok_or_else(|| {
        AppError::Validation(format!(
            "map file {} must contain a JSON object; found {}",
            path.display(),
            json_kind(&value)
        ))
    })?;
    let structured = ["sections", "default_status", "section_patterns"]
        .iter()
        .any(|key| object.contains_key(*key));
    let mut map = SectionMap::default();
    if structured {
        for key in object.keys() {
            if !matches!(
                key.as_str(),
                "sections" | "default_status" | "section_patterns"
            ) {
                return Err(AppError::Validation(format!(
                    "map file {}: unknown top-level key '{key}'; expected sections, default_status or section_patterns",
                    path.display()
                )));
            }
        }
        if let Some(sections) = object.get("sections") {
            let sections = sections.as_object().ok_or_else(|| {
                AppError::Validation(format!(
                    "map file {}: \"sections\" must be an object of section name to status; found {}",
                    path.display(),
                    json_kind(sections)
                ))
            })?;
            for (name, status) in sections {
                insert_literal_mapping(&mut map, path, name, status)?;
            }
        }
        if let Some(default_status) = object.get("default_status") {
            map.default_status = Some(parse_mapping_status_value(
                path,
                "default_status",
                default_status,
            )?);
        }
        if let Some(patterns) = object.get("section_patterns") {
            let patterns = patterns.as_array().ok_or_else(|| {
                AppError::Validation(format!(
                    "map file {}: section_patterns must be an array of {{pattern, status}} objects; found {}",
                    path.display(),
                    json_kind(patterns)
                ))
            })?;
            for (index, entry) in patterns.iter().enumerate() {
                let entry = entry.as_object().ok_or_else(|| {
                    AppError::Validation(format!(
                        "map file {}: section_patterns[{index}] must be an object",
                        path.display()
                    ))
                })?;
                for key in entry.keys() {
                    if key != "pattern" && key != "status" {
                        return Err(AppError::Validation(format!(
                            "map file {}: section_patterns[{index}] has unknown key '{key}'; expected pattern and status",
                            path.display()
                        )));
                    }
                }
                let pattern = entry
                    .get("pattern")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        AppError::Validation(format!(
                            "map file {}: section_patterns[{index}] requires a string \"pattern\"",
                            path.display()
                        ))
                    })?;
                let status = entry.get("status").ok_or_else(|| {
                    AppError::Validation(format!(
                        "map file {}: section_patterns[{index}] requires a \"status\"",
                        path.display()
                    ))
                })?;
                let status = parse_mapping_status_value(
                    path,
                    &format!("section_patterns[{index}].status"),
                    status,
                )?;
                let compiled = regex::Regex::new(pattern).map_err(|error| {
                    AppError::Validation(format!(
                        "map file {}: section pattern '{pattern}' is not a valid regex: {error}",
                        path.display()
                    ))
                })?;
                map.patterns.push((compiled, status));
            }
        }
    } else {
        for (name, status) in object {
            insert_literal_mapping(&mut map, path, name, status)?;
        }
    }
    map.path = Some(path.display().to_string());
    Ok(map)
}

fn parse_dependencies(value: &str) -> Result<Vec<u64>, String> {
    let value = value.trim();
    if value.is_empty() || value == "-" || value.eq_ignore_ascii_case("none") {
        return Ok(Vec::new());
    }
    let mut deps = value
        .split(',')
        .map(|raw| {
            parse_task_id(raw.trim()).map_err(|error| {
                format!("{error}; expected a comma-separated list of T-<digits> IDs, '-' or 'none'")
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    deps.sort_unstable();
    Ok(deps)
}

fn collect_deps_lines<'a>(
    lines: &[Line<'a>],
    fence_lines: &[bool],
    start: usize,
    end: usize,
) -> Vec<(usize, &'a str)> {
    let end = end.min(lines.len());
    let mut found = Vec::new();
    for (index, line) in lines.iter().enumerate().take(end).skip(start) {
        if fence_lines.get(index).copied().unwrap_or(false) {
            continue;
        }
        if let Some(value) = line.text.strip_prefix("Deps:") {
            found.push((index, value));
        }
    }
    found
}

/// The create-task 3.4.0 Deps grammar: the value is either an empty form or a
/// comma-separated list in which every trimmed item is exactly `T-<digits>`.
/// Anything else is `None` and makes the import unrecognized.
fn parse_deps_value(value: &str) -> Option<Vec<u64>> {
    let value = value.trim();
    if value.is_empty() || value == "-" || value.eq_ignore_ascii_case("none") {
        return Some(Vec::new());
    }
    let mut ids = Vec::new();
    for item in value.split(',') {
        let item = item.trim();
        let digits = item.strip_prefix("T-")?;
        if digits.is_empty() || !digits.chars().all(|ch| ch.is_ascii_digit()) {
            return None;
        }
        ids.push(digits.parse::<u64>().ok()?);
    }
    Some(ids)
}

/// The IDs a clean Deps line would keep: split on "," and ";", strip
/// surrounding whitespace and backticks, and keep the standalone `T-<digits>`
/// items that name a task present in this candidate's files.
fn salvageable_deps_ids(value: &str, known: &HashSet<u64>) -> Vec<u64> {
    let mut ids = Vec::new();
    for item in value.split([',', ';']) {
        let item = item.trim().trim_matches('`').trim();
        let Some(digits) = item.strip_prefix("T-") else {
            continue;
        };
        if digits.is_empty() || !digits.chars().all(|ch| ch.is_ascii_digit()) {
            continue;
        }
        let Ok(id) = digits.parse::<u64>() else {
            continue;
        };
        if known.contains(&id) && !ids.contains(&id) {
            ids.push(id);
        }
    }
    ids
}

fn deps_fix_text() -> &'static str {
    "keep only these IDs in Deps and move the rest of the original text to Notes"
}

fn unknown_dep_fix_text(id: u64) -> String {
    format!("remove T-{id:03} from Deps; no such task exists")
}

fn nonconforming_problem(
    file: &str,
    line: &DepsLine,
    known: &HashSet<u64>,
    second_line: bool,
) -> ImportProblem {
    let keepable = salvageable_deps_ids(&line.value, known);
    let keepable_text = if keepable.is_empty() {
        "none".to_string()
    } else {
        keepable
            .iter()
            .map(|id| format!("T-{id:03}"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let reason = if second_line {
        "a task may have only one Deps line"
    } else {
        "the value is not a comma-separated list of task IDs"
    };
    ImportProblem {
        kind: PROBLEM_NONCONFORMING_DEPS.to_string(),
        message: format!(
            "{file}: line {}: task T-{:03}: nonconforming Deps line 'Deps: {}': {reason}; IDs a clean line would keep: {keepable_text}; fix: {}",
            line.line_number,
            line.task_id,
            line.value,
            deps_fix_text()
        ),
        file: Some(file.to_string()),
        line: Some(line.line_number),
        task_id: Some(line.task_id),
        value: Some(line.value.clone()),
        keepable_ids: keepable,
        group: Vec::new(),
        fix: Some(deps_fix_text().to_string()),
    }
}

/// Recompute every task's `deps` from its canonical metadata block plus the
/// create-task `Deps:` lines, under the strict create-task grammar. Edges are
/// recorded only for IDs present in `known`; every nonconforming line and every
/// unknown or self-referencing ID becomes a blocking problem. The single-file
/// import and the bulk candidate both call this, so preview and apply agree.
pub(crate) fn resolve_create_task_deps(parsed: &mut ParsedImport, known: &HashSet<u64>) {
    parsed.deps_problems.clear();
    parsed.deps_edges.clear();
    let mut edges: HashMap<u64, Vec<u64>> = HashMap::new();
    let mut tasked: HashSet<u64> = HashSet::new();
    for line in &parsed.deps_lines {
        if !tasked.insert(line.task_id) {
            parsed.deps_problems.push(nonconforming_problem(
                &parsed.source_name,
                line,
                known,
                true,
            ));
            continue;
        }
        let Some(ids) = parse_deps_value(&line.value) else {
            parsed.deps_problems.push(nonconforming_problem(
                &parsed.source_name,
                line,
                known,
                false,
            ));
            continue;
        };
        let mut seen_in_line: HashSet<u64> = HashSet::new();
        let mut reported_in_line: HashSet<u64> = HashSet::new();
        for id in ids {
            if !seen_in_line.insert(id) && reported_in_line.insert(id) {
                parsed.deps_problems.push(ImportProblem {
                    kind: PROBLEM_OTHER.to_string(),
                    message: format!(
                        "{}: line {}: task T-{:03} lists dependency T-{:03} more than once; fix: remove the duplicate entry",
                        parsed.source_name, line.line_number, line.task_id, id
                    ),
                    file: Some(parsed.source_name.clone()),
                    line: Some(line.line_number),
                    task_id: Some(line.task_id),
                    value: Some(line.value.clone()),
                    keepable_ids: Vec::new(),
                    group: Vec::new(),
                    fix: Some("remove the duplicate entry".to_string()),
                });
            }
            if id == line.task_id {
                parsed.deps_problems.push(ImportProblem {
                    kind: PROBLEM_SELF_DEPENDENCY.to_string(),
                    message: format!(
                        "{}: line {}: task T-{:03} lists itself in Deps; fix: remove T-{:03} from Deps",
                        parsed.source_name, line.line_number, line.task_id, line.task_id
                    ),
                    file: Some(parsed.source_name.clone()),
                    line: Some(line.line_number),
                    task_id: Some(line.task_id),
                    value: Some(line.value.clone()),
                    keepable_ids: Vec::new(),
                    group: Vec::new(),
                    fix: Some(format!("remove T-{:03} from Deps", line.task_id)),
                });
                continue;
            }
            if !known.contains(&id) {
                parsed.deps_problems.push(ImportProblem {
                    kind: PROBLEM_UNKNOWN_DEPENDENCY.to_string(),
                    message: format!(
                        "{}: line {}: task T-{:03} depends on T-{id:03}, which is not present in this project's ledgers; fix: {}",
                        parsed.source_name,
                        line.line_number,
                        line.task_id,
                        unknown_dep_fix_text(id)
                    ),
                    file: Some(parsed.source_name.clone()),
                    line: Some(line.line_number),
                    task_id: Some(line.task_id),
                    value: Some(line.value.clone()),
                    keepable_ids: Vec::new(),
                    group: Vec::new(),
                    fix: Some(unknown_dep_fix_text(id)),
                });
                continue;
            }
            let recorded = edges.entry(line.task_id).or_default();
            if !recorded.contains(&id) {
                recorded.push(id);
                parsed.deps_edges.push(DepsEdge {
                    task_id: line.task_id,
                    dependency: id,
                    file: parsed.source_name.clone(),
                    line_number: line.line_number,
                    value: line.value.clone(),
                });
            }
        }
    }
    debug_assert_eq!(parsed.tasks.len(), parsed.task_previews.len());
    let name = parsed.source_name.clone();
    let edge_lines: HashMap<(u64, u64), usize> = parsed
        .deps_edges
        .iter()
        .map(|edge| ((edge.task_id, edge.dependency), edge.line_number))
        .collect();
    let mut duplicate_problems = Vec::new();
    for (task, preview) in parsed.tasks.iter_mut().zip(parsed.task_previews.iter_mut()) {
        let mut deps = task.metadata_deps.clone();
        if let Some(resolved) = edges.get(&task.id) {
            deps.extend(resolved.iter().copied());
        }
        // A dependency listed more than once is merged into a single edge, so
        // it never reaches apply. Preview still reports it: create and update
        // reject the same list, and a one-way migration must not hide it.
        let mut seen_deps: HashSet<u64> = HashSet::new();
        let mut reported_deps: HashSet<u64> = HashSet::new();
        for dep in &deps {
            if !seen_deps.insert(*dep) && reported_deps.insert(*dep) {
                let line = if task
                    .metadata_deps
                    .iter()
                    .filter(|entry| *entry == dep)
                    .count()
                    > 1
                {
                    task.metadata_deps_line.unwrap_or(task.heading_line)
                } else {
                    edge_lines
                        .get(&(task.id, *dep))
                        .copied()
                        .unwrap_or(task.heading_line)
                };
                duplicate_problems.push(ImportProblem {
                    kind: PROBLEM_OTHER.to_string(),
                    message: format!(
                        "{name}: line {line}: task T-{:03} lists dependency T-{:03} more than once; fix: remove the duplicate entry",
                        task.id, dep
                    ),
                    file: Some(name.clone()),
                    line: Some(line),
                    task_id: Some(task.id),
                    value: None,
                    keepable_ids: Vec::new(),
                    group: Vec::new(),
                    fix: Some("remove the duplicate entry".to_string()),
                });
            }
        }
        deps.sort_unstable();
        deps.dedup();
        preview.deps = deps.clone();
        task.deps = deps;
    }
    parsed.deps_problems.extend(duplicate_problems);
}

/// Resolve create-task Deps lines across a whole import set: a bulk candidate
/// holds several files, and an ID in one file may name a task in another.
pub fn resolve_create_task_deps_across(sources: &mut [ParsedImport]) -> HashSet<u64> {
    let known: HashSet<u64> = sources
        .iter()
        .flat_map(|parsed| parsed.tasks.iter().map(|task| task.id))
        .collect();
    for parsed in sources.iter_mut() {
        resolve_create_task_deps(parsed, &known);
    }
    known
}

struct MetadataBlock {
    priority: Priority,
    labels: Vec<String>,
    title: Option<String>,
    status: Option<TaskStatus>,
    deps: Vec<u64>,
    deps_line: Option<usize>,
    body_start: usize,
    body_end: Option<usize>,
    body_frame_end_line: Option<usize>,
    consumed: Vec<String>,
}

fn metadata_value<'a>(line: &Line<'a>, prefix: &str) -> Option<&'a str> {
    line.text.trim().strip_prefix(prefix).map(str::trim)
}

fn metadata_block(
    lines: &[Line<'_>],
    start: usize,
    end: usize,
    source_name: &str,
    frames: &HashMap<usize, CanonicalFrame>,
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
        let frame = frames
            .get(&(cursor + 1))
            .filter(|frame| frame.kind == CanonicalFrameKind::Body && frame.end_line < end);
        return Ok(Some(MetadataBlock {
            priority: Priority::default(),
            labels: Vec::new(),
            title: None,
            status: None,
            deps: Vec::new(),
            deps_line: None,
            body_start: frame
                .map(|frame| frame.content_start)
                .unwrap_or(lines[cursor].end),
            body_end: frame.map(|frame| frame.content_end),
            body_frame_end_line: frame.map(|frame| frame.end_line),
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
        (None, deps_value, cursor + 2)
    };

    let labels_value = lines
        .get(body_index)
        .and_then(|line| metadata_value(line, "Labels:"));
    let body_index = body_index + usize::from(labels_value.is_some());
    let priority_value = lines
        .get(body_index)
        .and_then(|line| metadata_value(line, "Priority:"));
    let body_index = body_index + usize::from(priority_value.is_some());
    if body_index >= end || lines[body_index].text.trim() != "Body:" {
        return Ok(None);
    }
    let priority = priority_value
        .map(str::parse::<Priority>)
        .transpose()
        .map_err(|error| {
            AppError::Validation(format!("{source_name}: invalid Priority metadata: {error}"))
        })?
        .unwrap_or_default();
    let labels = labels_value
        .map(crate::labels::parse)
        .transpose()?
        .unwrap_or_default();
    let status = status_value.parse::<TaskStatus>().map_err(|error| {
        AppError::Validation(format!(
            "{source_name}:{}: invalid Status value '{status_value}': {error}",
            cursor + 1
        ))
    })?;
    if let Some(version_value) = version_value {
        let version = version_value.parse::<u64>().map_err(|_| {
            AppError::Validation(format!(
                "{source_name}:{}: invalid task metadata version '{version_value}': expected a positive integer",
                cursor + 2
            ))
        })?;
        if version == 0 {
            return Err(AppError::Validation(format!(
                "{source_name}:{}: task metadata version must be a positive integer",
                cursor + 2
            )));
        }
    }
    let deps_line = if version_value.is_some() {
        cursor + 3
    } else {
        cursor + 2
    };
    let deps = parse_dependencies(deps_value).map_err(|message| {
        AppError::Validation(format!(
            "{source_name}:{deps_line}: invalid 'Depends on:' value '{deps_value}': {message}"
        ))
    })?;
    consumed.push("Status".to_string());
    if version_value.is_some() {
        consumed.push("Version".to_string());
    }
    consumed.push("Depends on".to_string());
    if labels_value.is_some() {
        consumed.push("Labels".to_string());
    }
    if priority_value.is_some() {
        consumed.push("Priority".to_string());
    }
    consumed.push("Body".to_string());
    let frame = frames
        .get(&(body_index + 1))
        .filter(|frame| frame.kind == CanonicalFrameKind::Body && frame.end_line < end);
    Ok(Some(MetadataBlock {
        priority,
        labels,
        title,
        status: Some(status),
        deps,
        deps_line: Some(deps_line),
        body_start: frame
            .map(|frame| frame.content_start)
            .unwrap_or(lines[body_index].end),
        body_end: frame.map(|frame| frame.content_end),
        body_frame_end_line: frame.map(|frame| frame.end_line),
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
    parse_with_schema(source_name, source, map_file, SourceSchema::Canonical)
}

pub fn parse_with_schema(
    source_name: impl Into<String>,
    source: Vec<u8>,
    map_file: Option<&Path>,
    schema: SourceSchema,
) -> Result<ParsedImport, AppError> {
    let map = match map_file {
        Some(path) => load_section_map(path)?,
        None => SectionMap::default(),
    };
    parse_with_map(source_name, source, &map, schema)
}

pub(crate) fn parse_with_map(
    source_name: impl Into<String>,
    source: Vec<u8>,
    map: &SectionMap,
    schema: SourceSchema,
) -> Result<ParsedImport, AppError> {
    let source_name: String = source_name.into();
    let text = std::str::from_utf8(&source).map_err(|error| {
        AppError::Validation(format!(
            "{source_name}: file is not valid UTF-8 (first invalid byte at offset {}); convert it to UTF-8",
            error.valid_up_to()
        ))
    })?;
    let source_hash = sha256(&source);
    let has_bom = source.starts_with(&[0xef, 0xbb, 0xbf]);
    let lines = lines_with_offsets(text);
    let mut marker_fences = None;
    let mut saw_section_or_task = false;
    let mut has_schema_marker = false;
    for line in &lines {
        if marker_fences.is_some() {
            update_fence(&mut marker_fences, line.text);
            continue;
        }
        if fence_candidate(line.text).is_some() {
            update_fence(&mut marker_fences, line.text);
            continue;
        }
        let Some(structural) = structural_text(line.text) else {
            continue;
        };
        if structural.starts_with("## ")
            || (structural.starts_with("### ") && parse_task_heading(structural).is_some())
        {
            saw_section_or_task = true;
        }
        if !saw_section_or_task && structural == SCHEMA_MARKER {
            has_schema_marker = true;
        }
    }
    let mut fences = None;
    let mut fence_lines = vec![false; lines.len()];
    let mut protected_lines = vec![false; lines.len()];
    let mut canonical_marker_lines = vec![false; lines.len()];
    let mut canonical_frames = HashMap::<usize, CanonicalFrame>::new();
    let mut frame_problems = Vec::new();
    let mut sections: Vec<(usize, String)> = Vec::new();
    let mut task_starts = Vec::new();
    let mut top_level_starts = Vec::new();
    let mut index = 0;
    while index < lines.len() {
        let line = &lines[index];
        if fences.is_some() {
            fence_lines[index] = true;
            update_fence(&mut fences, line.text);
            index += 1;
            continue;
        }
        if fence_candidate(line.text).is_some() {
            fence_lines[index] = true;
            update_fence(&mut fences, line.text);
            index += 1;
            continue;
        }
        if has_schema_marker {
            if let Some(header) = canonical_frame_start(line.text) {
                let position_kind = canonical_frame_position_kind(&lines, index);
                if position_kind == Some(header.kind) {
                    if let Some(frame) = framed_block(text, &lines, index, &header) {
                        protected_lines[index..=frame.end_line].fill(true);
                        canonical_marker_lines[index] = true;
                        canonical_marker_lines[frame.end_line] = true;
                        canonical_frames.insert(index, frame);
                        index = canonical_frames
                            .get(&index)
                            .map(|frame| frame.end_line + 1)
                            .unwrap_or(index + 1);
                        continue;
                    }
                }
                frame_problems.push(ImportProblem {
                    kind: PROBLEM_OTHER.to_string(),
                    message: format!(
                        "{source_name}:{}: malformed canonical {} frame; repair its byte length, separator, SHA-256 and end marker",
                        index + 1,
                        match header.kind {
                            CanonicalFrameKind::Body => "body",
                            CanonicalFrameKind::Rules => "rules",
                        }
                    ),
                    file: Some(source_name.clone()),
                    line: Some(index + 1),
                    task_id: None,
                    value: Some(line.text.to_string()),
                    keepable_ids: Vec::new(),
                    group: Vec::new(),
                    fix: Some("re-export the project or restore the canonical frame exactly".to_string()),
                });
                if position_kind.is_some() {
                    // Once a structural frame has been advertised, the
                    // importer cannot safely rediscover task headings in its
                    // unbounded body.  Preserve the remainder as opaque
                    // content and keep the blocking diagnostic above.
                    protect_untrusted_frame_tail(&mut protected_lines, index);
                    canonical_marker_lines[index] = true;
                    index = lines.len();
                    continue;
                }
            } else if structural_text(line.text)
                .is_some_and(|value| value.starts_with(CANONICAL_FRAME_PREFIX))
            {
                frame_problems.push(ImportProblem {
                    kind: PROBLEM_OTHER.to_string(),
                    message: format!(
                        "{source_name}:{}: malformed or misplaced canonical frame marker; frame markers are allowed only after Body: or at the start of the Rules section",
                        index + 1
                    ),
                    file: Some(source_name.clone()),
                    line: Some(index + 1),
                    task_id: None,
                    value: Some(line.text.to_string()),
                    keepable_ids: Vec::new(),
                    group: Vec::new(),
                    fix: Some("re-export the project or remove the misplaced frame marker".to_string()),
                });
                if canonical_frame_position_kind(&lines, index).is_some() {
                    protect_untrusted_frame_tail(&mut protected_lines, index);
                    canonical_marker_lines[index] = true;
                    index = lines.len();
                    continue;
                }
            }
        }
        if protected_lines[index] {
            index += 1;
            continue;
        }
        let Some(structural) = structural_text(line.text) else {
            index += 1;
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
        index += 1;
    }

    if !map.relaxed_missing_sections {
        for mapping in map.literal.keys() {
            if mapping != NO_SECTION && !sections.iter().any(|(_, section)| section == mapping) {
                return Err(AppError::Validation(format!(
                    "{} maps section '{mapping}', which {source_name} does not contain; add the section to the file or remove the mapping",
                    map.path.as_deref().unwrap_or("section map")
                )));
            }
        }
    }

    let mut tasks = Vec::new();
    let mut task_previews = Vec::new();
    let mut deps_lines = Vec::new();
    let mut parse_problems = frame_problems;
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
        let (id, mut title) = parse_task_heading(heading).ok_or_else(|| {
            AppError::Validation(format!(
                "{source_name}:{}: task heading '{heading}' is not '### T-<number> <title>'",
                *start_index + 1
            ))
        })?;
        if !seen.insert(id) && !duplicate_ids.contains(&id) {
            duplicate_ids.push(id);
        }
        let section = section_for_line(&sections, *start_index)
            .map(|position| sections[position].1.clone())
            .unwrap_or_else(|| NO_SECTION.to_string());
        let mut status = map.status_for(&section).unwrap_or(TaskStatus::Backlog);
        let mut deps = Vec::new();
        let mut labels = Vec::new();
        let mut priority = Priority::default();
        let mut metadata_deps_line = None;
        let mut body_start = lines[*start_index].end;
        let mut body_end_override = None;
        let mut body_frame_end_line = None;
        let mut consumed_metadata = Vec::new();
        match metadata_block(
            &lines,
            *start_index + 1,
            end_index,
            &source_name,
            &canonical_frames,
        ) {
            Ok(Some(metadata)) => {
                if let Some(metadata_title) = metadata.title {
                    title = metadata_title;
                }
                if let Some(metadata_status) = metadata.status {
                    status = metadata_status;
                }
                labels = metadata.labels;
                priority = metadata.priority;
                deps = metadata.deps;
                metadata_deps_line = metadata.deps_line;
                body_start = metadata.body_start;
                body_end_override = metadata.body_end;
                body_frame_end_line = metadata.body_frame_end_line;
                consumed_metadata = metadata.consumed;
            }
            Ok(None) => {}
            Err(error) => {
                parse_problems.push(ImportProblem {
                    kind: PROBLEM_OTHER.to_string(),
                    message: format!(
                        "{source_name}:{}: task T-{id:03} has invalid metadata: {error}",
                        *start_index + 1
                    ),
                    file: Some(source_name.clone()),
                    line: Some(*start_index + 1),
                    task_id: Some(id),
                    value: None,
                    keepable_ids: Vec::new(),
                    group: Vec::new(),
                    fix: Some("fix the task metadata and preview the import again".to_string()),
                });
            }
        }
        if schema == SourceSchema::CreateTask {
            let found = collect_deps_lines(&lines, &fence_lines, *start_index + 1, end_index);
            if !found.is_empty() {
                consumed_metadata.push("Deps".to_string());
            }
            for (line_index, value) in found {
                deps_lines.push(DepsLine {
                    task_id: id,
                    line_number: line_index + 1,
                    value: value.trim().to_string(),
                });
            }
        }
        let body_end = body_end_override.unwrap_or_else(|| {
            lines
                .get(end_index.saturating_sub(1))
                .map(|line| line.end)
                .unwrap_or(body_start)
        });
        let body = if body_start <= body_end && body_end <= text.len() {
            let value = &text[body_start..body_end];
            if body_end_override.is_some() {
                value.to_string()
            } else {
                value.trim_matches(['\r', '\n']).to_string()
            }
        } else {
            String::new()
        };
        if let Some(frame_end_line) = body_frame_end_line {
            let trailing = lines
                .iter()
                .enumerate()
                .skip(frame_end_line + 1)
                .take(end_index.saturating_sub(frame_end_line + 1))
                .find(|(_, line)| !line.text.trim().is_empty());
            if let Some((line_index, line)) = trailing {
                parse_problems.push(ImportProblem {
                    kind: PROBLEM_OTHER.to_string(),
                    message: format!(
                        "{source_name}:{}: canonical body frame for T-{id:03} is followed by unframed content before the next task or section",
                        line_index + 1
                    ),
                    file: Some(source_name.clone()),
                    line: Some(line_index + 1),
                    task_id: Some(id),
                    value: Some(line.text.to_string()),
                    keepable_ids: Vec::new(),
                    group: Vec::new(),
                    fix: Some(
                        "keep all task body bytes inside the canonical body frame or re-export the project"
                            .to_string(),
                    ),
                });
            }
        }
        if title.is_empty() {
            parse_problems.push(ImportProblem {
                kind: PROBLEM_OTHER.to_string(),
                message: format!(
                    "{source_name}:{}: task T-{id:03} has no title; write the heading as '### T-{id:03} <title>'",
                    *start_index + 1
                ),
                file: Some(source_name.clone()),
                line: Some(*start_index + 1),
                task_id: Some(id),
                value: None,
                keepable_ids: Vec::new(),
                group: Vec::new(),
                fix: Some(format!("write a non-empty title for T-{id:03}")),
            });
        }
        task_previews.push(ImportTaskPreview {
            priority,
            labels: labels.clone(),
            id,
            title: title.clone(),
            section: section.clone(),
            status: status.clone(),
            deps: deps.clone(),
            consumed_metadata,
        });
        tasks.push(ParsedTask {
            priority,
            labels,
            id,
            heading_line: *start_index + 1,
            title,
            body,
            status,
            metadata_deps: deps.clone(),
            deps,
            metadata_deps_line,
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
    for (index, marker) in canonical_marker_lines.iter().enumerate() {
        if *marker {
            assignments[index] = Assignment::Structural;
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
            || structural.starts_with("Archived from TASKS.md.")
            || structural == SCHEMA_MARKER
        {
            assignments[index] = Assignment::Structural;
        }
    }

    let mut rule_frames = canonical_frames
        .values()
        .filter(|frame| frame.kind == CanonicalFrameKind::Rules)
        .collect::<Vec<_>>();
    rule_frames.sort_by_key(|frame| frame.content_start);
    let has_canonical_rules_frame = !rule_frames.is_empty();
    if has_canonical_rules_frame {
        let mixed_rule_line = assignments
            .iter()
            .enumerate()
            .filter(|(_, assignment)| **assignment == Assignment::Rules)
            .filter(|(index, _)| !lines[*index].text.trim().is_empty())
            .map(|(index, _)| index)
            .find(|index| {
                !rule_frames
                    .iter()
                    .any(|frame| line_is_inside_frame(&lines[*index], frame))
            });
        if let Some(line_index) = mixed_rule_line {
            let line = &lines[line_index];
            parse_problems.push(ImportProblem {
                kind: PROBLEM_OTHER.to_string(),
                message: format!(
                    "{source_name}:{}: canonical Rules content is mixed with unframed text; keep the complete shared rules body inside a rules frame",
                    line_index + 1
                ),
                file: Some(source_name.clone()),
                line: Some(line_index + 1),
                task_id: None,
                value: Some(line.text.to_string()),
                keepable_ids: Vec::new(),
                group: Vec::new(),
                fix: Some("re-export the project or frame all shared rules content".to_string()),
            });
        }
    }
    let rules = if has_canonical_rules_frame {
        let mut exact = String::new();
        for frame in rule_frames {
            if !exact.is_empty() && !exact.ends_with('\n') {
                exact.push('\n');
            }
            exact.push_str(&text[frame.content_start..frame.content_end]);
        }
        exact
    } else {
        let mut legacy = String::new();
        let mut previous_rule_line = None;
        for (index, assignment) in assignments.iter().enumerate() {
            if *assignment == Assignment::Rules {
                append_rule_line(&mut legacy, &mut previous_rule_line, index, &lines[index]);
            }
        }
        legacy.trim_matches(['\r', '\n']).to_string()
    };
    let unassigned_ranges = source_ranges(&lines, &assignments);
    let has_unknown_content = !unassigned_ranges.is_empty();

    let mut section_previews = Vec::new();
    let mut unmapped_sections = Vec::new();
    let mut section_warnings = Vec::new();
    for (position, (section_index, heading)) in sections.iter().enumerate() {
        let end = section_end(&sections, position, lines.len());
        let contains_tasks = task_starts
            .iter()
            .any(|task| *task > *section_index && *task < end);
        let resolution = map.resolve(heading);
        let status = resolution.as_ref().map(|(status, _)| status.clone());
        let resolved_by_default = matches!(resolution, Some((_, StatusSource::Default)));
        if contains_tasks && status.is_none() && !unmapped_sections.contains(heading) {
            unmapped_sections.push(heading.clone());
        }
        if contains_tasks && resolved_by_default {
            let assigned = status
                .as_ref()
                .map(ToString::to_string)
                .unwrap_or_else(|| "unmapped".to_string());
            section_warnings.push(format!(
                "{source_name}: section '{heading}' holds tasks and was resolved only by default_status to {assigned}; add a literal sections entry or a matching section_pattern"
            ));
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
        let resolution = map.resolve(NO_SECTION);
        let status = resolution.as_ref().map(|(status, _)| status.clone());
        if status.is_none() {
            unmapped_sections.push(NO_SECTION.to_string());
        }
        if matches!(resolution, Some((_, StatusSource::Default))) {
            let assigned = status
                .as_ref()
                .map(ToString::to_string)
                .unwrap_or_else(|| "unmapped".to_string());
            section_warnings.push(format!(
                "{source_name}: section '{NO_SECTION}' holds tasks and was resolved only by default_status to {assigned}; add a literal sections entry or a matching section_pattern"
            ));
        }
        section_previews.push(ImportSectionPreview {
            heading: NO_SECTION.to_string(),
            status,
            contains_tasks: true,
        });
    }

    let tasks_without_section = task_starts
        .iter()
        .any(|start| section_for_line(&sections, *start).is_none());
    let unmapped_task_section = sections
        .iter()
        .enumerate()
        .any(|(position, (index, heading))| {
            let end = section_end(&sections, position, lines.len());
            let contains_tasks = task_starts.iter().any(|task| *task > *index && *task < end);
            contains_tasks && map.resolve(heading).is_none()
        })
        || (tasks_without_section && map.resolve(NO_SECTION).is_none());
    let schema_class = if has_schema_marker {
        SchemaClass::Schema1
    } else if unmapped_task_section {
        SchemaClass::Unsupported
    } else {
        SchemaClass::LegacyCompatible
    };

    let mut parsed = ParsedImport {
        source_name,
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
        deps_lines,
        deps_edges: Vec::new(),
        deps_problems: Vec::new(),
        parse_problems,
        section_warnings,
        has_schema_marker,
        has_canonical_rules_frame,
        schema_class,
    };
    let known: HashSet<u64> = parsed.tasks.iter().map(|task| task.id).collect();
    resolve_create_task_deps(&mut parsed, &known);
    Ok(parsed)
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

    #[test]
    fn create_task_ledger_markup_is_structural_but_unassigned_prose_still_blocks() {
        let input =
            b"# TASKS\nArchived from TASKS.md.\nTask schema: 1\nNext task ID: T-2\n## backlog\n### T-1 A\nbody\n"
                .to_vec();
        let parsed = parse("markup.md", input, None).unwrap();
        assert!(parsed.unassigned_ranges.is_empty());
        assert!(!parsed.has_unknown_content);

        let prose = b"## backlog\nunassigned prose\n### T-1 A\nbody\n".to_vec();
        let parsed = parse("prose.md", prose, None).unwrap();
        assert_eq!(parsed.unassigned_ranges.len(), 1);
        assert!(parsed.has_unknown_content);
    }

    #[test]
    fn create_task_schema_extracts_deps_without_consuming_the_body() {
        let input = b"## in-progress\n### T-1 Alpha\nOutcome:\n- ok\nDeps: T-2, T-3\nProof:\n- Run: x\n### T-2 Beta\nDeps: none\nbody\n### T-3 Gamma\nDeps: -\nbody\n".to_vec();
        let canonical = parse("block.md", input.clone(), None).unwrap();
        assert!(canonical.tasks[0].deps.is_empty());
        assert!(!canonical.task_previews[0]
            .consumed_metadata
            .contains(&"Deps".to_string()));

        let parsed = parse_with_schema("block.md", input, None, SourceSchema::CreateTask).unwrap();
        assert_eq!(parsed.tasks[0].deps, vec![2, 3]);
        assert!(parsed.tasks[1].deps.is_empty());
        assert!(parsed.tasks[2].deps.is_empty());
        assert!(parsed.task_previews[0]
            .consumed_metadata
            .contains(&"Deps".to_string()));
        assert_eq!(parsed.tasks[0].body, canonical.tasks[0].body);
        assert!(parsed.tasks[0].body.contains("Deps: T-2, T-3"));
        assert_eq!(parsed.task_previews[0].deps, vec![2, 3]);
        assert!(
            parsed.deps_problems.is_empty(),
            "{:?}",
            parsed.deps_problems
        );
    }

    #[test]
    fn create_task_schema_ignores_fenced_deps_and_reports_a_second_line() {
        let input =
            b"## ready\n### T-1 One\n```\nDeps: T-9\n```\nDeps: T-2, T-3\nDeps: T-4\nbody\n### T-2 Two\nbody two\n### T-3 Three\nbody three\n### T-4 Four\nbody four\n"
                .to_vec();
        let parsed =
            parse_with_schema("fenced-deps.md", input, None, SourceSchema::CreateTask).unwrap();
        assert_eq!(parsed.tasks[0].deps, vec![2, 3]);
        assert_eq!(parsed.deps_problems.len(), 1, "{:?}", parsed.deps_problems);
        let problem = &parsed.deps_problems[0];
        assert_eq!(problem.kind, PROBLEM_NONCONFORMING_DEPS);
        assert!(problem.message.contains("line 7"), "{}", problem.message);
        assert!(
            problem.message.contains("only one Deps line"),
            "{}",
            problem.message
        );
        assert!(parsed.tasks[0].body.contains("Deps: T-4"));
        assert!(parsed.tasks[0].body.contains("Deps: T-2, T-3"));
    }

    #[test]
    fn create_task_deps_typos_block_with_the_fix_text() {
        let input = b"## ready\n### T-1 One\nDeps: T-abc\nbody\n### T-2 Two\nbody two\n".to_vec();
        let parsed = parse_with_schema("typo.md", input, None, SourceSchema::CreateTask).unwrap();
        assert!(parsed.tasks[0].deps.is_empty());
        assert_eq!(parsed.deps_problems.len(), 1, "{:?}", parsed.deps_problems);
        let problem = &parsed.deps_problems[0];
        assert_eq!(problem.kind, PROBLEM_NONCONFORMING_DEPS);
        assert_eq!(problem.file.as_deref(), Some("typo.md"));
        assert_eq!(problem.line, Some(3));
        assert_eq!(problem.task_id, Some(1));
        assert_eq!(problem.value.as_deref(), Some("T-abc"));
        assert!(problem.message.contains("T-abc"), "{}", problem.message);
        assert!(
            problem.message.contains("keep only these IDs in Deps"),
            "{}",
            problem.message
        );
    }

    #[test]
    fn create_task_nonconforming_deps_lists_the_ids_a_clean_line_would_keep() {
        let input =
            b"## ready\n### T-1 One\nDeps: `T-2`, vendor SDK T-4\nbody\n### T-2 Two\nbody two\n### T-4 Four\nbody four\n"
                .to_vec();
        let parsed = parse_with_schema("deps.md", input, None, SourceSchema::CreateTask).unwrap();
        assert!(
            parsed.tasks[0].deps.is_empty(),
            "{:?}",
            parsed.tasks[0].deps
        );
        assert_eq!(parsed.deps_problems.len(), 1, "{:?}", parsed.deps_problems);
        let problem = &parsed.deps_problems[0];
        assert_eq!(problem.keepable_ids, vec![2], "{problem:#?}");
        assert!(problem.message.contains("T-002"), "{}", problem.message);
        assert!(
            problem.message.contains("vendor SDK"),
            "{}",
            problem.message
        );
    }

    #[test]
    fn create_task_deps_self_reference_is_a_problem_not_an_edge() {
        let input =
            b"## ready\n### T-1 One\nDeps: T-1, T-2\nbody\n### T-2 Two\nbody two\n".to_vec();
        let parsed = parse_with_schema("self.md", input, None, SourceSchema::CreateTask).unwrap();
        assert_eq!(parsed.tasks[0].deps, vec![2]);
        assert_eq!(parsed.deps_problems.len(), 1, "{:?}", parsed.deps_problems);
        assert_eq!(parsed.deps_problems[0].kind, PROBLEM_SELF_DEPENDENCY);
        assert!(parsed.deps_problems[0].message.contains("T-001"));
    }

    #[test]
    fn create_task_deps_empty_forms_stay_silent() {
        let input = b"## ready\n### T-1 One\nDeps: -\nbody\n### T-2 Two\nDeps: none\nbody\n### T-3 Three\nDeps:\nbody\n"
            .to_vec();
        let parsed =
            parse_with_schema("empty-deps.md", input, None, SourceSchema::CreateTask).unwrap();
        assert!(parsed.tasks.iter().all(|task| task.deps.is_empty()));
        assert!(
            parsed.deps_problems.is_empty(),
            "{:?}",
            parsed.deps_problems
        );
    }

    #[test]
    fn section_patterns_and_default_status_cover_an_open_ended_section_space() {
        let dir = tempfile::tempdir().expect("map dir");
        let map = dir.path().join("map.json");
        std::fs::write(
            &map,
            r#"{"sections":{"Ongoing":"in-progress"},"section_patterns":[{"pattern":"^\\d{4}-\\d{2}-\\d{2}","status":"done"}],"default_status":"backlog"}"#,
        )
        .expect("map");
        let input = b"## Ongoing\n### T-1 A\nbody\n## 2026-01-02 title\n### T-2 B\nbody\n## Mystery\n### T-3 C\nbody\n".to_vec();
        let parsed = parse("patterns.md", input, Some(&map)).unwrap();
        assert_eq!(parsed.tasks[0].status, TaskStatus::InProgress);
        assert_eq!(parsed.tasks[1].status, TaskStatus::Done);
        assert_eq!(parsed.tasks[2].status, TaskStatus::Backlog);
        assert!(parsed.unmapped_sections.is_empty());
        assert_eq!(
            parsed.section_warnings.len(),
            1,
            "{:?}",
            parsed.section_warnings
        );
    }

    #[test]
    fn default_status_resolution_of_a_task_section_is_warned_about() {
        let dir = tempfile::tempdir().expect("map dir");
        let map = dir.path().join("map.json");
        std::fs::write(
            &map,
            r#"{"section_patterns":[{"pattern":"^\\d{4}-\\d{2}-\\d{2}","status":"done"}],"default_status":"done"}"#,
        )
        .expect("map");
        let input = "## Next \u{2013} Today\n### T-1 A\nbody\n## done\n### T-2 B\nbody\n## 2026-01-02 x\n### T-3 C\nbody\n## Summary\nprose only\n".as_bytes().to_vec();
        let parsed = parse("en-dash.md", input, Some(&map)).unwrap();
        assert_eq!(parsed.tasks[0].status, TaskStatus::Done);
        assert_eq!(parsed.tasks[1].status, TaskStatus::Done);
        assert_eq!(parsed.tasks[2].status, TaskStatus::Done);
        assert_eq!(
            parsed.section_warnings.len(),
            1,
            "{:?}",
            parsed.section_warnings
        );
        let warning = &parsed.section_warnings[0];
        assert!(warning.contains("en-dash.md"), "{warning}");
        assert!(warning.contains("Next \u{2013} Today"), "{warning}");
        assert!(warning.contains("done"), "{warning}");
        let summary = parsed
            .sections
            .iter()
            .find(|section| section.heading == "Summary")
            .expect("summary section");
        assert!(!summary.contains_tasks);
        assert!(parsed.warnings().iter().any(|item| item == warning));
    }

    #[test]
    fn literal_mappings_beat_patterns_which_beat_canonical_names() {
        let dir = tempfile::tempdir().expect("map dir");
        let map = dir.path().join("map.json");
        std::fs::write(
            &map,
            r#"{"sections":{"Done":"blocked","2020-01-01 x":"ready"},"section_patterns":[{"pattern":"^Done$","status":"cancelled"},{"pattern":"^2020-","status":"done"},{"pattern":"^done$","status":"cancelled"}]}"#,
        )
        .expect("map");
        let input = b"## Done\n### T-1 A\nbody\n## 2020-01-01 x\n### T-2 B\nbody\n## 2020-02-02 y\n### T-3 C\nbody\n## done\n### T-4 D\nbody\n".to_vec();
        let parsed = parse("precedence.md", input, Some(&map)).unwrap();
        assert_eq!(parsed.tasks[0].status, TaskStatus::Blocked);
        assert_eq!(parsed.tasks[1].status, TaskStatus::Ready);
        assert_eq!(parsed.tasks[2].status, TaskStatus::Done);
        assert_eq!(parsed.tasks[3].status, TaskStatus::Cancelled);
    }

    #[test]
    fn prose_only_sections_need_no_mapping() {
        let input = b"## Summary\nprose only\n## backlog\n### T-1 A\nbody\n".to_vec();
        let parsed = parse("prose.md", input, None).unwrap();
        assert!(parsed.unmapped_sections.is_empty());
        assert_eq!(parsed.sections[0].status, None);
        assert!(!parsed.sections[0].contains_tasks);
        assert_eq!(parsed.sections[1].status, Some(TaskStatus::Backlog));
    }

    #[test]
    fn invalid_patterns_and_unknown_keys_fail_at_load() {
        let dir = tempfile::tempdir().expect("map dir");
        let bad_regex = dir.path().join("bad-regex.json");
        std::fs::write(
            &bad_regex,
            r#"{"section_patterns":[{"pattern":"(","status":"done"}]}"#,
        )
        .expect("bad regex map");
        let error = parse(
            "x.md",
            b"## backlog\n### T-1 A\nbody\n".to_vec(),
            Some(&bad_regex),
        )
        .expect_err("invalid regex");
        assert!(error.to_string().contains("not a valid regex"), "{error}");

        let bad_default = dir.path().join("bad-default.json");
        std::fs::write(&bad_default, r#"{"default_status":"nope"}"#).expect("bad default map");
        assert!(parse(
            "x.md",
            b"## backlog\n### T-1 A\nbody\n".to_vec(),
            Some(&bad_default)
        )
        .is_err());

        let extra_key = dir.path().join("extra-key.json");
        std::fs::write(&extra_key, r#"{"sections":{},"random":1}"#).expect("extra key map");
        let error = parse(
            "x.md",
            b"## backlog\n### T-1 A\nbody\n".to_vec(),
            Some(&extra_key),
        )
        .expect_err("unknown key");
        assert!(
            error.to_string().contains("unknown top-level key"),
            "{error}"
        );

        let extra_entry_key = dir.path().join("extra-entry-key.json");
        std::fs::write(
            &extra_entry_key,
            r#"{"section_patterns":[{"pattern":"x","status":"done","extra":1}]}"#,
        )
        .expect("extra entry key map");
        assert!(parse(
            "x.md",
            b"## backlog\n### T-1 A\nbody\n".to_vec(),
            Some(&extra_entry_key)
        )
        .is_err());
    }
}
