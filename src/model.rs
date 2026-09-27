use serde::{Deserialize, Serialize};
use std::fmt::{Display, Formatter};
use std::str::FromStr;

pub const TITLE_MAX_CHARS: usize = 500;
pub const BODY_MAX_BYTES: usize = 1_048_576;
pub const RULES_MAX_BYTES: usize = 262_144;
pub const MAX_DEPENDENCIES: usize = 1000;
pub const ID_PREFIX: &str = "T-";

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[value(rename_all = "UPPER")]
pub enum Priority {
    P0,
    P1,
    #[default]
    P2,
    P3,
}

impl Display for Priority {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::P0 => "P0",
            Self::P1 => "P1",
            Self::P2 => "P2",
            Self::P3 => "P3",
        })
    }
}
impl FromStr for Priority {
    type Err = String;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "P0" => Ok(Self::P0),
            "P1" => Ok(Self::P1),
            "P2" => Ok(Self::P2),
            "P3" => Ok(Self::P3),
            _ => Err(format!(
                "invalid priority '{value}'; expected P0, P1, P2 or P3"
            )),
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ListCursor {
    pub priority: Priority,
    pub id: u64,
}
impl Display for ListCursor {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}", self.priority, render_task_id(self.id))
    }
}
impl FromStr for ListCursor {
    type Err = String;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let (priority, id) = value.split_once(':').ok_or_else(|| {
            "list --after expects a priority and task ID, e.g. P2:T-123".to_string()
        })?;
        let id = parse_task_id(id)?;
        if id > i64::MAX as u64 {
            return Err("list cursor task ID exceeds SQLite's integer range".into());
        }
        Ok(Self {
            priority: priority.parse()?,
            id,
        })
    }
}

#[derive(Debug, Serialize)]
pub struct SelectionPage {
    pub items: Vec<TaskSummary>,
    pub has_more: bool,
    pub next_after: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct UnlockSummary {
    #[serde(flatten)]
    pub task: TaskSummary,
    pub direct_open_dependents: u64,
    pub immediately_runnable: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum TaskStatus {
    // Keep the Rust identifiers stable for callers while exposing canonical names.
    #[value(name = "draft")]
    #[serde(rename = "draft", alias = "backlog")]
    Backlog,
    #[value(name = "todo")]
    #[serde(rename = "todo", alias = "ready")]
    Ready,
    #[value(name = "in-progress")]
    #[serde(rename = "in-progress")]
    InProgress,
    /// Implemented and focused-tested, waiting for its group's broad gate.
    /// Nonterminal; satisfies dependents' readiness but not completion.
    #[value(name = "to-verify")]
    #[serde(rename = "to-verify")]
    ToVerify,
    #[value(name = "blocked")]
    Blocked,
    #[value(name = "done")]
    Done,
    #[value(name = "cancelled")]
    Cancelled,
}

impl Display for TaskStatus {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        let as_text = match self {
            Self::Backlog => "draft",
            Self::Ready => "todo",
            Self::InProgress => "in-progress",
            Self::ToVerify => "to-verify",
            Self::Blocked => "blocked",
            Self::Done => "done",
            Self::Cancelled => "cancelled",
        };
        write!(f, "{as_text}")
    }
}

impl FromStr for TaskStatus {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let norm = value.trim().to_ascii_lowercase();
        match norm.as_str() {
            "draft" | "backlog" => Ok(Self::Backlog),
            "todo" | "ready" => Ok(Self::Ready),
            "in-progress" | "inprogress" => Ok(Self::InProgress),
            "to-verify" | "toverify" => Ok(Self::ToVerify),
            "blocked" => Ok(Self::Blocked),
            "done" => Ok(Self::Done),
            "cancelled" | "canceled" => Ok(Self::Cancelled),
            _ => Err(format!(
                "invalid status '{value}'; expected one of draft, todo, in-progress, to-verify, blocked, done, cancelled"
            )),
        }
    }
}

impl TaskStatus {
    pub fn from_row(value: &str) -> Option<Self> {
        Self::from_str(value).ok()
    }

    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Done | Self::Cancelled)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, clap::ValueEnum)]
