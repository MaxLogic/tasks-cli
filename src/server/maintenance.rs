//! Stopped-service backup, restore, and adoption of an existing project database.
use super::{OwnedServer, ServiceError};
use crate::{
    private_fs, storage,
    store::{data_root_project_path, Store, CURRENT_SCHEMA_VERSION},
    AppError,
};
use rusqlite::{params, Connection, OpenFlags, TransactionBehavior};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    time::Duration,
};
use uuid::Uuid;

const MANIFEST: &str = "manifest.json";

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    format: u32,
    server_id: Uuid,
    files: Vec<DatabaseEvidence>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DatabaseEvidence {
    path: String,
    sha256: String,
    bytes: u64,
    schema: i32,
    identity: String,
    counts: Vec<(String, i64)>,
}

#[derive(Serialize)]
pub struct BackupResult {
    pub path: PathBuf,
    pub server_id: Uuid,
    pub databases: usize,
}

#[derive(Serialize)]
pub struct ImportResult {
    pub project_id: Uuid,
    pub project_key: Option<String>,
    pub name: String,
}

fn invalid(message: impl Into<String>) -> ServiceError {
    ServiceError::Storage(AppError::Database(message.into()))
}

fn new_destination(path: &Path) -> Result<(PathBuf, private_fs::ExportDirectory), ServiceError> {
    if !path.is_absolute() {
        return Err(invalid("destination must be a new absolute directory"));
    }
    let parent = path
        .parent()
        .ok_or_else(|| invalid("destination has no parent"))?;
    storage::validate_storage_root(parent)?;
    let guard = private_fs::validate_export_directory(parent)?;
    let parent = &guard.path;
    let name = path
        .file_name()
        .ok_or_else(|| invalid("destination has no name"))?;
    let resolved = parent.join(name);
    if fs::symlink_metadata(&resolved).is_ok() {
        return Err(invalid(
            "destination already exists; choose a new directory",
        ));
    }
    Ok((resolved, guard))
}

fn stage_for(out: &Path) -> Result<PathBuf, ServiceError> {
    let parent = out
        .parent()
        .ok_or_else(|| invalid("destination has no parent"))?;
    let stage = parent.join(format!(".tasks-server-maintenance-{}", Uuid::new_v4()));
    private_fs::create_dir(&stage)?;
    Ok(stage)
}

fn sync_dir(path: &Path) -> Result<(), ServiceError> {
    #[cfg(unix)]
    File::open(path)?.sync_all()?;
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

fn sync_publication_parents(
    stage: &Path,
    mut sync: impl FnMut(&Path) -> Result<(), ServiceError>,
) -> Result<(), ServiceError> {
    let projects = stage.join("projects");
    if projects.exists() {
        sync(&projects)?;
    }
    sync(stage)
}

fn publish(stage: &Path, out: &Path) -> Result<(), ServiceError> {
    if fs::symlink_metadata(out).is_ok() {
        return Err(invalid("destination appeared before publication"));
    }
    #[cfg(target_os = "linux")]
    {
        let parent = File::open(
            out.parent()
                .ok_or_else(|| invalid("destination has no parent"))?,
        )?;
        rustix::fs::renameat_with(
            &parent,
            stage
                .file_name()
                .ok_or_else(|| invalid("staging directory has no name"))?,
            &parent,
            out.file_name()
                .ok_or_else(|| invalid("destination has no name"))?,
            rustix::fs::RenameFlags::NOREPLACE,
        )
        .map_err(std::io::Error::from)?;
    }
    #[cfg(windows)]
    atomicwrites::move_atomic(stage, out)?;
    #[cfg(not(any(target_os = "linux", windows)))]
    return Err(invalid(
        "atomic no-overwrite publication is unsupported on this platform",
    ));
    sync_dir(
        out.parent()
            .ok_or_else(|| invalid("destination has no parent"))?,
    )?;
    Ok(())
}

fn open_source(path: &Path) -> Result<Connection, ServiceError> {
    if !fs::symlink_metadata(path)?.is_file() {
        return Err(invalid("database source must be a regular file"));
    }
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    conn.busy_timeout(Duration::from_secs(5))?;
    Ok(conn)
}

fn open_catalog(server: &OwnedServer) -> Result<Connection, ServiceError> {
    let conn = Connection::open_with_flags(
        server.data_root().join("server.sqlite"),
        OpenFlags::SQLITE_OPEN_READ_WRITE,
    )?;
    conn.busy_timeout(Duration::from_secs(5))?;
    conn.execute_batch("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")?;
    Ok(conn)
}

fn online_backup(source: &Path, destination: &Path) -> Result<(), ServiceError> {
    let source = open_source(source)?;
    let target = private_fs::create_file(destination)?;
    drop(target);
    source.backup("main", destination, None::<fn(rusqlite::backup::Progress)>)?;
    // Standalone snapshots must not need WAL/SHM files. Only this new copy's
    // journal mode changes; the source authority retains its durability mode.
    let copied = Connection::open_with_flags(destination, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
    copied.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")?;
    drop(copied);
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(destination)?
        .sync_all()?;
    Ok(())
}

fn sha256(path: &Path) -> Result<(String, u64), ServiceError> {
    let mut file = File::open(path)?;
    let mut digest = Sha256::new();
    let mut bytes = 0;
    let mut block = [0_u8; 65536];
    loop {
        let read = file.read(&mut block)?;
        if read == 0 {
            break;
        }
        bytes += read as u64;
        digest.update(&block[..read]);
    }
    Ok((format!("{:x}", digest.finalize()), bytes))
}

fn check_db(conn: &Connection) -> Result<(), ServiceError> {
    let integrity: String = conn.query_row("PRAGMA integrity_check", [], |row| row.get(0))?;
    let foreign_keys: i64 =
        conn.query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |row| {
            row.get(0)
        })?;
    if integrity != "ok" || foreign_keys != 0 {
        return Err(invalid("database integrity or foreign-key check failed"));
    }
    Ok(())
}

fn count(conn: &Connection, table: &str) -> Result<i64, ServiceError> {
    // Table names are fixed in this module, never supplied by an operator.
    Ok(
        conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |row| {
            row.get(0)
        })?,
    )
}

