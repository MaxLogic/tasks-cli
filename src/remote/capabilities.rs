//! Short-lived, private discovery evidence, never a replacement for write receipts.
use super::config::Profile;
use crate::{private_fs, AppError};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    cell::RefCell,
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const MAX_BYTES: u64 = 64 * 1024;
const TTL: Duration = Duration::from_secs(60);

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Discovery {
    format_version: u32,
    profile_sha256: String,
    checked_at: Duration,
    info: Value,
}

pub(super) struct Capabilities {
    path: PathBuf,
    profile_sha256: String,
    memory: RefCell<Option<Discovery>>,
}

pub(super) fn invalidate(root: &Path) {
    // Discovery is optional. Never replace a server error (including its exit
    // code, payload or unknown-outcome identity) with a cache cleanup error.
    let _ = std::fs::remove_file(root.join("client/capabilities.json"));
}

pub(super) fn invalidate_on_error<T>(
    root: &Path,
    result: Result<T, AppError>,
) -> Result<T, AppError> {
    if result.is_err() {
        invalidate(root);
    }
    result
}

fn now() -> Option<Duration> {
    SystemTime::now().duration_since(UNIX_EPOCH).ok()
}

fn fresh(checked_at: Duration, now: Duration) -> bool {
    now.checked_sub(checked_at).is_some_and(|age| age < TTL)
}

