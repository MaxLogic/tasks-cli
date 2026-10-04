//! Server-local identity and credential state. No network admin operations.
mod request_log;
pub mod signatures;
pub mod transport;
use crate::storage::{acquire_exclusive_lock_for, validate_storage_root, ExclusiveLock};
use crate::AppError;
use ed25519_dalek::VerifyingKey;
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Duration;
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("authentication failed: {0}")]
    Unauthorized(&'static str),
    #[error("request clock is outside the allowed window; synchronize client and server UTC")]
    Clock,
    #[error("service capacity is exhausted; retry later with a fresh signed request")]
    Capacity,
    #[error("invalid server input: {0}")]
    Validation(&'static str),
    #[error(transparent)]
    Storage(#[from] AppError),
}
impl From<rusqlite::Error> for ServiceError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Storage(error.into())
    }
}
impl From<std::io::Error> for ServiceError {
    fn from(error: std::io::Error) -> Self {
        Self::Storage(error.into())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registration {
    pub public_key: [u8; 32],
    pub actor_id: String,
    pub actor_name: String,
    pub installation_id: Uuid,
    pub installation_name: String,
}

/// Holding this value excludes another service or administrator for this root.
pub struct OwnedServer {
    root: PathBuf,
    id: Uuid,
    _ownership: ExclusiveLock,
}

impl OwnedServer {
    fn claim(root: &Path) -> Result<(PathBuf, ExclusiveLock), ServiceError> {
        let root = validate_storage_root(root)?;
        std::fs::create_dir_all(&root)?;
        let ownership = acquire_exclusive_lock_for(&root.join("server.lock"), Duration::ZERO)?;
        Ok((root, ownership))
    }

    pub fn initialize(root: &Path) -> Result<Self, ServiceError> {
        let (root, ownership) = Self::claim(root)?;
        let path = root.join("server.sqlite");
        // Explicit initialization never overwrites an existing identity or auth store.
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)?;
        let mut connection = Connection::open(&path)?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;",
        )?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute_batch(include_str!("schema.sql"))?;
        let id = Uuid::new_v4();
        transaction.execute(
            "INSERT INTO server_identity(singleton,server_id) VALUES (1,?1)",
            [id.to_string()],
        )?;
        Self::audit(&transaction, "initialize", None, None)?;
        transaction.pragma_update(None, "user_version", 1)?;
        transaction.commit()?;
        drop(connection);
        Ok(Self {
            root,
            id,
            _ownership: ownership,
        })
    }

    pub fn open(root: &Path) -> Result<Self, ServiceError> {
        // Refuse missing stores, rather than implicitly creating a new authority.
        let root = validate_storage_root(root)?;
        if !root.join("server.sqlite").is_file() {
            return Err(ServiceError::Validation(
                "server is not initialized; run admin init explicitly",
            ));
        }
        let (root, ownership) = Self::claim(&root)?;
        let connection = Connection::open_with_flags(
            root.join("server.sqlite"),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE,
        )?;
        let version: u32 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version != 1 {
            return Err(ServiceError::Validation(
                "unsupported server schema; use a compatible server binary",
            ));
        }
        Self::validate_schema(&connection)?;
        let text: String = connection.query_row(
            "SELECT server_id FROM server_identity WHERE singleton=1",
            [],
            |row| row.get(0),
        )?;
        let id = Uuid::parse_str(&text)
            .map_err(|_| ServiceError::Validation("invalid stored server identity"))?;
        if id.is_nil() {
            return Err(ServiceError::Validation("invalid stored server identity"));
        }
        Ok(Self {
            root,
            id,
            _ownership: ownership,
        })
    }

    pub fn server_id(&self) -> Uuid {
        self.id
    }

