//! Destination resolution, verified decoding and atomic publication (lane C2).
use super::{envelope, name, Limits};
use crate::{error::AppError, model::AttachmentRecord, output::MaterializedAttachment};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};

struct Destination {
    attachment: AttachmentRecord,
    path: PathBuf,
}

/// Preflight is separate from content retrieval so local and remote callers can
/// reject every collision before reading a blob or starting a download.
pub struct Plan {
    destinations: Vec<Destination>,
    replace: bool,
    cache: bool,
}

impl Plan {
    pub fn new(
        records: Vec<AttachmentRecord>,
        data_root: &Path,
        project: &str,
        out: Option<&Path>,
        overwrite: bool,
    ) -> Result<Self, AppError> {
        if out == Some(Path::new("-")) {
            return Err(AppError::usage(
                "--out - is refused; attachment get prints paths, never content",
            ));
        }
        if records.len() > 1 && out.is_some_and(|p| !p.is_dir()) {
            return Err(AppError::usage(
                "several attachments require an existing --out directory",
            ));
        }
        let mut destinations: Vec<Destination> = Vec::with_capacity(records.len());
        for attachment in records {
            let a = &attachment.attachment;
            name::validate(&a.name, &Limits::PRODUCTION).map_err(|e| integrity(&e.to_string()))?;
            let safe = name::sanitize(&a.name, a.id);
            let path = match out {
                Some(dir) if dir.is_dir() => dir.join(&safe),
                Some(file) => file.to_owned(),
                None => data_root
                    .join("cache/attachments")
                    .join(project)
                    .join(format!("A{}", a.id))
                    .join(&safe),
            };
            let path = resolved_destination(&path)?;
            for prior in &destinations {
                if path_key(&path) == path_key(&prior.path)
                    || same_existing_file(&path, &prior.path)?
                {
                    return Err(collision(prior, a.id, &path));
                }
            }
            destinations.push(Destination { attachment, path });
        }
        let plan = Self {
            destinations,
            replace: out.is_none() || overwrite,
            cache: out.is_none(),
        };
        // Inspect all existing destinations before a single publication.
        for destination in &plan.destinations {
            if exists(&destination.path)? {
                if !destination.path.is_file() {
                    return Err(AppError::io_path(
                        "materialize a regular file at",
                        &destination.path,
                        std::io::Error::new(
                            std::io::ErrorKind::InvalidInput,
                            "destination is not a regular file",
                        ),
                    ));
                }
                if !plan.replace && !matches_content(destination)? {
                    return Err(AppError::DestinationExists(
                        destination.path.display().to_string(),
                    ));
                }
            }
        }
        Ok(plan)
    }

