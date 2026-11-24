use crate::error::AppError;
use regex::Regex;
use rusqlite::{params_from_iter, Connection};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::Path;

#[derive(Debug, serde::Serialize)]
pub struct EnrichedText {
    pub text: String,
    pub replacements: usize,
    /// Unknown IDs of the current project (`T-N`, or `KEY-N` with its key).
    pub unknown_ids: Vec<u64>,
    /// Every unknown reference, including `KEY-N` of another known project.
    pub unknown_refs: Vec<String>,
}

/// Where references resolve: `T-N` and `own_key` references in the current
/// project's connection; other `KEY-N` in that key's project under
/// `data_root`, read-only. References with a key no project has stay
/// unchanged and unreported (they are often words such as UTF-8).
#[derive(Debug, Clone, Copy, Default)]
pub struct EnrichContext<'a> {
    pub own_key: Option<&'a str>,
    pub own_project: Option<&'a uuid::Uuid>,
    pub data_root: Option<&'a Path>,
}
pub const MAX_INPUT_BYTES: usize = 16 * 1024 * 1024;
const MAX_DISTINCT_IDS: usize = 10_000;

fn eligible(text: &str, start: usize, end: usize) -> bool {
    // Avoid path components, URL fragments and query values. This is plain-text
    // enrichment, not a Markdown parser; link labels remain eligible.
    !text[..start].ends_with(['/', '\\', '#', '=']) && !text[end..].starts_with(['/', '\\'])
}

/// Enriches `T-N`/`TN` references against the current project only.
pub fn enrich(conn: &Connection, text: &str) -> Result<EnrichedText, AppError> {
    enrich_with(conn, text, EnrichContext::default())
}

/// A reference target: the current project (`None`) or another project's key.
type Slot = Option<String>;

