//! Fresh installation signing keys. Never reuse SSH or harness credentials.
use crate::{private_fs, AppError};
use ed25519_dalek::{
    pkcs8::{spki::der::pem::LineEnding, DecodePrivateKey, EncodePrivateKey},
    SigningKey,
};
use rand_core::OsRng;
use std::{
    io::{Read, Write},
    path::Path,
};

/// Explicit setup only. Refuse existing keys rather than silently rotating them.
pub fn generate_key(directory: &Path) -> Result<[u8; 32], AppError> {
    private_fs::create_dir(directory)?;
    let mut file = private_fs::create_file(&directory.join("signing-key.pem"))?;
    let key = SigningKey::generate(&mut OsRng);
    let pem = key
        .to_pkcs8_pem(LineEnding::LF)
        .map_err(|_| AppError::Database("cannot encode signing key as PKCS#8 PEM".into()))?;
    file.write_all(pem.as_bytes())?;
    file.sync_all()?;
    Ok(key.verifying_key().to_bytes())
}

pub fn load_key(path: &Path) -> Result<SigningKey, AppError> {
    let file = private_fs::open_file(path)?;
    if file.metadata()?.len() > 16384 {
        return Err(AppError::Database(
            "private key exceeds the 16 KiB limit".into(),
        ));
    }
    let mut pem = String::new();
    file.take(16385).read_to_string(&mut pem)?;
    if pem.len() > 16384 {
        return Err(AppError::Database(
            "private key exceeds the 16 KiB limit".into(),
        ));
    }
    SigningKey::from_pkcs8_pem(&pem)
        .map_err(|_| AppError::Database("invalid Ed25519 PKCS#8 private key".into()))
}
