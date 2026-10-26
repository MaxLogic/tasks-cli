//! SQL-only attachment operations. The caller owns the transaction and commit.
use super::{
    envelope::{self, ValidatedEnvelope},
    name, Limits,
};
use crate::{
    error::AppError,
    model::{
        AddedAttachment, AttachResult, AttachmentRecord, AttachmentSummary, AttachmentUsage,
        DetachResult, TaskStatus,
    },
};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

#[derive(Debug)]
pub struct PreparedItem {
    pub name: String,
    pub envelope: ValidatedEnvelope,
}

/// A validated view into an immutable, digest-verified transport body. The bytes
/// remain borrowed through COMMIT; only small, recomputed metadata is owned.
pub(crate) struct BorrowedPreparedItem<'a> {
    name: String,
    bytes: &'a [u8],
    metadata: envelope::Metadata,
}

impl<'a> From<&'a PreparedItem> for BorrowedPreparedItem<'a> {
    fn from(item: &'a PreparedItem) -> Self {
        Self {
            name: item.name.clone(),
            bytes: item.envelope.bytes(),
            metadata: item.envelope.metadata().clone(),
        }
    }
}

#[cfg(feature = "server")]
pub(crate) fn prepare_borrowed<'a>(
    items: Vec<(String, &'a [u8])>,
    limits: &Limits,
) -> Result<Vec<BorrowedPreparedItem<'a>>, AppError> {
    // Complete batch admission must precede the first decoder invocation.
    preflight(items.iter().map(|(_, bytes)| *bytes), limits)?;
    for (display_name, _) in &items {
        name::validate(display_name, limits)?;
    }
    items
        .into_iter()
        .map(|(name, bytes)| {
            #[cfg(feature = "test-hooks")]
            if let Some(log) = std::env::var_os("TASKS_TEST_DECODE_LOG") {
                use std::io::Write;
                writeln!(
                    std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(log)?,
                    "decode"
                )?;
            }
            let metadata = envelope::decode_to(bytes, &name, std::io::sink(), limits)?;
            Ok(BorrowedPreparedItem {
                name,
                bytes,
                metadata,
            })
        })
        .collect()
}

pub fn create_schema(conn: &Connection) -> Result<(), AppError> {
    conn.execute_batch(include_str!("../attachment_schema.sql"))?;
    Ok(())
}

pub fn validate_schema(conn: &Connection) -> Result<(), AppError> {
    fn definitions(conn: &Connection) -> Result<Vec<(String, String)>, AppError> {
        let mut statement = conn.prepare("SELECT name,sql FROM sqlite_schema WHERE name IN ('attachment_blobs','task_attachments','idx_attachment_blobs_stored_size','idx_task_attachments_retained','idx_task_attachments_task','idx_task_attachments_blob','attachment_blobs_no_update','attachment_blobs_no_delete','task_attachments_no_delete','task_attachments_detach_once','attachment_blobs_no_replace','task_attachments_no_replace') ORDER BY name")?;
        let result = statement
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<Result<_, _>>()?;
        Ok(result)
    }
    let reference = Connection::open_in_memory()?;
    create_schema(&reference)?;
    if definitions(conn)? != definitions(&reference)? {
        return Err(AppError::Database(
            "attachment schema is damaged; restore a verified backup".into(),
        ));
    }
    Ok(())
}

fn quota_error(code: &'static str, message: String) -> AppError {
    AppError::Coded {
        code,
        exit: 2,
        message,
    }
}

