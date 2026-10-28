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
    capabilities: Option<super::capabilities::Capabilities>,
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
            capabilities: None,
        })
    }
    pub(super) fn with_state(profile: &Profile, root: &Path) -> Result<Self, AppError> {
        let mut client = Self::new(profile)?;
        client.capabilities =
            super::capabilities::Capabilities::new(root, profile, &client.http.private_ca_sha256)
                .ok();
        Ok(client)
    }
    pub(super) fn remember_capabilities(&self, root: &Path, profile: &Profile, info: &Value) {
        if let Ok(cache) =
            super::capabilities::Capabilities::new(root, profile, &self.http.private_ca_sha256)
        {
            cache.save(info);
        }
    }
    fn service_info(&self) -> Result<Value, AppError> {
        if let Some(cache) = &self.capabilities {
            if let Some(info) = cache.get() {
                if let Ok(info) = self.validate_info(info) {
                    return Ok(info);
                }
            }
        }
        let reply = parse_reply(
            self.http
                .send(Method::GET, "/v1/info", b"", None)
                .map_err(transport_error)?,
        )?;
        let reply = self.validate_info(reply)?;
        if let Some(cache) = &self.capabilities {
            cache.save(&reply);
        }
        Ok(reply)
    }
    fn validate_info(&self, reply: Value) -> Result<Value, AppError> {
        if reply["server_id"].as_str() != Some(self.server_id.to_string().as_str())
            || reply["ready"] != true
            || reply["protocol_version"] != 1
            || reply.get("capabilities").is_some_and(|value| {
                !value
                    .as_array()
                    .is_some_and(|items| items.iter().all(Value::is_string))
            })
        {
            return Err(invalid_reply());
        }
        Ok(reply)
    }
    /// Valid discovery retains the request-bound receipt gate. Configure uses
    /// an uncached client so explicit setup always checks the live server.
    pub fn info(&self) -> Result<Value, AppError> {
        let reply = self.service_info()?;
        if !reply["capabilities"]
            .as_array()
            .is_some_and(|capabilities| {
                capabilities
                    .iter()
                    .any(|value| value == "request-bound-receipts")
            })
        {
            return Err(invalid_reply());
        }
        Ok(reply)
    }
    /// Advertisement discovery is read-only. Legacy servers may omit this
    /// field entirely; that means no advertised capabilities, not receipt safety.
    pub fn has_attachment_capability(&self) -> Result<bool, AppError> {
        let reply = self.service_info()?;
        match reply.get("capabilities") {
            None => Ok(false),
            Some(Value::Array(items)) => Ok(items.iter().any(|v| v == "attachments-v1")),
            Some(_) => Err(invalid_reply()),
        }
    }
    pub fn read(&self, method: Method, target: &str, payload: &[u8]) -> Result<Value, AppError> {
        parse_reply(
            self.http
                .send(method, target, payload, None)
                .map_err(transport_error)?,
        )
    }
    pub fn require_attachments(&self) -> Result<(), AppError> {
        if !self.has_attachment_capability()? {
            return Err(AppError::Remote { code:"remote_capability", message:"server does not support attachments-v1; upgrade the server before using attachments".into(), request_id:None });
        }
        Ok(())
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
        self.require_attachments()?;
        // Advertisement discovery deliberately permits receipt-less legacy
        // reads; a new binary mutation still requires safe receipt recovery.
        self.info()?;
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
        self.send_pending(&store, &request, request_id.is_some())
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
        // Require live or unexpired discovery before saving or sending work.
        // A later outage still follows the existing unknown-outcome recovery.
        self.info()?;
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
        self.send_pending(&store, &request, retain)
    }
    pub fn reconcile(&self, root: &Path, id: Uuid) -> Result<ApiOutput, AppError> {
        let store = PendingStore::new(root)?;
        let _lock = store.lock()?;
        let request = store.load(id)?;
        request.check_destination(self.server_id, self.credential_id)?;
        self.send_pending(&store, &request, false)
    }
    pub fn reconcile_retained(&self, root: &Path, id: Uuid) -> Result<ApiOutput, AppError> {
        let store = PendingStore::new(root)?;
        let _lock = store.lock()?;
        let request = store.load(id)?;
        request.check_destination(self.server_id, self.credential_id)?;
        self.send_pending(&store, &request, true)
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
            || !matches!(reply.status, 200 | 400 | 404 | 409 | 413)
        {
            return Err(unknown("receipt_validation", "receipt_mismatch"));
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
