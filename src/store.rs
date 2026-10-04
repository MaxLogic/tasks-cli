use crate::error::AppError;
use crate::markdown::{ParsedImport, ParsedTask};
use crate::model::{
    parse_task_ref, render_keyed_task_id, Attribution, DependencySummary, HistoryEvent,
    ImportProblem, ImportReport, ListCursor, MetadataEvent, Pagination, Priority, RuleRecord,
    SelectionPage, ShowTask, TaskDetail, TaskStatus, TaskSummary, TaskUpdate, UnlockSummary,
    BODY_MAX_BYTES, MAX_DEPENDENCIES, RULES_MAX_BYTES, TITLE_MAX_CHARS,
};
use crate::storage::{
    acquire_exclusive_lock, validate_storage_path, validate_storage_root, ExclusiveLock,
};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

pub const CURRENT_SCHEMA_VERSION: i32 = 8;

/// Caller owns a read/write snapshot. Fetch only bounded archive metadata.
pub(crate) fn effective_archive_from(conn: &Connection) -> Result<Option<i64>, AppError> {
    let latest: Option<(i64,Option<String>)> = conn.query_row(
        "SELECT length(CAST(snapshot_json AS BLOB)),CASE WHEN length(CAST(snapshot_json AS BLOB))<=16384 THEN snapshot_json ELSE NULL END FROM metadata_events WHERE operation='viewer-archive' ORDER BY event_id DESC LIMIT 1",
        [],|row|Ok((row.get(0)?,row.get(1)?))).optional()?;
    let Some((_, snapshot)) = latest else {
        return Ok(None);
    };
    let snapshot = snapshot.ok_or_else(|| {
        AppError::ResponseLimit("archive metadata exceeds its 16 KiB read budget".into())
    })?;
    #[derive(serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    struct ArchiveState {
        archived_at_ms: Option<i64>,
        task_event_watermark: u64,
    }
    let state: ArchiveState = serde_json::from_str(&snapshot)
        .map_err(|_| AppError::Database("invalid viewer archive metadata".into()))?;
    let current: u64 =
        conn.query_row("SELECT COALESCE(MAX(event_id),0) FROM events", [], |row| {
            row.get(0)
        })?;
    Ok(state
        .archived_at_ms
        .filter(|_| current <= state.task_event_watermark))
}

fn create_receipt_schema(conn: &Connection) -> Result<(), AppError> {
    conn.execute_batch(include_str!("receipt_schema.sql"))?;
    Ok(())
}

fn validate_receipt_schema(conn: &Connection) -> Result<(), AppError> {
    fn definitions(conn: &Connection) -> Result<Vec<(String, String)>, AppError> {
        let mut query = conn.prepare("SELECT name,sql FROM sqlite_schema WHERE name IN ('mutation_receipts','mutation_receipts_no_update','mutation_receipts_no_delete') ORDER BY name")?;
        let rows = query
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<Result<_, _>>()?;
        Ok(rows)
    }
    let expected = Connection::open_in_memory()?;
    create_receipt_schema(&expected)?;
    if definitions(conn)? != definitions(&expected)? {
        return Err(AppError::Database(
            "mutation receipt schema is damaged; restore a verified backup".into(),
        ));
    }
    Ok(())
}

/// Local commands own a transaction. Server commands run the same mutation
/// inside a savepoint of the transaction that also persists its receipt.
enum WriteTransaction<'a> {
    Transaction(rusqlite::Transaction<'a>),
    Savepoint(rusqlite::Savepoint<'a>),
}

impl<'a> WriteTransaction<'a> {
    fn begin(conn: &'a mut Connection) -> Result<Self, AppError> {
        if conn.is_autocommit() {
            Ok(Self::Transaction(conn.transaction_with_behavior(
                TransactionBehavior::Immediate,
            )?))
        } else {
            Ok(Self::Savepoint(conn.savepoint()?))
        }
    }

    fn commit(self) -> Result<(), AppError> {
        match self {
            Self::Transaction(tx) => tx.commit()?,
            Self::Savepoint(tx) => tx.commit()?,
        }
        Ok(())
    }
}

impl std::ops::Deref for WriteTransaction<'_> {
    type Target = Connection;
    fn deref(&self) -> &Connection {
        match self {
            Self::Transaction(tx) => tx,
            Self::Savepoint(tx) => tx,
        }
    }
}

fn create_attribution_schema(tx: &rusqlite::Transaction<'_>) -> Result<(), AppError> {
    tx.execute_batch(
        "ALTER TABLE events ADD COLUMN attribution_json TEXT
             CHECK(attribution_json IS NULL OR (length(CAST(attribution_json AS BLOB)) <= 16384 AND json_valid(attribution_json)));
         CREATE TABLE metadata_events(
             event_id INTEGER PRIMARY KEY AUTOINCREMENT,
             operation TEXT NOT NULL,
             created_ms INTEGER NOT NULL,
             snapshot_json TEXT NOT NULL CHECK(json_valid(snapshot_json)),
             attribution_json TEXT NOT NULL CHECK(length(CAST(attribution_json AS BLOB)) <= 16384 AND json_valid(attribution_json))
         );
         CREATE TRIGGER metadata_events_no_update BEFORE UPDATE ON metadata_events
             BEGIN SELECT RAISE(ABORT, 'metadata history is append-only'); END;
         CREATE TRIGGER metadata_events_no_delete BEFORE DELETE ON metadata_events
             BEGIN SELECT RAISE(ABORT, 'metadata history is append-only'); END;",
    )?;
    Ok(())
}

fn read_json_column<T: serde::de::DeserializeOwned>(
    row: &rusqlite::Row<'_>,
    column: usize,
) -> rusqlite::Result<Option<T>> {
    row.get::<_, Option<String>>(column)?
        .map(|text| {
            serde_json::from_str(&text).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    column,
                    rusqlite::types::Type::Text,
                    Box::new(error),
                )
            })
        })
        .transpose()
}

/// Column definition of the optional project key (schema 6). The CHECK mirrors
/// `model::parse_project_key`: 2-6 uppercase ASCII letters/digits starting
/// with a letter; `T` alone is too short and so stays reserved.
const PROJECT_KEY_DEFINITION: &str = "TEXT CHECK (project_key IS NULL OR (length(project_key) BETWEEN 2 AND 6 AND substr(project_key,1,1) BETWEEN 'A' AND 'Z' AND project_key NOT GLOB '*[^A-Z0-9]*' AND NOT (substr(project_key,1,1) = 'T' AND substr(project_key,2) NOT GLOB '*[^0-9]*')))";

/// The authoritative runnable-readiness predicate. Callers that build their own
/// task SQL must splice this exact text, so the store and the viewer cannot
/// drift into two different definitions of "runnable". A `to-verify`
/// prerequisite counts as satisfied here (and in `unlocks`) only; completion
/// still requires terminal prerequisites (see `update_task`).
pub(crate) const RUNNABLE_PREDICATE: &str = "t.status IN ('todo','in-progress')
                   AND NOT EXISTS(SELECT 1 FROM task_labels l WHERE l.task_id=t.id AND l.label='needs-human')
                   AND NOT EXISTS(SELECT 1 FROM dependencies d JOIN tasks p ON p.id=d.depends_on_id WHERE d.task_id=t.id AND p.status NOT IN ('done','to-verify'))";

/// The two statuses RUNNABLE_PREDICATE's own `t.status IN (...)` term can
/// match. Pinned against that constant's literal text by
/// `runnable_statuses_match_runnable_predicate_text` below, so `select_tasks`'s
/// default-view UNION ALL arms can't silently drift from the predicate they
/// exist to serve.
const RUNNABLE_STATUSES: [&str; 2] = ["todo", "in-progress"];

/// The non-terminal statuses (every `TaskStatus` variant except `Done` and
/// `Cancelled`), as their SQL text (via `Display`), built directly from
/// `TaskStatus` so this list cannot drift from the enum: adding or removing
/// a status changes this automatically, with no separate literal list to
/// maintain.
fn non_terminal_statuses() -> Vec<String> {
    use clap::ValueEnum;
    crate::model::TaskStatus::value_variants()
        .iter()
        .filter(|status| !status.is_terminal())
        .map(|status| status.to_string())
        .collect()
}

/// Pushes a bound value and returns its numbered placeholder (`"?N"`),
/// so every caller names its own placeholder inline instead of the whole
/// query committing to one fixed position layout; the same placeholder text
/// may be spliced into the SQL more than once (SQLite numbered parameters
/// may repeat).
fn push_bind(
    binds: &mut Vec<Box<dyn rusqlite::ToSql>>,
    value: impl rusqlite::ToSql + 'static,
) -> String {
    binds.push(Box::new(value));
    format!("?{}", binds.len())
}

/// Builds `UNION ALL`-joined per-status arms over
/// `idx_tasks_status_priority_id`, each already sorted `t.priority,t.id` so
/// the outer `ORDER BY ... LIMIT` can merge them instead of sorting the
/// whole union (see `select_tasks`'s doc comment). `extra` is spliced
/// verbatim into every arm's `WHERE` (a literal AND-clause, not a bind
/// parameter); `label_ph`, `cursor_clause` and `limit_ph` are placeholder
/// text from `push_bind` (or, for `cursor_clause`, an empty string when
/// there is no cursor -- omitting the clause entirely rather than guarding
/// it with `?N IS NULL`, so a deep page still seeks `status=? AND
/// priority>?` instead of losing that to an unresolvable bound-parameter OR).
fn union_arms_sql<S: AsRef<str>>(
    statuses: &[S],
    extra: &str,
    label_ph: &str,
    cursor_clause: &str,
    limit_ph: &str,
) -> String {
    let arms: Vec<String> = statuses
        .iter()
        .map(|status| {
            let status = status.as_ref();
            format!(
                "SELECT * FROM (
                    SELECT t.id,t.status,t.version,t.title,t.priority FROM tasks t
                     WHERE t.status='{status}'
                       {extra}
                       AND ({label_ph} IS NULL OR EXISTS(SELECT 1 FROM task_labels l WHERE l.task_id=t.id AND l.label={label_ph}))
                       {cursor_clause}
                     ORDER BY t.priority,t.id
                )"
            )
        })
        .collect();
    format!(
        "{}\n ORDER BY priority,id LIMIT {limit_ph}",
        arms.join("\n UNION ALL\n")
    )
}

fn create_selection_schema(conn: &Connection) -> Result<(), AppError> {
    conn.execute_batch("ALTER TABLE tasks ADD COLUMN priority TEXT NOT NULL DEFAULT 'P2' CHECK(priority IN ('P0','P1','P2','P3'));
        CREATE INDEX idx_tasks_priority_id ON tasks(priority,id);
        CREATE INDEX idx_tasks_status_priority_id ON tasks(status,priority,id);")?;
    Ok(())
}

#[derive(Debug)]
pub struct Store {
    pub project_id: Uuid,
    pub db_path: PathBuf,
    pub conn: Connection,
    /// Stored project key (schema 6); `None` before a person assigns one.
    pub project_key: Option<String>,
    /// Validated data root this store was opened from.
    pub data_root: PathBuf,
    migration_lock: Option<ExclusiveLock>,
    /// Validated and serialized before entering any mutation transaction.
    attribution_json: String,
}

pub struct StoreInfo {
    pub project_id: Uuid,
    pub db_path: PathBuf,
    /// The key stored in the database, which may predate the caller's request.
    pub project_key: Option<String>,
}

pub fn data_root_project_path(data_root: &Path, project_id: &str) -> PathBuf {
    data_root
        .join("projects")
        .join(project_id)
        .join("TASKS.sqlite")
}

/// Opens an existing database for reading only.
///
/// A `SQLITE_OPEN_READ_ONLY` connection to a WAL database creates `-wal` and
/// `-shm` files but cannot remove them when it closes (removal follows the
/// close-time checkpoint, which a read-only connection may not run), and
/// every later open of the database pays for the leftovers. So when the WAL
/// is absent or empty when the read begins, the database is opened read-write
/// with `PRAGMA query_only`, and the last connection's close removes the
/// sidecars. A non-empty WAL keeps the read-only open, so a read does not
/// checkpoint a WAL that was pending when it began. A writer may still
/// commit while the read-write reader is open; if that reader closes last,
/// its close checkpoints those committed frames, as any SQLite connection's
/// close does.
pub(crate) fn open_for_reading(
    db_path: &Path,
    extra: rusqlite::OpenFlags,
) -> Result<Connection, AppError> {
    use rusqlite::OpenFlags;
    let mut wal = db_path.as_os_str().to_os_string();
    wal.push("-wal");
    let nothing_pending = match fs::symlink_metadata(PathBuf::from(wal)) {
        Ok(meta) => meta.is_file() && meta.len() == 0,
        Err(error) => error.kind() == std::io::ErrorKind::NotFound,
    };
    if nothing_pending {
        let conn = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_WRITE | extra)?;
        conn.pragma_update(None, "query_only", true)?;
        Ok(conn)
    } else {
        Ok(Connection::open_with_flags(
            db_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | extra,
        )?)
    }
}

/// Creates (or validates) a project database without a key, the state of a
/// database migrated from before project keys. The CLI always passes a key
/// through [`create_project_db_with_key`].
pub fn create_project_db(data_root: &Path, project_id: &Uuid) -> Result<StoreInfo, AppError> {
    create_project_db_with_key(data_root, project_id, None)
}

/// Creates a project database holding `key`, or validates an existing one
/// without changing its stored key (reported in the result). Key uniqueness is
/// the caller's job, under the registry lock.
pub fn create_project_db_with_key(
    data_root: &Path,
    project_id: &Uuid,
    key: Option<&str>,
) -> Result<StoreInfo, AppError> {
    create_project_db_with_context(data_root, project_id, key, &crate::attribution::current())
}

pub fn create_project_db_with_context(
    data_root: &Path,
    project_id: &Uuid,
    key: Option<&str>,
    attribution: &Attribution,
) -> Result<StoreInfo, AppError> {
    create_project_database(data_root, project_id, key, attribution, true)
}

/// An unpublished server project has no creation event until creation and its
/// receipt commit together. Only the server's catalog lock may call this.
#[cfg(feature = "server")]
pub(crate) fn prepare_server_project(
    data_root: &Path,
    project_id: &Uuid,
    attribution: &Attribution,
) -> Result<StoreInfo, AppError> {
    create_project_database(data_root, project_id, None, attribution, false)
}

fn create_project_database(
    data_root: &Path,
    project_id: &Uuid,
    key: Option<&str>,
    attribution: &Attribution,
    record_creation: bool,
) -> Result<StoreInfo, AppError> {
    let attribution_json = attribution.validated_json()?;
    let data_root = validate_storage_root(data_root)?;
    let db_path = data_root_project_path(&data_root, &project_id.to_string());
    // Check the actual database target before creating any descendant.  The
    // project directory may be a local symlink or a mount below an otherwise
    // valid data root.
    validate_storage_path(&db_path)?;
    if let Some(parent) = db_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| AppError::io_path("create the project directory", parent, error))?;
    }
    let _lock = acquire_exclusive_lock(&db_path.with_extension("create.lock"))?;
    if db_path.exists() {
        let mut conn = Connection::open(&db_path)?;
        let version = schema_version(&conn)?;
        if version == 0 && !table_exists(&conn, "project")? && !table_exists(&conn, "tasks")? {
            configure_writer(&conn)?;
            initialize_new_database(
                &mut conn,
                project_id,
                key,
                &attribution_json,
                record_creation,
            )?;
        } else {
            let info = verify_existing_project(&db_path, project_id)?;
            return Ok(info);
        }
    } else {
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&db_path)
            .map_err(|error| AppError::io_path("create the project database", &db_path, error))?;
        let mut conn = Connection::open(&db_path)?;
        configure_writer(&conn)?;
        initialize_new_database(
            &mut conn,
            project_id,
            key,
            &attribution_json,
            record_creation,
        )?;
    }
    let info = verify_existing_project(&db_path, project_id)?;
    Ok(info)
}

fn schema_version(conn: &Connection) -> Result<i32, AppError> {
    Ok(conn.pragma_query_value(None, "user_version", |row| row.get::<_, i32>(0))?)
}

fn table_exists(conn: &Connection, table: &str) -> Result<bool, AppError> {
    Ok(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
        [table],
        |row| row.get::<_, i64>(0),
    )? != 0)
}

fn column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool, AppError> {
    let mut statement = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        if row.get::<_, String>(1)? == column {
            return Ok(true);
        }
    }
    Ok(false)
}

fn configure_writer(conn: &Connection) -> Result<(), AppError> {
    conn.busy_timeout(Duration::from_secs(5))?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "FULL")?;
    Ok(())
}

/// Snapshot fields compared between consecutive task events, in output order.
const HISTORY_FIELDS: [&str; 6] = ["title", "body", "status", "priority", "labels", "deps"];

