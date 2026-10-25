//! Bounded streaming envelopes. Constructors verify original size and SHA-256.
use super::{name, sniff, AttachmentError, Limits, Result};
use liblzma::stream::{
    Action, Check, Filters, LzmaOptions, MtStreamBuilder, Status, Stream, PRESET_EXTREME,
};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{Read, Write},
    path::Path,
};

pub const HEADER_BYTES: usize = 52;
pub const DECODER_MEMLIMIT: u64 = 16 * 1024 * 1024;
const BLOCK_BYTES: u64 = 8 * 1024 * 1024;
const ENCODER_MEMLIMIT: u64 = 1024 * 1024 * 1024;
const BUFFER_BYTES: usize = 64 * 1024;

#[cfg(test)]
thread_local! {
    static ENCODER_INVOCATIONS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Codec {
    Raw,
    Xz,
}

/// Untrusted declarations for batch preflight. This value never admits a blob to
/// the store: only `ValidatedEnvelope` proves decoded bytes and their identity.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EnvelopeHeader {
    pub codec: Codec,
    pub original_size: u64,
    pub original_sha256: [u8; 32],
    pub payload_len: u64,
}

/// Inspect only the fixed header and total slice length; never decode payload.
pub fn parse_header(bytes: &[u8]) -> Result<EnvelopeHeader> {
    if bytes.len() < HEADER_BYTES {
        return Err(AttachmentError::Integrity("truncated header"));
    }
    if &bytes[..8] != b"TASKATT1" {
        return Err(AttachmentError::Integrity("wrong magic"));
    }
    if bytes[8] != 1 {
        return Err(AttachmentError::Integrity("unsupported version"));
    }
    let codec = match bytes[9] {
        0 => Codec::Raw,
        1 => Codec::Xz,
        _ => return Err(AttachmentError::Integrity("unknown codec")),
    };
    if bytes[10..12] != [0, 0] {
        return Err(AttachmentError::Integrity("nonzero reserved bytes"));
    }
    let mut size_bytes = [0u8; 8];
    size_bytes.copy_from_slice(&bytes[12..20]);
    let mut original_sha256 = [0u8; 32];
    original_sha256.copy_from_slice(&bytes[20..52]);
    let header = EnvelopeHeader {
        codec,
        original_size: u64::from_le_bytes(size_bytes),
        original_sha256,
        payload_len: (bytes.len() - HEADER_BYTES) as u64,
    };
    check_header_limits(&header, &Limits::PRODUCTION)?;
    Ok(header)
}

fn check_header_limits(header: &EnvelopeHeader, limits: &Limits) -> Result<()> {
    check_original(header.original_size, limits)?;
    if header.payload_len > limits.payload_bytes {
        return Err(AttachmentError::TooLarge {
            measured: header.payload_len,
            limit: limits.payload_bytes,
        });
    }
    Ok(())
}

impl Codec {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Raw => "raw",
            Self::Xz => "xz",
        }
    }
}

/// Metadata recomputed from decoded bytes, never accepted from the caller.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Metadata {
    pub codec: Codec,
    pub original_size: u64,
    pub sha256: String,
    pub kind: sniff::Kind,
    pub media_type: &'static str,
}

/// Only `encode` and `validate` can construct this store-admissible value.
#[derive(Debug)]
pub struct ValidatedEnvelope {
    bytes: Vec<u8>,
    metadata: Metadata,
    compression_attempted: bool,
}

impl ValidatedEnvelope {
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
    pub fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }
    pub fn metadata(&self) -> &Metadata {
        &self.metadata
    }
    pub fn codec(&self) -> Codec {
        self.metadata.codec
    }
    pub fn original_size(&self) -> u64 {
        self.metadata.original_size
    }
    pub fn sha256(&self) -> &str {
        &self.metadata.sha256
    }
    pub fn kind(&self) -> sniff::Kind {
        self.metadata.kind
    }
    pub fn media_type(&self) -> &'static str {
        self.metadata.media_type
    }
    /// Encoding diagnostic. Validation of an existing envelope reports false.
    pub fn compression_attempted(&self) -> bool {
        self.compression_attempted
    }
}

/// Check the opened object so a path precheck cannot admit a non-file.
pub fn encode_file(path: &Path, display_name: &str, limits: &Limits) -> Result<ValidatedEnvelope> {
    let file = File::open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(AttachmentError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "attachment source must be a regular file",
        )));
    }
    check_original(metadata.len(), limits)?;
    encode(file, display_name, limits)
}

