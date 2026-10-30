use crate::bulk::BulkRun;
use crate::model::{
    render_keyed_task_id, AddedAttachment, AttachmentRecord, HistoryEvent, ImportProblem,
    ImportReport, ProblemCounts, RuleRecord, ShowTask, TaskSummary,
};
use crate::viewer::{
    ViewerArchivePayload, ViewerInfoPayload, ViewerProjectsPayload, ViewerShowPayload,
    ViewerTasksPayload, ViewerUpdatePayload,
};
use serde::Serialize;

#[derive(Serialize)]
pub struct ImportFileReport {
    pub path: String,
    pub report: ImportReport,
}

/// `show` with one ID: the task fields at top level, plus the shared rules
/// only when `--rules` was passed.
#[derive(Serialize)]
pub struct ShowPayload {
    #[serde(flatten)]
    pub task: ShowTask,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rule_version: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rules: Option<String>,
}

/// Metadata and a verified local path. Original content is never serialized.
#[derive(Debug, Serialize)]
pub struct MaterializedAttachment {
    pub attachment: AttachmentRecord,
    pub path: String,
    pub reused: bool,
}

#[derive(Debug, Serialize)]
pub struct ClipboardAttachmentItem {
    pub source: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub original_size: u64,
    pub kind: String,
    pub media_type: String,
}

#[derive(Serialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub enum CommandPayload {
    AttachmentAdd {
        id: u64,
        display_id: String,
        status: String,
        version: u64,
        event_id: Option<u64>,
        attachments: Vec<AddedAttachment>,
        attachment_state: crate::model::AttachmentWriteState,
    },
    AttachmentDetach {
        id: u64,
        display_id: String,
        status: String,
        version: u64,
        event_id: Option<u64>,
        detached: Vec<u64>,
        attachment_state: crate::model::AttachmentWriteState,
    },
    AttachmentList {
        id: u64,
        display_id: String,
        version: u64,
        items: Vec<AttachmentRecord>,
        has_more: bool,
        next_after: Option<String>,
    },
    AttachmentGet {
        id: u64,
        display_id: String,
        items: Vec<MaterializedAttachment>,
    },
    AttachmentClipboard {
        items: Vec<ClipboardAttachmentItem>,
        skipped: Vec<crate::clipboard::SkippedClipboardEntry>,
        token: String,
    },
    Init {
        project_id: String,
        project_key: Option<String>,
        db_path: String,
    },
    /// `project-key`: the current key; `--set` adds the key it replaced.
    ProjectKey {
        project_key: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        previous_key: Option<Option<String>>,
    },
    Bind {
        project_id: String,
        root: String,
    },
    List {
        items: Vec<TaskSummary>,
        has_more: bool,
        next_after: Option<String>,
    },
    Unlocks {
        items: Vec<crate::model::UnlockSummary>,
        has_more: bool,
        next_offset: Option<u64>,
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
    Enrich {
        text: String,
        replacements: usize,
        unknown_ids: Vec<u64>,
        unknown_refs: Vec<String>,
        clipboard: bool,
    },
    Show(ShowPayload),
    /// `show` with several IDs; rules appear once, only with `--rules`.
    ShowMany {
        items: Vec<ShowTask>,
        #[serde(skip_serializing_if = "Option::is_none")]
        rule_version: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        rules: Option<String>,
    },
    Create {
        id: u64,
        display_id: String,
        status: String,
        version: u64,
        event_id: Option<u64>,
    },
    Update {
        id: u64,
        display_id: String,
        status: String,
        version: u64,
        event_id: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        task_state: Option<crate::viewer::TaskWriteState>,
    },
    History {
        id: u64,
        display_id: String,
        items: Vec<HistoryEvent>,
        has_more: bool,
        next_after: Option<u64>,
    },
    ProjectHistory {
        items: Vec<crate::model::MetadataEvent>,
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
        attachment_blobs: u64,
        attachment_stored_bytes: u64,
        attachment_quota_bytes: u64,
    },
    ViewerArchive(ViewerArchivePayload),
    ViewerInfo(ViewerInfoPayload),
    ViewerProjects(ViewerProjectsPayload),
    ViewerTasks(ViewerTasksPayload),
    ViewerShow(ViewerShowPayload),
    ViewerUpdate(ViewerUpdatePayload),
}

#[derive(Serialize)]
pub struct Envelope {
    pub schema_version: u8,
    pub project_id: Option<String>,
    pub data: CommandPayload,
    /// Project key for rendering task IDs in text output; JSON carries each
    /// object's own `display_id` instead.
    #[serde(skip)]
    pub id_key: Option<String>,
}