/// Column holding `ok` (1 when the event has a comparable predecessor);
/// the six per-field flags follow it.
const HISTORY_OK_COLUMN: usize = 6;

/// Column of the raw snapshot text when `history_sql` selects it.
const HISTORY_ATTRIBUTION_COLUMN: usize = HISTORY_OK_COLUMN + 1 + HISTORY_FIELDS.len();
const HISTORY_SNAPSHOT_COLUMN: usize = HISTORY_ATTRIBUTION_COLUMN + 1;

/// Builds the history query from fixed fragments (never user input). The page
/// is materialized first so each event's predecessor snapshot is looked up
/// once; field comparisons then run in SQL, so snapshot bodies are returned
/// only when `with_snapshot` asks for them. A field counts as changed only
/// when both snapshots contain it, so older snapshots without labels or
/// priority do not report spurious changes. Invalid legacy snapshot text
/// makes the comparison unavailable instead of failing the read.
fn history_sql(filter: &str, limit: &str, with_snapshot: bool) -> String {
    let flags = HISTORY_FIELDS
        .iter()
        .map(|field| {
            format!(
                "CASE WHEN ok THEN json_type(s, '$.{field}') IS NOT NULL
                   AND json_type(ps, '$.{field}') IS NOT NULL
                   AND json_extract(s, '$.{field}') IS NOT json_extract(ps, '$.{field}')
                 ELSE 0 END"
            )
        })
        .collect::<Vec<_>>()
        .join(", ");
    let snapshot = if with_snapshot { ", s" } else { "" };
    format!(
        "WITH page AS MATERIALIZED (
            SELECT e.event_id, e.task_id, e.entity_type, e.operation, e.resulting_version,
                   e.created_ms, e.snapshot_json AS s, e.attribution_json,
                   (SELECT p.snapshot_json FROM events p
                     WHERE p.task_id = e.task_id AND p.entity_type = 'task'
                       AND p.event_id < e.event_id
                     ORDER BY p.event_id DESC LIMIT 1) AS ps
            FROM events e
            WHERE {filter}
            ORDER BY e.event_id ASC LIMIT {limit}
        ),
        checked AS (
            SELECT *, COALESCE(ps IS NOT NULL AND json_valid(s) AND json_valid(ps), 0) AS ok
            FROM page
        )
        SELECT event_id, task_id, entity_type, operation, resulting_version, created_ms, ok,
               {flags}, attribution_json{snapshot}
        FROM checked ORDER BY event_id ASC"
    )
}

fn history_event_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<HistoryEvent> {
    let changed_fields = if r.get::<_, bool>(HISTORY_OK_COLUMN)? {
        let mut fields = Vec::new();
        for (offset, field) in HISTORY_FIELDS.iter().enumerate() {
            if r.get::<_, bool>(HISTORY_OK_COLUMN + 1 + offset)? {
                fields.push((*field).to_string());
            }
        }
        Some(fields)
    } else {
        None
    };
    Ok(HistoryEvent {
        event_id: r.get::<_, i64>(0)? as u64,
        task_id: r.get::<_, Option<i64>>(1)?.map(|v| v as u64),
        entity_type: r.get::<_, String>(2)?,
        operation: r.get::<_, String>(3)?,
        resulting_version: r.get::<_, i64>(4)?,
        created_ms: r.get::<_, i64>(5)?,
        attribution: read_json_column(r, HISTORY_ATTRIBUTION_COLUMN)?,
        changed_fields,
        snapshot_json: None,
    })
}

/// Most task IDs one `show` call accepts; matches the list page limit.
pub const MAX_SHOW_IDS: usize = 100;

fn validate_limit(limit: usize) -> Result<usize, AppError> {
    if (1..=100).contains(&limit) {
        Ok(limit)
    } else {
        Err(AppError::Validation(format!(
            "invalid limit {limit}: the list limit must be between 1 and 100; pass --limit with a value in that range"
        )))
    }
}

fn create_schema_objects(tx: &rusqlite::Transaction<'_>) -> Result<(), AppError> {
    tx.execute_batch(&format!(
        "
        CREATE TABLE project(
            project_id TEXT PRIMARY KEY,
            rules_markdown TEXT NOT NULL DEFAULT '',
            rules_version INTEGER NOT NULL DEFAULT 1,
            next_task_number INTEGER NOT NULL DEFAULT 1,
            project_key {PROJECT_KEY_DEFINITION}
        );
        CREATE TABLE tasks(
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            status TEXT NOT NULL,
            version INTEGER NOT NULL,
            created_ms INTEGER NOT NULL,
            updated_ms INTEGER NOT NULL,
            CHECK (version > 0),
            CHECK (status IN ('draft','todo','in-progress','to-verify','blocked','done','cancelled'))
        );
        CREATE TABLE dependencies(
            task_id INTEGER NOT NULL,
            depends_on_id INTEGER NOT NULL,
            PRIMARY KEY(task_id, depends_on_id),
            FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE,
            FOREIGN KEY(depends_on_id) REFERENCES tasks(id) ON DELETE CASCADE
        );
        CREATE TABLE events(
            event_id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id INTEGER,
            entity_type TEXT NOT NULL,
            operation TEXT NOT NULL,
            resulting_version INTEGER NOT NULL,
            created_ms INTEGER NOT NULL,
            snapshot_json TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE
        );
        CREATE TABLE imports(
            input_sha256 TEXT PRIMARY KEY,
            source_name TEXT NOT NULL,
            original_source BLOB NOT NULL,
            report_json TEXT NOT NULL,
            imported_ms INTEGER NOT NULL
        );
        CREATE INDEX idx_tasks_status_id ON tasks(status, id);
        CREATE INDEX idx_dependencies_depends_on_id ON dependencies(depends_on_id);
        CREATE INDEX idx_events_task_id ON events(task_id, event_id);
        "
    ))?;
    Ok(())
}

fn initialize_new_database(
    conn: &mut Connection,
    project_id: &Uuid,
    key: Option<&str>,
    attribution_json: &str,
    record_creation: bool,
) -> Result<(), AppError> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    create_schema_objects(&tx)?;
    crate::labels::create_schema(&tx)?;
    create_selection_schema(&tx)?;
    create_attribution_schema(&tx)?;
    create_receipt_schema(&tx)?;
    tx.execute(
        "INSERT INTO project(project_id, rules_markdown, rules_version, next_task_number, project_key) VALUES (?1, '', 1, 1, ?2)",
        params![project_id.to_string(), key],
    )?;
    if record_creation {
        tx.execute(
        "INSERT INTO metadata_events(operation,created_ms,snapshot_json,attribution_json) VALUES ('create',?1,?2,?3)",
        params![sqlite_now_ms(), json!({"project_id": project_id, "project_key": key}).to_string(), attribution_json],
    )?;
    }
    tx.pragma_update(None, "user_version", CURRENT_SCHEMA_VERSION)?;
    tx.commit()?;
    Ok(())
}

fn validate_current_schema(
    conn: &Connection,
    expected: &Uuid,
    db_path: &Path,
) -> Result<(), AppError> {
    let missing = |what: &str| {
        AppError::Database(format!(
            "{} is missing {what}; expected the tasks-cli schema version {CURRENT_SCHEMA_VERSION}. Restore the database from a backup, or run tasks init --root <dir> to create a new one",
            db_path.display()
        ))
    };
    let version = schema_version(conn)?;
    if version != CURRENT_SCHEMA_VERSION {
        return Err(AppError::Database(format!(
            "{} has schema version {version}; this build requires {CURRENT_SCHEMA_VERSION}. Run tasks migrate --project {expected}.",
            db_path.display()
        )));
    }
    for table in [
        "project",
        "tasks",
        "dependencies",
        "events",
        "imports",
        "task_labels",
        "tasks_fts",
        "metadata_events",
        "mutation_receipts",
    ] {
        if !table_exists(conn, table)? {
            return Err(missing(&format!("the {table} table")));
        }
    }
    validate_receipt_schema(conn)?;
    for column in [
        "project_id",
        "rules_markdown",
        "rules_version",
        "next_task_number",
        "project_key",
    ] {
        if !column_exists(conn, "project", column)? {
            return Err(missing(&format!("the project.{column} column")));
        }
    }
    for column in [
        "id",
        "title",
        "body",
        "status",
        "version",
        "created_ms",
        "updated_ms",
        "priority",
    ] {
        if !column_exists(conn, "tasks", column)? {
            return Err(missing(&format!("the tasks.{column} column")));
        }
    }
    for (table, columns) in [
        (
            "mutation_receipts",
            [
                "request_id",
                "actor_id",
                "installation_id",
                "route",
                "payload_sha256",
                "status",
                "response_json",
            ]
            .as_slice(),
        ),
        ("dependencies", ["task_id", "depends_on_id"].as_slice()),
        ("task_labels", ["task_id", "label"].as_slice()),
        ("tasks_fts", ["title", "body"].as_slice()),
        (
            "events",
            [
                "event_id",
                "task_id",
                "entity_type",
                "operation",
                "resulting_version",
                "created_ms",
                "snapshot_json",
                "attribution_json",
            ]
            .as_slice(),
        ),
        (
            "imports",
            [
                "input_sha256",
                "source_name",
                "original_source",
                "report_json",
                "imported_ms",
            ]
            .as_slice(),
        ),
        (
            "metadata_events",
            [
                "event_id",
                "operation",
                "created_ms",
                "snapshot_json",
                "attribution_json",
            ]
            .as_slice(),
        ),
    ] {
        for column in columns {
            if !column_exists(conn, table, column)? {
                return Err(missing(&format!("the {table}.{column} column")));
            }
        }
    }
    for trigger in [
        "tasks_fts_insert",
        "tasks_fts_update",
        "tasks_fts_delete",
        "metadata_events_no_update",
        "metadata_events_no_delete",
        "mutation_receipts_no_update",
        "mutation_receipts_no_delete",
    ] {
        let count: i64 = conn.query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name=?1",
            [trigger],
            |r| r.get(0),
        )?;
        if count != 1 {
            return Err(missing(&format!("the {trigger} trigger")));
        }
    }
    let project_count: i64 =
        conn.query_row("SELECT COUNT(*) FROM project", [], |row| row.get(0))?;
    if project_count != 1 {
        return Err(AppError::Database(format!(
            "{} has {project_count} rows in the project table; expected exactly 1. Restore the database from a backup",
            db_path.display()
        )));
    }
    let project: String = conn.query_row("SELECT project_id FROM project", [], |row| row.get(0))?;
    let actual = Uuid::parse_str(&project).map_err(|error| {
        AppError::Database(format!(
            "{} has an invalid project id '{project}': {error}; restore the database from a backup",
            db_path.display()
        ))
    })?;
    if actual != *expected {
        return Err(AppError::Usage(format!(
            "{} belongs to project {actual}, not {expected}; pass --project {actual} or open the database for {expected}",
            db_path.display()
        )));
    }
    Ok(())
}

fn verify_existing_project(db_path: &Path, expected: &Uuid) -> Result<StoreInfo, AppError> {
    let conn = open_for_reading(db_path, rusqlite::OpenFlags::empty())?;
    let version = schema_version(&conn)?;
    if version > CURRENT_SCHEMA_VERSION {
        return Err(AppError::Database(format!(
            "{} has schema version {version}, newer than this build supports ({CURRENT_SCHEMA_VERSION}); upgrade tasks-cli to a build that supports it",
            db_path.display()
        )));
    }
    if version < CURRENT_SCHEMA_VERSION {
        return Err(AppError::Database(format!(
            "{} has schema version {version}; this build requires {CURRENT_SCHEMA_VERSION}. Run tasks migrate --project {expected}.",
            db_path.display()
        )));
    }
    validate_current_schema(&conn, expected, db_path)?;
    Ok(StoreInfo {
        project_id: *expected,
        db_path: db_path.to_path_buf(),
        project_key: crate::keys::read_key(&conn)?,
    })
}

fn ensure_column(
    tx: &rusqlite::Transaction<'_>,
    table: &str,
    column: &str,
    definition: &str,
) -> Result<(), AppError> {
    if !column_exists(tx, table, column)? {
        tx.execute_batch(&format!(
            "ALTER TABLE {table} ADD COLUMN {column} {definition}"
        ))?;
    }
    Ok(())
}

