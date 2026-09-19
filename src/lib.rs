pub mod backup;
pub mod bulk;
pub mod cli;
pub mod error;
pub mod interop;
pub mod markdown;
pub mod model;
pub mod output;
pub mod problems;
pub mod registry;
pub mod storage;
pub mod store;

pub use error::AppError;

pub mod full_text;
pub mod labels;

pub mod clipboard;
pub mod enrich;
