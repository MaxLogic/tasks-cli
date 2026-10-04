#![cfg(feature = "server")]
use serde_json::json;
use tasks_cli::{
    model::{TaskStatus, TaskUpdate},
    server::receipts::{execute, ReceiptIdentity},
    store::{create_project_db, Store},
};
use uuid::Uuid;

fn fixture() -> (tempfile::TempDir, Uuid, ReceiptIdentity) {
    let root = tempfile::tempdir().unwrap();
    let project = Uuid::new_v4();
    create_project_db(root.path(), &project).unwrap();
    let identity = ReceiptIdentity {
        request_id: Uuid::new_v4(),
        actor_id: "owner".into(),
        installation_id: Uuid::new_v4(),
        route: "POST /tasks".into(),
    };
    (root, project, identity)
}
fn store(root: &std::path::Path, project: Uuid) -> Store {
    Store::open_rw(root, &project.to_string()).unwrap()
}
#[test]
fn receipt_and_mutation_commit_once_and_replay_precedes_version_check() {
    let (root, project, key) = fixture();
    let result = execute(
        store(root.path(), project),
        &key,
        b"canonical-create",
        |store| {
            let (id, version, event) =
                store.create_task("first", "body", TaskStatus::Ready, vec![])?;
            Ok(json!({"id":id,"version":version,"event_id":event}))
        },
    )
    .unwrap();
    assert_eq!(result.status, 200);
    let replay = execute(
        store(root.path(), project),
        &key,
        b"canonical-create",
        |_| panic!("replay must not dispatch"),
    )
    .unwrap();
    assert_eq!(replay, result);
    let mut update = key.clone();
    update.request_id = Uuid::new_v4();
    update.route = "PATCH /tasks/1".into();
    let result = execute(
        store(root.path(), project),
        &update,
        b"version-1",
        |store| {
            let (_, _, version, event) = store.update_task(
                1,
                1,
                TaskUpdate {
                    title: Some("updated".into()),
                    ..Default::default()
                },
            )?;
            Ok(json!({"version":version,"event_id":event}))
        },
    )
    .unwrap();
    let replay = execute(store(root.path(), project), &update, b"version-1", |_| {
        panic!("stale version must not be checked")
    })
    .unwrap();
    assert_eq!(replay, result);
    let db = store(root.path(), project);
    assert_eq!(
        db.conn
            .query_row(
                "SELECT count(*) FROM events WHERE entity_type='task'",
                [],
                |r| r.get::<_, u64>(0)
            )
            .unwrap(),
        2
    );
    assert_eq!(
        db.conn
            .query_row("SELECT count(*) FROM mutation_receipts", [], |r| r
                .get::<_, u64>(0))
            .unwrap(),
        2
    );
    assert!(db
        .conn
        .execute("DELETE FROM mutation_receipts", [])
        .is_err());
    assert!(db
        .conn
        .execute("UPDATE mutation_receipts SET status=400", [])
        .is_err());
}
#[test]
fn receipt_scope_and_payload_conflicts_never_dispatch_or_mutate() {
    let (root, project, key) = fixture();
    execute(store(root.path(), project), &key, b"first", |_| {
        Ok(json!({"saved":true}))
    })
    .unwrap();
    for fault in ["body", "actor", "installation", "route"] {
        let mut other = key.clone();
        match fault {
            "actor" => other.actor_id = "other".into(),
            "installation" => other.installation_id = Uuid::new_v4(),
            "route" => other.route = "PUT /rules".into(),
            _ => (),
        }
        let result = execute(
            store(root.path(), project),
            &other,
            if fault == "body" {
                b"second".as_slice()
            } else {
                b"first".as_slice()
            },
            |_| panic!("conflicting key must not dispatch"),
        )
        .unwrap();
        assert_eq!(result.status, 409);
        assert_eq!(result.body["error"]["code"], "idempotency_conflict");
    }
}
#[test]
fn terminal_completion_refusal_is_retained_after_the_prerequisite_changes() {
    let (root, project, key) = fixture();
    let mut db = store(root.path(), project);
    db.create_task("parent", "", TaskStatus::Ready, vec![])
        .unwrap();
    db.create_task("child", "", TaskStatus::Ready, vec![1])
        .unwrap();
    drop(db);
    let refusal = execute(
        store(root.path(), project),
        &key,
        b"finish-child",
        |store| {
            store.update_task(
                2,
                1,
                TaskUpdate {
                    status: Some(TaskStatus::Done),
                    ..Default::default()
                },
            )?;
            Ok(json!({}))
        },
    )
    .unwrap();
    assert_eq!(refusal.status, 400);
    let mut db = store(root.path(), project);
    db.update_task(
        1,
        1,
        TaskUpdate {
            status: Some(TaskStatus::Done),
            ..Default::default()
        },
    )
    .unwrap();
    drop(db);
    assert_eq!(
        execute(
            store(root.path(), project),
            &key,
            b"finish-child",
            |_| panic!("refusal cannot become a success")
        )
        .unwrap(),
        refusal
    );
    assert_eq!(
        store(root.path(), project).show_task("2").unwrap().version,
        1
    );
}
#[test]
fn failed_receipt_insert_rolls_back_counter_task_history_and_rules() {
    let (root, project, key) = fixture();
    let db = store(root.path(), project);
    db.conn.execute_batch("CREATE TRIGGER receipt_fault BEFORE INSERT ON mutation_receipts BEGIN SELECT RAISE(ABORT,'synthetic receipt failure'); END;").unwrap();
    drop(db);
    let result = execute(store(root.path(), project), &key, b"first", |store| {
        store.create_task("must roll back", "", TaskStatus::Ready, vec![])?;
        store.rules_set("must roll back", 1)?;
        Ok(json!({"ok":true}))
    });
    assert!(result.is_err());
    let db = store(root.path(), project);
    assert_eq!(
        db.conn
            .query_row("SELECT count(*) FROM tasks", [], |r| r.get::<_, u64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        db.conn
            .query_row("SELECT count(*) FROM events", [], |r| r.get::<_, u64>(0))
            .unwrap(),
        0
    );
    assert_eq!(db.project_rules().unwrap().version, 1);
    assert_eq!(
        db.conn
            .query_row("SELECT next_task_number FROM project", [], |r| r
                .get::<_, u64>(0))
            .unwrap(),
        1
    );
}
#[test]
fn competing_versioned_writes_have_one_success_and_one_persisted_conflict() {
    let (root, project, key) = fixture();
    store(root.path(), project)
        .create_task("original", "", TaskStatus::Ready, vec![])
        .unwrap();
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
    let results = std::thread::scope(|scope| {
        let handles = (0..2)
            .map(|index| {
                let barrier = barrier.clone();
                let mut key = key.clone();
                key.request_id = Uuid::new_v4();
                let root = root.path();
                scope.spawn(move || {
                    let db = store(root, project);
                    barrier.wait();
                    execute(db, &key, b"update", |store| {
                        let result = store.update_task(
                            1,
                            1,
                            TaskUpdate {
                                title: Some(format!("writer-{index}")),
                                ..Default::default()
                            },
                        )?;
                        Ok(json!({"version":result.2}))
                    })
                    .unwrap()
                })
            })
            .collect::<Vec<_>>();
        handles
            .into_iter()
            .map(|h| h.join().unwrap().status)
            .collect::<Vec<_>>()
    });
    assert_eq!(results.iter().filter(|&&s| s == 200).count(), 1);
    assert_eq!(results.iter().filter(|&&s| s == 409).count(), 1);
    assert_eq!(
        store(root.path(), project).show_task("1").unwrap().version,
        2
    );
}

#[test]
fn terminal_refusal_rolls_back_earlier_steps_but_keeps_receipt() {
    let (root, project, key) = fixture();
    let response = execute(store(root.path(), project), &key, b"refused", |store| {
        store.create_task("rollback", "", TaskStatus::Ready, vec![])?;
        Err(tasks_cli::AppError::validation("synthetic refusal"))
    })
    .unwrap();
    assert_eq!(response.status, 400);
    let db = store(root.path(), project);
    assert_eq!(
        db.conn
            .query_row("SELECT count(*) FROM tasks", [], |r| r.get::<_, u64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        db.conn
            .query_row("SELECT count(*) FROM mutation_receipts", [], |r| r
                .get::<_, u64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn schema_seven_upgrade_preserves_history_and_backups_and_rejects_weakened_receipts() {
    let (root, project, _) = fixture();
    let mut db = store(root.path(), project);
    db.create_task("legacy", "exact\r\nΩ", TaskStatus::Ready, vec![])
        .unwrap();
    let before: String = db
        .conn
        .query_row("SELECT snapshot_json FROM events", [], |r| r.get(0))
        .unwrap();
    db.conn
        .execute_batch("DROP TABLE mutation_receipts; PRAGMA user_version=7;")
        .unwrap();
    drop(db);
    assert!(Store::open_rw(root.path(), &project.to_string()).is_err());
    let mut db = Store::open_for_migration(root.path(), &project.to_string()).unwrap();
    let (from, to, backup) = db.migrate().unwrap();
    assert_eq!((from, to), (7, 8));
    let backup = rusqlite::Connection::open(backup.unwrap()).unwrap();
    assert_eq!(
        backup
            .pragma_query_value(None, "user_version", |r| r.get::<_, u64>(0))
            .unwrap(),
        7
    );
    assert_eq!(
        db.conn
            .query_row("SELECT snapshot_json FROM events", [], |r| r
                .get::<_, String>(0))
            .unwrap(),
        before
    );
    db.conn.execute_batch("DROP TRIGGER mutation_receipts_no_delete; CREATE TRIGGER mutation_receipts_no_delete BEFORE DELETE ON mutation_receipts BEGIN SELECT 1; END;").unwrap();
    drop(db);
    assert!(Store::open_rw(root.path(), &project.to_string()).is_err());
}

#[test]
fn streaming_markdown_preserves_complete_bytes_from_one_snapshot() {
    use std::io::Write;
    struct Probe {
        bytes: Vec<u8>,
        max_write: usize,
        first: Option<Box<dyn FnMut()>>,
    }
    impl Write for Probe {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if let Some(mut first) = self.first.take() {
                first();
            }
            self.max_write = self.max_write.max(bytes.len());
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let (root, project, _) = fixture();
    let mut db = store(root.path(), project);
    db.rules_set("rules Ω\r\n", 1).unwrap();
    for index in 0..12 {
        db.create_task(
            &format!("task-{index}"),
            &"x".repeat(1_048_576),
            TaskStatus::Ready,
            vec![],
        )
        .unwrap();
    }
    let (expected, count) = db.markdown_snapshot().unwrap();
    let path = root.path().to_owned();
    let mut probe = Probe {
        bytes: vec![],
        max_write: 0,
        first: Some(Box::new(move || {
            store(&path, project)
                .update_task(
                    1,
                    1,
                    TaskUpdate {
                        body: Some("concurrent new body".into()),
                        ..Default::default()
                    },
                )
                .unwrap();
        })),
    };
    assert_eq!(db.write_markdown(&mut probe).unwrap(), count);
    assert_eq!(probe.bytes, expected.as_bytes());
    assert!(probe.bytes.len() > 8 * 1024 * 1024);
    assert!(
        probe.max_write <= 1_048_576,
        "only one bounded task body may be handed to the writer at once"
    );
    assert_eq!(db.show_task("1").unwrap().version, 2);
}

mod api_routes {
    use super::*;
    use axum::http::{Method, Uri};
    use ed25519_dalek::SigningKey;
    use tasks_cli::server::{api, signatures::SigningIdentity, OwnedServer, Registration};

    struct ApiFixture {
        root: tempfile::TempDir,
        server: OwnedServer,
        signer: SigningIdentity,
    }
    impl ApiFixture {
        fn new() -> Self {
            let root = tempfile::tempdir().unwrap();
            let server = OwnedServer::initialize(root.path()).unwrap();
            let key = SigningKey::from_bytes(&[14; 32]);
            let id = server
                .register(&Registration {
                    public_key: key.verifying_key().to_bytes(),
                    actor_id: "registered-owner".into(),
                    actor_name: "Owner".into(),
                    installation_id: Uuid::new_v4(),
                    installation_name: "machine".into(),
                })
                .unwrap();
            let signer = SigningIdentity {
                server_id: server.server_id(),
                credential_id: id,
                key,
            };
            Self {
                root,
                server,
                signer,
            }
        }
        fn request(
            &self,
            method: Method,
            path: &str,
            body: serde_json::Value,
            key: Option<Uuid>,
        ) -> tasks_cli::server::receipts::ReceiptResponse {
            let uri: Uri = path.parse().unwrap();
            let bytes = if method == Method::GET {
                vec![]
            } else {
                serde_json::to_vec(&body).unwrap()
            };
            let headers = self.signer.sign_now(&method, &uri, &bytes, key).unwrap();
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64;
            let auth = self
                .server
                .authenticate(&method, &uri, &headers, now)
                .unwrap();
            auth.check_body(&bytes).unwrap();
            api::handle(&self.server, &auth, &method, &uri, &bytes).unwrap()
        }
        fn create(&self, project: Uuid) -> tasks_cli::server::receipts::ReceiptResponse {
            self.request(
                Method::POST,
                "/v1/projects",
                json!({"project_id":project,"name":"Synthetic project","project_key":"FIX"}),
                Some(Uuid::new_v4()),
            )
        }
    }

    #[test]
    fn unknown_project_refusal_has_a_durable_receipt_even_after_later_creation() {
        let f = ApiFixture::new();
        let project = Uuid::new_v4();
        let key = Uuid::new_v4();
        let route = format!("/v1/projects/{project}/tasks");
        let body = json!({"title":"must never be created","body":"body","status":"todo","deps":[],"labels":[]});
        let refusal = f.request(Method::POST, &route, body.clone(), Some(key));
        assert_eq!(refusal.status, 404);
        assert!(
            refusal.receipt.is_some(),
            "terminal refusal needs request identity"
        );
        let created = f.request(
            Method::POST,
            "/v1/projects",
            json!({"project_id":project,"name":"later","project_key":"LATER"}),
            Some(Uuid::new_v4()),
        );
        assert_eq!(created.status, 200);
        assert_eq!(f.request(Method::POST, &route, body, Some(key)), refusal);
        assert_eq!(
            store(f.root.path(), project)
                .conn
                .query_row("SELECT count(*) FROM tasks", [], |r| r.get::<_, u64>(0))
                .unwrap(),
            0
        );
    }

    #[test]
    fn large_project_history_is_refused_before_deserializing_snapshots() {
        let f = ApiFixture::new();
        let project = Uuid::new_v4();
        assert_eq!(f.create(project).status, 200);
        let db = store(f.root.path(), project);
        db.conn.execute("INSERT INTO metadata_events(operation,created_ms,snapshot_json,attribution_json) VALUES('import',1,?1,'{}')", [serde_json::to_string(&"x".repeat(5*1024*1024)).unwrap()]).unwrap();
        let reply = f.request(
            Method::POST,
            &format!("/v1/projects/{project}/query"),
            json!({"operation":"project_history","limit":10}),
            None,
        );
        assert_eq!(reply.status, 413);
        assert_eq!(reply.body["error"]["code"], "response_limit");
        let first = f.request(
            Method::POST,
            &format!("/v1/projects/{project}/query"),
            json!({"operation":"project_history","limit":1}),
            None,
        );
        assert_eq!(first.status, 200);
        assert_eq!(first.body["output"]["data"]["has_more"], true);
        assert_eq!(
            first.body["output"]["data"]["items"][0]["operation"],
            "create"
        );
    }

    #[test]
    fn typed_reads_writes_errors_and_authoritative_attribution() {
        let f = ApiFixture::new();
        let project = Uuid::new_v4();
        assert_eq!(f.create(project).status, 200);
        let path = format!("/v1/projects/{project}/tasks");
        let key = Uuid::new_v4();
        let attribution = tasks_cli::model::Attribution {
            actor_id: Some("forged".into()),
            ..Default::default()
        };
        let payload = json!({"title":"created","body":"complete Ω\r\nbody","status":"todo","attribution":attribution});
        let result = f.request(Method::POST, &path, payload.clone(), Some(key));
        assert_eq!(result.status, 200);
        assert_eq!(result.body["output"]["data"]["display_id"], "FIX-001");
        assert_eq!(f.request(Method::POST, &path, payload, Some(key)), result);
        let result = f.request(
            Method::POST,
            &format!("/v1/projects/{project}/query"),
            json!({"operation":"show","ids":["FIX-001"],"rules":true}),
            None,
        );
        assert_eq!(result.status, 200);
        assert_eq!(result.body["output"]["data"]["body"], "complete Ω\r\nbody");
        let update = format!("{path}/1");
        assert_eq!(
            f.request(
                Method::PATCH,
                &update,
                json!({"task_ref":"FIX-001","expect_version":1,"changes":{"title":"new"}}),
                Some(Uuid::new_v4())
            )
            .status,
            200
        );
        let conflict = f.request(
            Method::PATCH,
            &update,
            json!({"task_ref":"FIX-001","expect_version":1,"changes":{"title":"stale"}}),
            Some(Uuid::new_v4()),
        );
        assert_eq!(conflict.status, 409);
        assert_eq!(
            conflict.body["error"]["conflict"],
            json!({"expected":1,"current":2})
        );
        let mut db = store(f.root.path(), project);
        let event = db.history(1, None, 10, Some(1)).unwrap().1.unwrap();
        assert_eq!(
            event.attribution.unwrap().actor_id.as_deref(),
            Some("registered-owner")
        );
        for body in [
            json!({"operation":"execute","sql":"DELETE FROM tasks"}),
            json!({"operation":"list","limit":101}),
            json!({"operation":"show","ids":["1"],"unknown":true}),
        ] {
            assert_eq!(
                f.request(
                    Method::POST,
                    &format!("/v1/projects/{project}/query"),
                    body,
                    None
                )
                .status,
                400
            );
        }
        assert_eq!(
            f.request(
                Method::POST,
                &format!("/v1/projects/{}/query", Uuid::new_v4()),
                json!({"operation":"list"}),
                None
            )
            .status,
            404
        );
    }

    #[test]
    fn catalog_publish_failure_replays_creation_and_repairs_only_binding() {
        let f = ApiFixture::new();
        let project = Uuid::new_v4();
        let key = Uuid::new_v4();
        let db = rusqlite::Connection::open(f.root.path().join("server.sqlite")).unwrap();
        db.execute_batch("CREATE TRIGGER catalog_fault BEFORE INSERT ON projects BEGIN SELECT RAISE(ABORT,'synthetic publication failure'); END;").unwrap();
        let uri: Uri = "/v1/projects".parse().unwrap();
        let body = serde_json::to_vec(
            &json!({"project_id":project,"name":"original","project_key":"FIX"}),
        )
        .unwrap();
        let headers = f
            .signer
            .sign_now(&Method::POST, &uri, &body, Some(key))
            .unwrap();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let auth = f
            .server
            .authenticate(&Method::POST, &uri, &headers, now)
            .unwrap();
        assert!(api::handle(&f.server, &auth, &Method::POST, &uri, &body).is_err());
        db.execute_batch("DROP TRIGGER catalog_fault").unwrap();
        let repaired = f.request(
            Method::POST,
            "/v1/projects",
            json!({"project_id":project,"name":"original","project_key":"FIX"}),
            Some(key),
        );
        assert_eq!(repaired.status, 200);
        let db = store(f.root.path(), project);
        assert_eq!(
            db.conn
                .query_row(
                    "SELECT count(*) FROM metadata_events WHERE operation='create'",
                    [],
                    |r| r.get::<_, u64>(0)
                )
                .unwrap(),
            1
        );
        assert_eq!(f.create(project).status, 409);
        let catalog = f.request(Method::GET, "/v1/projects", json!(null), None);
        assert_eq!(catalog.body["items"].as_array().unwrap().len(), 1);
        assert_eq!(catalog.body["items"][0]["name"], "original");
    }

    #[test]
    fn rules_keys_exports_validation_refusals_and_catalog_pagination() {
        let f = ApiFixture::new();
        let project = Uuid::new_v4();
        f.create(project);
        let rules = format!("/v1/projects/{project}/rules");
        let key = Uuid::new_v4();
        let body = json!({"body":"exact rules Ω\r\n","expect_version":1});
        let saved = f.request(Method::PUT, &rules, body.clone(), Some(key));
        assert_eq!(saved.status, 200);
        assert_eq!(f.request(Method::PUT, &rules, body, Some(key)), saved);
        assert_eq!(
            f.request(
                Method::PUT,
                &rules,
                json!({"body":"stale","expect_version":1}),
                Some(Uuid::new_v4())
            )
            .status,
            409
        );
        let query = format!("/v1/projects/{project}/query");
        let saved = f.request(Method::POST, &query, json!({"operation":"rules"}), None);
        assert_eq!(saved.body["output"]["data"]["body"], "exact rules Ω\r\n");
        let second = Uuid::new_v4();
        assert_eq!(
            f.request(
                Method::POST,
                "/v1/projects",
                json!({"project_id":second,"name":"Second","project_key":"OTHER"}),
                Some(Uuid::new_v4())
            )
            .status,
            200
        );
        let setkey = format!("/v1/projects/{project}/key");
        let refused_key = Uuid::new_v4();
        let request = json!({"project_key":"OTHER"});
        let refusal = f.request(Method::PUT, &setkey, request.clone(), Some(refused_key));
        assert_eq!(refusal.status, 409);
        assert_eq!(
            f.request(
                Method::PUT,
                &format!("/v1/projects/{second}/key"),
                json!({"project_key":"NEWKEY"}),
                Some(Uuid::new_v4())
            )
            .status,
            200
        );
        assert_eq!(
            f.request(Method::PUT, &setkey, request, Some(refused_key)),
            refusal,
            "a collision refusal must not become a later key change"
        );
        assert_eq!(
            f.request(
                Method::PUT,
                &setkey,
                json!({"project_key":"CHANGED"}),
                Some(Uuid::new_v4())
            )
            .status,
            400
        );
        assert_eq!(
            f.request(
                Method::PUT,
                &setkey,
                json!({"project_key":"MINE"}),
                Some(Uuid::new_v4())
            )
            .status,
            200
        );
        let invalid = Uuid::new_v4();
        let path = format!("/v1/projects/{project}/tasks");
        let payload = json!({"title":"", "body":""});
        let refused = f.request(Method::POST, &path, payload.clone(), Some(invalid));
        assert_eq!(refused.status, 400);
        assert_eq!(
            f.request(Method::POST, &path, payload, Some(invalid)),
            refused
        );
        // Export is exercised through the streaming HTTP transport in remote_https.
        let page = f.request(Method::GET, "/v1/projects?limit=1", json!(null), None);
        assert_eq!(page.body["has_more"], true);
        let cursor = page.body["next_after"].as_str().unwrap();
        let next = f.request(
            Method::GET,
            &format!("/v1/projects?limit=1&after={cursor}"),
            json!(null),
            None,
        );
        assert_eq!(next.body["has_more"], false);
        assert_ne!(
            page.body["items"][0]["project_id"],
            next.body["items"][0]["project_id"]
        );
        assert!(
            f.request(Method::GET, "/v1/projects?limit=101", json!(null), None)
                .status
                == 400
        );
    }

    #[test]
    fn competing_project_creations_publish_one_creation_and_one_conflict_receipt() {
        let f = ApiFixture::new();
        let project = Uuid::new_v4();
        let replies = std::thread::scope(|scope| {
            let handles = (0..2)
                .map(|_| scope.spawn(|| f.create(project)))
                .collect::<Vec<_>>();
            handles
                .into_iter()
                .map(|h| h.join().unwrap().status)
                .collect::<Vec<_>>()
        });
        assert_eq!(replies.iter().filter(|&&s| s == 200).count(), 1);
        assert_eq!(replies.iter().filter(|&&s| s == 409).count(), 1);
        let db = store(f.root.path(), project);
        assert_eq!(
            db.conn
                .query_row("SELECT count(*) FROM metadata_events", [], |r| r
                    .get::<_, u64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            db.conn
                .query_row("SELECT count(*) FROM mutation_receipts", [], |r| r
                    .get::<_, u64>(0))
                .unwrap(),
            2
        );
    }

    #[test]
    fn server_schema_upgrade_is_explicit_backed_up_and_keeps_identity_credentials_and_nonces() {
        let f = ApiFixture::new();
        let id = f.server.server_id();
        let uri: Uri = "/v1/info".parse().unwrap();
        let headers = f
            .signer
            .sign(&Method::GET, &uri, b"", None, 1000, &[1; 32])
            .unwrap();
        f.server
            .authenticate(&Method::GET, &uri, &headers, 1000)
            .unwrap();
        drop(f.server);
        let db = rusqlite::Connection::open(f.root.path().join("server.sqlite")).unwrap();
        db.execute_batch("DROP TABLE projects; PRAGMA user_version=1;")
            .unwrap();
        drop(db);
        assert!(OwnedServer::open(f.root.path()).is_err());
        let backup = OwnedServer::migrate(f.root.path()).unwrap().unwrap();
        let old = rusqlite::Connection::open(backup).unwrap();
        assert_eq!(
            old.pragma_query_value(None, "user_version", |r| r.get::<_, u32>(0))
                .unwrap(),
            1
        );
        let server = OwnedServer::open(f.root.path()).unwrap();
        assert_eq!(server.server_id(), id);
        assert!(
            server
                .authenticate(&Method::GET, &uri, &headers, 1000)
                .is_err(),
            "replay survives upgrade"
        );
        let fresh = f
            .signer
            .sign(&Method::GET, &uri, b"", None, 1000, &[2; 32])
            .unwrap();
        server
            .authenticate(&Method::GET, &uri, &fresh, 1000)
            .unwrap();
        drop(server);
        assert!(OwnedServer::migrate(f.root.path()).unwrap().is_none());
    }

    struct HttpFixture {
        root: tempfile::TempDir,
        signer: SigningIdentity,
        state: tasks_cli::server::transport::ServiceState,
        address: std::net::SocketAddr,
        stop: Option<tokio::sync::oneshot::Sender<()>>,
        worker: Option<std::thread::JoinHandle<()>>,
    }
    impl HttpFixture {
        fn start(fixture: ApiFixture) -> Self {
            // Transfer the same authority to the actual HTTP service.
            let ApiFixture {
                root,
                server,
                signer,
            } = fixture;
            let state = tasks_cli::server::transport::ServiceState::new(server);
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            listener.set_nonblocking(true).unwrap();
            let (stop, receive) = tokio::sync::oneshot::channel();
            let app = state.router();
            let worker = std::thread::spawn(move || {
                tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(2)
                    .enable_all()
                    .build()
                    .unwrap()
                    .block_on(async {
                        let listener = tokio::net::TcpListener::from_std(listener).unwrap();
                        axum::serve(listener, app)
                            .with_graceful_shutdown(async {
                                let _ = receive.await;
                            })
                            .await
                            .unwrap();
                    });
            });
            Self {
                root,
                signer,
                state,
                address,
                stop: Some(stop),
                worker: Some(worker),
            }
        }
        fn begin(
            &self,
            method: Method,
            path: &str,
            body: &[u8],
            key: Option<Uuid>,
        ) -> std::net::TcpStream {
            self.begin_with_length(method, path, body, key, body.len())
        }
        fn begin_with_length(
            &self,
            method: Method,
            path: &str,
            body: &[u8],
            key: Option<Uuid>,
            declared: usize,
        ) -> std::net::TcpStream {
            use std::io::Write;
            let uri: Uri = path.parse().unwrap();
            let headers = self.signer.sign_now(&method, &uri, body, key).unwrap();
            let mut socket = std::net::TcpStream::connect(self.address).unwrap();
            socket
                .set_read_timeout(Some(std::time::Duration::from_secs(8)))
                .unwrap();
            socket
                .set_write_timeout(Some(std::time::Duration::from_secs(8)))
                .unwrap();
            write!(socket,"{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: {declared}\r\n").unwrap();
            for (name, value) in &headers {
                write!(socket, "{name}: {}\r\n", value.to_str().unwrap()).unwrap();
            }
            socket.write_all(b"\r\n").unwrap();
            if declared == body.len() {
                socket.write_all(body).unwrap();
            }
            socket
        }
        fn reply(mut socket: std::net::TcpStream) -> (u16, serde_json::Value) {
            use std::io::Read;
            let mut bytes = Vec::new();
            socket.read_to_end(&mut bytes).unwrap();
            let text = String::from_utf8(bytes).unwrap();
            let (head, body) = text.split_once("\r\n\r\n").unwrap();
            (
                head.split_whitespace().nth(1).unwrap().parse().unwrap(),
                serde_json::from_str(body).unwrap(),
            )
        }
        fn admitted(&self, before: u64) {
            let start = std::time::Instant::now();
            loop {
                let conn =
                    rusqlite::Connection::open(self.root.path().join("server.sqlite")).unwrap();
                let count: u64 = conn
                    .query_row("SELECT count(*) FROM replay_nonces", [], |r| r.get(0))
                    .unwrap();
                if count > before {
                    return;
                }
                assert!(
                    start.elapsed() < std::time::Duration::from_secs(3),
                    "HTTP request was not admitted"
                );
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
    }
    impl Drop for HttpFixture {
        fn drop(&mut self) {
            if let Some(stop) = self.stop.take() {
                let _ = stop.send(());
            }
            if let Some(worker) = self.worker.take() {
                worker.join().unwrap();
            }
        }
    }

    #[test]
    fn http_lost_acknowledgement_reconciles_once_and_admitted_write_finishes_during_shutdown() {
        let f = ApiFixture::new();
        let project = Uuid::new_v4();
        f.create(project);
        let mut http = HttpFixture::start(f);
        let db = store(http.root.path(), project);
        db.conn.execute_batch("BEGIN IMMEDIATE").unwrap();
        let key = Uuid::new_v4();
        let body = serde_json::to_vec(&json!({"title":"one admitted write","body":""})).unwrap();
        let path = format!("/v1/projects/{project}/tasks");
        let socket = http.begin(Method::POST, &path, &body, Some(key));
        http.admitted(1);
        // Admission already passed both shutdown checks before nonce consumption.
        http.state.begin_shutdown();
        assert_eq!(
            HttpFixture::reply(http.begin(Method::POST, &path, &body, Some(Uuid::new_v4()))).0,
            503
        );
        db.conn.execute_batch("COMMIT").unwrap();
        drop(db);
        let acknowledged = HttpFixture::reply(socket);
        assert_eq!(acknowledged.0, 200);
        // Discard the successful acknowledgement. A read cannot prove the
        // original request outcome; reconciliation must use its receipt.
        drop(acknowledged);
        let root = std::mem::replace(&mut http.root, tempfile::tempdir().unwrap());
        let signer = SigningIdentity {
            server_id: http.signer.server_id,
            credential_id: http.signer.credential_id,
            key: http.signer.key.clone(),
        };
        drop(http);
        let server = OwnedServer::open(root.path()).unwrap();
        let f = ApiFixture {
            root,
            server,
            signer,
        };
        let replay = f.request(
            Method::POST,
            &path,
            serde_json::from_slice(&body).unwrap(),
            Some(key),
        );
        assert_eq!(replay.status, 200);
        let db = store(f.root.path(), project);
        assert_eq!(
            db.conn
                .query_row(
                    "SELECT count(*) FROM events WHERE entity_type='task'",
                    [],
                    |r| r.get::<_, u64>(0)
                )
                .unwrap(),
            1
        );
    }

    #[test]
    fn http_oversized_query_is_rejected_before_application_parsing() {
        let f = ApiFixture::new();
        let project = Uuid::new_v4();
        f.create(project);
        let http = HttpFixture::start(f);
        let socket = http.begin_with_length(
            Method::POST,
            &format!("/v1/projects/{project}/query"),
            b"",
            None,
            tasks_cli::server::transport::MAX_BODY_BYTES + 1,
        );
        assert_eq!(HttpFixture::reply(socket).0, 413);
    }

    #[test]
    fn disconnected_admitted_http_write_reconciles_to_exactly_one_mutation() {
        let f = ApiFixture::new();
        let project = Uuid::new_v4();
        f.create(project);
        let mut http = HttpFixture::start(f);
        let db = store(http.root.path(), project);
        db.conn.execute_batch("BEGIN IMMEDIATE").unwrap();
        let key = Uuid::new_v4();
        let path = format!("/v1/projects/{project}/tasks");
        let payload = json!({"title":"lost HTTP response","body":""});
        let socket = http.begin(
            Method::POST,
            &path,
            &serde_json::to_vec(&payload).unwrap(),
            Some(key),
        );
        http.admitted(1);
        drop(socket);
        db.conn.execute_batch("COMMIT").unwrap();
        drop(db);
        let root = std::mem::replace(&mut http.root, tempfile::tempdir().unwrap());
        let signer = SigningIdentity {
            server_id: http.signer.server_id,
            credential_id: http.signer.credential_id,
            key: http.signer.key.clone(),
        };
        drop(http);
        let server = OwnedServer::open(root.path()).unwrap();
        let f = ApiFixture {
            root,
            server,
            signer,
        };
        let result = f.request(Method::POST, &path, payload.clone(), Some(key));
        assert_eq!(result.status, 200);
        assert_eq!(f.request(Method::POST, &path, payload, Some(key)), result);
        let db = store(f.root.path(), project);
        assert_eq!(
            db.conn
                .query_row("SELECT count(*) FROM tasks", [], |r| r.get::<_, u64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            db.conn
                .query_row(
                    "SELECT count(*) FROM events WHERE entity_type='task'",
                    [],
                    |r| r.get::<_, u64>(0)
                )
                .unwrap(),
            1
        );
    }

    #[test]
    fn valid_uuid_creation_refusals_are_durable_without_publishing_a_project() {
        let f = ApiFixture::new();
        let project = Uuid::new_v4();
        let key = Uuid::new_v4();
        let payload = json!({"project_id":project,"name":"","project_key":"FIX"});
        let refusal = f.request(Method::POST, "/v1/projects", payload.clone(), Some(key));
        assert_eq!(refusal.status, 400);
        assert!(
            tasks_cli::store::data_root_project_path(f.root.path(), &project.to_string()).is_file(),
            "a valid project UUID must own its terminal refusal receipt"
        );
        let db = store(f.root.path(), project);
        assert_eq!(
            db.conn
                .query_row("SELECT count(*) FROM mutation_receipts", [], |r| r
                    .get::<_, u64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            db.conn
                .query_row("SELECT count(*) FROM metadata_events", [], |r| r
                    .get::<_, u64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            f.request(Method::POST, "/v1/projects", payload, Some(key)),
            refusal
        );
        assert_eq!(
            f.request(
                Method::POST,
                "/v1/projects",
                json!({"project_id":project,"name":"changed"}),
                Some(key)
            )
            .status,
            409
        );
        assert!(f
            .request(Method::GET, "/v1/projects", json!(null), None)
            .body["items"]
            .as_array()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn large_show_is_refused_with_a_split_request_error_before_loading_bodies() {
        let f = ApiFixture::new();
        let project = Uuid::new_v4();
        f.create(project);
        let mut db = store(f.root.path(), project);
        for i in 0..5 {
            db.create_task(
                &format!("large-{i}"),
                &"x".repeat(1_048_576),
                TaskStatus::Ready,
                vec![],
            )
            .unwrap();
        }
        drop(db);
        let result = f.request(
            Method::POST,
            &format!("/v1/projects/{project}/query"),
            json!({"operation":"show","ids":["1","2","3","4","5"]}),
            None,
        );
        assert_eq!(result.status, 413);
        assert!(result.body["error"]["message"]
            .as_str()
            .unwrap()
            .contains("Split"));
        let result = f.request(
            Method::POST,
            &format!("/v1/projects/{project}/query"),
            json!({"operation":"show","ids":["1"]}),
            None,
        );
        assert_eq!(result.status, 200);
        assert_eq!(
            result.body["output"]["data"]["body"]
                .as_str()
                .unwrap()
                .len(),
            1_048_576
        );
    }
}