pub(crate) fn read_titles(
    conn: &Connection,
    ids: &[u64],
    titles: &mut HashMap<(Slot, u64), String>,
    slot: &Slot,
) -> Result<(), AppError> {
    read_titles_with_budget(conn, ids, titles, slot, None)
}
pub(crate) fn read_titles_with_budget(
    conn: &Connection,
    ids: &[u64],
    titles: &mut HashMap<(Slot, u64), String>,
    slot: &Slot,
    budget: Option<u64>,
) -> Result<(), AppError> {
    let snapshot = conn.unchecked_transaction()?;
    let mut remaining = budget;
    for batch in ids.chunks(500) {
        let slots = std::iter::repeat_n("?", batch.len())
            .collect::<Vec<_>>()
            .join(",");
        if let Some(left) = remaining {
            let bytes: u64=conn.query_row(&format!("SELECT COALESCE(SUM(length(CAST(title AS BLOB))),0) FROM tasks WHERE id IN ({slots})"),params_from_iter(batch.iter()),|row| row.get(0))?;
            if bytes > left {
                return Err(AppError::ResponseLimit(
                    "title lookup exceeds the response budget; request fewer references".into(),
                ));
            }
            remaining = Some(left - bytes);
        }
        let mut stmt =
            conn.prepare(&format!("SELECT id,title FROM tasks WHERE id IN ({slots})"))?;
        let rows = stmt.query_map(params_from_iter(batch.iter()), |r| {
            Ok((r.get::<_, u64>(0)?, r.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (id, title) = row?;
            titles.insert((slot.clone(), id), title);
        }
    }
    snapshot.commit()?;
    Ok(())
}

#[derive(Default)]
pub struct TitleResolution {
    pub titles: HashMap<(Option<String>, u64), String>,
    pub known_keys: BTreeSet<String>,
}
pub type TitleRequests = BTreeMap<Option<String>, Vec<u64>>;

pub fn enrich_with(
    conn: &Connection,
    text: &str,
    context: EnrichContext<'_>,
) -> Result<EnrichedText, AppError> {
    enrich_using(text, context.own_key, |by_slot| {
        let mut titles = HashMap::<(Slot, u64), String>::new();
        // Keys whose project was found; references to any other key are left alone.
        let mut known_keys = BTreeSet::<String>::new();
        if let Some(local) = by_slot.get(&None) {
            read_titles(conn, local, &mut titles, &None)?;
        }
        let has_foreign = by_slot.keys().any(Option::is_some);
        if has_foreign {
            if let Some(data_root) = context.data_root {
                // One read-only pass over the data root, only when the text names
                // another project's key; unreadable projects are skipped.
                let projects = crate::keys::scan_cached(data_root)?;
                for (slot, slot_ids) in by_slot.iter().filter(|(slot, _)| slot.is_some()) {
                    let Some(project) = projects.iter().find(|project| {
                        project.key.as_deref() == slot.as_deref()
                            && Some(&project.project_id) != context.own_project
                    }) else {
                        continue;
                    };
                    let Ok(store) = crate::store::Store::open_readonly(
                        data_root,
                        &project.project_id.to_string(),
                    ) else {
                        continue;
                    };
                    read_titles(&store.conn, slot_ids, &mut titles, slot)?;
                    if let Some(key) = slot {
                        known_keys.insert(key.clone());
                    }
                }
            }
        }
        Ok(TitleResolution { titles, known_keys })
    })
}
const MAX_OUTPUT_BYTES: usize = 64 * 1024 * 1024;
/// A range of at most this many IDs expands into a list.
const MAX_EXPANDED_RANGE: u64 = 50;
const LIST_CLOSE: [char; 9] = [',', '.', ';', ':', '!', '?', ')', ']', '}'];

/// A reference token or a list number. `end` is the end of its digit run.
/// Everything borrows the input, so repeated IDs cost no allocation.
#[derive(Clone, Copy)]
struct Reference<'t> {
    start: usize,
    end: usize,
    slot: Option<&'t str>,
    id: u64,
    /// The spelling of the list's key before the digits (`AUTH-`, `T-`, `T`).
    prefix: &'t str,
    /// A list number (`start..end` holds only digits): an enriched list
    /// number is written as a full reference.
    bare: bool,
}

/// One unit of the walk, in start order.
#[derive(Clone, Copy)]
enum Event<'t> {
    Single(Reference<'t>),
    /// `first` and `last` are the two ends of a list range.
    Range {
        first: Reference<'t>,
        last: Reference<'t>,
    },
    /// Never annotated or reported; its exact annotation protects its contents.
    Protect(Reference<'t>),
}

impl Event<'_> {
    fn start(&self) -> usize {
        match self {
            Event::Single(r) | Event::Protect(r) => r.start,
            Event::Range { first, .. } => first.start,
        }
    }
}

/// One parsed list element after the anchor.
#[derive(Clone, Copy)]
struct Element {
    start: usize,
    end: usize,
    id: u64,
    /// Reached through a dash: the end of a range.
    range_end: bool,
    /// Its separator contains horizontal whitespace, or is `and`.
    spaced: bool,
}

fn is_line_break(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

fn is_horizontal(c: char) -> bool {
    c.is_whitespace() && !is_line_break(c)
}

fn is_dash(c: char) -> bool {
    matches!(c, '-' | '\u{2013}' | '\u{2014}')
}

fn horizontal_len(text: &str) -> usize {
    text.len() - text.trim_start_matches(is_horizontal).len()
}

struct Candidate<'t> {
    reference: Reference<'t>,
    /// A project could own this key (always true for the current project).
    requestable: bool,
}

/// Reads one text without building per-occurrence records: candidates and list
/// numbers are found on demand, so memory does not grow with their count.
struct Lexer<'t> {
    text: &'t str,
    own_key: Option<&'t str>,
    pattern: Regex,
    /// `\w` of the first character, for the word boundary after a list number.
    word: Regex,
    key_checks: std::cell::RefCell<HashMap<&'t str, bool>>,
}

impl<'t> Lexer<'t> {
    fn new(text: &'t str, own_key: Option<&'t str>) -> Result<Self, AppError> {
        // The KEY-N branch comes first so a key such as `TA` is never read as a
        // legacy `T` reference; keys never have the `T<digits>` form.
        let pattern = Regex::new(r"\b(?:([A-Z][A-Z0-9]{1,5})-([0-9]+)|T-?([0-9]+))\b")
            .map_err(|e| AppError::Validation(format!("invalid task-reference pattern: {e}")))?;
        let word = Regex::new(r"\A\w")
            .map_err(|e| AppError::Validation(format!("invalid word pattern: {e}")))?;
        Ok(Self {
            text,
            own_key,
            pattern,
            word,
            key_checks: Default::default(),
        })
    }

    /// The first candidate at or after `from`.
    fn candidate(&self, from: usize) -> Option<Candidate<'t>> {
        let mut from = from;
        loop {
            let capture = self.pattern.captures_at(self.text, from)?;
            let found = capture.get(0)?;
            from = found.end();
            let (slot, number, requestable) =
                match (capture.get(1), capture.get(2), capture.get(3)) {
                    (None, None, Some(number)) => (None, number, true),
                    (Some(key), Some(number), _) => {
                        let key = &self.text[key.range()];
                        // Reserved standard-name prefixes (UTF-8, SHA-256,
                        // ISO-8601, ...) are never task-ID keys; a project set
                        // up through this CLI can never own one (see
                        // `parse_project_key`), so this cannot shadow a real
                        // key. A pre-existing store whose key column was
                        // written outside the CLI's validation (the schema
                        // CHECK does not forbid it) is not covered.
                        if crate::model::RESERVED_KEYS.contains(&key) {
                            continue;
                        }
                        if Some(key) == self.own_key {
                            (None, number, true)
                        } else {
                            // `T1-2` has the KEY-N shape with key `T1`, which
                            // no project can own: it is never requested.
                            let requestable =
                                *self.key_checks.borrow_mut().entry(key).or_insert_with(|| {
                                    crate::model::parse_project_key(key).is_ok()
                                });
                            (Some(key), number, requestable)
                        }
                    }
                    _ => continue,
                };
            let Ok(id) = number.as_str().parse::<u64>() else {
                continue;
            };
            if id > 0 && id <= i64::MAX as u64 {
                return Some(Candidate {
                    reference: Reference {
                        start: found.start(),
                        end: found.end(),
                        slot,
                        id,
                        prefix: &self.text[found.start()..number.start()],
                        bare: false,
                    },
                    requestable,
                });
            }
        }
    }

    /// Length of `[0-9]+` at the start of `text` when it ends at a word boundary.
    fn number_len(&self, text: &str) -> Option<usize> {
        let digits = text.bytes().take_while(u8::is_ascii_digit).count();
        if digits == 0 {
            return None;
        }
        let word_follows = match text[digits..].chars().next() {
            None => false,
            Some(c) if c.is_ascii() => c.is_ascii_alphanumeric() || c == '_',
            Some(_) => self.word.is_match(&text[digits..]),
        };
        (!word_follows).then_some(digits)
    }

    /// Separator plus the next number at the start of `rest`, as
    /// `(separator length, digits, dash, spaced)`. Alternatives are told apart
    /// by their first non-space character, so the order does not matter.
    fn separator(&self, rest: &str) -> Option<(usize, usize, bool, bool)> {
        let lead = horizontal_len(rest);
        let after = &rest[lead..];
        if let Some(after_comma) = after.strip_prefix(',') {
            let gap = horizontal_len(after_comma);
            // `, and 5`
            if gap > 0 {
                if let Some(tail) = after_comma[gap..].strip_prefix("and") {
                    let gap_after = horizontal_len(tail);
                    if gap_after > 0 {
                        if let Some(digits) = self.number_len(&tail[gap_after..]) {
                            return Some((lead + 1 + gap + 3 + gap_after, digits, false, true));
                        }
                    }
                }
            }
            let digits = self.number_len(&after_comma[gap..])?;
            return Some((lead + 1 + gap, digits, false, lead > 0 || gap > 0));
        }
        if lead > 0 {
            if let Some(tail) = after.strip_prefix("and") {
                let gap = horizontal_len(tail);
                if gap > 0 {
                    let digits = self.number_len(&tail[gap..])?;
                    return Some((lead + 3 + gap, digits, false, true));
                }
            }
        }
        let dash = after.chars().next().filter(|c| is_dash(*c))?;
        let after_dash = &after[dash.len_utf8()..];
        let gap = horizontal_len(after_dash);
        let digits = self.number_len(&after_dash[gap..])?;
        Some((
            lead + dash.len_utf8() + gap,
            digits,
            true,
            lead > 0 || gap > 0,
        ))
    }
}