fn migrate_v0_to_v1(
    tx: &rusqlite::Transaction<'_>,
    expected_project: &Uuid,
    db_path: &Path,
) -> Result<(), AppError> {
    if !table_exists(tx, "project")? {
        tx.execute_batch(
            "CREATE TABLE project(
                project_id TEXT PRIMARY KEY,
                rules_markdown TEXT NOT NULL DEFAULT '',
                rules_version INTEGER NOT NULL DEFAULT 1,
                next_task_number INTEGER NOT NULL DEFAULT 1
            )",
        )?;
    } else {
        if !column_exists(tx, "project", "project_id")? {
            return Err(AppError::Database(format!(
                "{}: legacy project table has no project_id column; restore the database from a backup",
                db_path.display()
            )));
        }
        ensure_column(tx, "project", "rules_markdown", "TEXT NOT NULL DEFAULT ''")?;
        ensure_column(tx, "project", "rules_version", "INTEGER NOT NULL DEFAULT 1")?;
        ensure_column(
            tx,
            "project",
            "next_task_number",
            "INTEGER NOT NULL DEFAULT 1",
        )?;
    }
    if !table_exists(tx, "tasks")? {
        tx.execute_batch(
            "CREATE TABLE tasks(
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                status TEXT NOT NULL,
                version INTEGER NOT NULL,
                created_ms INTEGER NOT NULL,
                updated_ms INTEGER NOT NULL,
                CHECK (version > 0),
                CHECK (status IN ('backlog','ready','in-progress','blocked','done','cancelled'))
            )",
        )?;
    } else {
        for required in ["id", "title", "body", "status"] {
            if !column_exists(tx, "tasks", required)? {
                return Err(AppError::Database(format!(
                    "{}: legacy tasks table has no {required} column; restore the database from a backup",
                    db_path.display()
                )));
            }
        }
        ensure_column(tx, "tasks", "version", "INTEGER NOT NULL DEFAULT 1")?;
        ensure_column(tx, "tasks", "created_ms", "INTEGER NOT NULL DEFAULT 0")?;
        ensure_column(tx, "tasks", "updated_ms", "INTEGER NOT NULL DEFAULT 0")?;
    }
    let had_legacy_dependencies = table_exists(tx, "dependencies")?;
    if !had_legacy_dependencies {
        tx.execute_batch(
            "CREATE TABLE dependencies(
                task_id INTEGER NOT NULL,
                depends_on_id INTEGER NOT NULL,
                PRIMARY KEY(task_id, depends_on_id),
                FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE,
                FOREIGN KEY(depends_on_id) REFERENCES tasks(id) ON DELETE CASCADE
            )",
        )?;
    }
    if !table_exists(tx, "events")? {
        tx.execute_batch(
            "CREATE TABLE events(
                event_id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id INTEGER,
                entity_type TEXT NOT NULL,
                operation TEXT NOT NULL,
                resulting_version INTEGER NOT NULL,
                created_ms INTEGER NOT NULL,
                snapshot_json TEXT NOT NULL,
                FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE
            )",
        )?;
    }
    if !table_exists(tx, "imports")? {
        tx.execute_batch(
            "CREATE TABLE imports(
                input_sha256 TEXT PRIMARY KEY,
                source_name TEXT NOT NULL,
                original_source BLOB NOT NULL,
                report_json TEXT NOT NULL,
                imported_ms INTEGER NOT NULL
            )",
        )?;
    }
    for (table, columns) in [
        ("dependencies", ["task_id", "depends_on_id"].as_slice()),
        (
            "events",
            [
                "event_id",
                "task_id",
                "entity_type",
                "operation",
                "resulting_version",
                "created_ms",
                "snapshot_json",
            ]
            .as_slice(),
        ),
        (
            "imports",
            [
                "input_sha256",
                "source_name",
                "original_source",
                "report_json",
                "imported_ms",
            ]
            .as_slice(),
        ),
    ] {
        for column in columns {
            if !column_exists(tx, table, column)? {
                return Err(AppError::Database(format!(
                    "{}: legacy {table} table has no {column} column; restore the database from a backup",
                    db_path.display()
                )));
            }
        }
    }
    tx.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_tasks_status_id ON tasks(status, id);
         CREATE INDEX IF NOT EXISTS idx_dependencies_depends_on_id ON dependencies(depends_on_id);
         CREATE INDEX IF NOT EXISTS idx_events_task_id ON events(task_id, event_id);",
    )?;

    let mut dependency_rows = tx.prepare(
        "SELECT task_id, depends_on_id FROM dependencies ORDER BY task_id, depends_on_id",
    )?;
    let dependency_iter =
        dependency_rows.query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)))?;
    let mut dependency_edges = Vec::new();
    for row in dependency_iter {
        dependency_edges.push(row?);
    }
    drop(dependency_rows);
    let mut seen_dependencies = HashSet::new();
    let mut dependency_counts = HashMap::<i64, usize>::new();
    for (task_id, depends_on_id) in &dependency_edges {
        if !seen_dependencies.insert((*task_id, *depends_on_id)) {
            return Err(AppError::Database(format!(
                "{}: legacy dependencies contains duplicate edge (T-{task_id:03}, T-{depends_on_id:03}); restore the database from a backup",
                db_path.display()
            )));
        }
        let count = dependency_counts.entry(*task_id).or_default();
        *count += 1;
        if *count > MAX_DEPENDENCIES {
            return Err(AppError::Database(format!(
                "{}: legacy task T-{task_id:03} has more than {MAX_DEPENDENCIES} dependencies; restore the database from a backup",
                db_path.display()
            )));
        }
    }
    for (task_id, depends_on_id) in &dependency_edges {
        if *task_id <= 0 || *depends_on_id <= 0 {
            return Err(AppError::Database(format!(
                "{}: legacy dependencies row ({task_id}, {depends_on_id}) contains a non-positive task id; restore the database from a backup",
                db_path.display()
            )));
        }
        let source_exists: i64 = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM tasks WHERE id=?1)",
            [task_id],
            |row| row.get(0),
        )?;
        if source_exists == 0 {
            return Err(AppError::Database(format!(
                "{}: legacy dependency source T-{task_id:03} does not exist; restore the database from a backup",
                db_path.display()
            )));
        }
        let exists: i64 = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM tasks WHERE id=?1)",
            [depends_on_id],
            |row| row.get(0),
        )?;
        if exists == 0 {
            return Err(AppError::Database(format!(
                "{}: legacy dependency T-{task_id:03} references T-{depends_on_id:03}, which does not exist; restore the database from a backup",
                db_path.display()
            )));
        }
        if task_id == depends_on_id {
            return Err(AppError::Database(format!(
                "{}: legacy dependency T-{task_id:03} depends on itself; restore the database from a backup",
                db_path.display()
            )));
        }
    }
    let mut cycle_statement = tx.prepare(
        "WITH RECURSIVE reach(root, node) AS (
             SELECT task_id, depends_on_id FROM dependencies
             UNION
             SELECT reach.root, dependencies.depends_on_id
             FROM reach
             JOIN dependencies ON dependencies.task_id = reach.node
         )
         SELECT DISTINCT root FROM reach WHERE root = node ORDER BY root",
    )?;
    let cycle_rows = cycle_statement.query_map([], |row| row.get::<_, i64>(0))?;
    let mut cycle_tasks = Vec::new();
    for row in cycle_rows {
        cycle_tasks.push(row?);
    }
    drop(cycle_statement);
    if !cycle_tasks.is_empty() {
        let key = crate::keys::read_key(tx)?;
        let listed = cycle_tasks
            .iter()
            .map(|id| render_keyed_task_id(key.as_deref(), *id as u64))
            .collect::<Vec<_>>()
            .join(", ");
        return Err(AppError::Database(format!(
            "{}: legacy dependency graph contains a cycle involving {listed}; restore the database from a backup",
            db_path.display()
        )));
    }

    // A v0 database may have created `dependencies` without the composite
    // primary key or foreign keys.  Rebuild it even when the columns look
    // compatible so the accepted legacy data has the same invariants as a
    // fresh store.  The caller owns the surrounding transaction, therefore a
    // failed rebuild or validation rolls back the original table unchanged.
    if had_legacy_dependencies {
        tx.execute_batch(
            "CREATE TABLE dependencies_v1(
                task_id INTEGER NOT NULL,
                depends_on_id INTEGER NOT NULL,
                PRIMARY KEY(task_id, depends_on_id),
                FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE,
                FOREIGN KEY(depends_on_id) REFERENCES tasks(id) ON DELETE CASCADE
            );
            INSERT INTO dependencies_v1(task_id, depends_on_id)
                SELECT task_id, depends_on_id FROM dependencies;
            DROP TABLE dependencies;
            ALTER TABLE dependencies_v1 RENAME TO dependencies;",
        )?;
    }
    tx.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_dependencies_depends_on_id ON dependencies(depends_on_id);",
    )?;

    let project_count: i64 = tx.query_row("SELECT COUNT(*) FROM project", [], |row| row.get(0))?;
    if project_count > 1 {
        return Err(AppError::Database(format!(
            "{}: legacy project table has {project_count} rows; expected at most 1. Restore the database from a backup",
            db_path.display()
        )));
    }
    if project_count == 0 {
        tx.execute(
            "INSERT INTO project(project_id, rules_markdown, rules_version, next_task_number) VALUES (?1, '', 1, 1)",
            [expected_project.to_string()],
        )?;
    } else {
        let project: String =
            tx.query_row("SELECT project_id FROM project", [], |row| row.get(0))?;
        let actual = Uuid::parse_str(&project).map_err(|error| {
            AppError::Database(format!(
                "{}: legacy project identity '{project}' is not a UUID ({error}); restore the database from a backup",
                db_path.display()
            ))
        })?;
        if actual != *expected_project {
            return Err(AppError::Usage(format!(
                "{}: this database belongs to project {actual}, not {expected_project}; pass --project {actual}, or restore the backup for {expected_project}",
                db_path.display()
            )));
        }
    }

    let mut legacy_tasks = Vec::new();
    let mut rows = tx.prepare(
        "SELECT id, title, body, status, version, created_ms, updated_ms FROM tasks ORDER BY id",
    )?;
    let iter = rows.query_map([], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, i64>(4)?,
            row.get::<_, i64>(5)?,
            row.get::<_, i64>(6)?,
        ))
    })?;
    for row in iter {
        legacy_tasks.push(row?);
    }
    drop(rows);
    let mut max_id = 0i64;
    for (id, title, body, status, version, created_ms, _) in legacy_tasks {
        if id <= 0 || version <= 0 {
            return Err(AppError::Database(format!(
                "{}: legacy task {id} has id or version {version} outside the allowed range; restore the database from a backup",
                db_path.display()
            )));
        }
        validate_status(&status)?;
        max_id = max_id.max(id);
        let event_exists: i64 = tx.query_row(
            "SELECT COUNT(*) FROM events WHERE task_id=?1 AND entity_type='task'",
            [id],
            |row| row.get(0),
        )?;
        if event_exists == 0 {
            let mut dependency_rows = tx.prepare(
                "SELECT depends_on_id FROM dependencies WHERE task_id=?1 ORDER BY depends_on_id",
            )?;
            let dependencies = dependency_rows
                .query_map([id], |row| row.get::<_, i64>(0))?
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .map(|value| value as u64)
                .collect::<Vec<_>>();
            tx.execute(
                "INSERT INTO events(task_id,entity_type,operation,resulting_version,created_ms,snapshot_json)
                 VALUES (?1,'task','migrated',?2,?3,?4)",
                params![
                    id,
                    version,
                    created_ms,
                    json!({"id": id, "title": title, "body": body, "status": status, "version": version, "deps": dependencies}).to_string()
                ],
            )?;
        }
    }
    let next = max_id.checked_add(1).ok_or_else(|| {
        AppError::Database(format!(
            "{}: the largest legacy task id {max_id} cannot be incremented; restore the database from a backup",
            db_path.display()
        ))
    })?;
    tx.execute(
        "UPDATE project SET next_task_number = CASE WHEN next_task_number <= ?1 THEN ?1 ELSE next_task_number END",
        [next],
    )?;
    tx.execute_batch("PRAGMA user_version = 1")?;
    Ok(())
}

fn migrate_v1_to_v2(tx: &rusqlite::Transaction<'_>) -> Result<(), AppError> {
    // Rebuild only tasks: changing its CHECK constraint in place is unsupported.
    // The caller disables foreign keys before BEGIN so DROP cannot cascade into
    // dependencies or append-only history. Both are validated before COMMIT.
    tx.execute_batch(
        "CREATE TABLE tasks_v2(
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            status TEXT NOT NULL,
            version INTEGER NOT NULL,
            created_ms INTEGER NOT NULL,
            updated_ms INTEGER NOT NULL,
            CHECK (version > 0),
            CHECK (status IN ('draft','todo','in-progress','blocked','done','cancelled'))
        );
        INSERT INTO tasks_v2(id,title,body,status,version,created_ms,updated_ms)
        SELECT id,title,body,
            CASE status WHEN 'backlog' THEN 'draft' WHEN 'ready' THEN 'todo' ELSE status END,
            version,created_ms,updated_ms FROM tasks;
        DROP TABLE tasks;
        ALTER TABLE tasks_v2 RENAME TO tasks;
        CREATE INDEX idx_tasks_status_id ON tasks(status,id);
        PRAGMA user_version = 2;",
    )?;
    Ok(())
}

fn migrate_v4_to_v5(tx: &rusqlite::Transaction<'_>) -> Result<(), AppError> {
    // Rebuild tasks to widen its status CHECK with `to-verify`, keeping the
    // column order of a fresh schema 5 store (priority last). The caller
    // disables foreign keys before BEGIN so DROP cannot cascade into
    // dependencies, labels or history; the FTS triggers are dropped and
    // recreated around the swap, and the external-content index keeps its
    // rowids because task IDs are copied unchanged.
    tx.execute_batch(
        "DROP TRIGGER tasks_fts_insert;
        DROP TRIGGER tasks_fts_delete;
        DROP TRIGGER tasks_fts_update;
        CREATE TABLE tasks_v5(
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            status TEXT NOT NULL,
            version INTEGER NOT NULL,
            created_ms INTEGER NOT NULL,
            updated_ms INTEGER NOT NULL,
            priority TEXT NOT NULL DEFAULT 'P2' CHECK(priority IN ('P0','P1','P2','P3')),
            CHECK (version > 0),
            CHECK (status IN ('draft','todo','in-progress','to-verify','blocked','done','cancelled'))
        );
        INSERT INTO tasks_v5(id,title,body,status,version,created_ms,updated_ms,priority)
        SELECT id,title,body,status,version,created_ms,updated_ms,priority FROM tasks;
        DROP TABLE tasks;
        ALTER TABLE tasks_v5 RENAME TO tasks;
        CREATE INDEX idx_tasks_status_id ON tasks(status,id);
        CREATE INDEX idx_tasks_priority_id ON tasks(priority,id);
        CREATE INDEX idx_tasks_status_priority_id ON tasks(status,priority,id);",
    )?;
    crate::full_text::create_triggers(tx)?;
    tx.execute_batch("PRAGMA user_version = 5;")?;
    Ok(())
}

fn migrate_v5_to_v6(tx: &rusqlite::Transaction<'_>) -> Result<(), AppError> {
    // Additive: existing projects keep working with T-N until a person
    // assigns a key with `project-key --set`.
    ensure_column(tx, "project", "project_key", PROJECT_KEY_DEFINITION)?;
    tx.execute_batch("PRAGMA user_version = 6;")?;
    Ok(())
}

fn sqlite_now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

fn validate_status(raw: &str) -> Result<TaskStatus, AppError> {
    TaskStatus::from_str(raw).map_err(AppError::Validation)
}

fn validate_title_body(who: &str, title: &str, body: &str) -> Result<(), AppError> {
    let title_len = title.chars().count();
    if title_len == 0 {
        return Err(AppError::Validation(format!(
            "{who}: the title is empty; provide a non-empty title"
        )));
    }
    if title_len > TITLE_MAX_CHARS {
        return Err(AppError::Validation(format!(
            "{who}: the title has {title_len} characters; the limit is {TITLE_MAX_CHARS}. Shorten the title"
        )));
    }
    if body.len() > BODY_MAX_BYTES {
        return Err(AppError::Validation(format!(
            "{who}: the body has {} bytes; the limit is {BODY_MAX_BYTES}. Trim the body",
            body.len()
        )));
    }
    Ok(())
}

fn validate_rules(who: &str, body: &str) -> Result<(), AppError> {
    if body.len() > RULES_MAX_BYTES {
        return Err(AppError::Validation(format!(
            "{who}: the shared rules have {} bytes; the limit is {RULES_MAX_BYTES}. Trim the rules.",
            body.len()
        )));
    }
    Ok(())
}

fn import_empty_store_message(project: &Uuid, task_rows: i64) -> String {
    format!(
        "import apply requires an empty store: project {project} already has {task_rows} task(s); import into a new project (tasks init --root <dir>) or remove the existing tasks."
    )
}

fn import_non_empty_rules_message(project: &Uuid) -> String {
    format!(
        "import apply requires empty shared rules: project {project} already has rules; clear them before importing, or import into a new project."
    )
}

fn normalize_dependencies(mut deps: Vec<u64>) -> Vec<u64> {
    deps.sort_unstable();
    deps
}

fn escape_like_literal(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.chars() {
        if matches!(ch, '\\' | '%' | '_') {
            escaped.push('\\');
        }
        escaped.push(ch);
    }
    escaped
}

#[cfg(feature = "test-hooks")]
fn maybe_precommit_fail(_operation: &str) -> Result<(), AppError> {
    if let Some(marker) = std::env::var_os("TASKS_PRECOMMIT_READY_FILE") {
        fs::write(marker, b"ready")?;
    }
    if let Ok(raw) = std::env::var("TASKS_HOLD_PRECOMMIT_MS") {
        let milliseconds = raw.parse::<u64>().map_err(|error| {
            AppError::Usage(format!(
                "{_operation}: invalid TASKS_HOLD_PRECOMMIT_MS value '{raw}': {error}; set it to a whole number of milliseconds"
            ))
        })?;
        std::thread::sleep(Duration::from_millis(milliseconds));
    }
    if std::env::var("TASKS_PRECOMMIT_FAIL").is_ok() {
        return Err(AppError::Usage(format!(
            "{_operation}: injected precommit failure (TASKS_PRECOMMIT_FAIL is set); unset it to run the operation for real"
        )));
    }
    Ok(())
}

#[cfg(not(feature = "test-hooks"))]
fn maybe_precommit_fail(_operation: &str) -> Result<(), AppError> {
    Ok(())
}

static BACKUP_COUNTER: AtomicU64 = AtomicU64::new(0);

fn validate_backup(
    path: &Path,
    expected_project: Option<&Uuid>,
    expected_schema: Option<i32>,
) -> Result<(), AppError> {
    let conn = open_for_reading(path, rusqlite::OpenFlags::empty())?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    let quick_check: String = conn.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    if quick_check != "ok" {
        return Err(AppError::Database(format!(
            "backup {} failed PRAGMA quick_check: {quick_check}; the file is corrupt, take a new backup",
            path.display()
        )));
    }
    let mut foreign_rows = conn.prepare("PRAGMA foreign_key_check")?;
    if foreign_rows.query([])?.next()?.is_some() {
        return Err(AppError::Database(format!(
            "backup {} failed PRAGMA foreign_key_check: it contains foreign-key violations; take a new backup",
            path.display()
        )));
    }
    let schema = schema_version(&conn)?;
    if let Some(expected_schema) = expected_schema {
        if schema != expected_schema {
            return Err(AppError::Database(format!(
                "backup {} has schema version {schema}; expected {expected_schema}",
                path.display()
            )));
        }
    }
    if let Some(expected_project) = expected_project {
        if expected_schema == Some(CURRENT_SCHEMA_VERSION) {
            validate_current_schema(&conn, expected_project, path)?;
        } else {
            let project = conn
                .query_row("SELECT project_id FROM project LIMIT 1", [], |row| {
                    row.get::<_, String>(0)
                })
                .optional()?
                .ok_or_else(|| {
                    AppError::Database(format!(
                        "backup {} has no project row; take a new backup",
                        path.display()
                    ))
                })?;
            let actual = Uuid::parse_str(&project).map_err(|error| {
                AppError::Database(format!(
                    "backup {} has an invalid project id '{project}': {error}; take a new backup",
                    path.display()
                ))
            })?;
            if actual != *expected_project {
                return Err(AppError::Usage(format!(
                    "backup {} belongs to project {actual}, not {expected_project}; check the backup path",
                    path.display()
                )));
            }
        }
    }
    Ok(())
}

fn remove_backup_sidecars(path: &Path) -> Result<(), AppError> {
    for sidecar in backup_sidecars(path) {
        match fs::remove_file(&sidecar) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(AppError::io_path(
                    "remove the backup sidecar",
                    &sidecar,
                    error,
                ))
            }
        }
    }
    Ok(())
}

fn backup_sidecars(path: &Path) -> [PathBuf; 2] {
    let Some(file_name) = path.file_name() else {
        return [PathBuf::new(), PathBuf::new()];
    };
    ["-wal", "-shm"].map(|suffix| {
        let mut sidecar_name = OsString::from(file_name);
        sidecar_name.push(suffix);
        path.with_file_name(sidecar_name)
    })
}

