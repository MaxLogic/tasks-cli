//! A complete export uses bounded JSON frames instead of one giant JSON string.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::{BufRead, Read, Write};
use thiserror::Error;
use uuid::Uuid;

pub const CHUNK_BYTES: usize = 16 * 1024;
pub const MAX_FRAME_BYTES: usize = 32 * 1024;

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ExportFrame {
    Begin {
        protocol_version: u32,
        project_id: Uuid,
    },
    Chunk {
        data: String,
    },
    End {
        task_count: u64,
        byte_count: u64,
        sha256: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(project: Uuid, bytes: &[u8]) -> Vec<u8> {
        let frames = [
            ExportFrame::Begin {
                protocol_version: 1,
                project_id: project,
            },
            ExportFrame::Chunk {
                data: STANDARD.encode(bytes),
            },
            ExportFrame::End {
                task_count: 3,
                byte_count: bytes.len() as u64,
                sha256: format!("{:x}", Sha256::digest(bytes)),
            },
        ];
        frames
            .into_iter()
            .flat_map(|frame| {
                let mut line = serde_json::to_vec(&frame).unwrap();
                line.push(b'\n');
                line
            })
            .collect()
    }

    #[test]
    fn complete_stream_checks_identity_count_digest_and_terminal_frame() {
        let project = Uuid::new_v4();
        let bytes = "complete Ω\r\n".as_bytes();
        let mut output = Vec::new();
        let summary =
            consume(&mut stream(project, bytes).as_slice(), &mut output, project).unwrap();
        assert_eq!(output, bytes);
        assert_eq!(summary.task_count, 3);
        assert_eq!(summary.byte_count, bytes.len() as u64);
    }

    #[test]
    fn truncation_tampering_wrong_project_and_oversized_frames_are_refused() {
        let project = Uuid::new_v4();
        let good = stream(project, b"exact");
        let mut cases = vec![
            good[..good.len() - 1].to_vec(),
            good[..good.iter().position(|b| *b == b'\n').unwrap() + 1].to_vec(),
            stream(Uuid::new_v4(), b"exact"),
        ];
        let mut trailing = good.clone();
        trailing.extend_from_slice(b"{}\n");
        cases.push(trailing);
        cases.push(
            String::from_utf8(good.clone())
                .unwrap()
                .replace("\"byte_count\":5", "\"byte_count\":6")
                .into_bytes(),
        );
        cases.push(
            String::from_utf8(good)
                .unwrap()
                .replace(&STANDARD.encode(b"exact"), &STANDARD.encode(b"other"))
                .into_bytes(),
        );
        cases.push(vec![b'x'; MAX_FRAME_BYTES + 1]);
        cases.push(stream(project, &vec![b'x'; CHUNK_BYTES + 1]));
        for invalid in cases {
            assert!(consume(&mut invalid.as_slice(), &mut Vec::new(), project).is_err());
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct ExportSummary {
    pub task_count: u64,
    pub byte_count: u64,
    pub sha256: String,
}

#[derive(Debug, Error)]
pub enum ExportError {
    #[error("export is incomplete or invalid; no output should be published")]
    Invalid,
    #[error("export transfer or output write failed; no output should be published")]
    Io,
}

fn frame(reader: &mut impl BufRead) -> Result<Option<ExportFrame>, ExportError> {
    let mut bytes = Vec::new();
    reader
        .take((MAX_FRAME_BYTES + 1) as u64)
        .read_until(b'\n', &mut bytes)
        .map_err(|_| ExportError::Io)?;
    if bytes.is_empty() {
        return Ok(None);
    }
    if bytes.len() > MAX_FRAME_BYTES || !bytes.ends_with(b"\n") {
        return Err(ExportError::Invalid);
    }
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|_| ExportError::Invalid)
}

pub fn consume(
    reader: &mut impl BufRead,
    out: &mut impl Write,
    project: Uuid,
) -> Result<ExportSummary, ExportError> {
    match frame(reader)? {
        Some(ExportFrame::Begin {
            protocol_version: 1,
            project_id,
        }) if project_id == project => (),
        _ => return Err(ExportError::Invalid),
    }
    let mut digest = Sha256::new();
    let mut count = 0u64;
    loop {
        match frame(reader)? {
            Some(ExportFrame::Chunk { data }) => {
                let bytes = STANDARD.decode(data).map_err(|_| ExportError::Invalid)?;
                if bytes.is_empty() || bytes.len() > CHUNK_BYTES {
                    return Err(ExportError::Invalid);
                }
                count = count
                    .checked_add(bytes.len() as u64)
                    .ok_or(ExportError::Invalid)?;
                digest.update(&bytes);
                out.write_all(&bytes).map_err(|_| ExportError::Io)?;
            }
            Some(ExportFrame::End {
                task_count,
                byte_count,
                sha256,
            }) => {
                let actual = format!("{:x}", digest.finalize());
                if byte_count != count || sha256 != actual || frame(reader)?.is_some() {
                    return Err(ExportError::Invalid);
                }
                return Ok(ExportSummary {
                    task_count,
                    byte_count,
                    sha256,
                });
            }
            _ => return Err(ExportError::Invalid),
        }
    }
}
