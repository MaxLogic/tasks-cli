//! Signed binary transfers, with the shared local/remote publication path.
use super::{
    client::{api_output, parse_reply, transport_error, RemoteClient},
    protocol::{ApiOutput, DetachAttachments, ReadRequest},
};
use crate::{
    attachment::{envelope, frame, materialize, name, AttachmentError, Limits},
    cli::AttachmentCommand,
    model::{AttachmentRecord, AttachmentSummary},
    output::{CommandPayload, Envelope},
    AppError,
};
use http::Method;
use std::{fs::File, io::Read, path::Path};
use uuid::Uuid;

pub struct VerifiedDownload {
    pub metadata: AttachmentSummary,
    pub bytes: Vec<u8>,
}
pub fn get(
    client: &RemoteClient,
    project: Uuid,
    task: u64,
    attachment: u64,
) -> Result<VerifiedDownload, AppError> {
    let (metadata, bytes) = download_envelope(client, project, task, attachment)?;
    let mut original = Vec::new();
    envelope::decode_to(&bytes, &metadata.name, &mut original, &Limits::PRODUCTION)
        .map_err(|_| AttachmentError::Integrity("download envelope failed verification"))?;
    Ok(VerifiedDownload {
        metadata,
        bytes: original,
    })
}
fn download_envelope(
    client: &RemoteClient,
    project: Uuid,
    task: u64,
    attachment: u64,
) -> Result<(AttachmentSummary, Vec<u8>), AppError> {
    client.require_attachments()?;
    let reply = client
        .http
        .send_binary(
            Method::GET,
            &format!("/v1/projects/{project}/tasks/{task}/attachments/{attachment}"),
            b"",
            "application/json",
            None,
            0,
            frame::MAX_DOWNLOAD_BYTES,
            client.transfer_timeout(
                frame::MAX_DOWNLOAD_BYTES as u64,
                Limits::PRODUCTION.original_bytes,
            ),
        )
        .map_err(transport_error)?;
    if reply.status != 200 {
        return parse_reply(reply)
            .and_then(api_output)
            .and_then(|_| Err(AppError::validation("unexpected download response")));
    }
    let (metadata, bytes) = frame::parse_download(&reply.body, project, task, attachment)?;
    Ok((metadata.attachment, bytes.to_vec()))
}

