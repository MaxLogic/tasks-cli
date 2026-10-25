//! Private HTTP listener: authentication applies even without a reverse proxy.
use super::{signatures::is_mutation, OwnedServer, ServiceError};
use axum::{
    body::to_bytes,
    extract::State,
    http::{Request, StatusCode},
    response::{IntoResponse, Response},
    Json, Router,
};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use std::{
    io,
    pin::Pin,
    sync::Mutex,
    task::{Context, Poll, Waker},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::Semaphore;

pub const MAX_BODY_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_OPERATIONS: usize = 8;
pub const MAX_TRANSFERS: usize = 2;

/// Per-connection cancellation wakes Hyper even when a peer never reads again.
#[derive(Clone, Debug, Default)]
pub struct ConnectionControl(Arc<ConnectionCancellation>);
#[derive(Debug, Default)]
struct ConnectionCancellation {
    cancelled: AtomicBool,
    read: Mutex<Option<Waker>>,
    write: Mutex<Option<Waker>>,
}
impl ConnectionControl {
    fn abort(&self) {
        self.0.cancelled.store(true, Ordering::Release);
        for slot in [&self.0.read, &self.0.write] {
            let waker = slot
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take();
            if let Some(waker) = waker {
                waker.wake();
            }
        }
    }
    fn ready(&self, cx: &Context<'_>, write: bool) -> io::Result<()> {
        let slot = if write { &self.0.write } else { &self.0.read };
        *slot
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(cx.waker().clone());
        if self.0.cancelled.load(Ordering::Acquire) {
            Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "attachment transfer expired",
            ))
        } else {
            Ok(())
        }
    }
}
/// Use with ConnectInfo<ConnectionControl> so transfer deadlines close the IO.
pub struct TransferListener(pub tokio::net::TcpListener);
pub struct TransferIo {
    socket: tokio::net::TcpStream,
    connection: ConnectionControl,
}
impl axum::serve::Listener for TransferListener {
    type Io = TransferIo;
    type Addr = std::net::SocketAddr;
    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        let (socket, address) = axum::serve::Listener::accept(&mut self.0).await;
        (
            TransferIo {
                socket,
                connection: ConnectionControl::default(),
            },
            address,
        )
    }
    fn local_addr(&self) -> io::Result<Self::Addr> {
        self.0.local_addr()
    }
}
impl axum::extract::connect_info::Connected<axum::serve::IncomingStream<'_, TransferListener>>
    for ConnectionControl
{
    fn connect_info(stream: axum::serve::IncomingStream<'_, TransferListener>) -> Self {
        stream.io().connection.clone()
    }
}
impl AsyncRead for TransferIo {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if let Err(error) = this.connection.ready(cx, false) {
            return Poll::Ready(Err(error));
        }
        Pin::new(&mut this.socket).poll_read(cx, buffer)
    }
}
impl AsyncWrite for TransferIo {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        if let Err(error) = this.connection.ready(cx, true) {
            return Poll::Ready(Err(error));
        }
        Pin::new(&mut this.socket).poll_write(cx, buffer)
    }
    fn poll_write_vectored(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffers: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        if let Err(error) = this.connection.ready(cx, true) {
            return Poll::Ready(Err(error));
        }
        Pin::new(&mut this.socket).poll_write_vectored(cx, buffers)
    }
    fn is_write_vectored(&self) -> bool {
        self.socket.is_write_vectored()
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if let Err(error) = this.connection.ready(cx, true) {
            return Poll::Ready(Err(error));
        }
        Pin::new(&mut this.socket).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if let Err(error) = this.connection.ready(cx, true) {
            return Poll::Ready(Err(error));
        }
        Pin::new(&mut this.socket).poll_shutdown(cx)
    }
}