pub enum SourceSchema {
    /// Canonical export metadata (`Status:`/`Version:`/`Depends on:`/`Body:`).
    #[default]
    #[value(name = "canonical")]
    Canonical,
    /// create-task ledger blocks with a top-level `Deps:` line.
    #[value(name = "create-task")]
    CreateTask,
}

/// How a ledger file declares its schema. The marker is never required: a
/// ledger whose task headings all sit under sections the map or the canonical
/// names resolve is recognized as compatible without it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SchemaClass {
    Schema1,
    LegacyCompatible,
    Unsupported,
}

impl SchemaClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Schema1 => "schema-1",
            Self::LegacyCompatible => "legacy-compatible",
            Self::Unsupported => "unsupported",
        }
    }
}

impl Display for SchemaClass {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

pub const PROBLEM_NONCONFORMING_DEPS: &str = "nonconforming-deps";
pub const PROBLEM_UNKNOWN_DEPENDENCY: &str = "unknown-dependency";
pub const PROBLEM_SELF_DEPENDENCY: &str = "self-dependency";
pub const PROBLEM_CYCLE: &str = "cycle";
pub const PROBLEM_OTHER: &str = "other";

/// One blocking problem found while previewing an import. Every problem is
/// reported; a run never stops at the first one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportProblem {
    pub kind: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    /// Always serialized: `[]` says a clean line would keep nothing, which is
    /// different from a problem that has no keepable-ID field at all.
    #[serde(default)]
    pub keepable_ids: Vec<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub group: Vec<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fix: Option<String>,
}

