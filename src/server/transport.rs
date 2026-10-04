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
use tokio::sync::Semaphore;

pub const MAX_BODY_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_OPERATIONS: usize = 8;

#[derive(Clone)]
pub struct ServiceState {
    server: Arc<OwnedServer>,
    operations: Arc<Semaphore>,
    draining: Arc<AtomicBool>,
    logs: super::request_log::RequestLogs,
}
impl ServiceState {
    pub fn new(server: OwnedServer) -> Self {
        Self {
            server: Arc::new(server),
            operations: Arc::new(Semaphore::new(MAX_OPERATIONS)),
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
impl IntoResponse for ServiceError {
    fn into_response(self) -> Response {
        let (status, code) = match &self {
            Self::Unauthorized(_) => (StatusCode::UNAUTHORIZED, "authentication"),
            Self::Clock => (StatusCode::UNAUTHORIZED, "clock_window"),
            Self::Capacity => (StatusCode::SERVICE_UNAVAILABLE, "capacity"),
            Self::Validation(_) => (StatusCode::BAD_REQUEST, "validation"),
            Self::Storage(crate::AppError::Busy(_) | crate::AppError::LockTimeout(_)) => {
                (StatusCode::SERVICE_UNAVAILABLE, "lock_timeout")
            }
            Self::Storage(_) => (StatusCode::INTERNAL_SERVER_ERROR, "storage"),
        };
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
            _permit: permit,
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
    let mutation = is_mutation(request.method(), request.uri());
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
        Ok((Ok(reply), permit)) => json_response(reply, permit),
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
    _permit: tokio::sync::OwnedSemaphorePermit,
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
    let bytes = match super::api::bounded_json(&reply.body) {
        Ok(bytes) => bytes,
        Err(error) => {
            return match super::receipts::refusal(&error) {
                Some(reply) => json_response(reply, permit),
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