#[derive(Clone)]
pub struct ServiceState {
    server: Arc<OwnedServer>,
    operations: Arc<Semaphore>,
    transfers: Arc<Semaphore>,
    draining: Arc<AtomicBool>,
    logs: super::request_log::RequestLogs,
}
impl ServiceState {
    pub fn new(server: OwnedServer) -> Self {
        Self {
            server: Arc::new(server),
            operations: Arc::new(Semaphore::new(MAX_OPERATIONS)),
            transfers: Arc::new(Semaphore::new(MAX_TRANSFERS)),
            draining: Arc::new(AtomicBool::new(false)),
            logs: super::request_log::RequestLogs::stderr(),
        }
    }
    pub fn with_log_file(mut self, file: std::fs::File) -> Self {
        self.logs = super::request_log::RequestLogs::file(file);
        self
    }
    pub fn begin_shutdown(&self) {
        self.draining.store(true, Ordering::SeqCst);
    }
    pub fn router(&self) -> Router {
        // One authenticated entry point prevents accidental unsigned fallback routes.
        Router::new().fallback(handler).with_state(self.clone())
    }
}

fn error(status: StatusCode, code: &str, message: &str) -> Response {
    (
        status,
        Json(serde_json::json!({"error":{"code":code,"message":message}})),
    )
        .into_response()
}
impl ServiceError {
    fn http_error(&self) -> (StatusCode, &'static str) {
        match self {
            Self::Unauthorized(_) => (StatusCode::UNAUTHORIZED, "authentication"),
            Self::Clock => (StatusCode::UNAUTHORIZED, "clock_window"),
            Self::Capacity => (StatusCode::SERVICE_UNAVAILABLE, "capacity"),
            Self::Validation(_) => (StatusCode::BAD_REQUEST, "validation"),
            Self::Storage(crate::AppError::Busy(_) | crate::AppError::LockTimeout(_)) => {
                (StatusCode::SERVICE_UNAVAILABLE, "lock_timeout")
            }
            Self::Storage(_) => (StatusCode::INTERNAL_SERVER_ERROR, "storage"),
        }
    }
}
impl IntoResponse for ServiceError {
    fn into_response(self) -> Response {
        let (status, code) = self.http_error();
        // Storage details stay server-local; never return filesystem/SQL diagnostics.
        let message = if matches!(self, Self::Storage(_)) {
            "server storage is unavailable".into()
        } else {
            self.to_string()
        };
        error(status, code, &message)
    }
}

async fn handler(
    State(state): State<ServiceState>,
    request: Request<axum::body::Body>,
) -> Response {
    let mut log =
        super::request_log::RequestLog::new(state.logs.clone(), request.method(), request.uri());
    let mut response = dispatch(state, request, &mut log).await;
    response.headers_mut().insert(
        "cache-control",
        axum::http::HeaderValue::from_static("no-store"),
    );
    log.completed(response.status().as_u16());
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn response_buffers_keep_admission_until_every_clone_is_released() {
        let semaphore = Arc::new(Semaphore::new(1));
        let permit = semaphore.clone().try_acquire_owned().unwrap();
        let bytes = axum::body::Bytes::from_owner(ResponseBytes {
            bytes: vec![1; 1024],
            _permit: Some(permit),
        });
        let clone = bytes.clone();
        assert_eq!(semaphore.available_permits(), 0);
        drop(bytes);
        assert_eq!(semaphore.available_permits(), 0);
        drop(clone);
        assert_eq!(semaphore.available_permits(), 1);
    }
}