#[derive(serde::Deserialize)]
struct MetadataReply {
    project_id: String,
    id_key: Option<String>,
    data: AttachmentPage,
}
#[derive(serde::Deserialize)]
struct AttachmentPage {
    id: u64,
    display_id: String,
    items: Vec<AttachmentRecord>,
    has_more: bool,
    next_after: Option<String>,
}
fn publish(
    client: &RemoteClient,
    root: &Path,
    project: &str,
    task_ref: &str,
    requested: &[String],
    out: Option<&Path>,
    overwrite: bool,
) -> Result<ApiOutput, AppError> {
    if requested.len() > 32 {
        return Err(AppError::usage(
            "at most 32 attachment IDs may be selected by get",
        ));
    }
    let mut ids = requested
        .iter()
        .map(|s| crate::attachment::command::parse_id(s))
        .collect::<Result<Vec<_>, _>>()?;
    ids.sort_unstable();
    ids.dedup();
    let mut after = None;
    let mut records = Vec::new();
    let metadata = loop {
        let reply = query(
            client,
            project,
            ReadRequest::Attachments {
                id: task_ref.into(),
                all: !ids.is_empty(),
                after,
                limit: 100,
            },
        )?;
        let metadata: MetadataReply = serde_json::from_value(reply.output)?;
        for record in &metadata.data.items {
            if ids.is_empty() || ids.binary_search(&record.attachment.id).is_ok() {
                records.push(record.clone());
            }
        }
        if !metadata.data.has_more || (!ids.is_empty() && records.len() == ids.len()) {
            break metadata;
        }
        let next = metadata
            .data
            .next_after
            .as_deref()
            .map(attachment_id)
            .transpose()?
            .filter(|next| after.is_none_or(|last| *next > last))
            .ok_or_else(|| AppError::validation("invalid attachment pagination response"))?;
        after = Some(next);
    };
    let missing = ids
        .iter()
        .filter(|id| !records.iter().any(|r| r.attachment.id == **id))
        .map(|id| format!("A{id}"))
        .collect::<Vec<_>>();
    if !missing.is_empty() {
        return Err(AppError::NotFound(format!(
            "attachments {} do not belong to {}",
            missing.join(", "),
            metadata.data.display_id
        )));
    }
    let project_id =
        Uuid::parse_str(project).map_err(|_| AppError::validation("invalid project UUID"))?;
    if metadata.project_id != project {
        return Err(AttachmentError::Integrity("attachment metadata project mismatch").into());
    }
    let expected = records
        .iter()
        .map(|r| (r.attachment.id, r.attachment.clone()))
        .collect::<std::collections::BTreeMap<_, _>>();
    let plan = materialize::Plan::new(records, root, project, out, overwrite)?;
    let items = plan.execute(|id| {
        let (summary, bytes) = download_envelope(client, project_id, metadata.data.id, id)?;
        if expected.get(&id) != Some(&summary) {
            return Err(
                AttachmentError::Integrity("download metadata changed after preflight").into(),
            );
        }
        Ok(bytes)
    })?;
    let envelope = Envelope {
        schema_version: 1,
        project_id: Some(metadata.project_id),
        id_key: metadata.id_key,
        data: CommandPayload::AttachmentGet {
            id: metadata.data.id,
            display_id: metadata.data.display_id,
            items,
        },
    };
    let text = envelope.text();
    Ok(ApiOutput {
        output: serde_json::to_value(envelope)?,
        text,
        catalog_name: None,
    })
}
fn query(
    client: &RemoteClient,
    project: &str,
    request: ReadRequest,
) -> Result<ApiOutput, AppError> {
    api_output(client.read(
        Method::POST,
        &format!("/v1/projects/{project}/query"),
        &serde_json::to_vec(&request)?,
    )?)
}
pub fn attachment_id(text: &str) -> Result<u64, AppError> {
    let text = text.strip_prefix(['A', 'a']).unwrap_or(text);
    text.parse::<u64>()
        .ok()
        .filter(|id| *id > 0 && *id <= i64::MAX as u64)
        .ok_or_else(|| AppError::validation("attachment ID must be A<n> or a positive number"))
}
fn quota() -> AppError {
    AppError::Coded {
        code: "attachment_batch_too_large",
        exit: 2,
        message: "attachment batch exceeds 32 items or 512 MiB of originals".into(),
    }
}
/// Check every opened source before reading any of them; encode from those same handles.
pub fn encode_files(
    files: &[std::path::PathBuf],
    display_name: Option<&str>,
) -> Result<Vec<(String, envelope::ValidatedEnvelope)>, AppError> {
    let limits = Limits::PRODUCTION;
    if files.is_empty() || files.len() > limits.batch_count as usize {
        return Err(quota());
    }
    if display_name.is_some() && files.len() != 1 {
        return Err(AppError::validation("--name requires one file"));
    }
    let mut total = 0u64;
    let mut sources = Vec::new();
    for path in files {
        let display = display_name
            .or_else(|| path.file_name().and_then(|v| v.to_str()))
            .ok_or_else(|| AppError::validation("attachment filename must be UTF-8 or use --name"))?
            .to_string();
        name::validate(&display, &limits)?;
        if path == Path::new("-") {
            if display_name.is_none() || files.len() != 1 {
                return Err(AppError::validation(
                    "stdin requires one --file - and --name",
                ));
            }
            sources.push((display, None));
            continue;
        }
        let file = File::open(path)?;
        let metadata = file.metadata()?;
        if !metadata.is_file() {
            return Err(AppError::validation(
                "attachment source must be a regular file",
            ));
        }
        if metadata.len() > limits.original_bytes {
            return Err(AttachmentError::OriginalTooLarge {
                measured: metadata.len(),
                limit: limits.original_bytes,
            }
            .into());
        }
        total = total.checked_add(metadata.len()).ok_or_else(quota)?;
        if total > limits.batch_original_bytes {
            return Err(quota());
        }
        sources.push((display, Some(file)));
    }
    let mut results = Vec::new();
    for (name, file) in sources {
        let reader: Box<dyn Read> = match file {
            Some(file) => Box::new(file),
            None => Box::new(std::io::stdin()),
        };
        let encoded = envelope::encode(reader, &name, &limits)?;
        results.push((name, encoded));
    }
    crate::attachment::db::preflight(results.iter().map(|(_, v)| v.bytes()), &limits)?;
    Ok(results)
}
pub fn add(
    client: &RemoteClient,
    root: &Path,
    project: &str,
    task_ref: &str,
    expected: u64,
    items: Vec<(String, envelope::ValidatedEnvelope)>,
    request_id: Option<Uuid>,
) -> Result<ApiOutput, AppError> {
    let task = crate::model::parse_task_ref(task_ref)
        .map_err(AppError::validation)?
        .id;
    let metadata = frame::UploadMetadata {
        format: 1,
        task_ref: task_ref.into(),
        expect_version: expected,
        items: items
            .iter()
            .map(|(name, value)| frame::UploadItem {
                name: name.clone(),
                original_size: value.original_size(),
                original_sha256: value.sha256().into(),
                stored_size: value.bytes().len() as u64,
            })
            .collect(),
        attribution: crate::attribution::current(),
    };
    let bytes = frame::upload(
        &metadata,
        &items.iter().map(|(_, v)| v.bytes()).collect::<Vec<_>>(),
    )?;
    client.write_binary(
        root,
        &format!("/v1/projects/{project}/tasks/{task}/attachments"),
        &bytes,
        request_id,
    )
}
fn clipboard_error(error: crate::clipboard::ClipboardCaptureError) -> AppError {
    let exit = match error.exit_code() {
        2 => 2,
        4 => 4,
        _ => 6,
    };
    AppError::Coded {
        code: error.code(),
        exit,
        message: error.to_string(),
    }
}
fn capture(root: &Path) -> Result<crate::clipboard::ClipboardCapture, AppError> {
    let private = root.join("client");
    crate::private_fs::create_dir(&private)?;
    let dir = private.join(format!("capture-{}", Uuid::new_v4()));
    crate::private_fs::create_dir(&dir)?;
    let result = crate::clipboard::read_attachments(&dir).map_err(clipboard_error);
    std::fs::remove_dir(&dir)?;
    result
}
pub fn execute(
    client: &RemoteClient,
    root: &Path,
    project: &str,
    command: &AttachmentCommand,
) -> Result<ApiOutput, AppError> {
    client.require_attachments()?;
    match command {
        AttachmentCommand::Add {
            id,
            expect_version,
            file,
            name,
            clipboard,
            clipboard_token,
            request_id,
        } => {
            let items = if *clipboard {
                let capture = capture(root)?;
                if let Some(token) = clipboard_token {
                    crate::clipboard::verify_capture_token(&capture, token)
                        .map_err(clipboard_error)?;
                }
                if let Some(image) = capture.image {
                    vec![(
                        "clipboard.png".into(),
                        envelope::encode(image.as_slice(), "clipboard.png", &Limits::PRODUCTION)?,
                    )]
                } else {
                    encode_files(&capture.files, None)?
                }
            } else {
                encode_files(file, name.as_deref())?
            };
            add(
                client,
                root,
                project,
                id,
                *expect_version,
                items,
                *request_id,
            )
        }
        AttachmentCommand::List {
            id,
            all,
            after,
            limit,
        } => query(
            client,
            project,
            ReadRequest::Attachments {
                id: id.clone(),
                all: *all,
                after: after.as_deref().map(attachment_id).transpose()?,
                limit: limit.unwrap_or(100),
            },
        ),
        AttachmentCommand::Detach {
            id,
            attachment,
            expect_version,
            request_id,
        } => {
            let reference = crate::model::parse_task_ref(id).map_err(AppError::validation)?;
            let task = reference.id;
            // Numeric IDs already select this project's route. Keyed input
            // still needs authoritative resolution before a numeric mutation.
            // Preserve typed read refusals for IDs outside the route range.
            if reference.key.is_some() || task == 0 || task > i64::MAX as u64 {
                query(
                    client,
                    project,
                    ReadRequest::Attachments {
                        id: id.clone(),
                        all: false,
                        after: None,
                        limit: 1,
                    },
                )?;
            }
            let target = format!("/v1/projects/{project}/tasks/{task}/attachments/detach");
            let payload = serde_json::to_value(DetachAttachments {
                expect_version: *expect_version,
                attachments: attachment
                    .iter()
                    .map(|s| attachment_id(s))
                    .collect::<Result<_, _>>()?,
                attribution: crate::attribution::current(),
            })?;
            match request_id {
                Some(id) => client.write_retained(root, Method::POST, &target, payload, *id),
                None => client.write(root, Method::POST, &target, payload),
            }
        }
        AttachmentCommand::Get {
            id,
            attachment,
            out,
            overwrite,
        } => publish(
            client,
            root,
            project,
            id,
            attachment,
            out.as_deref(),
            *overwrite,
        ),
        AttachmentCommand::Clipboard => {
            let capture = capture(root)?;
            let token = crate::clipboard::capture_token(&capture);
            let mut items = Vec::new();
            if let Some(image) = &capture.image {
                items.push(crate::output::ClipboardAttachmentItem {
                    source: "image".into(),
                    name: "clipboard.png".into(),
                    path: None,
                    original_size: image.len() as u64,
                    kind: "image".into(),
                    media_type: "image/png".into(),
                });
            }
            for path in &capture.files {
                let display = path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .ok_or_else(|| AppError::validation("clipboard filename must be UTF-8"))?;
                let mut file = File::open(path)?;
                let length = file.metadata()?.len();
                let mut prefix = Vec::new();
                Read::by_ref(&mut file)
                    .take(crate::attachment::sniff::PREFIX_BYTES as u64)
                    .read_to_end(&mut prefix)?;
                let kind = crate::attachment::sniff::sniff(&prefix, display);
                items.push(crate::output::ClipboardAttachmentItem {
                    source: "file".into(),
                    name: display.into(),
                    path: Some(path.display().to_string()),
                    original_size: length,
                    kind: kind.kind.as_str().into(),
                    media_type: kind.media_type.into(),
                });
            }
            let envelope = crate::output::Envelope {
                schema_version: 1,
                project_id: None,
                id_key: None,
                data: crate::output::CommandPayload::AttachmentClipboard {
                    items,
                    skipped: capture.skipped,
                    token,
                },
            };
            let text = envelope.text();
            Ok(ApiOutput {
                output: serde_json::to_value(envelope)?,
                text,
                catalog_name: None,
            })
        }
    }
}