    fn validate_schema(connection: &Connection) -> Result<(), ServiceError> {
        fn definitions(
            connection: &Connection,
        ) -> Result<Vec<(String, String, String)>, rusqlite::Error> {
            let mut statement=connection.prepare("SELECT type,name,sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type,name")?;
            let rows =
                statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?;
            rows.collect()
        }
        // Compare against the schema executed by SQLite, including trigger bodies,
        // rather than trusting a user_version stamp or trigger names alone.
        let expected = Connection::open_in_memory()?;
        expected.execute_batch(include_str!("schema.sql"))?;
        if definitions(connection)? != definitions(&expected)? {
            return Err(ServiceError::Validation(
                "server schema is damaged or incompatible; restore a verified backup",
            ));
        }
        let integrity: String =
            connection.query_row("PRAGMA quick_check(1)", [], |row| row.get(0))?;
        let foreign_keys: i64 =
            connection.query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |row| {
                row.get(0)
            })?;
        if integrity != "ok" || foreign_keys != 0 {
            return Err(ServiceError::Validation(
                "server database integrity check failed; restore a verified backup",
            ));
        }
        Ok(())
    }

    fn connect(&self) -> Result<Connection, ServiceError> {
        let connection = Connection::open_with_flags(
            self.root.join("server.sqlite"),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE,
        )?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")?;
        Ok(connection)
    }

    fn audit(
        connection: &Connection,
        operation: &str,
        credential: Option<Uuid>,
        registration: Option<&Registration>,
    ) -> Result<(), ServiceError> {
        let os_actor = whoami::account().ok();
        let identity = registration
            .map(serde_json::to_string)
            .transpose()
            .map_err(AppError::from)?;
        connection.execute("INSERT INTO admin_events(operation,credential_id,os_actor,identity_json) VALUES (?1,?2,?3,?4)", params![operation,credential.map(|id| id.to_string()),os_actor,identity])?;
        Ok(())
    }

    pub fn register(&self, registration: &Registration) -> Result<Uuid, ServiceError> {
        for text in [
            &registration.actor_id,
            &registration.actor_name,
            &registration.installation_name,
        ] {
            if text.trim().is_empty() || text.len() > 1024 {
                return Err(ServiceError::Validation(
                    "registration names must be nonempty and at most 1024 bytes",
                ));
            }
        }
        if registration.installation_id.is_nil() {
            return Err(ServiceError::Validation(
                "installation UUID must not be nil",
            ));
        }
        let key = VerifyingKey::from_bytes(&registration.public_key)
            .map_err(|_| ServiceError::Validation("invalid Ed25519 public key"))?;
        if key.is_weak() {
            return Err(ServiceError::Validation("weak Ed25519 public key"));
        }
        let mut connection = self.connect()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let id = Uuid::new_v4();
        transaction.execute("INSERT INTO credentials(credential_id,public_key,actor_id,actor_name,installation_id,installation_name,revoked) VALUES (?1,?2,?3,?4,?5,?6,0)",params![id.to_string(),registration.public_key.as_slice(),registration.actor_id,registration.actor_name,registration.installation_id.to_string(),registration.installation_name])?;
        Self::audit(&transaction, "register", Some(id), Some(registration))?;
        transaction.commit()?;
        Ok(id)
    }

    pub fn revoke(&self, credential: Uuid) -> Result<(), ServiceError> {
        let mut connection = self.connect()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let registration = Self::lookup(&transaction, credential, false)?;
        let changed = transaction.execute(
            "UPDATE credentials SET revoked=1 WHERE credential_id=?1 AND revoked=0",
            [credential.to_string()],
        )?;
        if changed != 0 {
            Self::audit(
                &transaction,
                "revoke",
                Some(credential),
                Some(&registration),
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    fn lookup(
        connection: &Connection,
        credential: Uuid,
        require_active: bool,
    ) -> Result<Registration, ServiceError> {
        let row = connection.query_row("SELECT public_key,actor_id,actor_name,installation_id,installation_name,revoked FROM credentials WHERE credential_id=?1",[credential.to_string()], |row| Ok((row.get::<_,Vec<u8>>(0)?,row.get::<_,String>(1)?,row.get::<_,String>(2)?,row.get::<_,String>(3)?,row.get::<_,String>(4)?,row.get::<_,bool>(5)?))).optional()?;
        let Some((key, actor_id, actor_name, machine, name, revoked)) = row else {
            return Err(ServiceError::Unauthorized("unknown or revoked credential"));
        };
        if require_active && revoked {
            return Err(ServiceError::Unauthorized("unknown or revoked credential"));
        }
        Ok(Registration {
            public_key: key
                .try_into()
                .map_err(|_| ServiceError::Validation("invalid stored public key"))?,
            actor_id,
            actor_name,
            installation_id: Uuid::parse_str(&machine)
                .map_err(|_| ServiceError::Validation("invalid stored installation UUID"))?,
            installation_name: name,
        })
    }

    pub fn credential(&self, credential: Uuid) -> Result<Registration, ServiceError> {
        Self::lookup(&self.connect()?, credential, true)
    }

    /// Internal admission step after cryptographic verification. Expired records
    /// alone may be removed. The transaction rechecks revocation before dispatch.
    pub fn consume_nonce(
        &self,
        credential: Uuid,
        nonce: &str,
        expires: i64,
        now: i64,
    ) -> Result<(), ServiceError> {
        let mut connection = self.connect()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        Self::lookup(&transaction, credential, true)?;
        transaction.execute(
            "DELETE FROM replay_nonces WHERE expires < ?1",
            [now.saturating_sub(30)],
        )?;
        let exists: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM replay_nonces WHERE credential_id=?1 AND nonce=?2)",
            params![credential.to_string(), nonce],
            |row| row.get(0),
        )?;
        if exists {
            return Err(ServiceError::Unauthorized(
                "nonce was already used; sign a fresh request",
            ));
        }
        let count: i64 = transaction.query_row(
            "SELECT count(*) FROM replay_nonces WHERE credential_id=?1",
            [credential.to_string()],
            |row| row.get(0),
        )?;
        let total: i64 =
            transaction.query_row("SELECT count(*) FROM replay_nonces", [], |row| row.get(0))?;
        if count >= 4096 || total >= 65536 {
            return Err(ServiceError::Capacity);
        }
        transaction.execute(
            "INSERT INTO replay_nonces(credential_id,nonce,expires) VALUES (?1,?2,?3)",
            params![credential.to_string(), nonce, expires],
        )?;
        transaction.commit()?;
        Ok(())
    }
}
