//! One synchronous authenticated client. Writes are never automatically retried.
use super::{
    config::Profile,
    credentials,
    https::{ClientError, ClientOptions, HttpResponse, HttpsClient},
    pending::{PendingStore, PendingWrite},
    protocol::ApiOutput,
    signing::SigningIdentity,
};
use crate::AppError;
use http::Method;
use serde_json::Value;
use std::{path::Path, time::Duration};
use uuid::Uuid;

pub struct RemoteClient {
    pub http: HttpsClient,
    pub server_id: Uuid,
    pub credential_id: Uuid,
}
pub fn transport_error(error: ClientError) -> AppError {
    let code = match error {
        ClientError::Configuration(_) => "remote_configuration",
        ClientError::Transport => "service_unavailable",
        ClientError::Redirect => "remote_redirect",
        ClientError::ResponseLimit => "remote_response_limit",
        ClientError::Export => "remote_export",
        ClientError::Signature => "remote_signature",
    };
    AppError::Remote {
        code,
        message: error.to_string(),
        request_id: None,
    }
}
fn invalid_reply() -> AppError {
    AppError::Remote {
        code: "remote_protocol",
        message: "invalid server response; check client/server protocol compatibility".into(),
        request_id: None,
    }
}

fn credential_error(error: AppError) -> AppError {
    use std::io::ErrorKind;
    let detail = match &error {
        AppError::Io(cause)
            if cfg!(windows) && matches!(cause.raw_os_error(), Some(32 | 33)) =>
        {
            "key file is locked by another process; wait for the key writer or rotation to finish, then retry the command".into()
        }
        AppError::Io(cause) if cause.kind() == ErrorKind::NotFound => {
            "key file or parent directory is missing; check credential_file in client.toml and restore the protected installation key".into()
        }
        AppError::Io(cause) if cause.kind() == ErrorKind::PermissionDenied => {
            "access to the key file or parent directory was denied; check owner-only file and directory permissions for the current user".into()
        }
        AppError::Io(cause) if cause.kind() == ErrorKind::InvalidData => {
            "key encoding is not valid UTF-8; restore a valid Ed25519 PKCS#8 PEM installation key".into()
        }
        // These causes contain validation/OS diagnostics, never key contents.
        // Preserve ACL, reparse, PEM and size refusals instead of masking them.
        _ => format!("{error}; restore a valid Ed25519 PKCS#8 PEM key of at most 16 KiB and use owner-only file and directory permissions"),
    };
    AppError::Remote {
        code: "remote_credential",
        message: format!("cannot load the protected installation key: {detail}"),
        request_id: None,
    }
}
pub fn parse_reply(reply: HttpResponse) -> Result<Value, AppError> {
    let value: Value = serde_json::from_slice(&reply.body).map_err(|_| invalid_reply())?;
    parse_value(reply.status, value)
}
fn parse_value(status: u16, mut value: Value) -> Result<Value, AppError> {
    if let Some(body) = value.as_object_mut() {
        body.remove("receipt");
    }
    if status == 200 {
        return Ok(value);
    }
    let message = value
        .get("error")
        .and_then(|e| e.get("message"))
        .and_then(Value::as_str)
        .filter(|s| s.len() <= 4096)
        .ok_or_else(invalid_reply)?
        .to_string();
    if let Some(error) = legacy_protocol_error(status, &value) {
        return Err(error);
    }
    if status == 426 {
        return match value["error"]["code"].as_str() {
            Some("client_upgrade_required") => Err(AppError::ClientUpgradeRequired(message)),
            Some("server_upgrade_required") => Err(AppError::ServerUpgradeRequired(message)),
            _ => Err(invalid_reply()),
        };
    }
    let exit_code = match status {
        400 | 413 => 2,
        404 => 3,
        409 => 4,
        _ => 5,
    };
    Err(AppError::RemoteReply {
        message,
        payload: value,
        exit_code,
    })
}

