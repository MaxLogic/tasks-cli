//! Required WSL gate with real Linux tasks and this lane's test tasks.exe.
#![cfg(target_os = "linux")]
mod support;
use serde_json::Value;
use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
};
use tempfile::TempDir;

fn windows(path: &Path) -> String {
    let output = Command::new("wslpath")
        .arg("-w")
        .arg(path)
        .output()
        .unwrap();
    assert!(output.status.success(), "wslpath: {:?}", output);
    String::from_utf8(output.stdout).unwrap().trim_end().into()
}
fn data(output: Output) -> Value {
    assert!(
        output.status.success(),
        "exit {:?}: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!String::from_utf8_lossy(&output.stdout).contains("TASKATT1"));
    serde_json::from_slice::<Value>(&output.stdout).unwrap()["data"].clone()
}
struct Fixture {
    windows_root: TempDir,
    linux_root: TempDir,
    exe: PathBuf,
    project: String,
}
impl Fixture {
    fn new() -> Self {
        let exe =
            PathBuf::from(std::env::var_os("TASKS_TEST_WINDOWS_EXE").expect(
                "required WSL gate: set TASKS_TEST_WINDOWS_EXE to this lane's test tasks.exe",
            ));
        assert!(
            exe.ends_with("tasks.exe") && exe.to_string_lossy().contains("verify-cli"),
            "must use a lane test binary: {}",
            exe.display()
        );
        let parent = PathBuf::from(
            std::env::var_os("TASKS_TEST_WINDOWS_TEMP")
                .expect("set TASKS_TEST_WINDOWS_TEMP to the lane's Windows-owned scratch parent"),
        );
        assert!(parent.starts_with("/mnt/"));
        let windows_root = tempfile::tempdir_in(parent).unwrap();
        let linux_root = tempfile::tempdir().unwrap();
        assert!(!linux_root.path().starts_with("/mnt/"));
        let root = windows_root.path().join("project");
        fs::create_dir(&root).unwrap();
        let init = data(
            support::process::command(&exe)
                .env_remove("TASKS_WINDOWS_EXE")
                .env_remove("TASKS_PROJECT")
                .args([
                    "--data-root",
                    &windows(windows_root.path()),
                    "--format",
                    "json",
                    "init",
                    "--root",
                    &windows(&root),
                    "--key",
                    "C2",
                ])
                .output()
                .unwrap(),
        );
        let project = init["project_id"].as_str().unwrap().to_owned();
        let f = Self {
            windows_root,
            linux_root,
            exe,
            project,
        };
        let body = f.linux_root.path().join("body.txt");
        fs::write(&body, b"delegation fixture").unwrap();
        data(
            f.cmd(&[
                "create",
                "--title",
                "delegation",
                "--body-file",
                body.to_str().unwrap(),
            ])
            .output()
            .unwrap(),
        );
        f
    }
    fn cmd(&self, args: &[&str]) -> Command {
        let mut cmd = support::process::command(env!("CARGO_BIN_EXE_tasks"));
        cmd.env_remove("TASKS_WINDOWS_EXE")
            .env_remove("TASKS_PROJECT")
            .args([
                "--windows-exe",
                self.exe.to_str().unwrap(),
                "--data-root",
                self.windows_root.path().to_str().unwrap(),
                "--project",
                &self.project,
                "--format",
                "json",
            ])
            .args(args);
        cmd
    }
    fn add(&self) {
        let source = self.linux_root.path().join("Linux Ω.txt");
        fs::write(&source, b"Linux file\n").unwrap();
        let add = data(
            self.cmd(&[
                "attachment",
                "add",
                "1",
                "--expect-version",
                "1",
                "--file",
                source.to_str().unwrap(),
            ])
            .output()
            .unwrap(),
        );
        assert_eq!(add["attachments"][0]["name"], "Linux Ω.txt");
        let mut child = self
            .cmd(&[
                "attachment",
                "add",
                "1",
                "--expect-version",
                "2",
                "--file",
                "-",
                "--name",
                "stdin.txt",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"stdin bytes\n")
            .unwrap();
        assert_eq!(data(child.wait_with_output().unwrap())["version"], 3);
    }
}

#[test]
fn real_binaries_convert_file_stdin_default_cache_and_linux_out_in_both_formats() {
    let f = Fixture::new();
    f.add();
    for format in ["json", "text"] {
        for explicit in [false, true] {
            let out = f.linux_root.path().join(format!("out-{format}"));
            fs::create_dir_all(&out).unwrap();
            let mut args = vec!["attachment", "get", "1", "--format", format];
            if explicit {
                args.extend(["--out", out.to_str().unwrap()]);
            }
            let output = f.cmd(&args).output().unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            let paths: Vec<String> = if format == "json" {
                data(output)["items"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|i| i["path"].as_str().unwrap().into())
                    .collect()
            } else {
                String::from_utf8(output.stdout)
                    .unwrap()
                    .lines()
                    .map(str::to_owned)
                    .collect()
            };
            assert_eq!(paths.len(), 2);
            for (index, path) in paths.iter().enumerate() {
                if explicit {
                    assert!(Path::new(path).starts_with(&out), "{path}");
                } else {
                    assert!(path.starts_with("/mnt/"), "{path}");
                }
                assert_eq!(
                    fs::read(path).unwrap(),
                    if index == 0 {
                        b"Linux file\n".as_slice()
                    } else {
                        b"stdin bytes\n".as_slice()
                    }
                );
            }
        }
    }
    // Nonzero child exit and stderr pass through unchanged; stdout stays empty.
    let failed = f.cmd(&["attachment", "get", "1", "A999"]).output().unwrap();
    assert_eq!(failed.status.code(), Some(3));
    assert!(failed.stdout.is_empty());
    let error: Value = serde_json::from_slice(&failed.stderr).unwrap();
    assert_eq!(error["error"]["code"], "not_found");
}

#[test]
fn reverse_conversion_failure_emits_no_stdout_and_names_the_written_windows_path() {
    let f = Fixture::new();
    f.add();
    let shim = f.linux_root.path().join("shim");
    fs::create_dir(&shim).unwrap();
    let script = shim.join("wslpath");
    fs::write(&script, "#!/bin/sh\nif [ \"$1\" = \"-u\" ]; then echo c2-conversion-refusal >&2; exit 23; fi\nexec /usr/bin/wslpath \"$@\"\n").unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
    let mut paths = vec![shim];
    paths.extend(std::env::split_paths(&std::env::var_os("PATH").unwrap()));
    for format in ["text", "json"] {
        let out = f.linux_root.path().join(format!("written-{format}.txt"));
        let output = f
            .cmd(&[
                "attachment",
                "get",
                "1",
                "A1",
                "--out",
                out.to_str().unwrap(),
                "--format",
                format,
            ])
            .env("PATH", std::env::join_paths(&paths).unwrap())
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(6));
        assert!(output.stdout.is_empty());
        let message = if format == "json" {
            serde_json::from_slice::<Value>(&output.stderr).unwrap()["error"]["message"]
                .as_str()
                .unwrap()
                .to_owned()
        } else {
            String::from_utf8(output.stderr).unwrap()
        };
        assert!(
            message.contains("already-written Windows path")
                && message.contains("c2-conversion-refusal"),
            "{message}"
        );
        assert!(message.contains(&windows(&out)), "{message}");
        assert_eq!(fs::read(out).unwrap(), b"Linux file\n");
    }
}

#[test]
fn clipboard_inspection_and_token_add_run_in_the_windows_backend() {
    let f = Fixture::new();
    let fixture = f.windows_root.path().join("clipboard");
    fs::create_dir(&fixture).unwrap();
    let source = fixture.join("Windows clipboard.txt");
    fs::write(&source, b"Windows fixture").unwrap();
    fs::write(
        fixture.join("files.json"),
        serde_json::to_vec(&vec![windows(&source)]).unwrap(),
    )
    .unwrap();
    let wslenv = format!(
        "{}:TASKS_TEST_CLIPBOARD_FIXTURE",
        std::env::var("WSLENV").unwrap_or_default()
    );
    let configure = |cmd: &mut Command| {
        cmd.env("TASKS_TEST_CLIPBOARD_FIXTURE", windows(&fixture))
            .env("WSLENV", &wslenv);
    };
    let mut cmd = f.cmd(&["attachment", "clipboard"]);
    configure(&mut cmd);
    let inspected = data(cmd.output().unwrap());
    assert_eq!(inspected["items"][0]["path"], windows(&source));
    let mut cmd = f.cmd(&[
        "attachment",
        "add",
        "1",
        "--expect-version",
        "1",
        "--clipboard",
        "--clipboard-token",
        inspected["token"].as_str().unwrap(),
    ]);
    configure(&mut cmd);
    assert_eq!(
        data(cmd.output().unwrap())["attachments"][0]["name"],
        "Windows clipboard.txt"
    );
    let get = data(f.cmd(&["attachment", "get", "1"]).output().unwrap());
    assert_eq!(
        fs::read(get["items"][0]["path"].as_str().unwrap()).unwrap(),
        b"Windows fixture"
    );
}
