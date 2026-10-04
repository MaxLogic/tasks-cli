//! Backend selection is scoped to the explicit data root; malformed files fail closed.
use crate::AppError;
use serde::{Deserialize, Serialize};
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
};
use uuid::Uuid;

const MAX_PROFILE_BYTES: u64 = 16_384;
fn connect_timeout() -> u64 {
    3
}
fn request_timeout() -> u64 {
    15
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "backend", rename_all = "lowercase", deny_unknown_fields)]
pub enum Profile {
    Local,
    Remote {
        server_url: String,
        server_id: Uuid,
        credential_id: Uuid,
        credential_file: PathBuf,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        private_ca: Option<PathBuf>,
        #[serde(default = "connect_timeout")]
        connect_timeout_seconds: u64,
        #[serde(default = "request_timeout")]
        request_timeout_seconds: u64,
    },
}
fn invalid() -> AppError {
    AppError::Remote {
        code: "remote_configuration",
        message: "invalid client.toml; configure a local backend or a valid HTTPS remote profile"
            .into(),
        request_id: None,
    }
}
impl Profile {
    pub fn validate(&self) -> Result<(), AppError> {
        if let Self::Remote {
            server_url,
            server_id,
            credential_id,
            credential_file,
            private_ca,
            connect_timeout_seconds,
            request_timeout_seconds,
        } = self
        {
            super::https::validate_origin(server_url).map_err(|_| invalid())?;
            if server_url.len() > 2048
                || server_id.is_nil()
                || credential_id.is_nil()
                || !credential_file.is_absolute()
                || private_ca.as_ref().is_some_and(|p| !p.is_absolute())
                || !(1..=60).contains(connect_timeout_seconds)
                || !(1..=300).contains(request_timeout_seconds)
            {
                return Err(invalid());
            }
        }
        Ok(())
    }
}
pub fn load(root: &Path) -> Result<Profile, AppError> {
    let path = root.join("client.toml");
    let metadata = match std::fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Profile::Local),
        Err(_) => return Err(invalid()),
    };
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(invalid());
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(invalid());
        }
    }
    let file = std::fs::File::open(&path).map_err(|_| invalid())?;
    let mut text = String::new();
    file.take(MAX_PROFILE_BYTES + 1)
        .read_to_string(&mut text)
        .map_err(|_| invalid())?;
    if text.len() > MAX_PROFILE_BYTES as usize {
        return Err(invalid());
    }
    let table: toml::Table = toml::from_str(&text).map_err(|_| invalid())?;
    // Serde internally tagged unit variants otherwise ignore surplus fields.
    if table.get("backend").and_then(toml::Value::as_str) == Some("local") && table.len() != 1 {
        return Err(invalid());
    }
    let profile: Profile = toml::from_str(&text).map_err(|_| invalid())?;
    profile.validate()?;
    Ok(profile)
}
pub fn save(root: &Path, profile: &Profile) -> Result<(), AppError> {
    profile.validate()?;
    std::fs::create_dir_all(root)?;
    let bytes = toml::to_string(profile)
        .map_err(|_| invalid())?
        .into_bytes();
    if bytes.len() > MAX_PROFILE_BYTES as usize {
        return Err(invalid());
    }
    let temporary = root.join(format!(".client-{}.tmp", Uuid::new_v4()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let result = (|| {
        file.write_all(&bytes)?;
        file.sync_all()?;
        drop(file);
        #[cfg(windows)]
        atomicwrites::replace_atomic(&temporary, &root.join("client.toml"))?;
        #[cfg(unix)]
        std::fs::rename(&temporary, root.join("client.toml"))?;
        #[cfg(unix)]
        std::fs::File::open(root)?.sync_all()?;
        Ok(())
    })();
    if temporary.exists() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
