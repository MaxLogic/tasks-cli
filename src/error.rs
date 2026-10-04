use rusqlite::Error as SqliteError;
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("usage: {0}")]
    Usage(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("project/task not found: {0}")]
    NotFoundCode(String),
    #[error(
        "version conflict: expected {expected}, current {current}; re-read the task and retry with the current version"
    )]
    VersionConflict { expected: u64, current: u64 },
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("response limit: {0}")]
    ResponseLimit(String),
    #[error("stale snapshot: {0}")]
    StaleSnapshot(String),
    #[error("lock timeout: {0}")]
    LockTimeout(String),
    #[error("lock busy: {0}")]
    Busy(String),
    #[error("storage/database: {0}")]
    Database(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("invalid path: {0}")]
    InvalidPath(String),
    #[error("validation: {0}")]
    Validation(String),
    /// The completion guard refused `done`: a validation error (exit 2) that
    /// also carries the blocking prerequisites for structured JSON output.
    #[error("validation: {message}")]
    OpenPrerequisites {
        task: u64,
        prerequisites: Vec<(u64, String)>,
        message: String,
        /// The project key, so JSON can carry each ID's display form.
        key: Option<String>,
    },
    #[error("registry: {0}")]
    Registry(String),
    #[error("interop: {0}")]
    Interop(String),
    #[error(
        "{file}: sha256 mismatch: expected {expected}, got {actual}; the file changed after the preview, re-run the preview"
    )]
    ShaMismatch {
        file: String,
        expected: String,
        actual: String,
    },
    #[error("serde: {0}")]
    Serde(String),
}

impl From<SqliteError> for AppError {
    fn from(value: SqliteError) -> Self {
        if let rusqlite::Error::SqliteFailure(err, _) = &value {
            if err.code == rusqlite::ErrorCode::DatabaseBusy {
                return AppError::LockTimeout(
                    "the database is locked by another process; retry when the other command finishes"
                        .to_string(),
                );
            }
            if err.code == rusqlite::ErrorCode::DatabaseLocked {
                return AppError::Busy(
                    "the database is locked by another writer; retry the command".to_string(),
                );
            }
        }
        AppError::Database(value.to_string())
    }
}

impl From<serde_json::Error> for AppError {
    fn from(value: serde_json::Error) -> Self {
        AppError::Serde(value.to_string())
    }
}