impl ImportProblem {
    pub fn other(message: impl Into<String>) -> Self {
        Self {
            kind: PROBLEM_OTHER.to_string(),
            message: message.into(),
            file: None,
            line: None,
            task_id: None,
            value: None,
            keepable_ids: Vec::new(),
            group: Vec::new(),
            fix: None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProblemCounts {
    pub total: usize,
    pub nonconforming_deps: usize,
    pub unknown_ids: usize,
    pub cycle_groups: usize,
    pub other: usize,
}

impl ProblemCounts {
    pub fn of(problems: &[ImportProblem]) -> Self {
        let mut counts = Self {
            total: problems.len(),
            ..Self::default()
        };
        for problem in problems {
            match problem.kind.as_str() {
                PROBLEM_NONCONFORMING_DEPS => counts.nonconforming_deps += 1,
                PROBLEM_UNKNOWN_DEPENDENCY => counts.unknown_ids += 1,
                PROBLEM_CYCLE => counts.cycle_groups += 1,
                _ => counts.other += 1,
            }
        }
        counts
    }

    pub fn line(&self) -> String {
        format!(
            "{} problem(s): {} nonconforming Deps, {} unknown IDs, {} cycle groups, {} other",
            self.total, self.nonconforming_deps, self.unknown_ids, self.cycle_groups, self.other
        )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskSummary {
    #[serde(default)]
    pub priority: Priority,
    pub id: u64,
    pub status: TaskStatus,
    pub version: u64,
    pub title: String,
    pub deps: Vec<u64>,
    #[serde(default)]
    pub labels: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskDetail {
    #[serde(default)]
    pub priority: Priority,
    pub id: u64,
    pub status: TaskStatus,
    pub version: u64,
    pub title: String,
    pub body: String,
    pub deps: Vec<u64>,
    #[serde(default)]
    pub labels: Vec<String>,
    pub dependency_summaries: Vec<DependencySummary>,
    pub rule_version: u64,
    pub rules: String,
}

/// Task detail as printed by `show`: no duplicate dependency ID list and no
/// rules, which the payload carries at most once when requested.
#[derive(Debug, Clone, Serialize)]
pub struct ShowTask {
    pub priority: Priority,
    pub id: u64,
    pub status: TaskStatus,
    pub version: u64,
    pub title: String,
    pub body: String,
    pub labels: Vec<String>,
    pub dependency_summaries: Vec<DependencySummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DependencySummary {
    pub id: u64,
    pub status: TaskStatus,
    pub version: u64,
    pub title: String,
}

#[derive(Debug, Clone, Default)]
pub struct TaskUpdate {
    pub priority: Option<Priority>,
    pub title: Option<String>,
    pub body: Option<String>,
    pub status: Option<TaskStatus>,
    pub deps: Option<Vec<u64>>,
    pub clear_deps: bool,
    pub labels: Option<Vec<String>>,
    /// Labels merged into the current set; conflicts with `labels`.
    pub add_labels: Vec<String>,
    /// Labels removed from the current set; conflicts with `labels`.
    pub remove_labels: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleRecord {
    pub version: u64,
    pub body: String,
}

/// One task history event. `task_id` and `entity_type` stay available to
/// library callers but are not serialized: the history payload names the task
/// once at top level and only task events are listed.
#[derive(Debug, Clone, Serialize)]
pub struct HistoryEvent {
    pub event_id: u64,
    #[serde(skip)]
    pub task_id: Option<u64>,
    #[serde(skip)]
    pub entity_type: String,
    pub operation: String,
    pub resulting_version: i64,
    pub created_ms: i64,
    /// Snapshot fields that differ from the previous task event; absent when
    /// the event has no comparable predecessor (create, migrated, legacy text).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub changed_fields: Option<Vec<String>>,
    /// Stored snapshot, emitted as a nested JSON value named `snapshot`.
    #[serde(
        rename = "snapshot",
        skip_serializing_if = "Option::is_none",
        serialize_with = "serialize_snapshot"
    )]
    pub snapshot_json: Option<String>,
}

/// Emits stored snapshot text as nested JSON; text that is not valid JSON
/// (possible in legacy stores) is emitted unchanged as a JSON string.
fn serialize_snapshot<S: serde::Serializer>(
    snapshot: &Option<String>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    match snapshot.as_deref() {
        Some(text) => match serde_json::from_str::<serde_json::Value>(text) {
            Ok(value) => value.serialize(serializer),
            Err(_) => serializer.serialize_str(text),
        },
        None => serializer.serialize_none(),
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pagination<T> {
    pub items: Vec<T>,
    pub has_more: bool,
    pub next_after: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InitResult {
    pub project_id: String,
    pub db_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportReport {
    pub source_sha256: String,
    pub has_bom: bool,
    pub task_count: usize,
    pub tasks: Vec<ImportTaskPreview>,
    pub sections: Vec<ImportSectionPreview>,
    pub rules: String,
    pub duplicate_ids: Vec<u64>,
    pub unmapped_sections: Vec<String>,
    pub ambiguous_sections: Vec<String>,
    pub unassigned_ranges: Vec<SourceRange>,
    pub has_unknown_content: bool,
    #[serde(default)]
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ImportTaskPreview {
    #[serde(default)]
    pub priority: Priority,
    pub id: u64,
    pub title: String,
    pub section: String,
    pub status: TaskStatus,
    #[serde(default)]
    pub deps: Vec<u64>,
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default)]
    pub consumed_metadata: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ImportSectionPreview {
    pub heading: String,
    pub status: Option<TaskStatus>,
    pub contains_tasks: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SourceRange {
    pub start_byte: usize,
    pub end_byte: usize,
    pub preview: String,
}

pub fn parse_task_id(input: &str) -> Result<u64, String> {
    let v = input.trim();
    if !v.to_ascii_uppercase().starts_with(ID_PREFIX) {
        return Err(format!(
            "invalid task id '{input}': expected the form T-<digits>"
        ));
    }
    let num = &v[2..];
    if num.is_empty() {
        return Err(format!(
            "invalid task id '{input}': expected the form T-<digits>"
        ));
    }
    num.parse::<u64>()
        .map_err(|_| format!("invalid task id '{input}': expected the form T-<digits>"))
}

pub fn render_task_id(id: u64) -> String {
    format!("{ID_PREFIX}{id:03}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_accept_short_and_padded_forms() {
        assert_eq!(parse_task_id("T-1"), Ok(1));
        assert_eq!(parse_task_id("t-001"), Ok(1));
        assert_eq!(render_task_id(1), "T-001");
        assert!(parse_task_id("1").is_err());
        assert!(parse_task_id("T-").is_err());
    }

    #[test]
    fn statuses_have_stable_cli_and_json_names() {
        assert_eq!(TaskStatus::InProgress.to_string(), "in-progress");
        assert_eq!(
            "in-progress".parse::<TaskStatus>(),
            Ok(TaskStatus::InProgress)
        );
        assert_eq!(
            serde_json::to_string(&TaskStatus::InProgress).unwrap(),
            "\"in-progress\""
        );
    }
}
