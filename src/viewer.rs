//! Additive `tasks viewer` JSON protocol (`viewer/spec.md` sections 4, 7 and 11).
//!
//! The collection commands page through one read transaction per request and
//! return a snapshot token binding the project UUID, the database file
//! identity, the current maximum event ID and the query parameters. Reads use
//! the existing read-only opening rules and never migrate. `viewer info` never
//! touches a store.

use crate::error::AppError;
use crate::labels;
use crate::model::{
    parse_task_id, render_task_id, DependencySummary, Priority, TaskDetail, TaskStatus, TaskUpdate,
    BODY_MAX_BYTES, MAX_DEPENDENCIES, TITLE_MAX_CHARS,
};
use crate::registry;
use crate::storage::{validate_storage_path, validate_storage_root};
use crate::store::{data_root_project_path, Store, CURRENT_SCHEMA_VERSION};
use rusqlite::types::Value as SqlValue;
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::io::Read;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

/// Protocol version reported inside every viewer payload.
pub const PROTOCOL_VERSION: u8 = 1;
/// Request documents are bounded before parsing.
pub const REQUEST_MAX_BYTES: usize = 8 * 1024 * 1024;
/// Default page size for both collections.
pub const DEFAULT_LIMIT: u64 = 100;
/// Maximum page size for both collections.
pub const MAX_LIMIT: u64 = 200;

const SNAPSHOT_PREFIX: &str = "v1:";
const STATUS_VALUES: [&str; 6] = [
    "draft",
    "todo",
    "in-progress",
    "blocked",
    "done",
    "cancelled",
];
const PRIORITY_VALUES: [&str; 4] = ["P0", "P1", "P2", "P3"];
const OPERATIONS: [&str; 5] = ["info", "projects", "tasks", "show", "update"];
const EDITABLE_FIELD_NAMES: [&str; 6] = ["title", "body", "status", "priority", "labels", "deps"];

// ---------------------------------------------------------------------------
// Response payloads
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct ViewerInfoPayload {
    pub protocol_version: u8,
    pub operations: Vec<&'static str>,
    pub statuses: Vec<&'static str>,
    pub priorities: Vec<&'static str>,
    pub editable_fields: Vec<&'static str>,
    pub editable_field_limits: EditableFieldLimits,
}

#[derive(Debug, Serialize)]
pub struct EditableFieldLimits {
    pub title: TitleLimit,
    pub body: BodyLimit,
    pub status: EnumLimit,
    pub priority: EnumLimit,
    pub labels: LabelsLimit,
    pub deps: DepsLimit,
}

#[derive(Debug, Serialize)]
pub struct TitleLimit {
    pub max_chars: usize,
}

#[derive(Debug, Serialize)]
pub struct BodyLimit {
    pub max_utf8_bytes: usize,
}

#[derive(Debug, Serialize)]
pub struct EnumLimit {
    pub values: Vec<&'static str>,
}

#[derive(Debug, Serialize)]
pub struct LabelsLimit {
    pub max_count: usize,
    pub item_max_chars: usize,
    pub item_allowed: &'static str,
}

#[derive(Debug, Serialize)]
pub struct DepsLimit {
    pub max_count: usize,
}

#[derive(Debug, Serialize)]
pub struct ViewerProjectsPayload {
    pub protocol_version: u8,
    pub items: Vec<ProjectItem>,
    pub total_count: u64,
    pub offset: u64,
    pub limit: u64,
    pub has_more: bool,
    pub next_offset: Option<u64>,
    pub snapshot: String,
}

#[derive(Debug, Serialize)]
pub struct ProjectItem {
    pub project_id: String,
    pub name: String,
    pub roots: Vec<String>,
    pub availability: &'static str,
    pub error: Option<ProjectError>,
    pub sampled_at_ms: i64,
    pub stats: Option<ProjectStats>,
}

#[derive(Debug, Serialize)]
pub struct ProjectError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Serialize)]
pub struct ProjectStats {
    pub total: u64,
    pub open: u64,
    pub blocked: u64,
    pub done: u64,
    pub cancelled: u64,
    pub started_ms: Option<i64>,
    pub last_write_ms: Option<i64>,
    pub progress_percent: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct ViewerTasksPayload {
    pub protocol_version: u8,
    pub items: Vec<TaskItem>,
    pub total_count: u64,
    pub offset: u64,
    pub limit: u64,
    pub has_more: bool,
    pub next_offset: Option<u64>,
    pub snapshot: String,
}

#[derive(Debug, Serialize)]
pub struct TaskItem {
    pub id: u64,
    pub title: String,
    pub status: TaskStatus,
    pub priority: Priority,
    pub version: u64,
    #[serde(default)]
    pub labels: Vec<String>,
    pub dependency_count: u64,
    pub waiting_dependency_count: u64,
    pub created_ms: i64,
    pub updated_ms: i64,
}

#[derive(Debug, Serialize)]
pub struct ViewerShowPayload {
    pub protocol_version: u8,
    #[serde(flatten)]
    pub task: TaskDetail,
    pub created_ms: i64,
    pub updated_ms: i64,
}

#[derive(Debug, Serialize)]
pub struct ViewerUpdatePayload {
    pub protocol_version: u8,
    pub id: u64,
    pub status: String,
    pub version: u64,
    pub event_id: Option<u64>,
}

/// `viewer info` reports the protocol surface without opening or creating a store.
pub fn info() -> ViewerInfoPayload {
    ViewerInfoPayload {
        protocol_version: PROTOCOL_VERSION,
        operations: OPERATIONS.to_vec(),
        statuses: STATUS_VALUES.to_vec(),
        priorities: PRIORITY_VALUES.to_vec(),
        editable_fields: EDITABLE_FIELD_NAMES.to_vec(),
        editable_field_limits: EditableFieldLimits {
            title: TitleLimit {
                max_chars: TITLE_MAX_CHARS,
            },
            body: BodyLimit {
                max_utf8_bytes: BODY_MAX_BYTES,
            },
            status: EnumLimit {
                values: STATUS_VALUES.to_vec(),
            },
            priority: EnumLimit {
                values: PRIORITY_VALUES.to_vec(),
            },
            labels: LabelsLimit {
                max_count: 32,
                item_max_chars: 64,
                item_allowed: "ASCII letters, digits and -_.:",
            },
            deps: DepsLimit {
                max_count: MAX_DEPENDENCIES,
            },
        },
    }
}

// ---------------------------------------------------------------------------
// Request reading and strict parsing
// ---------------------------------------------------------------------------

fn read_request_bytes(path: &Path) -> Result<Vec<u8>, AppError> {
    let bytes = if path == Path::new("-") {
        let mut bytes = Vec::new();
        std::io::stdin()
            .take(REQUEST_MAX_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|error| AppError::io_op("read the viewer request from stdin", error))?;
        bytes
    } else {
        std::fs::read(path)
            .map_err(|error| AppError::io_path("read the viewer request file", path, error))?
    };
    if bytes.len() > REQUEST_MAX_BYTES {
        return Err(AppError::Usage(format!(
            "the viewer request is {} bytes; the limit is {REQUEST_MAX_BYTES} bytes (8 MiB). Send only the query document",
            bytes.len()
        )));
    }
    Ok(bytes)
}

fn parse_request(bytes: &[u8]) -> Result<Value, AppError> {
    if bytes.iter().all(u8::is_ascii_whitespace) {
        return Err(AppError::Usage(
            "the viewer request is empty; send a JSON object".to_string(),
        ));
    }
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    let value = StrictValue::deserialize(&mut deserializer).map_err(|error| {
        AppError::Usage(format!("the viewer request is not valid JSON: {error}"))
    })?;
    deserializer.end().map_err(|error| {
        AppError::Usage(format!(
            "the viewer request has content after the JSON document: {error}"
        ))
    })?;
    Ok(value.0)
}

/// A `serde_json::Value` that rejects duplicated object keys at every level.
#[derive(Debug)]
struct StrictValue(Value);

impl<'de> Deserialize<'de> for StrictValue {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer
            .deserialize_any(StrictValueVisitor)
            .map(StrictValue)
    }
}