impl AppError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Usage(_) => "usage",
            Self::NotFound(_) | Self::NotFoundCode(_) => "not_found",
            Self::VersionConflict { .. } => "version_conflict",
            Self::Conflict(_) => "conflict",
            Self::ResponseLimit(_) => "response_limit",
            Self::StaleSnapshot(_) => "stale_snapshot",
            Self::LockTimeout(_) | Self::Busy(_) => "lock_timeout",
            Self::Database(_) => "database",
            Self::Io(_) => "io",
            Self::InvalidPath(_) => "invalid_path",
            Self::Validation(_) | Self::OpenPrerequisites { .. } => "validation",
            Self::Registry(_) => "registry",
            Self::Interop(_) => "interop",
            Self::ShaMismatch { .. } => "source_hash_mismatch",
            Self::Serde(_) => "serialization",
        }
    }

    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Usage(_) => 2,
            Self::NotFound(_) | Self::NotFoundCode(_) => 3,
            Self::VersionConflict { .. } => 4,
            Self::Conflict(_) => 4,
            Self::ResponseLimit(_) => 2,
            Self::StaleSnapshot(_) => 4,
            Self::LockTimeout(_) | Self::Busy(_) => 5,
            Self::InvalidPath(_)
            | Self::Validation(_)
            | Self::OpenPrerequisites { .. }
            | Self::ShaMismatch { .. } => 2,
            Self::Database(_)
            | Self::Io(_)
            | Self::Registry(_)
            | Self::Interop(_)
            | Self::Serde(_) => 6,
        }
    }

    pub fn validation(message: impl Into<String>) -> Self {
        Self::Validation(message.into())
    }

    /// Name the operation and the path for a filesystem failure, so a bare
    /// OS message never reaches the user.
    pub fn io_path(operation: &str, path: &Path, error: std::io::Error) -> Self {
        Self::Io(std::io::Error::new(
            error.kind(),
            format!("cannot {operation} {}: {error}", path.display()),
        ))
    }

    /// Name only the operation for a filesystem failure without a single path.
    pub fn io_op(operation: &str, error: std::io::Error) -> Self {
        Self::Io(std::io::Error::new(
            error.kind(),
            format!("cannot {operation}: {error}"),
        ))
    }

    /// Prefix an operation onto errors that carry only an underlying message.
    /// Errors that already name their object keep their own text.
    pub fn context(self, operation: &str) -> Self {
        match self {
            Self::Database(message) => Self::Database(format!("{operation}: {message}")),
            Self::Io(error) => Self::Io(std::io::Error::new(
                error.kind(),
                format!("{operation}: {error}"),
            )),
            Self::Serde(message) => Self::Serde(format!("{operation}: {message}")),
            Self::Registry(message) => Self::Registry(format!("{operation}: {message}")),
            Self::Busy(message) => Self::Busy(format!("{operation}: {message}")),
            Self::LockTimeout(message) => Self::LockTimeout(format!("{operation}: {message}")),
            other => other,
        }
    }

    /// A SQLite failure with the operation that was running.
    pub fn db_context(operation: &str, error: SqliteError) -> Self {
        Self::from(error).context(operation)
    }

    pub fn usage(message: impl Into<String>) -> Self {
        Self::Usage(message.into())
    }

    pub fn json(&self) -> String {
        let mut error = serde_json::Map::new();
        error.insert("code".to_string(), serde_json::json!(self.code()));
        error.insert("message".to_string(), serde_json::json!(self.to_string()));
        if let Self::VersionConflict { expected, current } = self {
            error.insert(
                "conflict".to_string(),
                serde_json::json!({"expected": expected, "current": current}),
            );
        }
        if let Self::OpenPrerequisites {
            task,
            prerequisites,
            key,
            ..
        } = self
        {
            let display = |id: u64| crate::model::render_keyed_task_id(key.as_deref(), id);
            let items = prerequisites
                .iter()
                .map(|(id, status)| {
                    serde_json::json!({"id": id, "display_id": display(*id), "status": status})
                })
                .collect::<Vec<_>>();
            error.insert(
                "open_prerequisites".to_string(),
                serde_json::json!({
                    "task": task,
                    "task_display_id": display(*task),
                    "prerequisites": items
                }),
            );
        }
        serde_json::json!({"schema_version": 1, "error": error}).to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn io_path_names_the_operation_and_the_path() {
        let error = AppError::io_path(
            "read the ledger",
            Path::new("C:/work/TASKS.md"),
            std::io::Error::new(std::io::ErrorKind::NotFound, "file not found"),
        );
        let message = error.to_string();
        assert!(message.contains("read the ledger"), "{message}");
        assert!(message.contains("C:/work/TASKS.md"), "{message}");
        assert!(message.contains("file not found"), "{message}");
        assert_eq!(error.exit_code(), 6);
        assert_eq!(error.code(), "io");
    }

    #[test]
    fn io_op_names_the_operation_without_a_path() {
        let error = AppError::io_op(
            "read the import source from stdin",
            std::io::Error::new(std::io::ErrorKind::BrokenPipe, "broken pipe"),
        );
        let message = error.to_string();
        assert!(
            message.contains("read the import source from stdin"),
            "{message}"
        );
        assert!(message.contains("broken pipe"), "{message}");
    }

    #[test]
    fn context_prefixes_operation_onto_carrying_variants() {
        let database = AppError::Database("table is missing".to_string())
            .context("migrate C:/data/TASKS.sqlite");
        assert!(database
            .to_string()
            .contains("migrate C:/data/TASKS.sqlite"));
        assert!(database.to_string().contains("table is missing"));
        let usage = AppError::Usage("bad flag".to_string()).context("migrate C:/data/TASKS.sqlite");
        assert_eq!(usage.to_string(), "usage: bad flag");
    }

    #[test]
    fn sha_mismatch_names_the_file_and_both_hashes() {
        let error = AppError::ShaMismatch {
            file: "C:/work/TASKS.md".to_string(),
            expected: "aa".to_string(),
            actual: "bb".to_string(),
        };
        let message = error.to_string();
        assert!(message.contains("C:/work/TASKS.md"), "{message}");
        assert!(message.contains("expected aa"), "{message}");
        assert!(message.contains("got bb"), "{message}");
        assert_eq!(error.code(), "source_hash_mismatch");
        assert_eq!(error.exit_code(), 2);
    }

    #[test]
    fn lock_messages_name_the_action_to_take() {
        let timeout = AppError::LockTimeout(
            "the database is locked by another process; retry when the other command finishes"
                .to_string(),
        );
        assert!(timeout.to_string().contains("retry"), "{timeout}");
        assert_eq!(timeout.exit_code(), 5);
        let busy = AppError::Busy(
            "the database is locked by another writer; retry the command".to_string(),
        );
        assert!(busy.to_string().contains("retry the command"), "{busy}");
        assert_eq!(busy.exit_code(), 5);
    }
}
