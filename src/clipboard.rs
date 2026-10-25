use crate::error::AppError;
use sha2::{Digest, Sha256};
use std::io::Read;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const MAX_CLIPBOARD_IMAGE: u64 = 20 * 1024 * 1024;
const MAX_CLIPBOARD_LIST: u64 = 1024 * 1024;
const MAX_CLIPBOARD_FILE: u64 = 256 * 1024 * 1024;
const MAX_CLIPBOARD_TOTAL: u64 = 512 * 1024 * 1024;

#[derive(Debug, serde::Serialize, PartialEq, Eq)]
pub struct SkippedClipboardEntry {
    pub path: String,
    pub reason: String,
}

#[derive(Debug, Default)]
pub struct ClipboardCapture {
    pub image: Option<Vec<u8>>,
    pub files: Vec<PathBuf>,
    pub skipped: Vec<SkippedClipboardEntry>,
    // Metadata belongs to the inspection snapshot, not a later token computation.
    file_facts: Vec<ClipboardFileFact>,
}

#[derive(Debug, serde::Serialize)]
struct ClipboardFileFact {
    path: String,
    size: u64,
    modified_ms: u128,
}

#[derive(Debug, thiserror::Error)]
pub enum ClipboardCaptureError {
    #[error("{0}")]
    Empty(ClipboardErrorDetails),
    #[error("{0}")]
    Changed(ClipboardErrorDetails),
    #[error("{0}")]
    TooLarge(ClipboardErrorDetails),
    #[error("{details}")]
    Unavailable {
        details: Box<ClipboardErrorDetails>,
        #[source]
        source: AppError,
    },
}

/// Stable mapping data for C2; optional measurements are absent for non-limit errors.
#[derive(Debug, serde::Serialize, thiserror::Error)]
#[error("{message}")]
pub struct ClipboardErrorDetails {
    pub code: &'static str,
    pub exit_code: i32,
    pub measured: Option<u64>,
    pub limit: Option<u64>,
    pub unit: Option<&'static str>,
    pub elapsed_ms: Option<u64>,
    pub message: String,
}

impl From<AppError> for ClipboardCaptureError {
    fn from(source: AppError) -> Self {
        Self::Unavailable {
            details: Box::new(ClipboardErrorDetails {
                code: "interop",
                exit_code: 6,
                measured: None,
                limit: None,
                unit: None,
                elapsed_ms: None,
                message: source.to_string(),
            }),
            source,
        }
    }
}

impl From<std::io::Error> for ClipboardCaptureError {
    fn from(source: std::io::Error) -> Self {
        AppError::from(source).into()
    }
}

impl ClipboardCaptureError {
    fn empty() -> Self {
        Self::Empty(ClipboardErrorDetails {
            code: "clipboard_empty",
            exit_code: 2,
            measured: None,
            limit: None,
            unit: None,
            elapsed_ms: None,
            message: "the clipboard has no image or files".into(),
        })
    }

    fn too_large(code: &'static str, measured: u64, limit: u64, unit: &'static str) -> Self {
        Self::TooLarge(ClipboardErrorDetails {
            code,
            exit_code: 2,
            measured: Some(measured),
            limit: Some(limit),
            unit: Some(unit),
            elapsed_ms: None,
            message: format!("clipboard capture exceeds {limit} {unit} (observed {measured})"),
        })
    }

    pub fn details(&self) -> &ClipboardErrorDetails {
        match self {
            Self::Empty(details) | Self::Changed(details) | Self::TooLarge(details) => details,
            Self::Unavailable { details, .. } => details,
        }
    }

    pub fn code(&self) -> &'static str {
        self.details().code
    }

    pub fn exit_code(&self) -> i32 {
        self.details().exit_code
    }

    fn with_elapsed(mut self, elapsed: std::time::Duration) -> Self {
        let details = match &mut self {
            Self::Empty(details) | Self::Changed(details) | Self::TooLarge(details) => details,
            Self::Unavailable { details, .. } => details.as_mut(),
        };
        details.elapsed_ms = Some(duration_ms(elapsed));
        self
    }
}

fn duration_ms(duration: std::time::Duration) -> u64 {
    duration.as_millis().min(u64::MAX as u128) as u64
}

/// Best-effort comparison between an inspection token and a fresh capture.
pub fn verify_capture_token(
    capture: &ClipboardCapture,
    expected: &str,
) -> Result<(), ClipboardCaptureError> {
    if capture_token(capture) == expected {
        Ok(())
    } else {
        Err(ClipboardCaptureError::Changed(ClipboardErrorDetails {
            code: "clipboard_changed",
            exit_code: 4,
            measured: None,
            limit: None,
            unit: None,
            elapsed_ms: None,
            message: "the clipboard changed; inspect it again before attaching".into(),
        }))
    }
}

