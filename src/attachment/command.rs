//! Local attachment commands. Preparation and rendering stay outside transactions.
use super::{db::PreparedItem, envelope, materialize, name, sniff, AttachmentError, Limits};
use crate::{
    cli::{AttachmentCommand, Cli, OutputFormat},
    clipboard::{self, ClipboardCapture, ClipboardCaptureError},
    error::AppError,
    model::{AttachmentRecord, AttachmentSummary},
    output::{ClipboardAttachmentItem, CommandPayload, Envelope},
    registry,
    store::Store,
};
use rusqlite::OptionalExtension;
use std::{
    fs::File,
    io::Read,
    path::{Path, PathBuf},
};

/// C2 enables this only when the local commands no longer return the stub error.
const LOCAL_IMPLEMENTED: bool = true;

/// The server must wait for D independently of local command availability.
#[derive(Clone, Copy, Debug)]
pub enum AttachmentBackend {
    Local,
    Remote,
}

/// Single advertisement source for viewer operations and attachments-v1.
/// C2 owns the local switch here; D owns the remote switch in frame.rs.
pub fn viewer_operations(backend: AttachmentBackend) -> &'static [&'static str] {
    let implemented = match backend {
        AttachmentBackend::Local => LOCAL_IMPLEMENTED,
        AttachmentBackend::Remote => super::frame::REMOTE_IMPLEMENTED,
    };
    if implemented {
        &[
            "attachment-add",
            "attachment-get",
            "attachment-detach",
            "attachment-clipboard",
        ]
    } else {
        &[]
    }
}

/// Dispatch attachment commands, including project-free clipboard inspection.
pub fn execute(cli: &Cli, command: &AttachmentCommand) -> Result<(), AppError> {
    if matches!(command, AttachmentCommand::Clipboard) {
        return render(cli, None, None, inspect_clipboard()?);
    }
    match command {
        AttachmentCommand::Add {
            request_id: Some(_),
            ..
        }
        | AttachmentCommand::Detach {
            request_id: Some(_),
            ..
        } => return Err(AppError::usage("request IDs require a remote profile")),
        AttachmentCommand::Get {
            out: Some(path), ..
        } if path == Path::new("-") => {
            return Err(AppError::usage(
                "--out - is refused; attachment get prints paths, never content",
            ))
        }
        _ => {}
    }
    let root = cli
        .data_root
        .clone()
        .unwrap_or_else(registry::default_data_root);
    let root = crate::storage::validate_storage_root(&root)?;
    let env_project = std::env::var("TASKS_PROJECT").ok();
    let project = registry::resolve_project(
        &root,
        cli.project.as_deref().or(env_project.as_deref()),
        cli.route_root.as_deref(),
    )?;

    let (key, payload) = match command {
        AttachmentCommand::Add {
            id,
            expect_version,
            file,
            name,
            clipboard,
            clipboard_token,
            ..
        } => {
            // Count, opened-file metadata, names and total size are admitted before
            // reading any source or opening the writable database.
            let sources = if *clipboard {
                let capture = capture_clipboard()?;
                if let Some(token) = clipboard_token {
                    clipboard::verify_capture_token(&capture, token).map_err(clipboard_error)?;
                }
                clipboard_sources(capture)?
            } else {
                file_sources(file, name.as_deref())?
            };
            let mut store = Store::open_rw(&root, &project)?;
            let task_id = store.resolve_ref(id)?;
            let items = encode_sources(sources)?;
            let added = store.attach(task_id, *expect_version, items, &Limits::PRODUCTION)?;
            (
                store.project_key.clone(),
                CommandPayload::AttachmentAdd {
                    id: added.id,
                    display_id: store.display_id(added.id),
                    status: added.status.to_string(),
                    version: added.version,
                    event_id: added.event_id,
                    attachments: added.attachments,
                    attachment_state: added.attachment_state,
                },
            )
        }
        AttachmentCommand::Detach {
            id,
            expect_version,
            attachment,
            ..
        } => {
            let ids = parse_ids(attachment)?;
            let mut store = Store::open_rw(&root, &project)?;
            let id = store.resolve_ref(id)?;
            let detached = store.detach(id, *expect_version, &ids)?;
            (
                store.project_key.clone(),
                CommandPayload::AttachmentDetach {
                    id,
                    display_id: store.display_id(id),
                    status: detached.status.to_string(),
                    version: detached.version,
                    event_id: detached.event_id,
                    detached: detached.detached,
                    attachment_state: detached.attachment_state,
                },
            )
        }
        AttachmentCommand::List {
            id,
            all,
            after,
            limit,
        } => {
            let mut store = Store::open_readonly(&root, &project)?;
            let task = store.show_task(id)?;
            let after = after.as_deref().map(parse_id).transpose()?;
            let page = store.list_attachments(task.id, *all, after, limit.unwrap_or(100))?;
            (
                store.project_key.clone(),
                CommandPayload::AttachmentList {
                    id: task.id,
                    display_id: task.display_id,
                    version: task.version,
                    items: page.items,
                    has_more: page.has_more,
                    next_after: page.next_after.map(|id| format!("A{id}")),
                },
            )
        }
        AttachmentCommand::Get {
            id,
            attachment,
            out,
            overwrite,
        } => {
            if attachment.len() > 32 {
                return Err(AppError::usage(
                    "at most 32 attachment IDs may be selected by get",
                ));
            }
            let ids = parse_ids(attachment)?;
            let mut store = Store::open_readonly(&root, &project)?;
            let task = store.show_task(id)?;
            let records = if ids.is_empty() {
                store.list_attachments(task.id, false, None, 32)?.items
            } else {
                selected_metadata(&store, task.id, &ids)?
            };
            let plan =
                materialize::Plan::new(records, &root, &project, out.as_deref(), *overwrite)?;
            let items = plan.execute(|attachment| {
                store
                    .read_envelope(task.id, attachment)
                    .map(|(_, bytes)| bytes)
            })?;
            (
                store.project_key.clone(),
                CommandPayload::AttachmentGet {
                    id: task.id,
                    display_id: task.display_id,
                    items,
                },
            )
        }
        AttachmentCommand::Clipboard => unreachable!("project-free clipboard handled above"),
    };
    render(cli, Some(project), key, payload)
}

