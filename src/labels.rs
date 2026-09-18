use crate::error::AppError;
use rusqlite::{params, Connection};
pub fn normalize(values: Vec<String>) -> Result<Vec<String>, AppError> {
    let mut out = Vec::new();
    for value in values {
        let label = value.trim().to_ascii_lowercase();
        if label.is_empty()
            || label.len() > 64
            || !label
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"-_.:".contains(&c))
        {
            return Err(AppError::Validation("labels must contain 1-64 ASCII letters, digits, hyphens, underscores, dots or colons".into()));
        }
        out.push(label);
    }
    out.sort();
    out.dedup();
    if out.len() > 32 {
        return Err(AppError::Validation(
            "a task may have at most 32 labels".into(),
        ));
    }
    Ok(out)
}
pub fn parse(text: &str) -> Result<Vec<String>, AppError> {
    if text.trim().is_empty() {
        return Ok(Vec::new());
    }
    normalize(text.split(',').map(str::to_owned).collect())
}
pub fn filter(label: Option<&str>) -> Result<Option<String>, AppError> {
    label
        .map(|v| normalize(vec![v.into()]).map(|mut v| v.remove(0)))
        .transpose()
}
pub fn create_schema(conn: &Connection) -> Result<(), AppError> {
    conn.execute_batch("CREATE TABLE task_labels(task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,label TEXT NOT NULL,PRIMARY KEY(task_id,label)); CREATE INDEX idx_task_labels_label ON task_labels(label,task_id);")?;
    crate::full_text::create_index(conn)
}
pub fn read(conn: &Connection, id: u64) -> Result<Vec<String>, AppError> {
    let mut stmt = conn.prepare("SELECT label FROM task_labels WHERE task_id=?1 ORDER BY label")?;
    let rows = stmt.query_map([id], |r| r.get(0))?;
    Ok(rows.collect::<Result<_, _>>()?)
}
pub fn replace(conn: &Connection, id: u64, labels: &[String]) -> Result<(), AppError> {
    conn.execute("DELETE FROM task_labels WHERE task_id=?1", [id])?;
    for label in labels {
        conn.execute("INSERT INTO task_labels VALUES(?1,?2)", params![id, label])?;
    }
    Ok(())
}

// List results are bounded; fetch all their labels in one indexed query.
pub fn read_many(
    conn: &Connection,
    ids: &[u64],
) -> Result<std::collections::HashMap<u64, Vec<String>>, AppError> {
    let mut out = std::collections::HashMap::<u64, Vec<String>>::new();
    if ids.is_empty() {
        return Ok(out);
    }
    let slots = std::iter::repeat_n("?", ids.len())
        .collect::<Vec<_>>()
        .join(",");
    let mut stmt = conn.prepare(&format!(
        "SELECT task_id,label FROM task_labels WHERE task_id IN ({slots}) ORDER BY task_id,label"
    ))?;
    let mut rows = stmt.query(rusqlite::params_from_iter(ids.iter()))?;
    while let Some(row) = rows.next()? {
        out.entry(row.get(0)?).or_default().push(row.get(1)?);
    }
    Ok(out)
}