fn project_evidence(root: &Path, id: Uuid) -> Result<DatabaseEvidence, ServiceError> {
    let relative = format!("projects/{id}/TASKS.sqlite");
    let path = root.join(&relative);
    let store = Store::open_readonly(root, &id.to_string())?;
    drop(store);
    let conn = open_source(&path)?;
    check_db(&conn)?;
    let schema: i32 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if schema != CURRENT_SCHEMA_VERSION {
        return Err(invalid(
            "project backup requires schema 8; migrate a copy explicitly",
        ));
    }
    let identity: String =
        conn.query_row("SELECT project_id FROM project", [], |row| row.get(0))?;
    if identity != id.to_string() {
        return Err(invalid("project identity differs from directory UUID"));
    }
    let mut counts = Vec::new();
    for table in [
        "tasks",
        "dependencies",
        "events",
        "imports",
        "metadata_events",
        "mutation_receipts",
    ] {
        counts.push((table.to_string(), count(&conn, table)?));
    }
    drop(conn);
    let (sha256, bytes) = sha256(&path)?;
    Ok(DatabaseEvidence {
        path: relative,
        sha256,
        bytes,
        schema,
        identity,
        counts,
    })
}

fn catalog_evidence(root: &Path) -> Result<DatabaseEvidence, ServiceError> {
    let path = root.join("server.sqlite");
    let conn = open_source(&path)?;
    OwnedServer::validate_schema(&conn)?;
    check_db(&conn)?;
    let schema: i32 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if schema != 2 {
        return Err(invalid("catalog backup requires schema 2"));
    }
    let identity: String = conn.query_row(
        "SELECT server_id FROM server_identity WHERE singleton=1",
        [],
        |row| row.get(0),
    )?;
    let mut counts = Vec::new();
    for table in ["projects", "credentials", "replay_nonces", "admin_events"] {
        counts.push((table.to_string(), count(&conn, table)?));
    }
    drop(conn);
    let (sha256, bytes) = sha256(&path)?;
    Ok(DatabaseEvidence {
        path: "server.sqlite".into(),
        sha256,
        bytes,
        schema,
        identity,
        counts,
    })
}

fn project_ids(root: &Path) -> Result<Vec<Uuid>, ServiceError> {
    let directory = root.join("projects");
    if !directory.exists() {
        return Ok(Vec::new());
    }
    let mut ids = Vec::new();
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            return Err(invalid("projects contains a non-directory entry"));
        }
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| invalid("non-UTF8 project directory"))?;
        let id = Uuid::parse_str(&name).map_err(|_| invalid("invalid project directory UUID"))?;
        if name != id.to_string() || !entry.path().join("TASKS.sqlite").is_file() {
            return Err(invalid("project directory is incomplete or noncanonical"));
        }
        ids.push(id);
    }
    ids.sort();
    Ok(ids)
}

fn evidence(root: &Path) -> Result<Manifest, ServiceError> {
    let catalog = catalog_evidence(root)?;
    let server_id =
        Uuid::parse_str(&catalog.identity).map_err(|_| invalid("invalid server identity"))?;
    let ids = project_ids(root)?;
    let catalog_conn = open_source(&root.join("server.sqlite"))?;
    let mut statement =
        catalog_conn.prepare("SELECT project_id FROM projects ORDER BY project_id")?;
    let listed = statement
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    for id in listed {
        let id = Uuid::parse_str(&id).map_err(|_| invalid("invalid catalog project UUID"))?;
        if !ids.contains(&id) {
            return Err(invalid("catalog project database is missing"));
        }
    }
    let mut files = vec![catalog];
    for id in ids {
        files.push(project_evidence(root, id)?);
    }
    Ok(Manifest {
        format: 1,
        server_id,
        files,
    })
}

