use crate::error::AppError;
use crate::markdown::{self, ParsedImport, SectionMap};
use crate::model::{ImportProblem, ImportReport, ProblemCounts, SourceSchema};
use crate::problems;
use crate::registry;
use crate::store::Store;
use regex::Regex;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

const LEDGER_NAMES: [&str; 2] = ["TASKS.md", "TASKS.ARCHIVE.md"];
const PRUNE_NAMES: [&str; 4] = [".git", "target", "node_modules", "3rdParty"];
const REFERENCE_NAMES: [&str; 2] = ["AGENTS.md", "CLAUDE.md"];
const REFERENCE_NEEDLE: &str = "TASKS.md";
const RUN_JSONL: &str = "run.jsonl";
const SUMMARY_MD: &str = "summary.md";
const UNRECOGNIZED_MD: &str = "unrecognized.md";
const EXPORT_DIR: &str = "exports";
const MANIFEST_JSON: &str = "quarantine-manifest.json";
const MAX_REPORTED_MISMATCHES: usize = 5;

pub const BUCKET_RECOGNIZED: &str = "recognized";
pub const BUCKET_RECOGNIZED_WITH_WARNINGS: &str = "recognized-with-warnings";
pub const BUCKET_UNRECOGNIZED: &str = "unrecognized";
pub const BUCKET_EXCLUDED: &str = "excluded";

#[derive(Debug, Clone)]
pub struct BulkOptions {
    pub data_root: PathBuf,
    pub scan_root: PathBuf,
    pub map_file: PathBuf,
    pub report_dir: PathBuf,
    pub excludes: Vec<String>,
    pub apply: bool,
    pub quarantine_dir: Option<PathBuf>,
    pub delete_quarantined: bool,
    pub source_schema: SourceSchema,
}

#[derive(Debug, Serialize)]
pub struct BulkRun {
    pub summary: BulkSummary,
    pub candidates: Vec<BulkCandidate>,
    pub excluded_paths: Vec<ExcludedPathRecord>,
    pub reports: BulkReportPaths,
    #[serde(skip)]
    pub failed: usize,
}

#[derive(Debug, Serialize)]
pub struct BulkSummary {
    pub scan_root: String,
    pub data_root: String,
    pub report_dir: String,
    pub map_file: String,
    pub apply: bool,
    pub source_schema: String,
    pub quarantine_dir: Option<String>,
    pub delete_quarantined: bool,
    pub candidates: usize,
    pub recognized: usize,
    pub recognized_with_warnings: usize,
    pub unrecognized: usize,
    pub excluded: usize,
    pub applied_projects: usize,
    pub verified_projects: usize,
    pub failed_projects: usize,
    pub pruned_directories: BTreeMap<String, usize>,
    pub excluded_paths: usize,
    pub ledger_references: usize,
    pub quarantined_files: usize,
    pub deleted_quarantined_files: usize,
}

#[derive(Debug, Serialize)]
pub struct BulkReportPaths {
    pub run_jsonl: String,
    pub summary_md: String,
    pub unrecognized_md: String,
    pub quarantine_manifest: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ExcludedPathRecord {
    pub path: String,
    pub relative_path: String,
    pub kind: String,
    pub reason: String,
}

#[derive(Debug, Serialize)]
pub struct BulkFileRecord {
    pub path: String,
    pub relative_path: String,
    pub bytes: usize,
    pub sha256: String,
    pub has_bom: bool,
    pub schema_class: String,
    pub has_schema_marker: bool,
    pub error: Option<String>,
    pub preview: Option<ImportReport>,
}

#[derive(Debug, Clone, Serialize)]
pub struct QuarantineRecord {
    pub source: String,
    pub destination: String,
    pub size: u64,
    pub sha256: String,
    pub status: String,
}

#[derive(Debug, Serialize)]
pub struct LedgerReferenceRecord {
    pub path: String,
    pub relative_path: String,
    pub lines: Vec<usize>,
}

#[derive(Debug, Serialize)]
pub struct BulkCandidate {
    pub directory: String,
    pub relative_directory: String,
    pub bucket: String,
    pub reason: Option<String>,
    pub reasons: Vec<String>,
    pub problems: Vec<ImportProblem>,
    pub problem_counts: ProblemCounts,
    pub warnings: Vec<String>,
    pub project_id: String,
    pub project_root: String,
    pub task_count: usize,
    pub files: Vec<BulkFileRecord>,
    pub applied: bool,
    pub already_imported: bool,
    pub verified: bool,
    pub verification_error: Option<String>,
    pub apply_error: Option<String>,
    pub quarantine: Vec<QuarantineRecord>,
    pub quarantined: bool,
    pub ledger_references: Vec<LedgerReferenceRecord>,
}

#[derive(Debug, Clone, Serialize)]
struct ManifestEntry {
    pub project_id: String,
    pub original_path: String,
    pub size: u64,
    pub sha256: String,
    pub destination: String,
    pub deleted: bool,
}

#[derive(Debug, Serialize)]
struct QuarantineManifest {
    pub format_version: u32,
    pub scan_root: String,
    pub data_root: String,
    pub quarantine_dir: String,
    pub apply: bool,
    pub delete_quarantined: bool,
    pub entries: Vec<ManifestEntry>,
}

#[derive(Debug, Clone)]
struct LedgerSource {
    name: String,
    path: PathBuf,
}

#[derive(Debug, Default)]
struct ScanResult {
    ledger_dirs: BTreeMap<PathBuf, Vec<LedgerSource>>,
    excluded_ledger_dirs: BTreeMap<PathBuf, Vec<String>>,
    excluded: Vec<ExcludedPathRecord>,
    pruned: BTreeMap<String, usize>,
}

enum CandidateInput {
    Ledgers(Vec<LedgerSource>),
    ExcludedOnly(Vec<String>),
}

struct CandidateOutcome {
    bucket: String,
    reason: Option<String>,
    reasons: Vec<String>,
    problems: Vec<ImportProblem>,
    counts: ProblemCounts,
    warnings: Vec<String>,
    files: Vec<BulkFileRecord>,
    task_count: usize,
    parsed: Vec<(String, ParsedImport)>,
    applied: bool,
    already_imported: bool,
    verified: bool,
    verification_error: Option<String>,
    apply_error: Option<String>,
    quarantine: Vec<QuarantineRecord>,
    quarantined: bool,
    manifest: Vec<ManifestEntry>,
    export_path: Option<String>,
    deleted: usize,
}

struct ScannedLedger {
    source: LedgerSource,
    bytes: Vec<u8>,
    sha256: String,
    relative: String,
    parsed: Result<ParsedImport, AppError>,
}

fn resolved_task_ids<'a>(parsed: impl Iterator<Item = &'a ParsedImport>) -> HashSet<u64> {
    parsed
        .flat_map(|parsed| parsed.tasks.iter().map(|task| task.id))
        .collect()
}