/// Read the source once, retaining at most L1 raw bytes and a bounded xz payload.
pub fn encode(source: impl Read, display_name: &str, limits: &Limits) -> Result<ValidatedEnvelope> {
    let threads = std::thread::available_parallelism().map_or(1, |n| n.get().min(8) as u32);
    encode_with_threads(source, display_name, limits, threads)
}

fn encode_with_threads(
    mut source: impl Read,
    display_name: &str,
    limits: &Limits,
    threads: u32,
) -> Result<ValidatedEnvelope> {
    name::validate(display_name, limits)?;
    let mut prefix = Vec::new();
    source
        .by_ref()
        .take((sniff::PREFIX_BYTES as u64).min(limits.original_bytes.saturating_add(1)))
        .read_to_end(&mut prefix)?;
    check_original(prefix.len() as u64, limits)?;
    let classification = sniff::sniff(&prefix, display_name);
    let mut compressor = if !classification.skip_compression {
        Some(Encoder::new(threads)?)
    } else {
        None
    };
    let attempted = compressor.is_some();
    let mut raw = Some(Vec::new());
    let mut hash = Sha256::new();
    let mut size = 0u64;
    let mut chunk = prefix.as_slice();
    let mut buffer = [0u8; BUFFER_BYTES];
    loop {
        size += chunk.len() as u64;
        check_original(size, limits)?;
        hash.update(chunk);
        if size <= limits.payload_bytes {
            if let Some(raw) = &mut raw {
                raw.extend_from_slice(chunk);
            }
        } else {
            raw = None;
        }
        if let Some(encoder) = &mut compressor {
            if !encoder.feed(chunk, Action::Run, limits.payload_bytes)? {
                compressor = None;
            }
        }
        if raw.is_none() && compressor.is_none() {
            return Err(AttachmentError::TooLarge {
                measured: if attempted {
                    limits.payload_bytes.saturating_add(1)
                } else {
                    size
                },
                limit: limits.payload_bytes,
            });
        }
        let bound = limits
            .original_bytes
            .saturating_sub(size)
            .saturating_add(1)
            .min(BUFFER_BYTES as u64) as usize;
        let count = loop {
            match source.read(&mut buffer[..bound]) {
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                result => break result?,
            }
        };
        if count == 0 {
            break;
        }
        chunk = &buffer[..count];
    }
    if let Some(encoder) = &mut compressor {
        if !encoder.feed(&[], Action::Finish, limits.payload_bytes)? {
            if raw.is_none() {
                return Err(AttachmentError::TooLarge {
                    measured: limits.payload_bytes.saturating_add(1),
                    limit: limits.payload_bytes,
                });
            }
            compressor = None;
        }
    }
    let (codec, payload) = match compressor {
        Some(encoder) if (encoder.payload.len() as u64) * 100 <= size * 98 => {
            (Codec::Xz, encoder.payload)
        }
        _ => match raw {
            Some(raw) => (Codec::Raw, raw),
            None => {
                return Err(AttachmentError::TooLarge {
                    measured: size,
                    limit: limits.payload_bytes,
                })
            }
        },
    };
    let mut bytes = Vec::with_capacity(HEADER_BYTES + payload.len());
    bytes.extend_from_slice(b"TASKATT1");
    bytes.extend_from_slice(&[1, if codec == Codec::Raw { 0 } else { 1 }, 0, 0]);
    bytes.extend_from_slice(&size.to_le_bytes());
    bytes.extend_from_slice(&hash.finalize());
    bytes.extend_from_slice(&payload);
    let mut validated = validate(bytes, display_name, limits)?;
    validated.compression_attempted = attempted;
    Ok(validated)
}

fn check_original(size: u64, limits: &Limits) -> Result<()> {
    if size > limits.original_bytes {
        return Err(AttachmentError::OriginalTooLarge {
            measured: size,
            limit: limits.original_bytes,
        });
    }
    Ok(())
}

struct Encoder {
    stream: Stream,
    payload: Vec<u8>,
}