fn clean_stale(directory: &Path) {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(id) = name
            .to_str()
            .and_then(|name| name.strip_prefix(".capabilities-")?.strip_suffix(".tmp"))
        else {
            continue;
        };
        if uuid::Uuid::parse_str(id).is_err() {
            continue;
        }
        // Do not follow links or delete another publisher's recent temp file.
        let Ok(meta) = std::fs::symlink_metadata(entry.path()) else {
            continue;
        };
        if meta.is_file()
            && !meta.file_type().is_symlink()
            && meta
                .modified()
                .ok()
                .and_then(|v| v.elapsed().ok())
                .is_some_and(|age| age >= TTL)
        {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

impl Capabilities {
    pub fn new(root: &Path, profile: &Profile, ca_hash: &str) -> Result<Self, AppError> {
        // Use the digest of the exact bytes already consumed by HTTPS setup,
        // avoiding a second CA read and a file-replacement race between reads.
        Ok(Self {
            path: root.join("client/capabilities.json"),
            profile_sha256: crate::markdown::sha256(&serde_json::to_vec(&(profile, ca_hash))?),
            memory: RefCell::new(None),
        })
    }

    pub fn get(&self) -> Option<Value> {
        self.get_with_clock(now)
    }

    fn get_with_clock(&self, clock: impl FnOnce() -> Option<Duration>) -> Option<Value> {
        let discovery = match self.memory.borrow().clone() {
            Some(value) => value,
            None => {
                // Any open, owner/ACL/reparse validation, read or decode failure
                // is a miss. Live authenticated discovery remains authoritative.
                let file = private_fs::open_cache_file(&self.path).ok()?;
                let mut bytes = Vec::new();
                file.take(MAX_BYTES + 1).read_to_end(&mut bytes).ok()?;
                if bytes.len() as u64 > MAX_BYTES {
                    return None;
                }
                serde_json::from_slice(&bytes).ok()?
            }
        };
        if discovery.format_version != 2
            || discovery.profile_sha256 != self.profile_sha256
            || !fresh(discovery.checked_at, clock()?)
        {
            return None;
        }
        let info = discovery.info.clone();
        *self.memory.borrow_mut() = Some(discovery);
        Some(info)
    }

    pub fn save(&self, info: &Value) {
        let Some(checked_at) = now() else {
            return;
        };
        let discovery = Discovery {
            format_version: 2,
            profile_sha256: self.profile_sha256.clone(),
            checked_at,
            info: info.clone(),
        };
        // Retain validated live discovery within this command even when disk
        // publication is unavailable. No cache I/O may change command success.
        let _ = self.publish(&discovery);
        *self.memory.borrow_mut() = Some(discovery);
    }

    fn publish(&self, discovery: &Discovery) -> Result<(), AppError> {
        let bytes = serde_json::to_vec(discovery)?;
        if bytes.len() as u64 > MAX_BYTES {
            return Ok(());
        }
        let directory = self
            .path
            .parent()
            .ok_or_else(|| AppError::validation("invalid capability cache path"))?;
        private_fs::create_dir(directory)?;
        clean_stale(directory);
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
        let _ = std::fs::remove_file(&temporary);
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subsecond_expiry_and_backward_clock_steps_are_cache_misses() {
        let root = tempfile::tempdir().unwrap();
        let cache = Capabilities::new(root.path(), &Profile::Local, "").unwrap();
        let checked_at = Duration::new(100, 999_999_999);
        *cache.memory.borrow_mut() = Some(Discovery {
            format_version: 2,
            profile_sha256: cache.profile_sha256.clone(),
            checked_at,
            info: serde_json::json!({"capabilities": []}),
        });
        assert!(cache.get_with_clock(|| Some(checked_at)).is_some());
        assert!(cache
            .get_with_clock(|| Some(checked_at + TTL - Duration::from_nanos(1)))
            .is_some());
        assert!(cache.get_with_clock(|| Some(checked_at + TTL)).is_none());
        assert!(cache
            .get_with_clock(|| Some(checked_at + TTL + Duration::from_nanos(1)))
            .is_none());
        assert!(cache
            .get_with_clock(|| Some(checked_at - Duration::from_nanos(1)))
            .is_none());
    }

    #[test]
    fn changing_only_server_or_credential_identity_misses_discovery() {
        let root = tempfile::tempdir().unwrap();
        let profile = Profile::Remote {
            server_url: "https://localhost:1234".into(),
            server_id: uuid::Uuid::new_v4(),
            credential_id: uuid::Uuid::new_v4(),
            credential_file: root.path().join("key.pem"),
            private_ca: None,
            connect_timeout_seconds: 3,
            request_timeout_seconds: 15,
        };
        Capabilities::new(root.path(), &profile, "")
            .unwrap()
            .save(&serde_json::json!({"ready":true}));
        assert!(Capabilities::new(root.path(), &profile, "")
            .unwrap()
            .get()
            .is_some());
        for server in [true, false] {
            let mut changed = profile.clone();
            let Profile::Remote {
                server_id,
                credential_id,
                ..
            } = &mut changed
            else {
                unreachable!()
            };
            if server {
                *server_id = uuid::Uuid::new_v4();
            } else {
                *credential_id = uuid::Uuid::new_v4();
            }
            assert!(Capabilities::new(root.path(), &changed, "")
                .unwrap()
                .get()
                .is_none());
        }
        assert!(
            Capabilities::new(root.path(), &profile, "different CA bytes")
                .unwrap()
                .get()
                .is_none()
        );
    }

    #[test]
    fn publishing_cleans_only_stale_discovery_temporary_files() {
        let root = tempfile::tempdir().unwrap();
        let cache = Capabilities::new(root.path(), &Profile::Local, "").unwrap();
        let directory = root.path().join("client");
        private_fs::create_dir(&directory).unwrap();
        let stale = directory.join(format!(".capabilities-{}.tmp", uuid::Uuid::new_v4()));
        let recent = directory.join(format!(".capabilities-{}.tmp", uuid::Uuid::new_v4()));
        let unrelated = directory.join(".capabilities-not-a-uuid.tmp");
        for path in [&stale, &recent, &unrelated] {
            let file = private_fs::create_file(path).unwrap();
            if path != &recent {
                file.set_modified(SystemTime::now() - TTL * 2).unwrap();
            }
        }
        cache.save(&serde_json::json!({"ready":true}));
        assert!(!stale.exists());
        assert!(recent.exists());
        assert!(unrelated.exists());
        assert!(cache.get().is_some());
    }
}
