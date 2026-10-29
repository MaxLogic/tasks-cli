use rusqlite::Error as SqliteError;
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("{0}")]
    ClientUpgradeRequired(String),
    #[error("{0}")]
    ServerUpgradeRequired(String),
    #[error("{message}")]
    Coded {
        code: &'static str,
        exit: u8,
        message: String,
    },
    #[error("usage: {0}")]
    Usage(String),
    #[error("destination exists: {0}; choose another path or pass --overwrite")]
    DestinationExists(String),
    #[error(
        "destination collision: {0}; choose distinct destination names or use the default cache"
    )]
    DestinationCollision(String),
    #[error("remote capability: {0}; upgrade the server to support attachments-v1")]
    RemoteCapability(String),
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
    #[error("remote service: {message}")]
    Remote {
        code: &'static str,
        message: String,
        request_id: Option<uuid::Uuid>,
    },
    #[error("{message}")]
    RemoteReply {
        message: String,
        payload: serde_json::Value,
        exit_code: i32,
    },
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

impl From<crate::attachment::AttachmentError> for AppError {
    fn from(value: crate::attachment::AttachmentError) -> Self {
        Self::Coded {
            code: value.code(),
            exit: value.exit_code() as u8,
            message: value.to_string(),
        }
    }
}

impl AppError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::ClientUpgradeRequired(_) => "client_upgrade_required",
            Self::ServerUpgradeRequired(_) => "server_upgrade_required",
            Self::Coded { code, .. } => code,
            Self::Usage(_) => "usage",
            Self::DestinationExists(_) => "destination_exists",
            Self::DestinationCollision(_) => "destination_collision",
            Self::RemoteCapability(_) => "remote_capability",
            Self::NotFound(_) | Self::NotFoundCode(_) => "not_found",
            Self::VersionConflict { .. } => "version_conflict",
            Self::Conflict(_) => "conflict",
            Self::ResponseLimit(_) => "response_limit",
            Self::Remote { code, .. } => code,
            Self::RemoteReply { .. } => "remote_application",
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
            Self::ClientUpgradeRequired(_) | Self::ServerUpgradeRequired(_) => 5,
            Self::Coded { exit, .. } => i32::from(*exit),
            Self::Usage(_) => 2,
            Self::DestinationExists(_) | Self::DestinationCollision(_) => 2,
            Self::RemoteCapability(_) => 5,
            Self::NotFound(_) | Self::NotFoundCode(_) => 3,
            Self::VersionConflict { .. } => 4,
            Self::Conflict(_) => 4,
            Self::ResponseLimit(_) => 2,
            Self::Remote { .. } => 5,
            Self::RemoteReply { exit_code, .. } => *exit_code,
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
        if let Self::RemoteReply { payload, .. } = self {
            return payload.to_string();
        }
        let mut error = serde_json::Map::new();
        error.insert("code".to_string(), serde_json::json!(self.code()));
        error.insert("message".to_string(), serde_json::json!(self.to_string()));
        if let Self::Remote {
            request_id: Some(id),
            ..
        } = self
        {
            error.insert("request_id".into(), serde_json::json!(id));
        }
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
    fn attachment_destination_and_capability_errors_have_stable_codes() {
        for (error, code, exit, recovery) in [
            (
                AppError::DestinationExists("C:/out/a.txt".into()),
                "destination_exists",
                2,
                "--overwrite",
            ),
            (
                AppError::DestinationCollision("A1 and A2 resolve to C:/out/a.txt".into()),
                "destination_collision",
                2,
                "distinct destination",
            ),
            (
                AppError::RemoteCapability("server lacks attachments-v1".into()),
                "remote_capability",
                5,
                "upgrade the server",
            ),
        ] {
            assert_eq!(error.exit_code(), exit);
            assert_eq!(error.code(), code);
            assert!(error.to_string().contains(recovery));
            let json: serde_json::Value = serde_json::from_str(&error.json()).unwrap();
            assert_eq!(json["schema_version"], 1);
            assert_eq!(json["error"]["code"], code);
            assert_eq!(json["error"]["message"], error.to_string());
        }
    }

    #[test]
    fn attachment_error_mapping_preserves_code_exit_and_message() {
        use crate::attachment::AttachmentError;
        for (error, code, exit) in [
            (
                AttachmentError::TooLarge {
                    measured: 21,
                    limit: 20,
                },
                "attachment_too_large",
                2,
            ),
            (
                AttachmentError::OriginalTooLarge {
                    measured: 257,
                    limit: 256,
                },
                "attachment_original_too_large",
                2,
            ),
            (
                AttachmentError::Integrity("SHA-256 mismatch"),
                "attachment_integrity",
                6,
            ),
            (
                AttachmentError::Name("invalid name".into()),
                "validation",
                2,
            ),
            (AttachmentError::Codec("encoder failed".into()), "io", 6),
            (
                AttachmentError::Io(std::io::Error::other("read failed")),
                "io",
                6,
            ),
        ] {
            let message = error.to_string();
            let mapped = AppError::from(error);
            assert_eq!(mapped.code(), code);
            assert_eq!(mapped.exit_code(), exit);
            assert_eq!(mapped.to_string(), message);
            let json: serde_json::Value = serde_json::from_str(&mapped.json()).unwrap();
            assert_eq!(json["error"]["code"], code);
            assert_eq!(json["error"]["message"], message);
        }
    }

    #[test]
    fn coded_error_uses_existing_json_and_text_rendering() {
        let error = AppError::Coded {
            code: "attachment_batch_too_large",
            exit: 2,
            message: "33 files; the limit is 32".into(),
        };
        assert_eq!(error.code(), "attachment_batch_too_large");
        assert_eq!(error.exit_code(), 2);
        assert_eq!(error.to_string(), "33 files; the limit is 32");
        let json: serde_json::Value = serde_json::from_str(&error.json()).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"schema_version": 1, "error": {"code": "attachment_batch_too_large", "message": "33 files; the limit is 32"}})
        );
    }

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