/// The elements of the list that follows an anchor, in the original text only.
struct Elements<'a, 't> {
    lexer: &'a Lexer<'t>,
    position: usize,
    previous_id: u64,
    previous_range_end: bool,
}

impl<'a, 't> Elements<'a, 't> {
    fn after(lexer: &'a Lexer<'t>, anchor: &Reference<'_>) -> Self {
        Self {
            lexer,
            position: anchor.end,
            previous_id: anchor.id,
            previous_range_end: false,
        }
    }
}

impl Iterator for Elements<'_, '_> {
    type Item = Element;

    fn next(&mut self) -> Option<Element> {
        let text = self.lexer.text;
        let (separator, digits, range_end, spaced) =
            self.lexer.separator(&text[self.position..])?;
        let start = self.position + separator;
        let end = start + digits;
        let id = text[start..end].parse::<u64>().ok()?;
        if id == 0 || id > i64::MAX as u64 {
            return None;
        }
        if range_end && (self.previous_range_end || id <= self.previous_id) {
            return None;
        }
        self.position = end;
        self.previous_id = id;
        self.previous_range_end = range_end;
        Some(Element {
            start,
            end,
            id,
            range_end,
            spaced,
        })
    }
}

/// The final boundary check of a list's last element.
fn list_end_is_valid(lexer: &Lexer<'_>, last: &Element) -> bool {
    let rest = &lexer.text[last.end..];
    let after = rest.trim_start_matches(LIST_CLOSE);
    let closed = after.len() != rest.len();
    if !after.is_empty() && !after.starts_with(char::is_whitespace) {
        return false;
    }
    // A range end followed by another dash would read as the start of a new
    // range once the first range is written out as a list.
    if last.range_end && !closed && after.trim_start_matches(is_horizontal).starts_with(is_dash) {
        return false;
    }
    if closed || after.is_empty() {
        return true;
    }
    let after = after.trim_start_matches(is_horizontal);
    let Some(first) = after.chars().next() else {
        return true;
    };
    // An unspaced range end may also be followed by whitespace and a word. The
    // lexer's Unicode `\w` decides what starts a word (letters, marks, decimal
    // digits, connector punctuation, join controls), as for task references.
    (last.range_end && !last.spaced && lexer.word.is_match(after))
        || is_line_break(first)
        || first == '('
        || first == ','
        || is_dash(first)
        || after
            .strip_prefix("and")
            .is_some_and(|tail| tail.starts_with(is_horizontal))
}