pub fn run(options: BulkOptions) -> Result<BulkRun, AppError> {
    let scan_root = options
        .scan_root
        .canonicalize()
        .map_err(|error| AppError::io_path("resolve --scan-root", &options.scan_root, error))?;
    if !scan_root.is_dir() {
        return Err(AppError::InvalidPath(format!(
            "--scan-root {} is not a directory; pass the directory that contains the ledgers",
            scan_root.display()
        )));
    }
    let report_dir = options.report_dir.clone();
    fs::create_dir_all(&report_dir)
        .map_err(|error| AppError::io_path("create --report-dir", &report_dir, error))?;
    let probe = report_dir.join(format!(".tasks-cli-write-probe-{}", std::process::id()));
    fs::write(&probe, b"tasks-cli bulk-import write probe")
        .map_err(|error| AppError::io_path("write the report-dir probe file", &probe, error))?;
    let _ = fs::remove_file(&probe);

    let map = markdown::load_section_map(&options.map_file)?.for_corpus();
    let excludes = options
        .excludes
        .iter()
        .map(|pattern| Ok((pattern.clone(), compile_glob(pattern)?)))
        .collect::<Result<Vec<_>, AppError>>()?;

    let scan = scan_tree(&scan_root, &excludes)?;

    let mut inputs: Vec<(PathBuf, CandidateInput)> = scan
        .ledger_dirs
        .iter()
        .map(|(dir, files)| (dir.clone(), CandidateInput::Ledgers(files.clone())))
        .collect();
    for (dir, names) in &scan.excluded_ledger_dirs {
        if !scan.ledger_dirs.contains_key(dir) {
            inputs.push((dir.clone(), CandidateInput::ExcludedOnly(names.clone())));
        }
    }
    inputs.sort_by_key(|(dir, _)| relative_text(&scan_root, dir));

    let mut candidates = Vec::with_capacity(inputs.len());
    let mut manifest = Vec::new();
    let mut failed = 0usize;

    for (index, (dir, input)) in inputs.iter().enumerate() {
        let project_id = match existing_binding(&options.data_root, dir)? {
            Some(existing) => existing,
            None => derived_project_id(dir).to_string(),
        };
        let outcome =
            process_candidate(index, dir, input, &scan_root, &options, &map, &project_id)?;
        if outcome.bucket == BUCKET_UNRECOGNIZED
            || outcome.apply_error.is_some()
            || (outcome.applied && !outcome.verified)
        {
            failed += 1;
        }
        manifest.extend(outcome.manifest);
        candidates.push(BulkCandidate {
            directory: dir.display().to_string(),
            relative_directory: display_relative(&scan_root, dir),
            bucket: outcome.bucket,
            reason: outcome.reason,
            reasons: outcome.reasons,
            problems: outcome.problems,
            problem_counts: outcome.counts,
            warnings: outcome.warnings,
            project_id,
            project_root: dir.display().to_string(),
            task_count: outcome.task_count,
            files: outcome.files,
            applied: outcome.applied,
            already_imported: outcome.already_imported,
            verified: outcome.verified,
            verification_error: outcome.verification_error,
            apply_error: outcome.apply_error,
            quarantine: outcome.quarantine,
            quarantined: outcome.quarantined,
            ledger_references: Vec::new(),
        });
        let _ = outcome.parsed;
        let _ = outcome.export_path;
        let _ = outcome.deleted;
    }

    for candidate in candidates.iter_mut() {
        if candidate.bucket == BUCKET_RECOGNIZED
            || candidate.bucket == BUCKET_RECOGNIZED_WITH_WARNINGS
        {
            candidate.ledger_references = find_ledger_references(Path::new(&candidate.directory))?;
        }
    }

    let mut summary = BulkSummary {
        scan_root: scan_root.display().to_string(),
        data_root: options.data_root.display().to_string(),
        report_dir: report_dir.display().to_string(),
        map_file: options.map_file.display().to_string(),
        apply: options.apply,
        source_schema: schema_name(options.source_schema).to_string(),
        quarantine_dir: options
            .quarantine_dir
            .as_ref()
            .map(|path| path.display().to_string()),
        delete_quarantined: options.delete_quarantined,
        candidates: candidates.len(),
        recognized: 0,
        recognized_with_warnings: 0,
        unrecognized: 0,
        excluded: 0,
        applied_projects: 0,
        verified_projects: 0,
        failed_projects: 0,
        pruned_directories: scan.pruned.clone(),
        excluded_paths: scan.excluded.len(),
        ledger_references: candidates
            .iter()
            .map(|candidate| candidate.ledger_references.len())
            .sum(),
        quarantined_files: candidates
            .iter()
            .flat_map(|candidate| candidate.quarantine.iter())
            .filter(|record| record.status == "moved" || record.status == "deleted")
            .count(),
        deleted_quarantined_files: candidates
            .iter()
            .flat_map(|candidate| candidate.quarantine.iter())
            .filter(|record| record.status == "deleted")
            .count(),
    };
    for candidate in &candidates {
        match candidate.bucket.as_str() {
            BUCKET_RECOGNIZED => summary.recognized += 1,
            BUCKET_RECOGNIZED_WITH_WARNINGS => summary.recognized_with_warnings += 1,
            BUCKET_UNRECOGNIZED => summary.unrecognized += 1,
            _ => summary.excluded += 1,
        }
        if candidate.applied {
            summary.applied_projects += 1;
        }
        if candidate.verified {
            summary.verified_projects += 1;
        }
        if candidate.apply_error.is_some() || candidate.verification_error.is_some() {
            summary.failed_projects += 1;
        }
    }

    let reports = write_reports(
        &report_dir,
        &summary,
        &candidates,
        &scan.excluded,
        &manifest,
        &options,
        &scan_root,
    )?;

    Ok(BulkRun {
        summary,
        candidates,
        excluded_paths: scan.excluded,
        reports,
        failed,
    })
}

