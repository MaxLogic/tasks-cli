// Frozen copy of `eligible` and `enrich_using` from tasks-cli commit
// 026a3fe39845d338f036c3ef97bc34c8d72c92c9 (src/enrich.rs). Never edit it.
// Only `crate::` paths were rewritten to `tasks_cli::`; the types come from the
// crate's public API. It is the oracle of the base differential test.
use regex::Regex;
use std::collections::{BTreeMap, BTreeSet};
use tasks_cli::enrich::{EnrichedText, TitleRequests, TitleResolution, MAX_INPUT_BYTES};
use tasks_cli::error::AppError;
const MAX_DISTINCT_IDS: usize = 10_000;
type Slot = Option<String>;

fn eligible(text: &str, start: usize, end: usize) -> bool {
    // Avoid path components, URL fragments and query values. This is plain-text
    // enrichment, not a Markdown parser; link labels remain eligible.
    !text[..start].ends_with(['/', '\\', '#', '=']) && !text[end..].starts_with(['/', '\\'])
}

/// Shared lexical/rendering rules with a bounded concrete title lookup seam.
pub fn enrich_using(
    text: &str,
    own_key: Option<&str>,
    resolve: impl FnOnce(&TitleRequests) -> Result<TitleResolution, AppError>,
) -> Result<EnrichedText, AppError> {
    if text.len() > MAX_INPUT_BYTES {
        return Err(AppError::Validation(
            "enrichment input exceeds 16 MiB; split the document".into(),
        ));
    }
    // The KEY-N branch comes first so a key such as `TA` is never read as a
    // legacy `T` reference; keys never have the `T<digits>` form.
    let pattern = Regex::new(r"\b(?:([A-Z][A-Z0-9]{1,5})-([0-9]+)|T-?([0-9]+))\b")
        .map_err(|e| AppError::Validation(format!("invalid task-reference pattern: {e}")))?;
    let mut candidates: Vec<(usize, usize, Slot, u64)> = Vec::new();
    for capture in pattern.captures_iter(text) {
        let Some(found) = capture.get(0) else {
            continue;
        };
        let (slot, number) = match (capture.get(1), capture.get(2), capture.get(3)) {
            (None, None, Some(number)) => (None, number),
            (Some(key), Some(number), _) => {
                let key = key.as_str();
                // Reserved standard-name prefixes (UTF-8, SHA-256, ISO-8601,
                // ...) are never task-ID keys; a project set up through this
                // CLI can never own one (see `parse_project_key`), so this
                // cannot shadow a real key. A pre-existing store whose key
                // column was written outside the CLI's validation (the
                // schema CHECK does not forbid it) is not covered.
                if tasks_cli::model::RESERVED_KEYS.contains(&key) {
                    continue;
                }
                if Some(key) == own_key {
                    (None, number)
                } else {
                    (Some(key.to_string()), number)
                }
            }
            _ => continue,
        };
        let Ok(id) = number.as_str().parse::<u64>() else {
            continue;
        };
        if id > 0 && id <= i64::MAX as u64 {
            candidates.push((found.start(), found.end(), slot, id));
        }
    }
    // Treat adjacent references separated by slashes as one unit when
    // deciding whether the text is a path. A chain in a URL remains excluded,
    // while "T-226/T-227" in prose is eligible in its entirety.
    let mut ids = BTreeSet::new();
    let mut occurrences: Vec<(usize, usize, Slot, u64)> = Vec::new();
    let mut first = 0;
    while first < candidates.len() {
        let mut last = first;
        while last + 1 < candidates.len()
            && &text[candidates[last].1..candidates[last + 1].0] == "/"
        {
            last += 1;
        }
        if eligible(text, candidates[first].0, candidates[last].1) {
            for candidate in &candidates[first..=last] {
                occurrences.push(candidate.clone());
                ids.insert((candidate.2.clone(), candidate.3));
            }
            if ids.len() > MAX_DISTINCT_IDS {
                return Err(AppError::Validation(
                    "enrichment input contains more than 10000 distinct task IDs; split the document"
                        .into(),
                ));
            }
        }
        first = last + 1;
    }
    if ids.is_empty() {
        return Ok(EnrichedText {
            text: text.into(),
            replacements: 0,
            unknown_ids: vec![],
            unknown_refs: vec![],
        });
    }
    let mut by_slot = BTreeMap::<Slot, Vec<u64>>::new();
    for (slot, id) in ids {
        by_slot.entry(slot).or_default().push(id);
    }
    let TitleResolution { titles, known_keys } = resolve(&by_slot)?;
    let reportable = |slot: &Slot| match slot {
        None => true,
        Some(key) => known_keys.contains(key),
    };
    // Resolve annotation protection after reading titles.  The first pass
    // cannot know whether `(Title)` is an exact annotation until the title
    // lookup completes.  IDs inside such an annotation are excluded from
    // diagnostics as well as from replacements; an occurrence of the same
    // unknown ID elsewhere remains reportable.
    let mut unknown = BTreeSet::<(Slot, u64)>::new();
    let mut protected_until = 0;
    for (start, end, slot, id) in &occurrences {
        if *start < protected_until {
            continue;
        }
        let lookup = (slot.clone(), *id);
        if let Some(title) = titles.get(&lookup) {
            let annotation = format!(" ({title})");
            if text[*end..].starts_with(&annotation) {
                protected_until = *end + annotation.len();
                continue;
            }
        }
        if !titles.contains_key(&lookup) && reportable(slot) {
            unknown.insert(lookup);
        }
    }
    let mut output = String::with_capacity(text.len());
    let mut copied = 0;
    let mut protected_until = 0;
    let mut replacements = 0;
    let mut output_bytes = text.len();
    for (start, end, slot, id) in occurrences {
        if start < protected_until {
            continue;
        }
        let Some(title) = titles.get(&(slot, id)) else {
            continue;
        };
        let annotation = format!(" ({title})");
        if text[end..].starts_with(&annotation) {
            protected_until = end + annotation.len();
            continue;
        }
        output_bytes += annotation.len();
        if output_bytes > 64 * 1024 * 1024 {
            return Err(AppError::Validation(
                "enriched output exceeds 64 MiB; split the document".into(),
            ));
        }
        output.push_str(&text[copied..end]);
        output.push_str(&annotation);
        copied = end;
        replacements += 1;
    }
    output.push_str(&text[copied..]);
    let unknown_refs = unknown
        .iter()
        .map(|(slot, id)| {
            let key = slot.as_deref().or(own_key).unwrap_or("T");
            format!("{key}-{id}")
        })
        .collect();
    Ok(EnrichedText {
        text: output,
        replacements,
        unknown_ids: unknown
            .iter()
            .filter(|(slot, _)| slot.is_none())
            .map(|(_, id)| *id)
            .collect(),
        unknown_refs,
    })
}