/// How many elements of the list after `anchor` count. A compact run (elements
/// joined by unspaced separators) that fails the final check is dropped as a
/// whole, back to the most recent element with a spaced separator, and the
/// check repeats on the new last element. That is: the longest prefix whose
/// last element passes the check, among the whole list and every prefix that
/// ends before an element with a spaced separator. One forward scan, no
/// stored elements.
fn counted_elements(lexer: &Lexer<'_>, anchor: &Reference<'_>) -> usize {
    let mut best = 0;
    let mut count = 0;
    let mut previous: Option<Element> = None;
    for element in Elements::after(lexer, anchor) {
        count += 1;
        if let Some(before) = previous.filter(|_| element.spaced) {
            if list_end_is_valid(lexer, &before) {
                best = count - 1;
            }
        }
        previous = Some(element);
    }
    if previous.is_some_and(|last| list_end_is_valid(lexer, &last)) {
        best = count;
    }
    best
}

type Visit<'a, 't> = &'a mut dyn FnMut(Event<'t>) -> Result<(), AppError>;

/// The units of the list started by `anchor`, anchor first.
fn list_events<'t>(
    lexer: &Lexer<'t>,
    anchor: Reference<'t>,
    visit: Visit<'_, 't>,
) -> Result<(), AppError> {
    let count = counted_elements(lexer, &anchor);
    let mut pending = Some(anchor);
    for element in Elements::after(lexer, &anchor).take(count) {
        let reference = Reference {
            start: element.start,
            end: element.end,
            id: element.id,
            bare: true,
            ..anchor
        };
        if element.range_end {
            match pending.take() {
                Some(first) => visit(Event::Range {
                    first,
                    last: reference,
                })?,
                None => visit(Event::Single(reference))?,
            }
        } else if let Some(previous) = pending.replace(reference) {
            visit(Event::Single(previous))?;
        }
    }
    if let Some(last) = pending {
        visit(Event::Single(last))?;
    }
    Ok(())
}

