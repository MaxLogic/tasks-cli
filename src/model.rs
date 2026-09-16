use serde::{Deserialize, Serialize};
use std::fmt::{Display, Formatter};
use std::str::FromStr;

pub const TITLE_MAX_CHARS: usize = 500;
pub const BODY_MAX_BYTES: usize = 1_048_576;
pub const RULES_MAX_BYTES: usize = 262_144;
pub const MAX_DEPENDENCIES: usize = 100;
pub const ID_PREFIX: &str = "T-";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum TaskStatus {
    #[value(name = "backlog")]
    Backlog,
    #[value(name = "ready")]
    Ready,
    #[value(name = "in-progress")]
    #[serde(rename = "in-progress")]
    InProgress,
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
            Self::Backlog => "backlog",
            Self::Ready => "ready",
            Self::InProgress => "in-progress",
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
            "backlog" => Ok(Self::Backlog),
            "ready" => Ok(Self::Ready),
            "in-progress" | "inprogress" => Ok(Self::InProgress),
            "blocked" => Ok(Self::Blocked),
            "done" => Ok(Self::Done),
            "cancelled" | "canceled" => Ok(Self::Cancelled),
            _ => Err(format!("invalid status '{value}'")),
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskSummary {
    pub id: u64,
    pub status: TaskStatus,
    pub version: u64,
    pub title: String,
    pub deps: Vec<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskDetail {
    pub id: u64,
    pub status: TaskStatus,
    pub version: u64,
    pub title: String,
    pub body: String,
    pub deps: Vec<u64>,
    pub dependency_summaries: Vec<DependencySummary>,
    pub rule_version: u64,
    pub rules: String,
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
    pub title: Option<String>,
    pub body: Option<String>,
    pub status: Option<TaskStatus>,
    pub deps: Option<Vec<u64>>,
    pub clear_deps: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleRecord {
    pub version: u64,
    pub body: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEvent {
    pub event_id: u64,
    pub task_id: Option<u64>,
    pub entity_type: String,
    pub operation: String,
    pub resulting_version: i64,
    pub created_ms: i64,
    pub snapshot_json: Option<String>,
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
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ImportTaskPreview {
    pub id: u64,
    pub title: String,
    pub section: String,
    pub status: TaskStatus,
    #[serde(default)]
    pub deps: Vec<u64>,
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
        return Err(format!("invalid task id '{input}'"));
    }
    let num = &v[2..];
    if num.is_empty() {
        return Err(format!("invalid task id '{input}'"));
    }
    num.parse::<u64>()
        .map_err(|_| format!("invalid task id '{input}'"))
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