    /// Read and verify one bounded envelope at a time, publishing only verified
    /// bytes. Multi-file gets are deliberately not a filesystem transaction.
    pub fn execute(
        self,
        mut read: impl FnMut(u64) -> Result<Vec<u8>, AppError>,
    ) -> Result<Vec<MaterializedAttachment>, AppError> {
        let mut published: Vec<PathBuf> = Vec::new();
        let mut result = Vec::with_capacity(self.destinations.len());
        let operation = (|| {
            for destination in &self.destinations {
                let bytes = read(destination.attachment.attachment.id)?;
                let reused = if matches_content(destination)? {
                    // A healthy cache must not mask corruption of the stored blob.
                    verified_decode(destination, &bytes, std::io::sink())?;
                    true
                } else {
                    if self.cache {
                        fs::create_dir_all(parent(&destination.path)?).map_err(|e| {
                            AppError::io_path("create cache directory for", &destination.path, e)
                        })?;
                    }
                    let mut temp = Staged::new(&destination.path)?;
                    let publication = (|| {
                        verified_decode(destination, &bytes, &mut temp.file)?;
                        temp.file.sync_all().map_err(|e| {
                            AppError::io_path("sync attachment for", &destination.path, e)
                        })?;
                        #[cfg(feature = "test-hooks")]
                        hold_publish()?;
                        if self.replace {
                            fs::rename(&temp.path, &destination.path).map_err(|e| {
                                AppError::io_path("publish attachment at", &destination.path, e)
                            })?;
                            temp.disarm();
                            published.push(destination.path.clone());
                            verify_published(destination)?;
                            Ok(false)
                        } else {
                            match publish_no_replace(&temp.path, &destination.path) {
                                Ok(()) => {
                                    temp.disarm();
                                    published.push(destination.path.clone());
                                    verify_published(destination)?;
                                    Ok(false)
                                }
                                Err(_) if exists(&destination.path)? => {
                                    if matches_content(destination)? {
                                        Ok(true)
                                    } else {
                                        Err(AppError::DestinationExists(
                                            destination.path.display().to_string(),
                                        ))
                                    }
                                }
                                Err(e) => Err(AppError::io_path(
                                    "publish without replacement at",
                                    &destination.path,
                                    e,
                                )),
                            }
                        }
                    })();
                    let cleanup = temp.cleanup();
                    let reused = match (publication, cleanup) {
                        (Ok(reused), Ok(())) => reused,
                        (Err(error), Ok(())) | (Ok(_), Err(error)) => return Err(error),
                        (Err(error), Err(cleanup)) => {
                            return Err(AppError::Coded {
                                code: error.code(),
                                exit: error.exit_code() as u8,
                                message: format!("{error}; {cleanup}"),
                            })
                        }
                    };
                    sync_directory(parent(&destination.path)?)?;
                    reused
                };
                // Re-resolve object identities after each publication and again at
                // completion. Hard links and path aliases cannot stand in for two outputs.
                for prior in &self.destinations[..result.len()] {
                    if same_existing_file(&prior.path, &destination.path)? {
                        return Err(collision(
                            prior,
                            destination.attachment.attachment.id,
                            &destination.path,
                        ));
                    }
                }
                result.push(MaterializedAttachment {
                    attachment: destination.attachment.clone(),
                    path: path_string(&destination.path)?,
                    reused,
                });
            }
            for (index, destination) in self.destinations.iter().enumerate() {
                for prior in &self.destinations[..index] {
                    if same_existing_file(&prior.path, &destination.path)? {
                        return Err(collision(
                            prior,
                            destination.attachment.attachment.id,
                            &destination.path,
                        ));
                    }
                }
            }
            Ok(())
        })();
        operation.map_err(|e: AppError| {
            if published.is_empty() {
                e
            } else {
                AppError::Coded {
                    code: e.code(),
                    exit: e.exit_code() as u8,
                    message: format!(
                        "{e}; already published: {}",
                        published
                            .iter()
                            .map(|p| p.display().to_string())
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                }
            }
        })?;
        Ok(result)
    }
}

fn path_string(path: &Path) -> Result<String, AppError> {
    let value = path.to_str().ok_or_else(|| {
        AppError::InvalidPath(format!(
            "output path is not UTF-8: {}; choose a UTF-8 destination",
            path.display()
        ))
    })?;
    #[cfg(windows)]
    if let Some(unc) = value.strip_prefix("\\\\?\\UNC\\") {
        return Ok(format!("\\\\{unc}"));
    }
    #[cfg(windows)]
    if let Some(local) = value.strip_prefix("\\\\?\\") {
        return Ok(local.to_owned());
    }
    Ok(value.to_owned())
}

fn collision(prior: &Destination, id: u64, path: &Path) -> AppError {
    AppError::DestinationCollision(format!(
        "{} and A{id} resolve to {}",
        prior.attachment.attachment.display_id,
        path.display()
    ))
}

fn parent(path: &Path) -> Result<&Path, AppError> {
    path.parent().ok_or_else(|| {
        AppError::InvalidPath(format!("{} has no destination directory", path.display()))
    })
}

fn exists(path: &Path) -> Result<bool, AppError> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(AppError::io_path("inspect destination", path, e)),
    }
}

