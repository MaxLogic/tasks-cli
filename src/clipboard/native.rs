//! Shared Win32 capture policy. Tests inject bytes at the clipboard boundary.
use super::*;
use image::{
    codecs::{bmp::BmpDecoder, png::PngEncoder},
    ImageDecoder, ImageEncoder,
};
use std::io::{self, Seek, SeekFrom};

// No COM/OLE, apartment, window, or clipboard writes are needed for capture.
#[cfg(windows)]
#[allow(unsafe_code)] // Explicit owner exception; all raw handles/pointers stay here.
mod win32;

const MAX_BITMAP: u64 = 256 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Format {
    Files,
    Png,
    DibV5,
    Dib,
}

#[cfg(any(windows, test, feature = "test-hooks"))]
impl Format {
    #[cfg(feature = "test-hooks")]
    fn name(self) -> &'static str {
        match self {
            Self::Files => "CF_HDROP",
            Self::Png => "PNG",
            Self::DibV5 => "CF_DIBV5",
            Self::Dib => "CF_DIB",
        }
    }
    fn limit(self) -> u64 {
        match self {
            Self::Files => MAX_CLIPBOARD_LIST,
            Self::Png => MAX_CLIPBOARD_IMAGE,
            _ => MAX_BITMAP + MAX_CLIPBOARD_LIST,
        }
    }
}

fn select_format(formats: &[Format]) -> Option<Format> {
    [Format::Files, Format::Png, Format::DibV5, Format::Dib]
        .into_iter()
        .find(|format| formats.contains(format))
}

fn invalid(message: &str) -> ClipboardCaptureError {
    AppError::Interop(format!("native clipboard: {message}")).into()
}

/// A clipboard snapshot owns its lock until the callback has consumed the data.
/// PNG/DIB allocations are bounded before copying. File drops are counted in
/// place before their metadata cap, without allocating path strings for a large
/// batch. Consuming the source releases its guard before any slow processing.
#[cfg(any(windows, test, feature = "test-hooks"))]
trait Source {
    fn formats(&self) -> Result<Vec<Format>, ClipboardCaptureError>;
    fn with_data<T>(
        &self,
        format: Format,
        consume: impl FnOnce(&[u8]) -> Result<T, ClipboardCaptureError>,
    ) -> Result<T, ClipboardCaptureError>;
}

#[cfg(any(windows, test, feature = "test-hooks"))]
fn check_size(format: Format, size: u64) -> Result<(), ClipboardCaptureError> {
    if format == Format::Files || size <= format.limit() {
        return Ok(());
    }
    Err(ClipboardCaptureError::too_large(
        "attachment_too_large",
        size,
        format.limit(),
        if format == Format::Png {
            "bytes"
        } else {
            "bitmap_bytes"
        },
    ))
}

#[cfg(any(windows, test, feature = "test-hooks"))]
enum Snapshot {
    Files(Vec<PathBuf>),
    Png(Vec<u8>),
    Dib(Vec<u8>),
}

#[cfg(any(windows, feature = "test-hooks"))]
fn capture_source(source: impl Source) -> Result<ClipboardCapture, ClipboardCaptureError> {
    capture_source_with(source, finish_snapshot)
}

#[cfg(any(windows, test, feature = "test-hooks"))]
fn capture_source_with(
    source: impl Source,
    finish: impl FnOnce(Snapshot) -> Result<ClipboardCapture, ClipboardCaptureError>,
) -> Result<ClipboardCapture, ClipboardCaptureError> {
    let Some(format) = select_format(&source.formats()?) else {
        return Err(ClipboardCaptureError::empty());
    };
    let snapshot = source.with_data(format, |data| {
        Ok(match format {
            Format::Files => Snapshot::Files(parse_drop(data)?),
            Format::Png => Snapshot::Png(data.to_vec()),
            Format::DibV5 | Format::Dib => {
                dib_dimensions(data)?; // Before copying a large native bitmap.
                Snapshot::Dib(data.to_vec())
            }
        })
    })?;
    drop(source); // GlobalUnlock has run; CloseClipboard precedes metadata/codec work.
    finish(snapshot)
}

