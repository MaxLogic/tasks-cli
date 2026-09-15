use clap::{error::ErrorKind, Parser};
use std::io::Read;
use std::path::{Path, PathBuf};
use tasks_cli::cli::{Cli, Command, OutputFormat, ParsedDeps, RulesCommand};
use tasks_cli::error::AppError;
use tasks_cli::interop;
use tasks_cli::markdown;
use tasks_cli::model::{parse_task_id, TaskStatus, TaskUpdate};
use tasks_cli::output::{CommandPayload, Envelope};
use tasks_cli::registry;
use tasks_cli::store::Store;

fn read_input(path: &Path) -> Result<Vec<u8>, AppError> {
    if path == Path::new("-") {
        let mut bytes = Vec::new();
        std::io::stdin().read_to_end(&mut bytes)?;
        Ok(bytes)
    } else {
        std::fs::read(path).map_err(|error| {
            AppError::Validation(format!("cannot read input {}: {error}", path.display()))
        })
    }
}

fn read_text(path: &Path) -> Result<String, AppError> {
    String::from_utf8(read_input(path)?)
        .map_err(|_| AppError::Validation(format!("{} is not valid UTF-8", path.display())))
}

fn resolved_root(cli: &Cli) -> Result<PathBuf, AppError> {
    let root = cli
        .data_root
        .clone()
        .unwrap_or_else(registry::default_data_root);
    tasks_cli::storage::validate_storage_root(&root)
}

fn resolved_project(cli: &Cli, data_root: &Path) -> Result<String, AppError> {
    let env_project = std::env::var("TASKS_PROJECT").ok();
    let explicit = cli.project.as_deref().or(env_project.as_deref());
    registry::resolve_project(data_root, explicit, cli.route_root.as_deref())
}

fn envelope(project_id: Option<String>, data: CommandPayload, format: OutputFormat) {
    let value = Envelope {
        schema_version: 1,
        project_id,
        data,
    };
    match format {
        OutputFormat::Json => println!("{}", value.json()),
        OutputFormat::Text => print!("{}", value.text()),
    }
}