struct StrictValueVisitor;

impl<'de> serde::de::Visitor<'de> for StrictValueVisitor {
    type Value = Value;

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("a JSON value")
    }

    fn visit_bool<E>(self, value: bool) -> Result<Value, E> {
        Ok(Value::Bool(value))
    }

    fn visit_i64<E>(self, value: i64) -> Result<Value, E> {
        Ok(Value::Number(value.into()))
    }

    fn visit_u64<E>(self, value: u64) -> Result<Value, E> {
        Ok(Value::Number(value.into()))
    }

    fn visit_f64<E>(self, value: f64) -> Result<Value, E>
    where
        E: serde::de::Error,
    {
        serde_json::Number::from_f64(value)
            .map(Value::Number)
            .ok_or_else(|| E::custom("non-finite JSON numbers are not supported"))
    }

    fn visit_str<E>(self, value: &str) -> Result<Value, E> {
        Ok(Value::String(value.to_string()))
    }

    fn visit_string<E>(self, value: String) -> Result<Value, E> {
        Ok(Value::String(value))
    }

    fn visit_none<E>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }

    fn visit_unit<E>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }

    fn visit_some<D>(self, deserializer: D) -> Result<Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        StrictValue::deserialize(deserializer).map(|value| value.0)
    }

    fn visit_seq<A>(self, mut sequence: A) -> Result<Value, A::Error>
    where
        A: serde::de::SeqAccess<'de>,
    {
        let mut items = Vec::new();
        while let Some(item) = sequence.next_element::<StrictValue>()? {
            items.push(item.0);
        }
        Ok(Value::Array(items))
    }

    fn visit_map<A>(self, mut source: A) -> Result<Value, A::Error>
    where
        A: serde::de::MapAccess<'de>,
    {
        let mut map = Map::new();
        while let Some(key) = source.next_key::<String>()? {
            if map.contains_key(&key) {
                return Err(serde::de::Error::custom(format!(
                    "duplicate JSON key '{key}'; each field may appear only once"
                )));
            }
            let value = source.next_value::<StrictValue>()?;
            map.insert(key, value.0);
        }
        Ok(Value::Object(map))
    }
}

fn request_object(value: Value) -> Result<Map<String, Value>, AppError> {
    match value {
        Value::Object(map) => Ok(map),
        other => Err(AppError::Usage(format!(
            "the viewer request must be a JSON object, found {}",
            json_kind(&other)
        ))),
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

fn reject_unknown_keys(map: &Map<String, Value>, allowed: &[&str]) -> Result<(), AppError> {
    if let Some(key) = map.keys().find(|key| !allowed.contains(&key.as_str())) {
        return Err(AppError::Usage(format!(
            "unknown viewer request field '{key}'; supported fields are {}",
            allowed.join(", ")
        )));
    }
    Ok(())
}

fn field_type_error(field: &str, expected: &str, value: &Value) -> AppError {
    AppError::Usage(format!(
        "'{field}' must be {expected}, found {}",
        json_kind(value)
    ))
}

fn field_null_error(field: &str) -> AppError {
    AppError::Usage(format!(
        "'{field}' must not be null; omit the field to keep the documented default"
    ))
}

fn unsupported_value(field: &str, value: &str, allowed: &[&str]) -> AppError {
    AppError::Usage(format!(
        "'{field}' has the unsupported value '{value}'; supported values are {}",
        allowed.join(", ")
    ))
}

fn optional_string(map: &Map<String, Value>, field: &str) -> Result<Option<String>, AppError> {
    match map.get(field) {
        None => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(Value::Null) => Err(field_null_error(field)),
        Some(other) => Err(field_type_error(field, "a string", other)),
    }
}

/// `snapshot` is the one optional field where an explicit null is documented.
fn nullable_string(map: &Map<String, Value>, field: &str) -> Result<Option<String>, AppError> {
    match map.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(other) => Err(field_type_error(field, "a string or null", other)),
    }
}

fn optional_string_array(
    map: &Map<String, Value>,
    field: &str,
) -> Result<Option<Vec<String>>, AppError> {
    match map.get(field) {
        None => Ok(None),
        Some(Value::Array(items)) => {
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                match item {
                    Value::String(text) => out.push(text.clone()),
                    other => return Err(field_type_error(field, "an array of strings", other)),
                }
            }
            Ok(Some(out))
        }
        Some(Value::Null) => Err(field_null_error(field)),
        Some(other) => Err(field_type_error(field, "an array of strings", other)),
    }
}

fn optional_u64_array(map: &Map<String, Value>, field: &str) -> Result<Option<Vec<u64>>, AppError> {
    match map.get(field) {
        None => Ok(None),
        Some(Value::Array(items)) => {
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                match item {
                    Value::Number(number) => match number.as_u64() {
                        Some(value) => out.push(value),
                        None => {
                            return Err(AppError::Usage(format!(
                                "'{field}' items must be whole numbers that are zero or greater"
                            )))
                        }
                    },
                    other => {
                        return Err(field_type_error(field, "an array of whole numbers", other))
                    }
                }
            }
            Ok(Some(out))
        }
        Some(Value::Null) => Err(field_null_error(field)),
        Some(other) => Err(field_type_error(field, "an array of whole numbers", other)),
    }
}

fn optional_u64(map: &Map<String, Value>, field: &str) -> Result<Option<u64>, AppError> {
    match map.get(field) {
        None => Ok(None),
        Some(Value::Number(number)) => match number.as_u64() {
            Some(value) => Ok(Some(value)),
            None => Err(AppError::Usage(format!(
                "'{field}' must be a whole number that is zero or greater"
            ))),
        },
        Some(Value::Null) => Err(field_null_error(field)),
        Some(other) => Err(field_type_error(field, "a whole number", other)),
    }
}

fn required_positive_u64(map: &Map<String, Value>, field: &str) -> Result<u64, AppError> {
    let value = map.get(field).ok_or_else(|| {
        AppError::Usage(format!(
            "the viewer request is missing the required field '{field}'"
        ))
    })?;
    match value {
        Value::Number(number) => match number.as_u64() {
            Some(value) if value > 0 => Ok(value),
            _ => Err(AppError::Usage(format!(
                "'{field}' must be a positive whole number"
            ))),
        },
        other => Err(field_type_error(field, "a positive whole number", other)),
    }
}

fn enum_field<T>(
    map: &Map<String, Value>,
    field: &str,
    allowed: &[&str],
    default: T,
    parse: fn(&str) -> Option<T>,
) -> Result<T, AppError> {
    match map.get(field) {
        None => Ok(default),
        Some(Value::String(text)) => {
            parse(text).ok_or_else(|| unsupported_value(field, text, allowed))
        }
        Some(Value::Null) => Err(field_null_error(field)),
        Some(other) => Err(field_type_error(field, "a string", other)),
    }
}

