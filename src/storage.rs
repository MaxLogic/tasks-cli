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
                    return Err(AppError::LockTimeout(format!(
                        "{} is held by another tasks process after {}ms; retry when it finishes",
                        path.display(),
                        timeout.as_millis()
                    )));
                }
                thread::sleep(Duration::from_millis(10));
                continue;
            }
            Err(error) => return Err(AppError::io_path("open lock file", path, error)),
        };
        match file.try_lock_exclusive() {
            Ok(()) => return Ok(ExclusiveLock(file)),
            Err(error) if is_lock_contention(&error) => {
                if started.elapsed() >= timeout {
                    return Err(AppError::LockTimeout(format!(
                        "{} is held by another tasks process after {}ms; retry when it finishes",
                        path.display(),
                        timeout.as_millis()
                    )));
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) => return Err(AppError::io_path("lock", path, error)),
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
        let cwd = std::env::current_dir()
            .map_err(|error| AppError::io_op("resolve the current directory", error))?;
        Ok(cwd.join(path))
    }
}

fn nearest_existing_path(path: &Path) -> Result<PathBuf, AppError> {
    let mut existing = path.to_path_buf();
    loop {
        match std::fs::symlink_metadata(&existing) {
            Ok(_) => return Ok(existing),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                if !existing.pop() {
                    return Err(AppError::InvalidPath(format!(
                        "storage path {} has no existing ancestor; pass an absolute path below an accessible local disk",
                        path.display()
                    )));
                }
            }
            Err(error) => return Err(AppError::io_path("inspect storage path", &existing, error)),
        }
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

#[cfg(any(target_os = "linux", test))]
fn windows_or_remote_mount(path: &Path, mountinfo: &str) -> bool {
    let mut owner = None;
    for line in mountinfo.lines() {
        let Some((fields, filesystem)) = line.split_once(" - ") else {
            continue;
        };
        let Some(mountpoint) = fields.split_whitespace().nth(4) else {
            continue;
        };
        // mountinfo escapes whitespace and backslashes as octal sequences.
        let mountpoint = mountpoint
            .replace("\\040", " ")
            .replace("\\011", "\t")
            .replace("\\012", "\n")
            .replace("\\134", "\\");
        let mountpoint = Path::new(&mountpoint);
        if !path.starts_with(mountpoint) {
            continue;
        }
        let depth = mountpoint.components().count();
        if owner.is_some_and(|(best, _)| best > depth) {
            continue;
        }
        let fs_type = filesystem.split_whitespace().next().unwrap_or("");
        let prohibited = matches!(fs_type, "drvfs" | "cifs" | "smb3" | "nfs" | "nfs4")
            || (fs_type == "9p" && filesystem.contains("aname=drvfs"));
        owner = Some((depth, prohibited));
    }
    owner.is_some_and(|(_, prohibited)| prohibited)
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
    let absolute = validate_storage_location_for(root, platform)?;
    if absolute.exists() && !absolute.is_dir() {
        return Err(AppError::InvalidPath(format!(
            "storage root {} exists but is not a directory; choose a directory path",
            absolute.display()
        )));
    }
    Ok(absolute)
}

fn validate_storage_location_for(
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
        return Err(AppError::InvalidPath(format!(
            "storage root {} is not absolute; pass an absolute path such as C:\\tasks-data or /home/<user>/tasks-data",
            root.display()
        )));
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
            "storage root {} is a remote or WSL-mounted {} path; use a local disk directory instead",
            absolute.display(),
            match platform {
                StoragePlatform::Windows => "Windows",
                StoragePlatform::Linux => "Linux",
            },
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
    validate_storage_path_for(&validated, platform)?;
    Ok(validated)
}

fn validate_storage_path_for(path: &Path, platform: StoragePlatform) -> Result<(), AppError> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        absolute_path(path)?
    };
    validate_storage_location_for(&absolute, platform)?;
    let existing = nearest_existing_path(&absolute)?;
    let canonical = existing
        .canonicalize()
        .map_err(|error| AppError::io_path("resolve filesystem ownership", &existing, error))?;
    validate_storage_location_for(&canonical, platform)?;
    #[cfg(target_os = "linux")]
    if platform == StoragePlatform::Linux {
        let mounts = std::fs::read_to_string("/proc/self/mountinfo").map_err(|error| {
            AppError::io_path(
                "read filesystem ownership",
                Path::new("/proc/self/mountinfo"),
                error,
            )
        })?;
        if windows_or_remote_mount(&canonical, &mounts) {
            return Err(AppError::InvalidPath(format!(
                "storage path {} is on a Windows or remote filesystem; use Linux-owned storage or delegate to tasks.exe",
                absolute.display()
            )));
        }
    }
    Ok(())
}

/// Validate the actual target path before opening or creating a database.
/// Existing files and directories are canonicalized so local same-OS links
/// work while links into a Windows, UNC, or remote mount fail closed.  For a
/// new path, the nearest existing ancestor is checked because that is where
/// the operating system will create the descendant.
pub fn validate_storage_path(path: &Path) -> Result<(), AppError> {
    let platform = if cfg!(windows) {
        StoragePlatform::Windows
    } else {
        StoragePlatform::Linux
    };
    validate_storage_path_for(path, platform)
}

#[cfg(test)]
mod tests {
    use super::*;
    use fs2::FileExt;
    use std::fs::OpenOptions;

    #[test]
    fn mountinfo_detects_custom_drvfs_mounts_and_respects_nested_linux_mounts() {
        let mounts = "30 1 8:1 / / rw - ext4 /dev/sda rw\n31 30 0:5 / /srv/windows\\040disk rw - 9p C:\\ rw,aname=drvfs;path=C:\\;symlinkroot=/mnt/\n32 31 8:2 / /srv/windows\\040disk/linux rw - ext4 /dev/sdb rw\n33 30 0:6 / /custom/d rw - drvfs D:\\ rw\n";
        assert!(windows_or_remote_mount(
            Path::new("/srv/windows disk/tasks/new"),
            mounts
        ));
        assert!(windows_or_remote_mount(
            Path::new("/custom/d/tasks"),
            mounts
        ));
        assert!(!windows_or_remote_mount(
            Path::new("/srv/windows disk/linux/tasks"),
            mounts
        ));
        assert!(!windows_or_remote_mount(
            Path::new("/srv/windows diskette/tasks"),
            mounts
        ));
    }

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
        let error = acquire_exclusive_lock_for(&path, Duration::from_millis(40))
            .expect_err("held lock must time out");
        let message = error.to_string();
        assert!(
            message.contains(path.to_str().expect("UTF-8 lock path")),
            "{message}"
        );
        assert!(message.contains("40ms"), "{message}");
        assert!(message.contains("retry when it finishes"), "{message}");
    }

    #[cfg(not(windows))]
    #[test]
    fn unix_errno_values_are_not_misclassified_as_lock_contention() {
        assert!(!is_lock_contention(&std::io::Error::from_raw_os_error(32)));
        assert!(!is_lock_contention(&std::io::Error::from_raw_os_error(33)));
    }
}
