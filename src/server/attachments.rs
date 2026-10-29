//! Attachment admission, header preflight and decode outside write transactions.
use super::{
    api,
    receipts::{self, ReceiptIdentity, ReceiptResponse},
    signatures::AuthenticatedRequest,
    OwnedServer, ServiceError,
};
use crate::{
    attachment::{
        db::{self, BorrowedPreparedItem},
        frame, Limits,
    },
    model::Attribution,
    output::CommandPayload,
    store::Store,
    AppError,
};
use http::{Method, Uri};
use std::{sync::Arc, time::Duration};
use uuid::Uuid;

pub fn is_download(method: &Method, uri: &Uri) -> bool {
    crate::remote::signing::is_download(method, uri)
}
fn route(uri: &Uri) -> Result<(Uuid, u64), AppError> {
    let parts: Vec<_> = uri.path().split('/').collect();
    if uri.query().is_some() || parts.len() < 7 {
        return Err(AppError::validation("invalid attachment route"));
    }
    let project =
        Uuid::parse_str(parts[3]).map_err(|_| AppError::validation("invalid project UUID"))?;
    let task = parts[5]
        .parse::<u64>()
        .map_err(|_| AppError::validation("invalid task ID"))?;
    if project.is_nil()
        || project.to_string() != parts[3]
        || task == 0
        || task > i64::MAX as u64
        || task.to_string() != parts[5]
    {
        return Err(AppError::validation("noncanonical attachment route"));
    }
    Ok((project, task))
}
fn application_input(error: AppError) -> AppError {
    // Decoder/format failures are untrusted input, never a stored-content failure.
    // Preserve explicit quotas (413), but make malformed envelopes terminal 400.
    match error {
        error @ AppError::Coded { exit: 2, .. } => error,
        AppError::Coded { code, message, .. } => AppError::Coded {
            code,
            message,
            exit: 2,
        },
        error => error,
    }
}
pub(super) fn upload(
    server: &OwnedServer,
    auth: &AuthenticatedRequest,
    uri: &Uri,
    bytes: &[u8],
    operations: Arc<tokio::sync::Semaphore>,
    log: &mut super::request_log::RequestLog,
) -> Result<ReceiptResponse, ServiceError> {
    let (project, task) = match route(uri) {
        Ok(v) => v,
        Err(e) => return api::response(Err(e)),
    };
    let identity = api::identity(auth, &Method::POST, uri)?;
    if !api::catalogued(server, project)? {
        let _lock =
            crate::storage::acquire_exclusive_lock(&server.data_root().join("registry.lock"))?;
        let attribution = api::context(auth, Attribution::default())?;
        crate::store::prepare_server_project(server.data_root(), &project, &attribution)?;
        return Ok(receipts::execute(
            Store::open_rw(server.data_root(), &project.to_string())?,
            &identity,
            bytes,
            |_| Err(AppError::NotFound("unknown server project".into())),
        )?);
    }
    {
        let store = Store::open_readonly(server.data_root(), &project.to_string())?;
        if let Some(reply) = receipts::lookup(&store, &identity, &crate::markdown::sha256(bytes))? {
            return Ok(reply);
        }
    }
    let prepared = (|| {
        let frame = frame::preflight_upload(bytes, &Limits::PRODUCTION)?;
        log.attachment_sizes(
            frame.metadata.items.len() as u64,
            frame.metadata.items.iter().map(|i| i.stored_size).sum(),
            frame.metadata.items.iter().map(|i| i.original_size).sum(),
        );
        let store = Store::open_readonly(server.data_root(), &project.to_string())?;
        if store.resolve_ref(&frame.metadata.task_ref)? != task {
            return Err(AppError::validation(
                "task reference does not match the route ID",
            ));
        }
        let (mut metadata, items) = prepare(bytes, frame)?;
        metadata.attribution = api::context(auth, metadata.attribution)?;
        Ok((metadata, items))
    })()
    .map_err(application_input);
    let _permit = tokio::runtime::Handle::current()
        .block_on(async {
            tokio::time::timeout(Duration::from_secs(1), operations.acquire_owned()).await
        })
        .map_err(|_| ServiceError::Capacity)?
        .map_err(|_| ServiceError::Capacity)?;
    execute(server, project, task, &identity, bytes, prepared)
}
fn prepare(
    bytes: &[u8],
    frame: frame::UploadFrame,
) -> Result<(frame::UploadMetadata, Vec<BorrowedPreparedItem<'_>>), AppError> {
    let items = frame
        .metadata
        .items
        .iter()
        .zip(frame.ranges)
        .map(|(item, range)| (item.name.clone(), &bytes[range]))
        .collect();
    let prepared = db::prepare_borrowed(items, &Limits::PRODUCTION)?;
    Ok((frame.metadata, prepared))
}
fn execute(
    server: &OwnedServer,
    project: Uuid,
    task: u64,
    identity: &ReceiptIdentity,
    bytes: &[u8],
    prepared: Result<(frame::UploadMetadata, Vec<BorrowedPreparedItem<'_>>), AppError>,
) -> Result<ReceiptResponse, ServiceError> {
    let mut store = Store::open_rw(server.data_root(), &project.to_string())?;
    store.conn.pragma_update(None, "temp_store", "MEMORY")?;
    if let Ok((metadata, _)) = &prepared {
        store.set_attribution(&metadata.attribution)?;
    }
    Ok(receipts::execute(store, identity, bytes, |store| {
        let (metadata, items) = prepared?;
        let result =
            store.attach_borrowed(task, metadata.expect_version, &items, &Limits::PRODUCTION)?;
        api::output(
            store,
            CommandPayload::AttachmentAdd {
                id: result.id,
                display_id: store.display_id(result.id),
                status: result.status.to_string(),
                version: result.version,
                event_id: result.event_id,
                attachments: result.attachments,
                attachment_state: result.attachment_state,
            },
        )
    })?)
}
pub(crate) struct Download {
    pub metadata: frame::DownloadMetadata,
    pub prefix: Vec<u8>,
    pub envelope: Vec<u8>,
}

pub(crate) fn download(server: &OwnedServer, uri: &Uri) -> Result<Download, AppError> {
    // Context is opt-in because existing protocol-2 clients reject unknown
    // frame fields. The signed query carries the complete task reference.
    let task_ref = match uri.query() {
        None => None,
        Some(query) => Some(
            query
                .strip_prefix("context=1&task_ref=")
                .filter(|reference| !reference.contains(['&', '=', '%']))
                .ok_or_else(|| AppError::validation("invalid download context query"))?,
        ),
    };
    let numeric: Uri = uri
        .path()
        .parse()
        .map_err(|_| AppError::validation("invalid attachment route"))?;
    let (project, task) = route(&numeric)?;
    if !api::catalogued(server, project)
        .map_err(|_| AppError::Database("server catalog unavailable".into()))?
    {
        return Err(AppError::NotFound("unknown server project".into()));
    }
    let id_text = uri
        .path()
        .rsplit('/')
        .next()
        .ok_or_else(|| AppError::validation("invalid attachment ID"))?;
    let id = id_text
        .parse::<u64>()
        .map_err(|_| AppError::validation("invalid attachment ID"))?;
    if id == 0 || id > i64::MAX as u64 || id.to_string() != id_text {
        return Err(AppError::validation("invalid attachment ID"));
    }
    let mut store = Store::open_readonly(server.data_root(), &project.to_string())?;
    let snapshot = store.conn.unchecked_transaction()?;
    store.project_key = crate::keys::read_key(&snapshot)?;
    if let Some(reference) = task_ref {
        if store.resolve_ref(reference)? != task {
            return Err(AppError::validation(
                "task reference does not match the route ID",
            ));
        }
    }
    let (record, bytes) = db::read_envelope(&snapshot, task, id)?;
    let context = task_ref.map(|_| frame::DownloadContext {
        id_key: store.project_key.clone(),
        detached_ms: record.detached_ms,
    });
    snapshot.commit()?;
    let metadata = frame::DownloadMetadata {
        format: 1,
        project_id: project,
        task_id: task,
        attachment: record.attachment,
        context,
    };
    // Keep the existing bounded SQLite read, but do not copy its full BLOB into
    // another frame Vec. The transport sends this prefix and envelope in order.
    let prefix = frame::download(&metadata, &[])?;
    if bytes.len() > frame::MAX_DOWNLOAD_BYTES.saturating_sub(prefix.len()) {
        return Err(AppError::validation(
            "attachment download exceeds its frame bound",
        ));
    }
    Ok(Download {
        metadata,
        prefix,
        envelope: bytes,
    })
}