#[cfg(any(windows, test, feature = "test-hooks"))]
fn finish_snapshot(snapshot: Snapshot) -> Result<ClipboardCapture, ClipboardCaptureError> {
    let capture = match snapshot {
        Snapshot::Files(files) => inspect_drop(files.len() as u64, files)?,
        Snapshot::Png(bytes) => ClipboardCapture {
            image: Some(bytes),
            ..Default::default()
        },
        Snapshot::Dib(bytes) => ClipboardCapture {
            image: Some(dib_to_png(&bytes)?),
            ..Default::default()
        },
    };
    require_content(capture)
}

pub(super) fn capture() -> Result<ClipboardCapture, ClipboardCaptureError> {
    #[cfg(windows)]
    {
        win32::capture()
    }
    #[cfg(not(windows))]
    {
        Err(invalid(
            "Windows attachment capture must run through tasks.exe",
        ))
    }
}

/// Only retry OpenClipboard's sharing failure, never malformed data or arbitrary
/// API errors. Four attempts and three 50 ms sleeps match the former busy policy.
#[cfg(any(windows, test))]
fn open_with(
    mut open: impl FnMut() -> Result<(), u32>,
    mut sleep: impl FnMut(),
) -> Result<(), ClipboardCaptureError> {
    for attempt in 0..4 {
        match open() {
            Ok(()) => return Ok(()),
            Err(5) if attempt < 3 => sleep(), // ERROR_ACCESS_DENIED: clipboard is open elsewhere.
            Err(code) => return Err(invalid(&format!("OpenClipboard failed (Windows error {code}); clipboard unavailable or locked; retry"))),
        }
    }
    unreachable!()
}

#[cfg(feature = "test-hooks")]
pub(super) fn capture_fixture(dir: &Path) -> Result<ClipboardCapture, ClipboardCaptureError> {
    struct Fixture<'a>(&'a Path);
    impl Source for Fixture<'_> {
        fn formats(&self) -> Result<Vec<Format>, ClipboardCaptureError> {
            let names: Vec<String> = serde_json::from_slice(&read_limited(
                &self.0.join("formats.json"),
                MAX_CLIPBOARD_LIST,
            )?)
            .map_err(AppError::from)?;
            Ok([Format::Files, Format::Png, Format::DibV5, Format::Dib]
                .into_iter()
                .filter(|f| names.iter().any(|n| n == f.name()))
                .collect())
        }
        fn with_data<T>(
            &self,
            format: Format,
            consume: impl FnOnce(&[u8]) -> Result<T, ClipboardCaptureError>,
        ) -> Result<T, ClipboardCaptureError> {
            let path = self.0.join(format!("{}.bin", format.name()));
            let file = std::fs::File::open(&path)
                .map_err(|e| AppError::io_path("read clipboard source fixture", &path, e))?;
            let size = file.metadata()?.len();
            check_size(format, size)?;
            // Test payloads are owned files, not native borrowed allocations.
            // Permit large drops so they reach count-first validation, while
            // bounding fixture memory independently of the accepted 1 MiB list.
            let read_limit = if format == Format::Files {
                MAX_BITMAP + MAX_CLIPBOARD_LIST
            } else {
                format.limit()
            };
            if size > read_limit {
                return Err(invalid("source fixture exceeds its allocation bound"));
            }
            let mut bytes = Vec::new();
            file.take(read_limit + 1).read_to_end(&mut bytes)?;
            if bytes.len() as u64 > read_limit {
                return Err(invalid("source fixture exceeds its allocation bound"));
            }
            check_size(format, bytes.len() as u64)?;
            consume(&bytes)
        }
    }
    capture_source(Fixture(dir))
}