#[allow(clippy::too_many_arguments)]
fn write_reports(
    report_dir: &Path,
    summary: &BulkSummary,
    candidates: &[BulkCandidate],
    excluded_paths: &[ExcludedPathRecord],
    manifest: &[ManifestEntry],
    options: &BulkOptions,
    scan_root: &Path,
) -> Result<BulkReportPaths, AppError> {
    let run_path = report_dir.join(RUN_JSONL);
    let mut jsonl = String::new();
    for candidate in candidates {
        jsonl.push_str(&serde_json::to_string(candidate)?);
        jsonl.push('\n');
    }
    fs::write(&run_path, jsonl)
        .map_err(|error| AppError::io_path("write the run report", &run_path, error))?;

    let summary_path = report_dir.join(SUMMARY_MD);
    fs::write(
        &summary_path,
        render_summary(summary, candidates, excluded_paths),
    )
    .map_err(|error| AppError::io_path("write the summary report", &summary_path, error))?;

    let unrecognized_path = report_dir.join(UNRECOGNIZED_MD);
    fs::write(&unrecognized_path, render_unmigrated(summary, candidates)).map_err(|error| {
        AppError::io_path("write the unmigrated report", &unrecognized_path, error)
    })?;

    let manifest_path = if options.apply && options.quarantine_dir.is_some() {
        let path = report_dir.join(MANIFEST_JSON);
        let document = QuarantineManifest {
            format_version: 1,
            scan_root: scan_root.display().to_string(),
            data_root: options.data_root.display().to_string(),
            quarantine_dir: options
                .quarantine_dir
                .as_ref()
                .map(|dir| absolute_path(dir).display().to_string())
                .unwrap_or_default(),
            apply: options.apply,
            delete_quarantined: options.delete_quarantined,
            entries: manifest.to_vec(),
        };
        fs::write(&path, serde_json::to_string_pretty(&document)?)
            .map_err(|error| AppError::io_path("write the quarantine manifest", &path, error))?;
        Some(path.display().to_string())
    } else {
        None
    };

    Ok(BulkReportPaths {
        run_jsonl: run_path.display().to_string(),
        summary_md: summary_path.display().to_string(),
        unrecognized_md: unrecognized_path.display().to_string(),
        quarantine_manifest: manifest_path,
    })
}