/// SHA-256 over compact UTF-8 JSON with top-level fields `files`, then `image`.
/// File fields are `path`, `size`, `modified_ms`, in clipboard order; absent image
/// is null. Paths use their absolute clipboard spelling, without case folding.
/// Compare tokens from two fresh captures. This is a best-effort metadata check.
pub fn capture_token(capture: &ClipboardCapture) -> String {
    // Formatting a JSON string Value provides deterministic, infallible escaping.
    let files = capture
        .file_facts
        .iter()
        .map(|f| {
            format!(
                "{{\"path\":{},\"size\":{},\"modified_ms\":{}}}",
                serde_json::Value::String(f.path.clone()),
                f.size,
                f.modified_ms
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    let image = capture
        .image
        .as_ref()
        .map(|png| format!("{{\"png_sha256\":\"{:x}\"}}", Sha256::digest(png)))
        .unwrap_or_else(|| "null".into());
    format!(
        "{:x}",
        Sha256::digest(format!("{{\"files\":[{files}],\"image\":{image}}}").as_bytes())
    )
}

#[cfg(any(test, feature = "test-hooks"))]
fn read_limited(path: &Path, limit: u64) -> Result<Vec<u8>, AppError> {
    let file = std::fs::File::open(path)
        .map_err(|e| AppError::io_path("read clipboard capture", path, e))?;
    let mut bytes = Vec::new();
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| AppError::io_path("read clipboard capture", path, e))?;
    if bytes.len() as u64 > limit {
        return Err(AppError::Interop(format!(
            "clipboard capture exceeds {limit} bytes"
        )));
    }
    Ok(bytes)
}

fn inspect_files(
    paths: Vec<PathBuf>,
    mut skipped: Vec<SkippedClipboardEntry>,
) -> Result<ClipboardCapture, ClipboardCaptureError> {
    if paths.len() > 32 {
        return Err(ClipboardCaptureError::too_large(
            "attachment_batch_too_large",
            paths.len() as u64,
            32,
            "files",
        ));
    }
    let mut capture = ClipboardCapture::default();
    let mut total = 0u64;
    for path in paths {
        let fact = (|| {
            if !path.is_absolute() {
                return Err("not an absolute path");
            }
            let name = path.to_str().ok_or("path is not UTF-8")?;
            let metadata = std::fs::metadata(&path).map_err(|e| {
                if e.kind() == std::io::ErrorKind::NotFound {
                    "missing"
                } else {
                    "cannot read metadata"
                }
            })?;
            if metadata.is_dir() {
                return Err("directory");
            }
            if !metadata.is_file() {
                return Err("not a regular file");
            }
            let modified_ms = metadata
                .modified()
                .map_err(|_| "cannot read modification time")?
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|_| "modification time before Unix epoch")?
                .as_millis();
            Ok(ClipboardFileFact {
                path: name.into(),
                size: metadata.len(),
                modified_ms,
            })
        })();
        match fact {
            Ok(fact) => {
                if fact.size > MAX_CLIPBOARD_FILE {
                    return Err(ClipboardCaptureError::too_large(
                        "attachment_original_too_large",
                        fact.size,
                        MAX_CLIPBOARD_FILE,
                        "bytes",
                    ));
                }
                total = total.checked_add(fact.size).ok_or_else(|| {
                    ClipboardCaptureError::too_large(
                        "attachment_batch_too_large",
                        u64::MAX,
                        MAX_CLIPBOARD_TOTAL,
                        "bytes",
                    )
                })?;
                if total > MAX_CLIPBOARD_TOTAL {
                    return Err(ClipboardCaptureError::too_large(
                        "attachment_batch_too_large",
                        total,
                        MAX_CLIPBOARD_TOTAL,
                        "bytes",
                    ));
                }
                capture.file_facts.push(fact);
                capture.files.push(path);
            }
            Err(reason) => skipped.push(SkippedClipboardEntry {
                path: path.to_string_lossy().into_owned(),
                reason: reason.into(),
            }),
        }
    }
    capture.skipped = skipped;
    Ok(capture)
}

fn inspect_drop(
    count: u64,
    files: Vec<PathBuf>,
) -> Result<ClipboardCapture, ClipboardCaptureError> {
    // Check reported count before statting even one supplied path.
    if count > 32 {
        return Err(ClipboardCaptureError::too_large(
            "attachment_batch_too_large",
            count,
            32,
            "files",
        ));
    }
    if count != files.len() as u64 {
        return Err(AppError::Interop(
            "clipboard helper returned an inconsistent file count".into(),
        )
        .into());
    }
    inspect_files(files, Vec::new())
}

fn read_png(path: &Path) -> Result<Vec<u8>, ClipboardCaptureError> {
    read_png_with(path, read_png_stream)
}

fn read_png_with(
    path: &Path,
    read_content: impl FnOnce(std::fs::File) -> Result<Vec<u8>, ClipboardCaptureError>,
) -> Result<Vec<u8>, ClipboardCaptureError> {
    let file =
        std::fs::File::open(path).map_err(|e| AppError::io_path("read clipboard PNG", path, e))?;
    let size = file.metadata().map_err(AppError::from)?.len();
    if size > MAX_CLIPBOARD_IMAGE {
        return Err(ClipboardCaptureError::too_large(
            "attachment_too_large",
            size,
            MAX_CLIPBOARD_IMAGE,
            "bytes",
        ));
    }
    read_content(file)
}

fn read_png_stream(input: impl Read) -> Result<Vec<u8>, ClipboardCaptureError> {
    let mut bytes = Vec::new();
    input
        .take(MAX_CLIPBOARD_IMAGE + 1)
        .read_to_end(&mut bytes)
        .map_err(AppError::from)?;
    if bytes.len() as u64 > MAX_CLIPBOARD_IMAGE {
        return Err(ClipboardCaptureError::too_large(
            "attachment_too_large",
            bytes.len() as u64,
            MAX_CLIPBOARD_IMAGE,
            "bytes",
        ));
    }
    Ok(bytes)
}

fn require_content(capture: ClipboardCapture) -> Result<ClipboardCapture, ClipboardCaptureError> {
    if capture.image.is_none() && capture.files.is_empty() && capture.skipped.is_empty() {
        Err(ClipboardCaptureError::empty())
    } else {
        Ok(capture)
    }
}

#[cfg(any(test, feature = "test-hooks"))]
fn read_fixture(dir: &Path) -> Result<ClipboardCapture, ClipboardCaptureError> {
    read_fixture_with_png(dir, read_png)
}

#[cfg(any(test, feature = "test-hooks"))]
fn read_fixture_with_png(
    dir: &Path,
    read_image: impl FnOnce(&Path) -> Result<Vec<u8>, ClipboardCaptureError>,
) -> Result<ClipboardCapture, ClipboardCaptureError> {
    let list = dir.join("files.json");
    let image = dir.join("image.png");
    if list.try_exists().map_err(AppError::from)? {
        #[derive(serde::Deserialize)]
        #[serde(untagged)]
        enum FixtureDrop {
            Paths(Vec<PathBuf>),
            Counted { count: u64, files: Vec<PathBuf> },
        }
        let drop: FixtureDrop = serde_json::from_slice(&read_limited(&list, MAX_CLIPBOARD_LIST)?)
            .map_err(AppError::from)?;
        let capture = match drop {
            FixtureDrop::Paths(files) => inspect_drop(files.len() as u64, files)?,
            FixtureDrop::Counted { count, files } => inspect_drop(count, files)?,
        };
        require_content(capture)
    } else if image.try_exists().map_err(AppError::from)? {
        require_content(ClipboardCapture {
            image: Some(read_image(&image)?),
            ..Default::default()
        })
    } else {
        Err(ClipboardCaptureError::empty())
    }
}

fn parse_file_uris(input: &str) -> (Vec<PathBuf>, Vec<SkippedClipboardEntry>) {
    let mut paths = Vec::new();
    let mut skipped = Vec::new();
    for line in input
        .lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
    {
        let parsed = (|| {
            let rest = line.strip_prefix("file://").ok_or("not a file URI")?;
            let path = if rest.starts_with('/') {
                rest
            } else {
                rest.strip_prefix("localhost/")
                    .map(|p| &rest[rest.len() - p.len() - 1..])
                    .ok_or("non-local file URI")?
            };
            if path.contains(['?', '#']) {
                return Err("unescaped query or fragment");
            }
            let mut decoded = Vec::new();
            let mut bytes = path.bytes();
            while let Some(byte) = bytes.next() {
                let byte = if byte == b'%' {
                    let a = (bytes.next().ok_or("invalid URI escape")? as char)
                        .to_digit(16)
                        .ok_or("invalid URI escape")?;
                    let b = (bytes.next().ok_or("invalid URI escape")? as char)
                        .to_digit(16)
                        .ok_or("invalid URI escape")?;
                    (a * 16 + b) as u8
                } else {
                    byte
                };
                if byte == 0 {
                    return Err("NUL in file URI");
                }
                decoded.push(byte);
            }
            String::from_utf8(decoded)
                .map(PathBuf::from)
                .map_err(|_| "file URI is not UTF-8")
        })();
        match parsed {
            Ok(path) => paths.push(path),
            Err(reason) => skipped.push(SkippedClipboardEntry {
                path: line.into(),
                reason: reason.into(),
            }),
        }
    }
    (paths, skipped)
}

/// Inspect the clipboard without accessing a store. `work_dir` must be an
/// absolute, private, caller-owned temporary directory (C2 supplies TempDir).
/// The caller removes the directory before starting store operations.
pub fn read_attachments(work_dir: &Path) -> Result<ClipboardCapture, ClipboardCaptureError> {
    #[cfg(feature = "test-hooks")]
    {
        let fixture = std::env::var_os("TASKS_TEST_CLIPBOARD_FIXTURE");
        with_fixture(fixture.as_deref().map(Path::new), || {
            read_attachments_backend(work_dir, backend()?)
        })
    }
    #[cfg(not(feature = "test-hooks"))]
    read_attachments_backend(work_dir, backend()?)
}

#[cfg(any(test, feature = "test-hooks"))]
fn with_fixture(
    fixture: Option<&Path>,
    desktop: impl FnOnce() -> Result<ClipboardCapture, ClipboardCaptureError>,
) -> Result<ClipboardCapture, ClipboardCaptureError> {
    match fixture {
        Some(dir) => read_fixture(dir),
        None => desktop(),
    }
}

fn read_attachments_backend(
    work_dir: &Path,
    selected: Backend,
) -> Result<ClipboardCapture, ClipboardCaptureError> {
    match selected {
        Backend::Windows => {
            if !work_dir.is_absolute() || !work_dir.is_dir() {
                return Err(AppError::Interop(
                    "clipboard work directory must be an existing absolute private directory"
                        .into(),
                )
                .into());
            }
            let image_path = work_dir.join(format!("clipboard-{}.png", uuid::Uuid::new_v4()));
            let result = (|| {
                let mut command = Command::new("powershell.exe");
                command.args([
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-STA",
                    "-Command",
                    include_str!("clipboard_attach.ps1"),
                ]);
                let request = serde_json::to_vec(&serde_json::json!({"image_path": image_path}))
                    .map_err(AppError::from)?;
                let reply = attachment_run(
                    command,
                    &request,
                    "PowerShell clipboard helper",
                    MAX_CLIPBOARD_LIST,
                )?;
                #[derive(serde::Deserialize)]
                struct Reply {
                    files: Vec<PathBuf>,
                    count: u64,
                    image: bool,
                    #[serde(default)]
                    too_large: bool,
                    measured: Option<u64>,
                    limit: Option<u64>,
                    unit: Option<String>,
                }
                let reply: Reply = serde_json::from_slice(&reply).map_err(AppError::from)?;
                if reply.too_large {
                    let measured = reply.measured.ok_or_else(|| {
                        AppError::Interop("clipboard helper omitted measured size".into())
                    })?;
                    let limit = reply.limit.ok_or_else(|| {
                        AppError::Interop("clipboard helper omitted size limit".into())
                    })?;
                    let unit = match reply.unit.as_deref() {
                        Some("bytes") => "bytes",
                        Some("bitmap_bytes") => "bitmap_bytes",
                        _ => {
                            return Err(AppError::Interop(
                                "clipboard helper returned invalid measurement unit".into(),
                            )
                            .into())
                        }
                    };
                    return Err(ClipboardCaptureError::too_large(
                        "attachment_too_large",
                        measured,
                        limit,
                        unit,
                    ));
                }
                let mut capture = inspect_drop(reply.count, reply.files)?;
                if reply.image {
                    capture.image = Some(read_png(&image_path)?);
                }
                Ok::<_, ClipboardCaptureError>(capture)
            })();
            let cleanup = match std::fs::remove_file(&image_path) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(AppError::io_path(
                    "remove clipboard temporary image",
                    &image_path,
                    e,
                )),
            };
            let capture = result?;
            cleanup?;
            require_content(capture)
        }
        Backend::Wayland | Backend::X11 => {
            let name = if selected == Backend::Wayland {
                "wl-paste"
            } else {
                "xclip"
            };
            let types = linux_clipboard_command(&selected, None);
            let types = attachment_run(types, &[], name, MAX_CLIPBOARD_LIST)?;
            let types = String::from_utf8(types).map_err(|_| {
                AppError::Interop(format!("{name} returned invalid clipboard types"))
            })?;
            let types: Vec<_> = types.split_whitespace().collect();
            if types.contains(&"text/uri-list") {
                let bytes = attachment_run(
                    linux_clipboard_command(&selected, Some("text/uri-list")),
                    &[],
                    name,
                    MAX_CLIPBOARD_LIST,
                )?;
                let text = String::from_utf8(bytes).map_err(|_| {
                    AppError::Interop(format!("{name} returned a non-UTF-8 URI list"))
                })?;
                let (files, skipped) = parse_file_uris(&text);
                require_content(inspect_files(files, skipped)?)
            } else if types.contains(&"image/png") {
                let png = attachment_run(
                    linux_clipboard_command(&selected, Some("image/png")),
                    &[],
                    name,
                    MAX_CLIPBOARD_IMAGE,
                )?;
                require_content(ClipboardCapture {
                    image: Some(png),
                    ..Default::default()
                })
            } else {
                Err(ClipboardCaptureError::empty())
            }
        }
    }
}

