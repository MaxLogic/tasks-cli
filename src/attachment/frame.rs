//! Bounded attachment upload/download framing. Preflight never decodes payloads.
use super::{envelope, name, AttachmentError, Limits};
use crate::{
    model::{AttachmentSummary, Attribution},
    AppError,
};
use serde::{Deserialize, Serialize};
use std::ops::Range;
use uuid::Uuid;

pub const MAX_UPLOAD_BYTES: usize = 52 * 1024 * 1024;
pub const MAX_DOWNLOAD_BYTES: usize = 20 * 1024 * 1024 + 64 * 1024;
const MAX_UPLOAD_METADATA: usize = 1024 * 1024;

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UploadItem {
    pub name: String,
    pub original_size: u64,
    pub original_sha256: String,
    pub stored_size: u64,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UploadMetadata {
    pub format: u32,
    pub task_ref: String,
    pub expect_version: u64,
    pub items: Vec<UploadItem>,
    #[serde(default)]
    pub attribution: Attribution,
}
pub struct UploadFrame {
    pub metadata: UploadMetadata,
    pub ranges: Vec<Range<usize>>,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DownloadMetadata {
    pub format: u32,
    pub project_id: Uuid,
    pub task_id: u64,
    pub attachment: AttachmentSummary,
}
fn invalid() -> AppError {
    AppError::Coded {
        code: "attachment_integrity",
        exit: 2,
        message: "invalid attachment transfer frame".into(),
    }
}
fn batch() -> AppError {
    AppError::Coded {
        code: "attachment_batch_too_large",
        exit: 2,
        message: "attachment batch exceeds 32 items or 512 MiB of originals".into(),
    }
}
fn metadata<'a>(
    bytes: &'a [u8],
    magic: &[u8; 8],
    max: usize,
) -> Result<(&'a [u8], usize), AppError> {
    if bytes.len() < 12 || &bytes[..8] != magic {
        return Err(invalid());
    }
    let mut length = [0; 4];
    length.copy_from_slice(&bytes[8..12]);
    let length = u32::from_le_bytes(length) as usize;
    let end = 12usize.checked_add(length).ok_or_else(invalid)?;
    if length == 0 || length > max || end > bytes.len() {
        return Err(invalid());
    }
    Ok((&bytes[12..end], end))
}
pub fn preflight_upload(bytes: &[u8], limits: &Limits) -> Result<UploadFrame, AppError> {
    if bytes.len() > MAX_UPLOAD_BYTES {
        return Err(batch());
    }
    let (json, mut offset) = metadata(bytes, b"TASKUP01", MAX_UPLOAD_METADATA)?;
    let metadata: UploadMetadata = serde_json::from_slice(json).map_err(|_| invalid())?;
    if metadata.format != 1 || metadata.items.is_empty() {
        return Err(invalid());
    }
    if metadata.items.len() > limits.batch_count as usize {
        return Err(batch());
    }
    let mut originals = 0u64;
    let mut stored = offset as u64;
    for item in &metadata.items {
        name::validate(&item.name, limits)?;
        if item.stored_size < envelope::HEADER_BYTES as u64 {
            return Err(invalid());
        }
        if item.stored_size - envelope::HEADER_BYTES as u64 > limits.payload_bytes {
            return Err(AttachmentError::TooLarge {
                measured: item.stored_size - envelope::HEADER_BYTES as u64,
                limit: limits.payload_bytes,
            }
            .into());
        }
        if item.original_size > limits.original_bytes {
            return Err(AttachmentError::OriginalTooLarge {
                measured: item.original_size,
                limit: limits.original_bytes,
            }
            .into());
        }
        originals = originals
            .checked_add(item.original_size)
            .ok_or_else(batch)?;
        stored = stored.checked_add(item.stored_size).ok_or_else(batch)?;
        if originals > limits.batch_original_bytes {
            return Err(batch());
        }
    }
    if stored != bytes.len() as u64 {
        return Err(invalid());
    }
    let mut ranges = Vec::with_capacity(metadata.items.len());
    for item in &metadata.items {
        let length = usize::try_from(item.stored_size).map_err(|_| invalid())?;
        let end = offset
            .checked_add(length)
            .filter(|end| *end <= bytes.len())
            .ok_or_else(invalid)?;
        let header = envelope::parse_header(&bytes[offset..end])?;
        if header.original_size != item.original_size
            || format_hash(&header.original_sha256) != item.original_sha256
        {
            return Err(invalid());
        }
        ranges.push(offset..end);
        offset = end;
    }
    Ok(UploadFrame { metadata, ranges })
}
fn format_hash(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
pub fn upload(metadata: &UploadMetadata, envelopes: &[&[u8]]) -> Result<Vec<u8>, AppError> {
    let mut bytes = prefix(b"TASKUP01", metadata, MAX_UPLOAD_METADATA)?;
    for envelope in envelopes {
        if envelope.len() > MAX_UPLOAD_BYTES.saturating_sub(bytes.len()) {
            return Err(batch());
        }
        bytes.extend_from_slice(envelope);
    }
    preflight_upload(&bytes, &Limits::PRODUCTION)?;
    Ok(bytes)
}
fn prefix(magic: &[u8; 8], value: &impl Serialize, max: usize) -> Result<Vec<u8>, AppError> {
    let json = serde_json::to_vec(value)?;
    if json.is_empty() || json.len() > max {
        return Err(invalid());
    }
    let mut bytes = Vec::with_capacity(12 + json.len());
    bytes.extend_from_slice(magic);
    bytes.extend_from_slice(&(json.len() as u32).to_le_bytes());
    bytes.extend_from_slice(&json);
    Ok(bytes)
}
pub fn download(metadata: &DownloadMetadata, envelope: &[u8]) -> Result<Vec<u8>, AppError> {
    let mut bytes = prefix(
        b"TASKDN01",
        metadata,
        64 * 1024 - 12 - envelope::HEADER_BYTES,
    )?;
    if envelope.len() > MAX_DOWNLOAD_BYTES.saturating_sub(bytes.len()) {
        return Err(invalid());
    }
    bytes.extend_from_slice(envelope);
    Ok(bytes)
}
pub fn parse_download(
    bytes: &[u8],
    project: Uuid,
    task: u64,
    attachment: u64,
) -> Result<(DownloadMetadata, &[u8]), AppError> {
    let integrity = || {
        AppError::from(AttachmentError::Integrity(
            "invalid download frame or identity",
        ))
    };
    if bytes.len() > MAX_DOWNLOAD_BYTES {
        return Err(integrity());
    }
    let (json, offset) = metadata(bytes, b"TASKDN01", 64 * 1024).map_err(|_| integrity())?;
    let metadata: DownloadMetadata = serde_json::from_slice(json).map_err(|_| integrity())?;
    if metadata.format != 1
        || metadata.project_id != project
        || metadata.task_id != task
        || metadata.attachment.id != attachment
    {
        return Err(integrity());
    }
    let raw = &bytes[offset..];
    let header = envelope::parse_header(raw).map_err(|_| integrity())?;
    if raw.len() as u64 != metadata.attachment.stored_size
        || header.original_size != metadata.attachment.original_size
        || format_hash(&header.original_sha256) != metadata.attachment.sha256
    {
        return Err(integrity());
    }
    Ok((metadata, raw))
}

/// Signed remote add, get and detach use the verified attachment implementation.
pub const REMOTE_IMPLEMENTED: bool = true;
