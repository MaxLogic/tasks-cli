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
        std::env::current_dir()?.join(path)
    };
    let output = ProcessCommand::new("wslpath")
        .arg("-w")
        .arg(&absolute)
        .output()
        .map_err(|err| AppError::Interop(format!("cannot run wslpath: {err}")))?;
    if !output.status.success() {
        return Err(AppError::Interop(
            String::from_utf8_lossy(&output.stderr).trim().to_string(),
        ));
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if value.is_empty() {
        return Err(AppError::Interop(
            "wslpath returned an empty path".to_string(),
        ));
    }
    Ok(PathBuf::from(value.replace('\\', "/")))
}

fn path_flag(arg: &str) -> Option<(&'static str, Option<&str>)> {
    for flag in [
        "--root",
        "--route-root",
        "--data-root",
        "--body-file",
        "--map-file",
        "--file",
        "--out",
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

fn convert_args(args: &[String]) -> Result<Vec<String>, AppError> {
    let mut out = Vec::with_capacity(args.len());
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if let Some((flag, inline)) = path_flag(arg) {
            if let Some(value) = inline {
                if value == "-" {
                    out.push(arg.clone());
                } else {
                    out.push(format!(
                        "{flag}={}",
                        translate(Path::new(value))?.to_string_lossy()
                    ));
                }
            } else {
                out.push(arg.clone());
                if index + 1 < args.len() && args[index + 1] != "-" {
                    index += 1;
                    out.push(
                        translate(Path::new(&args[index]))?
                            .to_string_lossy()
                            .to_string(),
                    );
                }
            }
        } else {
            out.push(arg.clone());
        }
        index += 1;
    }
    Ok(out)
}

fn should_inject_project_context(cli: &Cli) -> bool {
    cli.project.is_none() && !matches!(&cli.command, Command::Init { .. } | Command::Bind { .. })
}

pub fn delegate(cli: &Cli) -> Result<i32, AppError> {
    if !should_delegate(cli) {
        return Err(AppError::Interop(
            "delegation is only available from WSL".to_string(),
        ));
    }
    let exe = cli
        .windows_exe
        .clone()
        .or_else(|| std::env::var_os("TASKS_WINDOWS_EXE").map(PathBuf::from))
        .ok_or_else(|| AppError::Interop("missing Windows executable".to_string()))?;
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    let mut filtered = Vec::with_capacity(args.len());
    let mut index = 0;
    while index < args.len() {
        if args[index] == "--windows-exe" {
            index += 2;
            continue;
        }
        if args[index].starts_with("--windows-exe=") {
            index += 1;
            continue;
        }
        filtered.push(args[index].clone());
        index += 1;
    }
    let mut child_args = convert_args(&filtered)?;
    if should_inject_project_context(cli) {
        if let Some(project) = std::env::var_os("TASKS_PROJECT") {
            child_args.insert(0, project.to_string_lossy().to_string());
            child_args.insert(0, "--project".to_string());
        } else {
            let route_root = translate(&std::env::current_dir()?)?
                .to_string_lossy()
                .to_string();
            child_args.insert(0, route_root);
            child_args.insert(0, "--route-root".to_string());
        }
    }
    let status = ProcessCommand::new(exe)
        .args(child_args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .env_remove("TASKS_WINDOWS_EXE")
        .status()
        .map_err(|err| AppError::Interop(format!("cannot start Windows backend: {err}")))?;
    Ok(status.code().unwrap_or(6))
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn inline_path_flags_are_recognized_without_touching_text() {
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
