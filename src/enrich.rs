use crate::error::AppError;
use regex::Regex;
use rusqlite::{params_from_iter, Connection};
use std::collections::{BTreeSet, HashMap};

#[derive(Debug, serde::Serialize)]
pub struct EnrichedText {
    pub text: String,
    pub replacements: usize,
    pub unknown_ids: Vec<u64>,
}
pub const MAX_INPUT_BYTES: usize = 16 * 1024 * 1024;
const MAX_DISTINCT_IDS: usize = 10_000;

fn eligible(text: &str, start: usize, end: usize) -> bool {
    // Avoid path components, URL fragments and query values. This is plain-text
    // enrichment, not a Markdown parser; link labels remain eligible.
    !text[..start].ends_with(['/', '\\', '#', '=']) && !text[end..].starts_with(['/', '\\'])
}

pub fn enrich(conn: &Connection, text: &str) -> Result<EnrichedText, AppError> {
    if text.len() > MAX_INPUT_BYTES {
        return Err(AppError::Validation(
            "enrichment input exceeds 16 MiB; split the document".into(),
        ));
    }
    let pattern = Regex::new(r"\bT-?([0-9]+)\b")
        .map_err(|e| AppError::Validation(format!("invalid task-reference pattern: {e}")))?;
    let mut ids = BTreeSet::new();
    for capture in pattern.captures_iter(text) {
        let Some(found) = capture.get(0) else {
            continue;
        };
        let Some(number) = capture.get(1) else {
            continue;
        };
        if !eligible(text, found.start(), found.end()) {
            continue;
        }
        if let Ok(id) = number.as_str().parse::<u64>() {
            if id > 0 && id <= i64::MAX as u64 {
                ids.insert(id);
            }
        }
        if ids.len() > MAX_DISTINCT_IDS {
            return Err(AppError::Validation(
                "enrichment input contains more than 10000 distinct task IDs; split the document"
                    .into(),
            ));
        }
    }
    if ids.is_empty() {
        return Ok(EnrichedText {
            text: text.into(),
            replacements: 0,
            unknown_ids: vec![],
        });
    }
    let ids: Vec<_> = ids.into_iter().collect();
    let mut titles = HashMap::<u64, String>::new();
    let snapshot = conn.unchecked_transaction()?;
    for batch in ids.chunks(500) {
        let slots = std::iter::repeat_n("?", batch.len())
            .collect::<Vec<_>>()
            .join(",");
        let mut stmt =
            conn.prepare(&format!("SELECT id,title FROM tasks WHERE id IN ({slots})"))?;
        let rows = stmt.query_map(params_from_iter(batch.iter()), |r| {
            Ok((r.get::<_, u64>(0)?, r.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (id, title) = row?;
            titles.insert(id, title);
        }
    }
    snapshot.commit()?;
    let unknown_ids = ids
        .into_iter()
        .filter(|id| !titles.contains_key(id))
        .collect();
    let mut output = String::with_capacity(text.len());
    let mut copied = 0;
    let mut protected_until = 0;
    let mut replacements = 0;
    let mut output_bytes = text.len();
    for capture in pattern.captures_iter(text) {
        let Some(found) = capture.get(0) else {
            continue;
        };
        let Some(number) = capture.get(1) else {
            continue;
        };
        if found.start() < protected_until || !eligible(text, found.start(), found.end()) {
            continue;
        }
        let Ok(id) = number.as_str().parse::<u64>() else {
            continue;
        };
        let Some(title) = titles.get(&id) else {
            continue;
        };
        let annotation = format!(" ({title})");
        if text[found.end()..].starts_with(&annotation) {
            protected_until = found.end() + annotation.len();
            continue;
        }
        output_bytes += annotation.len();
        if output_bytes > 64 * 1024 * 1024 {
            return Err(AppError::Validation(
                "enriched output exceeds 64 MiB; split the document".into(),
            ));
        }
        output.push_str(&text[copied..found.end()]);
        output.push_str(&annotation);
        copied = found.end();
        replacements += 1;
    }
    output.push_str(&text[copied..]);
    Ok(EnrichedText {
        text: output,
        replacements,
        unknown_ids,
    })
}
