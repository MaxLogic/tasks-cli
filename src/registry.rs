use crate::error::AppError;
use crate::storage::{acquire_exclusive_lock, validate_storage_path, validate_storage_root};
use crate::store::{create_project_db_with_key, data_root_project_path, StoreInfo};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use uuid::Uuid;

const PROJECT_IDENTITY_FILE: &str = ".tasks.json";
const MAX_PROJECT_IDENTITY_BYTES: u64 = 4096;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ProjectIdentity {
    project_id: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct RegistryBinding {
    pub root: String,
    pub project_id: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Registry {
    pub format_version: u32,
    pub bindings: Vec<RegistryBinding>,
}

impl Default for Registry {
    fn default() -> Self {
        Self {
            format_version: 1,
            bindings: Vec::new(),
        }
    }
}

impl Registry {
    fn load(path: &Path) -> Result<Self, AppError> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let bytes =
            std::fs::read(path).map_err(|error| AppError::io_path("read registry", path, error))?;
        if bytes.is_empty() {
            return Ok(Self::default());
        }
        serde_json::from_slice(&bytes)
            .map_err(|error| AppError::Registry(format!(
                "registry file {} is not valid JSON: {error}; fix or remove the file, then run tasks init to recreate it",
                path.display()
            )))
    }

    fn store(&self, path: &Path) -> Result<(), AppError> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| AppError::io_path("create directory for", parent, error))?;
        }
        let tmp = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec_pretty(self)?;
        fs::write(&tmp, bytes)
            .map_err(|error| AppError::io_path("write registry file", &tmp, error))?;
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&tmp)
            .map_err(|error| AppError::io_path("open registry file", &tmp, error))?;
        file.sync_all()
            .map_err(|error| AppError::io_path("flush registry file", &tmp, error))?;
        drop(file);
        fs::rename(&tmp, path)
            .map_err(|error| AppError::io_path("replace registry file", path, error))?;
        Ok(())
    }

    pub fn with_bindings(
        data_root: &Path,
        mut f: impl FnMut(&mut Self) -> Result<(), AppError>,
    ) -> Result<Self, AppError> {
        let data_root = validate_storage_root(data_root)?;
        let path = registry_path(&data_root);
        fs::create_dir_all(&data_root)
            .map_err(|error| AppError::io_path("create data root", &data_root, error))?;
        let lock_path = data_root.join("registry.lock");
        let _lock = acquire_exclusive_lock(&lock_path)?;
        let mut registry = Self::load(&path)?;
        f(&mut registry)?;
        registry.store(&path)?;
        Ok(registry)
    }
}

pub fn default_data_root() -> PathBuf {
    if cfg!(windows) {
        let local = std::env::var("LOCALAPPDATA").unwrap_or_else(|_| ".".to_string());
        PathBuf::from(local).join("MaxLogic").join("tasks-cli")
    } else {
        if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
            if Path::new(&xdg).is_absolute() {
                return PathBuf::from(xdg).join("MaxLogic").join("tasks-cli");
            }
        }
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        PathBuf::from(home)
            .join(".local")
            .join("share")
            .join("MaxLogic")
            .join("tasks-cli")
    }
}

fn registry_path(data_root: &Path) -> PathBuf {
    data_root.join("registry.json")
}

fn normalize_for_match(path: &Path) -> Vec<String> {
    let comps = path
        .components()
        .map(|c| c.as_os_str().to_string_lossy().to_string())
        .collect::<Vec<_>>();
    if cfg!(windows) {
        comps.into_iter().map(|c| c.to_ascii_lowercase()).collect()
    } else {
        comps
    }
}

fn is_descendant(ancestor: &Path, child: &Path) -> Result<bool, AppError> {
    let anc = match ancestor.canonicalize() {
        Ok(path) => path,
        Err(_) => return Ok(false),
    };
    let ch = match child.canonicalize() {
        Ok(path) => path,
        Err(_) => return Ok(false),
    };
    let a = normalize_for_match(&anc);
    let b = normalize_for_match(&ch);
    if b.len() < a.len() {
        return Ok(false);
    }
    Ok(a.iter().zip(b.iter()).all(|(x, y)| x == y))
}

