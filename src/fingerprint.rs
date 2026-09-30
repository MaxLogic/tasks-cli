//! Shared file-fingerprint rule for the project-key cache
//! (`<data-root>/project-keys.json`, [`crate::keys`]) and the viewer's
//! project-statistics cache (`<data-root>/viewer-cache.sqlite3`,
//! [`crate::viewer`]). Both caches decide whether a cached value may be
//! reused for one database by comparing this fingerprint, computed the same
//! way for both callers: identity, size and modification time of the
//! database file and of a non-empty WAL or rollback journal (an empty WAL is
//! not counted, because a reader may create one without changing any data).
//!
//! Both callers also honor the same settle window: a file modified within
//! [`RACY_WINDOW`] of the check is read but must not be cached, because some
//! filesystems (FAT/exFAT) keep modification times to a 2-second
//! granularity, so a same-size change made within that window could still
//! produce an unchanged fingerprint.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// How long after its last modification a file's fingerprint may be treated
/// as stable enough to cache. An unknown modification time is never settled.
pub const RACY_WINDOW: Duration = Duration::from_secs(2);

/// The database and its WAL and rollback journal, with their metadata when
/// they count: the database always, a sidecar only when non-empty.
fn sidecar_files(db_path: &Path) -> Vec<(PathBuf, Option<fs::Metadata>)> {
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

/// Best-effort file identity, stable across a rename but not a delete and
/// recreate.
pub fn file_identity(path: &Path) -> String {
    file_id::get_file_id(path)
        .map(|id| format!("{id:?}"))
        .unwrap_or_else(|_| "unavailable".to_string())
}

/// Identity, size and modification time of `db_path` and its sidecars
/// ([`sidecar_files`]), joined into one string. Two calls at different times
/// against an unchanged set of files produce equal strings; any change to
/// identity, size or modification time of a counted file changes the result.
pub fn fingerprint(db_path: &Path) -> String {
    sidecar_files(db_path)
        .into_iter()
        .map(|(path, meta)| match meta {
            Some(meta) => format!(
                "{}:{:?}:{}",
                file_identity(&path),
                meta.modified().ok(),
                meta.len()
            ),
            None => "-".to_string(),
        })
        .collect::<Vec<_>>()
        .join("|")
}

/// True when every counted file ([`sidecar_files`]) was last modified at
/// least [`RACY_WINDOW`] before `now`; a file with no metadata (absent or
/// empty sidecar) never blocks settling, and an unreadable modification time
/// is never settled.
pub fn settled(db_path: &Path, now: SystemTime) -> bool {
    sidecar_files(db_path).iter().all(|(_, meta)| match meta {
        None => true,
        Some(meta) => meta
            .modified()
            .ok()
            .and_then(|modified| now.duration_since(modified).ok())
            .is_some_and(|age| age >= RACY_WINDOW),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::SystemTime;

    fn touch(path: &Path) {
        fs::write(path, b"x").unwrap();
    }

    #[test]
    fn same_database_yields_the_same_fingerprint_for_both_callers() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("TASKS.sqlite");
        touch(&db_path);
        let a = fingerprint(&db_path);
        let b = fingerprint(&db_path);
        assert_eq!(a, b, "two calls against an unchanged file must agree");
        assert!(!a.is_empty());
    }

    #[test]
    fn a_non_empty_wal_changes_the_fingerprint_but_an_empty_one_does_not() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("TASKS.sqlite");
        touch(&db_path);
        let base = fingerprint(&db_path);
        let wal_path = dir.path().join("TASKS.sqlite-wal");
        fs::write(&wal_path, b"").unwrap();
        assert_eq!(
            fingerprint(&db_path),
            base,
            "an empty WAL must not change the fingerprint"
        );
        fs::write(&wal_path, b"not empty").unwrap();
        assert_ne!(
            fingerprint(&db_path),
            base,
            "a non-empty WAL must change the fingerprint"
        );
    }

    #[test]
    fn a_just_modified_file_is_not_settled_but_an_aged_one_is() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("TASKS.sqlite");
        touch(&db_path);
        let now = SystemTime::now();
        assert!(
            !settled(&db_path, now),
            "a file modified just now must not be settled"
        );
        let old = now - Duration::from_secs(10);
        fs::OpenOptions::new()
            .write(true)
            .open(&db_path)
            .unwrap()
            .set_modified(old)
            .unwrap();
        assert!(settled(&db_path, now), "an aged file must be settled");
        assert!(
            !settled(&db_path, old + Duration::from_secs(1)),
            "a file within the racy window of `now` must not be settled"
        );
    }

    #[test]
    fn a_missing_database_is_settled_and_fingerprints_stably() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("missing.sqlite");
        assert!(settled(&db_path, SystemTime::now()));
        assert_eq!(fingerprint(&db_path), fingerprint(&db_path));
    }
}