async fn dispatch(
    state: ServiceState,
    request: Request<axum::body::Body>,
    log: &mut super::request_log::RequestLog,
) -> Response {
    let connection = request
        .extensions()
        .get::<axum::extract::ConnectInfo<ConnectionControl>>()
        .map(|info| info.0.clone());
    let mutation = is_mutation(request.method(), request.uri());
    let upload = crate::remote::signing::is_upload(request.method(), request.uri());
    let download = super::attachments::is_download(request.method(), request.uri());
    let length = request
        .headers()
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok());
    if upload {
        match length {
            None => {
                return error(
                    StatusCode::LENGTH_REQUIRED,
                    "length_required",
                    "attachment uploads require Content-Length",
                )
            }
            Some(length) if length > crate::attachment::frame::MAX_UPLOAD_BYTES as u64 => {
                return error(
                    StatusCode::PAYLOAD_TOO_LARGE,
                    "body_limit",
                    "attachment upload exceeds 52 MiB",
                )
            }
            _ => (),
        }
    }
    if mutation && state.draining.load(Ordering::SeqCst) {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "shutting_down",
            "server is shutting down; new writes are not admitted",
        );
    }
    let permit = match tokio::time::timeout(
        Duration::from_secs(1),
        state.operations.clone().acquire_owned(),
    )
    .await
    {
        Ok(Ok(permit)) => permit,
        _ => return ServiceError::Capacity.into_response(),
    };
    if mutation && state.draining.load(Ordering::SeqCst) {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "shutting_down",
            "server is shutting down; new writes are not admitted",
        );
    }
    let (parts, body) = request.into_parts();
    let server = state.server.clone();
    // The blocking worker owns the permit. Cancellation cannot release capacity
    // while synchronous SQLite work is still running.
    let authenticated = tokio::task::spawn_blocking(move || {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| ServiceError::Clock)?;
        let now = i64::try_from(now.as_secs()).map_err(|_| ServiceError::Clock)?;
        let authentication = server.authenticate(&parts.method, &parts.uri, &parts.headers, now)?;
        Ok::<_, ServiceError>((authentication, permit, parts, server.server_id()))
    })
    .await;
    let (authenticated, permit, parts, _server_id) = match authenticated {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => return error.into_response(),
        Err(_) => {
            return error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "worker",
                "server worker failed",
            )
        }
    };
    log.authenticated(&authenticated);
    if upload || download {
        // Never occupy an operation slot while waiting for a body or transfer slot.
        drop(permit);
        let transfer = match tokio::time::timeout(
            Duration::from_secs(1),
            state.transfers.clone().acquire_owned(),
        )
        .await
        {
            Ok(Ok(permit)) => permit,
            _ => return ServiceError::Capacity.into_response(),
        };
        #[cfg(feature = "test-hooks")]
        if let Some(path) = std::env::var_os("TASKS_TEST_TRANSFER_LOG") {
            use std::io::Write;
            if let Err(failure) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .and_then(|mut file| writeln!(file, "admitted"))
            {
                return ServiceError::Storage(failure.into()).into_response();
            }
        }
        let limit = if upload {
            crate::attachment::frame::MAX_UPLOAD_BYTES
        } else {
            MAX_BODY_BYTES
        };
        let deadline = if upload {
            Duration::from_secs(30 + length.unwrap_or(0) / (64 * 1024))
                .min(Duration::from_secs(600))
        } else {
            Duration::from_secs(15)
        };
        let bytes = match tokio::time::timeout(deadline, to_bytes(body, limit)).await {
            Ok(Ok(bytes)) => bytes,
            Ok(Err(_)) => {
                return error(
                    StatusCode::BAD_REQUEST,
                    "body_read",
                    "attachment transfer body could not be read within its bound",
                )
            }
            Err(_) => {
                if let Some(connection) = &connection {
                    connection.abort();
                }
                return error(
                    StatusCode::REQUEST_TIMEOUT,
                    "body_timeout",
                    "attachment body deadline exceeded",
                );
            }
        };
        if let Err(error) = authenticated.check_body(&bytes) {
            return error.into_response();
        }
        if upload && length != Some(bytes.len() as u64) {
            return error(
                StatusCode::BAD_REQUEST,
                "body_read",
                "Content-Length does not match body",
            );
        }
        if download && !bytes.is_empty() {
            return error(
                StatusCode::BAD_REQUEST,
                "validation",
                "download request body must be empty",
            );
        }
        let server = state.server.clone();
        let operations = state.operations.clone();
        if upload {
            let mut upload_log = log.handoff();
            let result = tokio::task::spawn_blocking(move || {
                let _transfer = transfer;
                let result = super::attachments::upload(
                    &server,
                    &authenticated,
                    &parts.uri,
                    &bytes,
                    operations,
                    &mut upload_log,
                );
                match &result {
                    Ok(reply) => {
                        upload_log.attachment_output(&reply.body);
                        upload_log.completed(reply.status);
                    }
                    Err(error) => upload_log.completed(error.http_error().0.as_u16()),
                }
                result
            })
            .await;
            return match result {
                Ok(Ok(reply)) => plain_json_response(reply),
                Ok(Err(error)) => error.into_response(),
                Err(_) => error(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "worker",
                    "attachment worker failed",
                ),
            };
        }
        let Some(connection) = connection else {
            return error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "transport",
                "attachment downloads require cancellable transport",
            );
        };
        let operation =
            match tokio::time::timeout(Duration::from_secs(1), operations.acquire_owned()).await {
                Ok(Ok(p)) => p,
                _ => return ServiceError::Capacity.into_response(),
            };
        let result = tokio::task::spawn_blocking(move || {
            let _operation = operation;
            (
                super::attachments::download(&server, &parts.uri),
                transfer,
                server,
            )
        })
        .await;
        let (bytes, transfer, server) = match result {
            Ok((Ok(bytes), transfer, server)) => (bytes, transfer, server),
            Ok((Err(error), _, _)) => {
                return match super::receipts::refusal(&error) {
                    Some(reply) => plain_json_response(reply),
                    None => ServiceError::Storage(error).into_response(),
                }
            }
            Err(_) => {
                return error(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "worker",
                    "attachment worker failed",
                )
            }
        };
        let (sender, body) =
            http_body_util::channel::Channel::<axum::body::Bytes, std::io::Error>::new(2);
        let mut download_log = log.handoff();
        // The server generated this bounded frame; this inspection does no decode.
        if let Some(metadata) = bytes
            .get(8..12)
            .and_then(|v| v.try_into().ok())
            .map(u32::from_le_bytes)
            .and_then(|len| bytes.get(12..12 + len as usize))
            .and_then(|json| {
                serde_json::from_slice::<crate::attachment::frame::DownloadMetadata>(json).ok()
            })
        {
            download_log.attachment_sizes(
                1,
                metadata.attachment.stored_size,
                metadata.attachment.original_size,
            );
        }
        tokio::task::spawn(async move {
            let _server = server;
            let transfer = Arc::new(transfer);
            let released = Arc::new(tokio::sync::Notify::new());
            let started = std::time::Instant::now();
            let mut sender = sender;
            for chunk in bytes.chunks(256 * 1024) {
                let timeout = Duration::from_secs(600)
                    .saturating_sub(started.elapsed())
                    .min(Duration::from_secs(15));
                let data = axum::body::Bytes::from_owner(TransferBytes {
                    bytes: chunk.to_vec(),
                    permit: Some(transfer.clone()),
                    released: released.clone(),
                });
                if !matches!(
                    tokio::time::timeout(timeout, sender.send_data(data)).await,
                    Ok(Ok(()))
                ) {
                    download_log.attachment_finished(false);
                    // Aborting a channel alone leaves chunks owned by Hyper's
                    // blocked socket writes. Fail the connection IO to drop
                    // those buffers and their permits without peer cooperation.
                    connection.abort();
                    sender.abort(std::io::Error::other(
                        "attachment stream deadline or disconnect",
                    ));
                    return;
                }
            }
            // send_data means queued, not consumed by the socket. Keep the
            // same deadlines over final buffered chunks after closing the queue.
            drop(sender);
            drop(bytes);
            while Arc::strong_count(&transfer) > 1 {
                let timeout = Duration::from_secs(600)
                    .saturating_sub(started.elapsed())
                    .min(Duration::from_secs(15));
                if tokio::time::timeout(timeout, released.notified())
                    .await
                    .is_err()
                {
                    download_log.attachment_finished(false);
                    connection.abort();
                    return;
                }
            }
            download_log.attachment_finished(true);
        });
        return (
            [("content-type", "application/octet-stream")],
            axum::body::Body::new(body),
        )
            .into_response();
    }
    if parts
        .headers
        .get("content-length")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .is_some_and(|length| length > MAX_BODY_BYTES as u64)
    {
        return error(
            StatusCode::PAYLOAD_TOO_LARGE,
            "body_limit",
            "request body exceeds the 8 MiB limit",
        );
    }
    let bytes =
        match tokio::time::timeout(Duration::from_secs(15), to_bytes(body, MAX_BODY_BYTES)).await {
            Ok(Ok(bytes)) => bytes,
            Ok(Err(failure)) => {
                use std::error::Error;
                let oversized = failure
                    .source()
                    .is_some_and(|cause| cause.is::<http_body_util::LengthLimitError>());
                return error(
                    if oversized {
                        StatusCode::PAYLOAD_TOO_LARGE
                    } else {
                        StatusCode::BAD_REQUEST
                    },
                    if oversized { "body_limit" } else { "body_read" },
                    if oversized {
                        "request body exceeds the 8 MiB limit"
                    } else {
                        "request body could not be read"
                    },
                );
            }
            Err(_) => {
                return error(
                    StatusCode::REQUEST_TIMEOUT,
                    "body_timeout",
                    "request body read timed out",
                )
            }
        };
    if let Err(error) = authenticated.check_body(&bytes) {
        return error.into_response();
    }
    let server = state.server.clone();
    if parts.method == axum::http::Method::GET && parts.uri.path().ends_with("/export") {
        let prepared = tokio::task::spawn_blocking(move || {
            let prepared = super::api::prepare_export(&server, &parts.uri);
            (prepared, permit, server)
        })
        .await;
        let (prepared, permit, server) = match prepared {
            Ok(value) => value,
            Err(_) => {
                return error(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "worker",
                    "server worker failed",
                )
            }
        };
        let store = match prepared {
            Ok(super::api::ExportPreparation::Ready(store)) => store,
            Ok(super::api::ExportPreparation::Refused(reply)) => {
                return json_response(reply, permit)
            }
            Err(error) => return error.into_response(),
        };
        let (sender, body) =
            http_body_util::channel::Channel::<axum::body::Bytes, std::io::Error>::new(2);
        let mut stream_log = log.handoff();
        tokio::task::spawn_blocking(move || {
            let _server = server;
            let result = super::export::ExportWriter::new(sender, permit).run(*store);
            stream_log.export_finished(result.is_ok());
        });
        return (
            [("content-type", "application/x-ndjson")],
            axum::body::Body::new(body),
        )
            .into_response();
    }
    match tokio::task::spawn_blocking(move || {
        let reply = super::api::handle(&server, &authenticated, &parts.method, &parts.uri, &bytes);
        (reply, permit)
    })
    .await
    {
        Ok((Ok(reply), permit)) => {
            log.attachment_output(&reply.body);
            json_response(reply, permit)
        }
        Ok((Err(error), _permit)) => error.into_response(),
        Err(_) => error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "worker",
            "server worker failed",
        ),
    }
}