/// Groups slash chains as base does, starts lists at standalone anchors and
/// reports the units in start order.
fn walk<'t>(lexer: &Lexer<'t>, visit: Visit<'_, 't>) -> Result<(), AppError> {
    let text = lexer.text;
    let mut position = 0;
    while let Some(first) = lexer.candidate(position) {
        let mut last_end = first.reference.end;
        let mut size = 1;
        while text[last_end..].starts_with('/') {
            match lexer.candidate(last_end) {
                Some(next) if next.reference.start == last_end + 1 => {
                    last_end = next.reference.end;
                    size += 1;
                }
                _ => break,
            }
        }
        position = last_end;
        let group_start = first.reference.start;
        if eligible(text, group_start, last_end) {
            if size == 1 {
                if first.requestable {
                    list_events(lexer, first.reference, visit)?;
                }
            } else {
                members(lexer, first, last_end, |member| {
                    if member.requestable {
                        visit(Event::Single(member.reference))?;
                    }
                    Ok(())
                })?;
            }
        } else if text[..group_start].ends_with(")/") {
            members(lexer, first, last_end, |member| {
                if member.requestable && text[member.reference.end..].starts_with(" (") {
                    visit(Event::Protect(member.reference))?;
                }
                Ok(())
            })?;
        }
    }
    Ok(())
}

/// Visits the members of the slash group that starts with `first` and ends at
/// `group_end`.
fn members<'t>(
    lexer: &Lexer<'t>,
    first: Candidate<'t>,
    group_end: usize,
    mut each: impl FnMut(&Candidate<'t>) -> Result<(), AppError>,
) -> Result<(), AppError> {
    let mut member = first;
    loop {
        each(&member)?;
        if member.reference.end >= group_end {
            return Ok(());
        }
        match lexer.candidate(member.reference.end) {
            Some(next) => member = next,
            None => return Ok(()),
        }
    }
}

fn is_short_range(first: &Reference<'_>, last: &Reference<'_>) -> bool {
    last.id - first.id < MAX_EXPANDED_RANGE
}

type Requested<'t> = BTreeSet<(Option<&'t str>, u64)>;

/// Every distinct `(slot, id)` the text can need, counted as it is found.
fn requested_ids<'t>(lexer: &Lexer<'t>) -> Result<Requested<'t>, AppError> {
    let mut requests = Requested::new();
    let mut previous: Option<(Option<&str>, u64)> = None;
    let mut request = |slot: Option<&'t str>, id: u64| -> Result<(), AppError> {
        if previous == Some((slot, id)) {
            return Ok(());
        }
        previous = Some((slot, id));
        requests.insert((slot, id));
        if requests.len() > MAX_DISTINCT_IDS {
            return Err(AppError::Validation(
                "enrichment input contains more than 10000 distinct task IDs; split the document"
                    .into(),
            ));
        }
        Ok(())
    };
    walk(lexer, &mut |event| match event {
        Event::Single(r) | Event::Protect(r) => request(r.slot, r.id),
        Event::Range { first, last } => {
            if is_short_range(&first, &last) {
                for id in first.id..=last.id {
                    request(first.slot, id)?;
                }
                Ok(())
            } else {
                request(first.slot, first.id)?;
                request(last.slot, last.id)
            }
        }
    })?;
    Ok(requests)
}

