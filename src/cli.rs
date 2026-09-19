use crate::model::{ListCursor, Priority, SourceSchema, TaskStatus};
use clap::{Parser, Subcommand, ValueEnum};
use std::path::PathBuf;

#[derive(Parser, Debug, Clone)]
#[command(name = "tasks", disable_help_subcommand = true)]
pub struct Cli {
    #[arg(long, global = true)]
    pub data_root: Option<PathBuf>,
    #[arg(long, global = true)]
    pub project: Option<String>,
    #[arg(long, global = true, value_enum, default_value = "text")]
    pub format: OutputFormat,
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
    Text,
    Json,
}

#[derive(Subcommand, Debug, Clone)]
pub enum Command {
    Init {
        #[arg(long)]
        root: PathBuf,
    },
    Bind {
        #[arg(long)]
        root: PathBuf,
        #[arg(long)]
        project: String,
    },
    List {
        /// Include every nonterminal task, regardless of readiness.
        #[arg(long, conflicts_with = "needs_human")]
        open: bool,
        /// Include nonterminal tasks labelled needs-human.
        #[arg(long)]
        needs_human: bool,
        #[arg(long)]
        label: Option<String>,
        #[arg(long)]
        status: Option<TaskStatus>,
        #[arg(long)]
        after: Option<ListCursor>,
        #[arg(long)]
        limit: Option<usize>,
    },
    /// Rank open prerequisites by the work completing them would unlock.
    Unlocks {
        #[arg(long, default_value_t = 0)]
        offset: u64,
        #[arg(long)]
        limit: Option<usize>,
    },
    Search {
        text: String,
        #[arg(long)]
        ranked: bool,
        #[arg(long, requires = "ranked")]
        prefix: bool,
        #[arg(long, requires = "ranked")]
        offset: Option<u64>,
        #[arg(long)]
        label: Option<String>,
        #[arg(long, conflicts_with = "ranked")]
        after: Option<u64>,
        #[arg(long)]
        limit: Option<usize>,
    },
    /// Insert task titles after references in UTF-8 input; default input is stdin.
    Enrich {
        #[arg(long, default_value = "-")]
        file: PathBuf,
    },
    /// Enrich clipboard text and put the result back on the clipboard.
    EnrichClipboard,
    Show {
        id: String,
    },
    Create {
        #[arg(long, value_enum, default_value = "P2")]
        priority: Priority,
        #[arg(long)]
        labels: Option<String>,
        #[arg(long)]
        title: String,
        #[arg(long = "body-file")]
        body_file: PathBuf,
        #[arg(long)]
        status: Option<TaskStatus>,
        #[arg(long)]
        deps: Option<String>,
        #[arg(long = "clear-deps", default_value_t = false, conflicts_with = "deps")]
        clear_deps: bool,
    },
    Update {
        #[arg(long, value_enum)]
        priority: Option<Priority>,
        #[arg(long, conflicts_with = "clear_labels")]
        labels: Option<String>,
        #[arg(long)]
        clear_labels: bool,
        id: String,
        #[arg(long = "expect-version")]
        expect_version: u64,
        #[arg(long)]
        title: Option<String>,
        #[arg(long = "body-file")]
        body_file: Option<PathBuf>,
        #[arg(long)]
        status: Option<TaskStatus>,
        #[arg(long, conflicts_with = "clear_deps")]
        deps: Option<String>,
        #[arg(long = "clear-deps", default_value_t = false)]
        clear_deps: bool,
    },
    History {
        id: String,
        #[arg(long)]
        after: Option<u64>,
        #[arg(long)]
        limit: Option<usize>,
        #[arg(long = "event")]
        event: Option<u64>,
    },
    #[command(subcommand)]
    Rules(RulesCommand),
    Import {
        #[arg(long, required = true)]
        file: Vec<PathBuf>,
        #[arg(long, default_value_t = false)]
        apply: bool,
        #[arg(long = "expect-sha256")]
        expect_sha256: Vec<String>,
        #[arg(long = "map-file")]
        map_file: Option<PathBuf>,
        #[arg(long = "source-schema", value_enum, default_value = "canonical")]
        source_schema: SourceSchema,
    },
    Export {
        #[arg(long)]
        out: PathBuf,
    },
    BulkImport {
        #[arg(long = "scan-root")]
        scan_root: PathBuf,
        #[arg(long = "map-file")]
        map_file: PathBuf,
        #[arg(long = "report-dir")]
        report_dir: PathBuf,
        #[arg(long = "exclude")]
        exclude: Vec<String>,
        #[arg(long, default_value_t = false)]
        apply: bool,
        #[arg(long = "quarantine-dir")]
        quarantine_dir: Option<PathBuf>,
        #[arg(long = "delete-quarantined", default_value_t = false)]
        delete_quarantined: bool,
        /// Apply only the clean candidates when others have problems.
        #[arg(long = "allow-partial", default_value_t = false)]
        allow_partial: bool,
        #[arg(long = "source-schema", value_enum, default_value = "canonical")]
        source_schema: SourceSchema,
    },
    Backup {
        #[arg(long)]
        out: PathBuf,
    },
    Migrate,
    Doctor,
}

#[derive(Subcommand, Debug, Clone)]
pub enum RulesCommand {
    Show,
    Set {
        #[arg(long = "body-file")]
        body_file: PathBuf,
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
    fn global_options_are_available_after_commands() {
        let cli = Cli::try_parse_from(["tasks", "list", "--format", "json"]).unwrap();
        assert_eq!(cli.format, OutputFormat::Json);
    }
}
