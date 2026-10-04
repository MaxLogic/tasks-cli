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
        let key = credentials::load_key(credential_file).map_err(|_| AppError::Remote { code: "remote_credential", message: "cannot load the protected installation key; check its file permissions and encoding".into(), request_id: None })?;
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
    pub fn info(&self) -> Result<Value, AppError> {
        let reply = parse_reply(
            self.http
                .send(Method::GET, "/v1/info", b"", None)
                .map_err(transport_error)?,
        )?;
        if reply["server_id"].as_str() != Some(self.server_id.to_string().as_str())
            || reply["ready"] != true
            || !reply["capabilities"]
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
    pub fn read(&self, method: Method, target: &str, payload: &[u8]) -> Result<Value, AppError> {
        parse_reply(
            self.http
                .send(method, target, payload, None)
                .map_err(transport_error)?,
        )
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
        // Online preflight avoids collecting unsent work during a known outage.
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
        let unknown = || {
            AppError::Remote { code:"unknown_write_outcome", message:format!("write outcome is unknown; run tasks remote reconcile {} with this profile before another mutation",request.request_id), request_id:Some(request.request_id) }
        };
        let method = Method::from_bytes(request.method.as_bytes()).map_err(|_| invalid_reply())?;
        let reply = self
            .http
            .send(
                method,
                &request.target,
                &request.bytes()?,
                Some(request.request_id),
            )
            .map_err(|_| unknown())?;
        let value: Value = serde_json::from_slice(&reply.body).map_err(|_| unknown())?;
        let receipt: super::protocol::RequestReceipt =
            serde_json::from_value(value.get("receipt").cloned().ok_or_else(unknown)?)
                .map_err(|_| unknown())?;
        if receipt.request_id != request.request_id
            || receipt.route != format!("{} {}", request.method, request.target)
            || receipt.payload_sha256 != crate::markdown::sha256(&request.bytes()?)
            || receipt.status != reply.status
            || !matches!(reply.status, 200 | 400 | 404 | 409 | 413)
        {
            return Err(unknown());
        }
        match parse_value(reply.status, value) {
            Ok(value) => {
                let output = api_output(value).map_err(|_| unknown())?;
                if retain {
                    store.confirm(request, &receipt).map_err(|_| unknown())?;
                } else {
                    store.remove(request.request_id).map_err(|_| unknown())?;
                }
                Ok(output)
            }
            Err(error @ AppError::RemoteReply { .. }) => {
                if retain {
                    store.confirm(request, &receipt).map_err(|_| unknown())?;
                } else {
                    store.remove(request.request_id).map_err(|_| unknown())?;
                }
                Err(error)
            }
            Err(_) => Err(unknown()),
        }
    }
}
