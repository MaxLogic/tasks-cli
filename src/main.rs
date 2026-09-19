use clap::{error::ErrorKind, Parser};
use std::io::Read;
use std::path::{Path, PathBuf};
use tasks_cli::cli::{Cli, Command, OutputFormat, ParsedDeps, RulesCommand};
use tasks_cli::error::AppError;
use tasks_cli::interop;
use tasks_cli::markdown;
use tasks_cli::model::{
    parse_task_id, ImportProblem, ImportReport, ProblemCounts, TaskStatus, TaskUpdate,
};
use tasks_cli::output::{CommandPayload, Envelope, ImportFileReport};
use tasks_cli::registry;
use tasks_cli::store::Store;

fn read_input(path: &Path) -> Result<Vec<u8>, AppError> {
    if path == Path::new("-") {
        let mut bytes = Vec::new();
        std::io::stdin()
            .read_to_end(&mut bytes)
            .map_err(|error| AppError::io_op("read the import source from stdin", error))?;
        Ok(bytes)
    } else {
        std::fs::read(path).map_err(|error| AppError::io_path("read", path, error))
    }
}

fn read_text(path: &Path) -> Result<String, AppError> {
    String::from_utf8(read_input(path)?).map_err(|error| {
        AppError::Validation(format!(
            "{} is not valid UTF-8 (first invalid byte at offset {}); convert it to UTF-8",
            path.display(),
            error.utf8_error().valid_up_to()
        ))
    })
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

fn import_payload(
    files: &[PathBuf],
    reports: Vec<ImportReport>,
    problems: Vec<ImportProblem>,
    problem_counts: ProblemCounts,
    already_imported: bool,
    applied: bool,
) -> CommandPayload {
    let mut reports = reports.into_iter();
    if files.len() == 1 {
        if let Some(report) = reports.next() {
            return CommandPayload::Import {
                path: files[0].display().to_string(),
                report,
                problems,
                problem_counts,
                already_imported,
                applied,
            };
        }
    }
    let entries = files
        .iter()
        .zip(reports)
        .map(|(path, report)| ImportFileReport {
            path: path.display().to_string(),
            report,
        })
        .collect();
    CommandPayload::ImportBatch {
        files: entries,
        problems,
        problem_counts,
        already_imported,
        applied,
    }
}

fn execute(cli: Cli) -> Result<(), AppError> {
    if interop::has_backend(&cli) && !interop::should_delegate(&cli) {
        return Err(AppError::Interop(
            "cannot use the Windows backend: --windows-exe or TASKS_WINDOWS_EXE is set, but this is not WSL; run the command on Windows, or run it from WSL"
                .to_string(),
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
                .map(|value| {
                    uuid::Uuid::parse_str(value).map_err(|error| {
                        AppError::Usage(format!(
                            "--project '{value}' is not a UUID ({error}); pass the UUID printed by tasks init, or omit --project to generate one"
                        ))
                    })
                })
                .transpose()?;
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
            open,
            needs_human,
            label,
            status,
            after,
            limit,
        } => {
            let project_id = resolved_project(&cli, &data_root)?;
            let status_text = status.as_ref().map(ToString::to_string);
            let page = Store::open_readonly(&data_root, &project_id)?.select_tasks(
                status_text.as_deref(),
                *after,
                limit.unwrap_or(20),
                label.as_deref(),
                *open,
                *needs_human,
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
        Command::Unlocks { offset, limit } => {
            let project_id = resolved_project(&cli, &data_root)?;
            let page = Store::open_readonly(&data_root, &project_id)?
                .unlocks(*offset, limit.unwrap_or(20))?;
            envelope(
                Some(project_id),
                CommandPayload::Unlocks {
                    items: page.items,
                    has_more: page.has_more,
                    next_offset: page.next_after,
                },
                cli.format,
            );
        }
        Command::Search {
            text,
            after,
            limit,
            ranked,
            prefix,
            offset,
            label,
        } => {
            let project_id = resolved_project(&cli, &data_root)?;
            let mut store = Store::open_readonly(&data_root, &project_id)?;
            let payload = if *ranked {
                let page = store.search_ranked(
                    text,
                    *prefix,
                    label.as_deref(),
                    offset.unwrap_or(0),
                    limit.unwrap_or(20),
                )?;
                CommandPayload::SearchRanked {
                    items: page.items,
                    has_more: page.has_more,
                    next_offset: page.next_after,
                }
            } else {
                let page = store.search_tasks_with_label(
                    text,
                    *after,
                    limit.unwrap_or(20),
                    label.as_deref(),
                )?;
                CommandPayload::Search {
                    items: page.items,
                    has_more: page.has_more,
                    next_after: page.next_after,
                }
            };
            envelope(Some(project_id), payload, cli.format);
        }
        Command::Enrich { .. } | Command::EnrichClipboard => {
            let project_id = resolved_project(&cli, &data_root)?;
            let store = Store::open_readonly(&data_root, &project_id)?;
            let clipboard = matches!(cli.command, Command::EnrichClipboard);
            let input = if let Command::Enrich { file } = &cli.command {
                let reader: Box<dyn Read> = if file == Path::new("-") {
                    Box::new(std::io::stdin())
                } else {
                    Box::new(
                        std::fs::File::open(file)
                            .map_err(|e| AppError::io_path("read", file, e))?,
                    )
                };
                let mut bytes = Vec::new();
                reader
                    .take(tasks_cli::enrich::MAX_INPUT_BYTES as u64 + 1)
                    .read_to_end(&mut bytes)?;
                String::from_utf8(bytes).map_err(|_| {
                    AppError::Validation("enrichment input is not valid UTF-8".into())
                })?
            } else {
                tasks_cli::clipboard::read_text()?
            };
            let result = tasks_cli::enrich::enrich(&store.conn, &input)?;
            if clipboard {
                tasks_cli::clipboard::replace_text(&input, &result.text)?;
            }
            if !result.unknown_ids.is_empty() {
                eprintln!(
                    "Unknown task IDs left unchanged: {}",
                    result
                        .unknown_ids
                        .iter()
                        .map(|id| format!("T-{id}"))
                        .collect::<Vec<_>>()
                        .join(", ")
                );
            }
            if cli.format == OutputFormat::Json {
                envelope(
                    Some(project_id),
                    CommandPayload::Enrich {
                        text: result.text,
                        replacements: result.replacements,
                        unknown_ids: result.unknown_ids,
                        clipboard,
                    },
                    cli.format,
                );
            } else if clipboard {
                println!(
                    "Enriched {} task references in the clipboard.",
                    result.replacements
                );
            } else {
                use std::io::Write;
                std::io::stdout().write_all(result.text.as_bytes())?;
            }
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
            let (from_version, to_version, backup_path) = store.migrate()?;
            envelope(
                Some(project_id),
                CommandPayload::Migrate {
                    from_version,
                    to_version,
                    backup_path: backup_path.map(|path| path.display().to_string()),
                },
                cli.format,
            );
        }
        Command::BulkImport { .. } => {
            let options = match &cli.command {
                Command::BulkImport {
                    scan_root,
                    map_file,
                    report_dir,
                    exclude,
                    apply,
                    quarantine_dir,
                    delete_quarantined,
                    allow_partial,
                    source_schema,
                } => tasks_cli::bulk::BulkOptions {
                    data_root: data_root.clone(),
                    scan_root: scan_root.clone(),
                    map_file: map_file.clone(),
                    report_dir: report_dir.clone(),
                    excludes: exclude.clone(),
                    apply: *apply,
                    quarantine_dir: quarantine_dir.clone(),
                    delete_quarantined: *delete_quarantined,
                    allow_partial: *allow_partial,
                    source_schema: *source_schema,
                },
                _ => unreachable!(),
            };
            if options.delete_quarantined && !options.apply {
                return Err(AppError::Usage(
                    "bulk-import: --delete-quarantined requires --apply; run with --apply --quarantine-dir <dir> --delete-quarantined to move and then delete the sources"
                        .to_string(),
                ));
            }
            if options.delete_quarantined && options.quarantine_dir.is_none() {
                return Err(AppError::Usage(
                    "bulk-import: --delete-quarantined requires --quarantine-dir; pass the directory that should hold the quarantined sources"
                        .to_string(),
                ));
            }
            let report_dir = options.report_dir.display().to_string();
            let run = tasks_cli::bulk::run(options)?;
            let failed = run.failed;
            let unrecognized = run.summary.unrecognized;
            let failed_projects = run.summary.failed_projects;
            let strict_refusal = run.strict_refusal.clone();
            envelope(None, CommandPayload::BulkImport(run), cli.format);
            if let Some(message) = strict_refusal {
                return Err(AppError::Validation(message));
            }
            if failed > 0 {
                return Err(AppError::Validation(format!(
                    "{failed} candidate(s) were not migrated: {unrecognized} unrecognized and {failed_projects} failed apply or verification. Nothing was written for them; see {report_dir}/unrecognized.md for the reasons"
                )));
            }
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
                    priority,
                    labels,
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
                    let (id, version, event_id) = store.create_task_with_priority_labels(
                        &title,
                        &body,
                        status.clone(),
                        deps,
                        labels
                            .as_deref()
                            .map(tasks_cli::labels::parse)
                            .transpose()?
                            .unwrap_or_default(),
                        priority,
                    )?;
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
                    priority,
                    labels,
                    clear_labels,
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
                            priority,
                            labels: if clear_labels {
                                Some(Vec::new())
                            } else {
                                labels
                                    .as_deref()
                                    .map(tasks_cli::labels::parse)
                                    .transpose()?
                            },
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
                    file: files,
                    apply,
                    expect_sha256,
                    map_file,
                    source_schema,
                } => {
                    if !expect_sha256.is_empty() && expect_sha256.len() != files.len() {
                        return Err(AppError::Usage(format!(
                            "import: {} --file source(s) but {} --expect-sha256 value(s); pass one --expect-sha256 per --file, in the same order",
                            files.len(),
                            expect_sha256.len()
                        )));
                    }
                    if files.len() > 1 && files.iter().any(|path| path.as_path() == Path::new("-"))
                    {
                        return Err(AppError::Usage(
                            "import: --file - (stdin) can be the only source; pass real paths to import several files"
                                .to_string(),
                        ));
                    }
                    let mut parsed = Vec::with_capacity(files.len());
                    for (index, path) in files.iter().enumerate() {
                        let bytes = read_input(path)?;
                        let item = markdown::parse_with_schema(
                            path.display().to_string(),
                            bytes,
                            map_file.as_deref(),
                            source_schema,
                        )?;
                        if let Some(expected) = expect_sha256.get(index) {
                            if !expected.eq_ignore_ascii_case(&item.source_hash) {
                                return Err(AppError::ShaMismatch {
                                    file: path.display().to_string(),
                                    expected: expected.clone(),
                                    actual: item.source_hash,
                                });
                            }
                        }
                        parsed.push(item);
                    }
                    markdown::resolve_create_task_deps_across(&mut parsed);
                    let mut problems = {
                        let refs: Vec<&markdown::ParsedImport> = parsed.iter().collect();
                        tasks_cli::problems::analyze(&refs)
                    };
                    let sources = parsed
                        .iter()
                        .map(|item| (item.source_name.clone(), item.source_hash.clone()))
                        .collect::<Vec<_>>();
                    let (state_problems, already_imported) =
                        store.import_state_problems(&sources)?;
                    problems.extend(state_problems);
                    let problem_counts = ProblemCounts::of(&problems);
                    if apply {
                        if expect_sha256.len() != files.len() {
                            return Err(AppError::Usage(format!(
                                "import apply: {} --file source(s) but {} --expect-sha256 value(s); pass one --expect-sha256 per --file, in the same order",
                                files.len(),
                                expect_sha256.len()
                            )));
                        }
                        if files.iter().any(|path| path.as_path() == Path::new("-")) {
                            return Err(AppError::Usage(
                                "import apply: --apply cannot re-read --file - (stdin); pass a real path so the source can be hashed and verified before import"
                                    .to_string(),
                            ));
                        }
                        if !problems.is_empty() {
                            let details = problems
                                .iter()
                                .map(|problem| format!("- {}", problem.message))
                                .collect::<Vec<_>>()
                                .join("\n");
                            return Err(AppError::Validation(format!(
                                "import blocked by {}:\n{details}",
                                problem_counts.line()
                            )));
                        }
                        let mut reparsed = Vec::with_capacity(files.len());
                        for (index, path) in files.iter().enumerate() {
                            let reread = read_input(path)?;
                            let item = markdown::parse_with_schema(
                                path.display().to_string(),
                                reread,
                                map_file.as_deref(),
                                source_schema,
                            )?;
                            if !expect_sha256[index].eq_ignore_ascii_case(&item.source_hash) {
                                return Err(AppError::ShaMismatch {
                                    file: path.display().to_string(),
                                    expected: expect_sha256[index].clone(),
                                    actual: item.source_hash,
                                });
                            }
                            reparsed.push(item);
                        }
                        markdown::resolve_create_task_deps_across(&mut reparsed);
                        let (reports, already) =
                            store.import_apply_many(reparsed, &expect_sha256)?;
                        envelope(
                            Some(project_id),
                            import_payload(
                                &files,
                                reports,
                                problems,
                                problem_counts,
                                already,
                                true,
                            ),
                            cli.format,
                        );
                        return Ok(());
                    }
                    let reports = store.import_preview_many(parsed);
                    envelope(
                        Some(project_id),
                        import_payload(
                            &files,
                            reports,
                            problems,
                            problem_counts,
                            already_imported,
                            false,
                        ),
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
                Command::Enrich { .. }
                | Command::EnrichClipboard
                | Command::List { .. }
                | Command::Unlocks { .. }
                | Command::Search { .. }
                | Command::Show { .. }
                | Command::History { .. }
                | Command::Init { .. }
                | Command::Bind { .. }
                | Command::BulkImport { .. }
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
