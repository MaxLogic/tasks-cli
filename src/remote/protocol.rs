//! Shared typed wire requests; no SQL, server runtime or temporary-file paths.
use crate::model::{Attribution, Priority, TaskStatus, TaskUpdate};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;
fn page_size() -> usize {
    20
}
fn initial_status() -> TaskStatus {
    TaskStatus::Backlog
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum ReadRequest {
    List {
        #[serde(default)]
        status: Option<TaskStatus>,
        #[serde(default)]
        after: Option<String>,
        #[serde(default = "page_size")]
        limit: usize,
        #[serde(default)]
        label: Option<String>,
        #[serde(default)]
        open: bool,
        #[serde(default)]
        needs_human: bool,
    },
    Unlocks {
        #[serde(default)]
        offset: u64,
        #[serde(default = "page_size")]
        limit: usize,
    },
    Search {
        text: String,
        #[serde(default)]
        ranked: bool,
        #[serde(default)]
        prefix: bool,
        #[serde(default)]
        label: Option<String>,
        #[serde(default)]
        after: Option<u64>,
        #[serde(default)]
        offset: u64,
        #[serde(default = "page_size")]
        limit: usize,
    },
    Show {
        ids: Vec<String>,
        #[serde(default)]
        rules: bool,
    },
    History {
        id: String,
        #[serde(default)]
        after: Option<u64>,
        #[serde(default = "page_size")]
        limit: usize,
        #[serde(default)]
        event: Option<u64>,
    },
    ProjectHistory {
        #[serde(default)]
        after: Option<u64>,
        #[serde(default = "page_size")]
        limit: usize,
    },
    Rules,
    ProjectKey,
    Titles {
        references: Vec<String>,
    },
    ViewerTasks {
        request: Value,
    },
    ViewerShow {
        id: String,
    },
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ViewerProjectsRequest {
    pub request: Value,
    pub root_matches: Vec<Uuid>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ViewerUpdate {
    pub request: Value,
    #[serde(default)]
    pub attribution: Attribution,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetArchive {
    pub archived: bool,
    #[serde(default)]
    pub attribution: Attribution,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TitleMatch {
    pub key: Option<String>,
    pub id: u64,
    pub title: String,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TitlesResult {
    pub titles: Vec<TitleMatch>,
    pub known_keys: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateProject {
    pub project_id: Uuid,
    pub name: String,
    #[serde(default)]
    pub project_key: Option<String>,
    #[serde(default)]
    pub attribution: Attribution,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateTask {
    pub title: String,
    pub body: String,
    #[serde(default)]
    pub priority: Priority,
    #[serde(default = "initial_status")]
    pub status: TaskStatus,
    #[serde(default)]
    pub deps: Vec<String>,
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default)]
    pub attribution: Attribution,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateTask {
    pub task_ref: String,
    pub expect_version: u64,
    pub changes: TaskUpdate,
    /// Keyed dependency references are resolved under the mutation transaction.
    #[serde(default)]
    pub dependency_refs: Option<Vec<String>>,
    #[serde(default)]
    pub attribution: Attribution,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetRules {
    pub body: String,
    pub expect_version: u64,
    #[serde(default)]
    pub attribution: Attribution,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetKey {
    pub project_key: String,
    #[serde(default)]
    pub attribution: Attribution,
}

/// The JSON member is exactly the existing CLI envelope; text uses the same
/// renderer. Clients select one representation without reconstructing fields.
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApiOutput {
    pub output: Value,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub catalog_name: Option<String>,
}

/// Transport confirmation of a persisted terminal result. Trusted TLS gateways
/// may produce unrelated errors; those lack this request-bound service marker.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestReceipt {
    pub request_id: Uuid,
    pub route: String,
    pub payload_sha256: String,
    pub status: u16,
}
