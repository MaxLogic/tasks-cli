//! Fixture cleanup errors must fail tests instead of silently leaving open databases.
#![allow(dead_code)]

pub struct TempDir(Option<tempfile::TempDir>);

impl TempDir {
    pub fn new() -> Self {
        Self(Some(
            tempfile::tempdir().expect("isolated fixture directory"),
        ))
    }

    pub fn path(&self) -> &std::path::Path {
        self.0.as_ref().expect("live fixture directory").path()
    }
}

impl From<tempfile::TempDir> for TempDir {
    fn from(root: tempfile::TempDir) -> Self {
        Self(Some(root))
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        if let Some(root) = self.0.take() {
            let path = root.path().to_owned();
            if let Err(error) = root.close() {
                let message = format!("fixture cleanup failed for {}: {error}", path.display());
                if std::thread::panicking() {
                    eprintln!("{message}");
                } else {
                    panic!("{message}");
                }
            }
        }
    }
}
