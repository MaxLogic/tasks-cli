//! Private client-owned files. Validate the opened object, not just its path.
//! Callers select a trusted personal data root; do not use a shared writable root.
use crate::AppError;
use std::{
    fs::{self, File, OpenOptions},
    path::Path,
};

fn insecure() -> AppError {
    AppError::Database(
        "private file permissions are insecure; use an owner-only client directory".into(),
    )
}

pub fn create_dir(path: &Path) -> Result<(), AppError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        match fs::DirBuilder::new().mode(0o700).create(path) {
            Ok(()) => (),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(error) => return Err(error.into()),
        }
    }
    #[cfg(windows)]
    {
        if path.try_exists()? {
            return validate_dir(path);
        }
        // Protect an empty uniquely owned directory before publishing its name.
        // Concurrent hooks must never observe a directory awaiting its ACL.
        let temporary = path
            .parent()
            .ok_or_else(insecure)?
            .join(format!(".private-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&temporary)?;
        let result = windows::protect_directory(&temporary).and_then(|_| {
            match fs::rename(&temporary, path) {
                Ok(()) => Ok(()),
                Err(_) if path.try_exists()? => validate_dir(path),
                Err(error) => Err(error.into()),
            }
        });
        if temporary.try_exists()? {
            fs::remove_dir(&temporary)?;
        }
        result?;
    }
    validate_dir(path)
}

pub fn validate_dir(path: &Path) -> Result<(), AppError> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err(insecure());
    }
    #[cfg(unix)]
    unix::validate(&meta, true)?;
    #[cfg(windows)]
    windows::validate(&windows::open_directory(path, false)?)?;
    Ok(())
}

pub fn create_file(path: &Path) -> Result<File, AppError> {
    validate_dir(path.parent().ok_or_else(insecure)?)?;
    create_output_file(path)
}

/// Retain directory handles on Windows so no component can be renamed while
/// an exclusively opened source file is linked. Unix publication requires
/// ownership and non-writable ancestors (sticky temporary roots are allowed).
pub(crate) struct ExportDirectory {
    pub path: std::path::PathBuf,
    #[cfg(windows)]
    _directories: Vec<File>,
}
pub(crate) fn validate_export_directory(path: &Path) -> Result<ExportDirectory, AppError> {
    let path = path.canonicalize()?;
    let meta = fs::symlink_metadata(&path)?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err(insecure());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if meta.uid() != rustix::process::geteuid().as_raw() || meta.mode() & 0o022 != 0 {
            return Err(AppError::Validation(
                "export directory must be owned by you and not writable by another user".into(),
            ));
        }
        for ancestor in path.ancestors().skip(1) {
            let meta = fs::metadata(ancestor)?;
            if !matches!(meta.uid(), 0) && meta.uid() != rustix::process::geteuid().as_raw()
                || meta.mode() & 0o022 != 0 && meta.mode() & 0o1000 == 0
            {
                return Err(AppError::Validation(
                    "export directory has an ancestor writable by another user".into(),
                ));
            }
        }
    }
    #[cfg(windows)]
    let directories = {
        use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
        let mut directories = Vec::new();
        for ancestor in path.ancestors().collect::<Vec<_>>().into_iter().rev() {
            let file = OpenOptions::new()
                .access_mode(0x20080)
                .share_mode(3)
                .custom_flags(0x02200000)
                .open(ancestor)?;
            if !file.metadata()?.is_dir() || file.metadata()?.file_attributes() & 0x400 != 0 {
                return Err(insecure());
            }
            directories.push(file);
        }
        directories
    };
    Ok(ExportDirectory {
        path,
        #[cfg(windows)]
        _directories: directories,
    })
}

/// A new unpublished export beside a user-selected destination. Its parent
/// need not be private, but the created file itself remains owner-protected.
pub(crate) fn create_output_file(path: &Path) -> Result<File, AppError> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options
            .access_mode(0xC0060000)
            .share_mode(0)
            .custom_flags(0x00200000);
    }
    let file = options.open(path)?;
    #[cfg(windows)]
    windows::protect(&file, false)?;
    validate_file(&file)?;
    Ok(file)
}

pub fn open_file(path: &Path) -> Result<File, AppError> {
    validate_dir(path.parent().ok_or_else(insecure)?)?;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(0).custom_flags(0x00200000);
    }
    let file = options.open(path)?;
    validate_file(&file)?;
    Ok(file)
}