impl Encoder {
    fn new(threads: u32) -> Result<Self> {
        #[cfg(test)]
        ENCODER_INVOCATIONS.with(|count| count.set(count.get() + 1));
        let mut options = LzmaOptions::new_preset(9 | PRESET_EXTREME).map_err(codec_error)?;
        options.dict_size(BLOCK_BYTES as u32);
        let mut filters = Filters::new();
        filters.lzma2(&options);
        let mut builder = MtStreamBuilder::new();
        builder
            .filters(filters)
            .block_size(BLOCK_BYTES)
            .check(Check::Crc64)
            .memlimit_threading(ENCODER_MEMLIMIT)
            .threads(1);
        // liblzma ignores memlimit_threading during encoding; explicitly budget threads.
        let threads = select_threads(threads, |n| {
            builder.threads(n);
            builder.memusage()
        })?;
        builder.threads(threads);
        Ok(Self {
            stream: builder.encoder().map_err(codec_error)?,
            payload: Vec::new(),
        })
    }

    /// False means output crossed L1. The caller can still use its raw fallback.
    fn feed(&mut self, mut input: &[u8], action: Action, limit: u64) -> Result<bool> {
        let mut output = [0u8; BUFFER_BYTES];
        loop {
            let before_in = self.stream.total_in();
            let before_out = self.stream.total_out();
            let capacity = limit
                .saturating_sub(self.payload.len() as u64)
                .saturating_add(1)
                .min(BUFFER_BYTES as u64) as usize;
            let status = self
                .stream
                .process(input, &mut output[..capacity], action)
                .map_err(codec_error)?;
            let consumed = (self.stream.total_in() - before_in) as usize;
            let produced = (self.stream.total_out() - before_out) as usize;
            self.payload.extend_from_slice(&output[..produced]);
            if self.payload.len() as u64 > limit {
                return Ok(false);
            }
            input = &input[consumed..];
            if status == Status::StreamEnd || (input.is_empty() && matches!(action, Action::Run)) {
                return Ok(true);
            }
            if consumed == 0 && produced == 0 {
                return Err(AttachmentError::Codec("xz encoder made no progress".into()));
            }
        }
    }
}

fn select_threads(requested: u32, mut memusage: impl FnMut(u32) -> u64) -> Result<u32> {
    let mut threads = requested.clamp(1, 8);
    loop {
        if memusage(threads) <= ENCODER_MEMLIMIT {
            return Ok(threads);
        }
        if threads == 1 {
            return Err(AttachmentError::Codec(
                "single-thread encoder exceeds 1 GiB memory budget".into(),
            ));
        }
        threads -= 1;
    }
}

fn codec_error(error: liblzma::stream::Error) -> AttachmentError {
    AttachmentError::Codec(error.to_string())
}

pub fn validate(bytes: Vec<u8>, display_name: &str, limits: &Limits) -> Result<ValidatedEnvelope> {
    let header = parse_header(&bytes)?;
    check_header_limits(&header, limits)?;
    let metadata = decode_with_header(&bytes, display_name, std::io::sink(), limits, header)?;
    Ok(ValidatedEnvelope {
        bytes,
        metadata,
        compression_attempted: false,
    })
}

/// Stream into a private/staged destination. On error the writer may contain
/// partial output; callers must publish only after this returns success.
pub fn decode_to(
    bytes: &[u8],
    display_name: &str,
    destination: impl Write,
    limits: &Limits,
) -> Result<Metadata> {
    let header = parse_header(bytes)?;
    check_header_limits(&header, limits)?;
    decode_with_header(bytes, display_name, destination, limits, header)
}

fn decode_with_header(
    bytes: &[u8],
    display_name: &str,
    mut destination: impl Write,
    limits: &Limits,
    header: EnvelopeHeader,
) -> Result<Metadata> {
    name::validate(display_name, limits)?;
    let codec = header.codec;
    let original_size = header.original_size;
    let payload = &bytes[HEADER_BYTES..];
    let mut decoded = Decoded {
        destination: &mut destination,
        hash: Sha256::new(),
        prefix: Vec::new(),
        size: 0,
        declared: original_size,
    };
    match codec {
        Codec::Raw => {
            if payload.len() as u64 != original_size {
                return Err(AttachmentError::Integrity("raw length mismatch"));
            }
            decoded.accept(payload)?;
        }
        Codec::Xz => {
            let mut stream =
                Stream::new_stream_decoder(DECODER_MEMLIMIT, 0).map_err(codec_error)?;
            let mut input = payload;
            let mut output = [0u8; BUFFER_BYTES];
            loop {
                let before_in = stream.total_in();
                let before_out = stream.total_out();
                // One byte past the declaration suffices to detect a bomb.
                let capacity = original_size
                    .saturating_sub(decoded.size)
                    .saturating_add(1)
                    .min(BUFFER_BYTES as u64) as usize;
                let status = stream
                    .process(input, &mut output[..capacity], Action::Finish)
                    .map_err(|e| {
                        AttachmentError::Integrity(if e == liblzma::stream::Error::MemLimit {
                            "xz decoder memory limit exceeded"
                        } else {
                            "invalid xz payload"
                        })
                    })?;
                let consumed = (stream.total_in() - before_in) as usize;
                let produced = (stream.total_out() - before_out) as usize;
                decoded.accept(&output[..produced])?;
                input = &input[consumed..];
                if status == Status::StreamEnd {
                    if !input.is_empty() {
                        return Err(AttachmentError::Integrity(
                            "trailing bytes or concatenated xz streams",
                        ));
                    }
                    break;
                }
                if consumed == 0 && produced == 0 {
                    return Err(AttachmentError::Integrity("truncated xz payload"));
                }
            }
        }
    }
    if decoded.size != original_size {
        return Err(AttachmentError::Integrity("decoded length mismatch"));
    }
    let digest = decoded.hash.finalize();
    if digest[..] != header.original_sha256 {
        return Err(AttachmentError::Integrity("SHA-256 mismatch"));
    }
    let classification = sniff::sniff(&decoded.prefix, display_name);
    Ok(Metadata {
        codec,
        original_size,
        sha256: format!("{digest:x}"),
        kind: classification.kind,
        media_type: classification.media_type,
    })
}