/// Resolved titles, split so a lookup never allocates.
struct Titles<'r> {
    local: HashMap<u64, &'r String>,
    foreign: HashMap<(&'r str, u64), &'r String>,
}

impl<'r> Titles<'r> {
    fn new(titles: &'r HashMap<(Slot, u64), String>) -> Self {
        let mut local = HashMap::new();
        let mut foreign = HashMap::new();
        for ((slot, id), title) in titles {
            match slot {
                None => local.insert(*id, title),
                Some(key) => foreign.insert((key.as_str(), *id), title),
            };
        }
        Self { local, foreign }
    }

    fn get(&self, slot: Option<&str>, id: u64) -> Option<&'r String> {
        match slot {
            None => self.local.get(&id).copied(),
            Some(key) => self.foreign.get(&(key, id)).copied(),
        }
    }
}

/// Writes the enriched text, or only measures it when `output` is `None`.
struct Renderer<'t, 'r> {
    text: &'t str,
    titles: &'r Titles<'r>,
    known_keys: &'r BTreeSet<String>,
    output: Option<String>,
    /// Bytes written (or measured) so far, excluding the uncopied rest.
    emitted: usize,
    copied: usize,
    protected_until: usize,
    replacements: usize,
    changed: bool,
    unknown: BTreeSet<(Option<&'t str>, u64)>,
}

impl<'t, 'r> Renderer<'t, 'r> {
    fn title(&self, reference: &Reference<'_>) -> Option<&'r String> {
        self.titles.get(reference.slot, reference.id)
    }

    fn report_if_unknown(&mut self, slot: Option<&'t str>, id: u64) {
        let reportable = match slot {
            None => true,
            Some(key) => self.known_keys.contains(key),
        };
        if reportable && self.titles.get(slot, id).is_none() {
            self.unknown.insert((slot, id));
        }
    }

    /// The end of the exact ` (title)` annotation after `reference`, if present.
    fn exact_end(&self, reference: &Reference<'_>) -> Option<usize> {
        let title = self.title(reference)?;
        let rest = self.text[reference.end..].strip_prefix(" (")?;
        let rest = rest.strip_prefix(title.as_str())?;
        rest.starts_with(')')
            .then_some(reference.end + title.len() + 3)
    }

    fn put(&mut self, piece: &str) {
        self.emitted += piece.len();
        if let Some(output) = &mut self.output {
            output.push_str(piece);
        }
    }

    fn copy_to(&mut self, upto: usize) {
        let piece = &self.text[self.copied..upto];
        self.put(piece);
        self.copied = upto;
    }

    /// Fails once the bytes already emitted pass the limit. The rest of the
    /// text is not counted: a later range can drop separator whitespace, so
    /// only the final call, after the last copy, sees the exact size.
    fn check_size(&self) -> Result<(), AppError> {
        if self.emitted > MAX_OUTPUT_BYTES {
            return Err(AppError::Validation(
                "enriched output exceeds 64 MiB; split the document".into(),
            ));
        }
        Ok(())
    }

    fn annotate(&mut self, title: &str) {
        self.put(" (");
        self.put(title);
        self.put(")");
        self.replacements += 1;
        self.changed = true;
    }

    /// Copies up to `reference` and writes it; a known list number gets its
    /// key prefix so that it is a full reference.
    fn write_reference(&mut self, reference: &Reference<'_>, known: bool) {
        self.copy_to(reference.start);
        if reference.bare && known {
            self.put(reference.prefix);
            self.changed = true;
        }
        self.copy_to(reference.end);
    }

    fn single(&mut self, reference: &Reference<'t>) -> Result<(), AppError> {
        let Some(title) = self.title(reference) else {
            self.report_if_unknown(reference.slot, reference.id);
            return Ok(());
        };
        self.write_reference(reference, true);
        match self.exact_end(reference) {
            Some(end) => self.protected_until = end,
            None => self.annotate(title),
        }
        self.check_size()
    }

    fn protect(&mut self, reference: &Reference<'t>) {
        if let Some(end) = self.exact_end(reference) {
            self.protected_until = end;
        }
    }

    fn range(&mut self, first: &Reference<'t>, last: &Reference<'t>) -> Result<(), AppError> {
        if !is_short_range(first, last) {
            self.single(first)?;
            return self.single(last);
        }
        for id in first.id..=last.id {
            self.report_if_unknown(first.slot, id);
        }
        if !(first.id..=last.id).any(|id| self.titles.get(first.slot, id).is_some()) {
            return Ok(());
        }
        let first_title = self.title(first);
        // Inside an expanded range every element is a full reference.
        self.write_reference(first, true);
        if let Some(title) = first_title {
            self.annotate(title);
        }
        for id in first.id + 1..last.id {
            self.put(", ");
            self.put(first.prefix);
            self.put(&id.to_string());
            if let Some(title) = self.titles.get(first.slot, id) {
                self.annotate(title);
            }
        }
        self.put(", ");
        let last_title = self.title(last);
        self.put(last.prefix);
        self.put(&self.text[last.start..last.end]);
        self.copied = last.end;
        if let Some(title) = last_title {
            match self.exact_end(last) {
                Some(end) => self.protected_until = end,
                None => self.annotate(title),
            }
        }
        self.changed = true;
        self.check_size()
    }

    fn event(&mut self, event: &Event<'t>) -> Result<(), AppError> {
        if event.start() < self.protected_until {
            return Ok(());
        }
        match event {
            Event::Single(reference) => self.single(reference),
            Event::Protect(reference) => {
                self.protect(reference);
                Ok(())
            }
            Event::Range { first, last } => self.range(first, last),
        }
    }
}

/// One rendering pass over `lexer`'s text; `output` selects write or measure.
fn render<'t, 'r>(
    lexer: &Lexer<'t>,
    titles: &'r Titles<'r>,
    known_keys: &'r BTreeSet<String>,
    output: Option<String>,
) -> Result<Renderer<'t, 'r>, AppError> {
    let mut renderer = Renderer {
        text: lexer.text,
        titles,
        known_keys,
        output,
        emitted: 0,
        copied: 0,
        protected_until: 0,
        replacements: 0,
        changed: false,
        unknown: BTreeSet::new(),
    };
    walk(lexer, &mut |event| renderer.event(&event))?;
    renderer.copy_to(lexer.text.len());
    renderer.check_size()?;
    Ok(renderer)
}

/// Shared lexical/rendering rules with a bounded concrete title lookup seam.
///
/// The text is read three times: to collect the requested IDs, to measure the
/// output (failing at 64 MiB before anything is allocated) and to write it
/// into a buffer of exactly that size. No pass stores per-occurrence records,
/// so memory stays near the input plus the output.
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
    let lexer = Lexer::new(text, own_key)?;
    let requests = requested_ids(&lexer)?;
    if requests.is_empty() {
        return Ok(EnrichedText {
            text: text.into(),
            replacements: 0,
            unknown_ids: vec![],
            unknown_refs: vec![],
        });
    }
    let mut by_slot = TitleRequests::new();
    for (slot, id) in &requests {
        by_slot.entry(slot.map(String::from)).or_default().push(*id);
    }
    drop(requests);
    let TitleResolution { titles, known_keys } = resolve(&by_slot)?;
    drop(by_slot);
    let titles = Titles::new(&titles);
    let measured = render(&lexer, &titles, &known_keys, None)?;
    let output = if measured.changed {
        let buffer = String::with_capacity(measured.emitted);
        let written = render(&lexer, &titles, &known_keys, Some(buffer))?;
        written.output.unwrap_or_default()
    } else {
        text.to_string()
    };
    let Renderer {
        replacements,
        unknown,
        ..
    } = measured;
    let unknown_refs = unknown
        .iter()
        .map(|(slot, id)| {
            let key = slot.or(own_key).unwrap_or("T");
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
