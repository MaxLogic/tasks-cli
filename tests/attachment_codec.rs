use liblzma::{
    stream::{Check, Filters, LzmaOptions, MtStreamBuilder, Stream, PRESET_EXTREME},
    write::XzEncoder,
};
use sha2::{Digest, Sha256};
use std::io::{self, Read, Write};
use tasks_cli::attachment::{
    envelope::{self, Codec},
    sniff::{self, Kind},
    AttachmentError, Limits,
};

#[test]
fn valid_empty_input_is_encodable() {
    let result = envelope::encode(&b""[..], "empty.log", &Limits::PRODUCTION);
    assert!(
        result.is_ok(),
        "valid empty attachment rejected: {result:?}"
    );
    let encoded = result.unwrap();
    assert_eq!(encoded.codec(), Codec::Raw);
    assert_eq!(encoded.bytes().len(), 52);
    assert_eq!(
        encoded.sha256(),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
}

fn random_bytes(len: usize) -> Vec<u8> {
    let mut state = 0x1234_5678_9abc_def0u64;
    (0..len)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state as u8
        })
        .collect()
}

fn frame(original: &[u8], codec: u8, payload: &[u8]) -> Vec<u8> {
    let mut bytes = b"TASKATT1".to_vec();
    bytes.extend_from_slice(&[1, codec, 0, 0]);
    bytes.extend_from_slice(&(original.len() as u64).to_le_bytes());
    bytes.extend_from_slice(&Sha256::digest(original));
    bytes.extend_from_slice(payload);
    bytes
}

fn xz(source: &[u8], dict_size: u32) -> Vec<u8> {
    let mut options = LzmaOptions::new_preset(1).unwrap();
    options.dict_size(dict_size);
    let mut filters = Filters::new();
    filters.lzma2(&options);
    let stream = Stream::new_stream_encoder(&filters, Check::Crc64).unwrap();
    let mut encoder = XzEncoder::new_stream(Vec::new(), stream);
    encoder.write_all(source).unwrap();
    encoder.finish().unwrap()
}

// Fixed contract parameters, independent of the production encoder constants.
fn policy_xz(source: &[u8], block_bytes: u64) -> Vec<u8> {
    let mut options = LzmaOptions::new_preset(9 | PRESET_EXTREME).unwrap();
    options.dict_size(8 * 1024 * 1024);
    let mut filters = Filters::new();
    filters.lzma2(&options);
    let stream = MtStreamBuilder::new()
        .filters(filters)
        .block_size(block_bytes)
        .check(Check::Crc64)
        .threads(1)
        .encoder()
        .unwrap();
    let mut encoder = XzEncoder::new_stream(Vec::new(), stream);
    encoder.write_all(source).unwrap();
    encoder.finish().unwrap()
}

fn multiblock_log() -> Vec<u8> {
    let mut source = b"INFO worker completed request with status 200\n".repeat(220_000);
    // Cross both the old and new block boundaries, including a partial tail.
    source.truncate(9 * 1024 * 1024 + 1);
    source
}

#[test]
fn encoder_uses_4mib_blocks_with_8mib_dictionary_and_preset_9e() {
    let source = multiblock_log();
    let expected = policy_xz(&source, 4 * 1024 * 1024);
    let encoded = round_trip(&source, "blocks.log");
    assert_eq!(encoded.codec(), Codec::Xz);
    assert_eq!(&encoded.bytes()[envelope::HEADER_BYTES..], expected);
}

#[test]
fn previous_8mib_block_envelope_still_decodes() {
    let source = multiblock_log();
    let payload = policy_xz(&source, 8 * 1024 * 1024);
    let bytes = frame(&source, 1, &payload);
    let mut decoded = Vec::new();
    let metadata =
        envelope::decode_to(&bytes, "legacy.log", &mut decoded, &Limits::PRODUCTION).unwrap();
    assert_eq!(metadata.codec, Codec::Xz);
    assert_eq!(metadata.original_size, source.len() as u64);
    assert_eq!(metadata.sha256, format!("{:x}", Sha256::digest(&source)));
    assert_eq!(decoded, source);
    envelope::validate(bytes, "legacy.log", &Limits::PRODUCTION).unwrap();
}