pub fn validate_file(file: &File) -> Result<(), AppError> {
    let meta = file.metadata()?;
    if !meta.is_file() {
        return Err(insecure());
    }
    #[cfg(unix)]
    unix::validate(&meta, false)?;
    #[cfg(windows)]
    windows::validate(file)?;
    Ok(())
}

#[cfg(unix)]
mod unix {
    use super::*;
    use std::os::unix::fs::MetadataExt;
    pub(super) fn validate(meta: &fs::Metadata, directory: bool) -> Result<(), AppError> {
        let required = if directory { 0o700 } else { 0o600 };
        if meta.uid() != rustix::process::geteuid().as_raw()
            || meta.mode() & 0o7777 != required
            || (!directory && meta.nlink() != 1)
        {
            return Err(insecure());
        }
        Ok(())
    }
}

#[cfg(windows)]
mod windows {
    use super::*;
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    use windows_permissions::constants::{
        AceType, SeObjectType::SE_FILE_OBJECT, SecurityInformation,
    };
    use windows_permissions::{wrappers, LocalBox, SecurityDescriptor};

    pub(super) fn open_directory(path: &Path, writable: bool) -> Result<File, AppError> {
        Ok(OpenOptions::new()
            .access_mode(if writable { 0x60000 } else { 0x20000 })
            .share_mode(0x7)
            .custom_flags(0x02200000)
            .open(path)?)
    }
    pub(super) fn protect_directory(path: &Path) -> Result<(), AppError> {
        protect(&open_directory(path, true)?, true)
    }
    pub(super) fn protect(file: &File, directory: bool) -> Result<(), AppError> {
        let descriptor =
            wrappers::GetSecurityInfo(file, SE_FILE_OBJECT, SecurityInformation::Owner)?;
        let owner = descriptor.owner().ok_or_else(insecure)?;
        let flags = if directory { "OICI" } else { "" };
        let acl: LocalBox<SecurityDescriptor> =
            format!("D:P(A;{flags};FA;;;{owner})(A;{flags};FA;;;SY)(A;{flags};FA;;;BA)").parse()?;
        // The wrapper's generic set_multiple has incorrect flag selection. Use
        // its direct safe handle API, explicitly protecting against inheritance.
        let mut handle = file.try_clone()?;
        wrappers::SetSecurityInfo(
            &mut handle,
            SE_FILE_OBJECT,
            SecurityInformation::Dacl | SecurityInformation::ProtectedDacl,
            None,
            None,
            acl.dacl(),
            None,
        )?;
        validate(file)
    }
    pub(super) fn validate(file: &File) -> Result<(), AppError> {
        if file.metadata()?.file_attributes() & 0x400 != 0 {
            return Err(insecure());
        }
        let descriptor = wrappers::GetSecurityInfo(
            file,
            SE_FILE_OBJECT,
            SecurityInformation::Owner | SecurityInformation::Dacl,
        )?;
        let owner = descriptor.owner().ok_or_else(insecure)?;
        let sddl = wrappers::ConvertSecurityDescriptorToStringSecurityDescriptor(
            &descriptor,
            SecurityInformation::Dacl,
        )?;
        let sddl = sddl.to_string_lossy();
        // The dependency's dacl() panics for a valid null DACL. Inspect the safe
        // conversion first and refuse unrestricted access before touching it.
        if !sddl.starts_with("D:P")
            || sddl.contains("NO_ACCESS_CONTROL")
            || sddl
                .split('(')
                .skip(1)
                .any(|entry| !entry.starts_with("A;"))
        {
            return Err(insecure());
        }
        let acl = descriptor.dacl().ok_or_else(insecure)?;
        if acl.len() == 0 || acl.len() > 32 {
            return Err(insecure());
        }
        for index in 0..acl.len() {
            let ace = acl.get_ace(index).ok_or_else(insecure)?;
            if ace.ace_type() != AceType::ACCESS_ALLOWED_ACE_TYPE {
                return Err(insecure());
            }
            let sid = ace.sid().ok_or_else(insecure)?;
            if sid != owner && !matches!(sid.to_string().as_str(), "S-1-5-18" | "S-1-5-32-544") {
                return Err(insecure());
            }
        }
        Ok(())
    }
}
