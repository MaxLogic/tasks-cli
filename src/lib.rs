pub mod attribution;
pub mod backup;
pub mod bulk;
pub mod cli;
pub mod error;
pub mod fingerprint;
pub mod interop;
pub mod keys;
pub mod markdown;
pub mod model;
pub mod output;
pub mod private_fs;
pub mod problems;
pub mod registry;
#[cfg(feature = "remote")]
pub mod remote;
#[cfg(feature = "server")]
pub mod server;
pub mod storage;
pub mod store;

pub use error::AppError;

pub mod full_text;
pub mod labels;

pub mod clipboard;
pub mod enrich;
pub mod viewer;
