use crate::bulk::BulkRun;
use crate::model::{
    HistoryEvent, ImportProblem, ImportReport, ProblemCounts, RuleRecord, TaskDetail, TaskSummary,
};
use serde::Serialize;

#[derive(Serialize)]
pub struct ImportFileReport {
    pub path: String,
    pub report: ImportReport,
}

#[derive(Serialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub enum CommandPayload {
    Init {
        project_id: String,
        db_path: String,
    },
    Bind {
        project_id: String,
        root: String,
    },
    List {
        items: Vec<TaskSummary>,
        has_more: bool,
        next_after: Option<u64>,
    },
    Search {
        items: Vec<TaskSummary>,
        has_more: bool,
        next_after: Option<u64>,
    },
    SearchRanked {
        items: Vec<TaskSummary>,
        has_more: bool,
        next_offset: Option<u64>,
    },
    Show(TaskDetail),
    Create {
        id: u64,
        status: String,
        version: u64,
        event_id: Option<u64>,
    },
    Update {
        id: u64,
        status: String,
        version: u64,
        event_id: Option<u64>,
    },
    History {
        id: u64,
        items: Vec<HistoryEvent>,
        has_more: bool,
        next_after: Option<u64>,
    },
    RulesShow(RuleRecord),
    RulesSet {
        version: u64,
    },
    Import {
        path: String,
        report: ImportReport,
        problems: Vec<ImportProblem>,
        problem_counts: ProblemCounts,
        already_imported: bool,
        applied: bool,
    },
    ImportBatch {
        files: Vec<ImportFileReport>,
        problems: Vec<ImportProblem>,
        problem_counts: ProblemCounts,
        already_imported: bool,
        applied: bool,
    },
    Export {
        out: String,
        task_count: usize,
    },
    BulkImport(BulkRun),
    Backup {
        out: String,
        bytes: u64,
    },
    Migrate {
        from_version: i32,
        to_version: i32,
        backup_path: Option<String>,
    },
    Doctor {
        db_path: String,
        project_id: String,
        schema_version: i32,
        sqlite_version: String,
    },
}

#[derive(Serialize)]
pub struct Envelope {
    pub schema_version: u8,
    pub project_id: Option<String>,
    pub data: CommandPayload,
}

