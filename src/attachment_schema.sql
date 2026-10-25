CREATE TABLE attachment_blobs(
    blob_id INTEGER PRIMARY KEY CHECK(blob_id > 0),
    content_sha256 TEXT NOT NULL UNIQUE
        CHECK(length(content_sha256) = 64 AND content_sha256 NOT GLOB '*[^0-9a-f]*'),
    original_size INTEGER NOT NULL CHECK(original_size BETWEEN 0 AND 268435456),
    codec TEXT NOT NULL CHECK(codec IN ('raw','xz')),
    stored_size INTEGER NOT NULL CHECK(stored_size BETWEEN 52 AND 20971572),
    created_ms INTEGER NOT NULL,
    envelope BLOB NOT NULL CHECK(length(envelope) = stored_size)  -- last: metadata reads skip overflow
);
CREATE INDEX idx_attachment_blobs_stored_size ON attachment_blobs(stored_size);
CREATE TABLE task_attachments(
    attachment_id INTEGER PRIMARY KEY CHECK(attachment_id > 0),
    task_id INTEGER NOT NULL REFERENCES tasks(id),
    blob_id INTEGER NOT NULL REFERENCES attachment_blobs(blob_id),
    name TEXT NOT NULL CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 255),
    kind TEXT NOT NULL CHECK(kind IN ('image','text','binary')),
    media_type TEXT NOT NULL CHECK(length(media_type) BETWEEN 3 AND 127),
    added_event_id INTEGER NOT NULL REFERENCES events(event_id),
    added_ms INTEGER NOT NULL,
    detached_event_id INTEGER REFERENCES events(event_id),
    detached_ms INTEGER,
    CHECK((detached_event_id IS NULL) = (detached_ms IS NULL))
);
CREATE INDEX idx_task_attachments_retained ON task_attachments(task_id, attachment_id)
    WHERE detached_event_id IS NULL;
CREATE INDEX idx_task_attachments_task ON task_attachments(task_id, attachment_id);
CREATE INDEX idx_task_attachments_blob ON task_attachments(blob_id);
CREATE TRIGGER attachment_blobs_no_update BEFORE UPDATE ON attachment_blobs
    BEGIN SELECT RAISE(ABORT, 'attachment content is immutable'); END;
CREATE TRIGGER attachment_blobs_no_delete BEFORE DELETE ON attachment_blobs
    BEGIN SELECT RAISE(ABORT, 'attachment content is retained'); END;
CREATE TRIGGER task_attachments_no_delete BEFORE DELETE ON task_attachments
    BEGIN SELECT RAISE(ABORT, 'attachment history is append-only'); END;
CREATE TRIGGER task_attachments_detach_once BEFORE UPDATE ON task_attachments
    WHEN OLD.detached_event_id IS NOT NULL OR NEW.detached_event_id IS NULL
      OR NEW.detached_ms IS NULL OR NEW.attachment_id IS NOT OLD.attachment_id
      OR NEW.task_id IS NOT OLD.task_id OR NEW.blob_id IS NOT OLD.blob_id
      OR NEW.name IS NOT OLD.name OR NEW.kind IS NOT OLD.kind
      OR NEW.media_type IS NOT OLD.media_type OR NEW.added_event_id IS NOT OLD.added_event_id
      OR NEW.added_ms IS NOT OLD.added_ms
    BEGIN SELECT RAISE(ABORT, 'an attachment changes only by one detach'); END;
CREATE TRIGGER attachment_blobs_no_replace BEFORE INSERT ON attachment_blobs
    WHEN EXISTS(SELECT 1 FROM attachment_blobs
                WHERE blob_id = NEW.blob_id OR content_sha256 = NEW.content_sha256)
    BEGIN SELECT RAISE(ABORT, 'attachment content is immutable'); END;
CREATE TRIGGER task_attachments_no_replace BEFORE INSERT ON task_attachments
    WHEN EXISTS(SELECT 1 FROM task_attachments WHERE attachment_id = NEW.attachment_id)
    BEGIN SELECT RAISE(ABORT, 'attachment history is append-only'); END;
