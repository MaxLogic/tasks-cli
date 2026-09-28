//! Project keys (`DAK` in `DAK-212`): uniqueness across one data root and the
//! lookup of the project that owns a key.
//!
//! A key lives only in its project database. Uniqueness checks (`init`,
//! `project-key --set`, bulk apply) always open and read every project
//! database under `<data-root>/projects/` with [`scan`].
//!
//! Lookups that only resolve a reference (`enrich`, the owner named by a
//! foreign `KEY-N`, import's foreign-heading check) use [`scan_cached`]:
//! opening a SQLite database costs milliseconds on Windows, so
//! `<data-root>/project-keys.json` caches each database's key next to its file
//! fingerprint (identity, size and modification time of the database and of
//! a non-empty WAL or journal). A database whose fingerprint differs is read
//! again, so a stale or concurrently rewritten cache costs time but never
//! yields a wrong key. The cache is derived data, rewritten atomically only by
//! [`scan_cached`].

use crate::error::AppError;
use crate::model::render_keyed_task_id;
use crate::registry;
use crate::storage::validate_storage_root;
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;
use uuid::Uuid;

/// One project database found under `<data-root>/projects/`.
#[derive(Debug, Clone)]
pub struct KeyedProject {
    pub project_id: Uuid,
    pub key: Option<String>,
    pub db_path: PathBuf,
}

/// Reads the stored key; databases from before project keys have none.
pub fn read_key(conn: &Connection) -> rusqlite::Result<Option<String>> {
    let has_column: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM pragma_table_info('project') WHERE name='project_key')",
        [],
        |row| row.get(0),
    )?;
    if !has_column {
        return Ok(None);
    }
    Ok(conn
        .query_row("SELECT project_key FROM project LIMIT 1", [], |row| {
            row.get::<_, Option<String>>(0)
        })
        .optional()?
        .flatten())
}

fn read_key_at(db_path: &Path) -> Result<Option<String>, AppError> {
    let conn = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    conn.busy_timeout(Duration::from_secs(5))?;
    Ok(read_key(&conn)?)
}

/// Identity, size and modification time of the database and of a non-empty
/// WAL or rollback journal. Empty sidecars count as absent because a
/// read-only reader may create an empty WAL without changing any data.
fn fingerprint(db_path: &Path) -> String {
    let mut parts = Vec::with_capacity(3);
    for suffix in ["", "-wal", "-journal"] {
        let mut name = db_path.as_os_str().to_os_string();
        name.push(suffix);
        let path = PathBuf::from(name);
        let part = match fs::metadata(&path) {
            Ok(meta) if suffix.is_empty() || meta.len() > 0 => {
                let identity = file_id::get_file_id(&path)
                    .map(|id| format!("{id:?}"))
                    .unwrap_or_else(|_| "unavailable".to_string());
                format!("{identity}:{:?}:{}", meta.modified().ok(), meta.len())
            }
            _ => "-".to_string(),
        };
        parts.push(part);
    }
    parts.join("|")
}

const CACHE_FILE: &str = "project-keys.json";
const CACHE_FORMAT: u32 = 1;

#[derive(Debug, Default, Serialize, Deserialize)]
struct KeyCache {
    format_version: u32,
    projects: BTreeMap<String, CachedKey>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct CachedKey {
    fingerprint: String,
    key: Option<String>,
}

fn load_cache(data_root: &Path) -> KeyCache {
    fs::read(data_root.join(CACHE_FILE))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<KeyCache>(&bytes).ok())
        .filter(|cache| cache.format_version == CACHE_FORMAT)
        .unwrap_or_default()
}

/// Best effort: a failed write only costs the next scan its shortcut.
fn store_cache(data_root: &Path, cache: &KeyCache) {
    let Ok(bytes) = serde_json::to_vec(cache) else {
        return;
    };
    let path = data_root.join(CACHE_FILE);
    let temp = data_root.join(format!("{CACHE_FILE}.{}.tmp", std::process::id()));
    if fs::write(&temp, bytes).is_ok() && fs::rename(&temp, &path).is_err() {
        let _ = fs::remove_file(&temp);
    }
}

/// Every project database under `<data-root>/projects/<uuid>/TASKS.sqlite`
/// with its key. `strict` fails on a database that cannot be read, because a
/// uniqueness check cannot vouch for it; otherwise such a project is skipped.
/// Directories that are not canonical UUIDs or hold no database are ignored.
/// Reads every database directly; never touches the key cache.
pub fn scan(data_root: &Path, strict: bool) -> Result<Vec<KeyedProject>, AppError> {
    scan_with(data_root, strict, false)
}

/// Lenient [`scan`] through the key cache, which it rewrites when it changed.
/// For reference lookups only, never for uniqueness checks.
pub fn scan_cached(data_root: &Path) -> Result<Vec<KeyedProject>, AppError> {
    scan_with(data_root, false, true)
}