/// Protocol-1 servers predate version admission. Their restricted signature
/// verifier rejects the new covered component before any application dispatch.
/// Recognize only that specific refusal, never a generic authentication error.
fn legacy_protocol_error(status: u16, value: &Value) -> Option<AppError> {
    (status == 401
        && value["error"]["code"] == "authentication"
        && value["error"]["message"] == "authentication failed: unexpected signed components")
        .then(|| AppError::ServerUpgradeRequired(format!(
            "update required: client protocol {}; server uses the protocol-1 signature profile; update tasks-server before using this client",
            super::signing::PROTOCOL_VERSION
        )))
}
pub fn api_output(value: Value) -> Result<ApiOutput, AppError> {
    let result: ApiOutput = serde_json::from_value(value).map_err(|_| invalid_reply())?;
    if result.output["schema_version"] != 1 || !result.output["data"].is_object() {
        return Err(invalid_reply());
    }
    Ok(result)
}
impl RemoteClient {
    pub fn new(profile: &Profile) -> Result<Self, AppError> {
        let Profile::Remote {
            server_url,
            server_id,
            credential_id,
            credential_file,
            private_ca,
            connect_timeout_seconds,
            request_timeout_seconds,
        } = profile
        else {
            return Err(invalid_reply());
        };
        profile.validate()?;
        let key = credentials::load_key(credential_file).map_err(credential_error)?;
        let identity = SigningIdentity {
            server_id: *server_id,
            credential_id: *credential_id,
            key,
        };
        let http = HttpsClient::new(
            server_url,
            ClientOptions {
                private_ca: private_ca.clone(),
                connect_timeout: Duration::from_secs(*connect_timeout_seconds),
                request_timeout: Duration::from_secs(*request_timeout_seconds),
            },
            identity,
        )
        .map_err(transport_error)?;
        Ok(Self {
            http,
            server_id: *server_id,
            credential_id: *credential_id,
        })
    }
    /// Explicit setup probes the live identity/readiness once. Ordinary
    /// commands rely on signed per-request protocol and server UUID admission.
    pub fn info(&self) -> Result<Value, AppError> {
        let reply = self.read(Method::GET, "/v1/info", b"")?;
        if reply["server_id"].as_str() != Some(self.server_id.to_string().as_str())
            || reply["ready"] != true
        {
            return Err(invalid_reply());
        }
        let version = |value: &Value| {
            value
                .as_u64()
                .and_then(|v| u32::try_from(v).ok())
                .ok_or_else(invalid_reply)
        };
        let latest = version(&reply["protocol_version"])?;
        let (min, max) = match (
            reply.get("min_protocol_version"),
            reply.get("max_protocol_version"),
        ) {
            (None, None) => (latest, latest),
            (Some(min), Some(max)) => (version(min)?, version(max)?),
            _ => return Err(invalid_reply()),
        };
        if min > max || !(min..=max).contains(&latest) {
            return Err(invalid_reply());
        }
        let client = super::signing::PROTOCOL_VERSION;
        if client < min {
            return Err(AppError::ClientUpgradeRequired(format!(
                "update required: client protocol {client}; server supports protocols {min}..={max}; update the tasks CLI and viewer before retrying"
            )));
        }
        if client > max {
            return Err(AppError::ServerUpgradeRequired(format!(
                "update required: client protocol {client}; server supports protocols {min}..={max}; update tasks-server before using this client"
            )));
        }
        Ok(reply)
    }
    pub fn read(&self, method: Method, target: &str, payload: &[u8]) -> Result<Value, AppError> {
        parse_reply(
            self.http
                .send(method, target, payload, None)
                .map_err(transport_error)?,
        )
    }
    pub fn transfer_timeout(&self, body_bytes: u64, original_bytes: u64) -> Duration {
        Duration::from_secs(
            self.http
                .request_timeout
                .as_secs()
                .saturating_add(body_bytes.div_ceil(128 * 1024))
                .saturating_add(original_bytes.div_ceil(32 * 1024 * 1024))
                .min(600),
        )
    }
    pub fn write_binary(
        &self,
        root: &Path,
        target: &str,
        body: &[u8],
        request_id: Option<Uuid>,
    ) -> Result<ApiOutput, AppError> {
        let store = PendingStore::new(root)?;
        let _lock = store.lock()?;
        if !store.list()?.is_empty() {
            return Err(AppError::Remote {
                code: "pending_write",
                message: "a previous write needs reconciliation; run tasks remote pending".into(),
                request_id: None,
            });
        }
        let mut request = PendingWrite::binary(self.server_id, self.credential_id, target, body)?;
        if let Some(id) = request_id {
            request.request_id = id;
        }
        store.save_binary(&request, body)?;
        self.send_pending(&store, &request, request_id.is_some(), true)
    }
    pub fn write(
        &self,
        root: &Path,
        method: Method,
        target: &str,
        payload: Value,
    ) -> Result<ApiOutput, AppError> {
        self.write_inner(root, method, target, payload, None, false)
    }
    pub fn write_retained(
        &self,
        root: &Path,
        method: Method,
        target: &str,
        payload: Value,
        request_id: Uuid,
    ) -> Result<ApiOutput, AppError> {
        self.write_inner(root, method, target, payload, Some(request_id), true)
    }
    fn write_inner(
        &self,
        root: &Path,
        method: Method,
        target: &str,
        payload: Value,
        request_id: Option<Uuid>,
        retain: bool,
    ) -> Result<ApiOutput, AppError> {
        let store = PendingStore::new(root)?;
        let _lock = store.lock()?;
        if !store.list()?.is_empty() {
            return Err(AppError::Remote { code:"pending_write", message:"a previous write needs reconciliation; run tasks remote pending before another mutation".into(), request_id:None });
        }
        let mut request = PendingWrite::new(
            self.server_id,
            self.credential_id,
            method.as_str(),
            target,
            payload,
        )?;
        if let Some(id) = request_id {
            request.request_id = id;
        }
        store.save(&request)?;
        self.send_pending(&store, &request, retain, true)
    }
    pub fn reconcile(&self, root: &Path, id: Uuid) -> Result<ApiOutput, AppError> {
        let store = PendingStore::new(root)?;
        let _lock = store.lock()?;
        let request = store.load(id)?;
        request.check_destination(self.server_id, self.credential_id)?;
        self.send_pending(&store, &request, false, false)
    }
    pub fn reconcile_retained(&self, root: &Path, id: Uuid) -> Result<ApiOutput, AppError> {
        let store = PendingStore::new(root)?;
        let _lock = store.lock()?;
        let request = store.load(id)?;
        request.check_destination(self.server_id, self.credential_id)?;
        self.send_pending(&store, &request, true, false)
    }
    pub fn acknowledge(&self, root: &Path, id: Uuid) -> Result<(), AppError> {
        let store = PendingStore::new(root)?;
        let _lock = store.lock()?;
        let request = store.load(id)?;
        request.check_destination(self.server_id, self.credential_id)?;
        store.acknowledge(&request)
    }
    fn send_pending(
        &self,
        store: &PendingStore,
        request: &PendingWrite,
        retain: bool,
        fresh: bool,
    ) -> Result<ApiOutput, AppError> {
        request.check_destination(self.server_id, self.credential_id)?;
        // Diagnostic categories must be fixed literals, never error Display
        // text: deserialization and I/O errors can include private input.
        let unknown = |_stage: &'static str, _category: &'static str| {
            let message = format!("write outcome is unknown; run tasks remote reconcile {} with this profile before another mutation", request.request_id);
            #[cfg(feature = "test-hooks")]
            let message = format!("{message} [stage={_stage}: {_category}]");
            AppError::Remote {
                code: "unknown_write_outcome",
                message,
                request_id: Some(request.request_id),
            }
        };
        let method = Method::from_bytes(request.method.as_bytes()).map_err(|_| invalid_reply())?;
        let reply = if request.body.is_some() {
            let body = store.load_body(request)?;
            // A retained terminal refusal may itself be malformed. Replay exact
            // verified bytes; use the maximum original budget for its deadline.
            let originals = crate::attachment::frame::preflight_upload(
                &body,
                &crate::attachment::Limits::PRODUCTION,
            )
            .map_or(
                crate::attachment::Limits::PRODUCTION.batch_original_bytes,
                |frame| frame.metadata.items.iter().map(|i| i.original_size).sum(),
            );
            self.http.send_binary(
                method,
                &request.target,
                &body,
                "application/octet-stream",
                Some(request.request_id),
                crate::attachment::frame::MAX_UPLOAD_BYTES,
                16 * 1024 * 1024,
                self.transfer_timeout(body.len() as u64, originals),
            )
        } else {
            self.http.send(
                method,
                &request.target,
                &request.bytes()?,
                Some(request.request_id),
            )
        }
        .map_err(|_| unknown("transport", "transport"))?;
        let value: Value = serde_json::from_slice(&reply.body)
            .map_err(|_| unknown("response_json", "malformed_response_json"))?;
        if let Some(AppError::ServerUpgradeRequired(message)) =
            legacy_protocol_error(reply.status, &value)
        {
            // A legacy reply has no request-bound marker. Preserve the pending
            // evidence, including on reconciliation, even for this known refusal.
            return Err(AppError::ServerUpgradeRequired(format!("{message}; pending evidence retained: after updating, run tasks remote reconcile {}", request.request_id)));
        }
        let receipt: super::protocol::RequestReceipt = serde_json::from_value(
            value
                .get("receipt")
                .cloned()
                .ok_or_else(|| unknown("receipt_missing", "missing_receipt"))?,
        )
        .map_err(|_| unknown("receipt_json", "malformed_receipt_json"))?;
        if receipt.request_id != request.request_id
            || receipt.route != format!("{} {}", request.method, request.target)
            || receipt.payload_sha256 != request.payload_sha256()?
            || receipt.status != reply.status
            || !matches!(reply.status, 200 | 400 | 404 | 409 | 413 | 426)
        {
            return Err(unknown("receipt_validation", "receipt_mismatch"));
        }
        if reply.status == 426 {
            let error = match parse_value(reply.status, value) {
                Err(
                    error @ (AppError::ClientUpgradeRequired(_)
                    | AppError::ServerUpgradeRequired(_)),
                ) => error,
                _ => return Err(unknown("upgrade_refusal", "invalid_upgrade_refusal")),
            };
            if fresh {
                store
                    .remove(request.request_id)
                    .map_err(|_| unknown("remove_upgrade_refusal", "pending_store"))?;
            }
            // Reconciliation may concern a previously committed request. A
            // pre-admission refusal cannot resolve that earlier outcome.
            return Err(error);
        }
        match parse_value(reply.status, value) {
            Ok(value) => {
                let output =
                    api_output(value).map_err(|_| unknown("api_output", "malformed_api_output"))?;
                if retain {
                    store
                        .confirm(request, &receipt)
                        .map_err(|_| unknown("confirm_success", "pending_store"))?;
                } else {
                    store
                        .remove(request.request_id)
                        .map_err(|_| unknown("remove_success", "pending_store"))?;
                }
                Ok(output)
            }
            Err(error @ AppError::RemoteReply { .. }) => {
                if retain {
                    store
                        .confirm(request, &receipt)
                        .map_err(|_| unknown("confirm_refusal", "pending_store"))?;
                } else {
                    store
                        .remove(request.request_id)
                        .map_err(|_| unknown("remove_refusal", "pending_store"))?;
                }
                Err(error)
            }
            Err(_) => Err(unknown("response_value", "invalid_response_value")),
        }
    }
}
