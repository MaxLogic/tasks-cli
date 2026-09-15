use crate::error::AppError;
use fs2::FileExt;
use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

const DEFAULT_LOCK_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StoragePlatform {
    Windows,
    Linux,
}

#[derive(Debug)]
pub struct ExclusiveLock(File);

impl Drop for ExclusiveLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

pub fn acquire_exclusive_lock(path: &Path) -> Result<ExclusiveLock, AppError> {
    acquire_exclusive_lock_for(path, DEFAULT_LOCK_TIMEOUT)
}

pub fn acquire_exclusive_lock_for(
    path: &Path,
    timeout: Duration,
) -> Result<ExclusiveLock, AppError> {
    let started = Instant::now();
    loop {
        let file = match OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(path)
        {
            Ok(file) => file,
            Err(error) if is_lock_contention(&error) => {
                if started.elapsed() >= timeout {
                    return Err(AppError::LockTimeout);
                }
                thread::sleep(Duration::from_millis(10));
                continue;
            }
            Err(error) => return Err(AppError::Io(error)),
        };
        match file.try_lock_exclusive() {
            Ok(()) => return Ok(ExclusiveLock(file)),
            Err(error) if is_lock_contention(&error) => {
                if started.elapsed() >= timeout {
                    return Err(AppError::LockTimeout);
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) => return Err(AppError::Io(error)),
        }
    }
}

fn is_lock_contention(error: &std::io::Error) -> bool {
    error.kind() == std::io::ErrorKind::WouldBlock
        || (cfg!(windows) && matches!(error.raw_os_error(), Some(32 | 33)))
}

fn absolute_path(path: &Path) -> Result<PathBuf, AppError> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

fn has_linux_windows_mount(path: &Path) -> bool {
    let text = path.to_string_lossy().replace('\\', "/");
    let components = text
        .split('/')
        .filter(|component| !component.is_empty() && *component != ".")
        .map(str::to_string)
        .collect::<Vec<_>>();
    let is_drive = |value: &str| value.len() == 1 && value.as_bytes()[0].is_ascii_alphabetic();
    text.starts_with('/')
        && ((components.len() >= 2
            && components[0].eq_ignore_ascii_case("mnt")
            && is_drive(&components[1]))
            || (components.len() >= 5
                && components[0] == "run"
                && components[1] == "desktop"
                && components[2] == "mnt"
                && components[3] == "host"
                && is_drive(&components[4])))
}

fn has_unc_prefix(path: &Path) -> bool {
    let value = path.to_string_lossy().replace('/', "\\");
    let upper = value.to_ascii_uppercase();
    (upper.starts_with("\\\\") && !upper.starts_with("\\\\?\\"))
        || upper.starts_with("\\\\?\\UNC\\")
        || upper.starts_with("\\\\.\\")
}

pub fn validate_storage_root_for(
    root: &Path,
    platform: StoragePlatform,
) -> Result<PathBuf, AppError> {
    let root_text = root.to_string_lossy();
    let absolute = match platform {
        StoragePlatform::Windows => {
            root.is_absolute()
                || root_text.as_bytes().get(1) == Some(&b':')
                || root_text.starts_with("\\\\")
        }
        StoragePlatform::Linux => root_text.starts_with('/'),
    };
    if !absolute {
        return Err(AppError::InvalidPath(
            "storage root must be absolute".to_string(),
        ));
    }
    let absolute = root.to_path_buf();
    let remote = match platform {
        StoragePlatform::Windows => has_unc_prefix(&absolute),
        StoragePlatform::Linux => {
            absolute.to_string_lossy().starts_with("//") || has_linux_windows_mount(&absolute)
        }
    };
    if remote {
        return Err(AppError::InvalidPath(format!(
            "storage root is not a supported local {} path: {}",
            match platform {
                StoragePlatform::Windows => "Windows",
                StoragePlatform::Linux => "Linux",
            },
            absolute.display()
        )));
    }
    if absolute.exists() && !absolute.is_dir() {
        return Err(AppError::InvalidPath(format!(
            "storage root is not a directory: {}",
            absolute.display()
        )));
    }
    Ok(absolute)
}

pub fn validate_storage_root(root: &Path) -> Result<PathBuf, AppError> {
    let absolute = absolute_path(root)?;
    let platform = if cfg!(windows) {
        StoragePlatform::Windows
    } else {
        StoragePlatform::Linux
    };
    let validated = validate_storage_root_for(&absolute, platform)?;
    let mut existing = validated.clone();
    while !existing.exists() {
        if !existing.pop() {
            break;
        }
    }
    if let Ok(canonical) = existing.canonicalize() {
        validate_storage_root_for(&canonical, platform)?;
    }
    Ok(validated)
}

#[cfg(test)]
mod tests {
    use super::*;
    use fs2::FileExt;
    use std::fs::OpenOptions;

    #[test]
    fn linux_rejects_drvfs_and_unc_roots() {
        assert!(
            validate_storage_root_for(Path::new("/tmp/tasks-data"), StoragePlatform::Linux).is_ok()
        );
        assert!(
            validate_storage_root_for(Path::new("/mnt/c/tasks-data"), StoragePlatform::Linux)
                .is_err()
        );
        assert!(validate_storage_root_for(
            Path::new("//server/share/tasks-data"),
            StoragePlatform::Linux
        )
        .is_err());
    }

    #[test]
    fn windows_rejects_unc_but_allows_local_drive_syntax() {
        assert!(
            validate_storage_root_for(Path::new(r"C:\tasks-data"), StoragePlatform::Windows)
                .is_ok()
        );
        assert!(validate_storage_root_for(
            Path::new(r"\\server\share\tasks-data"),
            StoragePlatform::Windows
        )
        .is_err());
        assert!(validate_storage_root_for(
            Path::new(r"\\?\UNC\server\share\tasks-data"),
            StoragePlatform::Windows
        )
        .is_err());
    }

    #[test]
    fn held_lock_times_out_instead_of_waiting_forever() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let path = temp.path().join("held.lock");
        let guard = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&path)
            .expect("lock file");
        guard.lock_exclusive().expect("held lock");
        assert!(matches!(
            acquire_exclusive_lock_for(&path, Duration::from_millis(40)),
            Err(AppError::LockTimeout)
        ));
    }

    #[cfg(not(windows))]
    #[test]
    fn unix_errno_values_are_not_misclassified_as_lock_contention() {
        assert!(!is_lock_contention(&std::io::Error::from_raw_os_error(32)));
        assert!(!is_lock_contention(&std::io::Error::from_raw_os_error(33)));
    }
}
