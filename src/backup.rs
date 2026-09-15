use crate::error::AppError;
use crate::store::Store;
use std::path::Path;

pub fn create(store: &mut Store, destination: &Path) -> Result<u64, AppError> {
    store.backup(destination)
}