fn optional_enum_field<T>(
    map: &Map<String, Value>,
    field: &str,
    allowed: &[&str],
    parse: fn(&str) -> Option<T>,
) -> Result<Option<T>, AppError> {
    match map.get(field) {
        None => Ok(None),
        Some(Value::String(text)) => parse(text)
            .map(Some)
            .ok_or_else(|| unsupported_value(field, text, allowed)),
        Some(Value::Null) => Err(field_null_error(field)),
        Some(other) => Err(field_type_error(field, "a string", other)),
    }
}

fn enum_array_field<T>(
    map: &Map<String, Value>,
    field: &str,
    allowed: &[&str],
    parse: fn(&str) -> Option<T>,
) -> Result<Vec<T>, AppError> {
    match map.get(field) {
        None => Ok(Vec::new()),
        Some(Value::Array(items)) => {
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                match item {
                    Value::String(text) => out
                        .push(parse(text).ok_or_else(|| unsupported_value(field, text, allowed))?),
                    other => return Err(field_type_error(field, "an array of strings", other)),
                }
            }
            Ok(out)
        }
        Some(Value::Null) => Err(field_null_error(field)),
        Some(other) => Err(field_type_error(field, "an array of strings", other)),
    }
}

fn parse_canonical_status(value: &str) -> Option<TaskStatus> {
    match value {
        "draft" => Some(TaskStatus::Backlog),
        "todo" => Some(TaskStatus::Ready),
        "in-progress" => Some(TaskStatus::InProgress),
        "blocked" => Some(TaskStatus::Blocked),
        "done" => Some(TaskStatus::Done),
        "cancelled" => Some(TaskStatus::Cancelled),
        _ => None,
    }
}

fn parse_canonical_priority(value: &str) -> Option<Priority> {
    match value {
        "P0" => Some(Priority::P0),
        "P1" => Some(Priority::P1),
        "P2" => Some(Priority::P2),
        "P3" => Some(Priority::P3),
        _ => None,
    }
}

fn status_rank(status: &TaskStatus) -> u8 {
    match status {
        TaskStatus::Backlog => 0,
        TaskStatus::Ready => 1,
        TaskStatus::InProgress => 2,
        TaskStatus::Blocked => 3,
        TaskStatus::Done => 4,
        TaskStatus::Cancelled => 5,
    }
}

fn priority_rank(priority: Priority) -> u8 {
    match priority {
        Priority::P0 => 0,
        Priority::P1 => 1,
        Priority::P2 => 2,
        Priority::P3 => 3,
    }
}

fn canonical_project(project: &str) -> Result<String, AppError> {
    Uuid::parse_str(project)
        .map(|id| id.to_string())
        .map_err(|error| {
            AppError::Usage(format!(
                "--project '{project}' is not a UUID ({error}); pass the UUID printed by tasks init"
            ))
        })
}

fn page_limit(limit: u64) -> Result<u64, AppError> {
    if (1..=MAX_LIMIT).contains(&limit) {
        Ok(limit)
    } else {
        Err(AppError::Usage(format!(
            "'limit' must be between 1 and {MAX_LIMIT}; got {limit}"
        )))
    }
}

fn page_offset(offset: u64) -> Result<u64, AppError> {
    if offset > i64::MAX as u64 {
        return Err(AppError::Usage(format!(
            "'offset' must fit SQLite's signed integer range; got {offset}"
        )));
    }
    Ok(offset)
}

fn placeholders(count: usize) -> String {
    std::iter::repeat_n("?", count)
        .collect::<Vec<_>>()
        .join(",")
}

fn compare_ascii_text(left: &str, right: &str) -> std::cmp::Ordering {
    left.to_ascii_lowercase()
        .cmp(&right.to_ascii_lowercase())
        .then_with(|| left.cmp(right))
}

fn contains_ascii_insensitive(haystack: &str, needle: &str) -> bool {
    haystack.to_ascii_lowercase().contains(needle)
}