fn linux_clipboard_command(selected: &Backend, target: Option<&str>) -> Command {
    let mut command = Command::new(if *selected == Backend::Wayland {
        "wl-paste"
    } else {
        "xclip"
    });
    if *selected == Backend::Wayland {
        match target {
            None => {
                command.arg("--list-types");
            }
            Some(target) => {
                command.args(["--no-newline", "--type", target]);
            }
        }
    } else {
        command.args([
            "-selection",
            "clipboard",
            "-t",
            target.unwrap_or("TARGETS"),
            "-o",
        ]);
    }
    command
}

fn attachment_run(
    command: Command,
    input: &[u8],
    name: &str,
    limit: u64,
) -> Result<Vec<u8>, ClipboardCaptureError> {
    // Section 9 specifies no deadline. Bound each owned helper invocation to 10 s.
    attachment_run_with_deadline(
        command,
        input,
        name,
        limit,
        std::time::Duration::from_secs(10),
        |_| {},
    )
}

// Windows uses only std::process: the static STA script spawns no children.
// Deliberately no Job Object dependency/unsafe code. A descendant inheriting
// pipes could outlive the CLI; the independent 500 ms pipe grace still bounds
// return latency. Linux retains process-group termination through safe rustix.
struct HelperProcess {
    child: std::process::Child,
    #[cfg(unix)]
    group: rustix::process::Pid,
    terminated: bool,
}

impl HelperProcess {
    fn spawn(
        mut command: Command,
        stdin: std::io::PipeReader,
        stdout: std::io::PipeWriter,
        stderr: std::io::PipeWriter,
    ) -> std::io::Result<Self> {
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        }
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        command.stdin(stdin).stdout(stdout).stderr(stderr);
        let child = command.spawn()?;
        Ok(Self {
            #[cfg(unix)]
            group: rustix::process::Pid::from_child(&child),
            child,
            terminated: false,
        })
    }

    fn id(&self) -> u32 {
        self.child.id()
    }

    fn exit_success(&mut self) -> std::io::Result<Option<bool>> {
        #[cfg(windows)]
        {
            Ok(self.child.try_wait()?.map(|status| status.success()))
        }
        #[cfg(unix)]
        {
            // Keep the root PID reserved until its group has been killed, even
            // when the root exits before its descendants.
            use rustix::process::{waitid, WaitId, WaitIdOptions};
            Ok(waitid(
                WaitId::Pid(self.group),
                WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT,
            )?
            .map(|status| status.exit_status() == Some(0)))
        }
    }

    fn terminate(&mut self) -> std::io::Result<()> {
        if self.terminated {
            return Ok(());
        }
        #[cfg(windows)]
        {
            if self.child.try_wait()?.is_none() {
                if let Err(error) = self.child.kill() {
                    if self.child.try_wait()?.is_none() {
                        return Err(error);
                    }
                }
            }
        }
        #[cfg(unix)]
        {
            use rustix::process::{kill_process_group, Signal};
            match kill_process_group(self.group, Signal::KILL) {
                Ok(()) | Err(rustix::io::Errno::SRCH) => {}
                Err(error) => return Err(error.into()),
            }
        }
        self.terminated = true;
        Ok(())
    }

    fn reaped(&mut self) -> std::io::Result<bool> {
        Ok(self.child.try_wait()?.is_some())
    }
}