fn canonical_project_id(project: &str) -> Result<String, AppError> {
    Uuid::parse_str(project.trim())
        .map(|id| id.to_string())
        .map_err(|_| {
            AppError::Usage(format!(
                "--project '{project}' is not a UUID; pass the UUID printed by tasks init"
            ))
        })
}

fn read_identity(path: &Path) -> Result<Option<String>, AppError> {
    let entry = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(AppError::io_path("inspect project identity", path, error)),
    };
    // On Windows is_symlink() also includes junctions. Only file symlinks
    // are eligible here; directory links and other reparse points stay rejected.
    #[cfg(windows)]
    let is_file_link = {
        use std::os::windows::fs::FileTypeExt;
        entry.file_type().is_symlink_file()
    };
    #[cfg(not(windows))]
    let is_file_link = entry.is_symlink();
    if !is_file_link && !ordinary_identity_file(&entry) {
        return Err(AppError::Validation(format!(
            "{} must be an ordinary file containing only a project_id",
            path.display()
        )));
    }
    let metadata = if is_file_link {
        fs::metadata(path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                match fs::read_link(path) {
                    Ok(target) => {
                        // Relative targets resolve against the link's directory.
                        let target = path
                            .parent()
                            .unwrap_or_else(|| Path::new("."))
                            .join(target);
                        if fs::symlink_metadata(&target).is_ok() {
                            AppError::Validation(format!(
                                "project identity link {} points to {}, which is a link to a missing target",
                                path.display(),
                                target.display()
                            ))
                        } else {
                            AppError::Validation(format!(
                                "project identity link {} points to missing {}",
                                path.display(),
                                target.display()
                            ))
                        }
                    }
                    Err(error) => AppError::io_path("read project identity link", path, error),
                }
            } else {
                AppError::io_path("inspect project identity target", path, error)
            }
        })?
    } else {
        entry
    };
    validate_identity_metadata(path, &metadata)?;

    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // A concurrent replacement with a FIFO must not block before the
        // opened handle's type can be checked.
        options.custom_flags(rustix::fs::OFlags::NONBLOCK.bits() as i32);
    }
    let file = options
        .open(path)
        .map_err(|error| AppError::io_path("open project identity", path, error))?;
    let metadata = file
        .metadata()
        .map_err(|error| AppError::io_path("inspect opened project identity", path, error))?;
    validate_identity_metadata(path, &metadata)?;
    let mut bytes = Vec::new();
    file.take(MAX_PROJECT_IDENTITY_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| AppError::io_path("read project identity", path, error))?;
    if bytes.len() as u64 > MAX_PROJECT_IDENTITY_BYTES {
        return Err(AppError::Validation(format!(
            "{} grew beyond the {} byte project identity limit while it was read",
            path.display(),
            MAX_PROJECT_IDENTITY_BYTES
        )));
    }
    let identity: ProjectIdentity = serde_json::from_slice(&bytes).map_err(|error| {
            AppError::Validation(format!(
                "{} is not a valid project identity: {error}; it must contain only {{\"project_id\":\"<canonical-lowercase-UUID>\"}}",
                path.display()
            ))
        })?;
    let canonical = Uuid::parse_str(&identity.project_id)
        .map(|id| id.to_string())
        .map_err(|_| {
            AppError::Validation(format!(
                "{} project_id '{}' is not a UUID",
                path.display(),
                identity.project_id
            ))
        })?;
    if identity.project_id != canonical {
        return Err(AppError::Validation(format!(
            "{} project_id must be canonical lowercase UUID text; use '{}'",
            path.display(),
            canonical
        )));
    }
    Ok(Some(canonical))
}

fn ordinary_identity_file(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return false;
        }
    }
    metadata.is_file()
}

fn validate_identity_metadata(path: &Path, metadata: &fs::Metadata) -> Result<(), AppError> {
    if !ordinary_identity_file(metadata) {
        return Err(AppError::Validation(format!(
            "{} must be an ordinary file containing only a project_id",
            path.display()
        )));
    }
    if metadata.len() > MAX_PROJECT_IDENTITY_BYTES {
        return Err(AppError::Validation(format!(
            "{} is {} bytes; project identity files are limited to {} bytes",
            path.display(),
            metadata.len(),
            MAX_PROJECT_IDENTITY_BYTES
        )));
    }
    Ok(())
}