fn u32_at(data: &[u8], offset: usize) -> Result<u32, ClipboardCaptureError> {
    Ok(u32::from_le_bytes(
        data.get(offset..offset + 4)
            .ok_or_else(|| invalid("truncated DIB/file drop header"))?
            .try_into()
            .map_err(|_| invalid("truncated header"))?,
    ))
}

fn parse_drop(data: &[u8]) -> Result<Vec<PathBuf>, ClipboardCaptureError> {
    if data.len() < 20 {
        return Err(invalid("truncated DROPFILES header"));
    }
    let offset = u32_at(data, 0)? as usize;
    if offset < 20 {
        return Err(invalid("invalid DROPFILES offset"));
    }
    let wide = u32_at(data, 16)? != 0;
    let data = data
        .get(offset..)
        .ok_or_else(|| invalid("invalid DROPFILES offset"))?;
    if wide && !offset.is_multiple_of(2) {
        return Err(invalid("misaligned UTF-16 file drop"));
    }
    let step = if wide { 2 } else { 1 };
    let mut cursor = 0;
    let mut count = 0;
    let mut ranges = Vec::new();
    // Count the entire terminated list in borrowed storage, retaining at most
    // 32 ranges. In particular, do not allocate a UTF-16 copy of a huge drop.
    loop {
        let rest = data
            .get(cursor..)
            .ok_or_else(|| invalid("unterminated file drop"))?;
        let end = if wide {
            rest.as_chunks::<2>()
                .0
                .iter()
                .position(|unit| *unit == [0, 0])
                .map(|n| n * 2)
        } else {
            rest.iter().position(|&byte| byte == 0)
        }
        .ok_or_else(|| invalid("unterminated file drop"))?;
        if end == 0 {
            break;
        }
        count += 1;
        if count <= 32 {
            ranges.push(cursor..cursor + end);
        }
        cursor += end + step;
    }
    check_drop_count(count)?; // Before the 1 MiB cap or any path/metadata work.
    if data.len() as u64 + offset as u64 > MAX_CLIPBOARD_LIST {
        return Err(invalid("CF_HDROP exceeds 1 MiB"));
    }
    let mut paths = Vec::with_capacity(count);
    for range in ranges {
        let raw = &data[range];
        let path = if wide {
            let units: Vec<u16> = raw
                .as_chunks::<2>()
                .0
                .iter()
                .map(|b| u16::from_le_bytes(*b))
                .collect();
            #[cfg(windows)]
            {
                use std::os::windows::ffi::OsStringExt;
                PathBuf::from(std::ffi::OsString::from_wide(&units))
            }
            #[cfg(not(windows))]
            {
                PathBuf::from(
                    String::from_utf16(&units).map_err(|_| invalid("file drop is not UTF-16"))?,
                )
            }
        } else {
            #[cfg(windows)]
            {
                win32::ansi_path(raw)?
            }
            #[cfg(not(windows))]
            {
                PathBuf::from(
                    std::str::from_utf8(raw).map_err(|_| invalid("file drop is not UTF-8"))?,
                )
            }
        };
        paths.push(path);
    }
    Ok(paths)
}

fn check_drop_count(count: usize) -> Result<(), ClipboardCaptureError> {
    if count > 32 {
        Err(ClipboardCaptureError::too_large(
            "attachment_batch_too_large",
            count as u64,
            32,
            "files",
        ))
    } else {
        Ok(())
    }
}

// Present a BMP file header without copying the potentially 256 MiB DIB.
struct BmpReader<'a> {
    header: [u8; 14],
    dib: &'a [u8],
    position: u64,
}
impl Read for BmpReader<'_> {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        let position = self.position as usize;
        let source = if position < 14 {
            &self.header[position..]
        } else {
            self.dib.get(position - 14..).unwrap_or_default()
        };
        let count = source.len().min(output.len());
        output[..count].copy_from_slice(&source[..count]);
        self.position += count as u64;
        Ok(count)
    }
}
impl Seek for BmpReader<'_> {
    fn seek(&mut self, from: SeekFrom) -> io::Result<u64> {
        let position = match from {
            SeekFrom::Start(p) => p as i128,
            SeekFrom::Current(p) => self.position as i128 + p as i128,
            SeekFrom::End(p) => self.dib.len() as i128 + 14 + p as i128,
        };
        self.position = u64::try_from(position)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid BMP seek"))?;
        Ok(self.position)
    }
}