struct ResponseBytes {
    bytes: Vec<u8>,
    _permit: Option<tokio::sync::OwnedSemaphorePermit>,
}
struct TransferBytes {
    bytes: Vec<u8>,
    permit: Option<Arc<tokio::sync::OwnedSemaphorePermit>>,
    released: Arc<tokio::sync::Notify>,
}
impl Drop for TransferBytes {
    fn drop(&mut self) {
        drop(self.permit.take());
        self.released.notify_one();
    }
}
impl AsRef<[u8]> for TransferBytes {
    fn as_ref(&self) -> &[u8] {
        &self.bytes
    }
}
fn plain_json_response(reply: super::receipts::ReceiptResponse) -> Response {
    render_json_response(reply, None)
}
impl AsRef<[u8]> for ResponseBytes {
    fn as_ref(&self) -> &[u8] {
        &self.bytes
    }
}
fn json_response(
    reply: super::receipts::ReceiptResponse,
    permit: tokio::sync::OwnedSemaphorePermit,
) -> Response {
    render_json_response(reply, Some(permit))
}
fn render_json_response(
    mut reply: super::receipts::ReceiptResponse,
    permit: Option<tokio::sync::OwnedSemaphorePermit>,
) -> Response {
    if let Some(receipt) = reply.receipt {
        let Some(body) = reply.body.as_object_mut() else {
            return error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "worker",
                "invalid terminal response",
            );
        };
        let receipt = match serde_json::to_value(receipt) {
            Ok(value) => value,
            Err(_) => {
                return error(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "worker",
                    "invalid terminal response",
                )
            }
        };
        body.insert("receipt".into(), receipt);
    }
    let bytes = match super::api::bounded_json(&reply.body) {
        Ok(bytes) => bytes,
        Err(error) => {
            return match super::receipts::refusal(&error) {
                Some(reply) => render_json_response(reply, permit),
                None => ServiceError::Storage(error).into_response(),
            }
        }
    };
    match StatusCode::from_u16(reply.status) {
        Ok(status) => (
            status,
            [("content-type", "application/json")],
            axum::body::Body::from(axum::body::Bytes::from_owner(ResponseBytes {
                bytes,
                _permit: permit,
            })),
        )
            .into_response(),
        Err(_) => error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "worker",
            "invalid response status",
        ),
    }
}
