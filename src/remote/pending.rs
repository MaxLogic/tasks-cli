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
                        ("POST", "tasks") | ("PUT", "rules") | ("PUT", "key")
                    )
            }
            ("PATCH", ["", "v1", "projects", project, "tasks", task]) => {
                Uuid::parse_str(project).is_ok_and(|id| !id.is_nil() && id.to_string() == *project)
                    && task
                        .parse::<u64>()
                        .is_ok_and(|id| id > 0 && id <= i64::MAX as u64 && id.to_string() == *task)
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