struct PngOutput {
    bytes: Vec<u8>,
    exceeded: Option<u64>,
}
impl Write for PngOutput {
    fn write(&mut self, input: &[u8]) -> io::Result<usize> {
        let size = self.bytes.len() as u64 + input.len() as u64;
        if size > MAX_CLIPBOARD_IMAGE {
            self.exceeded = Some(size);
            return Err(io::Error::other("PNG exceeds 20 MiB"));
        }
        self.bytes.extend_from_slice(input);
        Ok(input.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn dib_dimensions(data: &[u8]) -> Result<(usize, i32, i32), ClipboardCaptureError> {
    let header_size = u32_at(data, 0)? as usize;
    if ![12, 40, 52, 56, 108, 124].contains(&header_size) || data.len() < header_size {
        return Err(invalid("invalid or truncated DIB header"));
    }
    let (width, height) = if header_size == 12 {
        (
            u16::from_le_bytes([data[4], data[5]]) as i32,
            u16::from_le_bytes([data[6], data[7]]) as i32,
        )
    } else {
        (u32_at(data, 4)? as i32, u32_at(data, 8)? as i32)
    };
    if width <= 0 || height == 0 {
        return Err(invalid("invalid DIB dimensions"));
    }
    let bitmap_bytes = width as u64 * height.unsigned_abs() as u64 * 4;
    if bitmap_bytes > MAX_BITMAP {
        return Err(ClipboardCaptureError::too_large(
            "attachment_too_large",
            bitmap_bytes,
            MAX_BITMAP,
            "bitmap_bytes",
        ));
    }
    Ok((header_size, width, height))
}

fn dib_to_png(data: &[u8]) -> Result<Vec<u8>, ClipboardCaptureError> {
    let (header_size, _, _) = dib_dimensions(data)?;
    let (bits, colors, compression) = if header_size == 12 {
        (u16::from_le_bytes([data[10], data[11]]) as u32, 0, 0)
    } else {
        (
            u16::from_le_bytes([data[14], data[15]]) as u32,
            u32_at(data, 32)?,
            u32_at(data, 16)?,
        )
    };
    if ![1, 2, 4, 8, 16, 24, 32].contains(&bits) {
        return Err(invalid("unsupported DIB bit depth"));
    }
    let colors = if bits <= 8 {
        if colors == 0 {
            1u64 << bits
        } else {
            colors as u64
        }
    } else {
        colors as u64
    };
    if colors > 256 {
        return Err(invalid("invalid DIB color table"));
    }
    let masks = if header_size == 40 && compression == 3 {
        12
    } else {
        0
    };
    let mut offset = header_size as u64 + masks + colors * if header_size == 12 { 3 } else { 4 };
    // Packed V5 DIBs may place an ICC profile between the palette and pixels.
    if header_size == 124 {
        let profile = u32_at(data, 112)? as u64;
        let size = u32_at(data, 116)? as u64;
        if size != 0 {
            if profile < offset || profile + size > data.len() as u64 {
                return Err(invalid("invalid DIB color profile bounds"));
            }
            if profile == offset {
                offset += size;
            }
        }
    }
    if offset > data.len() as u64 {
        return Err(invalid("truncated DIB metadata"));
    }
    let mut header = [0u8; 14];
    header[..2].copy_from_slice(b"BM");
    header[2..6].copy_from_slice(&((data.len() + 14) as u32).to_le_bytes());
    header[10..14].copy_from_slice(&((offset + 14) as u32).to_le_bytes());
    let mut decoder = BmpDecoder::new(std::io::BufReader::new(BmpReader {
        header,
        dib: data,
        position: 0,
    }))
    .map_err(|_| invalid("invalid or unsupported DIB"))?;
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(MAX_BITMAP);
    decoder
        .set_limits(limits)
        .map_err(|_| invalid("DIB decoder limits exceeded"))?;
    let (width, height) = decoder.dimensions();
    let color = decoder.color_type();
    let mut pixels = vec![0u8; decoder.total_bytes() as usize];
    decoder
        .read_image(&mut pixels)
        .map_err(|_| invalid("invalid or truncated DIB pixels"))?;
    // Many screenshot producers include an alpha mask but leave every alpha
    // sample zero. Treat that convention as opaque; retain all real alpha data.
    if header_size == 124
        && u32_at(data, 52)? != 0
        && color == image::ColorType::Rgba8
        && pixels.as_chunks::<4>().0.iter().all(|pixel| pixel[3] == 0)
    {
        for pixel in pixels.as_chunks_mut::<4>().0 {
            pixel[3] = 255;
        }
    }
    let mut output = PngOutput {
        bytes: Vec::new(),
        exceeded: None,
    };
    let encoded = PngEncoder::new(&mut output).write_image(&pixels, width, height, color.into());
    if let Some(size) = output.exceeded {
        return Err(ClipboardCaptureError::too_large(
            "attachment_too_large",
            size,
            MAX_CLIPBOARD_IMAGE,
            "bytes",
        ));
    }
    encoded.map_err(|_| invalid("cannot encode DIB as PNG"))?;
    Ok(output.bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn r1_source_unlocks_and_closes_before_file_inspection_or_encoding() {
        use std::{cell::RefCell, rc::Rc};
        struct RecordingSource {
            events: Rc<RefCell<Vec<&'static str>>>,
            format: Format,
            bytes: Vec<u8>,
        }
        impl Drop for RecordingSource {
            fn drop(&mut self) {
                self.events.borrow_mut().push("close");
            }
        }
        impl Source for RecordingSource {
            fn formats(&self) -> Result<Vec<Format>, ClipboardCaptureError> {
                Ok(vec![self.format])
            }
            fn with_data<T>(
                &self,
                _: Format,
                consume: impl FnOnce(&[u8]) -> Result<T, ClipboardCaptureError>,
            ) -> Result<T, ClipboardCaptureError> {
                self.events.borrow_mut().push("copy");
                let result = consume(&self.bytes);
                self.events.borrow_mut().push("unlock");
                result
            }
        }
        let mut drop = vec![0u8; 20];
        drop[..4].copy_from_slice(&20u32.to_le_bytes());
        drop[16..20].copy_from_slice(&1u32.to_le_bytes());
        drop.extend([b'x', 0, 0, 0, 0, 0]);
        for (format, bytes, phase) in [
            (Format::Files, drop, "inspect"),
            (Format::DibV5, dib(true, -2), "encode"),
        ] {
            let events = Rc::new(RefCell::new(Vec::new()));
            let source = RecordingSource {
                events: events.clone(),
                format,
                bytes,
            };
            capture_source_with(source, |snapshot| {
                assert_eq!(events.borrow().as_slice(), &["copy", "unlock", "close"]);
                events.borrow_mut().push(phase);
                finish_snapshot(snapshot)
            })
            .unwrap();
            assert_eq!(
                events.borrow().as_slice(),
                &["copy", "unlock", "close", phase]
            );
        }
    }

    #[test]
    fn r1_zero_alpha_masked_v5_is_opaque_and_nonzero_alpha_is_preserved() {
        let mut bytes = dib(true, -2);
        bytes[127] = 0;
        bytes[131] = 0;
        let png = dib_to_png(&bytes).unwrap();
        let pixels = image::load_from_memory_with_format(&png, image::ImageFormat::Png)
            .unwrap()
            .to_rgba8();
        assert_eq!(pixels.as_raw(), &[255, 0, 0, 255, 0, 0, 255, 255]);
        bytes[127] = 64;
        let png = dib_to_png(&bytes).unwrap();
        let pixels = image::load_from_memory_with_format(&png, image::ImageFormat::Png)
            .unwrap()
            .to_rgba8();
        assert_eq!(pixels.as_raw(), &[255, 0, 0, 64, 0, 0, 255, 0]);
    }

    #[test]
    fn r1_wide_drop_allows_odd_padding_but_requires_list_termination() {
        let mut bytes = vec![0u8; 20];
        bytes[..4].copy_from_slice(&20u32.to_le_bytes());
        bytes[16..20].copy_from_slice(&1u32.to_le_bytes());
        bytes.extend([b'x', 0, 0, 0, 0, 0, 0xab]);
        assert_eq!(parse_drop(&bytes).unwrap(), vec![PathBuf::from("x")]);
        assert_eq!(parse_drop(&bytes[..24]).unwrap_err().code(), "interop");
    }

    #[test]
    fn r1_dib_allocation_limit_uses_bitmap_bytes() {
        let error = check_size(Format::DibV5, MAX_BITMAP + MAX_CLIPBOARD_LIST + 1).unwrap_err();
        assert_eq!(error.details().unit, Some("bitmap_bytes"));
    }

    pub(super) fn dib(v5: bool, height: i32) -> Vec<u8> {
        let size = if v5 { 124 } else { 40 };
        let mut data = vec![0u8; size];
        data[..4].copy_from_slice(&(size as u32).to_le_bytes());
        data[4..8].copy_from_slice(&1i32.to_le_bytes());
        data[8..12].copy_from_slice(&height.to_le_bytes());
        data[12..14].copy_from_slice(&1u16.to_le_bytes());
        data[14..16].copy_from_slice(&(if v5 { 32u16 } else { 24u16 }).to_le_bytes());
        if v5 {
            data[16..20].copy_from_slice(&3u32.to_le_bytes());
            for (i, mask) in [0xff0000u32, 0xff00, 0xff, 0xff000000].iter().enumerate() {
                data[40 + i * 4..44 + i * 4].copy_from_slice(&mask.to_le_bytes());
            }
            data[56..60].copy_from_slice(&0x73524742u32.to_le_bytes());
        }
        // Top row: red (half alpha for V5). Bottom row: opaque blue.
        let red = [0, 0, 255, if v5 { 128 } else { 0 }];
        let blue = [255, 0, 0, if v5 { 255 } else { 0 }];
        for row in if height < 0 { [red, blue] } else { [blue, red] } {
            data.extend(row);
        }
        data
    }

    #[test]
    fn format_precedence_is_independent_of_enumeration_order() {
        use Format::*;
        for (formats, expected) in [
            (vec![Dib, DibV5, Png, Files], Some(Files)),
            (vec![Dib, Png, DibV5], Some(Png)),
            (vec![Dib, DibV5], Some(DibV5)),
            (vec![Dib], Some(Dib)),
            (vec![], None),
        ] {
            assert_eq!(select_format(&formats), expected);
        }
    }

    #[test]
    fn dib_pixels_orientation_padding_and_alpha_survive_png_conversion() {
        for v5 in [false, true] {
            for height in [2, -2] {
                let png = dib_to_png(&dib(v5, height)).unwrap();
                let decoded = image::load_from_memory_with_format(&png, image::ImageFormat::Png)
                    .unwrap()
                    .to_rgba8();
                assert_eq!(decoded.dimensions(), (1, 2));
                assert_eq!(
                    decoded.as_raw(),
                    &[255, 0, 0, if v5 { 128 } else { 255 }, 0, 0, 255, 255]
                );
            }
        }
    }

    #[test]
    fn dib_rejects_oversize_before_pixels_and_reports_corrupt_data() {
        let mut data = dib(true, 2);
        data[4..8].copy_from_slice(&100000i32.to_le_bytes());
        data[8..12].copy_from_slice(&100000i32.to_le_bytes());
        let error = dib_to_png(&data[..124]).unwrap_err();
        assert_eq!(error.code(), "attachment_too_large");
        assert_eq!(error.details().measured, Some(40_000_000_000));
        assert_eq!(error.details().unit, Some("bitmap_bytes"));
        for data in [vec![], dib(false, 2)[..41].to_vec()] {
            assert_eq!(dib_to_png(&data).unwrap_err().code(), "interop");
        }
    }

    #[test]
    fn drop_count_reports_the_whole_batch_before_path_metadata() {
        let mut bytes = vec![0u8; 20];
        bytes[..4].copy_from_slice(&20u32.to_le_bytes());
        bytes[16..20].copy_from_slice(&1u32.to_le_bytes());
        for _ in 0..35 {
            bytes.extend([b'x', 0, 0, 0]);
        }
        bytes.extend([0, 0]);
        let error = parse_drop(&bytes).unwrap_err();
        assert_eq!(error.code(), "attachment_batch_too_large");
        assert_eq!(error.details().measured, Some(35));
    }

    #[test]
    fn only_busy_open_is_retried_and_attempts_are_bounded() {
        use std::cell::Cell;
        for (failures, code, expected_calls, expected_sleeps, succeeds) in [
            (2, 5, 3, 2, true),
            (4, 5, 4, 3, false),
            (1, 87, 1, 0, false),
        ] {
            let calls = Cell::new(0);
            let sleeps = Cell::new(0);
            let result = open_with(
                || {
                    calls.set(calls.get() + 1);
                    if calls.get() <= failures {
                        Err(code)
                    } else {
                        Ok(())
                    }
                },
                || sleeps.set(sleeps.get() + 1),
            );
            assert_eq!(result.is_ok(), succeeds);
            assert_eq!(
                (calls.get(), sleeps.get()),
                (expected_calls, expected_sleeps)
            );
        }
    }

    #[test]
    fn dib_palette_and_rgb565_masks_decode_known_colors() {
        let mut palette = dib(false, -2);
        palette.truncate(40);
        palette[14..16].copy_from_slice(&8u16.to_le_bytes());
        palette[32..36].copy_from_slice(&2u32.to_le_bytes());
        palette.extend([255, 0, 0, 0, 0, 0, 255, 0]); // blue, red
        palette.extend([1, 0, 0, 0, 0, 0, 0, 0]);
        let mut masked = dib(false, -2);
        masked.truncate(40);
        masked[14..16].copy_from_slice(&16u16.to_le_bytes());
        masked[16..20].copy_from_slice(&3u32.to_le_bytes());
        for mask in [0xf800u32, 0x07e0, 0x001f] {
            masked.extend(mask.to_le_bytes());
        }
        masked.extend([0, 248, 0, 0, 31, 0, 0, 0]); // RGB565 red, blue
        for data in [palette, masked] {
            let png = dib_to_png(&data).unwrap();
            let pixels = image::load_from_memory_with_format(&png, image::ImageFormat::Png)
                .unwrap()
                .to_rgb8();
            assert_eq!(pixels.as_raw(), &[255, 0, 0, 0, 0, 255]);
        }
    }

    #[test]
    fn png_writer_refuses_bytes_over_the_cap() {
        let mut writer = PngOutput {
            bytes: vec![0; MAX_CLIPBOARD_IMAGE as usize],
            exceeded: None,
        };
        assert!(writer.write_all(&[1]).is_err());
        assert_eq!(writer.exceeded, Some(MAX_CLIPBOARD_IMAGE + 1));
        assert_eq!(writer.bytes.len() as u64, MAX_CLIPBOARD_IMAGE);
    }
}
