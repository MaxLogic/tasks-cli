//! Project keys (`DAK` in `DAK-212`): uniqueness across one data root and the
//! lookup of the project that owns a key.
//!
//! A key lives only in its project database. Every key lookup goes through
//! `<data-root>/project-keys.json`, because opening a SQLite database costs
//! milliseconds on Windows: the uniqueness checks of `init`, `project-key
//! --set` and bulk apply (under the registry lock), `enrich`, the owner named
//! by a foreign `KEY-N` and import's foreign-heading check. The cache holds
//! each database's key next to its file fingerprint (identity, size and
//! modification time of the database and of a non-empty WAL or journal). A
//! database without an entry or whose fingerprint differs is read again, and a
//! read is cached only when the fingerprint was the same before and after it,
//! so a stale or concurrently rewritten cache costs time but never yields a
//! wrong key; a file modified within the last 2 seconds is read but not
//! cached, for filesystems with coarse modification times. The cache is
//! derived data, rewritten atomically by the reference lookups
//! ([`scan_cached`]) and after a committed `init`, `project-key --set` or bulk
//! apply ([`CacheUpdate`]), so a refused `init`, a bulk dry run or a
//! rolled-back apply leaves the data root unchanged.

use crate::error::AppError;
use crate::model::render_keyed_task_id;
use crate::registry;
use crate::storage::validate_storage_root;
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};
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
    let conn = crate::store::open_for_reading(db_path, OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
    conn.busy_timeout(Duration::from_secs(5))?;
    Ok(read_key(&conn)?)
}

/// The database and its WAL and rollback journal, with their metadata when
/// they count: the database always, a sidecar only when non-empty, because a
/// reader may create an empty WAL without changing any data.
fn fingerprint_files(db_path: &Path) -> Vec<(PathBuf, Option<fs::Metadata>)> {
    ["", "-wal", "-journal"]
        .into_iter()
        .map(|suffix| {
            let mut name = db_path.as_os_str().to_os_string();
            name.push(suffix);
            let path = PathBuf::from(name);
            let meta = fs::metadata(&path)
                .ok()
                .filter(|meta| suffix.is_empty() || meta.len() > 0);
            (path, meta)
        })
        .collect()
}

/// How long after its last modification a file's key may be cached. On a
/// filesystem with coarse modification times (FAT/exFAT keep 2 seconds) a
/// same-size change made within that window could keep the fingerprint; a
/// read of a file modified this recently is used but not cached.
const RACY_WINDOW: Duration = Duration::from_secs(2);

/// True when every counted file was last modified at least [`RACY_WINDOW`]
/// before `now`; an unknown modification time is never settled.
fn settled(db_path: &Path, now: SystemTime) -> bool {
    fingerprint_files(db_path)
        .iter()
        .all(|(_, meta)| match meta {
            None => true,
            Some(meta) => meta
                .modified()
                .ok()
                .and_then(|modified| now.duration_since(modified).ok())
                .is_some_and(|age| age >= RACY_WINDOW),
        })
}

