//! Attachment display names and portable materialized filenames.
use super::{AttachmentError, Limits, Result};
use std::path::Path;

pub fn validate(name: &str, limits: &Limits) -> Result<()> {
    if name.is_empty() || name.len() > limits.name_bytes {
        return Err(AttachmentError::Name(format!(
            "{} UTF-8 bytes; expected 1-{}",
            name.len(),
            limits.name_bytes
        )));
    }
    if name == "."
        || name == ".."
        || name.trim() != name
        || name
            .chars()
            .any(|c| c == '/' || c == '\\' || c.is_control())
    {
        return Err(AttachmentError::Name("no path separators, control characters, dot components or surrounding whitespace allowed".into()));
    }
    Ok(())
}

/// Takes a validated display name. The empty case is also supported for recovery.
pub fn sanitize(name: &str, attachment_id: u64) -> String {
    let mut safe: String = name
        .chars()
        .map(|c| if "<>:\"|?*".contains(c) { '_' } else { c })
        .collect();
    if is_device(&safe) {
        safe.insert(0, '_');
    }
    replace_trailing(&mut safe);
    truncate_portable(&mut safe);
    replace_trailing(&mut safe);
    if is_device(&safe) {
        safe.insert(0, '_');
        truncate_portable(&mut safe);
        replace_trailing(&mut safe);
    }
    if safe.is_empty() {
        format!("attachment-A{attachment_id}")
    } else {
        safe
    }
}

fn replace_trailing(safe: &mut String) {
    let trailing = safe.trim_end_matches(['.', ' ']).len();
    let count = safe.len() - trailing;
    safe.truncate(trailing);
    safe.extend(std::iter::repeat_n('_', count));
}

fn is_device(safe: &str) -> bool {
    // Windows ignores terminal dots/spaces and spaces before the extension when
    // recognizing DOS devices, including the historical superscript digits.
    let stem = safe
        .trim_end_matches(['.', ' '])
        .split('.')
        .next()
        .unwrap_or("")
        .trim_end_matches(' ')
        .to_ascii_uppercase();
    matches!(
        stem.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
    ) || stem
        .strip_prefix("COM")
        .or_else(|| stem.strip_prefix("LPT"))
        .is_some_and(|digit| {
            matches!(
                digit,
                "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
            )
        })
}

fn truncate_portable(safe: &mut String) {
    const MAX_BYTES: usize = 255;
    if safe.len() <= MAX_BYTES {
        return;
    }
    let suffix = safe
        .rsplit_once('.')
        .filter(|(_, ext)| ext.len() <= 32)
        .map(|(_, ext)| format!(".{ext}"));
    let mut end = MAX_BYTES - suffix.as_ref().map_or(0, String::len);
    while !safe.is_char_boundary(end) {
        end -= 1;
    }
    safe.truncate(end);
    if let Some(suffix) = suffix {
        safe.push_str(&suffix);
    }
}