fn render_summary(
    summary: &BulkSummary,
    candidates: &[BulkCandidate],
    excluded_paths: &[ExcludedPathRecord],
) -> String {
    let mut out = String::new();
    out.push_str("# tasks-cli bulk-import summary\n\n");
    out.push_str(&format!(
        "Mode: {}\n\n",
        if summary.apply { "apply" } else { "dry run" }
    ));
    out.push_str(&format!("- scan root: {}\n", summary.scan_root));
    out.push_str(&format!("- data root: {}\n", summary.data_root));
    out.push_str(&format!("- report dir: {}\n", summary.report_dir));
    out.push_str(&format!("- map file: {}\n", summary.map_file));
    out.push_str(&format!("- source schema: {}\n", summary.source_schema));
    match &summary.quarantine_dir {
        Some(dir) => out.push_str(&format!("- quarantine dir: {dir}\n")),
        None => out.push_str("- quarantine dir: (none; nothing is moved or deleted)\n"),
    }
    out.push_str(&format!(
        "- delete quarantined: {}\n\n",
        summary.delete_quarantined
    ));

    out.push_str("## Counts\n\n");
    out.push_str(&format!("- candidates: {}\n", summary.candidates));
    out.push_str(&format!("- recognized: {}\n", summary.recognized));
    out.push_str(&format!(
        "- recognized with warnings: {}\n",
        summary.recognized_with_warnings
    ));
    out.push_str(&format!("- unrecognized: {}\n", summary.unrecognized));
    out.push_str(&format!("- excluded: {}\n", summary.excluded));
    out.push_str(&format!(
        "- applied projects: {}\n",
        summary.applied_projects
    ));
    out.push_str(&format!(
        "- verified projects: {}\n",
        summary.verified_projects
    ));
    out.push_str(&format!("- failed projects: {}\n", summary.failed_projects));
    out.push_str(&format!(
        "- quarantined files: {}\n",
        summary.quarantined_files
    ));
    out.push_str(&format!(
        "- deleted quarantined files: {}\n",
        summary.deleted_quarantined_files
    ));
    out.push_str(&format!("- excluded paths: {}\n", summary.excluded_paths));
    out.push_str(&format!(
        "- AGENTS.md/CLAUDE.md files referencing TASKS.md: {}\n",
        summary.ledger_references
    ));
    if !summary.pruned_directories.is_empty() {
        let pruned = summary
            .pruned_directories
            .iter()
            .map(|(name, count)| format!("{name}={count}"))
            .collect::<Vec<_>>()
            .join(", ");
        out.push_str(&format!("- pruned directories: {pruned}\n"));
    }
    out.push('\n');

    out.push_str("## Candidates\n\n");
    if candidates.is_empty() {
        out.push_str("No TASKS.md or TASKS.ARCHIVE.md files were discovered.\n\n");
    }
    for (index, candidate) in candidates.iter().enumerate() {
        out.push_str(&format!(
            "### {:03} {} [{}]\n\n",
            index + 1,
            candidate.relative_directory,
            candidate.bucket
        ));
        out.push_str(&format!("- {}\n", candidate.problem_counts.line()));
        for problem in &candidate.problems {
            out.push_str(&format!("- problem: {}\n", problem.message));
        }
        out.push_str(&format!("- directory: {}\n", candidate.directory));
        out.push_str(&format!("- project UUID: {}\n", candidate.project_id));
        out.push_str(&format!("- tasks: {}\n", candidate.task_count));
        out.push_str(&format!(
            "- applied: {}; verified: {}\n",
            candidate.applied, candidate.verified
        ));
        if candidate.already_imported {
            out.push_str("- the sources were already imported verbatim in an earlier run\n");
        }
        for warning in &candidate.warnings {
            out.push_str(&format!("- warning: {warning}\n"));
        }
        if let Some(reason) = &candidate.reason {
            out.push_str(&format!("- reason: {reason}\n"));
        }
        if let Some(error) = &candidate.apply_error {
            out.push_str(&format!("- apply failed: {error}\n"));
        }
        if let Some(error) = &candidate.verification_error {
            out.push_str(&format!("- verification failed: {error}\n"));
        }
        out.push('\n');
        out.push_str("#### Files\n\n");
        for file in &candidate.files {
            out.push_str(&format!(
                "- {} ({} bytes, sha256 {}, bom={}, schema={})\n",
                file.relative_path, file.bytes, file.sha256, file.has_bom, file.schema_class
            ));
            if let Some(error) = &file.error {
                out.push_str(&format!("  - parse error: {error}\n"));
            }
            if let Some(preview) = &file.preview {
                out.push_str(&format!("  - tasks in preview: {}\n", preview.task_count));
                if !preview.rules.trim().is_empty() {
                    out.push_str(&format!("  - rules: {} bytes\n", preview.rules.len()));
                }
                for section in &preview.sections {
                    out.push_str(&format!(
                        "  - section \"{}\": status {}, contains_tasks={}\n",
                        section.heading,
                        section
                            .status
                            .as_ref()
                            .map(ToString::to_string)
                            .unwrap_or_else(|| "(none)".to_string()),
                        section.contains_tasks
                    ));
                }
            }
        }
        out.push('\n');
        if !candidate.quarantine.is_empty() {
            out.push_str("#### Quarantine\n\n");
            for record in &candidate.quarantine {
                out.push_str(&format!(
                    "- {} -> {} ({} bytes, sha256 {}, {})\n",
                    record.source, record.destination, record.size, record.sha256, record.status
                ));
            }
            out.push('\n');
        }
        if !candidate.ledger_references.is_empty() {
            out.push_str("#### Ledger references\n\n");
            for reference in &candidate.ledger_references {
                out.push_str(&format!(
                    "- {} lines {}\n",
                    reference.relative_path,
                    reference
                        .lines
                        .iter()
                        .map(usize::to_string)
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
            }
            out.push('\n');
        }
    }

    if !excluded_paths.is_empty() {
        out.push_str("## Excluded paths\n\n");
        for record in excluded_paths {
            out.push_str(&format!(
                "- [{}] {} - {}\n",
                record.kind, record.relative_path, record.reason
            ));
        }
        out.push('\n');
    }
    out
}

fn render_unmigrated(summary: &BulkSummary, candidates: &[BulkCandidate]) -> String {
    let mut out = String::new();
    out.push_str("# Unrecognized schema and unmigrated files\n\n");
    out.push_str(&format!(
        "Mode: {}. Every entry names the file and the reason it was left in place.\n\n",
        if summary.apply { "apply" } else { "dry run" }
    ));
    let mut wrote_section = false;
    for (heading, bucket) in [
        ("Unrecognized schema", BUCKET_UNRECOGNIZED),
        ("Excluded", BUCKET_EXCLUDED),
    ] {
        let matching = candidates
            .iter()
            .filter(|candidate| candidate.bucket == bucket)
            .collect::<Vec<_>>();
        if matching.is_empty() {
            continue;
        }
        wrote_section = true;
        out.push_str(&format!("## {heading} ({} candidates)\n\n", matching.len()));
        for candidate in matching {
            out.push_str(&format!("### {}\n\n", candidate.relative_directory));
            if candidate.files.is_empty() {
                out.push_str(&format!(
                    "- {}\n\n",
                    candidate.reason.as_deref().unwrap_or("excluded")
                ));
                continue;
            }
            if !candidate.problems.is_empty() {
                out.push_str(&format!("- {}\n", candidate.problem_counts.line()));
                for problem in &candidate.problems {
                    out.push_str(&format!("  - {}\n", problem.message));
                }
                out.push('\n');
                continue;
            }
            let reasons = if candidate.reasons.is_empty() {
                vec![candidate
                    .reason
                    .clone()
                    .unwrap_or_else(|| "no reason recorded".to_string())]
            } else {
                candidate.reasons.clone()
            };
            for file in &candidate.files {
                out.push_str(&format!("- {}\n", file.relative_path));
                if let Some(error) = &file.error {
                    out.push_str(&format!("  - {error}\n"));
                    continue;
                }
                let prefix = format!("{}:", file.relative_path);
                let specific = reasons
                    .iter()
                    .filter(|reason| reason.starts_with(&prefix))
                    .collect::<Vec<_>>();
                let listed = if specific.is_empty() {
                    reasons.iter().collect::<Vec<_>>()
                } else {
                    specific
                };
                for reason in listed {
                    out.push_str(&format!("  - {reason}\n"));
                }
            }
            out.push('\n');
        }
    }

    let broken = candidates
        .iter()
        .filter(|candidate| {
            candidate.apply_error.is_some() || candidate.verification_error.is_some()
        })
        .collect::<Vec<_>>();
    if !broken.is_empty() {
        wrote_section = true;
        out.push_str(&format!(
            "## Not migrated: apply or verification failed ({})\n\n",
            broken.len()
        ));
        for candidate in broken {
            out.push_str(&format!("### {}\n\n", candidate.relative_directory));
            for file in &candidate.files {
                out.push_str(&format!("- {}\n", file.relative_path));
            }
            if let Some(error) = &candidate.apply_error {
                out.push_str(&format!("  - apply failed: {error}\n"));
            }
            if let Some(error) = &candidate.verification_error {
                out.push_str(&format!("  - verification failed: {error}\n"));
            }
            out.push('\n');
        }
    }

    if !wrote_section {
        if summary.apply {
            out.push_str("Every discovered ledger file was recognized, imported and verified.\n");
        } else {
            out.push_str(
                "Every discovered ledger file was recognized. Dry run: no project was created and no source was moved or deleted; summary.md lists the project UUIDs, section statuses and quarantine destinations that apply would use.\n",
            );
        }
    }
    out
}

fn schema_name(schema: SourceSchema) -> &'static str {
    match schema {
        SourceSchema::Canonical => "canonical",
        SourceSchema::CreateTask => "create-task",
    }
}

fn relative_text(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .components()
        .map(|component| component.as_os_str().to_string_lossy().to_string())
        .collect::<Vec<_>>()
        .join("/")
}

fn display_relative(root: &Path, path: &Path) -> String {
    let text = relative_text(root, path);
    if text.is_empty() {
        ".".to_string()
    } else {
        text
    }
}

fn native_relative(root: &Path, path: &Path) -> PathBuf {
    path.strip_prefix(root).unwrap_or(path).to_path_buf()
}

fn compile_glob(pattern: &str) -> Result<Regex, AppError> {
    let mut expression = String::from("^");
    let mut chars = pattern.chars().peekable();
    while let Some(character) = chars.next() {
        match character {
            '*' => {
                if chars.peek() == Some(&'*') {
                    chars.next();
                    if chars.peek() == Some(&'/') {
                        chars.next();
                        expression.push_str("(?:.*/)?");
                    } else {
                        expression.push_str(".*");
                    }
                } else {
                    expression.push_str("[^/]*");
                }
            }
            '?' => expression.push_str("[^/]"),
            other => expression.push_str(&regex::escape(&other.to_string())),
        }
    }
    expression.push('$');
    Regex::new(&expression)
        .map_err(|error| AppError::Usage(format!("invalid --exclude glob '{pattern}': {error}")))
}

fn scan_tree(scan_root: &Path, excludes: &[(String, Regex)]) -> Result<ScanResult, AppError> {
    let mut result = ScanResult::default();
    let mut visited = HashSet::new();
    visited.insert(scan_root.to_path_buf());
    scan_directory(scan_root, scan_root, excludes, &mut result, &mut visited)?;
    Ok(result)
}

fn scan_directory(
    scan_root: &Path,
    dir: &Path,
    excludes: &[(String, Regex)],
    result: &mut ScanResult,
    visited: &mut HashSet<PathBuf>,
) -> Result<(), AppError> {
    let mut entries = fs::read_dir(dir)
        .map_err(|error| AppError::io_path("read the scan directory", dir, error))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| AppError::io_path("read the scan directory", dir, error))?;
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let name = entry.file_name().to_string_lossy().to_string();
        let path = entry.path();
        let relative = relative_text(scan_root, &path);
        let file_type = entry
            .file_type()
            .map_err(|error| AppError::io_path("inspect", &path, error))?;
        if file_type.is_symlink() {
            result.excluded.push(ExcludedPathRecord {
                path: path.display().to_string(),
                relative_path: relative,
                kind: "link".to_string(),
                reason: "symlink or reparse point is not followed".to_string(),
            });
            continue;
        }
        if file_type.is_dir() {
            if let Some(pruned) = PRUNE_NAMES
                .iter()
                .find(|candidate| name.eq_ignore_ascii_case(candidate))
            {
                *result.pruned.entry((*pruned).to_string()).or_default() += 1;
                continue;
            }
            if let Some((pattern, _)) = excludes.iter().find(|(_, regex)| regex.is_match(&relative))
            {
                result.excluded.push(ExcludedPathRecord {
                    path: path.display().to_string(),
                    relative_path: relative,
                    kind: "directory".to_string(),
                    reason: format!("matched --exclude '{pattern}'"),
                });
                continue;
            }
            match path.canonicalize() {
                Ok(canonical) => {
                    if !visited.insert(canonical) {
                        continue;
                    }
                }
                Err(error) => {
                    return Err(AppError::io_path("resolve", &path, error));
                }
            }
            scan_directory(scan_root, &path, excludes, result, visited)?;
            continue;
        }
        if file_type.is_file() && is_ledger_name(&name) {
            if let Some((pattern, _)) = excludes.iter().find(|(_, regex)| regex.is_match(&relative))
            {
                result.excluded.push(ExcludedPathRecord {
                    path: path.display().to_string(),
                    relative_path: relative,
                    kind: "file".to_string(),
                    reason: format!("matched --exclude '{pattern}'"),
                });
                result
                    .excluded_ledger_dirs
                    .entry(dir.to_path_buf())
                    .or_default()
                    .push(name);
                continue;
            }
            result
                .ledger_dirs
                .entry(dir.to_path_buf())
                .or_default()
                .push(LedgerSource { name, path });
        }
    }
    Ok(())
}

