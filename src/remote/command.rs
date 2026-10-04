//! CLI dispatch selects remote authority before Windows SQLite delegation.
use super::{
    client::{api_output, parse_reply, transport_error, RemoteClient},
    config::{self, Profile},
    pending::PendingStore,
    protocol::*,
};
use crate::{
    cli::{Cli, Command, OutputFormat, RemoteCommand, RulesCommand},
    model::{TaskStatus, TaskUpdate},
    output::{CommandPayload, Envelope},
    registry, AppError,
};
use http::Method;
use serde_json::json;
use std::{
    io::{Read, Write},
    path::Path,
};
use uuid::Uuid;

fn print(value: ApiOutput, format: OutputFormat) {
    match format {
        OutputFormat::Json => println!("{}", value.output),
        OutputFormat::Text => print!("{}", value.text),
    }
}
fn envelope(project: Option<String>, data: CommandPayload, format: OutputFormat) {
    let value = Envelope {
        schema_version: 1,
        project_id: project,
        id_key: None,
        data,
    };
    match format {
        OutputFormat::Json => println!("{}", value.json()),
        OutputFormat::Text => print!("{}", value.text()),
    }
}
fn refs(value: Option<&str>) -> Vec<String> {
    value
        .map(|s| {
            s.split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}
fn text(path: &Path) -> Result<String, AppError> {
    let reader: Box<dyn Read> = if path == Path::new("-") {
        Box::new(std::io::stdin())
    } else {
        Box::new(std::fs::File::open(path).map_err(|e| AppError::io_path("read", path, e))?)
    };
    let mut bytes = Vec::new();
    reader.take(1024 * 1024 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 1024 * 1024 {
        return Err(AppError::Validation("body exceeds the 1 MiB limit".into()));
    }
    String::from_utf8(bytes)
        .map_err(|_| AppError::Validation("body file is not valid UTF-8".into()))
}
fn project(cli: &Cli, root: &Path) -> Result<String, AppError> {
    let env = std::env::var("TASKS_PROJECT").ok();
    registry::resolve_project(
        root,
        cli.project.as_deref().or(env.as_deref()),
        cli.route_root.as_deref(),
    )
}
fn query(
    client: &RemoteClient,
    project: &str,
    request: ReadRequest,
) -> Result<ApiOutput, AppError> {
    api_output(client.read(
        Method::POST,
        &format!("/v1/projects/{project}/query"),
        &serde_json::to_vec(&request)?,
    )?)
}
pub fn setup(cli: &Cli, root: &Path, command: &RemoteCommand) -> Result<(), AppError> {
    match command {
        RemoteCommand::Keygen { directory } => {
            if !directory.is_absolute() {
                return Err(AppError::Usage("key directory must be absolute".into()));
            }
            let public_key = super::credentials::generate_key(directory)?;
            let machine_id = Uuid::new_v4();
            let mut file = crate::private_fs::create_file(&directory.join("installation.json"))?;
            file.write_all(
                serde_json::to_vec(&json!({"schema_version":1,"machine_id":machine_id}))?
                    .as_slice(),
            )?;
            file.sync_all()?;
            println!(
                "{}",
                json!({"public_key":public_key,"installation_id":machine_id,"installation_name":whoami::hostname().map_err(|_| AppError::Validation("OS hostname is unavailable".into()))?,"actor_id":whoami::account().map_err(|_| AppError::Validation("OS account is unavailable".into()))?,"actor_name":whoami::username().map_err(|_| AppError::Validation("OS account name is unavailable".into()))?})
            );
        }
        RemoteCommand::Configure {
            server_url,
            server_id,
            credential_id,
            credential_file,
            private_ca,
            connect_timeout_seconds,
            request_timeout_seconds,
        } => {
            let profile = Profile::Remote {
                server_url: server_url.clone(),
                server_id: *server_id,
                credential_id: *credential_id,
                credential_file: credential_file.clone(),
                private_ca: private_ca.clone(),
                connect_timeout_seconds: *connect_timeout_seconds,
                request_timeout_seconds: *request_timeout_seconds,
            };
            let client = RemoteClient::new(&profile)?;
            client.info()?;
            std::fs::create_dir_all(root)?;
            let pending = PendingStore::new(root)?;
            let _lock = pending.lock()?;
            if !pending.list()?.is_empty() {
                let Profile::Remote {
                    server_id: old_server,
                    credential_id: old_credential,
                    ..
                } = config::load(root)?
                else {
                    return Err(AppError::Validation(
                        "pending writes require their original remote profile".into(),
                    ));
                };
                if old_server != *server_id || old_credential != *credential_id {
                    return Err(AppError::Validation(
                        "reconcile pending writes before changing server or credential identity"
                            .into(),
                    ));
                }
            }
            config::save(root, &profile)?;
            println!(
                "{}",
                json!({"backend":"remote","server_id":server_id,"credential_id":credential_id})
            );
        }
        RemoteCommand::Local => {
            std::fs::create_dir_all(root)?;
            let pending = PendingStore::new(root)?;
            let _lock = pending.lock()?;
            if !pending.list()?.is_empty() {
                return Err(AppError::Validation(
                    "reconcile pending writes before selecting local operation".into(),
                ));
            }
            config::save(root, &Profile::Local)?;
            println!("{}", json!({"backend":"local"}));
        }
        RemoteCommand::Pending => {
            std::fs::create_dir_all(root)?;
            let store = PendingStore::new(root)?;
            let _lock = store.lock()?;
            let items = store.list()?.into_iter().map(|id| {
                let request = store.load(id)?;
                Ok(json!({"request_id":id,"server_id":request.server_id,"method":request.method,"target":request.target}))
            }).collect::<Result<Vec<_>,AppError>>()?;
            println!(
                "{}",
                json!({"schema_version":1,"data":{"command":"remote_pending","items":items}})
            );
        }
        RemoteCommand::Reconcile { request_id } => print(
            RemoteClient::new(&config::load(root)?)?.reconcile(root, *request_id)?,
            cli.format,
        ),
    }
    Ok(())
}
pub fn execute(cli: &Cli, root: &Path, profile: &Profile) -> Result<(), AppError> {
    if matches!(
        cli.command,
        Command::Import { .. }
            | Command::BulkImport { .. }
            | Command::Backup { .. }
            | Command::Migrate
            | Command::Doctor
    ) {
        return Err(AppError::Remote { code:"unsupported_remote_operation", message:"this maintenance operation requires server-local administration; no local database or input file was opened".into(),request_id:None });
    }
    let client = RemoteClient::new(profile)?;
    if let Command::Init {
        root: workspace,
        key,
    } = &cli.command
    {
        let workspace = workspace
            .canonicalize()
            .map_err(|e| AppError::io_path("resolve workspace", workspace, e))?;
        let identity = registry::project_identity_at_root(&workspace)?;
        let binding = registry::bound_project_at_root(root, &workspace)?;
        if identity.is_some() && binding.is_some() && identity != binding {
            return Err(AppError::Validation(
                "workspace identity and registry binding select different projects".into(),
            ));
        }
        let existing = identity.or(binding);
        let explicit = cli
            .project
            .as_deref()
            .map(|s| {
                Uuid::parse_str(s).map_err(|_| AppError::Validation("invalid project UUID".into()))
            })
            .transpose()?;
        if existing.is_some() && explicit.is_some() && existing != explicit {
            return Err(AppError::Validation(
                "workspace already selects another project".into(),
            ));
        }
        let id = explicit.or(existing).unwrap_or_else(Uuid::new_v4);
        if explicit.is_some() || existing.is_some() {
            match query(&client, &id.to_string(), ReadRequest::ProjectKey) {
                Ok(output) => {
                    if output.output["data"]["project_key"].as_str() != Some(key.as_str()) {
                        return Err(AppError::Validation(
                            "existing server project has another key; init does not change it"
                                .into(),
                        ));
                    }
                    registry::bind_remote_root(root, &workspace, id.to_string())?;
                    envelope(
                        Some(id.to_string()),
                        CommandPayload::Init {
                            project_id: id.to_string(),
                            project_key: Some(key.clone()),
                            db_path: format!("server:{}", client.server_id),
                        },
                        cli.format,
                    );
                    return Ok(());
                }
                Err(AppError::RemoteReply { exit_code: 3, .. }) => (),
                Err(error) => return Err(error),
            }
        }
        let name = workspace
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("Project")
            .to_string();
        let output = client.write(
            root,
            Method::POST,
            "/v1/projects",
            serde_json::to_value(CreateProject {
                project_id: id,
                name,
                project_key: Some(key.clone()),
                attribution: crate::attribution::current(),
            })?,
        )?;
        registry::bind_remote_root(root, &workspace, id.to_string()).map_err(|error| AppError::Remote {
            code: "workspace_binding", message: format!("server project {id} exists, but workspace binding failed: {error}; use tasks bind --root <workspace> --project {id} after fixing the workspace"), request_id: None,
        })?;
        print(output, cli.format);
        return Ok(());
    }
    if let Command::Bind {
        root: workspace,
        project: id,
    } = &cli.command
    {
        let id = Uuid::parse_str(id)
            .map_err(|_| AppError::Validation("invalid project UUID".into()))?
            .to_string();
        query(&client, &id, ReadRequest::ProjectKey)?;
        registry::bind_remote_root(root, workspace, id.clone())?;
        envelope(
            Some(id.clone()),
            CommandPayload::Bind {
                project_id: id,
                root: workspace.display().to_string(),
            },
            cli.format,
        );
        return Ok(());
    }
    let id = project(cli, root)?;
    if matches!(
        cli.command,
        Command::Enrich { .. } | Command::EnrichClipboard
    ) {
        return enrich(cli, &client, &id);
    }
    let request = match &cli.command {
        Command::List {
            open,
            needs_human,
            label,
            status,
            after,
            limit,
        } => Some(ReadRequest::List {
            open: *open,
            needs_human: *needs_human,
            label: label.clone(),
            status: status.clone(),
            after: after.as_ref().map(ToString::to_string),
            limit: limit.unwrap_or(20),
        }),
        Command::Unlocks { offset, limit } => Some(ReadRequest::Unlocks {
            offset: *offset,
            limit: limit.unwrap_or(20),
        }),
        Command::Search {
            text,
            after,
            limit,
            ranked,
            prefix,
            offset,
            label,
        } => Some(ReadRequest::Search {
            text: text.clone(),
            after: *after,
            limit: limit.unwrap_or(20),
            ranked: *ranked,
            prefix: *prefix,
            offset: offset.unwrap_or(0),
            label: label.clone(),
        }),
        Command::Show { ids, rules } => Some(ReadRequest::Show {
            ids: ids.clone(),
            rules: *rules,
        }),
        Command::History {
            id,
            after,
            limit,
            event,
        } => Some(ReadRequest::History {
            id: id.clone(),
            after: *after,
            limit: limit.unwrap_or(20),
            event: *event,
        }),
        Command::ProjectHistory { after, limit } => Some(ReadRequest::ProjectHistory {
            after: *after,
            limit: limit.unwrap_or(20),
        }),
        Command::Rules(RulesCommand::Show) => Some(ReadRequest::Rules),
        Command::ProjectKey { set: None } => Some(ReadRequest::ProjectKey),
        _ => None,
    };
    if let Some(request) = request {
        print(query(&client, &id, request)?, cli.format);
        return Ok(());
    }
    let attribution = crate::attribution::current();
    let base = format!("/v1/projects/{id}");
    let output = match &cli.command {
        Command::Create {
            priority,
            labels,
            title,
            body_file,
            status,
            deps,
            ..
        } => client.write(
            root,
            Method::POST,
            &format!("{base}/tasks"),
            serde_json::to_value(CreateTask {
                title: title.clone(),
                body: text(body_file)?,
                priority: *priority,
                status: status.clone().unwrap_or(TaskStatus::Backlog),
                deps: refs(deps.as_deref()),
                labels: refs(labels.as_deref()),
                attribution,
            })?,
        )?,
        Command::Update {
            priority,
            labels,
            clear_labels,
            add_label,
            remove_label,
            id: task,
            expect_version,
            title,
            body_file,
            status,
            deps,
            clear_deps,
        } => {
            let numeric = crate::model::parse_task_ref(task)
                .map_err(AppError::Validation)?
                .id;
            let changes = TaskUpdate {
                priority: *priority,
                title: title.clone(),
                body: body_file.as_deref().map(text).transpose()?,
                status: status.clone(),
                deps: None,
                clear_deps: *clear_deps,
                labels: if *clear_labels {
                    Some(vec![])
                } else {
                    labels.as_deref().map(|s| refs(Some(s)))
                },
                add_labels: refs(add_label.as_deref()),
                remove_labels: refs(remove_label.as_deref()),
            };
            client.write(
                root,
                Method::PATCH,
                &format!("{base}/tasks/{numeric}"),
                serde_json::to_value(UpdateTask {
                    task_ref: task.clone(),
                    expect_version: *expect_version,
                    changes,
                    dependency_refs: deps.as_deref().map(|s| refs(Some(s))),
                    attribution,
                })?,
            )?
        }
        Command::Rules(RulesCommand::Set {
            body_file,
            expect_version,
        }) => client.write(
            root,
            Method::PUT,
            &format!("{base}/rules"),
            serde_json::to_value(SetRules {
                body: text(body_file)?,
                expect_version: *expect_version,
                attribution,
            })?,
        )?,
        Command::ProjectKey { set: Some(key) } => client.write(
            root,
            Method::PUT,
            &format!("{base}/key"),
            serde_json::to_value(SetKey {
                project_key: key.clone(),
                attribution,
            })?,
        )?,
        Command::Export { out } => {
            export(
                &client,
                Uuid::parse_str(&id)
                    .map_err(|_| AppError::Validation("invalid project UUID".into()))?,
                out,
                cli.format,
            )?;
            return Ok(());
        }
        _ => {
            return Err(AppError::Remote {
                code: "unsupported_remote_operation",
                message: "remote support for this operation is not available in this candidate"
                    .into(),
                request_id: None,
            })
        }
    };
    print(output, cli.format);
    Ok(())
}

fn enrich(cli: &Cli, client: &RemoteClient, project: &str) -> Result<(), AppError> {
    let own = query(client, project, ReadRequest::ProjectKey)?;
    let key = own.output["data"]["project_key"].as_str();
    let clipboard = matches!(cli.command, Command::EnrichClipboard);
    let input = if let Command::Enrich { file } = &cli.command {
        let reader: Box<dyn Read> = if file == Path::new("-") {
            Box::new(std::io::stdin())
        } else {
            Box::new(std::fs::File::open(file).map_err(|e| AppError::io_path("read", file, e))?)
        };
        let mut bytes = Vec::new();
        reader
            .take(crate::enrich::MAX_INPUT_BYTES as u64 + 1)
            .read_to_end(&mut bytes)?;
        String::from_utf8(bytes)
            .map_err(|_| AppError::Validation("enrichment input is not valid UTF-8".into()))?
    } else {
        crate::clipboard::read_text()?
    };
    let result = crate::enrich::enrich_using(&input, key, |requests| {
        let references = requests
            .iter()
            .flat_map(|(key, ids)| {
                ids.iter()
                    .map(|id| format!("{}-{id}", key.as_deref().unwrap_or("T")))
            })
            .collect::<Vec<_>>();
        let mut result = crate::enrich::TitleResolution::default();
        for batch in references.chunks(500) {
            let value = client.read(
                Method::POST,
                &format!("/v1/projects/{project}/query"),
                &serde_json::to_vec(&ReadRequest::Titles {
                    references: batch.to_vec(),
                })?,
            )?;
            let titles: TitlesResult =
                serde_json::from_value(value).map_err(|_| AppError::Remote {
                    code: "remote_protocol",
                    message: "invalid title lookup response".into(),
                    request_id: None,
                })?;
            for title in titles.titles {
                result.titles.insert((title.key, title.id), title.title);
            }
            result.known_keys.extend(titles.known_keys);
        }
        Ok(result)
    })?;
    if clipboard {
        crate::clipboard::replace_text(&input, &result.text)?;
    }
    if !result.unknown_refs.is_empty() {
        eprintln!(
            "Unknown task IDs left unchanged: {}",
            result.unknown_refs.join(", ")
        );
    }
    if cli.format == OutputFormat::Json {
        envelope(
            Some(project.into()),
            CommandPayload::Enrich {
                text: result.text,
                replacements: result.replacements,
                unknown_ids: result.unknown_ids,
                unknown_refs: result.unknown_refs,
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
        std::io::stdout().write_all(result.text.as_bytes())?;
    }
    Ok(())
}

fn export(
    client: &RemoteClient,
    project: Uuid,
    out: &Path,
    format: OutputFormat,
) -> Result<(), AppError> {
    if out.try_exists()? {
        return Err(AppError::Usage(format!(
            "refusing to overwrite {}",
            out.display()
        )));
    }
    let parent = out
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let directory = crate::private_fs::validate_export_directory(parent)?;
    let parent = &directory.path;
    let destination = parent.join(
        out.file_name()
            .ok_or_else(|| AppError::Usage("export requires a file name".into()))?,
    );
    let temporary = parent.join(format!(".tasks-export-{}.tmp", Uuid::new_v4()));
    let result = (|| {
        let mut file = crate::private_fs::create_output_file(&temporary)?;
        let summary = match client
            .http
            .export(project, &mut file)
            .map_err(transport_error)?
        {
            super::https::RemoteExportResponse::Complete(summary) => summary,
            super::https::RemoteExportResponse::Refused(reply) => {
                parse_reply(reply)?;
                return Err(AppError::Validation("invalid export response".into()));
            }
        };
        file.sync_all()?;
        std::fs::hard_link(&temporary, &destination)
            .map_err(|e| AppError::io_path("publish complete export", out, e))?;
        drop(file);
        finish_publication(|| {
            std::fs::remove_file(&temporary)?;
            #[cfg(unix)]
            std::fs::File::open(parent)?.sync_all()?;
            Ok(())
        });
        envelope(
            Some(project.to_string()),
            CommandPayload::Export {
                out: out.display().to_string(),
                task_count: summary.task_count as usize,
            },
            format,
        );
        Ok(())
    })();
    if temporary.exists() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

// Once linked, the complete destination is authoritative. Cleanup/directory
// durability failures must not turn a published export into a reported refusal.
fn finish_publication(cleanup: impl FnOnce() -> std::io::Result<()>) {
    let _ = cleanup();
}

#[cfg(test)]
mod publication_tests {
    #[test]
    fn cleanup_failure_after_publication_does_not_report_a_failed_export() {
        super::finish_publication(|| Err(std::io::Error::other("injected sync failure")));
    }
}