/// Canonicalize the existing ancestor without creating cache directories. This
/// also resolves parent-directory aliases before comparing destination names.
fn resolved_destination(path: &Path) -> Result<PathBuf, AppError> {
    let absolute = std::path::absolute(path).map_err(|e| AppError::io_path("resolve", path, e))?;
    let mut ancestor = parent(&absolute)?.to_owned();
    let mut tail = Vec::new();
    while !exists(&ancestor)? {
        tail.push(
            ancestor
                .file_name()
                .ok_or_else(|| AppError::InvalidPath(format!("cannot resolve {}", path.display())))?
                .to_owned(),
        );
        ancestor = parent(&ancestor)?.to_owned();
    }
    let mut resolved = fs::canonicalize(&ancestor)
        .map_err(|e| AppError::io_path("resolve destination directory", &ancestor, e))?;
    for part in tail.into_iter().rev() {
        resolved.push(part);
    }
    resolved.push(
        absolute
            .file_name()
            .ok_or_else(|| AppError::InvalidPath(format!("{} has no file name", path.display())))?,
    );
    path_string(&resolved)?;
    Ok(resolved)
}

#[cfg(windows)]
fn path_key(path: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    path.as_os_str()
        .encode_wide()
        .map(|unit| {
            let Some(ch) = char::from_u32(unit as u32) else {
                return unit;
            };
            let mut upper = ch.to_uppercase();
            match (upper.next(), upper.next()) {
                (Some(value), None) if value.len_utf16() == 1 => value as u16,
                _ => unit,
            }
        })
        .collect()
}
#[cfg(not(windows))]
fn path_key(path: &Path) -> &std::ffi::OsStr {
    path.as_os_str()
}

fn same_existing_file(a: &Path, b: &Path) -> Result<bool, AppError> {
    if !exists(a)? || !exists(b)? {
        return Ok(false);
    }
    let a_id = file_id::get_file_id(a)
        .map_err(|e| AppError::io_path("read destination file identity", a, e))?;
    let b_id = file_id::get_file_id(b)
        .map_err(|e| AppError::io_path("read destination file identity", b, e))?;
    Ok(a_id == b_id)
}

fn matches_content(destination: &Destination) -> Result<bool, AppError> {
    if !exists(&destination.path)? {
        return Ok(false);
    }
    let mut file = File::open(&destination.path)
        .map_err(|e| AppError::io_path("read destination", &destination.path, e))?;
    let metadata = file
        .metadata()
        .map_err(|e| AppError::io_path("inspect destination", &destination.path, e))?;
    let a = &destination.attachment.attachment;
    if !metadata.is_file() || metadata.len() != a.original_size {
        return Ok(false);
    }
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    let mut size = 0u64;
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|e| AppError::io_path("hash destination", &destination.path, e))?;
        if count == 0 {
            break;
        }
        size += count as u64;
        if size > a.original_size {
            return Ok(false);
        }
        hash.update(&buffer[..count]);
    }
    Ok(size == a.original_size && format!("{:x}", hash.finalize()) == a.sha256)
}

fn verify_published(destination: &Destination) -> Result<(), AppError> {
    // Publication uses a pathname which another same-user writer may have
    // replaced since decoding. Re-read the output before reporting success.
    // Never remove a mismatching destination: it may belong to that writer.
    if !matches_content(destination)? {
        return Err(integrity(&format!(
            "published output does not match the verified attachment: {} (left in place)",
            destination.path.display()
        )));
    }
    Ok(())
}

fn verified_decode(
    destination: &Destination,
    bytes: &[u8],
    writer: impl Write,
) -> Result<(), AppError> {
    let a = &destination.attachment.attachment;
    if bytes.len() as u64 != a.stored_size {
        return Err(integrity("stored size does not match metadata"));
    }
    let metadata =
        envelope::decode_to(bytes, &a.name, writer, &Limits::PRODUCTION).map_err(|error| {
            match error {
                super::AttachmentError::Io(e) => {
                    AppError::io_path("write attachment for", &destination.path, e)
                }
                other => integrity(&other.to_string()),
            }
        })?;
    if metadata.original_size != a.original_size || metadata.sha256 != a.sha256 {
        return Err(integrity(
            "decoded hash or size does not match stored metadata",
        ));
    }
    Ok(())
}
fn integrity(message: &str) -> AppError {
    AppError::Coded { code: "attachment_integrity", exit: 6, message: format!("attachment integrity: {message}; restore damaged stored content from a verified backup") }
}

