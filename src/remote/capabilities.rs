//! Short-lived, private discovery evidence, never a replacement for write receipts.
use super::config::Profile;
use crate::{private_fs, AppError};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    cell::RefCell,
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_BYTES: u64 = 64 * 1024;
const TTL_SECONDS: u64 = 60;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Discovery {
    format_version: u32,
    profile_sha256: String,
    checked_at: u64,
    info: Value,
}

pub(super) struct Capabilities {
    path: PathBuf,
    profile_sha256: String,
    memory: RefCell<Option<Discovery>>,
}

pub(super) fn invalidate(root: &Path) -> Result<(), AppError> {
    match std::fs::remove_file(root.join("client/capabilities.json")) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

pub(super) fn invalidate_on_error<T>(
    root: &Path,
    result: Result<T, AppError>,
) -> Result<T, AppError> {
    if let Err(error) = result {
        if invalidate(root).is_err() {
            // Preserve unknown-outcome identity even if cache cleanup also fails.
            let request_id = match &error {
                AppError::Remote { request_id, .. } => *request_id,
                _ => None,
            };
            return Err(AppError::Remote {
                code: "remote_cache",
                message: format!("{error}; capability cache could not be cleared; remove client/capabilities.json from this data root before another remote command"),
                request_id,
            });
        }
        return Err(error);
    }
    result
}

fn now() -> Option<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|v| v.as_secs())
}

impl Capabilities {
    pub fn new(root: &Path, profile: &Profile) -> Result<Self, AppError> {
        // Bind identity, endpoint, credential paths and trust configuration.
        // A CA replacement at the same path must also force fresh discovery.
        let ca_hash = match profile {
            Profile::Remote {
                private_ca: Some(path),
                ..
            } => {
                let mut bytes = Vec::new();
                std::fs::File::open(path)?
                    .take(262145)
                    .read_to_end(&mut bytes)?;
                crate::markdown::sha256(&bytes)
            }
            _ => String::new(),
        };
        Ok(Self {
            path: root.join("client/capabilities.json"),
            profile_sha256: crate::markdown::sha256(&serde_json::to_vec(&(profile, ca_hash))?),
            memory: RefCell::new(None),
        })
    }

    pub fn get(&self) -> Result<Option<Value>, AppError> {
        let discovery = match self.memory.borrow().clone() {
            Some(value) => Some(value),
            None => match private_fs::open_file(&self.path) {
                Ok(file) => {
                    let mut bytes = Vec::new();
                    file.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
                    if bytes.len() as u64 > MAX_BYTES {
                        None
                    } else {
                        serde_json::from_slice(&bytes).ok()
                    }
                }
                Err(AppError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => None,
                Err(error) => return Err(error),
            },
        };
        let Some(discovery) = discovery else {
            return Ok(None);
        };
        if discovery.format_version != 1
            || discovery.profile_sha256 != self.profile_sha256
            || !now()
                .and_then(|time| time.checked_sub(discovery.checked_at))
                .is_some_and(|age| age < TTL_SECONDS)
        {
            return Ok(None);
        }
        let info = discovery.info.clone();
        *self.memory.borrow_mut() = Some(discovery);
        Ok(Some(info))
    }

    pub fn save(&self, info: &Value) -> Result<(), AppError> {
        let Some(checked_at) = now() else {
            return Ok(());
        };
        let discovery = Discovery {
            format_version: 1,
            profile_sha256: self.profile_sha256.clone(),
            checked_at,
            info: info.clone(),
        };
        let bytes = serde_json::to_vec(&discovery)?;
        if bytes.len() as u64 > MAX_BYTES {
            return Ok(());
        }
        let directory = self
            .path
            .parent()
            .ok_or_else(|| AppError::validation("invalid capability cache path"))?;
        private_fs::create_dir(directory)?;
        let temporary = directory.join(format!(".capabilities-{}.tmp", uuid::Uuid::new_v4()));
        let result: Result<(), AppError> = (|| {
            let mut file = private_fs::create_file(&temporary)?;
            file.write_all(&bytes)?;
            drop(file);
            #[cfg(windows)]
            atomicwrites::replace_atomic(&temporary, &self.path)?;
            #[cfg(unix)]
            std::fs::rename(&temporary, &self.path)?;
            Ok(())
        })();
        if temporary.exists() {
            std::fs::remove_file(&temporary)?;
        }
        result?;
        *self.memory.borrow_mut() = Some(discovery);
        Ok(())
    }
}
