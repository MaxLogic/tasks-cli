use rusqlite::Error as SqliteError;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("usage: {0}")]
    Usage(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("project/task not found: {0}")]
    NotFoundCode(String),
    #[error("version conflict: expected {expected}, current {current}")]
    VersionConflict { expected: u64, current: u64 },
    #[error("lock timeout")]
    LockTimeout,
    #[error("lock busy")]
    Busy,
    #[error("storage/database: {0}")]
    Database(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("invalid path: {0}")]
    InvalidPath(String),
    #[error("validation: {0}")]
    Validation(String),
    #[error("registry: {0}")]
    Registry(String),
    #[error("interop: {0}")]
    Interop(String),
    #[error("sha mismatch: expected {expected}, got {actual}")]
    ShaMismatch { expected: String, actual: String },
    #[error("serde: {0}")]
    Serde(String),
}

impl From<SqliteError> for AppError {
    fn from(value: SqliteError) -> Self {
        if let rusqlite::Error::SqliteFailure(err, _) = &value {
            if err.code == rusqlite::ErrorCode::DatabaseBusy {
                return AppError::LockTimeout;
            }
            if err.code == rusqlite::ErrorCode::DatabaseLocked {
                return AppError::Busy;
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
            Self::LockTimeout | Self::Busy => "lock_timeout",
            Self::Database(_) => "database",
            Self::Io(_) => "io",
            Self::InvalidPath(_) => "invalid_path",
            Self::Validation(_) => "validation",
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
            Self::LockTimeout | Self::Busy => 5,
            Self::InvalidPath(_) | Self::Validation(_) | Self::ShaMismatch { .. } => 2,
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
        serde_json::json!({"schema_version": 1, "error": error}).to_string()
    }
}