fn is_ledger_name(name: &str) -> bool {
    LEDGER_NAMES
        .iter()
        .any(|ledger| name.eq_ignore_ascii_case(ledger))
}

fn ledger_order(name: &str) -> usize {
    LEDGER_NAMES
        .iter()
        .position(|ledger| name.eq_ignore_ascii_case(ledger))
        .unwrap_or(LEDGER_NAMES.len())
}

fn same_path(left: &Path, right: &Path) -> bool {
    if cfg!(windows) {
        left.to_string_lossy()
            .eq_ignore_ascii_case(&right.to_string_lossy())
    } else {
        left == right
    }
}

fn existing_binding(data_root: &Path, canonical_dir: &Path) -> Result<Option<String>, AppError> {
    let registry = registry::list_bindings(data_root)?;
    Ok(registry
        .bindings
        .iter()
        .find(|binding| same_path(Path::new(&binding.root), canonical_dir))
        .map(|binding| binding.project_id.clone()))
}

fn derived_project_id(canonical_dir: &Path) -> Uuid {
    let mut hasher = Sha256::new();
    hasher.update(b"tasks-cli/bulk-import/project/v1\n");
    hasher.update(canonical_dir.to_string_lossy().as_bytes());
    let digest = hasher.finalize();
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

fn absolute_path(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    }
}

fn export_slug(relative_directory: &str) -> String {
    let mut slug = String::new();
    let mut last_dash = false;
    for character in relative_directory.chars() {
        if character.is_ascii_alphanumeric() {
            slug.push(character.to_ascii_lowercase());
            last_dash = false;
        } else if !last_dash && !slug.is_empty() {
            slug.push('-');
            last_dash = true;
        }
    }
    let slug = slug.trim_matches('-').to_string();
    if slug.is_empty() {
        "root".to_string()
    } else {
        slug
    }
}