/// Identity, size and modification time of the files [`fingerprint_files`]
/// counts.
fn fingerprint(db_path: &Path) -> String {
    let mut parts = Vec::with_capacity(3);
    for (path, meta) in fingerprint_files(db_path) {
        let part = match meta {
            Some(meta) => {
                let identity = file_id::get_file_id(&path)
                    .map(|id| format!("{id:?}"))
                    .unwrap_or_else(|_| "unavailable".to_string());
                format!("{identity}:{:?}:{}", meta.modified().ok(), meta.len())
            }
            None => "-".to_string(),
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

/// A refreshed key cache from a scan, to be written only once the caller's
/// change has committed, so a refused or rolled-back command leaves the data
/// root unchanged.
#[derive(Debug)]
#[must_use = "store the refreshed cache after the change commits, or drop it"]
pub struct CacheUpdate {
    fresh: KeyCache,
    changed: bool,
}

impl CacheUpdate {
    /// Best effort, like every cache write.
    pub fn store(self, data_root: &Path) {
        if self.changed {
            store_cache(data_root, &self.fresh);
        }
    }
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
/// with its key, through the key cache, which this never writes. `strict`
/// fails on a database that has to be read and cannot be, because a
/// uniqueness check cannot vouch for it; otherwise such a project is skipped.
/// Directories that are not canonical UUIDs or hold no database are ignored.
pub fn scan(data_root: &Path, strict: bool) -> Result<Vec<KeyedProject>, AppError> {
    Ok(scan_with(data_root, strict)?.0)
}

/// Lenient [`scan`] that also rewrites the key cache when it changed.
pub fn scan_cached(data_root: &Path) -> Result<Vec<KeyedProject>, AppError> {
    let (projects, update) = scan_with(data_root, false)?;
    update.store(data_root);
    Ok(projects)
}

fn scan_with(data_root: &Path, strict: bool) -> Result<(Vec<KeyedProject>, CacheUpdate), AppError> {
    let projects_dir = data_root.join("projects");
    let entries = match fs::read_dir(&projects_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let fresh = KeyCache {
                format_version: CACHE_FORMAT,
                projects: BTreeMap::new(),
            };
            let changed = load_cache(data_root).format_version != CACHE_FORMAT;
            return Ok((Vec::new(), CacheUpdate { fresh, changed }));
        }
        Err(error) => {
            return Err(AppError::io_path(
                "list project databases in",
                &projects_dir,
                error,
            ))
        }
    };
    let cache = load_cache(data_root);
    let now = SystemTime::now();
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
            // fingerprint, and were not modified too recently to tell apart.
            None => read_key_at(&db_path).map(|key| {
                let stable = self::fingerprint(&db_path) == fingerprint;
                (key, stable && settled(&db_path, now))
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
    // A missing or unreadable cache file loads as the default (format 0), so
    // a scan with nothing to cache still creates the file.
    let changed = fresh.projects != cache.projects || cache.format_version != CACHE_FORMAT;
    Ok((projects, CacheUpdate { fresh, changed }))
}

/// The project that owns `key`, if any. Strict: an unreadable database fails.
/// Reads the key cache without writing it.
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
/// it. Strict [`scan`] through the key cache; the refreshed cache is
/// returned for the caller to store once its change has committed. Call
/// while holding the registry lock so the answer stays true until the key is
/// written.
pub fn ensure_available(
    data_root: &Path,
    key: &str,
    except: Option<&Uuid>,
) -> Result<CacheUpdate, AppError> {
    let data_root = validate_storage_root(data_root)?;
    let (projects, update) = scan_with(&data_root, true)?;
    let owner = projects
        .into_iter()
        .find(|project| project.key.as_deref() == Some(key) && Some(&project.project_id) != except);
    match owner {
        Some(owner) => Err(AppError::Validation(format!(
            "project key {key} is already used by project {}; choose another key",
            describe_text(&data_root, &owner.project_id)
        ))),
        None => Ok(update),
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
    fn a_recently_modified_database_is_read_but_not_cached() {
        let root = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let info = crate::store::create_project_db_with_key(root.path(), &id, Some("RAC")).unwrap();
        let cached = || {
            load_cache(root.path())
                .projects
                .contains_key(&id.to_string())
        };
        let keys = scan_cached(root.path()).unwrap();
        assert_eq!(keys[0].key.as_deref(), Some("RAC"));
        assert!(!cached(), "a database modified just now must not be cached");
        let old = SystemTime::now() - Duration::from_secs(10);
        fs::OpenOptions::new()
            .write(true)
            .open(&info.db_path)
            .unwrap()
            .set_modified(old)
            .unwrap();
        assert!(settled(&info.db_path, SystemTime::now()));
        assert!(!settled(&info.db_path, old + Duration::from_secs(1)));
        scan_cached(root.path()).unwrap();
        assert!(cached(), "a settled database is cached");
    }

    #[test]
    fn missing_projects_directory_has_no_keys() {
        let root = tempfile::tempdir().unwrap();
        assert!(scan(root.path(), true).unwrap().is_empty());
        assert!(find_owner(root.path(), "DAK").unwrap().is_none());
    }
}