/// Header-only batch admission, also usable before validation by transport callers.
/// Check count first and all declared sizes before any caller starts decoding.
pub fn preflight<'a>(
    bytes: impl IntoIterator<Item = &'a [u8]>,
    limits: &Limits,
) -> Result<(), AppError> {
    let bytes: Vec<_> = bytes.into_iter().collect();
    if bytes.len() > limits.batch_count as usize {
        return Err(quota_error(
            "attachment_batch_too_large",
            format!(
                "{} files; per-command limit is {} files",
                bytes.len(),
                limits.batch_count
            ),
        ));
    }
    let mut total = 0u64;
    for bytes in bytes {
        let header = envelope::parse_header(bytes)?;
        if header.payload_len > limits.payload_bytes {
            return Err(super::AttachmentError::TooLarge {
                measured: header.payload_len,
                limit: limits.payload_bytes,
            }
            .into());
        }
        if header.original_size > limits.original_bytes {
            return Err(super::AttachmentError::OriginalTooLarge {
                measured: header.original_size,
                limit: limits.original_bytes,
            }
            .into());
        }
        total = total.checked_add(header.original_size).ok_or_else(|| {
            quota_error(
                "attachment_batch_too_large",
                format!(
                    "original-byte sum exceeds u64; per-command limit is {} original bytes",
                    limits.batch_original_bytes
                ),
            )
        })?;
        if total > limits.batch_original_bytes {
            return Err(quota_error(
                "attachment_batch_too_large",
                format!(
                    "{total} original bytes; per-command limit is {} original bytes",
                    limits.batch_original_bytes
                ),
            ));
        }
    }
    Ok(())
}

/// External envelope bytes are admitted as one batch before any decode work.
/// Call outside a write transaction, then pass the validated result to Store::attach.
pub fn prepare_items(
    items: Vec<(String, Vec<u8>)>,
    limits: &Limits,
) -> Result<Vec<PreparedItem>, AppError> {
    preflight(items.iter().map(|(_, bytes)| bytes.as_slice()), limits)?;
    for (display_name, _) in &items {
        name::validate(display_name, limits)?;
    }
    items
        .into_iter()
        .map(|(name, bytes)| {
            #[cfg(feature = "test-hooks")]
            if let Some(log) = std::env::var_os("TASKS_TEST_DECODE_LOG") {
                use std::io::Write;
                writeln!(
                    std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(log)?,
                    "decode"
                )?;
            }
            Ok(PreparedItem {
                envelope: envelope::validate(bytes, &name, limits)?,
                name,
            })
        })
        .collect()
}

pub fn project_quota(limits: &Limits) -> Result<u64, AppError> {
    #[cfg(feature = "test-hooks")]
    if let Ok(raw) = std::env::var("TASKS_TEST_PROJECT_ATTACHMENT_QUOTA") {
        let quota: u64 = raw.parse().map_err(|_| {
            AppError::Usage("TASKS_TEST_PROJECT_ATTACHMENT_QUOTA must be a byte count".into())
        })?;
        return Ok(quota.min(limits.project_stored_bytes));
    }
    Ok(limits.project_stored_bytes)
}

pub fn usage(conn: &Connection, quota: u64) -> Result<AttachmentUsage, AppError> {
    let (attachment_blobs, attachment_stored_bytes) = conn.query_row("SELECT count(*),coalesce(sum(stored_size),0) FROM attachment_blobs INDEXED BY idx_attachment_blobs_stored_size", [], |r| Ok((r.get(0)?,r.get(1)?)))?;
    Ok(AttachmentUsage {
        attachment_blobs,
        attachment_stored_bytes,
        attachment_quota_bytes: quota,
    })
}

const METADATA: &str = "a.attachment_id,a.name,a.kind,a.media_type,b.original_size,b.stored_size,b.content_sha256,a.added_ms,a.detached_ms";
fn record(row: &rusqlite::Row<'_>) -> rusqlite::Result<AttachmentRecord> {
    let id = row.get(0)?;
    Ok(AttachmentRecord {
        attachment: AttachmentSummary {
            id,
            display_id: format!("A{id}"),
            name: row.get(1)?,
            kind: row.get(2)?,
            media_type: row.get(3)?,
            original_size: row.get(4)?,
            stored_size: row.get(5)?,
            sha256: row.get(6)?,
            added_ms: row.get(7)?,
        },
        detached_ms: row.get(8)?,
    })
}

/// Bounded caller-selected task IDs; metadata only, never envelope overflow pages.
pub fn retained_attachments(
    conn: &Connection,
    ids: &[u64],
) -> Result<HashMap<u64, Vec<AttachmentSummary>>, AppError> {
    let mut result: HashMap<u64, Vec<AttachmentSummary>> = HashMap::new();
    for chunk in ids.chunks(100) {
        let placeholders = vec!["?"; chunk.len()].join(",");
        let sql = format!("SELECT {METADATA},a.task_id FROM task_attachments a JOIN attachment_blobs b USING(blob_id) WHERE a.task_id IN ({placeholders}) AND a.detached_event_id IS NULL ORDER BY a.task_id,a.attachment_id");
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(chunk), |r| {
            Ok((r.get::<_, u64>(9)?, record(r)?.attachment))
        })?;
        for row in rows {
            let (id, attachment) = row?;
            result.entry(id).or_default().push(attachment);
        }
    }
    Ok(result)
}

