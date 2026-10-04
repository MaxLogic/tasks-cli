//! Recovery evidence for one explicit request, never an automatic offline queue.
use crate::{private_fs, AppError};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
};
use uuid::Uuid;
const MAX_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PendingWrite {
    pub format_version: u32,
    pub request_id: Uuid,
    pub server_id: Uuid,
    pub credential_id: Uuid,
    pub method: String,
    pub target: String,
    pub payload: Value,
}
fn invalid() -> AppError {
    AppError::Remote { code: "pending_request", message: "invalid pending request; preserve it for inspection and use its original server and credential".into(), request_id: None }
}
impl PendingWrite {
    pub fn new(
        server_id: Uuid,
        credential_id: Uuid,
        method: &str,
        target: &str,
        payload: Value,
    ) -> Result<Self, AppError> {
        let value = Self {
            format_version: 1,
            request_id: Uuid::new_v4(),
            server_id,
            credential_id,
            method: method.into(),
            target: target.into(),
            payload,
        };
        value.validate()?;
        Ok(value)
    }
    fn validate(&self) -> Result<(), AppError> {
        let parts = self.target.split('/').collect::<Vec<_>>();
        let valid = match (self.method.as_str(), parts.as_slice()) {
            ("POST", ["", "v1", "projects"]) => true,
            (method, ["", "v1", "projects", project, resource]) => {
                let canonical = Uuid::parse_str(project)
                    .is_ok_and(|id| !id.is_nil() && id.to_string() == *project);
                canonical
                    && matches!(
                        (method, *resource),
                        ("POST", "tasks") | ("PUT", "rules") | ("PUT", "key") | ("PUT", "archive")
                    )
            }
            ("PATCH", ["", "v1", "projects", project, "tasks", task]) => {
                Uuid::parse_str(project).is_ok_and(|id| !id.is_nil() && id.to_string() == *project)
                    && task
                        .parse::<u64>()
                        .is_ok_and(|id| id > 0 && id <= i64::MAX as u64 && id.to_string() == *task)
            }
            ("PATCH", ["", "v1", "projects", project, "viewer", "update"]) => {
                Uuid::parse_str(project).is_ok_and(|id| !id.is_nil() && id.to_string() == *project)
            }
            _ => false,
        };
        if !valid
            || self.format_version != 1
            || self.request_id.is_nil()
            || self.server_id.is_nil()
            || self.credential_id.is_nil()
            || !self.payload.is_object()
            || self.bytes()?.len() > MAX_BYTES as usize
        {
            return Err(invalid());
        }
        Ok(())
    }
    pub fn bytes(&self) -> Result<Vec<u8>, AppError> {
        Ok(serde_json::to_vec(&self.payload)?)
    }
    pub fn check_destination(&self, server_id: Uuid, credential_id: Uuid) -> Result<(), AppError> {
        self.validate()?;
        if self.server_id != server_id || self.credential_id != credential_id {
            return Err(invalid());
        }
        Ok(())
    }
}
pub struct PendingStore {
    root: PathBuf,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfirmationRecord {
    format_version: u32,
    server_id: Uuid,
    credential_id: Uuid,
    receipt: super::protocol::RequestReceipt,
}
impl PendingStore {
    pub fn lock(&self) -> Result<crate::storage::ExclusiveLock, AppError> {
        crate::storage::acquire_exclusive_lock(
            &self.root.parent().ok_or_else(invalid)?.join("client.lock"),
        )
    }
    pub fn new(root: &Path) -> Result<Self, AppError> {
        let private = root.join("client");
        private_fs::create_dir(&private)?;
        let pending = private.join("pending");
        private_fs::create_dir(&pending)?;
        Ok(Self { root: pending })
    }
    fn path(&self, id: Uuid) -> PathBuf {
        self.root.join(format!("{id}.json"))
    }
    pub fn save(&self, request: &PendingWrite) -> Result<(), AppError> {
        request.validate()?;
        if std::fs::symlink_metadata(self.root.join(format!("{}.confirmed", request.request_id)))
            .is_ok()
        {
            return Err(AppError::Usage(
                "this request UUID already has confirmation evidence; choose a fresh request UUID"
                    .into(),
            ));
        }
        let bytes = serde_json::to_vec(request)?;
        if bytes.len() > MAX_BYTES as usize + 16_384 {
            return Err(invalid());
        }
        let path = self.path(request.request_id);
        let temporary = self.root.join(format!(".pending-{}.tmp", Uuid::new_v4()));
        let result = (|| {
            let mut file = private_fs::create_file(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            drop(file);
            #[cfg(windows)]
            atomicwrites::move_atomic(&temporary, &path)?;
            #[cfg(unix)]
            {
                std::fs::hard_link(&temporary, &path)?;
                std::fs::remove_file(&temporary)?;
                std::fs::File::open(&self.root)?.sync_all()?;
            }
            Ok(())
        })();
        if temporary.exists() {
            let _ = std::fs::remove_file(&temporary);
        }
        result
    }
    pub fn load(&self, id: Uuid) -> Result<PendingWrite, AppError> {
        let mut bytes = Vec::new();
        private_fs::open_file(&self.path(id))?
            .take(MAX_BYTES + 16_385)
            .read_to_end(&mut bytes)?;
        if bytes.len() > MAX_BYTES as usize + 16_384 {
            return Err(invalid());
        }
        let request: PendingWrite = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
        if request.request_id != id {
            return Err(invalid());
        }
        request.validate()?;
        Ok(request)
    }
    pub fn list(&self) -> Result<Vec<Uuid>, AppError> {
        private_fs::validate_dir(&self.root)?;
        let mut ids = Vec::new();
        for entry in std::fs::read_dir(&self.root)? {
            let entry = entry?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            let Some(stem) = name.strip_suffix(".json") else {
                continue;
            };
            let id = Uuid::parse_str(stem).map_err(|_| invalid())?;
            if id.to_string() != stem || ids.len() >= 10_000 {
                return Err(invalid());
            }
            ids.push(id);
        }
        ids.sort_unstable();
        Ok(ids)
    }
    pub fn remove(&self, id: Uuid) -> Result<(), AppError> {
        self.load(id)?;
        remove_completed(&self.path(id), || {
            #[cfg(unix)]
            std::fs::File::open(&self.root)?.sync_all()?;
            Ok(())
        })
    }

    /// Persist terminal transport evidence before the frontend can see stdout.
    /// It does not authorize another request or contain a task body.
    pub fn confirm(
        &self,
        request: &PendingWrite,
        receipt: &super::protocol::RequestReceipt,
    ) -> Result<(), AppError> {
        validate_confirmation(request, receipt)?;
        let path = self.root.join(format!("{}.confirmed", request.request_id));
        if path.try_exists()? {
            if self.confirmation(request)?.as_ref() == Some(receipt) {
                return Ok(());
            }
            return Err(invalid());
        }
        let bytes = serde_json::to_vec(&ConfirmationRecord {
            format_version: 1,
            server_id: request.server_id,
            credential_id: request.credential_id,
            receipt: receipt.clone(),
        })?;
        let temporary = self.root.join(format!(".confirmed-{}.tmp", Uuid::new_v4()));
        let result = (|| {
            let mut file = private_fs::create_file(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            drop(file);
            #[cfg(windows)]
            atomicwrites::move_atomic(&temporary, &path)?;
            #[cfg(unix)]
            {
                std::fs::hard_link(&temporary, &path)?;
                std::fs::remove_file(&temporary)?;
                std::fs::File::open(&self.root)?.sync_all()?;
            }
            Ok(())
        })();
        let _ = std::fs::remove_file(&temporary);
        result
    }
    pub fn confirmation(
        &self,
        request: &PendingWrite,
    ) -> Result<Option<super::protocol::RequestReceipt>, AppError> {
        let path = self.root.join(format!("{}.confirmed", request.request_id));
        match std::fs::symlink_metadata(&path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
            Ok(_) => (),
        }
        let mut bytes = Vec::new();
        private_fs::open_file(&path)?
            .take(16_385)
            .read_to_end(&mut bytes)?;
        if bytes.len() > 16_384 {
            return Err(invalid());
        }
        let record: ConfirmationRecord = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
        if record.format_version != 1
            || record.server_id != request.server_id
            || record.credential_id != request.credential_id
        {
            return Err(invalid());
        }
        validate_confirmation(request, &record.receipt)?;
        Ok(Some(record.receipt))
    }
    pub fn acknowledge(&self, request: &PendingWrite) -> Result<(), AppError> {
        if self.confirmation(request)?.is_none() {
            return Err(AppError::Remote {code:"unknown_write_outcome", message:"the original request has no confirmed outcome; check the pending change before acknowledging it".into(), request_id:Some(request.request_id)});
        }
        self.remove(request.request_id)?;
        let _ = std::fs::remove_file(self.root.join(format!("{}.confirmed", request.request_id)));
        Ok(())
    }
}
fn validate_confirmation(
    request: &PendingWrite,
    receipt: &super::protocol::RequestReceipt,
) -> Result<(), AppError> {
    request.validate()?;
    if receipt.request_id != request.request_id
        || receipt.route != format!("{} {}", request.method, request.target)
        || receipt.payload_sha256 != crate::markdown::sha256(&request.bytes()?)
        || !matches!(receipt.status, 200 | 400 | 404 | 409 | 413)
    {
        return Err(invalid());
    }
    Ok(())
}
fn remove_completed(
    path: &Path,
    sync_directory: impl FnOnce() -> std::io::Result<()>,
) -> Result<(), AppError> {
    std::fs::remove_file(path)?;
    // The terminal server result is already known. Failed directory sync may
    // resurrect this same receipt after a crash; reconciling it is safe. It must
    // not report an unknown outcome after the only recovery file was unlinked.
    let _ = sync_directory();
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn confirmation_cannot_acknowledge_the_same_payload_on_another_authority() {
        let root = tempfile::tempdir().unwrap();
        let store = PendingStore::new(root.path()).unwrap();
        let mut request = PendingWrite::new(
            Uuid::new_v4(),
            Uuid::new_v4(),
            "POST",
            "/v1/projects",
            serde_json::json!({"project_id":Uuid::new_v4()}),
        )
        .unwrap();
        store.save(&request).unwrap();
        let receipt = super::super::protocol::RequestReceipt {
            request_id: request.request_id,
            route: "POST /v1/projects".into(),
            payload_sha256: crate::markdown::sha256(&request.bytes().unwrap()),
            status: 200,
        };
        store.confirm(&request, &receipt).unwrap();
        assert!(store.confirmation(&request).unwrap().is_some());
        request.server_id = Uuid::new_v4();
        assert!(store.confirmation(&request).is_err());
        assert!(store.acknowledge(&request).is_err());
        assert_eq!(store.list().unwrap(), vec![request.request_id]);
    }
    #[test]
    fn post_unlink_sync_failure_does_not_report_an_unknown_outcome_without_evidence() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("confirmed.json");
        std::fs::write(&path, b"confirmed").unwrap();
        let removed = remove_completed(&path, || {
            Err(std::io::Error::other("injected directory sync failure"))
        });
        assert!(removed.is_ok());
        assert!(!path.exists());
    }
    #[test]
    fn unlink_failure_keeps_recovery_evidence() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("confirmed.json");
        std::fs::create_dir(&path).unwrap();
        assert!(remove_completed(&path, || Ok(())).is_err());
        assert!(path.exists());
    }
}