fn round_trip(bytes: &[u8], name: &str) -> envelope::ValidatedEnvelope {
    let encoded = envelope::encode(bytes, name, &Limits::PRODUCTION).unwrap();
    let mut decoded = Vec::new();
    let metadata =
        envelope::decode_to(encoded.bytes(), name, &mut decoded, &Limits::PRODUCTION).unwrap();
    assert_eq!(decoded, bytes, "{name}");
    assert_eq!(metadata.original_size, bytes.len() as u64);
    assert_eq!(metadata.sha256, format!("{:x}", Sha256::digest(bytes)));
    assert_eq!(
        &encoded.bytes()[..12],
        &[
            b'T',
            b'A',
            b'S',
            b'K',
            b'A',
            b'T',
            b'T',
            b'1',
            1,
            if encoded.codec() == Codec::Raw { 0 } else { 1 },
            0,
            0
        ]
    );
    encoded
}

#[test]
fn corpus_round_trips_and_raw_policy() {
    // A complete 1x1 RGBA PNG, rather than only a sniff signature.
    let png = [
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
        0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 11, 73, 68, 65, 84, 120, 156, 99, 96, 0, 2, 0, 0, 5, 0,
        1, 122, 94, 171, 63, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    ];
    let png = round_trip(&png, "pixel.png");
    assert_eq!(png.codec(), Codec::Raw);
    assert!(!png.compression_attempted());
    for (name, bytes) in [
        (
            "app.log",
            b"INFO worker completed request with status 200\n".repeat(4096),
        ),
        (
            "source.rs",
            b"fn main() { println!(\"hello\"); }\n".repeat(4096),
        ),
        (
            "data.json",
            b"{\"id\":123,\"status\":\"in-progress\",\"labels\":[\"test\"]}\n".repeat(4096),
        ),
    ] {
        let encoded = round_trip(&bytes, name);
        assert_eq!(encoded.codec(), Codec::Xz);
        assert!(encoded.compression_attempted());
        assert_eq!(&encoded.bytes()[52..58], b"\xfd7zXZ\0");
        assert_eq!(encoded.bytes()[59], 4, "xz CRC64 check ID");
    }
    for bits in [24u16, 32] {
        let mut bmp = vec![0u8; 54 + 256 * 256 * usize::from(bits / 8)];
        bmp[..2].copy_from_slice(b"BM");
        let len = bmp.len() as u32;
        bmp[2..6].copy_from_slice(&len.to_le_bytes());
        bmp[10..14].copy_from_slice(&54u32.to_le_bytes());
        bmp[14..18].copy_from_slice(&40u32.to_le_bytes());
        bmp[18..22].copy_from_slice(&256u32.to_le_bytes());
        bmp[22..26].copy_from_slice(&256u32.to_le_bytes());
        bmp[26..28].copy_from_slice(&1u16.to_le_bytes());
        bmp[28..30].copy_from_slice(&bits.to_le_bytes());
        for (i, b) in bmp[54..].iter_mut().enumerate() {
            *b = ((i / 256) % 256) as u8;
        }
        let encoded = round_trip(&bmp, "screenshot.bmp");
        assert_eq!(encoded.kind(), Kind::Image);
        assert_eq!(encoded.codec(), Codec::Xz);
    }
    for magic in [
        &b"\x89PNG\r\n\x1a\n"[..],
        &b"PK\x03\x04"[..],
        &b"\x1f\x8b"[..],
    ] {
        let mut bytes = magic.to_vec();
        bytes.extend_from_slice(&random_bytes(8192));
        let encoded = round_trip(&bytes, "compressed.bin");
        assert_eq!(encoded.codec(), Codec::Raw);
        assert!(!encoded.compression_attempted());
    }
    let encoded = round_trip(&random_bytes(1024 * 1024), "random.bin");
    assert_eq!(encoded.codec(), Codec::Raw);
    assert!(encoded.compression_attempted());
}