fn path_entry_exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn refuse_existing_backup_destination(out: &Path) -> Result<(), AppError> {
    if path_entry_exists(out) {
        return Err(AppError::Usage(format!(
            "refusing to overwrite {}: it already exists; choose a different --out path or move the existing file",
            out.display()
        )));
    }
    for sidecar in backup_sidecars(out) {
        if !sidecar.as_os_str().is_empty() && path_entry_exists(&sidecar) {
            return Err(AppError::Usage(format!(
                "refusing to publish {}: its SQLite sidecar {} already exists; choose a different --out path or move the existing sidecar",
                out.display(),
                sidecar.display()
            )));
        }
    }
    Ok(())
}

fn remove_backup_artifacts(path: &Path) -> Result<(), AppError> {
    match fs::remove_file(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(AppError::io_path("remove the backup file", path, error)),
    }
    remove_backup_sidecars(path)
}

fn publish_backup(
    conn: &Connection,
    out: &Path,
    expected_project: Option<&Uuid>,
    expected_schema: Option<i32>,
) -> Result<u64, AppError> {
    let out = out.to_path_buf();
    let parent = out.parent().unwrap_or_else(|| Path::new("."));
    validate_storage_root(parent)?;
    refuse_existing_backup_destination(&out)?;
    let name = out
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| {
            AppError::InvalidPath(format!(
                "--out {} has no file name; pass a file path such as backup.sqlite",
                out.display()
            ))
        })?;
    let temp = parent.join(format!(
        ".{name}.tasks-cli-tmp-{}-{}",
        std::process::id(),
        BACKUP_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let reserved = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)
        .map_err(|error| AppError::io_path("create the temporary backup file", &temp, error))?;
    drop(reserved);
    let result = (|| {
        conn.backup(
            rusqlite::MAIN_DB,
            &temp,
            None::<fn(rusqlite::backup::Progress)>,
        )?;
        validate_backup(&temp, expected_project, expected_schema)?;
        remove_backup_sidecars(&temp)?;
        // A destination sidecar may have appeared while SQLite produced and
        // validated the temporary backup.  Refuse publication while keeping
        // that unrelated sidecar untouched.
        refuse_existing_backup_destination(&out)?;
        match std::fs::hard_link(&temp, &out) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                return Err(AppError::Usage(format!(
                    "refusing to overwrite {}: it already exists; choose a different --out path or move the existing file",
                    out.display()
                )));
            }
            Err(error) => return Err(AppError::io_path("publish the backup", &out, error)),
        }
        Ok(std::fs::metadata(&out)
            .map_err(|error| AppError::io_path("read the backup size", &out, error))?
            .len())
    })();
    let cleanup = remove_backup_artifacts(&temp);
    match (result, cleanup) {
        (Ok(bytes), Ok(())) => Ok(bytes),
        (Ok(bytes), Err(_)) => Ok(bytes),
        (Err(error), _) => Err(error),
    }
}

// Publish a complete rendered export without replacing a competing writer's file.
fn publish_export(out: &Path, bytes: &[u8]) -> Result<(), AppError> {
    use std::io::Write;
    let parent = out.parent().unwrap_or_else(|| Path::new("."));
    let temp = parent.join(format!(".tasks-export-{}.tmp", Uuid::new_v4()));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)
        .map_err(|error| AppError::io_path("create temporary export", &temp, error))?;
    let result = (|| {
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|error| AppError::io_path("write export", &temp, error))?;
        fs::hard_link(&temp, out).map_err(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                AppError::Usage(format!(
                    "refusing to overwrite {}: it already exists; choose a different --out path",
                    out.display()
                ))
            } else {
                AppError::io_path("publish export", out, error)
            }
        })
    })();
    drop(file);
    let _ = fs::remove_file(&temp);
    result
}

fn project_db_path(data_root: &Path, project: &str) -> Result<(PathBuf, Uuid, PathBuf), AppError> {
    let data_root = validate_storage_root(data_root)?;
    let project_id = Uuid::parse_str(project).map_err(|error| {
        AppError::Usage(format!(
            "--project '{project}' is not a UUID ({error}); pass the UUID printed by tasks init"
        ))
    })?;
    let db_path = data_root_project_path(&data_root, &project_id.to_string());
    validate_storage_path(&db_path)?;
    if !db_path.is_file() {
        return Err(AppError::NotFoundCode(format!(
            "project {project} has no database at {}; run tasks init --root <dir> to create and bind a project, or pass an existing --project <UUID>",
            db_path.display()
        )));
    }
    Ok((db_path, project_id, data_root))
}