fn manifest_bytes(value: &Manifest) -> Result<Vec<u8>, ServiceError> {
    Ok(serde_json::to_vec_pretty(value).map_err(AppError::from)?)
}

fn write_manifest(stage: &Path, value: &Manifest) -> Result<(), ServiceError> {
    let bytes = manifest_bytes(value)?;
    if bytes.len() >= 1024 * 1024 {
        return Err(invalid("backup manifest exceeds the 1 MiB limit"));
    }
    let mut file = private_fs::create_file(&stage.join(MANIFEST))?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    Ok(())
}

/// The OwnedServer lock excludes serving and concurrent administration.
pub fn backup(server: &OwnedServer, out: &Path) -> Result<BackupResult, ServiceError> {
    let (out, _parent_guard) = new_destination(out)?;
    if out.starts_with(server.data_root().canonicalize()?) {
        return Err(invalid("backup destination is inside the server data root"));
    }
    let stage = stage_for(&out)?;
    let result = (|| {
        online_backup(
            &server.data_root().join("server.sqlite"),
            &stage.join("server.sqlite"),
        )?;
        for id in project_ids(server.data_root())? {
            let dir = stage.join("projects").join(id.to_string());
            if !dir
                .parent()
                .ok_or_else(|| invalid("invalid project path"))?
                .exists()
            {
                private_fs::create_dir(
                    dir.parent()
                        .ok_or_else(|| invalid("invalid project path"))?,
                )?;
            }
            private_fs::create_dir(&dir)?;
            online_backup(
                &data_root_project_path(server.data_root(), &id.to_string()),
                &dir.join("TASKS.sqlite"),
            )?;
            sync_dir(&dir)?;
        }
        let manifest = evidence(&stage)?;
        if manifest.server_id != server.server_id() {
            return Err(invalid("server identity changed during backup"));
        }
        write_manifest(&stage, &manifest)?;
        sync_publication_parents(&stage, sync_dir)?;
        publish(&stage, &out)?;
        Ok(BackupResult {
            path: out,
            server_id: manifest.server_id,
            databases: manifest.files.len(),
        })
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&stage);
    }
    result
}

fn verify_backup(path: &Path) -> Result<Manifest, ServiceError> {
    let root = storage::validate_storage_root(path)?;
    private_fs::validate_dir(&root)?;
    let mut bytes = Vec::new();
    private_fs::open_file(&root.join(MANIFEST))?
        .take(1024 * 1024)
        .read_to_end(&mut bytes)?;
    if bytes.len() >= 1024 * 1024 {
        return Err(invalid("backup manifest is too large"));
    }
    let manifest: Manifest =
        serde_json::from_slice(&bytes).map_err(|_| invalid("invalid backup manifest"))?;
    if bytes != manifest_bytes(&manifest)? {
        return Err(invalid("backup manifest is not canonical or was changed"));
    }
    if manifest.format != 1
        || manifest.files.is_empty()
        || manifest.files[0].path != "server.sqlite"
    {
        return Err(invalid("unsupported or incomplete backup manifest"));
    }
    let actual = evidence(&root)?;
    if manifest_bytes(&manifest)? != manifest_bytes(&actual)? {
        return Err(invalid(
            "backup evidence mismatch; source may be tampered or incomplete",
        ));
    }
    let expected: BTreeSet<_> = manifest.files.iter().map(|f| f.path.as_str()).collect();
    if expected.len() != manifest.files.len() {
        return Err(invalid("duplicate manifest database"));
    }
    // Require only the defined database and manifest files. WAL/SHM are not
    // needed because each database was published from SQLite's online backup.
    for entry in fs::read_dir(&root)? {
        let name = entry?.file_name();
        if name != "server.sqlite" && name != MANIFEST && name != "projects" {
            return Err(invalid("unexpected backup root entry"));
        }
    }
    for id in project_ids(&root)? {
        for entry in fs::read_dir(root.join("projects").join(id.to_string()))? {
            if entry?.file_name() != "TASKS.sqlite" {
                return Err(invalid("unexpected project backup entry"));
            }
        }
    }
    Ok(manifest)
}