fn render(
    cli: &Cli,
    project_id: Option<String>,
    id_key: Option<String>,
    data: CommandPayload,
) -> Result<(), AppError> {
    let envelope = Envelope {
        schema_version: 1,
        project_id,
        data,
        id_key,
    };
    use std::io::Write;
    let mut stdout = std::io::stdout().lock();
    match cli.format {
        OutputFormat::Json => writeln!(stdout, "{}", envelope.json()),
        OutputFormat::Text => write!(stdout, "{}", envelope.text()),
    }
    .map_err(|e| AppError::io_op("write attachment metadata", e))
}

pub fn parse_id(raw: &str) -> Result<u64, AppError> {
    let digits = raw.strip_prefix(['A', 'a']).unwrap_or(raw);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Err(AppError::usage(format!(
            "invalid attachment ID '{raw}'; use A12, a12 or 12"
        )));
    }
    digits
        .parse::<u64>()
        .ok()
        .filter(|&n| n > 0 && n <= i64::MAX as u64)
        .ok_or_else(|| {
            AppError::usage(format!(
                "invalid attachment ID '{raw}'; use a positive SQLite integer"
            ))
        })
}
fn parse_ids(raw: &[String]) -> Result<Vec<u64>, AppError> {
    let mut ids = raw
        .iter()
        .map(|s| parse_id(s))
        .collect::<Result<Vec<_>, _>>()?;
    ids.sort_unstable();
    ids.dedup();
    Ok(ids)
}

// Metadata only: no envelope overflow pages are touched during preflight.
fn selected_metadata(
    store: &Store,
    task: u64,
    ids: &[u64],
) -> Result<Vec<AttachmentRecord>, AppError> {
    let mut result = Vec::new();
    let mut missing = Vec::new();
    let mut stmt = store.conn.prepare("SELECT a.attachment_id,a.name,a.kind,a.media_type,b.original_size,b.stored_size,b.content_sha256,a.added_ms,a.detached_ms FROM task_attachments a JOIN attachment_blobs b USING(blob_id) WHERE a.task_id=?1 AND a.attachment_id=?2")?;
    for &id in ids {
        let record = stmt
            .query_row(rusqlite::params![task, id], |r| {
                Ok(AttachmentRecord {
                    attachment: AttachmentSummary {
                        id,
                        display_id: format!("A{id}"),
                        name: r.get(1)?,
                        kind: r.get(2)?,
                        media_type: r.get(3)?,
                        original_size: r.get(4)?,
                        stored_size: r.get(5)?,
                        sha256: r.get(6)?,
                        added_ms: r.get(7)?,
                    },
                    detached_ms: r.get(8)?,
                })
            })
            .optional()?;
        match record {
            Some(record) => result.push(record),
            None => missing.push(format!("A{id}")),
        }
    }
    if !missing.is_empty() {
        return Err(AppError::NotFound(format!(
            "attachments {} do not belong to {}",
            missing.join(", "),
            store.display_id(task)
        )));
    }
    Ok(result)
}

pub fn clipboard_error(error: ClipboardCaptureError) -> AppError {
    AppError::Coded {
        code: error.code(),
        exit: error.exit_code() as u8,
        message: error.to_string(),
    }
}