#[test]
fn l1_counts_payload_not_header_and_rechecks_existing_envelopes() {
    let bytes = random_bytes(Limits::PRODUCTION.payload_bytes as usize);
    let raw = frame(&bytes, 0, &bytes);
    let validated = envelope::validate(raw, "random.bin", &Limits::PRODUCTION).unwrap();
    assert_eq!(
        validated.bytes().len() as u64,
        Limits::PRODUCTION.payload_bytes + 52
    );
    let mut oversized = bytes.clone();
    oversized.push(1);
    assert!(matches!(
        envelope::validate(
            frame(&oversized, 0, &oversized),
            "random.bin",
            &Limits::PRODUCTION
        ),
        Err(AttachmentError::TooLarge {
            measured: 20_971_521,
            limit: 20_971_520
        })
    ));
    // Exercise client-side streaming enforcement without a costly incompressible xz attempt.
    let mut skipped = bytes;
    skipped[..8].copy_from_slice(b"\x89PNG\r\n\x1a\n");
    let encoded = envelope::encode(&skipped[..], "a.png", &Limits::PRODUCTION).unwrap();
    assert_eq!(encoded.codec(), Codec::Raw);
    skipped.push(1);
    assert!(matches!(
        envelope::encode(&skipped[..], "a.png", &Limits::PRODUCTION),
        Err(AttachmentError::TooLarge { .. })
    ));
}

#[test]
fn l1_overflow_at_encoder_finish_reports_compressed_bytes() {
    let limits = Limits {
        payload_bytes: 4096,
        ..Limits::PRODUCTION
    };
    let bytes = random_bytes(128 * 1024);
    let error = envelope::encode(&bytes[..], "random.bin", &limits).unwrap_err();
    assert!(
        matches!(
            error,
            AttachmentError::TooLarge {
                measured: 4097,
                limit: 4096
            }
        ),
        "{error:?}"
    );
}

struct ZeroSource {
    remaining: u64,
    read: u64,
}
impl Read for ZeroSource {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let count = (out.len() as u64).min(self.remaining) as usize;
        out[..count].fill(0);
        self.remaining -= count as u64;
        self.read += count as u64;
        Ok(count)
    }
}

#[test]
fn l2_streaming_boundary_stops_at_limit_plus_one() {
    let limits = Limits {
        original_bytes: 128 * 1024,
        payload_bytes: 1024,
        ..Limits::PRODUCTION
    };
    let encoded = envelope::encode(
        ZeroSource {
            remaining: limits.original_bytes,
            read: 0,
        },
        "zero.bin",
        &limits,
    )
    .unwrap();
    assert_eq!(encoded.original_size(), limits.original_bytes);
    assert_eq!(encoded.codec(), Codec::Xz);
    let mut source = ZeroSource {
        remaining: u64::MAX,
        read: 0,
    };
    let error = envelope::encode(&mut source, "zero.bin", &limits).unwrap_err();
    assert!(matches!(
        error,
        AttachmentError::OriginalTooLarge {
            measured: 131_073,
            limit: 131_072
        }
    ));
    assert_eq!(source.read, limits.original_bytes + 1);
    let mut oversized = encoded.into_bytes();
    oversized[12..20].copy_from_slice(&(limits.original_bytes + 1).to_le_bytes());
    assert!(matches!(
        envelope::validate(oversized, "zero.bin", &limits),
        Err(AttachmentError::OriginalTooLarge { .. })
    ));
}

#[test]
#[ignore = "slow production 256 MiB streaming boundary; coordinator batch gate"]
fn l2_real_256_mib_zero_stream() {
    let limits = Limits::PRODUCTION;
    let mut source = ZeroSource {
        remaining: limits.original_bytes,
        read: 0,
    };
    let encoded = envelope::encode(&mut source, "zero.bin", &limits).unwrap();
    assert_eq!(source.read, 268_435_456);
    assert_eq!(encoded.original_size(), 268_435_456);
    assert_eq!(encoded.codec(), Codec::Xz);
    let metadata = envelope::decode_to(encoded.bytes(), "zero.bin", io::sink(), &limits).unwrap();
    assert_eq!(metadata.original_size, limits.original_bytes);
}