impl Envelope {
    fn attachment_line(item: &crate::model::AttachmentSummary) -> String {
        format!(
            "{}\t{}\t{}\t{} bytes\t{}",
            item.display_id, item.kind, item.media_type, item.original_size, item.name
        )
    }
    fn rid(&self, id: u64) -> String {
        render_keyed_task_id(self.id_key.as_deref(), id)
    }

    /// One tab-separated row; the dependency and label columns appear only
    /// when non-empty.
    fn summary_line(&self, item: &TaskSummary) -> String {
        let mut line = format!(
            "{}\t{}\t{}\tv{}\t{}",
            self.rid(item.id),
            item.priority,
            item.status,
            item.version,
            Self::bound_title(&item.title),
        );
        if !item.deps.is_empty() {
            let deps = item
                .deps
                .iter()
                .map(|d| self.rid(*d))
                .collect::<Vec<_>>()
                .join(",");
            line.push_str(&format!("\t[{deps}]"));
        }
        if !item.labels.is_empty() {
            line.push_str(&format!("\tlabels=[{}]", item.labels.join(",")));
        }
        if item.attachment_count > 0 {
            line.push_str(&format!("\tattachments={}", item.attachment_count));
        }
        line.push('\n');
        line
    }

    fn show_lines(&self, task: &ShowTask) -> String {
        let mut out = String::new();
        out.push_str(&format!("id: {}\n", self.rid(task.id)));
        out.push_str(&format!("status: {}\n", task.status));
        out.push_str(&format!("priority: {}\n", task.priority));
        out.push_str(&format!("version: {}\n", task.version));
        if !task.labels.is_empty() {
            out.push_str(&format!("labels: {}\n", task.labels.join(", ")));
        }
        for dependency in &task.dependency_summaries {
            out.push_str(&format!(
                "depends_on: {0}\t{1}\tv{2}\t{3}\n",
                self.rid(dependency.id),
                dependency.status,
                dependency.version,
                dependency.title
            ));
        }
        for attachment in &task.attachments {
            out.push_str(&format!(
                "attachment: A{}\t{}\t{}\t{} bytes\t{}\n",
                attachment.id,
                attachment.kind,
                attachment.media_type,
                attachment.original_size,
                attachment.name
            ));
        }
        if !task.attachments.is_empty() {
            out.push_str(&format!("attachments: tasks attachment get {} [A{} ...] writes local files and prints their paths\n", self.rid(task.id), task.attachments[0].id));
        }
        out.push_str("title:\n");
        out.push_str(&format!("{}\n", task.title));
        out.push_str("body:\n");
        out.push_str(&task.body);
        out.push('\n');
        out
    }

    fn rules_lines(rule_version: Option<u64>, rules: Option<&str>) -> String {
        match (rule_version, rules) {
            (Some(version), Some(body)) => format!("rules(v{version}):\n{body}\n"),
            _ => String::new(),
        }
    }

