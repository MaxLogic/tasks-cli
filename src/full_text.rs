use crate::error::AppError;
use rusqlite::{params, Connection};

#[derive(Debug)]
pub struct RankedMatch {
    pub id: u64,
    pub status: String,
    pub version: u64,
    pub title: String,
    pub priority: String,
}

pub fn create_index(conn: &Connection) -> Result<(), AppError> {
    conn.execute_batch("CREATE VIRTUAL TABLE tasks_fts USING fts5(title,body,content='tasks',content_rowid='id',tokenize='unicode61',prefix='2 3');
        CREATE TRIGGER tasks_fts_insert AFTER INSERT ON tasks BEGIN
          INSERT INTO tasks_fts(rowid,title,body) VALUES(new.id,new.title,new.body); END;
        CREATE TRIGGER tasks_fts_delete AFTER DELETE ON tasks BEGIN
          INSERT INTO tasks_fts(tasks_fts,rowid,title,body) VALUES('delete',old.id,old.title,old.body); END;
        CREATE TRIGGER tasks_fts_update AFTER UPDATE OF title,body ON tasks WHEN new.title != old.title OR new.body != old.body BEGIN
          INSERT INTO tasks_fts(tasks_fts,rowid,title,body) VALUES('delete',old.id,old.title,old.body);
          INSERT INTO tasks_fts(rowid,title,body) VALUES(new.id,new.title,new.body); END;
        INSERT INTO tasks_fts(tasks_fts) VALUES('rebuild');")?;
    Ok(())
}

pub fn search(
    conn: &Connection,
    text: &str,
    prefix: bool,
    label: Option<&str>,
    offset: u64,
    limit: usize,
) -> Result<Vec<RankedMatch>, AppError> {
    let terms: Vec<_> = text.split_whitespace().collect();
    if text.len() > 4096
        || terms.is_empty()
        || terms.len() > 64
        || offset > i64::MAX as u64
        || !(1..=101).contains(&limit)
    {
        return Err(AppError::Validation(
            "ranked search requires 1-64 words, at most 4096 bytes, a valid offset and limit"
                .into(),
        ));
    }
    let query = terms
        .iter()
        .map(|term| {
            format!(
                "\"{}\"{}",
                term.replace('"', "\"\""),
                if prefix { "*" } else { "" }
            )
        })
        .collect::<Vec<_>>()
        .join(" AND ");
    let mut stmt = conn.prepare("SELECT t.id,t.status,t.version,t.title,t.priority FROM tasks_fts JOIN tasks t ON t.id=tasks_fts.rowid
        WHERE tasks_fts MATCH ?1 AND (?2 IS NULL OR EXISTS(SELECT 1 FROM task_labels l WHERE l.task_id=t.id AND l.label=?2))
        ORDER BY bm25(tasks_fts,10.0,1.0),t.id LIMIT ?3 OFFSET ?4")?;
    let rows = stmt.query_map(params![query, label, limit as i64, offset as i64], |r| {
        Ok(RankedMatch {
            id: r.get(0)?,
            status: r.get(1)?,
            version: r.get(2)?,
            title: r.get(3)?,
            priority: r.get(4)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}
