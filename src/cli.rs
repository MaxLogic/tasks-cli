use crate::model::{ListCursor, Priority, SourceSchema, TaskStatus};
use clap::{Parser, Subcommand, ValueEnum};
use std::path::PathBuf;

/// Shared SQLite task backlog for one project, independent of Git branches.
#[derive(Parser, Debug, Clone)]
#[command(
    name = "tasks",
    version = env!("TASKS_BUILD_VERSION"),
    disable_help_subcommand = true
)]
pub struct Cli {
    /// Directory holding project databases (default: per-user data directory).
    #[arg(long, global = true)]
    pub data_root: Option<PathBuf>,
    /// Project UUID; default is the project bound to the current directory.
    #[arg(long, global = true)]
    pub project: Option<String>,
    /// Output format: compact text or one-line JSON.
    #[arg(long, global = true, value_enum, default_value = "text")]
    pub format: OutputFormat,
    /// From WSL: delegate to this Windows tasks.exe for the Windows store.
    #[arg(long, global = true)]
    pub windows_exe: Option<PathBuf>,
    #[arg(long, global = true, hide = true)]
    pub route_root: Option<PathBuf>,
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Copy, Clone, Debug, Eq, PartialEq, ValueEnum, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum OutputFormat {
    /// Line-oriented text for reading.
    Text,
    /// One compact JSON object for parsing.
    Json,
}

#[derive(Subcommand, Debug, Clone)]
pub enum Command {
    /// Create a project database and bind a root directory to it.
    Init {
        /// Directory to bind; receives a .tasks.json identity file.
        #[arg(long)]
        root: PathBuf,
    },
    /// Bind another root directory to an existing project.
    Bind {
        /// Directory to bind.
        #[arg(long)]
        root: PathBuf,
        /// Project UUID to bind the directory to.
        #[arg(long)]
        project: String,
    },
    /// List runnable tasks (todo/in-progress, dependencies done), priority then ID.
    List {
        /// Include every nonterminal task, regardless of readiness.
        #[arg(long, conflicts_with = "needs_human")]
        open: bool,
        /// Include nonterminal tasks labelled needs-human.
        #[arg(long)]
        needs_human: bool,
        /// Only tasks carrying this label.
        #[arg(long)]
        label: Option<String>,
        /// Only tasks in this status; bypasses readiness filtering.
        #[arg(long)]
        status: Option<TaskStatus>,
        /// Resume after this cursor (next_after, e.g. P2:T-123).
        #[arg(long)]
        after: Option<ListCursor>,
        /// Page size, 1-100 (default 20).
        #[arg(long)]
        limit: Option<usize>,
    },
    /// Rank open prerequisites by the work completing them would unlock.
    Unlocks {
        /// Skip this many ranked rows (next_offset).
        #[arg(long, default_value_t = 0)]
        offset: u64,
        /// Page size, 1-100 (default 20).
        #[arg(long)]
        limit: Option<usize>,
    },
    /// Search task titles and bodies; substring by default.
    Search {
        /// Text to find (case-insensitive).
        text: String,
        /// Full-text search ranked by relevance.
        #[arg(long)]
        ranked: bool,
        /// Match word prefixes (with --ranked).
        #[arg(long, requires = "ranked")]
        prefix: bool,
        /// Skip this many ranked rows (with --ranked).
        #[arg(long, requires = "ranked")]
        offset: Option<u64>,
        /// Only tasks carrying this label.
        #[arg(long)]
        label: Option<String>,
        /// Resume after this numeric task ID.
        #[arg(long, conflicts_with = "ranked")]
        after: Option<u64>,
        /// Page size, 1-100 (default 20).
        #[arg(long)]
        limit: Option<usize>,
    },
    /// Insert task titles after references in UTF-8 input; default input is stdin.
    Enrich {
        /// Input file, or - for stdin.
        #[arg(long, default_value = "-")]
        file: PathBuf,
    },
    /// Enrich clipboard text and put the result back on the clipboard.
    EnrichClipboard,
    /// Show one or more tasks in full; rules only with --rules.
    Show {
        /// Task IDs (T-N), shown in the given order.
        #[arg(required = true, num_args = 1..)]
        ids: Vec<String>,
        /// Also print the shared project rules, once.
        #[arg(long)]
        rules: bool,
    },
    /// Create a task; prints its ID, status, version and event ID.
    Create {
        /// P0 (highest) to P3.
        #[arg(long, value_enum, default_value = "P2")]
        priority: Priority,
        /// Comma-separated labels.
        #[arg(long)]
        labels: Option<String>,
        /// Task title.
        #[arg(long)]
        title: String,
        /// UTF-8 body file, or - for stdin.
        #[arg(long = "body-file")]
        body_file: PathBuf,
        /// Initial status (default draft).
        #[arg(long)]
        status: Option<TaskStatus>,
        /// Comma-separated prerequisite IDs (T-1,T-2).
        #[arg(long)]
        deps: Option<String>,
        /// Create with no dependencies.
        #[arg(long = "clear-deps", default_value_t = false, conflicts_with = "deps")]
        clear_deps: bool,
    },
    /// Change a task if its version still matches; exit 4 on a stale version.
    Update {
        /// P0 (highest) to P3.
        #[arg(long, value_enum)]
        priority: Option<Priority>,
        /// Replace all labels with this comma-separated set.
        #[arg(long, conflicts_with_all = ["clear_labels", "add_label", "remove_label"])]
        labels: Option<String>,
        /// Remove every label.
        #[arg(long, conflicts_with_all = ["add_label", "remove_label"])]
        clear_labels: bool,
        /// Add these comma-separated labels, keeping the others.
        #[arg(long)]
        add_label: Option<String>,
        /// Remove these comma-separated labels, keeping the others.
        #[arg(long)]
        remove_label: Option<String>,
        /// Task ID (T-N).
        id: String,
        /// Version from list/show; the update fails if it changed.
        #[arg(long = "expect-version")]
        expect_version: u64,
        /// New title.
        #[arg(long)]
        title: Option<String>,
        /// Replacement body file, or - for stdin.
        #[arg(long = "body-file")]
        body_file: Option<PathBuf>,
        /// New status.
        #[arg(long)]
        status: Option<TaskStatus>,
        /// Replace dependencies with these comma-separated IDs.
        #[arg(long, conflicts_with = "clear_deps")]
        deps: Option<String>,
        /// Remove every dependency.
        #[arg(long = "clear-deps", default_value_t = false)]
        clear_deps: bool,
    },
    /// Page through a task's change events, with changed fields per event.
    History {
        /// Task ID (T-N).
        id: String,
        /// Resume after this event ID (next_after).
        #[arg(long)]
        after: Option<u64>,
        /// Page size, 1-100 (default 20).
        #[arg(long)]
        limit: Option<usize>,
        /// Show one event with its full snapshot.
        #[arg(long = "event")]
        event: Option<u64>,
    },
    /// Read or replace the shared project rules.
    #[command(subcommand)]
    Rules(RulesCommand),
    /// Preview a Markdown ledger import; --apply commits it to an empty project.
    Import {
        /// Markdown source; repeat for several files.
        #[arg(long, required = true)]
        file: Vec<PathBuf>,
        /// Commit the import instead of previewing it.
        #[arg(long, default_value_t = false)]
        apply: bool,
        /// Source SHA-256 from the preview, once per file.
        #[arg(long = "expect-sha256")]
        expect_sha256: Vec<String>,
        /// Section-to-status map file.
        #[arg(long = "map-file")]
        map_file: Option<PathBuf>,
        /// Source ledger dialect.
        #[arg(long = "source-schema", value_enum, default_value = "canonical")]
        source_schema: SourceSchema,
    },
    /// Write a deterministic Markdown snapshot of the project.
    Export {
        /// Destination file; must not exist.
        #[arg(long)]
        out: PathBuf,
    },
    /// Scan a directory tree for Markdown ledgers and migrate them (dry run by default).
    BulkImport {
        /// Directory tree to scan.
        #[arg(long = "scan-root")]
        scan_root: PathBuf,
        /// Section-to-status map file.
        #[arg(long = "map-file")]
        map_file: PathBuf,
        /// Directory for run reports.
        #[arg(long = "report-dir")]
        report_dir: PathBuf,
        /// Glob to skip; repeatable.
        #[arg(long = "exclude")]
        exclude: Vec<String>,
        /// Initialize projects, import and verify.
        #[arg(long, default_value_t = false)]
        apply: bool,
        /// Move imported sources here after verification.
        #[arg(long = "quarantine-dir")]
        quarantine_dir: Option<PathBuf>,
        /// Delete sources after quarantine.
        #[arg(long = "delete-quarantined", default_value_t = false)]
        delete_quarantined: bool,
        /// Apply only the clean candidates when others have problems.
        #[arg(long = "allow-partial", default_value_t = false)]
        allow_partial: bool,
        /// Source ledger dialect.
        #[arg(long = "source-schema", value_enum, default_value = "canonical")]
        source_schema: SourceSchema,
    },
    /// Write a consistent SQLite backup.
    Backup {
        /// Destination file; must not exist.
        #[arg(long)]
        out: PathBuf,
    },
    /// Upgrade the database schema after a verified backup.
    Migrate,
    /// Print the database path, project ID and schema, and check integrity.
    Doctor,
    /// Additive JSON protocol for the tasks viewer; requires --format json.
    #[command(subcommand)]
    Viewer(ViewerCommand),
}

#[derive(Subcommand, Debug, Clone)]
pub enum ViewerCommand {
    /// Archive a project, or restore it with --unarchive.
    Archive {
        /// Restore an archived project.
        #[arg(long)]
        unarchive: bool,
    },
    /// Report the protocol version, operations and editable-field limits without opening a store.
    Info,
    /// Page through registry projects with per-project availability and statistics.
    Projects {
        /// JSON request file, or - for stdin.
        #[arg(long = "request-file")]
        request_file: PathBuf,
    },
    /// Page through one project's tasks with combined filters.
    Tasks {
        /// JSON request file, or - for stdin.
        #[arg(long = "request-file")]
        request_file: PathBuf,
    },
    /// Return the full task detail plus created_ms and updated_ms.
    Show {
        /// Task ID (T-N).
        id: String,
    },
    /// Apply one version-checked update over the six editable fields.
    Update {
        /// JSON request file, or - for stdin.
        #[arg(long = "request-file")]
        request_file: PathBuf,
    },
}

#[derive(Subcommand, Debug, Clone)]
pub enum RulesCommand {
    /// Print the shared rules and their version.
    Show,
    /// Replace the shared rules if their version still matches.
    Set {
        /// UTF-8 rules file, or - for stdin.
        #[arg(long = "body-file")]
        body_file: PathBuf,
        /// Current rules version from rules show.
        #[arg(long = "expect-version")]
        expect_version: u64,
    },
}

#[derive(Debug, Clone)]
pub struct ParsedDeps(pub Vec<u64>);

impl ParsedDeps {
    pub fn parse(input: &str) -> Result<Self, String> {
        let items: Vec<u64> = if input.trim().is_empty() {
            Vec::new()
        } else {
            input
                .split(',')
                .filter(|s| !s.trim().is_empty())
                .map(|s| {
                    crate::model::parse_task_id(s.trim())
                        .map_err(|error| format!("--deps item '{s}': {error}"))
                })
                .collect::<Result<_, _>>()?
        };
        Ok(Self(items))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn dependency_parser_requires_task_ids() {
        assert_eq!(ParsedDeps::parse("T-1,T-002").unwrap().0, vec![1, 2]);
        assert!(ParsedDeps::parse("1").is_err());
    }

    #[test]
    fn global_options_are_available_before_commands() {
        let cli = Cli::try_parse_from(["tasks", "--format", "json", "list"]).unwrap();
        assert_eq!(cli.format, OutputFormat::Json);
    }

    #[test]
    fn every_command_and_visible_option_has_help() {
        use clap::CommandFactory;
        fn walk(command: &clap::Command, path: &str, missing: &mut Vec<String>) {
            for arg in command.get_arguments() {
                let builtin = matches!(arg.get_id().as_str(), "help" | "version");
                if !arg.is_hide_set() && !builtin && arg.get_help().is_none() {
                    missing.push(format!("{path} {}", arg.get_id()));
                }
            }
            for sub in command.get_subcommands() {
                let name = format!("{path} {}", sub.get_name());
                if sub.get_about().is_none() {
                    missing.push(name.clone());
                }
                walk(sub, &name, missing);
            }
        }
        let mut missing = Vec::new();
        walk(&Cli::command(), "tasks", &mut missing);
        assert!(missing.is_empty(), "missing help: {missing:?}");
    }

    #[test]
    fn show_accepts_several_ids_and_rules_flag() {
        let cli = Cli::try_parse_from(["tasks", "show", "T-1", "T-2", "--rules"]).unwrap();
        match cli.command {
            Command::Show { ids, rules } => {
                assert_eq!(ids, ["T-1", "T-2"]);
                assert!(rules);
            }
            other => panic!("unexpected command {other:?}"),
        }
        assert!(Cli::try_parse_from(["tasks", "show"]).is_err());
    }

    #[test]
    fn global_options_are_available_after_commands() {
        let cli = Cli::try_parse_from(["tasks", "list", "--format", "json"]).unwrap();
        assert_eq!(cli.format, OutputFormat::Json);
    }
}
