use crate::error::AppError;
use crate::storage::{acquire_exclusive_lock, validate_storage_root};
use crate::store::{create_project_db, StoreInfo};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

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
        let bytes = std::fs::read(path)?;
        if bytes.is_empty() {
            return Ok(Self::default());
        }
        serde_json::from_slice(&bytes)
            .map_err(|e| AppError::Registry(format!("invalid registry {e}")))
    }

    fn store(&self, path: &Path) -> Result<(), AppError> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec_pretty(self)?;
        fs::write(&tmp, bytes)?;
        let file = fs::OpenOptions::new().read(true).write(true).open(&tmp)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&tmp, path)?;
        Ok(())
    }

    pub fn with_bindings(
        data_root: &Path,
        mut f: impl FnMut(&mut Self) -> Result<(), AppError>,
    ) -> Result<Self, AppError> {
        let data_root = validate_storage_root(data_root)?;
        let path = registry_path(&data_root);
        fs::create_dir_all(&data_root)?;
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

pub fn resolve_project(
    data_root: &Path,
    explicit_project: Option<&str>,
    fallback_root: Option<&Path>,
) -> Result<String, AppError> {
    let data_root = validate_storage_root(data_root)?;
    let reg = Registry::load(&registry_path(&data_root))?;
    if let Some(project) = explicit_project {
        let p = project.trim().to_string();
        if Uuid::parse_str(&p).is_err() {
            return Err(AppError::Usage(format!("invalid project id '{p}'")));
        }
        return Ok(p);
    }
    let current_dir = std::env::current_dir()?;
    let route_from = fallback_root.unwrap_or(&current_dir);
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
        .map(|(_, b)| b.project_id)
        .ok_or_else(|| AppError::NotFound("no project bound for current directory".to_string()))
}

pub fn bind_root(
    data_root: &Path,
    root: &Path,
    project: Option<String>,
) -> Result<String, AppError> {
    let data_root = validate_storage_root(data_root)?;
    let mut canonical_root = root.to_path_buf();
    canonical_root = canonical_root
        .canonicalize()
        .map_err(|_| AppError::Registry(format!("cannot canonicalize root {:?}", root)))?;
    let project = match project {
        Some(project) => project,
        None => return Err(AppError::Usage("bind requires a project id".to_string())),
    };
    if Uuid::parse_str(&project).is_err() {
        return Err(AppError::Usage(format!("invalid project id '{project}'")));
    }
    let project_db = data_root
        .join("projects")
        .join(&project)
        .join("TASKS.sqlite");
    if !project_db.is_file() {
        return Err(AppError::NotFoundCode(format!(
            "project database not found: {}",
            project_db.display()
        )));
    }
    let mut bound_existing = false;
    let mut found_project = project.clone();
    Registry::with_bindings(&data_root, |registry| {
        if let Some(existing) = registry
            .bindings
            .iter()
            .find(|b| same_path(Path::new(&b.root), &canonical_root))
            .cloned()
        {
            if existing.project_id != project {
                return Err(AppError::Usage(format!(
                    "root {:?} is already bound to a different project {}",
                    root, existing.project_id
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

pub fn init_root(
    data_root: &Path,
    root: &Path,
    explicit_project: Option<Uuid>,
) -> Result<StoreInfo, AppError> {
    let data_root = validate_storage_root(data_root)?;
    let canonical_root = root
        .canonicalize()
        .map_err(|_| AppError::Registry(format!("cannot canonicalize root {:?}", root)))?;
    fs::create_dir_all(&data_root)?;
    let lock_path = data_root.join("registry.lock");
    let _lock = acquire_exclusive_lock(&lock_path)?;
    let path = registry_path(&data_root);
    let mut registry = Registry::load(&path)?;
    if let Some(existing) = registry
        .bindings
        .iter()
        .find(|binding| same_path(Path::new(&binding.root), &canonical_root))
    {
        let existing_id = Uuid::parse_str(&existing.project_id)
            .map_err(|_| AppError::Registry("binding contains invalid project id".to_string()))?;
        if let Some(requested) = explicit_project {
            if requested != existing_id {
                return Err(AppError::Usage(format!(
                    "root {:?} is already bound to a different project {}",
                    root, existing.project_id
                )));
            }
        }
        return create_project_db(&data_root, &existing_id);
    }
    let project_id = explicit_project.unwrap_or_else(Uuid::new_v4);
    let info = create_project_db(&data_root, &project_id)?;
    registry.bindings.push(RegistryBinding {
        root: canonical_root.to_string_lossy().to_string(),
        project_id: project_id.to_string(),
    });
    registry.store(&path)?;
    Ok(info)
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
