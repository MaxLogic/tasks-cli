//! Server-local identity and credential state. No network admin operations.
pub mod api;
pub mod attachments;
mod export;
pub mod maintenance;
pub mod receipts;
mod request_log;
pub mod signatures;
pub(crate) mod timing;
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
    #[error("{message}")]
    UpgradeRequired {
        code: &'static str,
        message: String,
        receipt: Option<crate::remote::protocol::RequestReceipt>,
    },
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
impl From<crate::remote::signing::SigningError> for ServiceError {
    fn from(error: crate::remote::signing::SigningError) -> Self {
        use crate::remote::signing::SigningError;
        match error {
            SigningError::Unauthorized(message) => Self::Unauthorized(message),
            SigningError::Validation(message) => Self::Validation(message),
            SigningError::Clock => Self::Clock,
        }
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
    // This query-only connection's shared main-file lock keeps the auth WAL
    // open between operations, preventing last-close checkpoint/unlink work.
    // Reuse it for short, serialized catalog lookups to avoid initializing a
    // fresh WAL reader after every nonce commit. Never retain a transaction or
    // read snapshot, or hold its mutex while opening/using a project Store.
    // Drop it before releasing root ownership (fields drop in declaration order).
    catalog_connection: std::sync::Mutex<Connection>,
    // Reuse the WAL writer and its directory-sync state between admissions.
    // Keep it independent of catalog reads and never retain a transaction.
    // Contention falls back to connect(), preserving SQLite's busy timeout.
    nonce_connection: std::sync::Mutex<Option<Connection>>,
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
        transaction.execute_batch(include_str!("catalog_schema.sql"))?;
        let id = Uuid::new_v4();
        transaction.execute(
            "INSERT INTO server_identity(singleton,server_id) VALUES (1,?1)",
            [id.to_string()],
        )?;
        Self::audit(&transaction, "initialize", None, None)?;
        transaction.pragma_update(None, "user_version", 2)?;
        transaction.commit()?;
        connection.pragma_update(None, "query_only", true)?;
        let nonce_connection = Self::connect_at(&root)?;
        Ok(Self {
            root,
            id,
            catalog_connection: std::sync::Mutex::new(connection),
            nonce_connection: std::sync::Mutex::new(Some(nonce_connection)),
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
        connection.busy_timeout(Duration::from_secs(5))?;
        let version: u32 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version != 2 {
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
        // SQLite-API backups are standalone DELETE-mode snapshots. Restore WAL
        // before retaining the lifetime connection, including on admin opens.
        let journal: String =
            connection.query_row("PRAGMA journal_mode=WAL", [], |row| row.get(0))?;
        if journal != "wal" {
            return Err(ServiceError::Validation(
                "server authority requires WAL mode",
            ));
        }
        connection.execute_batch("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")?;
        connection.pragma_update(None, "query_only", true)?;
        let nonce_connection = Self::connect_at(&root)?;
        Ok(Self {
            root,
            id,
            catalog_connection: std::sync::Mutex::new(connection),
            nonce_connection: std::sync::Mutex::new(Some(nonce_connection)),
            _ownership: ownership,
        })
    }

    /// Explicit stopped-service upgrade, preserving a verified SQLite snapshot.
    pub fn migrate(root: &Path) -> Result<Option<PathBuf>, ServiceError> {
        Ok(Self::migrate_all(root)?.backup_path)
    }
    pub fn migrate_all(root: &Path) -> Result<maintenance::MigrationResult, ServiceError> {
        let root = validate_storage_root(root)?;
        if !root.join("server.sqlite").is_file() {
            return Err(ServiceError::Validation("server is not initialized"));
        }
        let (root, _ownership) = Self::claim(&root)?;
        let mut conn = Connection::open_with_flags(
            root.join("server.sqlite"),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE,
        )?;
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.execute_batch("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")?;
        let version: u32 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version == 2 {
            Self::validate_schema_version(&conn, 2)?;
            let projects = maintenance::migrate_projects(&root)?;
            return Ok(maintenance::MigrationResult {
                schema_version: 2,
                backup_path: None,
                projects,
            });
        }
        if version != 1 {
            return Err(ServiceError::Validation(
                "unsupported server schema; use a compatible server binary",
            ));
        }
        Self::validate_schema_version(&conn, 1)?;
        let backup = root.join(format!("server.v1-pre-migrate-{}.sqlite", Uuid::new_v4()));
        conn.backup("main", &backup, None)?;
        let verified =
            Connection::open_with_flags(&backup, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        Self::validate_schema_version(&verified, 1)?;
        let id = |db: &Connection| {
            db.query_row(
                "SELECT server_id FROM server_identity WHERE singleton=1",
                [],
                |r| r.get::<_, String>(0),
            )
        };
        if id(&conn)? != id(&verified)?
            || verified.pragma_query_value(None, "user_version", |r| r.get::<_, u32>(0))? != 1
        {
            return Err(ServiceError::Validation(
                "server migration backup does not match the authority",
            ));
        }
        drop(verified);
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute_batch(include_str!("catalog_schema.sql"))?;
        Self::audit(&tx, "migrate-schema", None, None)?;
        tx.pragma_update(None, "user_version", 2)?;
        Self::validate_schema_version(&tx, 2)?;
        tx.commit()?;
        let projects = maintenance::migrate_projects(&root)?;
        Ok(maintenance::MigrationResult {
            schema_version: 2,
            backup_path: Some(backup),
            projects,
        })
    }

    pub fn server_id(&self) -> Uuid {
        self.id
    }

    pub(crate) fn data_root(&self) -> &Path {
        &self.root
    }

    fn validate_schema(connection: &Connection) -> Result<(), ServiceError> {
        Self::validate_schema_version(connection, 2)
    }

    fn validate_schema_version(connection: &Connection, version: u32) -> Result<(), ServiceError> {
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
        if version == 2 {
            expected.execute_batch(include_str!("catalog_schema.sql"))?;
        }
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
        Self::connect_at(&self.root)
    }

    fn connect_at(root: &Path) -> Result<Connection, ServiceError> {
        let connection = Connection::open_with_flags(
            root.join("server.sqlite"),
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
        let _nonce = timing::Phase::Nonce.start();
        let open = timing::Phase::NonceOpen.start();
        let mut retained = match self.nonce_connection.try_lock() {
            Ok(connection) => Some(connection),
            Err(std::sync::TryLockError::WouldBlock) => None,
            Err(std::sync::TryLockError::Poisoned(error)) => Some(error.into_inner()),
        };
        let mut fresh = None;
        let connection = match retained.as_mut() {
            Some(slot) => {
                timing::nonce_path(timing::NoncePath::Retained);
                // A failed COMMIT and failed drop-time ROLLBACK can leave a
                // transaction open. Close that writer before reconnecting,
                // including if reconnecting fails, to release its WAL lock.
                if slot
                    .as_ref()
                    .is_some_and(|connection| !connection.is_autocommit())
                {
                    drop(slot.take());
                }
                // Only reuse a recovered poisoned writer after checking its
                // transaction state. No authorization result is retained.
                self.nonce_connection.clear_poison();
                match &mut **slot {
                    Some(connection) => connection,
                    missing => missing.insert(self.connect()?),
                }
            }
            None => {
                timing::nonce_path(timing::NoncePath::Fallback);
                fresh.insert(self.connect()?)
            }
        };
        drop(open);
        let sql = timing::Phase::NonceSql.start();
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
        drop(sql);
        {
            let _commit = timing::Phase::NonceCommit.start();
            transaction.commit()?;
        }
        {
            let _close = timing::Phase::NonceClose.start();
            drop(retained);
            drop(fresh);
        }
        Ok(())
    }
}

#[cfg(test)]
mod nonce_connection_tests {
    use super::*;

    fn fixture() -> (tempfile::TempDir, std::sync::Arc<OwnedServer>, Uuid) {
        let root = tempfile::tempdir().unwrap();
        let server = std::sync::Arc::new(OwnedServer::initialize(root.path()).unwrap());
        let credential = server
            .register(&Registration {
                public_key: ed25519_dalek::SigningKey::from_bytes(&[74; 32])
                    .verifying_key()
                    .to_bytes(),
                actor_id: "fixture".into(),
                actor_name: "Fixture".into(),
                installation_id: Uuid::new_v4(),
                installation_name: "Fixture".into(),
            })
            .unwrap();
        (root, server, credential)
    }

    #[test]
    fn unfinished_retained_nonce_transaction_is_discarded_before_admission() {
        let (_root, server, credential) = fixture();
        {
            let connection = server.nonce_connection.lock().unwrap();
            let connection = connection.as_ref().unwrap();
            connection.execute_batch("BEGIN IMMEDIATE").unwrap();
            connection.execute(
                "INSERT INTO replay_nonces(credential_id,nonce,expires) VALUES (?1,'unfinished',1120)",
                [credential.to_string()],
            ).unwrap();
            assert!(!connection.is_autocommit());
        }
        // Closing the abandoned writer must roll back its uncommitted nonce.
        server
            .consume_nonce(credential, "unfinished", 1120, 1000)
            .unwrap();
        assert!(matches!(
            server.consume_nonce(credential, "unfinished", 1120, 1000),
            Err(ServiceError::Unauthorized(_))
        ));
        server
            .consume_nonce(credential, "next", 1120, 1000)
            .unwrap();
    }

    #[test]
    fn poisoned_retained_nonce_connection_recovers_with_or_without_a_transaction() {
        for leave_transaction in [false, true] {
            let (_root, server, credential) = fixture();
            let panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let connection = server.nonce_connection.lock().unwrap();
                let connection = connection.as_ref().unwrap();
                if leave_transaction {
                    connection.execute_batch("BEGIN IMMEDIATE").unwrap();
                }
                panic!("fixture: panic while holding the nonce writer");
            }));
            assert!(panic.is_err());
            assert!(server.nonce_connection.is_poisoned());
            server
                .consume_nonce(credential, "after-panic", 1120, 1000)
                .unwrap();
            assert!(!server.nonce_connection.is_poisoned());
            assert!(matches!(
                server.consume_nonce(credential, "after-panic", 1120, 1000),
                Err(ServiceError::Unauthorized(_))
            ));
        }
    }

    #[test]
    fn occupied_retained_nonce_connection_uses_an_independent_writer() {
        let (_root, server, credential) = fixture();
        // Occupy only the Rust mutex, without holding a SQLite transaction.
        let retained = server.nonce_connection.lock().unwrap();
        let (send, receive) = std::sync::mpsc::channel();
        let worker_server = std::sync::Arc::clone(&server);
        let worker = std::thread::spawn(move || {
            let result = timing::capture(std::time::Instant::now(), timing::Phase::Auth, || {
                worker_server.consume_nonce(credential, "fallback", 1120, 1000)
            });
            send.send(result).unwrap();
        });
        let progress = receive.recv_timeout(Duration::from_secs(10));
        // Release and join even if an incorrect blocking lock caused a timeout.
        drop(retained);
        worker.join().unwrap();
        let (result, timings) =
            progress.expect("nonce admission must not wait for the retained connection mutex");
        result.unwrap();
        assert_eq!(
            serde_json::to_value(timings).unwrap()["nonce_path"],
            "fallback"
        );
        assert!(matches!(
            server.consume_nonce(credential, "fallback", 1120, 1000),
            Err(ServiceError::Unauthorized(_))
        ));
    }
}
