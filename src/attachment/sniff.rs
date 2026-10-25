//! Deterministic classification of an attachment's decoded prefix.
pub const PREFIX_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Image,
    Text,
    Binary,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Image => "image",
            Self::Text => "text",
            Self::Binary => "binary",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Classification {
    pub kind: Kind,
    pub media_type: &'static str,
    pub skip_compression: bool,
}

pub fn sniff(prefix: &[u8], name: &str) -> Classification {
    let p = &prefix[..prefix.len().min(PREFIX_BYTES)];
    let ext = name
        .rsplit_once('.')
        .map(|(_, ext)| ext.to_ascii_lowercase())
        .unwrap_or_default();
    let image = |mime, skip| Classification {
        kind: Kind::Image,
        media_type: mime,
        skip_compression: skip,
    };
    let binary = |mime, skip| Classification {
        kind: Kind::Binary,
        media_type: mime,
        skip_compression: skip,
    };
    // BOM takes precedence over the overlapping MPEG frame-sync prefix FF FE.
    if p.starts_with(b"\xff\xfe") || p.starts_with(b"\xfe\xff") {
        return Classification {
            kind: Kind::Text,
            media_type: if p[0] == 0xff {
                "text/plain; charset=utf-16le"
            } else {
                "text/plain; charset=utf-16be"
            },
            skip_compression: false,
        };
    }
    if p.starts_with(b"\x89PNG\r\n\x1a\n") {
        return image("image/png", true);
    }
    if p.starts_with(b"\xff\xd8\xff") {
        return image("image/jpeg", true);
    }
    if p.starts_with(b"GIF87a") || p.starts_with(b"GIF89a") {
        return image("image/gif", true);
    }
    if p.starts_with(b"RIFF") && p.get(8..12) == Some(b"WEBP") {
        return image("image/webp", true);
    }
    if p.starts_with(b"BM") {
        return image("image/bmp", false);
    }
    if p.starts_with(b"\0\0\x01\0") {
        return image("image/x-icon", false);
    }
    if p.starts_with(b"II*\0")
        || p.starts_with(b"MM\0*")
        || p.starts_with(b"II+\0")
        || p.starts_with(b"MM\0+")
    {
        return image("image/tiff", false);
    }
    if p.get(4..8) == Some(b"ftyp") && p.len() >= 12 {
        // Only inspect brands inside the declared ftyp box, excluding minor_version.
        let size = u32::from_be_bytes([p[0], p[1], p[2], p[3]]) as usize;
        let end = if size == 0 {
            p.len()
        } else {
            size.min(p.len())
        };
        let compatible = p.get(16..end).unwrap_or_default().as_chunks::<4>().0;
        let brands = || std::iter::once(&p[8..12]).chain(compatible.iter().map(|b| b.as_slice()));
        if brands().any(|b| matches!(b, b"avif" | b"avis")) {
            return image("image/avif", true);
        }
        if brands().any(|b| {
            matches!(
                b,
                b"heic" | b"heix" | b"hevc" | b"hevx" | b"heim" | b"heis" | b"mif1" | b"msf1"
            )
        }) {
            return image("image/heic", true);
        }
        return binary(
            if brands().any(|b| b == b"qt  ") {
                "video/quicktime"
            } else {
                "video/mp4"
            },
            true,
        );
    }
    if p.starts_with(b"PK\x03\x04") || p.starts_with(b"PK\x05\x06") {
        let mime = match ext.as_str() {
            "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "jar" => "application/java-archive",
            "apk" => "application/vnd.android.package-archive",
            _ => "application/zip",
        };
        return binary(mime, true);
    }
    for (magic, mime) in [
        (&b"\x1f\x8b"[..], "application/gzip"),
        (&b"BZh"[..], "application/x-bzip2"),
        (&b"\xfd7zXZ\0"[..], "application/x-xz"),
        (&b"7z\xbc\xaf\x27\x1c"[..], "application/x-7z-compressed"),
        (&b"\x28\xb5\x2f\xfd"[..], "application/zstd"),
        (&b"Rar!\x1a\x07\0"[..], "application/vnd.rar"),
        (&b"Rar!\x1a\x07\x01\0"[..], "application/vnd.rar"),
        (&b"\x04\x22\x4d\x18"[..], "application/x-lz4"),
        (&b"ID3"[..], "audio/mpeg"),
        (&b"OggS"[..], "application/ogg"),
        (&b"fLaC"[..], "audio/flac"),
    ] {
        if p.starts_with(magic) {
            return binary(mime, true);
        }
    }
    if p.len() >= 3
        && p[0] == 0xff
        && p[1] & 0xe0 == 0xe0
        && p[1] & 0x06 != 0
        && p[2] & 0xf0 != 0xf0
    {
        return binary("audio/mpeg", true);
    }
    if p.starts_with(b"\x1a\x45\xdf\xa3") {
        return binary(
            if ext == "webm" {
                "video/webm"
            } else {
                "video/x-matroska"
            },
            true,
        );
    }
    for (magic, mime) in [
        (&b"%PDF-"[..], "application/pdf"),
        (&b"SQLite format 3\0"[..], "application/vnd.sqlite3"),
        (&b"MZ"[..], "application/vnd.microsoft.portable-executable"),
        (&b"\x7fELF"[..], "application/x-elf"),
        (&b"\0asm"[..], "application/wasm"),
    ] {
        if p.starts_with(magic) {
            return binary(mime, false);
        }
    }
    if p.starts_with(b"RIFF") && p.get(8..12) == Some(b"WAVE") {
        return binary("audio/wav", false);
    }
    let text = |mime| Classification {
        kind: Kind::Text,
        media_type: mime,
        skip_compression: false,
    };
    let utf8 = match std::str::from_utf8(p) {
        Ok(s) => Some(s),
        Err(e) if p.len() == PREFIX_BYTES && e.error_len().is_none() => {
            std::str::from_utf8(&p[..e.valid_up_to()]).ok()
        }
        Err(_) => None,
    };
    if let Some(s) = utf8 {
        let controls: usize = s
            .chars()
            .filter(|c| c.is_control() && !matches!(c, '\t' | '\n' | '\r' | '\x0c' | '\x1b'))
            .map(char::len_utf8)
            .sum();
        if !p.contains(&0) && (controls == 0 || controls * 100 < p.len()) {
            return text(text_mime(&ext));
        }
    }
    binary("application/octet-stream", false)
}

