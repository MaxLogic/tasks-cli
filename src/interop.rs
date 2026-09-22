use crate::cli::{Cli, Command};
use crate::error::AppError;
use std::path::{Path, PathBuf};
use std::process::{Command as ProcessCommand, Stdio};

fn is_wsl() -> bool {
    cfg!(target_os = "linux")
        && (std::env::var_os("WSL_INTEROP").is_some()
            || std::env::var_os("WSL_DISTRO_NAME").is_some()
            || std::fs::read_to_string("/proc/version")
                .map(|v| v.to_ascii_lowercase().contains("microsoft"))
                .unwrap_or(false))
}

pub fn should_delegate(cli: &Cli) -> bool {
    cfg!(target_os = "linux")
        && is_wsl()
        && (cli.windows_exe.is_some() || std::env::var_os("TASKS_WINDOWS_EXE").is_some())
}

pub fn has_backend(cli: &Cli) -> bool {
    cli.windows_exe.is_some() || std::env::var_os("TASKS_WINDOWS_EXE").is_some()
}

fn translate(path: &Path) -> Result<PathBuf, AppError> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|err| AppError::io_op("resolve the current directory", err))?
            .join(path)
    };
    let output = ProcessCommand::new("wslpath")
        .arg("-w")
        .arg(&absolute)
        .output()
        .map_err(|err| {
            AppError::Interop(format!(
                "cannot run wslpath to convert {}: {err}; install WSL or put wslpath on PATH",
                absolute.display()
            ))
        })?;
    if !output.status.success() {
        return Err(AppError::Interop(format!(
            "wslpath -w {} failed: {}",
            absolute.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if value.is_empty() {
        return Err(AppError::Interop(format!(
            "wslpath returned an empty Windows path for {}; check that the path exists",
            absolute.display()
        )));
    }
    Ok(PathBuf::from(value.replace('\\', "/")))
}

fn path_flag(arg: &str) -> Option<(&'static str, Option<&str>)> {
    for flag in [
        "--root",
        "--route-root",
        "--data-root",
        "--request-file",
        "--body-file",
        "--map-file",
        "--file",
        "--out",
        "--scan-root",
        "--report-dir",
        "--quarantine-dir",
    ] {
        if arg == flag {
            return Some((flag, None));
        }
        if let Some(value) = arg.strip_prefix(&format!("{flag}=")) {
            return Some((flag, Some(value)));
        }
    }
    None
}

// Derive value-taking options from Clap so adding an option does not silently
// turn its literal value into a path or delegation flag.
fn value_flags() -> std::collections::HashSet<String> {
    use clap::CommandFactory;
    fn collect(command: &clap::Command, flags: &mut std::collections::HashSet<String>) {
        for arg in command.get_arguments() {
            if arg.get_action().takes_values() {
                if let Some(long) = arg.get_long() {
                    flags.insert(format!("--{long}"));
                }
            }
        }
        for child in command.get_subcommands() {
            collect(child, flags);
        }
    }
    let mut flags = std::collections::HashSet::new();
    collect(&Cli::command(), &mut flags);
    flags
}

fn convert_args(
    args: &[String],
    translate: impl Fn(&Path) -> Result<PathBuf, AppError>,
) -> Result<Vec<String>, AppError> {
    let values = value_flags();
    let mut out = Vec::with_capacity(args.len());
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if arg == "--" {
            out.extend_from_slice(&args[index..]);
            break;
        }
        let (flag, inline) = arg
            .split_once('=')
            .map_or((arg.as_str(), None), |(flag, value)| (flag, Some(value)));
        if values.contains(flag) {
            let value = inline.or_else(|| args.get(index + 1).map(String::as_str));
            if flag != "--windows-exe" {
                if let Some(value) = value {
                    let value = if path_flag(flag).is_some() && value != "-" {
                        translate(Path::new(value))?.to_string_lossy().into_owned()
                    } else {
                        value.to_owned()
                    };
                    if inline.is_some() {
                        out.push(format!("{flag}={value}"));
                    } else {
                        out.push(arg.clone());
                        out.push(value);
                    }
                } else {
                    out.push(arg.clone());
                }
            }
            index += if inline.is_some() { 1 } else { 2 };
        } else {
            out.push(arg.clone());
            index += 1;
        }
    }
    Ok(out)
}

fn should_inject_project_context(cli: &Cli) -> bool {
    cli.project.is_none()
        && !matches!(
            &cli.command,
            Command::Init { .. } | Command::Bind { .. } | Command::BulkImport { .. }
        )
}

pub fn delegate(cli: &Cli) -> Result<i32, AppError> {
    if !should_delegate(cli) {
        return Err(AppError::Interop(
            "cannot delegate: this is not WSL, or no Windows backend is configured; run the command on Windows, or from WSL pass --windows-exe <path> or set TASKS_WINDOWS_EXE"
                .to_string(),
        ));
    }
    let exe = cli
        .windows_exe
        .clone()
        .or_else(|| std::env::var_os("TASKS_WINDOWS_EXE").map(PathBuf::from))
        .ok_or_else(|| {
            AppError::Interop(
                "no Windows backend executable: pass --windows-exe <path> or set TASKS_WINDOWS_EXE"
                    .to_string(),
            )
        })?;
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    let mut child_args = convert_args(&args, translate)?;
    if should_inject_project_context(cli) {
        if let Some(project) = std::env::var_os("TASKS_PROJECT") {
            child_args.insert(0, project.to_string_lossy().to_string());
            child_args.insert(0, "--project".to_string());
        } else {
            let route_root = translate(
                &std::env::current_dir()
                    .map_err(|err| AppError::io_op("resolve the current directory", err))?,
            )?
            .to_string_lossy()
            .to_string();
            child_args.insert(0, route_root);
            child_args.insert(0, "--route-root".to_string());
        }
    }
    let status = ProcessCommand::new(&exe)
        .args(child_args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .env_remove("TASKS_WINDOWS_EXE")
        .status()
        .map_err(|err| {
            AppError::Interop(format!(
                "cannot start Windows backend {}: {err}; check --windows-exe or TASKS_WINDOWS_EXE",
                exe.display()
            ))
        })?;
    Ok(status.code().unwrap_or(6))
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn delegation_preserves_literals_after_separator_and_option_values() {
        for args in [
            vec!["search", "--", "--out=needle"],
            vec!["search", "--", "--windows-exe=needle"],
            vec!["create", "--title", "--out=needle", "--body-file", "-"],
            vec![
                "create",
                "--title",
                "--windows-exe=needle",
                "--body-file",
                "-",
            ],
        ] {
            let args: Vec<String> = args.into_iter().map(str::to_owned).collect();
            let result = convert_args(&args, |path| {
                Ok(PathBuf::from(format!("translated:{}", path.display())))
            })
            .unwrap();
            assert_eq!(result, args);
        }
    }

    #[test]
    fn inline_path_flags_are_recognized_without_touching_text() {
        assert_eq!(
            path_flag("--request-file=requests/projects.json"),
            Some(("--request-file", Some("requests/projects.json")))
        );
        assert_eq!(path_flag("--request-file"), Some(("--request-file", None)));
        assert_eq!(
            path_flag("--body-file=notes with Ω.md"),
            Some(("--body-file", Some("notes with Ω.md")))
        );
        assert_eq!(path_flag("--body-file"), Some(("--body-file", None)));
        assert_eq!(
            path_flag("--route-root=C:\\work tree"),
            Some(("--route-root", Some("C:\\work tree")))
        );
        assert_eq!(path_flag("search text_%\\literal"), None);
    }

    #[test]
    fn viewer_request_files_are_translated_like_other_path_flags() {
        let args: Vec<String> = [
            "viewer",
            "projects",
            "--request-file",
            "requests/projects.json",
            "--data-root",
            "/mnt/f/root",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
        let result = convert_args(&args, |path| {
            Ok(PathBuf::from(format!("translated:{}", path.display())))
        })
        .expect("converted args");
        assert_eq!(
            result,
            [
                "viewer",
                "projects",
                "--request-file",
                "translated:requests/projects.json",
                "--data-root",
                "translated:/mnt/f/root",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect::<Vec<String>>()
        );
        let stdin: Vec<String> = ["viewer", "projects", "--request-file", "-"]
            .into_iter()
            .map(str::to_owned)
            .collect();
        assert_eq!(
            convert_args(&stdin, |path| {
                Ok(PathBuf::from(format!("translated:{}", path.display())))
            })
            .expect("converted stdin args"),
            stdin
        );
    }

    #[test]
    fn init_and_bind_do_not_inherit_project_routing_context() {
        let init =
            Cli::try_parse_from(["tasks", "init", "--root", "C:\\work"]).expect("init parse");
        assert!(!should_inject_project_context(&init));
        let bind = Cli::try_parse_from([
            "tasks",
            "bind",
            "--root",
            "C:\\work",
            "--project",
            "00000000-0000-0000-0000-000000000000",
        ])
        .expect("bind parse");
        assert!(!should_inject_project_context(&bind));
        let list = Cli::try_parse_from(["tasks", "list"]).expect("list parse");
        assert!(should_inject_project_context(&list));
    }
}