#[test]
fn malformed_headers_hashes_and_raw_lengths_are_refused() {
    let raw = frame(b"abc", 0, b"abc");
    for (offset, expected) in [
        (0, "wrong magic"),
        (8, "unsupported version"),
        (9, "unknown codec"),
        (10, "nonzero reserved bytes"),
        (11, "nonzero reserved bytes"),
        (20, "SHA-256 mismatch"),
    ] {
        let mut bytes = raw.clone();
        bytes[offset] = if offset == 9 { 2 } else { bytes[offset] ^ 0xff };
        let err = envelope::validate(bytes, "a.txt", &Limits::PRODUCTION).unwrap_err();
        assert!(
            matches!(err, AttachmentError::Integrity(msg) if msg == expected),
            "offset {offset}: {err}"
        );
    }
    for length in [0, 1, 2, 4] {
        let mut bytes = raw.clone();
        bytes[12..20].copy_from_slice(&(length as u64).to_le_bytes());
        assert!(matches!(
            envelope::validate(bytes, "a.txt", &Limits::PRODUCTION),
            Err(AttachmentError::Integrity("raw length mismatch"))
        ));
    }
    for len in [0, 8, 20, 51] {
        assert!(matches!(
            envelope::validate(raw[..len].to_vec(), "a.txt", &Limits::PRODUCTION),
            Err(AttachmentError::Integrity("truncated header"))
        ));
    }
}

#[test]
fn header_only_preflight_does_not_decode_and_enforces_production_bounds() {
    // Valid declarations, deliberately not an xz stream and deliberately wrong hash.
    let mut bytes = frame(b"hello", 1, b"undecodable");
    bytes[20] ^= 1;
    let header = envelope::parse_header(&bytes).unwrap();
    assert_eq!(header.codec, Codec::Xz);
    assert_eq!(header.original_size, 5);
    assert_eq!(header.payload_len, 11);
    assert_eq!(&header.original_sha256[..], &bytes[20..52]);
    assert!(matches!(
        envelope::validate(bytes.clone(), "file", &Limits::PRODUCTION),
        Err(AttachmentError::Integrity(_))
    ));
    for len in [0, 8, 20, 51] {
        assert!(matches!(
            envelope::parse_header(&bytes[..len]),
            Err(AttachmentError::Integrity("truncated header"))
        ));
    }
    bytes[12..20].copy_from_slice(&(Limits::PRODUCTION.original_bytes + 1).to_le_bytes());
    let error = envelope::parse_header(&bytes).unwrap_err();
    assert_eq!(error.code(), "attachment_original_too_large");
    assert_eq!(error.exit_code(), 2);
    assert!(matches!(
        error,
        AttachmentError::OriginalTooLarge {
            measured: 268_435_457,
            limit: 268_435_456
        }
    ));
    bytes[12..20].copy_from_slice(&0u64.to_le_bytes());
    bytes.resize(52 + Limits::PRODUCTION.payload_bytes as usize + 1, 0);
    let error = envelope::parse_header(&bytes).unwrap_err();
    assert_eq!(error.code(), "attachment_too_large");
    assert_eq!(error.exit_code(), 2);
    assert!(matches!(
        error,
        AttachmentError::TooLarge {
            measured: 20_971_521,
            limit: 20_971_520
        }
    ));
}

#[test]
fn validator_accepts_raw_compressible_content_regardless_of_encoder_policy() {
    let original = b"this text compresses very well\n".repeat(10_000);
    let raw = frame(&original, 0, &original);
    let valid = envelope::validate(raw, "a.log", &Limits::PRODUCTION).unwrap();
    assert_eq!(valid.codec(), Codec::Raw);
    assert_eq!(valid.kind(), Kind::Text);
    assert_eq!(valid.original_size(), original.len() as u64);
    let encoded = envelope::encode(&original[..], "a.log", &Limits::PRODUCTION).unwrap();
    assert_eq!(encoded.codec(), Codec::Xz);
    assert_eq!(encoded.sha256(), valid.sha256());
}

