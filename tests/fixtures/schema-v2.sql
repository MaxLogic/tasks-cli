-- Schema 2 before labels and full-text search, deliberately independent of current schema construction.
        CREATE TABLE project(
            project_id TEXT PRIMARY KEY,
            rules_markdown TEXT NOT NULL DEFAULT '',
            rules_version INTEGER NOT NULL DEFAULT 1,
            next_task_number INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE tasks(
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            status TEXT NOT NULL,
            version INTEGER NOT NULL,
            created_ms INTEGER NOT NULL,
            updated_ms INTEGER NOT NULL,
            CHECK (version > 0),
            CHECK (status IN ('draft','todo','in-progress','blocked','done','cancelled'))
        );
        CREATE TABLE dependencies(
            task_id INTEGER NOT NULL,
            depends_on_id INTEGER NOT NULL,
            PRIMARY KEY(task_id, depends_on_id),
            FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE,
            FOREIGN KEY(depends_on_id) REFERENCES tasks(id) ON DELETE CASCADE
        );
        CREATE TABLE events(
            event_id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id INTEGER,
            entity_type TEXT NOT NULL,
            operation TEXT NOT NULL,
            resulting_version INTEGER NOT NULL,
            created_ms INTEGER NOT NULL,
            snapshot_json TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE
        );
        CREATE TABLE imports(
            input_sha256 TEXT PRIMARY KEY,
            source_name TEXT NOT NULL,
            original_source BLOB NOT NULL,
            report_json TEXT NOT NULL,
            imported_ms INTEGER NOT NULL
        );
        CREATE INDEX idx_tasks_status_id ON tasks(status, id);
        CREATE INDEX idx_dependencies_depends_on_id ON dependencies(depends_on_id);
        CREATE INDEX idx_events_task_id ON events(task_id, event_id);

PRAGMA user_version = 2;