fn process_candidate(
    index: usize,
    dir: &Path,
    input: &CandidateInput,
    scan_root: &Path,
    options: &BulkOptions,
    map: &SectionMap,
    project_id: &str,
) -> Result<CandidateOutcome, AppError> {
    let mut outcome = CandidateOutcome {
        bucket: BUCKET_RECOGNIZED.to_string(),
        reason: None,
        reasons: Vec::new(),
        problems: Vec::new(),
        counts: ProblemCounts::default(),
        warnings: Vec::new(),
        files: Vec::new(),
        task_count: 0,
        parsed: Vec::new(),
        applied: false,
        already_imported: false,
        verified: false,
        verification_error: None,
        apply_error: None,
        quarantine: Vec::new(),
        quarantined: false,
        manifest: Vec::new(),
        export_path: None,
        deleted: 0,
    };
    let ledger_files = match input {
        CandidateInput::ExcludedOnly(names) => {
            outcome.bucket = BUCKET_EXCLUDED.to_string();
            let relative_dir = display_relative(scan_root, dir);
            let files = names
                .iter()
                .map(|name| format!("{relative_dir}/{name}"))
                .collect::<Vec<_>>()
                .join(", ");
            outcome.reason = Some(format!(
                "every ledger file in this directory matched --exclude: {}",
                files
            ));
            outcome.reasons = vec![outcome
                .reason
                .clone()
                .unwrap_or_else(|| "excluded".to_string())];
            return Ok(outcome);
        }
        CandidateInput::Ledgers(files) => {
            let mut files = files.clone();
            files.sort_by_key(|source| ledger_order(&source.name));
            files
        }
    };

    let mut blockers: Vec<String> = Vec::new();
    let mut scanned: Vec<ScannedLedger> = Vec::with_capacity(ledger_files.len());
    for source in &ledger_files {
        let bytes = fs::read(&source.path)
            .map_err(|error| AppError::io_path("read the ledger", &source.path, error))?;
        let sha256 = markdown::sha256(&bytes);
        let relative = relative_text(scan_root, &source.path);
        let parsed =
            markdown::parse_with_map(relative.clone(), bytes.clone(), map, options.source_schema);
        scanned.push(ScannedLedger {
            source: source.clone(),
            bytes,
            sha256,
            relative,
            parsed,
        });
    }
    // A candidate imports all of its files into one project, so a create-task
    // `Deps:` reference is resolved against every task ID of the candidate.
    let known = resolved_task_ids(scanned.iter().filter_map(|item| item.parsed.as_ref().ok()));
    for item in scanned.iter_mut() {
        if let Ok(parsed) = item.parsed.as_mut() {
            markdown::resolve_create_task_deps(parsed, &known);
        }
    }
    let mut parsed_set: Vec<(String, ParsedImport)> = Vec::new();
    for item in &scanned {
        match &item.parsed {
            Ok(parsed) => {
                let preview = Store::import_report(parsed);
                if parsed.has_bom {
                    outcome.warnings.push(format!(
                        "{}: starts with a UTF-8 BOM; bytes and SHA-256 are preserved",
                        item.relative
                    ));
                }
                outcome.warnings.extend(parsed.warnings());
                outcome.task_count += parsed.tasks.len();
                outcome.files.push(BulkFileRecord {
                    path: item.source.path.display().to_string(),
                    relative_path: item.relative.clone(),
                    bytes: item.bytes.len(),
                    sha256: item.sha256.clone(),
                    has_bom: parsed.has_bom,
                    schema_class: parsed.schema_class.as_str().to_string(),
                    has_schema_marker: parsed.has_schema_marker,
                    error: None,
                    preview: Some(preview),
                });
            }
            Err(error) => {
                blockers.push(format!("{}: {error}", item.relative));
                outcome
                    .problems
                    .push(ImportProblem::other(format!("{}: {error}", item.relative)));
                outcome.files.push(BulkFileRecord {
                    path: item.source.path.display().to_string(),
                    relative_path: item.relative.clone(),
                    bytes: item.bytes.len(),
                    sha256: item.sha256.clone(),
                    has_bom: item.bytes.starts_with(&[0xef, 0xbb, 0xbf]),
                    schema_class: "unsupported".to_string(),
                    has_schema_marker: false,
                    error: Some(error.to_string()),
                    preview: None,
                });
            }
        }
    }
    parsed_set.extend(
        scanned
            .into_iter()
            .filter_map(|item| item.parsed.ok().map(|parsed| (item.relative, parsed))),
    );
    let refs: Vec<&ParsedImport> = parsed_set.iter().map(|(_, parsed)| parsed).collect();
    outcome.problems.extend(problems::analyze(&refs));
    outcome.counts = ProblemCounts::of(&outcome.problems);
    blockers.extend(
        outcome
            .problems
            .iter()
            .map(|problem| problem.message.clone()),
    );
    if !blockers.is_empty() {
        outcome.bucket = BUCKET_UNRECOGNIZED.to_string();
        outcome.reasons = blockers.clone();
        outcome.reason = Some(blockers.join("; "));
    } else if !outcome.warnings.is_empty() {
        outcome.bucket = BUCKET_RECOGNIZED_WITH_WARNINGS.to_string();
    }
    if outcome.bucket == BUCKET_UNRECOGNIZED {
        return Ok(outcome);
    }

    if let Some(quarantine_dir) = options.quarantine_dir.as_ref() {
        let base = absolute_path(quarantine_dir);
        outcome.quarantine = ledger_files
            .iter()
            .zip(outcome.files.iter())
            .map(|(source, record)| QuarantineRecord {
                source: source.path.display().to_string(),
                destination: base
                    .join(native_relative(scan_root, &source.path))
                    .display()
                    .to_string(),
                size: record.bytes as u64,
                sha256: record.sha256.clone(),
                status: "planned".to_string(),
            })
            .collect();
    }

    if !options.apply {
        outcome.parsed = parsed_set;
        return Ok(outcome);
    }

    match apply_and_verify(
        index,
        dir,
        &ledger_files,
        &parsed_set,
        &outcome.files,
        &display_relative(scan_root, dir),
        map,
        options,
        project_id,
    ) {
        Ok(result) => {
            outcome.applied = true;
            outcome.already_imported = result.already_imported;
            outcome.verified = result.verified;
            outcome.verification_error = result.verification_error;
            outcome.export_path = Some(result.export_path);
        }
        Err(error) => {
            outcome.apply_error = Some(error.to_string());
        }
    }

    if outcome.verified {
        if let Some(quarantine_dir) = options.quarantine_dir.as_ref() {
            let base = absolute_path(quarantine_dir);
            let mut records = Vec::new();
            let mut failure: Option<String> = None;
            for (source, record) in ledger_files.iter().zip(outcome.files.iter()) {
                let destination = base.join(native_relative(scan_root, &source.path));
                if failure.is_some() {
                    records.push(QuarantineRecord {
                        source: source.path.display().to_string(),
                        destination: destination.display().to_string(),
                        size: record.bytes as u64,
                        sha256: record.sha256.clone(),
                        status: "planned".to_string(),
                    });
                    continue;
                }
                match move_file(&source.path, &destination) {
                    Ok(()) => {
                        let mut status = "moved".to_string();
                        if options.delete_quarantined {
                            fs::remove_file(&destination).map_err(|error| {
                                AppError::io_path(
                                    "delete the quarantined copy",
                                    &destination,
                                    error,
                                )
                            })?;
                            status = "deleted".to_string();
                            outcome.deleted += 1;
                        }
                        outcome.manifest.push(ManifestEntry {
                            project_id: project_id.to_string(),
                            original_path: source.path.display().to_string(),
                            size: record.bytes as u64,
                            sha256: record.sha256.clone(),
                            destination: destination.display().to_string(),
                            deleted: status == "deleted",
                        });
                        records.push(QuarantineRecord {
                            source: source.path.display().to_string(),
                            destination: destination.display().to_string(),
                            size: record.bytes as u64,
                            sha256: record.sha256.clone(),
                            status,
                        });
                    }
                    Err(error) => {
                        failure = Some(format!(
                            "quarantine failed for {}: {error}",
                            source.path.display()
                        ));
                        records.push(QuarantineRecord {
                            source: source.path.display().to_string(),
                            destination: destination.display().to_string(),
                            size: record.bytes as u64,
                            sha256: record.sha256.clone(),
                            status: "planned".to_string(),
                        });
                    }
                }
            }
            outcome.quarantine = records;
            outcome.quarantined = outcome
                .quarantine
                .iter()
                .any(|record| record.status == "moved" || record.status == "deleted");
            if let Some(message) = failure {
                outcome.apply_error = Some(message);
            }
        }
    }
    outcome.parsed = parsed_set;
    Ok(outcome)
}