#[test]
fn xz_bombs_trailing_concatenated_truncated_and_high_dictionary_are_refused() {
    let source = vec![0u8; 128 * 1024];
    let payload = xz(&source, 8 * 1024 * 1024);
    let valid = frame(&source, 1, &payload);
    envelope::validate(valid.clone(), "zero.bin", &Limits::PRODUCTION).unwrap();
    for (size, expected) in [
        (0u64, "output exceeds declared size"),
        (1, "output exceeds declared size"),
        (131_071, "output exceeds declared size"),
        (131_073, "decoded length mismatch"),
    ] {
        let mut bytes = valid.clone();
        bytes[12..20].copy_from_slice(&size.to_le_bytes());
        let mut output = Vec::new();
        let result = envelope::decode_to(&bytes, "zero.bin", &mut output, &Limits::PRODUCTION);
        assert!(
            matches!(result, Err(AttachmentError::Integrity(msg)) if msg == expected),
            "size={size}: {result:?}"
        );
        assert!(
            output.len() as u64 <= size,
            "oversized output escaped validator"
        );
    }
    for suffix in [&b"garbage"[..], &[0, 0, 0, 0][..], &payload[..]] {
        let mut bytes = valid.clone();
        bytes.extend_from_slice(suffix);
        assert!(matches!(
            envelope::validate(bytes, "zero.bin", &Limits::PRODUCTION),
            Err(AttachmentError::Integrity(
                "trailing bytes or concatenated xz streams"
            ))
        ));
    }
    for cut in [1, 12, payload.len() / 2] {
        let mut bytes = valid.clone();
        bytes.truncate(bytes.len() - cut);
        assert!(matches!(
            envelope::validate(bytes, "zero.bin", &Limits::PRODUCTION),
            Err(AttachmentError::Integrity(_))
        ));
    }
    let large_dict = frame(&source, 1, &xz(&source, 64 * 1024 * 1024));
    assert!(matches!(
        envelope::validate(large_dict, "zero.bin", &Limits::PRODUCTION),
        Err(AttachmentError::Integrity(
            "xz decoder memory limit exceeded"
        ))
    ));
    let mut corrupt = valid;
    corrupt[20] ^= 1;
    assert!(matches!(
        envelope::validate(corrupt, "zero.bin", &Limits::PRODUCTION),
        Err(AttachmentError::Integrity("SHA-256 mismatch"))
    ));
}

#[test]
fn io_errors_propagate() {
    struct FailingReader;
    impl Read for FailingReader {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            Err(io::Error::other("source failed"))
        }
    }
    assert!(matches!(
        envelope::encode(FailingReader, "file", &Limits::PRODUCTION),
        Err(AttachmentError::Io(_))
    ));
    struct FailingWriter;
    impl Write for FailingWriter {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(io::Error::other("destination failed"))
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    assert!(matches!(
        envelope::decode_to(
            &frame(b"abc", 0, b"abc"),
            "file",
            FailingWriter,
            &Limits::PRODUCTION
        ),
        Err(AttachmentError::Io(_))
    ));
}

#[test]
fn opened_regular_file_is_checked_and_encoded() {
    let root = tempfile::Builder::new()
        .prefix("attachment-file-")
        .tempdir_in(std::env::temp_dir())
        .unwrap();
    let path = root.path().join("source.txt");
    std::fs::write(&path, b"regular source").unwrap();
    let encoded = envelope::encode_file(&path, "source.txt", &Limits::PRODUCTION).unwrap();
    assert_eq!(encoded.original_size(), 14);
    assert!(matches!(
        envelope::encode_file(root.path(), "dir", &Limits::PRODUCTION),
        Err(AttachmentError::Io(_))
    ));
    let lowered = Limits {
        original_bytes: 13,
        ..Limits::PRODUCTION
    };
    assert!(matches!(
        envelope::encode_file(&path, "source.txt", &lowered),
        Err(AttachmentError::OriginalTooLarge {
            measured: 14,
            limit: 13
        })
    ));
}

