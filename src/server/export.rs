use crate::{
    remote::export::{ExportFrame, CHUNK_BYTES},
    store::Store,
    AppError,
};
use axum::body::Bytes;
use base64::{engine::general_purpose::STANDARD, Engine};
use http_body_util::channel::Sender;
use sha2::{Digest, Sha256};
use std::{
    io::Write,
    sync::Arc,
    time::{Duration, Instant},
};

pub(crate) struct ExportWriter {
    sender: Sender<Bytes, std::io::Error>,
    runtime: tokio::runtime::Handle,
    started: Instant,
    digest: Sha256,
    count: u64,
    permit: Arc<tokio::sync::OwnedSemaphorePermit>,
}
struct FrameBytes {
    bytes: Vec<u8>,
    _permit: Arc<tokio::sync::OwnedSemaphorePermit>,
}
impl AsRef<[u8]> for FrameBytes {
    fn as_ref(&self) -> &[u8] {
        &self.bytes
    }
}
impl ExportWriter {
    pub fn new(
        sender: Sender<Bytes, std::io::Error>,
        permit: tokio::sync::OwnedSemaphorePermit,
    ) -> Self {
        Self {
            sender,
            runtime: tokio::runtime::Handle::current(),
            started: Instant::now(),
            digest: Sha256::new(),
            count: 0,
            permit: Arc::new(permit),
        }
    }
    fn send(&mut self, frame: ExportFrame) -> std::io::Result<()> {
        let mut bytes = serde_json::to_vec(&frame).map_err(std::io::Error::other)?;
        bytes.push(b'\n');
        let remaining = Duration::from_secs(300)
            .saturating_sub(self.started.elapsed())
            .min(Duration::from_secs(15));
        self.runtime
            .block_on(async {
                tokio::time::timeout(
                    remaining,
                    self.sender.send_data(Bytes::from_owner(FrameBytes {
                        bytes,
                        _permit: self.permit.clone(),
                    })),
                )
                .await
            })
            .map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "export stream deadline exceeded",
                )
            })?
            .map_err(|_| {
                std::io::Error::new(std::io::ErrorKind::BrokenPipe, "export client disconnected")
            })
    }
    pub fn run(mut self, mut store: Store) -> Result<(), AppError> {
        let result = (|| {
            self.send(ExportFrame::Begin {
                protocol_version: 1,
                project_id: store.project_id,
            })?;
            let task_count = store.write_markdown(&mut self)?;
            let sha256 = format!("{:x}", self.digest.clone().finalize());
            self.send(ExportFrame::End {
                task_count: task_count as u64,
                byte_count: self.count,
                sha256,
            })?;
            Ok(())
        })();
        if result.is_err() {
            self.sender
                .abort(std::io::Error::other("export stream did not complete"));
        }
        result
    }
}
impl Write for ExportWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        for chunk in bytes.chunks(CHUNK_BYTES) {
            self.send(ExportFrame::Chunk {
                data: STANDARD.encode(chunk),
            })?;
            self.digest.update(chunk);
            self.count = self
                .count
                .checked_add(chunk.len() as u64)
                .ok_or_else(|| std::io::Error::other("export byte count exceeds its range"))?;
        }
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn queued_terminal_frames_retain_admission_after_the_producer_finishes() {
        let semaphore = Arc::new(tokio::sync::Semaphore::new(1));
        let permit = semaphore.clone().try_acquire_owned().unwrap();
        let (sender, body) = http_body_util::channel::Channel::<Bytes, std::io::Error>::new(2);
        tokio::task::spawn_blocking(move || {
            let mut writer = ExportWriter::new(sender, permit);
            writer
                .send(ExportFrame::Begin {
                    protocol_version: 1,
                    project_id: uuid::Uuid::new_v4(),
                })
                .unwrap();
            writer
                .send(ExportFrame::End {
                    task_count: 0,
                    byte_count: 0,
                    sha256: format!("{:x}", Sha256::digest([])),
                })
                .unwrap();
        })
        .await
        .unwrap();
        assert_eq!(semaphore.available_permits(), 0);
        drop(body);
        assert_eq!(semaphore.available_permits(), 1);
    }
}
