CREATE TABLE mutation_receipts (
    request_id TEXT PRIMARY KEY NOT NULL,
    actor_id TEXT NOT NULL,
    installation_id TEXT NOT NULL,
    route TEXT NOT NULL,
    payload_sha256 TEXT NOT NULL CHECK(length(payload_sha256) = 64),
    status INTEGER NOT NULL CHECK(status BETWEEN 200 AND 499),
    response_json TEXT NOT NULL CHECK(json_valid(response_json))
);
CREATE TRIGGER mutation_receipts_no_update BEFORE UPDATE ON mutation_receipts
    BEGIN SELECT RAISE(ABORT, 'mutation receipts are append-only'); END;
CREATE TRIGGER mutation_receipts_no_delete BEFORE DELETE ON mutation_receipts
    BEGIN SELECT RAISE(ABORT, 'mutation receipts are append-only'); END;
