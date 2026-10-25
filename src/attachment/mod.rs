pub mod envelope;
pub mod name;
pub mod sniff;

/// Attachment quotas. Byte quotas count exactly the quantities in design section 5.
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub payload_bytes: u64,
    pub original_bytes: u64,
    pub task_count: u32,
    pub task_stored_bytes: u64,
    pub project_stored_bytes: u64,
    pub batch_count: u32,
    pub batch_original_bytes: u64,
    pub name_bytes: usize,
}

impl Limits {
    pub const PRODUCTION: Self = Self {
        payload_bytes: 20 * 1024 * 1024,
        original_bytes: 256 * 1024 * 1024,
        task_count: 32,
        task_stored_bytes: 50 * 1024 * 1024,
        project_stored_bytes: 1024 * 1024 * 1024,
        batch_count: 32,
        batch_original_bytes: 512 * 1024 * 1024,
        name_bytes: 255,
    };
}

#[derive(Debug, thiserror::Error)]
pub enum AttachmentError {
    #[error("{measured} payload bytes after compression; the per-file limit is {limit} bytes")]
    TooLarge { measured: u64, limit: u64 },
    #[error("{measured} original bytes; the per-file decompressed limit is {limit} bytes")]
    OriginalTooLarge { measured: u64, limit: u64 },
    #[error("attachment integrity: {0}; restore damaged stored content from a verified backup")]
    Integrity(&'static str),
    #[error("attachment name: {0}")]
    Name(String),
    #[error("attachment codec: {0}")]
    Codec(String),
    #[error("attachment I/O: {0}")]
    Io(#[from] std::io::Error),
}

impl AttachmentError {
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::TooLarge { .. } | Self::OriginalTooLarge { .. } | Self::Name(_) => 2,
            Self::Integrity(_) | Self::Codec(_) | Self::Io(_) => 6,
        }
    }

    pub fn code(&self) -> &'static str {
        match self {
            Self::TooLarge { .. } => "attachment_too_large",
            Self::OriginalTooLarge { .. } => "attachment_original_too_large",
            Self::Integrity(_) => "attachment_integrity",
            Self::Name(_) => "validation",
            Self::Codec(_) | Self::Io(_) => "io",
        }
    }
}

pub type Result<T> = std::result::Result<T, AttachmentError>;