fn identity_project(route_from: &Path) -> Result<Option<String>, AppError> {
    for ancestor in route_from.ancestors() {
        if let Some(project) = read_identity(&ancestor.join(PROJECT_IDENTITY_FILE))? {
            return Ok(Some(project));
        }
    }
    Ok(None)
}

pub fn project_identity_at_root(root: &Path) -> Result<Option<Uuid>, AppError> {
    let canonical_root = root.canonicalize().map_err(|error| {
        AppError::Registry(format!(
            "cannot resolve root {}: {error}; check that the directory exists",
            root.display()
        ))
    })?;
    read_identity(&canonical_root.join(PROJECT_IDENTITY_FILE))?
        .map(|project| {
            Uuid::parse_str(&project).map_err(|error| {
                AppError::Validation(format!(
                    "invalid project identity UUID '{project}': {error}"
                ))
            })
        })
        .transpose()
}

pub fn write_project_identity(root: &Path, project_id: &Uuid) -> Result<PathBuf, AppError> {
    let canonical_root = root.canonicalize().map_err(|error| {
        AppError::Registry(format!(
            "cannot resolve root {}: {error}; check that the directory exists",
            root.display()
        ))
    })?;
    let path = canonical_root.join(PROJECT_IDENTITY_FILE);
    if let Some(existing) = read_identity(&path)? {
        if existing == project_id.to_string() {
            return Ok(path);
        }
        return Err(AppError::Validation(format!(
            "{} already selects project {existing}; refusing to overwrite it with {project_id}",
            path.display()
        )));
    }

    let mut file = match OpenOptions::new().create_new(true).write(true).open(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            if read_identity(&path)?.as_deref() == Some(&project_id.to_string()) {
                return Ok(path);
            }
            return Err(AppError::Validation(format!(
                "{} appeared while the identity was being created and selects another project; refusing to overwrite it",
                path.display()
            )));
        }
        Err(error) => return Err(AppError::io_path("create project identity", &path, error)),
    };
    let bytes = format!("{{\"project_id\":\"{project_id}\"}}\n");
    if let Err(error) = file
        .write_all(bytes.as_bytes())
        .and_then(|()| file.sync_all())
    {
        drop(file);
        let _ = fs::remove_file(&path);
        return Err(AppError::io_path("write project identity", &path, error));
    }
    Ok(path)
}

pub fn resolve_project(
    data_root: &Path,
    explicit_project: Option<&str>,
    fallback_root: Option<&Path>,
) -> Result<String, AppError> {
    let data_root = validate_storage_root(data_root)?;
    if let Some(project) = explicit_project {
        return canonical_project_id(project);
    }
    let current_dir = std::env::current_dir()
        .map_err(|error| AppError::io_op("resolve the current directory", error))?;
    let route_from = fallback_root.unwrap_or(&current_dir);
    if let Some(project) = identity_project(route_from)? {
        return Ok(project);
    }
    let reg = Registry::load(&registry_path(&data_root))?;
    let mut winner: Option<(usize, RegistryBinding)> = None;
    for b in reg.bindings.iter() {
        if is_descendant(Path::new(&b.root), route_from)? {
            let anc_len = Path::new(&b.root).components().count();
            match &winner {
                Some((best, _)) if *best >= anc_len => {}
                _ => winner = Some((anc_len, b.clone())),
            }
        }
    }
    winner
        .map(|(_, b)| canonical_project_id(&b.project_id))
        .ok_or_else(|| {
            AppError::NotFound(format!(
                "no project is bound to {} or any parent directory (registry {}); run tasks init --root {} to create and bind one, or pass --project <UUID>",
                route_from.display(),
                registry_path(&data_root).display(),
                route_from.display()
            ))
        })?
}

/// Resolve an exact legacy workspace binding without opening a project store.
pub fn bound_project_at_root(data_root: &Path, root: &Path) -> Result<Option<Uuid>, AppError> {
    let data_root = validate_storage_root(data_root)?;
    let registry = Registry::load(&registry_path(&data_root))?;
    for binding in registry.bindings {
        if same_path(Path::new(&binding.root), root) {
            return canonical_project_id(&binding.project_id).and_then(|id| {
                Uuid::parse_str(&id)
                    .map(Some)
                    .map_err(|_| AppError::Registry("invalid bound project UUID".into()))
            });
        }
    }
    Ok(None)
}

