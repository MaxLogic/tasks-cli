-- Apply after schema-v2.sql; frozen schema 3 labels/search additions.
CREATE TABLE task_labels(task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,label TEXT NOT NULL,PRIMARY KEY(task_id,label));
CREATE INDEX idx_task_labels_label ON task_labels(label,task_id);
CREATE VIRTUAL TABLE tasks_fts USING fts5(title,body,content='tasks',content_rowid='id',tokenize='unicode61',prefix='2 3');
CREATE TRIGGER tasks_fts_insert AFTER INSERT ON tasks BEGIN
  INSERT INTO tasks_fts(rowid,title,body) VALUES(new.id,new.title,new.body); END;
CREATE TRIGGER tasks_fts_delete AFTER DELETE ON tasks BEGIN
  INSERT INTO tasks_fts(tasks_fts,rowid,title,body) VALUES('delete',old.id,old.title,old.body); END;
CREATE TRIGGER tasks_fts_update AFTER UPDATE OF title,body ON tasks WHEN new.title != old.title OR new.body != old.body BEGIN
  INSERT INTO tasks_fts(tasks_fts,rowid,title,body) VALUES('delete',old.id,old.title,old.body);
  INSERT INTO tasks_fts(rowid,title,body) VALUES(new.id,new.title,new.body); END;
INSERT INTO tasks_fts(tasks_fts) VALUES('rebuild');
PRAGMA user_version = 3;
