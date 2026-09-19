use crate::error::AppError;
use std::io::Write;
use std::process::{Command, Stdio};

#[derive(Debug, PartialEq)]
enum Backend {
    Windows,
    Wayland,
    X11,
}
fn choose_backend(windows: bool, wsl: bool, wayland: bool, x11: bool) -> Result<Backend, AppError> {
    if windows || wsl {
        Ok(Backend::Windows)
    } else if wayland {
        Ok(Backend::Wayland)
    } else if x11 {
        Ok(Backend::X11)
    } else {
        Err(AppError::Interop(
            "no desktop clipboard is available; use tasks enrich --file PATH or provide stdin"
                .into(),
        ))
    }
}
fn backend() -> Result<Backend, AppError> {
    choose_backend(
        cfg!(windows),
        cfg!(target_os = "linux")
            && (std::env::var_os("WSL_DISTRO_NAME").is_some()
                || std::env::var_os("WSL_INTEROP").is_some()),
        std::env::var_os("WAYLAND_DISPLAY").is_some(),
        std::env::var_os("DISPLAY").is_some(),
    )
}
fn run(mut command: Command, input: &[u8], name: &str) -> Result<Vec<u8>, AppError> {
    let mut child=command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e|AppError::Interop(format!("cannot start {name}: {e}; Windows requires PowerShell, Wayland requires wl-clipboard, X11 requires xclip")))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| AppError::Interop(format!("cannot open {name} input")))?;
    // Drain output while sending input: a large echoed payload must not fill
    // stdout and deadlock the parent while it is still writing stdin.
    let (write_result, output) = std::thread::scope(|scope| {
        let writer = scope.spawn(move || stdin.write_all(input));
        let output = child.wait_with_output();
        let written = writer
            .join()
            .map_err(|_| AppError::Interop(format!("{name} input worker failed")))?;
        Ok::<_, AppError>((written, output))
    })?;
    let output = output.map_err(|e| AppError::Interop(format!("cannot wait for {name}: {e}")))?;
    if !output.status.success() {
        // Commands may print input in diagnostics; do not echo clipboard contents.
        return Err(AppError::Interop(format!("{name} failed ({}); the clipboard may be unavailable, locked, non-text, or changed; retry the command",output.status)));
    }
    write_result.map_err(|e| AppError::Interop(format!("cannot send text to {name}: {e}")))?;
    Ok(output.stdout)
}
fn windows(request: serde_json::Value) -> Result<Vec<u8>, AppError> {
    let mut command = Command::new("powershell.exe");
    command.args([
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-STA",
        "-Command",
        include_str!("clipboard.ps1"),
    ]);
    run(
        command,
        &serde_json::to_vec(&request)?,
        "Windows clipboard helper",
    )
}
pub fn read_text() -> Result<String, AppError> {
    let bytes = match backend()? {
        Backend::Windows => windows(serde_json::json!({"action":"read"}))?,
        Backend::Wayland => {
            let mut command = Command::new("wl-paste");
            command.args(["--no-newline", "--type", "text"]);
            run(command, &[], "wl-paste")?
        }
        Backend::X11 => {
            let mut command = Command::new("xclip");
            command.args(["-selection", "clipboard", "-out", "-target", "UTF8_STRING"]);
            run(command, &[], "xclip")?
        }
    };
    String::from_utf8(bytes)
        .map_err(|_| AppError::Validation("clipboard text is not valid UTF-8".into()))
}
pub fn replace_text(expected: &str, replacement: &str) -> Result<(), AppError> {
    if expected == replacement {
        return Ok(());
    }
    if replacement.contains('\0') {
        return Err(AppError::Validation(
            "clipboard text cannot contain NUL characters".into(),
        ));
    }
    match backend()? {
        Backend::Windows => {
            windows(
                serde_json::json!({"action":"replace","expected":expected,"replacement":replacement}),
            )?;
        }
        selected => {
            if read_text()? != expected {
                return Err(AppError::Interop(
                    "the clipboard changed during enrichment; run the command again".into(),
                ));
            }
            let mut command = Command::new(if selected == Backend::Wayland {
                "wl-copy"
            } else {
                "xclip"
            });
            if selected == Backend::Wayland {
                command.args(["--type", "text/plain;charset=utf-8"]);
            } else {
                command.args(["-selection", "clipboard", "-in", "-target", "UTF8_STRING"]);
            }
            run(command, replacement.as_bytes(), "clipboard writer")?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn backend_selection_has_explicit_ownership_and_headless_errors() {
        assert_eq!(
            choose_backend(true, false, false, false).unwrap(),
            Backend::Windows
        );
        assert_eq!(
            choose_backend(false, true, true, true).unwrap(),
            Backend::Windows
        );
        assert_eq!(
            choose_backend(false, false, true, true).unwrap(),
            Backend::Wayland
        );
        assert_eq!(
            choose_backend(false, false, false, true).unwrap(),
            Backend::X11
        );
        assert!(choose_backend(false, false, false, false).is_err());
        assert!(replace_text("unchanged", "unchanged").is_ok());
        assert!(replace_text("old", "bad\0text").is_err());
    }
    #[test]
    fn subprocess_transport_preserves_large_unicode_text_without_shell_interpolation() {
        let payload = "Ω literal $HOME `calc` \" + &[]{}\r\n".repeat(10000);
        let command = if cfg!(windows) {
            let mut c = Command::new("powershell.exe");
            c.args(["-NoProfile","-NonInteractive","-Command","[Console]::InputEncoding=New-Object System.Text.UTF8Encoding($false);[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false);[Console]::Write([Console]::In.ReadToEnd())"]);
            c
        } else {
            Command::new("cat")
        };
        let result = run(command, payload.as_bytes(), "transport test").unwrap();
        assert_eq!(result, payload.as_bytes());
    }
}