fn execute(cli: Cli) -> Result<(), AppError> {
    if interop::has_backend(&cli) && !interop::should_delegate(&cli) {
        return Err(AppError::Interop(
            "Windows delegation is available only from WSL".to_string(),
        ));
    }
    if interop::should_delegate(&cli) {
        let code = interop::delegate(&cli)?;
        std::process::exit(code);
    }
    let data_root = resolved_root(&cli)?;
    match &cli.command {
        Command::Init { root } => {
            let explicit_project = cli
                .project
                .as_deref()
                .map(uuid::Uuid::parse_str)
                .transpose()
                .map_err(|_| AppError::Usage("invalid project id".to_string()))?;
            let info = registry::init_root(&data_root, root, explicit_project)?;
            envelope(
                Some(info.project_id.to_string()),
                CommandPayload::Init {
                    project_id: info.project_id.to_string(),
                    db_path: info.db_path.display().to_string(),
                },
                cli.format,
            );
        }
        Command::Bind { root, project } => {
            let project_id = registry::bind_root(&data_root, root, Some(project.clone()))?;
            envelope(
                Some(project_id.clone()),
                CommandPayload::Bind {
                    project_id,
                    root: root.display().to_string(),
                },
                cli.format,
            );
        }
        Command::List {
            status,
            after,
            limit,
        } => {
            let project_id = resolved_project(&cli, &data_root)?;
            let status_text = status.as_ref().map(ToString::to_string);
            let page = Store::open_readonly(&data_root, &project_id)?.list_tasks(
                status_text.as_deref(),
                *after,
                limit.unwrap_or(20),
            )?;
            envelope(
                Some(project_id),
                CommandPayload::List {
                    items: page.items,
                    has_more: page.has_more,
                    next_after: page.next_after,
                },
                cli.format,
            );
        }
        Command::Search { text, after, limit } => {
            let project_id = resolved_project(&cli, &data_root)?;
            let page = Store::open_readonly(&data_root, &project_id)?.search_tasks(
                text,
                *after,
                limit.unwrap_or(20),
            )?;
            envelope(
                Some(project_id),
                CommandPayload::Search {
                    items: page.items,
                    has_more: page.has_more,
                    next_after: page.next_after,
                },
                cli.format,
            );
        }
        Command::Show { id } => {
            let project_id = resolved_project(&cli, &data_root)?;
            let detail = Store::open_readonly(&data_root, &project_id)?.show_task(id)?;
            envelope(Some(project_id), CommandPayload::Show(detail), cli.format);
        }
        Command::History {
            id,
            after,
            limit,
            event,
        } => {
            let project_id = resolved_project(&cli, &data_root)?;
            let id = parse_task_id(id).map_err(AppError::Validation)?;
            let (page, selected) = Store::open_readonly(&data_root, &project_id)?.history(
                id,
                *after,
                limit.unwrap_or(20),
                *event,
            )?;
            let page = if let Some(event) = selected {
                tasks_cli::model::Pagination {
                    items: vec![event],
                    has_more: false,
                    next_after: None,
                }
            } else {
                page
            };
            envelope(
                Some(project_id),
                CommandPayload::History {
                    id,
                    items: page.items,
                    has_more: page.has_more,
                    next_after: page.next_after,
                },
                cli.format,
            );
        }
        Command::Migrate => {
            let project_id = resolved_project(&cli, &data_root)?;
            let mut store = Store::open_for_migration(&data_root, &project_id)?;
            let (from_version, to_version) = store.migrate()?;
            envelope(
                Some(project_id),
                CommandPayload::Migrate {
                    from_version,
                    to_version,
                },
                cli.format,
            );
        }
        _ => {
            let project_id = resolved_project(&cli, &data_root)?;
            let mut store = match &cli.command {
                Command::Rules(RulesCommand::Show)
                | Command::Export { .. }
                | Command::Import { apply: false, .. } => {
                    Store::open_readonly(&data_root, &project_id)?
                }
                Command::Doctor => Store::open_for_diagnostics(&data_root, &project_id)?,
                _ => Store::open_rw(&data_root, &project_id)?,
            };
            match cli.command.clone() {
                Command::Create {
                    title,
                    body_file,
                    status,
                    deps,
                    clear_deps,
                } => {
                    let body = read_text(&body_file)?;
                    let deps = deps
                        .map(|v| {
                            ParsedDeps::parse(&v)
                                .map(|p| p.0)
                                .map_err(AppError::Validation)
                        })
                        .transpose()?
                        .unwrap_or_default();
                    let deps = if clear_deps { Vec::new() } else { deps };
                    let status = status.unwrap_or(TaskStatus::Backlog);
                    let (id, version, event_id) =
                        store.create_task(&title, &body, status.clone(), deps)?;
                    envelope(
                        Some(project_id),
                        CommandPayload::Create {
                            id,
                            status: status.to_string(),
                            version,
                            event_id,
                        },
                        cli.format,
                    );
                }
                Command::Update {
                    id,
                    expect_version,
                    title,
                    body_file,
                    status,
                    deps,
                    clear_deps,
                } => {
                    let id = parse_task_id(&id).map_err(AppError::Validation)?;
                    let body = body_file.as_deref().map(read_text).transpose()?;
                    let deps = deps
                        .map(|v| {
                            ParsedDeps::parse(&v)
                                .map(|p| p.0)
                                .map_err(AppError::Validation)
                        })
                        .transpose()?;
                    let (id, resulting_status, version, event_id) = store.update_task(
                        id,
                        expect_version,
                        TaskUpdate {
                            title,
                            body,
                            status,
                            deps,
                            clear_deps,
                        },
                    )?;
                    envelope(
                        Some(project_id),
                        CommandPayload::Update {
                            id,
                            status: resulting_status.to_string(),
                            version,
                            event_id,
                        },
                        cli.format,
                    );
                }
                Command::Rules(RulesCommand::Show) => envelope(
                    Some(project_id),
                    CommandPayload::RulesShow(store.rules_show()?),
                    cli.format,
                ),
                Command::Rules(RulesCommand::Set {
                    body_file,
                    expect_version,
                }) => {
                    let version = store.rules_set(&read_text(&body_file)?, expect_version)?;
                    envelope(
                        Some(project_id),
                        CommandPayload::RulesSet { version },
                        cli.format,
                    );
                }
                Command::Import {
                    file,
                    apply,
                    expect_sha256,
                    map_file,
                } => {
                    let bytes = read_input(&file)?;
                    let parsed =
                        markdown::parse(file.display().to_string(), bytes, map_file.as_deref())?;
                    if let Some(expected) = expect_sha256.as_deref() {
                        if !expected.eq_ignore_ascii_case(&parsed.source_hash) {
                            return Err(AppError::ShaMismatch {
                                expected: expected.to_string(),
                                actual: parsed.source_hash,
                            });
                        }
                    }
                    let report = if apply {
                        let expected = expect_sha256.as_deref().ok_or_else(|| {
                            AppError::Usage("--expect-sha256 is required with --apply".to_string())
                        })?;
                        if file == Path::new("-") {
                            return Err(AppError::Usage(
                                "--apply requires a re-readable import file".to_string(),
                            ));
                        }
                        let reread = read_input(&file)?;
                        let reparsed = markdown::parse(
                            file.display().to_string(),
                            reread,
                            map_file.as_deref(),
                        )?;
                        if !expected.eq_ignore_ascii_case(&reparsed.source_hash) {
                            return Err(AppError::ShaMismatch {
                                expected: expected.to_string(),
                                actual: reparsed.source_hash,
                            });
                        }
                        let (report, already) = store.import_apply(reparsed, Some(expected))?;
                        envelope(
                            Some(project_id),
                            CommandPayload::Import {
                                path: file.display().to_string(),
                                report,
                                already_imported: already,
                                applied: true,
                            },
                            cli.format,
                        );
                        return Ok(());
                    } else {
                        store.import_preview(parsed)
                    };
                    envelope(
                        Some(project_id),
                        CommandPayload::Import {
                            path: file.display().to_string(),
                            report,
                            already_imported: false,
                            applied: false,
                        },
                        cli.format,
                    );
                }
                Command::Export { out } => {
                    let count = store.export_markdown(&out)?;
                    envelope(
                        Some(project_id),
                        CommandPayload::Export {
                            out: out.display().to_string(),
                            task_count: count,
                        },
                        cli.format,
                    );
                }
                Command::Backup { out } => {
                    let bytes = tasks_cli::backup::create(&mut store, &out)?;
                    envelope(
                        Some(project_id),
                        CommandPayload::Backup {
                            out: out.display().to_string(),
                            bytes,
                        },
                        cli.format,
                    );
                }
                Command::Doctor => {
                    let (db_path, project_id, schema_version, sqlite_version) = store.doctor()?;
                    envelope(
                        Some(project_id.clone()),
                        CommandPayload::Doctor {
                            db_path,
                            project_id,
                            schema_version,
                            sqlite_version,
                        },
                        cli.format,
                    );
                }
                Command::List { .. }
                | Command::Search { .. }
                | Command::Show { .. }
                | Command::History { .. }
                | Command::Init { .. }
                | Command::Bind { .. }
                | Command::Migrate => unreachable!(),
            }
        }
    }
    Ok(())
}

fn json_requested(args: &[String]) -> bool {
    args.iter().any(|arg| arg == "--format=json")
        || args
            .windows(2)
            .any(|pair| pair[0] == "--format" && pair[1] == "json")
}

fn main() {
    let args = std::env::args().collect::<Vec<_>>();
    let json = json_requested(&args);
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::DisplayHelp | ErrorKind::DisplayVersion
            ) =>
        {
            print!("{error}");
            std::process::exit(0);
        }
        Err(error) => {
            let error = AppError::Usage(error.to_string());
            if json {
                eprintln!("{}", error.json());
            } else {
                eprintln!("{}", error);
            }
            std::process::exit(error.exit_code());
        }
    };
    if let Err(error) = execute(cli.clone()) {
        if cli.format == OutputFormat::Json {
            eprintln!("{}", error.json());
        } else {
            eprintln!("{}", error);
        }
        std::process::exit(error.exit_code());
    }
}