struct ApplyOutcome {
    already_imported: bool,
    verified: bool,
    verification_error: Option<String>,
    export_path: String,
}

#[allow(clippy::too_many_arguments)]
fn apply_and_verify(
    index: usize,
    dir: &Path,
    ledger_files: &[LedgerSource],
    preview: &[(String, ParsedImport)],
    files: &[BulkFileRecord],
    relative_directory: &str,
    map: &SectionMap,
    options: &BulkOptions,
    project_id: &str,
) -> Result<ApplyOutcome, AppError> {
    let mut reparsed = Vec::with_capacity(ledger_files.len());
    let mut hashes = Vec::with_capacity(ledger_files.len());
    for (position, source) in ledger_files.iter().enumerate() {
        let bytes = fs::read(&source.path).map_err(|error| {
            AppError::io_path("re-read the ledger before apply", &source.path, error)
        })?;
        let parsed = markdown::parse_with_map(
            preview[position].0.clone(),
            bytes,
            map,
            options.source_schema,
        )?;
        let expected = &files[position].sha256;
        if !parsed.source_hash.eq_ignore_ascii_case(expected) {
            return Err(AppError::ShaMismatch {
                file: source.path.display().to_string(),
                expected: expected.clone(),
                actual: parsed.source_hash,
            });
        }
        hashes.push(parsed.source_hash.clone());
        reparsed.push(parsed);
    }
    let known = resolved_task_ids(reparsed.iter());
    for parsed in reparsed.iter_mut() {
        markdown::resolve_create_task_deps(parsed, &known);
    }
    let explicit_project = Uuid::parse_str(project_id)
        .map_err(|error| {
            AppError::Usage(format!(
                "bulk-import produced project id '{project_id}', which is not a UUID ({error}); re-run the scan"
            ))
        })?;
    registry::init_root(&options.data_root, dir, Some(explicit_project))?;
    let mut store = Store::open_rw(&options.data_root, project_id)?;
    let (_, already_imported) = store.import_apply_many(reparsed, &hashes)?;

    let export_dir = options.report_dir.join(EXPORT_DIR);
    fs::create_dir_all(&export_dir).map_err(|error| {
        AppError::io_path(
            "create the verification export directory",
            &export_dir,
            error,
        )
    })?;
    let export_path = export_dir.join(format!(
        "{:03}-{}.md",
        index + 1,
        export_slug(relative_directory)
    ));
    if export_path.exists() {
        fs::remove_file(&export_path).map_err(|error| {
            AppError::io_path("remove the previous export", &export_path, error)
        })?;
    }
    let exported_count = store.export_markdown(&export_path)?;
    let exported_bytes = fs::read(&export_path)
        .map_err(|error| AppError::io_path("read the verification export", &export_path, error))?;
    let exported = markdown::parse(export_path.display().to_string(), exported_bytes, None)?;
    let verification = verify_project(&mut store, preview, &exported, exported_count);
    #[cfg(feature = "test-hooks")]
    let verification = maybe_force_verification_failure(verification);
    Ok(ApplyOutcome {
        already_imported,
        verified: verification.is_ok(),
        verification_error: verification.err(),
        export_path: export_path.display().to_string(),
    })
}