impl Drop for HelperProcess {
    fn drop(&mut self) {
        let _ = self.terminate();
    }
}

enum HelperIo {
    Input(std::io::Result<()>),
    Output(std::io::Result<Vec<u8>>),
    Diagnostics(std::io::Result<u64>),
}

fn helper_unavailable(
    name: &str,
    reason: &str,
    elapsed: std::time::Duration,
    measured: u64,
    limit: u64,
    unit: &'static str,
) -> ClipboardCaptureError {
    let message = format!("{name} {reason}; clipboard unavailable; retry");
    ClipboardCaptureError::Unavailable {
        details: Box::new(ClipboardErrorDetails {
            code: "interop",
            exit_code: 6,
            measured: Some(measured),
            limit: Some(limit),
            unit: Some(unit),
            elapsed_ms: Some(duration_ms(elapsed)),
            message: message.clone(),
        }),
        source: AppError::Interop(message),
    }
}

// Completion messages are sent only after the worker has dropped its pipe.
// A missing completion or a child that cannot be reaped cannot extend grace.
fn await_helper_shutdown(
    receiver: &std::sync::mpsc::Receiver<HelperIo>,
    mut reaped: impl FnMut() -> std::io::Result<bool>,
    written: &mut Option<std::io::Result<()>>,
    bytes: &mut Option<std::io::Result<Vec<u8>>>,
    drained: &mut Option<std::io::Result<u64>>,
    grace: std::time::Duration,
) -> std::io::Result<bool> {
    use std::time::{Duration, Instant};
    let started = Instant::now();
    while started.elapsed() < grace {
        if reaped()? && written.is_some() && bytes.is_some() && drained.is_some() {
            return Ok(true);
        }
        match receiver
            .recv_timeout(Duration::from_millis(5).min(grace.saturating_sub(started.elapsed())))
        {
            Ok(HelperIo::Input(result)) => *written = Some(result),
            Ok(HelperIo::Output(result)) => *bytes = Some(result),
            Ok(HelperIo::Diagnostics(result)) => *drained = Some(result),
            Err(_) => std::thread::sleep(Duration::from_millis(1)),
        }
    }
    Ok(false)
}