    /// One compact JSON line; callers parse it rather than read it.
    pub fn json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".to_string())
    }

    fn bound_title(title: &str) -> String {
        let trimmed = title.trim();
        if trimmed.chars().count() > 120 {
            trimmed.chars().take(120).collect::<String>()
        } else {
            trimmed.to_string()
        }
    }

    fn import_report_lines(&self, report: &ImportReport) -> String {
        let mut out = format!("tasks: {}\n", report.task_count);
        out.push_str(&format!("rules: {}\n", report.rules.len()));
        let duplicates = report
            .duplicate_ids
            .iter()
            .map(|id| self.rid(*id))
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
                .map(|dep| self.rid(*dep))
                .collect::<Vec<_>>()
                .join(",");
            out.push_str(&format!(
                "{0} {1} {2} consumed=[{3}] deps=[{4}] {5}\n",
                self.rid(task.id),
                task.status,
                task.section,
                consumed,
                deps,
                task.title
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
        match &self.data {
            CommandPayload::AttachmentAdd { display_id, status, version, event_id, attachments, .. } => {
                let mut out = format!("id: {display_id}\nstatus: {status}\nversion: {version}\nevent_id: {}\n", event_id.map_or_else(|| "null".into(), |id| id.to_string()));
                for item in attachments {
                    out.push_str(&format!("attached: {}\n", Self::attachment_line(&item.attachment)));
                }
                out
            }
            CommandPayload::AttachmentDetach { display_id, status, version, event_id, detached, .. } => {
                let mut out = format!("id: {display_id}\nstatus: {status}\nversion: {version}\nevent_id: {}\n", event_id.map_or_else(|| "null".into(), |id| id.to_string()));
                for id in detached { out.push_str(&format!("detached: A{id}\n")); }
                out
            }
            CommandPayload::AttachmentList { items, has_more, next_after, .. } => {
                let mut out = String::new();
                for item in items {
                    out.push_str(&Self::attachment_line(&item.attachment));
                    if item.detached_ms.is_some() { out.push_str("\tdetached"); }
                    out.push('\n');
                }
                out.push_str(&format!("has_more: {has_more}\n"));
                if let Some(next) = next_after { out.push_str(&format!("next_after: {next}\n")); }
                out
            }
            CommandPayload::AttachmentGet { items, .. } => items.iter().map(|item| format!("{}\n", item.path)).collect(),
            CommandPayload::AttachmentClipboard { items, token, .. } => {
                let mut out = String::new();
                for item in items {
                    let description = item.path.as_deref().unwrap_or(&item.name);
                    out.push_str(&format!("{}\t{} bytes\t{description}\n", item.source, item.original_size));
                }
                out.push_str(&format!("token: {token}\n"));
                out
            }
            CommandPayload::Init {
                project_id,
                project_key,
                db_path,
            } => {
                format!(
                    "project_id: {project_id}\ndb_path: {db_path}\nproject_key: {}\n",
                    project_key.as_deref().unwrap_or("none")
                )
            }
            CommandPayload::ProjectKey {
                project_key,
                previous_key,
            } => {
                let mut out = format!(
                    "project_key: {}\n",
                    project_key.as_deref().unwrap_or("none")
                );
                if let Some(previous) = previous_key {
                    out.push_str(&format!(
                        "previous_key: {}\n",
                        previous.as_deref().unwrap_or("none")
                    ));
                }
                out
            }
            CommandPayload::Bind { project_id, root } => {
                format!("project_id: {project_id}\nroot: {root}\n")
            }
            CommandPayload::Create {
                display_id,
                status,
                version,
                event_id,
                ..
            } => {
                format!(
                    "id: {display_id}\nstatus: {status}\nversion: {version}\nevent_id: {}\n",
                    event_id.map_or_else(|| "null".to_string(), |id| id.to_string())
                )
            }
            CommandPayload::Update {
                display_id,
                status,
                version,
                event_id,
                ..
            } => {
                format!(
                    "id: {display_id}\nstatus: {status}\nversion: {version}\nevent_id: {}\n",
                    event_id.map_or_else(|| "null".to_string(), |id| id.to_string())
                )
            }
            CommandPayload::List {
                items,
                has_more,
                next_after,
            } => {
                let mut out = items
                    .iter()
                    .map(|item| self.summary_line(item))
                    .collect::<String>();
                out.push_str(&format!("has_more: {has_more}\n"));
                if let Some(next) = next_after { out.push_str(&format!("next_after: {next}\n")); }
                out
            }
            CommandPayload::Unlocks { items, has_more, next_offset } => {
                let mut out = String::new();
                for item in items {
                    out.push_str(&format!("{}\tdirect_open_dependents={}\timmediately_runnable={}\n", self.summary_line(&item.task).trim_end(), item.direct_open_dependents, item.immediately_runnable));
                }
                out.push_str(&format!("has_more: {has_more}\n"));
                if let Some(next) = next_offset { out.push_str(&format!("next_offset: {next}\n")); }
                out
            }
            CommandPayload::Search {
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
                    out.push_str(&self.summary_line(item));
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
            CommandPayload::Enrich {text,..} => text.clone(),
            CommandPayload::Show(show) => {
                let mut out = self.show_lines(&show.task);
                out.push_str(&Self::rules_lines(show.rule_version, show.rules.as_deref()));
                out
            }
            CommandPayload::ShowMany {
                items,
                rule_version,
                rules,
            } => {
                let mut out = items
                    .iter()
                    .map(|task| self.show_lines(task))
                    .collect::<Vec<_>>()
                    .join("\n");
                out.push_str(&Self::rules_lines(*rule_version, rules.as_deref()));
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
                        "{}\tv{}\t{}\t{}",
                        e.event_id, e.resulting_version, e.operation, e.created_ms
                    ));
                    if let Some(fields) = &e.changed_fields {
                        out.push_str(&format!("\tchanged={}", fields.join(",")));
                    }
                    out.push('\n');
                    if let Some(attribution) = &e.attribution {
                        out.push_str("attribution: ");
                        // The value is composed solely of serializable data.
                        out.push_str(&serde_json::json!(attribution).to_string());
                        out.push('\n');
                    }
                    if let Some(snapshot) = &e.snapshot_json {
                        out.push_str("snapshot: ");
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
            CommandPayload::ProjectHistory { items, has_more, next_after } => {
                let mut out = String::new();
                for event in items {
                    out.push_str(&format!("{}\t{}\t{}\n", event.event_id, event.operation, event.created_ms));
                    out.push_str(&format!("snapshot: {}\nattribution: {}\n", event.snapshot, serde_json::json!(event.attribution)));
                }
                out.push_str(&format!("has_more: {has_more}\n"));
                if let Some(next) = next_after { out.push_str(&format!("next_after: {next}\n")); }
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
                    self.import_report_lines(report)
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
                    out.push_str(&self.import_report_lines(&entry.report));
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
                for candidate in &run.candidates {
                    if let Some(problem) = &candidate.key_problem {
                        out.push_str(&format!("key_problem: {problem}\n"));
                    }
                }
                if let Some(manifest) = &run.reports.quarantine_manifest {
                    out.push_str(&format!("quarantine_manifest: {manifest}\n"));
                }
                for candidate in &run.candidates {
                    out.push_str(&format!(
                        "- {} [{}] project={} key={} tasks={} applied={} verified={}\n",
                        candidate.relative_directory,
                        candidate.bucket,
                        candidate.project_id,
                        candidate.project_key.as_deref().unwrap_or("none"),
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
                attachment_blobs,
                attachment_stored_bytes,
                attachment_quota_bytes,
            } => format!(
                "db_path: {db_path}\nproject_id: {project_id}\nschema_version: {schema_version}\nsqlite_version: {sqlite_version}\nattachment_blobs: {attachment_blobs}\nattachment_stored_bytes: {attachment_stored_bytes}\nattachment_quota_bytes: {attachment_quota_bytes}\n"
            ),
            // The viewer protocol is JSON-only; main.rs rejects text mode before
            // dispatch, so this arm exists to keep the renderer exhaustive.
            CommandPayload::ViewerArchive(_)
            | CommandPayload::ViewerInfo(_)
            | CommandPayload::ViewerProjects(_)
            | CommandPayload::ViewerTasks(_)
            | CommandPayload::ViewerShow(_)
            | CommandPayload::ViewerUpdate(_) => serde_json::to_string(self)
                .unwrap_or_else(|_| "viewer payloads require --format json".to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn attachment_json() -> Value {
        json!({"id":12,"display_id":"A12","name":"run.log","kind":"text",
            "media_type":"text/plain; charset=utf-8","original_size":5,"stored_size":57,
            "sha256":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824","added_ms":123})
    }

    fn assert_attachment_render(data: CommandPayload, expected: Value, text: &str) {
        let envelope = Envelope {
            schema_version: 1,
            project_id: Some("project".into()),
            id_key: Some("TSK".into()),
            data,
        };
        assert_eq!(envelope.text(), text);
        assert_eq!(
            serde_json::from_str::<Value>(&envelope.json()).unwrap(),
            json!({"schema_version":1,"project_id":"project","data":expected})
        );
    }

    fn write_state_json() -> Value {
        json!({"items":[],"has_more":false,"next_after":null,"attachment_count":0,"updated_ms":100})
    }

    #[test]
    fn attachment_add_renders_text_and_exact_json() {
        let mut added = attachment_json();
        added["deduplicated"] = json!(true);
        assert_attachment_render(CommandPayload::AttachmentAdd {
            id:1, display_id:"TSK-001".into(), status:"todo".into(), version:9, event_id:Some(431),
            attachments:vec![serde_json::from_value(added.clone()).unwrap()],
            attachment_state: serde_json::from_value(write_state_json()).unwrap(),
        }, json!({"command":"attachment_add","id":1,"display_id":"TSK-001","status":"todo","version":9,"event_id":431,"attachments":[added],"attachment_state":write_state_json()}),
        "id: TSK-001\nstatus: todo\nversion: 9\nevent_id: 431\nattached: A12\ttext\ttext/plain; charset=utf-8\t5 bytes\trun.log\n");
    }

    #[test]
    fn attachment_detach_renders_text_json_and_noop() {
        for (event_id, detached, tail) in [
            (Some(432), vec![12, 13], "detached: A12\ndetached: A13\n"),
            (None, vec![], ""),
        ] {
            let text = format!(
                "id: TSK-001\nstatus: todo\nversion: 10\nevent_id: {}\n{tail}",
                event_id.map_or_else(|| "null".into(), |id| id.to_string())
            );
            let expected = json!({"command":"attachment_detach","id":1,"display_id":"TSK-001","status":"todo","version":10,"event_id":event_id,"detached":detached,"attachment_state":write_state_json()});
            assert_attachment_render(
                CommandPayload::AttachmentDetach {
                    id: 1,
                    display_id: "TSK-001".into(),
                    status: "todo".into(),
                    version: 10,
                    event_id,
                    detached,
                    attachment_state: serde_json::from_value(write_state_json()).unwrap(),
                },
                expected,
                &text,
            );
        }
    }

    #[test]
    fn attachment_list_renders_retained_detached_and_pagination() {
        let mut retained = attachment_json();
        retained["detached_ms"] = Value::Null;
        let mut detached = retained.clone();
        detached["id"] = json!(13);
        detached["display_id"] = json!("A13");
        detached["detached_ms"] = json!(200);
        let items = json!([retained, detached]);
        assert_attachment_render(CommandPayload::AttachmentList { id:1, display_id:"TSK-001".into(), version:10, items:serde_json::from_value(items.clone()).unwrap(), has_more:true, next_after:Some("A13".into()) },
        json!({"command":"attachment_list","id":1,"display_id":"TSK-001","version":10,"items":items,"has_more":true,"next_after":"A13"}),
        "A12\ttext\ttext/plain; charset=utf-8\t5 bytes\trun.log\nA13\ttext\ttext/plain; charset=utf-8\t5 bytes\trun.log\tdetached\nhas_more: true\nnext_after: A13\n");
        assert_attachment_render(
            CommandPayload::AttachmentList {
                id: 1,
                display_id: "TSK-001".into(),
                version: 10,
                items: vec![],
                has_more: false,
                next_after: None,
            },
            json!({"command":"attachment_list","id":1,"display_id":"TSK-001","version":10,"items":[],"has_more":false,"next_after":null}),
            "has_more: false\n",
        );
    }

    #[test]
    fn attachment_get_renders_only_paths_in_text_and_metadata_in_json() {
        let mut record = attachment_json();
        record["detached_ms"] = Value::Null;
        let path = "C:/cache/A12/run.log";
        for reused in [true, false] {
            assert_attachment_render(
                CommandPayload::AttachmentGet {
                    id: 1,
                    display_id: "TSK-001".into(),
                    items: vec![MaterializedAttachment {
                        attachment: serde_json::from_value(record.clone()).unwrap(),
                        path: path.into(),
                        reused,
                    }],
                },
                json!({"command":"attachment_get","id":1,"display_id":"TSK-001","items":[{"attachment":record,"path":path,"reused":reused}]}),
                "C:/cache/A12/run.log\n",
            );
        }
    }

    #[test]
    fn attachment_clipboard_renders_items_skips_token_without_image_path() {
        assert_attachment_render(CommandPayload::AttachmentClipboard { items:vec![
            ClipboardAttachmentItem { source:"image".into(), name:"clipboard image (PNG)".into(), path:None, original_size:412233, kind:"image".into(), media_type:"image/png".into() },
            ClipboardAttachmentItem { source:"file".into(), name:"run.log".into(), path:Some("C:/logs/run.log".into()), original_size:5, kind:"text".into(), media_type:"text/plain; charset=utf-8".into() },
        ], skipped:vec![crate::clipboard::SkippedClipboardEntry { path:"C:/logs".into(), reason:"directory".into() }], token:"abcd".into() },
        json!({"command":"attachment_clipboard","items":[
            {"source":"image","name":"clipboard image (PNG)","original_size":412233,"kind":"image","media_type":"image/png"},
            {"source":"file","name":"run.log","path":"C:/logs/run.log","original_size":5,"kind":"text","media_type":"text/plain; charset=utf-8"}
        ],"skipped":[{"path":"C:/logs","reason":"directory"}],"token":"abcd"}),
        "image\t412233 bytes\tclipboard image (PNG)\nfile\t5 bytes\tC:/logs/run.log\ntoken: abcd\n");
    }

    #[test]
    fn list_text_does_not_render_task_bodies() {
        let envelope = Envelope {
            schema_version: 1,
            project_id: None,
            data: CommandPayload::List {
                items: vec![TaskSummary {
                    attachment_count: 0,
                    priority: Default::default(),
                    labels: vec![],
                    id: 1,
                    display_id: "T-001".to_string(),
                    status: crate::model::TaskStatus::Backlog,
                    version: 1,
                    title: "title".to_string(),
                    deps: Vec::new(),
                }],
                has_more: false,
                next_after: None,
            },
            id_key: None,
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
                        priority: Default::default(),
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
            id_key: None,
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