pub fn bind_root(
    data_root: &Path,
    root: &Path,
    project: Option<String>,
) -> Result<String, AppError> {
    bind_root_inner(data_root, root, project, true)
}

/// The remote backend has already validated server ownership. This writes only
/// workspace routing and never inspects a leftover local project database.
pub fn bind_remote_root(
    data_root: &Path,
    root: &Path,
    project: String,
) -> Result<String, AppError> {
    let id = canonical_project_id(&project)?;
    if project_identity_at_root(root)?.is_some_and(|existing| existing.to_string() != id) {
        return Err(AppError::Validation(
            "workspace identity selects another project; refusing to replace it".into(),
        ));
    }
    let bound = bind_root_inner(data_root, root, Some(id.clone()), false)?;
    write_project_identity(
        root,
        &Uuid::parse_str(&id).map_err(|_| AppError::Validation("invalid project UUID".into()))?,
    )?;
    Ok(bound)
}
fn bind_root_inner(
    data_root: &Path,
    root: &Path,
    project: Option<String>,
    local: bool,
) -> Result<String, AppError> {
    let data_root = validate_storage_root(data_root)?;
    let mut canonical_root = root.to_path_buf();
    canonical_root = canonical_root.canonicalize().map_err(|error| {
        AppError::Registry(format!(
            "cannot resolve root {}: {error}; check that the directory exists",
            root.display()
        ))
    })?;
    let project = match project {
        Some(project) => project,
        None => {
            return Err(AppError::Usage(
                "bind requires a project id: run tasks bind --root <dir> --project <UUID> (tasks init prints the UUID)"
                    .to_string(),
            ))
        }
    };
    let project = canonical_project_id(&project)?;
    let mut bound_existing = false;
    let mut found_project = project.clone();
    Registry::with_bindings(&data_root, |registry| {
        // Keep validation protected from bulk cleanup until the binding is saved.
        if local {
            crate::store::Store::open_readonly(&data_root, &project)?;
        }
        if let Some(existing) = registry
            .bindings
            .iter()
            .find(|b| same_path(Path::new(&b.root), &canonical_root))
            .cloned()
        {
            if existing.project_id != project {
                return Err(AppError::Usage(format!(
                    "root {} is already bound to project {}; pass --project {} to reuse that binding or choose another root",
                    root.display(),
                    existing.project_id,
                    existing.project_id
                )));
            }
            bound_existing = true;
            found_project = existing.project_id.clone();
            return Ok(());
        }
        if registry
            .bindings
            .iter()
            .any(|b| b.project_id == project && !same_path(Path::new(&b.root), &canonical_root))
        {
            bound_existing = true;
        }
        registry.bindings.push(RegistryBinding {
            root: canonical_root.to_string_lossy().to_string(),
            project_id: project.clone(),
        });
        Ok(())
    })?;
    Ok(if bound_existing {
        found_project
    } else {
        project
    })
}

/// Runs `f` while holding the registry lock without rewriting the registry.
/// Project-key changes use it so a key check and its write cannot interleave
/// with another `init`, `project-key --set` or bulk apply.
pub fn with_registry_lock<T>(
    data_root: &Path,
    f: impl FnOnce(&Path) -> Result<T, AppError>,
) -> Result<T, AppError> {
    let data_root = validate_storage_root(data_root)?;
    fs::create_dir_all(&data_root)
        .map_err(|error| AppError::io_path("create data root", &data_root, error))?;
    let _lock = acquire_exclusive_lock(&data_root.join("registry.lock"))?;
    f(&data_root)
}

