//! Local attachment command execution, filled by lane C2.
use crate::{
    cli::{AttachmentCommand, Cli},
    error::AppError,
};

/// C2 enables this only when the local commands no longer return the stub error.
const LOCAL_IMPLEMENTED: bool = false;

/// The server must wait for D independently of local command availability.
#[derive(Clone, Copy, Debug)]
pub enum AttachmentBackend {
    Local,
    Remote,
}

/// Single advertisement source for viewer operations and attachments-v1.
/// C2 owns the local switch here; D owns the remote switch in frame.rs.
pub fn viewer_operations(backend: AttachmentBackend) -> &'static [&'static str] {
    let implemented = match backend {
        AttachmentBackend::Local => LOCAL_IMPLEMENTED,
        AttachmentBackend::Remote => super::frame::REMOTE_IMPLEMENTED,
    };
    if implemented {
        &[
            "attachment-add",
            "attachment-get",
            "attachment-detach",
            "attachment-clipboard",
        ]
    } else {
        &[]
    }
}

/// Dispatch attachment commands, including project-free clipboard inspection.
pub fn execute(_cli: &Cli, _command: &AttachmentCommand) -> Result<(), AppError> {
    Err(AppError::usage("not implemented in this build"))
}