#[test]
fn sniff_magic_table() {
    for (bytes, name, kind, mime, skip) in [
        (
            &b"\x89PNG\r\n\x1a\n"[..],
            "a",
            Kind::Image,
            "image/png",
            true,
        ),
        (&b"\xff\xd8\xff"[..], "a", Kind::Image, "image/jpeg", true),
        (&b"GIF87a"[..], "a", Kind::Image, "image/gif", true),
        (&b"GIF89a"[..], "a", Kind::Image, "image/gif", true),
        (&b"RIFF0000WEBP"[..], "a", Kind::Image, "image/webp", true),
        (&b"BM"[..], "a", Kind::Image, "image/bmp", false),
        (&b"\0\0\x01\0"[..], "a", Kind::Image, "image/x-icon", false),
        (&b"II*\0"[..], "a", Kind::Image, "image/tiff", false),
        (&b"MM\0*"[..], "a", Kind::Image, "image/tiff", false),
        (&b"II+\0"[..], "a", Kind::Image, "image/tiff", false),
        (
            &b"\0\0\0\x18ftypavif\0\0\0\0mif1avif"[..],
            "a",
            Kind::Image,
            "image/avif",
            true,
        ),
        (
            &b"\0\0\0\x18ftypheic\0\0\0\0mif1heic"[..],
            "a",
            Kind::Image,
            "image/heic",
            true,
        ),
        (
            &b"PK\x03\x04"[..],
            "a.zip",
            Kind::Binary,
            "application/zip",
            true,
        ),
        (
            &b"PK\x05\x06"[..],
            "a.jar",
            Kind::Binary,
            "application/java-archive",
            true,
        ),
        (
            &b"PK\x03\x04"[..],
            "a.docx",
            Kind::Binary,
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            true,
        ),
        (
            &b"PK\x03\x04"[..],
            "a.apk",
            Kind::Binary,
            "application/vnd.android.package-archive",
            true,
        ),
        (
            &b"\x1f\x8b"[..],
            "a",
            Kind::Binary,
            "application/gzip",
            true,
        ),
        (&b"BZh"[..], "a", Kind::Binary, "application/x-bzip2", true),
        (
            &b"\xfd7zXZ\0"[..],
            "a",
            Kind::Binary,
            "application/x-xz",
            true,
        ),
        (
            &b"7z\xbc\xaf\x27\x1c"[..],
            "a",
            Kind::Binary,
            "application/x-7z-compressed",
            true,
        ),
        (
            &b"\x28\xb5\x2f\xfd"[..],
            "a",
            Kind::Binary,
            "application/zstd",
            true,
        ),
        (
            &b"Rar!\x1a\x07\0"[..],
            "a",
            Kind::Binary,
            "application/vnd.rar",
            true,
        ),
        (
            &b"Rar!\x1a\x07\x01\0"[..],
            "a",
            Kind::Binary,
            "application/vnd.rar",
            true,
        ),
        (
            &b"\x04\x22\x4d\x18"[..],
            "a",
            Kind::Binary,
            "application/x-lz4",
            true,
        ),
        (&b"ID3"[..], "a", Kind::Binary, "audio/mpeg", true),
        (&b"\xff\xfb\x90"[..], "a", Kind::Binary, "audio/mpeg", true),
        (
            &b"\0\0\0\x14ftypisom\0\0\0\0mp42"[..],
            "a",
            Kind::Binary,
            "video/mp4",
            true,
        ),
        (
            &b"\0\0\0\x14ftypqt  \0\0\0\0qt  "[..],
            "a",
            Kind::Binary,
            "video/quicktime",
            true,
        ),
        (&b"OggS"[..], "a", Kind::Binary, "application/ogg", true),
        (&b"fLaC"[..], "a", Kind::Binary, "audio/flac", true),
        (
            &b"\x1a\x45\xdf\xa3"[..],
            "a.webm",
            Kind::Binary,
            "video/webm",
            true,
        ),
        (
            &b"\x1a\x45\xdf\xa3"[..],
            "a.mkv",
            Kind::Binary,
            "video/x-matroska",
            true,
        ),
        (&b"%PDF-"[..], "a", Kind::Binary, "application/pdf", false),
        (
            &b"SQLite format 3\0"[..],
            "a",
            Kind::Binary,
            "application/vnd.sqlite3",
            false,
        ),
        (
            &b"MZ"[..],
            "a",
            Kind::Binary,
            "application/vnd.microsoft.portable-executable",
            false,
        ),
        (
            &b"\x7fELF"[..],
            "a",
            Kind::Binary,
            "application/x-elf",
            false,
        ),
        (&b"\0asm"[..], "a", Kind::Binary, "application/wasm", false),
        (&b"RIFF0000WAVE"[..], "a", Kind::Binary, "audio/wav", false),
    ] {
        let got = sniff::sniff(bytes, name);
        assert_eq!(
            (got.kind, got.media_type, got.skip_compression),
            (kind, mime, skip),
            "{bytes:?} {name}"
        );
    }
}