fn capture_clipboard() -> Result<ClipboardCapture, AppError> {
    let work = tempfile::tempdir()
        .map_err(|e| AppError::io_op("create private clipboard directory", e))?;
    let capture = clipboard::read_attachments(work.path()).map_err(clipboard_error)?;
    work.close()
        .map_err(|e| AppError::io_op("remove private clipboard directory", e))?;
    Ok(capture)
}

pub fn inspect_clipboard() -> Result<CommandPayload, AppError> {
    let capture = capture_clipboard()?;
    let token = clipboard::capture_token(&capture);
    let mut items = Vec::new();
    if let Some(bytes) = &capture.image {
        items.push(ClipboardAttachmentItem {
            source: "image".into(),
            name: image_name()?,
            path: None,
            original_size: bytes.len() as u64,
            kind: "image".into(),
            media_type: "image/png".into(),
        });
    }
    for path in &capture.files {
        let name = name::from_path(path, &Limits::PRODUCTION)?;
        let mut file =
            File::open(path).map_err(|e| AppError::io_path("inspect clipboard file", path, e))?;
        let size = file.metadata()?.len();
        let mut prefix = Vec::new();
        (&mut file)
            .take(sniff::PREFIX_BYTES as u64)
            .read_to_end(&mut prefix)?;
        let classification = sniff::sniff(&prefix, &name);
        items.push(ClipboardAttachmentItem {
            source: "file".into(),
            name,
            path: Some(path.to_string_lossy().into_owned()),
            original_size: size,
            kind: classification.kind.as_str().into(),
            media_type: classification.media_type.into(),
        });
    }
    Ok(CommandPayload::AttachmentClipboard {
        items,
        skipped: capture.skipped,
        token,
    })
}

enum Input {
    File(File),
    Stdin,
    Image(std::io::Cursor<Vec<u8>>),
}
struct Source {
    name: String,
    input: Input,
}

fn file_sources(files: &[PathBuf], display_name: Option<&str>) -> Result<Vec<Source>, AppError> {
    let limits = &Limits::PRODUCTION;
    check_count(files.len())?;
    if files.is_empty() {
        return Err(AppError::usage(
            "add requires at least one --file or --clipboard",
        ));
    }
    if display_name.is_some() && files.len() != 1 {
        return Err(AppError::usage("--name requires exactly one --file"));
    }
    if let Some(name) = display_name {
        name::validate(name, limits)?;
    }
    let mut total = 0u64;
    let mut result = Vec::new();
    for path in files {
        if path == Path::new("-") {
            let name = display_name.ok_or_else(|| {
                AppError::usage("--file - requires --name and exactly one --file")
            })?;
            result.push(Source {
                name: name.into(),
                input: Input::Stdin,
            });
            continue;
        }
        let name = match display_name {
            Some(name) => name.into(),
            None => name::from_path(path, limits)?,
        };
        let file =
            open_source(path).map_err(|e| AppError::io_path("open attachment source", path, e))?;
        let metadata = file
            .metadata()
            .map_err(|e| AppError::io_path("inspect opened attachment source", path, e))?;
        if !metadata.is_file() {
            return Err(AppError::io_path(
                "attach a regular file from",
                path,
                std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "source is not a regular file",
                ),
            ));
        }
        if metadata.len() > limits.original_bytes {
            return Err(AttachmentError::OriginalTooLarge {
                measured: metadata.len(),
                limit: limits.original_bytes,
            }
            .into());
        }
        total = checked_total(total, metadata.len())?;
        result.push(Source {
            name,
            input: Input::File(file),
        });
    }
    Ok(result)
}
fn open_source(path: &Path) -> std::io::Result<File> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // Opened-handle admission must reject a FIFO without waiting for a writer.
        // O_NONBLOCK has no effect on admitted regular files.
        options.custom_flags(rustix::fs::OFlags::NONBLOCK.bits() as i32);
    }
    options.open(path)
}