fn attachment_run_with_deadline(
    command: Command,
    input: &[u8],
    name: &str,
    limit: u64,
    deadline: std::time::Duration,
    observe_child: impl FnOnce(u32),
) -> Result<Vec<u8>, ClipboardCaptureError> {
    use std::time::{Duration, Instant};
    let started = Instant::now();
    let (child_stdin, mut stdin) = std::io::pipe()?;
    let (stdout, child_stdout) = std::io::pipe()?;
    let (mut stderr, child_stderr) = std::io::pipe()?;
    let mut tree = HelperProcess::spawn(command, child_stdin, child_stdout, child_stderr)
        .map_err(|e| AppError::Interop(format!("cannot start {name}: {e}; install PowerShell, wl-clipboard or xclip for this desktop")))?;
    // spawn consumes and closes the parent's copies of all child pipe ends.
    observe_child(tree.id());
    let input = input.to_vec();
    let (sender, receiver) = std::sync::mpsc::channel();
    let writer_sender = sender.clone();
    std::thread::Builder::new()
        .name("clipboard-input".into())
        .spawn(move || {
            let result = stdin.write_all(&input);
            drop(stdin);
            let _ = writer_sender.send(HelperIo::Input(result));
        })?;
    let reader_sender = sender.clone();
    std::thread::Builder::new()
        .name("clipboard-output".into())
        .spawn(move || {
            let mut bytes = Vec::new();
            let result = stdout
                .take(limit + 1)
                .read_to_end(&mut bytes)
                .map(|_| bytes);
            let _ = reader_sender.send(HelperIo::Output(result));
        })?;
    std::thread::Builder::new()
        .name("clipboard-errors".into())
        .spawn(move || {
            let result = std::io::copy(
                &mut (&mut stderr).take(MAX_CLIPBOARD_LIST + 1),
                &mut std::io::sink(),
            );
            drop(stderr);
            let _ = sender.send(HelperIo::Diagnostics(result));
        })?;

    let mut written = None;
    let mut bytes = None;
    let mut drained = None;
    let mut overflow = None;
    let mut timed_out = false;
    let mut status = None;
    let mut monitor_error = None;
    loop {
        while let Ok(event) = receiver.try_recv() {
            match event {
                HelperIo::Input(result) => written = Some(result),
                HelperIo::Output(result) => {
                    if let Ok(output) = &result {
                        if output.len() as u64 > limit {
                            overflow = Some((output.len() as u64, limit));
                        }
                    }
                    bytes = Some(result);
                }
                HelperIo::Diagnostics(result) => {
                    if let Ok(count) = &result {
                        if *count > MAX_CLIPBOARD_LIST {
                            overflow = Some((*count, MAX_CLIPBOARD_LIST));
                        }
                    }
                    drained = Some(result);
                }
            }
        }
        if overflow.is_some() {
            break;
        }
        match tree.exit_success() {
            Ok(Some(success)) => {
                status = Some(success);
                break;
            }
            Ok(None) => {}
            Err(error) => {
                monitor_error = Some(error);
                break;
            }
        }
        if started.elapsed() >= deadline {
            timed_out = true;
            break;
        }
        std::thread::sleep(
            Duration::from_millis(5).min(deadline.saturating_sub(started.elapsed())),
        );
    }
    // Terminate the direct Windows helper / Linux group at every boundary.
    // Windows descendants may still hold pipes, so shutdown must not join them.
    let termination = tree.terminate();
    // Independent bound: no scoped threads, blocking waits or unconditional
    // joins, even if containment fails or an escaped handle keeps a pipe open.
    let cleanup_started = Instant::now();
    let complete = await_helper_shutdown(
        &receiver,
        || tree.reaped(),
        &mut written,
        &mut bytes,
        &mut drained,
        Duration::from_millis(500),
    )?;
    let elapsed = started.elapsed();
    if termination.is_err() || !tree.reaped()? {
        return Err(helper_unavailable(
            name,
            "shutdown did not complete within 500 ms",
            elapsed,
            duration_ms(cleanup_started.elapsed()),
            500,
            "milliseconds",
        ));
    }
    if let Some(error) = monitor_error {
        return Err(AppError::Interop(format!("cannot monitor {name}: {error}")).into());
    }
    if timed_out {
        return Err(helper_unavailable(
            name,
            &format!("timed out after {} ms", duration_ms(elapsed)),
            elapsed,
            duration_ms(elapsed),
            duration_ms(deadline),
            "milliseconds",
        ));
    }
    // Completion may arrive during shutdown after the root already exited.
    if let Some(Ok(output)) = &bytes {
        if output.len() as u64 > limit {
            overflow = Some((output.len() as u64, limit));
        }
    }
    if let Some(Ok(count)) = &drained {
        if *count > MAX_CLIPBOARD_LIST {
            overflow = Some((*count, MAX_CLIPBOARD_LIST));
        }
    }
    if let Some((measured, cap)) = overflow {
        if cap == MAX_CLIPBOARD_IMAGE {
            return Err(ClipboardCaptureError::too_large(
                "attachment_too_large",
                measured,
                cap,
                "bytes",
            )
            .with_elapsed(elapsed));
        }
        return Err(helper_unavailable(
            name,
            &format!("clipboard output exceeds {cap} bytes"),
            elapsed,
            measured,
            cap,
            "bytes",
        ));
    }
    if !complete {
        return Err(helper_unavailable(
            name,
            "shutdown did not complete within 500 ms",
            elapsed,
            duration_ms(cleanup_started.elapsed()),
            500,
            "milliseconds",
        ));
    }
    let output =
        bytes.ok_or_else(|| AppError::Interop(format!("{name} output worker unavailable")))??;
    if status != Some(true) {
        return Err(AppError::Interop(format!(
            "{name} failed; clipboard unavailable or locked; retry"
        ))
        .into());
    }
    // A successful root need not consume stdin. BrokenPipe is expected if its
    // descendants inherited stdin and were stopped at root exit.
    if let Some(Err(error)) = written {
        if error.kind() != std::io::ErrorKind::BrokenPipe {
            return Err(error.into());
        }
    }
    if let Some(Err(error)) = drained {
        return Err(error.into());
    }
    Ok(output)
}

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
            "no desktop clipboard is available; Windows requires PowerShell, Wayland requires wl-paste, X11 requires xclip; use --file PATH or provide stdin"
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
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
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
    use sha2::{Digest, Sha256};

    fn scratch() -> tempfile::TempDir {
        tempfile::Builder::new()
            .prefix("clipboard-unit-")
            .tempdir_in(std::env::temp_dir())
            .unwrap()
    }

    #[test]
    fn fixture_preserves_order_reports_skips_and_prefers_files() {
        let dir = scratch();
        let first = dir.path().join("Ω $HOME `x` first.txt");
        let second = dir.path().join("second.txt");
        let missing = dir.path().join("missing");
        std::fs::write(&first, b"first").unwrap();
        std::fs::write(&second, b"second").unwrap();
        std::fs::write(dir.path().join("image.png"), b"fixture image").unwrap();
        std::fs::write(
            dir.path().join("files.json"),
            serde_json::to_vec(&vec![&second, &first, dir.path(), &missing]).unwrap(),
        )
        .unwrap();
        let capture = read_fixture(dir.path()).unwrap();
        assert_eq!(capture.files, vec![second, first]);
        assert_eq!(capture.image, None);
        assert_eq!(capture.skipped.len(), 2);
        assert_eq!(capture.skipped[0].reason, "directory");
        assert_eq!(capture.skipped[1].reason, "missing");
    }

    #[test]
    fn token_has_a_canonical_image_vector_and_changes_with_content() {
        let mut capture = ClipboardCapture {
            image: Some(b"abc".to_vec()),
            ..Default::default()
        };
        let canonical = br#"{"files":[],"image":{"png_sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}}"#;
        assert_eq!(
            capture_token(&capture),
            format!("{:x}", Sha256::digest(canonical))
        );
        capture.image = Some(b"abcd".to_vec());
        assert_ne!(
            capture_token(&capture),
            format!("{:x}", Sha256::digest(canonical))
        );
    }

    #[test]
    fn tokens_track_file_order_size_and_snapshot_metadata() {
        let dir = scratch();
        let a = dir.path().join("a");
        let b = dir.path().join("b");
        std::fs::write(&a, b"a").unwrap();
        std::fs::write(&b, b"bb").unwrap();
        let list = dir.path().join("files.json");
        std::fs::write(&list, serde_json::to_vec(&vec![&a, &b]).unwrap()).unwrap();
        let old = read_fixture(dir.path()).unwrap();
        let token = capture_token(&old);
        assert_eq!(token.len(), 64);
        assert_eq!(token, capture_token(&read_fixture(dir.path()).unwrap()));
        std::fs::write(&a, b"changed").unwrap();
        assert_eq!(
            token,
            capture_token(&old),
            "capture is an inspection snapshot"
        );
        let changed = capture_token(&read_fixture(dir.path()).unwrap());
        assert_ne!(token, changed);
        std::fs::write(&list, serde_json::to_vec(&vec![&b, &a]).unwrap()).unwrap();
        assert_ne!(changed, capture_token(&read_fixture(dir.path()).unwrap()));
    }

    #[test]
    fn fixture_image_empty_and_malformed_inputs_do_not_access_clipboard() {
        let dir = scratch();
        assert!(matches!(
            read_fixture(dir.path()),
            Err(ClipboardCaptureError::Empty(_))
        ));
        std::fs::write(dir.path().join("image.png"), b"PNG fixture").unwrap();
        assert_eq!(
            read_fixture(dir.path()).unwrap().image.unwrap(),
            b"PNG fixture"
        );
        std::fs::write(dir.path().join("files.json"), b"not json").unwrap();
        assert!(matches!(
            read_fixture(dir.path()),
            Err(ClipboardCaptureError::Unavailable { .. })
        ));
    }

    #[test]
    fn uri_lists_decode_local_files_and_report_unsupported_entries() {
        let (paths, skipped) = parse_file_uris("# comment\r\nfile:///tmp/a%20b%23%CE%A9\r\nfile://localhost/tmp/z\nhttps://host/x\nfile://server/share/x\nfile:///bad%GG\nfile:///bad%00\nfile:///bad?query\n");
        assert_eq!(
            paths,
            vec![PathBuf::from("/tmp/a b#Ω"), PathBuf::from("/tmp/z")]
        );
        assert_eq!(skipped.len(), 5);
        assert!(skipped.iter().all(|item| !item.reason.is_empty()));
    }

    #[test]
    fn fixture_override_never_invokes_the_desktop_even_on_invalid_fixture() {
        let dir = scratch();
        std::fs::write(dir.path().join("image.png"), b"fixture").unwrap();
        let capture = with_fixture(Some(dir.path()), || panic!("desktop accessed")).unwrap();
        assert_eq!(capture.image.unwrap(), b"fixture");
        std::fs::write(dir.path().join("files.json"), b"invalid").unwrap();
        assert!(with_fixture(Some(dir.path()), || panic!("desktop accessed")).is_err());
        assert!(matches!(
            with_fixture(None, || Err(ClipboardCaptureError::empty())),
            Err(ClipboardCaptureError::Empty(_))
        ));
    }

    fn sparse(path: &Path, len: u64) {
        let file = std::fs::File::create(path).unwrap();
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            let output = Command::new("fsutil.exe")
                .args(["sparse", "setflag"])
                .arg(path)
                .creation_flags(0x08000000)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "cannot mark owned fixture sparse: {:?}",
                output.status
            );
        }
        file.set_len(len).unwrap();
    }

    #[test]
    fn fixture_refuses_drop_count_33_before_stat_or_file_content() {
        let dir = scratch();
        std::fs::write(
            dir.path().join("files.json"),
            br#"{"count":33,"files":["missing"]}"#,
        )
        .unwrap();
        let error = read_fixture(dir.path()).unwrap_err();
        assert_eq!(error.code(), "attachment_batch_too_large");
        assert_eq!(error.exit_code(), 2);
        assert_eq!(error.details().measured, Some(33));
        assert_eq!(error.details().limit, Some(32));
        assert_eq!(error.details().unit, Some("files"));
    }

    #[test]
    fn fixture_refuses_oversized_sparse_files_and_batches_by_metadata() {
        let dir = scratch();
        let a = dir.path().join("a");
        let b = dir.path().join("b");
        let c = dir.path().join("c");
        let list = dir.path().join("files.json");
        sparse(&a, 256 * 1024 * 1024 + 1);
        std::fs::write(&list, serde_json::to_vec(&vec![&a]).unwrap()).unwrap();
        assert_eq!(
            read_fixture(dir.path()).unwrap_err().code(),
            "attachment_original_too_large"
        );
        sparse(&a, 200 * 1024 * 1024);
        sparse(&b, 200 * 1024 * 1024);
        sparse(&c, 200 * 1024 * 1024);
        std::fs::write(&list, serde_json::to_vec(&vec![&a, &b, &c]).unwrap()).unwrap();
        assert_eq!(
            read_fixture(dir.path()).unwrap_err().code(),
            "attachment_batch_too_large"
        );
        std::fs::File::options()
            .write(true)
            .open(&a)
            .unwrap()
            .set_len(256 * 1024 * 1024)
            .unwrap();
        std::fs::File::options()
            .write(true)
            .open(&b)
            .unwrap()
            .set_len(256 * 1024 * 1024)
            .unwrap();
        std::fs::write(&list, serde_json::to_vec(&vec![&a, &b]).unwrap()).unwrap();
        assert_eq!(
            read_fixture(dir.path()).unwrap().files.len(),
            2,
            "exact 512 MiB is accepted without reading payloads"
        );
    }

    #[test]
    fn fixture_refuses_png_over_20_mib_from_metadata() {
        let dir = scratch();
        sparse(&dir.path().join("image.png"), 20 * 1024 * 1024 + 1);
        let content_reads = std::cell::Cell::new(0);
        assert_eq!(
            read_fixture_with_png(dir.path(), |path| read_png_with(path, |file| {
                content_reads.set(content_reads.get() + 1);
                read_png_stream(file)
            }))
            .map(|_| ())
            .expect_err("oversize PNG was accepted")
            .code(),
            "attachment_too_large"
        );
        assert_eq!(
            content_reads.get(),
            0,
            "oversized PNG must be refused before any content reader is invoked"
        );
        std::fs::File::options()
            .write(true)
            .open(dir.path().join("image.png"))
            .unwrap()
            .set_len(20 * 1024 * 1024)
            .unwrap();
        assert_eq!(
            read_fixture(dir.path()).unwrap().image.unwrap().len(),
            20 * 1024 * 1024
        );
    }

    #[test]
    fn growing_png_stream_stops_after_20_mib_plus_one() {
        struct Counted<'a>(&'a std::cell::Cell<u64>);
        impl Read for Counted<'_> {
            fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
                buf.fill(0);
                self.0.set(self.0.get() + buf.len() as u64);
                Ok(buf.len())
            }
        }
        let count = std::cell::Cell::new(0);
        let error = read_png_stream(Counted(&count))
            .map(|_| ())
            .expect_err("unbounded PNG accepted");
        assert_eq!(error.code(), "attachment_too_large");
        assert_eq!(count.get(), 20 * 1024 * 1024 + 1);
        assert_eq!(error.details().measured, Some(count.get()));
        assert_eq!(error.details().limit, Some(20 * 1024 * 1024));
    }

    #[test]
    fn helper_protocol_output_over_one_mib_is_interop() {
        let mut command = Command::new(if cfg!(windows) {
            "powershell.exe"
        } else {
            "sh"
        });
        if cfg!(windows) {
            command.args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "[Console]::Write(('x' * 1048577))",
            ]);
        } else {
            command.args(["-c", "head -c 1048577 /dev/zero"]);
        }
        let error = attachment_run(command, &[], "synthetic helper", 1024 * 1024).unwrap_err();
        assert_eq!(error.code(), "interop");
        assert_eq!(error.exit_code(), 6);
        assert_eq!(error.details().measured, Some(1024 * 1024 + 1));
        assert_eq!(error.details().limit, Some(1024 * 1024));
        assert!(error.to_string().contains("exceeds 1048576 bytes"));
    }

    #[test]
    fn shutdown_grace_is_bounded_without_worker_completion_or_reaping() {
        use std::time::{Duration, Instant};
        // Model a pipe whose remote end cannot be closed: no completion is
        // delivered, although the root process has already been reaped.
        let (_sender, receiver) = std::sync::mpsc::channel();
        let mut written = None;
        let mut bytes = None;
        let mut drained = None;
        let started = Instant::now();
        assert!(!await_helper_shutdown(
            &receiver,
            || Ok(true),
            &mut written,
            &mut bytes,
            &mut drained,
            Duration::from_millis(100)
        )
        .unwrap());
        assert!(started.elapsed() >= Duration::from_millis(100));
        assert!(started.elapsed() < Duration::from_millis(500));
        // Conversely, complete pipe workers cannot make an unreapable root
        // turn shutdown into an unbounded process wait.
        written = Some(Ok(()));
        bytes = Some(Ok(Vec::new()));
        drained = Some(Ok(0));
        let started = Instant::now();
        assert!(!await_helper_shutdown(
            &receiver,
            || Ok(false),
            &mut written,
            &mut bytes,
            &mut drained,
            Duration::from_millis(100)
        )
        .unwrap());
        assert!(started.elapsed() >= Duration::from_millis(100));
        assert!(started.elapsed() < Duration::from_millis(500));
    }

    // This test-only supervisor retains .NET Process handles before releasing
    // each helper handshake. It owns descendant cleanup independently of capture
    // and imposes its own watchdog, including for the no-grace mutation.
    #[cfg(windows)]
    const TREE_TEST_SUPERVISOR: &str = r#"