fn text_mime(ext: &str) -> &'static str {
    match ext {
        "json" => "application/json",
        "md" | "markdown" => "text/markdown",
        "csv" => "text/csv",
        "xml" => "application/xml",
        "html" | "htm" => "text/html",
        "yaml" | "yml" => "application/yaml",
        "toml" => "application/toml",
        "svg" => "image/svg+xml",
        "rs" => "text/x-rust",
        "pas" | "dpr" | "dpk" | "inc" => "text/x-pascal",
        "c" | "h" => "text/x-c",
        "cpp" | "cc" | "cxx" | "hpp" => "text/x-c++",
        "py" => "text/x-python",
        "js" | "jsx" => "text/x-javascript",
        "ts" | "tsx" => "text/x-typescript",
        "dart" => "text/x-dart",
        "cs" => "text/x-csharp",
        "java" => "text/x-java",
        "kt" | "kts" => "text/x-kotlin",
        "go" => "text/x-go",
        "swift" => "text/x-swift",
        "ps1" | "psm1" => "text/x-powershell",
        "sh" | "bash" => "text/x-shellscript",
        "sql" => "text/x-sql",
        "rb" => "text/x-ruby",
        "php" => "text/x-php",
        "lua" => "text/x-lua",
        _ => "text/plain; charset=utf-8",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_edges_and_extensions() {
        for (bytes, name, mime) in [
            (
                &b"\xef\xbb\xbfhello"[..],
                "a.txt",
                "text/plain; charset=utf-8",
            ),
            (&b"\xff\xfeh\0"[..], "a", "text/plain; charset=utf-16le"),
            (&b"\xfe\xff\0h"[..], "a", "text/plain; charset=utf-16be"),
            (
                &b"\x1b[31merror\x1b[0m\n"[..],
                "a.log",
                "text/plain; charset=utf-8",
            ),
            (&b"{}"[..], "a.JSON", "application/json"),
            (&b"<svg/>"[..], "a.svg", "image/svg+xml"),
        ] {
            let got = sniff(bytes, name);
            assert_eq!(
                (got.kind, got.media_type, got.skip_compression),
                (Kind::Text, mime, false),
                "{name}"
            );
        }
        assert_eq!(sniff(b"a\0b", "a.txt").kind, Kind::Binary);
        assert_eq!(sniff(b"\xff", "a.txt").kind, Kind::Binary);
        assert_eq!(sniff(b"\xe2\x82", "short.txt").kind, Kind::Binary);
        let mut cut = vec![b'a'; PREFIX_BYTES - 2];
        cut.extend_from_slice(b"\xe2\x82");
        assert_eq!(sniff(&cut, "cut.txt").kind, Kind::Text);
        let mut controls = vec![b'a'; 100];
        controls[0] = 1;
        assert_eq!(sniff(&controls, "a").kind, Kind::Binary);
        controls.push(b'a');
        assert_eq!(sniff(&controls, "a").kind, Kind::Text);
        assert_eq!(sniff(&[], "empty").kind, Kind::Text);
    }
}