#[test]
#[ignore = "release workstation feasibility probe; run explicitly with --release --ignored --nocapture"]
fn release_log_probe() {
    let evidence_root = std::path::PathBuf::from(
        std::env::var_os("TASKS_ATTACHMENT_PROBE_EVIDENCE_ROOT").expect(
            "set TASKS_ATTACHMENT_PROBE_EVIDENCE_ROOT to the existing absolute evidence directory",
        ),
    );
    assert!(evidence_root.is_absolute() && evidence_root.is_dir());
    let timing_path = evidence_root.join(format!("codec-probe-{}.jsonl", uuid::Uuid::new_v4()));
    let mut timing_file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&timing_path)
        .unwrap();
    let mut log = Vec::with_capacity(16 * 1024 * 1024);
    let mut id = 0u64;
    while log.len() < 16 * 1024 * 1024 {
        // Distinct deterministic request IDs plus repeated log/backtrace structure.
        let line = format!("2026-10-25T12:34:56.123Z INFO request={:016x}-{:016x} route=/api/tasks status=200 elapsed=12ms\n  0: tasks::store::apply\n  1: tasks::main\n", id.wrapping_mul(0x9e3779b97f4a7c15), id.wrapping_mul(0x517cc1b727220a95));
        log.extend_from_slice(line.as_bytes());
        id += 1;
    }
    log.truncate(16 * 1024 * 1024);
    let mut samples = Vec::new();
    for sample in 0..4 {
        let start = std::time::Instant::now();
        let encoded = envelope::encode(&log[..], "app.log", &Limits::PRODUCTION).unwrap();
        let encode_seconds = start.elapsed().as_secs_f64();
        let mut out = Vec::with_capacity(log.len());
        let start = std::time::Instant::now();
        envelope::decode_to(encoded.bytes(), "app.log", &mut out, &Limits::PRODUCTION).unwrap();
        let decode_seconds = start.elapsed().as_secs_f64();
        assert_eq!(out, log);
        assert_eq!(encoded.codec(), Codec::Xz);
        println!("sample={sample} warmup={} original={} stored={} encode_s={encode_seconds:.6} decode_s={decode_seconds:.6}", sample == 0, log.len(), encoded.bytes().len());
        writeln!(timing_file, "{}", serde_json::json!({"sample":sample,"warmup":sample==0,"original":log.len(),"stored":encoded.bytes().len(),"encode_seconds":encode_seconds,"decode_seconds":decode_seconds})).unwrap();
        if sample > 0 {
            samples.push((encode_seconds, decode_seconds));
        }
    }
    let mut encodes: Vec<f64> = samples.iter().map(|s| s.0).collect();
    let mut decodes: Vec<f64> = samples.iter().map(|s| s.1).collect();
    encodes.sort_by(f64::total_cmp);
    decodes.sort_by(f64::total_cmp);
    println!("warm median_encode_s={:.6} median_decode_s={:.6} max_encode_s={:.6} max_decode_s={:.6}; proposed limits 8s/0.5s; codec timings exclude process startup, input generation and output comparison", encodes[1], decodes[1], encodes[2], decodes[2]);
    writeln!(timing_file, "{}", serde_json::json!({"summary":true,"median_encode_seconds":encodes[1],"median_decode_seconds":decodes[1],"max_encode_seconds":encodes[2],"max_decode_seconds":decodes[2],"thresholds_enforced":false,"timing_boundary":"codec API; excludes process startup, input generation and output comparison"})).unwrap();
    timing_file.flush().unwrap();
    println!("timings_path={}", timing_path.display());
}