/// Creates or validates the project database under the registry lock. A new
/// database receives `key` after the key is checked against every project in
/// the data root; an existing one must already hold exactly that key. The
/// key check's refreshed cache is returned for the caller to store once its
/// whole change has committed.
pub fn create_or_verify_keyed(
    data_root: &Path,
    project_id: &Uuid,
    key: Option<&str>,
) -> Result<(StoreInfo, Option<crate::keys::CacheUpdate>), AppError> {
    let update = match key {
        Some(key) => Some(crate::keys::ensure_available(
            data_root,
            key,
            Some(project_id),
        )?),
        None => None,
    };
    let info = create_project_db_with_key(data_root, project_id, key)?;
    if let Some(key) = key {
        if info.project_key.as_deref() != Some(key) {
            return Err(AppError::Validation(format!(
                "project {project_id} already exists with {}; init does not change keys. Run tasks project-key --set {key} --project {project_id} to change it",
                match info.project_key.as_deref() {
                    Some(existing) => format!("key {existing}"),
                    None => "no key".to_string(),
                }
            )));
        }
    }
    Ok((info, update))
}

pub fn init_root(
    data_root: &Path,
    root: &Path,
    explicit_project: Option<Uuid>,
    key: Option<&str>,
) -> Result<StoreInfo, AppError> {
    init_root_with_prepare(
        data_root,
        root,
        explicit_project,
        key,
        create_project_db_with_key,
    )
}

fn init_root_with_prepare(
    data_root: &Path,
    root: &Path,
    explicit_project: Option<Uuid>,
    key: Option<&str>,
    prepare: impl FnOnce(&Path, &Uuid, Option<&str>) -> Result<StoreInfo, AppError>,
) -> Result<StoreInfo, AppError> {
    let data_root = validate_storage_root(data_root)?;
    let canonical_root = root.canonicalize().map_err(|error| {
        AppError::Registry(format!(
            "cannot resolve root {}: {error}; check that the directory exists",
            root.display()
        ))
    })?;
    fs::create_dir_all(&data_root)
        .map_err(|error| AppError::io_path("create data root", &data_root, error))?;
    let project_id = explicit_project.unwrap_or_else(Uuid::new_v4);
    let path = registry_path(&data_root);
    // This snapshot only avoids unnecessary preparation. Binding and key
    // ownership are checked again under the lock before anything is published.
    let snapshot = Registry::load(&path)?;
    let needs_database = !data_root_project_path(&data_root, &project_id.to_string()).exists()
        && !snapshot
            .bindings
            .iter()
            .any(|binding| same_path(Path::new(&binding.root), &canonical_root));
    let prepared = if needs_database {
        // SQLite WAL setup, FULL commits, close-time checkpoints and schema
        // validation can stall on storage. Keep them outside the global lock.
        // A non-UUID staging directory is invisible to key scans. Place it next
        // to the destination, including when projects/ or the UUID directory is
        // a link to another local volume, so publication is a same-volume rename.
        let db_path = data_root_project_path(&data_root, &project_id.to_string());
        validate_storage_path(&db_path)?;
        let project_dir = db_path
            .parent()
            .ok_or_else(|| AppError::Registry("project database has no parent directory".into()))?;
        let staging_parent = if project_dir.is_dir() {
            project_dir
        } else {
            project_dir.parent().ok_or_else(|| {
                AppError::Registry("project directory has no parent directory".into())
            })?
        };
        fs::create_dir_all(staging_parent).map_err(|error| {
            AppError::io_path("create project staging directory", staging_parent, error)
        })?;
        let staging = tempfile::Builder::new()
            .prefix(".init-")
            .tempdir_in(staging_parent)
            .map_err(|error| AppError::io_path("stage project database in", &data_root, error))?;
        let info = match prepare(staging.path(), &project_id, key) {
            Ok(info) => info,
            Err(error) => {
                staging.close().map_err(|cleanup| {
                    AppError::io_path("remove staged project database from", &data_root, cleanup)
                })?;
                return Err(error);
            }
        };
        Some((staging, info))
    } else {
        None
    };
    let result = init_root_locked(
        &data_root,
        &canonical_root,
        explicit_project,
        project_id,
        key,
        prepared.as_ref().map(|(_, info)| info),
    );
    if let Some((staging, _)) = prepared {
        staging.close().map_err(|error| {
            AppError::io_path("remove staged project database from", &data_root, error)
        })?;
    }
    result
}