pub fn from_path(path: &Path, limits: &Limits) -> Result<String> {
    let name = path.file_name().and_then(|n| n.to_str()).ok_or_else(|| {
        AttachmentError::Name("file has no UTF-8 final component; supply --name".into())
    })?;
    validate(name, limits)?;
    Ok(name.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn name_validation_table() {
        for name in [
            "", ".", "..", "a/b", "a\\b", "a\0b", "a\u{85}b", " a", "a ", "\ta",
        ] {
            assert!(validate(name, &Limits::PRODUCTION).is_err(), "{name:?}");
        }
        for name in ["a", "file name.json", "日本語.txt", "CON.txt", "a<>:?*"] {
            assert!(validate(name, &Limits::PRODUCTION).is_ok(), "{name:?}");
        }
        assert!(validate(&"x".repeat(255), &Limits::PRODUCTION).is_ok());
        assert!(validate(&"x".repeat(256), &Limits::PRODUCTION).is_err());
        assert!(validate(&"é".repeat(128), &Limits::PRODUCTION).is_err());
    }

    #[test]
    fn portable_sanitization_table() {
        for (input, expected) in [
            ("a<>:\"|?*b", "a_______b"),
            ("a. ", "a__"),
            ("CON", "_CON"),
            ("CONIN$", "_CONIN$"),
            ("CONOUT$", "_CONOUT$"),
            ("conin$", "_conin$"),
            ("cOnOuT$.txt", "_cOnOuT$.txt"),
            ("ConIn$.log", "_ConIn$.log"),
            ("CONIN$. ", "_CONIN$__"),
            ("conout$ .txt", "_conout$ .txt"),
            ("CONOUT$... ", "_CONOUT$____"),
            ("con.txt", "_con.txt"),
            ("NUL.zip", "_NUL.zip"),
            ("PrN", "_PrN"),
            ("AUX", "_AUX"),
            ("COM1.txt", "_COM1.txt"),
            ("lpt9", "_lpt9"),
            ("COM¹", "_COM¹"),
            ("LPT¹", "_LPT¹"),
            ("LPT²", "_LPT²"),
            ("COM³", "_COM³"),
            ("COM¹.log", "_COM¹.log"),
            ("lPt².txt", "_lPt².txt"),
            ("cOm³.json", "_cOm³.json"),
            ("COM¹ .txt", "_COM¹ .txt"),
            ("lpt²...txt", "_lpt²...txt"),
            ("COM³. ", "_COM³__"),
            ("LPT¹ . ", "_LPT¹___"),
            ("CON .txt", "_CON .txt"),
            ("com1 .txt", "_com1 .txt"),
            ("COM0", "COM0"),
            ("COM10", "COM10"),
            ("COM¹0", "COM¹0"),
            ("LPT⁴.txt", "LPT⁴.txt"),
            ("compare.txt", "compare.txt"),
            ("日本語.txt", "日本語.txt"),
            ("", "attachment-A42"),
        ] {
            let safe = sanitize(input, 42);
            assert_eq!(safe, expected, "{input:?}");
            assert_eq!(sanitize(&safe, 42), safe, "idempotence for {input:?}");
        }
    }

    #[test]
    fn sanitized_names_fit_utf8_limit_preserve_short_extensions_and_are_idempotent() {
        for (input, expected) in [
            (
                format!("CON.{}", "x".repeat(251)),
                format!("_CON.{}", "x".repeat(250)),
            ),
            (
                format!("{}.txt", "a".repeat(300)),
                format!("{}.txt", "a".repeat(251)),
            ),
            (
                format!("{}.json", "é".repeat(200)),
                format!("{}.json", "é".repeat(125)),
            ),
            (
                format!("{}é.txt", "a".repeat(250)),
                format!("{}.txt", "a".repeat(250)),
            ),
            (
                format!(
                    "{}{}",
                    "a".repeat(254),
                    ".extra-long-extension-that-has-more-than-32-bytes"
                ),
                format!("{}_", "a".repeat(254)),
            ),
            (
                format!("{} ", "a".repeat(254)),
                format!("{}_", "a".repeat(254)),
            ),
        ] {
            let safe = sanitize(&input, 42);
            assert_eq!(safe, expected, "{input:?}");
            assert!(safe.len() <= 255);
            assert_eq!(sanitize(&safe, 42), safe, "idempotence for {input:?}");
        }
    }

    #[test]
    fn default_name_is_the_final_component() {
        assert_eq!(
            from_path(Path::new("folder/file.json"), &Limits::PRODUCTION).unwrap(),
            "file.json"
        );
        assert!(from_path(Path::new("/"), &Limits::PRODUCTION).is_err());
    }

    #[test]
    #[cfg(windows)]
    fn invalid_utf8_final_component_requires_explicit_name() {
        use std::os::windows::ffi::OsStringExt;
        let path = std::path::PathBuf::from(std::ffi::OsString::from_wide(&[0xd800]));
        assert!(matches!(
            from_path(&path, &Limits::PRODUCTION),
            Err(AttachmentError::Name(_))
        ));
    }

    #[test]
    #[cfg(unix)]
    fn invalid_utf8_final_component_requires_explicit_name() {
        use std::os::unix::ffi::OsStringExt;
        let path = std::path::PathBuf::from(std::ffi::OsString::from_vec(vec![0xff]));
        assert!(matches!(
            from_path(&path, &Limits::PRODUCTION),
            Err(AttachmentError::Name(_))
        ));
    }
}