fn scan_with(
    data_root: &Path,
    strict: bool,
    use_cache: bool,
) -> Result<Vec<KeyedProject>, AppError> {
    let projects_dir = data_root.join("projects");
    let entries = match fs::read_dir(&projects_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(AppError::io_path(
                "list project databases in",
                &projects_dir,
                error,
            ))
        }
    };
    let cache = if use_cache {
        load_cache(data_root)
    } else {
        KeyCache::default()
    };
    let mut fresh = KeyCache {
        format_version: CACHE_FORMAT,
        projects: BTreeMap::new(),
    };
    let mut projects = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| {
            AppError::io_path("list project databases in", &projects_dir, error)
        })?;
        let name = entry.file_name();
        let Some(project_id) = name.to_str().and_then(|text| {
            Uuid::parse_str(text)
                .ok()
                .filter(|id| id.to_string() == text)
        }) else {
            continue;
        };
        let db_path = entry.path().join("TASKS.sqlite");
        if !db_path.is_file() {
            continue;
        }
        let fingerprint = fingerprint(&db_path);
        let cached = cache
            .projects
            .get(&project_id.to_string())
            .filter(|cached| cached.fingerprint == fingerprint)
            .map(|cached| cached.key.clone());
        let read = match cached {
            Some(key) => Ok((key, true)),
            // Cache a read only when the files did not change around it, so
            // a concurrent write can never pair an old key with a new
            // fingerprint.
            None => read_key_at(&db_path).map(|key| {
                let stable = self::fingerprint(&db_path) == fingerprint;
                (key, stable)
            }),
        };
        match read {
            Ok((key, cacheable)) => {
                if cacheable {
                    fresh.projects.insert(
                        project_id.to_string(),
                        CachedKey {
                            fingerprint,
                            key: key.clone(),
                        },
                    );
                }
                projects.push(KeyedProject {
                    project_id,
                    key,
                    db_path,
                })
            }
            Err(error) if strict => {
                return Err(AppError::Database(format!(
                    "cannot check project key uniqueness: {} could not be read ({error}); run tasks doctor --project {project_id} and repair or restore that database",
                    db_path.display()
                )))
            }
            Err(_) => {}
        }
    }
    projects.sort_by_key(|project| project.project_id);
    if use_cache && fresh.projects != cache.projects {
        store_cache(data_root, &fresh);
    }
    Ok(projects)
}

/// The project that owns `key`, if any. Strict: an unreadable database fails.
pub fn find_owner(data_root: &Path, key: &str) -> Result<Option<KeyedProject>, AppError> {
    Ok(scan(data_root, true)?
        .into_iter()
        .find(|project| project.key.as_deref() == Some(key)))
}

/// Name (basename of the first bound root, else the UUID) and bound root of a
/// project, for messages. Registry problems only make the description vaguer.
pub fn describe(data_root: &Path, project_id: &Uuid) -> (String, Option<String>) {
    let wanted = project_id.to_string();
    let mut roots = registry::list_bindings(data_root)
        .map(|registry| {
            registry
                .bindings
                .into_iter()
                .filter(|binding| {
                    Uuid::parse_str(&binding.project_id)
                        .map(|id| id == *project_id)
                        .unwrap_or(false)
                })
                .map(|binding| binding.root)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    roots.sort_by(|left, right| {
        left.to_ascii_lowercase()
            .cmp(&right.to_ascii_lowercase())
            .then_with(|| left.cmp(right))
    });
    let root = roots.into_iter().next();
    let name = root
        .as_deref()
        .and_then(|root| Path::new(root).file_name())
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or(wanted);
    (name, root)
}

fn describe_text(data_root: &Path, project_id: &Uuid) -> String {
    let (name, root) = describe(data_root, project_id);
    match root {
        Some(root) => format!("{name} ({project_id}, root {root})"),
        None => format!("{name} ({project_id}, no bound root)"),
    }
}

/// Refuses `key` when another project database in the data root already has
/// it. Reads every database directly (no cache). Call while holding the
/// registry lock so the answer stays true until the key is written.
pub fn ensure_available(
    data_root: &Path,
    key: &str,
    except: Option<&Uuid>,
) -> Result<(), AppError> {
    let data_root = validate_storage_root(data_root)?;
    let owner = scan(&data_root, true)?
        .into_iter()
        .find(|project| project.key.as_deref() == Some(key) && Some(&project.project_id) != except);
    match owner {
        Some(owner) => Err(AppError::Validation(format!(
            "project key {key} is already used by project {}; choose another key",
            describe_text(&data_root, &owner.project_id)
        ))),
        None => Ok(()),
    }
}

/// Exit-3 error for a task reference whose key is not this project's.
pub fn foreign_reference_error(
    data_root: &Path,
    key: &str,
    id: u64,
    own_project: &Uuid,
    own_key: Option<&str>,
) -> AppError {
    let reference = render_keyed_task_id(Some(key), id);
    let own_form = own_key.unwrap_or("T");
    let owner = scan_cached(data_root).map(|projects| {
        projects
            .into_iter()
            .find(|project| project.key.as_deref() == Some(key))
    });
    match owner {
        Ok(Some(owner)) => AppError::NotFound(format!(
            "{reference} belongs to project {}, not to this project {own_project} (IDs {own_form}-N); dependencies stay within one project. Run the command in that project's root or pass --project {}",
            describe_text(data_root, &owner.project_id),
            owner.project_id
        )),
        Ok(None) => AppError::NotFound(format!(
            "{reference}: no project in data root {} has key {key}; this project {own_project} uses {own_form}-N IDs",
            data_root.display()
        )),
        Err(error) => AppError::NotFound(format!(
            "{reference} does not belong to this project {own_project} (IDs {own_form}-N), and its owner could not be looked up: {error}"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_projects_directory_has_no_keys() {
        let root = tempfile::tempdir().unwrap();
        assert!(scan(root.path(), true).unwrap().is_empty());
        assert!(find_owner(root.path(), "DAK").unwrap().is_none());
    }
}