pub fn restore(backup: &Path, out: &Path) -> Result<BackupResult, ServiceError> {
    let (out, _parent_guard) = new_destination(out)?;
    let backup = storage::validate_storage_root(backup)?.canonicalize()?;
    if out.starts_with(&backup) || backup.starts_with(&out) {
        return Err(invalid("restore destination overlaps backup source"));
    }
    let manifest = verify_backup(&backup)?;
    let stage = stage_for(&out)?;
    let result = (|| {
        for item in &manifest.files {
            let target = stage.join(&item.path);
            let parent = target
                .parent()
                .ok_or_else(|| invalid("invalid manifest path"))?;
            if !parent.exists() {
                let projects = stage.join("projects");
                if !projects.exists() {
                    private_fs::create_dir(&projects)?;
                }
                private_fs::create_dir(parent)?;
            }
            let mut src = private_fs::open_file(&backup.join(&item.path))?;
            let mut dst = private_fs::create_file(&target)?;
            std::io::copy(&mut src, &mut dst)?;
            dst.sync_all()?;
            sync_dir(parent)?;
        }
        write_manifest(&stage, &manifest)?;
        if manifest_bytes(&evidence(&stage)?)? != manifest_bytes(&manifest)? {
            return Err(invalid("restored database evidence mismatch"));
        }
        sync_publication_parents(&stage, sync_dir)?;
        publish(&stage, &out)?;
        Ok(BackupResult {
            path: out,
            server_id: manifest.server_id,
            databases: manifest.files.len(),
        })
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&stage);
    }
    result
}

pub fn import_project(
    server: &OwnedServer,
    database: &Path,
    name: &str,
) -> Result<ImportResult, ServiceError> {
    if name.trim().is_empty() || name.len() > 1024 {
        return Err(ServiceError::Validation(
            "project name must contain 1-1024 bytes",
        ));
    }
    let _registry = storage::acquire_exclusive_lock(&server.data_root().join("registry.lock"))?;
    let source = open_source(database)?;
    check_db(&source)?;
    let schema: i32 = source.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if schema != CURRENT_SCHEMA_VERSION {
        return Err(invalid(
            "project schema is not 8; migrate a copy explicitly before import",
        ));
    }
    let text: String = source.query_row("SELECT project_id FROM project", [], |row| row.get(0))?;
    let id = Uuid::parse_str(&text).map_err(|_| invalid("invalid project UUID"))?;
    if id.is_nil() || text != id.to_string() {
        return Err(invalid("invalid or noncanonical project UUID"));
    }
    let conn = open_catalog(server)?;
    let exists: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM projects WHERE project_id=?1)",
        [id.to_string()],
        |row| row.get(0),
    )?;
    let dir = server.data_root().join("projects").join(id.to_string());
    if exists || fs::symlink_metadata(&dir).is_ok() {
        return Err(invalid(
            "project UUID already exists in catalog or project store",
        ));
    }
    let key = crate::keys::read_key(&source)?;
    if let Some(key) = &key {
        if crate::keys::find_owner(server.data_root(), key)?.is_some() {
            return Err(invalid("project key is already used"));
        }
    }
    drop(source);
    let projects = server.data_root().join("projects");
    if !projects.exists() {
        fs::create_dir(&projects)?;
    }
    storage::validate_storage_path(&dir)?;
    private_fs::create_dir(&dir)?;
    let result = (|| {
        online_backup(database, &dir.join("TASKS.sqlite"))?;
        let check = project_evidence(server.data_root(), id)?;
        if check.identity != id.to_string() {
            return Err(invalid("copied project identity mismatch"));
        }
        let copied = Store::open_readonly(server.data_root(), &id.to_string())?;
        if copied.project_key != key {
            return Err(invalid("project key changed during import"));
        }
        drop(copied);
        fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(dir.join("TASKS.sqlite"))?
            .sync_all()?;
        sync_dir(&dir)?;
        sync_dir(&projects)?;
        let mut conn = open_catalog(server)?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            "INSERT INTO projects(project_id,name) VALUES (?1,?2)",
            params![id.to_string(), name],
        )?;
        tx.commit()?;
        Ok(ImportResult {
            project_id: id,
            project_key: key,
            name: name.to_string(),
        })
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&dir);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn publication_syncs_projects_parent_before_stage_root() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir(root.path().join("projects")).unwrap();
        let mut called = Vec::new();
        sync_publication_parents(root.path(), |path| {
            called.push(path.to_path_buf());
            Ok(())
        })
        .unwrap();
        assert_eq!(
            called,
            vec![root.path().join("projects"), root.path().to_path_buf()]
        );
    }
    #[test]
    fn failed_projects_sync_prevents_root_publication_step() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir(root.path().join("projects")).unwrap();
        let mut called = Vec::new();
        assert!(sync_publication_parents(root.path(), |path| {
            called.push(path.to_path_buf());
            Err(invalid("injected directory sync failure"))
        })
        .is_err());
        assert_eq!(called, vec![root.path().join("projects")]);
    }
}