$ErrorActionPreference = 'Stop'
$root = $env:TASKS_CLIPBOARD_TREE_ROOT
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $env:TASKS_CLIPBOARD_TEST_EXE
$info.Arguments = '--exact clipboard::tests::helper_tree_invariant_worker --ignored --nocapture'
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$worker = [Diagnostics.Process]::Start($info)
$null = $worker.Handle
$held = New-Object 'Collections.Generic.List[Diagnostics.Process]'
$states = @{}
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    while (-not $worker.WaitForExit(5)) {
        foreach ($mode in @('timeout', 'overflow', 'exit')) {
            $parentPath = Join-Path $root "$mode.parent"
            $descendantPath = Join-Path $root "$mode.pid"
            if (-not $states.ContainsKey($mode) -and (Test-Path -LiteralPath $parentPath) -and (Test-Path -LiteralPath $descendantPath)) {
                $parentProcess = [Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($parentPath))
                $null = $parentProcess.Handle
                $held.Add($parentProcess)
                $descendant = [Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($descendantPath))
                $null = $descendant.Handle
                $held.Add($descendant)
                $states[$mode] = @{ Parent = $parentProcess; Descendant = $descendant; Cleaned = $false }
                [IO.File]::WriteAllText((Join-Path $root "$mode.ack"), 'go')
            }
            if ($states.ContainsKey($mode) -and -not $states[$mode].Cleaned -and (Test-Path -LiteralPath (Join-Path $root "$mode.done"))) {
                $state = $states[$mode]
                if (-not $state.Parent.WaitForExit(500)) { throw "$mode direct helper still alive" }
                if ($state.Descendant.HasExited) { throw "$mode descendant did not keep inherited pipes open" }
                $state.Descendant.Kill()
                if (-not $state.Descendant.WaitForExit(500)) { throw "$mode descendant cleanup failed" }
                $state.Cleaned = $true
                [Console]::WriteLine("$mode bounded return in $([double]::Parse([IO.File]::ReadAllText((Join-Path $root "$mode.done"))) / 1000) ms; direct helper gone; descendant cleaned by test handle")
                [IO.File]::WriteAllText((Join-Path $root "$mode.cleaned"), 'done')
            }
        }
        if ($timer.ElapsedMilliseconds -gt 12000) { throw 'bounded-return supervisor timed out' }
    }
    if ($worker.ExitCode -ne 0) { throw "invariant worker failed: $($worker.ExitCode)" }
    if ($states.Count -ne 3) { throw 'invariant did not run all three cases' }
} finally {
    foreach ($process in $held) {
        try {
            if (-not $process.HasExited) { $process.Kill() }
            if (-not $process.WaitForExit(500)) { throw 'retained process cleanup failed' }
        } finally { $process.Dispose() }
    }
    try {
        if (-not $worker.HasExited) { $worker.Kill() }
        if (-not $worker.WaitForExit(500)) { throw 'worker cleanup failed' }
    } finally { $worker.Dispose() }
}
"#;

    #[cfg(windows)]
    fn publish_tree_signal(
        path: impl AsRef<Path>,
        content: impl AsRef<[u8]>,
    ) -> std::io::Result<()> {
        // The supervisor must never observe an empty/partially written PID or
        // duration. Rename publishes the complete file in the same directory.
        let path = path.as_ref();
        let mut pending = path.as_os_str().to_os_string();
        pending.push(".pending");
        std::fs::write(&pending, content)?;
        std::fs::rename(pending, path)
    }

    #[cfg(windows)]
    fn wait_test_child(
        child: &mut std::process::Child,
        timeout: std::time::Duration,
    ) -> Option<std::process::ExitStatus> {
        let started = std::time::Instant::now();
        while started.elapsed() < timeout {
            if let Some(status) = child.try_wait().unwrap() {
                return Some(status);
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        None
    }

    #[cfg(windows)]
    #[test]
    fn helper_tree_shutdown_invariant_supervised() {
        use std::os::windows::process::CommandExt;
        use std::time::Duration;
        let dir = tempfile::tempdir().unwrap();
        let script_path = dir.path().join("supervisor.ps1");
        std::fs::write(&script_path, TREE_TEST_SUPERVISOR).unwrap();
        let log_path = dir.path().join("worker.log");
        let log = std::fs::File::create(&log_path).unwrap();
        let mut supervisor = Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-File"])
            .arg(&script_path)
            .env("TASKS_CLIPBOARD_TREE_WORKER", "1")
            .env("TASKS_CLIPBOARD_TREE_ROOT", dir.path())
            .env("TASKS_CLIPBOARD_TEST_EXE", std::env::current_exe().unwrap())
            .creation_flags(0x08000000)
            .stdout(log.try_clone().unwrap())
            .stderr(log)
            .spawn()
            .unwrap();
        let status = wait_test_child(&mut supervisor, Duration::from_secs(20));
        if status.is_none() {
            // Last-resort test watchdog only, never the production capture path.
            // The retained Child handle reserves this owned supervisor's identity.
            let mut cleanup = Command::new("taskkill.exe")
                .args(["/PID", &supervisor.id().to_string(), "/T", "/F"])
                .creation_flags(0x08000000)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            if wait_test_child(&mut cleanup, Duration::from_secs(2)).is_none() {
                let _ = cleanup.kill();
            }
            assert!(wait_test_child(&mut cleanup, Duration::from_millis(500)).is_some());
            let _ = supervisor.kill();
            assert!(wait_test_child(&mut supervisor, Duration::from_millis(500)).is_some());
        }
        eprintln!("{}", std::fs::read_to_string(&log_path).unwrap());
        assert!(
            status.is_some_and(|status| status.success()),
            "bounded-return supervisor failed or timed out"
        );
    }

    #[cfg(windows)]
    #[test]
    #[ignore = "synthetic subprocess entry point; invoked by the supervised invariant"]
    fn helper_tree_invariant_worker() {
        use std::time::{Duration, Instant};
        assert_eq!(std::env::var("TASKS_CLIPBOARD_TREE_WORKER").unwrap(), "1");
        let root = PathBuf::from(std::env::var_os("TASKS_CLIPBOARD_TREE_ROOT").unwrap());
        for mode in ["timeout", "overflow", "exit"] {
            let ack_path = root.join(format!("{mode}.ack"));
            let mut command = Command::new(std::env::current_exe().unwrap());
            command
                .args([
                    "--exact",
                    "clipboard::tests::synthetic_tree_helper",
                    "--ignored",
                    "--nocapture",
                ])
                .env("TASKS_CLIPBOARD_HELPER_MODE", mode)
                .env(
                    "TASKS_CLIPBOARD_DESCENDANT_PID",
                    root.join(format!("{mode}.pid")),
                )
                .env("TASKS_CLIPBOARD_DESCENDANT_ACK", &ack_path);
            let started = Instant::now();
            let result = attachment_run_with_deadline(
                command,
                &vec![b'x'; 2 * 1024 * 1024],
                "bounded-return invariant helper",
                MAX_CLIPBOARD_LIST,
                Duration::from_secs(2),
                |pid| {
                    publish_tree_signal(root.join(format!("{mode}.parent")), pid.to_string())
                        .unwrap();
                    let until = Instant::now() + Duration::from_secs(4);
                    while !ack_path.exists() && Instant::now() < until {
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    assert!(
                        ack_path.exists(),
                        "supervisor did not retain process handles"
                    );
                },
            );
            let elapsed = started.elapsed();
            // Signal even on a bad capture result so the supervisor cleans by
            // retained handles before any result/bound assertion can panic.
            publish_tree_signal(
                root.join(format!("{mode}.done")),
                elapsed.as_micros().to_string(),
            )
            .unwrap();
            let cleaned = root.join(format!("{mode}.cleaned"));
            let until = Instant::now() + Duration::from_secs(3);
            while !cleaned.exists() && Instant::now() < until {
                std::thread::sleep(Duration::from_millis(5));
            }
            assert!(
                cleaned.exists(),
                "supervisor did not confirm helper exit and descendant cleanup"
            );
            assert!(
                elapsed < Duration::from_secs(3),
                "{mode}: exceeded deadline + 500 ms grace + scheduling margin: {elapsed:?}"
            );
            let error = result.expect_err("an inherited pipe stayed open past grace");
            assert_eq!(error.code(), "interop");
            assert_eq!(error.exit_code(), 6);
            match mode {
                "timeout" => {
                    assert_eq!(error.details().unit, Some("milliseconds"));
                    assert_eq!(error.details().limit, Some(2000));
                    assert!(error.details().elapsed_ms.unwrap() >= 2000);
                }
                "overflow" => {
                    assert_eq!(error.details().unit, Some("bytes"));
                    assert_eq!(error.details().measured, Some(MAX_CLIPBOARD_LIST + 1));
                    assert!(error.details().elapsed_ms.unwrap() < 2000);
                }
                "exit" => {
                    assert_eq!(error.details().unit, Some("milliseconds"));
                    assert_eq!(error.details().limit, Some(500));
                    assert!(error.to_string().contains("shutdown did not complete"));
                }
                _ => unreachable!(),
            }
            eprintln!("{mode}: bounded return in {elapsed:?}; direct helper gone; descendant cleaned by test handle");
        }
    }

    #[cfg(windows)]
    #[test]
    #[ignore = "synthetic subprocess entry point; invoked by the supervised invariant"]
    #[allow(clippy::zombie_processes)] // Normal parent exit is the deliberate fixture.
    fn synthetic_tree_helper() {
        use std::time::{Duration, Instant};
        let mode = std::env::var("TASKS_CLIPBOARD_HELPER_MODE").unwrap();
        if mode == "descendant" {
            // Publish readiness after libtest has emitted its startup output,
            // before the parent can fill and close the bounded stdout reader.
            publish_tree_signal(
                std::env::var_os("TASKS_CLIPBOARD_DESCENDANT_READY").unwrap(),
                b"ready",
            )
            .unwrap();
            loop {
                std::thread::sleep(Duration::from_secs(60));
            }
        }
        let ready = PathBuf::from(std::env::var_os("TASKS_CLIPBOARD_DESCENDANT_PID").unwrap())
            .with_extension("ready");
        let mut command = Command::new(std::env::current_exe().unwrap());
        command.env("TASKS_CLIPBOARD_DESCENDANT_READY", &ready);
        command
            .args([
                "--exact",
                "clipboard::tests::synthetic_tree_helper",
                "--ignored",
                "--nocapture",
            ])
            .env("TASKS_CLIPBOARD_HELPER_MODE", "descendant")
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
        let mut descendant = command.spawn().unwrap();
        let ack = PathBuf::from(std::env::var_os("TASKS_CLIPBOARD_DESCENDANT_ACK").unwrap());
        // Until the supervisor has retained the descendant's handle, its own
        // parent keeps the Child handle and cleans it on a handshake failure.
        let ready_until = Instant::now() + Duration::from_secs(2);
        while !ready.exists() && Instant::now() < ready_until {
            std::thread::sleep(Duration::from_millis(5));
        }
        if !ready.exists() {
            let _ = descendant.kill();
            assert!(wait_test_child(&mut descendant, Duration::from_millis(500)).is_some());
            panic!("descendant did not become ready");
        }
        let publish = publish_tree_signal(
            std::env::var_os("TASKS_CLIPBOARD_DESCENDANT_PID").unwrap(),
            descendant.id().to_string(),
        );
        let until = Instant::now() + Duration::from_secs(5);
        while publish.is_ok() && !ack.exists() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(5));
        }
        if publish.is_err() || !ack.exists() {
            let _ = descendant.kill();
            assert!(wait_test_child(&mut descendant, Duration::from_millis(500)).is_some());
            panic!("supervisor handshake failed");
        }
        match mode.as_str() {
            "overflow" => {
                std::io::stdout()
                    .write_all(&vec![b'x'; 1024 * 1024 + 1])
                    .unwrap();
                std::io::stdout().flush().unwrap();
            }
            "exit" => {
                println!("parent completed");
                return;
            }
            "timeout" => {}
            _ => panic!("unknown mode"),
        }
        // The direct helper and its descendant both stall indefinitely. Only
        // the capture owner stops the helper; the supervisor stops descendants.
        loop {
            std::thread::sleep(Duration::from_secs(60));
        }
    }

    #[test]
    fn token_verification_and_empty_errors_expose_stable_mapping_data() {
        let capture = ClipboardCapture {
            image: Some(b"png".to_vec()),
            ..Default::default()
        };
        verify_capture_token(&capture, &capture_token(&capture)).unwrap();
        let changed = verify_capture_token(&capture, "stale").unwrap_err();
        assert_eq!(changed.code(), "clipboard_changed");
        assert_eq!(changed.exit_code(), 4);
        assert_eq!(changed.details().measured, None);
        let empty = require_content(ClipboardCapture::default()).unwrap_err();
        let json = serde_json::to_value(empty.details()).unwrap();
        assert_eq!(json["code"], "clipboard_empty");
        assert_eq!(json["exit_code"], 2);
        assert!(json["limit"].is_null());
    }

    #[test]
    fn attachment_commands_select_exact_targets() {
        for (backend, target, program, args) in [
            (Backend::Wayland, None, "wl-paste", vec!["--list-types"]),
            (
                Backend::Wayland,
                Some("image/png"),
                "wl-paste",
                vec!["--no-newline", "--type", "image/png"],
            ),
            (
                Backend::X11,
                None,
                "xclip",
                vec!["-selection", "clipboard", "-t", "TARGETS", "-o"],
            ),
            (
                Backend::X11,
                Some("text/uri-list"),
                "xclip",
                vec!["-selection", "clipboard", "-t", "text/uri-list", "-o"],
            ),
        ] {
            let command = linux_clipboard_command(&backend, target);
            assert_eq!(command.get_program(), program);
            assert_eq!(command.get_args().collect::<Vec<_>>(), args);
        }
    }

    #[test]
    fn attachment_transport_caps_output_and_does_not_echo_diagnostics() {
        let mut command = Command::new(if cfg!(windows) {
            "powershell.exe"
        } else {
            "sh"
        });
        if cfg!(windows) {
            command.args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "[Console]::Write('0123456789')",
            ]);
        } else {
            command.args(["-c", "printf 0123456789"]);
        }
        let error = attachment_run(command, &[], "synthetic helper", 4).unwrap_err();
        assert!(error.to_string().contains("exceeds 4 bytes"));
        let mut command = Command::new(if cfg!(windows) {
            "powershell.exe"
        } else {
            "sh"
        });
        if cfg!(windows) {
            command.args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "[Console]::Error.Write('SECRET'); exit 7",
            ]);
        } else {
            command.args(["-c", "printf SECRET >&2; exit 7"]);
        }
        let error = attachment_run(command, &[], "synthetic helper", 100).unwrap_err();
        assert!(error.to_string().contains("failed"));
        assert!(!error.to_string().contains("SECRET"));
    }

    /// Owner-run only: repeat for screenshot, registered PNG, and Explorer file copy.
    /// Set TASKS_TEST_REAL_CLIPBOARD=1 and TASKS_TEST_CLIPBOARD_KIND=image|file,
    /// then run this ignored test explicitly after placing that item on the clipboard.
    #[cfg(windows)]
    #[test]
    #[ignore = "requires owner consent and real clipboard preparation"]
    fn manual_real_clipboard_attachment_capture() {
        assert_eq!(
            std::env::var("TASKS_TEST_REAL_CLIPBOARD").as_deref(),
            Ok("1"),
            "owner opt-in required"
        );
        assert!(
            std::env::var_os("TASKS_TEST_CLIPBOARD_FIXTURE").is_none(),
            "remove fixture override for real proof"
        );
        let kind = std::env::var("TASKS_TEST_CLIPBOARD_KIND").expect("set image or file");
        assert!(matches!(kind.as_str(), "image" | "file"));
        let dir = scratch();
        let capture = read_attachments(dir.path()).unwrap();
        if kind == "image" {
            assert!(capture
                .image
                .as_ref()
                .unwrap()
                .starts_with(b"\x89PNG\r\n\x1a\n"));
        } else {
            assert!(!capture.files.is_empty());
        }
        assert_eq!(capture_token(&capture).len(), 64);
        assert!(
            std::fs::read_dir(dir.path()).unwrap().next().is_none(),
            "helper image was removed"
        );
    }
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