impl Envelope {
    pub fn json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".to_string())
    }

    fn bound_title(title: &str) -> String {
        let trimmed = title.trim();
        if trimmed.chars().count() > 120 {
            trimmed.chars().take(120).collect::<String>()
        } else {
            trimmed.to_string()
        }
    }

    fn import_report_lines(report: &ImportReport) -> String {
        let mut out = format!("tasks: {}\n", report.task_count);
        out.push_str(&format!("rules: {}\n", report.rules.len()));
        let duplicates = report
            .duplicate_ids
            .iter()
            .map(|id| format!("T-{id:03}"))
            .collect::<Vec<_>>()
            .join(",");
        out.push_str(&format!(
            "duplicates: {}\n",
            if duplicates.is_empty() {
                "none"
            } else {
                &duplicates
            }
        ));
        out.push_str(&format!("source_sha256: {}\n", report.source_sha256));
        for task in &report.tasks {
            let consumed = task.consumed_metadata.join(",");
            let deps = task
                .deps
                .iter()
                .map(|dep| format!("T-{dep:03}"))
                .collect::<Vec<_>>()
                .join(",");
            out.push_str(&format!(
                "T-{0:03} {1} {2} consumed=[{3}] deps=[{4}] {5}\n",
                task.id, task.status, task.section, consumed, deps, task.title
            ));
        }
        for section in &report.sections {
            let status = section
                .status
                .as_ref()
                .map(ToString::to_string)
                .unwrap_or_else(|| "unmapped".to_string());
            out.push_str(&format!(
                "section: {} status={} contains_tasks={}\n",
                section.heading, status, section.contains_tasks
            ));
        }
        for range in &report.unassigned_ranges {
            out.push_str(&format!(
                "unassigned: {}-{} {}\n",
                range.start_byte, range.end_byte, range.preview
            ));
        }
        let ambiguous = report.ambiguous_sections.join(",");
        out.push_str(&format!(
            "ambiguous_sections: {}\n",
            if ambiguous.is_empty() {
                "none"
            } else {
                &ambiguous
            }
        ));
        out.push_str(&format!(
            "has_unknown_content: {}\n",
            report.has_unknown_content
        ));
        out.push_str(&format!("has_bom: {}\n", report.has_bom));
        for warning in &report.warnings {
            out.push_str(&format!("warning: {warning}\n"));
        }
        out
    }

    /// The count line always comes first, then every problem in one list.
    fn import_problem_lines(problems: &[ImportProblem], counts: &ProblemCounts) -> String {
        let mut out = format!("problems: {}\n", counts.line());
        for problem in problems {
            out.push_str(&format!("problem: {}\n", problem.message));
        }
        out
    }

    pub fn text(&self) -> String {
        let mut out = match &self.data {
            CommandPayload::Init { project_id, db_path } => {
                format!("project_id: {project_id}\ndb_path: {db_path}\n")
            }
            CommandPayload::Bind { project_id, root } => {
                format!("project_id: {project_id}\nroot: {root}\n")
            }
            CommandPayload::Create {
                id,
                status,
                version,
                event_id,
            } => {
                format!(
                    "id: T-{id:03}\nstatus: {status}\nversion: {version}\nevent_id: {}\n",
                    event_id.map_or_else(|| "null".to_string(), |id| id.to_string())
                )
            }
            CommandPayload::Update {
                id,
                status,
                version,
                event_id,
            } => {
                format!(
                    "id: T-{id:03}\nstatus: {status}\nversion: {version}\nevent_id: {}\n",
                    event_id.map_or_else(|| "null".to_string(), |id| id.to_string())
                )
            }
            CommandPayload::List {
                items,
                has_more,
                next_after,
            }
            | CommandPayload::Search {
                items,
                has_more,
                next_after,
            }
            | CommandPayload::SearchRanked {
                items,
                has_more,
                next_offset: next_after,
            } => {
                let mut out = String::new();
                for item in items {
                    let deps = item
                        .deps
                        .iter()
                        .map(|d| format!("T-{d:03}"))
                        .collect::<Vec<_>>()
                        .join(",");
                    out.push_str(&format!(
                        "T-{0:03}\t{1}\tv{2}\t{3}\t[{4}]\tlabels=[{5}]\n",
                        item.id,
                        item.status,
                        item.version,
                        Self::bound_title(&item.title),
                        deps,
                        item.labels.join(",")
                    ));
                }
                out.push_str(&format!("has_more: {has_more}\n"));
                if let Some(next) = next_after {
                    let cursor_name = if matches!(self.data, CommandPayload::SearchRanked { .. }) {
                        "next_offset"
                    } else {
                        "next_after"
                    };
                    out.push_str(&format!("{cursor_name}: {next}\n"));
                }
                out
            }
            CommandPayload::Show(task) => {
                let mut out = String::new();
                out.push_str(&format!("id: T-{0:03}\n", task.id));
                out.push_str(&format!("status: {}\n", task.status));
                out.push_str(&format!("version: {}\n", task.version));
                out.push_str(&format!("labels: {}\n", task.labels.join(", ")));
                out.push_str(&format!("dependencies: {}\n", task.deps.len()));
                for dependency in &task.dependency_summaries {
                    out.push_str(&format!(
                        "depends_on: T-{0:03}\t{1}\tv{2}\t{3}\n",
                        dependency.id, dependency.status, dependency.version, dependency.title
                    ));
                }
                out.push_str("title:\n");
                out.push_str(&format!("{}\n", task.title));
                out.push_str("body:\n");
                out.push_str(&task.body);
                out.push('\n');
                out.push_str(&format!("rules(v{}):\n{}\n", task.rule_version, task.rules));
                out
            }
            CommandPayload::History {
                items,
                has_more,
                next_after,
                ..
            } => {
                let mut out = String::new();
                for e in items {
                    out.push_str(&format!(
                        "{}\tv{}\t{}\t{}\t{}\n",
                        e.event_id, e.resulting_version, e.entity_type, e.operation, e.created_ms
                    ));
                    if let Some(snapshot) = &e.snapshot_json {
                        out.push_str("snapshot_json: ");
                        out.push_str(snapshot);
                        out.push('\n');
                    }
                }
                out.push_str(&format!("has_more: {has_more}\n"));
                if let Some(next) = next_after {
                    out.push_str(&format!("next_after: {next}\n"));
                }
                out
            }
            CommandPayload::RulesShow(rules) => {
                format!("version: {}\n{}\n", rules.version, rules.body)
            }
            CommandPayload::RulesSet { version } => format!("version: {version}\n"),
            CommandPayload::Import {
                path,
                report,
                problems,
                problem_counts,
                already_imported,
                applied,
            } => {
                let mut out = format!(
                    "file: {path}\napplied: {applied}\nalready_imported: {already_imported}\n{}",
                    Self::import_report_lines(report)
                );
                out.push_str(&Self::import_problem_lines(problems, problem_counts));
                out
            }
            CommandPayload::ImportBatch {
                files,
                problems,
                problem_counts,
                already_imported,
                applied,
            } => {
                let mut out = format!(
                    "files: {}\napplied: {applied}\nalready_imported: {already_imported}\n",
                    files.len()
                );
                for entry in files {
                    out.push_str(&format!("file: {}\n", entry.path));
                    out.push_str(&Self::import_report_lines(&entry.report));
                }
                out.push_str(&Self::import_problem_lines(problems, problem_counts));
                out
            }
            CommandPayload::Export { out, task_count } => {
                format!("out: {out}\ntasks: {task_count}\n")
            }
            CommandPayload::BulkImport(run) => {
                let summary = &run.summary;
                let mut out = format!(
                    "mode: {}\nscan_root: {}\nreport_dir: {}\ncandidates: {}\nrecognized: {}\nrecognized_with_warnings: {}\nunrecognized: {}\nexcluded: {}\napplied_projects: {}\nverified_projects: {}\nfailed_projects: {}\nquarantined_files: {}\ndeleted_quarantined_files: {}\nreports: run.jsonl={} summary.md={} unrecognized.md={}\n",
                    if summary.apply { "apply" } else { "dry run" },
                    summary.scan_root,
                    summary.report_dir,
                    summary.candidates,
                    summary.recognized,
                    summary.recognized_with_warnings,
                    summary.unrecognized,
                    summary.excluded,
                    summary.applied_projects,
                    summary.verified_projects,
                    summary.failed_projects,
                    summary.quarantined_files,
                    summary.deleted_quarantined_files,
                    run.reports.run_jsonl,
                    run.reports.summary_md,
                    run.reports.unrecognized_md,
                );
                if let Some(manifest) = &run.reports.quarantine_manifest {
                    out.push_str(&format!("quarantine_manifest: {manifest}\n"));
                }
                for candidate in &run.candidates {
                    out.push_str(&format!(
                        "- {} [{}] project={} tasks={} applied={} verified={}\n",
                        candidate.relative_directory,
                        candidate.bucket,
                        candidate.project_id,
                        candidate.task_count,
                        candidate.applied,
                        candidate.verified
                    ));
                }
                out
            }
            CommandPayload::Backup { out, bytes } => {
                format!("out: {out}\nbytes: {bytes}\n")
            }
            CommandPayload::Migrate {
                from_version,
                to_version,
                backup_path,
            } => format!(
                "migrated: {from_version} -> {to_version}\nbackup_path: {}\n",
                backup_path.as_deref().unwrap_or("null")
            ),
            CommandPayload::Doctor {
                db_path,
                project_id,
                schema_version,
                sqlite_version,
            } => format!(
                "db_path: {db_path}\nproject_id: {project_id}\nschema_version: {schema_version}\nsqlite_version: {sqlite_version}\n"
            ),
        };
        if let Some(project_id) = &self.project_id {
            if !matches!(
                &self.data,
                CommandPayload::Init { .. } | CommandPayload::Bind { .. }
            ) {
                out = format!("project_id: {project_id}\n{out}");
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_text_does_not_render_task_bodies() {
        let envelope = Envelope {
            schema_version: 1,
            project_id: None,
            data: CommandPayload::List {
                items: vec![TaskSummary {
                    labels: vec![],
                    id: 1,
                    status: crate::model::TaskStatus::Backlog,
                    version: 1,
                    title: "title".to_string(),
                    deps: Vec::new(),
                }],
                has_more: false,
                next_after: None,
            },
        };
        let text = envelope.text();
        assert!(text.contains("title"));
        assert!(!text.contains("body:"));
    }

    #[test]
    fn import_text_preview_is_line_oriented() {
        let problem = ImportProblem {
            kind: "nonconforming-deps".to_string(),
            message: "input.md: line 3: task T-001: nonconforming Deps line 'Deps: T-099'"
                .to_string(),
            file: Some("input.md".to_string()),
            line: Some(3),
            task_id: Some(1),
            value: Some("T-099".to_string()),
            keepable_ids: Vec::new(),
            group: Vec::new(),
            fix: Some(
                "keep only these IDs in Deps and move the rest of the original text to Notes"
                    .to_string(),
            ),
        };
        let envelope = Envelope {
            schema_version: 1,
            project_id: None,
            data: CommandPayload::Import {
                path: "input.md".to_string(),
                report: ImportReport {
                    source_sha256: "hash".to_string(),
                    has_bom: true,
                    task_count: 1,
                    tasks: vec![crate::model::ImportTaskPreview {
                        labels: vec![],
                        id: 1,
                        title: "Title".to_string(),
                        section: "ready".to_string(),
                        status: crate::model::TaskStatus::Ready,
                        deps: Vec::new(),
                        consumed_metadata: vec!["Status".to_string(), "Body".to_string()],
                    }],
                    sections: vec![crate::model::ImportSectionPreview {
                        heading: "ready".to_string(),
                        status: Some(crate::model::TaskStatus::Ready),
                        contains_tasks: true,
                    }],
                    rules: String::new(),
                    duplicate_ids: Vec::new(),
                    unmapped_sections: Vec::new(),
                    ambiguous_sections: Vec::new(),
                    unassigned_ranges: vec![crate::model::SourceRange {
                        start_byte: 4,
                        end_byte: 8,
                        preview: "leftover".to_string(),
                    }],
                    has_unknown_content: true,
                    warnings: vec!["input.md: line 2: task T-001: section warning".to_string()],
                },
                problem_counts: ProblemCounts::of(std::slice::from_ref(&problem)),
                problems: vec![problem],
                already_imported: false,
                applied: false,
            },
        };
        let text = envelope.text();
        assert!(text.contains("T-001 todo ready consumed=[Status,Body] deps=[] Title"));
        assert!(text.contains("section: ready status=todo contains_tasks=true"));
        assert!(text.contains("unassigned: 4-8 leftover"));
        assert!(text.contains("has_bom: true"));
        assert!(text.contains("warning: input.md: line 2"));
        assert!(!text.contains("ImportTaskPreview"));
    }
}