struct Decoded<'a, W> {
    destination: &'a mut W,
    hash: Sha256,
    prefix: Vec<u8>,
    size: u64,
    declared: u64,
}

impl<W: Write> Decoded<'_, W> {
    fn accept(&mut self, chunk: &[u8]) -> Result<()> {
        self.size += chunk.len() as u64;
        if self.size > self.declared {
            return Err(AttachmentError::Integrity("output exceeds declared size"));
        }
        self.hash.update(chunk);
        let count = chunk.len().min(sniff::PREFIX_BYTES - self.prefix.len());
        self.prefix.extend_from_slice(&chunk[..count]);
        self.destination.write_all(chunk)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compressed_formats_skip_actual_encoder_invocation() {
        let before = ENCODER_INVOCATIONS.with(std::cell::Cell::get);
        for bytes in [
            &b"\x89PNG\r\n\x1a\n"[..],
            &b"PK\x03\x04"[..],
            &b"\x1f\x8b"[..],
        ] {
            let encoded = encode(bytes, "compressed.bin", &Limits::PRODUCTION).unwrap();
            assert_eq!(ENCODER_INVOCATIONS.with(std::cell::Cell::get), before);
            assert_eq!(encoded.codec(), Codec::Raw);
            assert!(!encoded.compression_attempted());
        }
        let encoded = encode(&b"ordinary text"[..], "text.txt", &Limits::PRODUCTION).unwrap();
        assert_eq!(ENCODER_INVOCATIONS.with(std::cell::Cell::get), before + 1);
        assert!(encoded.compression_attempted());
    }

    #[test]
    fn independent_blocks_are_identical_across_thread_counts() {
        let mut source = b"2026-10-25 INFO worker event completed normally\n".repeat(500_000);
        source.truncate(20 * 1024 * 1024);
        let one = encode_with_threads(&source[..], "log.txt", &Limits::PRODUCTION, 1).unwrap();
        let many = encode_with_threads(&source[..], "log.txt", &Limits::PRODUCTION, 8).unwrap();
        assert_eq!(one.bytes(), many.bytes());
        for envelope in [one, many] {
            let mut out = Vec::new();
            decode_to(envelope.bytes(), "log.txt", &mut out, &Limits::PRODUCTION).unwrap();
            assert_eq!(out, source);
        }
    }

    #[test]
    fn thread_budget_is_bounded_and_never_zero() {
        for requested in [0, 1, 2, 8, 100] {
            for per_thread in [1, 128 * 1024 * 1024, 300 * 1024 * 1024, ENCODER_MEMLIMIT] {
                let threads = select_threads(requested, |n| u64::from(n) * per_thread).unwrap();
                assert!((1..=8).contains(&threads));
                assert!(u64::from(threads) * per_thread <= ENCODER_MEMLIMIT);
                assert!(threads <= requested.clamp(1, 8));
            }
        }
        assert!(matches!(
            select_threads(8, |_| u64::MAX),
            Err(AttachmentError::Codec(_))
        ));
        assert_eq!(select_threads(8, |_| 1).unwrap(), 8);
        assert_eq!(
            select_threads(8, |n| u64::from(n) * 300 * 1024 * 1024).unwrap(),
            3
        );
    }
}