fn init_root_locked(
    data_root: &Path,
    canonical_root: &Path,
    explicit_project: Option<Uuid>,
    project_id: Uuid,
    key: Option<&str>,
    prepared: Option<&StoreInfo>,
) -> Result<StoreInfo, AppError> {
    let lock_path = data_root.join("registry.lock");
    let _lock = acquire_exclusive_lock(&lock_path)?;
    let path = registry_path(data_root);
    let mut registry = Registry::load(&path)?;
    if let Some(existing) = registry
        .bindings
        .iter()
        .find(|binding| same_path(Path::new(&binding.root), canonical_root))
    {
        let existing_id = Uuid::parse_str(&existing.project_id).map_err(|_| {
            AppError::Registry(format!(
                "registry {} binds root {} to invalid project id '{}'; fix the registry file",
                path.display(),
                existing.root,
                existing.project_id
            ))
        })?;
        if let Some(requested) = explicit_project {
            if requested != existing_id {
                return Err(AppError::Usage(format!(
                    "root {} is already bound to project {}; pass --project {} to reuse that binding or choose another root",
                    canonical_root.display(),
                    existing.project_id,
                    existing.project_id
                )));
            }
        }
        let (info, update) = create_or_verify_keyed(data_root, &existing_id, key)?;
        if let Some(update) = update {
            update.store(data_root);
        }
        return Ok(info);
    }
    let (info, update) = if let Some(prepared) = prepared {
        let update = key
            .map(|key| crate::keys::ensure_available(data_root, key, Some(&project_id)))
            .transpose()?;
        let db_path = data_root_project_path(data_root, &project_id.to_string());
        validate_storage_path(&db_path)?;
        let parent = db_path
            .parent()
            .ok_or_else(|| AppError::Registry("project database has no parent directory".into()))?;
        fs::create_dir_all(parent)
            .map_err(|error| AppError::io_path("create the project directory", parent, error))?;
        let create_lock = acquire_exclusive_lock(&db_path.with_extension("create.lock"))?;
        if db_path.exists() {
            // Another init (or library caller) published this UUID while it was
            // being prepared. Validate its database and key; never replace it.
            drop(create_lock);
            create_or_verify_keyed(data_root, &project_id, key)?
        } else {
            // The SQLite commit is already durable. Make the published name
            // durable too before a registry binding can refer to it.
            #[cfg(windows)]
            atomicwrites::move_atomic(&prepared.db_path, &db_path)
                .map_err(|error| AppError::io_path("publish project database", &db_path, error))?;
            #[cfg(not(windows))]
            {
                fs::rename(&prepared.db_path, &db_path).map_err(|error| {
                    AppError::io_path("publish project database", &db_path, error)
                })?;
                fs::File::open(parent)
                    .and_then(|directory| directory.sync_all())
                    .map_err(|error| AppError::io_path("flush project directory", parent, error))?;
            }
            (
                StoreInfo {
                    project_id,
                    db_path,
                    project_key: prepared.project_key.clone(),
                },
                update,
            )
        }
    } else {
        create_or_verify_keyed(data_root, &project_id, key)?
    };
    registry.bindings.push(RegistryBinding {
        root: canonical_root.to_string_lossy().to_string(),
        project_id: project_id.to_string(),
    });
    registry.store(&path)?;
    if let Some(update) = update {
        update.store(data_root);
    }
    Ok(info)
}

/// Remove one root/project binding. Only a caller that knows it created the
/// binding (for example a rollback of a failed bulk apply) may call this; it
/// never touches any other binding.
pub fn remove_binding(data_root: &Path, root: &Path, project_id: &str) -> Result<(), AppError> {
    let canonical_root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    Registry::with_bindings(data_root, |registry| {
        registry.bindings.retain(|binding| {
            !(same_path(Path::new(&binding.root), &canonical_root)
                && binding.project_id.eq_ignore_ascii_case(project_id))
        });
        Ok(())
    })?;
    Ok(())
}

fn same_path(left: &Path, right: &Path) -> bool {
    if cfg!(windows) {
        left.to_string_lossy()
            .eq_ignore_ascii_case(&right.to_string_lossy())
    } else {
        left == right
    }
}