impl Store {
    #[cfg(feature = "server")]
    pub(crate) fn complete_server_project_creation(
        &mut self,
        name: &str,
        key: Option<&str>,
    ) -> Result<(), AppError> {
        let tx = WriteTransaction::begin(&mut self.conn)?;
        let exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM metadata_events WHERE operation='create')",
            [],
            |r| r.get(0),
        )?;
        if exists {
            return Err(AppError::Conflict(
                "project UUID already exists; bind to it instead of creating it again".into(),
            ));
        }
        tx.execute("UPDATE project SET project_key=?1", [key])?;
        tx.execute("INSERT INTO metadata_events(operation,created_ms,snapshot_json,attribution_json) VALUES('create',?1,?2,?3)",params![sqlite_now_ms(),json!({"project_id":self.project_id,"name":name,"project_key":key}).to_string(),self.attribution_json])?;
        tx.commit()?;
        self.project_key = key.map(str::to_string);
        Ok(())
    }
    pub fn set_attribution(&mut self, context: &Attribution) -> Result<(), AppError> {
        self.attribution_json = context.validated_json()?;
        Ok(())
    }

    /// Archive state is a metadata event. A later task event makes an archived
    /// project active without rewriting append-only history.
    pub fn effective_archive(&self) -> Result<Option<i64>, AppError> {
        let tx = self.conn.unchecked_transaction()?;
        let archived_at_ms = effective_archive_from(&tx)?;
        tx.commit()?;
        Ok(archived_at_ms)
    }

    pub fn set_archive(&mut self, archived: bool) -> Result<Option<i64>, AppError> {
        let tx = WriteTransaction::begin(&mut self.conn)?;
        let previous = effective_archive_from(&tx)?;
        if previous.is_some() == archived {
            tx.commit()?;
            return Ok(previous);
        }
        let watermark: i64 =
            tx.query_row("SELECT COALESCE(MAX(event_id),0) FROM events", [], |row| {
                row.get(0)
            })?;
        let archived_at_ms = archived.then(sqlite_now_ms);
        tx.execute(
            "INSERT INTO metadata_events(operation,created_ms,snapshot_json,attribution_json) VALUES('viewer-archive',?1,?2,?3)",
            params![sqlite_now_ms(), json!({"archived_at_ms":archived_at_ms,"task_event_watermark":watermark as u64}).to_string(), self.attribution_json],
        )?;
        tx.commit()?;
        Ok(archived_at_ms)
    }

    /// Bounded project/key audit history; these events never alter task versions.
    pub fn metadata_history(
        &self,
        after: Option<u64>,
        limit: usize,
    ) -> Result<Pagination<MetadataEvent>, AppError> {
        self.metadata_history_with_budget(after, limit, None)
    }

    pub fn metadata_history_with_budget(
        &self,
        after: Option<u64>,
        limit: usize,
        budget: Option<u64>,
    ) -> Result<Pagination<MetadataEvent>, AppError> {
        let limit = validate_limit(limit)?;
        let after = i64::try_from(after.unwrap_or(0)).map_err(|_| {
            AppError::Validation("metadata cursor exceeds the supported event range".into())
        })?;
        let tx = self.conn.unchecked_transaction()?;
        if let Some(budget) = budget {
            let bytes: u64 = tx.query_row(
                "SELECT COALESCE(SUM(length(CAST(snapshot_json AS BLOB))+length(CAST(attribution_json AS BLOB))+256),0) FROM (SELECT snapshot_json,attribution_json FROM metadata_events WHERE event_id>?1 ORDER BY event_id LIMIT ?2)",
                params![after, limit],
                |row| row.get(0),
            )?;
            if bytes > budget {
                return Err(AppError::ResponseLimit(
                    "project history exceeds the response budget; request a smaller page".into(),
                ));
            }
        }
        let mut statement = tx.prepare(
            "SELECT event_id,operation,created_ms,snapshot_json,attribution_json FROM metadata_events
             WHERE event_id > ?1 ORDER BY event_id LIMIT ?2",
        )?;
        let items = statement
            .query_map(params![after, limit], |row| {
                Ok(MetadataEvent {
                    event_id: row.get::<_, i64>(0)? as u64,
                    operation: row.get(1)?,
                    created_ms: row.get(2)?,
                    snapshot: read_json_column(row, 3)?.ok_or(
                        rusqlite::Error::InvalidColumnType(
                            3,
                            "snapshot_json".into(),
                            rusqlite::types::Type::Null,
                        ),
                    )?,
                    attribution: read_json_column(row, 4)?.ok_or(
                        rusqlite::Error::InvalidColumnType(
                            4,
                            "attribution_json".into(),
                            rusqlite::types::Type::Null,
                        ),
                    )?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let has_more = match items.last() {
            Some(last) => tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM metadata_events WHERE event_id>?1)",
                [last.event_id],
                |row| row.get::<_, bool>(0),
            )?,
            None => false,
        };
        let next_after = if has_more {
            items.last().map(|event| event.event_id)
        } else {
            None
        };
        drop(statement);
        tx.commit()?;
        Ok(Pagination {
            items,
            has_more,
            next_after,
        })
    }

    pub fn open_readonly(data_root: &Path, project: &str) -> Result<Self, AppError> {
        let (db_path, project_id, data_root) = project_db_path(data_root, project)?;
        let conn = open_for_reading(&db_path, rusqlite::OpenFlags::empty())?;
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        let user_version = schema_version(&conn)?;
        if user_version > CURRENT_SCHEMA_VERSION {
            return Err(AppError::Database(format!(
                "{} has schema version {user_version}, newer than this build supports ({CURRENT_SCHEMA_VERSION}); upgrade tasks-cli to a build that supports it",
                db_path.display()
            )));
        }
        if user_version < CURRENT_SCHEMA_VERSION {
            return Err(AppError::Database(format!(
                "{} has schema version {user_version}; this build requires {CURRENT_SCHEMA_VERSION}. Run tasks migrate --project {project}.",
                db_path.display()
            )));
        }
        validate_current_schema(&conn, &project_id, &db_path)?;
        let project_key = crate::keys::read_key(&conn)?;
        Ok(Self {
            project_id,
            db_path,
            conn,
            project_key,
            data_root,
            migration_lock: None,
            attribution_json: crate::attribution::current().validated_json()?,
        })
    }

    pub fn open_for_diagnostics(data_root: &Path, project: &str) -> Result<Self, AppError> {
        let (db_path, project_id, data_root) = project_db_path(data_root, project)?;
        let conn = open_for_reading(&db_path, rusqlite::OpenFlags::empty())?;
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        let project_key = crate::keys::read_key(&conn).ok().flatten();
        Ok(Self {
            project_id,
            db_path,
            conn,
            project_key,
            data_root,
            migration_lock: None,
            attribution_json: crate::attribution::current().validated_json()?,
        })
    }

    pub fn open_rw(data_root: &Path, project: &str) -> Result<Self, AppError> {
        let (db_path, project_id, data_root) = project_db_path(data_root, project)?;
        let conn =
            Connection::open_with_flags(&db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE)?;
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        let user_version = schema_version(&conn)?;
        if user_version > CURRENT_SCHEMA_VERSION {
            return Err(AppError::Database(format!(
                "{} has schema version {user_version}, newer than this build supports ({CURRENT_SCHEMA_VERSION}); upgrade tasks-cli to a build that supports it",
                db_path.display()
            )));
        }
        if user_version < CURRENT_SCHEMA_VERSION {
            return Err(AppError::Database(format!(
                "{} has schema version {user_version}; this build requires {CURRENT_SCHEMA_VERSION}. Run tasks migrate --project {project}.",
                db_path.display()
            )));
        }
        validate_current_schema(&conn, &project_id, &db_path)?;
        let project_key = crate::keys::read_key(&conn)?;
        Ok(Self {
            project_id,
            db_path,
            conn,
            project_key,
            data_root,
            migration_lock: None,
            attribution_json: crate::attribution::current().validated_json()?,
        })
    }

    pub fn open_for_migration(data_root: &Path, project: &str) -> Result<Self, AppError> {
        let (db_path, project_id, data_root) = project_db_path(data_root, project)?;
        let migration_lock = acquire_exclusive_lock(&db_path.with_extension("migrate.lock"))?;
        let conn =
            Connection::open_with_flags(&db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE)?;
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        let version = schema_version(&conn)?;
        if version > CURRENT_SCHEMA_VERSION {
            return Err(AppError::Database(format!(
                "{} has schema version {version}, newer than this build supports ({CURRENT_SCHEMA_VERSION}); upgrade tasks-cli to a build that supports it",
                db_path.display()
            )));
        }
        if table_exists(&conn, "project")? {
            let existing: Option<String> = conn
                .query_row("SELECT project_id FROM project LIMIT 1", [], |row| {
                    row.get(0)
                })
                .optional()?;
            if let Some(existing) = existing {
                if existing != project {
                    return Err(AppError::Usage(format!(
                        "{} stores project {existing}, not {project}; pass --project {existing}",
                        db_path.display()
                    )));
                }
            }
        }
        let project_key = crate::keys::read_key(&conn).ok().flatten();
        Ok(Self {
            project_id,
            db_path,
            conn,
            project_key,
            data_root,
            migration_lock: Some(migration_lock),
            attribution_json: crate::attribution::current().validated_json()?,
        })
    }

    /// Display form of a task ID in this project: `KEY-001` or `T-001`.
    pub fn display_id(&self, id: u64) -> String {
        render_keyed_task_id(self.project_key.as_deref(), id)
    }

    fn stamp(&self, items: &mut [TaskSummary]) {
        for item in items {
            item.display_id = self.display_id(item.id);
        }
    }

    /// Resolves `KEY-N`, `T-N` or `N` to a task number of this project. A
    /// reference with another key fails with exit 3 naming its project.
    pub fn resolve_ref(&self, raw: &str) -> Result<u64, AppError> {
        let reference = parse_task_ref(raw).map_err(AppError::Validation)?;
        reference
            .resolve(self.project_key.as_deref())
            .map_err(|key| {
                crate::keys::foreign_reference_error(
                    &self.data_root,
                    &key,
                    reference.id,
                    &self.project_id,
                    self.project_key.as_deref(),
                )
            })
    }

    /// Stores a new, already validated key and returns the previous one. The
    /// caller holds the registry lock and has checked uniqueness. Task bodies
    /// are not rewritten: old `OLDKEY-N` mentions stay as written.
    pub fn set_project_key(&mut self, key: &str) -> Result<Option<String>, AppError> {
        let tx = WriteTransaction::begin(&mut self.conn)?;
        let previous = crate::keys::read_key(&tx)?;
        if previous.as_deref() != Some(key) {
            let changed = tx.execute(
                "UPDATE project SET project_key = ?1 WHERE project_id = ?2",
                params![key, self.project_id.to_string()],
            )?;
            if changed != 1 {
                return Err(AppError::Database(format!(
                    "{} has no project row for {}; restore the database from a backup",
                    self.db_path.display(),
                    self.project_id
                )));
            }
            tx.execute(
                "INSERT INTO metadata_events(operation,created_ms,snapshot_json,attribution_json) VALUES ('set-key',?1,?2,?3)",
                params![sqlite_now_ms(), json!({"previous_key": previous, "project_key": key}).to_string(), self.attribution_json],
            )?;
            tx.commit()?;
        }
        self.project_key = Some(key.to_string());
        Ok(previous)
    }

    /// Resolves a comma-separated dependency list (`--deps`).
    pub fn resolve_ref_list(&self, raw: &str) -> Result<Vec<u64>, AppError> {
        raw.split(',')
            .filter(|item| !item.trim().is_empty())
            .map(|item| {
                self.resolve_ref(item).map_err(|error| match error {
                    AppError::Validation(message) => {
                        AppError::Validation(format!("--deps item '{}': {message}", item.trim()))
                    }
                    other => other,
                })
            })
            .collect()
    }

    pub fn project_rules(&self) -> Result<RuleRecord, AppError> {
        let row = self
            .conn
            .query_row(
                "SELECT rules_version, rules_markdown FROM project LIMIT 1",
                [],
                |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?;
        let (version, body) =
            row.ok_or_else(|| {
                AppError::Usage(format!(
                    "project {} has no row in its project table; the database is incomplete. Restore it from a backup, or run tasks init --root <dir> to create a new one",
                    self.project_id
                ))
            })?;
        Ok(RuleRecord {
            version: version as u64,
            body,
        })
    }

    /// Compatibility library view: all open tasks, paged by numeric ID.
    /// The CLI uses `select_tasks` for priority ordering and default readiness.
    pub fn list_tasks(
        &mut self,
        status: Option<&str>,
        after: Option<u64>,
        limit: usize,
    ) -> Result<Pagination<TaskSummary>, AppError> {
        self.list_tasks_with_label(status, after, limit, None)
    }

    pub fn list_tasks_with_label(
        &mut self,
        status: Option<&str>,
        after: Option<u64>,
        limit: usize,
        label: Option<&str>,
    ) -> Result<Pagination<TaskSummary>, AppError> {
        let label = crate::labels::filter(label)?;
        let page_size = validate_limit(limit)?;
        let snapshot = self.conn.unchecked_transaction()?;
        let fetch = page_size + 1;
        let mut summaries = Vec::new();
        let mut stmt = if status.is_some() {
            self.conn.prepare(
                "SELECT id, status, version, title, priority
                 FROM tasks
                 WHERE status = ?1 AND id > ?2 AND (?4 IS NULL OR EXISTS(SELECT 1 FROM task_labels l WHERE l.task_id=tasks.id AND l.label=?4))
                 ORDER BY id ASC LIMIT ?3",
            )?
        } else {
            self.conn.prepare(
                "SELECT id, status, version, title, priority
                 FROM tasks
                 WHERE status NOT IN ('done','cancelled') AND id > ?1 AND (?3 IS NULL OR EXISTS(SELECT 1 FROM task_labels l WHERE l.task_id=tasks.id AND l.label=?3))
                 ORDER BY id ASC LIMIT ?2",
            )?
        };
        let mut rows = if let Some(status) = status {
            stmt.query(params![status, after.unwrap_or(0), fetch as i64, label])?
        } else {
            stmt.query(params![after.unwrap_or(0), fetch as i64, label])?
        };
        while let Some(row) = rows.next()? {
            let status_text: String = row.get(1)?;
            let task_status = TaskStatus::from_row(&status_text).ok_or_else(|| {
                rusqlite::Error::InvalidColumnType(
                    1,
                    "status".to_string(),
                    rusqlite::types::Type::Text,
                )
            })?;
            summaries.push(TaskSummary {
                id: row.get::<_, i64>(0)? as u64,
                display_id: String::new(),
                status: task_status,
                version: row.get::<_, i64>(2)? as u64,
                title: row.get::<_, String>(3)?,
                priority: row
                    .get::<_, String>(4)?
                    .parse()
                    .map_err(AppError::Validation)?,
                deps: Vec::new(),
                labels: Vec::new(),
            });
        }
        drop(rows);
        drop(stmt);
        let mut has_more = false;
        let next_after = if summaries.len() > page_size {
            has_more = true;
            summaries.pop();
            summaries.last().map(|task| task.id)
        } else {
            summaries.last().map(|task| task.id)
        };
        let next_after = if has_more { next_after } else { None };
        let ids = summaries.iter().map(|task| task.id).collect::<Vec<_>>();
        let mut dependencies = Self::task_dependencies_for_ids(&self.conn, &ids)?;
        let mut labels = crate::labels::read_many(&self.conn, &ids)?;
        for row in summaries.iter_mut() {
            row.deps = dependencies.remove(&row.id).unwrap_or_default();
            row.labels = labels.remove(&row.id).unwrap_or_default();
        }
        self.stamp(&mut summaries);
        snapshot.commit()?;
        Ok(Pagination {
            items: summaries,
            has_more,
            next_after,
        })
    }

    /// Priority-ordered work selection. An explicit status bypasses readiness;
    /// the human view additionally requires an open task with that label.
    pub fn select_tasks(
        &mut self,
        status: Option<&str>,
        after: Option<ListCursor>,
        limit: usize,
        label: Option<&str>,
        open: bool,
        needs_human: bool,
    ) -> Result<SelectionPage, AppError> {
        let label = crate::labels::filter(label)?;
        let status = status
            .map(validate_status)
            .transpose()?
            .map(|v| v.to_string());
        let size = validate_limit(limit)?;
        let snapshot = self.conn.unchecked_transaction()?;
        // Every branch below is chosen in Rust from `status`/`open`/
        // `needs_human`, all known at call time, rather than encoded as a
        // `?N IS NULL OR ...`-guarded predicate bound at query time: SQLite
        // cannot tell at prepare time which side of a bound-parameter OR is
        // live, so a single shared query always fell back to a full
        // `idx_tasks_priority_id` scan evaluating RUNNABLE_PREDICATE's
        // correlated subqueries on every row, even when almost all rows are
        // done/cancelled (TSK-014, following TSK-013's finding on
        // perf-100k-dense). A first attempt replaced the scan's status
        // predicate with a literal `t.status IN (...)`, which does pick a
        // status-indexed SEARCH, but only after adding `USE TEMP B-TREE FOR
        // ORDER BY` (the single scan can no longer stream the whole result
        // in priority order, so it loses the LIMIT early exit) -- a real
        // regression on open-heavy stores (TSK-014 review). Instead each
        // needed status becomes its own `SELECT ... WHERE t.status=<literal>
        // ... ORDER BY t.priority,t.id` arm over `idx_tasks_status_priority_id`
        // (already sorted the way each arm needs), joined with `UNION ALL`
        // and a single outer `ORDER BY priority,id LIMIT`. SQLite recognizes
        // that each arm already emits its slice in the compound's sort order
        // and merges them (`MERGE (UNION ALL)`) instead of sorting the
        // union, so the LIMIT early exit survives.
        // Placeholders are named inline via `push_bind` rather than committed
        // to one fixed position layout, so a cursor can be omitted entirely
        // (not just `?N IS NULL`-guarded) when there is none: a real
        // `AND (t.priority,t.id) > (?,?)` clause lets a deep page seek
        // `status=? AND priority>?` on `idx_tasks_status_priority_id`
        // instead of a bound-parameter OR the planner can't resolve.
        let mut binds: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        let label_ph = push_bind(&mut binds, label.clone());
        let cursor_clause = match &after {
            Some(cursor) => {
                let priority_ph = push_bind(&mut binds, cursor.priority.to_string());
                let id_ph = push_bind(&mut binds, cursor.id);
                format!("AND (t.priority,t.id) > ({priority_ph},{id_ph})")
            }
            None => String::new(),
        };
        let sql = if let Some(explicit_status) = &status {
            let status_ph = push_bind(&mut binds, explicit_status.clone());
            let limit_ph = push_bind(&mut binds, (size + 1) as i64);
            let needs_human_clause = if needs_human {
                "AND t.status NOT IN ('done','cancelled')
                 AND EXISTS(SELECT 1 FROM task_labels l WHERE l.task_id=t.id AND l.label='needs-human')"
            } else {
                ""
            };
            format!(
                "SELECT t.id,t.status,t.version,t.title,t.priority FROM tasks t
                 WHERE t.status={status_ph}
                   {needs_human_clause}
                   AND ({label_ph} IS NULL OR EXISTS(SELECT 1 FROM task_labels l WHERE l.task_id=t.id AND l.label={label_ph}))
                   {cursor_clause}
                 ORDER BY t.priority,t.id LIMIT {limit_ph}"
            )
        } else {
            let limit_ph = push_bind(&mut binds, (size + 1) as i64);
            if needs_human {
                // Bypasses RUNNABLE_PREDICATE regardless of `--open` (matches
                // the previous shared-query semantics): every non-terminal
                // status, restricted to the needs-human label.
                union_arms_sql(
                    &non_terminal_statuses(),
                    "AND EXISTS(SELECT 1 FROM task_labels l WHERE l.task_id=t.id AND l.label='needs-human')",
                    &label_ph,
                    &cursor_clause,
                    &limit_ph,
                )
            } else if open {
                // Bypasses RUNNABLE_PREDICATE: every non-terminal status,
                // unfiltered by readiness.
                union_arms_sql(
                    &non_terminal_statuses(),
                    "",
                    &label_ph,
                    &cursor_clause,
                    &limit_ph,
                )
            } else {
                // Default view: RUNNABLE_PREDICATE's own `t.status IN
                // (...)` term already restricts matches to these two
                // statuses, so only they need an arm.
                union_arms_sql(
                    &RUNNABLE_STATUSES,
                    &format!("AND ({RUNNABLE_PREDICATE})"),
                    &label_ph,
                    &cursor_clause,
                    &limit_ph,
                )
            }
        };
        let mut statement = snapshot.prepare(&sql)?;
        let mut rows =
            statement.query(rusqlite::params_from_iter(binds.iter().map(|b| b.as_ref())))?;
        let mut items = Vec::new();
        while let Some(row) = rows.next()? {
            items.push(Self::selection_summary(row)?);
        }
        drop(rows);
        drop(statement);
        let has_more = items.len() > size;
        items.truncate(size);
        Self::populate_summaries(&snapshot, &mut items)?;
        self.stamp(&mut items);
        let next_after = if has_more {
            items.last().map(|t| {
                ListCursor {
                    priority: t.priority,
                    id: t.id,
                }
                .to_string()
            })
        } else {
            None
        };
        snapshot.commit()?;
        Ok(SelectionPage {
            items,
            has_more,
            next_after,
        })
    }

    fn selection_summary(row: &rusqlite::Row<'_>) -> Result<TaskSummary, AppError> {
        Ok(TaskSummary {
            id: row.get(0)?,
            display_id: String::new(),
            status: validate_status(&row.get::<_, String>(1)?)?,
            version: row.get(2)?,
            title: row.get(3)?,
            priority: row
                .get::<_, String>(4)?
                .parse()
                .map_err(AppError::Validation)?,
            deps: Vec::new(),
            labels: Vec::new(),
        })
    }

    fn populate_summaries(conn: &Connection, items: &mut [TaskSummary]) -> Result<(), AppError> {
        let ids = items.iter().map(|t| t.id).collect::<Vec<_>>();
        let mut deps = Self::task_dependencies_for_ids(conn, &ids)?;
        let mut labels = crate::labels::read_many(conn, &ids)?;
        for task in items {
            task.deps = deps.remove(&task.id).unwrap_or_default();
            task.labels = labels.remove(&task.id).unwrap_or_default();
        }
        Ok(())
    }

    pub fn unlocks(
        &mut self,
        offset: u64,
        limit: usize,
    ) -> Result<Pagination<UnlockSummary>, AppError> {
        let size = validate_limit(limit)?;
        let offset_sql = i64::try_from(offset).map_err(|_| {
            AppError::Validation("unlocks --offset exceeds SQLite's integer range".into())
        })?;
        let snapshot = self.conn.unchecked_transaction()?;
        // `runnable_count` used to run a correlated NOT EXISTS per (p,t) edge,
        // rescanning t's other dependencies on every row (O(edges * local
        // degree) on a dense-edge graph). The outer WHERE already guarantees
        // p.status is not 'done'/'cancelled'/'to-verify', so p always counts
        // toward t's unsatisfied-prerequisite total (the `unsat` CTE, whose
        // filter is the same NOT IN ('done','to-verify') the old subquery
        // used for "other" prerequisites). That makes "no other unsatisfied
        // prerequisite besides p" equivalent to "t has exactly one
        // unsatisfied prerequisite total", computed once per t instead of
        // once per edge (TSK-005).
        let mut statement = snapshot.prepare(
            "WITH unsat AS (
                SELECT d.task_id AS task_id, COUNT(*) AS unsat_count
                FROM dependencies d JOIN tasks prerequisite ON prerequisite.id=d.depends_on_id
                WHERE prerequisite.status NOT IN ('done','to-verify')
                GROUP BY d.task_id
             )
             SELECT p.id,p.status,p.version,p.title,p.priority,COUNT(*) AS direct_count,
                    SUM(CASE WHEN t.status IN ('todo','in-progress')
                      AND unsat.unsat_count=1
                      AND NOT EXISTS(SELECT 1 FROM task_labels l WHERE l.task_id=t.id AND l.label='needs-human')
                      THEN 1 ELSE 0 END) AS runnable_count
             FROM tasks p JOIN dependencies d ON d.depends_on_id=p.id JOIN tasks t ON t.id=d.task_id
                  JOIN unsat ON unsat.task_id=t.id
             WHERE p.status NOT IN ('done','cancelled','to-verify') AND t.status NOT IN ('done','cancelled')
             GROUP BY p.id ORDER BY runnable_count DESC,direct_count DESC,p.priority,p.id
             LIMIT ?1 OFFSET ?2"
        )?;
        let mut rows = statement.query(params![(size + 1) as i64, offset_sql])?;
        let mut items = Vec::new();
        while let Some(row) = rows.next()? {
            items.push(UnlockSummary {
                task: Self::selection_summary(row)?,
                direct_open_dependents: row.get(5)?,
                immediately_runnable: row.get(6)?,
            });
        }
        drop(rows);
        drop(statement);
        let has_more = items.len() > size;
        items.truncate(size);
        let ids = items.iter().map(|t| t.task.id).collect::<Vec<_>>();
        let mut deps = Self::task_dependencies_for_ids(&snapshot, &ids)?;
        let mut labels = crate::labels::read_many(&snapshot, &ids)?;
        for item in &mut items {
            item.task.deps = deps.remove(&item.task.id).unwrap_or_default();
            item.task.labels = labels.remove(&item.task.id).unwrap_or_default();
            item.task.display_id = self.display_id(item.task.id);
        }
        snapshot.commit()?;
        Ok(Pagination {
            items,
            has_more,
            next_after: if has_more {
                Some(offset + size as u64)
            } else {
                None
            },
        })
    }

    pub fn search_tasks(
        &mut self,
        needle: &str,
        after: Option<u64>,
        limit: usize,
    ) -> Result<Pagination<TaskSummary>, AppError> {
        self.search_tasks_with_label(needle, after, limit, None)
    }

    pub fn search_tasks_with_label(
        &mut self,
        needle: &str,
        after: Option<u64>,
        limit: usize,
        label: Option<&str>,
    ) -> Result<Pagination<TaskSummary>, AppError> {
        let label = crate::labels::filter(label)?;
        if needle.is_empty() {
            return Err(AppError::Validation(
                "tasks search: the search text is empty; pass a non-empty search argument"
                    .to_string(),
            ));
        }
        let page_size = validate_limit(limit)?;
        let snapshot = self.conn.unchecked_transaction()?;
        let fetch = page_size + 1;
        let mut rows = self.conn.prepare(
            "
            SELECT id, status, version, title, priority
            FROM tasks
             WHERE id > ?1 AND (?4 IS NULL OR EXISTS(SELECT 1 FROM task_labels l WHERE l.task_id=tasks.id AND l.label=?4)) AND (LOWER(title) LIKE ?2 ESCAPE '\\' OR LOWER(body) LIKE ?2 ESCAPE '\\')
            ORDER BY id ASC LIMIT ?3
            ",
        )?;
        let mut out = Vec::new();
        let pattern = format!("%{}%", escape_like_literal(&needle.to_ascii_lowercase()));
        let mut iter = rows.query(params![after.unwrap_or(0), pattern, fetch as i64, label])?;
        while let Some(row) = iter.next()? {
            let status_text: String = row.get(1)?;
            let task_status = TaskStatus::from_row(&status_text).ok_or_else(|| {
                rusqlite::Error::InvalidColumnType(
                    1,
                    "status".to_string(),
                    rusqlite::types::Type::Text,
                )
            })?;
            out.push(TaskSummary {
                id: row.get::<_, i64>(0)? as u64,
                display_id: String::new(),
                status: task_status,
                version: row.get::<_, i64>(2)? as u64,
                title: row.get::<_, String>(3)?,
                priority: row
                    .get::<_, String>(4)?
                    .parse()
                    .map_err(AppError::Validation)?,
                deps: Vec::new(),
                labels: Vec::new(),
            });
        }
        drop(iter);
        drop(rows);
        let mut has_more = false;
        let mut next_after = out.last().map(|t| t.id);
        if out.len() > page_size {
            has_more = true;
            out.pop();
            next_after = out.last().map(|t| t.id);
        }
        let ids = out.iter().map(|task| task.id).collect::<Vec<_>>();
        let mut dependencies = Self::task_dependencies_for_ids(&self.conn, &ids)?;
        let mut labels = crate::labels::read_many(&self.conn, &ids)?;
        for row in out.iter_mut() {
            row.deps = dependencies.remove(&row.id).unwrap_or_default();
            row.labels = labels.remove(&row.id).unwrap_or_default();
        }
        self.stamp(&mut out);
        snapshot.commit()?;
        Ok(Pagination {
            items: out,
            has_more,
            next_after,
        })
    }

    pub fn search_ranked(
        &mut self,
        text: &str,
        prefix: bool,
        label: Option<&str>,
        offset: u64,
        limit: usize,
    ) -> Result<Pagination<TaskSummary>, AppError> {
        let size = validate_limit(limit)?;
        let label = crate::labels::filter(label)?;
        let snapshot = self.conn.unchecked_transaction()?;
        let mut matches =
            crate::full_text::search(&self.conn, text, prefix, label.as_deref(), offset, size + 1)?;
        let has_more = matches.len() > size;
        matches.truncate(size);
        let mut items = Vec::new();
        let ids = matches.iter().map(|r| r.id).collect::<Vec<_>>();
        let mut deps = Self::task_dependencies_for_ids(&self.conn, &ids)?;
        let mut labels = crate::labels::read_many(&self.conn, &ids)?;
        for row in matches {
            items.push(TaskSummary {
                id: row.id,
                display_id: self.display_id(row.id),
                status: validate_status(&row.status)?,
                version: row.version,
                title: row.title,
                priority: row.priority.parse().map_err(AppError::Validation)?,
                deps: deps.remove(&row.id).unwrap_or_default(),
                labels: labels.remove(&row.id).unwrap_or_default(),
            });
        }
        snapshot.commit()?;
        Ok(Pagination {
            items,
            has_more,
            next_after: if has_more {
                Some(offset + size as u64)
            } else {
                None
            },
        })
    }

    fn task_dependencies_for_ids(
        conn: &Connection,
        task_ids: &[u64],
    ) -> Result<HashMap<u64, Vec<u64>>, AppError> {
        let mut dependencies = task_ids
            .iter()
            .copied()
            .map(|id| (id, Vec::new()))
            .collect::<HashMap<_, _>>();
        if task_ids.is_empty() {
            return Ok(dependencies);
        }
        let placeholders = std::iter::repeat_n("?", task_ids.len())
            .collect::<Vec<_>>()
            .join(",");
        let query = format!(
            "SELECT task_id, depends_on_id
             FROM dependencies
             WHERE task_id IN ({placeholders})
             ORDER BY task_id, depends_on_id"
        );
        let mut rows = conn.prepare(&query)?;
        let values = task_ids.iter().map(|id| *id as i64);
        let mut iter = rows.query(rusqlite::params_from_iter(values))?;
        while let Some(row) = iter.next()? {
            let task_id = row.get::<_, i64>(0)? as u64;
            let depends_on_id = row.get::<_, i64>(1)? as u64;
            dependencies.entry(task_id).or_default().push(depends_on_id);
        }
        Ok(dependencies)
    }

    fn task_dependencies_from(conn: &Connection, task_id: u64) -> Result<Vec<u64>, AppError> {
        let mut rows = conn.prepare(
            "SELECT depends_on_id
             FROM dependencies
             WHERE task_id = ?1
             ORDER BY depends_on_id ASC",
        )?;
        let mut out = Vec::new();
        let iter = rows.query_map([task_id], |row| row.get::<_, i64>(0))?;
        for dep in iter {
            out.push(dep? as u64);
        }
        Ok(out)
    }

    fn task_dependencies(&self, task_id: u64) -> Result<Vec<u64>, AppError> {
        Self::task_dependencies_from(&self.conn, task_id)
    }

    fn dependency_summaries(&self, task_id: u64) -> Result<Vec<DependencySummary>, AppError> {
        let mut statement = self.conn.prepare(
            "SELECT tasks.id, tasks.status, tasks.version, tasks.title
             FROM dependencies
             JOIN tasks ON tasks.id = dependencies.depends_on_id
             WHERE dependencies.task_id = ?1
             ORDER BY tasks.id ASC",
        )?;
        let rows = statement.query_map([task_id as i64], |row| {
            Ok((
                row.get::<_, i64>(0)? as u64,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)? as u64,
                row.get::<_, String>(3)?,
            ))
        })?;
        let mut summaries = Vec::new();
        for row in rows {
            let (id, status, version, title) = row?;
            summaries.push(DependencySummary {
                id,
                display_id: self.display_id(id),
                status: validate_status(&status)?,
                version,
                title,
            });
        }
        Ok(summaries)
    }

    /// Full library detail for one task, including dependency IDs and rules.
    pub fn show_task(&mut self, raw_id: &str) -> Result<TaskDetail, AppError> {
        let id = self.resolve_ref(raw_id)?;
        let snapshot = self.conn.unchecked_transaction()?;
        let task = self
            .read_show_task(id)?
            .ok_or_else(|| self.task_not_found(&[id]))?;
        let rule = self.project_rules()?;
        let detail = TaskDetail {
            priority: task.priority,
            labels: task.labels,
            id,
            display_id: task.display_id,
            status: task.status,
            version: task.version,
            title: task.title,
            body: task.body,
            deps: self.task_dependencies(id)?,
            dependency_summaries: task.dependency_summaries,
            rule_version: rule.version,
            rules: rule.body,
        };
        snapshot.commit()?;
        Ok(detail)
    }

    /// Reads up to [`MAX_SHOW_IDS`] tasks in request order, with the shared
    /// rules only when `include_rules` is set, from one read snapshot. Repeated
    /// IDs are shown once. Any missing ID fails the whole read.
    pub fn show_tasks(
        &mut self,
        raw_ids: &[String],
        include_rules: bool,
    ) -> Result<(Vec<ShowTask>, Option<RuleRecord>), AppError> {
        self.show_tasks_with_budget(raw_ids, include_rules, None)
    }

    pub fn show_tasks_with_budget(
        &mut self,
        raw_ids: &[String],
        include_rules: bool,
        max_source_bytes: Option<u64>,
    ) -> Result<(Vec<ShowTask>, Option<RuleRecord>), AppError> {
        if raw_ids.len() > MAX_SHOW_IDS {
            return Err(AppError::Validation(format!(
                "show received {} task IDs; the limit is {MAX_SHOW_IDS}. Split the request.",
                raw_ids.len()
            )));
        }
        let mut ids = Vec::with_capacity(raw_ids.len());
        for raw in raw_ids {
            let id = self.resolve_ref(raw)?;
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
        let snapshot = self.conn.unchecked_transaction()?;
        if let Some(max_bytes) = max_source_bytes {
            let mut bytes = if include_rules {
                self.conn.query_row(
                    "SELECT length(CAST(rules_markdown AS BLOB)) FROM project",
                    [],
                    |r| r.get::<_, u64>(0),
                )?
            } else {
                0
            };
            for &id in &ids {
                let task_bytes:u64=self.conn.query_row("SELECT coalesce((SELECT length(CAST(body AS BLOB))+length(CAST(title AS BLOB))+256 FROM tasks WHERE id=?1),0) + coalesce((SELECT sum(length(CAST(p.title AS BLOB))+128) FROM dependencies d JOIN tasks p ON p.id=d.depends_on_id WHERE d.task_id=?1),0) + coalesce((SELECT sum(length(CAST(label AS BLOB))+32) FROM task_labels WHERE task_id=?1),0)",[id],|r|r.get(0))?;
                bytes = bytes.saturating_add(task_bytes);
                if bytes > max_bytes {
                    return Err(AppError::ResponseLimit("show contains too much text for one response. Split the request into fewer task IDs; read shared rules separately if needed".into()));
                }
            }
        }
        let mut tasks = Vec::with_capacity(ids.len());
        let mut missing = Vec::new();
        for &id in &ids {
            match self.read_show_task(id)? {
                Some(task) => tasks.push(task),
                None => missing.push(id),
            }
        }
        if !missing.is_empty() {
            return Err(self.task_not_found(&missing));
        }
        let rules = if include_rules {
            Some(self.project_rules()?)
        } else {
            None
        };
        snapshot.commit()?;
        Ok((tasks, rules))
    }

    fn task_not_found(&self, ids: &[u64]) -> AppError {
        let rendered = ids
            .iter()
            .map(|id| self.display_id(*id))
            .collect::<Vec<_>>()
            .join(", ");
        let noun = if ids.len() == 1 { "task" } else { "tasks" };
        AppError::NotFound(format!(
            "{noun} {rendered} not found in project {}; run tasks list to see the IDs in this project",
            self.project_id
        ))
    }

    fn read_show_task(&self, id: u64) -> Result<Option<ShowTask>, AppError> {
        let row = self
            .conn
            .query_row(
                "SELECT status, version, title, body, priority FROM tasks WHERE id = ?1",
                [id],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                    ))
                },
            )
            .optional()?;
        let Some((status_text, version, title, body, priority)) = row else {
            return Ok(None);
        };
        Ok(Some(ShowTask {
            priority: priority.parse().map_err(AppError::Validation)?,
            id,
            display_id: self.display_id(id),
            status: validate_status(&status_text)?,
            version: version as u64,
            title,
            body,
            labels: crate::labels::read(&self.conn, id)?,
            dependency_summaries: self.dependency_summaries(id)?,
        }))
    }

    pub fn history(
        &mut self,
        task_id: u64,
        after: Option<u64>,
        limit: usize,
        event: Option<u64>,
    ) -> Result<(Pagination<HistoryEvent>, Option<HistoryEvent>), AppError> {
        let project_id = self.project_id;
        if let Some(event_id) = event {
            let sql = history_sql(
                "e.event_id = ?1 AND e.task_id = ?2 AND e.entity_type = 'task'",
                "1",
                true,
            );
            let row = self
                .conn
                .query_row(&sql, params![event_id, task_id as i64], |r| {
                    let mut event = history_event_from_row(r)?;
                    event.snapshot_json = r.get::<_, String>(HISTORY_SNAPSHOT_COLUMN).ok();
                    Ok(event)
                })
                .optional()?;
            let single = row.ok_or_else(|| {
                AppError::NotFound(format!(
                    "event {event_id} not found for task {} in project {project_id}; run tasks history --project {project_id} to list events",
                    render_keyed_task_id(self.project_key.as_deref(), task_id),
                ))
            })?;
            return Ok((
                Pagination {
                    items: Vec::new(),
                    has_more: false,
                    next_after: None,
                },
                Some(single),
            ));
        }
        let page_size = validate_limit(limit)?;
        let fetch = page_size + 1;
        let sql = history_sql("e.task_id = ?1 AND e.event_id > ?2", "?3", false);
        let mut rows = self.conn.prepare(&sql)?;
        let mut list = rows
            .query_map(
                params![task_id as i64, after.unwrap_or(0), fetch as i64],
                history_event_from_row,
            )?
            .collect::<Result<Vec<_>, _>>()?;
        let mut has_more = false;
        let next_after = if list.len() > page_size {
            has_more = true;
            list.pop();
            list.last().map(|r| r.event_id)
        } else {
            list.last().map(|r| r.event_id)
        };
        Ok((
            Pagination {
                items: list,
                has_more,
                next_after,
            },
            None,
        ))
    }

    pub fn rules_set(&mut self, body: &str, expect_version: u64) -> Result<u64, AppError> {
        let who = format!("rules set in project {}", self.project_id);
        validate_rules(&who, body)?;
        let tx = WriteTransaction::begin(&mut self.conn)?;
        let current_version: i64 = tx.query_row("SELECT rules_version FROM project", [], |r| {
            r.get::<_, i64>(0)
        })?;
        if current_version as u64 != expect_version {
            return Err(AppError::VersionConflict {
                expected: expect_version,
                current: current_version as u64,
            });
        }
        let current_body: String =
            tx.query_row("SELECT rules_markdown FROM project", [], |row| row.get(0))?;
        if current_body == body {
            return Ok(current_version as u64);
        }
        tx.execute(
            "UPDATE project SET rules_markdown=?1, rules_version=rules_version+1 WHERE project_id=?2",
            params![body, self.project_id.to_string()],
        )?;
        let new_version: i64 = tx.query_row(
            "SELECT rules_version FROM project WHERE project_id=?1",
            [self.project_id.to_string()],
            |r| r.get::<_, i64>(0),
        )?;
        let snapshot = json!({
            "rules_version": new_version,
            "rules": body,
        });
        tx.execute(
            "INSERT INTO events(task_id,entity_type,operation,resulting_version,created_ms,snapshot_json,attribution_json)
             VALUES(NULL,'rules','set',?1,?2,?3,?4)",
            params![new_version, sqlite_now_ms(), snapshot.to_string(), self.attribution_json],
        )?;
        maybe_precommit_fail("rules")?;
        tx.commit()?;
        Ok(new_version as u64)
    }

    pub fn rules_show(&mut self) -> Result<RuleRecord, AppError> {
        self.project_rules()
    }

    fn ensure_task_ids_unique_in_source(
        source_name: &str,
        items: &[ParsedTask],
    ) -> Result<(), AppError> {
        let mut seen = HashSet::new();
        for t in items {
            if !seen.insert(t.id) {
                return Err(AppError::Validation(format!(
                    "{source_name}: task ID T-{:03} appears more than once; every task ID must be unique within a file",
                    t.id
                )));
            }
        }
        Ok(())
    }

    fn validate_task_dependencies_exist(
        conn: &Connection,
        task_id: u64,
        deps: &[u64],
        known: &HashSet<u64>,
        key: Option<&str>,
    ) -> Result<(), AppError> {
        let rid = |id: u64| render_keyed_task_id(key, id);
        for dep in deps {
            if known.contains(dep) {
                continue;
            }
            let exists: Option<i64> = conn
                .query_row("SELECT id FROM tasks WHERE id = ?1", [*dep as i64], |row| {
                    row.get::<_, i64>(0)
                })
                .optional()?;
            if exists.is_none() {
                return Err(AppError::Validation(format!(
                    "{} depends on {}, which is in neither the import sources nor this project; add that task to the file set or remove {} from Deps",
                    rid(task_id),
                    rid(*dep),
                    rid(*dep)
                )));
            }
        }
        Ok(())
    }

    fn validate_dependency_cycle(
        conn: &Connection,
        task_id: u64,
        deps: &[u64],
        key: Option<&str>,
    ) -> Result<(), AppError> {
        let rid = |id: u64| render_keyed_task_id(key, id);
        for dep in deps {
            if *dep == task_id {
                return Err(AppError::Validation(format!(
                    "{} lists itself as a dependency; remove {} from its Deps",
                    rid(task_id),
                    rid(task_id)
                )));
            }
            let query = "
                WITH RECURSIVE chain(x) AS (
                    SELECT ?1 AS x
                    UNION
                    SELECT depends_on_id
                    FROM dependencies
                    JOIN chain ON dependencies.task_id = chain.x
                )
                SELECT 1 FROM chain WHERE x = ?2 LIMIT 1
            ";
            let mut stmt = conn.prepare(query)?;
            let found: Option<i64> = stmt
                .query_row(params![*dep as i64, task_id as i64], |r| r.get::<_, i64>(0))
                .optional()?;
            if found.is_some() {
                return Err(AppError::Validation(format!(
                    "{} cannot depend on {}: {} already depends on it directly or indirectly, so this edge would create a cycle; remove one of the edges",
                    rid(task_id),
                    rid(*dep),
                    rid(*dep)
                )));
            }
        }
        Ok(())
    }

    fn replace_dependencies(tx: &Connection, task_id: u64, deps: &[u64]) -> Result<(), AppError> {
        tx.execute(
            "DELETE FROM dependencies WHERE task_id = ?1",
            [task_id as i64],
        )?;
        for dep in deps {
            tx.execute(
                "INSERT INTO dependencies(task_id, depends_on_id) VALUES (?1, ?2)",
                [task_id as i64, *dep as i64],
            )?;
        }
        Ok(())
    }

    pub fn create_task(
        &mut self,
        title: &str,
        body: &str,
        status: TaskStatus,
        deps: Vec<u64>,
    ) -> Result<(u64, u64, Option<u64>), AppError> {
        self.create_task_with_labels(title, body, status, deps, vec![])
    }
    pub fn create_task_with_labels(
        &mut self,
        title: &str,
        body: &str,
        status: TaskStatus,
        deps: Vec<u64>,
        labels: Vec<String>,
    ) -> Result<(u64, u64, Option<u64>), AppError> {
        self.create_task_with_priority_labels(
            title,
            body,
            status,
            deps,
            labels,
            Priority::default(),
        )
    }

    pub fn create_task_with_priority_labels(
        &mut self,
        title: &str,
        body: &str,
        status: TaskStatus,
        deps: Vec<u64>,
        labels: Vec<String>,
        priority: Priority,
    ) -> Result<(u64, u64, Option<u64>), AppError> {
        let labels = crate::labels::normalize(labels)?;
        let key = self.project_key.clone();
        let who = format!("create in project {}", self.project_id);
        validate_title_body(&who, title, body)?;
        let deps = normalize_dependencies(deps);
        if deps.len() > MAX_DEPENDENCIES {
            return Err(AppError::Validation(format!(
                "create: task '{title}' has {} dependencies; the limit is {MAX_DEPENDENCIES}. Reduce the list or split the task.",
                deps.len()
            )));
        }
        let unique_count = deps.len();
        let dep_set = deps.iter().collect::<HashSet<_>>();
        if dep_set.len() != unique_count {
            let mut seen = HashSet::new();
            let duplicate = deps
                .iter()
                .copied()
                .find(|dependency| !seen.insert(*dependency))
                .unwrap_or(deps[0]);
            return Err(AppError::Validation(format!(
                "create: task '{title}' lists dependency {} more than once; remove the duplicate entry.",
                render_keyed_task_id(key.as_deref(), duplicate)
            )));
        }
        let now = sqlite_now_ms();
        let tx = WriteTransaction::begin(&mut self.conn)?;
        tx.execute(
            "INSERT INTO tasks(id,title,body,status,version,created_ms,updated_ms,priority)
             VALUES(
                (SELECT next_task_number FROM project),
                ?1, ?2, ?3, 1, ?4, ?4, ?5
             )",
            params![title, body, status.to_string(), now, priority.to_string()],
        )?;
        let id: u64 = tx.query_row("SELECT id FROM tasks ORDER BY id DESC LIMIT 1", [], |r| {
            r.get::<_, i64>(0)
        })? as u64;
        tx.execute(
            "UPDATE project SET next_task_number = next_task_number + 1 WHERE project_id = ?1",
            [self.project_id.to_string()],
        )?;
        Self::validate_task_dependencies_exist(&tx, id, &deps, &HashSet::new(), key.as_deref())?;
        Self::validate_dependency_cycle(&tx, id, &deps, key.as_deref())?;
        Self::replace_dependencies(&tx, id, &deps)?;
        crate::labels::replace(&tx, id, &labels)?;
        let snapshot = json!({
            "id": id,
            "title": title,
            "body": body,
            "status": status.to_string(),
            "version": 1,
            "deps": deps,
            "labels": labels,
            "priority": priority,
        });
        tx.execute(
            "INSERT INTO events(task_id,entity_type,operation,resulting_version,created_ms,snapshot_json,attribution_json)
             VALUES (?1,'task','create',1,?2,?3,?4)",
            params![id as i64, now, snapshot.to_string(), self.attribution_json],
        )?;
        let event_id: i64 = tx.query_row(
            "SELECT event_id FROM events WHERE task_id=?1 AND operation='create' ORDER BY event_id DESC LIMIT 1",
            [id as i64],
            |r| r.get::<_, i64>(0),
        )?;
        maybe_precommit_fail("create")?;
        tx.commit()?;
        Ok((id, 1, Some(event_id as u64)))
    }

    pub fn update_task(
        &mut self,
        id: u64,
        expect_version: u64,
        changes: TaskUpdate,
    ) -> Result<(u64, TaskStatus, u64, Option<u64>), AppError> {
        let project_id = self.project_id;
        let key = self.project_key.clone();
        let rid = |id: u64| render_keyed_task_id(key.as_deref(), id);
        if changes.title.is_none()
            && changes.body.is_none()
            && changes.status.is_none()
            && changes.priority.is_none()
            && changes.deps.is_none()
            && !changes.clear_deps
            && changes.labels.is_none()
            && changes.add_labels.is_empty()
            && changes.remove_labels.is_empty()
        {
            return Err(AppError::Usage(format!(
                "update {}: no changes requested; pass at least one of --title, --body-file, --status, --deps, --clear-deps, --labels, --clear-labels, --add-label, --remove-label or --priority (project {project_id})",
                rid(id)
            )));
        }
        if changes.labels.is_some()
            && !(changes.add_labels.is_empty() && changes.remove_labels.is_empty())
        {
            return Err(AppError::Usage(format!(
                "update {}: --labels/--clear-labels replace the whole set and cannot be combined with --add-label or --remove-label; pass one style (project {project_id})",
                rid(id)
            )));
        }
        if changes.deps.is_some() && changes.clear_deps {
            return Err(AppError::Usage(format!(
                "update {}: --deps and --clear-deps cannot be combined; pass one of them (project {project_id})",
                rid(id)
            )));
        }
        let requested_deps = changes.deps.clone().map(normalize_dependencies);
        if let Some(deps) = requested_deps.as_ref() {
            if deps.len() > MAX_DEPENDENCIES {
                return Err(AppError::Validation(format!(
                    "update {}: the dependency list has {} entries; the limit is {MAX_DEPENDENCIES}. Reduce the list or split the task.",
                    rid(id),
                    deps.len()
                )));
            }
            let unique = deps.iter().collect::<HashSet<_>>();
            if unique.len() != deps.len() {
                let mut seen = HashSet::new();
                let duplicate = deps
                    .iter()
                    .find(|dependency| !seen.insert(*dependency))
                    .copied()
                    .unwrap_or(deps[0]);
                return Err(AppError::Validation(format!(
                    "update {}: dependency {} is listed more than once; remove the duplicate entry.",
                    rid(id),
                    rid(duplicate)
                )));
            }
            for dep in deps {
                if *dep == id {
                    return Err(AppError::Validation(format!(
                        "update {}: the task lists itself as a dependency; remove {} from the list.",
                        rid(id),
                        rid(id)
                    )));
                }
            }
        }

        let tx = WriteTransaction::begin(&mut self.conn)?;
        let current = tx
            .query_row(
                "SELECT title, body, status, version FROM tasks WHERE id = ?1",
                [id as i64],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, i64>(3)?,
                    ))
                },
            )
            .optional()?;
        let current = current.ok_or_else(|| {
            AppError::NotFound(format!(
                "task {} not found in project {project_id}; run tasks list to see the IDs in this project",
                rid(id)
            ))
        })?;
        let (cur_title, cur_body, cur_status, cur_version) = current;
        if cur_version as u64 != expect_version {
            return Err(AppError::VersionConflict {
                expected: expect_version,
                current: cur_version as u64,
            });
        }
        let next_title = changes.title.as_deref().unwrap_or(&cur_title).to_string();
        let next_body = changes.body.as_deref().unwrap_or(&cur_body).to_string();
        let next_status = changes
            .status
            .as_ref()
            .map(ToString::to_string)
            .unwrap_or(cur_status.clone());
        let next_status_value = validate_status(&next_status)?;
        let who = format!("update {} in project {}", rid(id), self.project_id);
        validate_title_body(&who, &next_title, &next_body)?;

        let cur_priority: String =
            tx.query_row("SELECT priority FROM tasks WHERE id=?1", [id], |r| r.get(0))?;
        let next_priority = changes
            .priority
            .map(|p| p.to_string())
            .unwrap_or_else(|| cur_priority.clone());
        let current_labels = crate::labels::read(&tx, id)?;
        let next_labels = match changes.labels {
            Some(replacement) => crate::labels::normalize(replacement)?,
            None if changes.add_labels.is_empty() && changes.remove_labels.is_empty() => {
                current_labels.clone()
            }
            None => {
                let removed = crate::labels::normalize(changes.remove_labels)?;
                let mut merged = current_labels
                    .iter()
                    .filter(|label| !removed.contains(label))
                    .cloned()
                    .collect::<Vec<_>>();
                merged.extend(changes.add_labels);
                crate::labels::normalize(merged)?
            }
        };
        let current_deps = Self::task_dependencies_from(&tx, id)?;
        let no_change = next_priority == cur_priority
            && next_labels == current_labels
            && next_title == cur_title
            && next_body == cur_body
            && next_status == cur_status
            && match (&requested_deps, changes.clear_deps) {
                (Some(d), false) => d == &current_deps,
                (None, false) => true,
                (_, true) => current_deps.is_empty(),
            };
        if no_change {
            return Ok((id, next_status_value, cur_version as u64, None));
        }
        if let Some(replacement) = requested_deps.as_deref() {
            Self::validate_task_dependencies_exist(
                &tx,
                id,
                replacement,
                &HashSet::new(),
                key.as_deref(),
            )?;
            Self::validate_dependency_cycle(&tx, id, replacement, key.as_deref())?;
        }
        if next_status_value == TaskStatus::Done && cur_status != "done" {
            let resulting_deps = match (&requested_deps, changes.clear_deps) {
                (Some(deps), _) => deps.as_slice(),
                (None, true) => &[],
                (None, false) => current_deps.as_slice(),
            };
            Self::refuse_done_with_open_prerequisites(
                &tx,
                id,
                resulting_deps,
                &project_id,
                key.as_deref(),
            )?;
        }
        tx.execute(
            "UPDATE tasks
             SET title = ?1, body = ?2, status = ?3, version = version + 1, updated_ms = ?4, priority = ?7
             WHERE id = ?5 AND version = ?6",
            params![
                next_title,
                next_body,
                next_status,
                sqlite_now_ms(),
                id as i64,
                expect_version as i64,
                next_priority
            ],
        )?;
        if tx.changes() != 1 {
            return Err(AppError::VersionConflict {
                expected: expect_version,
                current: cur_version as u64,
            });
        }
        if let Some(replacement) = requested_deps {
            Self::replace_dependencies(&tx, id, &replacement)?;
        } else if changes.clear_deps {
            Self::replace_dependencies(&tx, id, &[])?;
        }
        crate::labels::replace(&tx, id, &next_labels)?;
        let new_version: i64 = tx.query_row(
            "SELECT version FROM tasks WHERE id = ?1",
            [id as i64],
            |r| r.get::<_, i64>(0),
        )?;
        let snapshot = json!({
            "id": id,
            "title": next_title,
            "body": next_body,
            "status": next_status,
            "version": new_version,
            "deps": Self::task_dependencies_from(&tx, id)?,
            "labels": next_labels,
            "priority": next_priority,
        });
        tx.execute(
            "INSERT INTO events(task_id,entity_type,operation,resulting_version,created_ms,snapshot_json,attribution_json)
             VALUES (?1,'task','update',?2,?3,?4,?5)",
            params![id as i64, new_version, sqlite_now_ms(), snapshot.to_string(), self.attribution_json],
        )?;
        let event_id: i64 = tx.query_row(
            "SELECT event_id FROM events WHERE task_id=?1 AND operation='update' ORDER BY event_id DESC LIMIT 1",
            [id as i64],
            |r| r.get::<_, i64>(0),
        )?;
        maybe_precommit_fail("update")?;
        tx.commit()?;
        Ok((
            id,
            next_status_value,
            new_version as u64,
            Some(event_id as u64),
        ))
    }

    /// Completion guard: a task moves to done only when every prerequisite is
    /// done or cancelled. `deps` is the dependency set the update would commit.
    fn refuse_done_with_open_prerequisites(
        tx: &Connection,
        id: u64,
        deps: &[u64],
        project_id: &Uuid,
        key: Option<&str>,
    ) -> Result<(), AppError> {
        let rid = |id: u64| render_keyed_task_id(key, id);
        let mut statement = tx.prepare_cached("SELECT status FROM tasks WHERE id=?1")?;
        let mut open = Vec::new();
        for dep in deps {
            let status: String = statement.query_row([*dep as i64], |r| r.get(0))?;
            if status != "done" && status != "cancelled" {
                open.push((*dep, status));
            }
        }
        if open.is_empty() {
            return Ok(());
        }
        let listed = open
            .iter()
            .map(|(dep, status)| format!("{} ({status})", rid(*dep)))
            .collect::<Vec<_>>()
            .join(", ");
        Err(AppError::OpenPrerequisites {
            task: id,
            message: format!(
                "update {}: cannot mark done while prerequisites are not done or cancelled: {listed}; complete or cancel them first, in dependency order (project {project_id})",
                rid(id)
            ),
            prerequisites: open,
            key: key.map(str::to_owned),
        })
    }

    pub(crate) fn import_report(parsed: &ParsedImport) -> ImportReport {
        ImportReport {
            source_sha256: parsed.source_hash.clone(),
            has_bom: parsed.has_bom,
            task_count: parsed.tasks.len(),
            tasks: parsed.task_previews.clone(),
            sections: parsed.sections.clone(),
            rules: parsed.rules.clone(),
            duplicate_ids: parsed.duplicate_ids.clone(),
            unmapped_sections: parsed.unmapped_sections.clone(),
            ambiguous_sections: parsed.ambiguous_sections.clone(),
            unassigned_ranges: parsed.unassigned_ranges.clone(),
            has_unknown_content: parsed.has_unknown_content,
            warnings: parsed.warnings(),
        }
    }

    pub fn import_preview(&mut self, parsed: ParsedImport) -> ImportReport {
        Self::import_report(&parsed)
    }

    pub fn import_preview_many(&mut self, parsed: Vec<ParsedImport>) -> Vec<ImportReport> {
        parsed.iter().map(Self::import_report).collect()
    }

    pub fn import_apply(
        &mut self,
        parsed: ParsedImport,
        expect_sha256: Option<&str>,
    ) -> Result<(ImportReport, bool), AppError> {
        let expected = expect_sha256.ok_or_else(|| {
            AppError::Usage(
                "import apply: --expect-sha256 is required with --apply; run without --apply to preview, or pass the sha256 printed by the preview"
                    .to_string(),
            )
        })?;
        let (mut reports, already) =
            self.import_apply_many(vec![parsed], &[expected.to_string()])?;
        Ok((reports.remove(0), already))
    }

    /// Store-state checks import apply performs before its transaction. Import
    /// preview calls the same function, so a preview reporting no problem
    /// cannot fail apply because of the store contents.
    pub fn import_state_problems(
        &self,
        sources: &[(String, String)],
    ) -> Result<(Vec<ImportProblem>, bool), AppError> {
        let mut problems = Vec::new();
        let mut already_imported = Vec::new();
        for (name, hash) in sources {
            let existing: i64 = self.conn.query_row(
                "SELECT COUNT(*) FROM imports WHERE input_sha256 = ?1",
                [hash.clone()],
                |r| r.get::<_, i64>(0),
            )?;
            if existing > 0 {
                already_imported.push(name.clone());
            }
        }
        if !sources.is_empty() && already_imported.len() == sources.len() {
            return Ok((problems, true));
        }
        if !already_imported.is_empty() {
            problems.push(ImportProblem::other(format!(
                "import apply: these sources were already imported in an earlier run: {}; importing them again would duplicate tasks. Pass only sources that were not imported yet, or import into a fresh project.",
                already_imported.join(", ")
            )));
        }
        let task_rows: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM tasks", [], |r| r.get(0))?;
        if task_rows > 0 {
            problems.push(ImportProblem::other(import_empty_store_message(
                &self.project_id,
                task_rows,
            )));
        }
        let existing_rules = self.conn.query_row(
            "SELECT COUNT(*) FROM project WHERE TRIM(rules_markdown) != '' OR rules_version > 1",
            [],
            |r| r.get::<_, i64>(0),
        )?;
        if existing_rules > 0 {
            problems.push(ImportProblem::other(import_non_empty_rules_message(
                &self.project_id,
            )));
        }
        Ok((problems, false))
    }

    pub fn import_apply_many(
        &mut self,
        parsed: Vec<ParsedImport>,
        expect_sha256: &[String],
    ) -> Result<(Vec<ImportReport>, bool), AppError> {
        if parsed.is_empty() || parsed.len() != expect_sha256.len() {
            return Err(AppError::Usage(format!(
                "import apply: {} --file source(s) but {} --expect-sha256 value(s); pass one --expect-sha256 per --file, in the same order",
                parsed.len(),
                expect_sha256.len()
            )));
        }
        let mut reports = Vec::with_capacity(parsed.len());
        let mut hashes = Vec::with_capacity(parsed.len());
        for (index, item) in parsed.iter().enumerate() {
            let actual = item.source_hash.clone();
            let expected = &expect_sha256[index];
            if !expected.eq_ignore_ascii_case(&actual) {
                return Err(AppError::ShaMismatch {
                    file: item.source_name.clone(),
                    expected: expected.clone(),
                    actual,
                });
            }
            reports.push(Self::import_report(item));
            hashes.push(item.source_hash.clone());
        }
        let refs: Vec<&ParsedImport> = parsed.iter().collect();
        let mut problems = crate::problems::analyze(&refs);
        let sources = parsed
            .iter()
            .map(|item| (item.source_name.clone(), item.source_hash.clone()))
            .collect::<Vec<_>>();
        let (state_problems, all_already_imported) = self.import_state_problems(&sources)?;
        problems.extend(state_problems);
        if !problems.is_empty() {
            let counts = crate::model::ProblemCounts::of(&problems);
            let details = problems
                .iter()
                .map(|problem| format!("- {}", problem.message))
                .collect::<Vec<_>>()
                .join("\n");
            return Err(AppError::Validation(format!(
                "import blocked by {}:\n{details}",
                counts.line()
            )));
        }
        if all_already_imported {
            return Ok((reports, true));
        }
        let combined_rules = crate::problems::combined_rules(&refs);
        validate_rules(
            &format!("import into project {}", self.project_id),
            &combined_rules,
        )?;
        let mut seen_ids: HashMap<u64, &str> = HashMap::new();
        for item in &parsed {
            for task in &item.tasks {
                if let Some(previous) = seen_ids.insert(task.id, &item.source_name) {
                    return Err(AppError::Validation(format!(
                        "duplicate task ID T-{:03}: {} and {} both define it; task IDs must be unique across the whole file set",
                        task.id, previous, item.source_name
                    )));
                }
            }
        }
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let task_rows: i64 = tx.query_row("SELECT COUNT(*) FROM tasks", [], |r| r.get(0))?;
        if task_rows > 0 {
            return Err(AppError::Usage(import_empty_store_message(
                &self.project_id,
                task_rows,
            )));
        }
        let existing_rules = tx.query_row(
            "SELECT COUNT(*) FROM project WHERE TRIM(rules_markdown) != '' OR rules_version > 1",
            [],
            |r| r.get::<_, i64>(0),
        )?;
        if existing_rules > 0 {
            return Err(AppError::Usage(import_non_empty_rules_message(
                &self.project_id,
            )));
        }
        for item in &parsed {
            Self::ensure_task_ids_unique_in_source(&item.source_name, &item.tasks)?;
        }
        let known = parsed
            .iter()
            .flat_map(|item| item.tasks.iter())
            .map(|task| task.id)
            .collect::<HashSet<_>>();
        let mut max_id = 0u64;
        for item in &parsed {
            for task in &item.tasks {
                if task.id > max_id {
                    max_id = task.id;
                }
                let who = format!(
                    "import {}:{} task T-{:03} in project {}",
                    item.source_name, task.heading_line, task.id, self.project_id
                );
                validate_title_body(&who, &task.title, &task.body)?;
                tx.execute(
                    "INSERT INTO tasks(id,title,body,status,version,created_ms,updated_ms,priority)
                     VALUES (?1,?2,?3,?4,1,?5,?5,?6)",
                    params![
                        task.id,
                        task.title,
                        task.body,
                        task.status.to_string(),
                        sqlite_now_ms(),
                        task.priority.to_string()
                    ],
                )?;
            }
        }
        for item in &parsed {
            for task in &item.tasks {
                Self::validate_task_dependencies_exist(
                    &tx,
                    task.id,
                    &task.deps,
                    &known,
                    self.project_key.as_deref(),
                )?;
                Self::validate_dependency_cycle(
                    &tx,
                    task.id,
                    &task.deps,
                    self.project_key.as_deref(),
                )?;
                Self::replace_dependencies(&tx, task.id, &task.deps)?;
                crate::labels::replace(
                    &tx,
                    task.id,
                    &crate::labels::normalize(task.labels.clone())?,
                )?;
            }
        }
        for item in &parsed {
            for task in &item.tasks {
                tx.execute(
                    "INSERT INTO events(task_id,entity_type,operation,resulting_version,created_ms,snapshot_json,attribution_json)
                     VALUES (?1,'task','create',1,?2,?3,?4)",
                    params![
                        task.id as i64,
                        sqlite_now_ms(),
                        json!({
                            "id": task.id,
                            "title": task.title,
                            "body": task.body,
                            "status": task.status.to_string(),
                            "version": 1,
                            "labels": task.labels,
                            "priority": task.priority,
                            "deps": task.deps
                        })
                        .to_string(), self.attribution_json
                    ],
                )?;
            }
        }
        if max_id > 0 {
            tx.execute(
                "UPDATE project SET next_task_number = ?1 WHERE project_id = ?2",
                params![max_id + 1, self.project_id.to_string()],
            )?;
        }
        for (index, item) in parsed.iter().enumerate() {
            tx.execute(
                "INSERT INTO imports(input_sha256, source_name, original_source, report_json, imported_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    hashes[index],
                    item.source_name,
                    item.source,
                    serde_json::to_string(&reports[index])?,
                    sqlite_now_ms()
                ],
            )?;
            tx.execute(
                "INSERT INTO metadata_events(operation,created_ms,snapshot_json,attribution_json) VALUES ('import',?1,?2,?3)",
                params![sqlite_now_ms(), json!({"input_sha256": hashes[index], "source_name": item.source_name}).to_string(), self.attribution_json],
            )?;
        }
        if !combined_rules.is_empty() {
            tx.execute(
                "UPDATE project SET rules_markdown = ?1, rules_version = 1 WHERE project_id = ?2",
                params![combined_rules, self.project_id.to_string()],
            )?;
            tx.execute(
                "INSERT INTO events(task_id,entity_type,operation,resulting_version,created_ms,snapshot_json,attribution_json)
                 VALUES (NULL,'rules','update',1,?1,?2,?3)",
                params![sqlite_now_ms(), json!({"rules": combined_rules}).to_string(), self.attribution_json],
            )?;
        }
        maybe_precommit_fail("import")?;
        tx.commit()?;
        Ok((reports, false))
    }

    pub fn backup(&mut self, out: &Path) -> Result<u64, AppError> {
        publish_backup(
            &self.conn,
            out,
            Some(&self.project_id),
            Some(CURRENT_SCHEMA_VERSION),
        )
    }

    pub fn export_markdown(&mut self, out: &Path) -> Result<usize, AppError> {
        if out.exists() {
            return Err(AppError::Usage(format!(
                "refusing to overwrite {}: it already exists; choose a different --out path or move the existing file",
                out.display()
            )));
        }
        let (out_text, count) = self.markdown_snapshot()?;
        publish_export(out, out_text.as_bytes())?;
        Ok(count)
    }

    /// Generate the existing export from one read snapshot, without a server
    /// path supplied by a client or a temporary output file.
    pub fn markdown_snapshot(&mut self) -> Result<(String, usize), AppError> {
        let mut bytes = Vec::new();
        let count = self.write_markdown(&mut bytes)?;
        let text = String::from_utf8(bytes)
            .map_err(|_| AppError::Database("export is not valid UTF-8".into()))?;
        Ok((text, count))
    }

    /// Emit the existing complete Markdown format from one read snapshot. Each
    /// task body is loaded and released individually; the caller owns buffering.
    pub fn write_markdown(&mut self, out: &mut impl std::io::Write) -> Result<usize, AppError> {
        let snapshot = self.conn.unchecked_transaction()?;
        let rules = self.project_rules()?;
        out.write_all(b"# Task Backlog\n\n> Snapshot export; the SQLite database is the recovery authority.\n\nTask schema: 1\n\n")?;
        write!(out, "Project: {}\n\n## Rules\n\n", self.project_id)?;
        write_canonical_frame(out, "rules", &rules.body)?;
        out.write_all(b"\n\n")?;
        let mut count = 0;
        for status in [
            "draft",
            "todo",
            "in-progress",
            "to-verify",
            "blocked",
            "done",
            "cancelled",
        ] {
            let mut statement = self.conn.prepare(
                "SELECT id,title,body,version,priority FROM tasks WHERE status=?1 ORDER BY id",
            )?;
            let mut rows = statement.query([status])?;
            let mut heading = false;
            while let Some(row) = rows.next()? {
                if !heading {
                    write!(out, "## {status}\n\n")?;
                    heading = true;
                }
                let id: u64 = row.get(0)?;
                let title: String = row.get(1)?;
                let body: String = row.get(2)?;
                let version: u64 = row.get(3)?;
                let priority: String = row.get(4)?;
                let deps = Self::task_dependencies_from(&self.conn, id)?;
                let labels = crate::labels::read(&self.conn, id)?;
                write!(
                    out,
                    "### {} {title}\nStatus: {status}\nVersion: {version}\nDepends on: {}\n",
                    self.display_id(id),
                    deps.iter()
                        .map(|dep| self.display_id(*dep))
                        .collect::<Vec<_>>()
                        .join(", ")
                )?;
                if !labels.is_empty() {
                    writeln!(out, "Labels: {}", labels.join(", "))?;
                }
                write!(out, "Priority: {priority}\nBody:\n")?;
                write_canonical_frame(out, "body", &body)?;
                out.write_all(b"\n")?;
                count += 1;
            }
        }
        snapshot.commit()?;
        Ok(count)
    }

    fn migration_backup_path(&self, version: i32) -> PathBuf {
        let stem = self
            .db_path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("TASKS");
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        loop {
            let sequence = BACKUP_COUNTER.fetch_add(1, Ordering::Relaxed);
            let name = format!(
                "{stem}.v{version}-pre-migrate-{timestamp}-{}-{sequence}.sqlite",
                std::process::id()
            );
            let path = self.db_path.with_file_name(name);
            if !path.exists() {
                return path;
            }
        }
    }

    pub fn migrate(&mut self) -> Result<(i32, i32, Option<PathBuf>), AppError> {
        let _lock = match self.migration_lock.take() {
            Some(lock) => lock,
            None => acquire_exclusive_lock(&self.db_path.with_extension("migrate.lock"))?,
        };
        let current = schema_version(&self.conn)?;
        if current > CURRENT_SCHEMA_VERSION {
            return Err(AppError::Database(format!(
                "{} has schema version {current}, newer than this build supports ({CURRENT_SCHEMA_VERSION}); upgrade tasks-cli to a build that supports it",
                self.db_path.display()
            )));
        }
        if current == CURRENT_SCHEMA_VERSION {
            validate_current_schema(&self.conn, &self.project_id, &self.db_path)?;
            return Ok((current, current, None));
        }
        let pre_upgrade = self.migration_backup_path(current);
        let backup_project = if table_exists(&self.conn, "project")? {
            Some(&self.project_id)
        } else {
            None
        };
        publish_backup(&self.conn, &pre_upgrade, backup_project, Some(current))?;
        configure_writer(&self.conn)?;
        self.conn.pragma_update(None, "foreign_keys", "OFF")?;
        let migration_result = (|| -> Result<(), AppError> {
            let tx = self
                .conn
                .transaction_with_behavior(TransactionBehavior::Immediate)?;
            let locked_version = schema_version(&tx)?;
            if locked_version != current {
                return Err(AppError::Database(format!(
                    "{} changed schema from version {current} to {locked_version} while migration was preparing; retry the migration",
                    self.db_path.display()
                )));
            }
            if current == 0 {
                migrate_v0_to_v1(&tx, &self.project_id, &self.db_path)?;
            }
            if current < 2 {
                migrate_v1_to_v2(&tx)?;
            }
            if current < 3 {
                crate::labels::create_schema(&tx)?;
            }
            if current < 4 {
                create_selection_schema(&tx)?;
            }
            if current < 5 {
                migrate_v4_to_v5(&tx)?;
            }
            if current < 6 {
                migrate_v5_to_v6(&tx)?;
            }
            if current < 7 {
                create_attribution_schema(&tx)?;
            }
            if current < 8 {
                create_receipt_schema(&tx)?;
            }
            tx.pragma_update(None, "user_version", CURRENT_SCHEMA_VERSION)?;
            validate_current_schema(&tx, &self.project_id, &self.db_path)?;
            let mut foreign_rows = tx.prepare("PRAGMA foreign_key_check")?;
            if foreign_rows.query([])?.next()?.is_some() {
                return Err(AppError::Database(
                    "migration contains foreign-key violations; restore the database from a backup"
                        .to_string(),
                ));
            }
            drop(foreign_rows);
            tx.commit()?;
            Ok(())
        })();
        // Restore enforcement after either COMMIT or the transaction's rollback.
        let restore_result = self.conn.pragma_update(None, "foreign_keys", "ON");
        migration_result.map_err(|error| {
            error.context(&format!("cannot migrate {}", self.db_path.display()))
        })?;
        restore_result?;
        Ok((current, CURRENT_SCHEMA_VERSION, Some(pre_upgrade)))
    }

    pub fn doctor(&mut self) -> Result<(String, String, i32, String), AppError> {
        let quick_check: String = self
            .conn
            .query_row("PRAGMA quick_check", [], |r| r.get(0))?;
        if quick_check != "ok" {
            return Err(AppError::Database(format!(
                "{} failed PRAGMA quick_check: {quick_check}; the database is corrupt. Restore it from a backup",
                self.db_path.display()
            )));
        }
        let mut foreign_rows = self.conn.prepare("PRAGMA foreign_key_check")?;
        if foreign_rows.query([])?.next()?.is_some() {
            return Err(AppError::Database(format!(
                "{} failed PRAGMA foreign_key_check: it contains foreign-key violations. Restore it from a backup",
                self.db_path.display()
            )));
        }
        let project_id = if table_exists(&self.conn, "project")? {
            let stored: Option<String> = self
                .conn
                .query_row("SELECT project_id FROM project LIMIT 1", [], |r| {
                    r.get::<_, String>(0)
                })
                .optional()?;
            if let Some(stored) = stored {
                let actual = Uuid::parse_str(&stored).map_err(|error| {
                    AppError::Database(format!(
                        "{} has an invalid project id '{stored}': {error}; restore the database from a backup",
                        self.db_path.display()
                    ))
                })?;
                if actual != self.project_id {
                    return Err(AppError::Usage(format!(
                        "{} belongs to project {actual}, not {}; pass --project {actual}",
                        self.db_path.display(),
                        self.project_id
                    )));
                }
                stored
            } else {
                self.project_id.to_string()
            }
        } else {
            self.project_id.to_string()
        };
        let schema: i64 = self
            .conn
            .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .unwrap_or(0);
        let sqlite_version: String = self
            .conn
            .query_row("SELECT sqlite_version()", [], |r| r.get::<_, String>(0))?;
        Ok((
            self.db_path.to_string_lossy().to_string(),
            project_id,
            schema as i32,
            sqlite_version,
        ))
    }
}

