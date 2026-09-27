-- Apply after schema-v2.sql and schema-v3-additions.sql; frozen schema 4 priority additions.
ALTER TABLE tasks ADD COLUMN priority TEXT NOT NULL DEFAULT 'P2' CHECK(priority IN ('P0','P1','P2','P3'));
CREATE INDEX idx_tasks_priority_id ON tasks(priority,id);
CREATE INDEX idx_tasks_status_priority_id ON tasks(status,priority,id);
PRAGMA user_version = 4;