#[allow(dead_code)]
pub fn list_bindings(data_root: &Path) -> Result<Registry, AppError> {
    let data_root = validate_storage_root(data_root)?;
    Registry::load(&registry_path(&data_root))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_database_preparation_does_not_hold_registry_lock() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("workspace");
        fs::create_dir(&root).unwrap();
        let data = temp.path().join("data");
        let info = init_root_with_prepare(&data, &root, None, Some("NEW"), |staging, id, key| {
            let info = create_project_db_with_key(staging, id, key)?;
            // A stalled database flush must not block every other project init.
            let _probe = crate::storage::acquire_exclusive_lock_for(
                &data.join("registry.lock"),
                std::time::Duration::from_millis(40),
            )?;
            Ok(info)
        })
        .expect("database preparation must leave the registry available");
        assert_eq!(info.project_key.as_deref(), Some("NEW"));
        assert_eq!(
            Registry::load(&registry_path(&data))
                .unwrap()
                .bindings
                .len(),
            1
        );
    }

    #[test]
    fn init_does_not_scan_another_writers_uncommitted_database() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("workspace");
        fs::create_dir(&root).unwrap();
        let data = temp.path().join("data");
        let other = create_project_db_with_key(&data, &Uuid::new_v4(), Some("HLD")).unwrap();
        let registry_guard = acquire_exclusive_lock(&data.join("registry.lock")).unwrap();
        let conn = rusqlite::Connection::open(&other.db_path).unwrap();
        conn.execute_batch("PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE;")
            .unwrap();
        let result = init_root_with_prepare(&data, &root, None, Some("NEW"), |staging, id, key| {
            let info = create_project_db_with_key(staging, id, key)?;
            // Model another registry writer finishing while we prepare. Its
            // database must not be scanned before its registry lock is released.
            conn.execute_batch("COMMIT")?;
            drop(registry_guard);
            Ok(info)
        });
        assert!(result.is_ok(), "{:#?}", result.err());
        assert_eq!(crate::keys::scan(&data, true).unwrap().len(), 2);
    }

    #[test]
    fn prepared_init_rechecks_key_ownership_before_publishing() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("first");
        let other = temp.path().join("second");
        fs::create_dir(&root).unwrap();
        fs::create_dir(&other).unwrap();
        let data = temp.path().join("data");
        let result = init_root_with_prepare(&data, &root, None, Some("DUP"), |staging, id, key| {
            let info = create_project_db_with_key(staging, id, key)?;
            // The prepared key is unpublished and cannot prevent this winner.
            init_root(&data, &other, None, key)?;
            Ok(info)
        });
        assert!(
            matches!(result, Err(AppError::Validation(message)) if message.contains("already used"))
        );
        let registry = Registry::load(&registry_path(&data)).unwrap();
        assert_eq!(registry.bindings.len(), 1);
        assert!(same_path(
            Path::new(&registry.bindings[0].root),
            &other.canonicalize().unwrap()
        ));
        assert_eq!(fs::read_dir(data.join("projects")).unwrap().count(), 1);
        let projects = crate::keys::scan(&data, true).unwrap();
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0].key.as_deref(), Some("DUP"));
    }

    #[test]
    fn prepared_init_never_replaces_a_concurrently_created_uuid() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("first");
        let other = temp.path().join("second");
        fs::create_dir(&root).unwrap();
        fs::create_dir(&other).unwrap();
        let data = temp.path().join("data");
        let project = Uuid::new_v4();
        let result = init_root_with_prepare(
            &data,
            &root,
            Some(project),
            Some("OLD"),
            |staging, id, key| {
                let info = create_project_db_with_key(staging, id, key)?;
                init_root(&data, &other, Some(project), Some("WIN"))?;
                Ok(info)
            },
        );
        assert!(
            matches!(result, Err(AppError::Validation(message)) if message.contains("init does not change keys"))
        );
        let registry = Registry::load(&registry_path(&data)).unwrap();
        assert_eq!(registry.bindings.len(), 1);
        assert_eq!(fs::read_dir(data.join("projects")).unwrap().count(), 1);
        let projects = crate::keys::scan(&data, true).unwrap();
        assert_eq!(projects[0].project_id, project);
        assert_eq!(projects[0].key.as_deref(), Some("WIN"));
    }
}