fn clipboard_sources(capture: ClipboardCapture) -> Result<Vec<Source>, AppError> {
    let mut sources = file_sources(&capture.files, None).or_else(|e| {
        if capture.files.is_empty() {
            Ok(Vec::new())
        } else {
            Err(e)
        }
    })?;
    if let Some(image) = capture.image {
        sources.push(Source {
            name: image_name()?,
            input: Input::Image(std::io::Cursor::new(image)),
        });
    }
    check_count(sources.len())?;
    if sources.is_empty() {
        return Err(AppError::Coded {
            code: "clipboard_empty",
            exit: 2,
            message: "the clipboard has no attachable image or regular files".into(),
        });
    }
    Ok(sources)
}
fn check_count(count: usize) -> Result<(), AppError> {
    if count > Limits::PRODUCTION.batch_count as usize {
        return Err(batch_error(format!(
            "{count} files; per-command limit is {} files",
            Limits::PRODUCTION.batch_count
        )));
    }
    Ok(())
}
fn checked_total(total: u64, size: u64) -> Result<u64, AppError> {
    let sum = total
        .checked_add(size)
        .ok_or_else(|| batch_error("original-byte sum exceeds u64".into()))?;
    if sum > Limits::PRODUCTION.batch_original_bytes {
        return Err(batch_error(format!(
            "{sum} original bytes; per-command limit is {} original bytes",
            Limits::PRODUCTION.batch_original_bytes
        )));
    }
    Ok(sum)
}
fn batch_error(message: String) -> AppError {
    AppError::Coded {
        code: "attachment_batch_too_large",
        exit: 2,
        message,
    }
}

fn encode_sources(sources: Vec<Source>) -> Result<Vec<PreparedItem>, AppError> {
    let mut total = 0u64;
    let mut result = Vec::with_capacity(sources.len());
    for source in sources {
        #[cfg(feature = "test-hooks")]
        if let Some(path) = std::env::var_os("TASKS_TEST_ENCODE_LOG") {
            use std::io::Write;
            writeln!(
                std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(path)?,
                "encode"
            )?;
        }
        let input: Box<dyn Read> = match source.input {
            Input::File(file) => Box::new(file),
            Input::Stdin => Box::new(std::io::stdin()),
            Input::Image(cursor) => Box::new(cursor),
        };
        let remaining = Limits::PRODUCTION.batch_original_bytes - total;
        let mut input = BudgetReader {
            input,
            remaining,
            read: 0,
            exceeded: false,
        };
        let encoded = envelope::encode(&mut input, &source.name, &Limits::PRODUCTION);
        if input.exceeded {
            return Err(batch_error(format!(
                "more than {} original bytes; per-command limit is {} original bytes",
                total + input.read,
                Limits::PRODUCTION.batch_original_bytes
            )));
        }
        let envelope = encoded?;
        total = checked_total(total, envelope.original_size())?;
        result.push(PreparedItem {
            name: source.name,
            envelope,
        });
    }
    Ok(result)
}
struct BudgetReader {
    input: Box<dyn Read>,
    remaining: u64,
    read: u64,
    exceeded: bool,
}
impl Read for BudgetReader {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let cap = buffer
            .len()
            .min(self.remaining.saturating_sub(self.read).saturating_add(1) as usize);
        let n = self.input.read(&mut buffer[..cap])?;
        self.read += n as u64;
        if self.read > self.remaining {
            self.exceeded = true;
            return Err(std::io::Error::other(
                "attachment batch original-byte limit exceeded",
            ));
        }
        Ok(n)
    }
}

fn image_name() -> Result<String, AppError> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| {
            AppError::Interop(format!(
                "cannot name clipboard image: system clock precedes Unix epoch: {e}"
            ))
        })?;
    Ok(image_name_at(now.as_secs()))
}
fn image_name_at(seconds: u64) -> String {
    let mut days = seconds / 86_400;
    let mut year = 1970u64;
    let leap = |year: u64| {
        year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400))
    };
    loop {
        let n = if leap(year) { 366 } else { 365 };
        if days < n {
            break;
        }
        days -= n;
        year += 1;
    }
    let months = [
        31,
        if leap(year) { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut month = 0;
    while days >= months[month] {
        days -= months[month];
        month += 1;
    }
    format!(
        "clipboard-{year:04}{:02}{:02}T{:02}{:02}{:02}Z.png",
        month + 1,
        days + 1,
        seconds / 3600 % 24,
        seconds / 60 % 60,
        seconds % 60
    )
}

#[cfg(test)]
mod tests {
    use std::io::Read;

    #[test]
    fn running_batch_budget_stops_a_growing_source_at_one_byte_past_the_limit() {
        let mut input = super::BudgetReader {
            input: Box::new(std::io::repeat(b'x')),
            remaining: 7,
            read: 0,
            exceeded: false,
        };
        let error = input.read_to_end(&mut Vec::new()).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::Other);
        assert!(input.exceeded);
        assert_eq!(input.read, 8);
        assert_eq!(
            super::checked_total(536_870_912, 1).unwrap_err().code(),
            "attachment_batch_too_large"
        );
    }

    #[test]
    fn clipboard_names_use_utc_calendar_dates() {
        assert_eq!(super::image_name_at(0), "clipboard-19700101T000000Z.png");
        assert_eq!(
            super::image_name_at(1_709_251_199),
            "clipboard-20240229T235959Z.png"
        );
    }
}