pub fn attachment_counts(conn: &Connection, ids: &[u64]) -> Result<HashMap<u64, u64>, AppError> {
    let mut result = HashMap::new();
    for chunk in ids.chunks(100) {
        let sql = format!("SELECT task_id,count(*) FROM task_attachments WHERE task_id IN ({}) AND detached_event_id IS NULL GROUP BY task_id",vec!["?";chunk.len()].join(","));
        let mut stmt = conn.prepare(&sql)?;
        for row in stmt.query_map(rusqlite::params_from_iter(chunk), |r| {
            Ok((r.get(0)?, r.get(1)?))
        })? {
            let (id, count) = row?;
            result.insert(id, count);
        }
    }
    Ok(result)
}

pub fn list(
    conn: &Connection,
    task: u64,
    all: bool,
    after: u64,
    limit: usize,
) -> Result<Vec<AttachmentRecord>, AppError> {
    let filter = if all {
        ""
    } else {
        "AND a.detached_event_id IS NULL"
    };
    let mut stmt = conn.prepare(&format!("SELECT {METADATA} FROM task_attachments a JOIN attachment_blobs b USING(blob_id) WHERE a.task_id=?1 AND a.attachment_id>?2 {filter} ORDER BY a.attachment_id LIMIT ?3"))?;
    let rows = stmt
        .query_map(params![task, after, limit as u64], record)?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}

pub fn read_envelope(
    conn: &Connection,
    task: u64,
    id: u64,
) -> Result<(AttachmentRecord, Vec<u8>), AppError> {
    conn.query_row(&format!("SELECT {METADATA},b.envelope FROM task_attachments a JOIN attachment_blobs b USING(blob_id) WHERE a.task_id=?1 AND a.attachment_id=?2"), params![task,id], |r| Ok((record(r)?,r.get(9)?))).optional()?.ok_or_else(||AppError::NotFound(format!("attachment A{id} does not belong to task {task}")))
}