fn verify_project(
    store: &mut Store,
    preview: &[(String, ParsedImport)],
    exported: &ParsedImport,
    exported_count: usize,
) -> Result<(), String> {
    let mut mismatches: Vec<String> = Vec::new();
    let mut exported_by_id: HashMap<u64, &markdown::ParsedTask> =
        exported.tasks.iter().map(|task| (task.id, task)).collect();
    let mut preview_count = 0usize;
    for (name, parsed) in preview {
        for task in &parsed.tasks {
            preview_count += 1;
            let id = format!("T-{:03}", task.id);
            match exported_by_id.remove(&task.id) {
                None => mismatches.push(format!("{name}: {id} is missing from the re-export")),
                Some(other) => {
                    if other.title != task.title {
                        mismatches.push(format!("{name}: {id} title differs from the re-export"));
                    }
                    if other.body != task.body {
                        mismatches.push(format!(
                            "{name}: {id} body differs from the re-export ({} vs {} bytes)",
                            task.body.len(),
                            other.body.len()
                        ));
                    }
                    if other.status != task.status {
                        mismatches.push(format!(
                            "{name}: {id} status differs from the re-export ({} vs {})",
                            task.status, other.status
                        ));
                    }
                    if sorted_deps(&other.deps) != sorted_deps(&task.deps) {
                        mismatches.push(format!(
                            "{name}: {id} dependencies differ from the re-export"
                        ));
                    }
                }
            }
            match store.show_task(&id) {
                Ok(detail) => {
                    if detail.title != task.title {
                        mismatches.push(format!("{name}: {id} title differs in the store"));
                    }
                    if detail.body != task.body {
                        mismatches.push(format!(
                            "{name}: {id} body differs in the store ({} vs {} bytes)",
                            task.body.len(),
                            detail.body.len()
                        ));
                    }
                    if detail.status != task.status {
                        mismatches.push(format!(
                            "{name}: {id} status differs in the store ({} vs {})",
                            task.status, detail.status
                        ));
                    }
                    if sorted_deps(&detail.deps) != sorted_deps(&task.deps) {
                        mismatches.push(format!("{name}: {id} dependencies differ in the store"));
                    }
                }
                Err(error) => mismatches.push(format!("{name}: {id} cannot be read back: {error}")),
            }
        }
    }
    if preview_count != exported_count {
        mismatches.push(format!(
            "task count differs: preview {preview_count}, re-export {exported_count}"
        ));
    }
    for id in exported_by_id.keys() {
        mismatches.push(format!(
            "T-{id:03} is in the re-export but not in the preview"
        ));
    }
    if mismatches.is_empty() {
        Ok(())
    } else {
        let total = mismatches.len();
        mismatches.truncate(MAX_REPORTED_MISMATCHES);
        if total > MAX_REPORTED_MISMATCHES {
            mismatches.push(format!(
                "... and {} more differences",
                total - MAX_REPORTED_MISMATCHES
            ));
        }
        Err(mismatches.join("; "))
    }
}

fn sorted_deps(deps: &[u64]) -> Vec<u64> {
    let mut sorted = deps.to_vec();
    sorted.sort_unstable();
    sorted.dedup();
    sorted
}

fn move_file(source: &Path, destination: &Path) -> Result<(), AppError> {
    if destination.exists() {
        return Err(AppError::Validation(format!(
            "quarantine: refusing to overwrite {}: it already exists; choose a different --quarantine-dir or remove the existing file",
            destination.display()
        )));
    }
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| AppError::io_path("create the quarantine directory", parent, error))?;
    }
    if fs::rename(source, destination).is_ok() {
        return Ok(());
    }
    fs::copy(source, destination).map_err(|error| {
        AppError::io_path("copy the source into quarantine", destination, error)
    })?;
    let source_hash = markdown::sha256(&fs::read(source).map_err(|error| {
        AppError::io_path("re-read the source before quarantine", source, error)
    })?);
    let destination_hash = markdown::sha256(
        &fs::read(destination)
            .map_err(|error| AppError::io_path("read the quarantined copy", destination, error))?,
    );
    if source_hash != destination_hash {
        return Err(AppError::Validation(format!(
            "quarantine copy {} does not match the source {} byte for byte; the source was left in place, copy it manually and investigate the filesystem",
            destination.display(),
            source.display()
        )));
    }
    fs::remove_file(source)
        .map_err(|error| AppError::io_path("remove the source after quarantine", source, error))?;
    Ok(())
}

fn find_ledger_references(root: &Path) -> Result<Vec<LedgerReferenceRecord>, AppError> {
    let mut records = Vec::new();
    let mut visited = HashSet::new();
    visited.insert(root.to_path_buf());
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let mut entries = fs::read_dir(&dir)
            .map_err(|error| AppError::io_path("read the directory", &dir, error))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| AppError::io_path("read the directory", &dir, error))?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let name = entry.file_name().to_string_lossy().to_string();
            let path = entry.path();
            let file_type = entry.file_type()?;
            if file_type.is_symlink() {
                continue;
            }
            if file_type.is_dir() {
                if PRUNE_NAMES
                    .iter()
                    .any(|candidate| name.eq_ignore_ascii_case(candidate))
                {
                    continue;
                }
                if let Ok(canonical) = path.canonicalize() {
                    if !visited.insert(canonical) {
                        continue;
                    }
                }
                stack.push(path);
                continue;
            }
            if !file_type.is_file()
                || !REFERENCE_NAMES
                    .iter()
                    .any(|candidate| name.eq_ignore_ascii_case(candidate))
            {
                continue;
            }
            let bytes = fs::read(&path)
                .map_err(|error| AppError::io_path("read the reference file", &path, error))?;
            let Ok(text) = String::from_utf8(bytes) else {
                continue;
            };
            let lines = text
                .lines()
                .enumerate()
                .filter(|(_, line)| line.contains(REFERENCE_NEEDLE))
                .map(|(index, _)| index + 1)
                .collect::<Vec<_>>();
            if !lines.is_empty() {
                records.push(LedgerReferenceRecord {
                    path: path.display().to_string(),
                    relative_path: relative_text(root, &path),
                    lines,
                });
            }
        }
    }
    records.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    Ok(records)
}

#[cfg(feature = "test-hooks")]
fn maybe_force_verification_failure(result: Result<(), String>) -> Result<(), String> {
    match result {
        Ok(()) if std::env::var_os("TASKS_TEST_BULK_FAIL_VERIFY").is_some() => {
            Err("test hook: forced verification failure".to_string())
        }
        other => other,
    }
}