fn write_canonical_frame(
    out: &mut impl std::io::Write,
    kind: &str,
    content: &str,
) -> Result<(), AppError> {
    let digest = crate::markdown::sha256(content.as_bytes());
    writeln!(
        out,
        "<!-- tasks-cli:canonical-v1:{kind} bytes={} sha256={digest} -->",
        content.len()
    )?;
    out.write_all(content.as_bytes())?;
    if !content.ends_with('\n') {
        out.write_all(b"\n")?;
    }
    writeln!(
        out,
        "<!-- tasks-cli:canonical-v1:end-{kind} sha256={digest} -->"
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validation_enforces_title_and_body_limits() {
        assert!(validate_title_body("test", "ok", "body").is_ok());
        assert!(validate_title_body("test", "", "body").is_err());
        assert!(validate_title_body("test", &"x".repeat(TITLE_MAX_CHARS + 1), "body").is_err());
        assert!(validate_title_body("test", "ok", &"x".repeat(BODY_MAX_BYTES + 1)).is_err());
        assert!(validate_status("in-progress").is_ok());
        assert!(validate_status("unknown").is_err());
    }

    /// Pins `RUNNABLE_STATUSES` (the arms `select_tasks`'s default view
    /// unions) against `RUNNABLE_PREDICATE`'s own literal `t.status IN
    /// (...)` term, so the two constants can't silently drift apart.
    #[test]
    fn runnable_statuses_match_runnable_predicate_text() {
        for status in RUNNABLE_STATUSES {
            assert!(
                RUNNABLE_PREDICATE.contains(&format!("'{status}'")),
                "RUNNABLE_STATUSES has {status:?}, which RUNNABLE_PREDICATE's \
                 text no longer mentions: {RUNNABLE_PREDICATE}"
            );
        }
        let mentioned = RUNNABLE_PREDICATE
            .split("IN (")
            .nth(1)
            .and_then(|rest| rest.split(')').next())
            .expect("RUNNABLE_PREDICATE starts with a `t.status IN (...)` term");
        let mentioned_count = mentioned.matches('\'').count() / 2;
        assert_eq!(
            mentioned_count,
            RUNNABLE_STATUSES.len(),
            "RUNNABLE_PREDICATE's status list and RUNNABLE_STATUSES have \
             different lengths; update RUNNABLE_STATUSES to match: {RUNNABLE_PREDICATE}"
        );
    }

    /// Pins `non_terminal_statuses()` against every `TaskStatus` variant:
    /// adding or removing a variant must change this test's expected count,
    /// and every non-terminal variant's SQL text must be present.
    #[test]
    fn non_terminal_statuses_covers_every_non_terminal_task_status_variant() {
        use crate::model::TaskStatus;
        use clap::ValueEnum;
        let variants = TaskStatus::value_variants();
        let expected_non_terminal = variants.iter().filter(|s| !s.is_terminal()).count();
        let expected_terminal = variants.iter().filter(|s| s.is_terminal()).count();
        // If this fails, a TaskStatus variant was added/removed/renamed:
        // update this test (and re-check the derivation above) accordingly.
        assert_eq!(
            expected_terminal, 2,
            "expected exactly 'done' and 'cancelled' to be terminal"
        );
        let got = non_terminal_statuses();
        assert_eq!(got.len(), expected_non_terminal);
        for status in variants {
            if status.is_terminal() {
                continue;
            }
            assert!(
                got.iter().any(|s| *s == status.to_string()),
                "non_terminal_statuses() is missing {status}"
            );
        }
    }
}