fn task_state(conn: &Connection, id: u64, expected: u64) -> Result<TaskStatus, AppError> {
    let (status, version): (String, u64) = conn
        .query_row("SELECT status,version FROM tasks WHERE id=?1", [id], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .optional()?
        .ok_or_else(|| AppError::NotFound(format!("task {id}")))?;
    if expected != version {
        return Err(AppError::VersionConflict {
            expected,
            current: version,
        });
    }
    status.parse().map_err(AppError::Validation)
}

pub fn references(attachments: &[AttachmentSummary]) -> Value {
    Value::Array(attachments.iter().map(|a| json!({"id":a.id,"name":a.name,"kind":a.kind,"media_type":a.media_type,"original_size":a.original_size,"sha256":a.sha256})).collect())
}

fn write_event(
    conn: &Connection,
    id: u64,
    expected: u64,
    operation: &str,
    attachments: &[AttachmentSummary],
    now: i64,
    attribution: &str,
) -> Result<u64, AppError> {
    let (title, body, status, priority): (String, String, String, String) = conn.query_row(
        "SELECT title,body,status,priority FROM tasks WHERE id=?1",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
    )?;
    let mut deps_stmt = conn.prepare(
        "SELECT depends_on_id FROM dependencies WHERE task_id=?1 ORDER BY depends_on_id",
    )?;
    let deps = deps_stmt
        .query_map([id], |r| r.get::<_, u64>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    let snapshot = json!({"id":id,"title":title,"body":body,"status":status,"priority":priority,"version":expected+1,"labels":crate::labels::read(conn,id)?,"deps":deps,"attachments":references(attachments)});
    if conn.execute(
        "UPDATE tasks SET version=version+1,updated_ms=?1 WHERE id=?2 AND version=?3",
        params![now, id, expected],
    )? != 1
    {
        return Err(AppError::VersionConflict {
            expected,
            current: conn.query_row("SELECT version FROM tasks WHERE id=?1", [id], |r| r.get(0))?,
        });
    }
    conn.execute("INSERT INTO events(task_id,entity_type,operation,resulting_version,created_ms,snapshot_json,attribution_json) VALUES (?1,'task',?2,?3,?4,?5,?6)",params![id,operation,expected+1,now,snapshot.to_string(),attribution])?;
    Ok(conn.last_insert_rowid() as u64)
}

struct Resolved {
    blob_id: u64,
    stored_size: u64,
    deduplicated: bool,
}

pub(crate) fn attach(
    conn: &Connection,
    id: u64,
    expected: u64,
    items: &[BorrowedPreparedItem<'_>],
    limits: &Limits,
    now: i64,
    attribution: &str,
) -> Result<AttachResult, AppError> {
    let status = task_state(conn, id, expected)?;
    if items.is_empty() {
        return Err(AppError::Validation(
            "attach requires at least one item".into(),
        ));
    }
    let mut retained = retained_attachments(conn, &[id])?
        .remove(&id)
        .unwrap_or_default();
    let mut known: HashMap<String, (u64, u64)> = HashMap::new();
    let mut resolved = Vec::with_capacity(items.len());
    let mut next_blob: u64 = conn.query_row(
        "SELECT coalesce(max(blob_id),0) FROM attachment_blobs",
        [],
        |r| r.get(0),
    )?;
    let mut new_bytes = 0u64;
    for item in items {
        let hash = item.metadata.sha256.as_str();
        let existing = match known.get(hash) {
            Some(v) => Some(*v),
            None => conn
                .query_row(
                    "SELECT blob_id,stored_size FROM attachment_blobs WHERE content_sha256=?1",
                    [hash],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?,
        };
        let (blob_id, stored_size, deduplicated) = if let Some((blob, size)) = existing {
            (blob, size, true)
        } else {
            next_blob = next_blob
                .checked_add(1)
                .filter(|v| *v <= i64::MAX as u64)
                .ok_or_else(|| AppError::Database("attachment blob IDs exhausted".into()))?;
            let size = item.bytes.len() as u64;
            new_bytes = new_bytes.checked_add(size).ok_or_else(|| {
                quota_error(
                    "project_attachment_quota",
                    "stored-byte sum overflow".into(),
                )
            })?;
            (next_blob, size, false)
        };
        known.insert(hash.to_string(), (blob_id, stored_size));
        resolved.push(Resolved {
            blob_id,
            stored_size,
            deduplicated,
        });
    }
    let count = retained.len() + items.len();
    let task_bytes = retained
        .iter()
        .map(|a| a.stored_size)
        .chain(resolved.iter().map(|r| r.stored_size))
        .try_fold(0u64, |sum, n| sum.checked_add(n))
        .ok_or_else(|| {
            quota_error(
                "task_attachment_limit",
                "retained stored-byte sum overflow".into(),
            )
        })?;
    if count > limits.task_count as usize {
        return Err(quota_error(
            "task_attachment_limit",
            format!(
                "{count} retained attachment rows; per-task limit is {} rows",
                limits.task_count
            ),
        ));
    }
    if task_bytes > limits.task_stored_bytes {
        return Err(quota_error(
            "task_attachment_limit",
            format!(
                "{task_bytes} retained stored bytes (counted per row); per-task limit is {} bytes",
                limits.task_stored_bytes
            ),
        ));
    }
    let quota = limits.project_stored_bytes;
    let usage = usage(conn, quota)?;
    let project_bytes = usage
        .attachment_stored_bytes
        .checked_add(new_bytes)
        .ok_or_else(|| {
            quota_error(
                "project_attachment_quota",
                "project stored-byte sum overflow".into(),
            )
        })?;
    if project_bytes > quota {
        return Err(quota_error("project_attachment_quota",format!("{project_bytes} unique stored bytes including detached content; project limit is {quota} bytes")));
    }
    let mut next_id: u64 = conn.query_row(
        "SELECT coalesce(max(attachment_id),0) FROM task_attachments",
        [],
        |r| r.get(0),
    )?;
    let mut added = Vec::with_capacity(items.len());
    for (item, resolved) in items.iter().zip(&resolved) {
        if !resolved.deduplicated {
            conn.execute("INSERT INTO attachment_blobs(blob_id,content_sha256,original_size,codec,stored_size,created_ms,envelope) VALUES (?1,?2,?3,?4,?5,?6,?7)",params![resolved.blob_id,item.metadata.sha256,item.metadata.original_size,item.metadata.codec.as_str(),resolved.stored_size,now,item.bytes])?;
        }
        next_id = next_id
            .checked_add(1)
            .filter(|v| *v <= i64::MAX as u64)
            .ok_or_else(|| AppError::Database("attachment IDs exhausted".into()))?;
        let attachment = AttachmentSummary {
            id: next_id,
            display_id: format!("A{next_id}"),
            name: item.name.clone(),
            kind: item.metadata.kind.as_str().into(),
            media_type: item.metadata.media_type.into(),
            original_size: item.metadata.original_size,
            stored_size: resolved.stored_size,
            sha256: item.metadata.sha256.clone(),
            added_ms: now,
        };
        retained.push(attachment.clone());
        added.push(AddedAttachment {
            attachment,
            deduplicated: resolved.deduplicated,
        });
    }
    let event = write_event(conn, id, expected, "attach", &retained, now, attribution)?;
    for (added, resolved) in added.iter().zip(resolved) {
        let a = &added.attachment;
        conn.execute("INSERT INTO task_attachments(attachment_id,task_id,blob_id,name,kind,media_type,added_event_id,added_ms) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",params![a.id,id,resolved.blob_id,a.name,a.kind,a.media_type,event,now])?;
    }
    Ok(AttachResult {
        id,
        status,
        version: expected + 1,
        event_id: Some(event),
        attachments: added,
    })
}

pub(crate) fn detach(
    conn: &Connection,
    id: u64,
    expected: u64,
    ids: &[u64],
    now: i64,
    attribution: &str,
) -> Result<DetachResult, AppError> {
    let status = task_state(conn, id, expected)?;
    let mut detached = Vec::new();
    let mut seen = HashSet::new();
    let mut missing = Vec::new();
    for &attachment in ids {
        if !seen.insert(attachment) {
            continue;
        }
        let state: Option<Option<i64>> = conn
            .query_row(
                "SELECT detached_ms FROM task_attachments WHERE task_id=?1 AND attachment_id=?2",
                params![id, attachment],
                |r| r.get(0),
            )
            .optional()?;
        match state {
            None => missing.push(format!("A{attachment}")),
            Some(None) => detached.push(attachment),
            Some(Some(_)) => {}
        }
    }
    if !missing.is_empty() {
        return Err(AppError::NotFound(format!(
            "attachments {} do not belong to task {id}",
            missing.join(", ")
        )));
    }
    if detached.is_empty() {
        return Ok(DetachResult {
            id,
            status,
            version: expected,
            event_id: None,
            detached,
        });
    }
    let mut retained = retained_attachments(conn, &[id])?
        .remove(&id)
        .unwrap_or_default();
    retained.retain(|a| !seen.contains(&a.id));
    let event = write_event(conn, id, expected, "detach", &retained, now, attribution)?;
    for &attachment in &detached {
        conn.execute("UPDATE task_attachments SET detached_event_id=?1,detached_ms=?2 WHERE attachment_id=?3 AND detached_event_id IS NULL",params![event,now,attachment])?;
    }
    Ok(DetachResult {
        id,
        status,
        version: expected + 1,
        event_id: Some(event),
        detached,
    })
}

pub fn validate_items(items: &[PreparedItem], limits: &Limits) -> Result<(), AppError> {
    preflight(items.iter().map(|i| i.envelope.bytes()), limits)?;
    for item in items {
        name::validate(&item.name, limits)?;
    }
    Ok(())
}

pub(crate) fn validate_borrowed_items(
    items: &[BorrowedPreparedItem<'_>],
    limits: &Limits,
) -> Result<(), AppError> {
    preflight(items.iter().map(|i| i.bytes), limits)?;
    for item in items {
        name::validate(&item.name, limits)?;
    }
    Ok(())
}
