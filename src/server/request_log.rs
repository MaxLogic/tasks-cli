//! Fixed metadata only. Raw targets, headers and bodies never enter this type.
use axum::http::{Method, Uri};
use serde::Serialize;
use std::{
    io::{self, Write},
    sync::{Arc, Mutex},
    time::Instant,
};
use uuid::Uuid;

#[derive(Clone)]
pub(super) struct RequestLogs(Arc<Mutex<Box<dyn Write + Send>>>);
impl RequestLogs {
    pub(super) fn stderr() -> Self {
        Self(Arc::new(Mutex::new(Box::new(io::stderr()))))
    }
    pub(super) fn file(file: std::fs::File) -> Self {
        Self(Arc::new(Mutex::new(Box::new(file))))
    }
    fn emit(&self, record: &Record) {
        let result = (|| -> Result<(), ()> {
            let mut bytes = serde_json::to_vec(record).map_err(|_| ())?;
            bytes.push(b'\n');
            let mut writer = self.0.lock().map_err(|_| ())?;
            writer.write_all(&bytes).map_err(|_| ())?;
            writer.flush().map_err(|_| ())
        })();
        if result.is_err() {
            eprintln!("server request log write failed");
        }
    }
}
#[derive(Clone, Serialize)]
struct Record {
    request_id: Uuid,
    actor_id: Option<String>,
    project_id: Option<Uuid>,
    operation: &'static str,
    duration_ms: u64,
    #[serde(flatten)]
    timings: super::timing::Timings,
    outcome: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    item_count: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    stored_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    declared_original_bytes: Option<u64>,
}
pub(super) struct RequestLog {
    sink: RequestLogs,
    started: Instant,
    record: Record,
    emit: bool,
}
impl RequestLog {
    pub(super) fn new(sink: RequestLogs, method: &Method, uri: &Uri) -> Self {
        let (project_id, operation) = operation(method, uri);
        Self {
            sink,
            emit: true,
            started: Instant::now(),
            record: Record {
                request_id: Uuid::new_v4(),
                actor_id: None,
                project_id,
                operation,
                duration_ms: 0,
                timings: Default::default(),
                outcome: "cancelled".into(),
                item_count: None,
                stored_bytes: None,
                declared_original_bytes: None,
            },
        }
    }
    pub(super) fn authenticated(
        &mut self,
        authentication: &super::signatures::AuthenticatedRequest,
    ) {
        self.record.actor_id = Some(authentication.registration.actor_id.clone());
        if let Some(id) = authentication.idempotency_key {
            self.record.request_id = id;
        }
    }
    pub(super) fn completed(&mut self, status: u16) {
        self.record.outcome = format!("http_{status}");
    }
    pub(super) fn timings(&mut self, timings: super::timing::Timings) {
        self.record.timings.add(timings);
    }
    pub(super) fn encoded_since(&mut self, started: Instant) {
        self.record.timings.encode_ms += started.elapsed().as_secs_f64() * 1000.0;
    }
    pub(super) fn attachment_sizes(&mut self, count: u64, stored: u64, original: u64) {
        self.record.item_count = Some(count);
        self.record.stored_bytes = Some(stored);
        self.record.declared_original_bytes = Some(original);
    }
    /// Inspect only numeric fields in server-produced output, including receipts.
    pub(super) fn attachment_output(&mut self, reply: &serde_json::Value) {
        let data = &reply["output"]["data"];
        let (operation, field) = match data["command"].as_str() {
            Some("attachment_add") => ("attachment_add", "attachments"),
            Some("attachment_list") => ("attachment_list", "items"),
            Some("attachment_detach") => ("attachment_detach", "detached"),
            _ => return,
        };
        let Some(items) = data[field].as_array() else {
            return;
        };
        let sizes = items
            .iter()
            .try_fold((0u64, 0u64), |(stored, original), item| {
                if field == "detached" {
                    // Detach sends identifiers and declares no content bytes.
                    Some((stored, original))
                } else {
                    Some((
                        stored.checked_add(item["stored_size"].as_u64()?)?,
                        original.checked_add(item["original_size"].as_u64()?)?,
                    ))
                }
            });
        if let Some((stored, original)) = sizes {
            self.record.operation = operation;
            self.attachment_sizes(items.len() as u64, stored, original);
        }
    }
    pub(super) fn attachment_finished(&mut self, success: bool) {
        self.record.outcome = if success {
            "attachment_complete"
        } else {
            "attachment_interrupted"
        }
        .into();
    }
    pub(super) fn handoff(&mut self) -> Self {
        self.emit = false;
        Self {
            sink: self.sink.clone(),
            started: self.started,
            record: self.record.clone(),
            emit: true,
        }
    }
    pub(super) fn export_finished(&mut self, success: bool) {
        self.record.outcome = if success {
            "export_complete"
        } else {
            "export_interrupted"
        }
        .into();
    }
}
impl Drop for RequestLog {
    fn drop(&mut self) {
        if !self.emit {
            return;
        }
        self.record.duration_ms =
            u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX);
        self.sink.emit(&self.record);
    }
}
fn operation(method: &Method, uri: &Uri) -> (Option<Uuid>, &'static str) {
    let path = uri.path();
    if path == "/v1/info" && method == Method::GET {
        return (None, "info");
    }
    if path == "/v1/viewer/info" && method == Method::GET {
        return (None, "viewer_info");
    }
    if path == "/v1/viewer/projects" && method == Method::POST {
        return (None, "viewer_projects");
    }
    if path == "/v1/projects" {
        return (
            None,
            if method == Method::GET {
                "projects"
            } else if method == Method::POST {
                "project_create"
            } else {
                "unknown"
            },
        );
    }
    let mut segments = path.split('/');
    if segments.next() != Some("")
        || segments.next() != Some("v1")
        || segments.next() != Some("projects")
    {
        return (None, "unknown");
    }
    let project = segments
        .next()
        .and_then(|value| Uuid::parse_str(value).ok());
    if project.is_none() {
        return (None, "unknown");
    }
    let rest = segments.clone().collect::<Vec<_>>();
    match rest.as_slice() {
        ["tasks", id, "attachments"] if id.parse::<u64>().is_ok() && *method == Method::POST => {
            return (project, "attachment_add")
        }
        ["tasks", id, "attachments", "detach"]
            if id.parse::<u64>().is_ok() && *method == Method::POST =>
        {
            return (project, "attachment_detach")
        }
        ["tasks", id, "attachments", attachment]
            if id.parse::<u64>().is_ok()
                && attachment.parse::<u64>().is_ok()
                && *method == Method::GET =>
        {
            return (project, "attachment_get")
        }
        _ => (),
    }
    let operation = match (segments.next(), segments.next(), segments.next()) {
        (Some("query"), None, None) if method == Method::POST => "project_query",
        (Some("tasks"), None, None) if method == Method::POST => "task_create",
        (Some("tasks"), Some(id), None) if id.parse::<u64>().is_ok() && method == Method::PATCH => {
            "task_update"
        }
        (Some("rules"), None, None) if method == Method::PUT => "rules_update",
        (Some("key"), None, None) if method == Method::PUT => "key_update",
        (Some("viewer"), Some("update"), None) if method == Method::PATCH => "viewer_update",
        (Some("archive"), None, None) if method == Method::PUT => "viewer_archive",
        (Some("export"), None, None) if method == Method::GET => "export",
        _ => "unknown",
    };
    (project, operation)
}
