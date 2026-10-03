CREATE TABLE server_identity(singleton INTEGER PRIMARY KEY CHECK(singleton=1),server_id TEXT NOT NULL UNIQUE);
CREATE TABLE credentials(
 credential_id TEXT PRIMARY KEY, public_key BLOB NOT NULL CHECK(length(public_key)=32),
 actor_id TEXT NOT NULL, actor_name TEXT NOT NULL, installation_id TEXT NOT NULL,
 installation_name TEXT NOT NULL, revoked INTEGER NOT NULL CHECK(revoked IN (0,1))
);
CREATE TABLE replay_nonces(
 credential_id TEXT NOT NULL REFERENCES credentials(credential_id),nonce TEXT NOT NULL,
 expires INTEGER NOT NULL,PRIMARY KEY(credential_id,nonce)
);
CREATE INDEX replay_expiry ON replay_nonces(expires);
CREATE TABLE admin_events(
 event_id INTEGER PRIMARY KEY,operation TEXT NOT NULL,credential_id TEXT,
 os_actor TEXT,identity_json TEXT CHECK(identity_json IS NULL OR json_valid(identity_json)),
 recorded_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TRIGGER admin_events_no_update BEFORE UPDATE ON admin_events BEGIN SELECT RAISE(ABORT,'admin history is append-only'); END;
CREATE TRIGGER admin_events_no_delete BEFORE DELETE ON admin_events BEGIN SELECT RAISE(ABORT,'admin history is append-only'); END;