fn escape_like_literal(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        if matches!(character, '\\' | '%' | '_') {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    escaped
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn file_identity(path: &Path) -> String {
    match file_id::get_file_id(path) {
        Ok(identity) => format!("{identity:?}"),
        Err(_) => "unavailable".to_string(),
    }
}

// ---------------------------------------------------------------------------
// Snapshot tokens
// ---------------------------------------------------------------------------

fn encode_token(payload: &Value) -> String {
    let bytes = serde_json::to_vec(payload).unwrap_or_default();
    let mut token = String::with_capacity(SNAPSHOT_PREFIX.len() + bytes.len() * 2);
    token.push_str(SNAPSHOT_PREFIX);
    for byte in bytes {
        token.push_str(&format!("{byte:02x}"));
    }
    token
}

fn decode_token(token: &str) -> Option<Value> {
    let hex = token.strip_prefix(SNAPSHOT_PREFIX)?;
    if hex.len() % 2 != 0 {
        return None;
    }
    let raw = hex.as_bytes();
    let mut bytes = Vec::with_capacity(raw.len() / 2);
    let mut index = 0;
    while index < raw.len() {
        let pair = std::str::from_utf8(&raw[index..index + 2]).ok()?;
        bytes.push(u8::from_str_radix(pair, 16).ok()?);
        index += 2;
    }
    serde_json::from_slice(&bytes).ok()
}

fn stale_snapshot(reason: &str) -> AppError {
    AppError::StaleSnapshot(format!(
        "{reason}; reload the list from offset 0 and discard cached pages"
    ))
}

/// Compare a decoded token against the expected payload, ignoring the bound
/// count so a valid page can reuse it without recounting.
fn token_matches(decoded: &Value, expected: &Value) -> Option<u64> {
    let count = decoded.get("count")?.as_u64();
    let mut trimmed = decoded.clone();
    if let Value::Object(map) = &mut trimmed {
        map.remove("count");
    }
    (trimmed == *expected).then_some(count?)
}

// ---------------------------------------------------------------------------
// viewer projects
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Availability {
    Available,
    Missing,
    Error,
}

impl Availability {
    fn as_str(self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::Missing => "missing",
            Self::Error => "error",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProjectState {
    All,
    HasOpen,
    HasBlocked,
    Complete,
    Empty,
    Unavailable,
}

impl ProjectState {
    const VALUES: [&'static str; 6] = [
        "all",
        "has-open",
        "has-blocked",
        "complete",
        "empty",
        "unavailable",
    ];

    fn parse(value: &str) -> Option<Self> {
        match value {
            "all" => Some(Self::All),
            "has-open" => Some(Self::HasOpen),
            "has-blocked" => Some(Self::HasBlocked),
            "complete" => Some(Self::Complete),
            "empty" => Some(Self::Empty),
            "unavailable" => Some(Self::Unavailable),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::HasOpen => "has-open",
            Self::HasBlocked => "has-blocked",
            Self::Complete => "complete",
            Self::Empty => "empty",
            Self::Unavailable => "unavailable",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProjectSort {
    Name,
    Open,
    Total,
    Blocked,
    Started,
    LastWrite,
    Progress,
}

impl ProjectSort {
    const VALUES: [&'static str; 7] = [
        "name",
        "open",
        "total",
        "blocked",
        "started",
        "last-write",
        "progress",
    ];

    fn parse(value: &str) -> Option<Self> {
        match value {
            "name" => Some(Self::Name),
            "open" => Some(Self::Open),
            "total" => Some(Self::Total),
            "blocked" => Some(Self::Blocked),
            "started" => Some(Self::Started),
            "last-write" => Some(Self::LastWrite),
            "progress" => Some(Self::Progress),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Name => "name",
            Self::Open => "open",
            Self::Total => "total",
            Self::Blocked => "blocked",
            Self::Started => "started",
            Self::LastWrite => "last-write",
            Self::Progress => "progress",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Direction {
    Asc,
    Desc,
}

impl Direction {
    const VALUES: [&'static str; 2] = ["asc", "desc"];

    fn parse(value: &str) -> Option<Self> {
        match value {
            "asc" => Some(Self::Asc),
            "desc" => Some(Self::Desc),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Asc => "asc",
            Self::Desc => "desc",
        }
    }

    fn descending(self) -> bool {
        matches!(self, Self::Desc)
    }
}

struct ProjectQuery {
    query: String,
    state: ProjectState,
    sort: ProjectSort,
    direction: Direction,
    offset: u64,
    limit: u64,
    snapshot: Option<String>,
}

struct ProjectRecord {
    project_id: String,
    name: String,
    roots: Vec<String>,
    availability: Availability,
    error: Option<ProjectError>,
    sampled_at_ms: i64,
    stats: Option<ProjectStats>,
}

impl From<ProjectRecord> for ProjectItem {
    fn from(record: ProjectRecord) -> Self {
        Self {
            project_id: record.project_id,
            name: record.name,
            roots: record.roots,
            availability: record.availability.as_str(),
            error: record.error,
            sampled_at_ms: record.sampled_at_ms,
            stats: record.stats,
        }
    }
}

fn project_request(value: Value) -> Result<ProjectQuery, AppError> {
    let map = request_object(value)?;
    reject_unknown_keys(
        &map,
        &[
            "query",
            "state",
            "sort",
            "direction",
            "offset",
            "limit",
            "snapshot",
        ],
    )?;
    Ok(ProjectQuery {
        query: optional_string(&map, "query")?
            .unwrap_or_default()
            .trim()
            .to_string(),
        state: enum_field(
            &map,
            "state",
            &ProjectState::VALUES,
            ProjectState::All,
            ProjectState::parse,
        )?,
        sort: enum_field(
            &map,
            "sort",
            &ProjectSort::VALUES,
            ProjectSort::Name,
            ProjectSort::parse,
        )?,
        direction: enum_field(
            &map,
            "direction",
            &Direction::VALUES,
            Direction::Asc,
            Direction::parse,
        )?,
        offset: page_offset(optional_u64(&map, "offset")?.unwrap_or(0))?,
        limit: page_limit(optional_u64(&map, "limit")?.unwrap_or(DEFAULT_LIMIT))?,
        snapshot: nullable_string(&map, "snapshot")?,
    })
}

fn project_params(query: &ProjectQuery) -> Value {
    serde_json::json!({
        "query": query.query,
        "state": query.state.as_str(),
        "sort": query.sort.as_str(),
        "direction": query.direction.as_str(),
    })
}

fn projects_token(query: &ProjectQuery, catalog_digest: &str) -> String {
    encode_token(&serde_json::json!({
        "v": PROTOCOL_VERSION,
        "kind": "projects",
        "params": project_params(query),
        "catalog": catalog_digest,
    }))
}

fn validate_projects_token(
    token: &str,
    query: &ProjectQuery,
    catalog_digest: &str,
) -> Result<(), AppError> {
    let decoded = decode_token(token)
        .ok_or_else(|| stale_snapshot("the snapshot token is not a valid v1 token"))?;
    let expected = serde_json::json!({
        "v": PROTOCOL_VERSION,
        "kind": "projects",
        "params": project_params(query),
        "catalog": catalog_digest,
    });
    if decoded != expected {
        return Err(stale_snapshot(
            "the project catalog or query changed since this page was requested",
        ));
    }
    Ok(())
}

/// Enumerate the registry once and sample each project database in turn.
pub fn projects(data_root: &Path, request_file: &Path) -> Result<ViewerProjectsPayload, AppError> {
    let request = parse_request(&read_request_bytes(request_file)?)?;
    let query = project_request(request)?;
    let catalog = enumerate_projects(data_root)?;
    let catalog_digest = catalog_hash(&catalog);
    if let Some(token) = query.snapshot.as_deref() {
        validate_projects_token(token, &query, &catalog_digest)?;
    }
    let mut records = catalog
        .into_iter()
        .filter(|record| matches_project_query(record, &query))
        .collect::<Vec<_>>();
    sort_projects(&mut records, &query);
    let total_count = records.len() as u64;
    let offset = query.offset;
    let selected = if offset >= total_count {
        Vec::new()
    } else {
        records
            .into_iter()
            .skip(offset as usize)
            .take(query.limit as usize)
            .collect::<Vec<_>>()
    };
    let has_more = (offset + selected.len() as u64) < total_count;
    let next_offset = has_more.then_some(offset + selected.len() as u64);
    Ok(ViewerProjectsPayload {
        protocol_version: PROTOCOL_VERSION,
        items: selected.into_iter().map(ProjectItem::from).collect(),
        total_count,
        offset,
        limit: query.limit,
        has_more,
        next_offset,
        snapshot: projects_token(&query, &catalog_digest),
    })
}

fn enumerate_projects(data_root: &Path) -> Result<Vec<ProjectRecord>, AppError> {
    let data_root = validate_storage_root(data_root)?;
    let registry = registry::list_bindings(&data_root)?;
    let mut bound: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for binding in &registry.bindings {
        let parsed = Uuid::parse_str(&binding.project_id).map_err(|error| {
            AppError::Registry(format!(
                "registry binding '{}' has an invalid project id '{}': {error}; fix or remove the binding",
                binding.root, binding.project_id
            ))
        })?;
        bound
            .entry(parsed.to_string())
            .or_default()
            .push(binding.root.clone());
    }
    let sampled_at_ms = now_ms();
    let mut records = Vec::with_capacity(bound.len());
    for (project_id, mut roots) in bound {
        roots.sort_by(|left, right| compare_ascii_text(left, right).then_with(|| left.cmp(right)));
        let name = roots
            .first()
            .and_then(|root| Path::new(root).file_name())
            .map(|name| name.to_string_lossy().into_owned())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| project_id.clone());
        let db_path = data_root_project_path(&data_root, &project_id);
        let (availability, error, stats) = sample_project(&db_path, &project_id);
        records.push(ProjectRecord {
            project_id,
            name,
            roots,
            availability,
            error,
            sampled_at_ms,
            stats,
        });
    }
    Ok(records)
}

fn sample_project(
    db_path: &Path,
    project_id: &str,
) -> (Availability, Option<ProjectError>, Option<ProjectStats>) {
    if !db_path.is_file() {
        return (Availability::Missing, None, None);
    }
    match sample_project_inner(db_path, project_id) {
        Ok(stats) => (Availability::Available, None, Some(stats)),
        Err(error) => (
            Availability::Error,
            Some(ProjectError {
                code: error.code().to_string(),
                message: error.to_string(),
            }),
            None,
        ),
    }
}

/// Open one project database with a zero busy timeout, read its aggregate
/// statistics and close it before the caller opens the next database.
fn sample_project_inner(db_path: &Path, project_id: &str) -> Result<ProjectStats, AppError> {
    validate_storage_path(db_path)?;
    let conn = Connection::open_with_flags(
        db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let stats = (|| -> Result<ProjectStats, AppError> {
        conn.busy_timeout(Duration::ZERO)?;
        let version: i32 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version != CURRENT_SCHEMA_VERSION {
            return Err(AppError::Database(format!(
                "{} has schema version {version}; this build requires {CURRENT_SCHEMA_VERSION}. Run tasks migrate --project {project_id}.",
                db_path.display()
            )));
        }
        let embedded: Option<String> = conn
            .query_row("SELECT project_id FROM project LIMIT 1", [], |row| {
                row.get(0)
            })
            .optional()?;
        match embedded {
            Some(value) if value == project_id => {}
            Some(value) => {
                return Err(AppError::Database(format!(
                    "{} stores project {value}, not {project_id}; fix the registry binding",
                    db_path.display()
                )))
            }
            None => {
                return Err(AppError::Database(format!(
                    "{} has no row in its project table; the database is incomplete. Restore it from a backup, or run tasks init --root <dir> to create a new one",
                    db_path.display()
                )))
            }
        }
        let (total, open, blocked, done, cancelled, started_ms, last_write_ms) = conn.query_row(
            "SELECT COUNT(*),
                    COALESCE(SUM(CASE WHEN status NOT IN ('done','cancelled') THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN status = 'blocked' THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN status = 'done' THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0),
                    MIN(created_ms),
                    MAX(updated_ms)
             FROM tasks",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)? as u64,
                    row.get::<_, i64>(1)? as u64,
                    row.get::<_, i64>(2)? as u64,
                    row.get::<_, i64>(3)? as u64,
                    row.get::<_, i64>(4)? as u64,
                    row.get::<_, Option<i64>>(5)?,
                    row.get::<_, Option<i64>>(6)?,
                ))
            },
        )?;
        let remaining = total.saturating_sub(cancelled);
        let progress_percent = if remaining == 0 {
            None
        } else {
            Some(100.0 * done as f64 / remaining as f64)
        };
        Ok(ProjectStats {
            total,
            open,
            blocked,
            done,
            cancelled,
            started_ms,
            last_write_ms,
            progress_percent,
        })
    })();
    drop(conn);
    stats
}

fn matches_project_query(record: &ProjectRecord, query: &ProjectQuery) -> bool {
    if !query.query.is_empty() {
        let needle = query.query.to_ascii_lowercase();
        let matched = std::iter::once(record.name.as_str())
            .chain(std::iter::once(record.project_id.as_str()))
            .chain(record.roots.iter().map(String::as_str))
            .any(|haystack| contains_ascii_insensitive(haystack, &needle));
        if !matched {
            return false;
        }
    }
    let available = record.availability == Availability::Available;
    let stats = record.stats.as_ref();
    match query.state {
        ProjectState::All => true,
        ProjectState::Unavailable => !available,
        ProjectState::HasOpen => available && stats.is_some_and(|stats| stats.open > 0),
        ProjectState::HasBlocked => available && stats.is_some_and(|stats| stats.blocked > 0),
        ProjectState::Complete => {
            available && stats.is_some_and(|stats| stats.total > stats.cancelled && stats.open == 0)
        }
        ProjectState::Empty => available && stats.is_some_and(|stats| stats.total == 0),
    }
}

fn compare_optional<T: Ord>(
    left: Option<T>,
    right: Option<T>,
    descending: bool,
) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    match (left, right) {
        (Some(left), Some(right)) => {
            if descending {
                right.cmp(&left)
            } else {
                left.cmp(&right)
            }
        }
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

fn compare_optional_f64(
    left: Option<f64>,
    right: Option<f64>,
    descending: bool,
) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    match (left, right) {
        (Some(left), Some(right)) => {
            if descending {
                right.total_cmp(&left)
            } else {
                left.total_cmp(&right)
            }
        }
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

fn sort_projects(records: &mut [ProjectRecord], query: &ProjectQuery) {
    let descending = query.direction.descending();
    fn stats(record: &ProjectRecord) -> Option<&ProjectStats> {
        record.stats.as_ref()
    }
    records.sort_by(|left, right| {
        let ordering = match query.sort {
            ProjectSort::Name => {
                let ordering = compare_ascii_text(&left.name, &right.name);
                if descending {
                    ordering.reverse()
                } else {
                    ordering
                }
            }
            ProjectSort::Open => compare_optional(
                stats(left).map(|stats| stats.open),
                stats(right).map(|stats| stats.open),
                descending,
            ),
            ProjectSort::Total => compare_optional(
                stats(left).map(|stats| stats.total),
                stats(right).map(|stats| stats.total),
                descending,
            ),
            ProjectSort::Blocked => compare_optional(
                stats(left).map(|stats| stats.blocked),
                stats(right).map(|stats| stats.blocked),
                descending,
            ),
            ProjectSort::Started => compare_optional(
                stats(left).and_then(|stats| stats.started_ms),
                stats(right).and_then(|stats| stats.started_ms),
                descending,
            ),
            ProjectSort::LastWrite => compare_optional(
                stats(left).and_then(|stats| stats.last_write_ms),
                stats(right).and_then(|stats| stats.last_write_ms),
                descending,
            ),
            ProjectSort::Progress => compare_optional_f64(
                stats(left).and_then(|stats| stats.progress_percent),
                stats(right).and_then(|stats| stats.progress_percent),
                descending,
            ),
        };
        ordering.then_with(|| left.project_id.cmp(&right.project_id))
    });
}

/// Hash the identity, availability, error code and statistics of every catalog
/// record; sample times and variable error prose stay out.
fn catalog_hash(records: &[ProjectRecord]) -> String {
    let mut hasher = Sha256::new();
    for record in records {
        let entry = serde_json::json!({
            "project_id": record.project_id,
            "name": record.name,
            "roots": record.roots,
            "availability": record.availability.as_str(),
            "error_code": record.error.as_ref().map(|error| error.code.as_str()),
            "stats": record.stats.as_ref().map(|stats| serde_json::json!({
                "total": stats.total,
                "open": stats.open,
                "blocked": stats.blocked,
                "done": stats.done,
                "cancelled": stats.cancelled,
                "started_ms": stats.started_ms,
                "last_write_ms": stats.last_write_ms,
                "progress_percent": stats.progress_percent,
            })),
        });
        hasher.update(entry.to_string().as_bytes());
        hasher.update(b"\n");
    }
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

// ---------------------------------------------------------------------------
// viewer tasks
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Scope {
    Open,
    All,
}

impl Scope {
    const VALUES: [&'static str; 2] = ["open", "all"];

    fn parse(value: &str) -> Option<Self> {
        match value {
            "open" => Some(Self::Open),
            "all" => Some(Self::All),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::All => "all",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Readiness {
    Any,
    Runnable,
    Waiting,
}

impl Readiness {
    const VALUES: [&'static str; 3] = ["any", "runnable", "waiting"];

    fn parse(value: &str) -> Option<Self> {
        match value {
            "any" => Some(Self::Any),
            "runnable" => Some(Self::Runnable),
            "waiting" => Some(Self::Waiting),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Any => "any",
            Self::Runnable => "runnable",
            Self::Waiting => "waiting",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TaskSort {
    Id,
    Priority,
    Status,
    Title,
    Created,
    Updated,
}

impl TaskSort {
    const VALUES: [&'static str; 6] = ["id", "priority", "status", "title", "created", "updated"];

    fn parse(value: &str) -> Option<Self> {
        match value {
            "id" => Some(Self::Id),
            "priority" => Some(Self::Priority),
            "status" => Some(Self::Status),
            "title" => Some(Self::Title),
            "created" => Some(Self::Created),
            "updated" => Some(Self::Updated),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Id => "id",
            Self::Priority => "priority",
            Self::Status => "status",
            Self::Title => "title",
            Self::Created => "created",
            Self::Updated => "updated",
        }
    }
}

struct TaskQuery {
    query: String,
    scope: Scope,
    statuses: Vec<TaskStatus>,
    priorities: Vec<Priority>,
    labels: Vec<String>,
    readiness: Readiness,
    sort: TaskSort,
    direction: Direction,
    offset: u64,
    limit: u64,
    snapshot: Option<String>,
}

fn task_request(value: Value) -> Result<TaskQuery, AppError> {
    let map = request_object(value)?;
    reject_unknown_keys(
        &map,
        &[
            "query",
            "scope",
            "statuses",
            "priorities",
            "labels",
            "readiness",
            "sort",
            "direction",
            "offset",
            "limit",
            "snapshot",
        ],
    )?;
    let mut statuses = enum_array_field(&map, "statuses", &STATUS_VALUES, parse_canonical_status)?;
    statuses.sort_by_key(status_rank);
    statuses.dedup();
    let mut priorities = enum_array_field(
        &map,
        "priorities",
        &PRIORITY_VALUES,
        parse_canonical_priority,
    )?;
    priorities.sort_by_key(|priority| priority_rank(*priority));
    priorities.dedup();
    Ok(TaskQuery {
        query: optional_string(&map, "query")?
            .unwrap_or_default()
            .trim()
            .to_string(),
        scope: enum_field(&map, "scope", &Scope::VALUES, Scope::Open, Scope::parse)?,
        statuses,
        priorities,
        labels: labels::normalize(optional_string_array(&map, "labels")?.unwrap_or_default())?,
        readiness: enum_field(
            &map,
            "readiness",
            &Readiness::VALUES,
            Readiness::Any,
            Readiness::parse,
        )?,
        sort: enum_field(
            &map,
            "sort",
            &TaskSort::VALUES,
            TaskSort::Priority,
            TaskSort::parse,
        )?,
        direction: enum_field(
            &map,
            "direction",
            &Direction::VALUES,
            Direction::Asc,
            Direction::parse,
        )?,
        offset: page_offset(optional_u64(&map, "offset")?.unwrap_or(0))?,
        limit: page_limit(optional_u64(&map, "limit")?.unwrap_or(DEFAULT_LIMIT))?,
        snapshot: nullable_string(&map, "snapshot")?,
    })
}

fn task_params(query: &TaskQuery) -> Value {
    serde_json::json!({
        "query": query.query,
        "scope": query.scope.as_str(),
        "statuses": query.statuses,
        "priorities": query.priorities,
        "labels": query.labels,
        "readiness": query.readiness.as_str(),
        "sort": query.sort.as_str(),
        "direction": query.direction.as_str(),
    })
}

fn tasks_token(
    project_id: &str,
    file_identity: &str,
    max_event_id: i64,
    total_count: u64,
    query: &TaskQuery,
) -> String {
    encode_token(&serde_json::json!({
        "v": PROTOCOL_VERSION,
        "kind": "tasks",
        "project": project_id,
        "file": file_identity,
        "event": max_event_id,
        "count": total_count,
        "params": task_params(query),
    }))
}

/// Validate everything except the bound count, which a valid page reuses.
fn validate_task_token(
    token: &str,
    project_id: &str,
    file_identity: &str,
    max_event_id: i64,
    query: &TaskQuery,
) -> Result<u64, AppError> {
    let decoded = decode_token(token)
        .ok_or_else(|| stale_snapshot("the snapshot token is not a valid v1 token"))?;
    let expected = serde_json::json!({
        "v": PROTOCOL_VERSION,
        "kind": "tasks",
        "project": project_id,
        "file": file_identity,
        "event": max_event_id,
        "params": task_params(query),
    });
    token_matches(&decoded, &expected)
        .ok_or_else(|| stale_snapshot("the task list changed since this page was requested"))
}

/// Page through one project's tasks in a single read transaction.
pub fn tasks(
    data_root: &Path,
    project: &str,
    request_file: &Path,
) -> Result<ViewerTasksPayload, AppError> {
    let request = parse_request(&read_request_bytes(request_file)?)?;
    let query = task_request(request)?;
    let project_id = canonical_project(project)?;
    let data_root = validate_storage_root(data_root)?;
    let db_path = data_root_project_path(&data_root, &project_id);
    validate_storage_path(&db_path)?;
    let identity_before = file_identity(&db_path);
    let store = Store::open_readonly(&data_root, &project_id)?;
    let tx = store.conn.unchecked_transaction()?;
    let max_event_id: i64 =
        tx.query_row("SELECT COALESCE(MAX(event_id), 0) FROM events", [], |row| {
            row.get(0)
        })?;
    let (total_count, snapshot) = match query.snapshot.as_deref() {
        Some(token) => {
            let total_count =
                validate_task_token(token, &project_id, &identity_before, max_event_id, &query)?;
            (total_count, token.to_string())
        }
        None => {
            let total_count = count_tasks(&tx, &query)?;
            let snapshot = tasks_token(
                &project_id,
                &identity_before,
                max_event_id,
                total_count,
                &query,
            );
            (total_count, snapshot)
        }
    };
    let items = select_task_page(&tx, &query)?;
    tx.commit()?;
    if file_identity(&db_path) != identity_before {
        return Err(stale_snapshot(
            "the project database was replaced while the page was being read",
        ));
    }
    let has_more = (query.offset + items.len() as u64) < total_count;
    let next_offset = has_more.then_some(query.offset + items.len() as u64);
    Ok(ViewerTasksPayload {
        protocol_version: PROTOCOL_VERSION,
        items,
        total_count,
        offset: query.offset,
        limit: query.limit,
        has_more,
        next_offset,
        snapshot,
    })
}

/// The WHERE clause and its bound values for one task query. The only
/// interpolated text is this module's own allowlisted SQL.
fn task_filter_sql(query: &TaskQuery) -> (String, Vec<SqlValue>) {
    let mut conditions: Vec<String> = Vec::new();
    let mut params: Vec<SqlValue> = Vec::new();
    if query.scope == Scope::Open {
        conditions.push("t.status NOT IN ('done','cancelled')".to_string());
    }
    if !query.statuses.is_empty() {
        conditions.push(format!(
            "t.status IN ({})",
            placeholders(query.statuses.len())
        ));
        for status in &query.statuses {
            params.push(SqlValue::Text(status.to_string()));
        }
    }
    if !query.priorities.is_empty() {
        conditions.push(format!(
            "t.priority IN ({})",
            placeholders(query.priorities.len())
        ));
        for priority in &query.priorities {
            params.push(SqlValue::Text(priority.to_string()));
        }
    }
    for label in &query.labels {
        conditions.push(
            "EXISTS(SELECT 1 FROM task_labels l WHERE l.task_id=t.id AND l.label=?)".to_string(),
        );
        params.push(SqlValue::Text(label.clone()));
    }
    match query.readiness {
        Readiness::Any => {}
        // The authoritative readiness predicate from store::select_tasks; the
        // store owns the text so both callers cannot drift apart.
        Readiness::Runnable => {
            conditions.push(crate::store::RUNNABLE_PREDICATE.to_string())
        }
        Readiness::Waiting => conditions.push(
            "t.status NOT IN ('done','cancelled')
             AND EXISTS(SELECT 1 FROM dependencies d JOIN tasks p ON p.id=d.depends_on_id WHERE d.task_id=t.id AND p.status NOT IN ('done','cancelled'))"
                .to_string(),
        ),
    }
    if !query.query.is_empty() {
        match parse_task_id(&query.query) {
            Ok(id) => {
                conditions.push("t.id = ?".to_string());
                params.push(SqlValue::Integer(id as i64));
            }
            Err(_) => {
                let pattern = format!(
                    "%{}%",
                    escape_like_literal(&query.query.to_ascii_lowercase())
                );
                conditions.push(
                    "(lower(t.title) LIKE ? ESCAPE '\\' OR lower(t.body) LIKE ? ESCAPE '\\')"
                        .to_string(),
                );
                params.push(SqlValue::Text(pattern.clone()));
                params.push(SqlValue::Text(pattern));
            }
        }
    }
    let where_sql = if conditions.is_empty() {
        "1=1".to_string()
    } else {
        conditions.join(" AND ")
    };
    (where_sql, params)
}

/// Allowlisted ORDER BY expressions. Every primary sort keeps the numeric task
/// ID ascending as its tie-break, except ID-only sorting which uses the
/// requested direction once.
fn task_order_by(sort: TaskSort, direction: Direction) -> String {
    let way = if direction.descending() {
        "DESC"
    } else {
        "ASC"
    };
    match sort {
        TaskSort::Id => format!("t.id {way}"),
        TaskSort::Priority => format!(
            "CASE t.priority WHEN 'P0' THEN 0 WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 WHEN 'P3' THEN 3 ELSE 4 END {way}, t.id ASC"
        ),
        TaskSort::Status => format!(
            "CASE t.status WHEN 'draft' THEN 0 WHEN 'todo' THEN 1 WHEN 'in-progress' THEN 2 WHEN 'blocked' THEN 3 WHEN 'done' THEN 4 WHEN 'cancelled' THEN 5 ELSE 6 END {way}, t.id ASC"
        ),
        TaskSort::Title => {
            format!("lower(t.title) {way}, t.title COLLATE BINARY {way}, t.id ASC")
        }
        TaskSort::Created => format!("t.created_ms {way}, t.id ASC"),
        TaskSort::Updated => format!("t.updated_ms {way}, t.id ASC"),
    }
}

fn count_tasks(conn: &Connection, query: &TaskQuery) -> Result<u64, AppError> {
    let (where_sql, params) = task_filter_sql(query);
    let sql = format!("SELECT COUNT(*) FROM tasks t WHERE {where_sql}");
    let count: i64 = conn.query_row(&sql, rusqlite::params_from_iter(params.iter()), |row| {
        row.get(0)
    })?;
    Ok(count as u64)
}

fn select_task_page(conn: &Connection, query: &TaskQuery) -> Result<Vec<TaskItem>, AppError> {
    let (where_sql, mut params) = task_filter_sql(query);
    let order = task_order_by(query.sort, query.direction);
    let sql = format!(
        "SELECT t.id, t.title, t.status, t.priority, t.version, t.created_ms, t.updated_ms
         FROM tasks t WHERE {where_sql} ORDER BY {order} LIMIT ? OFFSET ?"
    );
    params.push(SqlValue::Integer(query.limit as i64));
    params.push(SqlValue::Integer(query.offset as i64));
    let mut statement = conn.prepare(&sql)?;
    let mut rows = statement.query(rusqlite::params_from_iter(params.iter()))?;
    let mut items = Vec::new();
    while let Some(row) = rows.next()? {
        items.push(read_task_item(row)?);
    }
    drop(rows);
    drop(statement);
    populate_task_items(conn, &mut items)?;
    Ok(items)
}

fn read_task_item(row: &rusqlite::Row<'_>) -> Result<TaskItem, AppError> {
    let id = row.get::<_, i64>(0)? as u64;
    let status_text: String = row.get(2)?;
    let priority_text: String = row.get(3)?;
    let created_ms = row
        .get::<_, Option<i64>>(5)?
        .ok_or_else(|| corrupt_timestamp(id, "created_ms"))?;
    let updated_ms = row
        .get::<_, Option<i64>>(6)?
        .ok_or_else(|| corrupt_timestamp(id, "updated_ms"))?;
    Ok(TaskItem {
        id,
        title: row.get(1)?,
        status: parse_canonical_status(&status_text)
            .ok_or_else(|| corrupt_status(id, &status_text))?,
        priority: parse_canonical_priority(&priority_text)
            .ok_or_else(|| corrupt_priority(id, &priority_text))?,
        version: row.get::<_, i64>(4)? as u64,
        labels: Vec::new(),
        dependency_count: 0,
        waiting_dependency_count: 0,
        created_ms,
        updated_ms,
    })
}

fn corrupt_timestamp(id: u64, column: &str) -> AppError {
    AppError::Database(format!(
        "task {} has a null {column}; the database is corrupt. Restore it from a backup, then run tasks doctor",
        render_task_id(id)
    ))
}

fn corrupt_status(id: u64, value: &str) -> AppError {
    AppError::Database(format!(
        "task {} has the unsupported status '{value}'; the database is corrupt. Restore it from a backup, then run tasks doctor",
        render_task_id(id)
    ))
}

fn corrupt_priority(id: u64, value: &str) -> AppError {
    AppError::Database(format!(
        "task {} has the unsupported priority '{value}'; the database is corrupt. Restore it from a backup, then run tasks doctor",
        render_task_id(id)
    ))
}

/// Fetch labels and dependency counts for the selected page only.
fn populate_task_items(conn: &Connection, items: &mut [TaskItem]) -> Result<(), AppError> {
    let ids = items.iter().map(|item| item.id).collect::<Vec<_>>();
    let mut labels_by_id = labels::read_many(conn, &ids)?;
    let mut counts = dependency_counts(conn, &ids)?;
    for item in items {
        item.labels = labels_by_id.remove(&item.id).unwrap_or_default();
        if let Some((total, waiting)) = counts.remove(&item.id) {
            item.dependency_count = total;
            item.waiting_dependency_count = waiting;
        }
    }
    Ok(())
}

fn dependency_counts(conn: &Connection, ids: &[u64]) -> Result<HashMap<u64, (u64, u64)>, AppError> {
    let mut out = HashMap::new();
    if ids.is_empty() {
        return Ok(out);
    }
    let sql = format!(
        "SELECT d.task_id, COUNT(*),
                COALESCE(SUM(CASE WHEN p.status NOT IN ('done','cancelled') THEN 1 ELSE 0 END), 0)
         FROM dependencies d JOIN tasks p ON p.id = d.depends_on_id
         WHERE d.task_id IN ({})
         GROUP BY d.task_id",
        placeholders(ids.len())
    );
    let mut statement = conn.prepare(&sql)?;
    let values = ids.iter().map(|id| *id as i64);
    let mut rows = statement.query(rusqlite::params_from_iter(values))?;
    while let Some(row) = rows.next()? {
        out.insert(
            row.get::<_, i64>(0)? as u64,
            (row.get::<_, i64>(1)? as u64, row.get::<_, i64>(2)? as u64),
        );
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// viewer show
// ---------------------------------------------------------------------------

/// `viewer show T-ID` returns every existing `TaskDetail` field plus both
/// timestamps from one deferred read transaction.
pub fn show(data_root: &Path, project: &str, raw_id: &str) -> Result<ViewerShowPayload, AppError> {
    let id = parse_task_id(raw_id).map_err(AppError::Validation)?;
    let project_id = canonical_project(project)?;
    let data_root = validate_storage_root(data_root)?;
    let db_path = data_root_project_path(&data_root, &project_id);
    validate_storage_path(&db_path)?;
    let identity_before = file_identity(&db_path);
    let store = Store::open_readonly(&data_root, &project_id)?;
    let tx = store.conn.unchecked_transaction()?;
    let (task, created_ms, updated_ms) = read_task_detail(&tx, &project_id, id)?;
    tx.commit()?;
    if file_identity(&db_path) != identity_before {
        return Err(stale_snapshot(
            "the project database was replaced while the task was being read",
        ));
    }
    Ok(ViewerShowPayload {
        protocol_version: PROTOCOL_VERSION,
        task,
        created_ms,
        updated_ms,
    })
}

fn read_task_detail(
    conn: &Connection,
    project_id: &str,
    id: u64,
) -> Result<(TaskDetail, i64, i64), AppError> {
    let row = conn
        .query_row(
            "SELECT status, priority, version, title, body, created_ms, updated_ms
             FROM tasks WHERE id = ?1",
            [id as i64],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<i64>>(5)?,
                    row.get::<_, Option<i64>>(6)?,
                ))
            },
        )
        .optional()?;
    let (status, priority, version, title, body, created_ms, updated_ms) = row.ok_or_else(|| {
        AppError::NotFound(format!(
            "task {} not found in project {project_id}; run tasks list to see the IDs in this project",
            render_task_id(id)
        ))
    })?;
    let created_ms = created_ms.ok_or_else(|| corrupt_timestamp(id, "created_ms"))?;
    let updated_ms = updated_ms.ok_or_else(|| corrupt_timestamp(id, "updated_ms"))?;
    let (rule_version, rules) = conn
        .query_row(
            "SELECT rules_version, rules_markdown FROM project LIMIT 1",
            [],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?
        .ok_or_else(|| {
            AppError::Database(format!(
                "project {project_id} has no row in its project table; the database is incomplete. Restore it from a backup, or run tasks init --root <dir> to create a new one"
            ))
        })?;
    Ok((
        TaskDetail {
            priority: parse_canonical_priority(&priority)
                .ok_or_else(|| corrupt_priority(id, &priority))?,
            id,
            status: parse_canonical_status(&status).ok_or_else(|| corrupt_status(id, &status))?,
            version: version as u64,
            title,
            body,
            deps: task_dependency_ids(conn, id)?,
            labels: labels::read(conn, id)?,
            dependency_summaries: task_dependency_summaries(conn, id)?,
            rule_version: rule_version as u64,
            rules,
        },
        created_ms,
        updated_ms,
    ))
}

fn task_dependency_ids(conn: &Connection, id: u64) -> Result<Vec<u64>, AppError> {
    let mut statement = conn.prepare(
        "SELECT depends_on_id FROM dependencies WHERE task_id = ?1 ORDER BY depends_on_id ASC",
    )?;
    let rows = statement.query_map([id as i64], |row| row.get::<_, i64>(0))?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row? as u64);
    }
    Ok(out)
}

fn task_dependency_summaries(
    conn: &Connection,
    id: u64,
) -> Result<Vec<DependencySummary>, AppError> {
    let mut statement = conn.prepare(
        "SELECT tasks.id, tasks.status, tasks.version, tasks.title
         FROM dependencies
         JOIN tasks ON tasks.id = dependencies.depends_on_id
         WHERE dependencies.task_id = ?1
         ORDER BY tasks.id ASC",
    )?;
    let rows = statement.query_map([id as i64], |row| {
        Ok((
            row.get::<_, i64>(0)? as u64,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)? as u64,
            row.get::<_, String>(3)?,
        ))
    })?;
    let mut summaries = Vec::new();
    for row in rows {
        let (dep_id, status, version, title) = row?;
        summaries.push(DependencySummary {
            id: dep_id,
            status: parse_canonical_status(&status)
                .ok_or_else(|| corrupt_status(dep_id, &status))?,
            version,
            title,
        });
    }
    Ok(summaries)
}

// ---------------------------------------------------------------------------
// viewer update
// ---------------------------------------------------------------------------

/// `viewer update` applies one version-checked change set over the six editable
/// fields through the existing `Store::update_task` transaction.
pub fn update(
    data_root: &Path,
    project: &str,
    request_file: &Path,
) -> Result<ViewerUpdatePayload, AppError> {
    let request = update_request(parse_request(&read_request_bytes(request_file)?)?)?;
    let project_id = canonical_project(project)?;
    let data_root = validate_storage_root(data_root)?;
    let mut store = Store::open_rw(&data_root, &project_id)?;
    let (id, status, version, event_id) =
        store.update_task(request.id, request.expect_version, request.changes)?;
    Ok(ViewerUpdatePayload {
        protocol_version: PROTOCOL_VERSION,
        id,
        status: status.to_string(),
        version,
        event_id,
    })
}

struct UpdateRequest {
    id: u64,
    expect_version: u64,
    changes: TaskUpdate,
}

fn update_request(value: Value) -> Result<UpdateRequest, AppError> {
    let map = request_object(value)?;
    reject_unknown_keys(&map, &["id", "expect_version", "changes"])?;
    let id = required_positive_u64(&map, "id")?;
    let expect_version = required_positive_u64(&map, "expect_version")?;
    let changes_value = map.get("changes").cloned().ok_or_else(|| {
        AppError::Usage(
            "the viewer update request is missing the required field 'changes'; pass an object listing the fields to change"
                .to_string(),
        )
    })?;
    let changes_map = request_object(changes_value)?;
    reject_unknown_keys(&changes_map, &EDITABLE_FIELD_NAMES)?;
    let changes = TaskUpdate {
        title: optional_string(&changes_map, "title")?,
        body: optional_string(&changes_map, "body")?,
        status: optional_enum_field(
            &changes_map,
            "status",
            &STATUS_VALUES,
            parse_canonical_status,
        )?,
        priority: optional_enum_field(
            &changes_map,
            "priority",
            &PRIORITY_VALUES,
            parse_canonical_priority,
        )?,
        labels: optional_string_array(&changes_map, "labels")?
            .map(labels::normalize)
            .transpose()?,
        deps: optional_u64_array(&changes_map, "deps")?,
        clear_deps: false,
    };
    if changes.title.is_none()
        && changes.body.is_none()
        && changes.status.is_none()
        && changes.priority.is_none()
        && changes.labels.is_none()
        && changes.deps.is_none()
    {
        return Err(AppError::Usage(format!(
            "viewer update {}: the changes object is empty; pass at least one of {}",
            render_task_id(id),
            EDITABLE_FIELD_NAMES.join(", ")
        )));
    }
    Ok(UpdateRequest {
        id,
        expect_version,
        changes,
    })
}