struct Staged {
    path: PathBuf,
    file: File,
    identity: same_file::Handle,
    cleanup_armed: bool,
}
impl Staged {
    fn new(destination: &Path) -> Result<Self, AppError> {
        // Fixed short name per the C2 design correction: a maximum-length final
        // name must not make its staging component exceed filesystem limits.
        let path = parent(destination)?.join(format!(".tasks-tmp-{}", uuid::Uuid::new_v4()));
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|e| AppError::io_path("create temporary attachment for", destination, e))?;
        // Retain the original object, rather than trusting an identity sampled
        // later through its replaceable pathname. std has no stable Windows
        // volume/file-index API; same-file supplies handle-based identity.
        let identity = file
            .try_clone()
            .and_then(same_file::Handle::from_file)
            .map_err(|e| AppError::io_path("identify temporary attachment (leftover)", &path, e))?;
        Ok(Self {
            path,
            file,
            identity,
            cleanup_armed: true,
        })
    }

    fn disarm(&mut self) {
        self.cleanup_armed = false;
    }

    fn cleanup(&mut self) -> Result<(), AppError> {
        // Do not retry in Drop after publication or an explicit cleanup error.
        self.disarm();
        let current = match same_file::Handle::from_path(&self.path) {
            Ok(current) => current,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(e) => {
                return Err(AppError::io_path(
                    "identify temporary attachment before cleanup (leftover)",
                    &self.path,
                    e,
                ))
            }
        };
        if current != self.identity {
            return Err(AppError::io_path(
                "preserve replaced temporary attachment (leftover; file identity is not ours)",
                &self.path,
                std::io::Error::other("temporary pathname was replaced by another writer"),
            ));
        }
        // As with backup cleanup, a same-user rename can replace this path
        // between the identity check and deletion. Defeating active hostile
        // renames in that window is outside the accepted threat model.
        match fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(AppError::io_path(
                "remove this command's temporary attachment (leftover)",
                &self.path,
                e,
            )),
        }
    }
}
impl Drop for Staged {
    fn drop(&mut self) {
        if self.cleanup_armed {
            let _ = self.cleanup();
        }
    }
}
#[cfg(windows)]
fn publish_no_replace(temp: &Path, dest: &Path) -> std::io::Result<()> {
    atomicwrites::move_atomic(temp, dest)
}
#[cfg(unix)]
fn publish_no_replace(temp: &Path, dest: &Path) -> std::io::Result<()> {
    fs::hard_link(temp, dest)
}
#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<(), AppError> {
    File::open(path)?
        .sync_all()
        .map_err(|e| AppError::io_path("sync destination directory", path, e))
}
#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> Result<(), AppError> {
    Ok(())
}

#[cfg(feature = "test-hooks")]
fn hold_publish() -> Result<(), AppError> {
    // A readiness/release barrier makes pathname replacement and competing
    // publishers deterministic without depending on process startup speed.
    if let Some(ready) = std::env::var_os("TASKS_TEST_PUBLISH_READY") {
        let release = std::env::var_os("TASKS_TEST_PUBLISH_RELEASE")
            .ok_or_else(|| AppError::usage("TASKS_TEST_PUBLISH_RELEASE is required"))?;
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(ready)?;
        let start = std::time::Instant::now();
        while !Path::new(&release).exists() {
            if start.elapsed() > std::time::Duration::from_secs(10) {
                return Err(AppError::usage("publication test barrier timed out"));
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }
    if let Ok(value) = std::env::var("TASKS_TEST_HOLD_PUBLISH_MS") {
        let millis: u64 = value
            .parse()
            .map_err(|_| AppError::usage("TASKS_TEST_HOLD_PUBLISH_MS must be milliseconds"))?;
        std::thread::sleep(std::time::Duration::from_millis(millis.min(10_000)));
    }
    Ok(())
}
